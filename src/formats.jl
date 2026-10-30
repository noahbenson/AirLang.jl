################################################################################
# formats.jl
#
# Plain-data converters: JSON, YAML, TOML, CSV/TSV, and `.env`. A format parses
# into ordinary air forms — an object or table is a map form, an array a
# sequence form, and null or an empty container is `naught` — and encodes forms
# back to text. CSV and TSV decode to a `table` and encode from one. There are
# no other extern types and no execution: a YAML or TOML file is always data.
#
#   (decode x format=:json)      text (a string or bytes) as a form
#   (encode v format=:json)      a form as text
#   (read-data "f.toml")         read a file, inferring its format
#   (write-data "f.yaml" v)      encode and write a file
#
# The path helpers are air's alone, like `read-file`/`write-file`/`load-air`:
# an ordinary user has no filesystem and is refused with
# `(:permission-denied :filesystem NAME)`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

include("formats/common.jl")
include("formats/json.jl")
include("formats/yaml.jl")
include("formats/toml.jl")
include("formats/csv.jl")
include("formats/dotenv.jl")

# Decode text in one format. Every format has an explicit branch, so a new one
# can never silently fall through to `.env`. Multi-document streams are YAML's.
function _decode_data(text::AbstractString, fmt::Symbol, opts::_DataOptions,
                      who::AbstractString)
    if fmt === :json
        _reject_options(opts, who, fmt, ())
        return _json_decode(text)
    elseif fmt === :yaml
        _reject_options(opts, who, fmt, (_DOCUMENTS_KEY,))
        return _yaml_decode(text; documents = opts.documents)
    elseif fmt === :toml
        _reject_options(opts, who, fmt, ())
        return _toml_decode(text)
    elseif fmt === :csv || fmt === :tsv
        _reject_options(opts, who, fmt, _CSV_OPTION_KEYS)
        return _csv_decode(text, fmt, opts, who)
    elseif fmt === :env
        _reject_options(opts, who, fmt, ())
        return _dotenv_decode(text)
    end
    throw(AirEvalError("$who: unknown format $(repr(fmt))"))
end

# Encode a form in one format.
function _encode_data(v::Form, fmt::Symbol, opts::_DataOptions,
                      who::AbstractString)
    if fmt === :json
        _reject_options(opts, who, fmt, ())
        return _json_encode(v)
    elseif fmt === :yaml
        _reject_options(opts, who, fmt, ())
        return _yaml_encode(v)
    elseif fmt === :toml
        _reject_options(opts, who, fmt, ())
        return _toml_encode(v)
    elseif fmt === :csv || fmt === :tsv
        _reject_options(opts, who, fmt, _CSV_OPTION_KEYS)
        return _csv_encode(v, fmt, opts, who)
    elseif fmt === :env
        _reject_options(opts, who, fmt, ())
        return _dotenv_encode(v)
    end
    throw(AirEvalError("$who: unknown format $(repr(fmt))"))
end
