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

The composite constructors (`ui-code`, `ui-editor`, `ui-notebook`,
`ui-browser`, `ui-shell`, `ui-chat`), the connection forms (`ui-attach!`,
`ui-detach!`, `ui-attached`, `ui-connection`, `ui-connections`), the
`(current-ui)` builtin, and the theme forms (`ui-theme`, `ui-theme!`,
`ui-style`) are described below.

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

## Composite widgets

The catalog above is a set of single controls. The human-interface layer adds
**composite** widgets — a code block, a definition editor, a notebook, a
namespace browser, a chat, and a tabbed shell — on one shared interaction
framework: styled lines, a terminal key model, a single editable text buffer
with automatic indentation and bracket pairing, and air-aware highlighting.

A composite is still one inert `(ui KIND …)` form, and still data. What makes
it *durable* is that its constructor creates a `mut` holding its state, in the
current namespace's database, and names that mut in the form:

```air
(val notes (ui-notebook text="(+ 1 2)"))   ; the mut is created here, once
(ui-attach! notes)                         ; instantiate and run it here
```

`val` rather than `def` is the right binding: the constructor runs once, when
the `val` is defined, so `notes` yields the same state mut every time. Storing
the form anywhere reachable — a `val`, a `mut`, another widget — keeps the
widget alive, and dropping the last reference lets its state go. A caller may
pass `state=` to share one mut between two widgets.

| constructor | creates |
| --- | --- |
| `(ui-code [ns] text="" state=…)` | `(ui code-block …)`, an editable source buffer |
| `(ui-editor [ns] target=sym text= state=…)` | `(ui editor …)`, the definition editor |
| `(ui-notebook [ns] text= state= collapse-lines=20)` | `(ui notebook …)`, input/output cells |
| `(ui-browser [root] root= state=…)` | `(ui browser …)`, the namespace tree |
| `(ui-shell state=…)` | `(ui shell …)`, a tab bar of widget forms |
| `(ui-chat in= out= peer= state=…)` | `(ui chat …)`, a conversation over a stream pair |

The optional first argument — or `root=`, or the namespace current at the call
— names the namespace the widget evaluates in and targets, and is captured with
the instance like any other UI context.

### Keys

Every composite shares one key model. A terminal sends bytes, so the renderer
parses them into keys and keeps the distinctions that matter: CR is Enter and LF
is Ctrl-J, `ESC [`-prefixed sequences are the editing keys, `ESC` followed by a
printable character is Alt-`c`, and a lone `ESC` is flushed after 25 ms. Shift
and Ctrl modifiers on arrows, Home/End, and Page keys survive parsing, and a
bracketed paste arrives as one paste event.

| key | meaning |
| --- | --- |
| `Ctrl-J` | run the cell, save the buffer, send the chat draft |
| `Ctrl-Shift-J`, `Alt-Enter` | run the notebook cell and move to the next one, inserting a cell below at the end |
| `Ctrl-R` | run every notebook cell, in document order |
| `Ctrl-O`, `Alt-O` | clear the active cell's output, or every cell's |
| `Ctrl-G`, `Alt-G` | insert a notebook cell below, above |
| `Ctrl-V`, `Alt-V` | jump one cell or one message down, up |
| `PageUp`, `PageDown` | page the document, the log, or the current cell |
| `Tab`, `Shift-Tab` | switch tabs — never indentation |
| `Alt-1` … `Alt-9` | select a tab directly |
| `Alt-←`, `Alt-→` | move the active tab left, right |
| `Alt-W` | close every tab (asking once when edits would be lost) |
| `Esc` | pop one layer: a prompt, a scroll view, or a filter, then a notebook's select mode, then the tab, then the UI |
| `Enter` | a newline in a text buffer; activation in a browser |
| `Ctrl-N`, `Ctrl-P` | next, previous line — crossing notebook cells at their edges |
| `Ctrl-A`/`Ctrl-E`, `Ctrl-B`/`Ctrl-F`, `Alt-B`/`Alt-F` | line start/end, character and word motion |
| `Ctrl-D` | delete the character or selection forward |
| `Ctrl-K`, `Ctrl-U`, `Ctrl-W`, `Ctrl-Y` | kill to end, to start, a word; yank |
| `Ctrl-Z`, `Alt-Z` | undo, redo |
| `Ctrl-L` | re-indent the buffer from its layout |
| `Ctrl-S` | find in the buffer; again for the next match — in a browser, the filter line |
| `Alt-L` | go to a line number |
| `Alt-]` | jump to the bracket matching the one at the cursor |
| `Alt-;` | comment or uncomment the current line, or every selected line |

There is deliberately **no indent key**: Tab always switches tabs, and
indentation is enforced automatically on every newline. `Ctrl-Shift-J` reaches
the renderer as a distinct key on terminals that speak CSI-u or
`modifyOtherKeys`; `Alt-Enter` is its portable alias, and a terminal that
collapses it onto `Ctrl-J`'s byte simply runs the cell in place.

A **prompt** is a transient input line in place of the status message, and it
owns every key until it closes. `Ctrl-S` opens an incremental search seeded with
the previous query; the match is selected as you type and the row shows `n/total`
(or `no match`), `Ctrl-S`/`Down` and `Up` step through matches with wrapping,
Enter keeps the cursor at the match, and Esc restores the cursor to where the
search began. `Alt-L` collects a line number and Enter jumps there. Search is
literal, case-sensitive, and line-local. The browser's filter line is a prompt
in the same sense, and the shell leaves its keys to it the same way. Both
buffer prompts work inside a notebook
cell, where they take precedence over the notebook's own `Ctrl-J`/`Ctrl-G`/…
bindings; inside a shell, Esc reaches the prompt before it can close the tab.
`Alt-]` selects the matching parenthesis, so pressing it again comes back, and
a bracket inside a string or comment is text, not structure. `Alt-;` toggles a
`#` line comment on each non-blank line the selection touches (a selection that
ends at column 0 does not include that line), and a `#| … |#` opener is left
alone rather than mistaken for a line comment.

The status row shows the title, the namespace, the closure verdict or the
running job, and then right-aligns **whole key hints**. Each hint has a long and
a short spelling (`ctrl-j: run` and `^J run`); the row fits as many complete
hints as there is room for, never cutting one, and switches to the short
spellings only when they fit strictly more hints. A narrow terminal therefore
loses hints rather than showing a truncated one, and a row too narrow even for
the left part alone is clipped by the renderer.

### Code awareness: indentation, pairing, highlighting

A text widget reuses the declarations the pretty printer already obeys. On
Enter the editor scans the text before the cursor, keeps a stack of open
containers with their opening column and head symbol, resolves the matching
`(layout …)`, and continues at `open_col + indent` — or at the align column for
`indent=align`, or under the last pinned head element while the head is still
incomplete. A form with no declared layout continues at `open_col + 1`, and
top-level text starts at column 0. Typing a closer on a whitespace-only line
re-indents that line to its opener's column. The printer and the editor agree by
construction: feeding a pretty-printed form back line by line reproduces exactly
its own leading spaces.

Editing does not only indent the new line: every edit recomputes the canonical
indent of every line and shifts the lines *below* the edit by however much that
indent changed — typing an opener pushes the rest of the form right, a closer
pulls it back. A line that sits at or past its old canonical indent keeps the
extra spaces the user added, and a deliberately reduced indent stays reduced;
blank lines and lines whose first non-blank character is a closer simply take
the new canonical. Strings and comments are never re-indented, because their
contents are not layout. The form containing the cursor is tinted with the
`form_bg` role, so the innermost form being edited is visible at a glance.

`(`, `[`, and `{` insert their closer; typing a closer that already sits at the
cursor steps over it; Backspace inside an auto-paired empty pair removes both;
Enter inside one opens three lines with the closer at the opener's column. `"`
pairs only when the scanner is not already inside a string or a comment, and
strings, raw
strings, regex literals, and nested `#| … |#` comments are all respected. `'`
is never paired — it is a symbol character and reader sugar.

Highlighting colors atoms, strings, numbers, keywords, and wildcards; comments
(including nested block comments) are scanned out of the token stream and
colored separately; parentheses cycle through four roles by depth, and a
mismatched closer or an unclosed opener is drawn as an error. A focused buffer's
status line also reports the closure verdict from the reader itself — `code ·
closed`, `code · unclosed`, `code · error` — so a buffer that would not parse
cannot run.

### `code-block`

One buffer with an output area. `Ctrl-J` checks the closure verdict and refuses
with an inline reason (`unclosed input: …`, `parse error: …`); otherwise it
evaluates every top-level form in the widget's namespace under its captured
context and shows the result beneath the buffer. What the forms printed comes
first — `println` and its kin are captured into the output area instead of
leaking to the terminal at the cursor — and then only the **last** form's value
appears, rendered with the permission-aware pretty printer. The earlier forms
still run and still have their effects (a `def` defines, a `set!` sets); it is
only their *values* that are omitted, because the last one is the result.
A last value of `naught` contributes no lines at all, so a form run for its
side effects alone shows just what it printed, or a bare ruler and timing when
it printed nothing. Errors are drawn in the error role, and an interrupted run
reports `interrupted`. The text that produced the
current output is remembered, so editing the text without re-running leaves the
old output visible and muted rather than pretending it is current. The output
itself lives in the widget's state alongside the buffer, so a widget that is
closed and reopened shows its last result still under its text.

Each run is timed on the job's own task, and the duration is set into the ruler
above the output and appended to the status message (`3 forms · 0.8 ms`); the
ruler is drawn even when the run produced no output lines, so a `naught` result
still shows how long it took. The time is stored with the output, so it survives
a reopen. `_ui_duration` spells a duration in microseconds, milliseconds, or
seconds, whichever reads best.

### `editor`

The definition editor is the same buffer in `:editor` mode. `target=` names a
definition; the buffer starts from the entry's stored source (`src=`), and when
there is none it reconstructs the printed definition, best effort — comments and
layout choices are not recoverable. `Ctrl-J` parses the buffer, requires
top-level `def`/`val`/`namespace` forms, evaluates them in the target namespace
appending in the usual way (later definitions win), and reports errors inline.
The text that produced the current definitions is remembered as "saved".

The editor edits *source text*, not live forms.

### `notebook`

A column of paired cells: each has an input buffer and its output, and output is
never editable. The document is continuous — Up at the first line of a cell,
and `Ctrl-P` likewise, move to the last line of the previous cell; Down and
`Ctrl-N` at the last line move to the next — and `Ctrl-V`/`Alt-V` jump a whole
cell.

`Ctrl-J` evaluates the active cell in place, under the same output rules as a
[`code-block`](#code-block): what it printed comes first, then only the last
form's value, and a final `naught` shows nothing but a ruler and the timing.
`Ctrl-G` inserts an empty cell below and `Alt-G` above, moving the cursor there;
they insert only and never run. A cell longer than `collapse-lines=` (default
20) shows that window plus `… N more`; Enter opens it as a scrolling, editable
view and Esc returns to the collapsed document. `PageUp`/`PageDown` move ten
lines inside a cell.

Each cell records the exact input text that produced its output. When the input
changes, the output stays on screen rendered muted, so it is visibly stale;
re-running replaces it, and reverting the text clears the mark. Each cell also
records how long its last run took, shown in the ruler above its output (and
dimmed with the output when stale) and in the status row while it is active; the
time is stored with the cell, so a reopened notebook still shows it, and
clearing the output clears the time with it.

`Ctrl-R` runs the whole document: the non-empty cells are queued in order and
run one at a time, each starting only after the previous result has landed, so
a later cell sees what an earlier one defined, and the cursor follows the cell
being run. The queue stops at a cell that refuses to run (unclosed input), and
`Ctrl-J`/`Ctrl-R` are refused while a cell is in flight. `Ctrl-O` clears the
active cell's output and `Alt-O` clears every cell's, leaving the inputs and
their saved text alone.

Running and moving are separate so that a long run is not retyped: `Ctrl-Shift-J`
(or `Alt-Enter`) runs the active cell and then opens the next one for editing,
inserting a fresh cell below when the active cell is the last. It refuses while
any cell is already running, exactly as `Ctrl-J` does.

The notebook has two modes, as a Jupyter user expects. `:nav` is the editing
mode described so far, with the cursor in the buffer. A single Esc leaves it for
`:select`, a command mode in which the cursor is hidden and the active cell is
marked in the gutter and tinted with the `form_bg` role. In `:select` a bare key
is a command, not text:

| key | action |
| --- | --- |
| `Up`/`k`/`Ctrl-P`, `Down`/`j`/`Ctrl-N` | select the previous, next cell |
| `Home`, `End` | select the first, last cell |
| `Enter` | edit the selected cell (`:nav`) |
| `a`, `b` | insert a cell above, below and edit it |
| `d`,`d` | delete the selected cell |
| `z` | restore the cell deleted last |
| `i`,`i` | interrupt |
| `Ctrl-J`, `Ctrl-Shift-J`/`Alt-Enter` | run in place, run and advance |
| `Ctrl-R`, `Ctrl-O`/`Alt-O` | run all, clear the active/every output |
| `Ctrl-G`/`Alt-G`, `Ctrl-V`/`Alt-V`, `PageUp`/`PageDown` | insert, jump, page |
| `Esc` | bubble: the shell closes the tab (asking if it is dirty), then the UI |

The two doubled commands are **chords**: `d` and `i` are prefixes, not actions,
so a stray `d` cannot destroy a cell. While a chord is pending the status row
says so (`d… (d: delete)`), and any second key that is not the expected one is
swallowed and clears the chord. Esc in `:select` does not return to editing; it
bubbles outward, so from a notebook tab the sequence is edit → select → shell
(the shell asks before discarding a dirty cell) → UI.

Deleting keeps the removed cell, and `z` re-inserts it at the position it held;
a second delete replaces what `z` would restore. Deleting the only cell clears
it instead of leaving an empty document. `i,i` interrupts: the run-all queue is
emptied and every running cell's job is cancelled, the cell draws `interrupted`,
and the status row says `interrupting…` (or `nothing to interrupt`). Cancellation
is cooperative: the reducer checks the job's token every 64 reduction steps and
the whole-tree verbs every 1024 elements, and the forms that block (a stream
`fetch`, an `await`) honor it too, so a long computation stops promptly. A call
into Julia itself (an extern, a tensor operation, a database round trip) still
runs to completion.

### `browser`

The namespace tree, built from `(ns-entries …)` (see
[Namespaces](namespaces.md)). Unreadable and hidden entries are absent, not
greyed. Up/Down move, Home/End jump, PageUp/PageDown page, Right expands a
subnamespace or opens an entry, Left collapses or moves to the parent, and Enter
toggles a subnamespace or opens an entry.

`Ctrl-J` on a `def` (or a proxy) opens the definition editor for it; on a `val`
it opens a notebook tab in that val's namespace, seeded with the val's name, so
data can be explored without editing anything. `Alt-J` on a `val` opens the
editor for its definition instead.

`Ctrl-S` opens a **filter line**. Typing narrows the tree live to the entries
whose names contain the text, case-insensitively; the walk goes through every
subnamespace, so a match is found however deeply it sits and whether or not its
parents are expanded. Each match is shown flat with its namespace for context
(`main.util.· printer`), Up/Down move through the matches, and the status row
reads `n of N entries` (or `no match`). Enter accepts the text and closes the
line — the narrowing stays, and it is stored with the browser's view — while
Esc cancels back to what was accepted. A second Esc clears the accepted filter,
and only a third leaves the browser. A matching subnamespace is a jump: Enter on
it makes it the root and drops the filter. Filtering reads names only, never
docs, and a keystroke is bounded (it stops after a few thousand entries or a
few hundred matches), so a large database cannot stall the frame.

### `shell`

A tab bar over widget forms. A fresh shell starts with two tabs: a browser of
the current namespace and a scratch notebook in it. `Tab`/`Shift-Tab` cycle and
`Alt-1`…`Alt-9` select directly. The default tabs are opened when a renderer
starts the shell, not when the form is built, so `(ui-render …)` of a fresh
shell shows `(no tabs)` and creates nothing.

`Alt-Left`/`Alt-Right` move the active tab one place left or right (it stops at
the ends rather than wrapping), and `Alt-W` closes every tab: it asks once when
any tab has unsaved edits, then dismisses the shell. Both defer to a prompt
inside the active tab, which owns every key while it is open. The tab switches
(`Tab`, `Shift-Tab`, `Alt-1`…`Alt-9`) stay available even then.

`Esc` pops one layer: with a scroll view open it closes the view; in a notebook
it leaves editing for select mode (see [`notebook`](#notebook)); otherwise it
closes the active tab, first asking `y: discard` / `n: cancel` when the tab is
dirty (an edited buffer, or a notebook cell whose text differs from what
produced its output). Closing the last tab dismisses the shell — with no tabs
there is nothing left to show.

Tabs opened from the browser are runtime-only unless the user stores their form.
That is the same rule as everywhere else: a widget survives because something
reachable names it.

### `chat`

A conversation with a peer over a **pair** of streams that the caller supplies:

```air
(val to-alice   (stream))
(val from-alice (stream))
(val chat (ui-chat in=from-alice out=to-alice peer=:alice))
(ui-attach! chat)
```

The widget never finds its own transport: `out=` is where it posts and `in=` is
where it listens, and both are required — a chat with no input could never hear
anything and one with no output could never speak. Messages render as cells: a
header row naming the sender (`you` or the peer's name) and its clock, then the
body, with the two directions tinted differently by role (`user_bg` for this
side, `peer_bg` for the other), so a glance distinguishes them.

`Enter` inserts a newline and `Ctrl-J` sends, so a draft may be several lines.
The input is a full code block, so it gets the same indentation, pairing, and
highlighting as any other buffer, and it grows to five rows before scrolling.
`Ctrl-V`/`Alt-V` move one message and `PageUp`/`PageDown` one page.

Messages that arrive while the log is scrolled away from its newest entry are
**unread**: the status row counts them (`2 new · peer: alice`), the hint row
offers `Ctrl-V` with the count, and the log draws a rule (`── 2 new ───`) where
the unseen messages begin. Scrolling back to the bottom, sending, or receiving
while already there clears the count, and it is not stored — a reopened chat
starts with its whole log read.

**Code mode.** When the draft begins with `(`, it is code. On send, the source
is appended to *this side's* log only, evaluated in the chat's namespace under
the captured context, and the result is appended to both logs and posted. The
peer receives the **value**, never the source. A value that is a string arrives
as text; anything else arrives as highlighted source. An error stays on the
sender's side: it is logged as an error and nothing is posted.

A pump task fetches the incoming stream with a short timeout and appends
whatever it finds, so the log is live without the key loop ever blocking on
it. The pump starts when the instance's widget is first built and runs until
the widget is closed — not on attach/detach — so messages keep arriving and are
stored while no renderer is attached, and a detached conversation resumes where
it was.

## Connections

A widget is not bound to a terminal. A **connection** is where bytes come from,
and a renderer joins a connection to a widget instance. That separation is what
lets the same widget be shown locally, over SSH, or not at all, and what makes
detach and reattach cheap: only the renderer stops, never the widget.

Connections are recorded in the `.io.conn` namespace as ordinary data:

```
.io.conn.air         ns   — air's endpoints
.io.conn.air.std     mut  — air's local/stdio endpoint
.io.conn.air.s1      mut  — air's first remote session
.io.conn.alice       mut  — a user's endpoint
.io.conn.air.bob     mut  — a constituent's endpoint (`air:bob`)
```

A record is inert data — `(conn id=:s1 kind=:ssh user=:alice principal=:air:alice
since=(time …) tty=true cols=80 rows=24 attached=naught closed=naught)` — with
`read` granted to everyone and `write` to the record's owner. A constituent's
record is owned by its admin, so the constituent can read its own connection but
not edit it. The live byte source and the attached instance are process-local
and are never serialized; the record outlives the socket. Its `attached` field
is the key of a `ui-open` instance and `true` for an attach's own projection,
so the record says a widget is showing without naming something unregistered.

| form | meaning |
| --- | --- |
| `(ui-attach! [conn] widget)` | attach and run until dismissed; no `conn` means this session's own |
| `(ui-detach! [conn])` | stop the renderer; the element and its muts survive |
| `(ui-attached [conn])` | the widget attached there — its form for an attach, its key for an open instance — or `naught` |
| `(ui-connection [conn])` | one connection's record, or `naught` |
| `(ui-connections [user])` | the caller's live connections (`air` sees every user's) |
| `(current-ui)` | the `(ui …)` form this evaluation belongs to, or `naught` |

A `widget` argument is either a `(ui …)` form or a key naming an open instance.
A key's instance is a named process resource: it stays open across a detach and
`ui-close!` releases it. A **raw form** is attached as a *projection*: the attach
instantiates it without registering it, so nothing outside the attach can look
it up. The **element** — the form and the `mut` holding its state — is not owned
by the connection at all. The attach records itself in that state
transactionally (`controller=` is the connection's namespace path), so the
element knows which connection is showing it; detaching or closing the
connection clears that field and changes nothing else. Because `(ui-attached)`
returns the form itself, storing it (`val`, `set!`, a cell result) keeps the
widget alive after the attach returns.

One widget per connection is allowed; a second attach raises
`(error :ui-attached path)`, and a `ui-open` instance already attached elsewhere
is refused the same way. Only the task that opened a connection may attach to
it, because a byte source belongs to one reader; detaching is allowed from
anywhere.

The instance — not the renderer — owns the widget and its background work. Its
tree is built once, and a ticker applies finished jobs and writes the result
into the widget's durable state. So **detaching never waits for or stops an
evaluation**: a notebook's running cell and its run-all queue, a code block's
run, and a chat's evaluation all continue with no renderer attached, and their
results are in the state when the widget is reattached. Only an explicit
interrupt (the notebook's `i,i`) cancels one, and it does so cooperatively.
Detaching flushes the widget's on-screen state (text, output, cursor) into its
`mut`; a projection is
retracted by the ticker only once no renderer and no job remain, so a running
job's result is written before the projection goes away. Only `ui-close!`
tears a named instance down and releases connection-era resources such as
the chat pump. Ctrl-C is the exception: it cancels the work the widget has in
flight before it raises `(error :ctrl-c)`.

`ui-show` is exactly "attach this session's connection": it looks up the current
session's connection and attaches there, so the older spelling keeps working.
`ui-run` is open + attach + close.

`(current-ui)` is bound around every evaluation an instance runs — a notebook
cell, a code block's run, a chat code message — and names the very form the
instance was built from, so `(val saved (current-ui))` inside a cell keeps that
widget. Outside any instance evaluation it is `naught`; an interactive SSH login
binds it to the session's default UI instead (see
[SSH](ssh.md#interactive-uis-over-ssh)).

## The theme

Widgets name **roles** — `:text`, `:muted`, `:accent`, `:string`, `:comment`,
`:number`, `:keyword`, `:wildcard`, `:symbol`, `:paren1`–`:paren4`, `:error`,
`:success`, `:warning`, `:selection`, `:cursor`, `:focus`, `:user_bg`,
`:peer_bg`, `:code_bg`, `:tab_active`, `:tab_inactive`, `:status`, `:prompt`,
`:border` — and the
renderer resolves them to a style at draw time. The default is ANSI-16 plus a
few 256-color background tints, so it works on any xterm-compatible terminal.

```air
(ui-theme)                        ; => (theme accent=(bold=true fg=bright_blue) … string=green …)
(ui-theme! string=:bright-yellow user-bg=:color235)
(ui-theme! reset=true)            ; restore the defaults first
(ui-theme! reset=true (ui-theme)) ; restore exactly the saved palette
(ui-style :string)                ; => (style bg=default bold=false … fg=green …)
```

`ui-theme` prints a role as a **bare color** when its foreground is the only
thing that departs from plain text, and as a **field map** otherwise, so a role
with a background (`selection=(bg=blue)`) or a weight (`error=(bold=true
fg=bright_red)`) says so. A field is named when it departs from plain text or
from the role's own default, so a role deliberately restored to plain still
round-trips. `ui-theme!` accepts the same two entry shapes, and takes a whole
theme map as an optional positional argument — bare, or under the `theme` head
that `ui-theme` emits — so `(ui-theme! reset=true (ui-theme))` restores exactly
what was saved. Role entries given alongside a map win over it.

A color read back from these maps prints as a bare symbol, as every symbol in
a map value does; the keyword spelling (`:green`) is accepted on input.

A color is an ANSI name (`:red`, `:bright_cyan`, …), a 256-color index
(`:color235`), or an `rgbRRGGBB` triplet; a string spelling works too and `-`
and `_` are interchangeable. `ui-theme!` is process-global; without `reset=true`
an entry layers on the role's current style.

A composite constructor also takes `theme=`, a map from roles to that widget's
style for them:

```air
(ui-notebook text="(+ 1 2)" theme=(string=:red accent=:magenta))
(ui-code theme=(string=(fg=:red bg=:blue bold=true) comment=(color=:cyan dim=true)))
```

An entry is either a bare color — a foreground recolor — or a map naming the
fields to change: `fg=`/`color=`, `bg=`, `bold=`, `dim=`, `italic=`,
`underline=`, and `reverse=`. Either form starts from the role it inherits, so
an entry that names only `bold=` keeps the inherited ink and an omitted role is
fully inherited. `color=` is a synonym for `fg=`, so naming both in one entry,
or naming the same field twice, is an error. Only the roles it names change,
and only while that widget is drawing — the process theme is untouched. A
widget's theme also covers the rows it composes, such as the tabs a shell draws
for its children. The map is resolved when the widget is built, so an unknown
role, an unknown field, a duplicated field, an entry that names no field at
all, a non-boolean flag, or a value that is not a color is an error at that
point rather than a silent fallback.

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

`(ui-show :k)` attaches this session's connection (see **Connections**), which
is how the same call works over SSH and at a local terminal. It enters the
alternate screen, draws a frame, and redraws in place. The writer remembers the
previous frame and sends only the rows whose styled text changed, so a keystroke
normally costs one row and a cursor move rather than a full screen; a resize
invalidates the whole frame. It restores the screen and cursor in `finally`.
Without an interactive terminal it raises `(error :no-renderer …)`.

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
- **Ctrl-C** aborts: the screen is restored, every evaluation the widget has in
  flight is cancelled, and `ui-show` raises `(error :ctrl-c)`, exactly as Ctrl-C
  at the REPL prompt raises `:ctrl-c`, so a surrounding `except` (or the REPL)
  handles it like any other error. A cancelled run draws `interrupted` in the
  widget, the same marker a notebook's `i,i` leaves.

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

A composite widget adds two things the abstract runtime does not need. Its tree
is built on first attach and then reused for every later renderer, so interaction
state (cursor, scroll position, an open scroll view) survives a detach; and a
ticker owned by the instance applies its background jobs and writes their results
into the widget's durable `mut`, whether or not a renderer is attached.

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

- **An attached UI is modal.** A connection shows one widget at a time until it
  is dismissed; a widget cannot share a session with the REPL prompt.
- **The terminal renderer needs a pty.** Both backends (SSH channel and local
  terminal) take over a terminal; a web renderer and incremental subtree updates
  are follow-ups. The abstract layer, the text renderer, and the shell describe
  the contract they must meet.
- **A key is what the terminal can say.** A lone Esc is separated from Alt by a
  25 ms timeout, so a very fast Alt-key is indistinguishable from Esc and the
  key; a terminal that maps Enter to LF loses Ctrl-J. xterm is the reference.
- **Evaluation stops only at a cancellation point.** A cell's evaluation runs on
  a spawned task, so the frame stays live while it works, the status row names
  the job, and Ctrl-C cancels it: the reducer checks the token every 64 steps
  and the whole-tree verbs every 1024 elements. A call into Julia (an extern, a
  tensor operation, a database round trip, a blocking stream `fetch` or promise
  `await`) still runs to completion, and work the evaluation spawned on another
  task is not reached. Esc is different: dismissing neither waits for nor stops
  a job, so it finishes in the background and its result is stored for the next
  attach.
- **Passwords are obscured, not protected.** A `password-input` value is an
  ordinary form, readable with `ui-values` and assertable like any other.
