# AirLang Examples

Worked solutions to the 25 problems in `example-problems.md`, written in air and
checked against the interpreter. Each entry gives the air code and a status:

- **✓** — works as written.
- **⚠** — works, with a caveat noted inline.
- **✗** — cannot be written with the current system; the blocking gap is named.

Everything here runs against an in-memory database (`MemoryDatabase`), so no
Postgres is needed; only the STM examples in Tier 4 need `env.db`.

Two syntax notes that the examples rely on: a `:name` is a **keyword** (inert
data), while a **hold** is a container headed by the symbol `'` — `(' a b c)` —
and `'x` is sugar for `(' x)` when `x` is a scalar, so `(' a b)` stays held as
data. Inside a hold, `~e` (sugar for `(preval e)`) is substituted with the value
of `e` (`(let (x=2) (' a ~x b))` → `(' a 2 b)`; a `let`, however, substitutes its
names textually, so `(let (x=2) (' a x b))` → `(' a 2 b)` too). `(let (x=1 y=2)
body…)` binds in parallel and substitutes the values into the body before
evaluating it; a sequence of mappings, `(let ((a=1) (b=2)) body…)`, lets each
group feed the next. `(get c i)` is the one accessor: an integer indexes a
sequence (1-based), a keyword a map, so a held form's content starts at index 2
(`(get (' f a b) 2)` is `f`). `hold=true` makes the root hold transparent, keeps
the extracted part held, and walks the path without reducing the intermediates;
`(with form k1 … kn val hold=true)` is the inverse, replacing a subpart with
`val` inserted without its own hold. The `hold-` family (`hold-get`,
`hold-with`, …) is the same treatment with the result held, and `>>` builds a
pipeline with `_` as the placeholder (`(x >> (_ + 1) (f _))`).

---

## Tier 1 — Core Collections, Immutability, and Data Manipulation

### 1. Word Frequency Counter ✓

```air
(def (word-counts ?text) (frequencies (string-split (string-lower text))))
(word-counts "the cat the dog the")   # => (cat=1 dog=1 the=3)
```

### 2. Nested Map Patching ✓

```air
(def (set-host ?cfg ?host) (with cfg :db (join (get cfg :db) host=host)))
(set-host (db=(host="x" port=1)) "y")   # => (db=(host="y" port=1))
```

`with` sets a subform at a key path (here the `:db` submap), `join` merges in
the new entry, and a **dynamic key** (`~k=…`) lets the key be computed:
`(let (a=:hits) (with cfg :db (join (get cfg :db) ~a=3)))`.

### 3. Sequence Rotation & Splice ✓

```air
(def (rotate-left ?c)  (join (drop-first 1 c) (first c)))
(def (rotate-right ?c) (join (last c) (wout c)))
(def (insert ?c ?i ?x) (join (take i c) (x) (drop-first i c)))
(def (remove-at ?c ?i) (wout c i))

(rotate-left (1 2 3 4))        # => (2 3 4 1)
(insert (1 2 3 4) 2 99)     # => (1 2 99 3 4)
```

### 4. Run-Length Encoding ✓

`partition-by` groups *adjacent* equal elements (`partition` is fixed-size):

```air
(def (rle ?c)   (map (?g -> ((first g) (count g))) (partition-by identity c)))
(def (unrle ?c) (mapcat (?p -> (repeat (get p 2) (get p 1))) c))

(rle (1 1 2 2 2 3))   # => ((1 2) (2 3) (3 1))
(unrle ((1 2) (2 3) (3 1)))   # => (1 1 2 2 2 3)
```

### 5. JSON-to-Air Map Normalization ✓

`keyword` turns a string key into a keyword; a dynamic key builds the map:

```air
(def (normalize ?raw)
  (reduce ((?acc ?kv) -> (let (k=(keyword (get kv 1))) (join acc ~k=(get kv 2)))) () raw))

(normalize (("host-name" "x") ("port" 1)))   # => (host-name="x" port=1)
```

---

## Tier 2 — Pattern Matching, Guards, and Term-Rewriting

### 6. Symbolic Algebraic Simplifier ✓

```air
(def (?x + 0) x)   (def (0 + ?x) x)
(def (?x * 1) x)   (def (1 * ?x) x)
(def (?x * 0) 0)   (def (0 * ?x) 0)

((2 + 0) * 1)   # => 2
(x * 0)         # => 0
```

Rules anchored on an operator now fire (the infix check falls through when the
operands aren't both numbers).

### 7. Symbolic Differentiation Engine ✓

```air
(def (d (?f + ?g) ?x) ((d f x) + (d g x)))
(def (d (?f * ?g) ?x) (((d f x) * g) + (f * (d g x))))
(def (d ?x ?x) 1)
(def (d ?c ?x) 0)

(d (x * x) x)   # => ((1 * x) + (x * 1))
(d (x + x) x)   # => 2
```

Rule **order** matters (the catch-all `(d ?c ?x)` must come last). The result is
unsimplified because the simplifier from #6 doesn't include `(1 * ?x) → x` unless
you add it.

### 8. Pattern Guards & Input Validation ✓

```air
(def (checked ?x \ integer?) x)
(def (checked ?x \ symbol?) (raise :arg-type x))

(checked 5)                                       # => 5
(do (checked :a) (except (:arg-type ?e) :caught)) # => :caught
```

A **signal** is the non-error counterpart: `(notify …)` runs the matching
`handle` clause and continues with its value, so a caller can observe progress
without unwinding. The handler may be written after the notify it serves.

```air
(do (notify :progress 40)                     # => 41
  (handle (:progress ?pct) (+ pct 1)))

(do (notify-or :ignored :progress 40)         # => 40 (the default is held)
  (handle (:progress ?pct) pct))
```

### 9. Depth-Controlled Lowering ✓

```air
(lower (' f (a (b c))) 1)    # => ('f (' a (b c)))
(lower (' f (a (b c))) -1)   # => ('f ('a ('b 'c)))
```

### 10. Tail-Call Factorial & Fibonacci ✓

```air
(def (fact ?n) (loop (n n acc 1) (if (n == 0) acc (recur (n - 1) (acc * n)))))
(def (fib ?n)  (loop (a 0 b 1 k n) (if (k == 0) a (recur b (a + b) (k - 1)))))

(fact 10)   # => 3628800
(fib 20)    # => 6765
```

A recursive definition can cache instead of looping:
`(def (fib ?n) memoize=(:lru 100) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))`.

⚠ `(fact 500)` wraps: AirDB leaves are `Int64`/`Float64`/`ComplexF64`, so there
are no bignums.

### 11. Structural Schema Validator ✓

```air
(def (valid-person? ?p \ (and (haskey p :name) (haskey p :age))) true)
(def (valid-person? ?p) false)

(valid-person? (name="Ada" age=36))   # => true
(valid-person? (name="Ada"))          # => false
```

---

## Tier 3 — Deductive Logic and the RETE Engine (`logic-set`)

Facts and rules enter a logic-set **held**, so the outputs below print their facts
quoted (e.g. `(' parent :abe :bob)`); the examples show them unquoted for
readability.

### 12. Family Tree Transitive Closure ✓

```air
(let (s=(logic-set :family))
  (assert s (parent :abe :bob))
  (assert s (parent :bob :carl))
  (assert s (rule (parent ?x ?y) :> (ancestor ?x ?y)))
  (assert s (rule (parent ?x ?z) (ancestor ?z ?y) :> (ancestor ?x ?y)))
  (facts s))
# => ((parent :abe :bob) (parent :bob :carl)
#     (ancestor :abe :bob) (ancestor :bob :carl) (ancestor :abe :carl))
```

`(why s (ancestor :abe :carl))` returns
`(because (rule (parent ?x ?z) (ancestor ?z ?y) :> (ancestor ?x ?y))
(' parent :abe :bob) (' ancestor :bob :carl))` — the rule and the premises that
derived the fact. Conditions are an implicit conjunction, and each `:>` is a
tracked consequence; side effects use `:+` (assertion), `:-` (retraction), and
`:=` (revision), and must carry an explicit `reason=` when they edit the set.

### 13. Graph Shortest Path ✓

Derive all paths, then keep the minimum per `(from to)` pair with `:accum`:

```air
(let (s=(logic-set :g))
  (assert s (edge :a :b 1))
  (assert s (edge :b :c 2))
  (assert s (edge :a :c 5))
  (assert s (rule (edge ?x ?y ?w) :> (path ?x ?y ?w)))
  (assert s (rule (path ?x ?z ?w1) (path ?z ?y ?w2)
                  :> (path ?x ?y (w1 + w2))))
  (assert s (rule (path ?x ?y ?w) :accum (w=:min) :> (shortest ?x ?y ?w)))
  (facts s))
# => (… (shortest :a :b 1) (shortest :b :c 2) (shortest :a :c 3))
```

`:accum (w=:min)` accumulates `?w`, so `?x` and `?y` are the group keys; the
minimum is taken per pair, and the direct `:a → :c` edge (weight 5) loses to the
two-hop path (1 + 2).

### 14. Expert Diagnostic System ✓

```air
(let (s=(logic-set :diag))
  (assert s (rule (symptom ?s) :> (cause :overheat)))
  (assert s (rule (cause :overheat) :> (fix :check-fan)))
  (assert s (symptom :loud))
  (facts s))
# => ((symptom :loud) (cause :overheat) (fix :check-fan))
```

### 15. Constraint Satisfaction (N-Queens) ⚠

Constraint **propagation** via production rules works — a queen attacks its column
and both diagonals, and a candidate square is `blocked` when attacked:

```air
(let (s=(logic-set :nq))
  (assert s (queen 1 2))
  (assert s (queen 2 4))
  (assert s (rule (queen ?r ?c) :> (attacks-col ?c)))
  (assert s (rule (queen ?r ?c) :> (attacks-diag (r + c))))
  (assert s (rule (queen ?r ?c) :> (attacks-antidiag (r - c))))
  (assert s (rule (attacks-col ?c) :> (blocked 3 ?c)))
  (assert s (rule (attacks-diag ?d) :> (blocked 3 (d - 3))))
  (assert s (rule (attacks-antidiag ?d) :> (blocked 3 (d + 3))))
  (facts s))
```

⚠ A full *solver* also needs search (place a queen, propagate, backtrack). The
propagation half is expressible; the search half is ordinary `loop`/`recur` on top
of it. Bounds (columns 1..n) are the caller's to enforce.

### 16. State Machine / Workflow Engine ✓

```air
(let (s=(logic-set :wf))
  (assert s (rule (state ?x :pending) (trigger ?x) :> (state ?x :running)))
  (assert s (rule (state ?x :running) (done ?x) :> (state ?x :complete)))
  (assert s (state :job :pending))
  (assert s (trigger :job))
  (assert s (done :job))
  (facts s))
# => (… (state :job :running) (state :job :complete))
```

### 17. Package Dependency Resolver ✓

```air
(let (s=(logic-set :pkg))
  (assert s (depends :app :lib1))
  (assert s (depends :lib1 :lib2))
  (assert s (depends :lib2 :lib3))
  (assert s (rule (depends ?x ?y) :> (needs ?x ?y)))
  (assert s (rule (depends ?x ?z) (needs ?z ?y) :> (needs ?x ?y)))
  (facts s))
# => needs :app→:lib1,:lib2,:lib3 and the rest of the closure
```

---

## Tier 4 — Error Handling, STM Transactions, and Persistence

### 18. Robust Bank Transfer ✓

```air
(let (a=(mut (balance=100)) b=(mut (balance=50)))
  (def (transfer ?f ?t ?amt)
    (let (bal=(get (value f) :balance))
      (if (bal < amt) (raise :insufficient f)
        (do (set! f :balance (bal - amt))
            (set! t :balance ((get (value t) :balance) + amt))))))
  (transfer a b 30)
  (get (value a) :balance))   # => 70
```

An uncaught error aborts the enclosing transaction (verified in `test/mut.jl`); a
caught validation error leaves account state intact. A `def` body can also be a
transaction on its own: `(def (transfer ?f ?t ?amt) tx=true …)` aborts its writes
when the body raises, without an enclosing `tx`; the body takes `let=`, `catch=`,
`:let`, and the `do` clauses directly.

### 19. IO Retry with Backoff ✓

```air
(let (tries=(mut 0))
  (def (flaky) (set! tries ((value tries) + 1))
               (if ((value tries) < 3) (raise :io :transient) :ok))
  (def (retry ?f ?n)
    (loop (k n) (do (f) (except (:io ?e) (if (k == 0) reraise (recur (k - 1)))))))
  (retry flaky 5))   # => :ok
```

### 20. Persistent Event-Sourcing Log ✓

An append-only log is a `mut` holding a container, appended with `with`. The log
starts with a two-element header `(:log :start)` so a one-event log cannot
collapse to the event itself:

```air
(let (log=(mut (:log :start)))
  (def (emit-event ?e) (set! log (push (value log) e)))
  (emit-event (:added :a))
  (emit-event (:removed :b))
  (value log))
# => (:log :start (:added :a) (:removed :b))
```

Replay folds the events into a state map (keyword elements are the header and
are skipped):

```air
(reduce ((?state ?e) ->
          (if (keyword? e) state
            (let (k=(keyword (name (get e 2))))
              (if (eq? (get e 1) :added) (join state ~k=true) (drop state k)))))
        () (value log))
# => (a=true)
```

The header matters because a **one-element sequence canonicalizes to its
element**; without it, a single-event log is indistinguishable from the event.
Snapshots are just a `def`/`let` holding the replayed state map.

### 21. Concurrent Multi-Threaded Counter ✓

`task` spawns a task; the STM makes the increments safe:

```air
(let (c=(mut 0))
  (let (fs=(for (i (range 8)) (task (set! c ((value c) + 1)))))
  (each await fs)
  (value c)))   # => 8
```

---

## Tier 5 — Advanced Metaprogramming and Grand Challenges

### 22. A Tiny Sub-Language Interpreter ✓

`eval` evaluates a form as data; the interpreter walks the AST directly (the
operator is the *middle* element of an infix form):

```air
(def (interp ?form ?env)
  (if (number? form) form
    (if (symbol? form) (get env form)
      (let (op=(get form 2) l=(get form 1) r=(get form 3))
        (if (op == +) ((interp l env) + (interp r env))
            (op == *) ((interp l env) * (interp r env))
            (raise :unknown op))))))

(interp ((x * 2) + 1) (x=5))   # => 11
```

### 23. SQL AST Generator ✓

```air
(def (to-sql ?q)
  (str "SELECT " (string-join (map name (get q 3)) ", ") " FROM " (name (get q 2))))

(to-sql (query (users) (id name)))   # => "SELECT id, name FROM users"
```

### 24. Conway's Game of Life ✓

2D grids are nested forms; `get` indexes them and the neighbour sum uses `for`
over the 3×3 offset window:

```air
(def (cell ?g ?r ?c)
  (if (or (r < 1) (c < 1) (r > (count g)) (c > (count (get g 1)))) 0
    (let (v=(get (get g r) c)) (if (naught? v) 0 v))))

(def (neighbours ?g ?r ?c)
  (reduce + 0 (for (dr (range -1 2) dc (range -1 2)
                       :if (not (and (dr == 0) (dc == 0))))
                   (cell g (r + dr) (c + dc)))))

(def grid ((1 0 0) (0 1 0) (0 0 1)))
(neighbours grid 2 2)   # => 2
(neighbours grid 3 3)   # => 1
```

`get` is 1-based on a sequence, so the bounds test is `1 ≤ r ≤ (count g)` and
`1 ≤ c ≤ (count (get g 1))`; the caller passes 1-based coordinates. The centre
of the diagonal grid touches both other `1`s (2 neighbours); the bottom-right
corner touches only the centre (1).

### 25. Mini-Prolog Engine ✓

Unification is written in air itself: terms are ordinary forms held raw by the
rule parameters, variables are wildcards (`?x`), and a substitution is a map from
`:x` to its value.

```air
# ---- Mini-Prolog: unification ------------------------------------------------

(def (deref ?t ?s) hold=(t)
  (if (and (wildcard? t) (haskey s (keyword (name t))))
      (let (v=(get s (keyword (name t))))
        (deref v s))
      t))

(def (bind-var ?v ?t ?s)
  (join s ~(keyword (name v))=t))

(def (term-equal ?a ?b) hold=(a b)
  (if (seq? a)
      (if (seq? b)
          (if (== (count a) (count b))
              (loop (i 1)
                (if (i > (count a))
                    true
                    (let (ai=(get a i) bi=(get b i))
                      (if (term-equal ai bi)
                          (recur (i + 1))
                          false))))
              false)
          false)
      (if (seq? b) false (eq? (unhold a) (unhold b)))))

(def (unify-list ?xs ?ys ?i ?s) hold=(xs ys)
  (if (i > (count xs))
      s
      (let (xi=(get xs i) yi=(get ys i))
        (let (s2=(unify xi yi s))
  (if (eq? s2 :fail)
              :fail
              (unify-list xs ys (i + 1) s2))))))

(def (unify ?a ?b ?s) hold=(a b)
  (let (da=(deref a s) db=(deref b s))
    (if (and (wildcard? da) (wildcard? db) (term-equal da db))
        s
        (if (wildcard? da)
            (bind-var da db s)
            (if (wildcard? db)
                (bind-var db da s)
                (if (and (seq? da) (seq? db))
                    (if (== (count da) (count db))
                        (unify-list da db 1 s)
                        :fail)
                    (if (term-equal da db) s :fail)))))))

# ---- Mini-Prolog: resolution -------------------------------------------------

(def (rename-term ?t ?tag) hold=(t)
  (if (wildcard? t)
      (symbol (str "?" (name t) tag))
      (if (seq? t)
          (map (?e -> (rename-term e tag)) t)
          t)))

(def (push-goals ?q ?b)
  (loop (i (- (count b) 1) acc q)
    (if (i < 2)
        acc
        (recur (i - 1) (push acc (get b i))))))

(def (vars ?t ?acc) hold=(t)
  (if (wildcard? t)
      (if (member? t acc) acc (push acc t))
      (if (seq? t)
          (reduce ((?acc ?e) -> (vars e acc)) acc t)
          acc)))

(def (project ?vset ?s)
  (reduce ((?acc ?v) -> (join acc ~(keyword (name v))=(deref v s)))
          ()
          (drop-first 2 vset)))

(def (sol-count ?ss) (if (symbol? ss) 0 (- (count ss) 1)))
(def (sol-get ?ss ?i) (get ss (i + 1)))
(def (sol-add ?ss ?s) (if (symbol? ss) (sols s) (push ss s)))
(def (sol-merge ?a ?b)
  (loop (i 1 acc a)
    (if (i > (sol-count b))
        acc
        (recur (i + 1) (sol-add acc (sol-get b i))))))

(def (solve-clauses ?i ?acc ?g ?q ?db ?tag ?s ?vset)
  (loop (i i acc acc)
    (if (i > (count db))
        acc
        (let (c=(get db i))
          (let (tag2=(str tag "_" i))
            (let (h0=(get c :head))
              (let (b0=(get c :body))
                (let (h=(rename-term h0 tag2))
                  (let (b=(rename-term b0 tag2))
                    (let (s2=(unify g h s))
                      (recur (i + 1)
                             (if (eq? s2 :fail)
                                 acc
                                 (sol-merge acc (solve-q (push-goals q b) db tag2 s2 vset))))))))))))))

(def (solve-q ?q ?db ?tag ?s ?vset)
  (if (== (count q) 2)
      (sol-add sols (project vset s))
      (let (n=(count q))
        (let (g=(get q n))
  (let (q2=(wout q n))
  (solve-clauses 2 sols g q2 db tag s vset))))))

(def (solve ?goal ?db) hold=(goal)
  (solve-q (goals :done goal) db "" () (vars goal (vs :done))))
```

A database is a `clauses` form of `head=`/`body=` maps; each body starts with
the `goals` marker and ends with a `:done` sentinel, so a one-goal body never
collapses to its goal. The query is a raw term — `solve`'s `hold=goal` parameter
receives it exactly as written, so it is not reduced:

```air
(let (db=(clauses
          (head=(parent :abe :bob) body=(goals :done))
          (head=(parent :bob :carl) body=(goals :done))
          (head=(ancestor ?x ?y) body=(goals (parent ?x ?y) :done))
          (head=(ancestor ?x ?y) body=(goals (parent ?x ?z) (ancestor ?z ?y) :done))))
  (solve (ancestor :abe ?who) db))
# => (sols (who=:bob) (who=:carl))
```

`solve` returns every solution — `(ancestor ?a ?b)` yields all three ancestor
pairs — and the bare symbol `sols` when there are none. Resolution is
depth-first with backtracking driven by iterating the clauses; each clause
invocation is freshened with a tag taken from its recursion path (`symbol`
builds names like `?x_3_2` at runtime), and `term-equal` compares terms
structurally without reducing them, so `(1 + 2)` is data rather than `3`.

What the code exercises: `hold=` on `def` parameters passes a term into a
function unreduced; `~(keyword (name v))=…` is a computed map key; and the
sentinels (`:done`, `sols`, `(vs :done)`)
work around one-element canonicalization. One sharp edge: a bound variable must
not share its name with the *head* of its own value. `(let (db=db) db)` is fine —
replacing `db` by itself is a fixed point and yields `db` — but a non-trivial
value such as `(let (db=(db 1)) db)` re-resolves its head `db` to the value again
until the recursion limit, hence the `clauses` marker above.

---

## Report: What Worked, and Remaining Gaps

**What worked well.** The whole suite now runs: persistent collections with
`with`/`wout`/`join`, `map`/`filter`/`reduce`/`for`, `frequencies`, and
`partition-by` cover Tier 1; operator-anchored rules, guards, `lower`, `loop`/`recur`
and replacement-rule lambdas cover Tier 2; the RETE engine (`logic-set`, `assert`/`retract`/
`revise`, `(rule …)` forms with `:>` consequences and `:accum` grouping,
cascades, transitive closure) covers Tier 3;
`mut`/`set` with STM plus `do`/`except` (and `handle`/`notify`) cover Tier 4, and
`task`/`await` gives
the concurrent counter; `eval`, rewriting, `get`-indexed grids, the infix-aware
interpreter, and the air-level unification/resolution engine cover Tier 5.

**Fixed while doing this.** A core engine bug: user rules matched the *raw* form,
so a scope-bound symbol inside it was not resolved before matching (a rule body's
`(d f x)` matched the wrong rule). The fix is a general **scope protocol** — each
binding form (`let`/`loop`/`for`/a replacement rule) declares its binders, and the reducer
resolves scope bindings before matching while leaving binding positions alone.
Two smaller additions came out of the Prolog engine: `(symbol x)` builds a symbol
from a string at runtime (needed for variable freshening), and `equal?` was
renamed `eq?`.

**Remaining gaps.**
1. **Bignums** — `Int64` leaves overflow (`(fact 500)`); an AirDB `FormLeaf` change.
2. **Search on top of constraint propagation (#15)** — expressible, not written.
3. **Hygiene** — a bound name that also heads its own value expands without end
   (see the note under #25); data is safest with names distinct from variables.
