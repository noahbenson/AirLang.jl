# Documentation and the builtin catalogue

Air documents itself. Every builtin and operator — 576 builtins and 17
operators, plus the reserved heads `error`, `signal`, and `ui` — has an entry
in a process-global catalogue, so nothing in the language is reachable only
through an external manual. The catalogue, the air-level docstrings on your own
`def`s, and the namespace listings are all ordinary air values, so a REPL
session, an agent, and this book read the same source.

## `(help)` and `(doc)`

`(help)` prints an introduction to the language: the form, evaluation, holds,
namespaces, and errors in a page, ending with a list of things to try next.

`(doc)` and `(doc .air)` return the **index** — every documented name grouped by
category, with a count per category. `(doc NAME)` returns one entry: the name,
its category as `(builtin :collection)`, and the catalogue text. `(doc .air.NAME)`
is the same lookup through the core namespace, and `.air.NAME` also names any of
them as a callable: `(.air.sqrt 9)` is `3.0`.

`(doc NAME)` (and `(doc .air.NAME)`) then lists the documented `def` rules that
use the name, newest first, each with its docstring. `(doc (form…))` holds its
argument rather than evaluating it and lists the documented rules whose patterns
**match that form**, which is how you find out which definition handles
`(doc (log 1.0))`:

```air
(doc .air.sqrt)     # the builtin entry
(doc log)           # the builtin (if any) plus every documented rule using log
(doc (log 1.0))     # only the rules that match that call
```

`(help NAME)` prints exactly the text `(doc NAME)` returns; `(help :category)`
prints one category's name list, and `(help :all)` prints the whole index.
Both write through the environment's output stream, so a session over SSH
prints to that client.

## Docstrings on your own definitions

A literal string at the head of a `def` body is the rule's **docstring**. It is
removed from the executable body, deindented, and recorded with the definition
in its namespace, so it survives a reload and a restart. The same `doc`/`help`
machinery reads it; [Patterns](patterns.md#docstrings) describes the
placement rules.

`(definitions arg)` takes the same argument as `(doc …)` but returns the
matching `def` forms as held data instead of text. Each docstring moves from the
head of the body into a `doc=` map entry, and a `hold=` or `memoize=` option is
reproduced:

```air
(definitions log)
# => ((' def (log ?x \ number?) ... doc="Returns the natural log of x.") …)
```

Because the forms are quoted data, a body that needs to unhold at run time uses
`(unhold x)` rather than `~` — see the note at the end of
[Docstrings](patterns.md#docstrings).

## The catalogue itself

The catalogue is air source: `src/core.air` holds one `(docdef CATEGORY name…
"text"…)` form per name, or per family of names that share a description. It is
read into `BUILTIN_DOCS` when the package loads, so changing it invalidates the
image rather than requiring a rebuild of the documentation.

* The optional first element is the **category**; it names the index group.
* The names are raw symbols, or a form of them, so a family documents together.
* The trailing strings are joined and deindented into one text.

**Registration semantics.** A `docdef` is a registration like `layout`, not a
definition: it is process-global, neither scoped nor transactional, and
`sandbox` does not undo one. The first entry for a name fixes its category and
its place in the index; a later `docdef` **amends** it, appending its text as a
further paragraph. That is how a specialized entry can extend a general one —
the `get` entry for a tensor path follows the general `get` entry rather than
replacing it. A library can document the names it adds the same way, which is
why `core.air` is ordinary air source rather than a Julia table.

A `docdef` accepts the reserved heads (`error`, `signal`, `ui`, and any builtin)
precisely because it documents a name rather than defining one; a `def` could
not define them.

## Listing namespaces

The builtin catalogue covers what ships with the language. The definitions in a
namespace are listed by the namespace forms, all of which default to the current
namespace and filter by permission — an entry the caller may not read is
**absent**, exactly as in `using` and `doc`:

| form | returns |
| --- | --- |
| `(ns-entries [target])` | one `(entry name=… kind=… owner=…)` record per entry |
| `(ns-entry [target] name)` | one entry record, or `naught` |
| `(ns-vals [target])` | the readable `val` names as keywords |
| `(ns-defs [target])` | the readable `def` rules, each held with `def` replaced by `'` |
| `(ns-facts [target])` | the implicit logic set's facts, as a held list |
| `(ns-rules [target])` | the implicit logic set's rules, as a held list |

```air
(namespace .util (val answer 42) (def (twice ?x) (* x 2)))
(ns-vals .util)   # => (:answer)
(ns-defs .util)   # => ((' def (twice ?x) (* x 2)))
(ns-facts .util)  # => (')
```

`ns-entries` adds `doc=`, `src=`, and `source=` metadata when present, and
`src=true` includes the stored source text.
[Namespaces](namespaces.md#listing-entries) covers the entry record and its
`kind`s; [Production rules](rules.md#production-rules)
covers the fact and rule listings.

## Reading this book

The chapters are ordered so that each one uses only ideas introduced earlier.
If you are new to the language, read
[Getting started](getting-started.md), then [Syntax](syntax.md), [The data
model](data-model.md), and [Collections](collections.md); after that the order
of the table of contents is a working path. If you are looking for a particular
name, `(doc NAME)` is faster than the book, and if you are looking for a
particular *job*, [How to read this book](index.md#how-to-read-this-book)
groups the chapters by area.
