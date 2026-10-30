################################################################################
# builtins_rules.jl
#
# The rule-definition and pattern-query special forms: `def`, `match?`,
# `matches`, and `replace`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# Deindent a docstring: drop leading and trailing blank lines, then remove the
# common indentation of the continuation lines. The first line starts right after
# the opening quote, so it carries no source indentation of its own and is left
# alone.
function _dedent_doc(s::AbstractString)
    occursin('\n', s) || return String(s)
    lines = String.(split(s, '\n'))
    firstline = findfirst(l -> !isempty(strip(l)), lines)
    firstline === nothing && return ""
    lastline = findlast(l -> !isempty(strip(l)), lines)
    lines = lines[firstline:lastline]
    indents = [length(l) - length(lstrip(l))
               for l in lines[2:end] if !isempty(strip(l))]
    n = isempty(indents) ? 0 : minimum(indents)
    if n > 0
        for i in 2:length(lines)
            lines[i] = isempty(strip(lines[i])) ? "" : chop(lines[i]; head = n, tail = 0)
        end
    end
    return join(lines, '\n')
end

# A `def` body inherits the whole `do`/`tx` grammar. The block options
# (`let=`, `catch=`) and trailing clauses live in the body forms; when the body
# needs any of them — or `tx=true` — the body is wrapped in a real `(do …)` or
# `(tx …)` form, so a single plain body form stays stored exactly as written.
const _DEF_DOC_KEY = Symbol(":doc")
const _DEF_OPTIONS = (HOLD_KEY, _DEF_DOC_KEY, _TX_KEY, _MEMO_KEY, _LET_KEY,
                      _CATCH_KEY)
const _VAL_OPTIONS = (HOLD_KEY, _DEF_DOC_KEY, _TX_KEY, _MEMO_KEY, _LET_KEY,
                      _CATCH_KEY)

# The pieces of a `def` (or `val`) call: the pattern, the raw body, whether the
# rule is implicit (no body), the optional deindented docstring, the `hold=`
# parameters, whether the body runs in a transaction, and the `memoize=` config.
# A literal string at the head of the body is the docstring (or it may be given
# as a `doc=` option, the spelling `definitions` produces).
function _parse_def_call(call::FormContainer, name::AbstractString = "def")
    length(call.seq) >= 2 || throw(AirDefError("$name needs a pattern"))
    allowed = name == "def" ? _DEF_OPTIONS : _VAL_OPTIONS
    for k in keys(call.map)
        k in allowed ||
            throw(AirDefError("$name: unknown option $(air_string(Form(k)))"))
    end
    pattern = to_form(call.seq[2])
    n = length(call.seq)
    doc = nothing
    body_start = 3
    if n >= body_start
        b = to_form(call.seq[body_start])
        if b isa FormScalar && value(b) isa AbstractString
            doc = _dedent_doc(value(b))
            body_start += 1
        end
    end
    if haskey(call.map, _DEF_DOC_KEY)
        doc === nothing || throw(AirDefError(
            "$name: the docstring is given once, as a leading string or doc="))
        d = to_form(call.map[_DEF_DOC_KEY])
        (d isa FormScalar && value(d) isa AbstractString) ||
            throw(AirDefError("$name: doc= must be a string"))
        doc = _dedent_doc(value(d))
    end
    letraw = haskey(call.map, _LET_KEY) ? to_form(call.map[_LET_KEY]) : nothing
    catchraw = haskey(call.map, _CATCH_KEY) ? to_form(call.map[_CATCH_KEY]) : nothing
    tx = false
    if haskey(call.map, _TX_KEY)
        tv = to_form(call.map[_TX_KEY])
        (tv isa FormScalar && value(tv) isa Bool) ||
            throw(AirDefError("$name: tx= must be true or false"))
        tx = value(tv)::Bool
    end
    memo = if haskey(call.map, _MEMO_KEY)
        name == "def" || throw(AirDefError(
            "$name: memoize= is not supported (a val is evaluated once)"))
        _memo_parse(to_form(call.map[_MEMO_KEY]), name)
    else
        nothing
    end
    bodyforms = Form[to_form(v) for v in _sx(call.seq, body_start:n)]
    implicit = isempty(bodyforms)
    if implicit
        (letraw !== nothing || catchraw !== nothing || tx) && throw(AirDefError(
            "$name: let=, catch=, and tx=true need a body"))
        haskey(call.map, _MEMO_KEY) &&
            throw(AirDefError("$name: memoize= needs a body"))
    end
    has_clause = any(bodyforms) do f
        h = head_symbol(f)
        h !== nothing && h in _BLOCK_CLAUSE_HEADS
    end
    need_block = length(bodyforms) > 1 || letraw !== nothing ||
                 catchraw !== nothing || tx || has_clause
    body = if implicit
        naught
    elseif !need_block
        bodyforms[1]
    else
        seq = FormValue[Form(Symbol(tx ? "tx" : "do"))]
        for f in bodyforms
            push!(seq, _store_form(f))
        end
        map = Pair{Symbol,FormValue}[]
        letraw === nothing || push!(map, _LET_KEY => _store_form(letraw))
        catchraw === nothing || push!(map, _CATCH_KEY => _store_form(catchraw))
        FormContainer(FormSeq(seq), FormMap(map))
    end
    return (pattern = pattern, body = body, implicit = implicit, doc = doc,
            held = _held_names(call), tx = tx, memo = memo)
end

# `(def pattern body…)` — register a reduction rule. At the top level the rule is
# global; inside a `namespace` block it is appended to that namespace. The
# pattern must satisfy the anchor rule. The body is kept raw; multiple body forms
# are wrapped as `(do …)`. With no body at all the rule is *implicit*: its
# replacement is the matched form itself, rebuilt at application time with its
# held parameters frozen (see `_implicit_form`). Returns `naught`.
function _bi_def(env::Env, scope::Scope, call::FormContainer)
    d = _parse_def_call(call, "def")
    check_anchor(d.pattern)
    ns = _write_ns(env)
    if ns === nothing
        memo = d.memo === nothing ? nothing : _memo_table(d.memo)
        add_rule!(env.rules, d.pattern, d.body; held = d.held, doc = d.doc,
                  implicit = d.implicit, memo = memo)
    else
        _ns_add_def!(env, ns, d.pattern, d.body; held = d.held,
                     doc = d.doc, implicit = d.implicit, memo = d.memo,
                     src = _form_source_info(call))
    end
    return naught
end
special!(:def, _bi_def)

# `(val pattern form…)` — like `def`, but evaluates the form at definition time
# and installs the resulting value as a thread-local constant. The value lives in
# an Air `Var{Form}`, so `bind` can shadow it for a dynamic extent (see
# `_bi_bind`); a reference to the name dereferences the binding, so every use
# sees the current value. The pattern must contain a raw-symbol anchor, just as
# with `def`; with several body forms they are evaluated in sequence, as by `do`.
function _bi_val(env::Env, scope::Scope, call::FormContainer)
    d = _parse_def_call(call, "val")
    check_anchor(d.pattern)
    d.implicit &&
        throw(AirDefError("val needs a value form"))
    value = canonicalize(air_reduce(env, scope, d.body))
    ns = _write_ns(env)
    if ns === nothing
        name = _def_name(d.pattern)
        body = if name === nothing
            value
        else
            _val_binding!(env, Symbol[], name, value)
            _ns_val_marker(Symbol[], name)
        end
        add_rule!(env.rules, d.pattern, body; held = d.held, doc = d.doc)
    else
        _ns_add_val!(env, ns, d.pattern, value; doc = d.doc,
                     src = _form_source_info(call))
    end
    return naught
end
special!(:val, _bi_val)

# ---- docstrings --------------------------------------------------------------

# The terminal text for documented rules: each pattern followed by its indented
# docstring, entries separated by a blank line.
function _doc_text(entries)
    chunks = String[]
    for (pattern, doc) in entries
        lines = [isempty(l) ? "" : "  " * l for l in split(doc, '\n')]
        push!(chunks, air_string(pattern) * "\n" * join(lines, '\n'))
    end
    return join(chunks, "\n\n")
end

# The rules selected by a `doc`/`definitions` argument: a raw symbol selects the
# rules whose pattern uses it; any other form is held and matched against the
# patterns (conditions evaluated as in a normal match). The active namespace
# layers are searched before the global store, so a `doc` inside a namespace
# block (or under `using`) documents that context's definitions.
function _doc_rules(env::Env, scope::Scope, arg::Form)
    out = Rule[]
    stores = RuleLayer[]
    _scope_has_layers(scope) && append!(stores, scope_layers(scope))
    # A namespace store is compiled newest-first (later definitions match
    # first), so walk it backwards to report definition order, and drop an
    # earlier definition of a pattern the namespace has since redefined. The
    # global store is already in definition order, with redefinitions replaced
    # in place.
    for store in stores
        _collect_doc_rules!(out, env, scope, store, arg, true)
    end
    _collect_doc_rules!(out, env, scope, env.rules, arg, false)
    return out
end

function _collect_doc_rules!(out::Vector{Rule}, env::Env, scope::Scope,
                             store::RuleLayer, arg::Form, newest_first::Bool)
    idxs = is_raw_symbol(arg) ? get(store.by_symbol, value(arg), Int[]) :
           candidate_rule_indices(store, arg)
    found = Rule[]
    seen = Form[]
    for i in idxs
        r = store.rules[i]
        # A definition the user may not read behaves like an absent one.
        (r.entry !== nothing && !_can(env, r.entry, :read)) && continue
        # A namespace store is newest-first, so the first occurrence of a
        # pattern is the definition that wins; an earlier one is stale.
        any(p -> isequal(p, r.pattern), seen) && continue
        if !is_raw_symbol(arg)
            air_match(env, scope, r.pattern, arg, Dict{Symbol,Form}()) === nothing &&
                continue
        end
        push!(seen, r.pattern)
        push!(found, r)
    end
    newest_first && reverse!(found)
    append!(out, found)
    return out
end

# `(doc symbol)` lists every documented rule whose pattern uses `symbol`;
# `(doc (form…))` holds its argument and lists every documented rule whose
# pattern matches that form.
function _bi_doc(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 ||
        throw(AirEvalError("doc expects a symbol or a single form"))
    arg = to_form(call.seq[2])
    entries = [(r.pattern, r.doc) for r in _doc_rules(env, scope, arg)
               if r.doc !== nothing]
    isempty(entries) && return Form("no documentation found for " * air_string(arg))
    return Form(_doc_text(entries))
end
special!(:doc, _bi_doc)

# The `hold=` option of a rule, rebuilt from its held-parameter set.
_hold_option(held::Set{Symbol}) = if length(held) == 1
    Form(first(held))
else
    Form(PVector{Any}([Form(s) for s in sort!(collect(held); by = string)]),
         PDict{Symbol,Any}())
end

# A quoted `def` form for `r`, with its docstring moved into a `doc=` map entry
# and its `hold=` option (if any) restored. The body is kept as stored: one
# element, `(do …)`-wrapped when the original `def` had several body forms. A
# rule written with no body has a synthesized body, which is omitted.
function _definition_form(r::Rule)
    seq = FormValue[_store_form(Form(Symbol("def"))), _store_form(r.pattern)]
    (r.implicit || isequal(r.body, naught)) || push!(seq, _store_form(r.body))
    map = Pair{Symbol,FormValue}[]
    isempty(r.held) || push!(map, HOLD_KEY => _store_form(_hold_option(r.held)))
    r.doc === nothing || push!(map, _DOC_KEY => _store_form(Form(r.doc)))
    r.memo === nothing ||
        push!(map, _MEMO_KEY => _store_form(_memo_option_form(_memo_config(r.memo))))
    return _holdify(FormContainer(FormSeq(seq), FormMap(map)))
end

# `(definitions arg)` — the matching `def` forms as quoted data, with each
# docstring in a `doc=` entry rather than at the head of the body.
function _bi_definitions(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 ||
        throw(AirEvalError("definitions expects a symbol or a single form"))
    arg = to_form(call.seq[2])
    seq = FormValue[_store_form(_definition_form(r)) for r in _doc_rules(env, scope, arg)]
    return FormContainer(FormSeq(seq), FormMap())
end
special!(Symbol("definitions"), _bi_definitions)

# `(match? pattern subject)` — whether the pattern matches the reduced subject.
function _bi_matchq(env::Env, scope::Scope, call::FormContainer)
    pattern = to_form(call.seq[2])
    subject = air_reduce(env, scope, to_form(call.seq[3]))
    return Form(air_match(env, scope, pattern, subject, Dict{Symbol,Form}()) !== nothing)
end
special!(Symbol("match?"), _bi_matchq)

# `(matches pattern subject)` — the bindings of the match as a mapping, or naught.
function _bi_matches(env::Env, scope::Scope, call::FormContainer)
    pattern = to_form(call.seq[2])
    subject = air_reduce(env, scope, to_form(call.seq[3]))
    binds = air_match(env, scope, pattern, subject, Dict{Symbol,Form}())
    binds === nothing && return naught
    # Canonicalize each binding, so a rest like `(2)` is never observably distinct
    # from `2` (every form the interpreter exposes is kept canonical).
    pairs = Pair{Symbol,Any}[Symbol(":" * String(k)) => canonicalize(v) for (k, v) in binds]
    return canonicalize(Form(PVector{Any}(), PDict{Symbol,Any}(pairs...)))
end
special!(:matches, _bi_matches)

# ---- the replace family ------------------------------------------------------

# A replacement rule is the inert form `(condition -> replacement)`, with an
# optional `unhold=` map entry. This is the only meaning of `->`; the RETE engine
# has its own structured `(rule …)` form.
const _UNHOLD = Symbol(":unhold")

# Split a rule-level guard out of a condition form. Two spellings are accepted:
#
#     (?x \ pred)      ; one pattern element before the `\` (the old rule shape)
#     (p ?x :guard g)  ; a `:guard` pair, with a wrapped single pattern unwrapped
#
# A `\` that follows a multi-element pattern is left for the pattern matcher,
# where it guards the preceding item as usual.
function _split_rule_guard(cond::Form)
    cond isa FormContainer || return cond, nothing
    seq = _sx(cond.seq, 1:length(cond.seq))
    bi = findfirst(v -> _symbolof(to_form(v)) === COND_MARK, seq)
    # A `\` at sequence position 2 guards the first element. In the whole-pattern
    # shape `(p \ cond)` it is a rule-level guard; in a longer pattern like
    # `(? \ symbol? 1)` it belongs to the pattern matcher, where it attaches to
    # the element before it.
    if bi == 2 && length(seq) == 3 && isempty(cond.map)
        pattern = to_form(seq[1])
        return pattern, _normalize_condition(pattern, to_form(seq[3]))
    end
    gi = findfirst(v -> _symbolof(to_form(v)) === Symbol(":guard"), seq)
    gi === nothing && return cond, nothing
    gi < length(seq) || throw(AirEvalError("':guard' needs a condition"))
    guard = to_form(seq[gi + 1])
    rest = FormValue[seq[1:(gi - 1)]...; seq[(gi + 2):end]...]
    # A wrapped single pattern, `((p ?x) :guard g)`, unwraps; otherwise the
    # remaining elements are the pattern itself.
    pattern = if isempty(cond.map) && length(rest) == 1
        to_form(rest[1])
    else
        FormContainer(FormSeq(rest), FormMap([k => v for (k, v) in cond.map]))
    end
    return pattern, _normalize_condition(pattern, guard)
end

# Returns `(pattern, guard-or-nothing, replacement, unhold, held)` from a
# replacement rule form. `held` is the form's `hold=` option, which matters when
# the rule is used as a function (see `_apply_rule_form`); `replace` ignores it.
function _parse_replace_rule(rule::Form)
    r = _strip_hold(rule)
    r isa FormContainer || throw(AirEvalError("a replace rule must be a form"))
    _is_replacement_rule(r) || throw(AirEvalError(
        "a replace rule must be written (pattern -> replacement)"))
    for k in keys(r.map)
        (k === _UNHOLD || k === Symbol(":hold")) || throw(AirEvalError(
            "a replacement rule accepts only the unhold= and hold= options"))
    end
    pattern, guard = _split_rule_guard(to_form(r.seq[1]))
    replacement = to_form(r.seq[3])
    unhold = false
    if haskey(r.map, _UNHOLD)
        l = _leafof(to_form(r.map[_UNHOLD]))
        l isa Bool ||
            throw(AirEvalError("the unhold= option must be true or false"))
        unhold = l
    end
    return pattern, guard, replacement, unhold, _held_names(r)
end

# Match one replacement rule against `subject`; on success return
# `(binds, replacement, unhold)` with `_` bound to the whole subject (so a
# replacement can write `(row=_)`), or `nothing`. A guard is evaluated with the
# match's bindings and must be exactly `true`.
function _match_replacement(env::Env, scope::Scope, rule::Form, subject::Form)
    pattern, guard, replacement, unhold, _ = _parse_replace_rule(rule)
    binds = air_match(env, scope, pattern, subject, Dict{Symbol,Form}())
    binds === nothing && return nothing
    # `_` is the whole subject, available to a guard (an alternative pattern's
    # bare-symbol guard is applied to it) as well as to the replacement.
    haskey(binds, PLACEHOLDER) || (binds[PLACEHOLDER] = subject)
    if guard !== nothing
        bscope = scope_extend(scope, [n => v for (n, v) in binds])
        _cond_true(air_reduce(env, bscope, guard)) || return nothing
    end
    return binds, replacement, unhold
end

# Try the rules in order against `subject`; the first match's replacement wins.
# The replacement is inserted exactly as written; reduction happens once, on the
# finished form (see the `replace` builtins below). With `unhold=true` a held
# replacement is inserted without its hold.
function _replace_first(env::Env, scope::Scope, subject::Form, rules)
    for r in rules
        m = _match_replacement(env, scope, r, subject)
        m === nothing && continue
        binds, replacement, unhold = m
        out = _substitute(replacement, binds)
        return unhold ? _strip_hold(out) : out
    end
    return subject
end

# `(replace subject rule… depth=n)` — the first matching rule replaces every node
# at depth `n` (default `0`, the subject itself; see `_map_at_depth`), with the
# structure around the replaced nodes rebuilt.
function _bi_replace(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("replace needs a subject"))
    _check_options(call, "replace", (DEPTH_KEY,))
    depth = _depth_opt(env, scope, call, "replace", 0)
    args = _call_args(env, scope, call)
    return _map_at_depth(x -> _replace_first(env, scope, x, args[2:end]),
                         args[1], depth)
end
special!(:replace, _bi_replace)

# Walk post-order (deepest first), applying the rules at every node.
function _replace_all_walk(env::Env, scope::Scope, x::Form, rules)
    if x isa FormContainer
        seq = FormValue[]
        for a in x.seq
            push!(seq, _store_form(_replace_all_walk(env, scope, to_form(a), rules)))
        end
        map = Pair{Symbol,FormValue}[]
        for (k, v) in x.map
            push!(map, k => _store_form(_replace_all_walk(env, scope, to_form(v), rules)))
        end
        rebuilt = FormContainer(FormSeq(seq), FormMap(map))
        return _replace_first(env, scope, rebuilt, rules)
    elseif x isa VolatileForm
        return x
    else
        return _replace_first(env, scope, x, rules)
    end
end

# `(replace-all subject rule… depth=n)` — with no `depth`, replace every matching
# subpart at every level, deepest first. With `depth=n`, replace only at exactly
# that level (so `depth=0` is `replace`).
function _bi_replace_all(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("replace-all needs a subject"))
    _check_options(call, "replace-all", (DEPTH_KEY,))
    has_depth = haskey(call.map, DEPTH_KEY)
    depth = has_depth ? _depth_opt(env, scope, call, "replace-all", 0) : 0
    args = _call_args(env, scope, call)
    has_depth ||
        return _replace_all_walk(env, scope, args[1], args[2:end])
    return _map_at_depth(x -> _replace_first(env, scope, x, args[2:end]),
                         args[1], depth)
end
special!(Symbol("replace-all"), _bi_replace_all)

# Repeat a replacement step until it reaches a fixed point.
function _replace_fixed_point(env::Env, subject::Form, step)
    cur = subject
    for _ in 1:env.max_steps
        nxt = step(cur)
        _same_value(nxt, cur) && return cur
        cur = nxt
    end
    throw(AirEvalError("repeated replacement did not reach a fixed point"))
end

# `(rreplace subject rule… depth=n)` — repeat the `replace` step; the default
# depth is `0`, the whole subject.
function _bi_rreplace(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("rreplace needs a subject"))
    _check_options(call, "rreplace", (DEPTH_KEY,))
    depth = _depth_opt(env, scope, call, "rreplace", 0)
    args = _call_args(env, scope, call)
    rules = args[2:end]
    return _replace_fixed_point(env, args[1],
        cur -> _map_at_depth(x -> _replace_first(env, scope, x, rules), cur, depth))
end
special!(:rreplace, _bi_rreplace)

# `(rreplace-all subject rule… depth=n)` — repeat the `replace-all` step; with no
# `depth` that is the whole tree, and with `depth=n` only level `n`.
function _bi_rreplace_all(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("rreplace-all needs a subject"))
    _check_options(call, "rreplace-all", (DEPTH_KEY,))
    has_depth = haskey(call.map, DEPTH_KEY)
    depth = has_depth ? _depth_opt(env, scope, call, "rreplace-all", 0) : 0
    args = _call_args(env, scope, call)
    rules = args[2:end]
    step = if has_depth
        cur -> _map_at_depth(x -> _replace_first(env, scope, x, rules), cur, depth)
    else
        cur -> _replace_all_walk(env, scope, cur, rules)
    end
    return _replace_fixed_point(env, args[1], step)
end
special!(Symbol("rreplace-all"), _bi_rreplace_all)

# Replace `?x` (or a bare symbol `x`) with its bound value throughout `template`.
function _substitute(x::Form, binds::Dict{Symbol,Form})
    return _subst(x, binds, Set{Symbol}())
end

# Substitute rule/fn parameters into a body: a raw occurrence `x` becomes its
# bound value, and a held occurrence `'x` becomes the *held* value `(' …)`. This is
# what makes a held parameter "inserted exactly as matched": the raw match is in
# the body before any downstream rule matches it. Binding positions stay put: a
# nested `loop`/`for` keeps its names (but its value expressions are in the
# enclosing scope, so they are substituted), a `let` keeps its map keys, and an
# `fn` keeps its parameter list; a nested binder shadows the parameter in its
# body.
function _subst_params(x::Form, binds::Dict{Symbol,Form})
    return _subst_params(x, binds, Set{Symbol}())
end

# A computed map key is stored as the symbol `:~<printed expr>` (see
# `_key_symbol`); substitute into its expression and re-encode it, so that
# `(let (a=:y) (' f ~a=1))` becomes `(' f y=1)` rather than leaving an unbound `a`.
function _subst_key(k::Symbol, substf)
    s = String(k)
    startswith(s, ":~") || return k
    expr = try
        read_air(s[3:end])
    catch
        return k
    end
    return Symbol(":~" * air_string(substf(expr)))
end

function _subst_params(x::Form, binds, bound::Set{Symbol})
    if x isa FormScalar
        s = value(x)
        if s isa Symbol && is_raw_symbol(s) && !(s in bound) && haskey(binds, s)
            return binds[s]
        end
        return x
    elseif !(x isa FormContainer)
        return x
    end
    x = _expand_block_markers(x)
    _is_block_form(x) &&
        return _subst_block(x, binds, bound, _subst_params, _subst_let_bindings)
    h = head_symbol(x)
    sc = _scope_form(x)
    # `let`: element 2 is the binding form — its keys are names, and each group's
    # value expressions are substituted under the names bound before it (see
    # `_subst_let_bindings`); the sequence tail is the body. The form's own map
    # holds options (`hold=`), not bindings.
    if h === Symbol("let")
        inner = sc === nothing ? bound : union(bound, sc.binders)
        bf = length(x.seq) >= 2 ? to_form(x.seq[2]) : naught
        seq = FormValue[]
        for (i, a) in enumerate(x.seq)
            if i == 1
                push!(seq, a)
            elseif i == 2
                push!(seq, _store_form(_subst_let_bindings(bf, binds, bound)))
            else
                push!(seq, _store_form(_subst_params(to_form(a), binds, inner)))
            end
        end
        map = Pair{Symbol,FormValue}[k => v for (k, v) in x.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    # `loop`/`for`: element 2 is the binding form — names stay, value expressions
    # are substituted — and the rest is the body.
    elseif (h === Symbol("loop") || h === Symbol("for")) && length(x.seq) >= 2
        bf = to_form(x.seq[2])
        inner = sc === nothing ? bound : union(bound, sc.binders)
        seq = FormValue[]
        for (i, a) in enumerate(x.seq)
            if i == 2
                b = bf isa FormContainer ?
                    (h === Symbol("loop") ? _subst_loop_bindings(bf, binds, bound) :
                                            _subst_for_bindings(bf, binds, bound)) : bf
                push!(seq, _store_form(b))
            elseif i == 1
                push!(seq, a)
            else
                push!(seq, _store_form(_subst_params(to_form(a), binds, inner)))
            end
        end
        map = Pair{Symbol,FormValue}[k => v for (k, v) in x.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    # A replacement rule is data: its pattern and arrow are left alone, while
    # the replacement and any `unhold=`/`hold=` values are substituted. The
    # pattern's own parameters shadow an outer binding in the replacement, just
    # as a lambda's parameters do.
    elseif _is_replacement_rule(x)
        inner = union(bound, Set(params_of(to_form(x.seq[1]))))
        seq = FormValue[x.seq[1], x.seq[2],
                        _store_form(_subst_params(to_form(x.seq[3]), binds, inner))]
        map = Pair{Symbol,FormValue}[
            k => _store_form(_subst_params(to_form(v), binds, inner))
            for (k, v) in x.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    end
    # Any other form: substitute throughout, respecting an enclosing binder set.
    seq = FormValue[]
    for a in x.seq
        push!(seq, _store_form(_subst_params(to_form(a), binds, bound)))
    end
    map = Pair{Symbol,FormValue}[]
    for (k, v) in x.map
        push!(map, _subst_key(k, e -> _subst_params(e, binds, bound)) =>
                    _store_form(_subst_params(to_form(v), binds, bound)))
    end
    return FormContainer(FormSeq(seq), FormMap(map))
end

# A `let` binding form under an outer rule/fn substitution. The groups are
# sequential, so group k's value expressions are substituted under the names bound
# by groups 1…k-1 (those shadow an outer name of the same spelling); the bindings
# within a group are parallel and see only `bound`. Binding keys are names, kept
# as written.
function _subst_let_bindings(bf::Form, binds, bound, substf = _subst_params)
    bf isa FormContainer || return bf
    if isempty(bf.seq)
        return _subst_let_group(bf, binds, bound, substf)
    end
    seq = FormValue[]
    bnd = bound
    for a in bf.seq
        g = to_form(a)
        if !(g isa FormContainer) || !isempty(g.seq)
            push!(seq, _store_form(g))      # not a group: leave it alone
            continue
        end
        push!(seq, _store_form(_subst_let_group(g, binds, bnd, substf)))
        bnd = union(bnd, Symbol[_bindname(k) for (k, _) in g.map])
    end
    map = Pair{Symbol,FormValue}[k => v for (k, v) in bf.map]
    return FormContainer(FormSeq(seq), FormMap(map))
end

function _subst_let_group(g::FormContainer, binds, bound, substf)
    map = Pair{Symbol,FormValue}[
        k => _store_form(substf(to_form(v), binds, bound))
        for (k, v) in g.map]
    return FormContainer(g.seq, FormMap(map))
end

# `loop (n n acc 1) …`: names at 1, 3, … and value expressions at 2, 4, ….
function _subst_loop_bindings(bf::FormContainer, binds, bound)
    seq = FormValue[]
    for (i, a) in enumerate(bf.seq)
        f = to_form(a)
        push!(seq, _store_form(isodd(i) ? f : _subst_params(f, binds, bound)))
    end
    map = Pair{Symbol,FormValue}[k => v for (k, v) in bf.map]
    return FormContainer(FormSeq(seq), FormMap(map))
end

# `for (n (range n) :if cond :let k v …)`: names stays, values/conditions are
# substituted.
function _subst_for_bindings(bf::FormContainer, binds, bound)
    elems = Form[to_form(a) for a in bf.seq]
    seq = FormValue[]
    i = 1
    while i <= length(elems)
        e = elems[i]
        s = _symbolof(e)
        if s === Symbol(":if")
            push!(seq, _store_form(e))
            i += 1
            i <= length(elems) &&
                (push!(seq, _store_form(_subst_params(elems[i], binds, bound))); i += 1)
        elseif s === Symbol(":let")
            push!(seq, _store_form(e))
            i += 1
            i <= length(elems) && (push!(seq, _store_form(elems[i])); i += 1)
            i <= length(elems) &&
                (push!(seq, _store_form(_subst_params(elems[i], binds, bound))); i += 1)
        else
            push!(seq, _store_form(e))          # the bound name
            i += 1
            i <= length(elems) &&
                (push!(seq, _store_form(_subst_params(elems[i], binds, bound))); i += 1)
        end
    end
    map = Pair{Symbol,FormValue}[k => v for (k, v) in bf.map]
    return FormContainer(FormSeq(seq), FormMap(map))
end

# A `do`/`tx` block under parameter substitution. The `let=` names are bound in
# the body and clause bodies; a clause pattern is data. A clause body additionally
# sees the pattern's own wildcards shadowing an outer parameter of the same name.
# The block options are still substituted (`let=` group-aware).
function _subst_block(x::FormContainer, binds, bound::Set{Symbol}, substf,
                      letf)
    letbinders = _block_let_binders(x)
    inner = isempty(letbinders) ? bound : union(bound, letbinders)
    start = _block_clause_start(x)
    bodyend = start == 0 ? length(x.seq) : start - 1
    seq = FormValue[x.seq[1]]
    for i in 2:bodyend
        push!(seq, _store_form(substf(to_form(x.seq[i]), binds, inner)))
    end
    if start != 0
        for i in start:length(x.seq)
            push!(seq, _store_form(
                _subst_block_clause(to_form(x.seq[i]), binds, inner, substf)))
        end
    end
    map = Pair{Symbol,FormValue}[]
    for (k, v) in x.map
        val = if k === Symbol(":let")
            letf(to_form(v), binds, bound, substf)
        else
            substf(to_form(v), binds, inner)
        end
        push!(map, k => _store_form(val))
    end
    return FormContainer(FormSeq(seq), FormMap(map))
end

function _subst_block_clause(f::Form, binds, bound::Set{Symbol}, substf)
    f isa FormContainer || return f
    h = head_symbol(f)
    if h === Symbol("except") || h === Symbol("handle")
        length(f.seq) >= 2 || return f
        pat = to_form(f.seq[2])
        cbound = union(bound, Set(params_of(pat)))
        seq = FormValue[f.seq[1], f.seq[2]]
        for i in 3:length(f.seq)
            push!(seq, _store_form(substf(to_form(f.seq[i]), binds, cbound)))
        end
        map = Pair{Symbol,FormValue}[k => v for (k, v) in f.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    elseif h === Symbol("finally")
        seq = FormValue[f.seq[1]]
        for i in 2:length(f.seq)
            push!(seq, _store_form(substf(to_form(f.seq[i]), binds, bound)))
        end
        map = Pair{Symbol,FormValue}[k => v for (k, v) in f.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    end
    return f
end

# Substitution that respects inner binders via `_scope_form`: a name rebound by
# `let`/`loop`/`for`/`fn` is shadowed (not substituted), and the binder's own
# binding form is left untouched. This is what keeps `(def (fact ?n) (loop (n n
# acc 1) …))` working when `?n` is inlined.
function _subst(x::Form, binds, bound::Set{Symbol})
    if x isa FormScalar
        s = value(x)
        if s isa Symbol
            if is_wildcard(s) && s != Symbol("?")
                name = Symbol(String(s)[2:end])
                (!(name in bound) && haskey(binds, name)) && return binds[name]
            elseif is_raw_symbol(s) && !(s in bound) && haskey(binds, s)
                return binds[s]
            end
        end
        return x
    elseif x isa FormContainer
        x = _expand_block_markers(x)
        _is_block_form(x) &&
            return _subst_block(x, binds, bound, _subst, _subst_let_bindings)
        sc = _scope_form(x)
        inner = sc === nothing ? bound : union(bound, sc.binders)
        # A `let`'s second element is the binding form (one mapping or a sequence
        # of them); the binder's own names are left as written and its value
        # expressions are substituted group by group. The form's own map holds
        # options (`hold=`), not bindings.
        if head_symbol(x) === Symbol("let") && length(x.seq) >= 2
            bf = to_form(x.seq[2])
            seq = FormValue[]
            for (i, a) in enumerate(x.seq)
                if i == 1
                    push!(seq, a)
                elseif i == 2
                    push!(seq, _store_form(_subst_let_bindings(bf, binds, bound, _subst)))
                else
                    push!(seq, _store_form(_subst(to_form(a), binds, inner)))
                end
            end
            map = Pair{Symbol,FormValue}[k => v for (k, v) in x.map]
            return FormContainer(FormSeq(seq), FormMap(map))
        end
        # A replacement rule is data: substitute into its replacement only, with
        # the pattern's parameters shadowing an outer binding.
        if _is_replacement_rule(x)
            inner = union(bound, Set(params_of(to_form(x.seq[1]))))
            seq = FormValue[x.seq[1], x.seq[2],
                            _store_form(_subst(to_form(x.seq[3]), binds, inner))]
            map = Pair{Symbol,FormValue}[
                k => _store_form(_subst(to_form(v), binds, inner)) for (k, v) in x.map]
            return FormContainer(FormSeq(seq), FormMap(map))
        end
        skip = sc === nothing ? 0 : sc.skip
        seq = FormValue[]
        for (i, a) in enumerate(x.seq)
            i == skip ? push!(seq, a) :
                push!(seq, _store_form(_subst(to_form(a), binds, inner)))
        end
        map = Pair{Symbol,FormValue}[]
        for (k, v) in x.map
            push!(map, _subst_key(k, e -> _subst(e, binds, inner)) =>
                        _store_form(_subst(to_form(v), binds, inner)))
        end
        return FormContainer(FormSeq(seq), FormMap(map))
    else
        return x
    end
end
