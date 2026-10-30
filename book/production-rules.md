# Production rules

This document specifies the RETE-based deductive rule engine (`logic-set`):
the rule form, its instructions, the trigger model, and aggregation/grouping
with `:accum`.

## 1. Overview and Core Philosophy

Air blends symbolic code-as-data structures with deductive rule evaluation. A
rule is a single structured form whose **conditions** are an implicit
conjunction and whose **instructions** say what to derive and what side effects
to run. Consequences are written as explicit `:>` slots, so the engine can
track each derived fact across firings; aggregation is a condition-region
`:accum` declaration rather than boilerplate.

```air
(rule (student class=?c grade=?g)
      :accum (g=:mean)
      :> (average class=?c value=?g))
```

Rules are asserted into a `logic-set` like any other value:

```air
(assert s (rule (parent ?x ?y) :> (ancestor ?x ?y)))
```

## 2. The Rule Form

```
(rule cond1 cond2 … :if g :let (k=v …) :> f :+ f :- f := f …)
```

* **Conditions** are the leading elements up to the first instruction keyword.
  They are an implicit conjunction: `(rule (parent ?x ?z) (ancestor ?z ?y) …)`.
  `(not p)` requires that no matching fact exists. `:accum` may appear anywhere
  in the condition region and applies to the whole conjunction.
* **Instructions** are keyword/argument pairs interpreted in order:
  * `:if cond` — if the reduced condition is not truthy, none of the
    instructions that follow are executed. A `:>` skipped this way counts as
    having produced `naught`.
  * `:let (k1=v1 k2=v2 …)` — evaluate and bind names as in `let`. Bindings
    within one map are parallel; separate `:let` instructions are sequential,
    so later ones see earlier values.
  * `:> form` — a consequence. Reduced with the bindings, it must yield a fact
    or `naught`. Each `:>` has a fixed slot index (its position among the `:>`
    instructions) that identifies the derived fact across firings.
  * `:+ form`, `:- form`, `:= form` — side effects run on an assertion,
    retraction, or revision trigger, respectively. They may call `assert`,
    `retract`, `revise`, or `revise-fact` only with an explicit `reason=`; `:>`
    needs none, because its output is automatically a derived fact.
* At least one condition and one instruction are required. Rules enter a
  logic-set held and are never reduced as code.

### Triggers

The condition decides the trigger; the consequences do not:

| event | when | instructions that run |
|---|---|---|
| assertion | a new combination of conditions matches | `:if`, `:let`, `:>`, `:+` |
| revision | a matching combination persists but a matched fact was revised (or an accumulator group changed) | `:if`, `:let`, `:>`, `:=` |
| retraction | a matching combination stops matching | `:if`, `:let`, `:-` (old bindings) |

In `:=`, the special symbol `_` is bound to a map-form of the revised condition
wildcards to their **new** values.

### Consequence slots and fact events

Facts carry stable identity tokens. Each `(invocation, :> slot)` remembers its
last output, and the old/new pair classifies the event:

* `naught` → fact: assert the fact with derived provenance.
* fact → `naught`: retract it when no other reason holds it.
* two different facts: revise — if the old fact has no other reason, its
  identity moves to the new value; otherwise the old fact stays and the new one
  is asserted.
* equal facts: no event.

Only `:>` outputs drive downstream events. A revised fact keeps its identity,
so a rule matching it fires its **revision** trigger (`:=`) rather than being
retracted and re-asserted. Consequences therefore decide their own fact events;
the condition event only selects which side effects run.

## 3. Reasons

A fact exists while it has at least one reason record:

* a **base** record, labelled with the `reason=` given to `assert` (default
  `naught`) or a keyword; and
* a **derived** record, `(because RULE PREMISE-FACT…)`, one per deriving
  `(invocation, :> slot)`.

Labels may be shared across facts and an assertion is its own record. Retracting
or revising one record leaves the fact present if another reason still holds
it. `(why s fact)` returns every reason. `revise` and `revise-fact` target base
facts only.

## 4. Accumulators and Grouping (`:accum`)

`:accum` lists the **accumulated** variables. Every other bound variable is a
group key.

### A. Vectors

```air
(rule (student class=?c grade=?g)
      :accum (g)
      :> (all class=?c grades=?g))
```

`?c` is a scalar group key; `?g` binds to a vector of the group's grades.

### B. Per-variable aggregation

```air
(rule (student class=?c grade=?g) :accum (g=:mean) :> (average class=?c value=?g))
```

Unannotated listed variables stay vectors. The aggregators are `:min`, `:max`,
`:sum`, `:mean`, `:median`, `:first`, and `:last`.

### C. Row selection with `:take`

`:take (min v)`, `:take (max v)`, `:take :first`, and `:take :last` bind all
listed variables to the selected row's scalars instead of vectors:

```air
(rule (student class=?c grade=?g) :accum (c g :take (max g))
      :> (best class=?c grade=?g))
```

`:take :last` is optimized to track the latest match directly rather than
collecting every value.

### D. Nesting

Repeated `:accum` specs nest. Outer levels partition; only the final level
aggregates or takes, yielding parallel sequences. In

```air
(rule (student class=?c dept=?d grade=?g)
      :accum (d) :accum (g=:mean)
      :> (roll class=?c depts=?d means=?g))
```

`?c` is the scalar group key, `?d` binds to the sequence of departments for that
class, and `?g` binds to a sequence of mean grades aligned with `?d`. An
annotation or `:take` on a non-final level is an error.

### E. Ordering

`:first` and `:last` follow assertion order. A revision preserves a fact's
position in its group.

## 5. Filtering and Thresholds (`HAVING` Equivalent)

`:if` gates the instructions, so an aggregated group can be filtered before its
consequence fires:

```air
(rule (student class=?c grade=?g)
      :accum (g=:mean)
      :if ((mean ?g) > 85)
      :> (honor-roll class=?c avg=(mean ?g)))
```

Flipping a group in and out of the guard asserts and retracts the consequence,
respectively.

## 6. Revision

`(revise s condition changes)` rewrites every base fact matching `condition`;
`changes` is a `(k=v …)` map from the condition's wildcards to new values.
`(revise-fact s old new)` names the facts directly. Both take an optional
`reason=` naming which record moves. A condition matching nothing is a no-op;
matching only derived facts is an error.

```air
(revise s (stats player=?p health-points=?h) (h=90) reason=:damage)
```

A revision moves the fact's reason record and identity, so the fact is not
retracted and re-asserted: downstream rules receive a revision trigger and run
their `:=` side effects.

## 7. Atomic Blocks

`(logic s edit…)` applies a group of edits as one event. Reads inside the block
see the set as it stood on entry, per-fact revision chains collapse within the
call (a later `revise` follows the moved record), and an error rolls the whole
block back. Two successive `logic` calls do not collapse.
