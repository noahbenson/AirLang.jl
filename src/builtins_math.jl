################################################################################
# builtins_math.jl
#
# Prefix math functions and the numeric constants. Like the operators, a math
# function is symbolic: it computes when its arguments are numbers and otherwise
# returns the form unchanged.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

function _math1(name::Symbol, fn::Function, x::Form)::Form
    l = _leafof(x)
    l isa Number || return _mk_prefix(name, [x])
    return to_form(fn(l))
end

function _math2(name::Symbol, fn::Function, x::Form, y::Form)::Form
    lx, ly = _leafof(x), _leafof(y)
    (lx isa Number && ly isa Number) || return _mk_prefix(name, [x, y])
    return to_form(fn(lx, ly))
end

_math_builtin1(name::Symbol, fn::Function) =
    (env, scope, args) -> _math1(name, fn, _arg(args, 1, String(name)))
_math_builtin2(name::Symbol, fn::Function) =
    (env, scope, args) -> _math2(name, fn, _arg(args, 1, String(name)), _arg(args, 2, String(name)))

const _MATH1 = [
    (:abs, abs), (:sign, sign), (:floor, floor), (:ceil, ceil), (:round, round),
    (:truncate, truncate), (:sqrt, sqrt), (:exp, exp), (:log, log), (:log2, log2),
    (:log10, log10), (:sin, sin), (:cos, cos), (:tan, tan), (:asin, asin),
    (:acos, acos), (:atan, atan), (:factorial, factorial),
]
const _MATH2 = [(:atan2, atan), (:gcd, gcd), (:lcm, lcm), (:binomial, binomial)]

for (name, fn) in _MATH1
    builtin!(name, _math_builtin1(name, fn))
end
for (name, fn) in _MATH2
    builtin!(name, _math_builtin2(name, fn))
end

function _minmax(name::Symbol, cmp::Function, args::Vector{Form})::Form
    isempty(args) && return _mk_prefix(name, args)
    # A single collection argument aggregates over its elements (so `(min ?g)`
    # works on a grouped variable).
    if length(args) == 1 && args[1] isa FormContainer
        args = Form[to_form(v) for v in args[1].seq]
        isempty(args) && return naught
    end
    leaves = [_leafof(a) for a in args]
    all(l -> l isa Number, leaves) || return _mk_prefix(name, args)
    return to_form(reduce(cmp, leaves))
end
builtin!(:min, (env, scope, args) -> _minmax(:min, min, args))
builtin!(:max, (env, scope, args) -> _minmax(:max, max, args))

# ---- bitwise operations ------------------------------------------------------
#
# `|` is the nesting shorthand, so these cannot be infix operators; they are
# named functions. Like the other math builtins they are symbolic: they compute
# on integers and otherwise return the form unchanged. A `Bool` is an integer in
# Julia, so `(bit-and true 1)` is `1`.
const _BITWISE = [
    (Symbol("bit-and"), (&)), (Symbol("bit-or"), (|)), (Symbol("bit-xor"), xor),
]
for (name, fn) in _BITWISE
    builtin!(name, (env, scope, args) -> begin
        _arg(args, 1, String(name))
        ls = [_leafof(a) for a in args]
        all(l -> l isa Integer, ls) || return _mk_prefix(name, args)
        return to_form(reduce(fn, ls))
    end)
end

builtin!(Symbol("bit-not"), (env, scope, args) -> begin
    x = _arg(args, 1, "bit-not")
    l = _leafof(x)
    l isa Integer || return _mk_prefix(Symbol("bit-not"), [x])
    return to_form(~l)
end)

const _SHIFTS = [(Symbol("bit-shift-left"), <<), (Symbol("bit-shift-right"), >>)]
for (name, fn) in _SHIFTS
    builtin!(name, (env, scope, args) -> begin
        x = _arg(args, 1, String(name)); n = _arg(args, 2, String(name))
        lx, ln = _leafof(x), _leafof(n)
        (lx isa Integer && ln isa Integer) || return _mk_prefix(name, [x, n])
        return to_form(fn(lx, ln))
    end)
end

# Numeric constants, registered as 0-arity rules on the environment.
function register_constants!(env::Env)
    add_rule!(env.rules, Form(Symbol("pi")), Form(Float64(pi)))
    add_rule!(env.rules, Form(Symbol("e")), Form(Float64(ℯ)))
    add_rule!(env.rules, Form(Symbol("tau")), Form(Float64(2pi)))
    add_rule!(env.rules, Form(Symbol("inf")), Form(Inf))
    add_rule!(env.rules, Form(Symbol("nan")), Form(NaN))
    return env
end
