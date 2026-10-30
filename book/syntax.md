# Syntax

Air is a Lisp-like functional language whose heaviest inspirations are Clojure
and Mathematica. Its core evaluation operations are fundamentally those of a
symbolic algebra engine, but it typically reads like a Lisp cousin.

## Structure

Air uses many of the aesthetic conventions of a Lisp-like language. The syntax
consists of symbols, strings, numbers, and forms which are nested using
parentheses. Forms are containers whose elements are whitespace-separated and
bracketed by parentheses, such as `(1 2 3)`.

A vertical pipe joins two adjacent sequence elements into a **pattern
alternative**: `(a |b)` is the pattern `(alt a b)`, and a run flattens, so
`(a | b | c)` is `(alt a b c)`. The pipe binds only its immediate neighbours,
so `(f a | b c)` is `(f (alt a b) c)`; a map entry is not a sequence element
and may stand on neither side of a pipe. Matching tries the branches in order
and the first match wins, with that branch's bindings. There is no reader
shorthand for nesting a form inside the final element; write the parentheses.

Comments begin with the `#` character and extend to the end of the line.

Strings in Air are bracketed by double quotes (`"`) or triple double quotes
(`"""`) and use the same formatting rules as Julia's strings. A **raw string** —
`raw"…"` or `raw"""…"""` — follows Julia's raw-string rules: a backslash is
literal (only `\"` escapes a quote), so `raw"\d+"` is the three characters
`\d+` without doubling every backslash.

A **regex literal** — `r"…"` or `r"""…"""` — is a raw string whose text is
compiled into a regular expression as it is read; the letters `i`, `m`, `s`,
`x`, and `a` immediately after the closing quote are flags. The literal builds
the same value as `(regex "…" ["flags"])`, so `r"\d+"i` and `(regex "\\d+"
"i")` are equal, and the printer spells a regex back as the literal.

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

## Regular Expressions

`r"a+"` (or, equivalently, `(regex "a+")`, with optional flags as in
`(regex "a+" "i")`) compiles a pattern; the result is an ordinary value that
prints as the literal `r"a+"i` and round-trips through source. Every string verb
that takes a pattern accepts
either a **string**, matched literally, or a regex value, matched as a regular
expression: `string-split`, `string-replace`, `string-index-of`,
`string-contains?`, and `string-match?`; `regex?` tests for a regex value.

- `string-find` returns the first match as `(match=… index=… groups=…)`, or
  `naught`; `string-find-all` returns a sequence of those forms.
- `index` is a 1-based character index (not a byte offset), and `groups` is a
  sequence of the capture strings (`naught` when the pattern has none).
- A regex replacement expands `$0` (the whole match), `$1`…`$n`, and `$name`
  (a named group); `$$` is a literal dollar. A literal pattern's replacement is
  used exactly as written.
- `string-match?` is the pattern-oriented spelling of `string-contains?`: it
  is true when the pattern matches anywhere in the subject.

## Evaluation and Core Semantics

All atom types evaluate to themselves with the exception of symbols, which can
be bound to other values. Following a Wolfram-like logic regarding variables
and symbols, symbols that are not bound to a value are treated as other
atoms--—i.e., they evaluate to themselves.

All Air code is simultaneously a piece of code and a piece of data (code is
data). A function call like `(f x)` is just a form with two symbols (`f` and
`x`), but if a pattern has been defined that fires on a match to `(f ?x)`, then
when the `(f x)` form is submitted to the Air interpreter, it is replaced with
whatever the pattern defines.

## Local Bindings (`let`)

`let` takes a binding form as its second element, followed by a body:

```air
(let (x=1 y=2) (+ x y))       # => 3
```

The bindings in one mapping are **parallel**: every value is evaluated in the
*enclosing* scope, before any of the names is substituted. `let` then substitutes
each name by its value in the body **textually, before the body is evaluated**, so
it does not introduce a scope of its own — it rewrites the body. Substitution
reaches every occurrence, including occurrences inside a quoted form:

```air
(let (x=2) (' a x b))                    # => (' a 2 b)
(let (y=10) (let (x=y) (?y -> x)))        # => (?y -> 10)
```

The binding form may also be a **sequence of mappings**, each of which feeds the
next: names bound by earlier groups are substituted into later groups' value
expressions before those are evaluated. Within a group the bindings stay
parallel, and a rebound name refers to its *previous* value inside its own new
value:

```air
(let ((a=1 b=2) (c=(a + b))) c)          # => 3
(let ((x=1) (x=(x + 2))) x)              # => 3
```

A `hold=(x y)` option on the `let` form names bindings whose values are inserted
exactly as written instead of evaluated (in every group; earlier groups still
substitute into them):

```air
(def (hold-y y=?y ??rest) hold=y)
(let (x=(1 + 1) y=(2 + 2) z=(3 + 3)) hold=(y z) (hold-y x=x y=y z=z))
# => (hold-y x=2 y=(2 + 2) z=6)

(let ((a=1 b=2) (c=(a + b))) hold=c (hold c))   # => (' (1 + 2))
```

Because a value is inserted rather than looked up, a value whose head is its own
name is harmless: `(let (db=(db 1)) db)` is `(db 1)`.
