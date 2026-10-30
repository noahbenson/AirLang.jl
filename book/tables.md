# Tables

A **table** is air's tabular value: named, typed, ordered columns of immutable
data, with an optional unique index. It is a persistent value like a form — an
update returns a new table and leaves the old one untouched — and it is backed
by Air's persistent vectors and dictionaries, so a column access is O(1), a cell
update is O(log n), and updates share structure with the table they came from.

A table is column-major. `(columns t)` preserves the declared order, a column
returns as an ordinary sequence, and a row returns as an ordinary map form whose
keys are the column names.

```air
(table name=("Bob" "Sue") age=(51 42))
# => #table(2×2: age, name)
```

Tables are an immutable extern type (`AirTable`), not a form: a schema and type
information cannot live in a plain form, and a plain sequence of row maps would
make a column access O(n) and a cell update O(n). Everything below is an
ordinary air value operation on top of that representation.

## Constructing a table

There are two spellings, and they build the same table:

```air
(table (name="Bob" age=51) (name="Sue" age=42))   # sequence elements are rows
(table name=("Bob" "Sue") age=(51 42))            # map entries are columns
(eq? (table (name="Bob" age=51) (name="Sue" age=42))
     (table name=("Bob" "Sue") age=(51 42)))      # => true
```

* **Rows.** Each sequence element is a map-only form; every row must name the
  same columns, or the constructor raises.
* **Columns.** Each map value is a sequence (its cells), `naught` (an empty
  column), or a scalar (a one-element column). Every column must have the same
  length.
* Rows and columns may not be mixed in one call.

The reserved keys `columns=`, `types=`, `na=`, and `index=` configure the table
rather than naming a column. A column literally named one of them is written
with row syntax or with `(table columns=(…) …)`. With no rows or columns,
`columns=` names the columns and gives a typed 0-row table.

```air
(table)                                    # => #table(0×0)
(table columns=(:a :b) types=(a=:int))     # => #table(0×2: a, b)
(table b=(1) a=(2) columns=(:b :a))        # the order is b, a
```

Without `columns=`, the names are sorted by their text, so `(table b=(1) a=(2))`
prints `#table(1×2: a, b)`. The order matters only for display and output; it
does not affect equality.

## Values, types, and NA

A cell is plain immutable air data: a scalar, a string, a keyword or symbol, or
a nested plain container. An extern (including `bytes` and another table), a
mutable, or a reference form is refused.

Each column records a **type** and an **NA marker** in its metadata. The types
are `:int`, `:float`, `:number`, `:string`, `:bool`, `:symbol`, `:keyword`,
`:naught`, and `:any`. The type is inferred from the non-missing cells unless
`types=` overrides it:

```air
(schema (table a=(1 2) b=(1 2.5) c=(true false) d=("x" "y")))
# => (a=(na=NA type=:int) b=(na=NaN type=:number)
#     c=(na=NA type=:bool) d=(na=NA type=:string))
```

A column with one cell type is that type; mixed integers and floats are
`:number`; a mix across families is `:any`; an all-missing column is `:naught`.
`types=` coerces, so strings can be parsed into numbers:

```air
(get (table a=("1" "2") types=(a=:int)) :a)    # => (1 2)
```

**Missing data is in band.** A cell equal to its column's NA marker is missing;
there is no separate null. Each column's default marker is `NaN` for a
`:float`/`:number` column and the predefined symbol `NA` for every other column,
and `na=` declares a different marker:

```air
(schema (table a=(1 2)))            # => (a=(na=NA type=:int))
(schema (table a=(1.0 2.0)))        # => (a=(na=NaN type=:float))
(schema (table a=(1 0) na=(a=0)))   # => (a=(na=0 type=:int))
(get (table a=(1 0) na=(a=0)) :a)   # => (1 0), and 0 is missing
```

An explicit marker is authoritative: with `na=(a=0)` the canonical `NA` and
`NaN` are ordinary data and are type-checked. The cost of an in-band marker is
that a legitimate value equal to the marker is indistinguishable from missing;
declare a different `na=` where that matters. In particular, a real `NaN` in a
float column is missing unless the column declares another marker.

`NA` is a fixed point of reduction: `NA` reduces to itself and no binding or
definition may shadow it (`(let (NA=5) NA)` raises). It is distinct from the
keyword `:NA` and the string `"NA"`.

## Access

`get` is the single accessor. An integer names a row, a keyword (or a string
naming a column) names a column, and any other key is looked up in the index.

```air
(let (t=(table name=("Bob" "Sue") age=(51 42)))
  ((get t :age)          # the whole column: => (51 42)
   (get t 1)             # a row map: => (age=51 name="Bob")
   (get t 1 :age)        # a cell: => 51
   (get t :age 1)))      # the same cell in the other order: => 51
```

Row `0` is the table itself, negative rows count from the end, and `default=`
supplies a value when the row or column is missing. `nth`, `first`, `last`,
`second`, `third`, and `rest` treat the table as its rows; `count` and `length`
are the row count. A table is not a sequence: `join`, `merge`, and `update-in`
refuse it rather than silently downgrading it.

## Updating

Every update returns a new table.

```air
(with t :age (60 70))        # replace a whole column (or add one)
(with t 2 (age=99))          # update the named cells of a row
(with t 2 (age=99))          # a partial row leaves the other columns alone
(with t (2 :age) 99)         # set one cell — row then column
(with t score=(1 2))         # a map entry also names a column
```

`:` is the wildcard for "all rows" or "all columns", so `(with t (: :age) v)`
is `(with t :age v)` and `(with t (2 :) v)` is `(with t 2 v)`; a lone `:` names
neither and raises (the wildcard's meaning on ordinary forms — every element of
an ordered level — is in [the data model](data-model.md#1-forms-and-collections)).
A new column's type and NA are inferred from its values,
an existing column's metadata is enforced, and a value of the wrong type or
length raises. A table cell is always a value, so a table reduces its update
value before inserting it.

```air
(push t (name="Z" age=3))    # a positional map appends a row
(push t score=(1 2))         # a map entry appends a column
(pop t)                      # remove the last row
(drop t 2)                   # remove a row
(wout t :age)                # remove a column
(wout t (2 :age))            # set one cell to its column's NA
```

A table is an ordinary form container for the `hold-` family. `hold-get` returns
a column, row, or cell held; `hold-with`, `hold-push`, and `hold-wout` return the
updated table held; and an inserted held value contributes its content, because a
table cell is always a value. `hold=false` asks for the plain result, and a
held table is opaque to the hold-blind accessors, so read from one with
`hold-get`:

```air
(hold-get t :age)                                # => (' 51 42)
(hold-get (hold-with t :age (' (60 70))) :age)   # => (' 60 70)
(hold-get (hold-push t score=(' (3 4))) :score)  # => (' 3 4)
```

## Index columns

A column may be declared the table's **index** with `index=:name`. Every value
in it must be a scalar, non-missing, and unique; those values then address rows:

```air
(let (t=(table name=("Bob" "Sue") age=(51 42) index=:name))
  ((get t "Bob")                        # => (age=51 name="Bob")
   (get (with t ("Bob" :age) 60) "Bob")))   # => (age=60 name="Bob")
```

`(table-index t)` is the index column, or `naught`. Integer keys always mean
row positions, so an index column whose values are integers is not addressable
by a bare integer key. Every update maintains the index: a cell or row change
replaces the old key, `push` inserts, `pop` and row removal delete, and removing
the index column clears the declaration. Duplicate or missing index values
raise.

## Iteration

The collection verbs treat a table as its rows, building one row map at a time:

```air
(let (t=(table name=("Bob" "Sue") age=(51 42)))
  ((for (r t) r.age)                        # => (51 42)
   (map (?r -> r.age) t)                    # => (51 42)
   (filter (?r -> (r.age > 45)) t)          # => ((age=51 name="Bob"))
   (reduce ((?a ?r) -> (a + r.age)) 0 t)))  # => 93
```

`map` with `depth=0` maps the table itself. `haskey` and `in` test a row or a
column, and a 0-row table iterates zero times, so `reduce` returns its initial
accumulator.

## Equality, printing, and persistence

`eq?` compares tables by content: the same rows and cells, the same column
metadata (type and NA), and the same index declaration. Column *order* is not
part of equality, matching air's map semantics; `columns` still preserves it
for output. `hash` follows `eq?`.

Printing is a summary, never the cells: `#table(2×2: age, name)` and, with an
index, `#table(2×2: age, name; index=name)`.

A table is stored in its namespace's database like any value, using its
serialization registration. Like every unnamed extern, it survives a database
write in the same process but cannot be reconstructed from `to-json`/`from-json`
text, which yields a dead extern. Do not use the serialization JSON as a
transport; use `encode`/`decode` with a data format instead.

## CSV and TSV

`decode` with `format=:csv` or `:tsv` returns a table, and `encode` accepts a
table or a non-empty sequence of row maps. The format options — `header`,
`column-delimiter`, `row-delimiter`, `types`, `na`, `columns`, and `index` — are
described in [Data formats](formats.md#csv-and-tsv).

```air
(decode "name,age\nBob,51\nSue,42" format=:csv)     # => #table(2×2: name, age)
(encode (table a=(1 2) b=("x" "y")) format=:csv)    # => "a,b\n1,x\n2,y\n"
```

## Limitations

* Missing data is in band: a real value equal to the NA marker cannot be
  distinguished from missing.
* An integer-valued index column is not addressable by a bare key, because an
  integer always names a row position.
* A table's cells are plain data, so a table cannot hold an extern, a mutable, or
  a reference form.
* Saving a table as a SQL table is a planned follow-up; the extern is already
  persistent, but it is not mapped onto columns and rows in the database.
