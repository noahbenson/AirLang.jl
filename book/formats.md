# Data formats

air reads and writes six text formats — JSON, YAML, TOML, CSV, TSV, and
`.env` — as **plain air data**. An object or table becomes a map form, an array
a sequence form, and a scalar a scalar; CSV and TSV decode to a
[`table`](tables.md) and encode from one. Nothing else becomes an extern type,
and nothing in a file is ever executed. Decoding is therefore safe: a YAML file
cannot construct an object or call a function, however its tags are written.

```air
(decode "{\"a\": [1, 2], \"b\": null}" format=:json)   # => (a=(1 2) b=naught)
(encode (a=(1 2) b=naught) format=:json)               # => "{\"a\":[1,2],\"b\":null}"
```

| form | meaning |
| --- | --- |
| `(decode x format=:json)` | parse text (a string or `bytes`) into a form |
| `(encode v format=:json)` | encode a form as text |
| `(read-data path)` | read a file, inferring the format from its name |
| `(read-data path format=:yaml)` | read a file in an explicit format |
| `(write-data path v)` | encode `v` and write it to a file |
| `(write-data path v format=:toml)` | write in an explicit format |

`format` accepts a keyword, a symbol, or a string, and `yml` and `dotenv` are
aliases of `yaml` and `env`. The default for `decode` and `encode` is `:json`.
`read-data` and `write-data` infer the format from the extension (`.json`,
`.yaml`, `.yml`, `.toml`, `.csv`, `.tsv`, or the file name `.env`) and raise
when they cannot.

```air
(read-data "config.toml")               # => (server=(host="localhost" port=8080))
(write-data "out.yaml" (a=1 b=(1 2)))   # writes "a: 1\nb:\n  - 1\n  - 2\n"
```

Like `write-file`, `write-data` defers the write to the transaction commit, so a
transaction that aborts writes nothing.

The path helpers are **gated by the `filesystem` permission on `.air.sys`**, and
a fresh instance grants it only to `air`: `read-data` and `write-data` refuse
any other identity with `(:permission-denied :filesystem :read-data)` until
`air` runs `(chmod! .air.sys filesystem=(:alice))`. Startup code and libraries
(which run as `air`) use them freely; a shared configuration value reaches a
user through a namespace or a database, not through a host path. `decode` and
`encode` touch no file — they read a string or a `bytes` value — and need no
permission. See [users, homes, and permissions](permissions.md#the-filesystem).

## The data mapping

The formats differ in what they can express; the mapping to forms is the same.

| data | air |
| --- | --- |
| object / table / mapping | a map form, `(a=1 b="x")` |
| array / sequence | a sequence form, `(1 2 3)` |
| a scalar | the scalar, `1`, `2.5`, `true`, `"x"` |
| null | `naught` |
| an empty object or array | `naught` |

Because an empty object and an empty array both become `naught`, the round trip
is **lossy for empty containers**: `{"a": {}}` and `{"a": []}` both encode as
`(a=naught)`, which writes back as `{"a": null}`. A *list* holding empties keeps
its length — `[{}, []]` is `(naught naught)` — but each element is null.

A map key is normalized to its text, so `{1: "x"}` and `{"1": "x"}` name the
same air key. In a form the key is the air keyword spelling, which is the text
with a leading `:`; the printer drops that colon, so keys read naturally. Two
keys that normalize alike are a **duplicate** and raise rather than silently
overwriting.

A value is plain data if it is a scalar, a string, a keyword or symbol (which
encode as their text), a sequence of plain data, or a map of plain data. A
container that mixes sequence elements and map entries (`(f a=1)`) has no
representation in any format and raises. So does an extern, a mutable, a
reference form, a rational, or a complex number. Map keys are emitted in sorted
order in every format, so encoding is deterministic.

A [`table`](tables.md) is the one extern with a plain-data shape: it encodes as
an array of its row maps, `[{"a":1,"b":"x"},{"a":2,"b":"y"}]`. Decoding that
returns the row maps, not a table — the schema is not carried by JSON or YAML —
so use CSV/TSV when a table needs to round-trip.

```air
(encode (name="x" count=1) format=:json)     # => "{\"count\":1,\"name\":\"x\"}"
(encode (1 a=2) format=:json)                # a map and a sequence in one form: error
(encode (/ 1 3) format=:json)                # a rational has no data representation: error
```

## JSON

The reader is strict RFC 8259: objects, arrays, strings with the standard
escapes and `\u` surrogate pairs, `true`/`false`/`null`, and numbers with no
leading zero, trailing decimal point, or stray text. A duplicate key, an
unpaired surrogate, a truncated document, or trailing garbage is an error.

An integer that fits `Int64` decodes as an `Int64`, a larger one as a `BigInt`,
and a number with a fraction or exponent as a `Float64`. Encoding rejects a
non-finite float (`inf`, `-inf`, `nan`), because JSON has no spelling for one.

```air
(decode "[1, 2.5, true, null, \"x\\n\"]")       # => (1 2.5 true naught "x\n")
(decode "9223372036854775808")                  # a BigInt
(encode naught format=:json)                    # => "null"
```

## YAML

The YAML reader covers the practical subset a configuration file uses and is
**safe by construction**:

* block mappings and sequences (`a: 1`, `- 1`), with sequences permitted at the
  indentation of their parent key;
* flow mappings and sequences (`{a: 1}`, `[1, 2]`), which may span lines;
* plain, single-quoted, and double-quoted scalars, with `''` doubling and the
  Julia-style escapes (`\n`, `\t`, `\x`, `\u`, `\U`, `\N`, `\_`, `\L`, `\P`);
* block scalars — literal `|` and folded `>`, with the strip (`-`), clip, and
  keep (`+`) chomping modes and explicit indentation indicators;
* comments, anchors and aliases (`&name` / `*name`), the `<<` merge key, and
  multi-document streams (`---` / `...`);
* the core-schema resolution of plain scalars.

In the core schema a plain `~`/`null` is `naught`, `true`/`false` are booleans,
decimal, `0x`, and `0o` integers are integers, and `.inf`/`.nan` are floats.
Everything else — including `yes`/`no`/`on`/`off` (which YAML 1.1 treats as
booleans) and bare dates — stays a **string**, as YAML 1.2 says.

```air
(decode "a: [1, 2]\nb:\n  c: |\n    x\n    y\n" format=:yaml)
# => (a=(1 2) b=(c="x\ny\n"))
(decode "yes: 2026-10-30\n" format=:yaml)     # => (yes="2026-10-30")
```

**Tags are never constructed.** The core tags (`!!str`, `!!int`, `!!float`,
`!!bool`, `!!null`, `!!map`, `!!seq`) are understood and apply their type; any
other tag — `!!python/object`, `!custom`, a `%TAG` directive — is an **error**.
That is the whole safety property: a YAML file from an untrusted source can only
produce data.

The reader bounds its work: nesting deeper than 256 levels, more than one
million nodes (including the size an alias expands to), a tab in indentation, or
an unknown alias is an error. Anchors are expanded when an alias is read, so an
"alias bomb" fails at the node limit instead of exhausting memory.

A stream with more than one document needs `documents=true`, which returns them
as a sequence; an empty or comment-only stream is `naught`. The encoder writes
block style with sorted keys, and a multi-document stream cannot be encoded
(encode each document and join them yourself).

```air
(decode "---\na: 1\n---\nb: 2\n" format=:yaml documents=true)   # => ((a=1) (b=2))
(decode "a: !!int \"5\"\n" format=:yaml)                       # => (a=5)
(decode "a: !!python/object x\n" format=:yaml)                 # error: unsupported tag
```

## TOML

TOML maps onto forms directly: a table is a map form, an array a sequence form,
and an inline table a nested map. The document itself must be a table, so the
top level of a decoded TOML file is always a map form (an empty document is
`naught`). Tables encode after the scalar entries, as `[section]` headers; an
array is written inline, with a map element as an inline table.

TOML has no null, so a `naught` *value* cannot be encoded; only the empty
document is `naught`.

```air
(decode "port = 8080\n[db]\nhost = \"x\"\n" format=:toml)
# => (db=(host="x") port=8080)
(encode (port=8080 db=(host="x")) format=:toml)
# => "port = 8080\n\n[db]\nhost = \"x\"\n"
(encode (a=naught) format=:toml)             # error: TOML has no null
```

TOML integers are 64-bit, so a `BigInt` outside that range raises. A float is
written as `nan`, `inf`, `-inf`, or a decimal that always keeps a fractional
part.

TOML has native dates, times, and datetimes, which have no counterpart among
air's values. They decode as marker forms that carry the literal text:

```air
(decode "d = 2026-10-30\nt = 12:30:00\nk = 2026-10-30T12:30:00\n" format=:toml)
# => (d=(toml-date "2026-10-30") k=(toml-datetime "2026-10-30T12:30:00")
#     t=(toml-time "12:30:00"))
```

The markers are ordinary air data — a two-element form headed `toml-date`,
`toml-time`, or `toml-datetime`. Encoding one writes its text unquoted when the
text is a valid literal of that kind and raises otherwise, so a marker never
silently becomes a string. Any other form of the same shape is an ordinary map.

The standard library's TOML parser rejects an offset date-time (`2026-10-30T12:30:00-08:00`);
a trailing `Z` is accepted but its UTC offset is dropped.

## CSV and TSV

A decode produces a [`table`](tables.md); an encode accepts a table or a
non-empty sequence of row maps. The parser is a dependency-free RFC 4180 state
machine over UTF-8 text, and the column and row delimiters are options.

| option | decode | encode |
| --- | --- | --- |
| `header` | absent: infer; `true`: the first record names the columns; `false`: `:col1`…`:colN`; `(names…)`: explicit names, no header consumed | `true` (default) writes the names; `false` omits them; `(names…)` writes explicit labels |
| `column-delimiter` | one-character string; default `,` (`\t` for tsv) | same |
| `row-delimiter` | string; default LF, accepting CRLF/LF/CR; when given, only that string ends a record and CR/LF are data | same; default `\n` |
| `types` | per-column type override | per-column output coercion |
| `na` | per-column missing marker | per-column missing marker |
| `columns` | rejected (use `header=(…)`) | select and order the output columns |
| `index` | declare the table's index column | rejected |

```air
(decode "name,age\nBob,51\nSue,42" format=:csv)     # => #table(2×2: name, age)
(schema (decode "name,age\nBob,51\nSue,42" format=:csv))
# => (age=(na=NA type=:int) name=(na=NA type=:string))
(decode "1,2\n3,4" format=:csv)                     # => #table(2×2: col1, col2)
(encode (table a=(1 2) b=("x" "y")) format=:csv)    # => "a,b\n1,x\n2,y\n"
(encode ((a=1 b="x") (a=2 b="y")) format=:csv)      # the same text
```

**Header inference.** When `header` is absent, the first record is a header iff
no field in it is a *plain number*: a canonical integer spelling (no leading
zeros), or a finite `Float64` (a fraction or exponent). Empty fields, `NA`, and
`NaN` do not count, so an all-string first row is a header and a row with any
number is data. This is a heuristic: a headerless all-string file loses its
first row, and a header row containing a numeric-looking field is treated as
data — pass `header=` whenever either is possible. `header=false` always names
the columns `:col1`…`:colN`, and `header=("x" "y")` names them explicitly
without consuming a record.

**Parsing.** A quote opens a quoted field only at its start; inside it a
doubled `""` is a literal quote and every delimiter and newline is data. A quote
inside an unquoted field, text after a closing quote, or an unterminated field
raises, as does a record whose width differs from the header's. CRLF, LF, and CR
all end a default-delimited record and a trailing terminator adds no row, so an
empty text is a 0-row table. Errors name the record number.

**Types and NA.** Fields are inferred with canonical rules: `:int` only for an
optional `-` and digits with no leading zero (so `007` stays a string), `:float`
only for a finite parse that is not an integer (so `1e3` is a float), `:bool`
only for `true`/`false`, and otherwise `:string`. `types=` overrides the
inference; declaring `:string`, `:symbol`, or `:keyword` keeps the field's text,
while `:int`, `:float`, `:number`, and `:bool` parse it. An empty field is the
column's NA, and the text `NA` or `NaN` is missing unless the column declares a
different marker with `na=`. A missing cell writes back as an empty field.

```air
(schema (decode "a,b\n1,2.5" format=:csv))
# => (a=(na=NA type=:int) b=(na=NaN type=:float))
(get (decode "a\n007\n1e3\ntrue\nNA" format=:csv) :a)
# => ("007" 1000.0 true NA)
(decode "n,a\nBob,1\nSue,2" format=:csv index=:n)   # an indexed table
(encode (table a=(1 NA) b=(NaN 2.0)) format=:csv)   # => "a,b\n1,\n,2.0\n"
(encode (table a=(1 2)) format=:csv columns=(:a) header=false)   # => "1\n2\n"
```

**TSV is not the IANA backslash convention.** It is RFC 4180 quoting with a tab
column delimiter: a tab, a newline, or a `"` inside a field is quoted by doubling
the quotes, exactly as for CSV.

**What is lost.** CSV carries no types of its own: a symbol or keyword decodes as
a string unless `types=` says otherwise, a `"007"` field stays a string, and a
`naught` cell cannot be spelled (declare an `na=` and use it, or encode a
different format). Encoding a `naught` cell, a container cell, or a non-finite
float that is not the column's NA raises.

## `.env`

A `.env` file is a flat mapping of variable names to text. Decoding accepts
comments, blank lines, an `export ` prefix, and empty, single-quoted,
double-quoted, and bare values; an unquoted `#` after whitespace starts a
comment, and `\n`, `\t`, `\\`, `\"`, and `\'` are recognized in double quotes.
A name must be a letter or `_` followed by letters, digits, `_`, `.`, or `-`.
Duplicate names and a line that is not `name=value` raise.

Every value is a **string** — `.env` has no numbers, booleans, or nulls — so
`A=1` decodes as `(A="1")`. Encoding requires a map at the top level whose
values are scalars; a `naught` value writes an empty value, and a value needing
quotes is double-quoted.

```air
(decode "export A=1\nB=\"x y\"\n" format=:env)     # => (A="1" B="x y")
(encode (B="x y" A="1") format=:env)               # => "A=1\nB=\"x y\"\n"
(encode (a=(1 2)) format=:env)                     # error: .env values are strings
```

Note that `.env` keys are conventionally uppercase, but air does not enforce or
change case: `(A="1")` writes `A=1` and `(a="1")` writes `a=1`.

## Differences from `to-json`

[Databases](databases.md) describes AirDB's `to-json` and `from-json`, which
also produce text. They are a *serialization* codec: a volatile becomes a
`"@uuid"` link, a non-finite float is the marked string `"#inf"`, and a cycle is
legal. `encode`/`decode` are a *data* codec: every value is written out
literally, links are not followed, and a non-finite float or a cyclic value is
an error. Use `to-json` to move air values between databases and `encode` to
exchange plain data with another program.

## Limits

* JSON nesting is bounded at 512 levels; YAML at 256, with a one-million-node
  total.
* JSON, YAML, TOML, and `.env` round-trip plain, non-empty data exactly under
  `eq?`; `decode(encode(x))` is *not* `x` for an empty container, which becomes
  `naught`, or for a TOML date marker written to another format, which becomes a
  map or a string. A table round-trips through CSV/TSV with its schema, but a
  symbol, keyword, or `"007"` field returns as a string unless `types=` names
  the column's type.
* There is no spreadsheet reader (`.xlsx` and friends) yet; CSV and TSV are
  covered above.
