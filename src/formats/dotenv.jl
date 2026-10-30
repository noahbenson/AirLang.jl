################################################################################
# formats/dotenv.jl
#
# `.env` files: `KEY=value` lines, comments, an optional `export` prefix, and
# single- or double-quoted values. A `.env` file has only strings, so decoding
# produces a map of string values and an empty value stays `""` — `naught` has
# no `.env` spelling.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _DOTENV_KEY_RE = r"^[A-Za-z_][A-Za-z0-9_.-]*$"

# ---- reader ------------------------------------------------------------------

"""
    _dotenv_decode(text) -> Form

Parse a `.env` file into a map form of string values.
"""
function _dotenv_decode(text::AbstractString)
    pairs = Pair{String,Form}[]
    seen = Set{String}()
    lines = split(replace(String(text), "\r\n" => "\n", "\r" => "\n"), '\n')
    for (n, raw) in enumerate(lines)
        l = strip(raw, [' ', '\t'])
        (isempty(l) || startswith(l, "#")) && continue
        if startswith(l, "export ") || startswith(l, "export\t")
            l = lstrip(l[8:end], [' ', '\t'])
        end
        eq = findfirst('=', l)
        eq === nothing && throw(AirEvalError(
            "invalid .env at line $n: expected KEY=value"))
        key = String(strip(l[1:(eq - 1)], [' ', '\t']))
        occursin(_DOTENV_KEY_RE, key) || throw(AirEvalError(
            "invalid .env at line $n: $(repr(key)) is not a valid key"))
        key in seen && throw(AirEvalError(
            "invalid .env at line $n: duplicate key $(repr(key))"))
        push!(seen, key)
        push!(pairs, key => Form(_dotenv_value_text(l[(eq + 1):end], n)))
    end
    return _map_form(pairs, "env")
end

function _dotenv_value_text(s::AbstractString, n::Integer)
    cs = collect(s)
    i = 1
    while i <= length(cs) && cs[i] in (' ', '\t')
        i += 1
    end
    i > length(cs) && return ""
    if cs[i] == '"'
        out = Char[]
        i += 1
        while i <= length(cs)
            c = cs[i]
            if c == '"'
                i += 1
                break
            elseif c == '\\' && i + 1 <= length(cs)
                e = cs[i + 1]
                i += 2
                if e == 'n'
                    push!(out, '\n')
                elseif e == 'r'
                    push!(out, '\r')
                elseif e == 't'
                    push!(out, '\t')
                elseif e == '0'
                    push!(out, '\0')
                elseif e == '"'
                    push!(out, '"')
                elseif e == '\\'
                    push!(out, '\\')
                else
                    push!(out, '\\')       # an unknown escape stays literal
                    push!(out, e)
                end
            else
                push!(out, c)
                i += 1
            end
        end
        _dotenv_tail_ok(cs, i, n)
        return String(out)
    elseif cs[i] == '\''
        out = Char[]
        i += 1
        closed = false
        while i <= length(cs)
            c = cs[i]
            if c == '\''
                i += 1
                closed = true
                break
            end
            push!(out, c)
            i += 1
        end
        closed || throw(AirEvalError(
            "invalid .env at line $n: an unterminated single-quoted value"))
        _dotenv_tail_ok(cs, i, n)
        return String(out)
    end
    for j in i:length(cs)
        if cs[j] == '#' && (j == i || cs[j - 1] in (' ', '\t'))
            return rstrip(String(cs[i:(j - 1)]))
        end
    end
    return rstrip(String(cs[i:end]))
end

# After a closing quote only whitespace or a comment may follow.
function _dotenv_tail_ok(cs::Vector{Char}, i::Integer, n::Integer)
    while i <= length(cs) && cs[i] in (' ', '\t')
        i += 1
    end
    (i > length(cs) || cs[i] == '#') ||
        throw(AirEvalError("invalid .env at line $n: unexpected text after a " *
                           "quoted value"))
    return nothing
end

# ---- writer ------------------------------------------------------------------

"""
    _dotenv_encode(v) -> String

Encode air data as a `.env` file. The top level must be a map form (or
`naught`, which is the empty file); values must be scalars, written as text. A
`naught` value is written as an empty value, the only spelling `.env` has.
"""
function _dotenv_encode(v::Form)
    kind, x = _data_shape(v, "encode")
    kind === :null && return ""
    kind === :object || throw(AirEvalError(
        "encode: .env needs a mapping at the top level, got " * air_string(v)))
    io = IOBuffer()
    for (k, e) in _map_pairs(x)
        occursin(_DOTENV_KEY_RE, k) || throw(AirEvalError(
            "encode: $(repr(k)) is not a valid .env key"))
        ek, ex = _data_shape(e, "encode")
        text = if ek === :null
            ""
        elseif ek === :leaf
            lk, lx = _leaf_data(ex, "encode")
            lk === :null ? "" : _dotenv_scalar_text(lk, lx)
        else
            throw(AirEvalError(
                "encode: .env values are strings, so " * air_string(e) *
                " cannot be encoded"))
        end
        print(io, k, "=", _dotenv_quote(text), "\n")
    end
    return String(take!(io))
end

function _dotenv_scalar_text(kind::Symbol, x)
    kind === :null && return ""
    kind === :bool && return x ? "true" : "false"
    kind === :int && return string(x)
    kind === :float && return string(x)
    return String(x)
end

function _dotenv_quote(s::AbstractString)
    isempty(s) && return ""
    needs = s != strip(s) || any(c -> c in (' ', '\t', '\n', '\r', '"', '\'',
                                            '\\', '#', '=', '\0'), s)
    needs || return String(s)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\0'
            print(io, "\\0")
        else
            print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end
