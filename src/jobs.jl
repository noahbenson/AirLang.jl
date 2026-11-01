################################################################################
# jobs.jl
#
# The durable job engine: scheduled events and durable tasks.
#
# A job is one database value — a `VolatileForm` holding a record mapping — stored
# as the value of a `val` in the creating user's `$.config.events` (an event) or
# `$.config.tasks` (a durable task). The record carries the captured execution
# context (the namespace, its active rule layers, the `val` bindings, `.env`, and
# `@`), the body, the schedule, the status, the promise the job fills, and — for
# a durable task — a checkpoint cell.
#
# The value is the durable root. A per-process worker registry (`_JOB_WORKERS`)
# is only an optimization: a job reopens on the next resume, and a second process
# over the same database is not coordinated with the first (see `book/events.md`).
#
# Work runs on a spawned task in the job's own thread context, so each top-level
# write is its own transaction, exactly as with `task`. The outcome is committed
# in one transaction that also settles the promise, so a crash cannot leave a
# finished job with an undelivered promise.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- the record shape --------------------------------------------------------

const _JOB_VERSION = 1
const _JOB_CONFIG_SEG = Symbol("config")
const _JOB_EVENTS_SEG = Symbol("events")
const _JOB_TASKS_SEG = Symbol("tasks")
const _JOB_POLL = 0.25

const _JK_VERSION = Symbol(":version")
const _JK_ID = Symbol(":id")
const _JK_NAME = Symbol(":name")
const _JK_KIND = Symbol(":kind")
const _JK_OWNER = Symbol(":owner")
const _JK_TX = Symbol(":tx")
const _JK_CTX = Symbol(":ctx")
const _JK_BODY = Symbol(":body")
const _JK_AT = Symbol(":at")
const _JK_INTERVAL = Symbol(":interval")
const _JK_REPEAT = Symbol(":repeat")
const _JK_STATUS = Symbol(":status")
const _JK_ATTEMPTS = Symbol(":attempts")
const _JK_DELIVERED = Symbol(":delivered")
const _JK_CHECKPOINTS = Symbol(":checkpoints")
const _JK_RESULT = Symbol(":result")
const _JK_ERROR = Symbol(":error")
const _JK_PROMISE = Symbol(":promise")
const _JK_CREATED = Symbol(":created")
const _JK_STARTED = Symbol(":started")
const _JK_FINISHED = Symbol(":finished")
const _JK_UPDATED = Symbol(":updated")

const _JOB_PENDING = :pending
const _JOB_RUNNING = :running
const _JOB_DONE = :done
const _JOB_ERROR = :error
const _JOB_CANCELLED = :cancelled

_job_terminal(status::Symbol) = status === _JOB_DONE || status === _JOB_ERROR ||
                               status === _JOB_CANCELLED

_job_kind_seg(kind::Symbol) = kind === :task ? _JOB_TASKS_SEG : _JOB_EVENTS_SEG
_job_noun(kind::Symbol) = kind === :task ? "task" : "event"

# ---- reading a record --------------------------------------------------------

# A field of a mapping form, or `nothing`.
function _job_field(f::Form, name::Symbol)
    (f isa FormContainer && haskey(f, name)) || return nothing
    return to_form(f[name])
end

# A field of a mapping form, or `naught`.
_job_or_naught(f::Form, name::Symbol) = begin
    v = _job_field(f, name)
    v === nothing ? naught : v
end

# A field's bare symbol (a keyword or symbol), or `nothing`.
function _job_sym(f::Form, name::Symbol)
    v = _job_field(f, name)
    v === nothing && return nothing
    s = _symbolof(v)
    return s === nothing ? nothing : _bindname(s)
end

# A field's truth value; a missing field is false.
function _job_flag(f::Form, name::Symbol)
    v = _job_field(f, name)
    return v !== nothing && truthy(v)
end

# A field's integer value; a missing field is 0.
function _job_count(f::Form, name::Symbol)
    v = _job_field(f, name)
    v === nothing && return 0
    l = _leafof(v)
    return l isa Integer ? Int(l) : 0
end

# A field's real value, or `nothing`.
function _job_real(f::Form, name::Symbol)
    v = _job_field(f, name)
    v === nothing && return nothing
    l = _leafof(v)
    return l isa Real ? Float64(l) : nothing
end

# The record value behind a job mutable.
_job_record_value(vf::VolatileForm) = canonicalize(to_form(vf[]))

_job_head(rec::Form) = rec isa FormContainer ? head_symbol(rec) : nothing
_job_is_record(rec::Form) =
    _job_head(rec) === :event || _job_head(rec) === :task

_job_status(rec::Form) = something(_job_sym(rec, _JK_STATUS), _JOB_PENDING)
_job_kind(rec::Form) = something(_job_sym(rec, _JK_KIND), :event)
_job_owner(rec::Form) = _job_sym(rec, _JK_OWNER)
_job_name(rec::Form) = _job_sym(rec, _JK_NAME)
_job_id(rec::Form) = begin
    v = _job_field(rec, _JK_ID)
    v === nothing ? "" : string(_leafof(v))
end

# The epoch seconds at which the job is next due.
function _job_at_secs(rec::Form)
    v = _job_field(rec, _JK_AT)
    v === nothing && return 0.0
    _is_time_form(v) && return _time_secs(v)
    l = _leafof(v)
    return l isa Real ? Float64(l) : 0.0
end

# The re-arm delay of a repeating job, in seconds.
_job_interval_secs(rec::Form) = something(_job_real(rec, _JK_INTERVAL), 0.0)

# A record with selected map entries replaced. This is the generic
# container-edit helper the agent layer introduced; a job record is the same
# shape, so it is shared rather than copied.
_job_set(rec::FormContainer, pairs::AbstractVector) = _agent_set(rec, pairs)

# A summary: the record without its body or captured context.
const _JOB_SUMMARY_KEYS = (_JK_ID, _JK_NAME, _JK_KIND, _JK_TX, _JK_OWNER,
                           _JK_STATUS, _JK_AT, _JK_INTERVAL, _JK_REPEAT,
                           _JK_ATTEMPTS, _JK_DELIVERED, _JK_PROMISE, _JK_RESULT,
                           _JK_ERROR, _JK_CREATED, _JK_STARTED, _JK_FINISHED,
                           _JK_UPDATED)

function _job_summary(rec::Form)
    return _ns_form(Form[], Pair{Symbol,Form}[k => _job_or_naught(rec, k)
                                              for k in _JOB_SUMMARY_KEYS])
end

# ---- the config namespace ----------------------------------------------------

_job_config_path(home::Vector{Symbol}, kind::Symbol) =
    vcat(home, Symbol[_JOB_CONFIG_SEG, _job_kind_seg(kind)])

# The name and record mutable of a `val` entry, or `nothing`.
function _job_entry_parts(e::Form)
    _entry_head(e) === _VAL_HEAD || return nothing
    body = _entry_body(e)
    body isa FormContainer || return nothing
    length(body.seq) == 3 || return nothing
    name = _def_name(to_form(body.seq[2]))
    name === nothing && return nothing
    return (name = name, value = to_form(body.seq[3]))
end

# The newest entry defining `name` whose value is a job record of `kind`.
function _job_entry_named(env::Env, ns::Namespace, name::Symbol, kind::Symbol)
    entries = _ns_entries_of(ns.vf)
    for i in length(entries):-1:1
        parts = _job_entry_parts(entries[i])
        (parts === nothing || parts.name !== name) && continue
        v = parts.value
        v isa VolatileForm || return nothing
        _job_kind(_job_record_value(v)) === kind || return nothing
        return v
    end
    return nothing
end

# The newest readable entry for every name, newest name first. A record shadowed
# by a later definition of the same name is not listed.
function _job_entries(env::Env, ns::Namespace, kind::Symbol)
    out = Pair{Symbol,VolatileForm}[]
    seen = Set{Symbol}()
    entries = _ns_entries_of(ns.vf)
    for i in length(entries):-1:1
        parts = _job_entry_parts(entries[i])
        parts === nothing && continue
        parts.name in seen && continue
        v = parts.value
        if !(v isa VolatileForm) || _job_kind(_job_record_value(v)) !== kind
            continue
        end
        push!(seen, parts.name)
        _can(env, v, :read) || continue
        push!(out, parts.name => v)
    end
    return out
end

# The config namespace of one user, or `nothing`.
function _job_config_ns(env::Env, user::Symbol, kind::Symbol)
    home = _user_home_path(env, user)
    home === nothing && return nothing
    return _ns_lookup(env, _job_config_path(home, kind); lazy = false)
end

# The record mutable a name or promise names, or `nothing`.
function _job_lookup(env::Env, kind::Symbol, name::Symbol, user::Symbol)
    ns = _job_config_ns(env, user, kind)
    ns === nothing && return nothing
    return _job_entry_named(env, ns, name, kind)
end

# The record mutable whose promise is `p`, among the users the caller may see.
function _job_lookup_promise(env::Env, kind::Symbol, p::PromiseForm)
    for u in _visible_user_ids(env, _current_user(env))
        ns = _job_config_ns(env, u, kind)
        ns === nothing && continue
        for (_, vf) in _job_entries(env, ns, kind)
            q = _job_field(_job_record_value(vf), _JK_PROMISE)
            q isa PromiseForm && q.id == p.id && return vf
        end
    end
    return nothing
end

# ---- names and bindings ------------------------------------------------------

# A `name=` argument as a bare symbol.
function _job_name_arg(env::Env, scope::Scope, x::Form, who::AbstractString)
    l = _leafof(air_reduce(env, scope, to_form(x)))
    s = if l isa Symbol
        _bindname(l)
    elseif l isa AbstractString
        Symbol(l)
    else
        nothing
    end
    s === nothing && throw(AirEvalError(
        "$(who): a name must be a keyword, symbol, or string, got $(air_string(to_form(l)))"))
    _valid_name_segment(String(s)) || throw(AirEvalError(
        "$(who): invalid name $(repr(String(s)))"))
    return s
end

# The name→value mapping a job stores. `true` snapshots the current thread's
# bindings, `false` (or a missing option) stores none unless `default_snapshot`,
# and a mapping is resolved and validated now so a bad name fails at creation.
function _job_bindings_form(env::Env, scope::Scope, opt,
                            default_snapshot::Bool)
    opt === nothing &&
        return default_snapshot ? _bindings_form(env) : _ns_empty_value()
    l = opt isa Form ? _leafof(opt) : nothing
    l === true && return _bindings_form(env)
    l === false && return _ns_empty_value()
    (opt isa FormContainer && isempty(opt.seq)) || throw(AirEvalError(
        "bindings must be true, false, or a mapping of names to values, got " *
        air_string(to_form(opt))))
    pairs = Pair{Symbol,Form}[]
    for (k, v) in opt.map
        name = _bindname(k)
        _find_val_binding(env, scope, name) === nothing && throw(AirEvalError(
            "bindings: $name is not a thread-local value in this context"))
        push!(pairs, k => canonicalize(to_form(v)))
    end
    return _ns_form(Form[], pairs)
end

# The `Var` dictionary a plain task installs from its `bindings=` option.
function _job_binding_dict(env::Env, scope::Scope, opt, clean::Bool)
    opt === nothing && return clean ? IdDict{Var,Any}() : Air.vars()
    f = _job_bindings_form(env, scope, opt, false)
    d = IdDict{Var,Any}()
    f isa FormContainer || return d
    for (k, v) in f.map
        b = _find_val_binding(env, scope, _bindname(k))
        b === nothing && continue
        d[b.var] = canonicalize(to_form(v))
    end
    return d
end

# ---- creating a job ----------------------------------------------------------

# A fresh unique id text with the given prefix.
_job_new_id(prefix::AbstractString) =
    prefix * string(rand(UInt64); base = 16, pad = 16)

# A name for an unnamed job: `e-…` for an event, `t-…` for a task.
function _job_generated_name(ns::Namespace, kind::Symbol)
    prefix = kind === :task ? "t-" : "e-"
    while true
        nm = Symbol(prefix * string(rand(UInt64); base = 16, pad = 16))
        _job_entry_parts_name_free(ns, nm) && return nm
    end
end

# Whether no entry in `ns` defines `name`.
function _job_entry_parts_name_free(ns::Namespace, name::Symbol)
    for e in _ns_entries_of(ns.vf)
        parts = _job_entry_parts(e)
        (parts !== nothing && parts.name === name) && return false
    end
    return true
end

# Reject a name already used by a live record. A terminal record's name can be
# reused: the new entry shadows it (later definitions win).
function _job_check_name!(env::Env, ns::Namespace, kind::Symbol, name::Symbol)
    vf = _job_entry_named(env, ns, name, kind)
    vf === nothing && return name
    _job_terminal(_job_status(_job_record_value(vf))) && return name
    throw(AirEvalError("($(_job_noun(kind))-exists name=$(air_string(Form(name))))"))
end

"""
    _job_create!(env, scope, kind; body, bindings, …) -> (vf, promise, name)

Register a durable job and start its worker. `body` is the uncaptured body (one
`do`/`tx` container for an event, the sequence of forms for a task). Creation and
registration happen in one transaction as the current user, so a job always
belongs to the user who scheduled it.
"""
function _job_create!(env::Env, scope::Scope, kind::Symbol;
                      body::Vector{Form},
                      bindings::Form = _ns_empty_value(),
                      envform::Union{Nothing,Form} = nothing,
                      name::Union{Nothing,Symbol} = nothing,
                      tx::Bool = false,
                      repeat::Bool = false,
                      at::Real = _now_secs(),
                      interval::Union{Nothing,Real} = nothing,
                      user::Symbol = _current_user(env))
    currtx() === nothing || throw(AirEvalError(
        "a durable $(_job_noun(kind)) cannot be created inside a transaction"))
    home = _user_home_path(env, user)
    home === nothing &&
        throw(AirEvalError("no home namespace for :$user"))
    c = _context(env)
    nspath = c.ns isa Namespace ? copy(c.ns.path) : Symbol[]
    captured = Form[_capture_form(scope, b) for b in body]
    ctxform = _capture_context(env, scope, nspath, _context_db_path(env);
                               bindings = bindings, envform = envform)
    md = _metadata_form(user; acl = _perms_acl(user))
    now = _mk_time(_now_secs())
    idtext = _job_new_id(kind === :task ? "t-" : "e-")
    path = _job_config_path(home, kind)
    made = _tx_boundary(env) do
        ns = _ns_ensure!(env, path)
        db = _ns_db(env, ns)
        _check_db_principal!(env, db, user)
        nm = name === nothing ? _job_generated_name(ns, kind) :
             _job_check_name!(env, ns, kind, name)
        p = PromiseForm(db; metadata = md)
        cps = kind === :task ?
            VolatileForm(db, _ns_empty_value(); metadata = md, history = false) :
            naught
        pairs = Pair{Symbol,Form}[
            _JK_VERSION => Form(_JOB_VERSION),
            _JK_ID => Form(idtext),
            _JK_NAME => Form(nm),
            _JK_KIND => Form(Symbol(":", String(kind))),
            _JK_OWNER => _keyword_form(user),
            _JK_TX => Form(tx),
            _JK_CTX => ctxform,
            _JK_BODY => _ns_form(captured),
            _JK_AT => _mk_time(at),
            _JK_INTERVAL => interval === nothing ? naught : Form(Float64(interval)),
            _JK_REPEAT => Form(repeat),
            _JK_STATUS => Form(Symbol(":", String(_JOB_PENDING))),
            _JK_ATTEMPTS => Form(0),
            _JK_DELIVERED => Form(false),
            _JK_CHECKPOINTS => cps,
            _JK_RESULT => naught,
            _JK_ERROR => naught,
            _JK_PROMISE => p,
            _JK_CREATED => now,
            _JK_STARTED => naught,
            _JK_FINISHED => naught,
            _JK_UPDATED => now]
        rec = _ns_form(Form[Form(Symbol(String(kind)))], pairs)
        _check_storable!(env, db, rec)
        vf = VolatileForm(db, rec; metadata = md, history = false)
        _ns_add_val!(env, ns, Form(nm), vf; owner = user)
        (vf = vf, promise = p, name = nm)
    end
    _ensure_job_worker!(env, made.vf)
    return made
end

# Read-modify-write a job record in one transaction, returning the new record
# (or the unchanged one when `f` returns `nothing`).
function _job_update!(env::Env, vf::VolatileForm, f::Function)
    return _tx_boundary(env) do
        _ensure_hooks!(env, vf)
        _record_write!(env, vf)
        cur = _job_record_value(vf)
        cur isa FormContainer ||
            throw(AirEvalError("a job record is not a mapping"))
        new = f(cur)
        if new !== nothing
            _check_storable!(env, vf.db, new)
            setindex!(vf, new)
        end
        new === nothing ? cur : new
    end
end
_job_update!(f::Function, env::Env, vf::VolatileForm) = _job_update!(env, vf, f)

# Whether an error is a lost promise-settlement race. Air promises are
# single-assignment, so a second settlement raises at commit.
_job_settlement_error(e) =
    e isa ArgumentError && occursin("already fulfilled", sprint(showerror, e))

# Run an update that may settle the promise; a lost settlement race is retried
# once with delivery skipped, so the status transition is never lost.
function _job_settling_update!(env::Env, vf::VolatileForm, f::Function)
    try
        return _job_update!(env, vf, f(true))
    catch e
        _job_settlement_error(e) || rethrow()
        return _job_update!(env, vf, f(false))
    end
end

# ---- the process registry ----------------------------------------------------

mutable struct _JobWorker
    task::Union{Nothing,Task}
    done::Bool
end

const _JOB_WORKERS = Dict{Base.UUID,_JobWorker}()
const _JOB_WORKERS_LOCK = ReentrantLock()

_job_worker_live(w::Union{Nothing,_JobWorker}) =
    w !== nothing && w.task !== nothing && !istaskdone(w.task) && !w.done

_job_worker_running(id::Base.UUID) = _job_worker_live(get(_JOB_WORKERS, id, nothing))

"""
    _ensure_job_worker!(env, vf) -> nothing

Start a worker for a pending job unless one is already running in this process.
The worker runs as the job's owner, in the owner's home namespace.
"""
function _ensure_job_worker!(env::Env, vf::VolatileForm)
    rec = _job_record_value(vf)
    _job_status(rec) === _JOB_PENDING || return nothing
    owner = _job_owner(rec)
    owner === nothing && return nothing
    home = _user_home_path(env, owner)
    home === nothing && return nothing
    ns = _ns_lookup(env, home; lazy = false)
    ns === nothing && return nothing
    ctx = TaskContext(owner, ns, nothing, naught)
    key = vf.id
    lock(_JOB_WORKERS_LOCK)
    try
        _job_worker_live(get(_JOB_WORKERS, key, nothing)) && return nothing
        w = _JobWorker(nothing, false)
        _JOB_WORKERS[key] = w
        se = _session_env(env)
        t = Threads.@spawn begin
            _reset_block_scopes!()
            try
                _with_context(se, ctx, () -> _job_worker_loop(se, vf))
            catch e
                e isa InterruptException && rethrow()
            finally
                w.done = true
                lock(_JOB_WORKERS_LOCK) do
                    cur = get(_JOB_WORKERS, key, nothing)
                    cur === w && delete!(_JOB_WORKERS, key)
                end
            end
        end
        w.task = t
    finally
        unlock(_JOB_WORKERS_LOCK)
    end
    return nothing
end

# ---- the worker --------------------------------------------------------------

# Wait until the job is due, claim it, run one attempt, and finish it. A
# repeating job is re-armed by its finish and loops; anything else ends here.
function _job_worker_loop(env::Env, vf::VolatileForm)
    while true
        rec = _job_record_value(vf)
        _job_status(rec) === _JOB_PENDING || return nothing
        remaining = _job_at_secs(rec) - _now_secs()
        if remaining > 0
            sleep(min(remaining, _JOB_POLL))
            continue
        end
        claimed = _job_claim!(env, vf)
        claimed === nothing && return nothing
        outcome = _job_run_attempt!(env, claimed)
        _job_finish!(env, vf, claimed, outcome) || return nothing
    end
end

# Move a due job from `:pending` to `:running`, or `nothing` when it is no longer
# pending (a cancel may race the claim).
function _job_claim!(env::Env, vf::VolatileForm)
    claimed = Ref{Any}(nothing)
    _job_update!(env, vf, rec -> begin
        _job_status(rec) === _JOB_PENDING || return nothing
        now = _mk_time(_now_secs())
        new = _job_set(rec, Pair{Symbol,Form}[
            _JK_STATUS => Form(Symbol(":", String(_JOB_RUNNING))),
            _JK_ATTEMPTS => Form(_job_count(rec, _JK_ATTEMPTS) + 1),
            _JK_STARTED => now,
            _JK_UPDATED => now])
        claimed[] = new
        new
    end)
    return claimed[]
end

# `(checkpoint form)` replay state: one per run, task-local.
struct _JobRun
    id::String
    cell::VolatileForm
    cursor::Base.RefValue{Int}
    lock::ReentrantLock
end

const _JOB_RUN_KEY = :airlang_job_run

function _current_job_run()
    tls = task_local_storage()
    tls isa IdDict || return nothing
    r = get(tls, _JOB_RUN_KEY, nothing)
    return r isa _JobRun ? r : nothing
end

# The recorded checkpoint values of a cell, as a plain list.
function _job_checkpoint_list(x::Form)
    x isa FormContainer || return Form[]
    return Form[to_form(v) for v in x.seq]
end

# Evaluate one attempt and report its outcome. The body runs in the captured
# context; a `:running` durable task installs a fresh replay cursor.
function _job_run_attempt!(env::Env, rec::Form)
    ctxform = _job_field(rec, _JK_CTX)
    ctxform === nothing &&
        return (ok = false, value = naught,
                error = AirEvalError("a job record has no captured context"))
    r = try
        _restore_context(env, ctxform; user = _job_owner(rec))
    catch e
        return (ok = false, value = naught, error = e)
    end
    body = _job_field(rec, _JK_BODY)
    forms = _job_checkpoint_list(body)
    cps = _job_field(rec, _JK_CHECKPOINTS)
    runstate = cps isa VolatileForm ?
        _JobRun(_job_id(rec), cps, Ref(0), ReentrantLock()) : nothing
    evalb = () -> Air.setvars(() -> begin
        v = naught
        for b in forms
            v = air_reduce(env, r.scope, b)
        end
        v
    end, r.binds)
    ev = runstate === nothing ? evalb :
        () -> task_local_storage(_JOB_RUN_KEY, runstate) do
            evalb()
        end
    try
        return (ok = true, value = _with_context(env, r.ctx, ev), error = nothing)
    catch e
        # `(exit v)` ends the run: its value is the result.
        e isa ExitSignal && return (ok = true, value = e.value, error = nothing)
        e isa InterruptException && rethrow()
        if e isa AirThrowSignal
            e = AirThrown(_error_object(Form(Symbol(":uncaught-throw")),
                                        e.tag, e.value))
        end
        return (ok = false, value = naught, error = e)
    end
end

# Commit an attempt's outcome and settle the promise. Returns whether the job
# was re-armed as a repeat; false means the worker should stop.
function _job_finish!(env::Env, vf::VolatileForm, rec::Form, outcome)
    rearmed = Ref(false)
    ok = outcome.ok
    stored = naught
    errform = naught
    if ok
        p = _job_field(rec, _JK_PROMISE)
        db = p isa PromiseForm ? p.db : vf.db
        try
            _check_storable!(env, db, outcome.value)
            stored = outcome.value
        catch e
            e isa AirUnstorable || rethrow()
            # An unstorable result must not lose the promise: deliver the error.
            ok = false
            errform = _error_form(e)
        end
    else
        errform = _error_form(outcome.error)
    end
    deliverable = ok ? stored : errform
    _job_settling_update!(env, vf, deliver -> cur -> begin
        _job_status(cur) === _JOB_CANCELLED && return nothing
        now = _mk_time(_now_secs())
        pairs = Pair{Symbol,Form}[]
        ok && push!(pairs, _JK_RESULT => stored)
        push!(pairs, _JK_ERROR => errform)
        if deliver && !_job_flag(cur, _JK_DELIVERED)
            q = _job_field(cur, _JK_PROMISE)
            if q isa PromiseForm && !isready(q)
                put!(q, deliverable)
                push!(pairs, _JK_DELIVERED => Form(true))
            end
        end
        # A completed run's checkpoints are spent.
        cps = _job_field(cur, _JK_CHECKPOINTS)
        cps isa VolatileForm && setindex!(cps, _ns_empty_value())
        if _job_flag(cur, _JK_REPEAT)
            push!(pairs, _JK_STATUS => Form(Symbol(":", String(_JOB_PENDING))))
            push!(pairs, _JK_AT => _mk_time(_now_secs() +
                                            _job_interval_secs(cur)))
            push!(pairs, _JK_UPDATED => now)
            rearmed[] = true
        else
            st = ok ? _JOB_DONE : _JOB_ERROR
            push!(pairs, _JK_STATUS => Form(Symbol(":", String(st))))
            push!(pairs, _JK_FINISHED => now)
            push!(pairs, _JK_UPDATED => now)
        end
        _job_set(cur, pairs)
    end)
    return rearmed[]
end

# ---- checkpoints -------------------------------------------------------------

# The error object a cancel delivers to the job's promise.
function _job_cancel_object(rec::Form, kind::Symbol)
    tag = kind === :task ? Symbol("task-cancelled") : Symbol("event-cancelled")
    return _error_object(Form[Form(Symbol(":", String(tag)))],
                         Pair{Symbol,FormValue}[
                             Symbol(":name") => Form(_job_name(rec))])
end

# ---- cancel ------------------------------------------------------------------

"""
    _job_cancel!(env, vf) -> Form

Cancel a non-terminal job: settle an undelivered promise with a cancellation
error and set the status to `:cancelled`. Cancelling a terminal job is a no-op.
This is not preemption — a body already running may still commit its own writes.
"""
function _job_cancel!(env::Env, vf::VolatileForm)
    rec = _job_record_value(vf)
    kind = _job_kind(rec)
    _check!(env, vf, :write)
    _job_terminal(_job_status(rec)) && return _job_summary(rec)
    obj = _job_cancel_object(rec, kind)
    _job_settling_update!(env, vf, deliver -> cur -> begin
        _job_terminal(_job_status(cur)) && return nothing
        pairs = Pair{Symbol,Form}[
            _JK_STATUS => Form(Symbol(":", String(_JOB_CANCELLED))),
            _JK_ERROR => obj,
            _JK_UPDATED => _mk_time(_now_secs())]
        if deliver && !_job_flag(cur, _JK_DELIVERED)
            q = _job_field(cur, _JK_PROMISE)
            if q isa PromiseForm && !isready(q)
                put!(q, obj)
                push!(pairs, _JK_DELIVERED => Form(true))
            end
        end
        _job_set(cur, pairs)
    end)
    return _job_summary(_job_record_value(vf))
end

# ---- resume ------------------------------------------------------------------

"""
    _job_resume!(env, vf) -> Bool

Return an interrupted job to `:pending` and make sure a worker is running. A
`:running` record with no live worker in this process was interrupted by a
restart; its checkpoints replay on the next attempt. Returns whether the record
is non-terminal (and therefore active again).
"""
function _job_resume!(env::Env, vf::VolatileForm)
    rec = _job_record_value(vf)
    _job_terminal(_job_status(rec)) && return false
    _job_update!(env, vf, cur -> begin
        st = _job_status(cur)
        st === _JOB_RUNNING || return nothing
        _job_worker_running(vf.id) && return nothing
        _job_set(cur, Pair{Symbol,Form}[
            _JK_STATUS => Form(Symbol(":", String(_JOB_PENDING))),
            _JK_UPDATED => _mk_time(_now_secs())])
    end)
    _ensure_job_worker!(env, vf)
    return true
end

# Resume every job of one kind belonging to `user`.
function _job_resume_user!(env::Env, user::Symbol, kind::Symbol)
    home = _user_home_path(env, user)
    home === nothing && return 0
    ns = _ns_lookup(env, home; lazy = false)
    ns === nothing && return 0
    ctx = TaskContext(user, ns, nothing, naught)
    return _with_context(env, ctx, () -> begin
        jns = _job_config_ns(env, user, kind)
        jns === nothing && return 0
        n = 0
        for (_, vf) in _job_entries(env, jns, kind)
            _job_resume!(env, vf) && (n += 1)
        end
        n
    end)
end

"""
    _resume_all_jobs!(env, kind) -> Int

Resume every job of `kind` the current user may see. A past-due one-shot fires
at once; a repeating event fires once and re-arms (missed occurrences coalesce).
"""
function _resume_all_jobs!(env::Env, kind::Symbol)
    n = 0
    for u in _visible_user_ids(env, _current_user(env))
        n += _job_resume_user!(env, u, kind)
    end
    return n
end

# Resume without letting one bad record prevent startup.
function _resume_jobs_quietly!(env::Env)
    for kind in (:event, :task)
        try
            _resume_all_jobs!(env, kind)
        catch e
            e isa InterruptException && rethrow()
            println(stderr, "air: could not resume $(_job_noun(kind)) jobs: ",
                    sprint(showerror, e))
        end
    end
    return nothing
end

# ---- the checkpoint special form ---------------------------------------------

# The recorded value at `i`, or `nothing` when this run has not reached it.
function _job_checkpoint_stored(env::Env, cell::VolatileForm, i::Int)
    _check!(env, cell, :read)
    entries = _job_checkpoint_list(canonicalize(to_form(cell[])))
    return i <= length(entries) ? entries[i] : nothing
end

# Record the value at `i`, or return the value another attempt recorded first.
function _job_checkpoint_store!(env::Env, cell::VolatileForm, i::Int, v::Form)
    got = Ref(v)
    _tx_boundary(env) do
        entries = _job_checkpoint_list(canonicalize(to_form(cell[])))
        if i <= length(entries)
            got[] = entries[i]
        else
            push!(entries, v)
            setindex!(cell, _ns_form(entries))
        end
    end
    return got[]
end

"""
    _bi_checkpoint(env, scope, call)

`(checkpoint form)` — a replay point in a durable task. Outside a durable run it
evaluates `form` and returns it, so the same body works as an event or a plain
task. Inside a run it returns the recorded value when a previous attempt reached
this point, and otherwise evaluates `form`, records it, and returns it.
"""
function _bi_checkpoint(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "checkpoint", ())
    length(call.seq) == 2 ||
        throw(AirEvalError("checkpoint takes exactly one form"))
    form = to_form(call.seq[2])
    run = _current_job_run()
    run === nothing && return air_reduce(env, scope, form)
    currtx() === nothing || throw(AirEvalError(
        "checkpoint cannot run inside a transaction: its replay cursor " *
        "cannot roll back with a retried transaction"))
    i = lock(run.lock) do
        run.cursor[] += 1
        run.cursor[]
    end
    stored = _job_checkpoint_stored(env, run.cell, i)
    stored === nothing || return stored
    v = air_reduce(env, scope, form)
    _check_storable!(env, run.cell.db, v)
    return _job_checkpoint_store!(env, run.cell, i, v)
end
special!(:checkpoint, _bi_checkpoint)

# ---- the query builtins ------------------------------------------------------

# A user argument at position `i`, or the current user; a stranger is refused.
function _job_user_arg(env::Env, scope::Scope, args, i::Int)
    length(args) < i && return _current_user(env)
    u = _user_id_arg(env, scope, args[i])
    (u === _AIR || u in _visible_user_ids(env, _current_user(env))) ||
        throw(AirEvalError("you cannot see the jobs of :$u"))
    return u
end

# The record mutable a query argument names, or an error object.
function _job_target(env::Env, scope::Scope, args, kind::Symbol,
                     who::AbstractString)
    x = _arg(args, 1, who)
    if x isa PromiseForm
        vf = _job_lookup_promise(env, kind, x)
        vf === nothing && return _job_not_found(kind, nothing)
        return vf
    end
    user = _job_user_arg(env, scope, args, 2)
    name = try
        _job_name_arg(env, scope, x, who)
    catch e
        e isa AirError || rethrow()
        return _job_error_obj(_job_not_found_tag(kind),
                              Pair{Symbol,FormValue}[Symbol(":name") => x])
    end
    vf = _job_lookup(env, kind, name, user)
    vf === nothing && return _job_not_found(kind, name)
    return vf
end

_job_not_found_tag(kind::Symbol) =
    kind === :task ? Symbol("task-not-found") : Symbol("event-not-found")

_job_not_found(kind::Symbol, name) =
    _job_error_obj(_job_not_found_tag(kind),
                   name === nothing ? Pair{Symbol,FormValue}[] :
                   Pair{Symbol,FormValue}[Symbol(":name") => Form(name)])

_job_error_obj(tag::Symbol, pairs::Vector{Pair{Symbol,FormValue}}) =
    _error_object(Form[Form(Symbol(":", String(tag)))], pairs)

# The map form `(name=(summary) …)` of one user's jobs.
function _job_listing(env::Env, user::Symbol, kind::Symbol)
    ns = _job_config_ns(env, user, kind)
    ns === nothing && return _ns_empty_value()
    pairs = Pair{Symbol,Form}[]
    for (name, vf) in _job_entries(env, ns, kind)
        push!(pairs, Symbol(":", String(name)) => _job_summary(_job_record_value(vf)))
    end
    return _ns_form(Form[], pairs)
end

function _job_info_builtin(env::Env, scope::Scope, args, kind::Symbol,
                           who::AbstractString)
    vf = _job_target(env, scope, args, kind, who)
    vf isa VolatileForm || return vf
    _check!(env, vf, :read)
    return _job_summary(_job_record_value(vf))
end

function _job_cancel_builtin(env::Env, scope::Scope, args, kind::Symbol,
                             who::AbstractString)
    vf = _job_target(env, scope, args, kind, who)
    vf isa VolatileForm || return vf
    _check!(env, vf, :write)
    rec = _job_record_value(vf)
    owner = _job_owner(rec)
    if owner === nothing || owner === _current_user(env)
        return _job_cancel!(env, vf)
    end
    home = _user_home_path(env, owner)
    ns = home === nothing ? nothing : _ns_lookup(env, home; lazy = false)
    ns === nothing && return _job_cancel!(env, vf)
    return _with_context(env, TaskContext(owner, ns, nothing, naught),
                         () -> _job_cancel!(env, vf))
end

function _job_resume_builtin(env::Env, scope::Scope, args, kind::Symbol,
                             who::AbstractString)
    length(args) <= 1 || throw(AirEvalError("$who takes an optional user name"))
    n = isempty(args) ? _resume_all_jobs!(env, kind) :
        _job_resume_user!(env, _job_user_arg(env, scope, args, 1), kind)
    return _ns_form(Form[], Pair{Symbol,Form}[Symbol(":resumed") => Form(n)])
end

builtin!(:events, (env, scope, args) -> begin
    isempty(args) || length(args) == 1 ||
        throw(AirEvalError("events takes an optional user name"))
    return _job_listing(env, _job_user_arg(env, scope, args, 1), :event)
end)

builtin!(:tasks, (env, scope, args) -> begin
    isempty(args) || length(args) == 1 ||
        throw(AirEvalError("tasks takes an optional user name"))
    return _job_listing(env, _job_user_arg(env, scope, args, 1), :task)
end)

builtin!(:event, (env, scope, args) ->
    _job_info_builtin(env, scope, args, :event, "event"))

builtin!(Symbol("task-info"), (env, scope, args) ->
    _job_info_builtin(env, scope, args, :task, "task-info"))

builtin!(Symbol("cancel-event"), (env, scope, args) ->
    _job_cancel_builtin(env, scope, args, :event, "cancel-event"))

builtin!(Symbol("cancel-task"), (env, scope, args) ->
    _job_cancel_builtin(env, scope, args, :task, "cancel-task"))

builtin!(Symbol("events-resume"), (env, scope, args) ->
    _job_resume_builtin(env, scope, args, :event, "events-resume"))

builtin!(Symbol("tasks-resume"), (env, scope, args) ->
    _job_resume_builtin(env, scope, args, :task, "tasks-resume"))
