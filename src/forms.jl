################################################################################
# forms.jl
#
# Helpers over AirDB's `Form` value model: the `naught` constant, symbol and
# keyword classification, the runtime canonicalization invariant, truthiness,
# and the air printer.
#
# Air values are AirDB `Form`s. A `FormScalar` wraps a leaf; a `FormContainer`
# holds a sequence (`seq`) and a symbol-keyed map (`map`); a `VolatileForm` is a
# mutable. Containers store raw leaves (a nested `FormScalar` is unwrapped on
# store), so a value read out of a container is re-wrapped with `to_form`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    naught

The air null value: `Form(nothing)`. The empty form `()` is identical to it, and
both are logically false.
"""
const naught = Form(nothing)

# ---- symbol classification ---------------------------------------------------

is_keyword(s::Symbol) = startswith(String(s), ":")
is_wildcard(s::Symbol) = startswith(String(s), "?")
# The hold head and its alias, the namespace-root marker, and the two internal
# namespace-entry heads are reserved: they never anchor a rule (and a pattern does
# not have to contain one as its anchor). The dot root is written `.` and resolves
# to the global namespace volatile.
#
# `$` (the current user's home) and `@` (the database root, or `.` for a system
# user) are *not* reserved: they are ordinary raw symbols, so a `let`/`loop`/`for`
# binding can shadow them, and only an unbound occurrence resolves to a root.
const DOT_ROOT = Symbol(".")
const HOME_ROOT = Symbol("\$")
const AT_ROOT = Symbol("@")
const NS_FN = Symbol("ns-fn")
const NS_SUB = Symbol("ns-sub")
const NS_VAL = Symbol("ns-val")
const NS_PROXY = Symbol("ns-proxy")
const NS_PROXY_APPLY = Symbol("ns-proxy-apply")
const NS_SUB_LINK = Symbol("ns-sub-link")
const NS_ALIAS = Symbol("ns-alias")
const RESERVED_HEADS = Set([Symbol("'"), Symbol("hold"), DOT_ROOT, NS_FN, NS_SUB,
                            NS_VAL, NS_PROXY, NS_PROXY_APPLY, NS_SUB_LINK,
                            NS_ALIAS])
is_raw_symbol(s::Symbol) = !is_keyword(s) && !is_wildcard(s) && !(s in RESERVED_HEADS)

# `(ns-fn <path> :name)` is the value a namespace exposes for a name defined by
# one or more `def`s. It is inert data except in head position, where it applies
# the namespace's rules for `name` to the whole call. `(ns-sub <path>)` is the
# map entry for a subnamespace; a lookup unwraps it to the subnamespace's
# volatile. `(ns-val <path> :name)` is the value a namespace exposes for a `val`:
# it dereferences to that binding's current thread-local value.
#
# An imported entry that could not be copied by value (one the importer may
# execute but not read, or one marked `anchor=true`) is a **proxy**: it stores
# the source path and name and resolves lazily. `(ns-proxy <path> :name)` is both
# the entry body and the map marker; in head position it applies the source
# namespace's rules, and a `val` marker dereferences through the source binding.
# `(ns-sub-link <path>)` is an imported subnamespace, and `(ns-alias <path>
# :name)` binds a `use`/`import` spec's `as=` name to the source namespace.
_is_ns_fn(x::Form) = x isa FormContainer && head_symbol(x) === NS_FN
_is_ns_sub(x::Form) = x isa FormContainer && head_symbol(x) === NS_SUB
_is_ns_val(x::Form) = x isa FormContainer && head_symbol(x) === NS_VAL
_is_ns_proxy(x::Form) = x isa FormContainer && head_symbol(x) === NS_PROXY
_is_ns_sub_link(x::Form) = x isa FormContainer && head_symbol(x) === NS_SUB_LINK
_is_ns_alias(x::Form) = x isa FormContainer && head_symbol(x) === NS_ALIAS

# The "such that" mark that attaches a condition to the pattern before it.
const COND_MARK = Symbol("\\")

# ---- holds -------------------------------------------------------------------
#
# A *held* form is a container whose **first element** is the symbol `'`. It
# holds all of its remaining sequence elements and its map: `(' a b c)` holds
# `(a b c)` and `(' f k=v)` holds `(f k=v)`. The canonical hold of a form
# splices its elements, so `_holdify((a b c))` is `(' a b c)`; a scalar is one
# element, `_holdify(a)` is `(' a)`. `'x` is reader sugar for `(' x)` when `x`
# is a scalar.
#
# The symbol `'` is otherwise ordinary: it holds only in the first position of a
# form, so `(f ' a)` passes the symbol as a value. A hold's *content* is the
# form rebuilt from everything after the head. A hold evaluates to itself except
# that `preval` holes inside it are filled in. `(hold e1 … en)` is a reserved
# alias that reduces to `(' e1 … en)`.
const HOLD = Symbol("'")
const HOLD_ALIAS = Symbol("hold")

# The pipeline: `(x >> step1 step2 …)` threads the value of `x` into the
# placeholder `_` of each raw step in turn; `(>> x step…)` is prefix sugar. The
# steps are not evaluated between substitutions; only the final form reduces.
const PIPELINE = Symbol(">>")
const PLACEHOLDER = Symbol("_")

# The canonical infix pipeline form, recognized by its second element. A hold is
# checked first, so `(' >> …)` is data.
_is_pipeline(x::FormContainer) =
    isempty(x.map) && length(x.seq) >= 3 &&
    _symbolof(to_form(x.seq[2])) === PIPELINE

# The eager-evaluation hole produced by `~e`: `~e` reads as `(preval e)`. Inside
# a hold it is evaluated when the hold is built; outside one it is an ordinary
# eager call. It is distinct from the runtime `unhold` operation, so embedded
# code containing `(unhold x)` is inert inside a held form.
const PREVAL = Symbol("preval")

# The pattern-alternative head produced by the reader's `|` sugar:
# `(a |b)` reads as `(alt a b)`, and a run `a | b | c` flattens to
# `(alt a b c)`. It is matched branch by branch (first match wins); outside a
# pattern it is ordinary inert data.
const ALT = Symbol("alt")

# The replacement-rule arrow and the RETE rule head. Both are reserved: their
# forms are data, so the reducer returns them unchanged.
const REPLACE_ARROW = Symbol("->")
const RULE = Symbol("rule")

"""
    _is_replacement_rule(x) -> Bool

Whether `x` is a replacement rule `(condition -> replacement [unhold=…])`: a
three-element container whose middle element is `->`.
"""
_is_replacement_rule(x::Form) =
    x isa FormContainer && length(x.seq) == 3 &&
    _symbolof(to_form(x.seq[2])) === REPLACE_ARROW

"""
    _is_rule_form(x) -> Bool

Whether `x` is a RETE rule form `(rule conditions… instructions…)`.
"""
_is_rule_form(x::Form) = x isa FormContainer && head_symbol(x) === RULE

"""
    _is_hold(x) -> Bool

Whether `x` is a held form: a container whose first element is `'`.
"""
_is_hold(x::Form) = x isa FormContainer && head_symbol(x) === HOLD

"""
    _holdify(x) -> FormContainer

The canonical held form for `x`. A container is spliced — `_holdify((a b c))` is
`(' a b c)` — and a scalar becomes the single element of the hold —
`_holdify(a)` is `(' a)`. An existing hold is returned unchanged.
"""
function _holdify(x::Form)
    _is_hold(x) && return x
    if x isa FormContainer
        seq = FormValue[Form(HOLD)]
        append!(seq, x.seq)
        return FormContainer(FormSeq(seq), x.map)
    end
    return FormContainer(FormSeq(FormValue[_store_form(Form(HOLD)), _store_form(x)]),
                         FormMap())
end

# A hold of exactly one scalar element, which prints with the quote sugar:
# `(' x)` prints as `'x`. Any other hold prints literally as `(' …)`.
_is_scalar_hold(x::Form) =
    _is_hold(x) && length(x.seq) == 2 && isempty(x.map) &&
    !(to_form(x.seq[2]) isa FormContainer)

# `x` held, unless it already is.
_ensure_hold(x::Form) = _is_hold(x) ? x : _holdify(x)

# The hold whose content elements are `seq` (with map `map`): every element is
# held as it stands, so a container argument stays one element.
_hold_form(seq, map) = FormContainer(FormSeq(FormValue[Form(HOLD), seq...]), map)

# The `hold=` option of a call form: true when its map's `:hold` entry is truthy.
_hold_opt(call::FormContainer) =
    haskey(call.map, Symbol(":hold")) && truthy(to_form(call.map[Symbol(":hold")]))

"""
    _hold_content(x) -> Form

The form a hold holds: everything after the head, plus its map, canonicalized.
`(' a b c)` holds `(a b c)`; `(' a)` holds `a`; `(')` holds `naught`. A hold of
exactly one element is that element (a holding of one container is the container,
not a one-element list around it). A form that is not a hold is returned as it
is.
"""
function _hold_content(x::Form)
    _is_hold(x) || return canonicalize(x)
    n = length(x.seq)
    if n == 2 && isempty(x.map)
        return canonicalize(to_form(x.seq[2]))
    end
    return canonicalize(FormContainer(FormSeq(_sx(x.seq, 2:n)), x.map))
end

# One hold layer removed, without evaluating the content.
_strip_hold(x::Form) = _is_hold(x) ? _hold_content(x) : x

"""
    _rest_marker(s) -> Union{Nothing,Tuple{Symbol,Union{Nothing,Symbol}}}

The kind and name of a rest wildcard: `?&` (the sequence rest) → `(:seq, name)`,
`?*` (the keyword rest) → `(:map, name)`, `??` (any remaining elements) →
`(:both, name)`. `nothing` for anything else.
"""
function _rest_marker(s::Symbol)
    t = String(s)
    startswith(t, "??") && return (:both, _rest_name(t[3:end]))
    startswith(t, "?&") && return (:seq, _rest_name(t[3:end]))
    startswith(t, "?*") && return (:map, _rest_name(t[3:end]))
    return nothing
end

_rest_name(t::AbstractString) = isempty(t) ? nothing : Symbol(t)

# A pattern condition passes only when it evaluates to `true` (not merely a
# truthy form), so an undefined predicate fails rather than passing.
_cond_true(x::Form) = x isa FormScalar && value(x) === true

# The leaf of a scalar form, or `nothing` for anything that is not a scalar.
# Note that `nothing` is itself a valid leaf (naught), so callers that must
# distinguish use `isa FormScalar` directly.
_leafof(x::FormScalar) = value(x)
_leafof(::Form) = nothing

# The `Symbol` a form holds, or `nothing`.
_symbolof(x::Form) = (l = _leafof(x); l isa Symbol ? l : nothing)

is_keyword(x::Form) = (s = _symbolof(x); s !== nothing && is_keyword(s))
is_wildcard(x::Form) = (s = _symbolof(x); s !== nothing && is_wildcard(s))
is_raw_symbol(x::Form) = (s = _symbolof(x); s !== nothing && is_raw_symbol(s))

# ---- canonicalization --------------------------------------------------------

"""
    canonicalize(x) -> Form

The canonical form of `x`: a container with no map and an empty sequence is
`naught`; everything else is unchanged. In particular a map-less one-element
container is an ordinary form and is **not** collapsed to its element: `(1)`,
`((1))`, `(naught)`, and `(')` all keep their shape.

`naught` is the same value as `()`; canonicalization is a runtime invariant of
the reducer, not a property of equality. The reader and every container
constructor normalize empty containers away (see `_store_form` and
`_normalize_empty`), so `()` and `naught` are interchangeable at any depth.
"""
canonicalize(x::Form) = x
function canonicalize(x::FormContainer)
    (isempty(x.map) && isempty(x.seq)) && return naught
    return x
end

"""
    _normalize_empty(x) -> Form

Recursively replace every empty container with `naught`, rebuilding a container
only when one of its children changed. This is the ingress normalization for
forms that did not pass through the reader or `_store_form` (for example
`from-json`), so that `()` and `naught` are the same value at any depth.
"""
_normalize_empty(x::Form) = x
function _normalize_empty(x::FormContainer)
    (isempty(x.map) && isempty(x.seq)) && return naught
    changed = false
    seq = FormValue[]
    for v in x.seq
        f = to_form(v)
        nf = _normalize_empty(f)
        changed |= !isequal(nf, f)
        push!(seq, _store_form(nf))
    end
    map = Pair{Symbol,FormValue}[]
    for (k, v) in x.map
        f = to_form(v)
        nf = _normalize_empty(f)
        changed |= !isequal(nf, f)
        push!(map, k => _store_form(nf))
    end
    return changed ? FormContainer(FormSeq(seq), FormMap(map)) : x
end

# Store a reduced form back into a container: a scalar is unwrapped to its leaf,
# everything else is kept as it is. An empty container is stored as the `naught`
# leaf, so no empty container can survive inside another form. This mirrors
# AirDB's private `_store`.
_store_form(f::FormScalar) = value(f)
_store_form(f::FormContainer) =
    (isempty(f.map) && isempty(f.seq)) ? nothing : f
_store_form(f::Form) = f

# FormSeq supports only integer indexing; this yields a plain vector for a range.
_sx(s, r) = FormValue[s[i] for i in r]

# Replace each `?x` with the bare name `x`, so it resolves to the binding.
function _strip_wildcards(x::Form)
    if x isa FormScalar
        s = value(x)
        (s isa Symbol && is_wildcard(s) && s != Symbol("?")) &&
            return Form(Symbol(String(s)[2:end]))
        return x
    elseif x isa FormContainer
        seq = FormValue[]
        for a in x.seq
            push!(seq, _store_form(_strip_wildcards(to_form(a))))
        end
        map = Pair{Symbol,FormValue}[]
        for (k, v) in x.map
            push!(map, k => _store_form(_strip_wildcards(to_form(v))))
        end
        return FormContainer(FormSeq(seq), FormMap(map))
    else
        return x
    end
end

# ---- truth -------------------------------------------------------------------

"""
    truthy(x) -> Bool

Whether `x` is logically true: `naught`, `false`, and the empty container are
false; everything else is true.
"""
function truthy(x::Form)
    if x isa FormScalar
        v = value(x)
        return !(v === nothing || v === false)
    elseif x isa FormContainer
        return !isempty(x)
    else
        return true
    end
end

# ---- structure ---------------------------------------------------------------

# The reserved head of a splice marker produced by the `...` reader syntax: a
# form `(... x)` means "splice the elements of `x` here".
const SPLAT = Symbol("...")

"""
    _is_splat(x) -> Bool

Whether `x` is a splice marker `(... expr)`.
"""
_is_splat(x::Form) = head_symbol(x) === SPLAT

"""
    head_symbol(x) -> Union{Symbol,Nothing}

The `Symbol` at the head of the sequence of a container, or `nothing`.
"""
function head_symbol(x::Form)
    x isa FormContainer || return nothing
    isempty(x.seq) && return nothing
    v = x.seq[1]
    v isa Symbol && return v
    (v isa FormScalar && value(v) isa Symbol) && return value(v)
    return nothing
end

"""
    _is_alt(x) -> Bool

Whether `x` is a pattern alternative `(alt branch…)` (see `ALT`). A map on the
form disqualifies it: the printed alternative has none, and `(alt … k=v)` is an
ordinary literal form.
"""
_is_alt(x::Form) =
    x isa FormContainer && head_symbol(x) === ALT && isempty(x.map)

"""
    raw_symbols(x) -> Vector{Symbol}

Every raw (non-keyword, non-wildcard) symbol occurring anywhere in `x`. These
are the anchor keys under which `x` is looked up in the rule store, so a pattern
is anchored by *any* raw symbol it contains — `(1 + 1)` is anchored by `+`. The
`alt` head of a pattern alternative is syntax, not an anchor; only its branches
contribute.
"""
function raw_symbols(x::Form)
    out = Symbol[]
    _raw_symbols!(out, x)
    return out
end

function _raw_symbols!(out::Vector{Symbol}, x::FormScalar)
    s = value(x)
    (s isa Symbol && is_raw_symbol(s)) && push!(out, s)
    return out
end
function _raw_symbols!(out::Vector{Symbol}, x::FormContainer)
    # `alt` is pattern syntax, not an anchor: its branches carry the anchors.
    for i in (_is_alt(x) ? 2 : 1):length(x.seq)
        _raw_symbols!(out, to_form(x.seq[i]))
    end
    for (_, v) in x.map
        _raw_symbols!(out, to_form(v))
    end
    return out
end
_raw_symbols!(out::Vector{Symbol}, ::VolatileForm) = out
_raw_symbols!(out::Vector{Symbol}, ::FormExtern) = out   # an extern carries no anchors
_raw_symbols!(out::Vector{Symbol}, ::ActorForm) = out
_raw_symbols!(out::Vector{Symbol}, ::PromiseForm) = out
_raw_symbols!(out::Vector{Symbol}, ::DelayForm) = out

# ---- printing ----------------------------------------------------------------

"""
    air_string(x) -> String

`x` printed as air source. A complex prints as an infix sum (`4.4 + 2.0i`), which
re-reads as the expression `(+ 4.4 2.0i)` and reduces to the same value.
"""
air_string(x::Form) = sprint(air_show, x)

"""
    air_pretty_string(x; width=80) -> String

`x` printed as air source, broken across lines greedily so that lines fit
`width` characters where a container can be split. As many elements as fit are
packed per line, indented one space past the enclosing form's opening
parenthesis; an element that does not fit is broken in turn. Scalars, holds,
splats, `~` holes, and forms with a special spelling stay inline, so one
indivisible token can still exceed the width. Line breaks are whitespace, so the
result re-reads as the same form.
"""
function air_pretty_string(x::Form; width::Integer = 80)
    io = IOBuffer()
    _pretty_show(io, x, 0, width)
    return String(take!(io))
end

# Print `x` at column `col`, breaking a container that does not fit. Returns the
# column just after the last character written, so a flat list can pack several
# elements per line and a broken child leaves the parent knowing where it ended.
function _pretty_show(io::IO, x::Form, col::Integer, width::Integer)::Int
    s = air_string(x)
    (col + textwidth(s) <= width) && (print(io, s); return col + textwidth(s))
    x isa FormContainer || (print(io, s); return col + textwidth(s))
    # Forms with a special spelling are never split: a splat, a scalar hold
    # (`'x`), and a `~` hole each print as a prefix plus one operand.
    ((_is_splat(x) && length(x.seq) == 2) || _is_scalar_hold(x) ||
     (head_symbol(x) === PREVAL && length(x.seq) == 2 && isempty(x.map))) &&
        (print(io, s); return col + textwidth(s))
    print(io, "(")
    inner = col + 1
    cur = inner
    first = true
    for v in x.seq
        fv = to_form(v)
        if first
            first = false
        elseif cur + 1 + textwidth(air_string(fv)) < width
            print(io, " "); cur += 1
        else
            print(io, "\n", " "^inner); cur = inner
        end
        cur = _pretty_show(io, fv, cur, width)
    end
    for k in sort!(collect(keys(x.map)))
        kt = _keyword_text(k); fv = to_form(x.map[k])
        full = kt * "=" * air_string(fv)
        if first
            first = false
        elseif cur + 1 + textwidth(full) < width
            print(io, " "); cur += 1
        else
            print(io, "\n", " "^inner); cur = inner
        end
        if cur + textwidth(full) <= width
            print(io, full); cur += textwidth(full)
        else
            print(io, kt, "="); cur += textwidth(kt) + 1
            cur = _pretty_show(io, fv, cur, width)
        end
    end
    print(io, ")")
    return cur + 1
end

# A volatile can point (directly or indirectly) at itself. Printing tracks the
# volatiles on the current path so a cycle prints opaquely instead of recursing
# forever; the set lives in task-local storage for the duration of one print.
const _SHOW_SEEN_KEY = :airlang_show_seen

function _show_seen()
    tls = task_local_storage()
    tls isa IdDict || return nothing
    s = get(tls, _SHOW_SEEN_KEY, nothing)
    return s isa Set{Base.UUID} ? s : nothing
end

function air_show(io::IO, x::Form)
    tls = task_local_storage()
    if !(tls isa IdDict) || haskey(tls, _SHOW_SEEN_KEY)
        return _air_show(io, x)          # a nested print shares the outer set
    end
    seen = Set{Base.UUID}()
    task_local_storage(_SHOW_SEEN_KEY, seen) do
        _air_show(io, x)
    end
    return nothing
end

_air_show(io::IO, x::FormScalar) = _air_show_leaf(io, value(x))
function _air_show(io::IO, x::FormContainer)
    if _is_splat(x) && length(x.seq) == 2
        _air_show(io, to_form(x.seq[2]))
        return print(io, "...")
    end
    # A hold of exactly one scalar element prints with the quote sugar: `(' a)`
    # is `'a`. Every other hold prints literally as `(' …)`, which is also how
    # the reader accepts it.
    if _is_scalar_hold(x)
        print(io, "'")
        return _air_show(io, to_form(x.seq[2]))
    end
    # A `preval` hole prints as `~x`; `(unhold x)` is an ordinary call.
    if head_symbol(x) === PREVAL && length(x.seq) == 2 && isempty(x.map)
        print(io, "~")
        return _air_show(io, to_form(x.seq[2]))
    end
    print(io, "(")
    sep = ""
    for v in x.seq
        print(io, sep); sep = " "
        _air_show(io, to_form(v))
    end
    for k in sort!(collect(keys(x.map)))
        print(io, sep); sep = " "
        print(io, _keyword_text(k), "=")
        _air_show(io, to_form(x.map[k]))
    end
    return print(io, ")")
end
# A namespace entry volatile prints as its body, with no `(mut …)` wrapper: the
# entry list is the namespace's sequence, so a namespace reads as the defs it
# holds. The task-local environment, when one is installed (see `air_string`),
# gates the body: an entry the current user may not read prints opaquely.
const _SHOW_ENV_KEY = :airlang_show_env

function _show_env()
    tls = task_local_storage()
    return tls isa IdDict ? get(tls, _SHOW_ENV_KEY, nothing) : nothing
end

function _air_show(io::IO, x::VolatileForm)
    env = _show_env()
    entry = _is_entry_vf(x)
    if !(env === nothing || _can(env, x, :read))
        return print(io, entry ? "#<entry " : "#<volatile ", x.id, ">")
    end
    seen = _show_seen()
    if seen !== nothing && x.id in seen
        return print(io, entry ? "#<entry " : "#<volatile ", x.id, ">")
    end
    seen === nothing || push!(seen, x.id)
    try
        entry && return _air_show(io, canonicalize(x[]))
        print(io, "(mut ")
        _air_show(io, canonicalize(x[]))
        return print(io, ")")
    finally
        seen === nothing || delete!(seen, x.id)
    end
end

# A host-level extern prints as `(extern :type payload)`, so it round-trips through
# source (see the `extern` special form). A dead extern, an unresolved promise,
# and any data without a payload print opaquely — printing must never block or
# fail.
function _air_show(io::IO, x::FormExtern)
    name = _extern_type_name(x)
    data = try
        value(x)
    catch
        return print(io, "#<extern ", name, ">")
    end
    data isa DeadExtern && return print(io, "#<extern ", name, " (expired)>")
    payload = try
        _extern_payload(data)
    catch
        nothing
    end
    payload === nothing && return print(io, "#<extern ", name, ">")
    print(io, "(extern :", name, " ")
    _air_show(io, to_form(payload))
    return print(io, ")")
end

# A reference form prints opaquely by identity: reading it can force a delay or
# block on a promise, so printing never dereferences one.
_air_show(io::IO, x::ActorForm) = print(io, "#<actor ", x.id, ">")
_air_show(io::IO, x::PromiseForm) = print(io, "#<promise ", x.id, ">")
function _air_show(io::IO, x::DelayForm)
    print(io, "#<delay :", x.type)
    # An air delay's serialization is its database cell, whose id distinguishes
    # two delays of the same type (and keeps `compare` total).
    x.form isa VolatileForm && print(io, " @", x.form.id)
    return print(io, ">")
end

_air_show_leaf(io::IO, ::Nothing) = print(io, "naught")
_air_show_leaf(io::IO, v::Bool) = print(io, v ? "true" : "false")
_air_show_leaf(io::IO, v::Symbol) = print(io, v)   # keeps a leading ':' or '?'
_air_show_leaf(io::IO, v::String) = print(io, repr(v))
_air_show_leaf(io::IO, v::Number) = print(io, v)
# A complex prints as an infix sum, `4.4 + 2.0i` (the `i` attached to the
# imaginary part). The spaced form re-reads as the infix expression `(+ 4.4 2.0i)`,
# which reduces to the same value; the no-space `4.4+2.0i` is a single literal.
function _air_show_leaf(io::IO, v::ComplexF64)
    re, im = real(v), imag(v)
    return print(io, re, im < 0 ? " - " : " + ", abs(im), "i")
end

# The source text of a map key: the leading ':' of a keyword is dropped, so the
# map key `Symbol(":a")` prints as `a`.
function _keyword_text(k::Symbol)
    s = String(k)
    return startswith(s, ":") ? s[2:end] : s
end

# ---- keys --------------------------------------------------------------------

# A form key as the Julia value a container indexes by (an `Int` or a `Symbol`).
_keyof(x::Form) = _leafof(x)

# A key for `get`: air map keys are keywords, so a bare symbol `a` is read as
# the keyword `:a` (while an explicit keyword or an integer is used as is).
function _get_key(x::Form)
    l = _leafof(x)
    l isa Symbol && return is_keyword(l) ? l : Symbol(":" * String(l))
    return l
end

# Strip a leading ':' from a keyword to get a local binding name.
_bindname(k::Symbol) = (s = String(k); startswith(s, ":") ? Symbol(s[2:end]) : k)

"""
    _index_of(k, n; append=false) -> Union{Nothing,Int}

The 1-based position an integer key names in a sequence of `n` elements. `0`
names the whole form and yields `nothing`; a positive `k` counts from the front
(`1` is the first element); a negative `k` counts from the end (`-1` is the
last). For a setter (`append=true`) `n + 1` names the append position; anything
else out of range raises.
"""
function _index_of(k::Integer, n::Integer; append::Bool = false)
    k == 0 && return nothing
    if k > 0
        k <= n && return Int(k)
        (append && k == n + 1) && return Int(n + 1)
    else
        (-n <= k <= -1) && return Int(n + k + 1)
    end
    throw(AirEvalError("key $k is out of range for a form of $n elements"))
end
