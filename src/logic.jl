################################################################################
# logic.jl
#
# The outer system: `logic-set` objects and forward-chaining production rules.
#
# A logic-set is a named `VolatileForm` in the database (AirDB `named_form`), so
# it persists and participates in transactions. Its value is a container:
#
#     (base=(…) rules=(…) active=(…) why=(…) facts=(…) reasons=(…) ids=(…))
#
# `reasons` holds the base reason records (one per assertion), `ids` maps each
# present fact to a stable identity token, `active` records one entry per
# currently firing activation (with the fact each `:>` slot currently derives),
# `why` records the derived provenance of each slot output, `base`/`facts` are
# user-facing summaries, and `rules` holds the rule forms.
#
# A rule is the structured form
#
#     (rule conditions… instructions…)
#
# with an implicit conjunction of conditions, and the instructions `:if`,
# `:let`, `:>`, `:+`, `:-`, and `:=`. Each `:>` has a fixed slot: the previous
# and the new output of that slot classify the event (naught→fact is an
# assertion, fact→naught a retraction, two different facts a revision, equal
# facts no event). The event type of the *condition* — a new match, a vanished
# match, or a persistent match whose premise changed — decides which of `:+`,
# `:-`, and `:=` run.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _RULE_HEAD = RULE

# The instruction keywords of the rule DSL. Each takes exactly one argument.
const _INS_IF        = Symbol(":if")
const _INS_LET       = Symbol(":let")
const _INS_CONSEQ    = Symbol(":>")
const _INS_ON_ASSERT = Symbol(":+")
const _INS_ON_RETRACT = Symbol(":-")
const _INS_ON_REVISE = Symbol(":=")
const _INSTRUCTIONS = (_INS_IF, _INS_LET, _INS_CONSEQ, _INS_ON_ASSERT,
                       _INS_ON_RETRACT, _INS_ON_REVISE)

const _NOT   = Symbol("not")
const _AND   = Symbol("and")
const _ACCUM = Symbol(":accum")
const _TAKE  = Symbol(":take")
const _AGGS  = (:min, :max, :sum, :mean, :median, :first, :last)

const _REASON_KEY = Symbol(":reason")

const _SET_BASE    = Symbol(":base")
const _SET_RULES   = Symbol(":rules")
const _SET_ACTIVE  = Symbol(":active")
const _SET_WHY     = Symbol(":why")
const _SET_FACTS   = Symbol(":facts")
const _SET_REASONS = Symbol(":reasons")
const _SET_IDS     = Symbol(":ids")
const _SET_KEYS    = (_SET_BASE, _SET_RULES, _SET_ACTIVE, _SET_WHY, _SET_FACTS,
                      _SET_REASONS, _SET_IDS)

# The most rounds one saturation may take; a rule that keeps rewriting its own
# inputs (a counter without a guard, say) is stopped rather than run forever.
const _MAX_ROUNDS = 1_000

# ---- the set value -----------------------------------------------------------

# A logic-set's initial (empty) value.
function _empty_logic_set()
    mp = Pair{Symbol,Any}[k => _store_form(FormContainer(FormSeq(FormValue[]), FormMap()))
                          for k in _SET_KEYS]
    return Form(PVector{Any}(Any[]), PDict{Symbol,Any}(mp...))
end

# The sequence stored under `k` in a set value. It is never canonicalized, so a
# one-fact set stays a container.
function _set_seq(s::Form, k::Symbol)
    s isa FormContainer || return FormValue[]
    haskey(s.map, k) || return FormValue[]
    v = to_form(s.map[k])
    v isa FormContainer ? FormValue[v.seq...] : FormValue[]
end

# A copy of the set value with the sequence under `k` replaced.
function _set_put(s::Form, k::Symbol, vals::Vector{FormValue})
    mp = Pair{Symbol,Any}[]
    found = false
    for (kk, v) in (s isa FormContainer ? s.map : FormMap())
        if kk === k
            push!(mp, kk => _store_form(FormContainer(FormSeq(vals), FormMap())))
            found = true
        else
            push!(mp, kk => _store_form(to_form(v)))
        end
    end
    found || push!(mp, k => _store_form(FormContainer(FormSeq(vals), FormMap())))
    return Form(PVector{Any}(Any[]), PDict{Symbol,Any}(mp...))
end

_set_forms(s::Form, k::Symbol) = Form[to_form(v) for v in _set_seq(s, k)]

# `_set_put` for a plain record form (the set value helpers assume a set).
function _set_put_plain(f::Form, k::Symbol, v)
    f isa FormContainer || return f
    mp = Pair{Symbol,Any}[kk => (kk === k ? _store_form(v) : x) for (kk, x) in f.map]
    return Form(PVector{Any}(Any[]), PDict{Symbol,Any}(mp...))
end

_record_seq(vals) = FormContainer(FormSeq(FormValue[_store_form(v) for v in vals]),
                                  FormMap())

# ---- facts -------------------------------------------------------------------

# The held form asserted for `x`: a fact is stored held, and an explicit quote
# around it (`(assert s (' p 1))`) names the same fact.
_factify(x::Form) = _holdify(canonicalize(_strip_hold(x)))

# Whether `form` is a rule: a held or unheld `(rule …)` form.
function _is_logic_rule(form::Form)
    f = _strip_hold(form)
    return f isa FormContainer && head_symbol(f) === _RULE_HEAD
end

# The variable a spec or binding key names: `class`, `?class`, or `:class` → `class`.
_varname(s::Symbol) = Symbol(lstrip(String(s), ['?', ':']))

# ---- rule parsing ------------------------------------------------------------

# One accumulated variable: its name and an optional aggregator.
mutable struct _AccumVar
    name::Symbol
    agg::Union{Nothing,Symbol}
end

# A `:take` row selection: `:first`, `:last`, or a min/max of one variable.
struct _Take
    kind::Symbol                 # :first, :last, :min, :max
    var::Union{Nothing,Symbol}
end

# One `:accum` level. The listed variables are accumulated (or partition the
# next level); every bound variable not listed anywhere is a group key.
struct _AccumSpec
    vars::Vector{_AccumVar}
    take::Union{Nothing,_Take}
end

# A parsed rule. `form` is the held rule value itself, kept as the activation
# key and for provenance.
struct _LogicRule
    form::Form
    pos::Vector{Form}                      # positive condition patterns
    neg::Vector{Form}                      # negated condition patterns
    accums::Vector{_AccumSpec}             # `:accum` levels, outermost first
    program::Vector{Tuple{Symbol,Form}}    # instructions, in order
    nslots::Int                            # number of `:>` consequences
    rests::Set{Symbol}                     # rest-capture names
end

# A symbol-bearing form, or `nothing`.
_symhead(x::Form) = _symbolof(x)

# Split a rule's condition region into positive patterns and negations. `and` is
# the conjunction (prefix, or infix folded left); `(not p)` negates. The old
# `:guard`/`:over` options are rejected with a pointer to their replacements.
function _flatten_cond!(cond::Form, pos::Vector{Form}, neg::Vector{Form})
    if cond isa FormContainer
        h = head_symbol(cond)
        if h === _NOT && length(cond.seq) == 2 && isempty(cond.map)
            push!(neg, to_form(cond.seq[2]))
            return nothing
        end
        if h === _AND && isempty(cond.map)
            length(cond.seq) >= 2 ||
                throw(AirEvalError("'and' needs at least one condition"))
            for v in _sx(cond.seq, 2:length(cond.seq))
                _flatten_cond!(to_form(v), pos, neg)
            end
            return nothing
        end
        # An infix and-chain `(p and q …)`, folded left.
        seq = _sx(cond.seq, 1:length(cond.seq))
        if isempty(cond.map) && length(seq) >= 3 && isodd(length(seq)) &&
           _symbolof(to_form(seq[2])) === _AND &&
           all(_symbolof(to_form(seq[j])) === _AND for j in 2:2:length(seq))
            acc = to_form(seq[1])
            for j in 3:2:length(seq)
                acc = Form(PVector{Any}(Any[Form(_AND), _store_form(acc),
                                            _store_form(to_form(seq[j]))]),
                           PDict{Symbol,Any}())
            end
            _flatten_cond!(acc, pos, neg)
            return nothing
        end
        for v in cond.seq
            s = _symbolof(to_form(v))
            s === Symbol(":guard") && throw(AirEvalError(
                "the ':guard' option is gone; use an ':if' instruction"))
            s === Symbol(":over") && throw(AirEvalError(
                "the ':over' option is gone; use an ':accum' condition"))
        end
    end
    push!(pos, cond)
    return nothing
end

# Parse one `:accum` spec: listed variables accumulate; `v=:agg` aggregates one
# variable; `:take :first|:last` or `:take (min v)|(max v)` selects a row.
function _parse_accum(spec::Form)
    vars = _AccumVar[]
    take = nothing
    seen = Set{Symbol}()
    addvar! = (name, agg) -> begin
        name in seen && throw(AirEvalError(":accum lists $name twice"))
        push!(seen, name)
        push!(vars, _AccumVar(name, agg))
    end
    if spec isa FormContainer
        i = 1
        seq = _sx(spec.seq, 1:length(spec.seq))
        while i <= length(seq)
            e = to_form(seq[i])
            s = _symbolof(e)
            s === nothing && throw(AirEvalError(
                ":accum entries must be symbols, as in :accum (a b)"))
            if s === _TAKE
                i + 1 <= length(seq) || throw(AirEvalError(":take needs an argument"))
                take === nothing || throw(AirEvalError(":accum has more than one :take"))
                take = _parse_take(to_form(seq[i + 1]))
                i += 2
                continue
            end
            addvar!(_varname(s), nothing)
            i += 1
        end
        for (k, v) in spec.map
            name = _varname(k)
            agg = _leafof(to_form(v))
            agg isa Symbol || throw(AirEvalError(
                ":accum aggregation must be one of $(join(_AGGS, ", "))"))
            aggn = _varname(agg)
            (aggn in _AGGS) || throw(AirEvalError(
                ":accum aggregation must be one of $(join(_AGGS, ", "))"))
            addvar!(name, aggn)
        end
    else
        s = _symbolof(spec)
        s === nothing && throw(AirEvalError(
            ":accum entries must be symbols, as in :accum (a b)"))
        addvar!(_varname(s), nothing)
    end
    isempty(vars) && throw(AirEvalError(":accum needs at least one variable"))
    if take !== nothing
        any(v -> v.agg !== nothing, vars) &&
            throw(AirEvalError(":take and an aggregation cannot share an :accum"))
        take.kind in (:min, :max) && take.var === nothing &&
            throw(AirEvalError(":take (min v) needs a variable"))
    end
    return _AccumSpec(vars, take)
end

function _parse_take(arg::Form)
    s = _symbolof(arg)
    if s !== nothing && _varname(s) in (:first, :last)
        return _Take(_varname(s), nothing)
    end
    if arg isa FormContainer && length(arg.seq) == 2
        h = _symbolof(to_form(arg.seq[1]))
        hn = h === nothing ? nothing : _varname(h)
        if hn === :min || hn === :max
            v = to_form(arg.seq[2])
            n = _symbolof(v)
            n === nothing && throw(AirEvalError(":take ($(hn) v) needs a variable"))
            return _Take(hn, _varname(n))
        end
    end
    throw(AirEvalError(
        ":take takes :first, :last, (min v), or (max v)"))
end

# The rest-capture names in a pattern.
function _collect_rests!(x::Form, out::Set{Symbol})
    if x isa FormScalar
        s = value(x)
        if s isa Symbol && is_wildcard(s)
            rm = _rest_marker(s)
            (rm !== nothing && rm[2] !== nothing) && push!(out, rm[2])
        end
    elseif x isa FormContainer
        for a in x.seq; _collect_rests!(to_form(a), out); end
        for (_, v) in x.map; _collect_rests!(to_form(v), out); end
    end
    return out
end

# An `:accum` name refers to a condition's key: `:accum (class)` accumulates the
# wildcard bound to the `:class` key of a pattern. When no pattern has that key,
# the name is taken as a binding name directly.
function _resolve_group_var(pos::Vector{Form}, name::Symbol)
    for p in pos
        p isa FormContainer || continue
        for (k, v) in p.map
            _varname(k) === name || continue
            s = _symbolof(to_form(v))
            (s !== nothing && is_wildcard(s)) && return _varname(s)
        end
    end
    return name
end

# Parse a rule form into its conditions and instruction program.
function _parse_rule(rule0::Form)
    rule0 isa FormContainer || throw(AirEvalError("a rule must be a form"))
    held = _is_hold(rule0) ? rule0 : _holdify(rule0)
    rule = _strip_hold(held)
    rule isa FormContainer || throw(AirEvalError("a rule must be a form"))
    head_symbol(rule) === _RULE_HEAD ||
        throw(AirEvalError("a rule must be written (rule conditions… instructions…)"))
    isempty(rule.map) || throw(AirEvalError(
        "a rule takes no key=value entries; write its conditions and instructions in sequence"))
    # The condition region runs up to the first instruction keyword.
    n = length(rule.seq)
    first_ins = n + 1
    for i in 2:n
        s = _symbolof(to_form(rule.seq[i]))
        if s !== nothing && s in _INSTRUCTIONS
            first_ins = i
            break
        end
    end
    pos = Form[]; neg = Form[]; accums = _AccumSpec[]
    i = 2
    while i < first_ins
        e = to_form(rule.seq[i])
        if _symbolof(e) === _ACCUM
            push!(accums, _parse_accum(_accum_arg(rule, i, first_ins)))
            i += 2
            continue
        end
        _flatten_cond!(e, pos, neg)
        i += 1
    end
    (isempty(pos) && isempty(neg)) &&
        throw(AirEvalError("a rule needs a condition"))
    # Resolve the accumulated names against the condition's bindings.
    bound = Set{Symbol}()
    for p in pos; union!(bound, params_of(p)); end
    accum_names = Set{Symbol}()
    for (j, spec) in enumerate(accums)
        names = Set{Symbol}()
        for v in spec.vars
            v.name = _resolve_group_var(pos, v.name)
            (v.name in bound) || throw(AirEvalError(
                ":accum variable $(v.name) is not bound by the rule's condition"))
            push!(accum_names, v.name)
            push!(names, v.name)
        end
        # `:take (min v)` may name the variable either directly or by its key.
        if spec.take !== nothing && spec.take.var !== nothing
            tv = _resolve_group_var(pos, spec.take.var)
            (tv in names) || throw(AirEvalError(
                ":take names $(spec.take.var), which is not listed in its :accum"))
            accums[j] = _AccumSpec(spec.vars, _Take(spec.take.kind, tv))
        end
        if j < length(accums) && (!isempty(spec.vars) && any(v -> v.agg !== nothing, spec.vars))
            throw(AirEvalError("only the final :accum level may aggregate"))
        end
        (j < length(accums) && spec.take !== nothing) &&
            throw(AirEvalError("only the final :accum level may use :take"))
    end
    # Parse the instruction region: keyword/argument pairs.
    program = Tuple{Symbol,Form}[]
    while i <= n
        s = _symbolof(to_form(rule.seq[i]))
        (s !== nothing && s in _INSTRUCTIONS) || throw(AirEvalError(
            "unknown rule instruction $(air_string(to_form(rule.seq[i])))"))
        i + 1 <= n || throw(AirEvalError("rule instruction $s needs an argument"))
        push!(program, (s, to_form(rule.seq[i + 1])))
        i += 2
    end
    isempty(program) && throw(AirEvalError("a rule needs at least one instruction"))
    nslots = count(p -> p[1] === _INS_CONSEQ, program)
    rests = Set{Symbol}()
    for p in pos; _collect_rests!(p, rests); end
    return _LogicRule(held, pos, neg, accums, program, nslots, rests)
end

# The argument of an `:accum` at index `i`; the spec itself is the next element.
function _accum_arg(rule::FormContainer, i::Int, first_ins::Int)
    i + 1 < first_ins || throw(AirEvalError(":accum needs a variable list"))
    return to_form(rule.seq[i + 1])
end

# ---- matching ----------------------------------------------------------------

# Every (binding, held-premise) pair of the positive patterns that also
# satisfies the negations. Premises are kept in positive-pattern order. Facts
# are stored held, so matching looks through the hold.
function _join_all(env::Env, lr::_LogicRule, facts::Vector{Form})
    out = Tuple{Dict{Symbol,Form},Vector{Form}}[]
    _join_step!(env, lr, 1, Dict{Symbol,Form}(), Form[], facts, out)
    return out
end

function _join_step!(env::Env, lr, i::Int, binds, prems, facts, out)
    if i > length(lr.pos)
        for np in lr.neg, f in facts
            air_match(env, _base_scope(env), np, _strip_hold(f), copy(binds)) === nothing ||
                return nothing
        end
        push!(out, (binds, copy(prems)))
        return nothing
    end
    for f in facts
        # `air_match` mutates its binding dict, so each branch gets its own copy.
        b = air_match(env, _base_scope(env), lr.pos[i], _strip_hold(f), copy(binds))
        b === nothing && continue
        push!(prems, f)
        _join_step!(env, lr, i + 1, b, prems, facts, out)
        pop!(prems)
    end
    return nothing
end

# ---- grouping and accumulation -----------------------------------------------

# A vector (a container) of the given forms, canonical, so a singleton collapses.
_vector_of(forms) =
    canonicalize(FormContainer(FormSeq(FormValue[_store_form(f) for f in forms]), FormMap()))

# A grouping member is a `(binding, premises)` match.
_binds_of(m) = m[1]

# Partition matches by the values of the `spec` variables (an ordered list),
# preserving first-seen group order.
function _partition_matches(matches, spec)
    order = Any[]; groups = Dict{Any,Vector{Any}}()
    for m in matches
        b = _binds_of(m)
        key = Tuple(to_form(get(b, v, naught)) for v in spec)
        if !haskey(groups, key)
            push!(order, key); groups[key] = Any[]
        end
        push!(groups[key], m)
    end
    return [(k, groups[k]) for k in order]
end

# The allocated names of the `:accum` levels from `level` on, in order.
_spec_names(specs, level::Int) =
    Symbol[v.name for s in specs[level:end] for v in s.vars]

# Select the index of the row a `:take` names.
function _take_index(members, take::_Take)
    if take.kind === :first
        return 1
    elseif take.kind === :last
        return length(members)
    end
    key = take.var
    best = 0; bestv = nothing
    for (j, m) in enumerate(members)
        v = _num(to_form(get(_binds_of(m), key, naught)), ":take")
        if best == 0 || (take.kind === :min ? v < bestv : v > bestv)
            best = j; bestv = v
        end
    end
    return best
end

# Aggregate the values a listed variable takes across a group.
function _aggregate(agg::Symbol, vals::Vector{Form})
    if agg === :first
        return isempty(vals) ? naught : vals[1]
    elseif agg === :last
        return isempty(vals) ? naught : vals[end]
    end
    nums = [_num(v, ":accum $agg") for v in vals]
    isempty(nums) && return naught
    agg === :min && return Form(minimum(nums))
    agg === :max && return Form(maximum(nums))
    agg === :sum && return Form(sum(nums))
    agg === :mean && return Form(sum(nums) / length(nums))
    if agg === :median
        s = sort(nums)
        n = length(s)
        return Form(isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
    end
    throw(AirEvalError("unknown :accum aggregation $agg"))
end

# Compute the accumulated bindings of one group at `level`. With a final level,
# listed variables are aggregated (or one row is taken); an outer level
# partitions the group by its listed variables and produces vectors aligned with
# the partition order.
function _accum_level(members, specs::Vector{_AccumSpec}, level::Int)
    spec = specs[level]
    names = Symbol[v.name for v in spec.vars]
    last = level == length(specs)
    out = Dict{Symbol,Form}()
    if last
        if spec.take !== nothing
            m = members[_take_index(members, spec.take)]
            b = _binds_of(m)
            for nm in names
                out[nm] = to_form(get(b, nm, naught))
            end
            return out
        end
        for v in spec.vars
            vals = Form[to_form(get(_binds_of(m), v.name, naught)) for m in members]
            out[v.name] = v.agg === nothing ? _vector_of(vals) :
                          _aggregate(v.agg, vals)
        end
        return out
    end
    parts = _partition_matches(members, names)
    for (j, nm) in enumerate(names)
        out[nm] = _vector_of(Form[to_form(p[1][j]) for p in parts])
    end
    deeper = _spec_names(specs, level + 1)
    dicts = [_accum_level(p[2], specs, level + 1) for p in parts]
    for nm in deeper
        out[nm] = _vector_of(Form[d[nm] for d in dicts])
    end
    return out
end

# Turn the matches of one rule into activations. Without `:accum`, one per
# match. With `:accum`, one per group: the unlisted bound variables are the
# group key, and the `:accum` levels supply the accumulated bindings.
function _group_matches(lr::_LogicRule, matches)
    isempty(lr.accums) && return matches
    vars = Symbol[]
    seen = Set{Symbol}()
    for m in matches, k in sort!(collect(keys(_binds_of(m))); by = string)
        (k in seen) && continue
        push!(seen, k); push!(vars, k)
    end
    accum_names = Set{Symbol}(v.name for s in lr.accums for v in s.vars)
    group_vars = Symbol[v for v in vars if !(v in accum_names)]
    out = Tuple{Dict{Symbol,Form},Vector{Form},Tuple,Vector{Form}}[]
    for (key, members) in _partition_matches(matches, group_vars)
        binds = Dict{Symbol,Form}(_binds_of(members[1]))
        merged = _accum_level(members, lr.accums, 1)
        for (k, v) in merged
            binds[k] = v
        end
        prems = Form[p for m in members for p in m[2]]
        push!(out, (binds, prems, key, Form[to_form(x) for x in key]))
    end
    return out
end

# ---- activations -------------------------------------------------------------

# One firing: a rule, the facts it matched (and their identity tokens), its
# bindings, and the fact each `:>` slot currently derives (`nothing` for naught).
mutable struct _Activation
    ruleidx::Int
    rule::Form
    kind::Symbol                       # :plain or :accum
    group::Vector{Form}                # accum group-key values; empty for plain
    ids::Vector{Int}                   # premise / member identity tokens
    premises::Vector{Form}
    binds::Dict{Symbol,Form}
    out::Vector{Union{Nothing,Form}}
end

_activation_key(a::_Activation) =
    a.kind === :plain ? (a.rule, :plain, Tuple(a.ids)) :
                        (a.rule, :accum, Tuple(a.group))

# Every activation of every rule against the current facts, in rule and then
# match order, keyed by fact identity (not by fact value) so a revision keeps
# its invocation.
function _activations_for(env::Env, parsed::Vector{_LogicRule}, facts::Vector{Form},
                          ids::Dict{Form,Int})
    acts = _Activation[]
    for (i, lr) in enumerate(parsed)
        matches = _join_all(env, lr, facts)
        isempty(matches) && continue
        if isempty(lr.accums)
            for (binds, prems) in matches
                aid = Int[ids[f] for f in prems]
                push!(acts, _Activation(i, lr.form, :plain, Form[], aid, prems,
                                        copy(binds), fill(nothing, lr.nslots)))
            end
        else
            for (binds, prems, _key, keyforms) in _group_matches(lr, matches)
                aid = Int[ids[f] for f in prems]
                push!(acts, _Activation(i, lr.form, :accum, keyforms, aid, prems,
                                        binds, fill(nothing, lr.nslots)))
            end
        end
    end
    return acts
end

# ---- identity tokens ---------------------------------------------------------

_max_id(ids::Dict{Form,Int}) = isempty(ids) ? 0 : maximum(values(ids))

# Give every present fact an identity token, in order.
function _ensure_ids!(ids::Dict{Form,Int}, facts::Vector{Form})
    nextid = _max_id(ids) + 1
    for f in facts
        haskey(ids, f) && continue
        ids[f] = nextid
        nextid += 1
    end
    return ids
end

# Follow a chain of moves (`a → b → c`) to the fact that finally holds the
# identity, so a batch that revises the same record twice — `(logic s (revise …
# 2) (revise … 3))` — transfers the original token straight to the last value.
function _transfer_target(transfers::Vector{Tuple{Form,Form}}, new::Form)
    cur = new
    for _ in 1:length(transfers)
        nxt = nothing
        for (o, n) in transfers
            if isequal(o, cur) && !isequal(n, cur)
                nxt = n
                break
            end
        end
        nxt === nothing && break
        cur = nxt
    end
    return cur
end

# Remove the tokens of facts that vanished, move a token from a revised fact to
# its replacement, and assign tokens to newly present facts. Each moved token is
# the revision signal the next round reads.
function _reconcile_ids!(ids::Dict{Form,Int}, present::Set{Form},
                         transfers::Vector{Tuple{Form,Form}}, revised::Set{Int})
    targets = Set{Form}(n for (_, n) in transfers)
    for (old, new) in transfers
        # A record that survives (another reason still holds it) keeps its
        # token; only a fact that vanished passes its identity on. An
        # intermediate of a chain is not present either.
        old in present && continue
        old in targets && continue
        final = _transfer_target(transfers, new)
        haskey(ids, old) || continue
        haskey(ids, final) && continue
        (final in present) || continue
        tid = ids[old]
        delete!(ids, old)
        ids[final] = tid
        push!(revised, tid)
    end
    for f in collect(keys(ids))
        (f in present) || delete!(ids, f)
    end
    nextid = _max_id(ids) + 1
    for f in present
        if !haskey(ids, f)
            ids[f] = nextid
            nextid += 1
        end
    end
    return ids
end

# ---- persisted records -------------------------------------------------------

_reason_form(f::Form, label::Form) = Form(
    PVector{Any}(Any[_store_form(f)]),
    PDict{Symbol,Any}(_REASON_KEY => _store_form(label)))

function _load_reasons(value::Form)
    out = Tuple{Form,Form}[]
    has_key = value isa FormContainer && haskey(value.map, _SET_REASONS)
    for r in _set_seq(value, _SET_REASONS)
        rec = to_form(r)
        rec isa FormContainer || continue
        isempty(rec.seq) && continue
        f = to_form(rec.seq[1])
        label = haskey(rec.map, _REASON_KEY) ? to_form(rec.map[_REASON_KEY]) : naught
        push!(out, (f, label))
    end
    if !has_key   # an older set value: every base fact had an implicit reason
        for f in _set_forms(value, _SET_BASE)
            push!(out, (f, naught))
        end
    end
    return out
end

function _id_form(f::Form, id::Int)
    return Form(PVector{Any}(Any[_store_form(f), id]), PDict{Symbol,Any}())
end

function _load_ids(value::Form)
    ids = Dict{Form,Int}()
    for r in _set_seq(value, _SET_IDS)
        rec = to_form(r)
        rec isa FormContainer || continue
        length(rec.seq) >= 2 || continue
        f = to_form(rec.seq[1])
        v = rec.seq[2]
        v isa Int && (ids[f] = v)
    end
    return ids
end

function _record_form(a::_Activation)
    bmap = Pair{Symbol,Any}[Symbol(":" * String(k)) => _store_form(v) for (k, v) in a.binds]
    outs = FormValue[o === nothing ? nothing : _store_form(o) for o in a.out]
    return Form(PVector{Any}(Any[]), PDict{Symbol,Any}(
        Symbol(":rule") => _store_form(a.rule),
        Symbol(":kind") => _store_form(Form(a.kind)),
        Symbol(":group") => _store_form(_record_seq(a.group)),
        Symbol(":ids") => _store_form(_record_seq(Form[Form(i) for i in a.ids])),
        Symbol(":premises") => _store_form(_record_seq(a.premises)),
        Symbol(":bindings") => _store_form(Form(PVector{Any}(Any[]), PDict{Symbol,Any}(bmap...))),
        Symbol(":out") => _store_form(FormContainer(FormSeq(outs), FormMap()))))
end

function _load_active(setvalue::Form)
    out = _Activation[]
    for r in _set_seq(setvalue, _SET_ACTIVE)
        f = to_form(r)
        f isa FormContainer || continue
        haskey(f.map, Symbol(":rule")) || continue
        rule = to_form(f.map[Symbol(":rule")])
        kind = haskey(f.map, Symbol(":kind")) ?
            _symbolof(to_form(f.map[Symbol(":kind")])) : nothing
        kind = kind === nothing ? :plain : kind
        group = haskey(f.map, Symbol(":group")) ?
            _set_forms(f, Symbol(":group")) : Form[]
        ids = Int[]
        for v in _set_seq(f, Symbol(":ids"))
            x = to_form(v)
            (x isa FormScalar && value(x) isa Int) && push!(ids, value(x))
        end
        prems = _set_forms(f, Symbol(":premises"))
        outs = Union{Nothing,Form}[]
        for v in _set_seq(f, Symbol(":out"))
            o = to_form(v)
            push!(outs, isequal(o, naught) ? nothing : o)
        end
        binds = Dict{Symbol,Form}()
        bm = haskey(f.map, Symbol(":bindings")) ? to_form(f.map[Symbol(":bindings")]) : naught
        if bm isa FormContainer
            for (k, v) in bm.map
                binds[_varname(k)] = to_form(v)
            end
        end
        push!(out, _Activation(0, rule, kind, group, ids, prems, binds, outs))
    end
    return out
end

# ---- provenance --------------------------------------------------------------

# The derived reason of one slot output: `(because RULE PREMISES…)`.
function _because_form(rule::Form, premises::Vector{Form})
    seq = Any[Form(Symbol("because")), _store_form(rule)]
    for p in premises
        push!(seq, _store_form(p))
    end
    return Form(PVector{Any}(seq), PDict{Symbol,Any}())
end

# The base facts of a reason-record list, in first-record order, deduplicated.
function _unique_facts(reasons::Vector{Tuple{Form,Form}})
    out = Form[]; seen = Set{Form}()
    for (f, _) in reasons
        (f in seen) && continue
        push!(seen, f); push!(out, f)
    end
    return out
end

# The complete fact set: base facts first, then each activation's slot outputs.
function _present_facts(reasons::Vector{Tuple{Form,Form}}, active::Vector{_Activation})
    out = Form[]; seen = Set{Form}()
    for (f, _) in reasons
        (f in seen) && continue
        push!(seen, f); push!(out, f)
    end
    for a in active, o in a.out
        o === nothing && continue
        (o in seen) && continue
        push!(seen, o); push!(out, o)
    end
    return out
end

# ---- storing the saturated state --------------------------------------------

function _store_logic_state(value::Form, reasons::Vector{Tuple{Form,Form}},
                            rules::Vector{Form}, active::Vector{_Activation},
                            ids::Dict{Form,Int})
    base = _unique_facts(reasons)
    facts = _present_facts(reasons, active)
    why = FormValue[]
    for a in active, o in a.out
        o === nothing && continue
        push!(why, _store_form(Form(PVector{Any}(Any[_store_form(o),
                                                      _store_form(_because_form(a.rule, a.premises))]),
                                          PDict{Symbol,Any}())))
    end
    value = _set_put(value, _SET_BASE, FormValue[_store_form(f) for f in base])
    value = _set_put(value, _SET_RULES, FormValue[_store_form(f) for f in rules])
    value = _set_put(value, _SET_ACTIVE,
                     FormValue[_store_form(_record_form(a)) for a in active])
    value = _set_put(value, _SET_WHY, why)
    value = _set_put(value, _SET_FACTS, FormValue[_store_form(f) for f in facts])
    value = _set_put(value, _SET_REASONS,
                     FormValue[_store_form(_reason_form(f, l)) for (f, l) in reasons])
    value = _set_put(value, _SET_IDS,
                     FormValue[_store_form(_id_form(f, id)) for (f, id) in ids])
    return value
end

# ---- running a rule program --------------------------------------------------

# The context a side effect (or a `logic` block) evaluates under. `gated` is true
# inside `:+`/`:-`/`:=`, where every operation must name its reason.
mutable struct _LogicCtx
    binds::Union{Nothing,Dict{Symbol,Form}}
    premises::Vector{Form}
    rests::Set{Symbol}
    ops::Vector{Any}
    trigger::Symbol
    gated::Bool
    base::Set{Form}
    set::Any
end

# The mapping bound to `_` during `:=`: each matched wildcard whose value changed,
# under its new value.
function _changed_bindings(oldb::Dict{Symbol,Form}, newb::Dict{Symbol,Form})
    mp = Pair{Symbol,Any}[]
    for (k, v) in newb
        k === Symbol("_") && continue
        oldv = get(oldb, k, nothing)
        (oldv !== nothing && isequal(oldv, v)) && continue
        push!(mp, Symbol(":" * String(k)) => _store_form(v))
    end
    return Form(PVector{Any}(Any[]), PDict{Symbol,Any}(mp...))
end

# Reduce `form` with the program's bindings substituted.
_eval_with(env::Env, form::Form, binds) =
    air_reduce(env, _base_scope(env), _substitute(form, binds))

# Add a `:let` instruction's bindings. The values are parallel: each is
# evaluated under the bindings from *before* the instruction.
function _run_let!(env::Env, arg::Form, binds::Dict{Symbol,Form})
    arg isa FormContainer || throw(AirEvalError(":let needs a (k=v …) map"))
    fresh = Pair{Symbol,Form}[]
    for (k, v) in arg.map
        push!(fresh, _bindname(k) => _eval_with(env, to_form(v), binds))
    end
    for (k, v) in fresh
        binds[k] = v
    end
    return nothing
end

# Evaluate one side-effect instruction under a gating context.
function _run_side_effect(env::Env, form::Form, binds, ctx::_LogicCtx)
    f = _substitute(form, binds)
    prev = env.logic_ctx
    env.logic_ctx = ctx
    try
        air_reduce(env, _base_scope(env), f)
    finally
        env.logic_ctx = prev
    end
    return nothing
end

# Run a rule's instructions for a firing. Returns one entry per `:>` slot: the
# fact that slot now derives, or `nothing` for naught. On a retraction trigger
# the consequences are skipped (the activation is gone) and only `:if`, `:let`,
# and `:-` run, with the vanished activation's bindings.
function _run_program(env::Env, lr::_LogicRule, act::_Activation,
                      trigger::Symbol, old_binds, ops::Vector{Any})
    binds = copy(act.binds)
    if trigger === :revise && old_binds !== nothing
        binds[Symbol("_")] = _changed_bindings(old_binds, act.binds)
    end
    outs = Union{Nothing,Form}[nothing for _ in 1:lr.nslots]
    slot = 0
    ctx = _LogicCtx(binds, act.premises, lr.rests, ops, trigger, true,
                    Set{Form}(), nothing)
    for (kind, form) in lr.program
        if kind === _INS_IF
            truthy(_eval_with(env, form, binds)) || break
        elseif kind === _INS_LET
            _run_let!(env, form, binds)
            ctx.binds = binds
        elseif kind === _INS_CONSEQ
            trigger === :retract && continue
            slot += 1
            v = _eval_with(env, form, binds)
            isequal(v, naught) || (outs[slot] = _factify(v))
        else
            wanted = kind === _INS_ON_ASSERT ? :assert :
                     kind === _INS_ON_RETRACT ? :retract :
                     kind === _INS_ON_REVISE ? :revise : :none
            wanted === trigger || continue
            _run_side_effect(env, form, binds, ctx)
        end
    end
    return outs
end

# ---- applying operations -----------------------------------------------------

# Follow a revised fact to its current form within one batch.
function _follow(moved::Dict{Form,Form}, f::Form)
    seen = Set{Form}()
    while haskey(moved, f) && !(f in seen)
        push!(seen, f)
        f = moved[f]
    end
    return f
end

function _add_reason!(reasons::Vector{Tuple{Form,Form}}, f::Form, label::Form)
    any(r -> isequal(r[1], f) && isequal(r[2], label), reasons) && return nothing
    push!(reasons, (f, label))
    return nothing
end

# Rewrite a matching fact by the `name=value` entries of a `revise`, evaluating
# each new value under the match's bindings.
function _rewrite_fact(env::Env, f::Form, binds::Dict{Symbol,Form}, kmap)
    nf = f
    for (k, v) in kmap
        name = _varname(k)
        haskey(binds, name) || throw(AirEvalError(
            "revise: ?$name is not bound by the condition"))
        newv = _eval_with(env, to_form(v), binds)
        nf = _replace_value(nf, binds[name], newv)
    end
    return nf
end

# Replace every occurrence of `old` in `x` by `new`.
function _replace_value(x::Form, old::Form, new::Form)
    isequal(x, old) && return new
    x isa FormContainer || return x
    seq = FormValue[]
    for a in x.seq
        push!(seq, _store_form(_replace_value(to_form(a), old, new)))
    end
    mp = Pair{Symbol,FormValue}[]
    for (k, v) in x.map
        push!(mp, k => _store_form(_replace_value(to_form(v), old, new)))
    end
    return FormContainer(FormSeq(seq), FormMap(mp))
end

# Move one reason record from `old` to `new`. Returns false when `old` has no
# record with that label (the fact is simply not selected).
function _move_reason!(reasons::Vector{Tuple{Form,Form}}, old::Form, new::Form,
                       label::Form)
    i = findfirst(r -> isequal(r[1], old) && isequal(r[2], label), reasons)
    i === nothing && return false
    deleteat!(reasons, i)
    _add_reason!(reasons, new, label)
    return true
end

# Apply a batch of operations in order. `derived` is the current set of derived
# facts, used to report an attempted revision of one. Returns the `(old, new)`
# revision pairs, so identity tokens can follow them.
function _apply_ops!(env::Env, reasons::Vector{Tuple{Form,Form}},
                     rules::Vector{Form}, derived::Set{Form}, ops)
    pairs = Tuple{Form,Form}[]
    moved = Dict{Form,Form}()
    for op in ops
        kind = op[1]
        if kind === :assert
            f = _follow(moved, op[2]); label = op[3]
            if _is_logic_rule(f)
                any(r -> isequal(r, f), rules) || push!(rules, f)
            else
                _add_reason!(reasons, f, label)
            end
        elseif kind === :retract
            f = _follow(moved, op[2]); label = op[3]
            if _is_logic_rule(f)
                filter!(r -> !isequal(r, f), rules)
            else
                i = findfirst(r -> isequal(r[1], f) && isequal(r[2], label), reasons)
                i === nothing || deleteat!(reasons, i)
            end
        elseif kind === :revise
            cond = op[2]; kmap = op[3]; label = op[4]
            hits = Tuple{Form,Form}[]
            for f in _unique_facts(reasons)
                binds = air_match(env, _base_scope(env), cond, _strip_hold(f),
                                  Dict{Symbol,Form}())
                binds === nothing && continue
                nf = _rewrite_fact(env, f, binds, kmap)
                isequal(nf, f) || push!(hits, (f, nf))
            end
            if isempty(hits)
                for f in derived
                    air_match(env, _base_scope(env), cond, _strip_hold(f),
                              Dict{Symbol,Form}()) === nothing && continue
                    throw(AirEvalError(
                        "revise cannot target a derived fact: $(air_string(f))"))
                end
            end
            for (f, nf) in hits
                _move_reason!(reasons, f, nf, label) || continue
                moved[f] = nf
                push!(pairs, (f, nf))
            end
        elseif kind === :revise_fact
            old = _follow(moved, op[2]); new = op[3]; label = op[4]
            isequal(old, new) && continue
            i = findfirst(r -> isequal(r[1], old) && isequal(r[2], label), reasons)
            if i === nothing
                (old in derived) && throw(AirEvalError(
                    "revise-fact cannot target a derived fact: $(air_string(old))"))
                throw(AirEvalError(
                    "revise-fact: the old fact is not in the set"))
            end
            deleteat!(reasons, i)
            _add_reason!(reasons, new, label)
            moved[old] = new
            push!(pairs, (old, new))
        else
            throw(AirEvalError("unknown logic operation $kind"))
        end
    end
    return pairs
end

# ---- firing ------------------------------------------------------------------

_derived_set(reasons::Vector{Tuple{Form,Form}}, active::Vector{_Activation}) = begin
    der = Set{Form}()
    for a in active, o in a.out
        o === nothing || push!(der, o)
    end
    der
end

function _parsed_for(parsed::Vector{_LogicRule}, form::Form)
    for lr in parsed
        isequal(lr.form, form) && return lr
    end
    return nothing
end

# Saturate a set value. Each round computes the current activations, classifies
# each as an assertion / retraction / revision against the stored records, runs
# the eligible instructions, folds their consequences and operations, and
# reconciles the fact identities. The loop ends when a round changes nothing.
function _fire(env::Env, value::Form; initial_ops = Any[])
    rules = _set_forms(value, _SET_RULES)
    reasons = _load_reasons(value)
    ids = _load_ids(value)
    active = _load_active(value)
    parsed = _LogicRule[_parse_rule(r) for r in rules]
    revised = Set{Int}()
    if !isempty(initial_ops)
        pairs = _apply_ops!(env, reasons, rules, _derived_set(reasons, active),
                            initial_ops)
        parsed = _LogicRule[_parse_rule(r) for r in rules]
        present = Set{Form}(_present_facts(reasons, active))
        _reconcile_ids!(ids, present, pairs, revised)
    end
    for _round in 1:_MAX_ROUNDS
        facts = _present_facts(reasons, active)
        _ensure_ids!(ids, facts)
        acts = _activations_for(env, parsed, facts, ids)
        oldmap = Dict{Any,Int}()
        for (i, a) in enumerate(active)
            oldmap[_activation_key(a)] = i
        end
        newkeys = Set{Any}(_activation_key(a) for a in acts)
        gone = _Activation[a for a in active if !(_activation_key(a) in newkeys)]
        fresh = _Activation[a for a in acts if !haskey(oldmap, _activation_key(a))]
        revs = Tuple{_Activation,_Activation}[]
        for a in acts
            k = _activation_key(a)
            haskey(oldmap, k) || continue
            o = active[oldmap[k]]
            if a.kind === :plain
                any(id -> id in revised, a.ids) && push!(revs, (o, a))
            elseif a.ids != o.ids || any(id -> id in revised, a.ids)
                push!(revs, (o, a))
            end
        end
        (isempty(gone) && isempty(fresh) && isempty(revs)) && break

        # ---- run the programs for this round's events ----------------------
        buf = Any[]
        newout = Dict{Any,Vector{Union{Nothing,Form}}}()
        for o in gone
            lr = _parsed_for(parsed, o.rule)
            lr === nothing && continue    # the rule itself was retracted
            _run_program(env, lr, o, :retract, nothing, buf)
        end
        for (o, a) in revs
            lr = parsed[a.ruleidx]
            newout[_activation_key(a)] =
                _run_program(env, lr, a, :revise, o.binds, buf)
        end
        for a in fresh
            lr = parsed[a.ruleidx]
            newout[_activation_key(a)] =
                _run_program(env, lr, a, :assert, nothing, buf)
        end

        # ---- the new activation records -----------------------------------
        next_active = _Activation[]
        for a in acts
            k = _activation_key(a)
            if haskey(newout, k)
                a.out = newout[k]
            elseif haskey(oldmap, k)
                oldouts = active[oldmap[k]].out
                a.out = length(oldouts) == length(a.out) ? copy(oldouts) :
                    Union{Nothing,Form}[s <= length(oldouts) ? oldouts[s] : nothing
                                        for s in 1:length(a.out)]
            end
            push!(next_active, a)
        end

        # ---- apply the round's operations ---------------------------------
        op_pairs = Tuple{Form,Form}[]
        if !isempty(buf)
            op_pairs = _apply_ops!(env, reasons, rules,
                                   _derived_set(reasons, active), buf)
            parsed = _LogicRule[_parse_rule(r) for r in rules]
        end

        # ---- identity: transfer a token only when a fact really moved ------
        base_after = _unique_facts(reasons)
        before = Set{Form}(base_after)
        for o in active, f in o.out
            f === nothing || push!(before, f)
        end
        present_list = _present_facts(reasons, next_active)
        after = Set{Form}(present_list)
        transfers = Tuple{Form,Form}[]
        for a in next_active
            k = _activation_key(a)
            haskey(oldmap, k) || continue
            oldouts = active[oldmap[k]].out
            for s in 1:length(a.out)
                oldf = s <= length(oldouts) ? oldouts[s] : nothing
                newf = a.out[s]
                isequal(oldf, newf) && continue
                if oldf !== nothing && newf !== nothing &&
                   !(oldf in after) && !(newf in before)
                    push!(transfers, (oldf, newf))
                end
            end
        end
        append!(transfers, op_pairs)
        empty!(revised)
        _reconcile_ids!(ids, after, transfers, revised)
        active = next_active
    end
    return _store_logic_state(value, reasons, rules, active, ids)
end

# ---- builtins ----------------------------------------------------------------

# `(logic-set name)` — create or open a named logic-set; returns its handle. A
# logic set is a named volatile in the current namespace's database, so the name
# follows the named-form rules (normalized, non-empty, `air/` reserved). Opening
# one requires read; mutating it requires write and querying it requires read
# (enforced by the operations themselves).
function _bi_logic_set(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("logic-set needs a name"))
    name = _named_name_arg(env, scope, to_form(call.seq[2]))
    db = _persist_db(env)
    existing = named_form(db, name; create = nothing)
    if existing !== nothing
        _check!(env, existing, :read, _named_target(name))
        return existing
    end
    me = _check_named_create!(env)
    return named_form(db, name; create = true, value = _empty_logic_set(),
                      metadata = _metadata_form(me; acl = _perms_acl(me)))
end
special!(Symbol("logic-set"), _bi_logic_set)

# A logic-set handle argument. Every operation gates on the set's own metadata:
# mutating it needs write, querying it needs read.
function _as_logic_set(env::Env, x::Form, who::String, perm::Symbol = :write)
    x isa VolatileForm || throw(AirEvalError("$who needs a logic-set handle"))
    _check!(env, x, perm)
    return x
end

# The reason a fact-carrying operation records. Inside a gated side effect
# (`:+`, `:-`, `:=`) an explicit `reason=` is required; elsewhere it defaults to
# `naught`. The label is `naught` or a keyword.
function _read_reason(env::Env, scope::Scope, call::FormContainer, gated::Bool)
    if haskey(call.map, _REASON_KEY)
        r = air_reduce(env, scope, to_form(call.map[_REASON_KEY]))
        (isequal(r, naught) || is_keyword(r)) ||
            throw(AirEvalError("reason= must be naught or a keyword"))
        return r
    end
    gated && throw(AirEvalError(
        "a rule side effect must give an explicit reason= to assert, retract, or revise"))
    return naught
end

# Apply one operation to a set and saturate; the transaction rolls back on error.
function _fire_op(env::Env, vf, op)
    _tx_boundary(env) do
        vf[] = _fire(env, vf[], initial_ops = Any[op])
    end
    return nothing
end

# `(assert s form [reason=…])` or, in a side effect or block, `(assert form)`.
function _bi_assert(env::Env, scope::Scope, call::FormContainer)
    args = _sx(call.seq, 2:length(call.seq))
    ctx = env.logic_ctx
    if length(args) == 1
        ctx === nothing && throw(AirEvalError(
            "assert needs a logic-set: write (assert set form)"))
        f = _factify(air_reduce(env, scope, to_form(args[1])))
        push!(ctx.ops, (:assert, f, _read_reason(env, scope, call, ctx.gated)))
        return f
    elseif length(args) == 2
        vf = _as_logic_set(env, air_reduce(env, scope, to_form(args[1])), "assert")
        f = _factify(air_reduce(env, scope, to_form(args[2])))
        label = _read_reason(env, scope, call, ctx !== nothing && ctx.gated)
        if ctx !== nothing && ctx.set === vf
            push!(ctx.ops, (:assert, f, label))
        else
            _fire_op(env, vf, (:assert, f, label))
        end
        return f
    end
    throw(AirEvalError("assert takes a logic-set and a form"))
end
special!(:assert, _bi_assert)

# `(retract s form [reason=…])` or, in a side effect or block, `(retract form)`.
function _bi_retract(env::Env, scope::Scope, call::FormContainer)
    args = _sx(call.seq, 2:length(call.seq))
    ctx = env.logic_ctx
    if length(args) == 1
        ctx === nothing && throw(AirEvalError(
            "retract needs a logic-set: write (retract set form)"))
        f = _factify(air_reduce(env, scope, to_form(args[1])))
        push!(ctx.ops, (:retract, f, _read_reason(env, scope, call, ctx.gated)))
        return f
    elseif length(args) == 2
        vf = _as_logic_set(env, air_reduce(env, scope, to_form(args[1])), "retract")
        f = _factify(air_reduce(env, scope, to_form(args[2])))
        label = _read_reason(env, scope, call, ctx !== nothing && ctx.gated)
        if ctx !== nothing && ctx.set === vf
            push!(ctx.ops, (:retract, f, label))
        else
            _fire_op(env, vf, (:retract, f, label))
        end
        return f
    end
    throw(AirEvalError("retract takes a logic-set and a form"))
end
special!(:retract, _bi_retract)

# `(revise s condition changes [reason=…])`, or in a side effect,
# `(revise condition changes)`. The condition's wildcards name the positions to
# rewrite; the map gives their new values. Only base facts can be revised.
function _bi_revise(env::Env, scope::Scope, call::FormContainer)
    seq = _sx(call.seq, 1:length(call.seq))
    ctx = env.logic_ctx
    if length(seq) == 3
        ctx === nothing && throw(AirEvalError(
            "revise needs a logic-set: write (revise set condition changes)"))
        cond = to_form(seq[2]); kmap = to_form(seq[3])
        push!(ctx.ops, (:revise, cond, kmap, _read_reason(env, scope, call, ctx.gated)))
        return naught
    elseif length(seq) == 4
        vf = _as_logic_set(env, air_reduce(env, scope, to_form(seq[2])), "revise")
        cond = to_form(seq[3]); kmap = to_form(seq[4])
        label = _read_reason(env, scope, call, ctx !== nothing && ctx.gated)
        if ctx !== nothing && ctx.set === vf
            push!(ctx.ops, (:revise, cond, kmap, label))
        else
            _fire_op(env, vf, (:revise, cond, kmap, label))
        end
        return naught
    end
    throw(AirEvalError(
        "revise takes (revise set condition changes) or, in a side effect, " *
        "(revise condition changes)"))
end
special!(:revise, _bi_revise)

# `(revise-fact s old new [reason=…])`, or in a side effect,
# `(revise-fact old new)`. Both facts are written out; only a base fact can be
# revised.
function _bi_revise_fact(env::Env, scope::Scope, call::FormContainer)
    args = _sx(call.seq, 2:length(call.seq))
    ctx = env.logic_ctx
    if length(args) == 2
        ctx === nothing && throw(AirEvalError(
            "revise-fact needs a logic-set: write (revise-fact set old new)"))
        old = _factify(air_reduce(env, scope, to_form(args[1])))
        new = _factify(air_reduce(env, scope, to_form(args[2])))
        push!(ctx.ops, (:revise_fact, old, new,
                        _read_reason(env, scope, call, ctx.gated)))
        return naught
    elseif length(args) == 3
        vf = _as_logic_set(env, air_reduce(env, scope, to_form(args[1])), "revise-fact")
        old = _factify(air_reduce(env, scope, to_form(args[2])))
        new = _factify(air_reduce(env, scope, to_form(args[3])))
        label = _read_reason(env, scope, call, ctx !== nothing && ctx.gated)
        if ctx !== nothing && ctx.set === vf
            push!(ctx.ops, (:revise_fact, old, new, label))
        else
            _fire_op(env, vf, (:revise_fact, old, new, label))
        end
        return naught
    end
    throw(AirEvalError(
        "revise-fact takes (revise-fact set old new) or, in a side effect, " *
        "(revise-fact old new)"))
end
special!(Symbol("revise-fact"), _bi_revise_fact)

# `(update coll key f)` — the collection update. (Logic-set edits are `revise`.)
function _update_call(env::Env, scope::Scope, call::FormContainer, is_hold_fn::Bool)
    args = _call_args(env, scope, call)
    if !isempty(args) && length(args) != 3
        args[1] isa VolatileForm && throw(AirEvalError(
            "update no longer edits a logic-set; use revise or revise-fact"))
    end
    length(args) >= 3 || throw(AirEvalError(
        "update takes a collection, a key, and a function"))
    strip, held = _hold_mode(call, is_hold_fn)
    c = _as_container(strip ? _strip_hold(args[1]) : args[1])
    kk = _get_key(args[2])
    (kk isa Integer || kk isa Symbol) ||
        throw(AirEvalError("update needs an integer or keyword key"))
    r = _call(env, scope, args[3], [_at_key(c, kk)])
    strip && (r = _strip_hold(r))
    result = canonicalize(_set_key(c, kk, r))
    return held ? _ensure_hold(result) : result
end
_hold_pair!(:update, _update_call)

# `(logic s body…)` — evaluate the body with `s` as the set of any bare or
# set-targeted operation, collecting them into one event. Reads inside the body
# see the set as it was on entry; the edits are applied together at the end.
function _bi_logic(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("logic needs a logic-set"))
    vf = _as_logic_set(env, air_reduce(env, scope, to_form(call.seq[2])), "logic")
    ops = Any[]
    ctx = _LogicCtx(nothing, Form[], Set{Symbol}(), ops, :block, false,
                    Set{Form}(_unique_facts(_load_reasons(vf[]))), vf)
    prev = env.logic_ctx
    env.logic_ctx = ctx
    result = naught
    try
        for v in _sx(call.seq, 3:length(call.seq))
            result = air_reduce(env, scope, to_form(v))
        end
    finally
        env.logic_ctx = prev
    end
    isempty(ops) || _tx_boundary(env) do
        vf[] = _fire(env, vf[], initial_ops = ops)
    end
    return result
end
special!(:logic, _bi_logic)

# `(facts s)` / `(rules s)` — the set's facts (including derived) or rules.
function _set_part(env::Env, vf, key::Symbol, who::String)
    vf = _as_logic_set(env, vf, who, :read)
    return canonicalize(FormContainer(FormSeq(_set_seq(vf[], key)), FormMap()))
end
builtin!(:facts, (env, scope, args) -> _set_part(env, args[1], _SET_FACTS, "facts"))
builtin!(:rules, (env, scope, args) -> _set_part(env, args[1], _SET_RULES, "rules"))

# `(why s fact)` — every reason recorded for a fact: explicit base labels and
# the `(because rule premises…)` provenance of each derivation, deduplicated.
builtin!(:why, (env, scope, args) -> begin
    vf = _as_logic_set(env, args[1], "why", :read)
    length(args) >= 2 || throw(AirEvalError("why needs a fact"))
    target = _factify(args[2])
    out = FormValue[]
    seen = Set{String}()
    push_reason! = r -> begin
        s = air_string(r)
        (s in seen) && return nothing
        push!(seen, s); push!(out, _store_form(r))
    end
    for (f, label) in _load_reasons(vf[])
        isequal(f, target) && push_reason!(label)
    end
    for w in _set_seq(vf[], _SET_WHY)
        rec = to_form(w)
        (rec isa FormContainer && length(rec.seq) >= 2) || continue
        isequal(to_form(rec.seq[1]), target) || continue
        push_reason!(to_form(rec.seq[2]))
    end
    return canonicalize(FormContainer(FormSeq(out), FormMap()))
end)

# `(because rule premises…)` — the reason form of a derivation. The first
# argument is a rule form, a keyword label, or naught.
builtin!(:because, (env, scope, args) -> begin
    isempty(args) && throw(AirEvalError("because needs a rule or reason"))
    head = args[1]
    (isequal(head, naught) || is_keyword(head) || _is_logic_rule(head)) ||
        throw(AirEvalError(
            "because takes a rule, a keyword, or naught as its first argument"))
    seq = Any[Form(Symbol("because")), _store_form(head)]
    for v in args[2:end]
        push!(seq, _store_form(v))
    end
    return Form(PVector{Any}(seq), PDict{Symbol,Any}())
end)

# `(rule? x)` — whether `x` is a RETE rule form.
builtin!(Symbol("rule?"), (env, scope, args) -> begin
    isempty(args) && throw(AirEvalError("rule? needs a form"))
    return Form(_is_logic_rule(args[1]))
end)
