# Loading files and libraries

`(load-air path…)` evaluates every form in every named file, in order. It reads
and parses **every** file before evaluating **any** form, then evaluates inside
one transaction, so a parse error or a runtime error leaves nothing behind. It
returns the last value. A relative path resolves against the directory of the
file that contains the `load-air` call (the process working directory at top
level), not against the caller's current directory:

```air
(load-air "util.air")   ; next to the loading file (or the cwd at top level)
```

The `air` command line uses the same loader: `air file.air` and `air -e '…'`.
The system namespace exposes the same functions as `.air.sys.load-air`,
`.air.sys.read-file`, and so on.

A **library** is a directory whose name is a valid name segment and that
contains an `init.air`. `AIR_LIBPATH` is a `:`-separated list of search
directories (`;` on Windows), read when a library is first needed; the default
is `<repo>/lib` and `~/.air/lib`, and the first directory with a matching
`<name>/init.air` wins. A library loads lazily — when `.lib.<name>` is first
addressed, or when a bare `using`/`import` spec names it:

```air
(using math (twice 4))       ; loads <libpath>/math/init.air if needed
(.lib.math.twice 4)          ; same
```

`init.air` runs as `air`, with `.lib.<name>` as the current namespace and the
library directory as the loading directory, in one transaction under a
per-library lock. A failed load registers nothing (`(.lib.bad …)` raises the
error the file raised; `.lib` has no `bad` entry afterwards). A recursive
reference to a library already loading is declined rather than deadlocking.
