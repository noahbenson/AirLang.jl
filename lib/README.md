# air libraries

This directory is the first entry on `AIR_LIBPATH`, the `:`-separated library
search path air reads when a library is first needed. The default path is
`<repo>/lib` followed by `~/.air/lib`; set `AIR_LIBPATH` to change it, and the
first directory containing a match wins.

In the container this directory is mounted at `/air/lib` (the image's
`AIR_LIBPATH`), so a library dropped here is available to `bin/air-docker` and
`docker compose run --rm air` without rebuilding anything.

## Layout

A library is a directory whose name is a single valid **name segment** —
`[A-Za-z0-9_-]+`, not starting with a digit or `-` plus a digit, and not the
bare `_` — holding an
**`init.air`**:

```
lib/
  math/
    init.air
    data/notes.txt
  game/
    init.air
```

The library loads lazily the first time it is referenced:

```air
(using math (twice 4))      ; loads lib/math/init.air, then merges its names
(.lib.math.twice 4)         ; the namespace itself is reachable too
(namespace .app (import math))   ; materialized copies/proxies, as usual
```

`init.air` is evaluated **as `air`**, with `.lib.<name>` as the current
namespace and the library directory as the loading directory. It may therefore
write `(def …)`/`(val …)` forms directly (they land in `.lib.<name>`) or spell
out `(namespace .lib.<name> …)` explicitly. Relative paths in `read-file`,
`write-file`, and `load-air` resolve against the library directory, so a
library can ship data files next to its source.

The whole file is parsed before anything is evaluated, and the load runs in one
transaction under a per-library lock: a parse error, a runtime error, or an
aborted transaction leaves `.lib` unchanged, so a failed library can be fixed
and retried. A library referenced while it is already loading (a cycle) is
declined rather than deadlocking.
