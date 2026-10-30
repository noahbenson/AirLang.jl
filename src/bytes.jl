################################################################################
# bytes.jl
#
# `bytes`: an immutable opaque byte string. It is the air value a transferred
# file becomes (`scp`/`sftp`) and the value a file is read back from, so it must
# persist, compare by content, and never print its contents.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    AirBytes

An immutable byte string. Two `bytes` values with the same contents are
equivalent air values (`eq?` and `hash` agree), the value survives a database
write and a JSON round trip, and it prints opaquely as `#<bytes N>` so a
file-sized payload never floods a result.
"""
struct AirBytes <: AbstractAirExtern
    data::Vector{UInt8}
end

AirBytes(s::AbstractString) = AirBytes(Vector{UInt8}(codeunits(String(s))))
AirBytes(v::AbstractVector) = AirBytes(Vector{UInt8}(v))

# The registered serialization: the raw octets, nothing else.
_bytes_serialize(b::AirBytes, io::IO) = write(io, b.data)
_bytes_deserialize(io::IO) = AirBytes(read(io))

_bytes_equal(a::AirBytes, b::AirBytes) = a.data == b.data
_bytes_hash(b::AirBytes, h::UInt) = hash(b.data, hash(:AirBytes, h))

_bytes_of(x::FormExtern) = begin
    d = _extern_data(x)
    d isa AirBytes || throw(AirEvalError("expected a bytes value, got $(air_string(x))"))
    d
end

# ---- air-level surface -------------------------------------------------------

# `(bytes x)` — a string's bytes; a sequence of integers is the other spelling,
# and no argument is the empty byte string.
builtin!(:bytes, (env, scope, args) -> begin
    isempty(args) && return _extern_form(AirBytes(UInt8[]))
    x = _arg(args, 1, "bytes")
    l = _leafof(x)
    l isa AbstractString && return _extern_form(AirBytes(String(l)))
    if x isa FormContainer && isempty(x.map)
        out = UInt8[]
        for v in x.seq
            n = _leafof(to_form(v))
            (n isa Integer && 0 <= n <= 255) ||
                throw(AirEvalError("bytes: every element must be an integer 0–255, " *
                                   "got $(air_string(to_form(v)))"))
            push!(out, UInt8(n))
        end
        return _extern_form(AirBytes(out))
    end
    throw(AirEvalError("bytes expects a string or a sequence of integers, got " *
                       air_string(x)))
end)

builtin!(Symbol("bytes?"), (env, scope, args) -> begin
    x = _arg(args, 1, "bytes?")
    x isa FormExtern || return Form(false)
    d = try
        value(x)
    catch
        return Form(false)
    end
    return _bool(d isa AirBytes)
end)

builtin!(Symbol("bytes-length"), (env, scope, args) ->
    Form(length(_bytes_of(_arg(args, 1, "bytes-length")).data)))

# The raw octets as a string. Not a UTF-8 decode: a byte string is not
# necessarily text, so the string carries the bytes as they are.
builtin!(Symbol("bytes-string"), (env, scope, args) ->
    Form(String(copy(_bytes_of(_arg(args, 1, "bytes-string")).data))))

# `(bytes-index b i)` — one octet, 1-based, like every other air index.
builtin!(Symbol("bytes-index"), (env, scope, args) -> begin
    b = _bytes_of(_arg(args, 1, "bytes-index"))
    i = _leafof(_arg(args, 2, "bytes-index"))
    i isa Integer || throw(AirEvalError("bytes-index: the index must be an integer"))
    (1 <= i <= length(b.data)) ||
        throw(AirEvalError("bytes-index: index $i is out of range for a " *
                           "$(length(b.data))-byte value"))
    return Form(Int(b.data[i]))
end)

# `(bytes-slice b start [stop])` — the octets from `start` to `stop` inclusive,
# as a new bytes value. A slice past the end raises, so an off-by-one is loud.
builtin!(Symbol("bytes-slice"), (env, scope, args) -> begin
    b = _bytes_of(_arg(args, 1, "bytes-slice"))
    lo = _leafof(_arg(args, 2, "bytes-slice"))
    hi = length(args) >= 3 ? _leafof(_arg(args, 3, "bytes-slice")) : length(b.data)
    (lo isa Integer && hi isa Integer) ||
        throw(AirEvalError("bytes-slice: the bounds must be integers"))
    (1 <= lo <= hi + 1 && hi <= length(b.data)) ||
        throw(AirEvalError("bytes-slice: the range $lo:$hi is out of range for a " *
                           "$(length(b.data))-byte value"))
    return _extern_form(AirBytes(b.data[lo:hi]))
end)
