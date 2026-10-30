################################################################################
# formats/csv.jl
#
# CSV and TSV. A decode yields a `table`; an encode accepts a table or a
# non-empty sequence of row maps. The parser is a dependency-free RFC 4180 state
# machine over UTF-8 text: `"` starts a quoted field only at field start, a
# doubled `""` is a literal quote, and (with the default row delimiter) CRLF, LF,
# and CR all terminate a record. Column and row delimiters are options. TSV is
# RFC 4180 quoting with a tab column delimiter, not the IANA backslash
# convention.
#
# Missing data is in band, as everywhere in a table: an empty field is the
# column's NA, and the text `NA` or `NaN` is missing unless the column declares
# a different marker with `na=`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# The options a csv/tsv verb understands. `index=` is decode-only and is
# rejected by the encoder itself with a more specific message.
const _CSV_OPTION_KEYS = (_HEADER_KEY, _COLUMN_DELIMITER_KEY, _ROW_DELIMITER_KEY,
                          _TABLE_TYPES_KEY, _TABLE_NA_KEY, _TABLE_COLUMNS_KEY,
                          _TABLE_INDEX_KEY)

# A canonical integer: an optional `-`, then `0` or a non-zero digit and digits.
const _CSV_INT_RE = r"^-?(0|[1-9][0-9]*)$"
# A canonical float: a decimal point or an exponent must appear, and a plain
# integer with a leading zero (`007`) is a string, not a number.
const _CSV_FLOAT_RE = r"^-?([0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)([eE][+-]?[0-9]+)?$"
const _CSV_LEADZERO_RE = r"^-?0[0-9]+$"

_csv_int_like(s::AbstractString) = occursin(_CSV_INT_RE, s)

function _csv_float_like(s::AbstractString)
    _csv_int_like(s) && return false
    occursin(_CSV_LEADZERO_RE, s) && return false
    occursin(_CSV_FLOAT_RE, s) || return false
    v = tryparse(Float64, s)
    return v !== nothing && isfinite(v)
end

# Is a field a plain number for header inference? Empty fields and the canonical
# missing texts do not count, and neither does a non-canonical spelling.
function _csv_number_text(s::AbstractString)
    isempty(s) && return false
    (s == "NA" || s == "NaN") && return false
    return _csv_int_like(s) || _csv_float_like(s)
end

# The text a declared NA marker is spelled with in a CSV field.
_csv_na_text(x::AbstractString) = String(x)
_csv_na_text(x::Symbol) = _symbol_text(x)
_csv_na_text(x::Bool) = x ? "true" : "false"
_csv_na_text(x::Integer) = string(x)
_csv_na_text(x::AbstractFloat) = isnan(x) ? "NaN" : string(x)
_csv_na_text(x) = string(x)

# A field is missing when it is empty, when it matches the column's declared NA
# text, or — with no declaration — when it is the canonical `NA` or `NaN`.
function _csv_missing_text(s::AbstractString, declared)
    isempty(s) && return true
    declared === nothing && return s == "NA" || s == "NaN"
    return s == _csv_na_text(declared)
end

# A field's scalar value under the canonical rules: an integer, a finite float,
# a boolean, or else the text itself.
function _csv_scalar(s::AbstractString)
    if _csv_int_like(s)
        v = tryparse(Int, s)
        v === nothing || return to_form(v)
        b = tryparse(BigInt, s)
        b === nothing || return to_form(b)
        return Form(s)
    end
    if _csv_float_like(s)
        v = tryparse(Float64, s)
        v === nothing || return to_form(v)
    end
    s == "true" && return Form(true)
    s == "false" && return Form(false)
    return Form(s)
end

# ---- parsing -----------------------------------------------------------------

# A one-code-point delimiter (the column delimiter must be a single character).
function _csv_char(s::String, who::AbstractString, what::AbstractString)
    cs = collect(s)
    length(cs) == 1 || throw(AirEvalError(
        "$who: $what must be a single character, got $(repr(s))"))
    return cs[1]
end

# Parse the text into records. A quote opens a quoted field only at field start;
# inside it everything is literal except a doubled quote. With no explicit row
# delimiter, CRLF, LF, and CR all end a record; with one, only that exact string
# does (so a stray CR or LF is data). A trailing terminator, or an empty text,
# does not create a phantom row.
function _csv_records(text::AbstractString, cdel::Char,
                      rowdelim::Union{Nothing,String}, who::AbstractString)
    recs = Vector{Vector{String}}()
    rec = String[]
    field = IOBuffer()
    started = false      # any character consumed since the last record end
    fieldstart = true    # the current field has no content yet
    quoted = false
    afterquote = false
    i = firstindex(text)
    n = lastindex(text)
    recno() = length(recs) + 1
    while i <= n
        if quoted
            c = text[i]
            if c == '"'
                j = nextind(text, i)
                if j <= n && text[j] == '"'
                    print(field, '"')
                    i = nextind(text, j)
                else
                    quoted = false
                    afterquote = true
                    i = j
                end
            else
                print(field, c)
                i = nextind(text, i)
            end
            continue
        end
        ending = rowdelim === nothing ?
            (text[i] == '\r' || text[i] == '\n') :
            startswith(SubString(text, i), rowdelim)
        if ending
            if started
                _csv_end_record!(recs, rec, field)
                started = false
            end
            fieldstart = true
            afterquote = false
            if rowdelim === nothing
                c = text[i]
                i = nextind(text, i)
                c == '\r' && i <= n && text[i] == '\n' && (i = nextind(text, i))
            else
                i = i + ncodeunits(rowdelim)
            end
            continue
        end
        c = text[i]
        if c == cdel
            _csv_end_field!(rec, field)
            started = true
            fieldstart = true
            afterquote = false
            i = nextind(text, i)
            continue
        elseif c == '"'
            if afterquote
                throw(AirEvalError(
                    "csv: record $(recno()): text after a closing quote"))
            elseif !fieldstart
                throw(AirEvalError(
                    "csv: record $(recno()): a quote inside an unquoted field"))
            end
            quoted = true
            started = true
            fieldstart = false
            i = nextind(text, i)
            continue
        end
        afterquote && throw(AirEvalError(
            "csv: record $(recno()): text after a closing quote"))
        print(field, c)
        started = true
        fieldstart = false
        i = nextind(text, i)
    end
    quoted && throw(AirEvalError(
        "csv: record $(recno()): unterminated quoted field"))
    started && _csv_end_record!(recs, rec, field)
    return recs
end

_csv_end_field!(rec::Vector{String}, field::IOBuffer) = begin
    push!(rec, String(take!(field)))
    return rec
end

function _csv_end_record!(recs::Vector{Vector{String}}, rec::Vector{String},
                          field::IOBuffer)
    _csv_end_field!(rec, field)
    push!(recs, copy(rec))
    empty!(rec)
    return recs
end

# ---- decoding ----------------------------------------------------------------

function _csv_auto_names(n::Int)
    return Symbol[Symbol(":col" * string(i)) for i in 1:n]
end

# A header label as an air column name. An empty label falls back to `:colN`.
function _csv_colname(label::AbstractString, j::Int)
    isempty(label) && return Symbol(":col" * string(j))
    return _data_key(label)
end

function _csv_decode(text::AbstractString, fmt::Symbol, opts::_DataOptions,
                     who::AbstractString)
    opts.documents && throw(AirEvalError(
        "$who: documents=true is only meaningful for yaml"))
    opts.columns === nothing || throw(AirEvalError(
        "$who: columns= is only meaningful when encoding; use header=(…) " *
        "to name the decoded columns"))
    cdel_s = opts.column_delimiter === nothing ?
        (fmt === :tsv ? "\t" : ",") : opts.column_delimiter
    cdel = _csv_char(cdel_s, who, "column-delimiter")
    recs = _csv_records(text, cdel, opts.row_delimiter, who)

    # The names: an explicit list, a header record, or `:col1` … `:colN`.
    names = Symbol[]
    data = recs
    h = opts.header
    if h === nothing
        if !isempty(recs) && !any(_csv_number_text, recs[1])
            names = Symbol[_csv_colname(s, j) for (j, s) in enumerate(recs[1])]
            data = recs[2:end]
        elseif !isempty(recs)
            names = _csv_auto_names(length(recs[1]))
        end
    elseif h === true
        if !isempty(recs)
            names = Symbol[_csv_colname(s, j) for (j, s) in enumerate(recs[1])]
            data = recs[2:end]
        end
    elseif h === false
        isempty(recs) || (names = _csv_auto_names(length(recs[1])))
    else
        names = Symbol[_table_name_of(Form(lbl), "$who header") for lbl in h]
    end
    length(unique(names)) == length(names) || throw(AirEvalError(
        "$who: the header repeats a column name"))

    nrows = length(data)
    for (r, rec) in enumerate(data)
        length(rec) == length(names) || throw(AirEvalError(
            "$who: csv record $((h === nothing || h === true) ? r + 1 : r) " *
            "has $(length(rec)) field(s); expected $(length(names))"))
    end

    # A declared NA or type must name a column.
    for nm in keys(opts.na)
        nm in names || throw(AirEvalError(
            "$who: na= names a column $(_colname(nm)) the data do not have"))
    end
    for nm in keys(opts.types)
        nm in names || throw(AirEvalError(
            "$who: types= names a column $(_colname(nm)) the data do not have"))
    end

    cols = Dict{Symbol,FormSeq}()
    sch = Dict{Symbol,_ColumnMeta}()
    for (j, nm) in enumerate(names)
        declared = get(opts.na, nm, nothing)
        # A declared text type keeps the field's text: `types=(a=:string)` on a
        # numeric column means "leave the numbers as strings", not "parse them
        # and then refuse".
        dty = get(opts.types, nm, nothing)
        texty = dty === :string || dty === :symbol || dty === :keyword
        cells = Vector{Form}(undef, nrows)
        miss = falses(nrows)
        for (r, rec) in enumerate(data)
            s = rec[j]
            m = _csv_missing_text(s, declared)
            miss[r] = m
            cells[r] = m ? naught : (texty ? Form(String(s)) : _csv_scalar(s))
        end
        ty = dty === nothing ? _infer_type(cells, miss) : dty
        final_na = declared === nothing ? _default_na(ty) : declared
        out = FormValue[]
        for r in 1:nrows
            push!(out, _store_form(miss[r] ? to_form(final_na) :
                                          _coerce_value(nm, ty, cells[r], who)))
        end
        cols[nm] = FormSeq(out)
        sch[nm] = _ColumnMeta(ty, final_na)
    end
    index = opts.index
    index === nothing || index in names || throw(AirEvalError(
        "$who: index= names a column $(_colname(index)) the data do not have"))
    return _table_form(_airtable(names, cols, sch, nrows, index))
end

# ---- encoding ----------------------------------------------------------------

_csv_needs_quote(s::AbstractString, cdel::Char, rowdelim::String) =
    occursin(cdel, s) || occursin(rowdelim, s) || occursin('\r', s) ||
    occursin('\n', s) || occursin('"', s)

function _csv_write_field!(io::IO, s::AbstractString, cdel::Char, rowdelim::String)
    if _csv_needs_quote(s, cdel, rowdelim)
        print(io, '"')
        for c in s
            c == '"' ? print(io, "\"\"") : print(io, c)
        end
        print(io, '"')
    else
        print(io, s)
    end
    return io
end

# One cell as CSV text; a cell equal to the column's NA is an empty field.
function _csv_cell_text(c::Form, namarker, nm::Symbol, who::AbstractString)
    isequal(c, to_form(namarker)) && return ""
    l = _leafof(c)
    l === nothing && throw(AirEvalError(
        "$who: column $(_colname(nm)) has a naught cell, which CSV cannot spell"))
    l isa Bool && return l ? "true" : "false"
    l isa Integer && return string(l)
    if l isa AbstractFloat
        isfinite(l) || throw(AirEvalError(
            "$who: column $(_colname(nm)) has the non-finite value $(l), " *
            "which is not its NA marker"))
        return string(l)
    end
    l isa AbstractString && return String(l)
    l isa Symbol && return _symbol_text(l)
    throw(AirEvalError(
        "$who: column $(_colname(nm)) has a value CSV cannot spell: " *
        air_string(c)))
end

# The output columns, the NA marker per column, and the cell accessor.
function _csv_encode_source(v::Form, who::AbstractString)
    t = _table_of(v)
    if t !== nothing
        nas = Dict{Symbol,Any}(nm => t.schema[nm].na for nm in t.names)
        return Symbol[nm for nm in t.names], nas, t.nrows,
               (nm, i) -> to_form(t.columns[nm][i])
    end
    (v isa FormContainer && isempty(v.map) && !isempty(v.seq)) || throw(
        AirEvalError("$who: CSV needs a table or a non-empty sequence of row maps"))
    rows = Form[]
    for e in v.seq
        r = to_form(e)
        (r isa FormContainer && isempty(r.seq)) || throw(AirEvalError(
            "$who: CSV row $(length(rows) + 1) is not a mapping: " * air_string(r)))
        push!(rows, r)
    end
    names = sort(collect(keys(rows[1].map)); by = String)
    for r in rows
        Set(keys(r.map)) == Set(names) || throw(AirEvalError(
            "$who: ragged rows: " * air_string(r)))
    end
    nas = Dict{Symbol,Any}()
    for nm in names
        cells = Form[to_form(r[nm]) for r in rows]
        miss = Bool[_is_missing_cell(c, nothing) for c in cells]
        nas[nm] = _default_na(_infer_type(cells, miss))
    end
    return names, nas, length(rows), (nm, i) -> to_form(rows[i][nm])
end

function _csv_encode(v::Form, fmt::Symbol, opts::_DataOptions,
                     who::AbstractString)
    opts.documents && throw(AirEvalError(
        "$who: documents=true is only meaningful for yaml"))
    opts.index === nothing || throw(AirEvalError(
        "$who: index= is only meaningful when decoding csv or tsv"))
    allnames, nas, nrows, cell = _csv_encode_source(v, who)
    for nm in keys(opts.types)
        nm in allnames || throw(AirEvalError(
            "$who: types= names a column $(_colname(nm)) the table does not have"))
    end
    for nm in keys(opts.na)
        nm in allnames || throw(AirEvalError(
            "$who: na= names a column $(_colname(nm)) the table does not have"))
    end
    names = allnames
    if opts.columns !== nothing
        for nm in opts.columns
            nm in allnames || throw(AirEvalError(
                "$who: columns= names a column $(_colname(nm)) the table does not have"))
        end
        names = opts.columns
    end
    for nm in names
        haskey(opts.na, nm) && (nas[nm] = opts.na[nm])
    end
    labels = if opts.header === nothing || opts.header === true
        String[_symbol_text(nm) for nm in names]
    elseif opts.header === false
        nothing
    else
        length(opts.header) == length(names) || throw(AirEvalError(
            "$who: header= has $(length(opts.header)) name(s) but the output " *
            "has $(length(names)) column(s)"))
        opts.header
    end

    cdel_s = opts.column_delimiter === nothing ?
        (fmt === :tsv ? "\t" : ",") : opts.column_delimiter
    cdel = _csv_char(cdel_s, who, "column-delimiter")
    rowdelim = opts.row_delimiter === nothing ? "\n" : opts.row_delimiter
    isempty(rowdelim) && throw(AirEvalError(
        "$who: row-delimiter must not be empty"))

    io = IOBuffer()
    if labels !== nothing
        for (j, lbl) in enumerate(labels)
            j > 1 && print(io, cdel)
            _csv_write_field!(io, lbl, cdel, rowdelim)
        end
        print(io, rowdelim)
    end
    for i in 1:nrows
        for (j, nm) in enumerate(names)
            j > 1 && print(io, cdel)
            c = cell(nm, i)
            # `types=` coerces the output cell, as it does on decode; a text type
            # is already the field's text, so it needs no coercion.
            if haskey(opts.types, nm) && !isequal(c, to_form(nas[nm]))
                oty = opts.types[nm]
                if !(oty === :string || oty === :symbol || oty === :keyword)
                    c = _coerce_value(nm, oty, c, who)
                end
            end
            _csv_write_field!(io, _csv_cell_text(c, nas[nm], nm, who), cdel, rowdelim)
        end
        print(io, rowdelim)
    end
    return String(take!(io))
end
