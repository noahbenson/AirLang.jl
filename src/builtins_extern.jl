################################################################################
# builtins_extern.jl
#
# The air surface for extern objects: `(extern :type payload)` reconstructs one
# from the payload its printed form carries, `extern?`/`extern-type` inspect one,
# and `promise`/`deliver`/`task`/`await` are the concurrency primitives.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# `(extern :type payload)` — rebuild the extern registered under `:type` from
# `payload`, so a printed extern reads back as itself.
function _bi_extern(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 3 || throw(AirEvalError("extern needs a type and a payload"))
    tag = _symbolof(air_reduce(env, scope, to_form(call.seq[2])))
    (tag !== nothing && is_keyword(tag)) ||
        throw(AirEvalError("extern needs a keyword type (e.g. :promise)"))
    name = Symbol(String(tag)[2:end])
    payload = _native_of(air_reduce(env, scope, to_form(call.seq[3])))
    return _extern_form(_extern_from_payload(Val(name), payload))
end
special!(Symbol("extern"), _bi_extern)

builtin!(Symbol("extern?"),
         (env, scope, args) -> Form(_arg(args, 1, "extern?") isa FormExtern))

builtin!(Symbol("extern-type"), (env, scope, args) -> begin
    x = _arg(args, 1, "extern-type")
    x isa FormExtern || throw(AirEvalError("extern-type needs an extern"))
    return Form(Symbol(":" * String(_extern_type_name(x))))
end)

# `(promise)` — a new, undelivered promise, stored in the current namespace's
# database. A form that holds an undelivered promise stores a link to it; a
# delivered one stores its value inline.
builtin!(:promise, (env, scope, args) -> begin
    isempty(args) || throw(AirEvalError("promise takes no arguments"))
    return PromiseForm(_persist_db(env))
end)

# `(deliver p value)` — fill a promise. A database promise (the kind `task`
# returns) and an ephemeral promise extern are both accepted.
function _bi_deliver(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 3 || throw(AirEvalError("deliver needs a promise and a value"))
    p = air_reduce(env, scope, to_form(call.seq[2]))
    v = air_reduce(env, scope, to_form(call.seq[3]))
    if p isa PromiseForm
        _check_storable!(env, p.db, v)
        put!(p, v)
        return v
    end
    p isa FormExtern || throw(AirEvalError("deliver needs a promise"))
    obj = _extern_data(p)
    obj isa AirPromise || throw(AirEvalError("deliver needs a promise"))
    return _deliver!(obj, v)
end
special!(:deliver, _bi_deliver)

# ---- tasks -------------------------------------------------------------------

# A task's failure has no channel in the promise value, but the promise must
# still be delivered so an awaiter does not block forever. The delivered value is
# therefore the error *form*, and the original condition is recorded here; `await`
# rethrows it. The registry is process-local (a task-local one would be invisible
# to the awaiting task) and keyed by the promise's id.
const _TASK_ERRORS = Dict{Any,Any}()
const _TASK_ERRORS_LOCK = ReentrantLock()

function _record_task_error!(p::PromiseForm, e)
    lock(_TASK_ERRORS_LOCK)
    try
        _TASK_ERRORS[p.id] = e
    finally
        unlock(_TASK_ERRORS_LOCK)
    end
    return nothing
end

function _task_error(p::PromiseForm)
    lock(_TASK_ERRORS_LOCK)
    try
        return get(_TASK_ERRORS, p.id, nothing)
    finally
        unlock(_TASK_ERRORS_LOCK)
    end
end

# `(task form…; clean=false)` — hold the forms, evaluate them on another task,
# and return a database-backed promise immediately. Reading it with `await`
# blocks until the task has run and yields the value of the final form (or
# rethrows the task's error); `(get p)`/`(ready? p)` read it the same way. The
# forms capture the enclosing *lexical* scope by substitution, like a closure,
# and the task starts with the current thread's `val` bindings (`bind`)
# installed, so it sees the same thread-local values as the code that spawned
# it. The task's identity (`current-user`, current namespace, `@`, and `.env`) is
# always carried across so it remains the same user's work; with `clean=true`
# the `val` bindings are cleared instead of inherited.
#
# A task is a process item: its promise is stored immediately, but the task
# itself is not serialized, so a promise whose task never delivers (because the
# process died) is simply never delivered.
function _bi_task(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "task", (Symbol(":clean"),))
    body = Form[to_form(v) for v in _sx(call.seq, 2:length(call.seq))]
    isempty(body) && throw(AirEvalError("task needs a body"))
    clean = haskey(call.map, Symbol(":clean")) &&
            truthy(to_form(call.map[Symbol(":clean")]))
    captured = Form[_capture_form(scope, b) for b in body]
    # The task has no local scope, but it keeps the namespace layers active at
    # the point the task was created, so its free names still resolve against
    # the same namespace context.
    lscope = _scope_layers_only(scope)
    c = _context(env)
    ctx = TaskContext(c.user, c.ns, c.dbroot, clean ? naught : c.env)
    bindings = clean ? IdDict{Air.Var,Any}() : Air.vars()
    p = PromiseForm(_persist_db(env))
    Threads.@spawn begin
        _reset_block_scopes!()
        try
            r = _with_context(env, ctx, () -> Air.setvars(() -> begin
                r = naught
                for b in captured
                    r = air_reduce(env, lscope, b)
                end
                return r
            end, bindings))
            _check_storable!(env, p.db, r)
            put!(p, r)
        catch e
            e isa InterruptException && rethrow()
            # Block scopes do not cross a task boundary, so a signal should never
            # reach here; convert defensively rather than record a control
            # exception.
            if e isa AirThrowSignal
                e = AirThrown(_error_object(Form(Symbol(":uncaught-throw")),
                                            e.tag, e.value))
            end
            _record_task_error!(p, e)
            try
                put!(p, _error_form(e))
            catch
                # The database closed, or the result was already delivered and
                # its write failed: the promise is lost, as documented.
            end
        end
    end
    return p
end
special!(:task, _bi_task)

# `future` was renamed: it now returns a database promise (so it can be stored
# and awaited from any environment over the same database) and is called `task`.
special!(:future, (env, scope, call) ->
    throw(AirEvalError("future has been renamed task; write (task …)")))

# `(await x)` — block until a promise is ready, and return its value. A failed
# task's promise rethrows the task's original error. As with `get`, reading an
# undelivered promise inside a transaction raises instead of waiting.
builtin!(:await, (env, scope, args) -> begin
    x = _arg(args, 1, "await")
    if x isa PromiseForm
        v = canonicalize(x[])
        e = _task_error(x)
        e === nothing || throw(e)
        return v
    end
    x isa FormExtern || throw(AirEvalError("await needs a promise"))
    obj = _extern_data(x)
    obj isa AirPromise && return _await_promise(obj)
    obj isa AirFuture && return _await_future(obj)
    throw(AirEvalError("await needs a promise"))
end)

# ---- actors, promises, and delays as air values -------------------------------

# `(delay body…)` — a lazy value. The forms are captured like a task's (free
# lexical names substituted, active namespace layers and `val` bindings saved)
# and stored as a tagged thunk in a database cell; the first `get` evaluates the
# body and replaces the thunk with the result, which is then durable. The delay
# itself is immutable and serializes as the cell's link.
function _bi_delay(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "delay", ())
    body = Form[to_form(v) for v in _sx(call.seq, 2:length(call.seq))]
    isempty(body) && throw(AirEvalError("delay needs a body"))
    captured = Form[_capture_form(scope, b) for b in body]
    db = _persist_db(env)
    me = _current_user(env)
    _check_db_principal!(env, db, me)
    c = _context(env)
    nspath = c.ns isa Namespace ? copy(c.ns.path) : Symbol[]
    thunk = _air_delay_thunk(env, scope, nspath, _context_db_path(env), captured)
    cell = _tx_boundary(env) do
        _check_storable!(env, db, thunk)
        VolatileForm(db, thunk; metadata = _metadata_form(me; acl = _perms_acl(me)),
                     history = false)
    end
    return DelayForm(_AIR_DELAY_TYPE, cell)
end
special!(:delay, _bi_delay)

# `(actor value history=true)` — a sequential worker whose every value is
# persisted in the current namespace's database.
function _bi_actor(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "actor", (Symbol(":history"),))
    length(call.seq) <= 2 || throw(AirEvalError("actor takes at most one value"))
    body = length(call.seq) == 2 ?
        air_reduce(env, scope, to_form(call.seq[2])) : form()
    history = !haskey(call.map, Symbol(":history")) ||
              truthy(to_form(call.map[Symbol(":history")]))
    db = _persist_db(env)
    me = _current_user(env)
    _check_db_principal!(env, db, me)
    return _tx_boundary(env) do
        _check_storable!(env, db, body)
        ActorForm(db, body; history = history)
    end
end
special!(:actor, _bi_actor)

# A function value to apply on an actor's task. The task keeps the namespace
# layers and `val` bindings active where the send was made, so a rule name and a
# `val` still resolve. `fn` has already been captured (see `_bi_send`).
function _actor_step(env::Env, scope::Scope, fn::Form)
    lscope = _scope_layers_only(scope)
    c = _context(env)
    bindings = Air.vars()
    return v -> _with_context(env, c,
        () -> Air.setvars(() -> _call(env, lscope, fn, Form[v]), bindings))
end

# `(send actor fn)` — send the function `fn` to the actor (inside a transaction,
# the send happens on commit). `fn` receives the actor's current value and
# returns the new one.
function _bi_send(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "send", ())
    length(call.seq) == 3 || throw(AirEvalError("send needs an actor and a function"))
    af = air_reduce(env, scope, to_form(call.seq[2]))
    af isa ActorForm || throw(AirEvalError("send needs an actor"))
    fn = _capture_form(scope, air_reduce(env, scope, to_form(call.seq[3])))
    _check_storable!(env, af.db, fn)
    f = _actor_step(env, scope, fn)
    Air.send(v -> begin
                  r = f(v)
                  _check_storable!(env, af.db, r)
                  r
              end, af)
    return af
end
special!(:send, _bi_send)

# `(reset! actor value)` — replace the actor's value without a function.
function _bi_reset(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "reset!", ())
    length(call.seq) == 3 || throw(AirEvalError("reset! needs an actor and a value"))
    af = air_reduce(env, scope, to_form(call.seq[2]))
    af isa ActorForm || throw(AirEvalError("reset! expects an actor"))
    v = air_reduce(env, scope, to_form(call.seq[3]))
    _check_storable!(env, af.db, v)
    Air.send(_ -> v, af)
    return af
end
special!(Symbol("reset!"), _bi_reset)

builtin!(Symbol("actor?"), (env, scope, args) -> Form(_arg(args, 1, "actor?") isa ActorForm))
builtin!(Symbol("promise?"), (env, scope, args) -> Form(_arg(args, 1, "promise?") isa PromiseForm))
builtin!(Symbol("delay?"), (env, scope, args) -> Form(_arg(args, 1, "delay?") isa DelayForm))

# `(ready? x)` — whether a promise has been delivered or a delay already forced.
builtin!(Symbol("ready?"), (env, scope, args) -> begin
    x = _arg(args, 1, "ready?")
    x isa PromiseForm && return Form(isready(x))
    x isa DelayForm && return Form(isready(x))
    x isa ActorForm && return Form(true)
    throw(AirEvalError("ready? needs a promise, delay, or actor"))
end)
