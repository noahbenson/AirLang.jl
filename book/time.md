# Times

Air has no separate time type. A **time** is the ordinary immutable form

```air
(time 1761686100.123)
```

whose single element is a floating-point count of seconds since the Unix epoch,
in UTC. Because it is an ordinary form it persists, serializes, hashes, and
compares like any other value; the printer, the arithmetic operators, and the
verbs below are the only things that know it is a moment rather than a call.

Times print as ISO-8601 in UTC:

```air
(now)                     # => (time "2026-10-29T06:43:02.663Z")
(time "2026-10-28")       # => (time "2026-10-28T00:00:00Z")
```

A value with finer than millisecond precision (or outside the range a
`DateTime` can represent) keeps its numeric spelling instead —
`(time 1.0e-7)` — so a printed time always reads back as exactly the same
value.

## The clock

`(now)` is the current instant. It is a pure value: it needs no database and is
unaffected by a transaction. `(time? x)` tests the type.

## Parsing and formatting

`(time x)` converts `x` to a time: a number is UTC epoch seconds, a time is
itself, and an ISO-8601 string is parsed. Anything else is left symbolic, like
every other math verb.

Accepted strings include a date alone, a date and time, a space or `T`
separator, a fractional second, and a `Z` or `±hh:mm`/`±hhmm` offset:

```air
(time "2026-10-28")                    # midnight UTC
(time "2026-10-28T21:15")              # midnight seconds
(time "2026-10-28 21:15:00.123")       # a fractional second
(time "2026-10-28T21:15:00.123+02:00") # the same instant, in UTC
```

A string that is not a valid time raises a catchable error rather than staying
symbolic, since it was meant as a time.

`(time-str t)` is the inverse: ISO-8601 UTC with milliseconds, trailing zeros
trimmed. Two options refine it:

```air
(time-str (now))                                   # "2026-10-29T06:43:02.663Z"
(time-str (now) format="yyyy-mm-dd HH:MM:SS")      # "2026-10-29 06:43:02"
(time-str (now) offset="+02:00")                   # "2026-10-29T08:43:02.663+02:00"
```

`format` is a Julia [`Dates`](https://docs.julialang.org/en/v1/stdlib/Dates/)
`DateFormat` string, whose tokens are **not** `strftime`'s: lowercase `m` is the
month, `d` the day, and `H` the hour, but `MM` is *minutes*, `SS` seconds, and
lowercase `s` milliseconds. So the `strftime` format `%Y-%m-%d %H:%M:%S` is
written `yyyy-mm-dd HH:MM:SS` — not `yyyy-mm-dd HH:MM:ss`, which would print
milliseconds where the seconds belong. `offset=` shifts the instant before
formatting and replaces the `Z`; a number of seconds works too.

`DateTime` carries milliseconds, so formatting and the printed ISO spelling are
millisecond-exact; the underlying `Float64` keeps the full precision for
arithmetic.

## Arithmetic

A time behaves like a real number of seconds in the operations where that
reading makes sense:

```air
(+ (now) 60)              # one minute from now  (a time)
(+ 60 (now))              # the same
(- (now) (now))           # a duration in seconds (a number)
(- (now) 3600)            # an hour ago (a time)
```

A time minus a time is a number of seconds; a time plus or minus a number is a
time. Everything else — time + time, time × number, unary minus on a time —
stays symbolic, so a form you did not mean to reduce is left alone.

## Comparisons

Ordering works on two times:

```air
(< (time 1) (time 2))                  # => true
```

A time and a plain number do not compare: `<` stays symbolic rather than
guessing that the number is epoch seconds. Use the explicit verbs when a value
might be either:

| verb | meaning |
| --- | --- |
| `(before? a b)` | `a` is earlier than `b` |
| `(after? a b)` | `a` is later than `b` |
| `(between? x lo hi)` | `lo` ≤ `x` ≤ `hi`, inclusive |

All three accept times **and** numbers (a time contributes its seconds), and a
symbolic argument leaves the form unchanged.

```air
(between? (now) (- (now) 1) (+ (now) 1))   # => true
(between? 1 0 2)                            # => true
```

## Printing and JSON

The printer spells a time as `(time "…Z")` both flat and in the
[pretty printer](printing.md), so layout decisions measure the same text. The
JSON codec knows nothing about times: a time is an ordinary form and encodes
structurally, with no database resource.

```air
(to-json (time 0.5))     # => "[[\":time\", 0.5], {}]"
```

## The `time` library

`lib/time/init.air` adds readable spellings for durations and instants:

```air
(using time (minutes 90))      # => 5400
(using time (hours 2))         # => 7200
(using time (days 1))          # => 86400
(using time (weeks 1))         # => 604800
```

`(seconds n)` is `n` itself; the rest are multiples. Two helpers read better
than arithmetic in prose:

```air
(since t)          # seconds elapsed between t and now
(ago (hours 1))    # the instant one hour ago
```

```air
(using time (between? (ago (days 1)) (- (now) (days 2)) (now)))
```

The library loads lazily the first time it is referenced, as
`.lib.time` (see [Loading files and libraries](libraries.md)).
