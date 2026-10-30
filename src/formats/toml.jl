################################################################################
# formats/toml.jl
#
# TOML for plain air data, on the standard-library parser. TOML has no null, so
# a table is a map form and an array a sequence form, but a `naught` value
# cannot be written. TOML's date, time, and date-time values become the marker
# forms `(toml-date "…")`, `(toml-time "…")`, and `(toml-datetime "…")`, which
# the writer reads back as TOML literals; no extern is involved.
#
# Julia's TOML parser does not accept an offset date-time, and it drops a `Z`
# suffix's timezone, so the writer emits what the marker holds but the reader
# sees the offset only when the parser keeps it. That is a limitation of the
# standard library, not of this reader.
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

"""
    _toml_decode(text) -> Form

Parse a TOML document into air data.
"""
function _toml_decode(text::AbstractString)
    data = try
        TOML.parse(String(text))
    catch e
        throw(AirEvalError("invalid TOML: " * sprint(showerror, e)))
    end
    return _data_to_form(data; who = "toml")
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
