# Control flow and bindings

The previous chapters described the form and how it reduces. This chapter
describes the forms that decide *what* runs: conditionals, boolean logic,
binding, loops, and sequencing. Pattern dispatch (`case`), traversal, and the
higher-order collection verbs build on the pattern language and are covered in
[Patterns](patterns.md) and [Collections](collections.md); the block form's
error and signal clauses are covered in [Errors and blocks](errors.md).

## Truthiness

Two values are false and one kind of form is false:

* `false`;
* `naught` (and therefore the empty form `()`); and
* an empty container.

Everything else is true — including `0`, the empty string `""`, and the keyword
`:false`. Predicates such as `zero?`, `empty?`, and `naught?` are the explicit
tests; a condition written in a conditional or a `when` is interpreted by this
rule.

## `if` and `cond`

`if` takes alternating conditions and values, with an optional trailing else
value:

```air
(if (< n 2) 1 (* n (fact (- n 1))))
(if (< x 0) :negative (== x 0) :zero :positive)
(if ready :go)                      # => naught when ready is false
```

The conditions are evaluated in order and the value paired with the first
truthy one is selected; that value is then reduced in **tail position** (see
below). Extra condition/value pairs are the else-if chain — the form above
reads "if `x < 0` then `:negative`, else if `x == 0` then `:zero`, else
`:positive`". With no true condition and no else value the result is `naught`.
`cond` is a synonym.

Comparison is `==`, `!=`, `<`, `<=`, `>`, or `>=`; a single `=` only separates
a map key from its value, so `(= x 0)` is not a comparison.

## `when` and `unless`

`when` evaluates its body when the condition is true and yields the last body
value; otherwise it is `naught`. `unless` is the negation:

```air
(when (empty? coll) (println "nothing to do"))
(unless (empty? coll) (process coll))
```

Both take any number of body forms and sequence them like a `do` with no
clauses.

## Boolean logic

`and` and `or` are the short-circuiting operators. `and` yields the last value
when every argument is true and the first false value otherwise; `or` yields
the first true value and the last value otherwise. The empty cases are `(and)`
→ `true` and `(or)` → `naught`. `not` is prefix-only, and `xor` is true when an
odd number of its arguments are true:

```air
(and (< 0 n) (< n 10))              # n is in range
(or fallback (compute))             # compute only when fallback is false
(not ready)
(xor a b)                           # exactly one of a and b
```

`and`/`or` are operators, not functions: `(a and b)` is `(and a b)`, and they
may be used infix. There is no `(a and not b)` reader form — write
`(a and (not b))`.

## `let`

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

A `bind=(x y)` option names bindings that are **bound**, not substituted: each
value is evaluated and installed as a lexical name instead of being written into
the body. Bound and substituted names live side by side, so a substituted value
may mention a bound name and resolves against it. The option goes on the `let`
form, or on a sequence binding form's own map (where a `:let` marker must put it):

```air
(let ((const=2.551 f=((a ^ 2) / ((a + b) ^ 2)))
      (a=(2 * const) b=(4 * (const ^ 2))) hold=f bind=(a b))
  f)                                     # => 0.02685688214587777

(do :let ((a=1) (b=(a + 1)) bind=(a b)) (+ a b))   # => 3
```

`const` substitutes into `a` and `b`; `a` and `b` are bound; `hold=f` inserts
`f`'s expression, which then evaluates against the bound `a` and `b`. A name
cannot be both held and bound. `let=` (used by blocks) already binds every name
and takes neither option.

Because a value is inserted rather than looked up, a value whose head is its own
name is harmless: `(let (db=(db 1)) db)` is `(db 1)`.

The body of a `let` is a sequence of forms; it yields the last value. A `let`
body is in tail position, and a `let` body is also a lexical scope for `loop`
and `for` bindings made inside it.

## Loops and iteration

`loop` binds names, evaluates a body, and re-enters the loop when the body
reaches a `recur`:

```air
(loop (i 1 acc 0)
  (if (> i 10) acc (recur (i + 1) (acc + i))))    # => 55
```

`recur` supplies the new values for the loop's names, in order. In **tail
position** it re-enters the loop in constant stack; a `recur` that is not in
tail position is still control flow but is not optimized. `recur` is not an
error: no `except` clause catches it. A `loop` with no `recur` simply yields its
body's value.

`while` repeats its body while a condition stays true and yields `naught`:

```air
(let (m=(mut 0))
  (while (< (get m) 3) (set! m (+ (get m) 1)))
  (get m))                                  # => 3
```

(`mut` and `set!` are described in [Mutability](mutability.md).)

`for` is a comprehension. Its binding form names a sequence of collection/name
pairs, processed left to right and nested, with `:if cond` and `:let name val`
steps in between. The result is the list of body values (`range` builds a
sequence of numbers; see [Collections](collections.md#the-collection-surface)):

```air
(for (x (range 1 4)) (* x 2))                    # => (2 4 6)
(for (x (range 1 6) :if (even? x)) x)            # => (2 4)
(for (r rows :let (n=(get r :name))) n)          # one value per row
```

The table chapter shows `for` over rows; a tensor iterates linearly in
column-major order (see [Tensors](tensors.md)). `doseq` is the same binding form
for effect and returns `naught`; `dotimes` binds a counter to `0 … n-1` and also
returns `naught`. `each` (in [Collections](collections.md)) is the same idea for
a function over a collection.

## Sequencing: `do` and definition bodies

`do` evaluates its body forms left to right and yields the last value. It is the
general block form: it also takes `let=` (a lexical scope around the whole block),
`:let` markers inside the body (nested textual `let`s), `catch=` for `throw`,
and trailing `except`, `handle`, and `finally` clauses. The full grammar, the
clause semantics, and `throw`/`signal` are in [Errors and blocks](errors.md).

A `def` body and a `val` body are the same block: several forms are sequenced as
a `do`, and the block options and clauses apply. A body that needs none of them
is stored exactly as written. See [Definition bodies](errors.md#definition-bodies).

## Tail position and `exit`

Reduction runs bottom-up to a fixed point. A call in **tail position** is
reduced iteratively rather than recursively, so a tail-recursive rule runs in
constant stack; only nested (non-tail) recursion is bounded by the depth budget.
Tail positions are:

* the selected branch of an `if`/`cond`;
* the last form of a `let` or `loop` body, or of a `do` with no
  `catch=`/`except`/`handle`/`finally` (with or without `:let`/`let=`);
* the body of `when`/`unless`;
* the last operand of `and`/`or`; and
* a rule body — a `def` body, a lambda's replacement, or a `case` clause (see
  [Patterns](patterns.md)).

`tx` is never a tail form.

`(exit [value])` ends the current task — the REPL, a loaded file, a `task`
body, or an SSH session turns it into that boundary's result — so a plain
`air_eval` sees it propagate. It is control flow, not an error, so no error
clause catches it. With no value it is `naught`.

## Where to go next

* [Patterns](patterns.md) — `def`, wildcards, `case`, and pattern dispatch.
* [Collections](collections.md) — `map`, `filter`, `reduce`, `thread`,
  pipelines, and traversal.
* [Errors and blocks](errors.md) — `except`, `catch`/`throw`, `handle`, and
  `finally`.
* [Mutability](mutability.md) — `set!`, filters and watches, `tx`, `sandbox`.
