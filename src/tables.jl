################################################################################
# tables.jl
#
# `table`: an immutable, typed, column-major table of plain air data. It is an
# extern (AirDB's form union is closed), backed by the persistent `PDict` and
# `PVector` collections, so a column read is O(1) and an update is O(log n) with
# structural sharing. Nothing is mutable and nothing takes a lock: an update
# returns a new table and leaves the old one untouched.
#
# A column stores its cells, its inferred-or-declared type, and its own NA marker
# (the value that means "missing" in that column) in metadata. Missing data is
# therefore in band: an int column's NA is the symbol `NA`, a float column's is
# `NaN`, and a user may declare a different marker with `na=`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- the value type ----------------------------------------------------------

"""
    _ColumnMeta

A column's declared type (`:int`, `:float`, `:number`, `:string`, `:bool`,
`:symbol`, `:keyword`, `:naught`, or `:any`) and the scalar value that marks a
missing cell in that column.
"""
struct _ColumnMeta
    type::Symbol
    na::Any
end

"""
    AirTable

An immutable table of plain air data: ordered named columns, each a `FormSeq` of
cells, each with `_ColumnMeta`. `index` optionally names a unique, non-missing
column whose values address rows (`(get t "Bob")`), and `indexmap` is the
persistent `(typeof(v), v) => row` map that implements that lookup.
"""
struct AirTable <: AbstractAirExtern
    names::PVector{Symbol}
    columns::PDict{Symbol,FormSeq}
    schema::PDict{Symbol,_ColumnMeta}
    nrows::Int
    index::Union{Nothing,Symbol}
    indexmap::PDict{Tuple{DataType,Any},Int}
    global _airtable_raw(names, columns, schema, nrows, index, indexmap) =
        new(names, columns, schema, nrows, index, indexmap)
end

# The declared inner constructor suppresses the default outer one; restore it for
# the validated builders (the field types check the arguments).
AirTable(names, columns, schema, nrows, index, indexmap) =
    _airtable_raw(names, columns, schema, nrows, index, indexmap)

const _TABLE_TYPES =
    (:int, :float, :number, :string, :bool, :symbol, :keyword, :naught, :any)
const COLON = Symbol(":")
const _TABLE_COLUMNS_KEY = Symbol(":columns")
const _TABLE_TYPES_KEY = Symbol(":types")
const _TABLE_NA_KEY = Symbol(":na")
const _TABLE_INDEX_KEY = Symbol(":index")
const _TABLE_OPTION_KEYS =
    (_TABLE_COLUMNS_KEY, _TABLE_TYPES_KEY, _TABLE_NA_KEY, _TABLE_INDEX_KEY)

# ---- small helpers -----------------------------------------------------------

_colname(name::Symbol) = air_string(Form(name))
_ttypename(ty::Symbol) = ":" * String(ty)
_tseq(forms) = FormContainer(FormSeq(FormValue[_store_form(f) for f in forms]),
                             FormMap())
_tmap(pairs) = FormContainer(FormSeq(FormValue[]),
                             FormMap(Pair{Symbol,FormValue}[
                                 k => _store_form(v) for (k, v) in pairs]))

# The `AirTable` behind a form, or `nothing`.
function _table_of(x::Form)
    x isa FormExtern || return nothing
    d = try
        value(x)
    catch
        return nothing
    end
    return d isa AirTable ? d : nothing
end

_table_form(t::AirTable) = _extern_form(t)

# A table's cell must be plain, immutable air data: a scalar (including
# `naught`), or a container of such cells. A volatile, an extern (bytes, another
# table, …), or a reference form has no table representation.
_cell_ok(::FormScalar) = true
function _cell_ok(x::FormContainer)
    for v in x.seq
        _cell_ok(to_form(v)) || return false
    end
    for (_, v) in x.map
        _cell_ok(to_form(v)) || return false
    end
    return true
end
_cell_ok(::Form) = false

# ---- types, NA, inference, and coercion --------------------------------------

_default_na(ty::Symbol) = ty in (:float, :number) ? NaN : NA_SYMBOL

# Whether a cell is missing. With a declared marker only that exact value is
# missing; without one, the canonical defaults are the symbol `NA` and any NaN.
function _is_missing_cell(c::Form, declared)
    declared === nothing || return isequal(c, to_form(declared))
    l = _leafof(c)
    l === NA_SYMBOL && return true
    return l isa AbstractFloat && isnan(l)
end

# The type a list of cells implies, ignoring missing ones.
function _infer_type(cells::Vector{Form}, miss::AbstractVector{Bool})
    seen = Form[]
    for (c, m) in zip(cells, miss)
        m || push!(seen, c)
    end
    isempty(seen) && return :naught
    ls = [_leafof(c) for c in seen]
    any(l -> l === nothing, ls) && return :any
    all(l -> l isa Bool, ls) && return :bool
    all(l -> l isa Integer && !(l isa Bool), ls) && return :int
    all(l -> l isa AbstractFloat, ls) && return :float
    all(l -> (l isa Integer && !(l isa Bool)) || l isa AbstractFloat, ls) &&
        return :number
    all(l -> l isa AbstractString, ls) && return :string
    all(l -> l isa Symbol && is_keyword(l), ls) && return :keyword
    all(l -> l isa Symbol && !is_keyword(l), ls) && return :symbol
    return :any
end

_type_mismatch(name::Symbol, ty::Symbol, c::Form, what::AbstractString) =
    AirEvalError("$what: column $(_colname(name)) is $(_ttypename(ty)), which " *
                 "cannot hold $(air_string(c))")

# Coerce one non-missing cell to `ty`, returning a form. Strings parse to
# numbers and booleans; integers widen to floats; string, symbol, and keyword
# convert among themselves. A lossy conversion (a float to an int, anything to a
# bool but "true"/"false") raises.
function _coerce_value(name::Symbol, ty::Symbol, c::Form, what::AbstractString)
    ty === :any && return c
    l = _leafof(c)
    if ty === :naught
        isequal(c, naught) && return c
        throw(_type_mismatch(name, ty, c, what))
    end
    l === nothing && throw(_type_mismatch(name, ty, c, what))
    if ty === :int
        (l isa Integer && !(l isa Bool)) && return c
        if l isa AbstractString
            v = tryparse(Int, l)
            v === nothing || return Form(v)
        end
    elseif ty === :float
        l isa AbstractFloat && return c
        (l isa Integer && !(l isa Bool)) && return Form(Float64(l))
        if l isa AbstractString
            v = tryparse(Float64, l)
            v === nothing || return Form(v)
        end
    elseif ty === :number
        (l isa Number && !(l isa Bool)) && return c
        if l isa AbstractString
            v = tryparse(Int, l)
            v === nothing && (v = tryparse(Float64, l))
            v === nothing || return Form(v)
        end
    elseif ty === :string
        l isa AbstractString && return c
        l isa Symbol && return Form(is_keyword(l) ? String(l)[2:end] : String(l))
    elseif ty === :symbol
        (l isa Symbol && !is_keyword(l)) && return c
        l isa Symbol && return Form(Symbol(String(l)[2:end]))
        l isa AbstractString && return Form(Symbol(l))
    elseif ty === :keyword
        (l isa Symbol && is_keyword(l)) && return c
        l isa Symbol && return Form(Symbol(":" * String(l)))
        l isa AbstractString && return Form(Symbol(":" * l))
    elseif ty === :bool
        l isa Bool && return c
        (l isa AbstractString && l == "true") && return Form(true)
        (l isa AbstractString && l == "false") && return Form(false)
    end
    throw(_type_mismatch(name, ty, c, what))
end

# Coerce a cell for an existing column: the column's NA stays missing, everything
# else must fit the declared type.
function _table_cell_for(meta::_ColumnMeta, name::Symbol, c::Form,
                         what::AbstractString)
    isequal(c, to_form(meta.na)) && return to_form(meta.na)
    return _coerce_value(name, meta.type, c, what)
end

# Build one column from raw cells. `type` overrides inference, `na` (a scalar
# leaf) declares the missing marker; either may be `nothing`.
function _table_column(name::Symbol, cells::Vector{Form};
                       type::Union{Nothing,Symbol} = nothing,
                       na::Any = nothing, what::AbstractString = "table")
    for c in cells
        _cell_ok(c) || throw(AirEvalError(
            "$what: column $(_colname(name)) has a cell that is not plain data: " *
            air_string(c)))
    end
    miss = Bool[_is_missing_cell(c, na) for c in cells]
    ty = type === nothing ? _infer_type(cells, miss) : type
    final_na = na === nothing ? _default_na(ty) : na
    out = FormValue[]
    for (c, m) in zip(cells, miss)
        push!(out, _store_form(m ? to_form(final_na) :
                                  _coerce_value(name, ty, c, what)))
    end
    return _ColumnMeta(ty, final_na), FormSeq(out)
end

# The cells of a column value: a sequence form, `naught` (empty), or a scalar (a
# one-element column).
function _column_cells(v::Form, what::AbstractString)
    if v isa FormContainer
        isempty(v.map) || throw(AirEvalError(
            "$what: a column must be a sequence, not a mapping"))
        return Form[to_form(x) for x in v.seq]
    elseif isequal(v, naught)
        return Form[]
    end
    return Form[v]
end

# ---- construction and validation ---------------------------------------------

function _table_indexmap(cols::PDict{Symbol,FormSeq}, sch::PDict{Symbol,_ColumnMeta},
                         nrows::Int, index::Union{Nothing,Symbol})
    im = PDict{Tuple{DataType,Any},Int}()
    index === nothing && return im
    col = cols[index]
    meta = sch[index]
    for i in 1:nrows
        c = to_form(col[i])
        _is_missing_cell(c, meta.na) && throw(AirEvalError(
            "table: index column $(_colname(index)) has a missing value in row $i"))
        l = _leafof(c)
        l === nothing && throw(AirEvalError(
            "table: index column $(_colname(index)) must hold scalars"))
        key = (typeof(l), l)
        haskey(im, key) && throw(AirEvalError(
            "table: index column $(_colname(index)) repeats the value " *
            air_string(c)))
        im = push(im, key => i)
    end
    return im
end

# Build a table from already-validated parts (used by the update operations).
_airtable_new(names::Vector{Symbol}, cols::PDict{Symbol,FormSeq},
              sch::PDict{Symbol,_ColumnMeta}, nrows::Int,
              index::Union{Nothing,Symbol},
              im::PDict{Tuple{DataType,Any},Int}) =
    AirTable(PVector{Symbol}(names), cols, sch, nrows, index, im)

# The validated constructor: every invariant is checked here.
function _airtable(names::Vector{Symbol}, columns::Dict{Symbol,FormSeq},
                   schema::Dict{Symbol,_ColumnMeta}, nrows::Int,
                   index::Union{Nothing,Symbol})
    ns = unique(names)
    length(ns) == length(names) || throw(AirEvalError("table: duplicate column name"))
    Set(names) == Set(keys(columns)) || throw(AirEvalError(
        "table: the column names and the column data disagree"))
    Set(names) == Set(keys(schema)) || throw(AirEvalError(
        "table: the column names and the column metadata disagree"))
    nrows >= 0 || throw(AirEvalError("table: the row count cannot be negative"))
    isempty(names) && nrows != 0 && throw(AirEvalError(
        "table: a table with no columns has no rows"))
    cols = PDict{Symbol,FormSeq}()
    sch = PDict{Symbol,_ColumnMeta}()
    for nm in names
        col = columns[nm]
        length(col) == nrows || throw(AirEvalError(
            "table: column $(_colname(nm)) has $(length(col)) cells but the " *
            "table has $nrows row(s)"))
        meta = schema[nm]
        meta.type in _TABLE_TYPES || throw(AirEvalError(
            "table: unknown column type $(meta.type) for $(_colname(nm))"))
        for i in 1:nrows
            c = to_form(col[i])
            _cell_ok(c) || throw(AirEvalError(
                "table: column $(_colname(nm)) has a cell that is not plain " *
                "data: " * air_string(c)))
            _is_missing_cell(c, meta.na) && continue
            _coerce_value(nm, meta.type, c, "table")
        end
        cols = push(cols, nm => col)
        sch = push(sch, nm => meta)
    end
    (index === nothing || haskey(sch, index)) || throw(AirEvalError(
        "table: the index column is not a column of the table"))
    im = _table_indexmap(cols, sch, nrows, index)
    return AirTable(PVector{Symbol}(names), cols, sch, nrows, index, im)
end

# ---- access ------------------------------------------------------------------

function _table_row(t::AirTable, i::Int)
    map = Pair{Symbol,FormValue}[nm => t.columns[nm][i] for nm in t.names]
    return canonicalize(FormContainer(FormSeq(FormValue[]), FormMap(map)))
end

function _table_column_form(t::AirTable, name::Symbol)
    col = t.columns[name]
    length(col) == 0 && return naught
    return canonicalize(FormContainer(col, FormMap()))
end

# Every row as an ordinary map form, in order, as one sequence form. The
# uncollapsed form (an empty container, not `naught`) is what the data-format
# emitters need, since an empty table is still an array.
_rows_form(t::AirTable) = FormContainer(
    FormSeq(FormValue[_store_form(_table_row(t, i)) for i in 1:t.nrows]),
    FormMap())

_rows_view(t::AirTable) = canonicalize(_rows_form(t))

# A table becomes its rows view; anything else is unchanged.
_rows_or(coll::Form) = (t = _table_of(coll); t === nothing ? coll : _rows_view(t))

# `get` for a table: an integer names a row (`0` the table), a keyword names a
# column, and any other key is looked up in the index.
function _table_get(env::Env, scope::Scope, form::Form, t::AirTable, k, key::Form,
                    default, held::Bool)
    local v::Form
    if k isa Integer
        i = try
            _index_of(k, t.nrows)
        catch e
            e isa AirEvalError || rethrow()
            default === nothing || return air_reduce(env, scope, default)
            rethrow()
        end
        v = i === nothing ? form : _table_row(t, i)
        return held ? _ensure_hold(v) : v
    elseif k isa Symbol && haskey(t.schema, k)
        v = _table_column_form(t, k)
        return held ? _ensure_hold(v) : v
    elseif k isa AbstractString
        # A string names a column when it matches one; otherwise it may still be
        # an index value (e.g. `(get t "Bob")` on a `:name` index).
        nm = Symbol(":" * String(k))
        if haskey(t.schema, nm)
            v = _table_column_form(t, nm)
            return held ? _ensure_hold(v) : v
        end
    end
    i = _table_lookup(t, k)
    if i !== nothing
        v = _table_row(t, i)
        return held ? _ensure_hold(v) : v
    end
    default === nothing && throw(AirEvalError(
        "table: key $(air_string(key)) names no row, column, or index value"))
    return air_reduce(env, scope, default)
end

# The row an index value names, or `nothing`.
function _table_lookup(t::AirTable, k)
    t.index === nothing && return nothing
    k === nothing && return nothing
    i = get(t.indexmap, (typeof(k), k), 0)
    return i == 0 ? nothing : i
end

function _table_row_index(t::AirTable, k)
    if k isa Integer
        i = _index_of(k, t.nrows)
        i === nothing && throw(AirEvalError(
            "0 names the whole table, not a row"))
        return i
    end
    i = _table_lookup(t, k)
    i === nothing && throw(AirEvalError(
        "table: no row matches $(air_string(Form(k)))"))
    return i
end

# ---- index maintenance -------------------------------------------------------

function _index_cell_key(t::AirTable, name::Symbol, c::Form, what::AbstractString)
    meta = t.schema[name]
    _is_missing_cell(c, meta.na) && throw(AirEvalError(
        "$what: index column $(_colname(name)) cannot be missing"))
    l = _leafof(c)
    l === nothing && throw(AirEvalError(
        "$what: index column $(_colname(name)) must hold scalars"))
    return (typeof(l), l)
end

function _index_replace(t::AirTable, i::Int, old::Form, new::Form,
                        what::AbstractString)
    key = _index_cell_key(t, t.index::Symbol, new, what)
    j = get(t.indexmap, key, 0)
    (j == 0 || j == i) || throw(AirEvalError(
        "$what: index column $(_colname(t.index::Symbol)) would repeat the value " *
        air_string(new)))
    oldl = _leafof(old)
    im = t.indexmap
    oldl === nothing || (im = delete(im, (typeof(oldl), oldl)))
    return push(im, key => i)
end

# ---- updates -----------------------------------------------------------------

# A column update: `(with t :age (10 20))`.
function _table_set_column(t::AirTable, name::Symbol, val::Form)
    cells = _column_cells(val, "with")
    if isempty(t.names)
        meta, col = _table_column(name, cells)
        cols = push(PDict{Symbol,FormSeq}(), name => col)
        sch = push(PDict{Symbol,_ColumnMeta}(), name => meta)
        n = length(cells)
        im = _table_indexmap(cols, sch, n, nothing)
        return _table_form(_airtable_new(Symbol[name], cols, sch, n, nothing, im))
    end
    length(cells) == t.nrows || throw(AirEvalError(
        "with: column $(_colname(name)) has $(length(cells)) cells but the " *
        "table has $(t.nrows) row(s)"))
    if haskey(t.schema, name)
        meta = t.schema[name]
        out = FormValue[]
        for c in cells
            push!(out, _store_form(_table_cell_for(meta, name, c, "with")))
        end
        col = FormSeq(out)
        cols = push(t.columns, name => col)
        im = t.index === name ?
            _table_indexmap(cols, t.schema, t.nrows, t.index) : t.indexmap
        return _table_form(AirTable(t.names, cols, t.schema, t.nrows, t.index, im))
    end
    meta, col = _table_column(name, cells)
    names = Symbol[nm for nm in t.names]
    push!(names, name)
    cols = push(t.columns, name => col)
    sch = push(t.schema, name => meta)
    return _table_form(_airtable_new(names, cols, sch, t.nrows, t.index, t.indexmap))
end

# A row update: `(with t 2 (name="b" age=42))`, a partial mapping.
function _table_update_row(t::AirTable, i::Int, val::Form)
    (val isa FormContainer && isempty(val.seq)) || throw(AirEvalError(
        "with: a row update needs a mapping of column names to values"))
    cells = Pair{Symbol,Form}[]
    for (k, v) in val.map
        haskey(t.schema, k) || throw(AirEvalError(
            "with: no column $(_colname(k)) in the table"))
        push!(cells, k => _table_cell_for(t.schema[k], k, to_form(v), "with"))
    end
    isempty(cells) && return _table_form(t)
    # Validate an index change against the whole table before writing anything,
    # so swapping two index values in one update is legal.
    newvals = Dict{Symbol,Form}(cells)
    if t.index !== nothing && haskey(newvals, t.index)
        key = _index_cell_key(t, t.index, newvals[t.index], "with")
        j = get(t.indexmap, key, 0)
        (j == 0 || j == i) || throw(AirEvalError(
            "with: index column $(_colname(t.index)) would repeat the value " *
            air_string(newvals[t.index])))
    end
    cols = t.columns
    for (nm, c) in cells
        cols = push(cols, nm => setindex(cols[nm], _store_form(c), i))
    end
    im = t.indexmap
    if t.index !== nothing && haskey(newvals, t.index)
        im = _index_replace(t, i, to_form(t.columns[t.index][i]),
                            newvals[t.index], "with")
    end
    return _table_form(AirTable(t.names, cols, t.schema, t.nrows, t.index, im))
end

# A single-cell update: `(with t (2 :age) 42)`.
function _table_set_cell(t::AirTable, i::Int, name::Symbol, val::Form)
    meta = t.schema[name]
    cell = _table_cell_for(meta, name, val, "with")
    old = to_form(t.columns[name][i])
    im = t.indexmap
    if t.index === name
        im = _index_replace(t, i, old, cell, "with")
    end
    cols = push(t.columns, name => setindex(t.columns[name], _store_form(cell), i))
    return _table_form(AirTable(t.names, cols, t.schema, t.nrows, t.index, im))
end

# The `with` setter for a table path (row then column; `:` is a wildcard).
function _table_with_set(t::AirTable, path::Vector{Any}, val::Form)
    isempty(path) && throw(AirEvalError(
        "with: a table needs a row or column key"))
    k1 = path[1]
    if length(path) == 1
        if k1 isa Symbol && k1 !== COLON
            # A keyword names a column, whether or not the table has it yet
            # (`(with t score=(1 2))` adds the column).
            return _table_set_column(t, k1, val)
        end
        k1 === COLON && throw(AirEvalError(
            "with: a lone : names neither rows nor columns"))
        return _table_update_row(t, _table_row_index(t, k1), val)
    elseif length(path) == 2
        k2 = path[2]
        if k1 === COLON
            (k2 isa Symbol && k2 !== COLON && haskey(t.schema, k2)) ||
                throw(AirEvalError("with: no column $(_colname_of(k2)) in the table"))
            return _table_set_column(t, k2, val)
        end
        i = _table_row_index(t, k1)
        if k2 === COLON
            return _table_update_row(t, i, val)
        end
        (k2 isa Symbol && haskey(t.schema, k2)) ||
            throw(AirEvalError("with: no column $(_colname_of(k2)) in the table"))
        return _table_set_cell(t, i, k2, val)
    end
    throw(AirEvalError("with: a table path has at most a row and a column"))
end

_colname_of(k) = air_string(Form(k))

# A push: positional map arguments append rows; map entries append columns. In
# hold mode (`hold-push`) the caller has already stripped each row's root hold
# and `strip` asks us to strip a column value's, so a held value contributes its
# content.
function _table_push(env::Env, scope::Scope, call::FormContainer, t::AirTable,
                     posargs::Vector{Form}, strip::Bool = false)
    out = t
    for row in posargs
        out = _table_push_row(out, row)
    end
    for (k, v) in call.map
        k === HOLD_KEY && continue
        val = to_form(v)
        strip && (val = _strip_hold(val))
        val = air_reduce(env, scope, val)
        out = _table_push_col(out, k, val)
    end
    return _table_form(out)
end

function _table_push_row(t::AirTable, row::Form)
    (row isa FormContainer && isempty(row.seq)) || throw(AirEvalError(
        "push: a row must be a mapping of column names to values"))
    if isempty(t.names)
        names = sort(collect(keys(row.map)); by = String)
        cols = PDict{Symbol,FormSeq}()
        sch = PDict{Symbol,_ColumnMeta}()
        for nm in names
            meta, col = _table_column(nm, Form[to_form(row[nm])])
            cols = push(cols, nm => col)
            sch = push(sch, nm => meta)
        end
        im = _table_indexmap(cols, sch, 1, nothing)
        return _airtable_new(names, cols, sch, 1, nothing, im)
    end
    Set(keys(row.map)) == Set(Symbol[nm for nm in t.names]) || throw(AirEvalError(
        "push: a row must name exactly the table's columns"))
    n = t.nrows + 1
    cells = Pair{Symbol,Form}[]
    for nm in t.names
        push!(cells, nm => _table_cell_for(t.schema[nm], nm, to_form(row[nm]),
                                          "push"))
    end
    cols = t.columns
    for (nm, c) in cells
        cols = push(cols, nm => push(cols[nm], _store_form(c)))
    end
    im = t.indexmap
    if t.index !== nothing
        newc = first(c for (nm, c) in cells if nm === t.index)
        key = _index_cell_key(t, t.index, newc, "push")
        haskey(im, key) && throw(AirEvalError(
            "push: index column $(_colname(t.index)) would repeat the value " *
            air_string(newc)))
        im = push(im, key => n)
    end
    return _airtable_new(Symbol[nm for nm in t.names], cols, t.schema, n, t.index,
                         im)
end

function _table_push_col(t::AirTable, name::Symbol, val::Form)
    haskey(t.schema, name) && throw(AirEvalError(
        "push: the table already has a column $(_colname(name))"))
    cells = _column_cells(val, "push")
    if isempty(t.names)
        meta, col = _table_column(name, cells)
        cols = push(PDict{Symbol,FormSeq}(), name => col)
        sch = push(PDict{Symbol,_ColumnMeta}(), name => meta)
        n = length(cells)
        im = _table_indexmap(cols, sch, n, nothing)
        return _airtable_new(Symbol[name], cols, sch, n, nothing, im)
    end
    length(cells) == t.nrows || throw(AirEvalError(
        "push: column $(_colname(name)) has $(length(cells)) cells but the " *
        "table has $(t.nrows) row(s)"))
    meta, col = _table_column(name, cells)
    names = Symbol[nm for nm in t.names]
    push!(names, name)
    cols = push(t.columns, name => col)
    sch = push(t.schema, name => meta)
    return _airtable_new(names, cols, sch, t.nrows, t.index, t.indexmap)
end

_columns_minus(cols::PDict{Symbol,FormSeq}, name::Symbol) =
    delete(cols, name)
_schema_minus(sch::PDict{Symbol,_ColumnMeta}, name::Symbol) = delete(sch, name)

function _table_drop_col(t::AirTable, name::Symbol)
    haskey(t.schema, name) || throw(AirEvalError(
        "no column $(_colname(name)) in the table"))
    names = Symbol[nm for nm in t.names if nm !== name]
    cols = _columns_minus(t.columns, name)
    sch = _schema_minus(t.schema, name)
    index = t.index === name ? nothing : t.index
    im = index === nothing ? PDict{Tuple{DataType,Any},Int}() : t.indexmap
    nrows = isempty(names) ? 0 : t.nrows
    return _table_form(_airtable_new(names, cols, sch, nrows, index, im))
end

function _table_drop_row(t::AirTable, i::Int)
    cols = t.columns
    for nm in t.names
        cols = push(cols, nm => deleteat(cols[nm], i))
    end
    # Removing a row renumbers every row after it, so the index is rebuilt.
    n = t.nrows - 1
    im = t.index === nothing ? PDict{Tuple{DataType,Any},Int}() :
        _table_indexmap(cols, t.schema, n, t.index)
    return _airtable_new(Symbol[nm for nm in t.names], cols, t.schema, n,
                         t.index, im)
end

_table_pop(t::AirTable) = t.nrows == 0 ? naught :
    _table_form(_table_drop_row(t, t.nrows))

# `wout`: no path pops the last row; a column key drops the column; a row key
# drops the row; a (row, column) path sets the cell to the column's NA.
function _table_wout(t::AirTable, path::Vector{Any})
    isempty(path) && return _table_pop(t)
    if length(path) == 1
        k = path[1]
        if k isa Symbol && k !== COLON && haskey(t.schema, k)
            return _table_drop_col(t, k)
        end
        k === COLON && throw(AirEvalError("wout: a lone : names neither rows nor columns"))
        return _table_form(_table_drop_row(t, _table_row_index(t, k)))
    elseif length(path) == 2
        k1, k2 = path
        i = _table_row_index(t, k1)
        (k2 isa Symbol && k2 !== COLON && haskey(t.schema, k2)) ||
            throw(AirEvalError("wout: no column $(_colname_of(k2)) in the table"))
        return _table_set_cell(t, i, k2, to_form(t.schema[k2].na))
    end
    throw(AirEvalError("wout: a table path has at most a row and a column"))
end

# ---- equality, hash, printing, persistence -----------------------------------

function _table_equal(a::AirTable, b::AirTable)
    a.nrows == b.nrows || return false
    a.index == b.index || return false
    length(a.names) == length(b.names) || return false
    for nm in a.names
        haskey(b.schema, nm) || return false
        ma, mb = a.schema[nm], b.schema[nm]
        (ma.type === mb.type && isequal(ma.na, mb.na)) || return false
        ca, cb = a.columns[nm], b.columns[nm]
        length(ca) == length(cb) || return false
        for i in 1:length(ca)
            isequiv(to_form(ca[i]), to_form(cb[i])) || return false
        end
    end
    return true
end

function _table_hash(t::AirTable, h::UInt)
    h = hash(:AirTable, h)
    h = hash(t.nrows, h)
    h = hash(t.index, h)
    for nm in sort(Symbol[nm for nm in t.names]; by = String)
        h = hash(nm, h)
        meta = t.schema[nm]
        h = hash(meta.type, h)
        h = equivhash(to_form(meta.na), h)
        for c in t.columns[nm]
            h = equivhash(to_form(c), h)
        end
    end
    return h
end

# Printing shows the shape and the columns, never the cells.
function _extern_show_text(t::AirTable)
    colnames = String[String(nm)[2:end] for nm in t.names]
    cols = join(colnames, ", ")
    s = string("#table(", t.nrows, "×", length(t.names),
               isempty(t.names) ? "" : ": " * cols)
    t.index === nothing || (s *= "; index=" * String(t.index)[2:end])
    return s * ")"
end

_table_serialize(t::AirTable, io::IO) = print(io, AirDB.to_JSON(_table_payload(t)))
_table_deserialize(io::IO) = _table_from_payload(AirDB.from_JSON(read(io, String)))

function _table_payload(t::AirTable)
    metapairs = Pair{Symbol,Form}[]
    datapairs = Pair{Symbol,Form}[]
    for nm in t.names
        meta = t.schema[nm]
        push!(metapairs, nm => _tmap([
            Symbol(":type") => Form(Symbol(":" * String(meta.type))),
            Symbol(":na") => to_form(meta.na)]))
        col = t.columns[nm]
        push!(datapairs, nm => FormContainer(col, FormMap()))
    end
    return _tmap([
        Symbol(":names") => _tseq(Form[Form(nm) for nm in t.names]),
        Symbol(":meta") => _tmap(metapairs),
        Symbol(":data") => _tmap(datapairs),
        Symbol(":nrows") => Form(t.nrows),
        Symbol(":index") => (t.index === nothing ? naught : Form(t.index))])
end

function _payload_seq(x::Form)
    isequal(x, naught) && return Form[]
    x isa FormContainer || throw(AirEvalError(
        "table: a serialized column must be a sequence"))
    return Form[to_form(v) for v in x.seq]
end

function _table_from_payload(p::Form)
    p isa FormContainer || throw(AirEvalError("table: malformed serialized payload"))
    haskey(p, Symbol(":names")) || throw(AirEvalError(
        "table: the serialized payload has no names"))
    names = Symbol[]
    for v in _payload_seq(to_form(p[Symbol(":names")]))
        l = _leafof(v)
        l isa Symbol || throw(AirEvalError("table: malformed column name"))
        push!(names, l)
    end
    metaform = to_form(p[Symbol(":meta")])
    dataform = to_form(p[Symbol(":data")])
    (metaform isa FormContainer && dataform isa FormContainer) ||
        throw(AirEvalError("table: malformed serialized columns"))
    cols = Dict{Symbol,FormSeq}()
    sch = Dict{Symbol,_ColumnMeta}()
    for nm in names
        haskey(dataform, nm) || throw(AirEvalError("table: missing column data"))
        cells = _payload_seq(to_form(dataform[nm]))
        cols[nm] = FormSeq(FormValue[_store_form(c) for c in cells])
        haskey(metaform, nm) || throw(AirEvalError("table: missing column metadata"))
        mf = to_form(metaform[nm])
        mf isa FormContainer || throw(AirEvalError("table: malformed column metadata"))
        tl = _leafof(to_form(mf[Symbol(":type")]))
        tl isa Symbol || throw(AirEvalError("table: malformed column type"))
        ty = Symbol(startswith(String(tl), ":") ? String(tl)[2:end] : String(tl))
        naf = to_form(mf[Symbol(":na")])
        naf isa FormScalar || throw(AirEvalError("table: malformed NA marker"))
        sch[nm] = _ColumnMeta(ty, value(naf))
    end
    nl = _leafof(to_form(p[Symbol(":nrows")]))
    nl isa Integer || throw(AirEvalError("table: malformed row count"))
    il = _leafof(to_form(p[Symbol(":index")]))
    index = il isa Symbol ? il : nothing
    return _airtable(names, cols, sch, Int(nl), index)
end

# ---- the `table` form --------------------------------------------------------

# A column name from a user form: a keyword, a bare symbol, or a string.
function _table_name_of(x::Form, what::AbstractString)
    l = _leafof(x)
    l isa Symbol && return is_keyword(l) ? l : Symbol(":" * String(l))
    l isa AbstractString && return Symbol(":" * l)
    throw(AirEvalError("$what: a column name must be a keyword, symbol, or string, " *
                       "not " * air_string(x)))
end

function _table_type_of(x::Form, what::AbstractString)
    l = _leafof(x)
    l isa Symbol || throw(AirEvalError(
        "$what: a column type must be a keyword such as :int"))
    t = String(l)
    ty = Symbol(startswith(t, ":") ? t[2:end] : t)
    ty in _TABLE_TYPES || throw(AirEvalError(
        "$what: unknown column type :$ty (expected one of " *
        join(_ttypename.(_TABLE_TYPES), ", ") * ")"))
    return ty
end

function _bi_table(env::Env, scope::Scope, call::FormContainer)
    opts = Dict{Symbol,Form}()
    colentries = Pair{Symbol,Form}[]
    for (k, v) in call.map
        if k in _TABLE_OPTION_KEYS
            opts[k] = air_reduce(env, scope, to_form(v))
        else
            push!(colentries, k => air_reduce(env, scope, to_form(v)))
        end
    end
    rows = Form[]
    for v in _sx(call.seq, 2:length(call.seq))
        push!(rows, air_reduce(env, scope, to_form(v)))
    end
    !isempty(rows) && !isempty(colentries) && throw(AirEvalError(
        "table: give rows or columns, not both"))
    for r in rows
        (r isa FormContainer && isempty(r.seq)) || throw(AirEvalError(
            "table: every row must be a mapping of column names to values, got " *
            air_string(r)))
    end

    # The names come from the data, or from `columns=` for an empty table.
    names = Symbol[]
    cells = Dict{Symbol,Vector{Form}}()
    if !isempty(rows)
        names = sort(collect(keys(rows[1].map)); by = String)
        for r in rows
            Set(keys(r.map)) == Set(names) || throw(AirEvalError(
                "table: ragged rows: " * air_string(r)))
        end
        for nm in names
            cells[nm] = Form[to_form(r[nm]) for r in rows]
        end
    elseif !isempty(colentries)
        names = sort(Symbol[k for (k, _) in colentries]; by = String)
        for (k, v) in colentries
            cells[k] = _column_cells(v, "table")
        end
        lengths = unique(length(cells[nm]) for nm in names)
        length(lengths) <= 1 || throw(AirEvalError(
            "table: the columns do not all have the same length"))
    end

    if haskey(opts, _TABLE_COLUMNS_KEY)
        given = Symbol[_table_name_of(to_form(v), "table columns")
                       for v in _payload_seq(opts[_TABLE_COLUMNS_KEY])]
        length(unique(given)) == length(given) || throw(AirEvalError(
            "table: columns= repeats a column name"))
        if isempty(names)
            names = given
        elseif Set(given) != Set(names)
            throw(AirEvalError("table: columns= must name exactly the table's columns"))
        else
            names = given
        end
        for nm in names
            get!(cells, nm, Form[])
        end
    end

    types = Dict{Symbol,Symbol}()
    if haskey(opts, _TABLE_TYPES_KEY)
        tf = opts[_TABLE_TYPES_KEY]
        (tf isa FormContainer && isempty(tf.seq)) || throw(AirEvalError(
            "table: types= must be a mapping of column names to types"))
        for (k, v) in tf.map
            haskey(cells, k) || throw(AirEvalError(
                "table: types= names a column $(_colname(k)) the table does not have"))
            types[k] = _table_type_of(to_form(v), "table types")
        end
    end

    nas = Dict{Symbol,Any}()
    if haskey(opts, _TABLE_NA_KEY)
        nf = opts[_TABLE_NA_KEY]
        (nf isa FormContainer && isempty(nf.seq)) || throw(AirEvalError(
            "table: na= must be a mapping of column names to markers"))
        for (k, v) in nf.map
            haskey(cells, k) || throw(AirEvalError(
                "table: na= names a column $(_colname(k)) the table does not have"))
            x = to_form(v)
            x isa FormScalar || throw(AirEvalError(
                "table: the NA marker for $(_colname(k)) must be a scalar value"))
            nas[k] = value(x)
        end
    end

    index = nothing
    if haskey(opts, _TABLE_INDEX_KEY)
        index = _table_name_of(opts[_TABLE_INDEX_KEY], "table index")
        index in names || throw(AirEvalError(
            "table: the index column $(_colname(index)) is not a column of the table"))
    end

    cols = Dict{Symbol,FormSeq}()
    sch = Dict{Symbol,_ColumnMeta}()
    nrows = 0
    for nm in names
        cs = get(cells, nm, Form[])
        meta, col = _table_column(nm, cs; type = get(types, nm, nothing),
                                  na = get(nas, nm, nothing))
        cols[nm] = col
        sch[nm] = meta
        nrows = length(cs)
    end
    return _table_form(_airtable(names, cols, sch, nrows, index))
end
special!(:table, _bi_table)

# ---- air-level surface -------------------------------------------------------

builtin!(Symbol("table?"), (env, scope, args) ->
    _bool(_table_of(_arg(args, 1, "table?")) !== nothing))

function _table_arg(args, name::AbstractString)
    t = _table_of(_arg(args, 1, name))
    t === nothing && throw(AirEvalError(
        "$name expects a table, got " * air_string(_arg(args, 1, name))))
    return t
end

builtin!(:columns, (env, scope, args) ->
    _tseq(Form[Form(nm) for nm in _table_arg(args, "columns").names]))

builtin!(:schema, (env, scope, args) -> begin
    t = _table_arg(args, "schema")
    pairs = Pair{Symbol,Form}[]
    for nm in t.names
        meta = t.schema[nm]
        push!(pairs, nm => _tmap([
            Symbol(":type") => Form(Symbol(":" * String(meta.type))),
            Symbol(":na") => to_form(meta.na)]))
    end
    return _tmap(pairs)
end)

builtin!(:nrows, (env, scope, args) -> Form(_table_arg(args, "nrows").nrows))

builtin!(Symbol("table-index"), (env, scope, args) -> begin
    t = _table_arg(args, "table-index")
    t.index === nothing ? naught : Form(t.index)
end)

# ---- registration ------------------------------------------------------------

function _register_table!()
    air_register_extern!(:table, AirTable; immutable = true,
                         serialize = _table_serialize,
                         deserialize = _table_deserialize,
                         equal = _table_equal, hash = _table_hash)
    return nothing
end
