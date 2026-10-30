# AirDB changes requested by AirLang

Status: requests for the AirDB maintainer (the user maintains AirDB.jl; nothing
here is edited from AirLang). Line numbers are from the AirDB working copy as of
2026-10-29. Item 1 is worked around in AirLang; the rest are latent or cosmetic.

## 1. Container `isequal` must recurse with `isequal`, not `==`

`FormSeq`, `FormMap`, and `FormContainer` define `isequal` in terms of `==`:

- `src/collections.jl:37-39` — `_seq_equal` uses element `==`, and both
  `Base.:(==)` and `Base.isequal(a::FormSeq, b::FormSeq)` call it.
- `src/collections.jl:113-121` — `Base.isequal(a::FormMap, b::FormMap) = a == b`.
- `src/form.jl:289-290` — `isequal(::FormContainer)` recurses into those.

Consequences, both measured on the current working copy:

```julia
mk(v) = AirDB.FormContainer(AirDB.FormSeq(AirDB.FormValue[AirDB.Form(v)]),
                            AirDB.FormMap())
n = mk(NaN)
isequal(n, n)   # false — a container holding a NaN is not equal to itself
```

So a `Dict`/`Set` keyed by a `NaN`-containing form can never be looked up again,
and `isequal` disagrees with `hash` (whose leaf hash treats a NaN normally and
with itself). AirLang hit this as an infinite loop: its reducer detects a fixed
point with a structural `isequal`, and `(f NaN)` never reached one. AirLang now
uses a private `_same_value`/`_same_contents` (recursing with `isequal`) in
`src/equality.jl` and at every fixed-point site in `src/reduce.jl`.

Suggested fix — recurse with `isequal` (leave `==` alone, so `Form(5) ==
Form(5.0)` stays true):

```julia
_seq_isequal(a, b) = length(a) == length(b) && all(isequal(a[i], b[i]) for i in eachindex(a))
Base.isequal(a::FormSeq, b::FormSeq) = _seq_isequal(a.v, b.v)

function Base.isequal(a::FormMap, b::FormMap)
    length(a) == length(b) || return false
    for (k, v) in a
        (haskey(b, k) && isequal(b[k], v)) || return false
    end
    return true
end
```

`FormScalar`'s `isequal` already delegates to Julia's, which handles both a NaN
and `1` vs `1.0` the way `hash` expects, so this makes a container agree with
its own leaves. (AirLang sites that compare whole forms as data — `member?`/
`in`, pattern literal matching, some `logic.jl` fact comparisons — have the same
NaN problem and would be fixed for free.)

## 2. The same mismatch makes `hash` and `isequal` disagree on signed zero

This is a corollary of item 1, but it is worth pinning with a test.
`hash(::FormSeq)`/`hash(::FormMap)` hash elements with Julia's `hash`, which
separates `-0.0` from `0.0`, while the current `isequal` compares numerically,
so the two relations contradict each other:

```julia
a, b = mk(-0.0), mk(0.0)
a == b            # true
isequal(a, b)     # true
isequiv(a, b)     # true
hash(a) == hash(b)  # false
d = Dict{Any,Int}(); d[a] = 1; get(d, b, :missing)  # :missing
```

Two keys that compare equal occupy different slots. Fixing item 1 (recursing
with `isequal`) also fixes this, because the element hash and Julia's
`isequal` agree on both a NaN and `-0.0`: `isequal(a, b)` then becomes false and
`hash(a) == hash(b)` is already false, so the pair is consistent. A regression
test over `mk(NaN)` and `mk(-0.0)`/`mk(0.0)` would keep it that way. If instead
the container relations are ever routed through the equivalence machinery
(`_equiv_leaf`/`equivhash` in `src/equivalence.jl`), the container hash must be
routed through `equivhash` at the same time.

## 3. `load!` overwrites newer in-memory metadata with the database row

`load!` (`src/volatile.jl:42-65`) unconditionally replaces both volatiles from
the row:

```julia
form, metadata, history = _read_current(vf.db, vf.id)
vf.volatile = Volatile{Form}(form)
vf.metavolatile = Volatile{FormMetadata}(metadata)
```

`set_metadata!` commits its edit to the metadata `Volatile` immediately (which
fixes same-object visibility), but the row update lands later on the writer. If
a form is edited while unloaded and its payload is then read within that window,
the stale row replaces the committed in-memory metadata. AirLang reproduced this
about 1 in 100 iterations by `chmod!`-ing an unloaded mutable and then reading
its payload; it now flushes metadata eagerly (`_set_metadata!`/`_flush_metadata!`
in AirLang's `src/hooks.jl`) to avoid the window.

Suggested fix: do not overwrite a metadata volatile that already holds a
committed value (e.g. assign only when `vf.metavolatile === nothing`, or track a
dirty flag and prefer the in-memory value until the writer confirms it). If the
current ordering is intended, documenting it on `load!` would let clients know
they must flush before loading.

## 4. `to_form` on an unrepresentable `Complex` raises a raw `ArgumentError`

`_formvalue(x::Complex)` (`src/form.jl:65-73`) throws `ArgumentError` when the
parts are neither exactly `Float64` nor exactly `BigFloat` —
`to_form(complex(1//3, 0))` is one. AirLang catches this at its own boundaries
(e.g. its `(complex re im)` builtin now raises an air error), but the same raw
error can still escape from a promotion inside AirDB-adjacent code. Either keep
it (it is documented in the message) or expose a predicate such as
`is_form_representable(x)` so clients can check before converting.
