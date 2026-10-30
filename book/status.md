# Implementation status

`AirLang.jl` currently implements the **inner (reduction) system**.

**Implemented**

* The reader: atoms (symbols, keywords, wildcards, strings, raw strings
  `raw"…"`, regex literals `r"…"` with flags, numbers, booleans,
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
* **Operators** (`+ - * / ^ // mod == != === !== < > <= >=`) are native and
  **infix-canonical**: `(a OP b)` is the canonical form, `(OP a b …)` is sugar,
  and non-numeric operands are left unevaluated (symbolic) — `(1 + 2)` → `3`,
  `(x + y)` → `(x + y)`.
* Special forms `def`, `let`, `if`/`cond`, `do`, `throw`, `notify`,
  `notify-or`, `get`, `match?`, `matches`,
  `mut`, `set!`, `swap!`/`alter!`, `tx`, `sandbox`, `watch`/`unwatch`/`watches`,
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
  reserved; logic-set ACLs (standalone sets use write to mutate and read to
  query; namespace sets use the four fact/rule permissions); `sync`/`status` as a
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
* Printing and layouts: `air_string` is the flat spelling and
  `air_pretty_string(x; width=80)` the greedy line-broken one, with
  `(form->string x pretty=true width=n)` in air; the REPL reads its width from
  `COLUMNS`. `(layout PATTERN head=N indent=M map=inline|block)` declares a
  structural layout for matching forms (user declarations ahead of the defaults
  for `def`, `let`, `val`, `if`, `cond`, `do`, `tx`, `namespace`, `using`,
  `logic`, `rule`, `assert`, and `error`), managed by `(layouts)`,
  `(clear-layout :head|:all)`, and `(reset-layouts)`. A layout is process-global
  and not undone by a transaction or a sandbox.
* Times: a time is the ordinary immutable form `(time SECONDS)` (UTC epoch
  seconds), printed as ISO-8601; `(now)`, `(time x)`, `(time-str t format= offset=)`,
  `time?`, the arithmetic (`time ± number` is a time, `time − time` seconds,
  ordering between two times), `between?`/`before?`/`after?`, and the `lib/time`
  helpers.
* The outer production-rule engine (core): every namespace is implicitly a logic
  set (the hidden named form `air/logic/<path>`, created lazily), and
  `logic-set` makes a standalone named one; `assert`, `retract`, `revise`, and
  `revise-fact` edit facts and rules, saturating the set to a fixed point. Bare
  operations target the current namespace (or the enclosing `logic` block), and
  `query`, `defrule`, and `ingest` round out the namespace-facing forms. A rule is the structured
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
  `(facts s)`/`(rules s)` return one held list — `(' (parent :abe :bob))` for
  one fact, `(')` for none — whose elements are the unheld facts, so a fact
  is ordinary data inside the hold. The
  incremental alpha/beta network is still deferred.
* Extern objects: a host-level value (a promise, a regex) is a
  first-class form leaf, built on AirDB's `FormExtern`/`ExternHandle` and its
  `register_extern` type registry. `(extern :type payload)` reconstructs one from
  the payload its printed form carries, `extern?`/`extern-type` inspect one, and
  an extern prints as `(extern :type payload)`, so it round-trips through source
  (a regex prints as its `r"…"flags` literal instead).
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
* Streams: `(stream maxsize=n)` is a reusable FIFO persisted in the current
  namespace's database (AirDB's `StreamForm`), `(post s v timeout=n)` appends the
  envelope `(obj sender=:user time=(time …))`, and `(fetch s meta=true
  timeout=n)` removes the oldest object or envelope, with a timeout expiry as
  `naught`. `count`, `open?`, `stream?`, and `(close! s)` inspect and close one;
  the stream's `read`/`write` ACL gates receiving and delivering. A stream is
  opaque on a `get` path, compares by identity, prints as `#<stream uuid>`, and
  serializes as the link `"&uuid"`.

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
  infix sum, which reduces to the same value. A complex prints as one atom,
  `4.4+2.0i`, so it re-reads as one value.
* The full AirDB numeric tower is supported — `Int64`, `BigInt`, `Float64`,
  `BigFloat`, `Rational{Int64}`, `Rational{BigInt}`, `ComplexF64`, and
  `Complex{BigFloat}` — with reader literals, an exact printer, widened
  predicates, and AirDB's equivalence. `//` is the exact rational constructor
  and integer division is `div`. See [Numbers](numbers.md).
