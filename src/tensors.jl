################################################################################
# tensors.jl
#
# `tensor`: a mutable N-dimensional numeric array (an AirDB extern), plus the
# reservation forms that make mutation safe under Air's STM.
#
# A tensor's elements are restricted to Air's numeric tower (Bool, Int64,
# BigInt, Float64, BigFloat, Rational{Int64}, Rational{BigInt}, ComplexF64, and
# Complex{BigFloat}); Julia promotion is used to find a common element type.
#
# Concurrency. AirDB gives every extern a read/write lock and an Air version
# cell, but a mutable extern may only be used through a reservation:
#
#   (reserve-read RESOURCES body…)   read locks, inline, transaction-safe
#   (reserve RESOURCES read=… body…) write locks on a spawned task, a promise
#
# A reservation installs a task-local context naming the reserved handles and
# their modes; `_tensor_read` and `_tensor_write` consult it. A tensor this task
# created and has never shared is usable directly (a "fresh" tensor), which is
# what makes an inline literal such as `(get [1 2 3] 1)` possible.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- the value types ---------------------------------------------------------

"""
    AirTensor

A mutable N-dimensional numeric array. `data` is an ordinary Julia `Array` whose
element type is in Air's numeric tower; `fe` is the single interned
`FormExtern` that carries it, so a tensor has exactly one handle (and therefore
one lock and one version) however many times it is converted to a form.
"""
mutable struct AirTensor <: AbstractAirExtern
    data::Array
    fe::Any
end
AirTensor(data::Array) = AirTensor(data, nothing)

"""
    AirReservation

The promise a write reservation returns. `(get r)` and `(await r)` wait for the
body's value (re-raising its error); `(ready? r)` tests readiness without
waiting. A pending reservation cannot be awaited inside a transaction.
"""
mutable struct AirReservation <: AbstractAirExtern
    promise::AirDB.ExternPromise{Any}
    fe::Any
end
AirReservation(promise::AirDB.ExternPromise) = AirReservation(promise, nothing)

# ---- the numeric tower -------------------------------------------------------

const _TOWER_TYPES = (Bool, Int64, BigInt, Float64, BigFloat,
                      Rational{Int64}, Rational{BigInt},
                      ComplexF64, Complex{BigFloat})

_in_tower(::Type{T}) where {T} = any(T === S for S in _TOWER_TYPES)

const _TENSOR_TYPE_ALIASES = Dict{Symbol,DataType}(
    :bool => Bool,
    :int => Int64, :int64 => Int64, :bigint => BigInt,
    :float => Float64, :float64 => Float64, :bigfloat => BigFloat,
    :rational => Rational{Int64}, :rational64 => Rational{Int64},
    :rationalbig => Rational{BigInt},
    :complex => ComplexF64, :complex64 => ComplexF64,
    :complexbig => Complex{BigFloat})

const _TENSOR_TYPE_NAMES = Dict{DataType,Symbol}(
    Bool => :bool, Int64 => :int64, BigInt => :bigint,
    Float64 => :float64, BigFloat => :bigfloat,
    Rational{Int64} => :rational64, Rational{BigInt} => :rationalbig,
    ComplexF64 => :complex64, Complex{BigFloat} => :complexbig)

function _tensor_type_of(x::Form, who::AbstractString)
    l = _leafof(x)
    l isa Symbol || throw(AirEvalError(
        "$who: the element type must be a keyword such as :float64"))
    s = String(l)
    s = startswith(s, ":") ? s[2:end] : s
    T = get(_TENSOR_TYPE_ALIASES, Symbol(s), nothing)
    T === nothing && throw(AirEvalError(
        "$who: unknown element type :$s (expected one of " *
        join(":" .* String.(sort!(collect(keys(_TENSOR_TYPE_ALIASES)))), ", ") * ")"))
    return T
end

# A numeric cell as its canonical leaf value.
function _tensor_leaf(x::Form)
    x isa FormScalar || throw(AirEvalError(
        "tensor: an element must be a number, got " * air_string(x)))
    l = value(x)
    l isa Number || throw(AirEvalError(
        "tensor: an element must be a number, got " * air_string(x)))
    c = to_form(l)
    v = _leafof(c)
    v isa Number || throw(AirEvalError(
        "tensor: an element must be a number, got " * air_string(x)))
    return v
end

# Each value is canonicalized to its AirDB leaf first, so a Julia array of a
# narrower type (`Int32`, `Float32`) promotes the way a form does.
function _tower_type(ls)
    T = Union{}
    for l in ls
        l isa Number || throw(AirEvalError(
            "tensor: an element must be a number, got " * string(l)))
        v = try
            AirDB._formvalue(l)
        catch e
            throw(AirEvalError("tensor: " * sprint(showerror, e)))
        end
        T = T === Union{} ? typeof(v) : promote_type(T, typeof(v))
    end
    T === Union{} && return Float64
    _in_tower(T) || throw(AirEvalError(
        "tensor: the element type $T is outside Air's numeric tower"))
    return T
end

# Canonicalize an array: an element type in the tower, rank at least 1. The
# result is always an `Array`: broadcasting a predicate or comparison yields a
# `BitArray`, which a tensor stores as an `Array{Bool}`.
function _canonical_data(data::AbstractArray)
    data = data isa Array ? data : Array(data)
    ndims(data) >= 1 || throw(AirEvalError("tensor: an array must have rank >= 1"))
    T = eltype(data)
    if T === Union{}
        return zeros(Float64, size(data))
    elseif _in_tower(T)
        return data
    end
    return Array{_tower_type(collect(data))}(data)
end

# ---- forms and interning -----------------------------------------------------

function _tensor_of(x::Form)
    x isa FormExtern || return nothing
    d = try
        value(x)
    catch
        return nothing
    end
    return d isa AirTensor ? d : nothing
end

function _reservation_of(x::Form)
    x isa FormExtern || return nothing
    d = try
        value(x)
    catch
        return nothing
    end
    return d isa AirReservation ? d : nothing
end

_tensor_form(t::AirTensor) = t.fe

# A tensor is written as its one interned handle, so `to_form`/`_formvalue` share
# the lock and version cell every time the same tensor becomes a form.
AirDB._formvalue(t::AirTensor) = t.fe
AirDB._formvalue(r::AirReservation) = r.fe
_extern_form(t::AirTensor) = t.fe
_extern_form(r::AirReservation) = r.fe

function _new_tensor(data::AbstractArray)
    d = _canonical_data(data)
    t = AirTensor(d, nothing)
    fe = invoke(AirDB._formvalue, Tuple{AirDB.AbstractAirExtern}, t)
    t.fe = fe
    _tensor_mark_fresh(fe.handle)
    return fe
end

function _new_reservation(p::AirDB.ExternPromise)
    r = AirReservation(p, nothing)
    fe = invoke(AirDB._formvalue, Tuple{AirDB.AbstractAirExtern}, r)
    r.fe = fe
    return fe
end

# ---- task-local reservation state --------------------------------------------

const _TENSOR_CTX_KEY = :airlang_tensor_reservation
const _TENSOR_FRESH_KEY = :airlang_tensor_fresh

struct _TensorCtx
    modes::IdDict{Any,Symbol}     # ExternHandle => :read | :write
end

function _tensor_tls(key)
    tls = task_local_storage()
    tls isa IdDict || return nothing
    return get(tls, key, nothing)
end

function _tensor_fresh_set()
    s = _tensor_tls(_TENSOR_FRESH_KEY)
    if !(s isa Base.IdSet{Any})
        s = Base.IdSet{Any}()
        task_local_storage(_TENSOR_FRESH_KEY, s)
    end
    return s
end

_tensor_mark_fresh(h) = (push!(_tensor_fresh_set(), h); nothing)

# Run `f` with `modes` as the current task's reservation context. Reservations do
# not nest: the inner one would try to take a lock the outer body already holds.
function _with_tensor_ctx(f::Function, modes::IdDict)
    _tensor_tls(_TENSOR_CTX_KEY) === nothing ||
        throw(AirEvalError("reservations cannot be nested"))
    task_local_storage(_TENSOR_CTX_KEY, _TensorCtx(modes))
    try
        return f()
    finally
        task_local_storage(_TENSOR_CTX_KEY, nothing)
    end
end

function _tensor_ctx()
    c = _tensor_tls(_TENSOR_CTX_KEY)
    return c isa _TensorCtx ? c : nothing
end

function _tensor_ctx_mode(h)
    c = _tensor_ctx()
    c === nothing && return nothing
    return get(c.modes, h, nothing)
end

# Whether this task may touch handle `h` in `need` mode (`:read` or `:write`).
function _tensor_allowed(h, need::Symbol)
    m = _tensor_ctx_mode(h)
    if m === :write
        return true
    elseif m === :read
        return need === :read
    end
    fresh = _tensor_tls(_TENSOR_FRESH_KEY)
    return fresh isa Base.IdSet{Any} && h in fresh
end

function _tensor_unreserved(what::AbstractString)
    throw(AirEvalError(
        "tensor: $what a tensor that is not reserved; wrap the operation in a " *
        "reservation such as {t : (get t 1)} or {t :! (set! t 1 9)}"))
end

"""
    _tensor_read(f, t)

Run `f(t.data)` if the current task may read `t`. A fresh tensor and one named
by the enclosing reservation (in either mode) are readable; anything else must
be declared. Call with `_tensor_read(t) do data … end`.
"""
function _tensor_read(f::Function, t::AirTensor)
    return f(_tensor_check_read(t))
end

# Validate read access and hand back the data array; broadcast helpers that read
# several tensors start here.
function _tensor_check_read(t::AirTensor)
    h = t.fe === nothing ? nothing : t.fe.handle
    (h !== nothing && _tensor_allowed(h, :read)) ||
        _tensor_unreserved("has no reservation covering")
    return t.data
end

function _tensor_read(f::Function, a::AirTensor, b::AirTensor)
    ha = a.fe === nothing ? nothing : a.fe.handle
    hb = b.fe === nothing ? nothing : b.fe.handle
    (ha !== nothing && _tensor_allowed(ha, :read)) ||
        _tensor_unreserved("has no reservation covering")
    (hb !== nothing && _tensor_allowed(hb, :read)) ||
        _tensor_unreserved("has no reservation covering")
    return f(a.data, b.data)
end

"""
    _tensor_write(f, t)

Run `f(t)` if the current task may mutate `t`. A write is never legal inside a
transaction; otherwise the handle must be held in write mode (or the tensor must
be fresh). A reserved handle's edit is counted so AirDB publishes its version
and marks it dirty while the write locks are held. Call with
`_tensor_write(t) do tt … end`.
"""
function _tensor_write(f::Function, t::AirTensor)
    AirDB.currtx() === nothing || throw(AirEvalError(
        "tensor: a tensor cannot be written inside a transaction; " *
        "use a {t :! …} (or (reserve (t) …)) reservation"))
    h = t.fe === nothing ? nothing : t.fe.handle
    (h !== nothing && _tensor_allowed(h, :write)) ||
        _tensor_unreserved("has no write reservation covering")
    if _tensor_ctx_mode(h) === :write
        h.edits += 1
        h.dirty = true
    end
    return f(t)
end

# The handles behind a list of resource forms, with a mode per handle. Reads are
# applied last so a resource named in both places is read-only, matching AirDB.
function _reservation_modes(writes, reads)
    modes = IdDict{Any,Symbol}()
    for f in writes
        modes[f.handle] = :write
    end
    for f in reads
        modes[f.handle] = :read
    end
    return modes
end

# ---- construction from nested forms ------------------------------------------

# The axis sizes of a nested form. A scalar cell has no shape; every cell at a
# level must have the same shape, and the element type is checked by the fill.
function _sub_shape(x::Form)::Vector{Int}
    if x isa FormContainer
        isempty(x.map) || throw(AirEvalError(
            "tensor: a mapping is not part of a tensor's shape"))
        isempty(x.seq) && return Int[0]
        s0 = _sub_shape(to_form(x.seq[1]))
        for v in x.seq
            _sub_shape(to_form(v)) == s0 || throw(AirEvalError(
                "tensor: a nested sequence is ragged"))
        end
        return Int[length(x.seq); s0]
    end
    return Int[]
end

function _fill_array!(arr::Array, x::Form, prefix::Tuple)
    if x isa FormContainer
        for (i, v) in enumerate(x.seq)
            _fill_array!(arr, to_form(v), (prefix..., i))
        end
    else
        arr[prefix...] = convert(eltype(arr), _tensor_leaf(x))
    end
    return arr
end

function _collect_tensor_leaves!(out::Vector{Any}, x::Form)
    if x isa FormContainer
        for v in x.seq
            _collect_tensor_leaves!(out, to_form(v))
        end
    else
        push!(out, _tensor_leaf(x))
    end
    return out
end

# A nested form as an Array, promoting the cell types. An empty container has no
# cells, so it takes `T` (default Float64).
function _array_of_form(x::Form; T::Union{Nothing,DataType} = nothing)
    root = x isa FormContainer ? x :
        FormContainer(FormSeq(FormValue[_store_form(x)]), FormMap())
    shape = _sub_shape(root)
    leaves = Any[]
    _collect_tensor_leaves!(leaves, root)
    ty = T === nothing ? _tower_type(leaves) : T
    arr = Array{ty}(undef, shape...)
    isempty(leaves) || _fill_array!(arr, root, ())
    return arr
end

_convert_eltype(data::Array, T::DataType) = begin
    _in_tower(T) || throw(AirEvalError(
        "tensor: the element type $T is outside Air's numeric tower"))
    eltype(data) === T && return data
    try
        return Array{T}(data)
    catch e
        throw(AirEvalError("tensor: cannot convert $(eltype(data)) data to $T: " *
                           sprint(showerror, e)))
    end
end

# The linear (column-major) elements, as an air sequence form and as leaves. The
# snapshot is taken under the read check, so a caller may then iterate freely.
function _tensor_elems_form(t::AirTensor)
    canonicalize(_tseq(Form[to_form(x) for x in _tensor_read(vec, t)]))
end

_tensor_leaves(t::AirTensor) = _tensor_read(t) do d
    collect(vec(d))
end

# ---- access ------------------------------------------------------------------

# One axis specification: a colon keeps the axis, an integer selects one index,
# a sequence selects several (and keeps the axis).
function _tensor_axis_spec(env::Env, scope::Scope, p::Form, who::AbstractString)
    r = air_reduce(env, scope, to_form(p))
    if r isa FormContainer
        isempty(r.map) || throw(AirEvalError(
            "$who: an index sequence cannot be a mapping"))
        out = Int[]
        for v in r.seq
            l = _leafof(to_form(v))
            l isa Integer || throw(AirEvalError(
                "$who: a tensor index must be an integer, :, or a sequence of integers"))
            push!(out, _as_int(l, who))
        end
        return out
    end
    l = _leafof(r)
    l === COLON && return COLON
    l isa Integer ||
        throw(AirEvalError(
            "$who: a tensor index must be an integer, :, or a sequence of integers"))
    return _as_int(l, who)
end

function _tensor_specs(env::Env, scope::Scope, path, rank::Int,
                       who::AbstractString)
    length(path) <= rank || throw(AirEvalError(
        "$who: a rank-$rank tensor takes at most $rank index/indices, " *
        "got $(length(path))"))
    specs = Any[COLON for _ in 1:rank]
    for i in eachindex(path)
        specs[i] = _tensor_axis_spec(env, scope, to_form(path[i]), who)
    end
    return specs
end

function _tensor_pos(k::Int, n::Int, who::AbstractString)
    (1 <= k <= n) && return k
    (-n <= k <= -1) && return n + k + 1
    throw(AirEvalError("$who: tensor index $k is out of range for an axis of " *
                       "length $n"))
end

function _tensor_index_tuple(data, specs, who::AbstractString)
    idx = Any[]
    for (sp, n) in zip(specs, size(data))
        if sp === COLON
            push!(idx, Colon())
        elseif sp isa Int
            push!(idx, _tensor_pos(sp, n, who))
        else
            push!(idx, Int[_tensor_pos(k, n, who) for k in sp])
        end
    end
    return idx
end

# `get` for a tensor: one key per axis. A fully specified all-integer path yields
# a scalar leaf; anything else yields a fresh copy with the kept axes. Key `0`
# alone names the whole tensor.
function _tensor_get(env::Env, scope::Scope, t::AirTensor, path, default,
                     held::Bool)
    if length(path) == 1
        sp = _tensor_axis_spec(env, scope, to_form(path[1]), "get")
        if sp isa Int && sp == 0
            form = t.fe
            return held ? _ensure_hold(form) : form
        end
    end
    specs = _tensor_specs(env, scope, path, ndims(t.data), "get")
    idx = try
        _tensor_index_tuple(t.data, specs, "get")
    catch e
        (e isa AirEvalError && default !== nothing) || rethrow()
        return air_reduce(env, scope, default)
    end
    form = _tensor_read(t) do data
        r = data[idx...]
        r isa AbstractArray ? _new_tensor(Array(r)) :
            to_form(AirDB._formvalue(r))
    end
    return held ? _ensure_hold(form) : form
end

# ---- values and assignment ---------------------------------------------------

# A value being written: either an array (a tensor or nested sequence) or a
# scalar leaf. `readt` reads a tensor value (under the current reservation).
function _value_array(value::Form, readt)
    tv = _tensor_of(value)
    tv === nothing || return readt(tv), false
    if value isa FormContainer
        isempty(value.map) || throw(AirEvalError(
            "tensor: a mapping is not a tensor value"))
        return _array_of_form(value), false
    end
    return _tensor_leaf(value), true
end

_promoted_data(data, T) = eltype(data) === T ? data : Array{T}(data)

# Assign `value` into `data` at `specs`, promoting `data`'s element type when the
# value needs it. Returns the (possibly new) array; `data` must not be shared.
function _array_assign(data::Array, specs, value::Form, readt,
                       who::AbstractString)
    obj, scalar = _value_array(value, readt)
    T2 = scalar ? promote_type(eltype(data), typeof(obj)) :
        promote_type(eltype(data), eltype(obj))
    _in_tower(T2) || throw(AirEvalError(
        "$who: the value's element type $T2 is outside Air's numeric tower"))
    nd = _promoted_data(data, T2)
    idx = _tensor_index_tuple(nd, specs, who)
    v = view(nd, idx...)
    if scalar
        fill!(v, convert(T2, obj))
    else
        size(obj) == size(v) || throw(AirEvalError(
            "$who: the value has shape $(size(obj)) but the target has " *
            "shape $(size(v))"))
        v .= obj
    end
    return nd
end

function _tensor_assign_all(t::AirTensor, value::Form, who::AbstractString)
    specs = Any[COLON for _ in 1:ndims(t.data)]
    data = _tensor_write(t) do tt
        _array_assign(tt.data, specs, value,
                      tv -> _tensor_read(copy, tv), who)
    end
    t.data = data
    return nothing
end

function _tensor_assign(t::AirTensor, specs, value::Form, who::AbstractString)
    data = _tensor_write(t) do tt
        _array_assign(tt.data, specs, value,
                      tv -> _tensor_read(copy, tv), who)
    end
    t.data = data
    return nothing
end

# `set!` on a tensor: `(set! t keys… value)`.
function _tensor_set(env::Env, scope::Scope, call::FormContainer, t::AirTensor)
    n = length(call.seq)
    value = air_reduce(env, scope, to_form(call.seq[n]))
    if n == 3
        _tensor_assign_all(t, value, "set!")
        return value
    end
    path = _sx(call.seq, 3:(n - 1))
    if length(path) == 1
        sp = _tensor_axis_spec(env, scope, to_form(path[1]), "set!")
        if sp === COLON || (sp isa Int && sp == 0)
            _tensor_assign_all(t, value, "set!")
            return value
        end
    end
    specs = _tensor_specs(env, scope, path, ndims(t.data), "set!")
    _tensor_assign(t, specs, value, "set!")
    return value
end

# `with` on a tensor: a pure copy-and-assign returning a fresh tensor.
function _tensor_with(env::Env, scope::Scope, call::FormContainer,
                      t::AirTensor, held::Bool, strip::Bool = false)
    (length(call.seq) - 2) % 2 == 0 ||
        throw(AirEvalError("with needs key/value pairs"))
    for k in keys(call.map)
        k === HOLD_KEY || throw(AirEvalError(
            "with: unknown option " * air_string(Form(k))))
    end
    data = _tensor_read(copy, t)
    i = 3
    while i <= length(call.seq)
        keyf = to_form(call.seq[i])
        val = air_reduce(env, scope, to_form(call.seq[i + 1]))
        strip && (val = _strip_hold(val))
        specs = _with_tensor_specs(env, scope, keyf, ndims(data))
        data = _array_assign(data, specs, val, tv -> _tensor_read(copy, tv),
                             "with")
        i += 2
    end
    form = _new_tensor(data)
    return held ? _ensure_hold(form) : form
end

# A `with` key names one axis specification, or a sequence of them (one per
# axis). `0` (or `:`) alone names the whole tensor.
function _with_tensor_specs(env::Env, scope::Scope, keyf::Form, rank::Int)
    if keyf isa FormContainer
        isempty(keyf.map) || throw(AirEvalError(
            "with: a key sequence cannot be a mapping"))
        path = Form[to_form(v) for v in keyf.seq]
        if length(path) == 1
            sp0 = _tensor_axis_spec(env, scope, path[1], "with")
            (sp0 === COLON || (sp0 isa Int && sp0 == 0)) &&
                return Any[COLON for _ in 1:rank]
        end
        return _tensor_specs(env, scope, path, rank, "with")
    end
    sp = _tensor_axis_spec(env, scope, keyf, "with")
    (sp === COLON || (sp isa Int && sp == 0)) &&
        return Any[COLON for _ in 1:rank]
    specs = Any[COLON for _ in 1:rank]
    specs[1] = sp
    return specs
end

# ---- printing ----------------------------------------------------------------

function _extern_show_text(t::AirTensor)
    dims = join(size(t.data), "×")
    return string("#<tensor ", dims, " ", eltype(t.data), ">")
end

function _extern_show_text(r::AirReservation)
    return isready(r.promise) ? "#<reservation ready>" : "#<reservation>"
end

# ---- reservation forms -------------------------------------------------------

# The resource expressions of a reservation spec: a map-less container names
# several resources, anything else exactly one. Every one is evaluated eagerly
# and must be an extern.
function _reservation_resources(env::Env, scope::Scope, spec::Form,
                                who::AbstractString)
    # A map-less container names several resource *expressions*, each evaluated
    # in the caller's scope; anything else names exactly one.
    raws = if spec isa FormContainer
        isempty(spec.map) || throw(AirEvalError(
            "$who: the resource list cannot be a mapping"))
        Form[to_form(v) for v in spec.seq]
    else
        Form[spec]
    end
    # A resource expression that evaluates to a map-less sequence contributes its
    # elements, so a variable holding several resources works.
    forms = Form[]
    for r in raws
        v = air_reduce(env, scope, r)
        if v isa FormContainer
            isempty(v.map) || throw(AirEvalError(
                "$who: a resource cannot be a mapping"))
            append!(forms, Form[to_form(x) for x in v.seq])
        elseif !isequal(v, naught)
            push!(forms, v)
        end
    end
    isempty(forms) && throw(AirEvalError(
        "$who: a reservation needs at least one resource"))
    for f in forms
        f isa FormExtern || throw(AirEvalError(
            "$who: a reservation resource must be an extern (such as a " *
            "tensor), got " * air_string(f)))
        d = try
            value(f)
        catch
            throw(AirEvalError("$who: a reservation resource is a dead extern"))
        end
        d isa DeadExtern && throw(AirEvalError(
            "$who: a reservation resource is a dead extern"))
    end
    return forms
end

function _run_reservation_body(env::Env, scope::Scope, body)
    result = naught
    for b in body
        result = air_reduce(env, scope, to_form(b))
    end
    return result
end

# `(reserve-read RESOURCES body…)` — read locks, run inline, return the value.
function _bi_reserve_read(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "reserve-read", ())
    length(call.seq) >= 3 ||
        throw(AirEvalError("reserve-read needs resources and a body"))
    resources = _reservation_resources(env, scope, to_form(call.seq[2]),
                                       "reserve-read")
    modes = IdDict{Any,Symbol}(f.handle => :read for f in resources)
    body = _sx(call.seq, 3:length(call.seq))
    return AirDB.reserve_read(resources...) do apis...
        _with_tensor_ctx(modes) do
            _run_reservation_body(env, scope, body)
        end
    end
end
special!(Symbol("reserve-read"), _bi_reserve_read)

# `(reserve RESOURCES read=(…) body…)` — write locks on a spawned task; returns a
# reservation. The body is captured like a task's, so it runs in the caller's
# namespace and with its `val` bindings.
function _bi_reserve(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "reserve", (Symbol(":read"),))
    length(call.seq) >= 3 ||
        throw(AirEvalError("reserve needs resources and a body"))
    writes = _reservation_resources(env, scope, to_form(call.seq[2]), "reserve")
    reads = haskey(call.map, Symbol(":read")) ?
        _reservation_resources(env, scope, to_form(call.map[Symbol(":read")]),
                               "reserve") : Form[]
    modes = _reservation_modes(writes, reads)
    body = Form[to_form(v) for v in _sx(call.seq, 3:length(call.seq))]
    captured = Form[_capture_form(scope, b) for b in body]
    lscope = _scope_layers_only(scope)
    c = _context(env)
    ctx = TaskContext(c.user, c.ns, c.dbroot, c.env, c.out)
    bindings = Air.vars()
    p = AirDB.reserve(writes...; read = reads) do apis...
        _reset_block_scopes!()
        run = () -> _with_tensor_ctx(modes) do
            try
                _run_reservation_body(env, lscope, captured)
            catch e
                e isa ExitSignal || rethrow()
                e.value
            end
        end
        _with_context(env, ctx, () -> Air.setvars(run, bindings))
    end
    return _new_reservation(p)
end
special!(:reserve, _bi_reserve)

# Await a reservation. Inside a transaction a pending reservation raises rather
# than blocking (it cannot commit until the transaction does).
function _reservation_await(env::Env, r::AirReservation)
    if AirDB.currtx() !== nothing && !isready(r.promise)
        throw(AirEvalError(
            "reservation: a pending reservation cannot be awaited inside a " *
            "transaction"))
    end
    v = try
        r.promise[]
    catch e
        e isa AirDB.ExternError && throw(AirEvalError(e.msg))
        rethrow()
    end
    v isa Form || (v = to_form(v))
    return canonicalize(v)
end

builtin!(Symbol("reservation?"), (env, scope, args) ->
    Form(_reservation_of(_arg(args, 1, "reservation?")) !== nothing))

# ---- tensor builtins ---------------------------------------------------------

function _tensor_arg(args, i, name::AbstractString)
    x = _arg(args, i, name)
    t = _tensor_of(x)
    t === nothing && throw(AirEvalError(
        "$name expects a tensor, got " * air_string(x)))
    return t
end

# The `eltype=` option of a construction form, or `nothing`.
function _tensor_eltype_opt(env::Env, scope::Scope, call::FormContainer,
                            who::AbstractString)
    haskey(call.map, Symbol(":eltype")) || return nothing
    return _tensor_type_of(air_reduce(env, scope,
                                      to_form(call.map[Symbol(":eltype")])), who)
end

function _tensor_dims(env::Env, scope::Scope, x::Form, who::AbstractString)
    r = air_reduce(env, scope, to_form(x))
    if r isa FormContainer
        isempty(r.map) || throw(AirEvalError(
            "$who: the dimensions cannot be a mapping"))
        out = Int[]
        for v in r.seq
            l = _leafof(to_form(v))
            l isa Integer || throw(AirEvalError(
                "$who: dimensions must be integers"))
            k = _as_int(l, who)
            k >= 0 || throw(AirEvalError("$who: a dimension cannot be negative"))
            push!(out, k)
        end
        return out
    end
    l = _leafof(r)
    l isa Integer || throw(AirEvalError("$who: dimensions must be integers"))
    k = _as_int(l, who)
    k >= 0 || throw(AirEvalError("$who: a dimension cannot be negative"))
    return Int[k]
end

# The dimensions after argument `from`: each argument is one dimension or a
# container of dimensions, so `(tensor-zeros 2 3)` and `(tensor-zeros (2 3))`
# agree.
function _tensor_dim_args(env::Env, scope::Scope, call::FormContainer,
                          from::Int, who::AbstractString)
    length(call.seq) >= from ||
        throw(AirEvalError("$who needs dimensions"))
    dims = Int[]
    for i in from:length(call.seq)
        append!(dims, _tensor_dims(env, scope, to_form(call.seq[i]), who))
    end
    return dims
end

# `[1 2 3]` / `[1 2; 3 4]` and friends: the reader's hold has already filled its
# `preval` holes, so its elements are the (nested) cells.
function _bi_tensor_literal(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-literal", ())
    length(call.seq) == 2 ||
        throw(AirEvalError("tensor-literal: malformed literal"))
    h = air_reduce(env, scope, to_form(call.seq[2]))
    _is_hold(h) || throw(AirEvalError("tensor-literal: malformed literal"))
    items = Form[to_form(v) for v in _sx(h.seq, 2:length(h.seq))]
    root = FormContainer(FormSeq(FormValue[_store_form(f) for f in items]),
                         FormMap())
    return _new_tensor(_array_of_form(root))
end
special!(Symbol("tensor-literal"), _bi_tensor_literal)

# `(tensor coll eltype=…)` — build from a nested sequence (or copy a tensor).
function _bi_tensor(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor", (Symbol(":eltype"),))
    length(call.seq) <= 2 ||
        throw(AirEvalError("tensor takes at most one argument"))
    T = _tensor_eltype_opt(env, scope, call, "tensor")
    if length(call.seq) == 1
        return _new_tensor(Array{T === nothing ? Float64 : T}(undef, 0))
    end
    x = air_reduce(env, scope, to_form(call.seq[2]))
    tv = _tensor_of(x)
    if tv !== nothing
        data = _tensor_read(copy, tv)
        T === nothing || (data = _convert_eltype(data, T))
        return _new_tensor(data)
    end
    if isequal(x, naught)
        return _new_tensor(Array{T === nothing ? Float64 : T}(undef, 0))
    end
    return _new_tensor(_array_of_form(x; T = T))
end
special!(:tensor, _bi_tensor)

builtin!(Symbol("tensor?"), (env, scope, args) ->
    Form(_tensor_of(_arg(args, 1, "tensor?")) !== nothing))

builtin!(Symbol("tensor-shape"), (env, scope, args) -> begin
    t = _tensor_arg(args, 1, "tensor-shape")
    _tseq(Form[Form(i) for i in size(t.data)])
end)

builtin!(Symbol("tensor-rank"), (env, scope, args) ->
    Form(ndims(_tensor_arg(args, 1, "tensor-rank").data)))

builtin!(Symbol("tensor-eltype"), (env, scope, args) -> begin
    t = _tensor_arg(args, 1, "tensor-eltype")
    Form(get(_TENSOR_TYPE_NAMES, eltype(t.data),
             Symbol(string(eltype(t.data)))))
end)

builtin!(Symbol("tensor-copy"), (env, scope, args) -> begin
    t = _tensor_arg(args, 1, "tensor-copy")
    _new_tensor(_tensor_read(copy, t))
end)

# `(tensor->form t)` — the nested sequence spelling, for persistence by hand.
function _array_to_form(data::AbstractArray)
    if ndims(data) == 1
        return canonicalize(_tseq(Form[to_form(x) for x in data]))
    end
    rest = ntuple(_ -> Colon(), ndims(data) - 1)
    return canonicalize(_tseq(Form[_array_to_form(view(data, i, rest...))
                                 for i in axes(data, 1)]))
end

builtin!(Symbol("tensor->form"), (env, scope, args) -> begin
    t = _tensor_arg(args, 1, "tensor->form")
    _tensor_read(_array_to_form, t)
end)

# ---- generators --------------------------------------------------------------

function _bi_tensor_zeros(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-zeros", (Symbol(":eltype"),))
    dims = _tensor_dim_args(env, scope, call, 2, "tensor-zeros")
    T = _tensor_eltype_opt(env, scope, call, "tensor-zeros")
    return _new_tensor(zeros(T === nothing ? Float64 : T, dims...))
end
special!(Symbol("tensor-zeros"), _bi_tensor_zeros)

function _bi_tensor_ones(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-ones", (Symbol(":eltype"),))
    dims = _tensor_dim_args(env, scope, call, 2, "tensor-ones")
    T = _tensor_eltype_opt(env, scope, call, "tensor-ones")
    return _new_tensor(ones(T === nothing ? Float64 : T, dims...))
end
special!(Symbol("tensor-ones"), _bi_tensor_ones)

function _bi_tensor_fill(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-fill", (Symbol(":eltype"),))
    length(call.seq) >= 3 || throw(AirEvalError(
        "tensor-fill needs a value and dimensions"))
    v = air_reduce(env, scope, to_form(call.seq[2]))
    l = _tensor_leaf(v)
    dims = _tensor_dim_args(env, scope, call, 3, "tensor-fill")
    T = _tensor_eltype_opt(env, scope, call, "tensor-fill")
    ty = T === nothing ? typeof(l) : T
    _in_tower(ty) || (ty = _tower_type([l]))
    return _new_tensor(fill(convert(ty, l), dims...))
end
special!(Symbol("tensor-fill"), _bi_tensor_fill)

function _bi_tensor_eye(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-eye", (Symbol(":eltype"),))
    length(call.seq) in (2, 3) ||
        throw(AirEvalError("tensor-eye takes one or two dimensions"))
    m = only(_tensor_dims(env, scope, to_form(call.seq[2]), "tensor-eye"))
    n = length(call.seq) == 3 ?
        only(_tensor_dims(env, scope, to_form(call.seq[3]), "tensor-eye")) : m
    T = _tensor_eltype_opt(env, scope, call, "tensor-eye")
    ty = T === nothing ? Float64 : T
    return _new_tensor(Matrix{ty}(LinearAlgebra.I, m, n))
end
special!(Symbol("tensor-eye"), _bi_tensor_eye)

function _bi_tensor_rand(env::Env, scope::Scope, call::FormContainer, normal::Bool)
    name = normal ? "tensor-randn" : "tensor-rand"
    _check_options(call, Symbol(name), (Symbol(":eltype"),))
    dims = _tensor_dim_args(env, scope, call, 2, name)
    T = _tensor_eltype_opt(env, scope, call, name)
    T === nothing || T === Float64 || throw(AirEvalError(
        "$name supports only :float64 elements"))
    data = normal ? randn(dims...) : rand(dims...)
    return _new_tensor(data)
end
special!(Symbol("tensor-rand"), (env, scope, call) ->
    _bi_tensor_rand(env, scope, call, false))
special!(Symbol("tensor-randn"), (env, scope, call) ->
    _bi_tensor_rand(env, scope, call, true))

# ---- elementwise operations --------------------------------------------------

function _tensor_math1(name::Symbol, fn::Function, t::AirTensor)::Form
    return _tensor_read(t) do data
        r = try
            fn.(data)
        catch e
            throw(AirEvalError("$name: " * sprint(showerror, e)))
        end
        _new_tensor(_canonical_data(r))
    end
end

function _tensor_math2(name::Symbol, fn::Function, x::Form, y::Form)
    tx, ty = _tensor_of(x), _tensor_of(y)
    lx, ly = _leafof(x), _leafof(y)
    if tx !== nothing && ty !== nothing
        return _tensor_read(tx, ty) do a, b
            r = try
                fn.(a, b)
            catch e
                throw(AirEvalError("$name: " * sprint(showerror, e)))
            end
            _new_tensor(_canonical_data(r))
        end
    elseif tx !== nothing
        ly isa Number || return nothing
        return _tensor_read(tx) do a
            r = try
                fn.(a, ly)
            catch e
                throw(AirEvalError("$name: " * sprint(showerror, e)))
            end
            _new_tensor(_canonical_data(r))
        end
    elseif ty !== nothing
        lx isa Number || return nothing
        return _tensor_read(ty) do b
            r = try
                fn.(lx, b)
            catch e
                throw(AirEvalError("$name: " * sprint(showerror, e)))
            end
            _new_tensor(_canonical_data(r))
        end
    end
    return nothing
end

# Broadcast an n-ary function over a mix of tensors and scalars, for `min`/`max`.
# Returns `nothing` when no argument is a tensor (or one is neither).
function _tensor_mathn(name::Symbol, fn::Function, args::Vector{Form})
    vals = Any[]
    found = false
    for a in args
        t = _tensor_of(a)
        if t !== nothing
            found = true
            push!(vals, _tensor_check_read(t))
        else
            l = _leafof(a)
            l isa Number || return nothing
            push!(vals, l)
        end
    end
    found || return nothing
    r = try
        fn.(vals...)
    catch e
        throw(AirEvalError("tensor $name: " * sprint(showerror, e)))
    end
    r isa Number && return to_form(AirDB._formvalue(r))
    return _new_tensor(_canonical_data(r))
end

function _tensor_mul_data(a::Array, b::Array)
    na, nb = ndims(a), ndims(b)
    if na == 1 && nb == 1
        length(a) == length(b) || throw(AirEvalError(
            "tensor *: vectors have lengths $(length(a)) and $(length(b))"))
        return sum(a .* b)
    elseif na == 2 && nb == 2
        size(a, 2) == size(b, 1) || throw(AirEvalError(
            "tensor *: shapes $(size(a)) and $(size(b)) do not multiply"))
        return a * b
    elseif na == 2 && nb == 1
        size(a, 2) == length(b) || throw(AirEvalError(
            "tensor *: shapes $(size(a)) and $(size(b)) do not multiply"))
        return a * b
    elseif na == 1 && nb == 2
        length(a) == size(b, 1) || throw(AirEvalError(
            "tensor *: shapes $(size(a)) and $(size(b)) do not multiply"))
        return vec(a' * b)
    end
    throw(AirEvalError(
        "tensor *: rank $na times rank $nb is not defined; " *
        "use tensor-mul for elementwise multiplication"))
end

function _binop_fn(name::Symbol)
    name === Symbol("+") && return (+)
    name === Symbol("-") && return (-)
    name === Symbol("*") && return (*)
    name === Symbol("/") && return (/)
    name === Symbol("^") && return (^)
    name === Symbol("mod") && return (mod)
    return nothing
end

function _tensor_arith(name::Symbol, a::Form, b::Form)::Union{Nothing,Form}
    ta, tb = _tensor_of(a), _tensor_of(b)
    (ta === nothing && tb === nothing) && return nothing
    fn = _binop_fn(name)
    fn === nothing && return nothing
    la, lb = _leafof(a), _leafof(b)
    if ta !== nothing && tb !== nothing
        if name === Symbol("*")
            return _tensor_read(ta, tb) do x, y
                r = try
                    _tensor_mul_data(x, y)
                catch e
                    e isa AirEvalError && rethrow()
                    throw(AirEvalError("tensor *: " * sprint(showerror, e)))
                end
                r isa AbstractArray ? _new_tensor(_canonical_data(Array(r))) :
                    to_form(AirDB._formvalue(r))
            end
        end
        return _tensor_read(ta, tb) do x, y
            r = try
                fn.(x, y)
            catch e
                throw(AirEvalError("tensor $name: " * sprint(showerror, e)))
            end
            _new_tensor(_canonical_data(r))
        end
    elseif ta !== nothing
        lb isa Number || return nothing
        return _tensor_arith_scalar(name, fn, ta, lb, false)
    else
        la isa Number || return nothing
        return _tensor_arith_scalar(name, fn, tb, la, true)
    end
end

function _tensor_arith_scalar(name::Symbol, fn::Function, t::AirTensor, s::Number,
                              reverse::Bool)
    return _tensor_read(t) do d
        r = try
            reverse ? fn.(s, d) : fn.(d, s)
        catch e
            throw(AirEvalError("tensor $name: " * sprint(showerror, e)))
        end
        _new_tensor(_canonical_data(r))
    end
end

function _tensor_unary(name::Symbol, t::AirTensor)::Form
    return _tensor_read(t) do d
        r = try
            name === Symbol("-") ? (-).(d) : (1) ./ d
        catch e
            throw(AirEvalError("tensor $name: " * sprint(showerror, e)))
        end
        _new_tensor(_canonical_data(r))
    end
end

# `(tensor-map f t)` — apply `f` to every element (linear column-major order).
builtin!(Symbol("tensor-map"), (env, scope, args) -> begin
    f = _arg(args, 1, "tensor-map")
    t = _tensor_arg(args, 2, "tensor-map")
    data = _tensor_read(copy, t)
    leaves = Any[]
    for x in vec(data)
        r = _call(env, scope, f, [to_form(AirDB._formvalue(x))])
        push!(leaves, _tensor_leaf(r))
    end
    T = _tower_type(leaves)
    out = Array{T}(undef, size(data))
    for (i, v) in enumerate(leaves)
        out[i] = convert(T, v)
    end
    return _new_tensor(out)
end)

# `(tensor-mul a b)` — elementwise product (with scalar/tensor broadcasting).
builtin!(Symbol("tensor-mul"), (env, scope, args) -> begin
    a = _arg(args, 1, "tensor-mul"); b = _arg(args, 2, "tensor-mul")
    r = _tensor_math2(Symbol("tensor-mul"), (*), a, b)
    r === nothing && throw(AirEvalError(
        "tensor-mul expects tensors or numbers, got " *
        air_string(a) * " and " * air_string(b)))
    r
end)

# ---- in-place operations -----------------------------------------------------

function _inplace_arg2(env::Env, args, name::AbstractString)
    t = _tensor_arg(args, 1, name)
    x = _arg(args, 2, name)
    return t, x
end

function _tensor_inplace!(name::AbstractString, fn::Function, t::AirTensor,
                          value::Form)
    data = _tensor_write(t) do tt
        v, scalar = _value_array(value, tv -> _tensor_read(copy, tv))
        if !scalar && size(v) != size(tt.data)
            throw(AirEvalError(
                "$name: the value has shape $(size(v)) but the tensor has " *
                "shape $(size(tt.data))"))
        end
        _canonical_data(fn.(tt.data, v))
    end
    t.data = data
    return nothing
end

for (nm, fn) in ((Symbol("tensor-add!"), (+)),
                 (Symbol("tensor-sub!"), (-)),
                 (Symbol("tensor-mul!"), (*)),
                 (Symbol("tensor-div!"), (/)))
    builtin!(nm, (env, scope, args) -> begin
        t, x = _inplace_arg2(env, args, String(nm))
        if _tensor_of(x) !== nothing || (x isa FormContainer)
            _tensor_inplace!(String(nm), fn, t, x)
        else
            l = _tensor_leaf(x)
            _tensor_inplace!(String(nm), fn, t, to_form(l))
        end
        _arg(args, 1, String(nm))
    end)
end

builtin!(Symbol("tensor-scale!"), (env, scope, args) -> begin
    t, x = _inplace_arg2(env, args, "tensor-scale!")
    _tensor_inplace!("tensor-scale!", (*), t, x)
    _arg(args, 1, "tensor-scale!")
end)

builtin!(Symbol("tensor-copyto!"), (env, scope, args) -> begin
    d = _tensor_arg(args, 1, "tensor-copyto!")
    s = _tensor_arg(args, 2, "tensor-copyto!")
    src = _tensor_read(copy, s)
    data = _tensor_write(d) do dd
        size(src) == size(dd.data) || throw(AirEvalError(
            "tensor-copyto!: shapes $(size(src)) and $(size(dd.data)) differ"))
        _array_assign(dd.data, Any[COLON for _ in 1:ndims(dd.data)],
                      _array_to_form(src),
                      tv -> _tensor_read(copy, tv), "tensor-copyto!")
    end
    d.data = data
    _arg(args, 1, "tensor-copyto!")
end)

# ---- equality and comparison -------------------------------------------------

builtin!(Symbol("tensor-equal?"), (env, scope, args) -> begin
    a = _tensor_of(_arg(args, 1, "tensor-equal?"))
    b = _tensor_of(_arg(args, 2, "tensor-equal?"))
    (a === nothing || b === nothing) && return Form(false)
    return Form(_tensor_read(a, b) do x, y
        size(x) == size(y) && all(x .== y)
    end)
end)

function _bi_tensor_close(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "tensor-close?",
                   (Symbol(":atol"), Symbol(":rtol")))
    args = _call_args(env, scope, call)
    length(args) == 2 || throw(AirEvalError(
        "tensor-close? expects two tensors"))
    a = _tensor_of(args[1]); b = _tensor_of(args[2])
    (a === nothing || b === nothing) && return Form(false)
    atol = haskey(call.map, Symbol(":atol")) ?
        _num(air_reduce(env, scope, to_form(call.map[Symbol(":atol")])),
             "tensor-close? atol") : 0
    rtol = haskey(call.map, Symbol(":rtol")) ?
        _num(air_reduce(env, scope, to_form(call.map[Symbol(":rtol")])),
             "tensor-close? rtol") : sqrt(eps(Float64))
    return Form(_tensor_read(a, b) do x, y
        size(x) == size(y) &&
            isapprox(x, y; atol = atol, rtol = rtol)
    end)
end
special!(Symbol("tensor-close?"), _bi_tensor_close)

# ---- LinearAlgebra -----------------------------------------------------------

function _tensor_linalg(name::AbstractString, t::AirTensor, f::Function)
    return _tensor_read(t) do d
        r = try
            f(d)
        catch e
            e isa AirEvalError && rethrow()
            throw(AirEvalError("$name: " * sprint(showerror, e)))
        end
        if r isa Number
            to_form(AirDB._formvalue(r))
        elseif r isa AbstractArray
            _new_tensor(_canonical_data(Array(r)))
        else
            throw(AirEvalError("$name: unexpected result $(typeof(r))"))
        end
    end
end

function _linalg_arg(args, i, name, rank::Int)
    t = _tensor_arg(args, i, name)
    ndims(t.data) == rank || throw(AirEvalError(
        "$name expects a rank-$rank tensor"))
    return t
end

# `(dot a b)` — Julia's dot product; any two tensors of the same shape (the
# Frobenius inner product for matrices, conjugating the first argument).
builtin!(:dot, (env, scope, args) -> begin
    a = _tensor_arg(args, 1, "dot"); b = _tensor_arg(args, 2, "dot")
    _tensor_read(a, b) do x, y
        size(x) == size(y) || throw(AirEvalError(
            "dot: shapes $(size(x)) and $(size(y)) differ"))
        to_form(AirDB._formvalue(LinearAlgebra.dot(x, y)))
    end
end)

builtin!(:norm, (env, scope, args) -> begin
    t = _tensor_arg(args, 1, "norm")
    p = length(args) >= 2 ? _num(args[2], "norm p") : 2
    _tensor_linalg("norm", t, d -> LinearAlgebra.norm(d, p))
end)

builtin!(:tr, (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "tr", 2)
    _tensor_linalg("tr", t, d -> LinearAlgebra.tr(d))
end)

builtin!(:det, (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "det", 2)
    _tensor_linalg("det", t, d -> LinearAlgebra.det(d))
end)

builtin!(:inv, (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "inv", 2)
    _tensor_linalg("inv", t, d -> inv(d))
end)

builtin!(Symbol("matrix-rank"), (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "matrix-rank", 2)
    _tensor_linalg("matrix-rank", t, d -> LinearAlgebra.rank(d))
end)

# `(linsolve A b)` — the solution of `A x = b`.
builtin!(Symbol("linsolve"), (env, scope, args) -> begin
    a = _linalg_arg(args, 1, "linsolve", 2)
    b = _tensor_arg(args, 2, "linsolve")
    (ndims(b.data) in (1, 2)) || throw(AirEvalError(
        "linsolve needs a vector or matrix right-hand side"))
    _tensor_read(a, b) do x, y
        r = try
            x \ y
        catch e
            throw(AirEvalError("linsolve: " * sprint(showerror, e)))
        end
        _new_tensor(_canonical_data(Array(r)))
    end
end)

# `(adjoint t)` — the conjugate transpose; a vector becomes a 1×n row.
builtin!(:adjoint, (env, scope, args) -> begin
    t = _tensor_arg(args, 1, "adjoint")
    ndims(t.data) <= 2 || throw(AirEvalError("adjoint expects rank <= 2"))
    # `adjoint` is Julia's conjugate transpose; a vector becomes a 1×n row.
    _tensor_linalg("adjoint", t, adjoint)
end)

# `(reshape t dims…)` — a reshaped copy.
builtin!(:reshape, (env, scope, args) -> begin
    t = _tensor_arg(args, 1, "reshape")
    dims = Int[]
    for a in args[2:end]
        if a isa FormContainer
            append!(dims, [_as_int(_leafof(to_form(v)), "reshape")
                           for v in a.seq])
        else
            push!(dims, _as_int(_num(a, "reshape"), "reshape"))
        end
    end
    isempty(dims) && throw(AirEvalError("reshape needs dimensions"))
    _tensor_read(t) do d
        length(d) == prod(dims) || throw(AirEvalError(
            "reshape: $(length(d)) elements cannot fill $(join(dims, "×"))"))
        _new_tensor(Array(reshape(d, dims...)))
    end
end)

builtin!(Symbol("eigen"), (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "eigen", 2)
    _tensor_read(t) do d
        E = try
            LinearAlgebra.eigen(Array(d))
        catch e
            throw(AirEvalError("eigen: " * sprint(showerror, e)))
        end
        _tmap([Symbol(":values") => _new_tensor(_canonical_data(Vector(E.values))),
               Symbol(":vectors") => _new_tensor(_canonical_data(Matrix(E.vectors)))])
    end
end)

builtin!(Symbol("svd"), (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "svd", 2)
    _tensor_read(t) do d
        F = try
            LinearAlgebra.svd(Array(d))
        catch e
            throw(AirEvalError("svd: " * sprint(showerror, e)))
        end
        _tmap([Symbol(":U") => _new_tensor(_canonical_data(Matrix(F.U))),
               Symbol(":S") => _new_tensor(_canonical_data(Vector(F.S))),
               Symbol(":Vt") => _new_tensor(_canonical_data(Matrix(F.Vt)))])
    end
end)

builtin!(Symbol("qr"), (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "qr", 2)
    _tensor_read(t) do d
        F = try
            LinearAlgebra.qr(Array(d))
        catch e
            throw(AirEvalError("qr: " * sprint(showerror, e)))
        end
        _tmap([Symbol(":Q") => _new_tensor(_canonical_data(Matrix(F.Q))),
               Symbol(":R") => _new_tensor(_canonical_data(Matrix(F.R)))])
    end
end)

builtin!(Symbol("cholesky"), (env, scope, args) -> begin
    t = _linalg_arg(args, 1, "cholesky", 2)
    _tensor_read(t) do d
        F = try
            LinearAlgebra.cholesky(LinearAlgebra.Symmetric(Array(d)))
        catch e
            throw(AirEvalError("cholesky: " * sprint(showerror, e)))
        end
        _new_tensor(_canonical_data(Matrix(F.U)))
    end
end)

# ---- registration ------------------------------------------------------------

function _register_tensor!()
    air_register_extern!(:tensor, AirTensor; immutable = false)
    air_register_extern!(:reservation, AirReservation; immutable = false)
    return nothing
end
