(events)=
# Events and Durable Tasks

A **job** is work that air runs later, in its own task, from a durable record.
Four special forms schedule one:

| form | when it runs | body |
| --- | --- | --- |
| `(do-at time body…)` | at a wall-clock time | a `do` block |
| `(do-in interval body…)` | after an interval, in seconds | a `do` block |
| `(tx-at time body…)` | at a wall-clock time | one transaction |
| `(tx-in interval body…)` | after an interval, in seconds | one transaction |

and `(task body… durable=true)` registers a durable task instead of an
ephemeral one. Every scheduled call returns a **promise**; `(await p)` yields
the body's value, and the promise is delivered exactly once.

```air
(val p (do-in 30 (check-widgets)))
(await p)                       ; => the value of (check-widgets)
```

```{note}
Nothing starts a job after a restart until air resumes it. See
[Durability and resume](#durability-and-resume).
```

## Scheduling

The time argument of `do-at`/`tx-at` is a [time](time.md) value or a number of
UTC epoch seconds; a time in the past fires at once. The interval argument of
`do-in`/`tx-in` is a non-negative number of seconds. The body is every
positional form after the time together with the block's `let=` and `catch=`
entries, so an event body is an ordinary `do` block:

```air
(do-in 5 let=(n=3) catch=true (print n) (throw :done))
```

`do-in` fires once. `repeat=true` turns it into a fixed-delay recurrence: the
next run is scheduled `interval` seconds after the previous one *completes*,
and missed occurrences coalesce rather than catch up. `do-at` and `tx-at`
reject `repeat=` — use `do-in` or `tx-in` to repeat.

`tx-at`/`tx-in` evaluate the body as one `tx`: an escaping error aborts every
write, and an error the body catches itself commits. Otherwise they behave
exactly like `do-at`/`do-in`.

## The promise contract

The promise settles when a run finishes:

* success delivers the body's value (for `do-in repeat=true`, the **first**
  run's value; later runs do not deliver again);
* an error delivers the air error object — `(await p)` returns `(error …)`
  rather than raising, so a failed body is inspectable;
* a cancellation delivers `(error :event-cancelled name=…)` or
  `(error :task-cancelled name=…)`;
* a result the database cannot hold is delivered as
  `(error :un-storable …)`; the body's other effects stand.

The status write and the delivery share one transaction, so a job cannot record
`:done` with an undelivered promise.

## Names, listing, and cancellation

```air
(val p (do-in 3600 name=:check-widgets (check-widgets)))
(events)                    ; => (check-widgets=(status=:pending …))
(event :check-widgets)      ; one summary, or (error :event-not-found …)
(cancel-event :check-widgets)
(cancel-event p)            ; the promise names the same job
```

| form | meaning |
| --- | --- |
| `(events [user])` | a map `name → summary` of the user's events |
| `(event x [user])` | one summary; `x` is a name (keyword, symbol, or string) or a promise |
| `(cancel-event x [user])` | cancel; returns the summary |
| `(events-resume [user])` | start every non-terminal event; `(resumed=n)` |

The same four exist for durable tasks: `tasks`, `task-info`, `cancel-task`,
and `tasks-resume`.

A summary excludes the body and the captured context; it reports `id`, `name`,
`kind`, `tx`, `owner`, `status`, `at`, `interval`, `repeat`, `attempts`,
`delivered`, `promise`, `result`, `error`, and the timestamps.

A name must be free at creation; reusing a name whose record is still
`:pending` or `:running` raises an `event-exists` (or `task-exists`) error. A
terminal record's name may be reused — the newer entry shadows it, and `(events)` lists only the
newest name. An unnamed call gets a generated name (`e-…` or `t-…`).

Cancelling is not preemption. A record that has not started is cancelled at
once and its worker stops within a slice; a body that is already running may
still commit its own side effects, and the outcome is discarded when it
finishes. Cancelling a terminal job is an idempotent no-op.

## Bindings

A `val` binding is task-local, so a job would normally see only definition
values. `bindings=` carries the creating task's overrides into the new task:

| value | effect |
| --- | --- |
| absent | no overrides (an event), the creator's current overrides (a `task`) |
| `true` | snapshot the creator's current overrides |
| `false` | no overrides |
| `(x=1 y=sm)` | exactly these values |

```air
(val x 10)
(bind (x=99) (do-in 5 bindings=true (print x)))   ; prints 99
(do-in 5 bindings=(x=42) (print x))               ; prints 42
(do-in 5 (print x))                               ; prints 10
```

Bindings are captured as **data**, not as `Var` identity, so they survive a
serialization and a restart: the values are stored in the job record and
resolved by name when the run starts. An event therefore sees the values as of
creation, not as of firing. A name in an explicit mapping must be a `val` in
the creating context, and its value must be storable in the job's database — a
mistake raises at creation, not hours later.

A stream is a durable value (it serializes as a link), so scheduling work that
posts to a stream is a first-class pattern:

```air
(val s (stream))
(do-in 60 bindings=(s=s) (post s "tick"))   ; the event posts a minute later
```

## Durable tasks and checkpoints

`(task body… durable=true name=:nightly)` registers the same kind of record
under `$.config.tasks`, starts it at once, and returns its promise. Plain
`task` remains ephemeral: its promise is durable, the running task is not.
`bindings=` defaults to `true` for both; `name=` requires `durable=true`, and
`clean=true` still clears `.env` and the bindings.

A durable task reruns **from the start** after a restart. `(checkpoint form)`
marks a step whose value a previous attempt already recorded, so the rerun
skips it:

```air
(task durable=true name=:nightly
      (checkpoint (fetch-source))
      (checkpoint (transform (checkpoint-value)))
      (store result))
```

Inside a durable run, `checkpoint` returns the recorded value when an earlier
attempt reached that point and otherwise evaluates its form, records the
result, and returns it. Outside a durable run — a plain task, an event, the
top level — it simply evaluates the form, so one body can serve every surface.
It refuses to run inside an open transaction, because its in-memory cursor
cannot roll back with a retried transaction.

Replay is **at least once**: a crash between an external side effect and the
checkpoint that records it repeats that step, and the sequence of `checkpoint`
call sites must be deterministic across attempts. The record is cleared when a
run completes, so a later resume starts clean.

## Durability and resume

A job's record is a database value: a mapping holding its identity, kind,
owner, body, captured context, schedule, status, attempts, checkpoints, result,
error, and promise. It lives in the creating user's home — `$.config.events` or
`$.config.tasks` — so a job belongs to the user who scheduled it, not to
whatever namespace happened to be current.

A job runs only while a process is alive. On startup, air calls the resume
machinery before the REPL and before serving:

* a record left `:running` by a crash is flipped back to `:pending` and rerun
  from the start (replaying its checkpoints);
* a repeating event fires once and re-arms;
* a due one-shot fires at once.

Embedders and tests get no implicit background work; call
`(events-resume)`/`(tasks-resume)` explicitly. It counts every non-terminal
record it made active, as `(resumed=n)`.

```{warning}
Jobs are coordinated within one process. Two live processes over one database
are not: a cancel written by one is not seen by the other's worker, and a
pending promise loaded in another live process is not woken by a delivery
there. Treat a registry as owned by one process at a time and poll `(event …)`
when crossing a process boundary.
```

Wall-clock due times can fire early or late if the system clock jumps. A
waiting job wakes four times a second to notice a cancel, so there is one
polling task per job.

## Permissions

A job is created and run with the identity of the user who scheduled it: the
body's `(current-user)` is that user, and the record carries an owner-only ACL.
`(events)`/`(tasks)` filter to the records the caller can read, and another
user cannot inspect or cancel someone else's job by name. `air` bypasses every
check; an admin sees its constituents' jobs. A job cannot be created inside an
open transaction.

## Limits

* A body cannot resume mid-stack; a durable task reruns from the start and
  relies on `checkpoint`s.
* Cancellation is not preemption.
* No cron syntax, retry policy, or backoff; a repeating job re-arms on a fixed
  delay and a failed run simply records its error.
* Reusing a terminal name accumulates a shadowed entry; there is no purge.
* One polling task and one transaction per status change per job.
