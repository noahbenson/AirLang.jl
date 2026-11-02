# Air

**Air** is a Clojure- and Mathematica-inspired scripting language that runs on
Julia. It is implemented by **AirLang.jl**, which builds on two libraries:

- **[Air.jl](https://github.com/noahbenson/Air.jl)** — Clojure-like immutable
  data structures and a software transactional memory (STM); and
- **[AirDB.jl](https://github.com/noahbenson/AirDB.jl)** — a persistence layer
  that stores Air forms in PostgreSQL `jsonb` tables in transaction order.

Air's two rule systems make it a natural interface to a reasoning and rules
system: one evaluates code by term rewriting (`def`, `replace`, lambdas), and
the other derives and maintains facts in a logic set (`assert`, `rule`,
`query`). Everything — code, data, rules, and errors — is the same kind of
immutable, inspectable form.

```{admonition} The short version
:class: tip
Air is a Lisp whose values are JSON-like forms, whose functions are rewrite
rules, whose namespaces are multi-user logic sets persisted in PostgreSQL, and
whose errors are matched structurally rather than by class.
```

## A first taste

```air
(+ 1 2)                             # => 3
(let (x=2 y=3) (* x y))             # => 6
(thread (f (1 2 3)))                # => ((f 1) (f 2) (f 3))
(replace ((a 1) (a 2)) ((a ?x) -> x) depth=1)   # => (1 2)
```

Definitions are patterns, and the body is a replacement:

```air
(def (fact ?n)
  (if (< n 2) 1 (* n (fact (- n 1)))))

(fact 5)                            # => 120
```

Facts and rules live in a namespace, which is implicitly a logic set:

```air
(namespace .app)
(assert .app (depends :app :lib1))
(assert .app (rule (depends ?x ?y) :> (needs ?x ?y)))

(facts .app)                        # => (' (depends :app :lib1) (needs :app :lib1))
(query .app (needs ?x ?y))          # => ((x=:app y=:lib1))
```

## How to read this book

The chapters are ordered so that each one builds only on ideas introduced
before it, and the table of contents is a reasonable reading order end to end.

**Foundations.** [Getting started](getting-started.md) installs air and opens a
REPL. [Syntax](syntax.md) covers atoms, comments, strings, forms, and the
evaluator. [The data model](data-model.md) describes the form itself, the
scalar shapes, quoted forms (holds), and the three equality relations.
[Control flow and bindings](control.md) adds truthiness, `if`/`cond`, `let`,
loops, and sequencing. [Errors](errors.md) introduces the block grammar —
`do`, `except`, `catch=`, `handle`, `finally` — that later chapters use.
[Patterns and function definitions](patterns.md) is the heart of the language:
wildcards, `def`, lambdas, `case`, memoization, and docstrings.

**Data types and collections.** [Numbers](numbers.md) is the numeric tower and
the math verbs. [Strings and regexes](strings.md) is text and patterns: string
operations, regex values, and formatting. [Collections](collections.md) is the
accessor and update surface, the wildcard key, higher-order verbs, threading,
and traversal. [Tables](tables.md) adds typed, indexed tables.

**Namespaces and rules.** [Namespaces](namespaces.md) is the dotted namespace
tree, `using`/`use`/`import`, thread-local values, and the listings;
[users and permissions](permissions.md) is homes, ACLs, and `assume`;
[the two rule systems](rules.md) contrasts rewriting with the deductive engine,
and the [production-rule reference](production-rules.md) is the engine's own
chapter.

**Mutation and concurrency.** [Mutability and transactions](mutability.md) is
`mut`, filters, watches, `tx`, and `sandbox`. [Tensors](tensors.md) uses that
machinery for mutable N-dimensional arrays and the `{…}` reservations that guard
them. [Tasks, delays, actors, and promises](concurrency.md) is work that is not
a reduction; [Streams](streams.md) is durable queues; [Events and durable
tasks](events.md) is scheduling work for later.

**Storage and data exchange.** [Loading files and libraries](libraries.md)
covers `load-air`, the library path, and `init.air`. [Databases](databases.md)
covers opened AirDB roots, named forms, sync, and JSON. [Data formats](formats.md)
covers JSON, YAML, TOML, CSV, TSV, and `.env` as plain air data.

**Interfaces.** [SSH access](ssh.md), [user interfaces](ui.md), and
[agents and channels](agents.md) put a running air process behind a terminal, a
widget tree, or a model.

**Reference.** [Externs](externs.md), [times](time.md), [printing and
layouts](printing.md), [testing](testing.md), [documentation and the builtin
catalogue](documentation.md), and [implementation status](status.md).

**Practice.** [Examples](examples.md) and the [problem set](problem-set.md) are
worked, checked programs.

## Requirements

Air requires Julia 1.11 or later and a checkout of
[Air.jl](https://github.com/noahbenson/Air.jl) 0.3 and
[AirDB.jl](https://github.com/noahbenson/AirDB.jl) 0.1 next to this repository.
A PostgreSQL server is needed only for database-backed work; the default
in-memory database needs nothing. See [Getting started](getting-started.md).

```{note}
The reference documentation describes the language as implemented by AirLang.jl.
Some parts of the wider design — notably the incremental RETE network and
sequence patterns — are still deferred; they are listed under
[Implementation status](status.md).
```
