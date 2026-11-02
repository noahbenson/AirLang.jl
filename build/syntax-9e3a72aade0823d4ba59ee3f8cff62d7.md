# Syntax

Air is a Lisp-like functional language whose heaviest inspirations are Clojure
and Mathematica. Its core evaluation operations are fundamentally those of a
symbolic algebra engine, but it typically reads like a Lisp cousin.

## Structure

Air uses many of the aesthetic conventions of a Lisp-like language. The syntax
consists of symbols, strings, numbers, and forms which are nested using
parentheses. Forms are containers whose elements are whitespace-separated and
bracketed by parentheses, such as `(1 2 3)`.

A form is a sequence *and* a map at once: `(f 1 2 a=3)` is the sequence
`(f 1 2)` with the map entry `a=3`. Map entries may appear anywhere and map
order is not preserved, so `(f a=3 1 b=4 2)` is the same form as
`(f 1 2 a=3 b=4)`; read a printed form by element *kind*, never by source
position. [The data model](data-model.md) develops this.

Comments begin with the `#` character and extend to the end of the line. A
nestable block comment is `#| … |#`.

Strings in Air are bracketed by double quotes (`"`) or triple double quotes
(`"""`) and use the same formatting rules as Julia's strings. A **raw string** —
`raw"…"` or `raw"""…"""` — follows Julia's raw-string rules: a backslash is
literal (only `\"` escapes a quote), so `raw"\d+"` is the three characters
`\d+` without doubling every backslash.

A **regex literal** — `r"…"` or `r"""…"""` — is a raw string whose text is
compiled into a regular expression as it is read; the letters `i`, `m`, `s`,
`x`, and `a` immediately after the closing quote are flags. The literal builds
the same value as `(regex "…" ["flags"])`, so `r"\d+"i` and `(regex "\\d+"
"i")` are equal, and the printer spells a regex back as the literal. See
[Strings and regexes](strings.md).

Numbers are formatted as in Julia: integers too large for `Int64` are read as
`BigInt`, `1//3` is a rational literal, `big"1.5"` a `BigFloat`, `2i` and
`4.4+2.0i` complex values, and `Inf`/`-Inf`/`NaN` are the non-finite floats.
See [Numbers](numbers.md).

Symbols may be specified in two ways:
1. **Standard Symbols:** A sequence of alphanumeric characters plus the
   characters `+`, `-`, `*`, `/`, `_`, `!`, `?`, `:`, `$`, `@`, `^`, `&`, `=`,
   `.` that does not start with a number forms a symbol; for example, `x`,
   `abc123`, and `+` are all valid symbols.
2. **Special Symbols:** 
   - Any symbol whose name starts with a `?` is considered a wildcard for
     pattern matching.
   - Any symbol that starts with a `:` is considered a keyword, meaning it
     cannot be redefined and always evaluates to itself (patterns also share
     this property).

## Evaluation and Core Semantics

All atom types evaluate to themselves with the exception of symbols, which can
be bound to other values. Following a Wolfram-like logic regarding variables
and symbols, symbols that are not bound to a value are treated as other
atoms — i.e., they evaluate to themselves.

All Air code is simultaneously a piece of code and a piece of data (code is
data). A function call like `(f x)` is just a form with two symbols (`f` and
`x`), but if a pattern has been defined that fires on a match to `(f ?x)`, then
when the `(f x)` form is submitted to the Air interpreter, it is replaced with
whatever the pattern defines.

Reduction runs **bottom-up to a fixed point**. A form is reduced only when some
`def` rule, builtin, or special form matches it; a form with no matching rule is
already a fixed point and is returned as written. The builtins and operators
cover arithmetic, collections, strings, and the rest of the standard library,
and `.air` holds every one of them — `(doc .air)` lists the catalogue. The
rules that ship with the language are written for concrete values, so `(1 + 2)`
is `3` while `(x + 1)` stays `(x + 1)`.

A **special form** is a builtin that controls evaluation rather than receiving
its arguments evaluated: `if` evaluates only the selected branch, `and`/`or`
short-circuit, `def` and `let` treat their arguments as syntax, and `do`
sequences its body. [The data model](data-model.md) describes the form those
builtins receive; binding and control flow — `let`, `if`/`cond`,
`when`/`unless`, loops, and `do` — are in [Control flow and
bindings](control.md); pattern dispatch is in [Patterns](patterns.md).

The pattern language extends the reader's syntax in one place: a vertical pipe
joins two adjacent sequence elements into a pattern **alternative**,
`(a |b)` being `(alt a b)`. The pipe binds only its immediate neighbours and a
run flattens; [Patterns](patterns.md#pattern-matching-rules) covers matching.
