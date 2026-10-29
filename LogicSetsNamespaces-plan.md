# Preliminary plan: implicit namespace logic-sets, fact/rule permissions, `query`/`defrule`/`ingest`

Status: preliminary implementation plan. Not yet started. Standalone logic sets
(`(logic-set :s)`) keep their current behavior; `depend` is deferred.

## Context

Today a logic set is a separate named volatile and a namespace holds only
`def`/`val` entries. The user wants namespaces to *be* logic sets implicitly:

- `assert`/`retract`/`revise`/`revise-fact` with no explicit target use the
  current namespace's set (or the set named by the enclosing `(logic s …)`
  block). The set is created lazily on the first fact or rule write; a namespace
  with no set behaves as an empty set.
- Namespaces gain four permissions — `readfact`, `writefact`, `readrule`,
  `writerule` — segregating reads/writes of facts from rules, and facts/rules
  from namespace entries.
- `(logic s body…)` accepts a namespace as well as a logic-set handle.
- Operations outside a `logic` block are individually transactional; only a
  surrounding `tx` makes a group atomic. `(logic …)` remains one transaction.
- `(query …)` returns the satisfiers of a rule-like pattern block.
- `(defrule …)` asserts `(rule …)` into the current target.
- `(ingest source)` copies base facts and rules from a source into the current
  target.
- `use`/`using`/`import` are untouched: they never intersect the logic-set
  aspect. `depend` (live propagation) is a later TODO item.

Settled user decisions for this round:

- `query` works over facts *and* rules; mixed pattern blocks are allowed when
  the user holds every read permission involved.
- `why` on a namespace target requires **both** `readfact` and `readrule`.
- `ingest` requires exactly the permissions it uses, but is all-or-nothing: if
  it would copy facts it needs source `readfact` + destination `writefact`; if
  it would copy rules it needs source `readrule` + destination `writerule`; any
  missing permission fails the whole ingest before any mutation. A source with
  no rules (or no facts) needs no rule (or fact) permissions.
- `query` returns a **plain list** of maps, not a held list. The canonicalization
  discussion that follows this plan removes singleton collapse, which makes
  zero satisfiers distinct from one satisfier with no bindings. Do not paper
  over the current ambiguity with a hold.

## Design

### Storage

- A namespace's set is a named form `air/logic/<path…>` in the *same database*
  as the namespace (`_ns_db`), with the root path mapping to `air/logic`. The
  `air/` prefix is already reserved, and `(named-forms)` filters it, so users
  cannot open the set by name; only the namespace-targeted forms reach it.
- Created lazily, inside the transaction of the first write, with value
  `_empty_logic_set()` and metadata `_metadata_form(owner; acl=_perms_acl(owner))`.
  Creation does **not** call `_check_named_create!` (which would demand `write`
  on the *current* namespace); the caller has already checked `writefact`/
  `writerule` on the target namespace.
- An absent set is an empty set for reads; reads never create it.

### Target resolution

Introduce `_LogicTarget`:

```julia
struct _LogicTarget
    ns::Union{Nothing,Namespace}       # namespace target, or nothing
    vf::Union{Nothing,VolatileForm}    # the set (may be unresolved/absent)
end
```

- A raw leading-dot/`@` address path (`.foo`, `@.foo`) or a value that resolves
  to a `Namespace` is a **namespace target**. Require the namespace to exist
  (`_ns_lookup(…; lazy=false)`); do not auto-create namespaces.
- Any other `VolatileForm` is a **standalone logic set** (today's behavior).
- A raw symbol bound in the current scope must be reduced first, exactly as
  `_ns_target_path` does, so `(assert s f)` keeps working when `s` is bound to a
  standalone set.
- Permission mapping: namespace targets check `readfact`/`writefact`/
  `readrule`/`writerule` on `ns.vf`; standalone sets map those onto `:read` /
  `:write` (unchanged semantics).
- The current namespace is `_context(env).ns` (already used by `_write_ns`).
  Bare operations use the enclosing `logic` block's target when there is one,
  else the current namespace.

### Permissions

- `_PERM_NAMES` gains `:readfact, :writefact, :readrule, :writerule`;
  `_perms_acl(owner)` grants all four to the owner, and
  `_world_read_exec_acl` grants world `readfact`/`readrule` (so `.air`/`.lib`
  facts and rules are readable like their entries).
- `chmod!`, `chown!`, `permissions`, `_acl_form`, and `_meta_acl` pick the new
  names up mechanically from `_PERM_NAMES`.
- Compatibility: in `_can`, a missing fact/rule permission in an *old* ACL
  falls back to `read`/`write`. New ACLs always contain the four keys, so the
  fallback only affects metadata written before this change.
- The owner shortcut in `_can` already grants everything; `air` bypasses.

### Operation → permission

| operation | namespace perm | standalone perm |
|---|---|---|
| `assert`/`retract` a rule form | `writerule` | `write`. |
| `assert`/`retract`/`revise`/`revise-fact` a fact | `writefact` | `write` |
| `facts`, fact patterns in `query` | `readfact` | `read` |
| `rules`, `rule`-headed patterns in `query` | `readrule` | `read` |
| `why` | `readfact` **and** `readrule` | `read` |
| `ingest` source | as used (above) | as used (`read`) |
| `ingest` destination | as used (above) | as used (`write`) |

Only the operation's own permission is checked; there is no implication from
`read`/`write` on new ACLs. Rule side effects fired by an authorized write are
engine consequences and are not re-checked per operation (document this: a rule
runs with the authority of the write that triggered it).

### Atomicity

- Bare ops outside a block: one `_tx_boundary` around *resolve/create set + fire*.
- `(logic target body…)`: one `_tx_boundary` at the end around create + fire of
  the collected ops; reads in the body see the pre-block state.
- `query`/`facts`/`rules`/`why` are pure reads and never fire.
- Inside an outer `tx`, all of these join that transaction.

### `query`

- Parse: if argument 1 resolves to a namespace or a logic-set handle, it is the
  target; otherwise every argument is a pattern. With no explicit target use the
  active `logic` block's target, else the current namespace.
- Split the pattern block with `_flatten_cond!` into positive and negated
  patterns (same grammar as a rule's conditions: implicit conjunction, `not`,
  infix `and`, guards).
- Refactor `_join_all`/`_join_step!` so the fact universe is chosen **per
  pattern**: a positive or negated pattern whose head is `rule` iterates the
  rule list; everything else iterates the fact list (base + derived). This makes
  mixed blocks work with no new join machinery.
- Dedupe satisfiers by their binding map (build the answer map once and use a
  `Set{Form}`; maps compare/hash order-insensitively), preserving first-seen
  order.
- Each answer map has `Symbol(":"*name)` keys for every bound wildcard
  (including rest captures); anonymous wildcards bind nothing.
- Permissions: `readfact` if any fact-universe pattern is present, `readrule`
  if any rule-universe pattern is present.
- Return a plain `FormContainer` list (no hold), canonicalized; the pending
  canonicalization change makes `()` vs `(())` meaningful.

### `defrule`

- Special form (raw arguments): build `(rule <raw args…>)` without reducing the
  arguments (rule forms are inert in the reducer, `h === RULE`), then assert it
  through the same path as a one-argument `assert`: the active block's target or
  the current namespace; `writerule` applies. Returns the rule form.

### `ingest`

- `(ingest source)` only; destination is the active `logic` block's target or
  the current namespace. `source` may be a namespace or a standalone set.
- Read the source's `_SET_BASE` and `_SET_RULES` (an absent/empty source is a
  no-op). Pre-check every required permission *before* mutating:
  `has_facts ⇒ source:readfact, dest:writefact`;
  `has_rules ⇒ source:readrule, dest:writerule`. Any failure raises and nothing
  happens.
- In one transaction: ensure/create the destination set, append each base fact
  with reason label `:ingest` (deduplicated), append each rule (deduplicated),
  then saturate. Derived facts are **not** copied; the destination's saturation
  re-derives them. Return `naught`.
- No dependency is recorded; that is `depend`.

### `depend`

- Not implemented. Register a tombstone special/macro name that raises an
  `AirEvalError` pointing at `TODO.md` (matching the `future` tombstone
  convention), and add a `TODO.md` entry describing live propagation: dependency
  edges per namespace, delta propagation on source change, immediate saturation
  in dependants, and cycle handling.

### `_LogicCtx` / firing plumbing

- `_LogicCtx` carries the target instead of a bare `set`; the two-argument forms
  compare targets (`_same_target`) rather than `ctx.set === vf`.
- `_run_program` receives the firing target so a bare `query` inside a rule
  handler targets the set being fired rather than the caller's namespace.
- `_fire(env, value; initial_ops, target)` threads it; `_fire_op(env, vf, op,
  target)` and `_bi_logic` supply it. Only two `_fire` call sites exist.

## Files

- `src/permissions.jl` — permission names/ACLs, `_can` fallback, target check
  helper for namespaces.
- `src/namespaces.jl` — `air/logic` name helpers, lazy set lookup/creation.
- `src/logic.jl` — target type/resolution, permission routing, bare-op targets,
  `_LogicCtx`/`_fire`/`_run_program` threading, `_join_patterns` refactor,
  `query`, `defrule`, `ingest`, `facts`/`rules`/`why` as special forms,
  `depend` tombstone.
- `src/env.jl` — only if a tiny helper belongs there; otherwise no change.
- `test/logic_ns.jl` (new; add to `test/runtests.jl`) — implicit sets on every
  namespace operation, lazy creation, `(logic ns …)` atomicity, permissions for
  all four perms, `query` (targets, mixed patterns, dedupe, guards/negation),
  `defrule`, `ingest` (all-or-nothing permissions, base-only copy, saturation,
  dedupe), `depend` tombstone.
- `test/permissions.jl` — new permission names appear in `permissions`, chmod
  accepts them, default owner-only, world read on `.lib`.
- `test/logic.jl` — unchanged standalone-set behavior (guard against
  regressions).
- `README.md` (§“Logic Sets”, §“Two Rule Systems”, permissions section) and
  `.claude/CLAUDE.md` — document implicit sets, the four perms, `query`,
  `defrule`, `ingest`, the `use` vs `ingest`/`depend` split, and atomicity.
- `TODO.md` — `depend`.

## Verification

1. Canonical suite:
   `export PATH="$HOME/.juliaup/bin:$PATH"; JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()'`
2. Manual scenarios:
   - `(namespace .foo)` → `(facts .foo)` is empty; `(assert .foo (p 1))` creates
     `air/logic/foo` and `(facts .foo)` shows it; a fresh `Env` over the same DB
     still sees it.
   - Bare `(assert (p 1))` at the prompt targets `.main`; inside
     `(namespace .bar (assert (p 1)))` targets `.bar`.
   - `(logic .foo (assert (p 1)) (assert (q 2)))` is atomic: an error in the
     second form leaves neither fact; two bare asserts outside a block commit
     independently.
   - Permission matrix with two users: owner default; `readfact` alone cannot
     write or read rules; `writerule` alone cannot read facts; `why` needs both;
     `ingest` with a partial grant mutates nothing.
   - `query` by namespace, by handle, inside a `logic` block, with a mixed
     pattern block, with negation/guards, with duplicate satisfiers.
   - `defrule` produces exactly the form `(assert (rule …))` would.
   - `ingest` copies base facts and rules, re-derives consequences, ignores
     duplicates, and leaves a source with no logic set untouched.
3. `git -C ~/Code/Air.jl status --short` / `git -C ~/Code/AirDB.jl status
   --short` show no edits (the base-library work belongs to the other agents).

## Out of scope / deferred

- `depend` (live, real-time propagation): TODO only.
- No change to `use`/`using`/`import` or to namespace entry semantics.
- No change to standalone logic-set permissions (still `read`/`write`).
- No Air.jl/AirDB.jl edits (other agents own the base-library proposals).
