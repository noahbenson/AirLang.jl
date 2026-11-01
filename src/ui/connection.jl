################################################################################
# ui/connection.jl
#
# Connections: where the bytes of a human interface come from, separated from
# the widgets shown on them.
#
# A connection is a durable record under `.io.conn` — a mutable holding a
# sequence of connection forms — plus a process-local handle that joins that
# record to a live byte source. The record outlives the socket; the handle is
# never serialized.
#
#     .io.conn.air            ns   — air's connection endpoints
#     .io.conn.air.std        mut  — air's local/stdio endpoint
#     .io.conn.air.s1         mut  — air's first remote session
#     .io.conn.alice          mut  — a core user's own endpoint
#     .io.conn.air.bob        mut  — a constituent's endpoint (`air:bob`)
#
# A record is `(conn id=… kind=… user=… principal=… since=… tty=… cols=… rows=…
# attached=… closed=…)`. Every field is inert data: keywords, numbers, booleans,
# `()` and `(time …)`.
#
# The ACL is `read=_`, `write=<owner>`, so the record is readable by everyone and
# writable only by the user (or, for a constituent, the admin) — the named user
# of a constituent's record can read their own connection but not edit it. The
# system itself writes the record on attach/detach/close as `air`.
#
# Attaching a widget to a connection runs a renderer on that connection's byte
# source until the widget is dismissed. Only the task that opened the connection
# may attach (a byte source belongs to one reader); detaching from any task is
# allowed, because it is only a flag.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _CONN_ROOT = Symbol("io")
const _CONN_DIR = Symbol("conn")
const _CONN_HEAD = Symbol("conn")

# ---- the handle --------------------------------------------------------------

"""
    _ConnHandle

One live connection: the durable record's path and id, who it belongs to, the
byte source, and the widget currently attached to it.
"""
mutable struct _ConnHandle
    env::Env                        # the environment the record lives in
    path::Vector{Symbol}
    id::Symbol
    user::Symbol
    kind::Symbol                    # :std, :local, :ssh
    tty::Bool
    cols::Int
    rows::Int
    since::Float64
    closed_at::Float64
    out::Any                        # the session IO (nothing for the local one)
    backend::Union{Nothing,_TermBackend}
    inst::Union{Nothing,_UiInstance}
    task::Union{Nothing,Task}
    closed::Bool
    lock::ReentrantLock
end

const _CONN_REGISTRY = _ConnHandle[]
const _CONN_LOCK = ReentrantLock()

# ---- paths -------------------------------------------------------------------

_conn_user_parts(user::Symbol) = Symbol.(split(String(user), ':'))

# The user who owns a connection record: a constituent's record belongs to its
# admin (so the constituent may read it but not edit it).
function _conn_owner(user::Symbol)
    p = _conn_user_parts(user)
    return length(p) == 2 ? p[1] : user
end

# The mutable that holds a user's connection records. Air and each constituent
# get a named endpoint (their connection namespace is real); a core user's
# endpoint is the entry named after them.
function _conn_path(user::Symbol, id::Symbol = :std)
    p = _conn_user_parts(user)
    length(p) == 2 && return Symbol[_CONN_ROOT, _CONN_DIR, p[1], p[2]]
    user === _AIR && return Symbol[_CONN_ROOT, _CONN_DIR, _AIR, id]
    return Symbol[_CONN_ROOT, _CONN_DIR, user]
end

# Display/spelling helpers.
_conn_display(path::Vector{Symbol}) = join(String.(path), ".")

function _conn_parse_path(s::AbstractString)
    t = strip(String(s))
    isempty(t) && return nothing
    parts = Symbol.(split(t, '.'))
    (length(parts) >= 3 && parts[1] === _CONN_ROOT && parts[2] === _CONN_DIR) ||
        return nothing
    return parts
end

# ---- durable records ---------------------------------------------------------

# `(conn …)` accessors, without reducing anything: the fields are inert.
_conn_field(f::Form, key::Symbol) =
    (f isa FormContainer && haskey(f.map, key)) ? to_form(f.map[key]) : nothing

function _conn_field_symbol(f::Form, key::Symbol)
    x = _conn_field(f, key)
    x === nothing && return nothing
    s = _symbolof(x)
    s === nothing && return nothing
    return Symbol(lstrip(String(s), ':'))
end

_conn_record_id(f::Form) = _conn_field_symbol(f, Symbol(":id"))

# The records in a mutable's value: a sequence of `(conn …)` forms (`()` when
# there are none).
function _conn_records(v::Form)
    v isa FormContainer || return Form[]
    # A comprehension over a `Union` alias narrows to the concrete type, so the
    # vector is filled explicitly to keep it a `Vector{Form}`.
    out = Form[]
    for x in v.seq
        push!(out, to_form(x))
    end
    return out
end

_conn_records_form(recs::AbstractVector{<:Form}) =
    FormContainer(FormSeq(FormValue[_store_form(x) for x in recs]), FormMap())

# The mutable holding a connection endpoint's records, or `nothing`.
function _conn_state(env::Env, path::Vector{Symbol})
    ns = _ns_lookup(env, path[1:(end - 1)]; lazy = false)
    ns === nothing && return nothing
    e = _ns_named_entry(env, ns, path[end])
    e === nothing && return nothing
    b = _entry_body(e)
    b isa FormContainer || return nothing
    length(b.seq) == 3 || return nothing
    v = to_form(b.seq[3])
    return v isa VolatileForm ? v : nothing
end

# Make every namespace on the path world-readable and world-executable, so that
# a record below it can be read by the user it names. Creating a namespace under
# `.io` gets air's ordinary owner-only policy, which is not what a connection
# wants — and the denial would come from traversing `.io`, not from the record.
function _conn_ns!(env::Env, path::Vector{Symbol})
    local ns
    for i in eachindex(path)
        ns = _ns_ensure!(env, path[1:i])
        acl = _meta_acl(ns.vf)
        if !get(get(acl, :read, Dict{Symbol,Bool}()), _ALL_USERS, false)
            tx() do
                _set_metadata!(ns.vf,
                               _metadata_like(ns.vf;
                                              acl = _world_read_exec_acl(_meta_owner(ns.vf))))
            end
            _flush_metadata!()
        end
    end
    return ns
end

# The ACL of a connection record's mutable.
_conn_acl(owner::Symbol) = Dict{Symbol,Dict{Symbol,Bool}}(
    :read => Dict(_ALL_USERS => true), :write => Dict(owner => true),
    :exec => Dict(_ALL_USERS => true))

# Fetch or create the endpoint mutable for `path`, owned by `owner`.
function _conn_state!(env::Env, path::Vector{Symbol}, owner::Symbol)
    vf = _conn_state(env, path)
    vf === nothing || return vf
    return _as_air(env) do
        parent = _conn_ns!(env, path[1:(end - 1)])
        db = _ns_db(env, path)
        acl = _conn_acl(owner)
        vf = tx() do
            VolatileForm(db, form(); metadata = _metadata_form(owner; acl = acl))
        end
        _ns_add_val!(env, parent, Form(path[end]), vf; owner = owner)
        vf
    end
end

# ---- the record form ---------------------------------------------------------

function _conn_form(h::_ConnHandle)
    return _ns_form(Form[Form(_CONN_HEAD)], Pair{Symbol,Form}[
        Symbol(":id") => _keyword_form(h.id),
        Symbol(":kind") => _keyword_form(h.kind),
        Symbol(":user") => _keyword_form(h.user),
        Symbol(":principal") => _keyword_form(h.user),
        Symbol(":since") => _mk_time(h.since),
        Symbol(":tty") => Form(h.tty),
        Symbol(":cols") => Form(h.cols),
        Symbol(":rows") => Form(h.rows),
        Symbol(":attached") => h.inst === nothing ? naught : _ui_key_form(h.inst.key),
        Symbol(":closed") => h.closed ? _mk_time(h.closed_at) : naught])
end

# Write the handle's record into its endpoint mutable, replacing an earlier
# record with the same id or appending. The system writes the record, so the
# write runs as air: a constituent may read their record but not edit it.
function _conn_persist!(env::Env, h::_ConnHandle)
    vf = _conn_state(env, h.path)
    vf === nothing && return nothing
    cur = _conn_form(h)
    recs = Form[]
    replaced = false
    for r in _conn_records(vf[])
        if !replaced && _conn_record_id(r) == h.id
            push!(recs, cur)
            replaced = true
        else
            push!(recs, r)
        end
    end
    replaced || push!(recs, cur)
    value = _conn_records_form(recs)
    _as_air(env) do
        _tx_boundary(env) do
            _ensure_hooks!(env, vf)
            _record_write!(env, vf)
            setindex!(vf, value)
            value
        end
    end
    return nothing
end

# ---- the registry ------------------------------------------------------------

function _conn_snapshot()
    return lock(_CONN_LOCK) do
        copy(_CONN_REGISTRY)
    end
end

# The connection the caller is on: the one whose byte source is this task's
# output, or — locally — the process terminal's.
function _conn_current(env::Env)
    out = _context(env).out
    me = _current_user(env)
    return lock(_CONN_LOCK) do
        if out !== nothing
            for h in _CONN_REGISTRY
                (h.closed || h.env !== env) && continue
                h.out === out && return h
            end
        end
        for h in _CONN_REGISTRY
            (h.closed || h.env !== env) && continue
            h.kind === :std && h.user === me && return h
        end
        for h in _CONN_REGISTRY
            (h.closed || h.env !== env) && continue
            h.kind === :local && h.user === me && return h
        end
        return nothing
    end
end

# The live connection at a path, preferring the caller's own session when one
# user has several. A closed one is returned too, so it can be described.
function _conn_at(env::Env, path::Vector{Symbol})
    out = _context(env).out
    me = _current_user(env)
    return lock(_CONN_LOCK) do
        if out !== nothing
            for h in _CONN_REGISTRY
                (h.closed || h.env !== env) && continue
                h.path == path && h.out === out && return h
            end
        end
        for h in _CONN_REGISTRY
            (h.closed || h.env !== env) && continue
            h.path == path && (me === _AIR || h.user === me) && return h
        end
        for h in _CONN_REGISTRY
            (h.env !== env) && continue
            h.path == path && return h
        end
        return nothing
    end
end

# The live connection that owns a record mutable (the form a path reduces to).
function _conn_for_state(env::Env, vf::VolatileForm)
    me = _current_user(env)
    return lock(_CONN_LOCK) do
        for h in _CONN_REGISTRY
            (h.closed || h.env !== env) && continue
            v = _conn_state(env, h.path)
            v !== nothing && v.id == vf.id && return h
        end
        return nothing
    end
end

# Resolve a connection argument: an address form, a dotted string, a connection
# id (a keyword/symbol), or a record mutable.
function _conn_arg(env::Env, scope::Scope, x::Form)
    path = _ns_address_path(env, x)
    if path !== nothing
        length(path) >= 3 && return _conn_at(env, path)
        return nothing
    end
    v = air_reduce(env, scope, x)
    if v isa VolatileForm
        return _conn_for_state(env, v)
    end
    l = _leafof(v)
    if l isa AbstractString
        p = _conn_parse_path(l)
        p === nothing && return nothing
        return _conn_at(env, p)
    elseif l isa Symbol
        s = String(l)
        startswith(s, ':') && (s = s[2:end])
        me = _current_user(env)
        return lock(_CONN_LOCK) do
            for h in _CONN_REGISTRY
                (h.closed || h.env !== env) && continue
                h.id === Symbol(s) && (me === _AIR || h.user === me) && return h
            end
            return nothing
        end
    end
    return nothing
end

# ---- opening and closing -----------------------------------------------------

# The next free id for a new endpoint record.
function _conn_pick_id(vf::VolatileForm, kind::Symbol)
    ids = Set{Symbol}()
    vf === nothing || for r in _conn_records(vf[])
        i = _conn_record_id(r)
        i === nothing || push!(ids, i)
    end
    kind === :std && !(:std in ids) && return :std
    i = 1
    while Symbol("s", i) in ids
        i += 1
    end
    return Symbol("s", i)
end

# Air's endpoints are named entries in `.io.conn.air`, one per connection, so the
# id is part of the path and must be chosen before the mutable is created.
function _conn_air_id(env::Env, kind::Symbol)
    if kind === :std && _conn_state(env, _conn_path(_AIR, :std)) === nothing
        return :std
    end
    i = 1
    while _conn_state(env, _conn_path(_AIR, Symbol("s", i))) !== nothing
        i += 1
    end
    return Symbol("s", i)
end

_conn_backend(::Symbol, out, tty::Bool, cols::Int, rows::Int) =
    out isa _SshChannelIO ? _SshBackend(out) :
    _LocalBackend(; tty = tty, cols = cols, rows = rows)

"""
    _conn_open!(env, kind, user; out=nothing, tty=false, cols=80, rows=24,
                backend=nothing) -> _ConnHandle

Register a live connection for `user` and record it under `.io.conn`. The caller
supplies the byte source (`out` for a channel backend) or an explicit `backend`.
"""
function _conn_open!(env::Env, kind::Symbol, user::Symbol;
                     out = nothing, tty::Bool = false, cols::Int = 80,
                     rows::Int = 24, backend::Union{Nothing,_TermBackend} = nothing)
    owner = _conn_owner(user)
    local path::Vector{Symbol}
    local id::Symbol
    if user === _AIR
        id = _conn_air_id(env, kind)
        path = _conn_path(user, id)
        _conn_state!(env, path, owner)
    else
        path = _conn_path(user)
        id = _conn_pick_id(_conn_state!(env, path, owner), kind)
    end
    h = _ConnHandle(env, path, id, user, kind, tty, cols, rows, _now_secs(), 0.0, out,
                    backend === nothing ?
                    _conn_backend(kind, out, tty, cols, rows) : backend,
                    nothing, nothing, false, ReentrantLock())
    lock(_CONN_LOCK) do
        push!(_CONN_REGISTRY, h)
    end
    _conn_persist!(env, h)
    return h
end

# End a connection: detach the widget, mark the record closed, and keep the
# handle so the record still describes it.
function _conn_close!(env::Env, h::_ConnHandle)
    h.closed && return nothing
    inst = h.inst
    if inst !== nothing
        inst.dismissed = true
        _ui_notify!(inst)
    end
    h.closed = true
    h.closed_at = _now_secs()
    if h.backend !== nothing
        try
            _tb_close!(h.backend)
        catch
        end
    end
    try
        _conn_persist!(env, h)
    catch
    end
    return nothing
end

# ---- attaching ---------------------------------------------------------------

# Attach `widget` (a `(ui …)` form or an instance key) to `h` and run its
# renderer until the widget is dismissed, aborted (Ctrl-C), or the instance is
# closed. A `(ui …)` form is instantiated for the attach and closed again when
# the renderer leaves; an instance key is attached as it stands and stays open.
function _conn_attach!(env::Env, scope::Scope, h::_ConnHandle, widget::Form)
    h.closed && throw(AirThrown(_error_object(
        Form(Symbol(":conn-closed")), _ns_path_form(h.path))))
    # One widget per connection: a second attach is a mistake, not a stack.
    h.inst !== nothing && throw(AirThrown(_error_object(
        Form(Symbol(":ui-attached")), _ns_path_form(h.path))))
    local inst::_UiInstance
    local temporary::Bool
    w = air_reduce(env, scope, widget)
    if w isa FormContainer && head_symbol(w) === UI_HEAD
        key = _ui_new_key()
        inst = _ui_instantiate(env, scope, key, w)
        lock(_UI_INSTANCES_LOCK) do
            _UI_INSTANCES[key] = inst
        end
        try
            _ui_assert_initial!(inst)
        catch
            lock(_UI_INSTANCES_LOCK) do
                get(_UI_INSTANCES, key, nothing) === inst &&
                    delete!(_UI_INSTANCES, key)
            end
            rethrow()
        end
        temporary = true
    else
        inst = _ui_lookup(env, w)
        temporary = false
    end
    h.inst = inst
    h.task = current_task()
    _conn_persist!(env, h)
    r = _TermRenderer(h.backend === nothing ?
                      _conn_backend(h.kind, h.out, h.tty, h.cols, h.rows) :
                      h.backend)
    try
        _ui_term_run!(r, inst)
    finally
        h.inst = nothing
        h.task = nothing
        try
            _conn_persist!(env, h)
        catch
        end
        temporary && _ui_close_key(env, _ui_key_form(inst.key))
    end
    return naught
end

# Stop a connection's renderer without closing anything: the instance and its
# mutables survive, and the connection returns to its plain REPL.
function _conn_detach!(h::_ConnHandle)
    lock(h.lock) do
        inst = h.inst
        inst === nothing && return nothing
        inst.dismissed = true
        _ui_notify!(inst)
    end
    return nothing
end

# ---- the air surface ---------------------------------------------------------

# The connection a builtin's optional argument names, or the caller's own.
function _conn_arg_or_current(env::Env, scope::Scope, args::Vector{Form},
                              name::AbstractString)
    length(args) <= 1 || throw(AirEvalError(
        "$name takes at most one connection"))
    h = isempty(args) ? nothing : _conn_arg(env, scope, args[1])
    h === nothing && (h = _conn_current(env))
    return h
end

"""
    (ui-attach! [conn] widget)

Attach `widget` to a connection and run it there until dismissed. With no `conn`,
the caller's own connection is used. `widget` is a `(ui …)` form (instantiated
for the attach and closed after) or a key naming an open instance (which stays
open).
"""
function _bi_ui_attach(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-attach!", ())
    n = length(call.seq)
    (2 <= n <= 3) ||
        throw(AirEvalError("ui-attach! takes a connection and a widget"))
    h = n == 3 ? _conn_arg(env, scope, to_form(call.seq[2])) : _conn_current(env)
    h === nothing && throw(AirThrown(_error_object(
        Form(Symbol(":no-connection")),
        Form("this session has no connection to attach to"))))
    return _conn_attach!(env, scope, h, to_form(call.seq[n]))
end
special!(Symbol("ui-attach!"), _bi_ui_attach)

"""
    (ui-detach! [conn])

Dismiss the widget attached to a connection (or to every connection the caller
owns). The widget's instance and its mutables survive.
"""
function _bi_ui_detach(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-detach!", ())
    length(call.seq) <= 2 ||
        throw(AirEvalError("ui-detach! takes at most one connection"))
    if length(call.seq) == 2
        h = _conn_arg(env, scope, to_form(call.seq[2]))
        h === nothing || _conn_detach!(h)
    else
        me = _current_user(env)
        for h in _conn_snapshot()
            h.env === env || continue
            (me === _AIR || h.user === me) && _conn_detach!(h)
        end
    end
    return naught
end
special!(Symbol("ui-detach!"), _bi_ui_detach)

# `(ui-attached [conn])` — the key of the instance attached to a connection.
function _bi_ui_attached(env::Env, scope::Scope, args::Vector{Form})
    h = _conn_arg_or_current(env, scope, args, "ui-attached")
    h === nothing && return naught
    inst = h.inst
    return inst === nothing ? naught : _ui_key_form(inst.key)
end
builtin!(Symbol("ui-attached"), _bi_ui_attached)

# `(ui-connection [conn])` — one connection's record, or `naught`.
function _bi_ui_connection(env::Env, scope::Scope, args::Vector{Form})
    h = _conn_arg_or_current(env, scope, args, "ui-connection")
    h === nothing && return naught
    return _conn_form(h)
end
builtin!(Symbol("ui-connection"), _bi_ui_connection)

# `(ui-connections [user])` — the caller's live connections (air sees every
# user's), sorted by user and id.
function _bi_ui_connections(env::Env, scope::Scope, args::Vector{Form})
    length(args) <= 1 ||
        throw(AirEvalError("ui-connections takes at most one user"))
    me = _current_user(env)
    who = me
    if length(args) == 1
        v = air_reduce(env, scope, args[1])
        s = _symbolof(v)
        s === nothing && throw(AirEvalError(
            "ui-connections: user must be a keyword or symbol"))
        who = Symbol(lstrip(String(s), ':'))
        (me === _AIR || who === me || _is_admin(env, me)) ||
            throw(AirPermissionDenied(:read, _keyword_form(who)))
    end
    hs = [h for h in _conn_snapshot()
          if h.env === env && !h.closed && (who === _AIR ? true : h.user === who)]
    sort!(hs; by = h -> (String(h.user), String(h.id)))
    isempty(hs) && return naught
    return _conn_records_form(Form[_conn_form(h) for h in hs])
end
builtin!(Symbol("ui-connections"), _bi_ui_connections)
