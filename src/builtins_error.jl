################################################################################
# builtins_error.jl
#
# The error system. `(error …)` is an inert error object (the reducer never
# evaluates its head or elements); `(raise …)` constructs one from evaluated
# arguments and throws it.
# `(do body… (except pattern body…)… (finally body…))` matches the *content* of
# an error object, resumes the original with the reserved symbol `reraise`, and
# runs `finally` on every path. Any non-air (AirLang or Julia) error surfaces to
# an `except` as `(error :internal …)`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- constructing error objects ---------------------------------------------

# `(error head args…)` with the given map entries. The arguments are stored as
# they are; the reducer keeps an error object unchanged.
function _error_object(args, map)
    seq = FormValue[Form(ERROR_HEAD)]
    for a in args
        push!(seq, _store_form(a))
    end
    mp = Pair{Symbol,FormValue}[k => _store_form(v) for (k, v) in map]
    return FormContainer(FormSeq(seq), FormMap(mp))
end

_error_object(args::Form...) = _error_object(Form[args...], Pair{Symbol,Form}[])

# ---- raise -------------------------------------------------------------------

# The task-local stack of errors currently being handled: an `except` body (and a
# `finally` with an error in flight) runs with its error on top, so a `raise`
# inside it records the context automatically.
const _HANDLING_KEY = :AirLangHandling

function _current_handling()
    st = get(task_local_storage(), _HANDLING_KEY, nothing)
    (st isa Vector{Form} && !isempty(st)) || return nothing
    return st[end]
end

function _with_handling(f::Function, errform::Form)
    d = task_local_storage()
    st = get(d, _HANDLING_KEY, nothing)
    if !(st isa Vector{Form})
        st = Form[]
        task_local_storage(_HANDLING_KEY, st)
    end
    push!(st, errform)
    try
        return f()
    finally
        pop!(st)
    end
end

const _FROM_KEY = Symbol(":from")
const _CAUSE_KEY = Symbol(":cause")

# `(raise a b… options…)` — evaluate every positional argument and map value,
# then throw `(error A B…)`. A single positional argument with no options that
# already evaluates to an error object is thrown exactly as it is. An explicit
# `from=` (any value, `naught` included) overrides or suppresses the automatic
# chain to the error being handled; `cause=` is explicit only.
function _bi_raise(env::Env, scope::Scope, call::FormContainer)
    args = Form[air_reduce(env, scope, to_form(x))
                for x in _sx(call.seq, 2:length(call.seq))]
    map = Pair{Symbol,Form}[]
    for (k, v) in call.map
        push!(map, k => air_reduce(env, scope, to_form(v)))
    end
    if length(args) == 1 && isempty(map)
        _is_error_object(args[1]) && throw(AirThrown(args[1]))
    end
    # `from=naught` and `cause=naught` mean "no link"; an explicit `from=` also
    # suppresses the automatic context.
    hadfrom = false
    kept = Pair{Symbol,Form}[]
    for (k, v) in map
        if k === _FROM_KEY
            hadfrom = true
            isequal(v, naught) || push!(kept, k => v)
        elseif k === _CAUSE_KEY
            isequal(v, naught) || push!(kept, k => v)
        else
            push!(kept, k => v)
        end
    end
    if !hadfrom
        handled = _current_handling()
        handled === nothing || push!(kept, _FROM_KEY => handled)
    end
    throw(AirThrown(_error_object(args, kept)))
end
special!(:raise, _bi_raise)

# ---- trace -------------------------------------------------------------------

# `(trace body…)` — evaluate the body and yield its value. If an error escapes,
# yield the data form `(:trace (error …) frames=(…))` instead of throwing: the
# first element is the error object an `except` would match, and `frames` lists
# the source frames known for it, innermost first. The result is final, so
# neither the object nor the frames are re-reduced.
function _bi_trace(env::Env, scope::Scope, call::FormContainer)
    result = naught
    try
        for i in 2:length(call.seq)
            result = air_reduce(env, scope, to_form(call.seq[i]))
        end
        return result
    catch e
        _is_control_exception(e) && rethrow()
        errform = e isa AirThrown ? e.form : _error_form(e)
        frames = _error_frames(e)
        if isempty(frames)
            info = _form_source_info(call)
            info === nothing || (frames = Form[info])
        end
        return _Final(_ns_form(Form[Form(Symbol(":trace")), errform],
                               Pair{Symbol,Form}[Symbol(":frames") =>
                                                 _ns_form(frames)]))
    end
end
special!(:trace, _bi_trace)

# ---- internal errors ---------------------------------------------------------

# A non-air exception becomes an air error object. An extern whose data could not
# be recovered (a promise stored before it was delivered, say) is
# `:extern-expired`; an AirDB extern error is `:extern-error`; anything else is
# `(:internal <message>)`.
function _error_form(e)
    e isa AirThrowSignal && throw(e)
    e isa AirTraced && return _error_form(e.err)
    e isa AirThrown && return e.form
    e isa ExternExpiredError &&
        return _error_object(Form(Symbol(":extern-expired")),
                             Form(Symbol(":" * String(e.name))))
    e isa ExternError &&
        return _error_object(Form(Symbol(":extern-error")), Form(e.msg))
    e isa FormNotFound &&
        return _error_object(Form(Symbol(":form-not-found")), Form(string(e.id)))
    e isa DatabaseError &&
        return _error_object(Form(Symbol(":database-error")),
                             Form(_error_message(e)))
    e isa AirPermissionDenied &&
        return _error_object(Form(Symbol(":permission-denied")),
                             Form(Symbol(":" * String(e.perm))), e.target)
    e isa AirProxyUnresolved &&
        return _error_object(Form(Symbol(":proxy-unresolved")),
                             _ns_path_form(e.path))
    e isa AirUnstorable &&
        return _error_object(Form(Symbol(":un-storable")), e.target)
    e isa AirStreamError &&
        return _error_object(Form[Form(Symbol(":" * String(e.tag))), e.data...],
                             Pair{Symbol,Form}[])
    return _internal_error_form(e)
end

_internal_error_form(e) =
    _error_object(Form(Symbol(":internal")), Form(_error_message(e)))

_error_message(e) = (e isa AirError && hasfield(typeof(e), :msg)) ? e.msg :
    sprint(showerror, e)
