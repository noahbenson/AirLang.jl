# The data model

Every value in air is a **form**: an immutable, JSON-like tree of scalars and
containers. Code is a form too, which is why a rule can rewrite a program and a
program can build a rule. This chapter describes the form itself, quoted forms
(holds), and the three equality relations. Mutable state is the one exception to
immutability and is described in [Mutability and
transactions](mutability.md); the accessor and update verbs are in
[Collections](collections.md).

## 1. Forms and Collections
A **form** is an immutable object that contains actual data. Strings, symbols,
numbers (see [Numbers](numbers.md) for the eight numeric leaves),
booleans, and the null value `naught` are all considered subtypes of the
`form` type.

* **Collections:** Sequences (whitespace-separated elements surrounded by
  parentheses) and mappings (paired values with keys, e.g., `(a=1 b=2 c=3)`)
  are forms.
* **Hybrid Forms:** Forms can include both sequential and mapping values: `(f 1
  2 a=3 b=4)` is a form with three sequential elements and two mapping
  elements. Keyword elements do not need to come in any particular order, and
  their ordering is not preserved (`(f 1 2 a=3 b=4)`, `(a=3 b=4 f 1 2)`, and
  `(f a=3 1 b=4 2)` are all equal forms).
* **Empty Form:** There is exactly one empty form `()`, which is considered
  logically false and identical to `naught` (acting as a `nil` value).
* **Querying and updating:** a form can be indexed by treating it as a
  function — for a form `f` equal to `(1 (2 3) a=(g h i))`, `(f 1)` returns
  `1`, `(f 2)` returns `(2 3)`, and `(f :a)` returns `(g h i)` — and `get`,
  `with`, `wout`, `update`, `update-in`, `push`, and `pop` are the verbs behind
  that idea. A path is a sequence of keys, an integer key counts from 1, and a
  missing key is `naught` to `update-in`'s function. [Collections](collections.md)
  covers the accessor, the lone-`:` wildcard, the scalar-as-singleton
  convention, locating with `where`, and the whole collection surface.

## 2. Scalars and Single-Element Forms
A scalar is its own sole sequence for the accessors: `(get 10 1)` is `10`,
descending past a scalar stays on it, and out-of-bounds indices throw, so a
scalar participates naturally in collection operations (`(push 10 11)` is
`(10 11)`). This is an **accessor convention, not a rewrite**: a written
container is never collapsed, so `10`, `(10)`, and `((10))` are three distinct
forms and `(eq? 10 (10))` is false. A one-element form reduces only when a
`def` (or builtin) matches it. The sole canonicalization is the empty form:
`()` and `naught` are the same singleton at every depth, so `(same? () naught)`
is true and no container ever embeds an empty container.

(holds)=
## 3. Literal Forms and Meta-Programming (`(' ...)` and `~`)
Holding is **structural**, not a flag: the canonical hold is a container whose
first element is the ordinary symbol `'`, `(' a b c)`. `'` is an ordinary
symbol character (`a'b` is a symbol), but a symbol may not *begin* with it —
except the bare `'` itself. There is no separate held bit on a form, and a held
form is an ordinary value everywhere. `'x` is reader sugar for `(' x)` when `x`
is a **scalar** (`'a`, `'5`, `':x`, `'"abc"`); the container spelling `'(…)` is
a parse error — write `(' …)`.
* **Literal Forms:** a hold holds each of its elements as written, so
  `(' a b c)` holds three elements and `(' (a b c))` holds one container. `'5`
  and `':a` stay held as well. A hold of exactly one scalar prints with the
  quote (`'a`, `'5`, `':a`); any other hold prints literally (`(' a b c)`,
  `(' f x=1)`). `(hold e…)` is the reserved alias that reduces to `(' e…)`.
  A held form does not reduce — it is data. `(unhold (' a b c))` drops the head
  and evaluates the remaining content, giving `(a b c)`.
* **Unquoting (`~`):** `~e` is sugar for `(preval e)`, a reserved special form
  that evaluates `e` eagerly wherever it appears. Inside a held form each
  `~e` is filled in with the reduced form of `e` at every depth (a nested hold
  fills its own holes): `(hold (a ~(1 + 2)))` reduces to `(' (a 3))`. `~` is
  *not* the runtime unhold operation — that is the ordinary call `(unhold x)`,
  which evaluates a held form's content. Use `lift` (below) to build a quoted
  form explicitly from literal and evaluated parts. A hole may be a map value
  (`(f x=~(1 + 2))` is `(f x=3)`, and `x=~y` is the same hole in atom form),
  and a trailing `...` splices the hole's value into the enclosing sequence
  rather than its operand (`(f ~(1 2 3)...)` is `(f 1 2 3)`).
* **Access:** because a hold is an ordinary form, the hold-blind accessors see it
  as one — `(first (' a b c))` is `'` and `(count (' a b c))` is 4. `get`
  indexes the form as written, so for a held form index 1 is the `'` head and
  index 2 is the first element of its content: `(get (' f a b) 2)` is `f` and
  `(get (' f x=1) :x)` is `1`. Pass `hold=true` to make the root hold
  transparent — the path then indexes the *content*, intermediate values are not
  reduced, and the result is held: `(get (' f (1 + 2)) 2 hold=true)` is
  `(' 1 + 2)`. This works for any form that keeps its arguments as data
  (`(get (part add 10) 2 hold=true)` is `'add`, where `part` is the partial
  application of [Patterns](patterns.md#lambdas-a-replacement-rule-in-head-position)).
  `(with form k1 v1 … hold=true)` is the inverse: it replaces the subform at
  each path with its value, inserted without its own hold and not evaluated —
  `(with (' a b c) 2 (' 1 + 1) hold=true)` is `(' a (1 + 1) c)`. `(held? x)`
  tests whether `x` is a held form, and `(held? form k…)` tests the subpart at
  that path (`hold=true` makes the root hold transparent first). `lower` pushes
  holds toward the leaves and `lift` lifts them back to the root
  (`(lift (' ' a x ' b))` → `(' a <value-of-x> b)`).
* **The `hold-` family:** every collection operation that takes a primary form
  has a `hold-` version — `hold-get`, `hold-nth`, `hold-with`, `hold-wout`,
  `hold-push`, `hold-push-in`, `hold-join`, `hold-join-in`, `hold-update`,
  `hold-thread`, `hold-held?`. These treat the primary form's root hold as
  transparent (the operation is on the content), let inserted held values
  contribute their content, and return the result held:
  `(hold-get (' 1 2 3) 2)` is `(' 2)`. Each takes `hold=` to select the result's
  heldness (`(hold-get (' 1 2 3) 2 hold=false)` is `2`), and the plain version
  accepts `hold=true` for the same treatment (`(get (1 2 3) 2 hold=true)` is
  `(' 2)`).

(equality)=
## 4. Equality, Equivalence, and Hashing
Three relations are distinct:

* `(same? a b)` is object **identity** (`===`).
* `(eq? a b)` is **equivalence**. Two scalars are equivalent when they have the
  same value *and* the same type, so `(eq? 1 1.0)` is false even though
  `(== 1 1.0)` is true. A signed zero is one value under equivalence
  (`(eq? -0.0 0.0)` is true) and `NaN` is equivalent to itself. Two containers
  are equivalent when their sequences are
  elementwise equivalent and their maps hold equivalent values under the same
  keys (map order is irrelevant). A **mutable** — a shared, writable cell,
  described in [Mutability](mutability.md) — and the database-backed handles
  (an actor, a promise) are equivalent only to themselves; an extern follows its own
  `isequal`, so two separately compiled equal regex values are equivalent while
  two tasks' promises are not. A delay is equivalent when its type and its
  serialization agree — equivalence never forces one. Everything immutable
  is therefore comparable by
  value, even when it points at a mutable: the mutable part contributes only
  its identity.
* `(== a b)` is **content** equality, the numeric-friendly relation used by the
  arithmetic comparisons (`(== 1 1.0)` is true, as are `(== -0.0 0.0)` and
  `(== (f 1) (f 1.0))`). It is AirDB's `==`, under which a `NaN` is equal to
  nothing, just as in Julia; `eq?` is the relation that treats `NaN` as equal to
  itself.

`(hash x)` follows `eq?`: equivalent forms hash alike, and the hash never
descends into a mutable object (a volatile hashes by its identity), so any
immutable form is hashable even when it contains one. Two forms that hash alike
need not be equivalent, but equivalent forms always hash alike, which is what a
memoization table or a keyed map needs.
