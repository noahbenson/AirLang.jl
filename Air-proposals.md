# Proposed changes to Air.jl for air's process model

Status: proposal for the Air.jl maintainer. Nothing here is implemented in
AirLang.jl yet; these changes are prerequisites for the AirLang-side work
listed at the end.

## Context

air is a **single-process** system. Threads/tasks play the role of OS
processes: a task is the unit of concurrent work, and its handle is a
database-backed promise (`AirDB.PromiseForm`). There is no plan for
multi-process air.

Two design commitments constrain any change here:

- **Delayed writes are intentional.** Memory is authoritative; the database may
  lag by some number of commits, and a crash leaves the database at a valid
  recent point. Nothing below may make a write synchronously durable or add a
  cross-process protocol.
- **A reference is not a permission.** Holding a value is fine; every *use* is
  checked. Air.jl is the substrate (STM, `Volatile`, `Actor`, `Promise`,
  `Delay`), not the policy layer: it should carry enough state for AirLang to
  check, and should never block in a way that cannot be cancelled.

The model still has four holes that AirLang cannot close on its own:

1. A promise created inside a transaction can be read (and, outside the
   transaction, `await`ed) before that transaction commits. Today this either
   blocks forever or loses the delivery.
2. A failed task is represented as a *delivered error value* plus a
   process-local registry (`src/builtins_extern.jl:66` in AirLang).
   Failure is not durable and is invisible to another `Env` over the same
   database.
3. A promise cannot be timed out or cancelled, so a task cannot be cancelled:
   `take` waits on a `Threads.Condition` with no wake-up path
   (`src/util.jl:459-479`).
4. `isequal` and `hash` on a promise call `take` (`src/util.jl:539-540`), so
   an undelivered promise as a dictionary key hangs.

Items A1–A3 below address these. A4 is optional. A5 records things that
deliberately do **not** change.

## A1. Promise failure state

### Current

`Promise{T}` has a single settlement slot:

```julia
mutable struct Promise{T}
    mutex::ReentrantLock
    cond::Threads.Condition
    _val::Union{Nothing,Some{T}}       # delivered value, or nothing
    ondelivery::Union{Nothing,Function}
end
```

(`src/util.jl:408-423`.) There is no failure channel, so air delivers an error
*form* and stores the real condition in AirLang's `_TASK_ERRORS`.

### Proposed

Add a second, mutually exclusive terminal slot and a callback:

```julia
mutable struct Promise{T}
    mutex::ReentrantLock
    cond::Threads.Condition
    _val::Union{Nothing,Some{T}}       # set iff delivered
    _err::Union{Nothing,Some{Any}}     # set iff failed
    ondelivery::Union{Nothing,Function}
    onfailure::Union{Nothing,Function} # NEW; called with the failure payload
end
```

Invariant: at most one of `_val`/`_err` is non-`nothing`, and both transitions
happen under `mutex`.

New API (exported):

- `fail!(p::Promise{T}, err) -> err` — settle as failed. Raises `ArgumentError`
  if the promise is already delivered or failed.
- `PromiseFailed <: Exception` with field `err::Any`; `showerror` prints
  `promise failed: <err>`. `take`/`getindex` throw it when failed.
- `isfailed(p) -> Bool`.
- `isready(p)` — true when delivered **or** failed.
- `take(p)` — returns the value or throws `PromiseFailed`; `take` must never
  block for a settled promise.
- `put!`/`fail!` on an already-settled promise raise
  `ArgumentError("given promise is already fulfilled")` (keep the existing
  message for `put!`; the failure path may say "already settled").

Transaction integration:

- `PromiseTxData{T}` (`src/TX.jl:624`) currently holds `val::Some{T}`. Extend it
  to hold either a delivered value or a failure payload.
- `take`'s read-your-writes branch (`src/util.jl:464-468`) must return a staged
  delivery or throw a staged failure.
- The commit path that calls `ondelivery` (`src/TX.jl:949`) must also call
  `onfailure` for a staged failure; the abort path discards both.
- `_promise_stage!` (`src/util.jl:491-507`) must allow failing a promise and
  must keep the "already fulfilled" check across both kinds.

AirDB uses `ondelivery` to write the delivered row
(`AirDB/src/ref_forms.jl:112-113`). With `onfailure` it can write a durable
failed row instead of storing an error form as a value.

### Acceptance

- `fail!(p, :boom)` then `take(p)` throws `PromiseFailed`; `isready(p)` is true;
  a second `put!` or `fail!` raises.
- `put!` then `fail!` (and the reverse) raises; the first settlement wins.
- Inside a transaction, `put!`/`fail!` then `take` sees the staged settlement;
  an abort discards it (the promise remains unsettled).
- `show` prints `<failed: …>` rather than blocking.
- Concurrent waiters all wake on failure.

## A2. Non-blocking `isequal`/`hash`

### Current

```julia
Base.isequal(a::Promise{T}, b::Promise{S}) where {T,S} = (a === b) || isequal(a[], b[])
Base.hash(d::Promise{T}) where {T} = 0x767127451c1e402a + hash(d[])
```

(`src/util.jl:539-540`.) Both call `take`, so an undelivered promise as a `Dict`
key or in a keyed structure blocks forever. AirDB works around this with
`IdDict`.

### Proposed

Identity semantics, matching air's `eq?` (a volatile, actor, or promise matches
only itself; hashing never descends into it):

```julia
Base.isequal(a::Promise, b::Promise) = a === b
Base.hash(d::Promise, h::UInt) = hash(objectid(d), hash(0x767127451c1e402a, h))
```

Note this is a behavior change only for code that compared the *values* of two
different promise objects; the current behavior is a hang, not a useful
semantic.

### Acceptance

- `hash(p)` and `isequal(p, p2)` return immediately for an undelivered `p`.
- Write the test under a hard timeout so a regression fails rather than hangs
  the suite.
- A promise still works as a `Dict` key across delivery.

## A3. Interruptible waits, timeouts, and cancellation

### Current

`take` (`src/util.jl:459-479`) loops on `wait(d.cond)` with no timeout, and
there is no way for another task to wake it. `Base.sleep` is not cancellable.
Consequently a task blocked on `(await p)` or `(sleep)` can never be cancelled.

### Proposed

**Timeouts.**

```julia
take(p; timeout::Union{Nothing,Real} = nothing) -> T
```

- Settled promise: return/throw immediately, even with `timeout=0`.
- Otherwise wait, and after `timeout` seconds throw
  `PromiseTimeout(timeout)` (new exception type, exported).
- Implement the timed wait with a `Timer` that notifies the waiter; close the
  timer in a `finally`. Do not busy-poll.

**Cancellation token.**

```julia
mutable struct CancelToken
    lock::ReentrantLock
    cancelled::Bool
    reason::Any
    waiters::IdDict{Any,Nothing}   # registered Waiter objects
end

canceltoken() -> CancelToken        # task-local, created lazily
setcanceltoken!(tok)                # task-local override; returns tok
cancel!(tok, reason = nothing)      # idempotent; wakes every waiter
iscancelled(tok) -> Bool
checkcancel(tok)                    # throws Cancelled if cancelled
Cancelled <: Exception              # fields: token, reason
```

**Waiters.** Each blocking call creates a small `Waiter` with its own lock and
`Threads.Condition`, registers it with the promise and (if a token is supplied)
with the token, then loops:

1. check cancelled (token) and settled (promise) under the waiter's lock;
2. wait on the waiter's condition;
3. on wake, re-check; the delivery, failure, cancellation, and timeout paths
   each notify the waiter.

Register before the final re-check, so a cancellation between the check and the
wait cannot be missed. Unregister in a `finally`. Delivery/failure must notify
all registered waiters as well as the promise's own `cond` (`notify(cond;
all=true)` already does the latter).

**Signatures.**

- `take(p; timeout = nothing, token = canceltoken())`. Pass `token = nothing`
  to opt out of cancellation (e.g. cleanup work in a cancelled task).
- `isready(p; token = nothing)` — a non-blocking predicate should not observe
  cancellation; keep the keyword to allow explicit checking if desired.
- `Air.sleep(seconds; token = canceltoken())` — an interruptible sleep;
  `Base.sleep` cannot be made cancellable, so air's `(sleep)` must call this.
  Early return is not enough: it throws `Cancelled`, since the semantics of
  `(sleep)` in a cancelled process should be "interrupted", not "completed".
- Every blocking Air primitive that air's process model uses must accept the
  same keywords.

**Interaction with transactions.** Keep the existing rule that an undelivered
promise must not be awaited inside a transaction (AirDB's `getindex` enforces
it at `AirDB/src/ref_forms.jl:160-167`). `take` itself does not need to know
about transactions, but do not change the staged-delivery read-your-writes
behavior.

### Acceptance

- `take(p; timeout=0.05)` throws `PromiseTimeout` with `p` still pending.
- A delivery at 0.02 s wins over a 0.5 s timeout.
- A waiter blocked in `take` wakes and throws `Cancelled` when another task
  calls `cancel!` on its token.
- `cancel!` before the wait throws immediately (no missed wake-up), including
  the check/register race.
- `Air.sleep(10)` returns in well under 1 s after cancellation, with
  `Cancelled`.
- A cancelled task can still pass `token=nothing` and block.
- No waiter leaks: after cancellation, the token's waiter set is empty.

## A4. Optional: bounded mailboxes

AirLang can build a mailbox from an `Actor` plus A3 (send a function that
signals a promise). Add a bounded mailbox to Air only if the process model needs
backpressure that promises cannot express; otherwise leave it to AirLang.

## A5. Deliberate non-changes

- **No `oncommit`/`onabort` hook.** AirLang's `_tx_boundary` runs after a
  successful commit and after AirDB has enqueued its write batch, so
  spawn-at-commit can be implemented there. Adding a general hook would invite
  users to run arbitrary effects inside the commit path.
- **No multi-process work**: no cross-writer CAS, leases, change feed, global
  transaction ids, or distributed promise delivery.
- **No synchronous durability.** The writer remains asynchronous; `sync` remains
  the explicit barrier.
- **No priority or fair-share scheduler.** Julia's task scheduler is the
  scheduler.

## Compatibility

- `take` gains keyword arguments; existing calls are unaffected.
- `isready` becomes true for failed promises, and the new `isfailed` is added.
- `hash`/`isequal` change from value-comparing (and blocking) to identity;
  this is the only semantic change to existing API, and it replaces a hang.
- `Promise` gains a field; the inner constructor is not public, but check any
  code that builds `Promise{T}` via `new` inside Air.
- New exported names: `fail!`, `PromiseFailed`, `PromiseTimeout`, `isfailed`,
  `CancelToken`, `Cancelled`, `canceltoken`, `setcanceltoken!`, `cancel!`,
  `iscancelled`, `checkcancel`, `sleep` (or a non-clashing name — see below).

Naming note: exporting `Air.sleep` shadows nothing at module scope but will
collide with `Base.sleep` if a user does `using Air`. Either export it as
`sleep` (users of the process API already know it is Air's) or keep it
unexported as `Air.AirSleep`/`Air.sleep_until` and let AirLang call it
qualified. AirLang only needs some stable entry point; prefer
`Air.sleep_interruptible` and document it as internal.

## Evidence (verify before changing)

- `src/util.jl:408-423` — `Promise` fields.
- `src/util.jl:459-479` — `take`, blocking wait.
- `src/util.jl:481-525` — `put!`, staging, delivery.
- `src/util.jl:526-538` — `isready`.
- `src/util.jl:539-540` — blocking `isequal`/`hash`.
- `src/TX.jl:616-630` — `PromiseTxData`.
- `src/TX.jl:940-955` — commit dispatch of promise callbacks.
- `src/TX.jl:1055-1070` — commit writes `_val`.

## AirLang follow-on (after this lands)

- `_bi_task` and `_bi_promise` stop using `_TASK_ERRORS`
  (`src/builtins_extern.jl:66-86`); a failed task calls `fail!` with its error
  form instead of delivering `_error_form(e)`.
- `(get p)` raises the same error as `(await p)`; add `(failed? p)` and
  `(promise-error p)`.
- `(sleep)` uses the interruptible sleep; `(cancel p)` calls `cancel!` on the
  task's token, which requires AirLang to keep a process table mapping a
  promise id to its `Task` and token.
- Task creation records the token so a child task does not inherit the
  parent's cancellation by accident (each task gets a fresh token unless
  explicitly linked).

## Out of scope

Supervision trees, links/monitors, priority scheduling, multi-process air, and
durable jobs. Those are AirLang-level (or future) work.
