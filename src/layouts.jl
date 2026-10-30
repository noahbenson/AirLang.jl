################################################################################
# layouts.jl
#
# Layouts declare how a form is broken across lines when it does not fit the
# print width. A declaration is an ordinary air form:
#
#     (layout (def ?name ?&body) head=2 indent=2 map=block)
#
# Its pattern is matched structurally against the form being printed — literals
# and wildcards, no conditions — so the layout is picked by *shape* rather than
# by evaluated arguments. Declarations are process-global (a layout is not a
# definition: a transaction or a sandbox does not undo one) and are consulted by
# `air_pretty_string`; a set of defaults is installed at load time and always
# consulted after the user's declarations.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    LayoutSpec

A registered layout: the `pattern` that selects it, the number of sequence
`head` elements pinned to the opening line, the continuation `indent` (a column
offset past the opening parenthesis, or `:align` for the column of the last
pinned element), and whether map entries are one per line (`mapblock`).
"""
struct LayoutSpec
    pattern::Form
    head::Int
    indent::Union{Int,Symbol}
    mapblock::Bool
end

# User declarations, newest last, keyed by the raw head symbol of the pattern.
const LAYOUTS = Dict{Symbol,Vector{LayoutSpec}}()
# The built-in defaults, consulted after every user declaration.
const DEFAULT_LAYOUTS = Dict{Symbol,Vector{LayoutSpec}}()
const LAYOUTS_LOCK = ReentrantLock()

# ---- structural pattern matching ---------------------------------------------
#
# A layout pattern is matched without an environment or a scope, so it may use
# wildcards and rest markers but no `\` conditions (evaluation would need the
# caller's scope, which printing does not have). Map entries are ignored on both
# sides: a layout is about how a form's *sequence* is laid out, so `(def (f ?x)
# body)` still selects a `def` with `memoize=true`.

const _LAYOUT_COND = Symbol("\\")

function _lay_eq(pat::Form, subj::Form)::Bool
    if pat isa FormScalar
        l = value(pat)
        if l isa Symbol && is_wildcard(l)
            return _rest_marker(l) === nothing      # a plain wildcard
        end
        return subj isa FormScalar && isequal(value(subj), l)
    end
    subj isa FormContainer || return false
    return _lay_seq_match(pat.seq, subj.seq)
end

function _lay_seq_match(ps, ss)::Bool
    i, j = 1, 1
    while i <= length(ps)
        p = to_form(ps[i])
        s = _symbolof(p)
        m = (s !== nothing && is_wildcard(s)) ? _rest_marker(s) : nothing
        if m !== nothing
            # A rest marker consumes every remaining subject element and may
            # only be last (the declaration checks this).
            return i == length(ps)
        end
        j > length(ss) && return false
        _lay_eq(p, to_form(ss[j])) || return false
        i += 1
        j += 1
    end
    return j == length(ss) + 1
end

_layout_matches(spec::LayoutSpec, x::Form) = _lay_eq(spec.pattern, x)

# ---- lookup ------------------------------------------------------------------

function _layout_any(specs::Union{Nothing,Vector{LayoutSpec}}, x::Form)
    specs === nothing && return nothing
    for i in length(specs):-1:1        # newest declaration wins
        _layout_matches(specs[i], x) && return specs[i]
    end
    return nothing
end

"""
    _layout_for(x) -> Union{Nothing,LayoutSpec}

The layout that governs printing `x`: the newest matching user declaration, then
the newest matching default, then `nothing` (the generic greedy layout).
"""
function _layout_for(x::Form)
    x isa FormContainer || return nothing
    isempty(x.seq) && return nothing
    h = head_symbol(x)
    h === nothing && return nothing
    return lock(LAYOUTS_LOCK) do
        s = _layout_any(get(LAYOUTS, h, nothing), x)
        s === nothing ? _layout_any(get(DEFAULT_LAYOUTS, h, nothing), x) : s
    end
end

# ---- declaration -------------------------------------------------------------

function _layout_int_opt(env::Env, scope::Scope, call::FormContainer, key::Symbol,
                         default::Integer, name::AbstractString)
    haskey(call.map, key) || return Int(default)
    l = _leafof(air_reduce(env, scope, to_form(call.map[key])))
    (l isa Integer && l >= 0) ||
        throw(AirEvalError("$name: $(String(key)) must be a non-negative integer"))
    return _as_int(l, "$name: $(String(key))")
end

function _layout_indent_opt(env::Env, scope::Scope, call::FormContainer)
    key = Symbol(":indent")
    haskey(call.map, key) || return 1
    f = air_reduce(env, scope, to_form(call.map[key]))
    l = _leafof(f)
    # `:align` (or the bare `align`); an air keyword is the symbol with its
    # leading ':' (`Symbol(":align")`), not Julia's `:align`.
    (l === :align || l === Symbol(":align")) && return :align
    (l isa Integer && l >= 0) ||
        throw(AirEvalError("layout: indent must be a non-negative integer or :align"))
    return _as_int(l, "layout: indent")
end

function _layout_map_opt(env::Env, scope::Scope, call::FormContainer)
    key = Symbol(":map")
    haskey(call.map, key) || return "inline"
    l = _leafof(air_reduce(env, scope, to_form(call.map[key])))
    (l === :inline || l === Symbol(":inline")) && return "inline"
    (l === :block || l === Symbol(":block")) && return "block"
    throw(AirEvalError("layout: map must be inline or block"))
end

# Reject a pattern the printer cannot use: no head, no map, no conditions, and a
# rest marker only in final position.
function _check_layout_pattern(pat::Form)
    pat isa FormContainer ||
        throw(AirEvalError("layout: the pattern must be a form"))
    isempty(pat.map) ||
        throw(AirEvalError("layout: the pattern may not have map entries"))
    h = head_symbol(pat)
    (h !== nothing && is_raw_symbol(h)) ||
        throw(AirEvalError("layout: the pattern needs a plain symbol head"))
    _check_layout_items(pat)
    return pat
end

function _check_layout_items(x)
    x isa FormContainer || return nothing
    for i in 1:length(x.seq)
        f = to_form(x.seq[i])
        s = _symbolof(f)
        if s !== nothing && s === _LAYOUT_COND
            throw(AirEvalError("layout: conditions (\\ ...) are not allowed in a pattern"))
        end
        if s !== nothing && is_wildcard(s) && _rest_marker(s) !== nothing
            i == length(x.seq) ||
                throw(AirEvalError("layout: a rest marker must be the last pattern element"))
        end
        f isa FormContainer && _check_layout_items(f)
    end
    return nothing
end

"""
    _bi_layout(env, scope, call)

`(layout PATTERN head=N indent=M map=:inline|:block)` — register a layout for
every form matching `PATTERN`. Re-registering the same pattern replaces its
declaration, so evaluating a declaration twice is harmless. Returns `naught`.
"""
function _bi_layout(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "layout",
                   (Symbol(":head"), Symbol(":indent"), Symbol(":map")))
    length(call.seq) == 2 ||
        throw(AirEvalError("layout takes one pattern"))
    pat = _check_layout_pattern(to_form(call.seq[2]))
    spec = LayoutSpec(pat,
                      _layout_int_opt(env, scope, call, Symbol(":head"), 1, "layout"),
                      _layout_indent_opt(env, scope, call),
                      _layout_map_opt(env, scope, call) == "block")
    h = head_symbol(pat)::Symbol
    lock(LAYOUTS_LOCK) do
        v = get!(LAYOUTS, h, LayoutSpec[])
        i = findfirst(s -> air_string(s.pattern) == air_string(pat), v)
        i === nothing ? push!(v, spec) : (v[i] = spec)
    end
    return naught
end
special!(:layout, _bi_layout)

# `(layouts)` — the registered user declarations, newest last, as a held list.
function _bi_layouts(env::Env, scope::Scope, call::FormContainer)
    (length(call.seq) == 1 && isempty(call.map)) ||
        throw(AirEvalError("layouts takes no arguments"))
    out = Form[]
    lock(LAYOUTS_LOCK) do
        for h in sort!(collect(keys(LAYOUTS)); by = String)
            for s in LAYOUTS[h]
                push!(out, _layout_decl(s))
            end
        end
    end
    return _hold_form(out, FormMap())
end
special!(:layouts, _bi_layouts)

function _layout_decl(spec::LayoutSpec)
    ind = spec.indent === :align ? Form(:align) : Form(spec.indent)
    m = Form(spec.mapblock ? :block : :inline)
    pairs = Pair{Symbol,Form}[Symbol(":head") => Form(spec.head),
                              Symbol(":indent") => ind,
                              Symbol(":map") => m]
    return _ns_form(Form[Form(:layout), spec.pattern], pairs)
end

# `(clear-layout :def)` / `(clear-layout :all)` — drop user declarations. The
# built-in defaults cannot be removed. Returns `naught`.
function _bi_clear_layout(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "clear-layout", ())
    length(call.seq) == 2 ||
        throw(AirEvalError("clear-layout takes a head symbol or :all"))
    l = _leafof(air_reduce(env, scope, to_form(call.seq[2])))
    l isa Symbol || throw(AirEvalError("clear-layout takes a head symbol or :all"))
    lock(LAYOUTS_LOCK) do
        if l === Symbol(":all")
            empty!(LAYOUTS)
        else
            delete!(LAYOUTS, _bindname(l))
        end
    end
    return naught
end
special!(Symbol("clear-layout"), _bi_clear_layout)

# `(reset-layouts)` — drop every user declaration (the defaults stay).
special!(Symbol("reset-layouts"), (env, scope, call) -> begin
    (length(call.seq) == 1 && isempty(call.map)) ||
        throw(AirEvalError("reset-layouts takes no arguments"))
    lock(LAYOUTS_LOCK) do
        empty!(LAYOUTS)
    end
    return naught
end)

# ---- default layouts ---------------------------------------------------------
#
# Installed at load time. Each is a shape plus its layout; the user's own
# declarations are consulted first, so any of these can be overridden or (with
# `clear-layout` on the user's entry) disabled for that shape.

function _register_default_layout!(pattern::Form, head::Int, indent::Union{Int,Symbol},
                                   mapblock::Bool)
    spec = LayoutSpec(_check_layout_pattern(pattern), head, indent, mapblock)
    h = head_symbol(pattern)::Symbol
    push!(get!(DEFAULT_LAYOUTS, h, LayoutSpec[]), spec)
    return nothing
end

function _install_default_layouts!()
    _register_default_layout!(_layout_pattern(:def), 2, 2, true)
    _register_default_layout!(_layout_pattern(:let), 2, 2, false)
    _register_default_layout!(_layout_pattern(:val), 2, 2, true)
    _register_default_layout!(_layout_pattern(:if), 1, 2, false)
    _register_default_layout!(_layout_pattern(:cond), 1, 2, false)
    _register_default_layout!(_layout_pattern(:do), 1, 2, true)
    _register_default_layout!(_layout_pattern(:tx), 1, 2, true)
    _register_default_layout!(_layout_pattern(:namespace), 2, 2, false)
    _register_default_layout!(_layout_pattern(Symbol("using")), 1, 2, false)
    _register_default_layout!(_layout_pattern(:logic), 2, 2, false)
    _register_default_layout!(_layout_pattern(:rule), 1, 2, false)
    _register_default_layout!(_layout_pattern(:assert), 2, 2, false)
    _register_default_layout!(_layout_pattern(:error), 2, 2, false)
    return nothing
end

# `(HEAD ?&rest)` — the shape "a call to HEAD with any arguments".
_layout_pattern(head::Symbol) =
    Form(PVector{Any}([Form(head), Form(Symbol("?&rest"))]), PDict{Symbol,Any}())

_install_default_layouts!()

# ---- printing ----------------------------------------------------------------
#
# These extend the flat printer in forms.jl: `_pretty_show` stays the entry
# point, delegating a splittable container either to the generic greedy layout
# or to a registered one. Both are exported to `forms.jl`'s caller by being
# defined here after `air_pretty_string`; Julia resolves the call at run time.

# Print a container under `spec`, breaking greedily once the opening line is
# exceeded. Returns the column just after the closing parenthesis.
function _pretty_show_layout(io::IO, x::FormContainer, col::Integer,
                             width::Integer, spec::LayoutSpec)::Int
    print(io, "(")
    cur = col + 1
    first = true
    n = length(x.seq)
    npin = min(spec.head, n)
    aligncol = col + 2
    for i in 1:npin
        fv = to_form(x.seq[i])
        if !first
            print(io, " ")
            cur += 1
        end
        first = false
        aligncol = cur
        cur = _pretty_show(io, fv, cur, width)
    end
    inner = spec.indent === :align ? aligncol : col + spec.indent
    inner = max(inner, col + 1)      # never back up past the opening "("
    for i in (npin + 1):n
        fv = to_form(x.seq[i])
        if first
            first = false
        elseif cur + 1 + textwidth(air_string(fv)) < width
            print(io, " ")
            cur += 1
        else
            print(io, "\n", " "^inner)
            cur = inner
        end
        cur = _pretty_show(io, fv, cur, width)
    end
    for k in sort!(collect(keys(x.map)))
        kt = _keyword_text(k)
        fv = to_form(x.map[k])
        full = kt * "=" * air_string(fv)
        if first
            first = false
        elseif spec.mapblock || !(cur + 1 + textwidth(full) < width)
            print(io, "\n", " "^inner)
            cur = inner
        else
            print(io, " ")
            cur += 1
        end
        if cur + textwidth(full) <= width
            print(io, full)
            cur += textwidth(full)
        else
            print(io, kt, "=")
            cur += textwidth(kt) + 1
            cur = _pretty_show(io, fv, cur, width)
        end
    end
    print(io, ")")
    return cur + 1
end
