# Getting started

## Requirements

- **Julia 1.11 or later.** AirLang's `Project.toml` uses the `[sources]` local
  path entries that Julia 1.11 introduced.
- **[Air.jl](https://github.com/noahbenson/Air.jl) 0.3** and
  **[AirDB.jl](https://github.com/noahbenson/AirDB.jl) 0.1**, checked out beside
  this repository. AirLang depends on both as local path packages.
- **PostgreSQL** only if you want database-backed persistence. The default
  in-memory database needs no server.

## Installation

Clone the three repositories as siblings. AirLang's `Project.toml` resolves
`../Air.jl` and `../AirDB.jl`, so the directory names matter:

```bash
mkdir -p ~/Code && cd ~/Code
git clone https://github.com/noahbenson/Air.jl
git clone https://github.com/noahbenson/AirDB.jl
git clone https://github.com/noahbenson/AirLang.jl
cd AirLang.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

`Pkg.instantiate()` resolves the path dependencies and downloads the registered
ones (Air uses `DataStructures`; AirDB uses `LibPQ`). Precompiling happens on
first use:

```bash
julia --project=. -e 'using AirLang'
```

## Running air

`bin/air` is the command line. With no arguments it starts a read-eval-print
loop; `-e` evaluates one chunk of code; any other argument is a file to load:

```bash
./bin/air                              # the REPL
./bin/air -e '(+ 1 2)'                 # => 3
./bin/air -e 'using AirLang; (println "hi")'
./bin/air program.air                  # load a file
```

The `-e` chunks and files in one invocation share an environment, so definitions
made by an earlier `-e` are visible to a later one. The REPL reads a form across
lines while the reader reports an unterminated form, string, or block comment
(with a `...> ` continuation prompt) and sets `AIR_HISTORY` to a file that each
complete input is appended to, for use with external line editors such as
`rlwrap`.

From Julia, the same entry points are available as functions:

```julia
using AirLang, AirDB

env = Env(db = MemoryDatabase())          # a private in-memory database
air_eval(env, read_air("(+ 1 2)"))        # => 3
air_string(air_eval(env, read_air("(let (x=2) (* x 3))")))   # => "6"
```

`air_eval`, `read_air`, `air_string`, `air_pretty_string`, `air_repl`,
`open_airdb!`, and `close_airdb!` are exported. `Env` carries the process
database; see [Databases](databases.md).

## Libraries

`lib/` in this repository is the first entry of **`AIR_LIBPATH`**, the
`:`-separated (Windows: `;`) list of directories air searches when a library is
first needed; the default is `<repo>/lib` followed by `~/.air/lib`. A library is
a directory holding an `init.air`:

```
lib/
  math/
    init.air
```

```air
(using math (twice 4))       # loads lib/math/init.air if needed
(.lib.math.twice 4)          # the loaded namespace is reachable too
```

`lib/README.md` describes the layout; [Loading files and
libraries](libraries.md) covers the loader in detail.

## The Docker image

The repository ships a `Dockerfile` and a `docker-compose.yml`. The image is a
slim Julia runtime with AirLang and its dependencies precompiled; it contains no
build toolchain, and the host's `./lib` is mounted at `/air/lib` and used as the
library path.

The sibling checkouts are passed as named build contexts (BuildKit, the default
in current Docker):

```bash
docker build -t airlang \
    --build-context air=../Air.jl \
    --build-context airdb=../AirDB.jl .
```

Or use the compose file, which names the same contexts and also starts a
PostgreSQL sidecar:

```bash
docker compose run --rm air          # an air REPL with ./lib mounted
docker compose up --build            # air plus PostgreSQL
```

`bin/air-docker` is a thin wrapper that runs the image with the same command
line as `bin/air` and mounts `./lib`:

```bash
./bin/air-docker                     # REPL
./bin/air-docker -e '(+ 1 2)'        # => 3
./bin/air-docker program.air
```

Inside the container the library path is `/air/lib` (the mount) and Julia's
depot is `/opt/julia`.

## Running the tests

The test suite needs only the default in-memory database; the PostgreSQL tests
run when `AIRLANG_TEST_PG_URL` names a server:

```bash
julia --project=. test/runtests.jl

# ... with PostgreSQL:
AIRLANG_TEST_PG_URL="postgresql://air:air@localhost/air" \
    julia --project=. test/runtests.jl
```

`julia --project=. -e 'using Pkg; Pkg.test()'` is the same suite under Pkg's
isolation. The `docker-compose.yml` sidecar provides a PostgreSQL server with
user, password, and database `air`:

```bash
docker compose up -d postgres
```
