# Tensors

A **tensor** is air's mutable N-dimensional numeric array. It is a thin wrapper
over a Julia `Array` whose elements are restricted to air's [numeric
tower](numbers.md): `Bool`, `Int64`, `BigInt`, `Float64`, `BigFloat`,
`Rational{Int64}`, `Rational{BigInt}`, `ComplexF64`, and `Complex{BigFloat}`.
Arithmetic, promotion, broadcasting, and the linear-algebra surface are Julia's.

```air
[1 2 3]                          # => #<tensor 3 Int64>
[1 2; 3 4]                       # => #<tensor 2×2 Int64>
(+ [1 2; 3 4] 10)                # => #<tensor 2×2 Int64>
(det [1.0 2.0; 3.0 4.0])         # => -2.0
```

Unlike a form, a tensor **mutates**: `set!` (the mutable-writing form from
[Mutability](mutability.md)) and the `tensor-…!` verbs write into the existing
array. That is the one thing air's STM cannot roll back, so a mutation is legal
only inside a **reservation**, and never inside a [transaction](mutability.md#transactions).
The same rule covers every read of an existing tensor: *all accesses to a tensor
require an enclosing reservation*. Constructing a tensor is free.

```{admonition} The rule
:class: warning
`{t : …}` is an inline **read** reservation and `{t :! …}` is a deferred
**write** reservation. Reading a tensor outside one — or writing one outside a
write reservation — raises. A write reservation never runs inside a
transaction; it runs after the transaction commits.
```

## Array literals

A bracketed literal builds a tensor. Cells are ordinary expressions and are
evaluated; groups separated by semicolons are axes of the shape, with the
**innermost** (most semicolons) outermost.

```air
[1 2 3]                                    # a 3-vector
[]                                         # an empty vector (Float64)
[1 (+ 1 1) 3]                              # cells evaluate: (1 2 3)
[1 2; 3 4]                                 # a 2×2 matrix
[1 2 3; 4 5 6]                             # 2 rows of 3 columns
[1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12]        # a 2×3×2 tensor
```

A run of `k` semicolons separates elements at nesting depth `maxk - k`, where
`maxk` is the longest run: in the last example `;;` splits the two pages, and
each single `;` splits that page's three rows. The outermost level of the
spelling is axis 1 and the deepest cells are the last axis, which is exactly
how `tensor->form` prints a tensor back. Iteration is column-major, so axis 1
varies fastest: `[1 2; 3 4]` iterates as `(1 3 2 4)`, where axis 1 is the row.

Every cell must be numeric and every level rectangular; a ragged literal, a
non-numeric cell, or a mapping cell raises. A pair of brackets with nothing
inside is a 1-D empty tensor of element type Float64.

## Constructing a tensor

`(tensor x)` builds one from a nested sequence — the same shape rules as a
literal — and copies a tensor argument. `(tensor)` with no argument is an empty
vector. `eltype=` fixes (or converts to) the element type:

```air
(tensor ((1 2) (3 4)))                  # => #<tensor 2×2 Int64>
(tensor [1 2; 3 4])                     # => a copy
(tensor [1 2] eltype=:float64)          # => #<tensor 2 Float64>
(tensor->form (tensor [1 2] eltype=:float64))   # => (1.0 2.0)
```

The type names are `:bool`, `:int64`, `:bigint`, `:float64`, `:bigfloat`,
`:rational64`, `:rationalbig`, `:complex64`, and `:complexbig`, with the short
aliases `:int`, `:float`, `:rational`, and `:complex`. The reader's leaf types
pick the same names, so `(tensor-eltype [1 2.5])` is `:float64` and
`(tensor-eltype [1//2])` is `:rational64`.

Generators take their dimensions either as separate arguments or as one
sequence; `eltype=` works throughout (the random generators are Float64 only):

```air
(tensor-zeros 2 3)                 # 2×3 of 0.0
(tensor-ones (2 2))                # 2×2 of 1.0
(tensor-fill 7 (2 2))              # 2×2 of 7, element type Int64
(tensor-eye 3)                     # the 3×3 identity
(tensor-eye 2 3)                   # a 2×3 identity (diagonal)
(tensor-rand 2 3)  (tensor-randn 2 3)
```

Introspection is metadata-only and needs no reservation: `tensor?`,
`tensor-shape` (a sequence of sizes), `tensor-rank`, `tensor-eltype`, and
`tensor-copy` (a fresh copy).

```air
(tensor-shape [1 2; 3 4])          # => (2 2)
(tensor-rank [1 2; 3 4])           # => 2
(tensor-eltype [1 2.5])            # => float64
```

## Reading: `get`

`get` takes one key per axis. An integer selects one index and drops that axis;
`:` keeps the axis; a sequence of integers selects several indices and keeps the
axis. Missing trailing axes are full, negative indices count from the end, and a
path longer than the rank raises. If every axis is selected by an integer the
result is a scalar leaf; otherwise it is a fresh copy.

```air
(let (t=[1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12])
  ((get t 2 1 2)                    # => 8
   (tensor->form (get t 1))         # => ((1 2) (3 4) (5 6))
   (tensor->form (get t 2 (1 3) 2)) # => (8 12)
   (tensor->form (get t : : 2))))   # => ((2 4 6) (8 10 12))
```

`(get t 0)` and `(get t)` return the tensor itself (the same value, with its one
handle); `(get t :)` returns a copy. `default=` supplies a value for an
out-of-range index instead of raising:

```air
(get [1 2 3] 5 default=:none)      # => :none
```

`hold=true` on `get` holds the result, as it does for a form. Reading a tensor
requires a reservation (see below), except for a tensor this task constructed
itself: a literal or a `val` bound in the current task is accessible directly.

The wildcard `:` here is the tensor's per-axis selector, not the map-entry
wildcard of a form path.

## Reservations

A reservation names the tensors a body may touch and whether it may write them.
It is the only way to access a tensor that this task did not just construct.

- `{t u … : body…}` — sugar for `(reserve-read (t u …) body…)`. A **read**
  reservation runs the body inline and returns its value. Reads are safe inside
  a transaction: AirDB records the extern versions, so a concurrent write forces
  the transaction to retry.
- `{t u … :! body…}` — sugar for `(reserve (t u …) body…)`. A **write**
  reservation runs the body on a spawned task and returns an `AirReservation`.
  `(get r)` and `(await r)` wait for the body's value (re-raising its error), and
  `(ready? r)` tests readiness. It can never run inside a transaction; inside
  one it is deferred until the transaction commits.
- Mixed modes put both kinds in one reservation: `{a : b :! body…}` reads `a`
  and writes `b`, and `(reserve (a b) read=(a) body…)` is the same thing. The
  sugar is order-insensitive: `{b :! a : body…}` also reads `a` and writes `b`.

```air
(let (t=[1 2 3])
  {t : (get t 2)})                       # => 2

(let (t=[1 2 3])
  (let (r={t :! (set! t 1 9)})
    (get r)))                            # => 9

(let (a=[1 2] b=[3 4])
  (get {a : b :! (set! b 1 (+ (get b 1) (get a 1)))}))   # => 4
```

Write reservations serialize on a tensor: a second write reservation waits for
the first, so each body sees the previous one's writes. Two reservations never
nest, and every tensor the body touches must be declared — a read in a
write-mode reservation is allowed, but a tensor missing from the declaration is
an error even for a read. Do not block inside a reservation body (`await`,
`fetch`, …), and do not spawn a task from one that touches reserved tensors.

A write reservation made inside a transaction is commit-gated, so it is pending
throughout that transaction; `(get r)` on it inside the transaction raises
rather than blocking. A reservation made inside a `sandbox` never runs, because
the sandbox's transaction is discarded.

Freshness is per task: a tensor another task made (and you awaited) is not fresh
in yours, so it needs a reservation like any other existing tensor.

## Writing

`set!` assigns into a tensor and returns the written value. With no keys it
replaces the whole tensor; with keys it assigns a region. A scalar broadcasts to
every selected cell; a tensor (or nested sequence) must match the selected shape
exactly. Promotion replaces the element type in place, preserving the tensor's
identity:

```air
(let (t=[1 2; 3 4]) (do (set! t 1 1 9) (tensor->form t)))   # => ((9 2) (3 4))
(let (t=[1 2; 3 4]) (do (set! t 1 5)   (tensor->form t)))   # => ((5 5) (3 4))
(let (t=[1 2; 3 4]) (do (set! t 5)     (tensor->form t)))   # => ((5 5) (5 5))
(let (t=[1 2])      (do (set! t 1 1.5) (tensor-eltype t)))  # => float64
```

`set!` is legal only in a write reservation, and never inside a transaction:

```air
(let (t=[1 2]) (tx (set! t 1 9)))     # raises: a tensor cannot be written in a tx
```

`with` is the pure inverse: it copies the tensor, applies the same key/value
assignment, and returns a **new** tensor, leaving the source untouched. Only
`hold=` is accepted as an option:

```air
(tensor->form (with [1 2; 3 4] 1 5))      # => ((5 5) (3 4))
(tensor->form (with [1 2 3] 2 0))         # => (1 0 3)
```

The in-place verbs apply a function to every element. A tensor operand must have
the tensor's shape; a scalar broadcasts; promotion replaces the element type:

```air
(let (t=[1 2 3]) (do (tensor-add! t 10) (tensor->form t)))   # => (11 12 13)
(let (t=[2.0 4.0]) (do (tensor-div! t 2) (tensor->form t)))  # => (1.0 2.0)
(let (t=[1 2 3]) (do (tensor-scale! t 3) (tensor->form t)))  # => (3 6 9)
(let (t=[1 2 3]) (do (tensor-copyto! t [9 8 7]) (tensor->form t)))  # => (9 8 7)
```

`tensor-add!`, `tensor-sub!`, `tensor-mul!`, `tensor-div!` (`tensor-scale!` is
`tensor-mul!` by another name) and `tensor-copyto!` all require a write
reservation.

`tensor-map!` replaces every linear cell with the result of an air callable, and
`tensor-clamp!` bounds every cell by two values; both preserve the tensor's
identity, promote its element type as needed, and require a write reservation:

```air
(let (t=[1 2 3]) (do (tensor-map! (?x -> (x + 1)) t) (tensor->form t)))  # => (2 3 4)
(let (t=[1 5 9]) (do (tensor-clamp! t 2 8) (tensor->form t)))            # => (2 5 8)
```

## Arithmetic and broadcasting

`+ - * / ^ mod` and the math verbs broadcast elementwise over tensors, with air's
numeric promotion. A scalar operand broadcasts; two tensors must have compatible
shapes; a symbolic operand stays symbolic.

```air
(tensor->form (+ [1 2; 3 4] 10))     # => ((11 12) (13 14))
(tensor->form (+ [1 2] [3 4]))       # => (4 6)
(tensor->form (^ [1 2 3] 2))         # => (1 4 9)
(tensor->form (mod [1 2 3 4] 2))     # => (1 0 1 0)
(tensor->form (abs [-1 2]))          # => (1 2)
(tensor->form (sqrt [4.0 9.0]))      # => (2.0 3.0)
(tensor->form (max [1 2] 5))         # => (5 5)
```

`*` follows Julia for ranks up to 2: a scalar scales, matrix×matrix,
matrix×vector, and vector×matrix multiply, and vector×vector is the dot product.
Rank 3 and above raise for ×; use `tensor-mul` for the elementwise product:

```air
(tensor->form (* [1 2; 3 4] [5 6; 7 8]))   # => ((19 22) (43 50))
(tensor->form (* [1 2; 3 4] [1 2]))        # => (5 11)
(* [1 2 3] [4 5 6])                        # => 32
(tensor->form (tensor-mul [1 2] [3 4]))    # => (3 8)
```

Unary `-` negates and unary `/` reciprocates. `//` and the ordering comparisons
stay symbolic over a tensor; `==` is air's content equality, which for a mutable
extern is identity. Use `tensor-equal?` (content, same shape) and
`tensor-close?` (`atol=`, `rtol=`) to compare values:

```air
(let (t=[1 2]) (== t t))                   # => true
(== [1 2] [1 2])                           # => false
(tensor-equal? [1 2] [1 2])                # => true
(tensor-close? [1.0 2.0] [1.0 2.0000001] atol=0.001)   # => true
(tensor->form (tensor-map (?x -> (x * 2)) [1 2]))      # => (2 4)
```

## Iteration and reductions

Iteration is linear and **column-major** (the first axis varies fastest). The
collection verbs read the elements as ordinary scalar forms, and the structural
verbs refuse a tensor: a tensor is not a sequence, so use `get`, `with`, `set!`,
or `tensor->form`.

```air
(for (x [1 2; 3 4]) x)                     # => (1 3 2 4)
(map (?x -> (x + 1)) [1 2 3])              # => (2 3 4)
(filter (?x -> (x > 1)) [1 2 3])           # => (2 3)
(reduce ((?a ?b) -> (a + b)) 0 [1 2; 3 4]) # => 10
(first [1 2; 3 4])                         # => 1
(nth [1 2; 3 4] 3)                         # => 2
(length [1 2; 3 4])                        # => 4
(sum [1 2; 3 4])                           # => 10
(mean [1 2; 3 4])                          # => 2.5
(in 3 [1 2; 3 4])                          # => true
```

`first`, `last`, `second`, `third`, `rest`, `nth`, `length`, `count`, `in`,
`map`, `filter`, `reduce`, `for`, `each`, `doseq`, and the numeric reductions
(`sum`, `product`, `mean`, `median`, `variance`, `std`) all iterate the linear
elements. `min`/`max` reduce a single tensor and broadcast when any operand is a
tensor.

### Axis reductions: `dims=` and `drop=`

A reduction also takes `dims=`, which is **Julia-style**: the reduced axes are
kept as length-1 axes, and `drop=true` removes them. `dims=:all` names every
axis, and a negative axis counts from the end. Without `dims=` the reduction is
over the linear elements and yields a scalar; dropping every axis also yields a
scalar rather than a rank-0 array.

```air
(tensor->form (sum [1 2; 3 4] dims=1))                # => ((4 6))
(tensor->form (sum [1 2; 3 4] dims=1 drop=true))      # => (4 6)
(tensor->form (mean [1 2; 3 4] dims=2))               # => ((1.5) (3.5))
(tensor->form (median [1 2 3; 4 5 6] dims=1))         # => ((2.5 3.5 4.5))
(tensor->form (sum [1 2; 3 4] dims=:all))             # => ((10))
```

`variance` and `std` are sample statistics by default (`ddof=1`); `ddof=0`
gives the population value. `min` and `max` take the same options when called
with a single tensor (`(min t dims=1)`); with several operands they broadcast
and reject `dims=`.

`tensor-any`, `tensor-all`, and `tensor-count` treat a nonzero element as true
and take the same `dims=`/`drop=` options; without `dims=` they reduce the
linear elements to one scalar Boolean or count.

```air
(tensor-any [0 0])                                    # => false
(tensor->form (tensor-all [1 1; 0 1] dims=2))         # => ((true) (false))
(tensor->form (tensor-count [0 1 2; 3 0 0] dims=1))   # => ((1 1 1))
```

### Cumulative operations

`tensor-cumsum` and `tensor-cumprod` accumulate along one axis and keep the
shape; without `dims=` they return the linear (column-major) accumulation.
`tensor-diff` takes repeated differences (`n=1`) along one axis, or linearly
without `dims=`.

```air
(tensor->form (tensor-cumsum [1 2 3]))                # => (1 3 6)
(tensor->form (tensor-cumsum [1 2; 3 4] dims=2))      # => ((1 3) (3 7))
(tensor->form (tensor-cumprod [1 2 3]))               # => (1 2 6)
(tensor->form (tensor-diff [1 4 9 16]))               # => (3 5 7)
```

### Sorting and indices

`sort` and `reverse` gain a tensor branch: without `dims=` they sort or reverse
the linear elements into a vector, and with `dims=` they keep the shape and act
along the named axes (`sort` names exactly one axis; `descending=true`
reverses the order). `tensor-argsort` returns the 1-based linear permutation
that sorts the tensor, and `tensor-argmax`/`tensor-argmin` return the linear
index of the extreme cell (or, with `dims=`/`drop=`, a tensor of them).

```air
(tensor->form (sort [3 1; 2 4] dims=1))               # => ((2 1) (3 4))
(tensor->form (reverse [1 2; 3 4] dims=1))            # => ((3 4) (1 2))
(tensor->form (tensor-argsort [3 1 2]))               # => (2 3 1)
(tensor-argmax [3 1; 2 4])                            # => 4
(tensor->form (tensor-argmax [3 1; 2 4] dims=1))      # => ((1 4))
```

### Masks and selection

The operators keep their symbolic and identity meaning, so the elementwise
comparisons are the `tensor-` verbs. Each needs at least one tensor operand and
returns a Boolean tensor. `tensor-where` selects from its second operand where
the condition is true and from its third where it is false; a nonzero condition
counts as true, and the value operands broadcast.

```air
(tensor->form (tensor-lt [1 4] [2 3]))                # => (true false)
(tensor->form (tensor-eq [1 2] [1 3]))                # => (true false)
(tensor->form (tensor-where (tensor-gt [1 5] 3) [0 0] [1 1]))   # => (1 0)
```

### Manipulation

Every manipulation verb returns a fresh tensor, reading its inputs under the
usual reservation rules.

| form | result |
| --- | --- |
| `(tensor-concat t… axis=1)` | join along an existing axis |
| `(tensor-stack t… axis=1)` | join along a new length-1 axis |
| `(tensor-flip t [axis=…])` | reverse along one axis (default: every axis) |
| `(tensor-roll t shift [axis=1])` | circular shift |
| `(tensor-tile t reps…)` | repeat the array, numpy-style |
| `(tensor-squeeze t)` | drop every length-1 axis |
| `(tensor-expand-dims t axis)` | insert a length-1 axis |
| `(tensor-diag t [k=0])` | a matrix's diagonal as a vector |
| `(tensor-diagm v [k=0])` | a vector as a diagonal matrix |
| `(tensor-tril t [k=0])` | lower triangle |
| `(tensor-triu t [k=0])` | upper triangle |

```air
(tensor->form (tensor-stack [1 2] [3 4]))             # => ((1 2) (3 4))
(tensor->form (tensor-flip [1 2; 3 4]))               # => ((4 3) (2 1))
(tensor-shape (tensor-tile [1 2 3] 2 3))              # => (2 9)
(tensor->form (tensor-diag [1 2 3; 4 5 6]))           # => (1 5)
(tensor->form (tensor-tril [1 2; 3 4]))               # => ((1 0) (3 4))
```

`transpose` takes `perm=` for any rank; with no `perm=` it reverses the axes (a
vector becomes a 1×n row, as before).

```air
(tensor->form (transpose (reshape [1 2 3 4 5 6] (2 3 1)) perm=(3 2 1)))
# => (((1 2) (3 4) (5 6)))
```

### Construction helpers

`tensor-arange` follows numpy: the stop is exclusive, and the step may be
fractional. `tensor-linspace` takes `n=` (default 50) evenly spaced points and
`endpoint=` (default true). `tensor-randint lo hi dims…` samples integers from
`lo` to `hi-1`.

```air
(tensor->form (tensor-arange 5))                      # => (0 1 2 3 4)
(tensor->form (tensor-arange 0 10 3))                 # => (0 3 6 9)
(tensor->form (tensor-linspace 0 1 n=5))              # => (0.0 0.25 0.5 0.75 1.0)
(tensor-shape (tensor-randint 0 10 3 3))              # => (3 3)
```

## Linear algebra

A curated `LinearAlgebra` surface is available; a scalar result is a leaf and an
array result is a fresh tensor. Decompositions return a map form.

| form | result |
| --- | --- |
| `(dot a b)` | the dot product of two same-shape tensors (Frobenius) |
| `(norm t [p])` | the p-norm (default 2) |
| `(tr t)` | the trace of a matrix |
| `(det t)` | the determinant |
| `(inv t)` | the inverse |
| `(pinv t)` | the Moore–Penrose pseudoinverse |
| `(matrix-rank t)` | the numerical rank |
| `(matrix-cond t)` | the condition number |
| `(nullspace t)` | an orthonormal basis of the null space |
| `(linsolve A b)` | the solution of `A x = b` |
| `(eigvals t)` | the eigenvalues as a vector |
| `(svdvals t)` | the singular values as a vector |
| `(lu t)` | `(L=… U=… p=…)` with `A[p, :] = L * U` |
| `(cross a b)` | the cross product of two 3-vectors |
| `(kron a b)` | the Kronecker product |
| `(isposdef t)` | whether a matrix is positive definite |
| `(issymmetric t)` | whether a matrix is symmetric |
| `(ishermitian t)` | whether a matrix is Hermitian |
| `(transpose t [perm=…])` | axes reversed (rank ≤ 2 keeps a vector as a 1×n row) |
| `(adjoint t)` | the conjugate transpose |
| `(reshape t dims…)` | a reshaped copy |
| `(eigen t)` | `(values=… vectors=…)` |
| `(svd t)` | `(U=… S=… Vt=…)` |
| `(qr t)` | `(Q=… R=…)` |
| `(cholesky t)` | `(U=…)`, the upper triangular factor |

```air
(dot [1 2 3] [4 5 6])                 # => 32
(norm [3 4])                          # => 5.0
(tr [1.0 2.0; 3.0 4.0])               # => 5.0
(tensor->form (inv [1.0 0.0; 0.0 4.0]))   # => ((1.0 0.0) (0.0 0.25))
(tensor->form (transpose [1 2; 3 4]))     # => ((1 3) (2 4))
(tensor->form (linsolve [2.0 0.0; 0.0 4.0] [2.0 8.0]))   # => (1.0 2.0)
(get (eigen [2.0 0.0; 0.0 3.0]) :values)  # => #<tensor 2 Float64>
```

The condition number is `matrix-cond` rather than `cond`, because `cond` is
air's conditional special form (like `matrix-rank`, air's own names take the
`matrix-` prefix). The decompositions promote to complex where needed, and a
`LinearAlgebra` error is wrapped as an air eval error (the message names the
operation).

## Printing and persistence

A tensor prints opaquely, without its payload:

```air
[1 2 3]                 # => #<tensor 3 Int64>
[1 2; 3 4]              # => #<tensor 2×2 Int64>
{… :! …}                # => #<reservation> or #<reservation ready>
```

Printing never takes a lock and never blocks. A tensor is not storable in a
database namespace (`val`ing one into an opened database raises
`(error :un-storable …)`) and does not survive `to-json`/`from-json` as a live
value: the round trip yields a dead extern. `tensor->form` is the supported
persistence spelling — it returns a nested sequence of scalar forms that
`(tensor …)` rebuilds:

```air
(tensor->form [1 2; 3 4])              # => ((1 2) (3 4))
(tensor (tensor->form [1 2; 3 4]))     # a new tensor with the same contents
```
