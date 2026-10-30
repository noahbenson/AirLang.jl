# AirLang.jl

**Air** is a Clojure- and Mathematica-inspired scripting language for Julia. It
is implemented by AirLang.jl, which builds on two libraries:
[Air.jl](https://github.com/noahbenson/Air.jl) (Clojure-like immutable data
structures and a software transactional memory) and
[AirDB.jl](https://github.com/noahbenson/AirDB.jl) (a persistence layer that
stores Air forms as `jsonb` in PostgreSQL, in transaction order).

Air is intended as the interface to a reasoning and rules system that tracks
complex metadata, recognizes conditions within it, and executes Julia functions
when required. Everything — code, data, rules, errors — is the same immutable,
inspectable form, and namespaces are multi-user logic sets.

```air
(+ 1 2)                                    # => 3
(let (x=2 y=3) (* x y))                    # => 6
(thread (f (1 2 3)))                       # => ((f 1) (f 2) (f 3))

(def (fact ?n)
  (if (< n 2) 1 (* n (fact (- n 1)))))
(fact 5)                                   # => 120
```

Namespaces are implicitly logic sets, so rules and facts are ordinary
definitions:

```air
(namespace .app)
(assert .app (depends :app :lib1))
(assert .app (rule (depends ?x ?y) :> (needs ?x ?y)))

(facts .app)          # => (' (depends :app :lib1) (needs :app :lib1))
(query .app (needs ?x ?y))                 # => ((x=:app y=:lib1))
```

## Documentation

The [Air book](book/index.md) is the reference. It is built with Jupyter Book 2
(MyST) and published at
<https://noahbenson.github.io/AirLang.jl/>. Suggested reading order:

| chapter | contents |
| --- | --- |
| [Getting started](book/getting-started.md) | installing, the REPL and CLI, Docker, libraries |
| [Syntax](book/syntax.md) | atoms, strings, regular expressions, forms, `let` |
| [The data model](book/data-model.md) | forms, holds, mutables, equality |
| [Numbers](book/numbers.md) | the numeric tower, literals, exactness, `//` vs `div` |
| [Patterns and function definitions](book/patterns.md) | matching, `def`, lambdas, `case`, `depth=` |
| [Namespaces](book/namespaces.md) | the namespace tree, `using`/`import`, `val`, tasks |
| [Users, homes, and permissions](book/permissions.md) | users, ACLs, `assume` |
| [Streams](book/streams.md) | reusable queues: `post`, `fetch`, envelopes, permissions |
| [Loading files and libraries](book/libraries.md) | `load-air`, `AIR_LIBPATH`, `init.air` |
| [Databases](book/databases.md) | AirDB, named forms, logic sets, JSON |
| [The two rule systems](book/rules.md) | reduction rules and the deductive engine |
| [Times](book/time.md) · [Printing and layouts](book/printing.md) | time values, layouts, pretty printing |
| [Errors](book/errors.md) · [Externs](book/externs.md) · [Testing](book/testing.md) | reference chapters |
| [Implementation status](book/status.md) | what is implemented and what is deferred |
| [Examples](book/examples.md) · [Problem set](book/problem-set.md) | worked programs |

## Requirements and installation

Air requires Julia 1.11 or later plus checkouts of Air.jl 0.3 and AirDB.jl 0.1
beside this repository:

```bash
mkdir -p ~/Code && cd ~/Code
git clone https://github.com/noahbenson/Air.jl
git clone https://github.com/noahbenson/AirDB.jl
git clone https://github.com/noahbenson/AirLang.jl
cd AirLang.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

## Running air

```bash
./bin/air                      # the REPL (sets AIR_HISTORY for line editors)
./bin/air -e '(+ 1 2)'         # => 3
./bin/air program.air          # load a file
```

## Docker

The image is a slim Julia runtime with AirLang and its dependencies precompiled.
The host's `lib/` is mounted at `/air/lib` and used as air's library path.

```bash
docker compose run --rm air    # an air REPL with ./lib mounted
docker compose up --build      # air plus PostgreSQL
./bin/air-docker -e '(+ 1 2)'  # the same CLI, in the container
```

The sibling checkouts are passed as named build contexts:

```bash
docker build -t airlang \
    --build-context air=../Air.jl \
    --build-context airdb=../AirDB.jl .
```

## Libraries

`lib/` is the first entry of `AIR_LIBPATH`. A library is a directory holding an
`init.air`, loaded lazily the first time it is referenced:

```air
(using math (twice 4))       # loads lib/math/init.air
(.lib.math.twice 4)          # the loaded namespace is reachable too
```

See [`lib/README.md`](lib/README.md) and [Loading files and
libraries](book/libraries.md).

## Repository layout

| path | contents |
| --- | --- |
| `src/` | the interpreter (reader, reducer, namespaces, logic engine, database glue) |
| `test/` | the test suite (`test/runtests.jl`) |
| `book/` | the documentation, built with MyST |
| `lib/` | the library search path's first entry |
| `bin/air` | the command line |
| `bin/air-docker` | the command line, in the container |
| `bin/build-docs` | build the documentation locally |
| `bin/deploy-docs` | build and publish the documentation to GitHub Pages |
| `Dockerfile`, `docker-compose.yml` | the container image and a PostgreSQL sidecar |

## Tests

```bash
julia --project=. test/runtests.jl
```

The PostgreSQL tests run only when `AIRLANG_TEST_PG_URL` names a server. CI runs
the suite on Julia 1.11, the latest release, and nightly, and builds the book.

## Status

AirLang implements the reduction engine, namespaces and permissions, the
AirDB-backed persistence layer, and the core of the deductive rule engine. The
incremental RETE network, sequence patterns, and serializable tasks are
deferred. See [Implementation status](book/status.md) and `TODO.md`.

## License

MIT — see [`LICENSE`](LICENSE).
