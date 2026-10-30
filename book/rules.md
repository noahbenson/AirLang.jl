# The two rule systems

Air features two complementary rule systems tailored for algebraic evaluation
and declarative logic programming, respectively.

## 1. Reduction Rules (Inner System / Term-Rewriting)
The inner system handles bottom-up algebraic evaluation, function definition
(`def`), syntax normalization, and immediate fixed-point reduction. When a form
like `(f 2)` is submitted to the evaluation engine, reduction rules evaluate it
recursively until a fixed point is reached.

## 2. Production Rules (Outer System / Deductive Engine)
The outer system operates like a DROOLS rules engine backed by `logic-set`
objects.
* **Logic Sets:** Every namespace is a logic set, and `logic-set` makes a
  standalone one. Users add, change, and remove facts with `(assert s fact)`,
  `(retract s fact)`, `(revise s condition changes)`, and `(revise-fact s old
  new)`; with no target they edit the current namespace. `defrule` asserts a
  structured rule, `query` lists the satisfiers of a condition block, and
  `ingest` copies the base facts and rules of another set. Operations take an
  optional `reason=` — `naught` (the default) or a keyword. `revise` changes
  only base facts: the condition binds wildcards and the `(k=v …)` map gives
  their new values.
* **`->` is replacement-only.** `(pattern -> replacement)` is inert data for the
  `replace` family (see below); it is not a rule in the outer system. A form
  containing `->` asserted into a logic-set is an ordinary fact.
* **Rules are structured forms.** A RETE rule is
  `(rule conditions… instructions…)`: the leading forms are an implicit
  conjunction (negation is `(not pattern)`), and the rest is a flat sequence of
  keyword/argument instruction pairs interpreted by the engine:
  ```air
  (assert s (rule (parent ?x ?z) (ancestor ?z ?y)
                  :if (not (done ?x))
                  :let (label=(concat x "/" y))
                  :> (ancestor ?x ?y)
                  :+ (log "new")
                  :- (log "gone")
                  := (log _)))
  ```
  * `:if cond` — if the condition is not truthy, the instructions after it are
    skipped (a skipped `:>` is `naught`).
  * `:let (k=v …)` — bind names as in a `let`; later instructions see them.
    Separate `:let` instructions are sequential, while bindings inside one map
    are parallel.
  * `:> form` — a consequence: the form must reduce to a fact or `naught`. Each
    `:>` has a fixed slot that identifies its output across firings.
  * `:+ form`, `:- form`, `:= form` — side effects run on an assertion,
    retraction, or revision trigger. They may call `assert`/`retract`/`revise`/
    `revise-fact` only with an explicit `reason=`. During `:=` the wildcard `_`
    is bound to a map of the changed wildcards to their new values.
* **Triggers are decided by the condition,** not by the consequence:
  a new combination of matches is an **assertion** (runs `:if`, `:let`, `:>`,
  `:+`); a combination that persists while a matched fact was revised (or an
  accumulator group changed) is a **revision** (runs `:=` instead); a
  combination that stops matching is a **retraction** (runs `:-` with the old
  bindings). Each `:>` slot's old and new outputs classify its own event:
  `naught`→fact asserts, fact→`naught` retracts, different facts revise, equal
  facts do nothing. Facts carry stable identities across revisions, so a
  downstream rule sees a revision rather than a retract/assert pair.
* **Reasons.** Every fact exists because of one or more reason records. A base
  fact records the label given to `assert`/`revise` (a keyword or `naught`); a
  derived fact records `(because RULE PREMISES…)`. Labels may be shared, and a
  fact survives while any reason holds it; retracting or revising one reason
  touches only that record. `(why s fact)` returns every reason.
* **Grouping and accumulation (`:accum`).** `:accum` lists the **accumulated**
  variables; every other bound variable is a group key:
  ```air
  (assert s (rule (student class=?c grade=?g)
                  :accum (g=:mean)
                  :> (avg class=?c value=?g)))
  ```
  Unannotated variables bind to vectors; `=:min`, `=:max`, `=:sum`, `=:mean`,
  `=:median`, `=:first`, and `=:last` aggregate. `:take (min v)`, `:take (max
  v)`, `:take :first`, and `:take :last` select one row instead. Repeated
  `:accum` specs nest: outer levels partition and the final level aggregates,
  yielding parallel sequences. `:first`/`:last` follow insertion order, and a
  revision keeps its position.
* **Atomic blocks.** `(logic s edits…)` applies a group of edits as one event:
  reads inside the block see the snapshot from entry, per-fact revision chains
  collapse within the call (but not across calls), and an error rolls the whole
  block back.
* **Advanced Features:** complete **provenance tracking** (a Justification-Based
  Truth Maintenance System) that records why a fact is true so an LLM can
  narrate explanations on demand.
* **In-Place Mutation & STM:** Instead of destructive retract/reassert cycles
  for mutable entities (like revising the fact
  `(stats player=:Nurgle health-points=100)` to
  `(stats player=:Nurgle health-points=90)`), `revise` moves the fact's reason
  record and identity in place, emitting a targeted delta.
* **Actor-Backed I/O:** Side effects involving file descriptors or network
  outputs are routed to background actors, ensuring safe rollback if STM
  transactions abort.
