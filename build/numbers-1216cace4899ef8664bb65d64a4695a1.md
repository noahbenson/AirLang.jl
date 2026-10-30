# Numbers

A number in air is one of the eight leaves AirDB stores and serializes:

| leaf | written | example |
| --- | --- | --- |
| `Int64` | digits that fit the machine word | `42` |
| `BigInt` | any other integer | `123456789012345678901234567890` |
| `Float64` | a decimal point, an exponent, or `Inf`/`NaN` | `1.5`, `1e9`, `-Inf` |
| `BigFloat` | `big"…"` | `big"1.5"` |
| `Rational{Int64}` | `n//d` | `1//3` |
| `Rational{BigInt}` | `n//d` with a large part | `123456789012345678901234567890//7` |
| `ComplexF64` | `a+bi` with no space | `4.4+2.0i`, `2i` |
| `Complex{BigFloat}` | `big"…"i`, or `(complex re im)` | `big"2.0"i` |

These are exactly AirDB's `FormLeaf` types, so a number written in air, read
from a database, or decoded from JSON is the same Julia value.

## Literals

Integers are read as `Int64` when they fit and as `BigInt` otherwise; an
integer-shaped token never silently becomes a float. A `//` with no spaces
around it is a rational literal, and the sign is normalized onto the numerator
(`1//-3` reads as `-1//3`). `big"…"` parses a `BigFloat` at the ambient
precision, and the usual prefixed-literal spellings work anywhere a form may
appear (`x=big"1.5"`, `'big"1.5"`).

`Inf`, `-Inf`, and `NaN` are the spellings the printer emits, and they read
back as the `Float64` values they name. The constants `inf` and `nan` are also
available as bare symbols.

A complex value prints as **one atom** with no space around the sign —
`4.4+2.0i`, not `4.4 + 2.0i` — so a printed form re-reads as the same value at
any depth. A complex value whose real part is zero still prints its zero
(`0.0+2.0i`), and a `Complex{BigFloat}` prints as `(complex big"re" big"im")`
because a bare `re+imi` atom could not be read back as the same type.

## Printing and round-tripping

Every number prints in a spelling the reader accepts and that denotes the same
value, at any depth:

```air
1//3                      # => 1//3
big"1.5"                  # => big"1.5"
(f 4.4+2.0i)              # => (f 4.4+2.0i)
```

A `BigFloat` whose precision is the ambient `precision(BigFloat)` prints as
`big"…"`. Any other precision prints with the annotation, because `big"…"`
would silently re-read at the ambient precision instead:

```air
(bigfloat "1.5" precision=512)
```

## Constructors

Three constructors build the values the reader cannot spell directly:

* `(rational n d)` — the exact rational `n/d`; a zero denominator raises.
* `(complex re im)` — the complex value with those parts; `ComplexF64` when
  both parts are exactly `Float64`, `Complex{BigFloat}` otherwise.
* `(bigfloat "…" precision=n)` — a `BigFloat` parsed at `n` bits (default: the
  ambient precision).

## Arithmetic

Arithmetic is Julia's, and air adds no promotion rules of its own. Both
operands must be numbers and the result is canonicalized to a leaf; a value
that is not a number leaves the form symbolic (`(x + 1)`).

* `/` always divides in floating point: `(/ 1 2)` is `0.5`, and `/` of two
  rationals stays exact (`(/ 1//2 2)` is `1//4`).
* `//` is the **exact rational** constructor, as in Julia: `(7 // 2)` is
  `7//2`, and a zero denominator raises. Integer division is the `div` verb:
  `(div 7 2)` is `3`, and `(div -7 2)` is `-3` (it truncates toward zero).
* `mod` keeps Julia's meaning (the result has the sign of the divisor), and
  `(mod 7//2 1)` is `1//2`.
* Exact inputs give exact results: `(+ 1//3 1//6)` is `1//2`, and an operation
  with a `BigInt` operand stays a `BigInt` without overflow
  (`(* 1267650600228229401496703205376 2)` is `2535301200456458802993406410752`).
* `Int64` arithmetic wraps, as in Julia: `(^ 2 100)` is `0`. Write a literal
  that does not fit an `Int64`, or a rational, to keep the result exact.

The math verbs (`abs`, `sqrt`, `floor`, `round`, `sin`, …) are Julia functions
too, so they follow the type of their argument: `(floor 7//2)` is `3//1`, and
`(sqrt -1)` is an error rather than a complex value.

## Predicates

`number?` is true for any of the eight leaves. `int?` and `integer?` are true
for `Int64` and `BigInt`, `float?` for `Float64` and `BigFloat`, and
`complex?` for the two complex types. A rational is a number but not an
integer, even when it is whole (`(int? 1//1)` is false). `zero?`, `even?`,
`odd?`, `positive?`, `negative?`, `nan?`, and `infinite?` accept whatever
Julia accepts for their type.

## Equality

The three relations in [the data model](data-model.md#5-equality-equivalence-and-hashing)
treat numbers as follows:

* `eq?` is AirDB's `isequiv`: the same type and the same value. `(eq? 1 1.0)`,
  `(eq? 1 1//1)`, and `(eq? 1 big"1.0")` are all false. A signed zero is one
  value (`(eq? -0.0 0.0)` is true) and `NaN` is equivalent to itself.
* `==` is content equality, which is AirDB's `==` on forms. It is
  numeric-friendly, so `(== 1 1.0)` is true and `(== -0.0 0.0)` is true; a
  `NaN` is equal to nothing, as in Julia.
* `(hash x)` follows `eq?`, so equivalent numbers hash alike and `1` and
  `1.0`, which are not equivalent, need not.

`(compare a b)` and the ordering operators order two `Real` values numerically.
A complex value has no order, so an ordering comparison that involves one stays
symbolic — `(< 1 2.0+1.0i)` — while `compare` falls back to the printed
spelling so that its order stays total.

## JSON

AirDB's codec carries every leaf. An integer too large for `Int64` is the
string `"#big:…"`, a rational `"#rat:n/d"` or `"#bigrat:n/d"`, a big float
`"#bigfloat:<bits>:…"`, and a non-finite float `"#inf"`, `"#-inf"`, or
`"#nan"`. `from-json` returns the same value `to-json` was given, including the
precision of a `BigFloat`:

```air
(to-json 1//3)                         # => "#rat:1/3"
(eq? (from-json (to-json big"1.5")) big"1.5")   # => true
```
