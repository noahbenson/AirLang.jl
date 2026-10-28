################################################################################
# builtins_hold.jl
#
# Held forms. A held form is a container whose first element is the symbol `'` —
# `(' a b c k=v)` — whose content is everything after the head; `'x` is reader
# sugar for `(' x)` when `x` is a scalar. A held form evaluates to itself except
# that `preval` holes (written `~e`) are filled in eagerly. `(hold e…)` is a
# reserved alias that reduces to `(' e…)`. `(unhold x)` removes the hold and
# evaluates. `lower` pushes holds down toward the leaves; `lift` is its inverse.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# `(preval x)` — the eager hole written `~x`. It evaluates `x` wherever it
# appears; inside a held form the hold's expansion fills it in.
function _bi_preval(env::Env, scope::Scope, call::FormContainer)
    (length(call.seq) == 2 && isempty(call.map)) ||
        throw(AirEvalError("preval takes one operand"))
    return air_reduce(env, scope, to_form(call.seq[2]))
end
special!(PREVAL, _bi_preval)

# `(hold e1 … en k=v…)` — the reserved alias for the hold head: it holds its
# arguments exactly as written, so the result is the canonical `(' e1 … en
# k=v…)`. Arguments are not evaluated (a `preval` hole is filled in when the
# resulting hold is reduced).
function _bi_hold_alias(env::Env, scope::Scope, call::FormContainer)
    return canonicalize(_hold_form(_sx(call.seq, 2:length(call.seq)), call.map))
end
special!(HOLD_ALIAS, _bi_hold_alias)

# `(unhold x)` — remove one hold and evaluate what it held. A bound symbol is
# resolved first, so `(unhold a)` evaluates the value bound to `a` (e.g. a held
# parameter); an operand that is not itself a hold is evaluated first (so
# `(unhold (hold a b c))` works through the alias), and the hold it produces is
# unheld. A form that evaluates to something unheld is returned as evaluated.
function _bi_unhold(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("unhold needs an operand"))
    x = to_form(call.seq[2])
    if x isa FormScalar && (s = value(x)) isa Symbol && is_raw_symbol(s)
        b = scope_get(scope, s)
        b === nothing || (x = to_form(b.value))
    end
    _is_hold(x) || (x = air_reduce(env, scope, x))
    return _is_hold(x) ? air_reduce(env, scope, _hold_content(x)) : x
end
# Overridable: a user rule anchored on `unhold` (for example an air-level
# `(def (unhold (hold ??args)) (args...))`) takes precedence; the builtin is the
# fallback for any other operand.
special!(:unhold, _bi_unhold; overridable = true)

# Lower all the way to the leaves: hold every leaf, descend through containers.
function _lower_all(form::Form)
    f = _is_hold(form) ? _hold_content(form) : form
    if f isa FormContainer
        seq = FormValue[_store_form(_lower_all(to_form(v))) for v in f.seq]
        map = Pair{Symbol,FormValue}[k => _store_form(_lower_all(to_form(v))) for (k, v) in f.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    else
        return _holdify(f)
    end
end

# Lower a held form from level 0 to level `n` (root = 0).
function _lower_to(form::Form, n::Integer, depth::Int)
    if depth == n
        return _is_hold(form) ? form : _holdify(form)
    end
    f = _is_hold(form) ? _hold_content(form) : form
    if f isa FormContainer
        seq = FormValue[_store_form(_lower_to(to_form(v), n, depth + 1)) for v in f.seq]
        map = Pair{Symbol,FormValue}[k => _store_form(_lower_to(to_form(v), n, depth + 1))
                                     for (k, v) in f.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    else
        return f
    end
end

# `(lower form)` / `(lower form n)` — a structural, non-evaluating rewrite.
builtin!(:lower, (env, scope, args) -> begin
    form = _arg(args, 1, "lower")
    n = length(args) >= 2 ? _leafof(args[2]) : 1
    n isa Integer || throw(AirEvalError("lower needs an integer level"))
    _is_hold(form) || return form
    n == 0 && return form
    return n == -1 ? _lower_all(form) : _lower_to(form, n, 0)
end)

# Raise holds to the root: the inverse of `(lower form -1)`. A held leaf is a
# literal (`'a` → the symbol `a` in the result); an unheld element is already a
# value. The result is a single held form, so `(lift (' 'a x 'b))` is
# `(' a <value-of-x> b)`.
function _raise_all(form::Form)
    f = _is_hold(form) ? _hold_content(form) : form
    if f isa FormContainer
        seq = FormValue[_store_form(_raise_all(to_form(v))) for v in f.seq]
        map = Pair{Symbol,FormValue}[k => _store_form(_raise_all(to_form(v)))
                                     for (k, v) in f.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    else
        return f
    end
end

# `(lift form)` — build a held form explicitly: literal leaves are quoted
# (`'a`), evaluated elements are written plainly. Contrast `lower`. (This is the
# hold-lifting operation; `raise` is the error special form.)
builtin!(:lift, (env, scope, args) -> begin
    length(args) == 1 || throw(AirEvalError("lift takes one argument"))
    return _holdify(canonicalize(_raise_all(args[1])))
end)

# `(held? x)` — whether `x` is a held form. `(held? form k…)` — whether the
# subpart at that path is itself held, i.e. whether `(get form k…)` would return
# a held form. The path indexes the form exactly as `get` does, so for a quoted
# form the first index is 2 (index 1 is the `'` head). A hold is not
# inherited: index 2 of `(' f (1 + 2))` is not held even though the outer form is.
function _held_call(env::Env, scope::Scope, call::FormContainer, is_hold_fn::Bool)
    strip = haskey(call.map, HOLD_KEY) ? _hold_opt(call) : is_hold_fn
    args = _call_args(env, scope, call)
    isempty(args) && throw(AirEvalError("held? needs a form"))
    x = strip ? _strip_hold(args[1]) : args[1]
    for i in 2:length(args)
        if x isa FormScalar
            # A scalar is its own sole element, as for `get`: `0`, `1`, and
            # `-1` name it (and a scalar is never held); anything else raises.
            k = _get_key(args[i])
            k isa Integer ||
                throw(AirEvalError("held?: $(air_string(x)) has no key $(air_string(args[i]))"))
            _index_of(k, _leafof(x) === nothing ? 0 : 1)
            continue
        end
        x isa FormContainer ||
            throw(AirEvalError("held?: $(air_string(x)) has no key $(air_string(args[i]))"))
        k = _get_key(args[i])
        if k isa Integer
            j = _index_of(k, length(x.seq))
            j === nothing || (x = canonicalize(to_form(x.seq[j])))
        elseif k isa Symbol && haskey(x, k)
            x = canonicalize(to_form(x[k]))
        else
            throw(AirEvalError("key $(air_string(args[i])) not found in $(air_string(x))"))
        end
    end
    return _bool(_is_hold(x))
end
_hold_pair!(Symbol("held?"), _held_call)
