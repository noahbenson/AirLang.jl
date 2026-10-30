# Namespaces

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
| `.air.sys` | the system functions: `load-air`, `read-file`, `write-file`, `read-data`, `write-data`, `open-airdb`, `close-airdb` |
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
permissions](permissions.md#users-homes-and-permissions)).

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

## Roots, homes, and the current namespace

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

A **`.`-atom** address is not the only spelling a namespace-taking form accepts.
`(get $ :config)` and a leading-`.` path name the same namespace, and every form
that resolves an address — `namespace`, `using`, `use`, `import`, `unuse`,
`clear`, `open-airdb`, and the logic-set targets — accepts either, so
`(namespace $.config.ssh (val authorized-keys ("…")))` writes
`.sys.user.<u>.home.config.ssh`. The resolver checks a bound name first: when
the body has bound `$` (or `@`) lexically, the form is evaluated normally and
the binding wins, exactly as it does for a bare `$`.

The task's identity, current namespace, database root, and `.env` mapping
travel with spawned tasks, so a `task` sees the same roots (see
[Tasks](#tasks)).

(using-use-and-import)=
## `using`, `use`, and `import`

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

## Thread-local values (`val`, `bind`, `bindings`)

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

(tasks)=
## Tasks

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

(delays-actors-and-promises)=
## Delays, actors, and promises

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
`(ready? p)` tests it. A promise serializes as a link (`"~uuid"`) whether it is
pending or delivered, and stores a row either way, so a reader of the stored
form waits on the same promise rather than on a copy of its value. `task`
returns such a promise; `deliver` and `await` also accept an ephemeral promise
extern.
