# The data model

Every value in air is a **form**: an immutable, JSON-like tree of scalars and
containers. Code is a form too, which is why a rule can rewrite a program and a
program can build a rule. This chapter describes the form itself, quoted forms
(holds), mutables, and the three equality relations.

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
* **Querying:** Collection contents can be queried by treating them as
  functions; for a form `f` equal to `(1 (2 3) a=(g h i))`, `(f 1)` returns
  `1`, `(f 2)` returns `(2 3)`, and `(f :a)` returns `(g h i)`. Extended
  argument lists forward through the return value (e.g., `(f 2 1)` returns
  `2`).
* **Updating:** `(with form k1 v1 …)` replaces the subform at each key (a
  sequence key is a nested path, and an integer key `n + 1` appends);
  `(update coll key f)` replaces it with `(f old)`; `(update-in coll k1 … kn
  f)` does the same at a deep path, with a missing key yielding `naught` to
  `f`; and `(wout form k…)` removes the subform. Extra arguments to `f` are
  written with `part`, as in `(update-in m :a (part + 10))`.
* **The wildcard key:** the lone `:` names **every element of an ordered
  level** — a form with sequence elements but no map entries. In `get` it
  selects the whole level and maps the rest of the path over each element
  (`(get ((a=1) (a=2)) : :a)` is `(1 2)`); in `with` it replaces the elements,
  which requires one inserted value per element (`(with ((a=1) (a=2)) (: :a) (9
  9))` is `((a=9) (a=9))`); in `wout` and `drop` it removes every element, and
  as an intermediate step it applies the rest of the path to each one
  (`(wout ((a=1 x=0) (a=2 x=0)) : :x)` is `((a=1) (a=2))`). A level with map
  entries has no order, so it raises; in a table path `:` keeps its own meaning
  (all rows or all columns) and a lone `:` raises. When any `wout` key is `:`,
  its key arguments form one path.
* **Locating:** `(where coll obj depth=d)` finds every element at depth `d`
  equal to `obj`. With no `depth`, it searches depth `1` and returns the **bare
  keys** of the matches in encounter order: `(where (:a :b :b :c) :b)` is
  `(2 3)` and a single match `(where (:a :b :c) :b)` is `(2)`. With an explicit
  non-negative integer `depth`, it returns **one path per occurrence**, each
  path a list of `d` keys: `(where ((1 2) (3 2)) 2 depth=2)` is
  `((1 2) (2 2))` and `(where (:a :b :c) :b depth=1)` is `((2))`. At `depth=0`
  the subject is the only candidate and its sole key is the whole-form key `0`,
  so the result is `((0))` when the subject equals `obj` and `()` otherwise.
  `depth=:all` searches every depth and returns one path per occurrence, each of
  its own length: `(where (:a :b (:a :b) :c) :b depth=:all)` is `((2) (3 2))`.
  No match is `()` in every mode. Results are plain (not held); splice a path
  into `get`, `with`, or `update-in`: `(get coll (first (where …))...)`.

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
  (`(get (part add 10) 2 hold=true)` is `'add`).
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

## 4. Mutables
In addition to immutable atom types, there is a `mutable` type that `form`
objects are able to contain. All `mutable` objects are simple
pointers/references automatically synchronized across threads in a fashion
similar to Clojure's `ref` objects (implemented via `AirDB.jl`).

Mutables can be created using `(mut)`. Mutables automatically vanish during
queries, but can be updated using `(set! ...)` which traverses forms and updates
the deepest mutable object on the path. For example, if `f` equals 
`(1 (2 (mut (3 (4 5)))))`, then `(set! f 2 2 2 2 6)` updates the mutable at
`(f 2 2)` such that its value has been updated to set its position `2 2` to the
value `6`. `(value m)`, `(get m)`, and `(get m 0)` all read the mutable's value;
`(swap! m f args…)` (alias `alter!`) replaces it with `(f value args…)` in one
transaction and returns the new value, so a lost update is impossible.

Every operation that *edits* a mutable in a transaction ends in `!`: `set!`,
`swap!`, `alter!`, `chmod!`, and `chown!`. `mut` does not, because it creates
rather than edits a volatile. `(reset! actor value)` replaces an actor's value
directly (see [Delays, actors, and promises](namespaces.md#delays-actors-and-promises)); a
mutable is written with `set!`.

`(mut value filter=… finalize=…)` attaches Air's filter and finalizer. Both are
kept as written and stored in the mutable's metadata, so they survive a reload.
A replacement rule `(?x -> …)` is applied as a function; any other form is
evaluated with `_` bound to the value, so `filter=(if (_ < 0) 0 _)` clamps at
zero. A filter runs on every write (including the value passed to `mut`) and its
result is stored; a finalizer runs after the body of the writing transaction and
before it commits, and its result replaces the value. Because the finalizer runs
in the transaction's finalizing state, volatiles cannot be written from it.
`(set-filter! m fn)` and `(set-finalize! m fn)` replace them later (`naught`
removes one).

`(watch m key fn)` registers `fn` to run as `(fn key m old new)` at the end of
the body of the outermost transaction that writes `m`, before it commits. The
watch runs as the user who registered it, in the namespace where it was
registered, and once per mutable per transaction (with the transaction's final
value). Its writes are part of the same transaction, so a retry reruns it; a
`raise` from it aborts the transaction, while a `throw` is deferred like any
throw caught outside (see `tx` below). Watches are stored in the mutable's
metadata and survive a reload; a watch function must be self-contained (a
replacement rule, not a code fragment using `_`). Installing a watch needs
`watch` and `read` on the mutable; `watch` is owner-only by default.
`(unwatch m key…)` removes one watch or all of them, and `(watches m)` returns
the held watch tables.

`(tx body…)` evaluates the body inside one STM transaction and yields its last
value. It accepts the full `do` block grammar — `:let`/`let=`, `catch=`/`throw`,
`except`, `handle`/`notify`, and `finally` — all prepared and run inside the
transaction. Air's transactions join rather than nest: `tx` joins an open
transaction, so the outermost `tx` is the commit/rollback boundary (`namespace`,
`load-air`, a logic-set edit, and `set!` are transactional too). An error that
escapes it aborts every write made since it began and propagates, even if an
outer block catches it; an error caught by the tx's own `except` commits. A
throw caught by the tx's own `catch=` commits. A throw that escapes the tx to an
outer `catch=` is deferred until after the commit: watches run as usual, the
transaction commits, and the signal is rethrown (a retried attempt discards it).
Watches run at the end of that outermost transaction body, so their writes commit
or roll back with it.

`(sandbox body…)` evaluates the same block grammar in a transaction that is
**never committed**: it yields the body's value and discards every write, so a
`def`, `val`, `mut`, fact, rule, or namespace created inside it is gone
afterwards. It is the way to try something out — a rule you are not sure about,
a namespace edit you want to test — without touching the namespace. Because Air's
transactions join rather than nest, the body runs in a transaction of its own on
a private task (the caller waits for it), which means it cannot abort a
transaction around it and it reads committed state rather than an enclosing
transaction's staged writes. A `throw` still reaches an enclosing `catch=` and a
`notify` an enclosing `handle`; side effects outside the database (a file write,
`open-airdb`) are not undone.

## 5. Equality, Equivalence, and Hashing
Three relations are distinct:

* `(same? a b)` is object **identity** (`===`).
* `(eq? a b)` is **equivalence**. Two scalars are equivalent when they have the
  same value *and* the same type, so `(eq? 1 1.0)` is false even though
  `(== 1 1.0)` is true. A signed zero is one value under equivalence
  (`(eq? -0.0 0.0)` is true) and `NaN` is equivalent to itself. Two containers
  are equivalent when their sequences are
  elementwise equivalent and their maps hold equivalent values under the same
  keys (map order is irrelevant). A mutable (a volatile), an actor, and a
  promise are equivalent only to themselves; an extern follows its own
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
