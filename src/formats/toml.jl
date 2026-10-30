################################################################################
# formats/toml.jl
#
# TOML for plain air data, on the standard-library parser. TOML has no null, so
# a table is a map form and an array a sequence form, but a `naught` value
# cannot be written. TOML's date, time, and date-time values become the marker
# forms `(toml-date "…")`, `(toml-time "…")`, and `(toml-datetime "…")`, which
# the writer reads back as TOML literals; no extern is involved.
#
# Julia's TOML parser rejects an offset date-time (`2026-10-30T12:30:00-08:00`)
# and drops a `Z` suffix. The reader works around it: it pre-scans the source,
# quoting each offset date-time as an opaque sentinel string, parses, and then
# restores every sentinel to a `(toml-datetime "…")` marker carrying the literal
# exactly as written. The scanner skips strings and comments, so only a bare
# value is touched.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _TOML_DATE = Symbol("toml-date")
const _TOML_TIME = Symbol("toml-time")
const _TOML_DATETIME = Symbol("toml-datetime")
const _TOML_MARKERS = Set([_TOML_DATE, _TOML_TIME, _TOML_DATETIME])

_toml_marker_form(name::Symbol, s::AbstractString) =
    _ns_form(Form[Form(name), Form(String(s))])

_data_to_form(d::Dates.Date; who::AbstractString = "toml") =
    _toml_marker_form(_TOML_DATE, string(d))
_data_to_form(t::Dates.Time; who::AbstractString = "toml") =
    _toml_marker_form(_TOML_TIME, string(t))
_data_to_form(dt::Dates.DateTime; who::AbstractString = "toml") =
    _toml_marker_form(_TOML_DATETIME, string(dt))

# A marker form and its text, or `nothing` when the value is not a marker.
function _toml_marker(v::Form)
    v isa FormContainer || return nothing
    (isempty(v.map) && length(v.seq) == 2) || return nothing
    h = head_symbol(v)
    (h isa Symbol && h in _TOML_MARKERS) || return nothing
    l = _leafof(to_form(v.seq[2]))
    l isa AbstractString || return nothing
    return (h, String(l))
end

const _TOML_MARKER_RES = Dict{Symbol,Regex}(
    _TOML_DATE => r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
    _TOML_TIME => r"^[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$",
    _TOML_DATETIME =>
        r"^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})?$",
)

# ---- reader ------------------------------------------------------------------

# A bare offset date-time: the shape the standard-library parser cannot read (or
# whose `Z` it drops).
const _TOML_OFFSET_DT_RE =
    r"\d{4}-\d{2}-\d{2}[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:[Zz]|[+-][0-9]{2}:[0-9]{2})"

# Is a bare token at `i` a TOML value position (so a date-time may begin here)?
_toml_value_start(c::Char) = c in ('=', '[', ',', '{', ' ', '\t', '\r', '\n')
_toml_value_end(c::Char) = c in (',', ']', '}', '#', ' ', '\t', '\r', '\n')

# Copy a single-line basic or literal string, returning the index after it. An
# unterminated string is copied to the end so the parser reports it.
function _toml_copy_quoted!(io::IO, s::String, i::Int, q::Char)
    n = lastindex(s)
    print(io, q)
    j = nextind(s, i)
    while j <= n
        c = s[j]
        if c == '\\' && q == '"'
            print(io, c)
            j = nextind(s, j)
            j <= n || break
            print(io, s[j])
            j = nextind(s, j)
        elseif c == q
            print(io, c)
            return nextind(s, j)
        else
            print(io, c)
            j = nextind(s, j)
        end
    end
    return nextind(s, n)
end

# Copy a triple-quoted (multiline) string, returning the index after it. A run
# of three or more quotes ends the string — the last three are the delimiter and
# any earlier ones are content.
function _toml_copy_multiline!(io::IO, s::String, i::Int, q::Char)
    n = lastindex(s)
    a = nextind(s, i)
    b = nextind(s, a)
    print(io, SubString(s, i, b))
    j = nextind(s, b)
    while j <= n
        c = s[j]
        if c == '\\' && q == '"'
            print(io, c)
            j = nextind(s, j)
            j <= n || break
            print(io, s[j])
            j = nextind(s, j)
        elseif c == q
            k = j
            run = 0
            while k <= n && s[k] == q
                run += 1
                k = nextind(s, k)
            end
            print(io, SubString(s, j, prevind(s, k)))
            run >= 3 && return k
            j = k
        else
            print(io, c)
            j = nextind(s, j)
        end
    end
    return nextind(s, n)
end

# Quote every bare offset date-time in the source as an opaque sentinel string,
# leaving strings and comments alone. Returns the rewritten text and the map
# from sentinel text to the literal it stands for.
function _toml_protect_datetimes(text::AbstractString)
    s = String(text)
    prefix = "__air_toml_offset_"
    while occursin(prefix, s)
        prefix = "_" * prefix
    end
    sentinels = Dict{String,String}()
    io = IOBuffer()
    i = firstindex(s)
    n = lastindex(s)
    k = 0
    while i <= n
        c = s[i]
        if c == '#'
            j = findnext(==('\n'), s, i)
            print(io, SubString(s, i, j === nothing ? n : prevind(s, j)))
            i = j === nothing ? nextind(s, n) : j
        elseif c == '"' || c == '\''
            a = nextind(s, i)
            if a <= n && s[a] == c && nextind(s, a) <= n && s[nextind(s, a)] == c
                i = _toml_copy_multiline!(io, s, i, c)
            else
                i = _toml_copy_quoted!(io, s, i, c)
            end
        else
            m = match(_TOML_OFFSET_DT_RE, SubString(s, i))
            if m !== nothing && m.offset == 1 &&
               (i == firstindex(s) || _toml_value_start(s[prevind(s, i)]))
                j = nextind(s, i, length(m.match))
                if j > n || _toml_value_end(s[j])
                    key = prefix * string(k) * "__"
                    k += 1
                    sentinels[key] = String(m.match)
                    print(io, '"', key, '"')
                    i = j
                    continue
                end
            end
            print(io, c)
            i = nextind(s, i)
        end
    end
    return String(take!(io)), sentinels
end

# Replace every sentinel string in the parsed form with its marker form.
function _toml_restore(x::Form, sentinels::Dict{String,String})
    if x isa FormContainer
        seq = FormValue[_store_form(_toml_restore(to_form(v), sentinels)) for v in x.seq]
        map = Pair{Symbol,FormValue}[
            key => _store_form(_toml_restore(to_form(v), sentinels)) for (key, v) in x.map]
        return canonicalize(FormContainer(FormSeq(seq), FormMap(map)))
    end
    l = _leafof(x)
    if l isa AbstractString && haskey(sentinels, l)
        return _toml_marker_form(_TOML_DATETIME, sentinels[l])
    end
    return x
end

"""
    _toml_decode(text) -> Form

Parse a TOML document into air data.
"""
function _toml_decode(text::AbstractString)
    protected, sentinels = _toml_protect_datetimes(text)
    data = try
        TOML.parse(protected)
    catch e
        throw(AirEvalError("invalid TOML: " * sprint(showerror, e)))
    end
    v = _data_to_form(data; who = "toml")
    isempty(sentinels) && return v
    return _toml_restore(v, sentinels)
end

# ---- writer ------------------------------------------------------------------

"""
    _toml_encode(v) -> String

Encode air data as TOML. The top level must be a map form (or `naught`, which
is the empty document); keys are emitted in sorted order, and nested maps become
`[table]` sections. An array is written inline, with a map element as an inline
table, so any shape round-trips.
"""
function _toml_encode(v::Form)
    kind, x = _data_shape(v, "encode")
    kind === :null && return ""
    kind === :object || throw(AirEvalError(
        "encode: TOML needs a mapping at the top level, got " * air_string(v)))
    io = IOBuffer()
    _toml_table!(io, String[], x)
    return String(take!(io))
end

function _toml_table!(io::IO, path::Vector{String}, obj::FormContainer)
    pairs = _map_pairs(obj)
    # Scalar and array entries first; a table header then claims every following
    # key, so the tables come after.
    for (k, e) in pairs
        _data_shape(e, "encode")[1] === :object && continue
        print(io, _toml_key(k), " = ", _toml_value(e), "\n")
    end
    for (k, e) in pairs
        kind, x = _data_shape(e, "encode")
        kind === :object || continue
        sub = String[path..., k]
        print(io, "\n[", join((_toml_key(s) for s in sub), "."), "]\n")
        _toml_table!(io, sub, x)
    end
    return nothing
end

function _toml_value(v::Form)
    m = _toml_marker(v)
    m !== nothing && return _toml_marker_text(m)
    kind, x = _data_shape(v, "encode")
    if kind === :null
        throw(AirEvalError("encode: TOML has no null, so " * air_string(v) *
                           " cannot be encoded"))
    elseif kind === :leaf
        return _toml_leaf(_leaf_data(x, "encode")...)
    elseif kind === :array
        return "[" * join((_toml_value(e) for e in _seq_elems(x)), ", ") * "]"
    end
    return "{" * join((_toml_key(k) * " = " * _toml_value(e)
                       for (k, e) in _map_pairs(x)), ", ") * "}"
end

function _toml_marker_text((name, s)::Tuple{Symbol,String})
    occursin(_TOML_MARKER_RES[name], s) ||
        throw(AirEvalError("encode: $(string(name)) does not hold a valid TOML " *
                           "literal: $(repr(s))"))
    return s
end

function _toml_leaf(kind::Symbol, x)
    kind === :null && throw(AirEvalError("encode: TOML has no null value"))
    kind === :bool && return x ? "true" : "false"
    if kind === :int
        (typemin(Int64) <= x <= typemax(Int64)) || throw(AirEvalError(
            "encode: TOML integers are 64-bit, so $x cannot be encoded"))
        return string(x)
    elseif kind === :float
        isnan(x) && return "nan"
        isinf(x) && return x < 0 ? "-inf" : "inf"
        s = string(x)
        (occursin('.', s) || occursin('e', s) || occursin('E', s)) || (s *= ".0")
        return s
    end
    return _toml_string(String(x))
end

function _toml_string(s::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\f'
            print(io, "\\f")
        elseif c == '\r'
            print(io, "\\r")
        elseif c < ' ' || c == '\x7f'
            print(io, "\\u", lpad(string(UInt32(c); base = 16), 4, '0'))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end

_toml_key(k::AbstractString) =
    occursin(r"^[A-Za-z0-9_-]+$", k) ? String(k) : _toml_string(k)
