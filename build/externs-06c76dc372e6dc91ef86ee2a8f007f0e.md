# Extern objects

This document summarizes the architectural strategy for managing ephemeral, host-level execution resources (such as promises, tasks, and sockets) as extern types within Air, and how they interact with the persistence layer (`AirDB.jl`).

## 1. Core Architecture & In-Memory Management
* **Extern Types:** Low-level system resources and concurrency primitives are implemented as specialized Julia types managed directly by the host language's garbage collector (GC).
* **First-Class In-Memory Representation:** In-memory Air forms can seamlessly contain live Julia object references as leaf nodes, allowing operations like `(await p)` to execute with native performance.
* **Extensibility:** Extern types are defined statically at startup via user-defined Julia methods implementing the Air extern protocol.

---

## 2. Serialization Schema (`AirDB.jl` Boundary)
Because active sockets and in-flight tasks cannot be serialized as raw pointers to PostgreSQL, extern objects participate in a clean serialization protocol mapped to structured S-expressions in JSONB.

* **Serialized Form Shape:** 
  ```air
  (extern :type payload)
  ```
* **Deserialization:** When loaded from `AirDB.jl`, the runtime dispatches the form back through the registered startup extern methods to reconstruct the appropriate state or wrapper.

---

## 3. Persistence Strategy: Tombstones on Commit
To avoid complex, race-prone asynchronous database row-mutations for in-flight tasks:

* **Ephemeral Resource Rule:** Active, unresolved execution primitives are treated strictly as runtime execution state rather than permanent domain state.
* **The Tombstone Approach:** When an active or pending extern object (such as an unfulfilled promise) hits the database serializer during a write/commit, it is immediately converted into an inert, serializable **tombstone**:
  ```air
  (extern :promise :abandoned)
  ```
* **Behavior on Recovery:** If application code encounters an expired or abandoned extern tombstone post-recovery, it fails cleanly with a structured runtime error (e.g., `:extern-expired`) rather than hanging indefinitely.

---

## 4. Database-Backed Reference Forms

The concurrency primitives that *can* be persisted are not externs at all: they
are AirDB reference forms with their own serializations, and AirLang exposes one
constructor per kind.

| air form | AirDB form | JSON |
| --- | --- | --- |
| `(actor value history=…)` | `ActorForm` | `"!<uuid>"` |
| `(promise)` | `PromiseForm` | `"~<uuid>"` until delivered, then its value |
| `(delay body…)` | `DelayForm(:air, cell)` | `{"delay": ":air", "form": "@<cell>"}` |

* **Actors.** `(send a fn)` calls `fn` with the current value and persists the
  result; inside a transaction the send is deferred to commit, and `(sync)`
  flushes. The send captures the caller's lexical names like a task (inner
  binders shadow) and keeps the sender's namespace layers and `val` bindings.
  `(reset! a value)` replaces the value directly. Every update is
  written to `form_actor_current` (plus `form_actor_history` when `history` is
  on, fixed at creation).
* **Promises.** `(deliver p v)` fills a promise once; `(get p)`/`(await p)`
  read it (blocking outside a transaction, raising inside one unless it is
  already delivered) and `(ready? p)` tests it. A promise stores a row and
  always encodes as a link, whether it is pending or delivered, so a reader
  waits on the same promise rather than on a copy of its value.
* **Delays.** The registration registry (`register_delay`) is keyed by a type
  name, and the loader sees only the serialized form. AirLang registers `:air`
  once at startup; its serialization is a `VolatileForm` *cell*. The cell first
  holds a tagged thunk — the substituted body plus the captured namespace path,
  active `using` layers, `val` bindings, `@` root, and `.env` — and is replaced
  by the computed value on the first force. That is what makes the cache durable:
  a fresh process that opens the database finds the value already computed and
  never runs the body. The `Env` the force runs in is installed task-locally for
  the dynamic extent of the call (the loader has no environment argument), and
  the body runs as the user who forces it, like a stored `def`. A value the
  database cannot hold, or a user without write access, is simply not cached;
  the delay still yields the value. Printing and encoding never force a delay,
  and a body that forces its own delay raises a catchable
  `(error :internal "a delay cannot force itself")`.

## 5. `bytes`: an immutable extern

Most externs wrap a live resource and must die with the process. `bytes` is the
opposite: an opaque, **immutable** octet string that persists, compares by
content, and prints opaquely.

```air
(bytes "hello")            ; from a string's bytes
(bytes-of (104 105))       ; from a sequence of integers
(bytes-length b)           ; the octet count
(bytes-string b)           ; the raw octets as a string
(bytes-index b 1)          ; one octet as an integer (1-based)
(bytes-slice b 2 3)        ; a sub-range, as bytes
(bytes? x)
```

Because it is immutable and its equality is structural, two `bytes` values with
the same contents are the same air value: `eq?` and `hash` agree, so it works as
a memo key and in a keyed table. Its registration supplies `serialize`
(`write(io, data)`), `deserialize` (`read(io)`), `equal`, and `hash` to
`register_extern`, so a database stores and reloads the raw octets. It does
**not** round-trip through `to-json`/`from-json`: those write an unnamed extern
as an opaque marker, and reading it back yields a `DeadExtern`. Move a payload
through a database or an SFTP transfer instead. Printing is opaque —
`#<bytes 1048576>` — so a file-sized payload never floods a result or a log.

It is the value a transferred file becomes and the value a local file is read
back from: the SSH subsystem ([SSH access](ssh.md)) turns a remote path into a
namespace path and a file into a `bytes` val.

## 6. `table`: an immutable extern

A [`table`](tables.md) is the second immutable, content-valued extern. It holds
persistent columns (`FormSeq` views over Air's `PVector`s), an ordered name
list, a per-column `_ColumnMeta` (type and NA marker), a row count, and an
optional index dictionary. The registration supplies `serialize`, `deserialize`,
`equal`, and `hash`, so a committed table reloads with its schema and NA markers
intact, and `eq?`/`hash` agree on tables whose columns are in a different order
or whose cells are equivalent.

Like `bytes`, a table is stored faithfully in a database but does not survive
`to-json`/`from-json` text; for interchange use CSV/TSV or a database.

**Status of §3.** The tombstone scheme is not what the runtime does today: an
unnamed extern is written without an id and reads back as a `DeadExtern` that
prints `#<extern :type (expired)>` and raises `(error :extern-expired :type)`
when touched. A `task` returns a database `PromiseForm`, so its promise
survives a round trip (as a link until delivered); the running task itself is a
process item and cannot be serialized, so a promise whose task never delivered
is simply never delivered.
