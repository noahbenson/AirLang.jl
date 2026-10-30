################################################################################
# builtins_block.jl
#
# The `do`/`tx` block: `:let`/`let=` binding, scoped `catch=`/`throw`, `except`
# clauses, dynamically scoped `handle`/`signal`/`notify`, and `finally`.
#
# A block is
#
#     (do options… body… (except pattern body…)… (handle pattern body…)…
#         (finally body…))
#
# with the same grammar for `tx`; `tx` only differs in running the prepared
# block inside one transaction. `try` has no separate implementation.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- syntax ------------------------------------------------------------------

struct _Block
    body::Vector{Form}
    letraw::Union{Nothing,Form}
    catchraw::Union{Nothing,Form}
    excepts::Vector{Tuple{Form,Vector{Form}}}
    handles::Vector{Tuple{Form,Vector{Form}}}
    finally_body::Union{Nothing,Vector{Form}}
end

# Split a block call into its body, options, and trailing clauses. Clause bodies
# are kept raw; `:let` markers are expanded later, at preparation time.
function _parse_block(call::FormContainer, name::AbstractString)
    _check_options(call, name, (_LET_KEY, _CATCH_KEY))
    letraw = haskey(call.map, _LET_KEY) ? to_form(call.map[_LET_KEY]) : nothing
    catchraw = haskey(call.map, _CATCH_KEY) ? to_form(call.map[_CATCH_KEY]) : nothing
    elems = Form[to_form(v) for v in _sx(call.seq, 2:length(call.seq))]
    body = Form[]
    excepts = Tuple{Form,Vector{Form}}[]
    handles = Tuple{Form,Vector{Form}}[]
    fbody = nothing
    in_clauses = false
    i = 1
    while i <= length(elems)
        f = elems[i]
        h = head_symbol(f)
        h === Symbol("catch") && throw(AirEvalError(
            "$name: use catch=… for a throw tag and (except pattern body…) for errors"))
        if h === Symbol("except") || h === Symbol("handle")
            in_clauses = true
            (f isa FormContainer && length(f.seq) >= 2) ||
                throw(AirEvalError("a $(h) clause needs a pattern"))
            pat = to_form(f.seq[2])
            cbody = Form[to_form(v) for v in _sx(f.seq, 3:length(f.seq))]
            if h === Symbol("except")
                push!(excepts, (pat, cbody))
            else
                push!(handles, (pat, cbody))
            end
        elseif h === Symbol("finally")
            in_clauses = true
            fbody === nothing ||
                throw(AirEvalError("$name has more than one finally clause"))
            i == length(elems) ||
                throw(AirEvalError("$name: finally must be the last clause"))
            fbody = Form[to_form(v) for v in _sx(f.seq, 2:length(f.seq))]
        elseif in_clauses
            throw(AirEvalError(
                "$name: expected an except, handle, or finally clause, got $(air_string(f))"))
        else
            push!(body, f)
        end
        i += 1
    end
    return _Block(body, letraw, catchraw, excepts, handles, fbody)
end

# A `let=` binding form evaluated once at block entry, producing one extended
# scope. Unlike `let` this is a real lexical scope: it is visible in the body,
# clause patterns/conditions, clause bodies, and `finally`. Groups feed one
# another, as in `let`; a rebound name keeps its last value in a single level.
function _let_scope(env::Env, scope::Scope, raw::Form, name::AbstractString)
    if raw isa FormContainer && !isempty(raw.seq) &&
       any(k -> k in _LET_OPTION_KEYS, keys(raw.map))
        throw(AirEvalError(
            "$name: hold= and bind= belong to let; let= binds every name"))
    end
    groups = isequal(raw, naught) ? FormContainer[] : _let_groups(raw)
    groups === nothing && throw(AirEvalError(
        "$name: let= bindings must be one key=value mapping or a sequence of them"))
    subst = Dict{Symbol,Form}()
    history = Pair{Symbol,Form}[]
    for g in groups
        fresh = Pair{Symbol,Form}[]
        for (k, v) in g.map
            nm = _bindname(k)
            _check_not_reserved(nm, AirEvalError, "bound")
            rawv = isempty(subst) ? to_form(v) : _subst_params(to_form(v), subst)
            push!(fresh, nm => air_reduce(env, scope, rawv))
        end
        for (nm, val) in fresh
            subst[nm] = val
            push!(history, nm => val)
        end
    end
    isempty(history) && return scope
    order = Symbol[]
    lastval = Dict{Symbol,Form}()
    for (nm, val) in history
        haskey(lastval, nm) || push!(order, nm)
        lastval[nm] = val
    end
    return scope_extend(scope, [nm => lastval[nm] for nm in order])
end

# ---- catch tags --------------------------------------------------------------

mutable struct _CatchScope
    tags::Vector{Form}
end

# One `catch=` tag: a held scalar literal, or `~expr` reduced to a scalar.
function _literal_tag(env::Env, scope::Scope, x::Form, name::AbstractString)
    if x isa FormScalar
        return x
    elseif x isa FormContainer && head_symbol(x) === PREVAL &&
           length(x.seq) == 2 && isempty(x.map)
        v = air_reduce(env, scope, to_form(x.seq[2]))
        v isa FormScalar || throw(AirEvalError(
            "$name: a computed catch tag must be a scalar, got $(air_string(v))"))
        return v
    end
    throw(AirEvalError(
        "$name: a catch tag must be a literal or a ~expression, got $(air_string(x))"))
end

# The tags of a `catch=` option: one literal/`~` tag, or a form whose sequence is
# a list of them. A catch with no tag, or with any map entries, is an error.
function _catch_tags(env::Env, scope::Scope, raw::Form, name::AbstractString)
    isequal(raw, naught) &&
        throw(AirEvalError("$name: catch= needs at least one tag"))
    if raw isa FormScalar
        return Form[_literal_tag(env, scope, raw, name)]
    end
    if raw isa FormContainer && head_symbol(raw) === PREVAL &&
       length(raw.seq) == 2 && isempty(raw.map)
        return Form[_literal_tag(env, scope, raw, name)]
    end
    raw isa FormContainer || throw(AirEvalError(
        "$name: catch= needs a literal or a sequence of literals"))
    isempty(raw.map) || throw(AirEvalError(
        "$name: catch= may not have map entries"))
    isempty(raw.seq) &&
        throw(AirEvalError("$name: catch= needs at least one tag"))
    return Form[_literal_tag(env, scope, to_form(v), name) for v in raw.seq]
end

const _CATCH_SCOPES_KEY = :AirLangCatchScopes

function _catch_scopes()
    d = task_local_storage()
    s = get(d, _CATCH_SCOPES_KEY, nothing)
    if !(s isa Vector{_CatchScope})
        s = _CatchScope[]
        task_local_storage(_CATCH_SCOPES_KEY, s)
    end
    return s::Vector{_CatchScope}
end

_tags_match(tags::Vector{Form}, tag::Form) = any(t -> isequal(t, tag), tags)

# The innermost active catch scope that accepts `tag`, or `nothing`.
function _catch_target(tag::Form)
    s = _catch_scopes()
    for i in length(s):-1:1
        _tags_match(s[i].tags, tag) && return s[i]
    end
    return nothing
end

# ---- handlers ----------------------------------------------------------------

struct _HandlerEntry
    pattern::Form
    body::Vector{Form}
    scope::Scope
end

struct _HandlerScope
    entries::Vector{_HandlerEntry}
end

const _HANDLER_SCOPES_KEY = :AirLangHandlerScopes

function _handler_scopes()
    d = task_local_storage()
    s = get(d, _HANDLER_SCOPES_KEY, nothing)
    if !(s isa Vector{_HandlerScope})
        s = _HandlerScope[]
        task_local_storage(_HANDLER_SCOPES_KEY, s)
    end
    return s::Vector{_HandlerScope}
end

# A spawned task starts with no active block control scopes, even if its task
# local storage was inherited rather than freshly created.
function _reset_block_scopes!()
    d = task_local_storage()
    d[_CATCH_SCOPES_KEY] = _CatchScope[]
    d[_HANDLER_SCOPES_KEY] = _HandlerScope[]
    return nothing
end

# ---- preparation -------------------------------------------------------------

struct _PreparedBlock
    block::_Block
    scope::Scope
    catch_scope::Union{Nothing,_CatchScope}
    handlers::_HandlerScope
end

function _prepare_block(env::Env, scope::Scope, block::_Block,
                        name::AbstractString)
    body = _rewrite_body_lets(block.body)
    b = _Block(body, block.letraw, block.catchraw, block.excepts, block.handles,
               block.finally_body)
    pscope = b.letraw === nothing ? scope : _let_scope(env, scope, b.letraw, name)
    cscope = b.catchraw === nothing ? nothing :
             _CatchScope(_catch_tags(env, pscope, b.catchraw, name))
    entries = _HandlerEntry[_HandlerEntry(pat, cbody, pscope)
                            for (pat, cbody) in b.handles]
    return _PreparedBlock(b, pscope, cscope, _HandlerScope(entries))
end

# ---- running a block ---------------------------------------------------------

# The exceptions that carry control flow rather than a diagnosable error: an
# interrupt, a `throw`, a `recur`, and an `exit`. They pass through every block
# unchanged.
_is_control_exception(e) =
    e isa InterruptException || e isa AirThrowSignal || e isa _Recur ||
    e isa ExitSignal

# Apply the except clauses to an escaping error. The first matching clause runs
# under the handling context; a final `reraise` continues with the next clause
# (or rethrows the original). Control exceptions are never matched here. Any
# other exception — an `AirError` or a Julia exception such as AirDB's
# `FormNotFound` — is seen by the patterns as the error object `_error_form`
# builds, and is rethrown unchanged when no clause matches.
function _body_and_excepts(env::Env, prep::_PreparedBlock)
    block = prep.block
    try
        result = naught
        for a in block.body
            result = air_reduce(env, prep.scope, a)
        end
        return result
    catch e
        _is_control_exception(e) && rethrow()
        errform = e isa AirThrown ? e.form : _error_form(e)
        for (pat, cbody) in block.excepts
            binds = air_match(env, prep.scope, pat,
                              _content_subject(pat, errform),
                              Dict{Symbol,Form}())
            binds === nothing && continue
            inner = scope_extend(prep.scope, [n => v for (n, v) in binds])
            r = _with_handling(errform) do
                v = naught
                for a in cbody
                    v = air_reduce(env, inner, a)
                end
                v
            end
            _is_reraise(r) && continue
            return r
        end
        rethrow()
    end
end

# Run the finally body. Handlers are still active; the catch scope and except
# clauses are already closed. With an air error in flight it runs under that
# error's handling context, so a raise in `finally` records it as `from=`.
function _run_finally(env::Env, prep::_PreparedBlock, pending)
    fbody = prep.block.finally_body
    fbody === nothing && return nothing
    if pending !== nothing && !_is_control_exception(pending)
        ef = pending isa AirThrown ? pending.form : _error_form(pending)
        _with_handling(ef) do
            for a in fbody
                air_reduce(env, prep.scope, a)
            end
        end
    else
        for a in fbody
            air_reduce(env, prep.scope, a)
        end
    end
    return nothing
end

# Evaluate a prepared block. The catch scope is active through the body and the
# except/handle bodies and is popped before `finally`; handler scopes are active
# through all of those, including `finally`. Any condition escaping `finally`
# replaces the result or the condition already in flight.
function _run_block(env::Env, prep::_PreparedBlock)
    cstack = prep.catch_scope === nothing ? nothing : _catch_scopes()
    hstack = isempty(prep.handlers.entries) ? nothing : _handler_scopes()
    cstack !== nothing && push!(cstack, prep.catch_scope)
    hstack !== nothing && push!(hstack, prep.handlers)
    result = naught
    pending = nothing
    try
        try
            result = _body_and_excepts(env, prep)
        catch e
            if e isa AirThrowSignal && prep.catch_scope !== nothing &&
               e.target === prep.catch_scope
                result = e.value
            else
                pending = e
            end
        end
        cstack !== nothing && pop!(cstack)
        cstack = nothing
        if prep.block.finally_body !== nothing
            try
                _run_finally(env, prep, pending)
            catch e
                pending = e
            end
        end
    finally
        cstack !== nothing && pop!(cstack)
        hstack !== nothing && pop!(hstack)
    end
    pending === nothing && return result
    throw(pending)
end

# ---- do ----------------------------------------------------------------------

function _do_eval(env::Env, scope::Scope, call::FormContainer,
                  name::AbstractString)
    block = _parse_block(call, name)
    prep = _prepare_block(env, scope, block, name)
    if prep.catch_scope === nothing && isempty(prep.block.excepts) &&
       isempty(prep.block.handles) && prep.block.finally_body === nothing
        body = prep.block.body
        isempty(body) && return naught
        for i in 1:(length(body) - 1)
            air_reduce(env, prep.scope, body[i])
        end
        return _Tail(body[end], prep.scope)
    end
    return _Final(_run_block(env, prep))
end

_bi_do(env::Env, scope::Scope, call::FormContainer) =
    _do_eval(env, scope, call, "do")
special!(:do, _bi_do)

# ---- throw -------------------------------------------------------------------

function _call_frames(call::FormContainer)
    info = _form_source_info(call)
    return info === nothing ? Form[] : Form[info]
end

function _thrown_error(errform::Form, call::FormContainer)
    frames = _call_frames(call)
    return isempty(frames) ? AirThrown(errform) : AirThrown(errform, frames)
end

# `(throw value)`, `(throw tag value)`, `(throw ~tag value)`, or `(throw)`.
# A tag is a held literal (or a computed scalar); the value is evaluated. The
# innermost active catch scope with the tag accepts it; otherwise the throw is
# immediately the ordinary error `(error :uncaught-throw tag value)`.
function _bi_throw(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "throw", ())
    n = length(call.seq)
    n <= 3 || throw(AirEvalError("throw takes at most a tag and a value"))
    if n == 1
        tag = Form(true)
        value = naught
    elseif n == 2
        tag = Form(true)
        value = air_reduce(env, scope, to_form(call.seq[2]))
    else
        tag = _literal_tag(env, scope, to_form(call.seq[2]), "throw")
        value = air_reduce(env, scope, to_form(call.seq[3]))
    end
    target = _catch_target(tag)
    if target !== nothing
        throw(AirThrowSignal(target, tag, value))
    end
    errform = _error_object(Form(Symbol(":uncaught-throw")), tag, value)
    throw(_thrown_error(errform, call))
end
special!(:throw, _bi_throw)

# ---- notify / notify-or ------------------------------------------------------

# The signal a notify call dispatches: an exact signal object when the call is
# one positional argument with no map entries, otherwise a newly built signal
# from the evaluated arguments and map.
function _notify_signal(args::Vector{Form}, map::Vector{Pair{Symbol,Form}})
    if length(args) == 1 && isempty(map) && _is_signal_object(args[1])
        return args[1]
    end
    return _signal_object(args, map)
end

function _find_handler(env::Env, sig::Form)
    scopes = _handler_scopes()
    for i in length(scopes):-1:1
        for entry in scopes[i].entries
            subject = _content_subject(entry.pattern, sig)
            binds = air_match(env, entry.scope, entry.pattern, subject,
                              Dict{Symbol,Form}())
            binds === nothing && continue
            return (entry, binds)
        end
    end
    return nothing
end

function _run_handler(env::Env, entry::_HandlerEntry, binds)
    inner = scope_extend(entry.scope, [n => v for (n, v) in binds])
    result = naught
    for a in entry.body
        result = air_reduce(env, inner, a)
    end
    return result
end

function _unhandled_signal(call::FormContainer, sig::Form)
    errform = _error_object(Form(Symbol(":unhandled-signal")), sig)
    throw(_thrown_error(errform, call))
end

function _bi_notify(env::Env, scope::Scope, call::FormContainer)
    args = Form[air_reduce(env, scope, to_form(v))
                for v in _sx(call.seq, 2:length(call.seq))]
    map = Pair{Symbol,Form}[]
    for (k, v) in call.map
        push!(map, k => air_reduce(env, scope, to_form(v)))
    end
    sig = _notify_signal(args, map)
    found = _find_handler(env, sig)
    found === nothing && _unhandled_signal(call, sig)
    entry, binds = found
    return _Final(_run_handler(env, entry, binds))
end
special!(:notify, _bi_notify)

function _bi_notify_or(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError(
        "notify-or needs a default value, as in (notify-or default data…)"))
    default = to_form(call.seq[2])
    args = Form[air_reduce(env, scope, to_form(v))
                for v in _sx(call.seq, 3:length(call.seq))]
    map = Pair{Symbol,Form}[]
    for (k, v) in call.map
        push!(map, k => air_reduce(env, scope, to_form(v)))
    end
    sig = _notify_signal(args, map)
    found = _find_handler(env, sig)
    if found === nothing
        return _Final(air_reduce(env, scope, default))
    end
    entry, binds = found
    return _Final(_run_handler(env, entry, binds))
end
special!(Symbol("notify-or"), _bi_notify_or)

# ---- try is gone -------------------------------------------------------------

special!(:try, (env, scope, call) -> throw(AirEvalError(
    "try is no longer supported; use (do ... (except ...))")))
