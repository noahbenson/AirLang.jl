# AirLang.jl

A clojure- and Mathematica-inspired scripting language for Julia that builds on
the Air.jl and AirDB.jl libraries.


## Context and Motivation

`Air.jl` is a library that implements clojure-like immutable data structures
and an STM system. `AirDB.jl` is a database persistence layer that lives on top
of and uses `Air.jl` for concurrency/transactions and that allows users to
easily create and manage mutable JSON-like objects across multiple threads that
are automatically syncronized to a PostgreSQL database in `jsonb` tables.

`AirLang.jl` is a project that seeks to unite these libraries into a
clojure-like interpreted language that runs in Julia, air. Air, the language,
is intended for use in part as the interface to a reasoning and rules system
that can be used to track complex metadata, recognize conditions within it, and
execute julia functions when required.


## Basic Syntax

Air is a lisp-like functional language that whose heaviest inspirations are
clojure and mathematica. Its core evaluation operations are fundamentally those
of a symbolic algebra engine, but it typically reads like a lisp cousin.

### Structure

Air uses many of the aesthetic conventions of a lisp-like language. The syntax
consists of symbols, strings, numbers, and forms which are nested using
parentheses. Forms are described below and are typically containers whose
elements are whitespace separated and bracketed by parentheses: `(1 2
3)`. Forms can be nested, and when the final element of a form is itself a
container form (e.g., `(1 2 (3 4))`), a vertical pipe character can be used, so
`(1 2 |3 4)` is identical to the object `(1 2 (3 4))`, and `(1 |2 |3 |4)` is
identical to the object `(1 (2 (3 (4))))`.

Comments begin with the `#` character and go to the end of the line.

Strings in air are bracketed by double quotes (`"`) or tripe double quotes
(`"""`) and use the same formatting rules as Julia's strings.

Numbers are formatted as in Julia.

Symbols may be specified in two ways: a sequence of alphanumeric characters
plus the characters `+`, `-`, `*`, `/`, `_`, `!`, `?`, `:`, `$`, `^`, `&`, `=`,
`.` that does not start with a number forms a symbol; for example `x`,
`abc123`, and `+` are all valid symbols. There are also two kinds of special
symbols: (1) any symbol whose name starts with a `?` is considered a wildcard
(see patterns below), and any symbol that starts with a `:` is considered a
keyword, meaning that it cannot be redefined, and it always evaluates to itself
(patterns also have this property).

#### Evaluation

All atom types (see below) evaluate to themselves with the exception of
symbols, which can be bound to other values. Because air follows a Wolfram-like
logic regarding variables and symbols, symbols that are not bound to a value
are treated as other atoms---i.e., they evaluate to themselves.

All air code is simultaneously a piece of code and a piece of data (code is
data). A function call like `(f x)` is just a form with two symbol (`f` and
`x`), but if a pattern has been defined that fires on a match to `(f ?x)`, then
when the `(f x)` form is submitted to the air interpreter, it is replaced with
whatever the pattern defines. (Patterns are explained in more detail in the
"Patterns" section below.) If no pattern matches the form `(f x)` then the
interpreter will replace each of its elements using any relevant pattern. So,
for example, suppose the a pattern has been defined `(inc ?x)` for incrementing
a number, and the pattern explicitly requires that `x` be an integer. In this
case, the form `(inc n)` doesn't match, because the match for `?x` (`n`) is a
symbol, not a number, so the interpreter doesn't apply the `(inc ?x)` pattern
yet. Instead, it replaces the elements of the form with any matches. So if a
pattern has been defined that replaces the symbol `x` with the value `4` (i.e.,
`x = 4` in Python, but in air we must interpret this as a pattern/replacement
of `x` with the number `4`), then after the form's elements have been replaced,
the reduced form is `(inc 4)`. This form now matches the `(inc ?x)` pattern
because `4` is a number. If `(dec n)` were provided to the interpreter instead
(and no `dec` pattern had been defined), then the result would instead have
been the form `(dec 4)`.

### Types

Air is not strongly typed and has only a few types.

#### Forms

A **form** is an immutable object that contains actual data. The concept of a
form is somewhat broad: a string, symbol, float, complex number, integer, bool,
or the null value `naught` are all considered subtypes of the `form`
type. Sequences, which can be specified in air using whitespace separated
elements surrounded by parentheses, are also forms. For example: `(1 2 3)` is a
form that is roughly equivalent to the Julia object `[1, 2, 3]`. Mappings,
which can also be specified using parentheses, but by pairing the values with
keys, are forms as well; for example `(a=1 b=2 c=3)` is a mapping with keys
`:a`, `:b`, and `:c` whose values are 1, 2, and 3. In fact, forms can include
both sequential and mapping values: `(f 1 2 a=3 b=4)` is a form with three
sequential elements (`1`: `f`, `2`: `1`, and `3`: `2`) and two mapping elements
(`:a`: `3` and `:b`: `4`). Named keyword elements of a form do not need to come
in any particular order with respect to either each other or the ordered
elements (and the ordering of keyword elements is not preserved). So `(f 1 2
a=3 b=4)`, `(a=3 b=4 f 1 2)` and `(f a=3 1 b=4 2)` are all equal forms.

All of this makes `form` effectively an abstract type with several concrete
subtypes (though `air` does not implement a real inheritance system or type
hierarchy). Types are typically checked using simple functions such as `(form?
f)` (check whether `f` is a `form`). Similar predicate functions include
`int?`, `float?`, `string?`, `symbol?`, `bool?`, `coll?` (which tests
whether a form is a collection), and `atom?` (which is effectively the opposite
of `coll?`). Note that `air` does not especially distinguish between sequential
and mapping forms---all of them are collection forms, which have lengths and
map keys (integers or symbols) to values; though the mapping or sequence parts
can be extracted usign `(mappart f)` and `(seqpart f)`.

Note that there is exactly one empty form `()`, and it is (1) considered
logically false, and (2) identical to the builtin value `naught` (which is used
as a `nil` value). Scalar forms (numbers, strings, symbols, booleans, and
`naught`) are all considered atoms in that they are not collections and cannot
store other forms.

The contents of collection forms can be queried by treating them as functions;
for a form `f` that is equal to `(1 (2 3) a=(g h i))`, the function `(f 1)`
returns `1`; `(f 2)` returns `(2 3)`, and `(f :a)` returns `(g h i)`. Further,
`(f 2 1)` returns `2` and `(f :a 1)` returns `g` because extended argument
lists are passed forwarded through the return value.

#### Mutables

In addition to the immutable atom types listed above, there is a `mutable` type
that is not considered a `form`, but that `form` objects are allowed to contain
as values. All `mutable` objects are simple pointer/references that are
automatically syncronized across threads in a fashion similar to clojure's
`ref` objects. (This behavior is all implemented and documented in the
`AirDB.jl` library that this language is built on.)  Mutables can be created
using the `mut` function: `(mut)` results in a new mutable whose contents are
an empty form.

Supposing we had a form `f` whose value was `(1 2 (mut (:a :b)))` (where `(mut
(:a :b))` creates a new mutable whose initial value is `(:a :b)`. The mutable
object in the form automatically vanishes during queries: `(f 3 1)` returns
`:a`. However `(f 3)` would return the mutable object itself.

Mutables can be set using the `set` function: `(set (f 3) (:a :b :c))` results
in `f` being effectively equal to `(1 2 (mut (:a :b :c))`. The `set` function
can also traverse forms and will automatically update the deepest mutable
object on the path to contain the requested changes. So if `f` instead equals
`(1 (2 (mut (3 (4 5)))))`, then `(set f 2 2 2 2 6)` updates the mutable at `(f
2 2)` such that it's value (`(3 (4 5))`) has been updated to set its position
`2 2` to the value 6, so the result is that `f` now contains
`(1 2 (mut (3 (4 6))))`.


### Patterns

Air is built around symbol pattern expansion and replacement. Fundamentally,
any form is a pattern, but a form like `10` that has no wildcards is a pattern
that matches only itself. Any symbol whose first character is a `?` is
considered a wildcard symbol that can stand for anything in a pattern. These
symbols, like keyword symbols, cannot be assigned values and always evaluate to
themselves, but in patterns, they stand for any possible value.

Additionally, the character `\` stands for "such that"---it comes after a
pattern and before a condition on that pattern. So, for example, the pattern
`(?head 10)` matches `(10 10)` or `("abc" 10)` or `((1 2) 10)`. However, the
pattern `(?head \ string? 10)` matches only `("abc" 10)` of the previous
examples because the `?head` wildcard must match `(string? head)` The following
are all equivalent patterns: `(?h \ string? 10)`, `(?h \ (string? h) 10)`, and
`(?h 10) \ (string? h)`. Note that when the pattern is evaluated all named
wildcards are bound. (The special wildcard `?` stands for anything, is not
considered the same wildcard in separate positions, and is not bound in the
condition clause.) A pattern like `(?h 10 ?h)` will match `(1 10 1)` but not
`(1 10 2)`, but `(? 10 ?)` matches any three elements with 10 in the
middle---because the wildcards are not named, they are not required to bind the
same value.

The special symbol `??` can be used to stand for any other elements of a form
not listed, and a symbol that starts with `??` such as `??rest` binds all
elements of a form not matched in the rest of the pattern (assuming that the
pattern does match). So `(match? (1 2 a=? ??) (1 2 3 a=1 b=2))` returns `true`
because the `3` and `b=2` are captured in the `??` wildcard but `(match? (1 2
a=? ??) (2 3 a=1 b=2)` returns `false` because the form doesn't match the `1 2`
part of the pattern.

The special symbols `?&` and `?*` can similarly be used to bind any number of
sequential elements in a row or any number of mapping elements, respectively,
and like the `??` wildcard can be given a name to bind their matches, such as
`?&rest` or `?*kwargs`.

Patterns may not match on wildcards for keys, but if a pattern includes a key
whose first character is a `?` (which is not valid air typically because all
keys must be keyword symbols), then the keyword is optional and is assigned
whatever value is provided when not present. For example, the following
expression, `(matches (f ?x ?method=naught) (f 10 method=:newton))`, should
return one match: `(x=10 method=:newton)` and the similar expression
`(matches (f ?x ?method=naught) (f 10))` should return one match
`(x=10 method=naught)`. This is distinct from the pattern
`(f x method=?method)` which also binds `x` and `method` but requires that
`method` be explicitly part of the matched form's keys.

Functions in air are written as pattern replacements, much as in the Wolfram
language. For example, here is a pattern for an inefficient version of the
Fibonacci sequence:

```
(def (f ?n)
    |if (= n 0) 1
        (= n 1) 1  # automatic else-if (if is like cond)
        |+ (f |- n 1) |f |- n 2)
```

Notably patterns that stand in for functions are not required to match a symbol
on their first element; while it's natural for a Fibonacci function to be
called as `(fib ?x)`, there's no reason another function more appropriate for
infix notation would be defined as follows:

```
(def (?a contains ?b) \ (haskey a :contents)
    |b in |a :contents)
```

The above function essentially matches only when `?b` is a form with the key
`:content` and the value of that key contains the element matched by `?b`.

In addition to matching plain forms, patterns can explicitly match the
unevaluated arguments. The `on` function that binds a pattern/replacement takes
an optional argument `hold`, which can be given a sequence of symbols that are
to be held unevaluated in the match. For example, the following code
differentiates simple functions with respect to a given variable.

```
(def (diff (?x + ?f) ?x) hold=(x f)
   |1 + |diff (unhold f) (unhold x))
(def (diff (?f + ?x) ?x) hold=(x f)
   |(diff (unhold f) (unhold x)) + 1)
(def (diff (?f + ?g) ?x) hold=(x f g)
   |(diff (unhold f) (unhold x)) + |diff (unhold g) (unhold x))
(def (diff (?x * ?f) ?x) hold=(x f)
   |f + |diff f x)
(def (diff (?f * ?x) ?x) hold=(x f)
   |(diff f x) + f)
(def (diff (?f * ?g) ?x) hold=(x f g)
   |((diff f x) * g) + |f * |diff g x)
```

When one evaluates, for example, `(diff (a + (b * x)) x)` the call chain is as
follows:
1. `(diff (?f + ?g) ?x)` is matched with `f=a`, `g=(b * x)`, and `x=x`; it
   evaluates to `((diff a 
2. 
