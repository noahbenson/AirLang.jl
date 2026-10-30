################################################################################
# formats/common.jl
#
# Shared machinery for the data formats: format-name normalization, input
# decoding, the conversion between plain Julia data and air forms, and the air
# surface (`decode`, `encode`, `read-data`, `write-data`).
#
# The formats are *plain data* converters, deliberately independent of AirDB's
# JSON codec (`to-json`/`from-json`, which writes links and extern references).
# A JSON object becomes a map form, an array a sequence form, and null — like an
# empty object or an empty array — becomes `naught`. Nothing here constructs an
# extern or executes anything in a file.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- format names ------------------------------------------------------------

const _FORMAT_ALIASES = Dict{String,Symbol}(
    "json" => :json,
    "yaml" => :yaml,
    "yml" => :yaml,
    "toml" => :toml,
    "csv" => :csv,
    "tsv" => :tsv,
    "env" => :env,
    "dotenv" => :env,
)

const _FORMAT_LIST = "json, yaml, toml, csv, tsv, or env"

# Air map keys are symbols that *begin* with a colon (`Symbol(":format")`), not
# Julia keyword literals (which have no colon).
const _FORMAT_KEY = Symbol(":format")
const _DOCUMENTS_KEY = Symbol(":documents")
const _HEADER_KEY = Symbol(":header")
const _COLUMN_DELIMITER_KEY = Symbol(":column-delimiter")
const _ROW_DELIMITER_KEY = Symbol(":row-delimiter")

# Every option the data verbs accept; a format accepts the subset it understands.
const _DATA_OPTION_KEYS = (_FORMAT_KEY, _DOCUMENTS_KEY, _HEADER_KEY,
                           _COLUMN_DELIMITER_KEY, _ROW_DELIMITER_KEY,
                           _TABLE_TYPES_KEY, _TABLE_NA_KEY,
                           _TABLE_COLUMNS_KEY, _TABLE_INDEX_KEY)

"""
    _format_name(x, who) -> Symbol

The canonical format name a form denotes: `:json`, `:yaml`, `:toml`, `:csv`,
`:tsv`, or `:env`. A keyword, a symbol, or a string is accepted; `yml` and
`dotenv` are aliases.
"""
function _format_name(x::Form, who::AbstractString)
    l = _leafof(x)
    s = l isa Symbol ? String(l) :
        l isa AbstractString ? String(l) :
        throw(AirEvalError("$who: the format must be a keyword or string, got " *
                           air_string(x)))
    startswith(s, ":") && (s = s[2:end])
    fmt = get(_FORMAT_ALIASES, lowercase(s), nothing)
    fmt === nothing && throw(AirEvalError(
        "$who: unknown format $(repr(s)); expected $(_FORMAT_LIST)"))
    return fmt
end

"""
    _format_for_path(path, who) -> Symbol

Infer a format from a file name: the extension (`.json`, `.yaml`/`.yml`, `.toml`,
`.env`) or the name `.env`.
"""
function _format_for_path(path::AbstractString, who::AbstractString)
    base = basename(path)
    base == ".env" && return :env
    ext = lowercase(splitext(base)[2])
    startswith(ext, ".") && (ext = ext[2:end])
    fmt = get(_FORMAT_ALIASES, ext, nothing)
    fmt === nothing && throw(AirEvalError(
        "$who: cannot infer a format from $(repr(path)); pass format=…"))
    return fmt
end

# ---- input -------------------------------------------------------------------

# A leading byte-order mark is not part of the data.
_strip_bom(s::String) =
    startswith(s, "﻿") ? SubString(s, nextind(s, 1)) : s

"""
    _decode_input(x, who) -> String

The text a `decode` argument carries: a string as it is, or a `bytes` value
reinterpreted as UTF-8 (which must be valid). A leading byte-order mark is
dropped.
"""
function _decode_input(x::Form, who::AbstractString)
    l = _leafof(x)
    l isa AbstractString && return _strip_bom(String(l))
    if x isa FormExtern
        d = try
            value(x)
        catch
            nothing
        end
        if d isa AirBytes
            isvalid(String, d.data) ||
                throw(AirEvalError("$who: the bytes are not valid UTF-8"))
            return _strip_bom(String(copy(d.data)))
        end
    end
    throw(AirEvalError("$who expects a string or bytes value, got " * air_string(x)))
end

# ---- plain data -> forms -----------------------------------------------------

"""
    _data_to_form(x; who="data") -> Form

Convert parsed plain data to an air form: a dictionary to a map form (keys
normalized to keywords), a vector to a sequence form, `nothing` to `naught`, and
a scalar to itself. A format module extends this for its own scalar types (TOML's
date and time values become the marker forms `(toml-date …)` and friends).
"""
function _data_to_form(x; who::AbstractString = "data")
    return _scalar_data_form(x, who)
end

_scalar_data_form(::Nothing, who) = naught
_scalar_data_form(x::Bool, who) = Form(x)
_scalar_data_form(x::Integer, who) = Form(x isa Int64 ? x : BigInt(x))
_scalar_data_form(x::AbstractFloat, who) = Form(Float64(x))
_scalar_data_form(x::AbstractString, who) = Form(String(x))
_scalar_data_form(x, who) = throw(AirEvalError(
    "$who: cannot represent a $(typeof(x)) value as air data"))

function _data_to_form(x::AbstractVector; who::AbstractString = "data")
    return _seq_form(Form[_data_to_form(v; who = who) for v in x])
end

function _data_to_form(x::AbstractDict; who::AbstractString = "data")
    pairs = Pair{String,Form}[]
    for (k, v) in x
        push!(pairs, _data_key_text(k, who) => _data_to_form(v; who = who))
    end
    return _map_form(pairs, who)
end

# A mapping key as text. The parsers accept scalar keys and normalize them to
# their text, so a YAML `1: x` and a JSON `"1": x` name the same air key.
function _data_key_text(k, who::AbstractString)
    k isa AbstractString && return String(k)
    k isa Symbol && return _symbol_text(k)
    k isa Integer && return string(k)
    k isa AbstractFloat && return string(k)
    k isa Bool && return k ? "true" : "false"
    throw(AirEvalError("$who: a mapping key must be a scalar, got $(typeof(k))"))
end

# A map key normalized to air's keyword convention: the leading ':' is added
# (unless the key already spells one). Two keys that normalize alike are a
# duplicate, so the collision is loud rather than silent.
_data_key(k::AbstractString) =
    Symbol(":" * (startswith(k, ":") ? k[2:end] : k))

_symbol_text(s::Symbol) = (t = String(s); startswith(t, ":") ? t[2:end] : t)

# A sequence form; an empty one is `naught`.
_seq_form(xs::Vector{Form}) = _ns_form(xs)

# A map form from key text and value forms, rejecting a duplicate key.
function _map_form(pairs::Vector{Pair{String,Form}}, who::AbstractString)
    seen = Set{Symbol}()
    out = Pair{Symbol,Form}[]
    for (k, v) in pairs
        sym = _data_key(k)
        sym in seen && throw(AirEvalError("$who: duplicate key $(repr(k))"))
        push!(seen, sym)
        push!(out, sym => v)
    end
    return _ns_form(Form[], out)
end

# ---- forms -> plain data -----------------------------------------------------

"""
    _data_shape(v, who) -> (Symbol, Any)

The data shape of a form: `(:null, nothing)`, `(:leaf, leaf)`, `(:array, form)`,
or `(:object, form)`. A container with both sequence elements and map entries
has no representation in any of the formats and raises; so does anything that is
not plain immutable data (an extern, a mutable, a reference form).
"""
function _data_shape(v::Form, who::AbstractString)
    # A table has the plain-data shape of its rows: an array of row objects.
    t = _table_of(v)
    t === nothing || return (:array, _rows_form(t))
    if v isa FormContainer
        (isempty(v.seq) && isempty(v.map)) && return (:null, nothing)
        if isempty(v.map)
            return (:array, v)
        elseif isempty(v.seq)
            return (:object, v)
        end
        throw(AirEvalError("$who: $(air_string(v)) has both sequence elements and " *
                           "map entries, so it is not plain data"))
    elseif v isa FormScalar
        # `naught` is a scalar holding `nothing`; it is a null, not a leaf.
        x = value(v)
        return x === nothing ? (:null, nothing) : (:leaf, x)
    end
    throw(AirEvalError("$who: $(air_string(v)) is not plain immutable data"))
end

"""
    _leaf_data(l, who) -> (Symbol, Any)

Classify a leaf as `(:null, nothing)`, `(:bool, b)`, `(:int, i)`, `(:float, f)`,
or `(:string, s)`. A keyword or symbol encodes as its text (the leading `:` is
dropped); a rational, a complex number, or any other leaf raises, because no
format can carry it without ambiguity.
"""
function _leaf_data(l, who::AbstractString)
    l === nothing && return (:null, nothing)
    l isa Bool && return (:bool, l)
    l isa Integer && return (:int, l)
    l isa AbstractFloat && return (:float, l)
    l isa AbstractString && return (:string, String(l))
    l isa Symbol && return (:string, _symbol_text(l))
    throw(AirEvalError("$who: the value $(repr(l)) has no data representation"))
end

# The sequence elements of an array-shaped form, as forms.
_seq_elems(c::FormContainer) = Form[to_form(v) for v in c.seq]

# The (key text, value form) pairs of an object-shaped form, sorted by key so
# every emitter is deterministic.
function _map_pairs(c::FormContainer)
    ks = sort!(collect(keys(c.map)); by = String)
    return Pair{String,Form}[_keyword_text(k) => to_form(c.map[k]) for k in ks]
end

# ---- options -----------------------------------------------------------------

# The reduced value of a call's map option, or `nothing` when absent.
function _call_option(env::Env, scope::Scope, call::FormContainer,
                      key::AbstractString, who::AbstractString)
    k = Symbol(":", key)
    haskey(call.map, k) || return nothing
    return air_reduce(env, scope, to_form(call.map[k]))
end

function _format_option(env::Env, scope::Scope, call::FormContainer,
                        who::AbstractString, default::Symbol)
    v = _call_option(env, scope, call, "format", who)
    return v === nothing ? default : _format_name(v, who)
end

# Every data-format option, parsed once. `header` is `nothing` (infer), `true`,
# `false`, or a vector of explicit labels; `types` maps a column to its type and
# `na` a column to its missing-marker value; `columns` and `index` name columns.
# `given` records which options the call actually carried, so a format can
# reject one it does not understand.
struct _DataOptions
    documents::Bool
    header::Any
    column_delimiter::Union{Nothing,String}
    row_delimiter::Union{Nothing,String}
    types::Dict{Symbol,Symbol}
    na::Dict{Symbol,Any}
    columns::Union{Nothing,Vector{Symbol}}
    index::Union{Nothing,Symbol}
    given::Set{Symbol}
end

function _data_delimiter(env::Env, scope::Scope, call::FormContainer,
                         key::Symbol, who::AbstractString)
    v = _call_option(env, scope, call, String(key)[2:end], who)
    v === nothing && return nothing
    l = _leafof(v)
    l isa AbstractString || throw(AirEvalError(
        "$who: $(String(key)[2:end]) must be a string, got " * air_string(v)))
    return String(l)
end

function _data_header(env::Env, scope::Scope, call::FormContainer,
                      who::AbstractString)
    haskey(call.map, _HEADER_KEY) || return nothing
    h = _call_option(env, scope, call, "header", who)
    isequal(h, Form(true)) && return true
    isequal(h, Form(false)) && return false
    (h isa FormContainer && isempty(h.map)) || throw(AirEvalError(
        "$who: header= must be true, false, or a sequence of column names"))
    labels = String[]
    for v in h.seq
        l = _leafof(to_form(v))
        l isa Symbol && (push!(labels, _symbol_text(l)); continue)
        l isa AbstractString && (push!(labels, String(l)); continue)
        throw(AirEvalError(
            "$who: a header name must be a keyword, symbol, or string, got " *
            air_string(to_form(v))))
    end
    return labels
end

function _data_options(env::Env, scope::Scope, call::FormContainer,
                       who::AbstractString)
    given = Set{Symbol}(k for k in keys(call.map) if k !== _FORMAT_KEY)
    docs = haskey(call.map, _DOCUMENTS_KEY) &&
        truthy(_call_option(env, scope, call, "documents", who))
    types = Dict{Symbol,Symbol}()
    if haskey(call.map, _TABLE_TYPES_KEY)
        tf = _call_option(env, scope, call, "types", who)
        (tf isa FormContainer && isempty(tf.seq)) || throw(AirEvalError(
            "$who: types= must be a mapping of column names to types"))
        for (k, v) in tf.map
            types[k] = _table_type_of(to_form(v), "$who types")
        end
    end
    nas = Dict{Symbol,Any}()
    if haskey(call.map, _TABLE_NA_KEY)
        nf = _call_option(env, scope, call, "na", who)
        (nf isa FormContainer && isempty(nf.seq)) || throw(AirEvalError(
            "$who: na= must be a mapping of column names to markers"))
        for (k, v) in nf.map
            x = to_form(v)
            x isa FormScalar || throw(AirEvalError(
                "$who: the NA marker for $(_colname(k)) must be a scalar value"))
            nas[k] = value(x)
        end
    end
    cols = nothing
    if haskey(call.map, _TABLE_COLUMNS_KEY)
        cf = _call_option(env, scope, call, "columns", who)
        (cf isa FormContainer && isempty(cf.map)) || throw(AirEvalError(
            "$who: columns= must be a sequence of column names"))
        cols = Symbol[_table_name_of(to_form(v), "$who columns") for v in cf.seq]
    end
    index = nothing
    if haskey(call.map, _TABLE_INDEX_KEY)
        index = _table_name_of(_call_option(env, scope, call, "index", who),
                               "$who index")
    end
    return _DataOptions(docs, _data_header(env, scope, call, who),
                        _data_delimiter(env, scope, call, _COLUMN_DELIMITER_KEY, who),
                        _data_delimiter(env, scope, call, _ROW_DELIMITER_KEY, who),
                        types, nas, cols, index, given)
end

# Reject an option the chosen format does not understand. `documents` keeps its
# own message ("only meaningful for yaml") because it predates the table options.
function _reject_options(opts::_DataOptions, who::AbstractString, fmt::Symbol,
                         allowed)
    for k in opts.given
        k in allowed && continue
        k === _FORMAT_KEY && continue
        # `documents=false` is the default, so it is never an error.
        if k === _DOCUMENTS_KEY
            opts.documents || continue
            throw(AirEvalError("$who: documents=true is only meaningful for yaml"))
        end
        throw(AirEvalError(
            "$who: the $(String(k)[2:end]) option is only meaningful for csv or tsv"))
    end
    return nothing
end

_check_arity(call::FormContainer, name::AbstractString, n::Integer) =
    length(call.seq) == n + 1 ||
    throw(AirEvalError("$name takes $(n == 1 ? "one argument" :
                       "$n arguments"), got $(length(call.seq) - 1)"))

# ---- the air surface ---------------------------------------------------------

function _bi_decode(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "decode", _DATA_OPTION_KEYS)
    _check_arity(call, "decode", 1)
    x = air_reduce(env, scope, to_form(call.seq[2]))
    fmt = _format_option(env, scope, call, "decode", :json)
    opts = _data_options(env, scope, call, "decode")
    return _decode_data(_decode_input(x, "decode"), fmt, opts, "decode")
end
special!(:decode, _bi_decode)

function _bi_encode(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "encode", _DATA_OPTION_KEYS)
    _check_arity(call, "encode", 1)
    x = air_reduce(env, scope, to_form(call.seq[2]))
    fmt = _format_option(env, scope, call, "encode", :json)
    opts = _data_options(env, scope, call, "encode")
    return Form(_encode_data(x, fmt, opts, "encode"))
end
special!(:encode, _bi_encode)

function _bi_read_data(env::Env, scope::Scope, call::FormContainer)
    _require_filesystem(env, "read-data")
    _check_options(call, "read-data", _DATA_OPTION_KEYS)
    _check_arity(call, "read-data", 1)
    arg = air_reduce(env, scope, to_form(call.seq[2]))
    path = _resolve_air_path(_str(arg, "read-data"))
    farg = _call_option(env, scope, call, "format", "read-data")
    fmt = farg === nothing ? _format_for_path(path, "read-data") :
          _format_name(farg, "read-data")
    opts = _data_options(env, scope, call, "read-data")
    data = try
        read(path)
    catch e
        throw(AirEvalError("read-data: cannot read $path: " * sprint(showerror, e)))
    end
    return _decode_data(_decode_input(_extern_form(AirBytes(data)), "read-data"),
                        fmt, opts, "read-data")
end
special!(Symbol("read-data"), _bi_read_data)

function _bi_write_data(env::Env, scope::Scope, call::FormContainer)
    _require_filesystem(env, "write-data")
    _check_options(call, "write-data", _DATA_OPTION_KEYS)
    _check_arity(call, "write-data", 2)
    arg = air_reduce(env, scope, to_form(call.seq[2]))
    path = _resolve_air_path(_str(arg, "write-data"))
    v = air_reduce(env, scope, to_form(call.seq[3]))
    farg = _call_option(env, scope, call, "format", "write-data")
    fmt = farg === nothing ? _format_for_path(path, "write-data") :
          _format_name(farg, "write-data")
    opts = _data_options(env, scope, call, "write-data")
    text = _encode_data(v, fmt, opts, "write-data")
    # Like `write-file`, the write itself is deferred to the transaction commit
    # and dropped if the transaction aborts.
    send(_FILE_ACTOR) do st
        write(path, text)
        return st
    end
    return naught
end
special!(Symbol("write-data"), _bi_write_data)
