################################################################################
# signals.jl
#
# `(signal …)` objects and the control exception used by `(throw …)`.
#
# A signal object is inert data, exactly like an error object: the reducer never
# evaluates its head or elements. It is the value `(notify …)` dispatches to the
# dynamically scoped `handle` clauses of a block.
#
# `AirThrowSignal` is control flow, not an error: it carries the identity of the
# catch scope that accepted the throw, plus the already-evaluated tag and value.
# It must pass through every error-catching layer unchanged; a block catches
# only the signals whose target is its own catch scope.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const SIGNAL_HEAD = :signal

# `(signal data… k=v…)`, built from already-evaluated values. Mirrors
# `_error_object` in builtins_error.jl.
function _signal_object(args, map)
    seq = FormValue[Form(SIGNAL_HEAD)]
    for a in args
        push!(seq, _store_form(a))
    end
    mp = Pair{Symbol,FormValue}[k => _store_form(v) for (k, v) in map]
    return FormContainer(FormSeq(seq), FormMap(mp))
end

_signal_object(args::Form...) =
    _signal_object(Form[args...], Pair{Symbol,Form}[])

function _is_signal_object(x)
    x isa FormContainer && !isempty(x.seq) || return false
    return _symbolof(to_form(x.seq[1])) === SIGNAL_HEAD
end

# The content of an object with a leading inert head (`error` or `signal`): its
# sequence without the head, keeping the map. Any other form is its own content.
function _object_content(x::Form)
    (_is_error_object(x) || _is_signal_object(x)) || return x
    seq = FormValue[x.seq[i] for i in 2:length(x.seq)]
    map = Pair{Symbol,FormValue}[k => v for (k, v) in x.map]
    return canonicalize(FormContainer(FormSeq(seq), FormMap(map)))
end

# A clause pattern matches the object's content, except a bare non-rest wildcard,
# which binds the whole object so a handler can inspect or re-raise it.
function _content_subject(pattern::Form, obj::Form)
    if pattern isa FormScalar
        s = value(pattern)
        (s isa Symbol && is_wildcard(s) && _rest_marker(s) === nothing) &&
            return obj
    end
    return _object_content(obj)
end

"""
    AirThrowSignal(target, tag, value)

A `(throw tag value)` that matched an active `catch=` scope. `target` is the
catch-scope object that accepted it (compared with `===`); `tag` and `value` are
the evaluated forms. This is control flow, not an [`AirError`](@ref): every
layer that handles air errors must let it pass through.
"""
struct AirThrowSignal <: Exception
    target::Any
    tag::Form
    value::Form
end

Base.showerror(io::IO, e::AirThrowSignal) =
    print(io, "air throw signal: ", air_string(e.tag), " ", air_string(e.value))
