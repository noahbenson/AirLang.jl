# air — a Julia image with AirLang and its sibling packages.
#
# AirLang depends on the local checkouts of Air.jl and AirDB.jl, so the build
# context must be the directory *containing* AirLang.jl:
#
#     cd ..
#     docker build -f AirLang.jl/Dockerfile -t airlang .
#
# or simply `docker compose up --build` in this directory (docker-compose.yml
# sets the context to `..`). The image runs the air REPL; `docker run -it
# airlang -e '(+ 1 2)'` uses the same command line as `bin/air`.

# Julia 1.11 is the first release whose Pkg understands the `[sources]` local
# path entries AirLang.jl's Project.toml uses.
FROM julia:1.11-bookworm

# A writable depot for resolution/precompilation, and the library path the
# compose file mounts the host's ./lib onto.
ENV JULIA_DEPOT_PATH=/opt/julia \
    AIR_LIBPATH=/air/lib

WORKDIR /src

# The local path dependencies named in AirLang.jl/Project.toml's [sources].
COPY Air.jl /src/Air.jl
COPY AirDB.jl /src/AirDB.jl
COPY AirLang.jl /src/AirLang.jl

# Resolve against the copied sources and precompile, so startup is quick and
# the image does not need network access at run time.
WORKDIR /src/AirLang.jl
RUN julia --project=. -e 'using Pkg; Pkg.resolve(); Pkg.instantiate(); Pkg.precompile()'

WORKDIR /air

ENTRYPOINT ["julia", "--project=/src/AirLang.jl", "-e", "using AirLang; exit(AirLang.air_main(ARGS))", "--"]
CMD []
