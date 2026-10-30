################################################################################
# builtins_control.jl
#
# Special forms for control flow and local binding: `if`/`cond` and `let`. The
# `do` block lives in builtins_block.jl.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# `(if c1 v1 c2 v2 … else)` — like `cond`: the first true condition's value, else
# the trailing form, else `naught`.
function _bi_if(env::Env, scope::Scope, call::FormContainer)
    args = call.seq
    i = 2
    n = length(args)
    while i + 1 <= n
        truthy(air_reduce(env, scope, to_form(args[i]))) &&
            return _Tail(to_form(args[i + 1]), scope)
        i += 2
    end
    i <= n && return _Tail(to_form(args[i]), scope)
    return naught
end
special!(:if, _bi_if)
special!(:cond, _bi_if)

# `(exit [value])` — end the current task with `value` (default `naught`). The
# signal is control flow: no error clause catches it, and the nearest task
# boundary (a `task`, a REPL, a load, an SSH session) turns it into that
# boundary's result. A bare `air_eval` lets it escape to the caller.
special!(:exit, (env, scope, call::FormContainer) -> begin
    _check_options(call, "exit", ())
    length(call.seq) > 2 &&
        throw(AirEvalError("exit takes at most one value"))
    v = length(call.seq) == 2 ? air_reduce(env, scope, to_form(call.seq[2])) : naught
    throw(ExitSignal(v))
end)

# `(let (x=1 y=2) body…)` or `(let ((a=1 b=2) (c=(a + b))) body…)` — evaluate the
# bindings, then substitute each name in the body by its value *before* evaluating
# the body; `let` does not introduce a scope of its own, and the substitution is
# textual, so it reaches inside a quoted form and a computed key. The binding form
# is either one mapping, whose bindings are parallel (every value is evaluated in
# the enclosing scope), or a sequence of mappings that feed one another: earlier
# groups' names are substituted into later groups' value expressions, which are
# then evaluated (unless held) before being visible further on. A `hold=(x y)`
# option names bindings whose values are inserted exactly as written instead of
# evaluated, in every group.
function _bi_let(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 ||
        throw(AirEvalError("let needs a binding form, as in (let (x=1) body)"))
    bform = to_form(call.seq[2])
    held = _held_names(call)
    groups = isequal(bform, naught) ? FormContainer[] : _let_groups(bform)
    groups === nothing && throw(AirEvalError(
        "let bindings must be one key=value mapping or a sequence of them"))
    subst = Dict{Symbol,Form}()
    for g in groups
        # Bindings within a group are parallel: each value expression sees `subst`
        # as it stood before the group. A rebound name therefore refers to its
        # *previous* value inside its own new value — `(let ((x=1) (x=(x + 2))) x)`
        # is `3` — while the new value is what later groups and the body see.
        fresh = Pair{Symbol,Form}[]
        for (k, v) in g.map
            name = _bindname(k)
            _check_not_reserved(name, AirEvalError, "bound")
            raw = isempty(subst) ? to_form(v) : _subst_params(to_form(v), subst)
            push!(fresh, name => (name in held ? raw : air_reduce(env, scope, raw)))
        end
        for (name, val) in fresh
            subst[name] = val
        end
    end
    n = length(call.seq)
    n >= 3 || return naught
    for i in 3:(n - 1)
        body = to_form(call.seq[i])
        isempty(subst) || (body = _subst_params(body, subst))
        air_reduce(env, scope, body)
    end
    body = to_form(call.seq[n])
    isempty(subst) || (body = _subst_params(body, subst))
    return _Tail(body, scope)
end
special!(:let, _bi_let)

# ---- capturing a scope -------------------------------------------------------

# Free variables: raw symbols bound in `scope` that are not in `skip`. This is
# the *candidate* set for a body that will run later; `_capture_form` decides
# which occurrences are actually free.
function _collect_free!(subst, scope::Scope, x::Form, skip)
    if x isa FormScalar
        s = value(x)
        if s isa Symbol && is_raw_symbol(s) && !(s in skip) && !haskey(subst, s)
            b = scope_get(scope, s)
            b === nothing || (subst[s] = b.value)
        end
    elseif x isa FormContainer
        for v in x.seq
            _collect_free!(subst, scope, to_form(v), skip)
        end
        for (_, v) in x.map
            _collect_free!(subst, scope, to_form(v), skip)
        end
    end
    return nothing
end

# Capture the lexical scope for a body that will run later (a task, a delay,
# or an actor step). The substitution uses the same binder rules as `let`
# (`_subst_params`), so a nested `let`, `loop`/`for`, or replacement rule binds
# its own names: `(for (x (1)) (get (delay ((?x -> (+ x 1)) 5))))` is `6`, not
# `2`. Only names that the binder-aware pass leaves free are substituted.
function _capture_form(scope::Scope, x::Form)
    cand = Dict{Symbol,Form}()
    _collect_free!(cand, scope, x, Set{Symbol}())
    isempty(cand) && return x
    return _subst_params(x, cand, Set{Symbol}())
end

# ---- case --------------------------------------------------------------------

# `(case subject (pattern -> replacement) … default)` — dispatch by pattern.
# Each clause is an ordinary replacement rule: it uses the same matcher
# (wildcards, `\` guards, optional keys) and its replacement may use `_` for the
# whole subject. The first matching clause wins; a trailing non-rule form is the
# default, and no match at all yields `naught`. `select` is a synonym.
function _bi_case(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("case needs a subject"))
    subject = air_reduce(env, scope, to_form(call.seq[2]))
    n = length(call.seq)
    for i in 3:n
        clause = to_form(call.seq[i])
        if !_is_replacement_rule(_strip_hold(clause))
            # A non-rule element is the default and must come last.
            i == n || throw(AirEvalError(
                "case: a default clause must be the last element"))
            return _Tail(clause, scope)
        end
        m = _match_replacement(env, scope, clause, subject)
        m === nothing && continue
        binds, replacement, unhold = m
        out = _substitute(replacement, binds)
        unhold && (out = _strip_hold(out))
        return _Tail(out, scope)
    end
    return naught
end
special!(:case, _bi_case)
special!(:select, _bi_case)

# `(and …)` / `(or …)` — short-circuiting; `and` yields the first falsy value or
# the last, `or` the first truthy value or `naught`.
function _bi_and(env::Env, scope::Scope, call::FormContainer)
    n = length(call.seq)
    n >= 2 || return Form(true)
    for i in 2:(n - 1)
        result = air_reduce(env, scope, to_form(call.seq[i]))
        truthy(result) || return result
    end
    return _Tail(to_form(call.seq[n]), scope)
end

function _bi_or(env::Env, scope::Scope, call::FormContainer)
    n = length(call.seq)
    n >= 2 || return naught
    for i in 2:(n - 1)
        result = air_reduce(env, scope, to_form(call.seq[i]))
        truthy(result) && return result
    end
    return _Tail(to_form(call.seq[n]), scope)
end
special!(:and, _bi_and)
special!(:or, _bi_or)

builtin!(:not, (env, scope, args) -> Form(!truthy(_arg(args, 1, "not"))))
builtin!(:xor, (env, scope, args) -> Form(truthy(_arg(args, 1, "xor")) !=
                                           truthy(_arg(args, 2, "xor"))))

# ---- higher-order functions --------------------------------------------------

# `(map f coll depth=n)` — apply `f` to every node at depth `n` (default `1`,
# the collection's elements: both sequence elements and map values), rebuilding
# the structure around the results. `depth=0` applies `f` to `coll` itself, and a
# scalar is its own sole element, so `(map f 3)` is `(f 3)`.
special!(:map, (env, scope, call::FormContainer) -> begin
    length(call.seq) == 3 ||
        throw(AirEvalError("map expects a function and a collection"))
    _check_options(call, "map", (DEPTH_KEY,))
    depth = _depth_opt(env, scope, call, "map", 1)
    f = air_reduce(env, scope, to_form(call.seq[2]))
    coll = air_reduce(env, scope, to_form(call.seq[3]))
    # A table maps over its rows, which stand in for its depth-1 elements;
    # `depth=0` maps the table itself. A deeper level descends into the row maps.
    t = _table_of(coll)
    if t !== nothing && depth > 0
        coll = _rows_view(t)
    end
    return _map_at_depth(x -> _call(env, scope, f, [x]), coll, depth)
end)

# `(nest f n x)` — `f` applied exactly `n` times:
# `(nest (?x -> (2 * x)) 5 1)` is `32`. `(nest-list f n x)` is every value along
# the way, from `x` to the final one (`n + 1` elements).
function _nest_count(form::Form, name::AbstractString)
    k = _leafof(form)
    (k isa Integer && k >= 0) ||
        throw(AirEvalError("$name: the count must be a non-negative integer"))
    return k
end

builtin!(:nest, (env, scope, args) -> begin
    f = _arg(args, 1, "nest"); n = _nest_count(_arg(args, 2, "nest"), "nest")
    x = _arg(args, 3, "nest")
    for _ in 1:n
        x = _call(env, scope, f, [x])
    end
    return x
end)

builtin!(Symbol("nest-list"), (env, scope, args) -> begin
    f = _arg(args, 1, "nest-list")
    n = _nest_count(_arg(args, 2, "nest-list"), "nest-list")
    x = _arg(args, 3, "nest-list")
    out = FormValue[_store_form(x)]
    for _ in 1:n
        x = _call(env, scope, f, [x])
        push!(out, _store_form(x))
    end
    return canonicalize(FormContainer(FormSeq(out), FormMap()))
end)

# `(nest-while f pred x)` — apply `f` while `pred` holds of the current value,
# testing before each application (so a value that already fails is returned
# unchanged). `list=true` returns every value along the way instead of the last.
# A predicate that never fails is stopped by the reduction budget.
special!(Symbol("nest-while"), (env, scope, call::FormContainer) -> begin
    length(call.seq) == 4 ||
        throw(AirEvalError("nest-while expects a function, a predicate, and a value"))
    _check_options(call, "nest-while", (LIST_KEY,))
    args = _call_args(env, scope, call)
    f, pred, x = args[1], args[2], args[3]
    list = haskey(call.map, LIST_KEY) && truthy(to_form(call.map[LIST_KEY]))
    out = FormValue[_store_form(x)]
    while truthy(_call(env, scope, pred, [x]))
        x = _call(env, scope, f, [x])
        push!(out, _store_form(x))
    end
    return list ? canonicalize(FormContainer(FormSeq(out), FormMap())) : x
end)

builtin!(:filter, (env, scope, args) -> begin
    f = _arg(args, 1, "filter"); coll = _rows_or(_arg(args, 2, "filter"))
    return Base.filter(x -> truthy(_call(env, scope, f, [x])), coll)
end)

builtin!(:remove, (env, scope, args) -> begin
    f = _arg(args, 1, "remove"); coll = _rows_or(_arg(args, 2, "remove"))
    return Base.filter(x -> !truthy(_call(env, scope, f, [x])), coll)
end)

# `(reduce f init coll)` — left fold over the sequence elements.
builtin!(:reduce, (env, scope, args) -> begin
    f = _arg(args, 1, "reduce"); acc = _arg(args, 2, "reduce")
    coll = _arg(args, 3, "reduce")
    t = _table_of(coll)
    if t !== nothing
        for i in 1:t.nrows
            acc = _call(env, scope, f, [acc, _table_row(t, i)])
        end
        return acc
    end
    if coll isa FormContainer
        for v in coll.seq
            acc = _call(env, scope, f, [acc, to_form(v)])
        end
    else
        acc = _call(env, scope, f, [acc, coll])
    end
    return acc
end)
builtin!(:fold, (env, scope, args) -> BUILTINS[:reduce].fn(env, scope, args))

# `(mapcat f coll)` — map then join the results.
builtin!(:mapcat, (env, scope, args) -> begin
    f = _arg(args, 1, "mapcat"); coll = _rows_or(_arg(args, 2, "mapcat"))
    mapped = Base.map(x -> _call(env, scope, f, [to_form(x)]), coll)
    return _join_forms(mapped)
end)

# `(each f coll)` — apply `f` to every value for its effect; returns `naught`.
builtin!(:each, (env, scope, args) -> begin
    f = _arg(args, 1, "each"); coll = _arg(args, 2, "each")
    t = _table_of(coll)
    if t !== nothing
        for i in 1:t.nrows
            _call(env, scope, f, [_table_row(t, i)])
        end
        return naught
    end
    if coll isa FormContainer
        for v in values(coll)
            _call(env, scope, f, [to_form(v)])
        end
    end
    return naught
end)

# `(apply f args-form)` — build and reduce `(f …)`.
builtin!(:apply, (env, scope, args) -> begin
    f = _arg(args, 1, "apply"); as = _rows_or(_arg(args, 2, "apply"))
    xs = as isa FormContainer ? Form[to_form(v) for v in as.seq] : Form[as]
    return _call(env, scope, f, xs)
end)

# ---- when / unless -----------------------------------------------------------

function _bi_when(env::Env, scope::Scope, call::FormContainer)
    n = length(call.seq)
    n >= 2 || return naught
    truthy(air_reduce(env, scope, to_form(call.seq[2]))) || return naught
    n >= 3 || return naught
    for i in 3:(n - 1)
        air_reduce(env, scope, to_form(call.seq[i]))
    end
    return _Tail(to_form(call.seq[n]), scope)
end
special!(:when, _bi_when)

function _bi_unless(env::Env, scope::Scope, call::FormContainer)
    n = length(call.seq)
    n >= 2 || return naught
    truthy(air_reduce(env, scope, to_form(call.seq[2]))) && return naught
    n >= 3 || return naught
    for i in 3:(n - 1)
        air_reduce(env, scope, to_form(call.seq[i]))
    end
    return _Tail(to_form(call.seq[n]), scope)
end
special!(:unless, _bi_unless)

# ---- for ---------------------------------------------------------------------

# `(for (x coll … :if cond :let name val) body…)` — a comprehension. Bindings are
# processed left to right (nested); `:if` skips when falsy, `:let` binds a name.
function _bi_for(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("for needs a binding form"))
    bindings = to_form(call.seq[2])
    bindings isa FormContainer || throw(AirEvalError("for needs a binding form"))
    results = FormValue[]
    _for_step(env, scope, bindings.seq, 1, _sx(call.seq, 3:length(call.seq)), results)
    return canonicalize(FormContainer(FormSeq(results), FormMap()))
end
special!(:for, _bi_for)

function _for_step(env::Env, scope::Scope, binds, i::Int, body, results)
    n = length(binds)
    if i > n
        result = naught
        for b in body
            result = air_reduce(env, scope, to_form(b))
        end
        push!(results, _store_form(result))
        return nothing
    end
    head = to_form(binds[i])
    s = _symbolof(head)
    if s === Symbol(":if")
        i + 1 <= n || throw(AirEvalError("for: :if needs a condition"))
        truthy(air_reduce(env, scope, to_form(binds[i + 1]))) || return nothing
        return _for_step(env, scope, binds, i + 2, body, results)
    elseif s === Symbol(":let")
        i + 2 <= n || throw(AirEvalError("for: :let needs a name and a value"))
        name = _leafof(to_form(binds[i + 1]))
        val = air_reduce(env, scope, to_form(binds[i + 2]))
        return _for_step(env, scope_extend(scope, [name => val]), binds, i + 3, body, results)
    else
        i + 1 <= n || throw(AirEvalError("for: a binding needs a collection"))
        name = _leafof(head)
        coll = air_reduce(env, scope, to_form(binds[i + 1]))
        t = _table_of(coll)
        if t !== nothing
            for j in 1:t.nrows
                _for_step(env, scope_extend(scope, [name => _table_row(t, j)]),
                          binds, i + 2, body, results)
            end
            return nothing
        end
        if coll isa FormContainer
            for v in values(coll)
                _for_step(env, scope_extend(scope, [name => to_form(v)]), binds, i + 2, body, results)
            end
        elseif !isequal(coll, naught)
            _for_step(env, scope_extend(scope, [name => coll]), binds, i + 2, body, results)
        end
        return nothing
    end
end

# ---- doseq / dotimes ---------------------------------------------------------

# `(doseq (x coll …) body…)` — run the body for every value, for its effect;
# bindings are processed left to right as nested loops. Returns `naught`.
function _doseq_step(env::Env, scope::Scope, pairs::Vector{Form}, i::Int, body)
    if i > length(pairs)
        for b in body
            air_reduce(env, scope, to_form(b))
        end
        return nothing
    end
    name = _leafof(pairs[i])
    name isa Symbol || throw(AirEvalError("doseq binding names must be symbols"))
    coll = air_reduce(env, scope, pairs[i + 1])
    t = _table_of(coll)
    if t !== nothing
        for j in 1:t.nrows
            _doseq_step(env, scope_extend(scope, [name => _table_row(t, j)]),
                        pairs, i + 2, body)
        end
        return nothing
    end
    for v in _elems(coll)
        _doseq_step(env, scope_extend(scope, [name => to_form(v)]), pairs, i + 2, body)
    end
    return nothing
end

function _bi_doseq(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("doseq needs a binding form"))
    bf = to_form(call.seq[2])
    (bf isa FormContainer && iseven(length(bf.seq))) ||
        throw(AirEvalError("doseq needs name/collection pairs"))
    _doseq_step(env, scope, Form[to_form(v) for v in bf.seq], 1,
                _sx(call.seq, 3:length(call.seq)))
    return naught
end
special!(:doseq, _bi_doseq)

# `(dotimes (i n) body…)` — run the body with `i` bound to 0 … n-1. Returns
# `naught`.
function _bi_dotimes(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("dotimes needs a binding form"))
    bf = to_form(call.seq[2])
    (bf isa FormContainer && length(bf.seq) == 2) ||
        throw(AirEvalError("dotimes needs a name and a count"))
    name = _leafof(to_form(bf.seq[1]))
    name isa Symbol || throw(AirEvalError("dotimes needs a symbol name"))
    n = _leafof(air_reduce(env, scope, to_form(bf.seq[2])))
    n isa Integer || throw(AirEvalError("dotimes needs an integer count"))
    body = _sx(call.seq, 3:length(call.seq))
    for i in 0:(n - 1)
        s = scope_extend(scope, [name => Form(i)])
        for b in body
            air_reduce(env, s, to_form(b))
        end
    end
    return naught
end
special!(:dotimes, _bi_dotimes)

# ---- the `>>` pipeline -------------------------------------------------------
#
# `(x >> step1 step2 …)` evaluates `x`, substitutes the result for every `_` in
# the first raw step, substitutes *that* form for every `_` in the next step, and
# so on. The steps are not evaluated between substitutions — only the final form
# reduces once: `(1 >> (_ + _) (' _))` is `(' (1 + 1))`, not `'2`. `(>> x step…)`
# is prefix sugar for the same form.

# Substitute the placeholder `_` throughout `x` (textually, as `let` does, so it
# reaches inside holds and computed keys).
function _subst_placeholder(x::Form, val::Form)
    if x isa FormScalar
        return value(x) === PLACEHOLDER ? val : x
    elseif x isa FormContainer
        seq = FormValue[_store_form(_subst_placeholder(to_form(v), val)) for v in x.seq]
        map = Pair{Symbol,FormValue}[
            _subst_key(k, e -> _subst_placeholder(e, val)) =>
                _store_form(_subst_placeholder(to_form(v), val))
            for (k, v) in x.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    end
    return x
end

# Whether `x` mentions `_` at all (so a step without one can be rejected).
function _has_placeholder(x::Form)
    x isa FormScalar && return value(x) === PLACEHOLDER
    x isa FormContainer || return false
    any(v -> _has_placeholder(to_form(v)), x.seq) && return true
    any(v -> _has_placeholder(to_form(v)), [v for (_, v) in x.map]) && return true
    for k in keys(x.map)
        s = String(k)
        startswith(s, ":~") || continue
        expr = try
            read_air(s[3:end])
        catch
            continue
        end
        _has_placeholder(expr) && return true
    end
    return false
end

function _run_pipeline(env::Env, scope::Scope, init::Form, steps)
    cur = air_reduce(env, scope, init)
    for s in steps
        step = to_form(s)
        _has_placeholder(step) ||
            throw(AirEvalError("a pipeline step must contain the placeholder _"))
        cur = _subst_placeholder(step, cur)
    end
    return cur
end

special!(PIPELINE, (env, scope, call) -> begin
    length(call.seq) >= 2 || throw(AirEvalError(">> needs an initial value"))
    return _run_pipeline(env, scope, to_form(call.seq[2]),
                         call.seq[3:length(call.seq)])
end)

# ---- thread / hold-thread ----------------------------------------------------
#
# Mathematica-style threading: every *sequential container element* of the form
# is replaced by its k-th element, and the form is repeated over the common
# length: `(thread (f (1 2 3)))` is `((f 1) (f 2) (f 3))`. The head is not
# special — a held form's `'` head is passed through like any other atom — and a
# nested hold is an ordinary form: `(thread (f (' a b)))` is `((f ') (f a) (f b))`.
#
# `hold-thread` strips the argument's root hold before threading and re-holds the
# result; `hold=` (false for `thread`, true for `hold-thread`) selects whether the
# result is held.

function _thread_form(x::FormContainer)
    idx = Int[]
    for (i, v) in enumerate(x.seq)
        to_form(v) isa FormContainer && push!(idx, i)
    end
    isempty(idx) && return x
    n = length(to_form(x.seq[idx[1]]).seq)
    for i in idx
        length(to_form(x.seq[i]).seq) == n ||
            throw(AirEvalError("thread: threaded elements differ in length"))
    end
    out = FormValue[]
    for k in 1:n
        seq = FormValue[]
        for (i, v) in enumerate(x.seq)
            push!(seq, i in idx ? _store_form(to_form(to_form(v).seq[k])) : v)
        end
        push!(out, _store_form(FormContainer(FormSeq(seq), x.map)))
    end
    return FormContainer(FormSeq(out), FormMap())
end

function _bi_thread(env::Env, scope::Scope, call::FormContainer, default_hold::Bool)
    length(call.seq) >= 2 || throw(AirEvalError("thread needs a form"))
    x = air_reduce(env, scope, to_form(call.seq[2]))
    # `hold-thread` is the version for a held argument: the root hold is
    # transparent, and the result is held again below.
    default_hold && (x = _strip_hold(x))
    r = x isa FormContainer ? _thread_form(x) : x
    hold = haskey(call.map, Symbol(":hold")) ? _hold_opt(call) : default_hold
    return hold ? _holdify(r) : r
end

special!(:thread, (env, scope, call) -> _bi_thread(env, scope, call, false))
special!(Symbol("hold-thread"), (env, scope, call) -> _bi_thread(env, scope, call, true))

# ---- part / comp / juxt / complement -----------------------------------------
#
# These HOLD their arguments: `(part f a b)` is `(part :f a b)`, so `f` is captured
# rather than reduced. A `~arg` argument IS evaluated (then held), so its value
# enters the part form. Applying a part form un-holds its arguments:
#     ((part f a b) c d)  =>  (f a b c d)
# Holding is idempotent, so a part form is stable under re-reduction.

const _PART_FORMS = Set([Symbol("part"), Symbol("comp"), Symbol("juxt"), Symbol("complement")])

_is_part_form(x::Form) = x isa FormContainer && head_symbol(x) in _PART_FORMS

# Hold one argument; a `~x` hole is filled in, so its value is captured.
function _part_arg(env::Env, scope::Scope, a::Form)
    _is_hold(a) && return a
    return _holdify(_expand_hold_item(env, scope, a))
end

function _bi_part(env::Env, scope::Scope, call::FormContainer)
    seq = Any[Form(head_symbol(call))]
    for v in _sx(call.seq, 2:length(call.seq))
        push!(seq, _store_form(_part_arg(env, scope, to_form(v))))
    end
    return FormContainer(FormSeq(seq), FormMap())
end
for name in _PART_FORMS
    special!(name, _bi_part)
end

# Apply a part form `(part x1 … xn)` to `args`, un-holding each `xi`.
function _apply_part_form(env::Env, scope::Scope, headf::Form, args::Vector{Form})
    h = air_reduce(env, scope, headf)   # holds the arguments and evaluates any `~`
    h isa FormContainer || return naught
    ch = head_symbol(h)
    ch in _PART_FORMS || return naught
    xs = Form[air_reduce(env, scope, _strip_hold(to_form(v)))
              for v in _sx(h.seq, 2:length(h.seq))]
    if ch === Symbol("part")
        isempty(xs) && return naught
        return _call(env, scope, xs[1], vcat(xs[2:end], args))
    elseif ch === Symbol("comp")
        isempty(xs) && return naught
        acc = _call(env, scope, xs[end], args)
        for i in (length(xs) - 1):-1:1
            acc = _call(env, scope, xs[i], Form[acc])
        end
        return acc
    elseif ch === Symbol("juxt")
        vals = FormValue[_store_form(_call(env, scope, x, args)) for x in xs]
        return canonicalize(FormContainer(FormSeq(vals), FormMap()))
    else   # complement
        isempty(xs) && return naught
        return _call(env, scope, Form(Symbol("not")), Form[_call(env, scope, xs[1], args)])
    end
end

# ---- memoize -----------------------------------------------------------------

# `(memoize f)` — a callable that returns the cached result of `(f args…)`,
# keyed by the function form and the argument form. The cache lives in the
# environment (`Env.memo`), so it is shared by every call in one environment.
# The result is built as a `part` form, which captures `f` by holding it.
const _MEMOIZED = Symbol("memoized")

function _bi_memoize(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 || throw(AirEvalError("memoize expects a function"))
    seq = FormValue[Form(Symbol("part")), Form(_MEMOIZED),
                    _store_form(_part_arg(env, scope, to_form(call.seq[2])))]
    return FormContainer(FormSeq(seq), FormMap())
end
special!(:memoize, _bi_memoize)

builtin!(_MEMOIZED, (env, scope, args) -> begin
    length(args) >= 2 ||
        throw(AirEvalError("a memoized function needs an argument list"))
    f = args[1]
    xs = args[2:end]
    key = (f, Form(PVector{Any}(xs), PDict{Symbol,Any}()))
    haskey(env.memo, key) && return env.memo[key]
    r = _call(env, scope, f, xs)
    env.memo[key] = r
    return r
end)

# ---- the composition stdlib --------------------------------------------------

# Written in air and registered on every environment. A replacement rule in head
# position is a function: `(?args -> x)` accepts any argument form and returns
# `x`.
#
# There is no rule sugar: a replacement rule `(condition -> replacement)` is
# inert data parsed by the `replace` family and applied as a function in head
# position, and a RETE rule is the structured `(rule conditions… instructions…)`
# form parsed by the logic engine. `rule` and `->` are reserved, and a rule form
# reduces to itself outside head position.
const _STDLIB = [
    "(def (identity ?x) x)",
    "(def (constantly ?x) (?args -> x))",
]

function register_stdlib!(env::Env)
    for src in _STDLIB
        air_eval(env, read_air(src))
    end
    return env
end

# ---- eval --------------------------------------------------------------------

# `(eval form)` — evaluate `form` as DATA, in the global scope (no local
# bindings). A held form is un-held first, so `(eval (' 1 + 2))` → `3`; a symbol
# bound to a form evaluates that form.
function _bi_eval(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("eval needs a form"))
    x = air_reduce(env, scope, to_form(call.seq[2]))
    return air_reduce(env, _base_scope(env), _strip_hold(x))
end
special!(:eval, _bi_eval)
