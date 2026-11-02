# Mutability and transactions

Forms are immutable, but a form may contain a **mutable**: a shared reference
synchronized across threads, like Clojure's `ref` and implemented by AirDB.
A mutable is a value like any other — it can be stored in a form, in a
namespace, or in a database — and every write to one happens in a transaction.
This chapter covers creating and editing a mutable, its filter and finalizer
hooks, watches, and the `tx` and `sandbox` block forms.

## Creating and reading

`(mut value filter=… finalize=…)` creates a mutable holding `value`.
`(value m)`, `(get m)`, and `(get m 0)` all read it; a mutable also **vanishes**
on a `get` path, so `(get (a=<mutable>) :a :b)` reads through it as if the
mutable were not there.

```air
(let (m=(mut 3)) (+ (get m) 1))     # => 4
```

`mut?` tests one. A mutable prints as `#<volatile …>`, and two reads of the
same mutable are the same object (`same?`); the value inside participates in
`eq?` only through the mutable's identity (see [Equality](data-model.md#equality)).

## Writing

Every operation that **edits** a mutable in a transaction ends in `!`;
`mut` does not, because it creates rather than edits a volatile.

```air
(set! m 4)                     # replace the value
(set! form 2 :a 4)             # edit the deepest mutable on the path
(swap! m inc)                  # replace with (inc old), returning the new value
(swap! m + 10)                 # (fn value args…) in one transaction
(alter! m inc)                 # an alias of swap!
```

`set!` with more than two arguments walks a path and edits the deepest mutable
on it. `swap!`/`alter!` applies its function to the current value in a single
transaction and returns the new value, so a lost update is impossible. `set!`,
`swap!`, `alter!`, `chmod!`, and `chown!` are the volatile edits; `reset!` is
reserved for actors (see [Actors](concurrency.md#actors)).

## Filters and finalizers

`(mut value filter=… finalize=…)` attaches Air's filter and finalizer. Both are
kept as written and stored in the mutable's metadata, so they survive a reload.
A replacement rule `(?x -> …)` is applied as a function; any other form is
evaluated with `_` bound to the value, so `filter=(if (_ < 0) 0 _)` clamps at
zero.

A **filter** runs on every write (including the value passed to `mut`) and its
result is stored. A **finalizer** runs after the body of the writing transaction
and before it commits, and its result replaces the value. Because the finalizer
runs in the transaction's finalizing state, volatiles cannot be written from it.
`(set-filter! m fn)` and `(set-finalize! m fn)` replace them later (`naught`
removes one); `(set! …)` and these two are the ways to change a mutable.

## Watches

`(watch m key fn)` registers `fn` to run as `(fn key m old new)` at the end of
the body of the outermost transaction that writes `m`, before it commits:

```air
(watch m :log (part println "changed:"))
(set! m 10)                    # => the watch runs once, before the commit
(unwatch m :log)               # remove one watch
(watches m)                    # the held watch tables
```

The watch runs as the user who registered it, in the namespace where it was
registered, and **once per mutable per transaction** (with the transaction's
final value). Its writes are part of the same transaction, so a retry reruns
it; a `raise` from it aborts the transaction, while a `throw` is deferred like
any throw caught outside (see [Errors and blocks](errors.md)). Watches are
stored in the mutable's metadata and survive a reload; a watch function must be
self-contained (a replacement rule, not a code fragment using `_`). Installing a
watch needs `watch` and `read` on the mutable; `watch` is owner-only by default.

## Transactions

`(tx body…)` evaluates its body inside one STM transaction and yields its last
value. It accepts the full `do` block grammar — `:let`/`let=`, `catch=`/`throw`,
`except`, `handle`/`notify`, and `finally` — all prepared and run inside the
transaction.

Air's transactions **join rather than nest**: `tx` joins an open transaction, so
the outermost `tx` is the commit/rollback boundary (`namespace`, `load-air`, a
logic-set edit, and `set!` are transactional too). An error that escapes it
aborts every write made since it began and propagates, even if an outer block
catches it; an error caught by the tx's own `except` commits. A throw caught by
the tx's own `catch=` commits. A throw that escapes the tx to an outer `catch=`
is deferred until after the commit: watches run as usual, the transaction
commits, and the signal is rethrown (a retried attempt discards it). Watches run
at the end of that outermost transaction body, so their writes commit or roll
back with it.

`(sandbox body…)` evaluates the same block grammar in a transaction that is
**never committed**: it yields the body's value and discards every write, so a
`def`, `val`, `mut`, fact, rule, or namespace created inside it is gone
afterwards. It is the way to try something out — a rule you are not sure about,
a namespace edit you want to test — without touching the namespace. Because Air's
transactions join rather than nest, the body runs in a transaction of its own on
a private task (the caller waits for it), which means it cannot abort a
transaction around it and it reads committed state rather than an enclosing
transaction's staged writes. A `throw` still reaches an enclosing `catch=` and a
`notify` an enclosing `handle`; side effects outside the database (a file write,
`open-airdb`) are not undone.

`(sync)` waits for committed writes to reach the database, and `(status)` reports
the pending write count; see [Sync and status](databases.md#sync-and-status).

## Mutables and databases

A mutable belongs to the database of the **namespace it is created in**: `mut`
in `.main` makes a process-store mutable, while `mut` in a namespace under an
opened root makes one in that root's database. A value assigned in a database
namespace must be **storable**; embedding a mutable from another database raises
`(error :un-storable target)`. This is the same rule for every reference form
(see [Databases](databases.md#the-database-of-a-form)).

Two related values look like mutables on the access path but are not written
with `set!`: a **delay** is a database-backed value computed once, and an
**actor** is a sequential worker written with `send`/`reset!`. Both are
described in [Tasks, delays, actors, and promises](concurrency.md).

## Where to go next

* [Errors and blocks](errors.md) — the clause grammar `tx` and `sandbox` accept.
* [Databases](databases.md) — persistence, named forms, and `sync`.
* [Namespaces](namespaces.md) — the namespace a mutable is stored in.
