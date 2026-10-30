# User interfaces

Air has an abstract user interface. A UI is a tree of ordinary air forms headed
`ui`; the forms describe *what* an element means, not how it is drawn, so the
same tree can be presented by a terminal over SSH, by a web page, or by any
other renderer that follows the contract. Air owns the values, the validation,
the callbacks, and the facts an element asserts; a renderer is only a view.

```air
(ui-open :prefs
  (ui column
    (ui label text="Experiment configuration")
    (ui text-input id=:experiment-name initval="experiment-01"
                   label="Experiment name" assert=(experiment-name _))
    (ui dropdown id=:device options=(("CPU" :cpu) ("GPU" :gpu))
                 initval=:gpu label="Compute device" assert=(compute-device _))
    (ui slider id=:threshold initval=0.8 min=0.0 max=1.0 step=0.01
               label="Confidence threshold" assert=(confidence-threshold _))
    (ui button label="Done" on-click=(() -> (ui-dismiss! :prefs)))))
(ui-show :prefs)
(ui-values :prefs)          ; => (device=:gpu experiment-name="experiment-01" …)
(facts .main)               ; => (' (compute-device :gpu) …)
```

The forms resemble widgets in the style of `ipywidgets`, but an element's value
lives in the UI runtime, not in a renderer, and an `assert` makes that value an
ordinary fact that rules and functions use without knowing a UI exists.

## Principles

1. **Interface independence.** A `(ui …)` form names a semantic element, not a
   terminal or web control.
2. **Composability.** Elements nest arbitrarily; layout elements arrange other
   elements.
3. **Statefulness.** Interactive elements hold a value air can read and update.
4. **Reactivity.** A change can run a callback and revise a fact.
5. **Validation.** Air validates every value itself; a renderer may help, but
   it is never trusted.
6. **Identity.** An element may carry an `id` that survives a redraw or an
   update.
7. **Extensibility.** New widget kinds follow the same conventions; a renderer
   that cannot present one must say so rather than substitute different
   semantics.

## A UI tree is inert data

`ui` is a **reserved head**, like `error` and `signal`: a form headed `ui` never
reduces, at any depth, so a tree is descriptive data until `ui-open`
instantiates it.

```air
(ui checkbox initval=true)                    ; => (ui checkbox initval=true)
(ui label text=(+ 1 2))                       ; => (ui label text=(+ 1 2))
```

That is what keeps `assert=` and `on-change=` raw: `(ui …)` is data, and the
runtime evaluates the parameters it understands itself, at instantiation.
`let` and `with` still *build* trees, because they substitute textually before
evaluating:

```air
(let (n=0.8)
  (ui slider initval=n min=0.0 max=1.0 label="Threshold"))
```

Every parameter except `assert` is evaluated once when `ui-open` instantiates
the element, so a parameter may be any expression —
`initval=(get $.config.threshold)` just works. `assert` is evaluated with `_`
bound to the element's current value, there and on every change.

## Common parameters

| parameter | meaning |
| --- | --- |
| `id` | a keyword, symbol, or string naming the element within its instance |
| `label` | human-readable text; descriptive, never an identifier |
| `description` | supplementary explanatory text |
| `disabled` | a Boolean; a disabled element still displays its value but a user may not change it |

An `id` is unique within an instance (a duplicate is an error) and independent
of position in the tree. `(ui-values :k)` and `(ui-set! :k :id v)` address
elements by it. An element without an `id` is still a distinct element with an
internal path; it can carry `assert=`/`on-change=` but air cannot address it.
Other forms of `id` are rejected with a clear error.

A `disabled` element refuses a *user* change — the renderer reports it as
invalid — while air itself may still update it with `ui-set!`.

## Stateful elements

An interactive element holds a current value. `initval` establishes it; a kind
with a type-specific default (`false` for `checkbox`, `""` for `text-input`, …)
may omit it. Two parameters let a change participate in the rest of air.

### `on-change`

A function called after a value change has been accepted and installed:

```air
(ui checkbox id=:debug initval=false label="Enable debugging"
  on-change=((?old ?new) -> (record-change old new)))
```

It is **not** called at creation (initialization is not a change), and it is not
called when an update does not actually change the value. An error it raises
propagates as an ordinary air error; the value stays installed.

### `assert`

A fact form evaluated with `_` bound to the element's current value:

```air
(ui checkbox initval=false label="Enable debugging"
  assert=(if _ (debugging-enabled true) naught))
```

The result must be a fact or `naught`. When the element is instantiated the
fact is asserted; on every change the element's assertion is *revised* to the
new result, in one logical revision, so the old fact never coexists with its
replacement. `naught` retracts it, and an identical result is a no-op. Either
`on-change` or `assert` may be supplied without the other.

The assertion is maintained in the **namespace that was current when the
element was instantiated**, even if the process later switches namespaces, and
it therefore needs `writefact` there. The runtime labels every fact it asserts
with a reason unique to the instance and element, so retracting our fact never
disturbs an identical fact asserted elsewhere by other air code:

```air
(assert (experiment-name "xyz"))   ; asserted independently
(ui-set! :a :n "other")            ; our labeled record is revised
(facts .main)                      ; (experiment-name "xyz") survives
```

Removing an element — by `ui-update!` or `ui-close!` — retracts only the fact
that element owned.

## Validation and errors

Air validates every incoming value before accepting it; a renderer never
validates.

- The value, the constraint, and the error message are air's.
- An invalid update changes nothing: no value, no callback, no assertion
  revision.
- A renderer is told the reason and displays it, keeping the last accepted
  value.
- `(ui-set! :k :id v)` raises `(error :ui-invalid :id "reason")` for the same
  failure.

The constraints are per kind: bounds, step alignment, option membership,
`lo ≤ hi`, non-empty `required` text, and so on. See the catalog below.

## The widget catalog

### Boolean inputs

`checkbox` and `toggle` hold `true` or `false`; the difference is
presentational. `initval` defaults to `false`.

```air
(ui checkbox initval=true label="Dark Mode?")
(ui toggle initval=false label="Enable debugging")
```

### Text inputs

`text-input` and `text-area` hold a string; `text-area` also takes `rows=`.
`password-input` holds a string too, but the renderer obscures it — visual
obscuring is **not** secure storage: the value is an ordinary air value,
reachable by `ui-values` and by `assert`.

`initval` defaults to `""`, `placeholder` is an optional hint, and
`required=true` rejects an empty string.

```air
(ui text-input initval="" label="Search" placeholder="Enter search terms...")
(ui text-area initval="" label="Notes" rows=8)
(ui password-input label="API Token" placeholder="Enter token...")
```

### Numeric inputs

`int-input` holds an integer, `float-input` a number; both take optional `min`,
`max`, and `step` (default `1`). `slider` is a bounded number and requires
`min` and `max`; it also takes `orientation=` (`:horizontal` or `:vertical`),
`readout=` (show the value), and `continuous-update=` (communicate while
dragging rather than on release). These four require `initval` — unlike a
Boolean or a string, an uninitialized number has no sensible default.

```air
(ui int-input initval=1000 min=1 max=100000 label="Number of iterations")
(ui slider initval=0.8 min=0.0 max=1.0 step=0.01 label="Threshold")
```

`range-slider` holds a two-element sequence `(lower upper)` with `lower ≤
upper`; both ends obey `min`, `max`, and `step`.

```air
(ui range-slider initval=(0.2 0.8) min=0.0 max=1.0 step=0.01
     label="Confidence interval")
```

### Selection

An option is either a bare value — its label is derived from the value — or a
`(label value)` pair. The **value** is what air receives; the label is only
displayed.

```air
(ui dropdown options=(:small :medium :large) initval=:medium label="Image size")
(ui dropdown options=(("CPU" :cpu) ("GPU" :gpu)) initval=:gpu
     label="Compute backend")
(ui radio-group options=(:mean :median :maximum) initval=:mean
     label="Aggregation method")
(ui selection-slider options=(:low :medium :high) initval=:medium
     label="Processing quality")
```

`dropdown`, `radio-group`, and `selection-slider` hold one option value,
require `initval` and `options`, and reject anything that is not in `options`.
`multi-select` holds a sequence of selected values, each of which must be an
option; it requires `options` and defaults to an empty selection.

```air
(ui multi-select options=(:mean :median :maximum :minimum)
     initval=(:mean :median) label="Statistics to calculate")
```

### Actions

A `button` has no value. Its `label` is its text and `on-click` is a zero-argument
function called when it is activated (Enter or Space in a terminal).

```air
(ui button label="Run analysis" on-click=(() -> (run-analysis)))
(ui button label="Cancel" disabled=true)
```

A button does not take `initval`, `on-change`, or `assert`.

### Display

`label` shows `text=`; `progress` shows a read-only `value=` between `min`
(default `0`) and `max` (default `1`); `status` shows a categorical `value=`
(`:success`, `:warning`, `:error`, `:pending` are suggested, but any value is
accepted and the presentation is renderer-dependent).

```air
(ui label text="Experiment experiment-01 is running.")
(ui progress value=0.65 label="Processing samples")
(ui status value=:success label="Input validation")
```

### Layout

Layout elements hold children and have no value.

`column` stacks children vertically; `row` places them horizontally; `group`
groups them, optionally under a `label`; `tabs` presents separate groups of
children and takes only `tab` children; `accordion` presents expandable groups
and takes only `section` children.

```air
(ui column
  (ui label text="Experiment settings")
  (ui text-input initval="experiment-01" label="Name")
  (ui group label="Display settings"
    (ui checkbox initval=true label="Show labels")
    (ui checkbox initval=false label="Show grid")))

(ui tabs
  (ui tab label="General" (ui checkbox initval=true label="Enabled"))
  (ui tab label="Advanced" (ui float-input initval=0.01 label="Tolerance")))

(ui row
  (ui button label="Run")
  (ui button label="Cancel"))
```

`tab` and `section` take a `label` and any children. A tree is arbitrarily
nested.

## The air surface

Instances are named, process-global resources, like `ssh-server`. A key is a
keyword, symbol, or string; the colon is dropped, so `:prefs` and `"prefs"` name
the same instance.

| form | meaning |
| --- | --- |
| `(ui kind params… children…)` | one element; inert data |
| `(ui-open [key] tree)` | instantiate and register; returns the key (generated when absent) |
| `(ui-show key)` | attach this session's terminal renderer and block |
| `(ui-run tree)` | open, show, and close; returns the final values |
| `(ui-render key width=80)` | a deterministic text snapshot |
| `(ui-values key)` | a mapping of every identified interactive element's value |
| `(ui-value key id)` | one element's value |
| `(ui-set! key id value)` | a programmatic update |
| `(ui-update! key tree)` | re-instantiate the tree, keeping matching values |
| `(ui-dismiss! key)` | leave the renderer; `ui-show` returns |
| `(ui-close! key)` | retract the instance's facts and forget it |
| `(ui-instances)` | the caller's open instance keys |

`ui-open` returns the key as a keyword; with no key it generates one (`:ui1`,
`:ui2`, …). A key already in use is an error. Instances are owned by the user
who opened them: `air` sees them all, another user sees only its own, and an
operation on someone else's instance raises an error.

`ui-update!` re-instantiates the tree in one step. An element whose `id`
survives keeps its current value when the new kind still accepts it (so a
surviving field is not reset to its new `initval`), new elements take their
`initval`, removed elements' facts are retracted, and changed parameters take
effect.

`ui-close!` is idempotent, so a cleanup path need not know whether the UI
already closed itself.

## Renderers

A renderer is a view over an instance. It reads the tree, values, and
validation reasons, presents them somehow, and reports only semantic events —
`(:set id value)`, `(:click id)`, `(:dismiss)` — which the runtime routes
through one validated update path. It never validates, stores, or asserts
anything, and it never echoes an engine-originated update back, because it has
no path to do so.

The runtime notifies every attached renderer after every accepted change,
including a programmatic one, so multiple views of one instance stay in step.
An equal-value set is a no-op, so a redraw loop cannot oscillate.

### The text renderer

`(ui-render :k width=80)` is the headless renderer, for documentation and tests.
It is deterministic: a `column` stacks, a `row` shares a line, a `group`
indents, `tabs` shows the first tab, and a checkbox is `[x]` or `[ ]`.

```air
(ui-open :r (ui column
  (ui label text="Config")
  (ui text-input id=:n initval="exp-01" label="Name")
  (ui dropdown id=:d options=(("CPU" :cpu) ("GPU" :gpu)) initval=:gpu
               label="Device")))
(ui-render :r)      ; => "Config\nName: exp-01\nDevice: GPU"
```

### The terminal renderer

`(ui-show :k)` requires an interactive SSH session (`src/ssh/`); otherwise it
raises `(error :no-renderer …)`. It enters the alternate screen, draws a frame,
redraws in place (clearing one line at a time rather than the whole screen, to
avoid flicker), and restores the screen and cursor in `finally`.

Focus is the renderer's, and Tab / Shift-Tab (or Up / Down) cycle through the
value-bearing and button elements:

- **Space** toggles a checkbox or toggle, activates a button, or begins editing
  a text field with a space;
- **Enter** activates a button or commits a text field edit;
- **Left/Right** step numbers, sliders, and selection widgets; Home/End jump to
  the bounds or the first/last option; in a `multi-select`, Left/Right moves the
  selection and Space toggles it;
- printable characters edit a text element with a drawn cursor.

A text or slider edit commits on Enter or when focus leaves the element; there
is no key release in a terminal, so that is what `continuous-update=false`
means.

There are two ways out, deliberately different:

- **Esc** dismisses gracefully: the screen is restored and `ui-show` returns
  `naught`.
- **Ctrl-C** aborts: the screen is restored and `ui-show` raises
  `(error :ctrl-c)`, exactly as Ctrl-C at the REPL prompt raises `:ctrl-c`, so a
  surrounding `except` (or the REPL) handles it like any other error.

A `Done` button that calls `(ui-dismiss! :k)` is the same graceful path.
Validation failures appear on the status line, and the display keeps the last
accepted value.

## Lifecycle

1. **Creation.** `ui-open` reduces the tree once and instantiates each element:
   the kind is checked, every parameter is evaluated in the caller's scope, and
   an `assert`/`on-change` keeps the lexical names it will need when it fires.
2. **Initialization.** Defaults and `initval` establish values; initial
   assertions are evaluated and asserted. A failure here retracts whatever was
   already asserted and leaves no instance behind.
3. **Presentation.** One or more renderers display the instance.
4. **Interaction.** A renderer reports a semantic event.
5. **Revision.** Air validates and accepts or rejects it, installs the value,
   revises the assertion, and runs the callback.
6. **Removal.** `ui-update!` or `ui-close!` retracts the facts the removed
   elements owned, never facts asserted elsewhere.

A callbacks and assertions run in the namespace, `val` bindings, and identity
captured at instantiation, so a UI opened inside `(namespace .app …)` keeps
writing `.app` even when the value is changed from another namespace or task.

## Example: experiment configuration

```air
(ui-open :experiment
  (ui group id=:experiment-configuration label="Experiment configuration"
    (ui text-input id=:experiment-name initval="experiment-01"
                   label="Experiment name" assert=(experiment-name _))
    (ui dropdown id=:compute-device
                 options=(("CPU" :cpu) ("GPU" :gpu)) initval=:gpu
                 label="Compute device" assert=(compute-device _))
    (ui int-input id=:iterations initval=1000 min=1 max=100000
                  label="Number of iterations" assert=(iterations _))
    (ui float-input id=:learning-rate initval=0.001 min=0.000001 max=1.0
                    label="Learning rate" assert=(learning-rate _))
    (ui slider id=:confidence-threshold initval=0.8 min=0.0 max=1.0 step=0.01
               label="Confidence threshold" assert=(confidence-threshold _))
    (ui checkbox id=:save-intermediate initval=true
                 label="Save intermediate results" assert=(save-intermediate _))
    (ui row
      (ui button label="Run experiment" on-click=(() -> (run-experiment)))
      (ui button label="Done" on-click=(() -> (ui-dismiss! :experiment))))))
(ui-show :experiment)
```

Afterwards the selections are ordinary facts, so a rule can use
`(compute-device ?d)` without knowing where `?d` came from.

## Limits

- **A shown UI is modal.** `ui-show` owns the session until it is dismissed;
  there is no non-blocking dashboard yet.
- **The terminal renderer needs a pty.** A local `stty`-driven renderer, a web
  renderer, and incremental subtree updates are follow-ups; the abstract layer
  and the text renderer are the contract they must meet.
- **Passwords are obscured, not protected.** A `password-input` value is an
  ordinary form, readable with `ui-values` and assertable like any other.
