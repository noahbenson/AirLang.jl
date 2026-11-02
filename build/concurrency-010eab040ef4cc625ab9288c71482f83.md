# Tasks, delays, actors, and promises

Air has four values for work that is not simply a reduction: a **task** runs a
body on another Julia task; a **promise** carries a value from one task to
another; a **delay** computes a body at most once; and an **actor** applies
functions to a value sequentially. All four are database-backed, so they survive
a serialization round trip and a process restart. Streams
([Streams](streams.md)), scheduled events ([Events](events.md)), and agent
sessions ([Agents](agents.md)) are built on the same idea.

## Tasks

`(task form…)` holds its arguments and evaluates them on a separate task,
returning a database-backed **promise** immediately. `(await p)` blocks until
the task finishes and returns the value of the final form, or rethrows the
task's error; `(get p)` and `(ready? p)` read the same promise.

A task captures its enclosing lexical scope (like a closure), keeps the
namespace context active at the point it was created, and **inherits the
current task's `val` bindings**:

```air
(val x 10)
(bind (x=100) (await (task (+ x 1))))   # => 101
```

The spawned task receives a copy of the bindings, so a later `bind` in the
parent does not change what the task sees. `bindings=false` installs no
overrides and `bindings=(x=1 …)` installs exactly those values. A `clean=true`
option clears `.env` and the bindings; an explicit `bindings=` wins over it.

Because a form is data, `(task (' a b))` delivers the held form `(' a b)`
rather than evaluating it. An `(exit v)` inside a task delivers `v`.

A task is a **process item**: its promise lives in the current namespace's
database, but the running task itself is not serialized, so a promise whose
task never delivered (because the process stopped) is simply never delivered.
`(task form… durable=true name=:x)` instead registers a **durable task** — a
record in `$.config.tasks` that reruns from the start after a restart,
replaying its `(checkpoint form)` steps — and `(do-at …)`, `(do-in …)`,
`(tx-at …)`, and `(tx-in …)` schedule events the same way. See
[Events and Durable Tasks](events.md).

## Promises

`(promise)` is a single-assignment value in the current namespace's database.
`(deliver p v)` fills it once, `(get p)`/`(await p)` read it — blocking until
it is delivered, except inside a transaction, which raises instead — and
`(ready? p)` tests it. A promise serializes as a link (`"~uuid"`) whether it is
pending or delivered, and stores a row either way, so a reader of the stored
form waits on the same promise rather than on a copy of its value. `task`
returns such a promise; `deliver` and `await` also accept an ephemeral promise
extern. `promise?` tests one.

## Delays

`(delay body…)` computes its body lazily and at most once. `(get d)`,
`(get d 0)`, and any `get` path that walks *through* `d` force it; a delay
vanishes on the path exactly as a mutable does. Free lexical names are
substituted into the body like a task's, and the namespace context active at
creation — the current namespace, its active `using` layers, the thread-local
`val` bindings, `@`, and `.env` — is saved with it, so the body runs correctly
later, even after the database is reopened. The first force stores the value in
the delay's database cell and every later force returns it without running the
body again:

```air
(val counter (mut 0))
(val d (delay (set! counter (+ (get counter) 1))))
(get d)        # => 1
(get d)        # => 1 (the body does not run again)
(get counter)  # => 1
```

A delay is immutable and never forces on printing or serialization. The body
runs as the user who forces it (like a stored `def`), and a body that forces its
own delay raises a catchable error rather than recursing. `delay?` tests one.

## Actors

`(actor value history=true)` is a sequential worker whose value is persisted on
every update. `(send a fn)` sends the function `fn` (which receives the current
value and returns the new one) and `(reset! a value)` replaces the value
directly; both are deferred to commit inside a transaction, and `(sync)` flushes
a pending send.

The send closes over the caller's lexical scope the way a task does: a
`loop`/`for` binding or rule parameter used inside `fn` is substituted with its
value, and the namespace context active at the call (its `using` layers and
`val` bindings) is kept, so a rule name or a `val` still resolves. A name bound
by the function's own pattern shadows the captured one, so
`(for (x …) (send a (?x -> …)))` uses the parameter, not the loop's `x`.
`actor?` tests one.

## Bindings across tasks

A `val` is an Air `Var` whose current value lives in per-Julia-task storage; a
`bind` overlays that storage for a dynamic extent. A spawned task inherits a
snapshot of the overrides, not the `Var` itself, which is why a later `bind` in
the parent does not change a running task. `(bindings)` renders the overrides
as a plain mapping and `bind` can reinstall one; see
[Thread-local values](namespaces.md#thread-local-values-val-bind-bindings).
An event or durable job can capture the same mapping **as data**, so it sees
the values as of creation rather than as of firing; see
[Events and Durable Tasks](events.md).

## Persistence and errors

A task, delay, actor, or promise belongs to the database of the namespace where
it was created, and storing one in another database raises
`(error :un-storable target)`. An error raised by a task body is delivered to
`await` and rethrown there, so `(do (await (task (raise :boom))) (except ?e
:caught))` is `:caught`. Catch scopes and handler scopes are task-local and do
not cross a `(task …)` boundary: a `notify` in a task with no local handler is
an `:unhandled-signal` error, and an unmatched `throw` becomes an
`:uncaught-throw` error rethrown by `await`. A durable task or event delivers
its error as a **value** instead, so `(await p)` returns `(error …)`.
