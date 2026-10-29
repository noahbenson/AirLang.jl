# AirLang.jl

A Clojure- and Mathematica-inspired scripting language for Julia that builds on
the `Air.jl` and `AirDB.jl` libraries.

## Context and Motivation

`Air.jl` is a library that implements Clojure-like immutable data structures
and a Software Transactional Memory (STM) system. `AirDB.jl` is a database
persistence layer that lives on top of and uses `Air.jl` for concurrency and
transactions, allowing users to easily create and manage mutable JSON-like
objects across multiple threads that are automatically synchronized to a
PostgreSQL database in `jsonb` tables.

`AirLang.jl` is a project that seeks to unite these libraries into a
Clojure-like interpreted language that runs in Julia, called **Air**. Air is
intended for use in part as the interface to a reasoning and rules system that
can be used to track complex metadata, recognize conditions within it, and
execute Julia functions when required.

---

## Basic Syntax

Air is a Lisp-like functional language whose heaviest inspirations are Clojure
and Mathematica. Its core evaluation operations are fundamentally those of a
symbolic algebra engine, but it typically reads like a Lisp cousin.

### Structure

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

Numbers are formatted as in Julia.

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

### Regular Expressions

`(regex "a+")` compiles a pattern (with optional flags, `(regex "a+" "i")`);
the result is an ordinary value that prints as `(extern :regex ("a+" "i"))` and
round-trips through source. Every string verb that takes a pattern accepts
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

### Evaluation and Core Semantics

All atom types evaluate to themselves with the exception of symbols, which can
be bound to other values. Following a Wolfram-like logic regarding variables
and symbols, symbols that are not bound to a value are treated as other
atoms--—i.e., they evaluate to themselves.

All Air code is simultaneously a piece of code and a piece of data (code is
data). A function call like `(f x)` is just a form with two symbols (`f` and
`x`), but if a pattern has been defined that fires on a match to `(f ?x)`, then
when the `(f x)` form is submitted to the Air interpreter, it is replaced with
whatever the pattern defines.

### Local Bindings (`let`)

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

---

## Data Model & Advanced Form Semantics

### 1. Forms and Collections
A **form** is an immutable object that contains actual data. Strings, symbols,
floats, complex numbers, integers, booleans, and the null value `naught` are
all considered subtypes of the `form` type.

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

### 2. Scalars and Single-Element Forms
A scalar is its own sole sequence for the accessors: `(get 10 1)` is `10`,
descending past a scalar stays on it, and out-of-bounds indices throw, so a
scalar participates naturally in collection operations (`(push 10 11)` is
`(10 11)`). This is an **accessor convention, not a rewrite**: a written
container is never collapsed, so `10`, `(10)`, and `((10))` are three distinct
forms and `(eq? 10 (10))` is false. A one-element form reduces only when a
`def` (or builtin) matches it. The sole canonicalization is the empty form:
`()` and `naught` are the same singleton at every depth, so `(same? () naught)`
is true and no container ever embeds an empty container.

### 3. Literal Forms and Meta-Programming (`(' ...)` and `~`)
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

### 4. Mutables
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
directly (see [Delays, actors, and promises](#delays-actors-and-promises)); a
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

### 5. Equality, Equivalence, and Hashing
Three relations are distinct:

* `(same? a b)` is object **identity** (`===`).
* `(eq? a b)` is **equivalence**. Two scalars are equivalent when they have the
  same value *and* the same type, so `(eq? 1 1.0)` is false even though
  `(== 1 1.0)` is true. Two containers are equivalent when their sequences are
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
  arithmetic comparisons (`(== 1 1.0)` is true).

`(hash x)` follows `eq?`: equivalent forms hash alike, and the hash never
descends into a mutable object (a volatile hashes by its identity), so any
immutable form is hashable even when it contains one. Two forms that hash alike
need not be equivalent, but equivalent forms always hash alike, which is what a
memoization table or a keyed map needs.

---

## Patterns and Function Definitions

### Pattern Matching Rules
Any form is a pattern, but a form without wildcards matches only itself. 
* **Wildcards:** Symbols starting with `?` stand for any value and evaluate to
  themselves in patterns.
* **Conditions (`\`):** The character `\` stands for "such that" and introduces
  a condition (e.g., `(?h \ string? 10)` or `(?h \ (string? h) 10)`).
* **Alternatives (`|`):** A pipe joins two adjacent elements into `(alt p q)`;
  a run flattens, so `p | q | r` is `(alt p q r)`. Branches are tried in order
  and the first match wins, with that branch's bindings (a failed branch leaks
  nothing). `alt` is pattern syntax, not an anchor: a rule is indexed by the
  raw symbols inside its branches.
* **Rest & Sequences:** `??` matches any other elements; `??rest` binds all
  sequential and keyword sequences while `?&rest`, and `?*kwargs` bind
  variable-length sequential or keyword sequences respectively.
* **Optional Keyword Patterns:** Keys starting with a `?` (e.g.,
  `?method=naught`) are optional and bind to a default value (`naught` in this
  case) if missing. However, the keyword matched in this example is `:method`,
  not `?method`.

### Global vs. Local Patterns & The Anchor Rule
* **Global Evaluation Rules:** To guarantee blazing-fast indexation in the RETE
  engine, **every global pattern must include at least one raw (non-keyword and
  non-wildcard) symbol anchor** (e.g., `(f ?x)` is valid; `(?f ?x)` or `(?x 1)`
  are invalid globally).
* **Local Structural Patterns:** Purely structural, unanchored patterns are
  fully permitted when explicitly invoked via local operations (e.g.,
  `(replace dataset ((?a ?b) ?c) (a b c))`).

### Rule-Level Argument Holding (`hold=(...)`)
Functions and reduction rules can name parameters that are matched **raw** and
inserted into the replacement *exactly as matched* using the `hold=(...)` option
in `def`. Such a parameter is bound to the raw form for the duration of one
replacement — it is **not held**, and it is not evaluated at binding time; a
non-held parameter is reduced first. The replacement then reduces normally, so
the raw match is visible to the rules that immediately enclose it and is
evaluated in due course otherwise. An explicit `(unhold x)` evaluates a raw
match inside the body (`~` is a quasiquote hole and is a different operation),
and a held occurrence `'x` receives the *held* match.

*Example — raw argument insertion:*
```air
(def (f ?x ?y) hold=x (g x y))
(f (1 + 1) (2 + 2))          # => (g (1 + 1) 4), then (g 2 4)
(let (x=5 y=6) (f x y))      # => (g 5 6) (let substitutes before the rule runs)
```

### Empty-Body Definitions (Unreduced Forms)
A `def` with **no body** declares a rule that reproduces its matched form rather
than replacing it, so the form itself becomes a fixed point. The parameters are
still inserted according to the usual rule — a non-held parameter reduces, a
`hold=` parameter is inserted raw — but nothing else reduces:

```air
(def (f ?x))                 # arguments reduce, the form does not
(f (1 + 1))                  # => (f 2)
(def (g ?x) hold=x)          # the argument is inserted exactly as matched
(g (1 + 1))                  # => (g (1 + 1))
```

The replacement is the pattern with each matched part put back in place: an
unnamed `?` contributes its reduced match, a rest marker splices the remaining
elements, and an optional key contributes the subject's entry (or is omitted
when absent).

### Definition Bodies Are Blocks
A `def` body inherits the whole `do` grammar. It may use level-1 `:let`
markers, take the `let=` and `catch=` options, and end with `except`, `handle`,
and `finally` clauses; several body forms are evaluated in sequence as a `do`
block. A body that needs none of those is stored exactly as written, so an
ordinary one-form definition is unchanged:

```air
(def (recip ?x)
  catch=:zero
  (if (== x 0) (throw :zero :undefined) (/ 1 x)))

(recip 4)                 # => 0.25
(recip 0)                 # => :undefined

(def (lookup d k)
  let=(missing=:absent)
  (notify :miss k)
  (handle (:miss ?key) missing))
```

The option `tx=true` runs the body in a transaction, making the definition
equivalent to a `tx` instead of a `do`: an error escaping the body aborts every
write it made, while an error caught by the body's own `except` (or a throw
caught by its own `catch=`) commits. `tx=false` is the default, an ordinary
block. `let=`, `catch=`, and `tx=true` need a non-empty body.

`val` accepts the same options and body grammar; its value is evaluated once at
definition time.

### Memoization (`memoize=`)
A `def` may take `memoize=m` to cache results by the evaluated arguments:

* `memoize=true` or `memoize=:weak` (the default mode) holds each result
  **weakly**: an entry survives only while another value still references the
  result, so the cache never pins memory.
* `memoize=(:lru max)` holds up to `max` results strongly, evicting the least
  recently used entry.
* `memoize=false` or `memoize=naught` disables memoization, which is the
  default when the option is absent.

The key is the rule's **evaluated** parameter bindings, compared by `eq?`
equivalence: `(f (+ 1 1))` and `(f 2)` share an entry, `(f 1)` and `(f 1.0)` are
distinct, and equal maps written in a different order are the same key. A held
parameter contributes its raw match, exactly as the body sees it. The mode is stored with the definition in its namespace and is
reproduced by `definitions`; the cache itself is process-local and never saved.
A redefinition starts a fresh cache. An implicit `def` (no body) cannot be
memoized, and memoization assumes the body is deterministic — a result that
depends on a mutable, the current user, or another dynamic context will be
reused. A memoized result is computed eagerly, so recursive calls inside a
memoized rule do not occupy tail position.

```air
(def (fib ?n) memoize=true
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(fib 80)                  # => 23416728348467685
```


*Example — Fibonacci Sequence (Reduction Rule):*
```air
(def (f ?n)
  (if (= n 0) 1
      (= n 1) 1  # automatic else-if
      (+ (f (- n 1)) (f (- n 2)))))
```

*Example — Held argument:*
```air
(def (diff (?a + ?b) ?a)
  (1 + (diff (unhold b) (unhold a))))
(def (duff (?b + ?a) ?a)
  ((diff b a) + 1))
```

### Lambdas: A Replacement Rule in Head Position

There is no separate lambda form: **a replacement rule in head position is a
function**. Its pattern is matched against the arguments as written — no
arguments is `naught`, one argument is that argument, and several are the
argument list — and its replacement is the body:

```air
((?x -> (x ^ 2)) 3)              # => 9
(((?a ?b) -> (a + b)) 3 4)       # => 7
(let (f=(?x -> (x + 1))) (f 2))  # => 3
```

A multi-parameter pattern needs its own parentheses — the rule form has exactly
three elements, so `(?a ?b -> body)` is not a rule. A call whose pattern does
not match is left unreduced, and such a form passed to `map`, `filter`,
`reduce`, `sort-by`, and the other higher-order verbs is applied element by
element.

The body is **substituted, not lexically closed**: free names in the replacement
resolve when the rule is applied, in the caller's scope — `(let (x=2) ((?y ->
(x + y)) 3))` → `5`. A name bound by the pattern shadows an outer binding of the
same name. Rule data is opaque to scope resolution and to `let`: neither rewrites
the pattern, and the replacement is rewritten only where the pattern does not
bind the name.

Inside the body, `_` is bound to a **hold of every argument** as it entered:

```air
((?x -> _) 5)                    # => '5
(((?a ?b) -> _) 5 6)             # => (' 5 6)
((?x -> _) (a b))                # => (' (a b))
```

In a `replace` rule (and in a `case` clause) `_` is instead the entire matched
subject, **unheld**: `(replace (abc 1) ((? \ symbol? 1) -> (row=_)))` →
`(row=(abc 1))`. A replacement rule also accepts `unhold=true`, which inserts its
replacement unheld so the result is evaluated.

**Partial application** is the `part` form: `(part f a b)` captures `f`, `a`, and
`b` (holding them so they are not reduced) and applying the result appends the
new arguments — `((part add 10) 5)` is `(add 10 5)`. `partial` is not a separate
verb; use `part`. The companions `comp` (compose), `juxt` (apply all and
collect), and `complement` (negate a predicate) follow the same rule.

### Case Dispatch (`case` / `select`)

`(case subject clause… default?)` evaluates the subject once and tests each
clause in order. A clause is a replacement rule, using the ordinary pattern
language — wildcards, `\` conditions, nested patterns, and `_` for the whole
subject — so a clause can discriminate structurally, not just by equality:

```air
(case (abc 1) ((? \ symbol? 1) -> (row=_)) :other)   # => (row=(abc 1))
(case (a b) ((?n \ integer?) -> (n * 2)) ((?a ?b) -> (a + b)))  # => (a + b)
```

The first matching clause's replacement is evaluated and returned so a matching
clause in tail position is a tail call. A trailing element that is not a
replacement rule is the default, returned as-is when nothing matches; without one
the result is `naught`. A non-rule element anywhere but last is an error.
`select` is an alias.

### Level-Aware Traversal (`depth=`) and Pattern Selection

`replace`, `rreplace`, `map`, `cases`, and `drop-cases` accept `depth=n`, which
selects the level of the form they operate on. `depth=0` is the subject itself;
`depth=n` is every node `n` element steps down, where both sequence elements and
map values are children, with the structure above the selected level rebuilt.
A scalar is its own sole element (the same "a scalar is a singleton" convention
the collection verbs use), so descending past a scalar stays on it; an extern is
opaque. `replace` and `rreplace` default to `depth=0`; `map`, `cases`, and
`drop-cases` default to `depth=1`.

```air
(replace ((a 1) (a 2)) ((a ?x) -> x))          # => ((a 1) (a 2))  (depth 0)
(replace ((a 1) (a 2)) ((a ?x) -> x) depth=1)  # => (1 2)
(map (?x -> (wrap x)) (a=(1 2) b=3) depth=2)
# => (a=((wrap 1) (wrap 2)) b=(wrap 3))
```

`replace-all` and `rreplace-all` keep their whole-tree walk when `depth` is
absent; given `depth=n`, they operate only on level `n` (so `depth=0` is then
exactly `replace`).

`(cases coll clause… depth=n)` collects the elements at that level that match a
clause, in encounter order. A clause is a bare pattern (the element itself is
kept) or a replacement rule `(pattern -> replacement)` (the element is
replaced); a rule-level guard `(p \ g)` on a bare pattern tests the whole
element, so `(?x \ even?)` selects even elements. Non-matching elements are
omitted. `(drop-cases coll clause… depth=n)` returns the collection with the
matching elements removed and the rest of the structure rebuilt:

```air
(cases (1 2 3 4) (?x \ even?))                 # => (2 4)
(cases (1 2 3 4) ((?x \ even?) -> (10 * x)))   # => (20 40)
(drop-cases (1 2 3 4) (?x \ even?))            # => (1 3)
(drop-cases (a=1 b=2 c=3) (?x \ even?))        # => (a=1 c=3)
```

Unlike `case`, `cases` and `drop-cases` have no default clause: a bare pattern
is indistinguishable from one.

`(matches-any? subject clause…)` asks the same question over the **whole tree**:
it is true when the subject itself or any subpart matches a clause. Clauses are
as in `cases` — a bare pattern, a rule-level guard, or a replacement rule (only
its pattern and guard matter):

```air
(matches-any? (a (b 1)) b)             # => true
(matches-any? (1 3) (?x \ even?))      # => false
```

### Repetition (`nest`)

`(nest f n x)` applies `f` to `x` exactly `n` times; `(nest-list f n x)` returns
every value along the way, from `x` to the final one (`n + 1` elements).
`(nest-while f pred x)` applies `f` while `pred` holds of the current value,
testing before each application, so a value that already fails is returned
unchanged; `list=true` returns the values instead of the last one.

```air
(nest (?x -> (2 * x)) 5 1)                      # => 32
(nest-list (?x -> (2 * x)) 3 1)                 # => (1 2 4 8)
(nest-while (?x -> (x // 2)) even? 8)           # => 1
(nest-while (?x -> (x // 2)) even? 8 list=true) # => (8 4 2 1)
```

The count `n` must be a non-negative integer. `f` and `pred` take a symbol
naming a rule or a lambda, as the other higher-order verbs do; a predicate that
never fails is stopped by the reduction budget.

### Docstrings (`doc`)
A literal string at the head of a `def` body is that rule's **docstring**; it is
removed from the executable body. A multiline docstring is deindented: leading
and trailing blank lines are dropped and the continuation lines lose their
common indentation.

```air
(def (log ?x \ number?)
  "Returns the natural log of x."
  ...)

(def (log ?base \ number? ?x \ number?)
  "Returns the log-base-b of x."
  ...)
```

`(doc symbol)` returns a terminal-ready string listing every documented pattern
that uses the symbol, and `(doc (form…))` — which **holds** its argument rather
than evaluating it — lists the documented patterns that match that form:

```air
(doc log)          # both patterns above, each with its docstring
(doc (log 1.0))    # only the one-argument pattern
```

`(definitions arg)` takes the same argument and returns the matching `def` forms
as quoted data instead, moving each docstring from the head of the body into a
`doc=` map entry:

```air
(definitions log)
# => ((' def (log ?x \ number?) ... doc="Returns the natural log of x.")
#     (' def (log ?base \ number? ?x \ number?) ... doc="Returns the log-base-b of x."))
```

Undocumented rules are included too, just without a `doc=` entry. Because the
returned forms are live quoted data, rule bodies should use `(unhold x)` for
runtime unholding (it is an ordinary call and survives reconstruction verbatim)
and `lift` to build a computed quoted form. A `~` is a quasiquote hole: a body
that is itself quoted code containing `~` has that hole expanded when the
reconstruction's quote is built, so use `lift` there too if the body must
survive as data.

---

## Namespaces

A namespace is an ordered collection of `def` and `val` definitions addressed by
a dotted path. `.` alone is the global namespace root; `.air` is the core
namespace, holding every builtin, operator, standard-library name, and constant
(`pi`, `e`, `tau`, `inf`, `nan`). A leading-dot atom is a path:
`.util.algebra.square` reads as `(get . :util :algebra :square)`, so the whole
namespace tree is ordinary `.` access over nested namespace values. A bare name
in a namespace form is a root-level name, so `(namespace util …)` is
`(namespace .util …)`.

The root holds the process's system namespaces:

| path | contents |
| --- | --- |
| `.air` | the generated core namespace: builtins, operators, constants (owned by `air`, world `r-x`) |
| `.air.sys` | the system functions: `load-air`, `read-file`, `write-file`, `open-airdb`, `close-airdb` |
| `.sys` | system state; readable only by `air` |
| `.sys.user.<name>` | a system user's record and `home` |
| `.lib` | the library cache (owned by `air`, world `r-x`) |
| `.main` | `air`'s startup namespace |
| `.env` | a `val` holding the task's environment mapping |

Every entry in a namespace is itself a volatile with its own metadata — owner,
ACL, provenance, and an optional `anchor` — so two users may own different
definitions in one namespace, and an import is an explicit, inspectable entry
rather than a transient lookup. Metadata is visible to anyone who can reach an
entry; the **body** is gated by its `read` permission (see [Users, homes, and
permissions](#users-homes-and-permissions)).

```air
(namespace .util
  (def (twice ?x) (* x 2))
  (val answer 42))
(.util.twice 4)      # => 8
(.util.answer)       # => 42
```

`def` and `val` inside a `namespace` block append to that namespace, and a
subnamespace is created automatically: `(namespace .util.algebra (…))` registers
`algebra` inside `.util` (creating any missing ancestors). A `namespace` block is
a transaction — if a body form fails, everything the block defined rolls back. A
subnamespace may never shadow a definition of the same name, in either order, and
neither may a definition shadow a subnamespace.

Definitions added later are matched first, so a reload or override wins:

```air
(namespace .util (def (twice ?x) (* x 2)))
(namespace .util (def (twice ?x) (+ x x)))
(.util.twice 4)      # => 8, from the later definition
```

A zero-argument call applies a definition too: `(.util.f)` calls `f`, matching
either `(def (f) …)` or a scalar `(def f …)`.

### Roots, homes, and the current namespace

Three addresses are resolved by the running task rather than by fixed paths:

* `$` — the current user's **home** namespace: `.sys.user.<u>.home` for a system
  user, `@.user.<u>.home` for a database user. It is a capability held directly
  by the task, so a user works in their home without being able to read `.sys`
  (or the user records enclosing it).
* `@` — the root namespace of the database the task is attached to. An
  unattached user sees `@` as `.` (the air root).
* The **current namespace** — task-local: `$` for a created user, `.main` for
  `air` at boot. A top-level `def`/`val` is written there, so it is durable: an
  entry in a namespace rather than a process-global rule. `(namespace path
  body…)` replaces the current namespace for `body` and does **not** layer the
  caller's definitions, which is what makes `(namespace .air …)` pristine;
  `using=(ns…)` activates namespaces for the body without nesting it.

`$` and `@` are ordinary symbols: a lexically bound name shadows them and `let`
may rebind them (`(let ($=8) $)` → `8`), so bind them as data, not as code.

The task's identity, current namespace, database root, and `.env` mapping
travel with spawned tasks, so a `task` sees the same roots (see
[Tasks](#tasks)).

### `using`, `use`, and `import`

`(using spec… body…)` activates one namespace, or a list of them, for `body`:
the namespace's rules are searched (below `body`'s own definitions and above the
global store) and its `val`s become resolvable names. `using` copies nothing; it
is context for the body. A spec is a namespace address with optional `only=`,
`except=`, and `as=` options, written either as keyword pairs in the spec's
sequence or in its map:

```air
(using .util (twice 4))
(using (.util :only (twice answer)) (twice 4))
(using (.util :except (answer)) (twice 4))
(using ((.util :only (twice)) (.util.algebra :as alg)) (get alg :square))
```

Later specs have priority over earlier ones. `as=` binds the namespace value
itself to a name (it does not add a dot path).

Inside a `namespace` block, `(use spec…)` and `(import spec…)` **materialize**
the selected names as entries of the current namespace. `use` keeps them private
(they compile into the namespace's rules but are absent from its map); `import`
also exports them in the map. What is stored depends on what the importer may do
with the source entry:

| source entry | stored entry |
| --- | --- |
| readable `def` | a copy, owned by the target namespace's owner, carrying the source's ACL |
| readable `val` | an entry that shares the source's `Var`, so a rebinding of the source is visible |
| execute-only, a proxy, or `anchor=true` | a **proxy** storing `(source path, name)`; it applies the source lazily with the source entry's owner and ACL |
| subnamespace | a link entry, resolved through the source namespace |

Every imported entry records `source=<namespace>` in its metadata. Re-importing
a name replaces the previous entry from that source, so an `import` is how a
namespace is refreshed. A proxy keeps an execute-only body hidden; a missing
source raises `(error :proxy-unresolved path)` at call time. `(chmod! entry
anchor=true)` marks an entry so that it is always imported as a proxy, even when
it is readable.

```air
(namespace .algebra
  (use .util)                        ; may call (twice 2) inside this namespace
  (import (.util :only (answer)))    ; `answer` becomes part of `.algebra`
  (def (quad ?x) (* (twice (twice x)) 2)))
(algebra.quad 3)                     # => 24
(get . :algebra :answer)             # => 42
```

Removal:

* `(clear sym)` removes the current block's entries that define or export `sym`,
  including imported copies; `(clear :all)` removes every definition and import
  (local subnamespaces stay).
* `(unuse ns)` removes the block's entries imported from `ns`; `(unuse ns
  name…)` removes just those names (provenance is the entry's `source=`).
* `(del sym)` is an alias of `clear`. Outside a namespace block, `clear` targets
  the process-global rule store and never removes a builtin, operator, or core
  constant.

### Thread-local values (`val`, `bind`, `bindings`)

`(val pattern form…)` is like `def`, but `form` is evaluated once at definition
time and the pattern is installed as a value rather than a function — it cannot
be called. Each `val` is backed by an Air `Var`, so its value is **thread-local**:
a `bind` shadows it in the current task only and restores the previous value when
its body finishes. `bind` names values by the name its namespace context matches,
so it rebinds exactly the `val` that a bare reference would see:

```air
(val x 10)
(bind (x=99) x)                             # => 99
x                                           # => 10
(using .util (bind (answer=1) (twice 1)))   # => 3
```

The binding form is evaluated before it is used, so its values are ordinary
expressions (`(bind (x=(x + 1)) x)` → `11`). Binding a name that is not a `val` in
the current context is an error. `bind` is dynamic, not lexical: it affects calls
into rules and namespace functions made within its body.

`(bindings)` evaluates to a mapping of the current task's overrides — the `val`s
whose value differs from its definition value — and that mapping can be
reinstalled with `bind`:

```air
(bind (x=1 y=2) (bindings))     # => (x=1 y=2)
(bind (x=5) (bind (bindings) x))   # => 5
```

### Tasks

`(task form…)` holds its arguments and evaluates them on a separate task,
returning a database-backed **promise** immediately. `(await p)` blocks until
the task finishes and returns the value of the final form, or rethrows the
task's error; `(get p)` and `(ready? p)` read the same promise. A task captures
its enclosing lexical scope (like a closure), keeps the namespace context active
at the point it was created, and **inherits the current task's `val` bindings**:

```air
(val x 10)
(bind (x=100) (await (task (+ x 1))))   # => 101
```

The spawned task receives a copy of the bindings, so a later `bind` in the parent
does not change what the task sees. A task is a process item: its promise lives
in the current namespace's database, but the running task itself is not
serialized, so a promise whose task never delivered (because the process
stopped) is simply never delivered.

### Delays, actors, and promises

Three reference forms are backed by live objects *and* by the database, so they
survive a serialization round trip.

`(delay body…)` computes its body lazily and at most once. `(get d)`, `(get d 0)`,
and any `get` path that walks *through* `d` force it; a delay vanishes on the
path exactly as a mutable does. Free lexical names are substituted into the body
like a task's, and the namespace context active at creation — the current
namespace, its active `using` layers, the thread-local `val` bindings, `@`, and
`.env` — is saved with it, so the body runs correctly later, even after the
database is reopened. The first force stores the value in the delay's database
cell and every later force returns it without running the body again:

```air
(val counter (mut 0))
(val d (delay (set! counter (+ (get counter) 1))))
(get d)        # => 1
(get d)        # => 1 (the body does not run again)
(get counter)  # => 1
```

A delay is immutable and never forces on printing or serialization. The body
runs as the user who forces it (like a stored `def`), and a body that forces its
own delay raises a catchable error rather than recursing.

`(actor value history=true)` is a sequential worker whose value is persisted on
every update. `(send a fn)` sends the function `fn` (which receives the current
value and returns the new one) and `(reset! a value)` replaces the value
directly; both are deferred to commit inside a transaction, and `(sync)` flushes
a pending send. The send closes over the caller's lexical scope the way a task
does: a `loop`/`for` binding or rule parameter used inside `fn` is substituted
with its value, and the namespace context active at the call (its `using`
layers and `val` bindings) is kept, so a rule name or a `val` still resolves.
A name bound by the function's own pattern shadows the captured one, so
`(for (x …) (send a (?x -> …)))` uses the parameter, not the loop's `x`.
`(actor? x)` tests one.

`(promise)` is a single-assignment value in the current namespace's database.
`(deliver p v)` fills it (once), `(get p)`/`(await p)` read it — blocking until
it is delivered, except inside a transaction, which raises instead — and
`(ready? p)` tests it. A form holding an *undelivered* promise serializes as a
link (`"~uuid"`) and stores a row; a *delivered* one serializes as its value
inline, so a delivered promise keeps its value but not its identity across a
round trip. `task` returns such a promise; `deliver` and `await` also accept an
ephemeral promise extern.

---

## Users, homes, and permissions

Air's namespaces are multi-user. A **user id** is a keyword: `:air`, `:alice`,
`:game:bob`. Name segments are `[A-Za-z0-9_-]+` with no leading digit, no
leading `-` followed by a digit, and not the single `_`. A *constituent* id is
exactly `admin:name` (one level; a constituent cannot itself have
constituents). `:air` is the implicit superuser:
it passes every permission check, creates core users, and is the only user that
may change admin status.

`(current-user)` is the task's identity (default `:air`), and `(owner)` is the
owner of the `def` currently executing, else the current user. `(as-user id
body…)` evaluates `body` as `id` for its dynamic extent; authentication is out
of scope, so this is the whole mechanism for acting as another user. `(users)`
lists the users visible to the task — the system users, or the attached
database's users while `@` is set.

```air
(create-user :bob)                       ; :air only
(set-admin :game true)                   ; :air only
(as-user :game (create-constituent :kid)) ; => :game:kid
(as-user :game:kid (current-user))        ; => :game:kid
```

Each user has a **home** namespace, `$`: a top-level `def` run as that user is
written there. System users' records live in `.sys.user.<name>`; database
users' live in `@.user.<name>`. The home is a capability: `$` is reachable even
when the enclosing record is not, and `air`'s `.main` stays private.

### Permissions

Every namespace and every namespace entry is a volatile whose metadata carries
an owner and an ACL:

```air
(owner=:alice
 acl=(read=(_=true bob=true)
      write=(alice=true)
      exec=(_=true)
      assume=(game:bob=true)
      hide=(mallory=true)
      watch=(alice=true)
      filter=(alice=true)
      finalize=(alice=true)))
```

Each permission maps user ids to booleans; `:_` means every user. By default the
owner has `read`, `write`, `exec`, `watch`, `filter`, and `finalize`, and nobody
else has anything. `air` bypasses every check, and a core admin has ownership
privileges over its constituents' data. `hide` is a veto: a listed user has no
access of any kind. `watch` gates installing a watch (which also needs `read`);
`filter` and `finalize` gate replacing a mutable's filter or finalizer.
`anchor=true` is a per-entry flag rather than a permission — it forces imports of
that entry to be proxies (see [`using`, `use`, and
`import`](#using-use-and-import)).

`(permissions target)` returns the metadata, `(chmod! target read=(…) write=(…)
exec=(…) assume=(…) hide=(…) watch=(…) filter=(…) finalize=(…) anchor=…)`
replaces the listed permission maps, and `(chown! target user)` gives the target
a new owner. A `target` is a namespace, a definition (by name or by `(get …)`),
or a `mut`. `chmod!` and `chown!` need `write` on the target.

| operation | requires |
| --- | --- |
| `get`/printing/doc of an entry's body | `read` on the entry |
| calling a `def` | `exec` on its entry (and `read` on the namespace to reach its map) |
| resolving or `bind`ing a `val` | `read` on its entry |
| `def`/`val`/`clear`/`unuse` in a namespace | `write` on the namespace |
| `(namespace ns …)` | `read` on `ns`; writes additionally need `write` |
| `chmod!`/`chown!` | `write` on the target |
| reading/writing a `mut` | `read`/`write` on the mutable |
| `watch`/`unwatch`/`watches` | `watch` (and `read` for `watch`) on the mutable |
| `set-filter!`/`set-finalize!` | `filter`/`finalize` on the mutable |
| `(open-airdb …)` | `write` on the containing namespace |

A denial is a catchable error object, `(error :permission-denied
:read|:write|:exec|:assume target)`, whose content an `except` clause matches as
`(:permission-denied perm target)`, where `target` is a namespace path or a keyword name. Operations that
filter — `using`, `doc`, `definitions`, namespace printing — treat an
unreadable entry as absent rather than raising, and printing shows the body as
`#<entry …>`.

`(assume body…)` is legal only inside a `def` whose entry grants `assume` to the
current user. It evaluates `body` with `current-user` set to that definition's
owner, so an owner can expose a controlled operation on private data without
granting read or write on the data itself:

```air
(namespace .vault
  (val hidden 41)
  (def (peek) (assume hidden)))
(chmod! .vault read=(_=true) exec=(_=true))          ; the namespace is reachable
(chmod! (get . :vault :peek) exec=(_=true) assume=(bob=true))
(as-user :bob (.vault.peek))      # => 41; bob cannot read hidden directly
```

`(env)` returns the task's environment mapping, and `(with-env mapping body…)`
extends it for the dynamic extent of `body`. Both `.env` and `val` bindings
travel into a `task`; `(task clean=true …)` starts with empty bindings and
an empty `.env` but keeps identity and namespace context.

---

## Loading files and libraries

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

---

## Databases

A process starts with one private in-memory database holding the air root
(`.air`, `.sys`, `.lib`, `.main`, and the system user records). `(open-airdb
name opts…)` opens an AirDB database, roots a namespace at `name` in it, and
attaches `@` to that root for the calling task. From Julia, `Env(db = d)` selects
the **process** database — the store behind `.`, `.main`, and a system user's
home — and does not change the database of any opened root:

```air
(open-airdb .work memory=true)      ; an in-memory database (as in the tests)
(open-airdb .work dbname="air" user="air" host="localhost" port=5432)
(open-airdb .work url="postgresql://air@localhost/air" create=true)
```

| option | meaning |
| --- | --- |
| `memory=true` | a fresh in-memory database |
| `url=` / `conninfo=` | a libpq connection string, passed through verbatim |
| `dbname=` `user=` `host=` `port=` `password=` `sslmode=` | a PostgreSQL connection (`host` defaults to `localhost`, `port` to `5432`) |
| `create=true` | create the schema (`create_database`); the PostgreSQL database itself must exist |
| `create=false` | open an existing schema only |
| (absent) | try to open, then create |

A bare `name` is relative to the current namespace (so `air`'s `(open-airdb
work …)` roots `.main.work`); an explicit `.path` or `@.path` is absolute.
Opening requires `write` on the containing namespace, and a root may not be
placed over an existing namespace or where a database is already open. Unless
the opener is `air`, opening writes the opener's user record into the database;
an admin's status carries over. A newly created root is owned by its opener.

A namespace at or under an opened root lives in that database (the
longest-prefixed open root wins), so `(namespace .work.util …)` is durable
there. `@` addresses the same root: with `.work` open, `@.util.f` is
`.work.util.f`. Opening a database inside another (`(open-airdb .work.sub …)`)
creates a distinct database that owns the namespaces at or under `.work.sub`,
with its own users and permissions.

Database users are separate from system users. `(create-user :bob)` while
attached writes `@.user.bob` into the attached database; `(users)` lists that
database's users (`air` included); and a permission map in a database may name
only one of its own users (or `_`), so `(chmod! .work read=(mallory=true))`
raises a bad-user error. A user of another database is likewise not a valid
principal.

Because namespaces in a database are persisted as linked volatiles, a value
assigned there must be **storable**: it may not embed a volatile from another
database. Storing `.main`'s mutable or the `.air` namespace raises
`(error :un-storable target)` instead of writing an unresolvable link. `mut` inside a
database namespace creates its mutable in that same database.

`(close-airdb name)` flushes and closes the database, removes its root namespace
from the parent, and detaches `@` (returning it to `.`) when it pointed at that
root. Closing a database also closes any database rooted beneath it. From Julia,
`open_airdb!(env, path, db)` roots an already-opened database — the way the
tests use `MemoryDatabase` — and `close_airdb!(env, path)` closes it.

### The database of a form

A form's database is the database of the **namespace it is written in**, never
an ambient store chosen by the environment. The system namespaces (`.`, `.air`,
`.sys`, `.lib`, `.main`, and a system user's home) live in the process database;
a namespace at or under an opened root lives in that root's database. `mut`,
`logic-set`, the named-form operations, `form-at`, and `from-json` all follow
this one rule, so a mutable made in `.main` belongs to the process store even
while `@` points elsewhere, and storing it in a database namespace raises
`(error :un-storable …)`.

### Named forms

AirDB registers a name for a volatile, giving a form a durable, database-wide
handle:

```air
(named-form :counter create=true value=3)   ; create and name a new volatile
(named-form :counter)                       ; the same volatile
(value (named-form :counter))               ; 3
(named-form :counter create=false)          ; raises when the name is absent
(named-form :counter create=naught)         ; naught when the name is absent
(named-form :alias create=true value=(named-form :counter))  ; an alias
(name-form! :other (named-form :counter))   ; repoint an existing name
(named-forms)                               ; (alias=(mut 3) counter=(mut 3) …)
```

A name may be a keyword, a raw symbol, or a string; `:counter` and `"counter"`
agree, and the leading colon of a keyword is stripped, so `(named-form
:counter)` registers `counter`. Names beginning `air/` are reserved for air's
own bookkeeping and neither appear in `named-forms` nor may be created.
`value=` may be an ordinary form or an existing volatile of the same database,
in which case the name becomes an **alias** for it (no new form is made). A
created form records its history unless `history=false`. The name table is
transactional: a creation or repointing joins the enclosing transaction, so it
is retried or discarded with it, and a failed transaction leaves no name behind.

Creating a name publishes an entry from the current namespace, so it needs
`write` there (and a user record in a database); a lookup needs `read` on the
named form. A new named form is owned by its creator with the default owner-only
ACL. `named-forms` lists the names the caller may read. `name-form!` may claim a
free name with `write` in the namespace; repointing an existing name instead
needs `write` on the form currently named (or on the database root, for a
database administrator).

A **logic set** is a named volatile: `(logic-set :s)` is `(named-form :s)` whose
value has the logic-set shape. Every operation is gated by the set's own ACL —
mutating it (`assert`, `retract`, `revise`, `revise-fact`, and `logic`) needs
`write`, and every query (`facts`, `rules`, and `why`) needs `read`, as does
opening the set by name.

### Sync and status

`(sync)` blocks until every write committed before the call has reached the
database; `(sync target)` targets a namespace or volatile instead of the current
namespace's database. It is a **barrier**, not a drain: it queues a flush behind
the writes already scheduled, so writes that other tasks schedule afterward do
not delay it, and the sequential writer cannot be starved by continuing
activity. `(status)` returns `(pending=N error=naught)`: the number of updates
scheduled but not yet written, and the last writer error. Both are also
`.air.sys.sync` and `.air.sys.status`.

Air defers an actor message sent inside an open transaction until that
transaction commits, so a `sync` placed inside a `namespace`, `load-air`, or
other transaction cannot include that transaction's own writes. It flushes
every write already scheduled and returns; the block's writes are scheduled when
the block commits, so call `(sync)` outside the block to make them durable. A
`MemoryDatabase` has nothing to flush, so its `sync` returns at once.

### Form identity and JSON

`(form-id volatile)` returns the form's UUID as a string. `(form-at id)` returns
the volatile with that id in the current database without loading its body; when
no such form is in the database, reading the handle raises `(error
:form-not-found id)`. `(loaded? volatile)` reports whether the body has been read into memory,
and `(history volatile)` whether the form records its history.

`(to-json value)` encodes a form as JSON text and `(from-json text)` decodes it
in the current database. The codec is AirDB's: numbers and booleans are JSON
scalars, `naught` is `null`, a string is a JSON string carrying its reader quote
(`'hi`), a keyword is a JSON string carrying its colon (`"::x"`), a form is the
pair `[sequence, map]`, and a volatile is the link string `"@uuid"`. Links are
never expanded, so a cyclic structure encodes; `from-json` resolves each link
through the current database, and a link to a missing form raises
`(error :form-not-found id)`. An extern encodes by type and id (`{"extern": …,
"id": …}`) and reads back through the database's resource registry. The
database reference forms have their own encodings: an actor is `"!uuid"`, a
promise is `"~uuid"` until it is delivered (then it encodes as its value), and a
delay is `{"delay": ":air", "form": <the cell's link>}` — never forced by
encoding. A form bound for a database may embed only volatiles, actors, promises,
and delays of that same database; anything else raises
`(error :un-storable target)`.

Printing is cycle-safe on the same terms: a volatile that contains itself prints
the inner occurrence opaquely as `#<volatile uuid>` instead of recursing.

JSON has no infinity or NaN, so AirDB writes a non-finite float as a marked
string: `Inf` is `"#inf"`, `-Inf` is `"#-inf"`, and `NaN` is `"#nan"`. The `#`
marker cannot be confused with a string (`'`), a symbol (`:`), or a link (`@`),
and a literal string that looks like one is still a string, so `(to-json inf)`
is the JSON string `"#inf"` while `(to-json "#inf")` is `"'#inf"`. Such a value
flushes to any database, including the `.air` constants `inf` and `nan`.

---

## Testing

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

---

## The Two Rule Systems

Air features two complementary rule systems tailored for algebraic evaluation
and declarative logic programming, respectively.

### 1. Reduction Rules (Inner System / Term-Rewriting)
The inner system handles bottom-up algebraic evaluation, function definition
(`def`), syntax normalization, and immediate fixed-point reduction. When a form
like `(f 2)` is submitted to the evaluation engine, reduction rules evaluate it
recursively until a fixed point is reached.

### 2. Production Rules (Outer System / Deductive Engine)
The outer system operates like a DROOLS rules engine backed by `logic-set`
objects.
* **Logic Sets:** Users declare sets using `logic-set`, adding, changing, and
  removing facts with `(assert s fact)`, `(retract s fact)`, `(revise s
  condition changes)`, and `(revise-fact s old new)`. Operations take an
  optional `reason=` — `naught` (the default) or a keyword. `revise` changes
  only base facts: the condition binds wildcards and the `(k=v …)` map gives
  their new values.
* **`->` is replacement-only.** `(pattern -> replacement)` is inert data for the
  `replace` family (see below); it is not a rule in the outer system. A form
  containing `->` asserted into a logic-set is an ordinary fact.
* **Rules are structured forms.** A RETE rule is
  `(rule conditions… instructions…)`: the leading forms are an implicit
  conjunction (negation is `(not pattern)`), and the rest is a flat sequence of
  keyword/argument instruction pairs interpreted by the engine:
  ```air
  (assert s (rule (parent ?x ?z) (ancestor ?z ?y)
                  :if (not (done ?x))
                  :let (label=(concat x "/" y))
                  :> (ancestor ?x ?y)
                  :+ (log "new")
                  :- (log "gone")
                  := (log _)))
  ```
  * `:if cond` — if the condition is not truthy, the instructions after it are
    skipped (a skipped `:>` is `naught`).
  * `:let (k=v …)` — bind names as in a `let`; later instructions see them.
    Separate `:let` instructions are sequential, while bindings inside one map
    are parallel.
  * `:> form` — a consequence: the form must reduce to a fact or `naught`. Each
    `:>` has a fixed slot that identifies its output across firings.
  * `:+ form`, `:- form`, `:= form` — side effects run on an assertion,
    retraction, or revision trigger. They may call `assert`/`retract`/`revise`/
    `revise-fact` only with an explicit `reason=`. During `:=` the wildcard `_`
    is bound to a map of the changed wildcards to their new values.
* **Triggers are decided by the condition,** not by the consequence:
  a new combination of matches is an **assertion** (runs `:if`, `:let`, `:>`,
  `:+`); a combination that persists while a matched fact was revised (or an
  accumulator group changed) is a **revision** (runs `:=` instead); a
  combination that stops matching is a **retraction** (runs `:-` with the old
  bindings). Each `:>` slot's old and new outputs classify its own event:
  `naught`→fact asserts, fact→`naught` retracts, different facts revise, equal
  facts do nothing. Facts carry stable identities across revisions, so a
  downstream rule sees a revision rather than a retract/assert pair.
* **Reasons.** Every fact exists because of one or more reason records. A base
  fact records the label given to `assert`/`revise` (a keyword or `naught`); a
  derived fact records `(because RULE PREMISES…)`. Labels may be shared, and a
  fact survives while any reason holds it; retracting or revising one reason
  touches only that record. `(why s fact)` returns every reason.
* **Grouping and accumulation (`:accum`).** `:accum` lists the **accumulated**
  variables; every other bound variable is a group key:
  ```air
  (assert s (rule (student class=?c grade=?g)
                  :accum (g=:mean)
                  :> (avg class=?c value=?g)))
  ```
  Unannotated variables bind to vectors; `=:min`, `=:max`, `=:sum`, `=:mean`,
  `=:median`, `=:first`, and `=:last` aggregate. `:take (min v)`, `:take (max
  v)`, `:take :first`, and `:take :last` select one row instead. Repeated
  `:accum` specs nest: outer levels partition and the final level aggregates,
  yielding parallel sequences. `:first`/`:last` follow insertion order, and a
  revision keeps its position.
* **Atomic blocks.** `(logic s edits…)` applies a group of edits as one event:
  reads inside the block see the snapshot from entry, per-fact revision chains
  collapse within the call (but not across calls), and an error rolls the whole
  block back.
* **Advanced Features:** complete **provenance tracking** (a Justification-Based
  Truth Maintenance System) that records why a fact is true so an LLM can
  narrate explanations on demand.
* **In-Place Mutation & STM:** Instead of destructive retract/reassert cycles
  for mutable entities (like revising the fact
  `(stats player=:Nurgle health-points=100)` to
  `(stats player=:Nurgle health-points=90)`), `revise` moves the fact's reason
  record and identity in place, emitting a targeted delta.
* **Actor-Backed I/O:** Side effects involving file descriptors or network
  outputs are routed to background actors, ensuring safe rollback if STM
  transactions abort.

---

## Implementation Status

`AirLang.jl` currently implements the **inner (reduction) system**.

**Implemented**

* The reader: atoms (symbols, keywords, wildcards, strings, numbers, booleans,
  `naught`), parenthesized forms, the `|` pattern-alternative shorthand, `#` line comments
  and nestable `#| … |#` block comments,
  `k=v` mappings and hybrid forms, the `.` accessor (`f.a.b` reads as
  `(get f :a :b)`), and the `...` splat (`(f a... b)`) — parsed directly into
  `AirDB.Form` values.
* The reduction engine: anchor-indexed dispatch (a global pattern is anchored by
  *any* raw symbol it contains, so `(?a + ?b)` is anchored by `+`), fixed-point
  reduction, and runtime canonicalization of the empty form (`()` → `naught`).
* Pattern matching: exact structural match, named wildcards (`?x`), rest
  wildcards (`?&` sequence, `?*` keywords, `??` any remaining elements),
  alternatives (`p | q`, read as `(alt p q)`), and
  conditions (`pattern \ pred`, which must evaluate to `true`); the anchor rule is
  enforced at `def`.
* Error handling: `(error :tag …)` is an inert error **object** (arguments are
  never evaluated); `(raise :tag data…)` evaluates its arguments and throws
  `(error :tag data…)`, and raising a single error object throws it exactly.
  A `(do options… body… (except pattern body…)… (handle pattern body…)…
  (finally body…))` block matches each `except` pattern against the error's
  **content** (the object without its `error` head); a bare wildcard pattern
  binds the whole object, and the reserved symbol `reraise` as an `except`
  body's final value resumes the original error through later clauses. `do`
  also takes `let=` (a block scope) and level-1 `:let` markers, scoped
  `catch=`/`throw` (a throw returns the block early; an unmatched one is
  `(error :uncaught-throw tag value)`), and `handle` clauses for `(signal …)`
  objects dispatched by `(notify …)`/`(notify-or default …)`; a handler's value
  becomes `notify`'s value and execution continues. `finally` always runs and
  its value is discarded. `from=` records automatic handling context (Python's
  `__context__`) and `cause=` an explicit transformation; `showerror` prints
  the chain. Any internal AirLang or Julia error surfaces as
  `(error :internal <message>)`. An uncaught error aborts the enclosing STM
  transaction; an error caught inside the transaction commits; a throw escaping
  the transaction commits first and is rethrown. `try` has been removed (its
  name is a tombstone that raises).
* Diagnostics: the reader records each container's character span, and a loader
  (`load-air`, a library `init.air`, the CLI) installs it while evaluating, so
  an uncaught error prints `(at name:line:col)` plus the source line; a loaded
  `def`/`val` stores its definition site as `src=(name=… line=… col=… text=…)`
  in the entry body, and the innermost executing definition wins. Positions are
  best-effort (a bare REPL form has none) and never change the error object an
  `except` matches. `(trace body…)` yields the body's value or, on error, the
  data form `(:trace (error …) frames=(…))`.
* Held forms (code-as-data): a hold is a container headed by the ordinary symbol
  `'` — `(' a b c)` — and holds each element as written. `'x` is reader sugar
  for `(' x)` when `x` is a scalar (`'a`, `'5`, `':a`, `'"abc"`); `'(…)` is a
  parse error. A hold of one scalar prints with the quote, any other prints
  literally (`(' a b c)`). `(hold e…)` reduces to `(' e…)`, `(unhold x)` drops
  the head and evaluates the content, and `~e` (sugar for `(preval e)`) is an
  eagerly evaluated hole filled in inside any hold, at every depth and in each
  nested hold separately (`(let (x=2) (' a ~x b))` → `(' a 2 b)`; a `let`
  nonetheless substitutes its names textually, so `(let (x=2) (' a x b))` is
  also `(' a 2 b)`). `get` indexes the form as written — `(get (' f a b) 2)` is
  `f` — and `hold=true` makes the root hold transparent and keeps the result
  held, with a path walked without reducing intermediate values;
  `(with form k1 v1 … hold=true)` replaces subforms, inserting values without
  their own holds. Every operation with a primary form argument has a `hold-`
  version (`hold-get`, `hold-nth`, `hold-with`, `hold-wout`, `hold-push`,
  `hold-push-in`, `hold-join`, `hold-join-in`, `hold-update`, `hold-held?`, and
  `hold-thread`) that always sees through the root hold and holds its result;
  `hold=` selects the result's heldness. `held?`, `lower`, and `lift` are the
  remaining hold operations. The other accessors see the raw form
  (`(first (' a b c))` → `'`). `def` and a replacement-rule lambda accept a
  `hold=(x y)` / `hold=x` option, and patterns support optional `?k=default`
  keys.
* **Integer keys** are uniform across `get`, `nth`, `with`, `wout`, `update`,
  `update-in`, and `held?`: `0` is the whole form, `1…n` index the sequence,
  `-1…-n` count from the end, and a setter's key `n + 1` appends. Anything
  further raises. `update-in` follows the deep path `k1 … kn` and yields a
  missing key as `naught` to the function.
* **Operators** (`+ - * / ^ // mod = != < > <= >=`) are native and
  **infix-canonical**: `(a OP b)` is the canonical form, `(OP a b …)` is sugar,
  and non-numeric operands are left unevaluated (symbolic) — `(1 + 2)` → `3`,
  `(x + y)` → `(x + y)`.
* Special forms `def`, `let`, `if`/`cond`, `do`, `throw`, `notify`,
  `notify-or`, `get`, `match?`, `matches`,
  `mut`, `set!`, `swap!`/`alter!`, `tx`, `watch`/`unwatch`/`watches`,
  `set-filter!`/`set-finalize!`, `and`/`or`, `when`/`unless`, `case`/`select`,
  `doseq`/`dotimes`, and `for`; the `replace` family
  (`replace`, `replace-all`, `rreplace`, `rreplace-all`) with inert
  `(pattern -> replacement)` rules, an optional `unhold=true`, and a level
  selector `depth=n`.
* A Julia-native standard library: predicates (including `associative?` and
  `counted?`), numeric functions and constants (including the bitwise
  `bit-and`/`bit-or`/`bit-xor`/`bit-not`/`bit-shift-left`/`bit-shift-right`
  and `subdivide`), `compare`/`hash`, string
  operations (`string-format`, `string-reverse`, the `string-take`/
  `string-drop`/`string-capitalize`/`string-trim-left`/`string-trim-right`
  family, and the regex-aware `string-split`/`string-replace`/
  `string-index-of`/`string-contains?`/`string-match?`/`string-find`/
  `string-find-all` with `(regex …)` values and `$0`/`$1`/`$name`
  replacement syntax),
  collection verbs (`map`/`filter`/`reduce`, `prepend`, `zip`, `interleave`,
  `flatten`, `partition`, `with`/`wout`, `sort`, `range`, `join`, `shuffle`,
  `variance`, `cases`/`drop-cases`, `matches-any?`, `where`
  (locations), `nest`/`nest-list`/
  `nest-while`, `transpose`, `riffle`, `tuples`, `count-distinct`,
  `gather-by`/`split-by`, `map-thread`, `outer`, `array`,
  the set operations `union`/`intersect`/
  `difference`/`subset?`/`superset?`, …), and
  higher-order functions that take a symbol naming a rule or a
  `(pattern -> replacement)` lambda; `memoize` wraps a function in a callable
  that caches by function and arguments, and `memoize=` on a `def` gives the
  definition itself a weak or LRU cache.
* I/O: `print`/`println` write through Air's actor-backed `airout` (so output is
  deferred to a transaction's commit and dropped on abort), `str` concatenates,
  and `read-file`/`write-file` read and (actor-backed) write files.
* Recursion & composition: `loop`/`recur` and `while`; general tail calls (a
  call in tail position — the branch of an `if`, a `let` body, the last form of
  a clause-free `do` (with or without `:let`/`let=`), a
  `when`/`unless` body, the last operand of `and`/`or`, a rule body, or an
  applied lambda body — is reduced iteratively, so a tail-recursive rule runs in
  constant stack and only nested, non-tail recursion is depth-bounded);
  lambdas as replacement rules in head position, whose bodies resolve their free
  names in the caller's scope at application time; the `>>` pipeline, which
  substitutes `_` textually through raw
  steps and reduces only the final form
  (`(let (x=2) (x >> (_ + 1) (f _) (result=_)))` → `(result=(f 3))`); the
  Mathematica-style `thread` / `hold-thread`, which distribute a form over its
  sequential container elements (`(thread (f (1 2 3)))` →
  `((f 1) (f 2) (f 3))`); and `identity`/`constantly`/`comp`/`complement`/
  `juxt`, defined as air-level rules registered on every environment.
* Namespaces: `(namespace ns body…)` with automatic subnamespaces, atomic
  blocks, and later-definition priority; dotted `.` paths through the root `.`
  and the core `.air`; `(using spec… body…)` (one namespace or a list, with
  `only=`, `except=`, and `as=`); materialized `(use …)` / `(import …)` inside a
  namespace block, with copy/link/proxy entries and `source=` provenance;
  `(clear sym)`, `(clear :all)`, `(unuse ns …)`, and `(del sym)`; thread-local
  `val`s backed by Air `Var`s with `(bind (x=v …) body…)` and `(bindings)`; and
  namespace-aware `doc`/`definitions`. Top-level `def`/`val` target the
  task-local current namespace (`$`, or `.main` for `air`), so they are durable.
* Users and permissions: task-local `current-user`/`owner`, `(as-user …)`,
  `(create-user …)`, `(create-constituent …)`, `(set-admin …)`, `(users)`,
  homes via `$`, the attached-database root `@` (`.` when unattached), the
  task-local `.env` with `(with-env …)`, and a per-volatile owner/ACL enforced
  on read, write, exec, assume, watch, filter, and finalize, with `hide` as a
  veto. `(permissions …)`, `(chmod! …)` (including `anchor=true`), `(chown! …)`.
  Permission denials are catchable `(error :permission-denied …)` objects; filtered
  operations treat an unreadable entry as absent.
* Mutables: `set!` (including deep traversal), `swap!`/`alter!`, `(get m)`; a
  `mut` filter and finalizer (`mut filter=… finalize=…`, `set-filter!`,
  `set-finalize!`), stored in metadata so they survive a reload; and watches
  (`watch`/`unwatch`/`watches`), which run as their registrar, once per mutable
  per transaction, at the end of the outermost transaction body before the
  commit, so their writes are transactional. Filter and finalizer forms that are
  not replacement rules are evaluated with `_` bound to the value.
* Loading and libraries: `(load-air path…)` is parse-first and atomic, with
  relative paths resolved against the loading file's directory; `AIR_LIBPATH`
  discovery of `<name>/init.air`; lazy, per-library-locked loads under
  `.lib.<name>` as `air`; and the `.air.sys` system functions.
* Databases: `open-airdb`/`close-airdb` over AirDB (in-memory or PostgreSQL via
  `url=`/`dbname=…`), a namespace root per database with longest-prefix
  ownership of the tree, `@` attachment, per-database users and ACL principals,
  recursive close, and the storable-form check (`(error :un-storable …)`). The
  Julia entry points are `open_airdb!`/`close_airdb!`.
* Persistence: one database per namespace, so `mut`, logic sets, and named forms
  agree on where a form lives; `named-form`/`name-form!`/`named-forms` with
  aliases, `create=`, `history=`, per-database names, and the `air/` prefix
  reserved; logic-set ACLs (write to mutate, read to query); `sync`/`status` as a
  FIFO flush barrier; `form-id`/`form-at`/`loaded?`/`history`; the
  `to-json`/`from-json` codec with `"@uuid"` links and extern references; and
  cycle-safe printing (`#<volatile …>`).
* An air-level test framework: `(check expr)` is a boolean truth test that records
  inside a `(test name body…)`, whose result is the inert data summary
  `(name=… pass=… fail=… failures=(…))`; counters are task-local, so nested and
  concurrent tests do not interfere.
* A REPL (`air_repl`) and the `air` command line (`bin/air`). The REPL reads a
  form across lines while the reader reports an unterminated form, string, or
  block comment (a `...> ` continuation prompt), prints results through
  `air_pretty_string(x; width=80)` (greedy line breaking; pass `pretty=false`
  for the flat form), and appends each complete input to the file named by
  `AIR_HISTORY` for external line editors such as `rlwrap`.
* The outer production-rule engine (core): a `logic-set` is a named form in the
  database; `assert`, `retract`, `revise`, and `revise-fact` edit facts and
  rules, saturating the set to a fixed point. A rule is the structured
  `(rule conditions… instructions…)` form: the conditions are an implicit
  conjunction (`(not pattern)` negates, `:accum` groups), and the instructions
  are `:if`, `:let`, `:>` (consequence slots), and the trigger side effects
  `:+` / `:-` / `:=`. The condition's event — assertion, revision, or
  retraction — decides which side effects run; each `:>` slot's old and new
  outputs classify its own fact event. Facts have stable identities across
  revisions and one or more reasons: a base label (`naught` or a keyword) or a
  derived `(because RULE PREMISES…)`; `(why s fact)` returns them. `:accum`
  lists the accumulated variables (unlisted bindings are group keys), with
  `=:min`/`=:max`/`=:sum`/`=:mean`/`=:median`/`=:first`/`=:last` aggregators,
  `:take` row selection, and nested specs that yield parallel sequences.
  `(logic s edits…)` applies a block as one atomic event (snapshot reads,
  per-call revision collapse, rollback on error); `(update coll key f)` is the
  collection update. Facts and rules enter a logic-set **held**, so they are
  immutable data: a later `def` cannot rewrite a stored rule, and
  `(facts s)`/`(rules s)` return them held and always as a list
  (`((' parent :abe :bob))` for one fact). The
  incremental alpha/beta network is still deferred.
* Extern objects: a host-level value (a promise, a regex) is a
  first-class form leaf, built on AirDB's `FormExtern`/`ExternHandle` and its
  `register_extern` type registry. `(extern :type payload)` reconstructs one from
  the payload its printed form carries, `extern?`/`extern-type` inspect one, and
  an extern prints as `(extern :type payload)`, so it round-trips through source.
  A regex is a **value**: equal source-and-flags pairs are interned to the same
  extern, so they are `eq?` and `same?`; promises are **identities**.
  Concurrency: `(task form…)`, `(deliver p v)`, and `(await x)`; `task`
  holds its arguments, runs them on another task, and immediately returns a
  database-backed promise. `await` returns the final form's value or rethrows
  the task's error. A task captures its enclosing lexical scope like a
  closure, keeps the namespace context captured at creation, and inherits the
  current task's `val` bindings (see Namespaces). An unnamed extern has
  no stored data, so persisting one writes it without an id and reading it back
  yields a dead extern that prints `#<extern :type (expired)>`; touching one
  raises the catchable air error `(error :extern-expired :type)`. A spawned task runs
  its own STM transaction, so two tasks mutating the same form conflict and retry.
* Database reference forms: an actor, a promise, and a delay are database-backed
  values (AirDB's `ActorForm`, `PromiseForm`, `DelayForm`) with their own
  serializations. `(actor value history=…)`/`(send a fn)`/`(reset! a v)`,
  `(promise)`/`(deliver p v)`/`(ready? p)`, and `(delay body…)`; `get` (and
  `value`) force a delay and read an actor or a promise, so all three vanish on a
  `get` path like a mutable. Delays capture the namespace context, active
  `using` layers, `val` bindings, `@`, `.env`, and their free lexical names,
  compute once, and persist the result in a database cell.

**Deferred**

* Sequence patterns and sequence replacement: a rule whose pattern matches a
  run of elements rather than a whole form.
* Head-restricted blanks: not supported; use a condition (`p \ pred`).
* The outer engine's incremental RETE alpha/beta network (a full re-derivation
  runs on each assert instead).
* Forms-as-functions querying (`(f 1)` on a collection returns its element).
* Serializable tasks: a task is a process item, so only its promise is
  stored (as a link until delivered, as its value afterwards). Storing the
  running task so it can respawn after a reload is deferred; a promise whose
  task never delivered is simply never delivered.
* Sockets and other extern types; `pmap` and higher-level parallel helpers built
  on `task`.

**Spec notes**

* `.` is reserved: it is the subform accessor, the namespace root, and the
  splat, not a symbol character. On a form, `.` is pure syntactic sugar for
  `get`: `form.key` reads as `(get form :key)` and `f.a.b` as `(get f :a :b)`,
  which `get` walks so it can be overridden. At the start of an atom, `.`
  introduces a namespace path (`.`, `.air`, `.util.a` read as `(get . :util :a)`;
  the leading dot is the root, `.air` is the core namespace). The accessor keys
  are **held**: a bare suffix is the literal keyword, so `f.a` does not see a
  variable `a`. `~` evaluates a single key — `f.~k` reads as `(get f (preval k))`,
  and `f.~a.b` as `(get f (preval a) :b)`. A numeric suffix indexes a sequence and
  a written keyword (`f.:a`, `f.:test`) is kept as written.
* An operator's canonical form is infix, and operators are symbolic on
  non-numeric operands. Because infix is binary, `(1 + 2 + 3)` is a five-element
  form (write `(+ 1 2 3)` or `(1 + (2 + 3))`).
* The symbol character set is extended to accept `<` and `>` (used by the
  comparison operators but absent from the list above).
* The anchor rule is enforced as "at least one raw symbol anywhere in the
  pattern", which admits infix patterns such as `(?a + ?b)`.
* Canonicalization is applied by the reducer, not by the reader or by equality.
* Complex numbers use `i`, not Julia's `im`. A no-space `4.4+2.0i` (the `i`
  attached to the number) is a single literal; the spaced `(4.4 + 2.0i)` is the
  infix sum, which reduces to the same value. A complex prints as `4.4 + 2.0i`.
