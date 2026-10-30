# Patterns and function definitions

Definitions in air are **patterns**: a form with wildcards that, when it matches
a subject, supplies a replacement. A `def` installs one globally; a replacement
rule in head position acts as a function; and the same pattern language drives
`replace`, `case`, `map`, and the other traversal verbs. This chapter covers the
pattern language and everything built on it.

## Pattern Matching Rules
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

## Global vs. Local Patterns & The Anchor Rule
* **Global Evaluation Rules:** To guarantee blazing-fast indexation in the RETE
  engine, **every global pattern must include at least one raw (non-keyword and
  non-wildcard) symbol anchor** (e.g., `(f ?x)` is valid; `(?f ?x)` or `(?x 1)`
  are invalid globally).
* **Local Structural Patterns:** Purely structural, unanchored patterns are
  fully permitted when explicitly invoked via local operations (e.g.,
  `(replace dataset ((?a ?b) ?c) (a b c))`).

## Rule-Level Argument Holding (`hold=(...)`)
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

## Empty-Body Definitions (Unreduced Forms)
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

## Definition Bodies Are Blocks
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

## Memoization (`memoize=`)
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

## Lambdas: A Replacement Rule in Head Position

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

## Case Dispatch (`case` / `select`)

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

## Level-Aware Traversal (`depth=`) and Pattern Selection

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

## Repetition (`nest`)

`(nest f n x)` applies `f` to `x` exactly `n` times; `(nest-list f n x)` returns
every value along the way, from `x` to the final one (`n + 1` elements).
`(nest-while f pred x)` applies `f` while `pred` holds of the current value,
testing before each application, so a value that already fails is returned
unchanged; `list=true` returns the values instead of the last one.

```air
(nest (?x -> (2 * x)) 5 1)                      # => 32
(nest-list (?x -> (2 * x)) 3 1)                 # => (1 2 4 8)
(nest-while (?x -> (div x 2)) even? 8)           # => 1
(nest-while (?x -> (div x 2)) even? 8 list=true) # => (8 4 2 1)
```

The count `n` must be a non-negative integer. `f` and `pred` take a symbol
naming a rule or a lambda, as the other higher-order verbs do; a predicate that
never fails is stopped by the reduction budget.

## Docstrings (`doc`)
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
