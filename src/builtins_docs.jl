################################################################################
# builtins_docs.jl
#
# Documentation for the builtin library. The catalogue is air source — one
# `(docdef …)` form per name, or per family of names that share a description —
# in `core.air` beside this file. The forms are read once when the package
# loads and installed in `BUILTIN_DOCS`; `(doc …)` and `(help …)` read that
# table, and `(doc .air)`, `(help)`, and `(help :category)` present the index.
#
# A `docdef` is a process-global registration, not a definition: like `layout`,
# it is not undone by `sandbox` and it is not transactional. User rules carry
# their documentation in the rule's docstring instead (see `builtins_rules.jl`),
# which is scoped to the namespace that holds the rule.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# name => (category, deindented docstring); `_DOC_ORDER` keeps the order the
# catalogue declares, so the index is stable from run to run.
const BUILTIN_DOCS = Dict{Symbol,Tuple{Symbol,String}}()
const _DOC_ORDER = Symbol[]

# ---- the docdef form ---------------------------------------------------------

_docdef_string(x::Form) = (l = _leafof(x); l isa AbstractString)

# A name in a docdef is any bare symbol that is not a keyword or a wildcard.
# Unlike `is_raw_symbol` this admits the reserved heads (`hold`, `.`), because a
# catalogue entry documents a name rather than defining one.
function _is_docdef_name(x::Form)
    l = _leafof(x)
    return l isa Symbol && !is_keyword(x) && !is_wildcard(x)
end

# Collect the names in a docdef's name position: a bare symbol, or a form of
# them, `(sqrt cbrt exp)`, so one description can cover a family.
function _docdef_names!(out::Vector{Symbol}, x::Form)
    if _is_docdef_name(x)
        push!(out, _symbolof(x))
        return out
    elseif x isa FormContainer && isempty(x.map) && !isempty(x.seq)
        for v in _sx(x.seq, 1:length(x.seq))
            _docdef_names!(out, to_form(v))
        end
        return out
    end
    throw(AirDefError("docdef: " * air_string(x) * " is not a name"))
end

# `(docdef [category] name… "text"…)` → [(name, category, text), …]. The
# category is an optional keyword (`:math`); the names are raw symbols or a form
# of them; every remaining element is a string, joined with newlines.
function _docdef_entries(x::Form)
    (x isa FormContainer) ||
        throw(AirDefError("docdef: expected a (docdef …) form"))
    head_symbol(x) === :docdef ||
        throw(AirDefError("docdef: expected a form headed by docdef"))
    isempty(x.map) || throw(AirDefError("docdef: takes no map entries"))
    xs = Form[to_form(v) for v in _sx(x.seq, 2:length(x.seq))]
    isempty(xs) && throw(AirDefError("docdef: needs a name and a docstring"))
    cat = :general
    if is_keyword(xs[1])
        cat = Symbol(chop(String(_symbolof(xs[1])); head = 1, tail = 0))
        xs = xs[2:end]
    end
    names = Symbol[]
    i = 1
    while i <= length(xs) && !_docdef_string(xs[i])
        _docdef_names!(names, xs[i])
        i += 1
    end
    isempty(names) && throw(AirDefError("docdef: needs at least one name"))
    i <= length(xs) ||
        throw(AirDefError("docdef: needs a docstring for " * string(names[1])))
    parts = String[]
    for j in i:length(xs)
        _docdef_string(xs[j]) ||
            throw(AirDefError("docdef: expected a string, found " *
                              air_string(xs[j])))
        push!(parts, _dedent_doc(_leafof(xs[j])))
    end
    text = join(parts, '\n')
    return [(n, cat, text) for n in names]
end

# The first entry for a name fixes its category and its place in the index; a
# later entry **amends** it, its text appended as a further paragraph. That is
# how a specialised entry (`get` on a tensor path) extends the general one
# without displacing it.
function _install_docdef!(name::Symbol, cat::Symbol, text::String)
    old = get(BUILTIN_DOCS, name, nothing)
    if old === nothing
        push!(_DOC_ORDER, name)
        BUILTIN_DOCS[name] = (cat, text)
    else
        BUILTIN_DOCS[name] = (old[1], old[2] * "\n\n" * text)
    end
    return nothing
end

# `(docdef [category] name… "text"…)` — declare documentation for builtin names.
# Core documentation is installed when the package loads; this form exists so a
# library can document names it adds, and so `core.air` is ordinary air source.
function _bi_docdef(env::Env, scope::Scope, call::FormContainer)
    for (n, c, t) in _docdef_entries(call)
        _install_docdef!(n, c, t)
    end
    return naught
end
special!(:docdef, _bi_docdef)

# ---- the catalogue -----------------------------------------------------------

coredocspath() = joinpath(@__DIR__, "core.air")

function _load_core_docs!(path::AbstractString = coredocspath())
    for form in read_all_air(read(path, String))
        for (n, c, t) in _docdef_entries(form)
            _install_docdef!(n, c, t)
        end
    end
    return BUILTIN_DOCS
end

Base.include_dependency(coredocspath())
_load_core_docs!()

# ---- rendering ---------------------------------------------------------------

# The index: every documented name, grouped by category, in declaration order.
function _doc_categories()
    cats = Symbol[]
    for n in _DOC_ORDER
        c = BUILTIN_DOCS[n][1]
        c in cats || push!(cats, c)
    end
    return cats
end

function _doc_category_text(cat::Symbol)
    names = [n for n in _DOC_ORDER if BUILTIN_DOCS[n][1] === cat]
    isempty(names) && return ""
    lines = [":" * String(cat) * " (" * string(length(names)) * ")"]
    cur = "  "
    for (i, n) in enumerate(names)
        word = (i == 1 ? "" : "  ") * string(n)
        if length(cur) + length(word) > 78 && i > 1
            push!(lines, cur)
            cur = "  " * string(n)
        else
            cur *= word
        end
    end
    push!(lines, cur)
    return join(lines, '\n')
end

function _doc_index_text(cat::Union{Nothing,Symbol} = nothing)
    if cat !== nothing
        t = _doc_category_text(cat)
        return isempty(t) ? "no documentation category :" * String(cat) : t
    end
    cats = _doc_categories()
    lines = ["Air documents " * string(length(BUILTIN_DOCS)) *
             " builtin names in " * string(length(cats)) * " categories:"]
    for c in cats
        push!(lines, "")
        push!(lines, _doc_category_text(c))
    end
    push!(lines, "")
    push!(lines, "Use (doc NAME) for one entry and (help) for an introduction.")
    return join(lines, '\n')
end

# One builtin's entry: the name, its category, and the catalogue text indented
# under it. The text's first line is conventionally the call's spelling.
function _builtin_doc_text(name::Symbol, cat::Symbol, text::AbstractString)
    body = join([isempty(l) ? "" : "  " * l for l in split(text, '\n')], '\n')
    return air_string(Form(name)) * "  (builtin :" * String(cat) * ")\n" * body
end

# The names a `doc` argument identifies: a raw symbol, `.air`, or `.air.NAME`.
# Anything else (`(log ?x)`, a literal) is matched against rule patterns.
_dot_root(x::Form) = (l = _leafof(x); l === DOT_ROOT)

function _doc_target_symbol(x::Form)
    _is_docdef_name(x) && return _symbolof(x)
    if x isa FormContainer && isempty(x.map) && head_symbol(x) === :get
        xs = Form[to_form(v) for v in _sx(x.seq, 1:length(x.seq))]
        if length(xs) == 3 && _dot_root(xs[2]) && is_keyword(xs[3]) &&
           _symbolof(xs[3]) === Symbol(":air")
            return :air
        elseif length(xs) == 4 && _dot_root(xs[2]) && is_keyword(xs[3]) &&
               _symbolof(xs[3]) === Symbol(":air")
            # The keys of a `.` path are held keywords, so their leaf keeps the
            # `:` marker; the catalogue is keyed by the bare name.
            l = _leafof(xs[4])
            l isa Symbol || return nothing
            return Symbol(lstrip(String(l), ':'))
        end
    end
    return nothing
end

# The text `(doc x)` and `(help x)` return for `x`: the built catalogue entry
# first, then any documented rules, newest first.
function _doc_return_text(env::Env, scope::Scope, arg::Form)
    sym = _doc_target_symbol(arg)
    sym === :air && return _doc_index_text()
    chunks = String[]
    if sym !== nothing
        bd = get(BUILTIN_DOCS, sym, nothing)
        bd === nothing || push!(chunks, _builtin_doc_text(sym, bd[1], bd[2]))
    end
    rulearg = sym === nothing ? arg : Form(sym)
    entries = [(r.pattern, r.doc) for r in _doc_rules(env, scope, rulearg)
               if r.doc !== nothing]
    isempty(entries) || push!(chunks, _doc_text(entries))
    isempty(chunks) && return "no documentation found for " * air_string(arg)
    return join(chunks, "\n\n")
end

# ---- help --------------------------------------------------------------------

const _HELP_INTRO = raw"""
Air is a Clojure- and Mathematica-inspired scripting language that runs on
Julia. Everything in Air is a form: code, data, definitions, facts, and errors
are the same kind of immutable, inspectable value.

A form is a sequence and a map at once. (f 1 2 a=3) is the sequence (f 1 2)
with the map entry a=3; the two mix freely, map entries may appear anywhere,
and map order does not matter. Scalars are numbers, strings, symbols (f), and
keywords (:key). A pattern's ?name is a wildcard.

Evaluation is term rewriting. The interpreter reduces a form from the inside
out, and a form changes only when a rule matches it:

    (def (fact ?n) (if (< n 2) 1 (* n (fact (- n 1)))))
    (fact 5)                        # => 120

The body is the replacement, and a form with no matching rule is already a
fixed point — (f 1 2) is data until you define f. The functions that ship with
Air are the builtins: special forms (def, let, if, do, …) and Julia-backed
functions. Every builtin and operator name is a member of the core namespace
.air, so (.air.sqrt 9) is 3.0, and (doc .air) lists the whole catalogue.

Quotes hold code as data: (' f 1) is a held form, and ~ evaluates one
expression inside a hold — the quasiquote hole. (unhold x) evaluates a held
value. Inside a hold a bare symbol stays literal.

Namespaces are layered, permission-checked rule stores that double as logic
sets: (namespace .app …) opens one, (using .app …) activates it for a body,
and (assert .app (p 1)) / (query .app (p ?x)) use the fact engine. . is the
global root, $ the current user's home, and @ the attached database root.

Errors are ordinary values: (error :tag …) never reduces, so it is matched and
inspected like any other form, and (do … (except …)) handles one.
(raise tag data…) throws one.

To explore from here:

    (doc NAME)          documentation for a builtin, an operator, or a def
    (doc .air)          every builtin name, grouped by category
    (help :collection)  the names in one category, e.g. :collection, :math
    (.air.NAME args…)   call any builtin explicitly through .air
    (definitions NAME)  the def forms that mention or match NAME

The manual is the Air book under book/, arranged as a reading order: syntax,
the data model, control flow, errors, and patterns first; then numbers,
strings, collections, tensors, and tables; then namespaces, permissions, and
the rule systems; then mutation, concurrency, and events; then storage,
interfaces, and a reference. README.md holds a one-page summary of the whole
language.
"""

# `(help)` prints an introduction to the language; `(help name)` prints that
# name's documentation; `(help :category)` or `(help :all)` prints an index.
function _bi_help(env::Env, scope::Scope, call::FormContainer)
    n = length(call.seq)
    text = if n == 1
        _HELP_INTRO
    elseif n == 2
        arg = to_form(call.seq[2])
        if is_keyword(arg)
            cat = Symbol(chop(String(_symbolof(arg)); head = 1, tail = 0))
            cat === :all ? _doc_index_text() : _doc_index_text(cat)
        else
            _doc_return_text(env, scope, arg)
        end
    else
        throw(AirEvalError("help takes at most one argument"))
    end
    out = _air_out(env)
    write(out, text)
    endswith(text, "\n") || write(out, "\n")
    return naught
end
special!(:help, _bi_help)
