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

- **[Getting started](getting-started.md)** — installing air, running the REPL
  and the command line, the Docker image, and the library path.
- **[Syntax](syntax.md)** — atoms, comments, strings, regular expressions,
  forms, and `let`.
- **[The data model](data-model.md)** — forms and collections, scalars and
  single-element forms, quoted forms, mutables, and equality.
- **[Patterns and function definitions](patterns.md)** — pattern matching,
  `def`, lambdas, `case`, level-aware traversal, repetition, and docstrings.
- **[Namespaces](namespaces.md)** — the namespace tree, `using`/`use`/`import`,
  thread-local values, tasks, delays, actors, and promises.
- **[Users, homes, and permissions](permissions.md)** — users, homes, ACLs, and
  `assume`.
- **[Streams](streams.md)** — reusable queues: `post`, `fetch`, envelopes,
  timeouts, and the read/write ACL of a stream.
- **[Loading files and libraries](libraries.md)** — `load-air`, the library
  path, and `init.air`.
- **[Databases](databases.md)** — opening an AirDB database, named forms, logic
  sets, synchronization, and JSON.
- **[Tables](tables.md)** — typed, indexed tabular values: the `table`
  constructor, `with`/`push` updates, row iteration, and CSV/TSV interchange.
- **[Data formats](formats.md)** — reading and writing JSON, YAML, TOML, CSV,
  TSV, and `.env` as plain air data, safely.
- **[SSH access](ssh.md)** — `ssh-server`, authorized-key login, the remote
  REPL, and SFTP with `bytes` files.
- **[User interfaces](ui.md)** — inert `(ui …)` trees, the widget catalog,
  assertions, and the terminal and text renderers.
- **[The two rule systems](rules.md)** — reduction rules and the deductive
  engine, with the [production-rule reference](production-rules.md) in detail.
- **[Errors](errors.md)**, **[externs](externs.md)**, **[times](time.md)**,
  **[printing and layouts](printing.md)**, and **[testing](testing.md)** — the
  reference chapters.
- **[Implementation status](status.md)** — what is implemented and what is
  deferred.
- **[Examples](examples.md)** and the **[problem set](problem-set.md)** —
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
