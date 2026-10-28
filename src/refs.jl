################################################################################
# refs.jl
#
# The database-backed reference forms: actors, promises, and delays. AirDB
# supplies the form types (`ActorForm`, `PromiseForm`, `DelayForm`) and their
# live behaviour; this file makes them usable from air.
#
# Two pieces of plumbing live here because they are needed before the builtin
# library is loaded:
#
#   * `_force_ref_form` — the accessor rule. `get`, `value`, and a get path treat
#     an actor, a promise, and a delay like a mutable: they vanish on the path,
#     so `(get p)` reads the promise and `(get d 0)` forces the delay.
#   * the `:air` delay loader. A `DelayForm`'s registered loader is a
#     process-global function of its serialization form alone, so it cannot
#     receive an `Env`. `_with_current_env` installs the evaluating environment
#     for the dynamic extent of a force, and the loader reads it back.
#
# An air delay's serialization form is a *database cell*: a `VolatileForm` whose
# value is initially a tagged thunk (the captured body and context) and, after
# the first force, the computed value. That is what makes the cache durable:
# reopening the database finds the value already in the cell and never runs the
# body again. The delay form itself is immutable and is written inline wherever
# it appears; only the cell it points at changes.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _AIR_DELAY_HEAD = Symbol("air-delay")
const _AIR_DELAY_TYPE = Symbol("air")
const _DELAY_STATE_KEY = Symbol(":state")
const _DELAY_PENDING = Symbol(":pending")
const _DELAY_NS_KEY = Symbol(":ns")
const _DELAY_DBROOT_KEY = Symbol(":dbroot")
const _DELAY_ENV_KEY = Symbol(":env")
const _DELAY_BINDINGS_KEY = Symbol(":bindings")
const _DELAY_LAYERS_KEY = Symbol(":layers")
const _DELAY_BODY_KEY = Symbol(":body")
const _DELAY_ONLY_KEY = Symbol(":only")
const _DELAY_EXCEPT_KEY = Symbol(":except")

# ---- the evaluating environment ---------------------------------------------

# The `Env` whose reduction is currently forcing a reference form. The delay
# loader is called through AirDB's `df[]`, which has no environment argument, so
# the forcing site installs it task-locally for exactly the dynamic extent of the
# call. A spawned task starts with no value; a force there installs its own.
const _CURRENT_ENV_KEY = :airlang_current_env

function _current_env()
    tls = task_local_storage()
    tls isa IdDict || return nothing
    e = get(tls, _CURRENT_ENV_KEY, nothing)
    return e isa Env ? e : nothing
end

function _with_current_env(f::Function, env::Env)
    return task_local_storage(_CURRENT_ENV_KEY, env) do
        f()
    end
end

# ---- forcing ----------------------------------------------------------------

# A delay whose body forces itself would re-enter Air's `Delay` (whose lock is
# reentrant) until the stack runs out. Track the delays being forced on this
# task so the cycle is a catchable air error instead.
const _FORCING_DELAYS_KEY = :airlang_forcing_delays

function _forcing_delays()
    tls = task_local_storage()
    tls isa IdDict || return nothing
    s = get(tls, _FORCING_DELAYS_KEY, nothing)
    s isa Set{UInt} && return s
    s = Set{UInt}()
    task_local_storage(_FORCING_DELAYS_KEY, s)
    return s
end

"""
    _force_ref_form(env, x) -> Form

Read the value behind a reference form: an actor's current value, a promise's
delivered value, or a delay's computed value. Any other form is returned
unchanged, so callers can use this as a transparent dereference on the get path.
"""
function _force_ref_form(env::Env, x::Form)
    if x isa DelayForm
        seen = _forcing_delays()
        key = objectid(x.delay)
        (seen !== nothing && key in seen) &&
            throw(AirEvalError("a delay cannot force itself"))
        seen === nothing || push!(seen, key)
        try
            return _with_current_env(env) do
                x[]
            end
        finally
            seen === nothing || delete!(seen, key)
        end
    elseif x isa ActorForm || x isa PromiseForm
        return x[]
    end
    return x
end

# ---- the air delay thunk ----------------------------------------------------

# The cell's initial value. Every field is plain data so the thunk itself is
# storable in the database that holds the cell.
function _air_delay_thunk(env::Env, scope::Scope, nspath::Vector{Symbol},
                          dbpath::Union{Nothing,Vector{Symbol}}, captured::Vector{Form})
    layers = Form[]
    if _scope_has_layers(scope)
        for layer in scope_layers(scope)
            push!(layers, _air_delay_layer(env, layer, nspath))
        end
    end
    map = Pair{Symbol,Form}[
        _DELAY_STATE_KEY => Form(_DELAY_PENDING),
        _DELAY_NS_KEY => _ns_path_form(nspath),
        _DELAY_ENV_KEY => _context(env).env,
        _DELAY_BINDINGS_KEY => _bindings_form(env),
        _DELAY_LAYERS_KEY => _ns_form(layers),
        _DELAY_BODY_KEY => _ns_form(captured)]
    dbpath === nothing || push!(map, _DELAY_DBROOT_KEY => _ns_path_form(dbpath))
    return _ns_form(Form[Form(_AIR_DELAY_HEAD)], map)
end

# One active rule layer, as a form the loader can rebuild. An unfiltered layer is
# a namespace's own store; a `using ... only=`/`except=` layer is a filtered copy
# of one, which the set of names it kept reproduces exactly.
function _air_delay_layer(env::Env, layer::RuleLayer, fallback::Vector{Symbol})
    layer isa RuleStore ||
        throw(AirEvalError("a delay cannot capture an unknown rule layer"))
    # An unfiltered layer is a namespace's own store; the cache tells us which.
    for (_, ns) in env.nscache
        ns.rules === layer &&
            return _ns_form(Form[], Pair{Symbol,Form}[_DELAY_NS_KEY => _ns_path_form(ns.path)])
    end
    # A `using … only=`/`except=` layer is a filtered copy of a namespace's own
    # store. Its rules share the source entries' volatiles, which identifies the
    # source; the names the layer kept reproduce the filter.
    src = nothing
    if !isempty(layer.rules)
        r0 = layer.rules[1]
        for (_, ns) in env.nscache
            any(rr -> rr.entry === r0.entry && isequal(rr.pattern, r0.pattern),
                ns.rules.rules) || continue
            src = ns
            break
        end
    end
    path = src === nothing ? fallback : src.path
    names = Symbol[]
    for r in layer.rules
        n = _def_name(r.pattern)
        (n === nothing || n in names) && continue
        push!(names, n)
    end
    return _ns_form(Form[], Pair{Symbol,Form}[
        _DELAY_NS_KEY => _ns_path_form(path),
        _DELAY_ONLY_KEY => _ns_form(Form[Form(n) for n in sort!(names)])])
end

_is_delay_pending_state(x::Form) =
    x isa FormContainer && head_symbol(x) === _AIR_DELAY_HEAD &&
    haskey(x, _DELAY_STATE_KEY) &&
    isequal(to_form(x[_DELAY_STATE_KEY]), Form(_DELAY_PENDING))

# The registered `:air` loader. `form` is the delay's cell.
function _air_delay_load(form::Form)
    env = _current_env()
    env === nothing &&
        throw(AirEvalError("an air delay can only be forced during air evaluation"))
    form isa VolatileForm ||
        throw(AirEvalError("an air delay's serialization is not a database cell"))
    cell = form
    _check!(env, cell, :read)
    state = cell[]
    _is_delay_pending_state(state) || return state
    v = _eval_air_delay(env, state::FormContainer)
    return _cache_delay_value!(env, cell, v)
end

# Rebuild the captured namespace context and evaluate the body in it. Identity is
# deliberately *not* restored: stored code runs as the user who forces it, as a
# stored `def` does.
function _eval_air_delay(env::Env, state::FormContainer)
    nspath = haskey(state, _DELAY_NS_KEY) ?
        _stored_path(to_form(state[_DELAY_NS_KEY])) : nothing
    nspath === nothing &&
        throw(AirEvalError("a delay's stored context is malformed"))
    ns = _ns_lookup(env, nspath)
    ns === nothing && throw(AirEvalError(
        "the namespace $(_ns_display(nspath)) of a delay is not available"))
    layers = RuleLayer[]
    if haskey(state, _DELAY_LAYERS_KEY)
        specs = to_form(state[_DELAY_LAYERS_KEY])
        if specs isa FormContainer
            for v in specs.seq
                push!(layers, _air_delay_layer_store(env, to_form(v)))
            end
        end
    end
    scope = Scope(nothing, Symbol[], Form[], layers, nothing)
    binds = IdDict{Var,Any}()
    if haskey(state, _DELAY_BINDINGS_KEY)
        bf = to_form(state[_DELAY_BINDINGS_KEY])
        if bf isa FormContainer
            for (k, v) in bf.map
                b = _find_val_binding(env, scope, _bindname(k))
                b === nothing && continue
                binds[b.var] = canonicalize(to_form(v))
            end
        end
    end
    c = _context(env)
    dbroot = c.dbroot
    if haskey(state, _DELAY_DBROOT_KEY)
        p = _stored_path(to_form(state[_DELAY_DBROOT_KEY]))
        if p !== nothing
            r = _ns_lookup(env, p)
            dbroot = r === nothing ? nothing : r.vf
        end
    end
    envform = haskey(state, _DELAY_ENV_KEY) ?
        to_form(state[_DELAY_ENV_KEY]) : naught
    ctx = TaskContext(c.user, ns, dbroot, envform)
    body = haskey(state, _DELAY_BODY_KEY) ? to_form(state[_DELAY_BODY_KEY]) : naught
    return _with_context(env, ctx, () -> Air.setvars(() -> begin
        r = naught
        body isa FormContainer || return r
        for b in body.seq
            r = air_reduce(env, scope, to_form(b))
        end
        return r
    end, binds))
end

# Rebuild one captured rule layer.
function _air_delay_layer_store(env::Env, spec::Form)
    spec isa FormContainer ||
        throw(AirEvalError("a delay's stored context is malformed"))
    haskey(spec, _DELAY_NS_KEY) ||
        throw(AirEvalError("a delay's stored context is malformed"))
    path = _stored_path(to_form(spec[_DELAY_NS_KEY]))
    path === nothing &&
        throw(AirEvalError("a delay's stored context is malformed"))
    ns = _ns_lookup(env, path)
    ns === nothing && throw(AirEvalError(
        "the namespace $(_ns_display(path)) of a delay is not available"))
    haskey(spec, _DELAY_ONLY_KEY) || haskey(spec, _DELAY_EXCEPT_KEY) ||
        return ns.rules
    only = haskey(spec, _DELAY_ONLY_KEY) ?
        _delay_name_set(to_form(spec[_DELAY_ONLY_KEY])) : nothing
    except = haskey(spec, _DELAY_EXCEPT_KEY) ?
        _delay_name_set(to_form(spec[_DELAY_EXCEPT_KEY])) : Set{Symbol}()
    return _filtered_store(ns, only, except)
end

function _delay_name_set(x::Form)
    s = Set{Symbol}()
    x isa FormContainer || return s
    for v in x.seq
        n = _symbolof(to_form(v))
        n === nothing || push!(s, n)
    end
    return s
end

# Save the computed value in the cell, so a later force (in this process or in a
# fresh one that reopens the same database) returns it without re-running the
# body. A value that the database cannot hold, or a user without write access,
# is simply not cached; the delay still yields its value.
function _cache_delay_value!(env::Env, cell::VolatileForm, v::Form)
    _can(env, cell, :write) || return v
    try
        _check_storable!(env, cell.db, v)
    catch e
        e isa AirUnstorable && return v
        rethrow()
    end
    return _tx_boundary(env) do
        setindex!(cell, v)
        v
    end
end
