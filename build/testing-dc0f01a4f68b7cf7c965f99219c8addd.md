# Testing

`(check expr)` evaluates `expr` and returns a boolean. Inside a `(test name
body…)` it also records the outcome: a falsy expression is a failure, and an
uncaught error in the body is recorded as one failure and ends the body. The
name is evaluated, so it may be a string, keyword, or any other value. The
result is a data form `(name=<name> pass=<n> fail=<n> failures=(<failure>…))`,
where each failure is the held failing expression (or the caught error form), so
evaluating the summary again does not run it:

```air
(test "addition" (check (== (+ 1 2) 3)) (check (== (* 2 3) 7)))
# => (fail=1 failures=((' == (* 2 3) 7)) name="addition" pass=1)
```

A check may sit anywhere in the body — inside a helper `def`, a `doseq`, or a
branch — because it records into whichever test is running. A plain truth test
(`true?`) or a bare expression records nothing, so a failing check inside a
helper would otherwise pass vacuously.

Counters are task-local, so tests running on separate tasks do not interfere,
and a nested `test` reports only its own body.
