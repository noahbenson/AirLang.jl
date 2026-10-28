# Proposed changes to AirDB.jl for air's process model

Status: proposal for the AirDB.jl maintainer. Nothing here is implemented in
AirLang.jl yet; these changes are prerequisites for the AirLang-side work
listed at the end.

## Context

air is a **single-process** system, and its tasks/threads are its OS processes.
A task's handle is a database-backed promise (`PromiseForm`), so the database is
also the process table's backing store. The following commitments are fixed:

- **Single process.** No cross-writer coordination, leases, change feed, or
  global transaction ids.
- **Delayed writes are intentional.** Memory is authoritative; the database may
  lag by some number of commits. A crash leaves a valid database at a recent
  point. Do not make a write synchronously durable.
- **A reference is not a permission.** Holding a foreign value is allowed;
  every use is checked. AirDB is the storage layer: it must carry owner/ACL
  metadata and expose it *without* reading the payload, but it does not know
  the caller's identity and must not enforce policy.
- **Task/promise/actor default ACL is owner-only**, matching namespaces and
  entries (owner has read/write/exec; nobody else has anything).

Four gaps remain that AirLang cannot close alone:

1. A task's promise can be read before the transaction that created it
   commits; today it either deadlocks or loses the delivery.
2. Task failure is not durable: AirLang stores the error *form* as the
   delivered value and keeps the real condition in a process-local registry.
3. Actors, promises, and resources have no owner/ACL metadata, and
   `metadata(vf)` loads the payload, so a permission check cannot precede the
   read.
4. A delivery can be lost when the promise row was never created (a real bug,
   see D1.4).

## D1. Promise state, durable failure, and uncommitted promises

### Current

- `form_promise` has only `promise_id`, `value`, `delivered_at`
  (`src/database.jl:73-79`).
- `_UPDATE_PROMISE_SQL` is unconditional and has no `value IS NULL` guard
  (`src/database.jl:165-170`); a delivery to a row that was never created
  silently does nothing.
- `_SELECT_PROMISE_SQL` returns only `value` (`src/database.jl:173`).
- `load!` treats "no row" and "empty row" identically and sets
  `persisted = true` in both cases (`src/ref_forms.jl:117-143`, especially
  `:126-128`).
- `PromiseForm(db)` is created `loaded = true` with an in-memory `Air.Promise`
  (`src/ref_forms.jl:102-109`), with no notion of whether its creating
  transaction has committed.

### 1.1 Schema (v6)

```sql
CREATE TABLE IF NOT EXISTS form_promise (
    promise_id  UUID        PRIMARY KEY,
    state       TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (state IN ('pending','delivered','failed')),
    value       JSONB,
    error       JSONB,
    metadata    JSONB,
    settled_at  TIMESTAMPTZ
)
```

`delivered_at` is renamed `settled_at` because a failure is also a settlement.
(The version bump means existing databases are refused anyway; see D4.)

### 1.2 Delivery and failure are compare-and-set

```sql
-- delivery
UPDATE form_promise
   SET value = $2::jsonb, state = 'delivered', settled_at = clock_timestamp()
 WHERE promise_id = $1::uuid AND state = 'pending'
RETURNING promise_id;

-- failure
UPDATE form_promise
   SET error = $2::jsonb, state = 'failed', settled_at = clock_timestamp()
 WHERE promise_id = $1::uuid AND state = 'pending'
RETURNING promise_id;
```

In a single-process system the in-process `Air.Promise` already prevents a
second settlement, so a zero-row result indicates a bug (or a stale handle).
Do not raise from the writer for it — that would poison the writer and set
`db.failure`. Treat it as a no-op and, in debug builds, warn. The API-level
`put!`/`fail!` check the loaded state and raise `ArgumentError` before staging.

### 1.3 Load, read, and failure

- `_SELECT_PROMISE_SQL` returns `value, error, state, metadata, settled_at`.
  Distinguish four cases: **absent**, **pending**, **delivered**, **failed**.
- `load!` on absent keeps `persisted = false` and leaves the promise
  unsettled. `getindex`/`isready` on an absent promise that is not
  `commit_state === :pending` raise `FormNotFound` (today it silently looks
  pending).
- `load!` on delivered constructs an `Air.Promise` already delivered (no
  callback); on failed constructs one and calls `Air.fail!` with the stored
  error form.
- `put!` on a failed promise raises; `isready` is true for failed.

The error is stored as an air error *form* (JSONB), so AirLang can rethrow it
unchanged.

### 1.4 Ensure the row on delivery (bug fix)

`_write_batch!` builds `ensures` from `promise_ensure` plus the promises
referenced by encoded forms (`src/actor.jl:300-303`). A promise that was
delivered but never embedded in a stored form therefore has no row, and
`_UPDATE_PROMISE_SQL` matches nothing — **the delivery is lost**. This is
reachable today with a task whose promise is awaited but never stored.

Fix: include `keys(promise_update)` in `ensures`, and create the row in the
same batch. Change `promise_ensure` from `Set{UUID}` to
`Dict{UUID, Union{Nothing,Form}}` so the insert can carry the owner metadata
(D2):

```sql
INSERT INTO form_promise (promise_id, metadata)
VALUES ($1::uuid, $2::jsonb)
ON CONFLICT (promise_id) DO NOTHING
```

Ordering invariant: the writer actor processes batches in commit order, and a
spawned task reaches its delivery only after its creating batch has been
enqueued, so ensure-before-update holds across batches, not just within one.

### 1.5 Uncommitted and aborted promises

Add to `PromiseForm`:

```julia
mutable struct PromiseForm <: Form
    id::UUID
    promise::Union{Nothing,Air.Promise{Form}}
    loaded::Bool
    persisted::Bool
    lock::ReentrantLock
    db::AbstractDatabase
    commit_state::Symbol          # :live | :pending | :aborted
end
```

- `PromiseForm(db; pending_commit = false)`. AirLang passes
  `pending_commit = true` when it creates a promise inside a transaction.
- `mark_pending_commit!(pf)`, `mark_committed!(pf)`, `mark_aborted!(pf)`.
- `:pending`: `isready` and `getindex` raise `UncommittedPromise`; `put!` and
  `fail!` are still allowed (delivering inside the creating transaction is
  legitimate and stages the write).
- `:aborted`: `isready`, `getindex`, `put!`, and `fail!` raise `AbortedPromise`.
- `:live`: exactly today's behavior.

Deliberate departure: `Base.isready` raising is unusual, but a caller that
reacts to `false` by waiting would otherwise deadlock on a promise that can
never exist. AirLang maps both exceptions to
`(error :uncommitted-promise …)` / `(error :aborted-promise …)`.

A promise reloaded by id is always `:live` (a committed row exists). An
uncommitted promise has no id lookup path: `get_promise` finds no row, and
`load!` must not claim `persisted = true`.

Caveat to document: if the handle is evicted from the cache and reloaded
*while* its creating transaction is open (only possible with no strong
reference to it), the new object is `:live`. In practice the creating code
holds the handle, so this cannot occur; note it rather than add a
process-global table.

## D2. Owner/ACL metadata on actors, promises, and resources

### Current

`form_current` has `metadata`; `form_actor_current`
(`src/database.jl:55-61`) and `resources` (`src/database.jl:44-51`) do not.
`metadata` is defined only for `VolatileForm` (`src/volatile.jl:100-112`), and
it loads the payload. There is no way to give an actor, promise, or resource an
owner.

### Proposed

- `form_actor_current` gains `metadata JSONB`;
  `_UPSERT_ACTOR_SQL`/`_UPSERT_ACTOR_CURRENT_SQL` take it.
  `ActorForm` gains a `metadata::Union{Nothing,Form}` field,
  `ActorForm(db, value; history = true, metadata = nothing)`, and
  `metadata(::ActorForm)`.
- `form_promise` gains `metadata JSONB` (D1); `promise_ensure` carries it.
  `metadata(::PromiseForm)`.
- `resources` gains `metadata JSONB`; `_UPSERT_RESOURCE_SQL` and
  `_SELECT_RESOURCE_SQL` handle it; `ExternHandle` gains
  `metadata::Union{Nothing,Form}` with a lazy metadata read;
  `metadata(::ExternHandle)` and `metadata(::FormExtern)`.
  `_stage_resource!` carries the metadata; `chmod!`-style metadata-only edits
  use a separate `_stage_resource_metadata!`.
- `metadata(x)` for every kind returns `nothing` when unmanaged. AirLang's
  `_can` already treats `nothing` as unrestricted, preserving behavior for
  values created before this change (and for ephemeral externs, which have no
  row — see below).

Ownership is fixed at creation in the metadata blob; ACL edits are ordinary
metadata writes. The upsert sets `metadata = EXCLUDED.metadata` (as
`form_current` does today) so an ACL edit is persisted with the next write; a
metadata-only edit is staged explicitly.

### Externs without a row

An extern that has never been written to the database (e.g. a regex value
created in memory) has no `resources` row and therefore no metadata. It is an
ordinary value, like a string: unrestricted, and it cannot be shared across
users except by being stored. Once persisted, the resource row carries the
owner and is subject to the same checks as a volatile. State this in the
docs: **only database-backed externs are permissioned**.

## D3. Metadata-only reads

### Current

`_SELECT_CURRENT_SQL` fetches `payload, metadata, history` in one query
(`src/database.jl:128-129`), and `metadata(vf)` calls `load!`
(`src/volatile.jl:100-112`). So every permission check reads and decodes the
payload before it can decide whether the caller may read it. The same pattern
applies to actors (`_SELECT_ACTOR_SQL`), promises (`_SELECT_PROMISE_SQL`), and
resources (`_SELECT_RESOURCE_SQL`).

### Proposed

Add metadata-only queries and make `metadata` use them:

```sql
SELECT metadata, history FROM form_current WHERE form_id = $1::uuid;
SELECT metadata, state FROM form_promise WHERE promise_id = $1::uuid;
SELECT metadata FROM form_actor_current WHERE actor_id = $1::uuid;
SELECT metadata FROM resources WHERE type = $1 AND id = $2;
```

`metadata(x)` fills only the metadata slot and does **not** mark the payload
loaded; `load!` remains payload-only. A caller that reads metadata and then the
payload pays one extra round trip on the first read; that is the cost of
checking before reading, and it is the point.

Acceptance: a metadata read issues no payload query and never decodes the
payload (test with a payload that would fail to decode if fetched).

## D4. Migration

- Bump `_SCHEMA_VERSION` (`src/database.jl:11-13`) from `"5"` to `"6"`. The
  existing policy refuses an older database at open
  (`src/database.jl:445`); keep it. `CREATE TABLE IF NOT EXISTS` cannot add
  columns, so an in-place `ALTER TABLE` migration would be needed to preserve
  data; not recommended pre-release, but note it as the alternative if the
  maintainer wants to keep a live database.
- `MemoryDatabase` must mirror everything:
  - `actorvals::Dict{UUID,NTuple{2,Any}}` → `(value, history, metadata)`;
  - `promisevals::Dict{UUID,Union{Nothing,Form}}` → a small record with
    `state`, `value`, `error`, `metadata`;
  - `resources::Dict{Tuple{Symbol,Symbol},Vector{UInt8}}` →
    `(data, metadata)`;
  - `store` already holds form metadata.
- Update the docstrings at `src/ref_forms.jl:95-101,145-183` to describe the
  four promise states and the CAS rule.

## D5. Optional / later

- **History and versions API.** The rows already exist in `form_history` and
  `form_actor_history`. Add read-only `form_versions(db, id)`,
  `form_at_version(db, id, v)`, and `form_at_time(db, id, t)`. AirLang's
  `(history vf)` currently returns the *flag*, not the versions; rename the
  flag accessor when this lands.
- **Scalar types.** Time/instant, UUID, and BigInt/Rational/Decimal (the last
  is already deferred because `FormLeaf` is Int64/Float64/ComplexF64). None of
  these block the process model; air can carry epoch seconds as a float and ids
  as strings today.

## D6. Explicit non-goals

- Multi-process coherence, cross-writer CAS or version conflict detection,
  writer leases, global commit sequence numbers, change feeds for wake-ups,
  cross-database links, and durable/claimable jobs (a table with lease and
  attempt columns).
- Synchronous durability or any change to the delayed-write commit model.
- Permission *enforcement* inside AirDB. AirDB has no caller identity; it
  stores and exposes metadata. AirLang checks.

## Evidence (verify before changing)

- `src/database.jl:11-13` — schema version.
- `src/database.jl:15-94` — DDL and drop list.
- `src/database.jl:96-173` — form/actor/promise/resource SQL.
- `src/database.jl:440-455` — schema-version check at open.
- `src/actor.jl:50-75` — `WriteBatch` fields.
- `src/actor.jl:136-152` — `_stage!`.
- `src/actor.jl:188-214` — `_receive!`.
- `src/actor.jl:275-344` — `_write_batch!`; `:300-303` is the ensure bug,
  `:329-331` the promise updates.
- `src/ref_forms.jl:95-184` — promise creation, load, read, deliver.
- `src/ref_forms.jl:186-215` — promise/extern reference tracking.
- `src/volatile.jl:100-112` — `metadata` loads the payload.
- `src/externs.jl:526-660` — `reserve`/`reserve_read` and resource staging.
- `src/types.jl:122-150` — `ExternHandle`/`FormExtern`.
- `src/types.jl:212-245` — `ActorForm`/`PromiseForm`.
- `src/memory.jl:14-58` — `MemoryDatabase` fields.

## Acceptance tests

1. **Promise states.** Create → `pending`; deliver → reload shows
   `delivered`; fail → reload shows `failed` and `take` throws the stored error.
2. **Ensure bug.** Deliver a promise that is never stored in any form and then
   `sync`; reload by id and see the value. (Fails today.)
3. **Uncommitted promise.** A `PromiseForm(pending_commit=true)` raises
   `UncommittedPromise` on `isready`/`getindex`; `mark_committed!` makes it
   readable; `mark_aborted!` makes every read/deliver raise
   `AbortedPromise`.
4. **Metadata.** Owner/ACL survive a reload for a volatile, actor, promise, and
   resource; `metadata` on an unmanaged value returns `nothing`.
5. **Metadata-only read.** Reading metadata does not decode the payload.
6. **Memory parity.** All of the above pass with `MemoryDatabase`.

## AirLang follow-on (after this lands)

- `_bi_task`/`_bi_promise` create promises with `pending_commit = true` inside a
  transaction; AirLang's `_tx_boundary` calls `mark_committed!` on success and
  `mark_aborted!` on abort. `(await p)`/`(get p)` surface the uncommitted and
  aborted errors.
- Spawn-at-commit: `_tx_boundary` starts deferred tasks only after a successful
  commit, after AirDB has enqueued the write batch.
- Failures: `_TASK_ERRORS` is removed; a failed task calls `Air.fail!` with its
  error form; `(get p)` raises like `(await p)`; `(failed? p)` and
  `(promise-error p)` inspect.
- Permissions: `send`/`reset!`/`get` on actors, `deliver`/`get`/`await`/`ready?`
  on promises, and extern data access go through `_check!`; `permissions`,
  `chmod!`, and `chown!` are extended from `VolatileForm` to every kind, using
  the metadata-only reads of D3. Default owner-only ACLs, with `air` bypassing.
- File I/O is air-superuser-only: `read-file`, `write-file`
  (`AirLang/src/builtins_io.jl:38,46`) and `load-air`
  (`AirLang/src/lib.jl:156`) currently have no gate.

## Out of scope

Multi-process air, distributed references, durable jobs, and synchronous
durability.
