################################################################################
# tensor_ops.jl
#
# The numpy-shaped surface around `AirTensor`: construction helpers, comparison
# masks and `tensor-where`, array manipulation, axis-aware reductions
# (`dims=`/`drop=`), cumulative operations, extra `LinearAlgebra` wrappers, and
# the in-place mapping verbs. The generic verbs `sum`, `mean`, `sort`, `reverse`,
# and `transpose` gain their tensor branches in their own files; the helpers they
# call live here.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const DIMS_KEY = Symbol(":dims")
const DROP_KEY = Symbol(":drop")
const AXIS_KEY = Symbol(":axis")
const DESC_KEY = Symbol(":descending")
const DD_KEY = Symbol(":ddof")
const N_KEY = Symbol(":n")
const ENDPOINT_KEY = Symbol(":endpoint")
const K_KEY = Symbol(":k")
const PERM_KEY = Symbol(":perm")
const ALL_KEYWORD = Symbol(":all")

# ---- option helpers ----------------------------------------------------------

# The integer values of a reduced dimension/axis form: either one integer or a
# map-less sequence of integers.
function _axis_values(v::Form, who::AbstractString)
    if v isa FormContainer
        isempty(v.map) || throw(AirEvalError(
            "$who: the axis list cannot be a mapping"))
        out = Int[]
        for x in v.seq
            l = _leafof(to_form(x))
            l isa Integer || throw(AirEvalError(
                "$who: axes must be integers"))
            push!(out, _as_int(l, who))
        end
        return out
    end
    l = _leafof(v)
    l isa Integer || throw(AirEvalError("$who: axes must be integers"))
    return Int[_as_int(l, who)]
end

function _norm_axis(a::Int, rank::Int, who::AbstractString)
    aa = a < 0 ? rank + a + 1 : a
    (1 <= aa <= rank) ||
        throw(AirEvalError("$who: axis $a is out of range for rank $rank"))
    return aa
end

# `dims=` as a sorted list of positive axes, `nothing` when absent. `:all` names
# every axis, and a negative axis counts from the end (as in Julia).
function _tensor_axes_opt(env::Env, scope::Scope, call::FormContainer,
                          rank::Int, who::AbstractString)
    haskey(call.map, DIMS_KEY) || return nothing
    v = air_reduce(env, scope, to_form(call.map[DIMS_KEY]))
    _leafof(v) === ALL_KEYWORD && return collect(1:rank)
    vals = _axis_values(v, "$who dims")
    isempty(vals) && throw(AirEvalError("$who: dims cannot be empty"))
    out = Int[]
    for a in vals
        aa = _norm_axis(a, rank, who)
        aa in out || push!(out, aa)
    end
    sort!(out)
    return out
end

function _tensor_drop_opt(env::Env, scope::Scope, call::FormContainer)
    haskey(call.map, DROP_KEY) || return false
    return truthy(air_reduce(env, scope, to_form(call.map[DROP_KEY])))
end

function _tensor_axis_opt(env::Env, scope::Scope, call::FormContainer,
                          rank::Int, default::Int, who::AbstractString)
    haskey(call.map, AXIS_KEY) || return _norm_axis(default, rank, who)
    v = air_reduce(env, scope, to_form(call.map[AXIS_KEY]))
    vals = _axis_values(v, "$who axis")
    length(vals) == 1 ||
        throw(AirEvalError("$who: axis= must name exactly one axis"))
    return _norm_axis(vals[1], rank, who)
end

function _tensor_int_opt(env::Env, scope::Scope, call::FormContainer,
                         key::Symbol, default::Int, who::AbstractString)
    haskey(call.map, key) || return default
    l = _leafof(air_reduce(env, scope, to_form(call.map[key])))
    l isa Integer || throw(AirEvalError(
        "$who: $(air_string(Form(key))) must be an integer"))
    return _as_int(l, "$who: $(String(key)[2:end])")
end

function _tensor_bool_opt(env::Env, scope::Scope, call::FormContainer,
                          key::Symbol, default::Bool)
    haskey(call.map, key) || return default
    return truthy(air_reduce(env, scope, to_form(call.map[key])))
end

function _perm_option(env::Env, scope::Scope, call::FormContainer, rank::Int,
                      who::AbstractString)
    v = air_reduce(env, scope, to_form(call.map[PERM_KEY]))
    perm = _axis_values(v, "$who perm")
    length(perm) == rank || throw(AirEvalError(
        "$who: perm must list $rank axes"))
    sort(perm) == collect(1:rank) || throw(AirEvalError(
        "$who: perm must be a permutation of 1:$(rank)"))
    return perm
end

# ---- reading several tensors -------------------------------------------------

# Check every input before using any, so a missing reservation cannot leave a
# partially-read operation.
function _tensor_read_many(ts::Vector{AirTensor})
    data = Array[]
    for t in ts
        push!(data, _tensor_check_read(t))
    end
    return data
end

# ---- axis-aware reductions ---------------------------------------------------

# Run `f(data, axes)` under the read reservation, then (optionally) drop the
# reduced axes. Dropping every axis yields a scalar leaf rather than a rank-0
# array, which a tensor cannot represent.
function _tensor_reduce_dims(name::AbstractString, t::AirTensor, axes,
                             drop::Bool, f::Function)::Form
    return _tensor_read(t) do d
        r = try
            f(d, axes)
        catch e
            e isa AirEvalError && rethrow()
            throw(AirEvalError("$name: " * sprint(showerror, e)))
        end
        if drop && length(axes) == ndims(d)
            rr = try
                dropdims(r; dims = Tuple(axes))
            catch e
                throw(AirEvalError("$name: " * sprint(showerror, e)))
            end
            return to_form(AirDB._formvalue(only(rr)))
        elseif drop
            r = try
                dropdims(r; dims = Tuple(axes))
            catch e
                throw(AirEvalError("$name: " * sprint(showerror, e)))
            end
        end
        r isa AbstractArray || throw(AirEvalError(
            "$name: an axis reduction must produce an array"))
        return _new_tensor(_canonical_data(r))
    end
end

_reduction_count(d, ax) = prod(size(d, i) for i in ax)

function _mean_data(d, ax)
    n = _reduction_count(d, ax)
    s = sum(d; dims = Tuple(ax))
    return n == 0 ? fill(NaN, size(s)) : s ./ n
end

_tensor_sum_dims(t::AirTensor, ax, drop) =
    _tensor_reduce_dims("sum", t, ax, drop,
                        (d, a) -> sum(d; dims = Tuple(a)))
_tensor_product_dims(t::AirTensor, ax, drop) =
    _tensor_reduce_dims("product", t, ax, drop,
                        (d, a) -> prod(d; dims = Tuple(a)))
_tensor_mean_dims(t::AirTensor, ax, drop) =
    _tensor_reduce_dims("mean", t, ax, drop, _mean_data)

# The median of a vector; `NaN` for an empty slice so `mapslices` has a
# consistent element type when a reduced axis has length zero.
function _median_vec(v)
    n = length(v)
    n == 0 && return NaN
    s = sort(v)
    isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2
end

_tensor_median_dims(t::AirTensor, ax, drop) =
    _tensor_reduce_dims("median", t, ax, drop,
                        (d, a) -> mapslices(_median_vec, d; dims = Tuple(a)))

function _variance_data(d, ax, ddof::Int)
    m = _mean_data(d, ax)
    s = sum(abs2.(d .- m); dims = Tuple(ax))
    den = _reduction_count(d, ax) - ddof
    den <= 0 && return fill(NaN, size(s))
    return s ./ den
end

_tensor_variance_dims(t::AirTensor, ax, drop, ddof::Int) =
    _tensor_reduce_dims("variance", t, ax, drop,
                        (d, a) -> _variance_data(d, a, ddof))
_tensor_std_dims(t::AirTensor, ax, drop, ddof::Int) =
    _tensor_reduce_dims("std", t, ax, drop,
                        (d, a) -> sqrt.(_variance_data(d, a, ddof)))

# The linear (non-`dims=`) variance over a vector of leaves.
function _variance_scalar(ls, ddof::Int)::Form
    n = length(ls)
    n - ddof <= 0 && return naught
    m = sum(ls) / n
    return to_form(sum(abs2(x - m) for x in ls) / (n - ddof))
end

# ---- construction ------------------------------------------------------------

function _bi_tensor_arange(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-arange", ())
    args = _call_args(env, scope, call)
    length(args) in (1, 2, 3) ||
        throw(AirEvalError("tensor-arange takes one to three arguments"))
    ls = [_leafof(a) for a in args]
    all(x -> x isa Real, ls) ||
        throw(AirEvalError("tensor-arange expects real numbers"))
    start, stop, step = length(ls) == 1 ? (0, ls[1], 1) :
        length(ls) == 2 ? (ls[1], ls[2], 1) : (ls[1], ls[2], ls[3])
    iszero(step) && throw(AirEvalError("tensor-arange: step cannot be zero"))
    r = try
        collect(range(start, stop; step = step))
    catch e
        throw(AirEvalError("tensor-arange: " * sprint(showerror, e)))
    end
    # Numpy's `arange` excludes the stop; `range` includes it when it lands
    # exactly, so drop that last element.
    !isempty(r) && last(r) == stop && pop!(r)
    return _new_tensor(_canonical_data(r))
end
special!(Symbol("tensor-arange"), _bi_tensor_arange)

function _bi_tensor_linspace(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-linspace", (N_KEY, ENDPOINT_KEY))
    args = _call_args(env, scope, call)
    length(args) == 2 ||
        throw(AirEvalError("tensor-linspace takes a start and a stop"))
    ls = [_leafof(a) for a in args]
    all(x -> x isa Real, ls) ||
        throw(AirEvalError("tensor-linspace expects real numbers"))
    n = _tensor_int_opt(env, scope, call, N_KEY, 50, "tensor-linspace")
    n >= 1 || throw(AirEvalError("tensor-linspace: n must be at least 1"))
    endpoint = _tensor_bool_opt(env, scope, call, ENDPOINT_KEY, true)
    r = try
        # `range` has no `endpoint=` keyword, so build the open variant by hand.
        endpoint ? collect(range(ls[1], ls[2]; length = n)) :
                   collect(range(ls[1]; step = (ls[2] - ls[1]) / n, length = n))
    catch e
        throw(AirEvalError("tensor-linspace: " * sprint(showerror, e)))
    end
    return _new_tensor(_canonical_data(r))
end
special!(Symbol("tensor-linspace"), _bi_tensor_linspace)

function _bi_tensor_randint(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-randint", ())
    length(call.seq) >= 4 ||
        throw(AirEvalError("tensor-randint needs a range and dimensions"))
    lo = _as_int(_num(air_reduce(env, scope, to_form(call.seq[2])),
                      "tensor-randint lo"), "tensor-randint lo")
    hi = _as_int(_num(air_reduce(env, scope, to_form(call.seq[3])),
                      "tensor-randint hi"), "tensor-randint hi")
    hi > lo || throw(AirEvalError(
        "tensor-randint: hi ($hi) must be greater than lo ($lo)"))
    dims = _tensor_dim_args(env, scope, call, 4, "tensor-randint")
    isempty(dims) && throw(AirEvalError("tensor-randint needs dimensions"))
    return _new_tensor(rand(lo:(hi - 1), dims...))
end
special!(Symbol("tensor-randint"), _bi_tensor_randint)

# ---- comparison masks and where ---------------------------------------------

for (nm, fn) in ((Symbol("tensor-lt"), (<)), (Symbol("tensor-le"), (<=)),
                 (Symbol("tensor-gt"), (>)), (Symbol("tensor-ge"), (>=)),
                 (Symbol("tensor-eq"), (==)), (Symbol("tensor-ne"), (!=)))
    builtin!(nm, (env, scope, args) -> begin
        a = _arg(args, 1, String(nm)); b = _arg(args, 2, String(nm))
        r = _tensor_math2(nm, fn, a, b)
        r === nothing && throw(AirEvalError(
            "$(nm) expects at least one tensor operand"))
        r
    end)
end

# `(tensor-where cond a b)` — elementwise select; a nonzero condition is true.
function _where_fn(c, x, y)
    cond = c isa Bool ? c : !iszero(c)
    return cond ? x : y
end

function _bi_tensor_where(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-where", ())
    args = _call_args(env, scope, call)
    length(args) == 3 ||
        throw(AirEvalError("tensor-where takes a condition and two values"))
    r = _tensor_mathn(Symbol("tensor-where"), _where_fn, args)
    r === nothing && throw(AirEvalError(
        "tensor-where expects at least one tensor operand"))
    return r
end
special!(Symbol("tensor-where"), _bi_tensor_where)

# ---- manipulation ------------------------------------------------------------

function _bi_tensor_concat(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-concat", (AXIS_KEY,))
    args = _call_args(env, scope, call)
    isempty(args) && throw(AirEvalError("tensor-concat needs tensors"))
    ts = AirTensor[]
    for a in args
        t = _tensor_of(a)
        t === nothing && throw(AirEvalError(
            "tensor-concat expects tensors, got " * air_string(a)))
        push!(ts, t)
    end
    rank = ndims(ts[1].data)
    all(t -> ndims(t.data) == rank, ts) ||
        throw(AirEvalError("tensor-concat: every tensor must have the same rank"))
    axis = _tensor_axis_opt(env, scope, call, rank, 1, "tensor-concat")
    data = _tensor_read_many(ts)
    r = length(data) == 1 ? copy(data[1]) :
        try
            cat(data...; dims = axis)
        catch e
            throw(AirEvalError("tensor-concat: " * sprint(showerror, e)))
        end
    return _new_tensor(_canonical_data(r))
end
special!(Symbol("tensor-concat"), _bi_tensor_concat)

function _bi_tensor_stack(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-stack", (AXIS_KEY,))
    args = _call_args(env, scope, call)
    isempty(args) && throw(AirEvalError("tensor-stack needs tensors"))
    ts = AirTensor[]
    for a in args
        t = _tensor_of(a)
        t === nothing && throw(AirEvalError(
            "tensor-stack expects tensors, got " * air_string(a)))
        push!(ts, t)
    end
    rank = ndims(ts[1].data)
    all(t -> ndims(t.data) == rank, ts) ||
        throw(AirEvalError("tensor-stack: every tensor must have the same rank"))
    axis = _tensor_axis_opt(env, scope, call, rank + 1, 1, "tensor-stack")
    data = _tensor_read_many(ts)
    expanded = [
        reshape(d, (size(d)[1:axis - 1]..., 1, size(d)[axis:end]...))
        for d in data]
    r = try
        cat(expanded...; dims = axis)
    catch e
        throw(AirEvalError("tensor-stack: " * sprint(showerror, e)))
    end
    return _new_tensor(_canonical_data(r))
end
special!(Symbol("tensor-stack"), _bi_tensor_stack)

function _bi_tensor_flip(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-flip", (AXIS_KEY, DIMS_KEY))
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("tensor-flip expects one tensor"))
    t = _tensor_arg(args, 1, "tensor-flip")
    rank = ndims(t.data)
    axes = if haskey(call.map, DIMS_KEY)
        _tensor_axes_opt(env, scope, call, rank, "tensor-flip")
    elseif haskey(call.map, AXIS_KEY)
        Int[_tensor_axis_opt(env, scope, call, rank, 1, "tensor-flip")]
    else
        collect(1:rank)
    end
    return _tensor_read(t) do d
        _new_tensor(_canonical_data(reverse(d; dims = Tuple(axes))))
    end
end
special!(Symbol("tensor-flip"), _bi_tensor_flip)

function _bi_tensor_roll(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-roll", (AXIS_KEY,))
    args = _call_args(env, scope, call)
    length(args) == 2 || throw(AirEvalError("tensor-roll takes a tensor and a shift"))
    t = _tensor_arg(args, 1, "tensor-roll")
    shift = _as_int(_num(args[2], "tensor-roll shift"), "tensor-roll shift")
    rank = ndims(t.data)
    axis = _tensor_axis_opt(env, scope, call, rank, 1, "tensor-roll")
    shifts = zeros(Int, rank)
    shifts[axis] = shift
    return _tensor_read(t) do d
        _new_tensor(_canonical_data(circshift(d, Tuple(shifts))))
    end
end
special!(Symbol("tensor-roll"), _bi_tensor_roll)

function _bi_tensor_tile(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-tile", ())
    args = _call_args(env, scope, call)
    length(args) >= 2 || throw(AirEvalError("tensor-tile needs repetitions"))
    t = _tensor_arg(args, 1, "tensor-tile")
    reps = Int[]
    for a in args[2:end]
        append!(reps, _axis_values(a, "tensor-tile reps"))
    end
    isempty(reps) && throw(AirEvalError("tensor-tile needs repetitions"))
    all(r -> r >= 0, reps) || throw(AirEvalError(
        "tensor-tile: repetitions cannot be negative"))
    return _tensor_read(t) do d
        nd = ndims(d)
        if length(reps) > nd
            # Numpy prepends singleton axes when there are more repetitions
            # than dimensions.
            shape = (ones(Int, length(reps) - nd)..., size(d)...)
            d = reshape(d, shape...)
        elseif length(reps) < nd
            reps = vcat(ones(Int, nd - length(reps)), reps)
        end
        _new_tensor(_canonical_data(repeat(d; outer = Tuple(reps))))
    end
end
special!(Symbol("tensor-tile"), _bi_tensor_tile)

function _bi_tensor_squeeze(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-squeeze", ())
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("tensor-squeeze expects one tensor"))
    t = _tensor_arg(args, 1, "tensor-squeeze")
    return _tensor_read(t) do d
        axes = [i for i in 1:ndims(d) if size(d, i) == 1]
        isempty(axes) && return _new_tensor(copy(d))
        r = dropdims(d; dims = Tuple(axes))
        ndims(r) == 0 && (r = [only(r)])
        _new_tensor(_canonical_data(r))
    end
end
special!(Symbol("tensor-squeeze"), _bi_tensor_squeeze)

function _bi_tensor_expand_dims(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-expand-dims", ())
    args = _call_args(env, scope, call)
    length(args) == 2 ||
        throw(AirEvalError("tensor-expand-dims takes a tensor and an axis"))
    t = _tensor_arg(args, 1, "tensor-expand-dims")
    rank = ndims(t.data)
    raw = _leafof(args[2])
    raw isa Integer || throw(AirEvalError(
        "tensor-expand-dims: the axis must be an integer"))
    axis = _norm_axis(_as_int(raw, "tensor-expand-dims"),
                      rank + 1, "tensor-expand-dims")
    return _tensor_read(t) do d
        shape = (size(d)[1:axis - 1]..., 1, size(d)[axis:end]...)
        _new_tensor(_canonical_data(Array(reshape(d, shape...))))
    end
end
special!(Symbol("tensor-expand-dims"), _bi_tensor_expand_dims)

function _bi_tensor_diag(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-diag", (K_KEY,))
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("tensor-diag expects one tensor"))
    t = _linalg_arg(args, 1, "tensor-diag", 2)
    k = _tensor_int_opt(env, scope, call, K_KEY, 0, "tensor-diag")
    return _tensor_linalg("tensor-diag", t, d -> LinearAlgebra.diag(d, k))
end
special!(Symbol("tensor-diag"), _bi_tensor_diag)

function _bi_tensor_diagm(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-diagm", (K_KEY,))
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("tensor-diagm expects one tensor"))
    t = _linalg_arg(args, 1, "tensor-diagm", 1)
    k = _tensor_int_opt(env, scope, call, K_KEY, 0, "tensor-diagm")
    return _tensor_linalg("tensor-diagm", t,
                          d -> LinearAlgebra.diagm(k => vec(d)))
end
special!(Symbol("tensor-diagm"), _bi_tensor_diagm)

function _bi_tensor_triangular(env::Env, scope::Scope, call::FormContainer,
                               name::Symbol, fn::Function)
    _check_options(call, String(name), (K_KEY,))
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("$(name) expects one tensor"))
    t = _linalg_arg(args, 1, String(name), 2)
    k = _tensor_int_opt(env, scope, call, K_KEY, 0, String(name))
    return _tensor_linalg(String(name), t, d -> fn(d, k))
end
special!(Symbol("tensor-tril"), (env, scope, call) ->
    _bi_tensor_triangular(env, scope, call, Symbol("tensor-tril"), LinearAlgebra.tril))
special!(Symbol("tensor-triu"), (env, scope, call) ->
    _bi_tensor_triangular(env, scope, call, Symbol("tensor-triu"), LinearAlgebra.triu))

function _bi_tensor_argsort(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-argsort", (DESC_KEY,))
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("tensor-argsort expects one tensor"))
    t = _tensor_arg(args, 1, "tensor-argsort")
    desc = _tensor_bool_opt(env, scope, call, DESC_KEY, false)
    return _tensor_read(t) do d
        p = try
            sortperm(vec(d); rev = desc)
        catch e
            throw(AirEvalError("tensor-argsort: " * sprint(showerror, e)))
        end
        _new_tensor(Vector{Int}(p))
    end
end
special!(Symbol("tensor-argsort"), _bi_tensor_argsort)

function _bi_tensor_arg_extreme(env::Env, scope::Scope, call::FormContainer,
                                name::Symbol, f::Function)
    _check_options(call, String(name), (DIMS_KEY, DROP_KEY))
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("$(name) expects one tensor"))
    t = _tensor_arg(args, 1, String(name))
    rank = ndims(t.data)
    if haskey(call.map, DIMS_KEY)
        axes = _tensor_axes_opt(env, scope, call, rank, String(name))
        drop = _tensor_drop_opt(env, scope, call)
        return _tensor_reduce_dims(String(name), t, axes, drop,
                                   (d, ax) -> begin
            r = f(d; dims = Tuple(ax))
            li = LinearIndices(d)
            out = Array{Int}(undef, size(r))
            for i in eachindex(r)
                out[i] = li[r[i]]
            end
            out
        end)
    end
    haskey(call.map, DROP_KEY) && throw(AirEvalError(
        "$(name): drop= requires dims="))
    return _tensor_read(t) do d
        r = try
            f(vec(d))
        catch e
            throw(AirEvalError("$(name): " * sprint(showerror, e)))
        end
        to_form(r)
    end
end
special!(Symbol("tensor-argmax"), (env, scope, call) ->
    _bi_tensor_arg_extreme(env, scope, call, Symbol("tensor-argmax"), argmax))
special!(Symbol("tensor-argmin"), (env, scope, call) ->
    _bi_tensor_arg_extreme(env, scope, call, Symbol("tensor-argmin"), argmin))

# ---- cumulative operations ---------------------------------------------------

function _bi_tensor_cumulative(env::Env, scope::Scope, call::FormContainer,
                               name::Symbol, f::Function)
    _check_options(call, String(name), (DIMS_KEY,))
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("$(name) expects one tensor"))
    t = _tensor_arg(args, 1, String(name))
    axes = _tensor_axes_opt(env, scope, call, ndims(t.data), String(name))
    if axes !== nothing && length(axes) != 1
        throw(AirEvalError("$(name): dims= names exactly one axis"))
    end
    return _tensor_read(t) do d
        r = try
            axes === nothing ? f(vec(d)) : f(d; dims = axes[1])
        catch e
            throw(AirEvalError("$(name): " * sprint(showerror, e)))
        end
        _new_tensor(_canonical_data(r))
    end
end
special!(Symbol("tensor-cumsum"), (env, scope, call) ->
    _bi_tensor_cumulative(env, scope, call, Symbol("tensor-cumsum"), cumsum))
special!(Symbol("tensor-cumprod"), (env, scope, call) ->
    _bi_tensor_cumulative(env, scope, call, Symbol("tensor-cumprod"), cumprod))

function _bi_tensor_diff(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-diff", (DIMS_KEY, N_KEY))
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("tensor-diff expects one tensor"))
    t = _tensor_arg(args, 1, "tensor-diff")
    n = _tensor_int_opt(env, scope, call, N_KEY, 1, "tensor-diff")
    n >= 0 || throw(AirEvalError("tensor-diff: n must be non-negative"))
    axes = _tensor_axes_opt(env, scope, call, ndims(t.data), "tensor-diff")
    if axes !== nothing && length(axes) != 1
        throw(AirEvalError("tensor-diff: dims= names exactly one axis"))
    end
    return _tensor_read(t) do d
        r = axes === nothing ? vec(d) : d
        r = try
            for _ in 1:n
                r = axes === nothing ? diff(r) : diff(r; dims = axes[1])
            end
            r
        catch e
            throw(AirEvalError("tensor-diff: " * sprint(showerror, e)))
        end
        _new_tensor(_canonical_data(r))
    end
end
special!(Symbol("tensor-diff"), _bi_tensor_diff)

function _bi_tensor_truth_reduce(env::Env, scope::Scope, call::FormContainer,
                                 name::Symbol, scalar_f::Function,
                                 array_f::Function)
    _check_options(call, String(name), (DIMS_KEY, DROP_KEY))
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("$(name) expects one tensor"))
    t = _tensor_arg(args, 1, String(name))
    axes = _tensor_axes_opt(env, scope, call, ndims(t.data), String(name))
    if axes === nothing
        haskey(call.map, DROP_KEY) && throw(AirEvalError(
            "$(name): drop= requires dims="))
        return _tensor_read(t) do d
            to_form(scalar_f(!iszero, vec(d)))
        end
    end
    drop = _tensor_drop_opt(env, scope, call)
    return _tensor_reduce_dims(String(name), t, axes, drop,
                               (d, ax) -> array_f(!iszero, d; dims = Tuple(ax)))
end
special!(Symbol("tensor-any"), (env, scope, call) ->
    _bi_tensor_truth_reduce(env, scope, call, Symbol("tensor-any"), any, any))
special!(Symbol("tensor-all"), (env, scope, call) ->
    _bi_tensor_truth_reduce(env, scope, call, Symbol("tensor-all"), all, all))
special!(Symbol("tensor-count"), (env, scope, call) ->
    _bi_tensor_truth_reduce(env, scope, call, Symbol("tensor-count"), count, count))

# ---- extra LinearAlgebra wrappers -------------------------------------------

builtin!(:eigvals, (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "eigvals", 2)
    _tensor_linalg("eigvals", t, d -> LinearAlgebra.eigvals(Array(d)))
end)

builtin!(:svdvals, (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "svdvals", 2)
    _tensor_linalg("svdvals", t, d -> LinearAlgebra.svdvals(Array(d)))
end)

builtin!(:pinv, (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "pinv", 2)
    _tensor_linalg("pinv", t, d -> LinearAlgebra.pinv(Array(d)))
end)

builtin!(:nullspace, (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "nullspace", 2)
    _tensor_linalg("nullspace", t, d -> LinearAlgebra.nullspace(Array(d)))
end)

# `cond` is air's conditional special form, so the condition number is
# `matrix-cond`, matching `matrix-rank`.
builtin!(Symbol("matrix-cond"), (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "matrix-cond", 2)
    _tensor_linalg("matrix-cond", t, d -> LinearAlgebra.cond(Array(d)))
end)

builtin!(:cross, (env, scope, args) -> begin
    a = _linalg_arg(args, 1, "cross", 1)
    b = _linalg_arg(args, 2, "cross", 1)
    _tensor_read(a, b) do x, y
        (length(x) == 3 && length(y) == 3) || throw(AirEvalError(
            "cross: both vectors must have length 3"))
        _new_tensor(_canonical_data(LinearAlgebra.cross(x, y)))
    end
end)

builtin!(:kron, (env, scope, args) -> begin
    a = _tensor_arg(args, 1, "kron")
    b = _tensor_arg(args, 2, "kron")
    _tensor_read(a, b) do x, y
        r = try
            LinearAlgebra.kron(x, y)
        catch e
            throw(AirEvalError("kron: " * sprint(showerror, e)))
        end
        _new_tensor(_canonical_data(r))
    end
end)

builtin!(:lu, (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "lu", 2)
    _tensor_read(t) do d
        F = try
            LinearAlgebra.lu(Array(d))
        catch e
            throw(AirEvalError("lu: " * sprint(showerror, e)))
        end
        _tmap([Symbol(":L") => _new_tensor(_canonical_data(Matrix(F.L))),
               Symbol(":U") => _new_tensor(_canonical_data(Matrix(F.U))),
               Symbol(":p") => _new_tensor(_canonical_data(Vector(F.p)))])
    end
end)

function _bi_linalg_predicate(env::Env, scope::Scope, call::FormContainer,
                              name::Symbol, f::Function)
    _check_options(call, String(name), ())
    args = _call_args(env, scope, call)
    length(args) == 1 || throw(AirEvalError("$(name) expects one tensor"))
    t = _linalg_arg(args, 1, String(name), 2)
    return _tensor_linalg(String(name), t, f)
end
special!(:isposdef, (env, scope, call) ->
    _bi_linalg_predicate(env, scope, call, :isposdef, d -> begin
        M = eltype(d) <: Complex ? LinearAlgebra.Hermitian(Array(d)) :
            LinearAlgebra.Symmetric(Array(d))
        LinearAlgebra.isposdef(M)
    end))
special!(:issymmetric, (env, scope, call) ->
    _bi_linalg_predicate(env, scope, call, :issymmetric,
                         d -> LinearAlgebra.issymmetric(Array(d))))
special!(:ishermitian, (env, scope, call) ->
    _bi_linalg_predicate(env, scope, call, :ishermitian,
                         d -> LinearAlgebra.ishermitian(Array(d))))

# ---- in-place operations -----------------------------------------------------

# `(tensor-map! f t)` — replace every cell with `(f cell)`; the tensor keeps its
# identity and its element type is promoted as needed.
function _bi_tensor_map_bang(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-map!", ())
    args = _call_args(env, scope, call)
    length(args) == 2 ||
        throw(AirEvalError("tensor-map! takes a function and a tensor"))
    f = args[1]
    t = _tensor_arg(args, 2, "tensor-map!")
    data = _tensor_write(t) do tt
        src = copy(tt.data)
        leaves = Any[]
        for x in vec(src)
            r = _call(env, scope, f, [to_form(AirDB._formvalue(x))])
            push!(leaves, _tensor_leaf(r))
        end
        T = _tower_type(leaves)
        out = Array{T}(undef, size(src))
        for (i, v) in enumerate(leaves)
            out[i] = convert(T, v)
        end
        out
    end
    t.data = data
    return args[2]
end
special!(Symbol("tensor-map!"), _bi_tensor_map_bang)

function _bi_tensor_clamp_bang(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-clamp!", ())
    args = _call_args(env, scope, call)
    length(args) == 3 ||
        throw(AirEvalError("tensor-clamp! takes a tensor and two bounds"))
    t = _tensor_arg(args, 1, "tensor-clamp!")
    lo = _num(args[2], "tensor-clamp! lo")
    hi = _num(args[3], "tensor-clamp! hi")
    lo <= hi || throw(AirEvalError(
        "tensor-clamp!: lo ($(air_string(args[2]))) exceeds hi " *
        "($(air_string(args[3])))"))
    data = _tensor_write(t) do tt
        r = try
            clamp.(tt.data, lo, hi)
        catch e
            throw(AirEvalError("tensor-clamp!: " * sprint(showerror, e)))
        end
        _canonical_data(r)
    end
    t.data = data
    return args[1]
end
special!(Symbol("tensor-clamp!"), _bi_tensor_clamp_bang)
