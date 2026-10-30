# Databases

A process starts with one private in-memory database holding the air root
(`.air`, `.sys`, `.lib`, `.main`, and the system user records). `(open-airdb
name opts…)` opens an AirDB database, roots a namespace at `name` in it, and
attaches `@` to that root for the calling task. From Julia, `Env(db = d)` selects
the **process** database — the store behind `.`, `.main`, and a system user's
home — and does not change the database of any opened root:

```air
(open-airdb .work memory=true)      ; an in-memory database (as in the tests)
(open-airdb .work dbname="air" user="air" host="localhost" port=5432)
(open-airdb .work url="postgresql://air@localhost/air" create=true)
```

| option | meaning |
| --- | --- |
| `memory=true` | a fresh in-memory database |
| `url=` / `conninfo=` | a libpq connection string, passed through verbatim |
| `dbname=` `user=` `host=` `port=` `password=` `sslmode=` | a PostgreSQL connection (`host` defaults to `localhost`, `port` to `5432`) |
| `create=true` | create the schema (`create_database`); the PostgreSQL database itself must exist |
| `create=false` | open an existing schema only |
| (absent) | try to open, then create |

A bare `name` is relative to the current namespace (so `air`'s `(open-airdb
work …)` roots `.main.work`); an explicit `.path` or `@.path` is absolute.
Opening requires `write` on the containing namespace, and a root may not be
placed over an existing namespace or where a database is already open. Unless
the opener is `air`, opening writes the opener's user record into the database;
an admin's status carries over. A newly created root is owned by its opener.

A namespace at or under an opened root lives in that database (the
longest-prefixed open root wins), so `(namespace .work.util …)` is durable
there. `@` addresses the same root: with `.work` open, `@.util.f` is
`.work.util.f`. Opening a database inside another (`(open-airdb .work.sub …)`)
creates a distinct database that owns the namespaces at or under `.work.sub`,
with its own users and permissions.

Database users are separate from system users. `(create-user :bob)` while
attached writes `@.user.bob` into the attached database; `(users)` lists that
database's users (`air` included); and a permission map in a database may name
only one of its own users (or `_`), so `(chmod! .work read=(mallory=true))`
raises a bad-user error. A user of another database is likewise not a valid
principal.

Because namespaces in a database are persisted as linked volatiles, a value
assigned there must be **storable**: it may not embed a volatile from another
database. Storing `.main`'s mutable or the `.air` namespace raises
`(error :un-storable target)` instead of writing an unresolvable link. `mut` inside a
database namespace creates its mutable in that same database.

`(close-airdb name)` flushes and closes the database, removes its root namespace
from the parent, and detaches `@` (returning it to `.`) when it pointed at that
root. Closing a database also closes any database rooted beneath it. From Julia,
`open_airdb!(env, path, db)` roots an already-opened database — the way the
tests use `MemoryDatabase` — and `close_airdb!(env, path)` closes it.

## The database of a form

A form's database is the database of the **namespace it is written in**, never
an ambient store chosen by the environment. The system namespaces (`.`, `.air`,
`.sys`, `.lib`, `.main`, and a system user's home) live in the process database;
a namespace at or under an opened root lives in that root's database. `mut`,
`logic-set`, the named-form operations, `form-at`, and `from-json` all follow
this one rule, so a mutable made in `.main` belongs to the process store even
while `@` points elsewhere, and storing it in a database namespace raises
`(error :un-storable …)`.

## Named forms

AirDB registers a name for a volatile, giving a form a durable, database-wide
handle:

```air
(named-form :counter create=true value=3)   ; create and name a new volatile
(named-form :counter)                       ; the same volatile
(value (named-form :counter))               ; 3
(named-form :counter create=false)          ; raises when the name is absent
(named-form :counter create=naught)         ; naught when the name is absent
(named-form :alias create=true value=(named-form :counter))  ; an alias
(name-form! :other (named-form :counter))   ; repoint an existing name
(named-forms)                               ; (alias=(mut 3) counter=(mut 3) …)
```

A name may be a keyword, a raw symbol, or a string; `:counter` and `"counter"`
agree, and the leading colon of a keyword is stripped, so `(named-form
:counter)` registers `counter`. Names beginning `air/` are reserved for air's
own bookkeeping and neither appear in `named-forms` nor may be created.
`value=` may be an ordinary form or an existing volatile of the same database,
in which case the name becomes an **alias** for it (no new form is made). A
created form records its history unless `history=false`. The name table is
transactional: a creation or repointing joins the enclosing transaction, so it
is retried or discarded with it, and a failed transaction leaves no name behind.

Creating a name publishes an entry from the current namespace, so it needs
`write` there (and a user record in a database); a lookup needs `read` on the
named form. A new named form is owned by its creator with the default owner-only
ACL. `named-forms` lists the names the caller may read. `name-form!` may claim a
free name with `write` in the namespace; repointing an existing name instead
needs `write` on the form currently named (or on the database root, for a
database administrator).

(logic-sets-namespaces-and-facts)=
## Logic sets, namespaces, and facts

A **logic set** is a named volatile holding facts, rules, and their provenance.
There are two ways to reach one.

A **standalone set** is named explicitly: `(logic-set :s)` is `(named-form :s)`
whose value has the logic-set shape, and every operation takes it as its target.
Its ACL is the old mapping — mutating the set (`assert`, `retract`, `revise`,
`revise-fact`, and `logic`) needs `write`, and every query (`facts`, `rules`,
`why`, and `query`) needs `read`, as does opening the set by name.

Every **namespace is implicitly a logic set**. `(assert .foo (p 1))` writes into
the set of `.foo`; with no target, `(assert (p 1))` writes into the current
namespace, so a bare `assert` inside `(namespace .foo …)` or while `.foo` is
current edits `.foo`. `facts`, `rules`, `why`, `query`, `revise`, `retract`,
`revise-fact`, `defrule`, and `ingest` accept a namespace the same way. The set
is stored as the hidden named form `air/logic/<path>` (`air/logic` at the root)
in the namespace's own database, so it persists, shares the namespace's access
control, and never appears in `named-forms`; `air/` is reserved, so it cannot be
opened by name. The set is created lazily by the first fact or rule write; a
namespace with no set reads as an empty set, and a read never creates one.

```air
(namespace .app)
(assert .app (depends :app :lib1))       ; creates air/logic/app
(assert .app (rule (depends ?x ?y) :> (needs ?x ?y)))
(facts .app)                             ; => (' (depends :app :lib1) (needs :app :lib1))
(query .app (needs ?x ?y))               ; => ((x=:app y=:lib1))
```

`(facts target)` and `(rules target)` return one **held list** of the facts or
rules — `(' (depends :app :lib1) (needs :app :lib1))`, and `(')` for an empty
set — whose elements are the facts themselves, unheld, so the list is ordinary
data that a `def` cannot rewrite while the hold keeps evaluating it inert.

The four fact/rule permissions gate these operations on a namespace
(`readfact`/`writefact`/`readrule`/`writerule`; see
[permissions](permissions.md#permissions)); a `rule` form asserted or retracted needs the
`…rule` permission, and `why` needs both read permissions.

`(query [target] pattern…)` returns every distinct satisfier of a rule-like
condition block as a plain list of maps, in first-seen order: `(query .app
(depends ?x ?y))`. The patterns are the rule engine's conditions — an implicit
conjunction, `(not p)` for negation, and infix `and` — but there are no
instructions and no accumulators. A pattern whose head is `rule` searches the
rule universe; every other pattern searches the facts. A satisfier with no
bindings is `(naught)`, and no satisfier is `naught`. `(defrule conditions…
instructions…)` builds a `(rule …)` form from its raw arguments and asserts it
into the current target, returning the rule. `(ingest source)` copies a source's
base facts and rules into the current target in one transaction and saturates it,
so derived facts are rederived rather than copied; it checks exactly the
permissions it uses, all before mutating anything. Live propagation from a source
to its dependants is not implemented (`depend` is a tombstone) and is tracked in
`TODO.md`.

Every operation outside a `logic` block is its own transaction, so separate
`assert`s commit independently; `(logic target body…)` collects the body's edits
and applies them as one event, and any enclosing `(tx …)` also joins them.

## Sync and status

`(sync)` blocks until every write committed before the call has reached the
database; `(sync target)` targets a namespace or volatile instead of the current
namespace's database. It is a **barrier**, not a drain: it queues a flush behind
the writes already scheduled, so writes that other tasks schedule afterward do
not delay it, and the sequential writer cannot be starved by continuing
activity. `(status)` returns `(pending=N error=naught)`: the number of updates
scheduled but not yet written, and the last writer error. Both are also
`.air.sys.sync` and `.air.sys.status`.

Air defers an actor message sent inside an open transaction until that
transaction commits, so a `sync` placed inside a `namespace`, `load-air`, or
other transaction cannot include that transaction's own writes. It flushes
every write already scheduled and returns; the block's writes are scheduled when
the block commits, so call `(sync)` outside the block to make them durable. A
`MemoryDatabase` has nothing to flush, so its `sync` returns at once.

## Form identity and JSON

`(form-id volatile)` returns the form's UUID as a string. `(form-at id)` returns
the volatile with that id in the current database without loading its body; when
no such form is in the database, reading the handle raises `(error
:form-not-found id)`. `(loaded? volatile)` reports whether the body has been read into memory,
and `(history volatile)` whether the form records its history.

`(to-json value)` encodes a form as JSON text and `(from-json text)` decodes it
in the current database. The codec is AirDB's: numbers and booleans are JSON
scalars, `naught` is `null`, a string is a JSON string carrying its reader quote
(`'hi`), a keyword is a JSON string carrying its colon (`"::x"`), a form is the
pair `[sequence, map]`, and a volatile is the link string `"@uuid"`. Links are
never expanded, so a cyclic structure encodes; `from-json` resolves each link
through the current database, and a link to a missing form raises
`(error :form-not-found id)`. An extern encodes by type and id (`{"extern": …,
"id": …}`) and reads back through the database's resource registry. The
database reference forms have their own encodings: an actor is `"!uuid"`, a
promise is `"~uuid"` until it is delivered (then it encodes as its value), and a
delay is `{"delay": ":air", "form": <the cell's link>}` — never forced by
encoding. A form bound for a database may embed only volatiles, actors, promises,
and delays of that same database; anything else raises
`(error :un-storable target)`.

Printing is cycle-safe on the same terms: a volatile that contains itself prints
the inner occurrence opaquely as `#<volatile uuid>` instead of recursing.

JSON has no infinity or NaN, so AirDB writes a non-finite float as a marked
string: `Inf` is `"#inf"`, `-Inf` is `"#-inf"`, and `NaN` is `"#nan"`. The `#`
marker cannot be confused with a string (`'`), a symbol (`:`), or a link (`@`),
and a literal string that looks like one is still a string, so `(to-json inf)`
is the JSON string `"#inf"` while `(to-json "#inf")` is `"'#inf"`. Such a value
flushes to any database, including the `.air` constants `inf` and `nan`.

The rest of the numeric tower has a marker too, so an exact value never degrades
on the way through JSON: a `BigInt` is `"#big:…"`, a rational `"#rat:n/d"` (or
`"#bigrat:n/d"`), and a `BigFloat` `"#bigfloat:<bits>:…"`. See
[Numbers](numbers.md).
