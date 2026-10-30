################################################################################
# formats/json.jl
#
# A standard JSON (RFC 8259) reader and writer for plain air data. This is
# deliberately *not* AirDB's codec: `to-json`/`from-json` write database links
# and extern references, while these converters carry data only. An object is a
# map form, an array a sequence form, and null — like an empty object or an
# empty array — is `naught`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _JSON_MAX_DEPTH = 512

mutable struct _JsonParser
    b::Vector{UInt8}
    i::Int
    depth::Int
end

_json_error(p::_JsonParser, msg::AbstractString) =
    throw(AirEvalError("invalid JSON at character $(p.i): $msg"))

function _json_skip_ws!(p::_JsonParser)
    while p.i <= length(p.b)
        c = p.b[p.i]
        (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d) || break
        p.i += 1
    end
    return nothing
end

"""
    _json_decode(text) -> Form

Parse a JSON document into air data.
"""
function _json_decode(text::AbstractString)
    p = _JsonParser(Vector{UInt8}(codeunits(String(text))), 1, 0)
    _json_skip_ws!(p)
    x = _json_value!(p)
    _json_skip_ws!(p)
    p.i <= length(p.b) && _json_error(p, "unexpected content after the document")
    return _data_to_form(x; who = "json")
end

function _json_value!(p::_JsonParser)
    p.depth += 1
    p.depth > _JSON_MAX_DEPTH && _json_error(p, "the document is nested too deeply")
    try
        p.i > length(p.b) && _json_error(p, "expected a value")
        c = p.b[p.i]
        c == 0x7b && return _json_object!(p)          # {
        c == 0x5b && return _json_array!(p)           # [
        c == 0x22 && return _json_string!(p)          # "
        c == 0x74 && return _json_literal!(p, "true", true)
        c == 0x66 && return _json_literal!(p, "false", false)
        c == 0x6e && return _json_literal!(p, "null", nothing)
        (c == 0x2d || (0x30 <= c <= 0x39)) && return _json_number!(p)
        return _json_error(p, "unexpected $(repr(Char(c)))")
    finally
        p.depth -= 1
    end
end

function _json_literal!(p::_JsonParser, word::AbstractString, v)
    w = Vector{UInt8}(codeunits(word))
    p.i + length(w) - 1 <= length(p.b) &&
        p.b[p.i:(p.i + length(w) - 1)] == w || _json_error(p, "expected $word")
    p.i += length(w)
    return v
end

function _json_object!(p::_JsonParser)
    p.i += 1                                       # {
    out = Dict{String,Any}()
    _json_skip_ws!(p)
    if p.i <= length(p.b) && p.b[p.i] == 0x7d       # }
        p.i += 1
        return out
    end
    while true
        _json_skip_ws!(p)
        (p.i <= length(p.b) && p.b[p.i] == 0x22) ||
            _json_error(p, "expected a string key")
        k = _json_string!(p)
        haskey(out, k) && _json_error(p, "duplicate key $(repr(k))")
        _json_skip_ws!(p)
        (p.i <= length(p.b) && p.b[p.i] == 0x3a) || _json_error(p, "expected ':'")
        p.i += 1
        _json_skip_ws!(p)
        out[k] = _json_value!(p)
        _json_skip_ws!(p)
        p.i > length(p.b) && _json_error(p, "unterminated object")
        c = p.b[p.i]; p.i += 1
        c == 0x2c && continue                      # ,
        c == 0x7d && break                         # }
        _json_error(p, "expected ',' or '}'")
    end
    return out
end

function _json_array!(p::_JsonParser)
    p.i += 1                                       # [
    out = Any[]
    _json_skip_ws!(p)
    if p.i <= length(p.b) && p.b[p.i] == 0x5d       # ]
        p.i += 1
        return out
    end
    while true
        _json_skip_ws!(p)
        push!(out, _json_value!(p))
        _json_skip_ws!(p)
        p.i > length(p.b) && _json_error(p, "unterminated array")
        c = p.b[p.i]; p.i += 1
        c == 0x2c && continue                      # ,
        c == 0x5d && break                         # ]
        _json_error(p, "expected ',' or ']'")
    end
    return out
end

# ---- strings -----------------------------------------------------------------

function _json_string!(p::_JsonParser)
    p.i += 1                                       # opening quote
    out = UInt8[]
    while true
        p.i > length(p.b) && _json_error(p, "unterminated string")
        c = p.b[p.i]; p.i += 1
        if c == 0x22
            return String(out)
        elseif c == 0x5c                           # backslash
            p.i > length(p.b) && _json_error(p, "unterminated escape")
            e = p.b[p.i]; p.i += 1
            if e == 0x22;     push!(out, 0x22)
            elseif e == 0x5c; push!(out, 0x5c)
            elseif e == 0x2f; push!(out, 0x2f)
            elseif e == 0x62; push!(out, 0x08)
            elseif e == 0x66; push!(out, 0x0c)
            elseif e == 0x6e; push!(out, 0x0a)
            elseif e == 0x72; push!(out, 0x0d)
            elseif e == 0x74; push!(out, 0x09)
            elseif e == 0x75
                cp = _json_hex4!(p)
                if 0xd800 <= cp <= 0xdbff
                    # A high surrogate must pair with a following low surrogate.
                    (p.i + 1 <= length(p.b) && p.b[p.i] == 0x5c &&
                     p.b[p.i + 1] == 0x75) ||
                        _json_error(p, "an unpaired surrogate escape")
                    p.i += 2
                    lo = _json_hex4!(p)
                    (0xdc00 <= lo <= 0xdfff) ||
                        _json_error(p, "an unpaired surrogate escape")
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00)
                elseif 0xdc00 <= cp <= 0xdfff
                    _json_error(p, "an unpaired surrogate escape")
                end
                _utf8_push!(out, cp)
            else
                _json_error(p, "unknown escape \\$(Char(e))")
            end
        elseif c < 0x20
            _json_error(p, "an unescaped control character in a string")
        else
            push!(out, c)                          # UTF-8 bytes pass through
        end
    end
end

function _json_hex4!(p::_JsonParser)
    p.i + 3 <= length(p.b) || _json_error(p, "a truncated \\u escape")
    v = 0
    for _ in 1:4
        c = p.b[p.i]; p.i += 1
        d = 0x30 <= c <= 0x39 ? Int(c - 0x30) :
            0x41 <= c <= 0x46 ? Int(c - 0x41 + 10) :
            0x61 <= c <= 0x66 ? Int(c - 0x61 + 10) :
            _json_error(p, "a bad \\u escape")
        v = (v << 4) | d
    end
    return v
end

function _utf8_push!(out::Vector{UInt8}, cp::Integer)
    if cp < 0x80
        push!(out, UInt8(cp))
    elseif cp < 0x800
        push!(out, UInt8(0xc0 | (cp >> 6)), UInt8(0x80 | (cp & 0x3f)))
    elseif cp < 0x10000
        push!(out, UInt8(0xe0 | (cp >> 12)), UInt8(0x80 | ((cp >> 6) & 0x3f)),
              UInt8(0x80 | (cp & 0x3f)))
    else
        push!(out, UInt8(0xf0 | (cp >> 18)), UInt8(0x80 | ((cp >> 12) & 0x3f)),
              UInt8(0x80 | ((cp >> 6) & 0x3f)), UInt8(0x80 | (cp & 0x3f)))
    end
    return nothing
end

# ---- numbers -----------------------------------------------------------------

const _JSON_NUMBER_RE =
    r"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$"

function _json_number!(p::_JsonParser)
    start = p.i
    while p.i <= length(p.b)
        c = p.b[p.i]
        (0x30 <= c <= 0x39 || c in (0x2d, 0x2b, 0x2e, 0x65, 0x45)) || break
        p.i += 1
    end
    s = String(p.b[start:(p.i - 1)])
    occursin(_JSON_NUMBER_RE, s) || _json_error(p, "bad number $(repr(s))")
    (occursin('.', s) || occursin('e', s) || occursin('E', s)) &&
        return parse(Float64, s)
    i = tryparse(Int64, s)
    return i === nothing ? parse(BigInt, s) : i
end

# ---- writer ------------------------------------------------------------------

"""
    _json_encode(v) -> String

Encode air data as standard JSON. Keys are emitted in sorted order, so the
output is deterministic.
"""
function _json_encode(v::Form)
    io = IOBuffer()
    _json_write!(io, v)
    return String(take!(io))
end

function _json_write!(io::IO, v::Form)
    kind, x = _data_shape(v, "encode")
    if kind === :null
        print(io, "null")
    elseif kind === :leaf
        _json_write_leaf!(io, _leaf_data(x, "encode")...)
    elseif kind === :array
        print(io, "[")
        sep = ""
        for e in _seq_elems(x)
            print(io, sep); sep = ","
            _json_write!(io, e)
        end
        print(io, "]")
    else
        print(io, "{")
        sep = ""
        for (k, e) in _map_pairs(x)
            print(io, sep); sep = ","
            _json_write_string!(io, k)
            print(io, ":")
            _json_write!(io, e)
        end
        print(io, "}")
    end
    return nothing
end

function _json_write_leaf!(io::IO, kind::Symbol, x)
    if kind === :null
        print(io, "null")
    elseif kind === :bool
        print(io, x ? "true" : "false")
    elseif kind === :int
        print(io, x)
    elseif kind === :float
        isfinite(x) || throw(AirEvalError(
            "encode: JSON cannot represent the non-finite number $x"))
        print(io, x)
    else
        _json_write_string!(io, x)
    end
    return nothing
end

function _json_write_string!(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\f'
            print(io, "\\f")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c < ' '
            print(io, "\\u", lpad(string(UInt16(c); base = 16), 4, '0'))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return nothing
end
