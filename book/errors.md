# Error handling

Air features a pattern-matched, structural error system integrated directly into
its core evaluation engine, replacing traditional class-based exception
hierarchies. Errors are ordinary forms, so they can be stored, matched, compared,
and printed like any other value.

## 1. Error objects are constants

An **error object** is a form whose first element is the ordinary symbol
`error`:

```air
(error :io "Connection lost")
(error)                    # the empty error
(error :arg :a x=1)        # the map is part of the object
```

The reducer never evaluates an error object or any of its elements: `error` is
an inert head, so `(error :io (+ 1 2))` is the *unevaluated* form
`(error :io (+ 1 2))` at any depth. The first element after the head is
conventionally the error type (a keyword), but air never inspects it; the type
is optional and purely conventional. `error` cannot be given a reduction rule.

## 2. Raising errors

`raise` is a special form that constructs an error object and throws it.

```air
(raise :io "Connection lost" path="/tmp/x")
```

* **Arguments are evaluated.** `(raise :io (+ 1 2))` raises
  `(error :io 3)`. Map entries are evaluated too.
* **No type is required.** `(raise)`, `(raise :io)`, and `(raise "oops")` are
  all legal; they raise `(error)`, `(error :io)`, and `(error "oops")`.
* **The first slot is not special.** `(raise :io "x")` raises `(error :io "x")`
  and `(raise "a" "b")` raises `(error "a" "b")`.
* **A single error object is raised exactly.** If `raise` has exactly one
  positional argument and no options and that argument evaluates to an
  `(error …)` object, the object is thrown as it is — its elements are not
  re-evaluated or copied:

  ```air
  (raise (error :io (+ 1 2)))        # throws (error :io (+ 1 2))
  (raise (error :io) "abc")          # (error (error :io) "abc")
  ```

  Adding any option (or a second argument) makes `raise` rebuild an object, so
  the error object becomes the first payload element.

## 3. Blocks: `do`, `tx`, `except`, `catch`, `handle`, and `finally`

`do` is the language's block form and subsumes the old `try`: it evaluates a
body with optional binding, error clauses, signal handlers, and a finalizer.
`tx` accepts exactly the same grammar and runs it inside one transaction.

```air
(do
    let=(scale=2)                       # a lexical block scope
    :let (x=(compute scale))            # a textual binding inside the body
    (some-function x)                   # body…
  (except (:io ??data)                  # matches the content of (error :io …)
    (print "I/O failed: " data)
    :handled)
  (except (:arg ?x \ symbol?)
    :bad-argument)
  (except ?err                          # a bare wildcard binds the whole object
    (print "Unrecognized error: " err)
    reraise)                            # resume it (see below)
  (handle (:progress ?pct)              # a notified signal runs here and
    (print pct "%"))                    # execution continues after notify
  (finally
    (print "done")))
```

A block is

```
(do options… body… (except pattern body…)… (handle pattern body…)… (finally body…)?)
```

The only options are `let=` and `catch=`. The body runs left to right, and the
clauses that follow it may be `except` and `handle` in any order; at most one
`finally` may appear, and it must be last. A bare `(catch …)` clause is an
error: write `catch=` for a throw tag or `except` for an error pattern.
`except`/`handle` outside a block remain ordinary data.

The block's value is the last body value (`naught` for an empty body), a caught
`throw` value, or the matching `except`/`handle` body's value. `finally`'s value
is discarded. Block setup — the `let=` values and the `catch=` tags — runs
before the body; a failure there is not handled by the same block's clauses and
does not run its `finally` (an outer block can still handle it).

### `:let` markers and `let=`

A level-1 bare `:let` in the body consumes the next body form as a `let`
binding form; the remaining body forms become its body. Markers nest left to
right, need not be first, and a marker in the final body position is inert
data. `:let` is the same textual `let` as elsewhere: its names are substituted
into the rest of the body, and they are **not** visible to `except`, `handle`,
or `finally`.

`let=` instead wraps the whole block in one **lexical scope**, visible in the
body, clause bodies, signal handlers, and `finally`, and outermost relative to
any `:let` markers. Its groups feed one another exactly as `let`'s do, but as a
scope it does not rewrite inside a hold or a computed key.

```air
(do let=(a=1) :let (a=2) a)        ; => 2
(do let=(a=5) :let (a=2) (raise :x) (except (:x) a))   ; => 5
```

### `except`

* **Content matching.** An `except` pattern is matched against the **content**
  of the error object: the object without its `error` head, keeping its map.
  `(except (:io ?msg) …)` therefore matches `(error :io "x")` with
  `msg = "x"`, and `(except () …)` matches `(error)`.
* **Bare wildcards bind the object.** A pattern that is a single non-rest
  wildcard (`?e`, `?`) is matched against the whole error object, so the handler
  can inspect or re-raise it. Use `(except (:io ??data) …)` to capture the
  content's sequence and map.
* **First match wins.** Clauses are tested top to bottom; the first matching
  clause runs and later clauses are skipped.
* **Escaping.** If no clause matches, the error continues propagating. A new
  error raised inside a handler also escapes the block; it is not offered to
  later clauses.
* **Empty body.** A matching `except` with no body evaluates to `naught` and
  consumes the error.
* **Host exceptions.** A non-air exception is matched through the error object
  air builds for it (`(error :internal message)`, or a specific head such as
  `:form-not-found`), and is rethrown unchanged when no clause matches.

### `reraise`

`reraise` is a reserved bare symbol (it cannot be bound by `let`, `def`, or a
pattern). When the **final value** of an `except` body is `reraise`, the
original error resumes as if that clause had not fired: later clauses still get
a chance to match it, and if none handles it, it escapes the block. Side
effects performed before the `reraise` are kept.

```air
(do (raise :io "x")
  (except (:io ?m) reraise)      ; log here, then let the next clause see it
  (except ?e (print e)))
```

### `catch=` and `throw`

`catch=` makes a `throw` return from the block early:

```air
(let (x=-1)
  (do catch=:tag
      (if (< x 0) (throw :tag :undef))
      (sqrt x)))                 ; => :undef
```

* `catch=true` is the literal tag `true`; `catch=:tag` is one tag;
  `catch=(tag1 tag2…)` is a list. Tags are **held literals**, not forms and not
  patterns: a symbol is not evaluated. `~expr` is the only escape and must
  reduce to a scalar. Any other form is an error, as are an empty `catch=` and
  a `catch=` with map entries.
* `(throw value)` means `(throw true value)`; `(throw)` is
  `(throw true naught)`; `(throw tag value)` uses a held or computed tag. The
  value is evaluated. Extra arguments or map options are errors.
* At a `throw`, the innermost active `catch=` scope with a matching tag accepts
  it. A block catches only signals aimed at its own scope, so same-tag nesting
  is unambiguous and other signals pass through. A `throw` from an `except`
  body is caught by the same block's `catch=`; one from `finally` is not (its
  catch scope is already closed), though an outer block can still catch it.
* With no matching catch, the throw is immediately the ordinary error
  `(error :uncaught-throw tag value)`, raised from the `throw` form's position.
  `except` clauses therefore never see a throw signal; they see only that
  error once no catch matches.

### `signal`, `notify`, and `handle`

A **signal object** is a form headed by the ordinary symbol `signal`. Like an
error object it is a constant: it never reduces, at any depth.

```air
(signal :progress 40)
```

`(notify data…)` evaluates its positional arguments and map values. With
exactly one positional argument, no map entries, and a `(signal …)` value, it
dispatches that object unchanged; otherwise it dispatches the freshly built
signal. Handlers are searched from the innermost active block to the outermost,
and top to bottom within a block; the first match wins. A handler pattern
matches the signal's content (the object without its head, keeping the map),
and a bare non-rest wildcard binds the whole signal object.

A matching handler runs at the notify site in its defining block's scope (the
block's `let=` scope, plus the pattern bindings). Its value becomes `notify`'s
value and execution continues. A handler is dynamically scoped but lexically
evaluated: it is registered at block entry, works for a `notify` written
*before* the `handle` clause, and disappears when the block exits. An error
raised by a handler follows the context in which the `notify` ran.

With no matching handler, `notify` raises `(error :unhandled-signal signal)`
from the notify form. `(notify-or default data…)` is the same, except `default`
is held and evaluated only when nothing matches; it is not part of the signal.

```air
(do (notify :progress 40)
  (handle (:progress ?pct) (+ pct 1)))     ; => 41
(do (notify-or :none :progress 40)
  (handle (:progress ?pct) pct))           ; => 40
```

Catch scopes and handler scopes are task-local and do not cross a `(task …)`
boundary: a notify in a task with no local handler is an `:unhandled-signal`
error, and an unmatched throw becomes an `:uncaught-throw` error rethrown by
`await`.

### `finally`

`finally` always runs — after normal completion, after a matched `except`, after
a caught `throw`, after a `reraise`, and while an error or throw escapes. It may
appear without any other clause, must be last, and there may be at most one. Its
value is discarded. The block's `handle` scope is still active while it runs,
but its `catch=`/`except` are closed. If it raises or throws, that condition
replaces the result or the condition already in flight, and a replaced error
becomes the new error's automatic `from` (see below).

### Definition bodies

A `def` body (and a `val` body, which is evaluated once at definition time) is
this same block. It takes `let=` and `catch=`, level-1 `:let` markers, and
trailing `except`/`handle`/`finally` clauses; several body forms are evaluated
in sequence as by `do`. Everything above applies unchanged: an error from the
body can be handled by its own `except`, a `throw` by its own `catch=`, and a
`finally` always runs.

`tx=true` (the only `def`-specific option besides `memoize=`) runs the whole
body as a `tx` instead of a `do`:

```air
(def (store ?x) tx=true (write-something x) (raise :disk-full))
(do (store 5) (except (:disk-full) 1))
; => 1, and the write is rolled back

(def (safe-store ?x) tx=true (write-something x) (raise :disk-full)
  (except (:disk-full) :failed))
(safe-store 5)
; => :failed, and the write commits
```

`tx=false` is the default, an ordinary block with no transaction. A memoized
body caches only a successful result; an error or throw passes through and
stores nothing.

### Tail position

A `do` with no `catch=`, `except`, `handle`, or `finally` keeps its last body
form in tail position (including when it uses `:let`/`let=`), so a tail call
through it does not grow the stack. Any condition-handling feature makes the
block run eagerly, and `tx` is never a tail form.

### Migration from `try`

`try` has been removed. Rewrite `(try body… (except …)… (finally …))` as
`(do body… (except …)… (finally …))`; it is a tombstone that raises an error.


## 4. Error chains (`from` and `cause`)

Python distinguishes implicit context (`__context__`) from an explicitly
declared cause (`__cause__`); air uses the map options `from=` and `cause=`.

* **`from` is automatic context.** A `raise` inside an `except` handler (or a
  `finally` with an error in flight) records the error being handled as
  `from=`:

  ```air
  (do (raise :disk-full) (except (:disk-full) (raise :save-failed)))
  ; => (error :save-failed from=(error :disk-full))
  ```

  An explicit `from=` overrides the automatic value, and `from=naught`
  suppresses it. Raising an error object exactly (the single-object rule) does
  not add `from`.
* **`cause` is explicit only.** Use `cause=` when one error transforms another:
  `(raise :save-failed cause=(error :disk-full))`.

Both are ordinary map entries, matchable like any other; `?*` and `??` capture
them, while `?&` does not.

`showerror` prints the chain recursively, labeling an explicit cause
`direct cause:` and an automatic context `during handling of:`:

```
air error: (error :save-failed)
  ...
direct cause:
  (error :disk-full)
```

The walk is depth-limited to 16 links to stop cycles.

## 5. Internal errors

A non-air exception raised by the host (bad index, closed file, permission
denial, parse failure, …) is presented to `except` as an error object too,
conventionally `(error :internal message)`. Air conditions use their own heads
(`:permission-denied`, `:extern-expired`, `:database-error`, `:form-not-found`,
`:proxy-unresolved`, `:un-storable`), all matched through their content.

```air
(do (get (1 2) 5) (except (:internal ?msg) msg))
```

## 6. Transactional integration (STM)

Error handling interacts directly with Air's Software Transactional Memory
(`Air.jl`) and persistence layer (`AirDB.jl`):

* **Uncaught errors abort.** An error that escapes its enclosing transaction
  boundary triggers an automatic **STM transaction abort and rollback**,
  preventing partial or corrupted state changes from committing. This is true
  even when an outer block catches the error: the abort has already happened.
* **Caught errors commit.** An error intercepted and handled inside the `except`
  clause of a `do`/`tx` running *inside* the transaction does not force a
  rollback, letting the transaction recover or handle validation failures
  gracefully.
* **Throws commit first.** A `throw` caught by a block *inside* the
  transaction returns normally and commits. A throw that escapes the
  transaction to an outer `catch=` is deferred: the body returns normally (so
  writes are not staged as an abort), watches run as on a normal exit, the
  transaction commits, and only then is the signal rethrown. If the transaction
  fails and Air retries, the deferred throw from the failed attempt is
  discarded and the body runs again, so the throw may never complete.
* **Handlers run in the transaction.** A handler notified while the transaction
  is open is ordinary code in that transaction: its writes are transactional
  and roll back with an abort. A watch error aborts; a watch throw replaces a
  pending throw (the last one wins). Exceptions raised by a `finally` or by
  finalizers/commit are outside the deferral and abort.
* **A `tx=true` definition is a boundary.** The body of such a `def` (or `val`)
  is an explicit `tx`, so an escaping error aborts the body's writes and an
  error caught by the body's own `except`, or a throw caught by its own
  `catch=`, commits. Nested inside another transaction, it joins it rather than
  opening a second boundary.

## 7. Source positions

Forms are data, so a position is not part of a form; the reader records the
character span of each container it parses, and a loader (`load-air`, a library
`init.air`, or the CLI) installs that record task-locally while it evaluates the
forms. Positions are best-effort: an environment that evaluates a bare form — a
REPL call, a test — has no source record and reports no position.

Two decorations are attached to an error as `frames`, innermost first:

* The **top-level form** during whose evaluation the error escaped, from the
  loader's span record.
* The **definition site** of the `def` whose body was executing, from the
  `src=` entry that `def`/`val` store in the namespace entry's body (the body is
  gated by `read` like any other; diagnostics read it internally). The innermost
  rule context wins, so an error inside `g`'s body reported while `f` calls `g`
  describes `g`'s definition, not `f`'s.

A frame is the map form `(name=… line=… col=… text=…)`, where `name` is the file
path (or `<interactive>`), `line`/`col` are 1-based, and `text` is the exact
source text of the form. `showerror` prints the innermost frame as
`(at name:line:col)` followed by the first line of its source text; a parse
error carries `name: ` before its message. The decoration never changes the
error object that `except` matches.

## 8. Tracing

`(trace body…)` evaluates its body and yields the last value. If an error
escapes, it yields the final data form

```air
(:trace (error :oops 1) frames=((name="/tmp/t.air" line=1 col=1 text="(def (bad ?x) (raise :oops x))")))
```

instead of throwing: the first element is the error object an `except` would
see, and `frames` lists the source frames known for it (`()` when none). The
result is final, so neither the error object nor the frames are re-reduced;
nested `trace` forms simply see the outer result as data. Use it to inspect a
failure without stopping a load or test.
