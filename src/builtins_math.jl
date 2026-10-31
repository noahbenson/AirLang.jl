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
    # A tensor operand broadcasts the function over its elements.
    tv = _tensor_of(x)
    tv === nothing || return _tensor_math1(name, fn, tv)
    l = _leafof(x)
    l isa Number || return _mk_prefix(name, [x])
    return to_form(fn(l))
end

function _math2(name::Symbol, fn::Function, x::Form, y::Form)::Form
    tr = _tensor_math2(name, fn, x, y)
    tr === nothing || return tr
    lx, ly = _leafof(x), _leafof(y)
    (lx isa Number && ly isa Number) || return _mk_prefix(name, [x, y])
    return to_form(fn(lx, ly))
end

_math_builtin1(name::Symbol, fn::Function) =
    (env, scope, args) -> _math1(name, fn, _arg(args, 1, String(name)))
_math_builtin2(name::Symbol, fn::Function) =
    (env, scope, args) -> _math2(name, fn, _arg(args, 1, String(name)), _arg(args, 2, String(name)))

const _MATH1 = [
    (:abs, abs), (:sign, sign), (:sqrt, sqrt), (:cbrt, cbrt),
    (:exp, exp), (:exp2, exp2), (:exp10, exp10), (:expm1, expm1),
    (:log, log), (:log2, log2), (:log10, log10), (:log1p, log1p),
    (:sin, sin), (:cos, cos), (:tan, tan), (:asin, asin), (:acos, acos),
    (:atan, atan), (:sinh, sinh), (:cosh, cosh), (:tanh, tanh),
    (:asinh, asinh), (:acosh, acosh), (:atanh, atanh),
    (:sinc, sinc), (:sinpi, sinpi), (:cospi, cospi),
    (:deg2rad, deg2rad), (:rad2deg, rad2deg),
    (:real, real), (:imag, imag), (:conj, conj), (:angle, angle),
    (:abs2, abs2), (:cis, cis), (:factorial, factorial),
    (:isnan, isnan), (:isinf, isinf), (:isfinite, isfinite),
    (:isinteger, isinteger), (:iseven, iseven), (:isodd, isodd),
]
const _MATH2 = [(:atan2, atan), (:gcd, gcd), (:lcm, lcm), (:binomial, binomial),
                (:hypot, hypot), (:rem, rem), (:copysign, copysign)]

for (name, fn) in _MATH1
    builtin!(name, _math_builtin1(name, fn))
end
for (name, fn) in _MATH2
    builtin!(name, _math_builtin2(name, fn))
end

# A symbolic prefix that keeps its map entries, so `(round (f x) digits=2)` is
# not silently stripped of `digits=` when `(f x)` does not reduce to a number.
function _mk_prefix_opts(env::Env, scope::Scope, call::FormContainer,
                         name::Symbol, args)
    seq = FormValue[_store_form(Form(name))]
    append!(seq, FormValue[_store_form(a) for a in args])
    map = FormMap()
    for (k, v) in call.map
        map = push(map, k => _store_form(air_reduce(env, scope, to_form(v))))
    end
    return FormContainer(FormSeq(seq), map)
end

const DIGITS_KEY = Symbol(":digits")
const SIGDIGITS_KEY = Symbol(":sigdigits")

function _digits_opt(env::Env, scope::Scope, call::FormContainer,
                     key::Symbol, who::AbstractString)
    haskey(call.map, key) || return nothing
    l = _leafof(air_reduce(env, scope, to_form(call.map[key])))
    l isa Integer || throw(AirEvalError(
        "$who: $(air_string(Form(key))) must be an integer"))
    return _as_int(l, "$who: $(String(key)[2:end])")
end

# `round`, `floor`, `ceil`, and `truncate` with an optional `digits=` (and
# `sigdigits=` for `round`). The plain one-argument forms are identical to the
# `_MATH1` broadcast.
function _bi_round_like(env::Env, scope::Scope, call::FormContainer,
                        name::Symbol, fn::Function, allow_sigdigits::Bool)
    allowed = allow_sigdigits ? (DIGITS_KEY, SIGDIGITS_KEY) : (DIGITS_KEY,)
    _check_options(call, String(name), allowed)
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("$(name) expects one argument"))
    digits = _digits_opt(env, scope, call, DIGITS_KEY, String(name))
    sigdigits = allow_sigdigits ?
        _digits_opt(env, scope, call, SIGDIGITS_KEY, String(name)) : nothing
    (digits !== nothing && sigdigits !== nothing) && throw(AirEvalError(
        "$(name): digits= and sigdigits= cannot both be given"))
    apply(x) = digits === nothing && sigdigits === nothing ? fn(x) :
        sigdigits !== nothing ? fn(x; sigdigits = sigdigits) :
        fn(x; digits = digits)
    x = args[1]
    tv = _tensor_of(x)
    if tv !== nothing
        return _tensor_read(tv) do data
            r = try
                apply.(data)
            catch e
                e isa AirEvalError && rethrow()
                throw(AirEvalError("$(name): " * sprint(showerror, e)))
            end
            _new_tensor(_canonical_data(r))
        end
    end
    l = _leafof(x)
    l isa Number || return _mk_prefix_opts(env, scope, call, name, [x])
    r = try
        apply(l)
    catch e
        e isa AirEvalError && rethrow()
        throw(AirEvalError("$(name): " * sprint(showerror, e)))
    end
    return to_form(AirDB._formvalue(r))
end

for (name, fn, sig) in ((:round, round, true), (:floor, floor, false),
                        (:ceil, ceil, false), (:truncate, trunc, false))
    special!(name, (env, scope, call) ->
        _bi_round_like(env, scope, call, name, fn, sig))
end

# `(clamp x lo hi)` — Julia's three-argument clamp, broadcast over tensors.
builtin!(:clamp, (env, scope, args) -> begin
    length(args) == 3 || throw(AirEvalError("clamp expects three arguments"))
    tr = _tensor_mathn(:clamp, clamp, args)
    tr === nothing || return tr
    ls = [_leafof(a) for a in args]
    all(l -> l isa Real, ls) || return _mk_prefix(:clamp, args)
    return to_form(AirDB._formvalue(clamp(ls...)))
end)

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
    tr = _tensor_math2(:div, div, x, y)
    tr === nothing || return tr
    lx, ly = _leafof(x), _leafof(y)
    (lx isa Integer && ly isa Integer) || return _mk_prefix(:div, [x, y])
    iszero(ly) && throw(AirEvalError("div: division by zero"))
    return to_form(div(lx, ly))
end)

# `min`/`max`: a single tensor aggregates over its linear cells (or along `dims=`);
# with several operands they broadcast elementwise, as before.
function _bi_minmax(env::Env, scope::Scope, call::FormContainer,
                    name::Symbol, cmp::Function)
    _check_options(call, String(name), (DIMS_KEY, DROP_KEY))
    args = _call_args(env, scope, call)
    isempty(args) && return _mk_prefix(name, args)
    if length(args) == 1
        tv = _tensor_of(args[1])
        if tv !== nothing
            if haskey(call.map, DIMS_KEY)
                axes = _tensor_axes_opt(env, scope, call, ndims(tv.data),
                                        String(name))
                drop = _tensor_drop_opt(env, scope, call)
                f = name === :min ? minimum : maximum
                return _tensor_reduce_dims(String(name), tv, axes, drop,
                                           (d, ax) -> f(d; dims = Tuple(ax)))
            end
            haskey(call.map, DROP_KEY) && throw(AirEvalError(
                "$(name): drop= requires dims="))
            ls = _tensor_leaves(tv)
            return isempty(ls) ? naught : to_form(reduce(cmp, ls))
        end
        # A single collection argument aggregates over its elements (so
        # `(min ?g)` works on a grouped variable).
        if args[1] isa FormContainer
            args = Form[to_form(v) for v in args[1].seq]
            isempty(args) && return naught
        end
    end
    (haskey(call.map, DIMS_KEY) || haskey(call.map, DROP_KEY)) &&
        throw(AirEvalError("$(name): dims= and drop= need a single tensor"))
    # Any tensor operand broadcasts elementwise.
    tr = _tensor_mathn(name, cmp, args)
    tr === nothing || return tr
    leaves = [_leafof(a) for a in args]
    all(l -> l isa Number, leaves) || return _mk_prefix(name, args)
    return to_form(reduce(cmp, leaves))
end
special!(:min, (env, scope, call) -> _bi_minmax(env, scope, call, :min, min))
special!(:max, (env, scope, call) -> _bi_minmax(env, scope, call, :max, max))

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
