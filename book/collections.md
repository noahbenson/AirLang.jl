# Collections

A form is a collection: a sequence of elements and a map of key–value entries.
The same verbs operate on both, and a scalar is treated as its own sole
sequence element, so collection code rarely needs a special case for one value.
This chapter covers access and update, the wildcard key, the whole collection
surface, the higher-order verbs, threading and pipelines, and traversal by
depth. [The data model](data-model.md) describes the form itself;
[Tables](tables.md) and [Tensors](tensors.md) add their own path grammars.

## Counting and looking in

`count` is the number of **sequence elements**; `length` is the number of
entries, sequence elements plus map entries. A scalar is a singleton
(`(count 5)` is `1`, `(count naught)` is `0`), a table reports its rows, and a
tensor its elements.

```air
(count (a=1 b=2))       # => 0
(length (a=1 b=2))      # => 2
(count (1 2 a=3))       # => 2
(in 2 (1 2 3))          # => true       (member? is the same with its arguments in the other order)
(contains? (a=1) :a)    # => true
(haskey (a=1) :a)       # => true
(keys (a=1 b=2))        # => (:a :b)
(vals (a=1 b=2))        # => (1 2)
(empty? ())             # => true
```

## `get`: the single accessor

`get` takes a path of keys. An **integer** indexes the sequence (1-based); a
**negative** integer counts from the end; `0` is the whole form; and `n + 1` is
the append position in a setter. A **keyword** names a map entry, and a bare
symbol key is read as a keyword:

```air
(get (a b c) 2)          # => b
(get (a b c) -1)         # => c
(get (a=1 b=2) :b)       # => 2
(get (a=1 b=2) b)        # => 2
(get ((a=1) (a=2)) 2 :a) # => 2       (a path walks the form)
(get 5 1)                # => 5       (a scalar is its own sole element)
```

The `.` accessor is pure sugar: `f.a.b` is `(get f :a :b)`, `f.:x` is
`(get f :x)`, and `...` splices (`(f a... b)`). Its keys are **held**, so a bare
suffix is the literal keyword and `f.a` ignores a variable `a`; `~` evaluates
one key, so `f.~k` is `(get f (preval k))` and `f.~a.b` is
`(get f (preval a) :b)`. A leading-dot atom such as `.util.a` is a namespace
path and reads as `(get . :util :a)` (see [Namespaces](namespaces.md)).

`hold=true` makes a root hold transparent: the path then indexes the *content*
without reducing intermediate values, and the result is held. This works for
any form that keeps its arguments as data, not only a hold:

```air
(get (' f (1 + 2)) 2 hold=true)     # => (' 1 + 2)
(get (part add 10) 2 hold=true)     # => 'add
```

The `hold-` family is the same idea as a prefix: `hold-get`, `hold-nth`,
`hold-with`, `hold-wout`, `hold-push`, `hold-push-in`, `hold-join`,
`hold-join-in`, `hold-update`, `hold-update-in`, and `hold-held?` operate on a
held form's content and return the result held, with `hold=` selecting the
result's heldness. See [Holds](data-model.md#holds).

## The wildcard key (`:`)

The lone `:` names **every entry of a level**: each sequence element in order,
then each map value in canonical key order (the printer's order; air does not
preserve the order in which keys were written).

* In `get` it selects the whole level and maps the rest of the path over each
  entry, so the result is an ordinary sequence and map values lose their keys:
  `(get ((a=1) (a=2)) : :a)` is `(1 2)`, `(get (a=1 b=2) :)` is `(1 2)`, and
  `(get (1 2 a=3) :)` is `(1 2 3)`.
* In `with` a scalar is **broadcast** to every entry (`(with (a=1 b=2) : 9)` is
  `(a=9 b=9)`) and a container supplies one value per entry in that same
  canonical order (`(with (b=2 a=1) : (7 8))` is `(a=7 b=8)`), keeping each
  sequence position and map key in place.
* In `wout` and `drop` it removes every entry, and as an intermediate step it
  applies the rest of the path to each one
  (`(wout ((a=1 x=0) (a=2 x=0)) : :x)` is `((a=1) (a=2))`).

**Map entries can be unintuitive.** Map values are paired in *canonical key
order*, not source order, so write the values in the order the printer would
show the keys. On a mixed level the sequence elements always come first, so
`(with (1 2 a=3) : (7 8 9))` is `(7 8 a=9)`. A scalar sets every entry, but a
one-element form is one value, not a broadcast, so `(with (a=1 b=2) : (9))`
raises — air never collapses `(9)` into `9`. A table keeps its own meaning for
`:` (all rows or all columns), and a lone `:` raises on a table path.

## Updating

Every update is pure: it returns a new form and leaves its argument unchanged.

```air
(with (a=1 b=2) :a 9)              # => (a=9 b=2)
(with ((a=1) (a=2)) 2 :a 9)        # => ((a=1) (a=9))
(wout (a=1 b=2) :a)                # => (b=2)
(drop (a=1 b=2) :a)                # => (b=2)
(update (a=1) :a inc)              # => (a=2)
(update-in (a=(b=1)) :a :b inc)    # => (a=(b=2))
(push (1 2) 3 4)                   # => (1 2 3 4)
(pop (1 2 3))                      # => (1 2)
(push-in (a=(1 2)) :a 3)           # => (a=(1 2 3))
(join (1 2) (3 4))                 # => (1 2 3 4)
(join (a=1) (b=2))                 # => (a=1 b=2)
(merge (a=1) (a=2 b=3))            # => (a=2 b=3)
```

`with` takes a path and then one value; `wout` removes the entry at a path;
`update` and `update-in` replace the subform with `(f old)` (a missing
`update-in` key is `naught` to `f`); `push` appends; `pop` removes the last
sequence element; `join` concatenates sequences and merges maps. An integer key
of `n + 1` in a setter appends. `insert` inserts at an index, `split-at` splits
at one, and `prepend` adds elements at the front.

## The collection surface

The verbs fall into a few families. Every one is listed with its exact
signature in the catalogue — `(doc NAME)` — and this section is a map of what is
there.

**Positional access.** `first`, `second`, `third`, `last`, `rest`, and `nth`.
These are hold-blind: on a held form `(first (' a b c))` is the `'` head.

**Slicing.** `take`/`drop-first` (the first *n*, the rest), `take-last`/
`drop-last`, and `take-while`/`drop-while`.

**Partitioning and grouping.** `partition coll n` (fixed-size runs),
`partition-by f coll` (runs where `f` changes), `split-by f coll`,
`gather-by f coll`, `group-by f coll` (a map from the printed key to the
elements), `frequencies` (a map from each element to its count),
`distinct`/`dedupe`/`count-distinct`, and `shuffle`.

**Ordering and order statistics.** `sort` (with `key=` and `reverse=`),
`sort-by`, `reverse`, `sum`, `product`, `mean`, `median`, `variance`, and
`std`. `sort` and `reverse` take a tensor branch: linear without `dims=`, shape
preserving with it. The statistics reduce a tensor along `dims=` and take
`drop=`.

**Set-like verbs.** `union`, `intersect`, `difference`, `subset?`, and
`superset?`.

**Combining.** `zip` (element-wise tuples), `zipmap` (a map from one sequence
to another), `interleave`, `map-thread` (`f` applied across several collections,
stopping at the shortest), `outer` (the outer product, nested one level per
collection), `riffle` (a separator between elements), `tuples`, `flatten`,
`transpose`, and `subdivide`.

**Constructing.** `range` (`(range n)`, `(range start stop)`,
`(range start step stop)`), `repeat`, and `array` (`(array f n)` builds a
sequence by calling `f` on `0 … n-1`).

**Transforming the map.** `keys`, `vals`, `invert`, `map-keys` (the function
receives a keyword and must return a symbol), and `deep-map` (bottom-up over
every node).

## Higher-order verbs

The higher-order verbs take a **function**: a symbol naming a rule, a
replacement rule in head position (`(?x -> …)`), or a partial application
(`(part f a)`). See [Lambdas](patterns.md#lambdas-a-replacement-rule-in-head-position).

```air
(map (?x -> (* 2 x)) (1 2 3))         # => (2 4 6)
(filter (?x \ even?) (1 2 3 4))       # => (2 4)
(remove (?x \ even?) (1 2 3 4))       # => (1 3)
(reduce + 0 (1 2 3 4))                # => 10     (fold is a synonym)
(mapcat (?x -> (repeat 2 x)) (1 2))    # => (1 1 2 2)
(each println (1 2 3))                # prints three lines, returns naught
(apply + (1 2 3))                     # => 6
(any? even? (1 3 4))                  # => true
(all? even? (2 4))                    # => true
(none? even? (1 3))                   # => true
(sort-by (?x -> x.age) people)        # a copy, ascending by age
```

`map` defaults to `depth=1` (the collection's elements); `depth=0` applies the
function to the collection itself, and `depth=n` rebuilds the structure around
the nodes at that level. `map` on a table maps rows; on a tensor it maps
elements. `filter` filters rows of a table.

`memoize` wraps a function in a process-local cache keyed by its arguments
(`memoized` is the internal form); a `def` can also be memoized directly with
`memoize=true`, which is described in [Patterns](patterns.md#memoization-memoize).

## Threading and pipelines

`thread` distributes a form over its sequential container elements,
Mathematica-style. The head is not special and a nested hold is an ordinary
form:

```air
(thread (f (1 2 3)))          # => ((f 1) (f 2) (f 3))
(hold-thread (' f (1 2 3)))   # => (' (f 1) (f 2) (f 3))
(thread (' f (1 2 3)))        # => ((' f 1) (' f 2) (' f 3))
```

`hold-thread` strips the argument's root hold before threading and holds the
result; `hold=` selects the result's heldness (false on `thread`, true on
`hold-thread`).

The **pipeline** `>>` substitutes a value into raw step forms and reduces only
the final form. `_` is the placeholder:

```air
(let (x=2) (x >> (_ + 1) (f _) (result=_)))   # => (result=(f 3))
(1 >> (_ + _) (' _))                          # => (' (1 + 1)), not '2
```

Evaluate `x`, substitute its result textually for every `_` in the raw first
step, substitute that form into the next step, and so on; a step with no `_`
raises. `(>> x step…)` is the prefix spelling.

## Traversal by depth

`replace`, `rreplace`, `map`, `cases`, and `drop-cases` accept `depth=n`,
selecting the level they operate on. `depth=0` is the subject itself; `depth=n`
is every node `n` element steps down, where both sequence elements and map
values are children, with the structure above rebuilt. A scalar is its own sole
element, so descending past a scalar stays on it; an extern is opaque.
`replace` and `rreplace` default to `depth=0`; `map`, `cases`, and `drop-cases`
default to `depth=1`:

```air
(replace ((a 1) (a 2)) ((a ?x) -> x))          # => ((a 1) (a 2))  (depth 0)
(replace ((a 1) (a 2)) ((a ?x) -> x) depth=1)  # => (1 2)
(map (?x -> (wrap x)) (a=(1 2) b=3) depth=2)
# => (a=((wrap 1) (wrap 2)) b=(wrap 3))
```

`replace-all` and `rreplace-all` keep their whole-tree walk when `depth` is
absent; with `depth=n` they operate only on level `n` (so `depth=0` is then
exactly `replace`). `cases` collects the elements at a level that match a
clause, and `drop-cases` removes them; `matches-any?` asks the same question
over the whole tree. The clause grammar — a bare pattern, a rule-level `\`
guard, or a replacement rule — is the pattern language of
[Patterns](patterns.md#pattern-selection).

## Locating entries

`where` reports where a value occurs:

```air
(where (:a :b :b :c) :b)                # => (2 3)   the bare keys
(where ((1 2) (3 2)) 2 depth=2)         # => ((1 2) (2 2))   one path each
(where (:a :b (:a :b) :c) :b depth=:all)  # => ((2) (3 2))
```

With no `depth` it searches depth 1 and returns the **bare keys** of the
matches in encounter order; with an explicit non-negative integer `depth` it
returns **one path per occurrence**, each path a list of `d` keys. At
`depth=0` the only key is the whole-form key `0`, so the result is `((0))` when
the subject equals `obj` and `()` otherwise. `depth=:all` searches every depth
and returns one path per occurrence, each of its own length. No match is `()`
in every mode, results are plain (not held), and a path splices into `get`,
`with`, or `update-in`.

## Where to go next

* [Patterns](patterns.md) — the pattern language and the traversal clause forms.
* [Tables](tables.md) and [Tensors](tensors.md) — their own path grammars.
* [Data model](data-model.md) — holds, equality, and the form itself.
* [Mutability](mutability.md) — `set!` and `swap!` for a mutable inside a form.
