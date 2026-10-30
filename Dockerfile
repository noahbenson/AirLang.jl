# air — a minimal Julia image with AirLang and its dependencies precompiled.
#
# The image contains Julia, its standard library, and the packages air needs
# (Air.jl's `DataStructures`, AirDB.jl's `LibPQ`) — nothing else. There is no
# compiler, no Python, and no package manager state.
#
# AirLang depends on the local checkouts of Air.jl and AirDB.jl. They are passed
# as named build contexts (`air` and `airdb`), so the ordinary context stays
# this repository:
#
#     docker build -t airlang \
#         --build-context air=../Air.jl \
#         --build-context airdb=../AirDB.jl .
#
# `docker compose build air` does the same (docker-compose.yml names the
# contexts), and `bin/air-docker --build` wraps it. The image runs the air REPL;
# `docker run -it airlang -e '(+ 1 2)'` uses the same command line as
# `bin/air`.

# Julia 1.11 is the first release whose Pkg understands the `[sources]` local
# path entries AirLang.jl's Project.toml uses.
FROM julia:1.11-bookworm

LABEL org.opencontainers.image.title="air" \
      org.opencontainers.image.description="The air language interpreter" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/noahbenson/AirLang.jl"

# A private depot, and the library path the compose file mounts the host's
# ./lib onto (`/air/lib`).
ENV JULIA_DEPOT_PATH=/opt/julia \
    AIR_LIBPATH=/air/lib

WORKDIR /src

# The local path dependencies named in AirLang.jl/Project.toml's [sources].
COPY --from=air . /src/Air.jl
COPY --from=airdb . /src/AirDB.jl
COPY . /src/AirLang.jl

# Resolve and precompile, so startup is quick and the image needs no network at
# run time. `JULIA_CPU_TARGET=generic` makes the caches portable to any CPU of
# this architecture; the registry and download caches are build-time only and
# are dropped afterwards.
WORKDIR /src/AirLang.jl
RUN JULIA_CPU_TARGET=generic julia --project=. \
        -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' \
 && julia --project=. -e 'using AirLang' \
 && rm -rf /opt/julia/registries /opt/julia/clones /opt/julia/logs \
           /usr/local/julia/share/doc /usr/local/julia/share/man \
           /usr/local/julia/share/julia/test

# The library directory is a mount point for the host's ./lib; it is created
# here (and owned by the runtime user) so an image run without a mount still
# has a writable AIR_LIBPATH.
RUN useradd --create-home --uid 1000 air \
 && mkdir -p /air/lib \
 && chown -R air:air /opt/julia /src /air

USER air
WORKDIR /air

ENTRYPOINT ["julia", "--project=/src/AirLang.jl", "-e", "using AirLang; exit(AirLang.air_main(ARGS))", "--"]
CMD []
