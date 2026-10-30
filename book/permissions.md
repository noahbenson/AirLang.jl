(users-homes-and-permissions)=
# Users, homes, and permissions

Air's namespaces are multi-user. A **user id** is a keyword: `:air`, `:alice`,
`:game:bob`. Name segments are `[A-Za-z0-9_-]+` with no leading digit, no
leading `-` followed by a digit, and not the single `_`. A *constituent* id is
exactly `admin:name` (one level; a constituent cannot itself have
constituents). `:air` is the implicit superuser:
it passes every permission check, creates core users, and is the only user that
may change admin status.

`(current-user)` is the task's identity (default `:air`), and `(owner)` is the
owner of the `def` currently executing, else the current user. `(as-user id
body…)` evaluates `body` as `id` for its dynamic extent; authentication is out
of scope, so this is the whole mechanism for acting as another user. `(users)`
lists the users visible to the task — the system users, or the attached
database's users while `@` is set.

```air
(create-user :bob)                       ; :air only
(set-admin :game true)                   ; :air only
(as-user :game (create-constituent :kid)) ; => :game:kid
(as-user :game:kid (current-user))        ; => :game:kid
```

Each user has a **home** namespace, `$`: a top-level `def` run as that user is
written there. System users' records live in `.sys.user.<name>`; database
users' live in `@.user.<name>`. The home is a capability: `$` is reachable even
when the enclosing record is not, and `air`'s `.main` stays private.

(permissions)=
## Permissions

Every namespace and every namespace entry is a volatile whose metadata carries
an owner and an ACL:

```air
(owner=:alice
 acl=(read=(_=true bob=true)
      write=(alice=true)
      exec=(_=true)
      readfact=(_=true)
      writefact=(alice=true)
      readrule=(_=true)
      writerule=(alice=true)
      assume=(game:bob=true)
      hide=(mallory=true)
      watch=(alice=true)
      filter=(alice=true)
      finalize=(alice=true)))
```

Each permission maps user ids to booleans; `:_` means every user. By default the
owner has `read`, `write`, `exec`, the four fact/rule permissions, `watch`,
`filter`, and `finalize`, and nobody else has anything. `air` bypasses every
check, and a core admin has ownership privileges over its constituents' data.
`hide` is a veto: a listed user has no access of any kind. `watch` gates
installing a watch (which also needs `read`); `filter` and `finalize` gate
replacing a mutable's filter or finalizer. `anchor=true` is a per-entry flag
rather than a permission — it forces imports of that entry to be proxies (see
[`using`, `use`, and `import`](namespaces.md#using-use-and-import)).

The four fact/rule permissions govern a namespace's implicit logic set (see
[logic sets](databases.md#logic-sets-namespaces-and-facts)): `readfact`/`readrule` for
`facts`, `rules`, `why`, and `query`, and `writefact`/`writerule` for
`assert`, `retract`, `revise`, and `revise-fact`. A standalone logic-set handle
keeps the older mapping, where those operations need the set's `read` or
`write`.

`(permissions target)` returns the metadata, `(chmod! target read=(…) write=(…)
exec=(…) readfact=(…) writefact=(…) readrule=(…) writerule=(…) assume=(…)
hide=(…) watch=(…) filter=(…) finalize=(…) anchor=…)` replaces the listed
permission maps, and `(chown! target user)` gives the target a new owner. A
`target` is a namespace, a definition (by name or by `(get …)`), or a `mut`.
`chmod!` and `chown!` need `write` on the target.

| operation | requires |
| --- | --- |
| `get`/printing/doc of an entry's body | `read` on the entry |
| calling a `def` | `exec` on its entry (and `read` on the namespace to reach its map) |
| resolving or `bind`ing a `val` | `read` on its entry |
| `def`/`val`/`clear`/`unuse` in a namespace | `write` on the namespace |
| `(namespace ns …)` | `read` on `ns`; writes additionally need `write` |
| `chmod!`/`chown!` | `write` on the target |
| `assert`/`retract`/`revise`/`revise-fact` on a namespace | `writefact`, or `writerule` for a `rule` form |
| `facts`/`rules`/`why`/`query` on a namespace | `readfact`, `readrule`, or both as used (`why` needs both) |
| reading/writing a `mut` | `read`/`write` on the mutable |
| `watch`/`unwatch`/`watches` | `watch` (and `read` for `watch`) on the mutable |
| `set-filter!`/`set-finalize!` | `filter`/`finalize` on the mutable |
| `(open-airdb …)` | `write` on the containing namespace |

A denial is a catchable error object, `(error :permission-denied
:read|:write|:exec|:readfact|:writefact|:readrule|:writerule|:assume target)`,
whose content an `except` clause matches as
`(:permission-denied perm target)`, where `target` is a namespace path or a keyword name. Operations that
filter — `using`, `doc`, `definitions`, namespace printing — treat an
unreadable entry as absent rather than raising, and printing shows the body as
`#<entry …>`.

`(assume body…)` is legal only inside a `def` whose entry grants `assume` to the
current user. It evaluates `body` with `current-user` set to that definition's
owner, so an owner can expose a controlled operation on private data without
granting read or write on the data itself:

```air
(namespace .vault
  (val hidden 41)
  (def (peek) (assume hidden)))
(chmod! .vault read=(_=true) exec=(_=true))          ; the namespace is reachable
(chmod! (get . :vault :peek) exec=(_=true) assume=(bob=true))
(as-user :bob (.vault.peek))      # => 41; bob cannot read hidden directly
```

`(env)` returns the task's environment mapping, and `(with-env mapping body…)`
extends it for the dynamic extent of `body`. Both `.env` and `val` bindings
travel into a `task`; `(task clean=true …)` starts with empty bindings and
an empty `.env` but keeps identity and namespace context.
