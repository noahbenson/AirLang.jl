################################################################################
# externs.jl
#
# Host-level extern types. AirDB supplies the form node (`FormExtern`, an
# `ExternHandle` wrapping the data) and the registry (`register_extern`); this
# file registers the names AirLang owns, converts an extern to and from the
# payload its printed form carries, and defines the concurrency primitives
# `promise` and `future`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    ExternExpiredError(name)

Raised when an extern's data could not be recovered — a form read back from a
database or JSON whose extern was stored without a recoverable value. It
surfaces to air as `(:extern-expired :name)`.
"""
struct ExternExpiredError <: Exception
    name::Symbol
end

"""
    air_register_extern!(name, T; immutable = true, serialize, deserialize,
                         equal, hash)

Register the extern type `T` with AirDB under `name`. AirLang declares no
read-edit operations for its types, so `immutable` stays at its default; a type
that declared any would have to pass `immutable = false`. `serialize` (with its
inverse `deserialize`) makes a value storable in a database, and `equal` (with
`hash`) gives an immutable value content equivalence; AirDB requires each pair
together, and `equal` only for an immutable type.
"""
function air_register_extern!(name::Symbol, ::Type{T};
                              immutable::Bool = true,
                              serialize::Union{Nothing,Function} = nothing,
                              deserialize::Union{Nothing,Function} = nothing,
                              equal::Union{Nothing,Function} = nothing,
                              hash::Union{Nothing,Function} = nothing) where {T<:AbstractAirExtern}
    register_extern(name, T; immutable = immutable,
                    serialize = serialize, deserialize = deserialize,
                    equal = equal, hash = hash)
    return name
end

# The registered type name of an extern form (also known for a dead extern, whose
# handle keeps only the name).
_extern_type_name(fe::FormExtern) = fe.handle.type

# The Julia data behind an extern form. A dead extern has no data; touching one
# raises an error air programs can catch.
function _extern_data(fe::FormExtern)
    data = value(fe)
    data isa DeadExtern && throw(ExternExpiredError(fe.handle.type))
    return data
end

# ---- promise -----------------------------------------------------------------

"""
    AirPromise

A value slot another task can `deliver` to; `await` blocks until it is filled.
An unresolved promise prints opaquely and does not survive persistence.
"""
mutable struct AirPromise <: AbstractAirExtern
    cond::Threads.Condition
    value::Any
    ready::Bool
    # A promise that a `future` failed on carries the exception here; `await`
    # rethrows it in the awaiting task, so a `try` around the `await` catches it
    # exactly as it would catch the body's error run inline.
    error::Any
end
AirPromise() = AirPromise(Threads.Condition(), nothing, false, nothing)

function _deliver!(p::AirPromise, v)
    lock(p.cond) do
        p.ready && throw(AirEvalError("this promise has already been delivered"))
        p.value = v
        p.ready = true
        notify(p.cond; all = true)
    end
    return v
end

# Deliver a failure: the promise becomes ready, but `await` raises instead of
# returning a value.
function _fail!(p::AirPromise, e)
    lock(p.cond) do
        p.ready && throw(AirEvalError("this promise has already been delivered"))
        p.error = e
        p.ready = true
        notify(p.cond; all = true)
    end
    return p
end

function _await_promise(p::AirPromise)
    lock(p.cond) do
        while !p.ready
            wait(p.cond)
        end
        p.error === nothing || throw(p.error)
        return p.value
    end
end

# ---- future ------------------------------------------------------------------

"""
    AirFuture

A `Task` running an air form; `await` returns its value. An unfinished future
prints opaquely and does not survive persistence.
"""
struct AirFuture <: AbstractAirExtern
    task::Task
end

_await_future(f::AirFuture) = fetch(f.task)

# ---- regex -------------------------------------------------------------------

"""
    AirRegex

A compiled regular expression: a Julia `Regex` together with the source text and
flags it was built from, wrapped as an air extern. `(regex "a+")` builds one and
`regex?` tests for one; the string verbs accept an `AirRegex` wherever they
accept a pattern and use the compiled form. It prints as
`(extern :regex ("a+" "i"))`, so it round-trips through source, and equal
source-and-flags pairs are the same air value.
"""
struct AirRegex <: AbstractAirExtern
    re::Regex
    source::String
    flags::String
end

function AirRegex(source::AbstractString, flags::AbstractString = "")
    src = String(source)
    flg = String(flags)
    re = try
        Regex(src, flg)
    catch e
        throw(AirEvalError("invalid regular expression $(repr(src))" *
                           (isempty(flg) ? "" : " with flags $(repr(flg))") *
                           ": " * sprint(showerror, e)))
    end
    return AirRegex(re, src, flg)
end

# The reader's `r"…"flags` spelling of a regex. Escaping mirrors the reader: a
# backslash is doubled only where it would otherwise be read as an escape (before
# another backslash, before a quote, or at the very end) and a quote is always
# escaped, so the printed literal reads back as exactly the same source and flags.
function _regex_literal(r::AirRegex)
    cs = collect(r.source)
    io = IOBuffer()
    print(io, "r\"")
    for (k, c) in enumerate(cs)
        if c == '"' || (c == '\\' && (k == length(cs) || cs[k + 1] in ('\\', '"')))
            print(io, '\\')
        end
        print(io, c)
    end
    print(io, '"')
    print(io, r.flags)
    return String(take!(io))
end

# ---- wrapping data as a form -------------------------------------------------

# An `AirRegex` is a value, so equal regexes must be equal air values. AirDB's
# extern equality is identity-based for unnamed handles, so regexes are interned:
# building the same source and flags twice yields the same handle. The cache is
# weak, so a pattern no live form uses is collected.
const _REGEX_HANDLES = Dict{Tuple{String,String},WeakRef}()
const _REGEX_LOCK = ReentrantLock()

function _extern_form(r::AirRegex)
    key = (r.source, r.flags)
    lock(_REGEX_LOCK)
    try
        wr = get(_REGEX_HANDLES, key, nothing)
        if wr !== nothing
            h = wr.value
            h === nothing || return FormExtern(h)
        end
        fe = to_form(r)
        _REGEX_HANDLES[key] = WeakRef(fe.handle)
        return fe
    finally
        unlock(_REGEX_LOCK)
    end
end

# Promise and future values are identities, not values: each construction is a
# distinct extern, so they are not interned.
_extern_form(x::AbstractAirExtern) = to_form(x)

# ---- printed payloads --------------------------------------------------------
#
# An extern prints as `(extern :type payload)` when its data reduces to a form,
# and opaquely otherwise. The payload functions are the inverse pair: a printed
# form reads back as the same extern.

_extern_payload(p::AirPromise) =
    (p.ready && p.error === nothing) ? p.value : nothing
_extern_payload(f::AirFuture) =
    (istaskdone(f.task) && !istaskfailed(f.task)) ? f.task.result : nothing
_extern_payload(r::AirRegex) = [r.source, r.flags]

# A form payload back to ordinary Julia data (a leaf, a Vector, or a Dict),
# mirroring AirDB's internal `_to_native`, so a provider sees the same shape from
# source as it does from the database.
_native_of(x::FormScalar) = value(x)
_native_of(x::FormExtern) = value(x)
_native_of(x::VolatileForm) = x
_native_of(x) = x
function _native_of(x::FormContainer)
    if isempty(x.map)
        return [_native_of(to_form(v)) for v in x.seq]
    elseif isempty(x.seq)
        return Dict(k => _native_of(to_form(v)) for (k, v) in x.map)
    else
        return (seq = [_native_of(to_form(v)) for v in x.seq],
                map = Dict(k => _native_of(to_form(v)) for (k, v) in x.map))
    end
end

_extern_from_payload(::Val{:promise}, payload) = begin
    p = AirPromise()
    _deliver!(p, to_form(payload))
    p
end

_extern_from_payload(::Val{:future}, payload) = begin
    t = Task(() -> payload)
    schedule(t)
    AirFuture(t)
end

function _extern_from_payload(::Val{:regex}, payload)
    parts = payload isa AbstractVector ? payload :
            payload isa Tuple ? collect(payload) : [payload]
    src = isempty(parts) ? "" : String(parts[1])
    flg = length(parts) < 2 ? "" : String(parts[2])
    return AirRegex(src, flg)
end

_extern_from_payload(::Val{name}, _) where {name} =
    throw(AirEvalError("no extern type is registered as :$name"))

# ---- registration ------------------------------------------------------------

function __init__()
    air_register_extern!(:promise, AirPromise)
    air_register_extern!(:future, AirFuture)
    air_register_extern!(:regex, AirRegex)
    # `bytes` is the one value type that persists and compares by content, so a
    # transferred file survives a database write and `eq?`/`hash` agree on it.
    air_register_extern!(:bytes, AirBytes; serialize = _bytes_serialize,
                         deserialize = _bytes_deserialize,
                         equal = _bytes_equal, hash = _bytes_hash)
    # `table` is immutable, persists through its payload, and compares by content
    # (type, NA metadata, index, and cells), so `eq?`/`hash` agree on it.
    _register_table!()
    # The loader that evaluates an air delay's captured thunk. AirDB's registry is
    # process-global and rejects a duplicate, so tolerate a re-registration.
    try
        AirDB.register_delay(_AIR_DELAY_TYPE, _air_delay_load)
    catch e
        e isa ArgumentError || rethrow()
    end
    # Resolve libssh once. When the artifact cannot load, `using AirLang` still
    # works and every `ssh-*` builtin raises a catchable `(error :ssh …)`.
    _ssh_init!()
    return nothing
end
