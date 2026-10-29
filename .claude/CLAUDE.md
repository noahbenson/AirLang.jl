# Air syntax — a working reference

**Forms are a sequence *and* a map.** A form `( … )` holds two things at once: a
**sequence** of whitespace-separated elements, and a **map** of `key=value`
entries. They mix freely (`(f 1 2 a=3 b=4)`), map entries may appear anywhere
(`(f a=3 1 b=4 2)` is the same form), and map order is not preserved. The printer
emits all map entries after the sequence elements, so `(f x=1 2)` prints as
`(f 2 x=1)` — the same value. Read a printed form by element *kind*, never
by source position. At **reduction** time (not at read time, and not in
equality) `()` becomes `naught`; `()` and `naught` are the same singleton at
every depth. A one-element form is otherwise **never collapsed**: `(x)` is a
one-element form distinct from `x`, and it reduces only when some `def` or
builtin matches it, so a one-element list, log, or fact is visibly a
one-element list.

**Atoms.** Keywords start with `:` (`:x`) and are inert data that never reduces —
`~:x` is `:x`. Wildcards start with `?` (`?x`, `?&rest`, `?*kwargs`, `??`) and
are inert data too. `'` is an ordinary symbol character, but a symbol may not
*begin* with it — the sole exceptions are the bare symbol `'`, the reader sugar
`'x` for a scalar `x`, and computed keys; `|` and `.` remain reserved
characters, not symbol characters (`.` is the accessor, the namespace-path
prefix and root, and the splat). `=` only separates a key from its value; the
sole exceptions are the comparison symbols `== != === !== <= >=`, which may
contain `=`. Comments are `#` to the end of the line, or a nestable
`#| … |#` block.

**Strings.** A string is Julia-style (`"…"`, `"""…"""`, with Julia's escapes); a
raw string `raw"…"` (or `raw"""…"""`) suppresses escape processing, so
`raw"\d+"` is the three characters `\d+`. `(regex "pattern" [flags])` compiles a
pattern into an ordinary value (it prints as `(extern :regex (…))`); the string
verbs that take a pattern accept a literal string or a regex value, and a regex
replacement expands `$0`, `$1`…, `$name`, and `$$`.

**Operators are infix-canonical.** `(a OP b)` is the canonical form; `(OP a b …)`
is sugar that folds left, so `(OP a b c)` is `((a OP b) OP c)`. The operators are
`+ - * / ^ // mod`, `== != === !== < > <= >=`, and `and`/`or` (which
short-circuit; `(and)` is `true`, `(or)` is `naught`). Infix is binary:
`(1 + 2 + 3)` is a five-element form that does not reduce; write `(+ 1 2 3)` or
`(1 + (2 + 3))`.

There is nothing special about arithmetic: **a form reduces only when some
`def`ined pattern matches it and supplies a replacement**, and a form with no
matching rule is already a fixed point. The arithmetic rules that ship with the
language are written for numbers, so `(1 + 2)` → `3`, while `(x + 1)` stays
`(x + 1)` — not because the operator declines non-numeric operands, but because
no pattern matches `(x + 1)`. The same mechanism is what lets a user rule
anchored on an operator fire (algebraic simplification, differentiation, …).

Bitwise operations are named functions, following the same symbolic convention,
because `|` is the pattern-alternative operator and cannot be infix: `bit-and`, `bit-or`,
`bit-xor`, `bit-not`, `bit-shift-left`, `bit-shift-right` (a boolean counts as
an integer: `(bit-and true 1)` is `1`).

`not` is **prefix only**, `(not cond)`; there is no `(a and not b)` — write
`(a and (not b))`. (The logic-set engine has a separate `not`, which prefixes a
fact pattern to require that no matching fact exists — a different meaning that
does not carry over to the term reducer.)

**Rules.** The two rule systems have separate forms. `->` belongs only to the
replacement family: `(pattern -> replacement)` is inert data read by `replace`,
`replace-all`, `rreplace`, and `rreplace-all`, and, in **head position**, a
lambda (above). It accepts an optional `unhold=true` that inserts the replacement
unheld, so it is evaluated. It derives nothing and is not a rule in the logic
engine — a form containing `->` asserted into a logic-set is an ordinary fact. The logic-set engine uses the structured
`(rule conditions… instructions…)` form: the leading patterns are an **implicit
conjunction** (`(not p)` negates; `:accum` groups), and the instructions are
keyword/argument pairs — `:if cond` gates the instructions that follow,
`:let (k=v …)` binds as in `let`, `:> form` is a consequence (it must reduce to
a fact or `naught`, and each `:>` has a fixed slot), and `:+`, `:-`, `:=` are
side effects run on an assertion, retraction, or revision trigger. The
condition's event selects the side effects; each `:>` slot's old and new outputs
classify its own assertion/retraction/revision. A side effect must pass an
explicit `reason=` to `assert`/`retract`/`revise`/`revise-fact`; in `:=` the
symbol `_` maps the revised wildcards to their new values. `revise` rewrites
base facts selected by a condition (`(revise s cond (k=v …))`), while
`revise-fact` names the old and new facts outright. Note that in `:=` the
symbol `_` is the revision map; outside the logic engine `_` is the pipeline
placeholder (below).

**Pipelines and threading.** `(x >> step1 step2 …)` evaluates `x`, substitutes
the result textually for every `_` in the *raw* first step, substitutes that form
into the next step, and reduces only the final form: `(let (x=2) (x >> (_ + 1) (f
_) (result=_)))` → `(result=(f 3))`, and `(1 >> (_ + _) (' _))` → `(' (1 + 1))`,
not `'2`. A step with no `_` raises. `(>> x step…)` is prefix sugar.
`thread` is Mathematica-style: it distributes a form over its sequential
container elements — `(thread (f (1 2 3)))` → `((f 1) (f 2) (f 3))`,
`(thread (' f (1 2 3)))` → `((' f 1) (' f 2) (' f 3))`. The head is not special
and a nested hold is an ordinary form: `(thread (f (' a b)))` →
`((f ') (f a) (f b))`. `hold-thread` strips the argument's root hold before
threading and holds the result (`(hold-thread (' f (1 2 3)))` →
`(' (f 1) (f 2) (f 3))`); `hold=` selects the result's heldness (false default
on `thread`, true on `hold-thread`).

**Levels (`depth=`) and pattern selection.** `replace`, `rreplace`, `map`,
`cases`, and `drop-cases` take `depth=n`: `0` is the subject itself, `n > 0` is
every node `n` element steps down, where a container's children are its
sequence elements *and* its map values, and the structure above the selected
level is rebuilt. A scalar is its own sole element, so descending past a scalar
stays on it; an extern is opaque. `replace`/`rreplace` default to `0`;
`map`/`cases`/`drop-cases` default to `1`. `replace-all`/`rreplace-all` keep
their whole-tree walk without `depth`; with it they operate only at that level
(`depth=0` is then `replace`). `cases` collects the matching elements at the
level — a bare pattern keeps the element, a `(pattern -> replacement)` clause
replaces it, and a rule-level `\` guard on a bare pattern tests the whole
element, so `(?x \ even?)` means an even element. `drop-cases` removes the
matching elements. Neither takes a default clause (a bare pattern is
indistinguishable from one). `where` is the same walk as a locator:
`(where coll obj depth=d)`. With no `depth` it searches depth `1` and returns
the **bare keys** of the matches in encounter order (`(where (:a :b :b :c) :b)`
is `(2 3)`). With an explicit non-negative integer `depth` it returns **one
path per occurrence**, each path a list of `d` keys
(`(where ((1 2) (3 2)) 2 depth=2)` is `((1 2) (2 2))`). At `depth=0` the only
key is the whole-form key `0`, so the result is `((0))` when the subject equals
`obj` and `()` otherwise. `depth=:all` searches every depth and returns one
path per occurrence, each of its own length (`(where (:a :b (:a :b) :c) :b
depth=:all)` is `((2) (3 2))`). No match is `()` in every mode; results are
plain (not held). Splice a path into `get`, `with`, or `update-in`.

**Pattern alternatives (`|`).** A pipe joins two adjacent sequence elements into
an alternative: `(a |b)` reads as `(alt a b)`, and a container whose sole
element is such a run *is* the `(alt …)` form, so `(a | b)` is `(alt a b)`
rather than `((alt a b))`. A run flattens to an n-ary alternative: `(a | b | c)`
is `(alt a b c)`. The pipe binds only its immediate neighbours, so
`(f a | b c)` is `(f (alt a b) c)`. In a pattern the branches are tried in
order against the same subject; the first match wins and supplies the bindings,
and a failed branch leaks nothing. A pipe needs a sequence element on each
side; a map entry is not one and may stand on neither side. There is no reader
shorthand for nesting a form in the final element — write the parentheses.

```air
(def (f (a | b)) :hit)              ; matches (f a) and (f b)
(def ((f | g) ?x) :hit)             ; matches (f v) and (g v)
(case b ((a | b | c) -> :sym) :other)   ; => :sym
```

**Quotes are holds.** A hold is a container whose first element is the ordinary
symbol `'`: `(' a b c)`. `'` is an ordinary symbol character, but a symbol may
not *begin* with it except the bare `'` itself; `'x` is reader sugar for
`(' x)` only when `x` is a **scalar** (`'a`, `'5`, `':x`, `'"abc"`). The
container spelling `'(…)` is a parse error. A hold holds each element as
written, so `(' a b c)` holds three elements while `(' (a b c))` holds one
container. A hold of exactly one scalar prints with the quote (`'a`, `'5`,
`':a`); any other hold prints literally (`(' a b c)`, `(' f x=1)`). `(hold e…)`
is the reserved alias that reduces to `(' e…)`. `:` alone remains the keyword
marker (`:a`) and `:(…)` is a parse error. A held form **stays held** — it is
data, not code. Inside a hold only `~` substitutes; a bare symbol and a bare
subform stay literal: `(' a x b)` stays `(' a x b)`, while
`(let (x=2) (' a ~x b))` → `(' a 2 b)`. `let` is the exception: it substitutes
its names **textually, before the body is evaluated**, so it reaches inside
holds — `(let (x=2) (' a x b))` → `(' a 2 b)` too. Each hold owns its own `~`,
so `(let (x=2) (' a (' b ~x)))` → `(' a (' b 2))`. `~e` is sugar for
`(preval e)`, a reserved special form that evaluates `e` eagerly wherever it
appears; inside a hold it is filled in recursively at every depth (and in a
computed key). A hole may sit in a map value (`(f x=~(1 + 2))` → `(f x=3)`,
and `x=~y` is the same hole), and the `...` suffix binds looser than `~`, so
`(f ~(1 2 3)...)` → `(f 1 2 3)` (the hole's value splices; its operand does
not). `(hold (a ~(1 + 2)))` → `(' (a 3))`. It is *not* the runtime
unhold operation: that is the ordinary call `(unhold x)`, which is inert data
inside a hold. `(unhold (' a b c))` drops the head and evaluates the content,
giving `(a b c)`. If `x` is bound to `(' 3 + 1)`, then `(' a ~x)` is
`(' a 4)`, while `(' a (unhold x))` stays `(' a (unhold x))`.

A hold is **opaque** to the hold-blind accessors: `(first (' a b c))` is `'`
and `(count (' a b c))` is 4. `get` indexes the form exactly as it is written,
so for a held form index 1 is the `'` head and index 2 is the first content
element: `(get (' f a b) 2)` is `f`, and `(get (' f x=1) :x)` is `1`. To
extract a subpart **while keeping it held**, pass `hold=true`: it makes the
root hold transparent, walks the path over the *content* without reducing
intermediate values, and holds the result — `(get (' f (1 + 2)) 2 hold=true)`
is `(' 1 + 2)`. This works for any form that keeps its arguments as data, not
only a hold — `(get (part add 10) 2 hold=true)` is `'add`.
`(with form k1 v1 … hold=true)` is the inverse: replace the subform at each
path with its value, inserted without its own hold and not evaluated, so
`(with (' a b c) 2 (' 1 + 1) hold=true)` is `(' a (1 + 1) c)`.
Likewise `(held? x)` tests whether `x` is a held form, and
`(held? form subindices…)` tests whether the subpart at that path is held:
`(held? (' f (1 + 2)))` is true, `(held? (' f (1 + 2)) 3)` is false (that
`(1 + 2)` is not held), and `(held? (' f (' 1 + 2)) 3)` is true. `hold=true` on
`held?` makes the root hold transparent first (`hold-held?` defaults it on).
`lower` pushes holds toward the leaves and `lift` lifts them back to the root.
(`raise` is the error special form, not a hold operation.)
So code that must inspect a term should take it held and use `get` rather than
`~`.

**The `hold-` family.** Every operation whose primary argument is a form has a
`hold-` version — `hold-get`, `hold-nth`, `hold-with`, `hold-wout`, `hold-push`,
`hold-push-in`, `hold-join`, `hold-join-in`, `hold-update`, `hold-held?`, and
`hold-thread`. These always treat the root hold as transparent (the operation is
on the content), let inserted held values contribute their content, and return
the result held: `(hold-get (' 1 2 3) 2)` is `(' 2)`. `hold=` selects the
result's heldness (`(hold-get (' 1 2 3) 2 hold=false)` is `2`), and the plain
version accepts `hold=true` for the same treatment
(`(get (1 2 3) 2 hold=true)` is `(' 2)`). Integer keys are uniform across
`get`, `nth`, `with`, `wout`, `update`, `update-in`, and `held?`: `0` is the
whole form, `1…n` index the sequence, `-1…-n` count from the end, a setter's key
`n + 1` appends, and anything further raises. A scalar is its own sole sequence,
so `(get 5 1)` is `5`; `naught` is the empty form, so only `0` names it. `(update-in coll k1 … kn f)` is a
deep `update`: it replaces the subform at the path with `(f old)`, a sequence
key is a nested path as for `get` and `with`, and a missing key is `naught` to
`f`.

**Binding forms and access.** `let` takes a binding form and a body:
`(let (x=1 y=2) body…)`. Bindings in one mapping are parallel (each value
evaluates in the enclosing scope), and source position does not matter. The
binding form may instead be a **sequence of mappings**, `((a=1) (b=2))`, each
feeding the next: earlier groups substitute into later groups' value expressions,
and a rebound name sees its *previous* value inside its own new value
(`(let ((x=1) (x=(x + 2))) x)` → `3`). `let` **substitutes** each name by its
value in the body *before* evaluating it — it does not introduce a scope, and the
substitution reaches inside quotes; `hold=(x y)` on the `let` form names bindings
whose values are inserted exactly as written instead of evaluated, in every
group.
`loop (i 1 acc s) body` with `recur` is a tail-recursive loop that does not grow
the stack. `def (pattern) body…` optionally takes `hold=(x y)` so that those
parameters match the **raw** call and are inserted into the replacement *exactly
as matched* — unheld and not evaluated at binding time (a non-held parameter is
reduced first). The replacement then reduces normally, so the raw match is seen
by the immediately enclosing form's rules and is otherwise evaluated in due
course: with `(def (f ?x ?y) hold=x (g x y))`, `(f (1 + 1) (2 + 2))` →
`(g (1 + 1) 4)` → `(g 2 4)` when no `g` rule fires, and `(let (x=5 y=6) (f x y))`
→ `(g 5 6)` (the `let` substitutes before `f`'s rule runs). `(unhold x)` evaluates a raw match, and a
quoted occurrence `'x` in the body receives the *held* match (`(' (1 + 1))`). A `def` with
**no body** declares a rule that reproduces its matched form, so the form is a
fixed point: `(def (f ?x))` makes `(f (1 + 1))` → `(f 2)` (arguments reduce, the
form does not), while `(def (g ?x) hold=x)` makes it stay `(g (1 + 1))`. `lower`
pushes holds toward the leaves and `lift` lifts them back
to the root, building a quoted form explicitly (`(lift (' 'a x 'b))` →
`(' a <value-of-x> b)`). A literal string at the head of a `def` body is its docstring (deindented,
and not executed); `(doc sym)` lists the documented patterns that use `sym`, and
`(doc (form…))` holds its argument and lists the documented patterns that match
that form. `(definitions arg)` takes the same argument but returns the matching
`def` forms as quoted data, with each docstring moved into a `doc=` map entry.
A `def` body is a **block**: it takes `let=`/`catch=`, level-1 `:let` markers,
and trailing `except`/`handle`/`finally` clauses exactly as `do` does (several
body forms are sequenced as a `do`), and `tx=true` runs the body as a `tx`
instead (an escaping error aborts the writes; one caught by the body's own
`except` commits). `tx=false` is the default. A `def` also takes
`memoize=true`/`:weak` (weak, the default mode) or `memoize=(:lru n)` (bounded,
strong) to cache results by the `eq?`-equivalent evaluated arguments (a held
parameter contributes its raw match); the mode is stored in
the namespace entry and reproduced by `definitions`, while the cache is
process-local. An implicit `def`, a body with dynamic dependencies, and tail
calls inside a memoized body are the caveats. `val` accepts the same block
options (`let=`, `catch=`, `tx=`) but not `memoize=`.
There is no separate lambda form: **a replacement rule in head position is a
function** — `((?x -> (x ^ 2)) 3)` is `9`, and a multi-parameter pattern needs its
own parentheses (`(((?a ?b) -> (a + b)) 3 4)`). Its body is substituted, not
lexically closed: a free name resolves when the rule is applied, in the caller's
scope, and a name bound by the pattern shadows an outer one. Inside the body `_`
is a hold of every argument (`((?x -> _) 5)` is `'5`; `(((?a ?b) -> _) 5 6)` is
`(' 5 6)`); inside a `replace` rule or `case` clause `_` is the whole matched
subject, unheld. `(case subject clause… default?)` tests replacement-rule clauses
in order, first match wins, and a trailing non-rule is the default (`naught` when
absent); `select` is an alias. `if`/`cond` is `(if c1 v1 c2 v2 … else)`. `get` is the single accessor: an **integer** indexes a
sequence (**1-based**) and a **keyword** indexes the map, and a bare symbol key
is read as a keyword. The `.` accessor is pure sugar for `get`: `f.a.b` is
`(get f :a :b)`, `f.:x` is `(get f :x)`, and `...` splices (`(f a... b)`). Its
keys are **held** — a bare suffix is the literal keyword, so `f.a` ignores a
variable `a`; `~` evaluates one key, so `f.~k` is `(get f (preval k))` and
`f.~a.b` is `(get f (preval a) :b)`.

**Namespaces and thread-local values.** `.` alone is the global namespace root
and `.air` the core namespace (every builtin, operator, and constant); a
leading-dot atom is a path, so `.util.a` reads as `(get . :util :a)` and the
whole tree is ordinary `.` access over layered namespace volatiles. `.air.sys`
holds the system functions (`load-air`, `read-file`, `write-file`,
`open-airdb`, `close-airdb`), `.sys.user` holds the user records, `.lib` is the
library cache, `.main` is `air`'s startup namespace, and `.env` is a `val`
holding the task's environment mapping. `$` is the current user's **home**
capability and `@` the root of the attached database (`.` when unattached);
both are ordinary symbols that a local binding may shadow. The **current
namespace** is task-local — `.main` for `air`, `$` for a created user — and a
top-level `def`/`val` appends there, so it is durable rather than a
process-global rule. `(namespace path body…)` replaces the current namespace
for `body` (it does not layer the caller's definitions) and appends the body's
`def`/`val` forms in one transaction, creating subnamespaces automatically;
later definitions match first, and a subnamespace and a definition may not share
a name in either order. `(using spec… body…)` activates one namespace, or a
list, for `body` — context only, nothing is copied; a spec may carry `only=(…)`,
`except=(…)`, or `as=sym`. Inside a `namespace` block, `(use spec…)` and
`(import spec…)` **materialize** entries: a readable `def` is copied, a
readable `val` shares the source `Var`, and an execute-only or `anchor=true`
entry becomes a lazy proxy; `import` also exports the names in the map, `use`
keeps them private, and every entry records `source=`. `(clear sym)`, `(clear
:all)`, and `(unuse ns [names…])` remove entries; `(del sym)` is an alias of
`clear`. `(val pattern form…)` evaluates `form` once at definition time and
installs it — backed by an Air `Var` — as a thread-local value that cannot act
as a function; a bare reference yields it, while the zero-argument call
`(.ns.v)` is a one-element list containing it. `(bind (x=… y=…) body…)` rebinds, thread-locally for `body`'s dynamic
extent, the `val`s that its namespace context resolves; `(bindings)` returns the
overrides as a mapping that `bind` can reinstall. `(task form…)` holds its
arguments, evaluates them on a spawned task that inherits the current bindings,
identity, namespace, and database context, and returns a database-backed
promise; `(await p)` yields the final form's value or rethrows the task's error.
`(promise)`/`(deliver p v)`/`(ready? p)` are the same value without a body (see
Reference forms above), and `future` is a tombstone.

**Users and permissions.** User ids are keywords (`:air`, `:alice`,
`:game:bob`); `air` is the superuser, and a constituent is exactly
`admin:name`. `(current-user)` is the task's identity and `(owner)` the owner
of the executing `def` (else the current user); `(as-user id body…)` evaluates
`body` as `id`; `(create-user …)`, `(create-constituent …)`,
`(set-admin …)`, and `(users)` manage records in `.sys.user` or `@.user`.
Every namespace and entry volatile carries metadata `(owner=… acl=…)`, where
the ACL maps `read`/`write`/`exec`/`assume`/`hide`/`watch`/`filter`/`finalize`
to user ids with `_` meaning everyone. The owner has all of them except
`assume` by default, nobody else has anything, `air` bypasses every check, and
`hide` is a veto. `(permissions target)`, `(chmod! target read=(…) write=(…)
…)` (also `anchor=true`), and `(chown! target user)` edit the metadata;
`chmod!`/`chown!` need `write` on the target. `watch` gates installing a watch,
`filter`/`finalize` gate replacing those hooks on a `mut`. A denial is the
catchable error `(error :permission-denied perm target)`; filtered operations (`using`,
`doc`, listings, printing) treat an unreadable entry as absent. `(assume
body…)` is legal only inside a `def` whose entry grants `assume` to the caller
and runs `body` as the definition's owner.

**Mutables and hooks.** `(mut value filter=… finalize=…)` creates a mutable;
`(value m)`, `(get m)`, and `(get m 0)` all read it. Volatile edits end in `!`:
`set!` (also `set! form path… value`, which edits the deepest mutable on the
path), `swap!`/`alter!` (`(fn value args…)` in one transaction), `chmod!`, and
`chown!`. `mut` is not an edit, and `reset!` is reserved for actors. A filter or
finalizer is kept as written in the mutable's metadata (so it survives a
reload): a replacement rule is applied as a function, any other form is
evaluated with `_` bound to the value. A filter runs on every write and its
result is stored; a finalizer runs after the body of the writing transaction,
before the commit attempt, in the `:finalizing` state where mutables cannot be
written, and its result replaces the value. `(watch m key fn)` registers
`(fn key m old new)` to run as its registrar, in the namespace where it was
registered, at the end of the outermost transaction body — pre-commit and once
per mutable per transaction, so its writes are transactional and a retry reruns
it. Watches live in metadata too; `(unwatch m key…)` and `(watches m)` manage
them.

**Reference forms.** Three database-backed values behave like mutables on the
access path. `(delay body…)` holds a body and computes it at most once; it is
forced by `(get d)`, `(get d 0)`, `value`, and any `get` path that walks through
it (delays vanish on the path as volatiles do), and it is immutable. The body is
captured like a task's — free lexical names substituted, and the current
namespace, its active `using` layers, the `val` bindings, `@`, and `.env`
stored — so the first force evaluates it in that context and writes the result
into the delay's database cell; every later force, in any environment over that
database, reads the cached value without running the body. Printing and
serialization never force it, and a body that forces its own delay raises a
catchable error. `(actor value history=…)` is a persisted worker:
`(send a fn)` sends `fn` (called with the current value; deferred to commit
inside a transaction) and `(reset! a value)` replaces the value; `(sync)`
flushes. A send captures the sender's lexical names like a task (a
`loop`/`for` or rule binding used inside `fn` is substituted), and it keeps the
sender's namespace layers and `val` bindings active; a name bound by `fn`'s own
pattern shadows the captured one. `(promise)` is a single-assignment database value: `(deliver p v)`
fills it once, `(get p)`/`(await p)` read it (blocking outside a transaction,
raising inside one unless delivered), and `(ready? p)` tests it; an undelivered
promise serializes as `"~uuid"`, a delivered one as its value. `task` returns
such a promise; `deliver` and `await` also accept an ephemeral promise extern. Predicates: `actor?`, `promise?`, `delay?`.
An actor, promise, or delay from another database is `(error :un-storable …)`.

**Persistence.** A form's database is that of the namespace it is written in:
the process store for `.`, `.main`, and system homes, an opened root's database
below it (`Env(db=…)` selects only the process store). `mut`, logic sets, and
named forms all follow this one rule, so a mutable from `.main` cannot be stored
in a database namespace (`(error :un-storable …)`). `(named-form name create=true
value=… history=…)` opens or creates a named volatile — a name is a keyword,
symbol, or string normalized to its text (so `:x` registers `x`), `air/` is
reserved, `create=false` raises and `create=naught` yields `naught` when absent,
and a `value=` that is a same-database volatile makes the name an alias.
`(name-form! name volatile)` repoints a name; `(named-forms)` lists the readable
names. Creating needs write in the current namespace; opening a named form and
every logic-set query need read; logic-set mutation (`assert`, `retract`,
`revise`, `logic`) needs write. `(tx body…)` evaluates a full `do` block (its
grammar is below) in one STM transaction and yields the block's value;
transactions join rather than nest, so the outermost `tx` (`namespace`,
`load-air`, a logic-set edit, and `set!` are transactional too) is the
commit/rollback boundary. An error escaping it aborts its writes even if an
outer block catches it; an error caught by the tx's own `except` commits, as
does a throw caught by its own `catch=`. A throw escaping to an outer `catch=`
is deferred: watches run, the transaction commits, and only then is the signal
rethrown (a retried attempt discards it). `(sync)` is a FIFO flush barrier — call it outside an open
transaction to cover that transaction's writes, since Air defers actor sends
until commit — and `(status)` is `(pending=N error=…)`.
`(form-id vf)`/`(form-at id)`/`(loaded? vf)`/`(history vf)` expose identity (an
unknown id yields `(error :form-not-found id)` on read); `(to-json v)`/`(from-json s)`
use AirDB's codec, where a volatile is a bare `"@uuid"` link, so cycles encode
and print as `#<volatile …>`, and a non-finite float is the marked string
`"#inf"`, `"#-inf"`, or `"#nan"`.

**Loading, libraries, and databases.** `(load-air path…)` parses every file
before evaluating any form and evaluates all of them in one transaction, with
relative paths resolved against the loading file's directory; `.air.sys.load-air`
is the same function. A library is a `<name>/init.air` directory found on the
`:`-separated `AIR_LIBPATH` (default `<repo>/lib` and `~/.air/lib`), loaded
lazily as `air` under `.lib.<name>` on first reference. `(open-airdb name
opts…)` opens AirDB (memory, `url=`, or `dbname=`/`user=`/…) and roots `name`
in it; namespaces at or under an open root (longest prefix wins) live in that
database, whose users and ACL principals are separate from the system's.
`@` is the attached root, `(close-airdb name)` closes recursively and detaches
it, and storing a value that embeds a volatile from another database raises
`(error :un-storable target)`. `mut` creates its mutable in the database of the
current namespace.

**Keys.** A bare key is a keyword: `(form x=10)` has the key `:x`, so
`(form x=10).:x` is `10`. A **computed key** is written `~expr=value`, and the
expression must evaluate to a keyword: `(form ~(keyword (name ?x))=10)` reduces
to `(form x=10)`, since `(name ?x)` is `"x"` and `(keyword "x")` is `:x`.

**Evaluation.** Reduction runs bottom-up to a fixed point. A call in **tail
position** — the selected branch of an `if`/`cond`, the last form of a `let` or
lambda body, the last form of a `do` with no `catch=`/`except`/`handle`/
`finally` (with or without `:let`/`let=`), a `when`/`unless` body, the last
operand of `and`/`or`, a rule body — is reduced iteratively rather than
recursively, so a tail-recursive
rule runs in constant stack; only nested (non-tail) recursion is bounded by the
depth budget. An unbound symbol
evaluates to itself; a symbol bound by `loop`/`for` resolves through the lexical
scope and its value is then reduced in that scope (a held value is data
and is returned as written). `let` is different: it inserts the value into the
body, so the value is never looked up again — `(let (db=(db 1)) db)` is
`(db 1)`, not a runaway recursion. Name data markers differently from
variables. A form whose head is a builtin, special form, operator, or matching
`def` rule is replaced by its result. Every global `def` pattern must contain at least one raw
(non-keyword, non-wildcard) symbol as an anchor, and rule order matters. Code is
data: the same form is a value and a call, and quoting is how you hold code
without running it.

**Equality.** Three relations. `same?` is identity (`===`). `eq?` is
**equivalence**: scalars match by value *and* type (`(eq? 1 1.0)` is false),
containers match elementwise with map order irrelevant, a volatile, actor, or
promise matches only itself, a delay matches when its type and serialization do
(it is never forced by a comparison), and an extern follows its own `isequal`
(an equal regex value matches) — so any immutable form is comparable even when it
contains a mutable, whose part contributes only its identity. `==` is **content** equality, which is numeric-friendly (`(== 1
1.0)` is true). `(hash x)` follows `eq?` (equal forms hash alike; the hash never
descends into a mutable), which is what memoization and keyed tables rely on.

**Errors and diagnostics.** `(error :tag …)` is an inert error **object** — the
`error` head never reduces, so its elements stay raw at any depth. `(raise :tag
data…)` evaluates its arguments and throws `(error :tag data…)`; the type slot
is optional and conventional (air never inspects it), and a lone argument that
is already an error object is thrown exactly. `do` is the block form:
`(do options… body… (except pattern body…)… (handle pattern body…)… (finally
body…))`. `except` matches each pattern against the error's **content** (the
object without the `error` head, with its map); a bare wildcard pattern binds
the whole object. The reserved bare symbol `reraise`, as an `except` body's
final value, resumes the original error through later clauses (or out of the
block); `finally` always runs and its value is discarded. Other options are
`let=` (a block lexical scope, outermost) and level-1 `:let` markers in the body
(nested textual `let`s, invisible to the clauses). `catch=true`/`catch=:tag`/
`catch=(tags…)` lets `(throw value)`/`(throw tag value)` return early; an
unmatched throw is `(error :uncaught-throw tag value)`. `(signal :tag data…)`
is inert like `error`; `(notify …)` dispatches it to the innermost matching
`handle` clause (content-matched, first match wins, handlers active through
`finally`) and takes the handler's value, or raises
`(error :unhandled-signal signal)`; `(notify-or default …)` holds `default` and
evaluates it only when nothing matches. `try` is gone (only a tombstone). A
`raise` inside a handler records the handled error as `from=` (automatic
context, overridable, `from=naught` suppresses); `cause=` is explicit. A
non-air exception surfaces to an `except` as `(error :internal message)`.
`showerror` prints the
`direct cause:` / `during handling of:` chain. Positions are not part of a
form: the reader records container spans, a loader installs them task-locally
while evaluating, and an escaping error carries `frames`
(`(name=… line=… col=… text=…)`, innermost first). A loaded `def`/`val` stores
its definition site as `src=` in the entry body, and the innermost executing
definition wins; `showerror` prints `(at name:line:col)` plus the source line.
Positions are best-effort — a bare REPL form has none — and never change the
error object an `except` matches. `(trace body…)` yields the body's value or, on
error, the final data form `(:trace (error …) frames=(…))`.

**Testing.** `(check expr)` is a boolean truth test. Inside `(test name body…)`
it records the outcome, and an uncaught error in the body is recorded as one
failure and ends the body. `test` yields the inert data form
`(name=… pass=… fail=… failures=(…))`, where each failure is held so that
evaluating the summary again does not run it; counters are task-local, so
nested and concurrent tests are independent.
