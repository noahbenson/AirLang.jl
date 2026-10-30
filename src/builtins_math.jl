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

# ---- the numeric tower -------------------------------------------------------
#
# A numeric leaf is one of `Int64`, `BigInt`, `Float64`, `BigFloat`,
# `Rational{Int64}`, `Rational{BigInt}`, `ComplexF64`, or `Complex{BigFloat}`
# (AirDB's `FormLeaf`). The reader has a literal for each of the real ones and a
# one-token spelling for `ComplexF64`; these constructors fill in the spellings
# the printer needs for the rest.

# `(rational n d)` — the exact rational `n/d`.
builtin!(:rational, (env, scope, args) -> begin
    x = _arg(args, 1, "rational"); y = _arg(args, 2, "rational")
    lx, ly = _leafof(x), _leafof(y)
    (lx isa Integer && ly isa Integer) || return _mk_prefix(:rational, [x, y])
    iszero(ly) && throw(AirEvalError("rational: a zero denominator"))
    return to_form(lx // ly)
end)

# `(complex re im)` — the complex value with the given parts; it is
# `ComplexF64` when both parts are exactly `Float64` and `Complex{BigFloat}`
# otherwise, as AirDB canonicalizes it.
builtin!(:complex, (env, scope, args) -> begin
    x = _arg(args, 1, "complex"); y = _arg(args, 2, "complex")
    lx, ly = _leafof(x), _leafof(y)
    (lx isa Real && ly isa Real) || return _mk_prefix(:complex, [x, y])
    # A part that is neither exactly a `Float64` nor exactly a `BigFloat` (an
    # exact third, say) has no complex leaf, and rounding it would change the
    # value, so this is an air error rather than AirDB's raw `ArgumentError`.
    return try
        to_form(complex(lx, ly))
    catch
        throw(AirEvalError("complex: parts must be exactly representable as " *
                           "Float64 or BigFloat, got $(air_string(x)) and " *
                           "$(air_string(y))"))
    end
end)

const PRECISION_KEY = Symbol(":precision")

# `(bigfloat "1.5" precision=512)` — the `BigFloat` the text denotes, parsed at
# `precision` (default: the ambient one). The printer uses this spelling for a
# value whose precision is not the ambient default, which `big"…"` cannot carry.
special!(:bigfloat, (env, scope, call) -> begin
    _check_options(call, "bigfloat", (PRECISION_KEY,))
    args = _call_args(env, scope, call)
    length(args) == 1 ||
        throw(AirEvalError("bigfloat expects one string argument"))
    l = _leafof(args[1])
    l isa AbstractString ||
        throw(AirEvalError("bigfloat expects a string, got $(air_string(args[1]))"))
    p = precision(BigFloat)
    if haskey(call.map, PRECISION_KEY)
        pl = _leafof(air_reduce(env, scope, to_form(call.map[PRECISION_KEY])))
        (pl isa Integer && pl >= 2) ||
            throw(AirEvalError("bigfloat: precision must be an integer >= 2"))
        p = _as_int(pl, "bigfloat: precision")
    end
    v = try
        setprecision(BigFloat, p) do
            parse(BigFloat, String(l))
        end
    catch
        throw(AirEvalError("bigfloat: malformed number $(repr(String(l)))"))
    end
    return to_form(v)
end)

# `(div x y)` — integer division, the operation `//` used to be.
builtin!(:div, (env, scope, args) -> begin
    x = _arg(args, 1, "div"); y = _arg(args, 2, "div")
    lx, ly = _leafof(x), _leafof(y)
    (lx isa Integer && ly isa Integer) || return _mk_prefix(:div, [x, y])
    iszero(ly) && throw(AirEvalError("div: division by zero"))
    return to_form(div(lx, ly))
end)

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
