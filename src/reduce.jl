################################################################################
# reduce.jl
#
# The reduction engine: the inner term-rewriting system. `air_reduce` reduces a
# form to a fixed point, always returning a *canonical* form.
#
# Order of operations for a container: a builtin at the head wins, then a global
# rule anchored by any raw symbol in the form, and only then are the elements
# reduced bottom-up and the form retried. This matches the README: a form is
# replaced by a matching pattern if one fires, and otherwise its elements are
# replaced and the result is retried.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# A pending tail reduction. A helper that would otherwise call `air_reduce` in
# tail position returns `_Tail(form, scope)` instead; `air_reduce` unwinds the
# Julia frames and loops, so a tail call does not grow the stack. This is what
# makes a tail-recursive rule run in constant stack: the depth budget counts
# *nested* reductions, not iterations.
struct _Tail
    form::Form
    scope::Scope
end

# A tail step either keeps the current scope (control forms) or extends it (a
# rule application). Rebinding the extension on the scope the tail chain
# started from keeps the scope chain from growing along a long tail recursion;
# every parameter is substituted into the body, so an intermediate binding is no
# longer needed once its body has been entered.
function _tail_scope(base::Scope, cur::Scope, next::Scope)
    next === cur && return cur
    next.parent === cur || return next
    # The layers of the scope the tail step replaces (`cur`) must survive: a
    # namespace function's rule application adds a name binding but no layers, so
    # keeping only `next.layers` would drop the namespace context mid-body. Stop
    # at `base` — its own layers already apply through the scope we rebase onto,
    # and re-collecting them on every step would grow the layer list without
    # bound along a long tail recursion.
    layers = RuleLayer[next.layers...]
    s = cur
    while s !== nothing && s !== base
        append!(layers, s.layers)
        s = s.parent
    end
    # The tail step may have entered a new rule body; `owner`/`assume` read the
    # nearest rule context, so it must survive the rebase.
    rule = next.rule === nothing ? base.rule : next.rule
    return scope_extend(base, [next.names[i] => next.vals[i]
                               for i in eachindex(next.names)];
                        layers = layers, rule = rule)
end

"""
    air_reduce(env, scope, x) -> Form

Reduce `x` to a fixed point in `env`, with local bindings `scope`. Always returns
a canonical form. Guards against runaway recursion with a total-step budget and a
nesting-depth budget. A `_Tail` returned by an inner step is followed
iteratively, so tail calls do not consume stack.
"""
function air_reduce(env::Env, scope::Scope, x::Form)
    env.depth[] += 1
    try
        env.depth[] > env.max_depth &&
            throw(AirEvalError("reduction nested too deeply (possible infinite recursion)"))
        base = scope
        while true
            (env.steps[] += 1) > env.max_steps &&
                throw(AirEvalError("reduction did not reach a fixed point"))
            r = _air_reduce(env, scope, x)
            r isa _Tail || return r
            x = r.form
            scope = _tail_scope(base, scope, r.scope)
        end
    catch e
        e isa InterruptException && rethrow()
        e isa AirError || rethrow()
        e2 = _annotate_error(e, scope)
        e2 === e && rethrow()
        throw(e2)
    finally
        env.depth[] -= 1
    end
end

function _air_reduce(env::Env, scope::Scope, x::Form)
    if x isa VolatileForm || x isa FormExtern ||
       x isa ActorForm || x isa PromiseForm || x isa DelayForm ||
       x isa StreamForm
        return x        # a mutable, an extern, or a reference form is a value
    elseif x isa FormScalar
        s = value(x)
        # The dot root marker evaluates to the global namespace volatile.
        s === DOT_ROOT && return _ns_root(env)
        # `NA` is air's predefined missing-value marker and a fixed point: it
        # reduces to itself. No binding form admits it as a name, but `let`
        # substitutes textually, so guard here before any scope lookup.
        s === NA_SYMBOL && return x
        if s isa Symbol && is_raw_symbol(s)
            bound = scope_get(scope, s)
            if bound !== nothing
                v = bound.value
                # A self-binding is a fixed point: `(let (db=db) db)` is `db`.
                # Any other value is reduced in the current scope; if its head is
                # this same name, resolution grows the form until the budget
                # stops it.
                isequal(v, x) && return x
                return _Tail(v, scope)
            end
            # `$` and `@` are ordinary raw symbols, so a local binding above
            # shadows them; unbound, they name the current user's home and the
            # database root (`.` for a system user).
            s === HOME_ROOT && return _home_volatile(env)
            s === AT_ROOT && return _at_root(env)
            m = match_rule_for(env, scope, x)
            m === nothing || return _apply_rule_checked(env, scope, m, x)
        end
        return x
    else
        h = head_symbol(x)
        # An error object is a constant: `(error :io data…)` never reduces, at any
        # depth, so a raw payload survives for matching and traceback. It is not
        # a hold (there is no `'`), just inert data.
        h === ERROR_HEAD && return x
        # A signal object is the same kind of constant: `(signal :tag data…)`
        # never reduces, so `notify` can dispatch it exactly.
        h === SIGNAL_HEAD && return x
        # A UI tree is descriptive data: `(ui kind …)` never reduces, so an
        # `assert=` body stays raw until the runtime instantiates the element
        # and evaluates the parameter itself.
        h === UI_HEAD && return x
        # A held form is data: it stays as it is, but its `preval` holes (written
        # `~e`) are filled in eagerly. This precedes splice expansion, so a `...`
        # inside a hold stays literal.
        h === HOLD && return _finish(env, scope, x, _expand_hold(env, scope, x))
        # A replacement rule and a RETE rule are data. Their conditions and
        # bodies are raw code, evaluated only by the engine that consumes them.
        _is_replacement_rule(x) && return x
        h === RULE && return x
        # A namespace entry marker is inert data: it names a definition to be
        # applied only when it lands in head position (see `_apply_ns_fn`). A
        # `val` marker is not inert: it dereferences to its thread-local binding.
        (_is_ns_fn(x) || _is_ns_sub(x) || _is_ns_proxy(x) ||
         _is_ns_sub_link(x) || _is_ns_alias(x)) && return x
        if _is_ns_val(x)
            v = _ns_val_value(env, x)
            return isequal(v, x) ? x : _Tail(v, scope)
        end
        # The canonical (infix) pipeline form `(x >> step…)`.
        _is_pipeline(x) &&
            return _finish(env, scope, x,
                           _run_pipeline(env, scope, to_form(x.seq[1]),
                                         x.seq[3:length(x.seq)]))
        # 0. Expand any splices (`x...`) first.
        _has_splat(x) && return _Tail(_splice(env, scope, x), scope)
        # A replacement-rule form in head position is a function: its pattern is
        # matched against the argument form and its replacement is the body (see
        # `_apply_rule_form`). A `part`/`comp`/`juxt`/`complement` form is applied
        # by un-holding that form's arguments.
        if h === nothing && !isempty(x.seq)
            headf = to_form(x.seq[1])
            args = Form[to_form(v) for v in _sx(x.seq, 2:length(x.seq))]
            if _is_ns_fn(headf)
                # `(.util.foo 1 2)` — a namespace entry in head position applies
                # that namespace's rules for `foo` to the reconstructed call.
                r = _apply_ns_fn(env, scope, headf, args, x)
                r === nothing || return (r isa _Tail ? r : canonicalize(r))
            elseif _is_ns_proxy(headf)
                # `(.dst.foo 1 2)` — an imported proxy applies the *source*
                # namespace's rules without requiring read access to the source.
                r = _apply_proxy(env, scope, headf, args, x)
                r === nothing || return (r isa _Tail ? r : canonicalize(r))
            elseif _is_replacement_rule(headf)
                r = _apply_rule_form(env, scope, headf, args)
                r === nothing || return (r isa _Tail ? r : canonicalize(r))
            elseif _is_part_form(headf)
                return canonicalize(_apply_part_form(env, scope, headf, args))
            end
        end
        # 1. Special forms are reserved and dispatched by head. An overridable
        #    special (like `get`) defers to a matching user rule first.
        if h !== nothing && haskey(BUILTINS, h) && BUILTINS[h].special
            b = BUILTINS[h]
            if b.overridable
                m = match_rule_for(env, scope, x)
                m === nothing || return _apply_rule_checked(env, scope, m, x)
            end
            return _finish(env, scope, x, apply_builtin(env, scope, b, x))
        end
        # 1b. A rule that holds any of its parameters must see the *raw* form,
        #     before scope resolution replaces a caller's bare symbol by its value
        #     (`(def (f ?x) hold=x (g x))` must receive the symbol `x`, not its
        #     value). Operator forms defer so infix/prefix reduction keeps its
        #     priority; their rules are tried at step 4.
        if !_is_operator_call(x, h)
            m = match_rule_for(env, scope, x; want_held=true)
            m === nothing || return _apply_rule_checked(env, scope, m, x)
        end
        # 2. Resolve scope-bound symbols, so a user rule (and infix/prefix
        #    dispatch) matches the resolved form rather than one still holding a
        #    bare local name.
        if !_scope_empty(scope)
            rx = _resolve(scope, x)
            rx === x || return _Tail(rx, scope)
        end
        # 3. The infix form is the canonical form of an operator application. It
        #    fires first, but if the operands are not both numbers (symbolic) the
        #    reducer falls through so a rule anchored on the operator can match.
        op = infix_operator(x)
        if op !== nothing
            a = air_reduce(env, scope, to_form(x.seq[1]))
            # `and`/`or` short-circuit: the second operand is only reduced if the
            # first does not decide the result.
            if op === Symbol("and")
                truthy(a) || return a
                return _Tail(to_form(x.seq[3]), scope)
            elseif op === Symbol("or")
                truthy(a) && return a
                return _Tail(to_form(x.seq[3]), scope)
            end
            b = air_reduce(env, scope, to_form(x.seq[3]))
            r = op_infix(op, a, b)
            r === nothing || return canonicalize(r)
        end
        # 3. A prefix operator call is sugar, normalized to infix.
        if h !== nothing && haskey(OPERATORS, h)
            args = Form[air_reduce(env, scope, to_form(v)) for v in _sx(x.seq, 2:length(x.seq))]
            return canonicalize(op_prefix(env, scope, h, args))
        end
        # 4. Global user rules, tried before eager builtins so that a builtin
        #    like `get` can be overridden for a particular form.
        m = match_rule_for(env, scope, x)
        m === nothing || return _apply_rule_checked(env, scope, m, x)
        # 5. Eager builtins.
        if h !== nothing && haskey(BUILTINS, h)
            return _finish(env, scope, x, apply_builtin(env, scope, BUILTINS[h], x))
        end
        # 6. Otherwise reduce the elements and retry.
        return _reduce_children(env, scope, x)
    end
end

# ---- applying a function -----------------------------------------------------

# Build the call `(f args…)` and reduce it. A symbol `f` dispatches to a rule,
# operator, or builtin; a replacement-rule form is applied by matching (see
# `_apply_rule_form`).
_call(env::Env, scope::Scope, f::Form, args) =
    air_reduce(env, scope, Form(PVector{Any}([f, args...]), PDict{Symbol,Any}()))

# The `hold=` option of a `def`/rule form: a set of parameter names to bind without
# reducing. The value is `hold=x` (one name) or `hold=(x y …)` (several).
function _held_names(call::FormContainer)
    return _option_names(call.map, Symbol(":hold"))
end

# The names an option's value lists: one symbol, or a sequence of symbols.
function _option_names(map, key::Symbol)
    out = Set{Symbol}()
    haskey(map, key) || return out
    h = to_form(map[key])
    if h isa FormContainer
        for v in h.seq
            s = _symbolof(to_form(v))
            s === nothing || push!(out, s)
        end
    else
        s = _symbolof(h)
        s === nothing || push!(out, s)
    end
    return out
end

# The hold bound to `_` inside a rule body: every argument, as it entered the
# function. A non-held rule (`hold=` absent) binds the reduced arguments; a rule
# that holds a parameter binds the raw arguments, matching that rule's "exactly as
# matched" semantics. The elements are kept as elements, so a single container
# argument is held as one element: `((?x -> _) (a b))` is `(' (a b))`.
function _args_hold(env::Env, scope::Scope, args::Vector{Form}, raw::Bool)
    seq = FormValue[]
    for a in args
        push!(seq, _store_form(raw ? a : air_reduce(env, scope, a)))
    end
    return _hold_form(seq, FormMap())
end

# Apply a replacement-rule form to `args`: a rule in head position is a lambda.
# The subject is the argument form as written, so `((?x -> (x + 10)) 5)` matches
# `?x` against `5`, a multi-argument pattern `(?a ?b)` matches `(1 2)`, and a
# no-argument call matches its pattern against `naught`.
# On a match the replacement is reduced in a scope binding the parameters; `_` is
# bound to a hold of all arguments. Otherwise return `nothing`, leaving the call
# unreduced (as a rule form the reducer does not match stays inert).
function _apply_rule_form(env::Env, scope::Scope, rf::FormContainer,
                          args::Vector{Form})
    pattern, guard, replacement, unhold, held = _parse_replace_rule(rf)
    # The subject is the argument form as written: no arguments is `naught`, one
    # argument is that argument itself (so `((?x -> …) v)` binds `?x` to `v`),
    # and several arguments are the argument list.
    subject = isempty(args) ? naught :
              length(args) == 1 ? canonicalize(args[1]) :
              FormContainer(FormSeq(FormValue[args...]), FormMap())
    binds = air_match(env, scope, pattern, subject, Dict{Symbol,Form}())
    binds === nothing && return nothing
    if guard !== nothing
        gscope = scope_extend(scope, [n => v for (n, v) in binds])
        _cond_true(air_reduce(env, gscope, guard)) || return nothing
    end
    pairs = Pair{Symbol,Form}[]
    subst = Dict{Symbol,Form}()
    for (name, v) in binds
        name in held || (v = air_reduce(env, scope, v))
        subst[name] = v
        # A bare-symbol match is left to resolve through the caller's scope
        # (see `_rule_expansion`).
        (v isa FormScalar && value(v) isa Symbol && is_raw_symbol(value(v))) && continue
        push!(pairs, name => v)
    end
    subst[PLACEHOLDER] = _args_hold(env, scope, args, !isempty(held))
    body = _subst_params(replacement, subst)
    unhold && (body = _strip_hold(body))
    return _Tail(body, scope_extend(scope, pairs))
end

# ---- splicing ----------------------------------------------------------------

_has_splat(x::FormContainer) = any(v -> _is_splat(to_form(v)), x.seq)

# Expand the splice markers in `x`: each `(... e)` contributes the elements of
# the reduced `e` (its sequence appended, its map merged); a scalar contributes
# itself and `naught` contributes nothing.
function _splice(env::Env, scope::Scope, x::FormContainer)
    seq = FormValue[]
    map = Pair{Symbol,FormValue}[]
    for v in x.seq
        fv = to_form(v)
        if _is_splat(fv) && length(fv.seq) == 2
            val = air_reduce(env, scope, to_form(fv.seq[2]))
            if val isa FormContainer
                for e in val.seq
                    push!(seq, e)
                end
                for (k, e) in val.map
                    push!(map, _dynamic_key(k, env, scope) => e)
                end
            elseif !isequal(val, naught)
                push!(seq, _store_form(val))
            end
        else
            push!(seq, _store_form(air_reduce(env, scope, fv)))
        end
    end
    for (k, v) in x.map
        push!(map, _dynamic_key(k, env, scope) =>
                    _store_form(air_reduce(env, scope, to_form(v))))
    end
    return FormContainer(FormSeq(seq), FormMap(map))
end

# Reduce each child, rebuild, and retry if anything changed.
function _reduce_children(env::Env, scope::Scope, x::FormContainer)
    seq = FormValue[]
    for a in x.seq
        push!(seq, _store_form(air_reduce(env, scope, to_form(a))))
    end
    map = Pair{Symbol,FormValue}[]
    for (k, v) in x.map
        push!(map, _dynamic_key(k, env, scope) =>
                    _store_form(air_reduce(env, scope, to_form(v))))
    end
    new = FormContainer(FormSeq(seq), FormMap(map))
    _same_value(new, x) && return canonicalize(x)
    # A one-element container whose element reduced to a namespace `def` marker is
    # a (zero-argument) call: keep it so `_apply_ns_fn` sees the marker in head
    # position instead of treating the marker as an inert value.
    if length(new.seq) == 1 && isempty(new.map) && _is_ns_fn(to_form(new.seq[1]))
        return _Tail(new, scope)
    end
    return _Tail(canonicalize(new), scope)
end

# Apply a rule, but stop if it reproduces its input (a self-rule), so a rule like
# `(def (f ?x) (f x))` returns rather than spins until the budget is spent. The
# replacement is returned as a tail step rather than reduced here, so a
# tail-recursive rule iterates in constant stack.
function _apply_rule_checked(env::Env, scope::Scope, m, x::Form)
    rule, _ = m
    if rule.memo !== nothing
        # The key is the evaluated parameter bindings, so `(f (+ 1 1))` and
        # `(f 2)` share an entry and a held parameter keeps its raw match. The
        # bindings are computed once and reused by the expansion, so a memoized
        # rule never evaluates its arguments twice. A hit is already a fixed
        # point, so it is returned as is.
        subst = _rule_subst(env, scope, rule, m[2])
        key = _memo_key(subst)
        hit, val = _memo_lookup(rule.memo, key)
        hit && return val
        body, bscope = _rule_expansion(env, scope, m, x; subst = subst)
        _same_value(body, x) && return canonicalize(x)
        val = air_reduce(env, bscope, body)
        _memo_store!(rule.memo, key, val)
        return val
    end
    body, bscope = _rule_expansion(env, scope, m, x)
    isequal(body, x) && return canonicalize(x)
    return _Tail(body, bscope)
end

"""
    apply_rule(env, scope, (rule, binds), subject) -> Form

Bind the rule's parameters and reduce the rule body in the extended scope. A held
parameter is bound to the raw form **exactly as matched** — unheld and not
evaluated — so the replacement inserts it as-is and later reduction applies to
the result; a non-held parameter is reduced first. A parameter whose match is the
same bare symbol skips the binding, so the symbol resolves through the caller's
scope instead of becoming a self-binding. A held occurrence `'x` in the body is
replaced by the held match `(' …)` (holding is preserved through substitution).

A rule written with no body (`rule.implicit`) reproduces its matched form instead
of replacing it: the replacement is rebuilt from the pattern and the subject (see
`_implicit_form`), so held parameters stay exactly as matched while every other
part reduces. The form itself is a fixed point and is not re-matched.
"""
function apply_rule(env::Env, scope::Scope, m, subject::Form)
    body, bscope = _rule_expansion(env, scope, m, subject)
    return air_reduce(env, bscope, body)
end

# The evaluated parameter bindings of a rule match: a non-held parameter is
# reduced in the caller's scope, a held one stays exactly as matched.
function _rule_subst(env::Env, scope::Scope, rule::Rule, binds)
    subst = Dict{Symbol,Form}()
    for name in rule.params
        haskey(binds, name) || continue
        v = binds[name]
        name in rule.held || (v = air_reduce(env, scope, v))
        subst[name] = v
    end
    return subst
end

# The unreduced replacement and its scope for a rule match. `subst` may be given
# when the evaluated bindings are already known (memoization computes them once,
# to key the cache on the evaluated arguments without reducing them twice).
function _rule_expansion(env::Env, scope::Scope, m, subject::Form;
                         subst::Union{Nothing,Dict{Symbol,Form}} = nothing)
    rule, binds = m
    subst === nothing && (subst = _rule_subst(env, scope, rule, binds))
    if rule.implicit
        return (canonicalize(_implicit_form(env, scope, rule.pattern, subject,
                                            binds, subst, rule.held, true)), scope)
    end
    pairs = Pair{Symbol,Form}[]
    for name in rule.params
        haskey(subst, name) || continue
        v = subst[name]
        # A bare-symbol match is not bound in the scope: the substituted body
        # already carries the symbol, and letting it resolve through the caller's
        # scope is what "inserted exactly as-is" means (binding `x` to `x` would
        # make a self-binding, and binding two parameters to each other's symbols
        # would make a resolution cycle).
        (v isa FormScalar && value(v) isa Symbol && is_raw_symbol(value(v))) && continue
        push!(pairs, name => v)
    end
    body = isempty(subst) ? rule.body : _subst_params(rule.body, subst)
    # The rule's entry carries its owner and ACL; recording it on the scope is
    # what lets `owner` and `assume` see the definition being evaluated.
    return (body, scope_extend(scope, pairs; rule = rule))
end

# ---- implicit rules (a `def` with no body) -----------------------------------

# Rebuild the matched form as an implicit rule's replacement. Held parameters are
# frozen exactly as matched; every other part is reduced (a non-held parameter
# through its already-reduced binding, everything else through `air_reduce`). The
# form itself is never re-reduced at `top`, which would match this rule again.
function _implicit_form(env::Env, scope::Scope, pattern::Form, subject::Form,
                        binds, subst, held::Set{Symbol}, top::Bool)
    if pattern isa FormScalar
        s = value(pattern)
        if s isa Symbol && is_wildcard(s) && s != Symbol("?")
            _rest_marker(s) === nothing || return subject
            name = Symbol(String(s)[2:end])
            name in held && return subject
            haskey(subst, name) && return subst[name]
        end
        return top ? subject : air_reduce(env, scope, subject)
    elseif pattern isa FormContainer && subject isa FormContainer
        rebuilt = _implicit_container(env, scope, pattern, subject, binds, subst, held)
        top && return canonicalize(rebuilt)
        return air_reduce(env, scope, canonicalize(rebuilt))
    elseif top
        return subject
    else
        return air_reduce(env, scope, subject)
    end
end

function _implicit_container(env::Env, scope::Scope, pattern::FormContainer,
                             subject::FormContainer, binds, subst, held)
    items = _parse_pattern_items(pattern.seq)
    ridx = findfirst(it -> it.rest !== nothing, items)
    seq = FormValue[]
    map = Pair{Symbol,FormValue}[]
    if ridx === nothing
        for j in eachindex(items)
            push!(seq, _store_form(_implicit_form(env, scope, items[j].form,
                                                 to_form(subject.seq[j]),
                                                 binds, subst, held, false)))
        end
        _implicit_map!(map, env, scope, pattern.map, subject.map, binds, subst, held)
        return FormContainer(FormSeq(seq), FormMap(map))
    end
    kind, name = items[ridx].rest
    before = items[1:(ridx - 1)]
    after = items[(ridx + 1):end]
    nb, na, ns = length(before), length(after), length(subject.seq)
    for j in 1:nb
        push!(seq, _store_form(_implicit_form(env, scope, before[j].form,
                                             to_form(subject.seq[j]),
                                             binds, subst, held, false)))
    end
    # The captured middle: a named rest (`?&xs`, `?*xs`, `??xs`) is spliced back
    # from its binding — raw when held, reduced elementwise otherwise — and an
    # unnamed rest is the subject's middle, reduced.
    if name !== nothing && haskey(binds, name)
        cap = binds[name]
        if cap isa FormContainer
            for e in cap.seq
                push!(seq, _store_form(name in held ? to_form(e) :
                                       air_reduce(env, scope, to_form(e))))
            end
            for (k, v) in cap.map
                push!(map, k => _store_form(name in held ? to_form(v) :
                                            air_reduce(env, scope, to_form(v))))
            end
        end
    else
        for i in (nb + 1):(ns - na)
            push!(seq, _store_form(air_reduce(env, scope, to_form(subject.seq[i]))))
        end
    end
    for j in 1:na
        push!(seq, _store_form(_implicit_form(env, scope, after[j].form,
                                             to_form(subject.seq[ns - na + j]),
                                             binds, subst, held, false)))
    end
    _implicit_map!(map, env, scope, pattern.map, subject.map, binds, subst, held)
    if (kind === :map || kind === :both) && name === nothing
        explicit = _pattern_real_keys(pattern.map)
        for (k, v) in subject.map
            k in explicit && continue
            push!(map, k => _store_form(air_reduce(env, scope, to_form(v))))
        end
    end
    return FormContainer(FormSeq(seq), FormMap(map))
end

# The map entries a pattern states explicitly. An optional key `?k=default` is
# matched as the real key `:k`.
function _pattern_real_keys(pmap)
    keys = Set{Symbol}()
    for (k, _) in pmap
        s = String(k)
        push!(keys, startswith(s, ":?") ? Symbol(":", s[3:end]) : k)
    end
    return keys
end

function _implicit_map!(map, env::Env, scope::Scope, pmap, smap, binds, subst,
                        held::Set{Symbol})
    for (k, v) in pmap
        s = String(k)
        if startswith(s, ":?")
            # An optional key is present or absent in the subject; only a present
            # key is reproduced (the default was never in the form).
            name = Symbol(s[3:end])
            realk = Symbol(":", s[3:end])
            haskey(smap, realk) || continue
            val = name in held ? to_form(smap[realk]) :
                haskey(subst, name) ? subst[name] :
                air_reduce(env, scope, to_form(smap[realk]))
            push!(map, realk => _store_form(val))
        else
            haskey(smap, k) || continue
            push!(map, k => _store_form(_implicit_form(env, scope, to_form(v),
                                                       to_form(smap[k]),
                                                       binds, subst, held, false)))
        end
    end
    return map
end

# A value a context-switching special form has already reduced to a fixed point
# in *its own* scope (`namespace`, `as-user`, `with-env`). Re-reducing it in the
# caller's scope would be wrong — the caller's rules might match a form the inner
# context deliberately left unreduced — so `_finish` returns it as final.
struct _Final
    value::Form
end

# A builtin's result must itself be a fixed point: `(get (' a (inc 1)) 2)` extracts
# the *unheld* form `(inc 1)`, which still has a reduction, so it is reduced here
# (a `hold=true` result is held, and reduces to itself). A builtin that returns its
# input unchanged is left alone, so the reducer never loops on it.
function _finish(env::Env, scope::Scope, x::Form, r::Form)
    c = canonicalize(r)
    _same_value(c, x) && return c
    return _Tail(c, scope)
end

_finish(env::Env, scope::Scope, x::Form, r::_Final) = r.value

# A special form that reduced itself to its final expression hands back a tail
# step; pass it through untouched.
_finish(env::Env, scope::Scope, x::Form, r::_Tail) = r

# ---- hold expansion ----------------------------------------------------------

# Fill in the `preval` holes of a held form, leaving everything else exactly as
# written (a bare symbol stays literal); the result is still a held form. Holes
# are expanded at every depth, including inside nested holds, and computed map
# keys are resolved.
function _expand_hold(env::Env, scope::Scope, x::FormContainer)
    seq = FormValue[x.seq[1]]
    for i in 2:length(x.seq)
        push!(seq, _store_form(_expand_hold_item(env, scope, to_form(x.seq[i]))))
    end
    map = Pair{Symbol,FormValue}[
        _dynamic_key(k, env, scope) =>
            _store_form(_expand_hold_item(env, scope, to_form(v)))
        for (k, v) in x.map]
    new = FormContainer(FormSeq(seq), FormMap(map))
    return _same_value(new, x) ? x : new
end

# One element of a held form: a `(preval e)` hole reduces to the value of `e`;
# every other container is rebuilt with its own holes filled in, at any depth.
function _expand_hold_item(env::Env, scope::Scope, x::Form)
    if x isa FormContainer
        if head_symbol(x) === PREVAL && length(x.seq) == 2 && isempty(x.map)
            return air_reduce(env, scope, to_form(x.seq[2]))
        end
        # `(hold e…)` is the reserved alias; canonicalize it here so a hold's
        # content uses the one hold spelling at every depth.
        head_symbol(x) === HOLD_ALIAS &&
            return _expand_hold(env, scope, _hold_form(x.seq, x.map))
        _is_hold(x) && return _expand_hold(env, scope, x)   # a nested hold
        seq = FormValue[_store_form(_expand_hold_item(env, scope, to_form(v)))
                         for v in x.seq]
        map = Pair{Symbol,FormValue}[
            _dynamic_key(k, env, scope) =>
                _store_form(_expand_hold_item(env, scope, to_form(v)))
            for (k, v) in x.map]
        new = FormContainer(FormSeq(seq), FormMap(map))
        return _same_value(new, x) ? x : new
    end
    return x
end

# Whether `x` is an operator application (infix-canonical or prefix sugar), which
# the reducer handles before user rules so that numeric operands reduce.
_is_operator_call(x::FormContainer, h) =
    infix_operator(x) !== nothing || (h !== nothing && haskey(OPERATORS, h))

# ---- resolving scope bindings before matching --------------------------------

# Whether a scope has any bindings at all (so `_resolve` can be skipped).
_scope_empty(::Nothing) = true
_scope_empty(s::Scope) = isempty(s.names) && _scope_empty(s.parent)

"""
    _resolve(scope, x) -> Form

Replace each raw symbol in `x` bound in `scope` with its value, so a user rule (and
infix/prefix dispatch) matches the *resolved* form: in `(def (d (?f + ?g) ?x) ((d f
x) + (d g x)))` the subform `(d f x)` is seen as `(d <value-of-f> x)`. Inner binders
are respected via `_scope_form`, so a `let`/`loop`/`for` binding position is never
rewritten. Returns `x` itself when nothing changes.
"""
_resolve(scope::Scope, x::Form) = _resolve(scope, x, Set{Symbol}())

function _resolve(scope, x::Form, bound::Set{Symbol})
    if x isa FormScalar
        s = value(x)
        s === NA_SYMBOL && return x   # a fixed point, as in `_air_reduce`
        if s isa Symbol && is_raw_symbol(s) && !(s in bound)
            b = scope_get(scope, s)
            b === nothing || return b.value
        end
        return x
    elseif x isa FormContainer
        # A replacement rule is data: its pattern's parameters shadow any outer
        # binding, and its replacement's free names resolve when the rule is
        # *applied*, not here. Resolving through it would capture an unrelated
        # outer binding of the same name (a loop variable `acc`, say) into the
        # rule's body. A hold and a RETE `rule` are data for the same reason: a
        # hold's bare names stay literal (only its own `~` holes evaluate, when
        # the hold itself reduces), and a RETE rule's code is run later by the
        # logic engine, so an enclosing binding must not be baked into it. The
        # direct occurrences are already shielded by the early returns in
        # `_air_reduce`; this covers the ones nested in an argument position.
        _is_replacement_rule(x) && return x
        h = head_symbol(x)
        (h === HOLD || h === RULE || h === UI_HEAD || h === NS_FN ||
         h === NS_SUB || h === NS_VAL || h === NS_PROXY ||
         h === NS_PROXY_APPLY || h === NS_SUB_LINK || h === NS_ALIAS) && return x
        # `:let` markers in a block body hide their real `let` from
        # `_scope_form`; expand them first so their binders shadow correctly.
        x = _expand_block_markers(x)
        _is_block_form(x) && return _resolve_block(scope, x, bound)
        sc = _scope_form(x)
        inner = sc === nothing ? bound : union(bound, sc.binders)
        skip = sc === nothing ? 0 : sc.skip
        seq = FormValue[]
        for (i, a) in enumerate(x.seq)
            i == skip ? push!(seq, a) :
                push!(seq, _store_form(_resolve(scope, to_form(a), inner)))
        end
        map = Pair{Symbol,FormValue}[]
        for (k, v) in x.map
            push!(map, k => _store_form(_resolve(scope, to_form(v), inner)))
        end
        new = FormContainer(FormSeq(seq), FormMap(map))
        return _same_value(new, x) ? x : new
    else
        return x
    end
end

# A `do`/`tx` block: the `let=` names are visible in the whole block, and a
# clause pattern is data (its wildcards are bound only at match time), so leave
# it raw and shield its names in the clause body.
function _resolve_block(scope::Scope, x::FormContainer, bound::Set{Symbol})
    letbinders = _block_let_binders(x)
    inner = isempty(letbinders) ? bound : union(bound, letbinders)
    start = _block_clause_start(x)
    bodyend = start == 0 ? length(x.seq) : start - 1
    seq = FormValue[x.seq[1]]
    for i in 2:bodyend
        push!(seq, _store_form(_resolve(scope, to_form(x.seq[i]), inner)))
    end
    if start != 0
        for i in start:length(x.seq)
            push!(seq, _store_form(_resolve_block_clause(scope, to_form(x.seq[i]),
                                                         inner)))
        end
    end
    map = Pair{Symbol,FormValue}[]
    for (k, v) in x.map
        val = if k === Symbol(":let")
            _resolve_let_bindings(scope, to_form(v), bound)
        else
            _resolve(scope, to_form(v), inner)
        end
        push!(map, k => _store_form(val))
    end
    return FormContainer(FormSeq(seq), FormMap(map))
end

function _resolve_block_clause(scope, f::Form, bound::Set{Symbol})
    f isa FormContainer || return f
    h = head_symbol(f)
    if h === Symbol("except") || h === Symbol("handle")
        length(f.seq) >= 2 || return f
        pat = to_form(f.seq[2])
        cbound = union(bound, Set(params_of(pat)))
        seq = FormValue[f.seq[1], f.seq[2]]
        for i in 3:length(f.seq)
            push!(seq, _store_form(_resolve(scope, to_form(f.seq[i]), cbound)))
        end
        map = Pair{Symbol,FormValue}[k => v for (k, v) in f.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    elseif h === Symbol("finally")
        seq = FormValue[f.seq[1]]
        for i in 2:length(f.seq)
            push!(seq, _store_form(_resolve(scope, to_form(f.seq[i]), bound)))
        end
        map = Pair{Symbol,FormValue}[k => v for (k, v) in f.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    end
    return f
end

# ---- dispatch ----------------------------------------------------------------

"""
    match_rule_for(env, scope, x; want_held=nothing) -> Union{Tuple{Rule,Dict{Symbol,Form}},Nothing}

The first rule (in insertion order) whose pattern matches `x`, with its bindings.
When `want_held` is `true` only rules that hold some parameter are considered;
when `false` only rules that hold none.
"""
function match_rule_for(env::Env, scope::Scope, x::Form;
                        want_held::Union{Nothing,Bool}=nothing)
    # Namespace rule layers activated by `using` (or by applying a namespace
    # function) are consulted nearest-first, before the global rules.
    if _scope_has_layers(scope)
        for layer in scope_layers(scope)
            m = _match_store(layer, env, scope, x; want_held = want_held)
            m === nothing || return m
        end
    end
    return _match_store(env.rules, env, scope, x; want_held = want_held)
end

# The first rule of one store that matches `x`, honoring the held filter.
function _match_store(store, env::Env, scope::Scope, x::Form;
                      want_held::Union{Nothing,Bool}=nothing)
    for idx in candidate_rule_indices(store, x)
        rule = store.rules[idx]
        # Keep a rule when it satisfies the filter: `want_held=true` keeps the
        # rules that hold a parameter, `false` keeps the ones that hold none.
        (want_held === nothing || isempty(rule.held) != want_held) || continue
        binds = air_match(env, scope, rule.pattern, x, Dict{Symbol,Form}())
        binds === nothing && continue
        # A namespace rule is gated by its entry: calling a `def` needs `exec`,
        # and resolving a `val` needs `read`. Checked only after a successful
        # match, so a denied rule cannot affect an unrelated call.
        _check_rule!(env, rule)
        return (rule, binds)
    end
    return nothing
end

# The rules anchored by any raw symbol in `x`, in insertion order. A rule is
# tried even if it cannot match; the extra candidates fail fast.
function candidate_rule_indices(store, x::Form)
    seen = Set{Int}()
    out = Int[]
    for s in raw_symbols(x)
        for i in get(store.by_symbol, s, Int[])
            i in seen && continue
            push!(seen, i)
            push!(out, i)
        end
    end
    sort!(out)
    return out
end
