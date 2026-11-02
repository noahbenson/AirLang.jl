# Implementation status

`AirLang.jl` currently implements the **inner (reduction) system**.

**Implemented**

* The reader: atoms (symbols, keywords, wildcards, strings, raw strings
  `raw"…"`, regex literals `r"…"` with flags, numbers, booleans,
  `naught`), parenthesized forms, the `|` pattern-alternative shorthand, `#` line comments
  and nestable `#| … |#` block comments,
  `k=v` mappings and hybrid forms, the `.` accessor (`f.a.b` reads as
  `(get f :a :b)`), the `...` splat (`(f a... b)`), bracketed tensor literals
  (`[1 2 3]`, `[1 2; 3 4]`, and `;;` pages for a rank-3 literal), and
  reservation sugar (`{t : body}`, `{t :! body}`, and mixed
  `{a : b :! body}`) — parsed directly into `AirDB.Form` values.
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
* Tables: an immutable `AirTable` extern with column-major persistent storage,
  ordered names, per-column type and in-band NA metadata (`NaN` for float
  columns, the predefined fixed-point symbol `NA` otherwise, overridable with
  `na=`), and an optional unique index (`index=:col`, with `(get t "Bob")` and
  `(with t ("Bob" :age) 60)` addressing rows by index value). The `table`
  constructor accepts row maps, column map entries, `columns=`, `types=`, `na=`,
  and `index=`; `get`, `with` (column, partial row, cell, and the `:` wildcard),
  `push` (row or column), `pop`, `drop`, and `wout` maintain a new table and its
  index; `for`, `map`, `filter`, `reduce`, `any?`, and their kin iterate row
  maps; `table?`, `columns`, `schema`, `nrows`, and `table-index` inspect one;
  and `eq?`/`hash` compare content, metadata, and the index declaration. See
  `book/tables.md`.
* Tensors: a mutable `AirTensor` extern over a Julia `Array` of air's numeric
  tower, with bracketed literals, `tensor`/`tensor-zeros`/`-ones`/`-fill`/`-eye`
  /`-rand`/`-randn`, metadata (`tensor?`, `tensor-shape`, `tensor-rank`,
  `tensor-eltype`) that needs no reservation, per-axis `get` (integers,
  negatives, `:` and index sequences; `0` is the tensor itself and `:` a copy),
  `set!` and `with`, in-place verbs (`tensor-add!` and kin, plus `tensor-map!`
  and `tensor-clamp!`), Julia-like arithmetic with broadcasting and matrix `*`,
  linear column-major iteration and the numeric reductions, Julia-style axis
  reductions (`dims=`/`drop=` on `sum`/`product`/`mean`/`median`/`variance`/
  `std`/`min`/`max`, plus `tensor-any`/`-all`/`-count`), cumulative operations,
  construction helpers (`tensor-arange`/`-linspace`/`-randint`), comparison
  masks and `tensor-where`, manipulation (`tensor-concat`/`-stack`/`-flip`/
  `-roll`/`-tile`/`-squeeze`/`-expand-dims`/`-diag`/`-diagm`/`-tril`/`-triu`),
  sorting and indices (`sort`/`reverse` tensor branches, `tensor-argsort`/
  `-argmax`/`-argmin`), and a `LinearAlgebra` surface (`dot`, `norm`, `tr`,
  `det`, `inv`, `pinv`, `matrix-rank`, `matrix-cond`, `nullspace`, `linsolve`,
  `eigvals`, `svdvals`, `lu`, `cross`, `kron`, `isposdef`, `issymmetric`,
  `ishermitian`, `transpose`, `adjoint`, `reshape`, `eigen`, `svd`, `qr`,
  `cholesky`). Because a tensor is mutable,
  every access to an existing tensor runs in a reservation: `(reserve-read
  resources body…)`/`{… : …}` reads inline and is transaction-safe (extern
  versions are checked, so a concurrent write forces a retry), while `(reserve
  resources body…; read=…)`/`{… :! …}` write-locks on a spawned task and
  returns a promise-like `AirReservation` (`get`/`await`/`ready?`), which inside
  a transaction is commit-gated. A write is never legal inside a transaction; a
  tensor is not storable in a database namespace and does not survive `to-json`
  (`tensor->form` is the persistence spelling). See `book/tensors.md`.
* Data formats: `decode`/`encode` and `read-data`/`write-data` convert JSON,
  YAML, TOML, CSV, TSV, and `.env` to and from plain air data — an object is a
  map form, an array a sequence form, and null or an empty container is
  `naught` — while CSV and TSV decode to a table and encode from one (with
  `header`, `column-delimiter`, `row-delimiter`, `types`, `na`, `columns`, and
  `index` options). Nothing is executed: the YAML reader implements a safe
  practical subset (block and flow collections, quoted and block scalars,
  anchors/aliases with expansion limits, merge keys, multi-document streams,
  core tags only) and refuses every other tag. TOML dates, times, and datetimes
  become the marker forms `(toml-date …)`, `(toml-time …)`, and
  `(toml-datetime …)`. Emitters sort map keys; `write-data` defers to the
  transaction commit like `write-file`. The path helpers need the `filesystem`
  permission on `.air.sys`, which a fresh instance grants only to `air`; an
  ungranted user is refused with `(:permission-denied :filesystem name)`, and
  `air` may grant the permission with `(chmod! .air.sys filesystem=(…))`.
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
  `AIR_HISTORY` for external line editors such as `rlwrap`. `(exit [value])` ends
  the enclosing task: the REPL returns the value, a loaded file stops, and a
  `task` body delivers it to its promise.
* SSH access: `(ssh-server [name] opts…)` serves a line-editing REPL and SFTP v3
  to users who authenticate with a key from their own `$.config.ssh` (or the
  `ssh` val of `$.config`). Only `air` or an admin may start one, and it admits
  exactly the users its owner may assume; the host key lives in the process
  database at `.sys.ssh.<key>`; `(ssh-servers)`,
  `(ssh-host-key key [private=true])`, and `(ssh-close! key)` manage the servers.
  A directory is a namespace and a file is an immutable `bytes` val, so
  `scp`/`sftp` transfer against air paths. An upload is buffered and committed
  as one val at `CLOSE`, and there is no exec channel.
* User interfaces: a UI is a tree of inert `(ui …)` forms (the head is reserved,
  like `error`) covering the full widget catalog — boolean, text, numeric,
  selection, action, display, and layout kinds. `(ui-open [key] tree)` creates
  a named, owner-scoped instance and evaluates its parameters; `on-change` runs
  a callback and `assert` maintains a fact in the namespace current at
  instantiation, labeled per element so it never disturbs an identical fact
  asserted elsewhere. `(ui-values)`, `(ui-value)`, `(ui-set! :key :id v)`,
  `(ui-update! :key tree)`, `(ui-dismiss! :key)`, `(ui-close! :key)`,
  `(ui-instances)`, and `(ui-run tree)` drive it; `(ui-render :key width=n)` is
  a deterministic text renderer, and `(ui-show :key)` is a full-screen
  alternate-buffer terminal renderer over an SSH session (alternate screen,
  reverse-video focus, validation on a status line, Esc to dismiss, Ctrl-C to
  abort with `(error :ctrl-c)`).
* The human-interface (HUI) layer: styled lines with a role-based theme
  (`ui-theme`, `ui-theme!`, `ui-style`, and a per-widget `theme=` map installed
  for that widget's own draw, whose entries are a foreground color or a map of
  style fields; ANSI-16, 256-color, and RGB colors). `ui-theme` prints a role as
  a bare color when only its foreground departs from plain text and as a field
  map otherwise, and `ui-theme!` also accepts a whole saved palette as an
  optional positional theme map, so `(ui-theme! reset=true (ui-theme))`
  round-trips; a repeated field and an entry that names no field are errors. A
  status row right-aligns whole key hints (long and short spellings; short only
  when it fits strictly more). The
  terminal key model keeps CR and LF apart (so Ctrl-J is distinct from
  Enter), resolves `ESC`-prefixed and modifier CSI sequences, times out a lone
  Esc after 25 ms, and delivers bracketed paste as one event; and one editable
  text buffer with layout-driven automatic indentation (the printer's own
  `layout` declarations, so a replayed pretty form reproduces its indentation),
  bracket pairing that respects strings, raw strings, regex literals, and nested
  block comments, undo/redo, and kill/yank.
* Composite widgets, each a durable `(ui KIND …)` form whose state is a `mut`
  created by its constructor (`ui-code`, `ui-editor`, `ui-notebook`,
  `ui-browser`, `ui-shell`, `ui-chat`): a code block that refuses to run
  unclosed input and dims stale output; a definition editor that saves from
  stored source and re-evaluates `def`/`val` forms; a notebook of paired
  input/output cells with `Ctrl-J` run, `Ctrl-R` run-all (sequential, in
  document order), `Ctrl-O`/`Alt-O` clear-output, `Ctrl-G`/`Alt-G` insert,
  continuous document navigation, collapse-and-scroll for long cells, and
  stale-output marking; a `ns-entries` namespace tree whose `Ctrl-J` opens the
  editor for a definition and a notebook for a `val`; a tabbed shell with a
  browser and a scratch notebook by default (opened when a renderer starts it,
  so a headless render creates nothing), Tab/Shift-Tab tab switching,
  `Alt-1`…`Alt-9` selection, and an Esc that pops one layer and asks before
  discarding edits;
  and a chat over a caller-supplied stream pair, with message cells tinted by
  direction, a polled receive pump, and code mode — a draft beginning with `(`
  is evaluated locally and only its value is sent.
* Connections: `.io.conn` records each live endpoint as inert data
  (`id=`, `kind=`, `user=`, `since=`, `attached=`, `closed=`), readable by
  everyone and writable by its owner; `(ui-attach! [conn] widget)`,
  `(ui-detach! [conn])`, `(ui-attached)`, `(ui-connection)`, and
  `(ui-connections)` drive them. `ui-show` attaches the caller's own connection,
  one widget per connection, and a widget instance and its muts survive a
  detach. The instance owns its built tree and a ticker, so an evaluation or a
  notebook run-all continues with no renderer attached and its result is stored
  in the widget's state; detaching flushes the on-screen state, and only
  `ui-close!` tears a named instance down. Both the SSH channel backend and a
  local `TTYTerminal` backend exist.
* UI sessions: an attach of a raw `(ui …)` form is a projection with no named
  instance, and the element itself — the form and its state `mut` — records its
  connection as `controller=` transactionally. Detaching or closing the
  connection clears the controller and leaves the element; the projection is
  retracted only once no renderer and no job remain, so a job's result is
  written first. `(ui-attached)` returns the attached form (or an open
  instance's key), and `(current-ui)` names the form an evaluation belongs to.
  An interactive SSH login opens a default `(ui-shell)` (browser and notebook in
  `$`) held on the session task, which `ui=false` in `$.config.ssh` turns off;
  a non-pty session never opens one.
* `ns-entries` and `ns-entry` list a namespace's entries as data
  (`name=` as a keyword, `kind=`, `owner=`, `doc=`, and `src=` on request),
  omitting unreadable and hidden entries exactly as `using` and `doc` do.
  `ns-vals` lists the readable `val` names as keywords (a redefinition appears
  once, at its last position), `ns-defs` the readable `def` rules as held forms
  with `def` replaced by `'` and any stored `src=` stripped, and `ns-facts` /
  `ns-rules` the implicit logic set's held fact and rule lists.
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
  extern, so they are `eq?` and `same?`; promises are **identities**. A `bytes`
  value is an immutable octet string with content equality (so it hashes like a
  value) that prints opaquely as `#<bytes N>`; it is the value a transferred
  file holds.
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
* Events, scheduled transactions, and durable tasks: `(do-at time body…)` and
  `(do-in interval body…)` register a durable **event** in the creator's
  `$.config.events`, run its body in its own task at a wall-clock time or after
  a delay, and return a promise that receives the value (`(tx-at …)`/`(tx-in …)`
  run the body as one transaction). `repeat=true` on `do-in`/`tx-in` re-arms
  after each completed run; `name=`, `bindings=`, `let=`, and `catch=` are the
  options. `(events)`, `(event x)`, `(cancel-event x)`, and `(events-resume)`
  list, inspect, cancel, and resume; `(tasks)`, `(task-info)`,
  `(cancel-task)`, and `(tasks-resume)` are the same for durable tasks, which
  `(task … durable=true name=:x)` registers in `$.config.tasks`. A record holds
  the body, the captured context (namespace, layers, bindings, `@`, `.env`), the
  schedule, the status, the attempts, and the promise; an error is delivered as
  an error object, and a result the database cannot hold as `:un-storable`.
  `bindings=true` snapshots the creator's `val` overrides as data, so an event
  sees the values as of creation and a captured stream still posts after a
  restart. A durable task reruns from the start and replays its
  `(checkpoint form)` steps (at-least-once). A cancel also cancels the running
  attempt's token, so a long body stops at its next air-level cancellation
  point: the reducer polls every 64 steps and the whole-tree verbs every 1024
  elements, while a Julia call (including a blocking `await`/`fetch`) and work the body
  spawned on another task are not interrupted. Records are coordinated within one
  process; `air` resumes them on startup before the REPL or serving. See
  [Events and Durable Tasks](events.md).
* Agents and channels: a user record carries `kind=:human|:agent`, and
  `(create-agent :bot config…)` makes an `:agent` constituent whose inference
  settings live in `$.config.agent` (`user-kind`, `agent?`, `agents`,
  `agent-config`, `agent-config!`). A session is a mutable behind the named form
  `agent/<agent>/sessions/<sid>`; its handle carries a channel of three streams
  (outbox, inbox, and a hook copy queue), and `open-session`, `sessions`,
  `session-info`, `session-history`, `session-channel`, `session-post`,
  `session-fetch`, `session-hook!`, `session-resume`, and `session-close!`
  manage it, with `channel?`/`channel-post`/`channel-fetch`/`channel-ready?`/
  `channel-count`/`channel-hook!`/`channel-unhook!`/`channel-close!` over the
  channel. A worker task turns a text message into a model turn and a
  keyword-headed form into a command (`:help`, `:context`, `:reset`, `:system`,
  `:model`, `:compact`, `:stop`), answers with a structured `(reply …)` or an
  error object, and keeps the transcript, usage, and context estimate in the
  session state; `context=` enables usage-driven compaction. The transport
  speaks the Anthropic Messages API and the OpenAI chat-completions dialect
  (Fireworks, OpenAI, DeepSeek, and any `:compatible` server), retries 429/5xx
  with backoff, and is replaceable in tests. A reply is copied to the notify
  queue when the owner's `on-receive` hook is installed, so the hook and
  `session-fetch` never steal from each other; a failing hook is recorded in
  `last-hook-error`. Sessions are durable and resume lazily on the next
  message. See [Agents](agents.md).

**Deferred**

* Sequence patterns and sequence replacement: a rule whose pattern matches a
  run of elements rather than a whole form.
* Head-restricted blanks: not supported; use a condition (`p \ pred`).
* The outer engine's incremental RETE alpha/beta network (a full re-derivation
  runs on each assert instead).
* Forms-as-functions querying (`(f 1)` on a collection returns its element).
* Serializable task *stacks*: a durable task reruns from the start and replays
  its `checkpoint`s, so a step between a side effect and its checkpoint can
  repeat (at-least-once), and conditional checkpoints can mis-replay. Cron
  syntax, retry/backoff policies, cancelling inside a long Julia call, a single
  heap-based scheduler (there is one polling task per job),
  cross-database/cross-process leases, labelled checkpoints, and purging reused
  names are deferred. A plain (non-durable) task is still a process item: only
  its promise is stored.
* Sockets and other extern types; `pmap` and higher-level parallel helpers built
  on `task`.
* Incremental SSH transfers and a non-interactive exec channel: an SFTP upload
  is buffered and committed as one `bytes` val at `CLOSE` (correct and atomic,
  but not streamed), and `ssh host command` is not served, so only the REPL and
  the SFTP subsystem are available.
* Streaming model replies (SSE), tool and function calling, an agent that
  evaluates air code, an exact tokenizer, prompt caching, session purge and
  garbage collection, cross-process session locks, provider-specific quirks
  (e.g. `max_completion_tokens`), and cost/rate accounting. The agent layer is
  text in, one reply out.
* The agent-user-interface (AUI) level: chat and form tools that an agent drives
  over a text protocol. Only the human-interface level is built.
* Renderer follow-ups: a web renderer, mouse support, and cancelling work inside
  a long Julia call (a running cell is evaluated on its own task, so the frame
  stays live, and Ctrl-C cancels it at its next air-level cancellation point).

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
