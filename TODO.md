# air — language feature TODO

A working list of language features to add before air is "complete". Items marked
★ came from the initial list; the rest are brainstormed candidates, drawn mainly
from Mathematica's core guides (list manipulation, patterns, strings, functional
programming) and Clojure's `clojure.core`.

Already implemented: reader (including the `.` accessor and the `...` splat), the
reduction engine, `def`, `let`, `if`/`cond`, `do`, `get`, `match?`, `matches`,
`mut`, `set!`, the `replace` family, native infix-canonical symbolic operators
(`+ - * / = < >`), predicates (`int? float? string? bool? symbol? keyword?
wildcard? coll? atom? naught?`), collection verbs (`push pop drop length haskey
in merge`), `seqpart`/`mappart`, namespaces (`namespace`, `using`/`use`/`import`,
`clear`/`unuse`/`del`), thread-local `val`/`bind`/`bindings`, `task`/`await`,
roots and homes (`$`, `@`, `.sys`, `.lib`, `.main`, `.env`), users and
permissions (`as-user`, `create-user`, `create-constituent`, `set-admin`,
`users`, `permissions`, `chmod!`, `chown!`, `assume`), `load-air`/`AIR_LIBPATH`
libraries, `open-airdb`/`close-airdb` with per-database namespaces and users,
the data formats (`decode`/`encode` and `read-data`/`write-data` for JSON,
YAML, TOML, and `.env`), the set verbs, the Mathematica-style list verbs
(`transpose`, `riffle`, `tuples`, `subdivide`, `count-distinct`, `gather-by`,
`split-by`, `map-thread`, `outer`, `array`, `trampoline`), bitwise functions
(`bit-and`, `bit-or`, `bit-xor`, `bit-not`, `bit-shift-left`,
`bit-shift-right`), the REPL (multi-line input, `AIR_HISTORY`,
pretty-printing), the SSH server (`ssh-server`: key login, a remote REPL,
SFTP), the immutable `bytes` extern,
`(exit)`, and the CLI.

---

## Immediate follow-ups

- [x] **`get … hold=true` and `held?`** — `(get form sub… hold=true)` returns the
  subpart still held, and `(held? form sub…)` reports whether
  `(get form sub…)` would return a held form. `held?` also accepts no subpaths
  (testing the form itself); a hold is not inherited by its content.
- [x] **Computed keys (`~expr=value`)** — the reader accepts `~expr` before `=`
  (encoded as the symbol `:~<printed expr>`), and the general reducer (plus
  `with` and holds) evaluates it. The expression must yield a keyword:
  `(form ~(keyword (name ?x))=10)` → `(form x=10)`.
- [x] **`def`/`val` bodies are blocks** — a `def` body accepts the `do` grammar
  (`let=`, level-1 `:let`, `catch=`/`throw`, `except`, `handle`, `finally`), and
  `tx=true` makes it a `tx` rather than a `do`. The body is wrapped in a
  `(do …)`/`(tx …)` only when it needs one, so a plain one-form definition is
  stored as written and `definitions` round-trips. `val` takes the same options,
  is evaluated once, and rejects `memoize=`.
- [x] **`memoize=` on a `def`** — `true`/`:weak` keeps results in `WeakRef`s;
  `(:lru max)` holds up to `max` strongly and evicts by last use. The key is the
  rule's evaluated parameter bindings under `eq?` equivalence (so `(f (+ 1 1))`
  and `(f 2)` share an entry while `1` and `1.0` do not). The mode is stored in
  the namespace entry and reproduced by `definitions`; the cache is
  process-local, survives a namespace rebuild, and is fresh on redefinition.
- [x] **Equivalence and hashing** — `eq?` is equivalence (type-sensitive scalars,
  map-order-free containers, identity for mutables/actors/promises, type and
  serialization for delays, `isequal` for externs), `==` stays content equality,
  and `(hash x)` follows `eq?` without ever descending into a mutable.
- [x] **Delays, actors, and promises** — AirDB's reference forms are exposed to
  air. `(delay body…)` captures its body and context, forces at most once on a
  `get` (or a `get` path), and stores the result in a database cell that any
  later environment reads instead of recomputing; `(actor value history=…)` with
  `send`/`reset!`/`sync` persists every value; `(promise)` is a single-assignment
  value that encodes as a link until delivered and as its value afterwards.
  `get`/`value` force a delay and read an actor or promise, printing and encoding
  never force one, and the three are `un-storable` across databases. `task`
  returns a database promise whose running task is process-local.
- [x] **SSH access.** `(ssh-server [name] opts…)` starts a server admits the
  users its owner may assume (`air`: everyone, an admin: itself and its
  constituents); a user logs in with a key from their own `$.config.ssh` and
  lands in their home namespace at a line-editing REPL. `(ssh-servers)`,
  `(ssh-host-key …)`, and `(ssh-close! …)` manage the keyed servers; host keys
  live in `.sys.ssh.<key>`, not on disk. SFTP v3 serves the same paths —
  a directory is a namespace and a file is an immutable `bytes` val. See
  `book/ssh.md`.
- [x] **Abstract user interfaces.** `(ui …)` is a reserved, inert head; a tree
  of them describes the full widget catalog (boolean, text, numeric, selection,
  action, display, and layout kinds). `ui-open` instantiates a named,
  owner-scoped instance, evaluating parameters and capturing the namespace and
  `val` bindings; `on-change` runs callbacks and `assert` maintains a
  per-element-labeled fact in that captured namespace. `ui-values`, `ui-value`,
  `ui-set!`, `ui-update!`, `ui-dismiss!`, `ui-close!`, `ui-instances`, and
  `ui-run` drive it, `ui-render` is a deterministic text renderer, and
  `ui-show` is a full-screen terminal renderer over SSH (alternate screen,
  focus, validation line, Esc to dismiss, Ctrl-C to abort). See `book/ui.md`.
- [ ] **More UI renderers.** A local `stty`-driven terminal renderer (v1 needs a
  pty SSH session) and a web renderer would exercise the abstract layer; both
  implement the same attach/draw/event contract.
- [ ] **Incremental UI updates.** `ui-update!` re-instantiates the whole tree;
  an incremental subtree update would avoid rebuilding and re-evaluating every
  parameter for a dashboard-style redraw.
- [ ] **Non-modal UIs.** `ui-show` owns the session until dismissal; a
  dashboard that yields to the REPL needs a different run loop.
- [ ] **Incremental SFTP uploads.** A written file is buffered whole and
  committed as one `bytes` val at `CLOSE`, because `bytes` is immutable. A
  mutable upload buffer (or a streaming `bytes` builder) would make large
  transfers not require memory proportional to the file.
- [ ] **Non-interactive exec over SSH.** `ssh host command` opens a channel
  request air does not serve, so only the REPL and the SFTP subsystem are
  available; legacy `scp` (`scp -O`) depends on exec and therefore fails.
- [ ] **Preemptible evaluation.** `Ctrl-C` in a session evaluates
  `(raise :ctrl-c)`, but air evaluation is not preemptible, so a byte sent while
  a form runs is read only when that form finishes.
- [x] **Data formats** — `decode`/`encode` (with `format=`) and
  `read-data`/`write-data` (with extension inference) convert JSON, YAML, TOML,
  CSV, TSV, and `.env` to and from plain air data: an object becomes a map form,
  an array a sequence form, and null or an empty container `naught`. Decoding is
  safe by construction — the YAML reader covers a practical subset and
  constructs no tags, so nothing in a file executes — and TOML dates, times, and
  datetimes become the marker forms `(toml-date …)`, `(toml-time …)`, and
  `(toml-datetime …)`. Emitters sort map keys, and `write-data` defers to the
  transaction commit like `write-file`. The path helpers require the grantable
  `filesystem` permission on `.air.sys`: no policy grants it, so a fresh
  instance admits only `air`, and `air` may grant another user with
  `(chmod! .air.sys filesystem=(…))`. See `book/formats.md`.
- [x] **Tables, CSV, and TSV.** An immutable `AirTable` extern — column-major
  persistent columns, ordered names, per-column type and in-band NA metadata,
  and an optional unique index — with `table`, `get`/`with`/`push`/`pop`/`drop`/
  `wout`, row-map iteration, and `table?`/`columns`/`schema`/`nrows`/
  `table-index`. CSV and TSV decode to a table and encode from one, with
  header inference, arbitrary column and row delimiters, `types=`, `na=`,
  `columns=`, and `index=`. See `book/tables.md`.
- [ ] **Save tables as SQL tables.** The requested next step: map a table onto a
  real database table (schema from the column metadata, NA from the declared
  marker, the index as a unique key), with a table loaded from and written to
  AirDB/PostgreSQL. This needs an AirDB-side facility for named tabular storage.
- [ ] **Spreadsheets.** An `.xlsx`/`.ods` reader and writer on top of the table
  type (CSV and TSV are done).
- [ ] **Streaming CSV.** The parser holds the whole text and every record; a
  streaming reader would bound memory for a file too large to hold, at the cost
  of giving up the single-table result.
- [ ] **Integer index keys.** An integer key always names a row position, so an
  index column of integers cannot be addressed by a bare key; a key form
  (e.g. `(index 5)`) would make it addressable.
- [ ] **`with` map entries on ordinary forms.** A map entry on `with` names a
  table column; on a non-table it is still ignored as it always was. Either
  extend it to ordinary forms (`(with (a=1) b=2)` → `(a=1 b=2)`) or reject it
  loudly rather than dropping it.
- [ ] **More data formats.** XML, INI, and a streaming tokenizer for documents
  too large to hold in memory.

---

## Fundamental changes to canonicalization and holding (in progress)

- [x] **`hold=` means "insert exactly as matched", not "hold".** A rule with a
  held parameter matches the **raw** call (before scope resolution) and binds the
  parameter to the matched form **unheld**; a non-held parameter is reduced at
  binding time. The body is then reduced normally, so the raw match is visible to
  the immediately enclosing form's rules and is otherwise evaluated in due course.
  - `(def (f ?x ?y) hold=x (g x y))`:
    `(f (1 + 1) (2 + 2))` → `(g (1 + 1) 4)` (`(g 2 4)` if no `g` rule fires);
    `(let (x=5 y=6) (f x y))` → `(g 5 6)` (the `let` substitutes before the
    match, so the raw match is `5`).
  - A match that is the bare symbol itself is not bound, so the symbol resolves
    through the caller's scope instead of becoming a self-binding.
  - A quoted occurrence `'x` in the body receives the *held* match: with
    `(def (f ?x ?y) hold=x (let (u=x v='x) (' ~u ~v)))`,
    `(f (1 + 1) (2 + 2))` → `(' 2 (' (1 + 1)))`.
  - Rules without `hold=` still match the resolved form, after infix/prefix
    operator reduction, as before.
- [x] **Holding is structural; there is no held flag.** `AirDB`'s `Form` has no
  held bit; a hold is a container whose first element is the ordinary symbol
  `'`: `(' a b c)`. A literal hold holds each element as written, so `(' a b c)`
  holds three elements while `(' (a b c))` holds one container. `'x` is reader
  sugar for `(' x)` **only for a scalar**, so `'5` prints `'5`; the container
  spelling `'(…)` is a parse error. A hold of one scalar prints with the quote,
  any other hold prints literally (`(' a b c)`). `(hold e…)` is the reserved
  alias that reduces to `(' e…)`; `hold` cannot be user-defined. `~e` is sugar
  for `(preval e)`, a reserved special form that evaluates `e` eagerly wherever
  it appears; a hold fills its `preval` holes recursively at every depth (each
  nested hold fills its own), so `(hold (a ~(1 + 2)))` reduces to `(' (a 3))`.
  The hold-blind accessors see the raw form — `(first (' a b c))` is `'`,
  `(count (' a b c))` is 4. An integer key indexes a form as written, so a
  hold's content starts at index 2 (`(get (' f a b) 2)` is `f`); `hold=true`
  makes the root hold transparent, walks the path over the content without
  reducing intermediate values, and holds the result, and `with … hold=true`
  replaces a subpart with a value inserted without its own hold. `(unhold x)`
  drops the head and evaluates the content. Every collection operation has a
  `hold-` version (`hold-get`, `hold-with`, `hold-join`, …) that treats the
  root hold as transparent and returns the result held. Matching compares the
  wrapped forms structurally, and the logic-set stores facts and rules held.
- [x] **A one-element form is never collapsed.** `canonicalize` rewrites only
  the empty form to `naught`; `()` and `naught` are the same singleton at every
  depth, but `(x)` is an ordinary one-element form that reduces only when a
  `def` (or builtin) matches it. `((a b))` is inert unless a rule such as
  `(def ((a ?x)) (x + 10))` matches it; a zero-argument lambda call matches its
  pattern against `naught` and a one-argument call passes the argument itself.
  The reader, `_store_form`, namespace payloads, JSON ingress, and pattern rest
  captures normalize an empty child to `naught`, so no empty container survives
  in a value. `where` returns bare keys by default and one path per occurrence
  when a depth is given; `where-all` is replaced by `depth=:all`.

## Project: redefine the rule syntax (done)

Settled decisions (implemented):

- [x] **`->` for replacement rules only.** `(condition -> replacement)` is inert
  data for the `replace` family, with an optional `unhold=true`; it is not a
  RETE rule. The outer engine uses the structured
  `(rule conditions… instructions…)` DSL: conditions are an implicit
  conjunction, and the instructions are `:if`, `:let`, `:>` (consequence slots),
  and the trigger side effects `:+`, `:-`, `:=`. `-!` and `-_` are gone, as is
  the keyword `(rule condition=…)` form.
- [x] **Empty-body `def` declares a rule that stays unreduced.** `(def (f ?x))`
  reduces `(f (5 + 5))` to `(f 10)` (arguments reduce, form does not); with
  `hold=x` it reduces to `(f (5 + 5))`. (`definitions` omits the synthesized body
  and restores `hold=`.) Separately, the reducer treats a `->` form and a
  `(rule …)` form as **data**: it returns them unchanged, so their conditions
  and instructions stay unevaluated until the `replace` family or the logic
  engine reads them.
- [x] **Pipelines and threading.** `->` is replacement-rule data, so the old
  Clojure threading is gone: `(x >> step …)` is a pipeline that substitutes the
  running value for `_` in each raw step and reduces only the final form, and
  `thread` is Mathematica-style over a container's sequential elements
  (`(thread (f (1 2 3)))` → `((f 1) (f 2) (f 3))`).
- [x] **Conditions are an implicit conjunction.** Conditions are the leading
  forms of `(rule …)`; `(not p)` negates and `:accum` applies to the whole
  conjunction.
- [x] **Eager `assert`/`retract`.** `(assert s (make-fact …))` evaluates its fact;
  a user protects a fact form with their own `(def (parent ?x ?y) hold=(x y))`.
- [x] **Double updates are structurally impossible.** Each `:>` consequence has
  a fixed slot and facts carry stable identities, so a revised premise is a
  revision event, not a retract/assert pair, and a wildcard value occurring in
  several positions no longer rewrites twice.
- [x] **Only base facts are revisable.** `revise`/`revise-fact` reject derived
  facts; a derived fact changes only through the `:>` slot that produced it.

---

## Error handling

Spec: `errors.md`. A pattern-matched, structural error system that replaces
class-based exception hierarchies.

- [x] `(error :tag details…)` is an inert error **object**: the `error` head never
  reduces, so its arguments stay raw at any depth. The type is conventional and
  optional; air never inspects it.
- [x] `(raise :tag data…)` evaluates its arguments and throws
  `(error :tag data…)`; `(raise)` raises `(error)`. With exactly one positional
  argument and no options, an argument that is already an `(error …)` object is
  thrown exactly (only `raise` evaluates; the object does not).
- [x] `(do options… body… (except pattern body…)… (handle pattern body…)…
  (finally body…))` is the single block form (`try` is removed; only a tombstone
  remains). On error, each `except` pattern is matched against the error's
  **content** (the object without its `error` head, keeping its map) in order;
  the first match handles it. A bare wildcard pattern binds the whole object. An
  empty `except` body consumes the error and yields `naught`; no match escapes.
- [x] Block options: `let=` wraps the block in one lexical scope (visible in the
  body, clause bodies, handlers, and `finally`, outermost); a level-1 `:let`
  marker consumes the next body form as a nested textual `let` (invisible to the
  clauses; a trailing marker is inert). Marker expansion runs in the
  binder-aware passes (`_resolve`, `_subst_params`, `_subst`), and clause
  patterns are data whose wildcards shadow outer bindings.
- [x] `catch=true`/`catch=:tag`/`catch=(tags…)` with held literal tags (or a
  `~expr` scalar) and `(throw value)`, `(throw tag value)`, `(throw)`; the
  innermost matching catch scope wins; a throw from `except` is caught by the
  same block, one from `finally` is not; an unmatched throw is
  `(error :uncaught-throw tag value)` from the throw form.
- [x] `(signal :tag data…)` is inert like `error`; `(notify …)` dispatches it to
  the innermost matching `handle` clause (content-matched, first match wins,
  active through `finally`), taking the handler's value and continuing;
  `(notify-or default …)` holds and lazily evaluates `default`; no handler
  raises `(error :unhandled-signal signal)`. Catch and handler scopes are
  task-local and do not cross `task`.
- [x] `tx` accepts the same grammar and runs it in one transaction: an internal
  catch or `except` commits, an escaping error aborts, and a throw caught
  outside is deferred until after the commit (watches included).
- [x] `(sandbox body…)` runs that grammar in a transaction that is deliberately
  aborted: it yields the body's value and keeps none of its writes (`def`,
  `val`, `mut`, facts, rules, named forms, namespaces). Air's `tx` joins rather
  than nests, so the body runs in its own transaction on a private task; it
  reads committed state (not an enclosing transaction's staged writes), and
  non-database side effects escape. `throw` and `notify` still reach the
  caller's `catch=` and `handle`.
- [x] `reraise` is a reserved bare symbol: when it is the final value of an
  `except` body, the original error resumes through the remaining clauses (side
  effects kept) and escapes if unhandled. It cannot be bound by `let`, `def`, or
  a pattern.
- [x] `finally` always runs (normal completion, handled error, `reraise`, escape);
  its value is discarded, it must be last, there is at most one, and an error it
  raises replaces the result or in-flight error.
- [x] Error chains: a `raise` inside an `except`/`finally` with an error in flight
  records it as `from=` (automatic context, Python's `__context__`); an explicit
  `from=` overrides, `from=naught` suppresses, and `cause=` is explicit only.
  `showerror` prints `direct cause:` / `during handling of:` recursively.
- [x] Transactional integration: an error escaping a transaction aborts/rolls it
  back (even if an outer block catches it); an error caught inside it commits; a
  throw escaping to an outer catch commits first and is rethrown after.
- [x] Internal errors surface to `except` as `(error :internal <message>)`; air
  conditions use their own heads (`:permission-denied`, `:extern-expired`, …).
- [x] Requires rest patterns (`?*`, `??`, `?&`) and conditions in `except`
  patterns.
- [x] The hold-lifting operation formerly named `raise` is now `(lift form)`, so
  `raise` unambiguously raises an error; `lift` remains the inverse of `lower`.

## 0. Design decisions to settle first

- [x] **Reserve `.`** — dropped from the symbol character set; now the subform
  accessor (`form.key` → `(get form :key)`, `f.a.b` → `(get f :a :b)` → nested),
  the namespace root and path prefix (`.` alone, `.util.a` →
  `(get . :util :a)`), and the splat (`form...`). Done.
- [x] **Replace `(form key)` querying.** Canonical extraction is
  `(get form k1 k2 …)`; `form.k1.k2` is sugar. Non-literal keys work, and `get`
  is overridable by a user rule. Done.
- [x] **`replace` rule syntax.** A rule is `(pattern -> replacement)`, optionally
  with a `:guard` inside the condition. `replace` takes the subject plus N
  rules, first match wins. Done.
- [x] **`i` vs. a symbol.** Bare `i` is the imaginary base (`0 + 1i`); a user may
  still rebind it or shadow it with a `let` binding, so it is not a reserved
  name.
- [x] **Numeric tower.** AirDB's `FormLeaf` now carries `BigInt`, `BigFloat`,
  `Rational{Int64}`, `Rational{BigInt}`, and `Complex{BigFloat}`. Air reads and
  prints every leaf exactly, keeps `//` as the exact rational constructor
  (integer division moved to `div`), and adopts AirDB's `isequiv`/`equivhash`.
  See `book/numbers.md`.
- [x] **Recursion depth.** A call in tail position — the selected `if`/`cond`
  branch, the last form of a `let` body, the last form of a `do` with no
  `catch=`/`except`/`handle`/`finally` (including `:let`/`let=`), a
  `when`/`unless` body, the last `and`/`or` operand, a rule body, or an applied
  lambda body — is reduced
  iteratively by the trampoline in `air_reduce`, so a tail-recursive rule runs
  in constant stack and is bounded only by `max_steps` (raised to 1,000,000).
  Nested (non-tail) recursion is still bounded by `max_depth` (2,000).

## 1. Reader / parser

- [x] ★ Splat `...`: `form...` splices a form into its surrounding form.
- [x] ★ `.` accessor: `form.key` (no parens) → `(get form :key)`, with held keys
  and `~` to evaluate one (`f.~k`); also `(test=10).:test`. A leading `.` is a
  namespace path (`.air`, `.util.a`), and a spaced `.` is a literal symbol.
- [x] ★ Remove `.` from symbol characters (parser + README).
- [x] Held forms `(' …)` (scalar sugar `'x`) and the eager hole `~`
  (`(preval e)`); `(unhold x)` as the runtime operation, `lower`, and `lift`
  (the inverse of `lower`; `raise` is the error special form).
- [x] Conditions `\` (attached to the pattern form before them; must return `true`).
- [x] Rest/sequence patterns `??`, `?&rest`, `?*kwargs`.
- [x] Optional keyword patterns `?k=default`.
- [x] `hold=(x y)` / `hold=x` in `def` and in a replacement-rule lambda.
- [x] String escapes (Julia's rules) and raw strings `raw"…"` / `raw"""…"""`;
  `~` interpolation for `string-format`.
- [x] Block comments `#| … |#` (nestable; may span lines or sit inside a form).
- [x] Regex literals — `r"…"` is a raw string compiled at read time into the
  same value `(regex "…" ["flags"])` builds; the letters `i m s x a` immediately
  after the closing quote are flags, and a regex prints as the literal again.

## 2. Evaluation & rules

- [x] ★ `replace` — subject + N rules; first matching rule wins; whole-form match.
- [x] ★ `replace-all` — walk the form and replace every matching subpart, deepest first.
- [x] ★ `rreplace` — `replace` to a fixed point.
- [x] ★ `rreplace-all` — `replace-all` to a fixed point.
- [x] `Cases` / `Select` over a collection (Mathematica). The `case`/`select`
  dispatch forms are done (see §7), as are `cases` / `drop-cases` (§5) and the
  whole-tree query `matches-any?` (§17).
- [x] Extend `match?` / `matches` / `def` / `replace` / `except` to conditions and
  rest patterns (optional keys still deferred).
- [x] Anonymous functions / lambdas — a replacement rule in head position
  (`(((?x ?y) -> body) a b)`); there is no `fn` form.
- [x] Pattern alternatives — `(alt p q …)`, written with `|` between adjacent
  sequence elements: `(a |b)` reads as `(alt a b)` and a run flattens to
  `(alt a b c)`. The matcher tries branches in order and the first match wins;
  `alt` is not an anchor (the branches' raw symbols are).
- [ ] Pattern tests (`?pred`) — needs a definition.
- [x] Head-restricted blanks — not supported in air; a condition (`\ pred`) is
  the mechanism.
- [x] Rule attributes (`orderless`, `flat`, …) — not supported in air. Keyword
  matching is already orderless, and `flat` has no defined semantics.
- [ ] Local rule scopes (`with`-style).
- [x] `->` replacement rules and the `(rule conditions… instructions…)` DSL.

## 3. Operators & math

- [x] Operators are native and **infix-canonical** (`(a OP b)`), with prefix
  sugar, and **symbolic** on non-numeric operands. Done for
  `+ - * / ^ // mod = != < > <= >=`.
- [x] ★ `^` power/exponent.
- [x] ★ `mod` (modulo).
- [x] ★ `//` exact rational constructor (`(7 // 2)` is `7//2`); `div` is the
  integer division verb.
- [x] `<=`, `>=`, `!=`; variadic chains for every comparison.
- [x] `and`, `or`, `not`, `xor` (short-circuiting where needed).
- [x] `abs`, `sign`, `min`, `max`, `floor`, `ceil`, `round`, `truncate`.
- [x] `sqrt`, `exp`, `log`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`.
- [x] `gcd`, `lcm`, `factorial`, `binomial`.
- [x] Constants: `pi`, `e`, `tau`, `inf`, `nan`.
- [x] Bitwise ops — named functions, since `|` is the pattern-alternative
  operator and cannot be an infix operator: `bit-and`, `bit-or`, `bit-xor`, `bit-not`,
  `bit-shift-left`, `bit-shift-right`. They are symbolic on non-integers, like
  the arithmetic verbs, and a boolean counts as an integer (Julia's `Bool`).
- [x] Numeric predicates: `number?`, `integer?`, `even?`, `odd?`, `zero?`, `positive?`, `negative?`, `nan?`, `infinite?`.

## 4. Predicates

★ from your list: `not`, `int?`, `float?`, `string?`, `symbol?`, `keyword?`,
`wildcard?`, `form?`, `mut?`, `imm?`, `bool?`, `true?`, `false?`, `empty?`
(= is `naught`), `complex?`, `even?`, `odd?`, `positive?`, `negative?`.

- [x] Type: `number?`, `integer?`, `zero?`, `nan?`, `infinite?`, `seq?`, `map?`,
  `mut?`/`imm?`, `true?`/`false?`, `empty?`, `complex?`, `even?`/`odd?`,
  `positive?`/`negative?`.
- [x] Identity/structure: `same?` (identity), `eq?` (equivalence: a scalar by
  value *and* type, a container elementwise with map order ignored, a mutable or
  extern by identity).
- [x] Membership: `contains?`, `member?`.
- [x] Quantifiers: `all?`, `any?`, `none?` over a collection.
- [x] Text: `starts-with?`, `ends-with?`.
- [x] Emptiness: `blank?`, `present?`.
- [x] `associative?`, `counted?`.
- [x] `matches?` — not needed; `match?` (boolean) and `matches` (bindings) are
  the pattern verbs, and the string verb is `string-match?`.

## 5. Collections & sequences

- [x] Access: `first`, `last`, `rest`, `nth`, `take`, `drop-first`, `take-last`,
  `drop-last`, `take-while`, `drop-while`, `split-at`.
- [x] `drop` keeps key-removal; `drop-first` drops the first *n*.
- [x] Higher-order: `map` (seq + map values), `filter`, `remove`, `reduce`/`fold`,
  `mapcat`, `each`.
- [x] Combining: `join`, `join-in`, `with`, `wout`, `push`, `push-in` (the
  `with-in`/`wout-in` pair is gone), each with a `hold-` variant.
- [x] Ordering: `sort`, `sort-by`, `reverse`, `distinct` (all duplicates),
  `dedupe` (consecutive only), `partition`, `group-by`, `frequencies`.
- [x] Generation: `range`, `repeat`.
- [x] Aggregation: `count`, `sum`, `product`, `min`, `max`.
- [x] Maps: `update`, `keys`, `vals`, `zipmap`, `invert`.
- [x] Sets: `union`, `intersect`, `difference`.
- [x] `apply`.
- [x] `prepend`, `interleave`, `zip`, `flatten`, `mean`/`median`,
  `comp`/`juxt`/`complement`/`part` (partial application; there is no
  separate `partial` verb).
- [x] `shuffle`, `variance` (sample, `n - 1`), `subset?`/`superset?`.
  `iterate` is not a separate verb: the eager `nest-list` **is** bounded
  `iterate`. `cycle` (unbounded) stays out while air is eager.
- [x] Repetition: `nest`, `nest-list`, and `nest-while` (with `list=true` for
  the sequence of values). `fixed-point` is not needed — `(rreplace x (?y ->
  (f y)))` already repeats a step to a fixed point.
- [x] `cases` / `drop-cases` — Mathematica-style pattern selection over a
  collection (`drop-cases`, not `delete-cases`). Both take `depth=` (default
  `1`, the collection's elements); `select` remains the `case` alias. A clause
  is a bare pattern (keep the element) or a replacement rule (replace it); a
  rule-level `\` guard on a bare pattern tests the whole element. There is no
  default clause.
- [x] **Level-aware traversal (`depth=`)** — `replace`, `rreplace`, `map`, and
  the collection selectors accept `depth=n`: `0` is the subject itself, `n > 0`
  is every node at depth `n` (sequential elements *and* map values count as
  children), with the structure above the selected level reassembled. A scalar
  is its own sole element; an extern is opaque. `replace`/`rreplace` default to
  `0`; `map` and `cases`/`drop-cases` default to `1`. `replace-all` /
  `rreplace-all` keep their whole-tree walk when `depth` is absent and operate
  only on level `n` when it is given.
- [x] Set operations treat `naught` as the empty set (`(union () (1 2))` is
  `(1 2)`), matching `subset?`/`superset?` and the runtime `()` → `naught`
  canonicalization.
- [x] **Transposition and products** — `transpose` (columns, stopping at the
  shortest row; a scalar row is a singleton), `tuples` (the Cartesian product
  of a list of collections, or `(tuples coll n)` for the n-fold power),
  `riffle` (insert a separator, cycling a separator collection), and `outer`
  (the nested product of function values).
- [x] **Numeric and grouping verbs** — `subdivide` (`n + 1` evenly spaced points
  between optional bounds), `count-distinct`, `gather-by` (all equal keys, in
  first-occurrence order; `group-by` keeps a map), `split-by` (an alias of
  `partition-by`), `map-thread` (zip-with a function), `array`
  (`(f start) … (f start + n - 1)`), and `trampoline` (bounce while the result
  is a function).

## 6. Strings

★ from your list: `string-length`, `string-join`, `substring`, `string-replace`,
`string-format` (`~var` insertion, `~~` for a literal tilde).

- [x] `string-split`, `string-upper`/`upcase`, `string-lower`/`downcase`,
  `string-trim`, `string-starts-with?`, `string-ends-with?`, `string-contains?`,
  `string-index-of`, `string-repeat`, `string-pad-left`/`string-pad-right`,
  `string-append`, `string-chars`, `string-lines`, `form->string`, `string->form`.
- [x] `string-take`/`string-drop`, `string-capitalize`, `string-trim-left`/`right`.
- [x] `string-reverse`.
- [x] Regex: `(regex "pattern" [flags])` values (`regex?`; printed as
  `(extern :regex (…))`, round-trips through source), `string-match?`,
  `string-find` / `string-find-all` returning `(match=… index=… groups=…)`, and
  regex support in `string-split` / `string-replace` / `string-index-of` /
  `string-contains?`, with `$0`/`$1`/`$name`/`$$` replacement syntax. A string
  pattern stays literal.

## 7. Control flow & functions

- [x] `when`, `unless`, `and`/`or`/`not`/`xor`.
- [x] Lambdas are replacement rules in head position — `((?x -> (x + 1)) 2)`;
  there is no separate `fn` form. Free names in the replacement resolve at
  application time in the caller's scope (no lexical capture), and `_` is a hold
  of all arguments (the whole subject, unheld, inside `replace`/`case`).
- [x] `for` comprehensions with `:if` and `:let`.
- [x] `apply`; `each`.
- [x] `case`/`select` — pattern dispatch on one subject, first match wins, a
  trailing non-rule default (`naught` when absent).
- [x] Pipelines `(x >> step …)` with the `_` placeholder, and Mathematica-style
  `thread` / `hold-thread` (`->` is replacement-rule data, so Clojure
  `->`/`->>` threading is gone).
- [x] Composition: `comp`, `complement`, `constantly`, `identity`, `juxt`, and
  `part` (partial application; `partial` is not a separate verb).
- [x] Recursion: `loop`/`recur` (tail calls); `while`.
- [x] General tail calls: any self-recursive rule whose call is in tail position
  runs in constant stack (the reducer loops on a pending tail step); non-tail
  recursion remains depth-bounded.
- [x] `doseq` (nested over collections) and `dotimes` — run a body for its
  effect and return `naught`.
- [x] `assert` — reserved for logic-sets (§16).

## 8. Mutables & STM

- [x] `mut?`, `imm?` (see §4).
- [x] `set!` (including the `set! form path… value` traversal), `swap!`/`alter`.
  Volatile edits end in `!`; `mut` creates rather than edits.
- [x] `(value m)`, `(get m)`, and `(get m 0)` all read a mutable's value.
- [x] Filters and finalizers: `mut filter=… finalize=…`, `set-filter!`,
  `set-finalize!`. They are kept as written in the mutable's metadata (a
  replacement rule is applied as a function; any other form is evaluated with
  `_` bound to the value), so they survive a reload. A finalizer runs after the
  transaction body, before the commit attempt, where mutables cannot be written.
- [x] Watches: `watch`, `unwatch`, `watches`. A watch is `(fn key m old new)`,
  runs as its registrar in the namespace where it was registered, and fires at
  the end of the outermost transaction body — pre-commit, once per mutable per
  transaction — so its writes are transactional. Persisted in metadata; a new
  `watch` permission (owner-only) gates installation.
- [x] `reset!` — replaces an actor's value without applying a function.
- [x] `(tx body…)` — evaluate a full `do` block in one STM transaction and yield
  its value. Transactions join rather than nest, so the outermost `tx` is the
  commit/rollback boundary; an error that escapes it aborts its writes, an error
  caught inside it commits, and a throw escaping to an outer catch commits first
  (after running watches) and is rethrown.
- [x] Mutables inside patterns and `replace` — a mutable (volatile), actor, or
  promise is an opaque atom to the matcher: it matches only itself
  (`isequal` on the AirDB id), never by its value, and no pattern walk descends
  into a mutable's value. A wildcard may still bind one, and `(get m)` is the
  explicit way to inspect it. Covered in `test/pattern.jl`.
- [x] Deref sugar (`@form`?) — settled (2026-10-29): not wanted. `get` already
  dereferences a mutable, actor, promise, or delay, and `@` is the attached
  database root, so a deref operator would add a third spelling for an
  operation that already reads well.

## 9. Persistence & AirDB integration

- [x] **Database sessions.** `(open-airdb name opts…)` opens or creates an AirDB
  database (in-memory, `url=`, or `dbname=`/`user=`/…), roots `name` in it, and
  attaches `@`; namespaces at or under the root live there, with per-database
  users and ACL principals and a storable-form check. `(close-airdb name)`
  flushes, closes, removes the root namespace, and detaches `@`.
- [x] **One database per namespace.** `mut`, logic sets, named forms, `form-at`,
  and `from-json` use the database of the namespace they are written in
  (`Env(db=…)` selects only the process store behind `.`/`.main`/system homes).
- [x] **`named-form`, `name-form!`, `named-forms`.** Names are per database and
  normalized to their text (`:x` and `"x"` agree); `air/` is reserved;
  `create=`/`value=`/`history=` select creation, aliasing, and history; creating
  needs write in the current namespace and lookup needs read.
- [x] **Logic-set permissions.** Mutating a set needs write, querying it needs
  read, and opening it by name needs read; each set is a named volatile with its
  own ACL.
- [x] **`sync`, `status` as air builtins** (`close` is covered by
  `close-airdb`). `sync` is a FIFO barrier; inside an open transaction it flushes
  what is already scheduled and cannot cover that transaction's writes.
- [x] **Links between forms; lazy-loading semantics.** A volatile embeds as a
  link; `form-at` returns an unloaded handle (`loaded?`); a missing id raises
  `(error :form-not-found id)` on read; printing is cycle-safe (`#<volatile …>`).
- [x] **`to-json` / `from-json`.** AirDB's codec, resolved through the current
  database, including `"@uuid"` links and extern references.
- [x] **Non-finite floats in AirDB's JSON codec.** AirDB writes `Inf`, `-Inf`,
  and `NaN` as the marked strings `"#inf"`, `"#-inf"`, and `"#nan"`, which are
  valid JSON and cannot collide with a string, symbol, or link marker; complex
  components use the same encoding. The `.air` constants are stored as values.
- [x] **Serializable promises.** `(promise)` is a single-assignment database
  value that always serializes as the link `"~uuid"` (pending or delivered), so
  a reader waits on the same promise and a delivery survives the round trip.
- [ ] **Storing a `task` in the database.** `(task body…)` returns a database
  `PromiseForm`, so the promise itself serializes (`"~uuid"` until delivered).
  The running task, however, is a process item: its held body and context are
  not stored, so a task in flight when the process stops never delivers, and a
  promise that is saved but never delivered is simply lost for now. If
  respawning is wanted, the database could store the body and context and re-run
  it on load; the open question is *when* — immediately on load, lazily on the
  first `await`, or never. No decision and no implementation yet.

## 10. Julia interop (`extern`)

- [x] **Adapt to AirDB's new extern type system.** `FormExtern{T}` now wraps an
  `ExternHandle{T}`, registered with `register_extern(name, T; read_only,
  read_edit, constructors, immutable, serialize, deserialize)`. AirLang's types
  are unnamed externs built with `to_form`; `AirRegex` is interned (weakly) so
  equal patterns are still `eq?`/`same?`, while promises keep identity
  semantics. Registration declares no operations, so the setters are
  not yet reachable through AirDB's `reserve`/`call` API.
  - **Known limitation:** an unnamed extern is not storable, so a form persisted
    with a regex/promise reads back as a dead extern (`(error :extern-expired :type)`
    when touched). Making regexes true DB resources would need an id and a
    `serialize`/`deserialize` pair; decide whether that is wanted.
- [ ] `(extern Name …)` wrapping a Julia type or function: constructors, accessors, method calls.
- [ ] Conversion between forms and Julia values.
- [ ] A small pre-wrapped stdlib (math, strings, regex).

## 11. Errors & diagnostics

- [x] `do`/`tx` blocks and error values — `(error :tag details…)` is an inert
  constant; `(raise :tag data…)` throws it (with `reraise`, `finally`,
  automatic `from`, explicit `cause`, and chain printing); `except`, scoped
  `catch=`/`throw`, `handle`/`signal`/`notify`/`notify-or`, `:let`/`let=`, and
  `finally` all live on the block. `try` is a tombstone.
- [x] **Source positions.** The reader records container spans; a loader installs
  them task-locally while evaluating, so an uncaught error carries
  `(name=… line=… col=… text=…)` frames (innermost first) and prints
  `(at name:line:col)` plus the source line. A loaded `def`/`val` stores its
  definition site as `src=` in the entry body; the innermost executing
  definition wins. Positions are best-effort and never change the error object
  an `except` matches.
- [x] **Reduction stack traces / `trace`.** `(trace body…)` yields the body's
  value or the final data form `(:trace (error …) frames=(…))`.

## 12. Namespaces & modules

- [x] **Namespaces.** `.` is the global namespace root and `.air` the core
  namespace; a leading-dot atom is a path (`.util.a` reads as
  `(get . :util :a)`), so the tree is ordinary `.` access over nested namespace
  volatiles (layered so updates are transactional). `(namespace path body…)`
  appends its `def`/`val` forms as one transaction, creates subnamespaces
  automatically, matches later definitions first, and forbids shadowing between
  a definition and a subnamespace. `(using spec… body…)` activates namespaces
  (a spec may carry `only=`, `except=`, `as=`); inside a namespace block,
  `(use …)` is private and `(import …)` re-exports. `(clear sym)` removes the
  matching definitions (`del` is an alias); builtin air definitions are never
  removable.
- [x] **Materialized imports.** `use`/`import` store entries in the target
  namespace rather than recording a dependency: a readable `def` is copied (owned
  by the target, carrying the source ACL), a readable `val` shares the source
  `Var`, and an execute-only, proxied, or `anchor=true` entry becomes a lazy
  proxy resolved at call time. Every entry records `source=`, so a re-import
  refreshes it and `(clear sym)`, `(clear :all)`, and `(unuse ns [names…])`
  remove it by name or provenance.
- [x] **Roots, homes, and the current namespace.** `.sys.user` holds system user
  records; `$` is the task's home capability and `@` the attached database root
  (`.` when unattached). The current namespace is task-local (`.main` for `air`,
  `$` for a user), so a top-level `def`/`val` is a durable entry.
- [x] **Users and permissions.** Keyword user ids (`:air`, `:alice`, `:game:bob`)
  with `air` as superuser and non-nesting constituents; `(as-user …)`,
  `(create-user …)`, `(create-constituent …)`, `(set-admin …)`, `(users)`,
  `(current-user)`, `(owner)`; per-volatile owner/ACL metadata enforced on read,
  write, exec, and assume (`hide` is a veto), with `(permissions …)`,
  `(chmod! …)` (including `anchor=true`), `(chown! …)`, and `(assume …)`.
- [x] **`load-air` and libraries.** Parse-first, transactional evaluation with
  nested relative paths; `AIR_LIBPATH` discovery of `<name>/init.air`, loaded
  lazily as `air` under `.lib.<name>` under a per-library lock.
- [x] **Databases.** `(open-airdb name opts…)` / `(close-airdb name)` over AirDB
  (memory or PostgreSQL), a rooted namespace per database with longest-prefix
  ownership, `@` attachment, per-database users and ACL principals, recursive
  close, and the `(error :un-storable …)` check for foreign volatiles. Julia entry
  points: `open_airdb!`/`close_airdb!`.
- [x] **Thread-local `val`.** `(val pattern form…)` evaluates `form` once at
  definition time and installs it as an Air `Var`-backed, thread-local value
  (not callable). `(bind (x=… y=…) body…)` rebinds the `val`s that its namespace
  context resolves, for the dynamic extent of `body`; `(bindings)` returns the
  overrides as a mapping and `bind` can reinstall it.
- [x] **`task`/`await`.** `(task form…)` holds its arguments, evaluates them on
  a spawned task that inherits the current `val` bindings and namespace context,
  and immediately returns a database-backed promise; `(await p)` returns the
  final form's value or rethrows its error. `(future …)` is a tombstone.
- [x] `require`/`load` for `.air` files — implemented as `(load-air path…)`
  (parse-first, atomic, relative to the loading file) plus `AIR_LIBPATH`
  libraries (`<name>/init.air`, lazily loaded under `.lib.<name>`).

## 13. Printing, equality & hashing

- [x] `print`, `println`, `air-string`, `str` (all have), plus
  `air_pretty_string(x; width=80)`, which breaks long forms across lines
  greedily while keeping each line within `width` where it can.
- [x] `eq?`, `same?` (identity) (have).
- [x] `compare`, `hash` (follows `eq?`; an immutable containing a mutable is
  hashable, the mutable part contributing only its identity).

## 14. I/O & side effects

- [x] `print`/`println` (writing through Air's `airout`), `str`.
- [x] File read/write (`read-file`/`write-file`).
- [x] Actor-backed I/O for transactional side effects (both printing and file
  writes are deferred to the transaction's commit).
- [ ] Reading from stdin, and actor-backed reads — later.

## 15. Testing & tooling

- [x] air-level test framework: `(check expr)` is a boolean truth test that records
  inside `(test name body…)`; `test` returns the inert data summary
  `(name=… pass=… fail=… failures=(…))`, with failures held; counters are
  task-local.
- [x] Docstrings on `def` (a literal string at the head of the body, deindented);
  `(doc symbol)` lists patterns that use the symbol and `(doc (form…))` lists
  patterns that match the held form; `(definitions arg)` returns the matching
  `def` forms as quoted data with the docstring in a `doc=` entry.
- [x] REPL: multi-line input while the reader reports an unterminated form,
  string, or block comment under a `...> ` prompt; line-oriented history written
  to `AIR_HISTORY` for external tools such as `rlwrap`; and
  `air_pretty_string(x; width=80)`, which breaks a form greedily across lines
  (the REPL uses it by default; pass `pretty=false` for the flat form).

## 16. Outer system (production rules / RETE)

- [x] `logic-set`, `assert`, `retract`, `revise`, `revise-fact` (eager, with
  optional `reason=`).
- [x] The `(rule conditions… instructions…)` DSL: `:if`, `:let`, `:>` slots,
  and the trigger side effects `:+`, `:-`, `:=`.
- [x] Accumulators (`:accum`), annotations (`=:min`/`:max`/`:sum`/`:mean`/
  `:median`/`:first`/`:last`), `:take` row selection, nesting, `(not …)`.
- [x] Event-driven saturation: trigger classification (assertion / revision /
  retraction), per-slot consequence tracking, and stable fact identities.
- [x] Reasons: base labels and derived `(because RULE PREMISES…)`; multi-reason
  survival; `revise`/`revise-fact` target base facts only.
- [x] Atomic `logic` blocks (snapshot reads, per-call revision collapse,
  rollback on error).
- [x] `update` is the collection update only; set edits are `revise`.
- [x] Provenance / JTMS (`why`, `because`, `rule?`).
- [x] Implicit namespace logic sets (hidden `air/logic/<path>` named forms,
  created lazily), the `readfact`/`writefact`/`readrule`/`writerule`
  permissions, `query`, `defrule`, and `ingest`.
- [x] `facts`/`rules` return one held list (`(' (p 1) (q 2))`, `(')` when
  empty) instead of one hold per element; the hold keeps the list inert and
  its elements are the unheld facts.
- [ ] `depend` (live propagation between logic sets). Freeze the semantics of
  `(depend source [destination])`: record a dependency edge from the source set
  to the destination (the current namespace unless given); on any commit that
  changes the source's base facts or rules, propagate the delta — copied facts
  and rules carry the dependency as their reason, so a source retraction
  retracts the copies and a source revision revises them — then saturate the
  destination immediately so dependants are consistent before the committing
  transaction returns. Cycles must terminate: propagate within the enclosing
  transaction, deduplicate repeated deltas, and either process edges in a
  fixed order or reject a cycle at `depend` time. `ingest` stays the one-shot
  copy; `depend` is the live subscription.
- [ ] Incremental alpha/beta network (a full re-saturation runs per change).
- [ ] `explain` (natural-language narration of a `why` record).

## 17. Mathematica-inspired candidates

- [x] `nest`, `nest-list`, `nest-while` (`FixedPoint` is `rreplace`; see §5).
- [x] `Cases` (`cases`), `Select` (`select`/`case`), `MemberQ` (`member?`),
  `DeleteCases` (`drop-cases`), `FreeQ` (`matches-any?`), `Count` (`count`),
  `Position` (`where`). `Position`'s transposed result is replaced by
  occurrence-major paths: `(where coll obj)` returns the bare keys at depth 1,
  `(where coll obj depth=d)` returns one path per occurrence (each a list of
  `d` keys, including `depth=0`, whose sole key is the whole-form key `0`), and
  `(where coll obj depth=:all)` searches every depth. Paths splice into
  `get`/`with`/`update-in`.
- [x] `Table`/`Array` (`array` — an integer range only, as air has no table
  iterators), `Range` (`range`), `Tuples` (`tuples`), `Subdivide` (`subdivide`).
- [x] `Total` (`sum`), `Product` (`product`), `Counts` (`frequencies`),
  `CountDistinct` (`count-distinct`), `GroupBy` (`group-by`), `GatherBy`
  (`gather-by`), `SplitBy` (`split-by`).
- [x] `MapThread` (`map-thread`), `Outer` (`outer`), `Thread` (`thread`),
  `Transpose` (`transpose`), `Riffle` (`riffle`), `Partition` (`partition`).
- [x] `With`, `Block`, `Module` — `let` is `With` (textual replacement), `let
  bind=` is `Block` (the named values are installed as a lexical scope), and a
  `Module` (mutable names) is `mut`/`val`. No separate forms are needed.
- [ ] Symbolic algebra (`Solve`, `D`, `Integrate`, `Simplify`) — out of scope.

## 18. Clojure-inspired candidates

- [x] `update-in` — `(update-in coll k1 … kn f)` replaces the subform at the
  path with `(f old)`; a sequence key is a nested path and a missing key is
  `naught` to `f`. Not planned: `conj` (covered by `push`), `assoc-in`
  (covered by `with`/`join-in`), and `cons` (covered by `prepend`, which is
  the same operation with the arguments flipped).
- [x] `thread` (Mathematica-style) and `>>` pipelines. Not planned:
  `cond->`, `some->`, `as->` — they exist in Clojure to work around its
  threading macro, which air deliberately does not have; `>>` plus `if`
  covers the same ground.
- [x] `doseq`, `dotimes`, `loop`/`recur`.
- [x] `juxt`, `comp`, `part` (partial application), `memoize`, `trampoline`.
- [ ] Lazy sequences / transducers (later — air is eager).

---

## Conflicts with the current implementation

- `drop` — settled (2026-10-28): `drop` stays the key-removal opposite of
  `push`; `wout` stays the opposite of `with`. The first-n verb (today
  `drop-first`) will be renamed later, possibly `drop-range`.
- `in` vs `contains?`/`member?` — pick one name.
- `seqpart`/`mappart` vs `get` — decide how they relate.

## Open questions

1. `drop` naming — settled: `drop` is key removal; rename `drop-first` later.
2. `i` — settled: bare `i` is the imaginary base, rebindable like any name.
3. Numeric tower — settled 2026-10-29: AirDB supplies the leaves; air adopts
   them fully (`book/numbers.md`).
4. N-ary infix: `(1 + 2 + 3)` should reduce to `((1 + 2) + 3)` eventually
   (deferred — it currently stays unevaluated).
5. Conditions: today a condition whose predicate is an *unbound* symbol passes
   (the resulting form is truthy). Should conditions require a boolean?
6. Hygiene (settled): a binding whose name is also the head symbol of its own
   value. Since `let` substitutes rather than scoping, none of these recurses:
   `(let (db=db) db)` and `(let (db=(db)) db)` yield `db`, and
   `(let (db=(db 1)) db)` yields `(db 1)`. No engine change is needed.
