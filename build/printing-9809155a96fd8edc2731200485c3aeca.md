# Printing and layouts

Air values are printed as air source: what you write is what you read back. Two
printers serve different needs — the **flat** printer, which is what forms mean,
and the **pretty** printer, which breaks a form across lines to fit a width.
A **layout** declaration tells the pretty printer how a particular shape of form
should break.

## Two printers

`air_string(x)` is the flat spelling: one line, every map entry after the
sequence elements, in the canonical order. `air_pretty_string(x; width=80)` is
the same text broken across lines to fit `width`, and it is identical to the
flat spelling when the form already fits. Both are Julia functions; in air, the
`form->string` verb is the same pair:

```air
(form->string x)                               # flat
(form->string x pretty=true width=22)          # broken to fit 22 columns
```

For `x` the form `(foo (alpha 1) (beta 2))`, the second is

```
(foo (alpha 1)
 (beta 2))
```

The REPL prints results with the pretty printer at the terminal's width. The
`air` command reads `COLUMNS` and passes it through; the default is 80. In
Julia, both `air_string(env, x)` and `air_pretty_string(env, x; width=…)` respect
the current user's permissions (an unreadable entry prints as a handle).

### How the printer breaks a form

The greedy rule is simple: print elements on the current line while they fit,
and start a new line when the next one would exceed the width. The **head**
elements are pinned to the opening line; the rest start at the **indent** column.
A form that fits entirely stays on one line, so the printer never spends more
vertical space than it needs.

## Declaring a layout

A layout is an ordinary air form:

```air
(layout (myverb ?first ?&rest) head=2 indent=2 map=block)
```

- `PATTERN` selects the forms to lay out. It is matched **structurally** — the
  same wildcards and rest markers as a [`def`](patterns.md) pattern — against the
  form's shape, before any evaluation. It may contain literals, wildcards, and
  one rest marker, which must be the last pattern element. It may not use `\`
  conditions (there is no scope available while printing), and it may not carry
  map entries.
- `head=N` pins the first `N` sequence elements to the opening line (default 1).
  `(def (f ?x) …)` uses `head=2`, so the name and its arguments stay together.
- `indent=M` puts continuation lines `M` columns past the opening `(` (default
  1). `indent=align` instead aligns them with the column where the last pinned
  element starts.
- `map=block` puts every `key=value` entry on its own line; `map=inline` (the
  default) packs them like the other elements.

```air
(layout (myverb ?first ?&rest) head=2 indent=2 map=block)
(myverb target (a 2) (b 3) k=1)   # at a narrow width:
# (myverb target (a 2)
#   (b 3)
#   k=1)
```

## The defaults

The interpreter installs a small set of layouts at startup. Your own
declarations are consulted first; these are fallbacks, and a declaration for the
same shape replaces its default.

| head | head= | indent= | map= |
| --- | --- | --- | --- |
| `def` | 2 | 2 | block |
| `let` | 2 | 2 | inline |
| `val` | 2 | 2 | block |
| `if`, `cond` | 1 | 2 | inline |
| `do`, `tx` | 1 | 2 | block |
| `namespace` | 2 | 2 | inline |
| `using` | 1 | 2 | inline |
| `logic` | 2 | 2 | inline |
| `rule` | 1 | 2 | inline |
| `assert` | 2 | 2 | inline |
| `error` | 2 | 2 | inline |

A form whose head has no declaration uses the generic layout: one pinned element
and a continuation indent of one column.

## Managing declarations

```air
(layout (myverb ?first ?&rest) head=2 indent=2)   # declare (or replace)
(layouts)                                         # the declarations, newest last
(clear-layout :myverb)                            # drop the ones for one head
(clear-layout :all)                               # drop every user declaration
(reset-layouts)                                   # the same as :all
```

Registering a pattern identical to an existing declaration replaces it, so
evaluating a declaration twice is harmless. The built-in defaults cannot be
removed — `clear-layout` only drops your own declarations, after which the
default (or the generic layout) applies again.

A layout is a **process-global registration, not a definition**: `(sandbox …)`
does not undo one, and it is not part of a transaction. That is deliberate —
layouts describe how code is *displayed*, not what the code does — so keep them
in startup code or a library rather than in a transaction whose outcome matters.

Layouts are also purely presentational: the flat `air_string` is unaffected, and
pretty output re-reads as exactly the same form as the flat output — reading
`(form->string x pretty=true)` and `(form->string x)` with `string->form` gives
two `eq?` values.
