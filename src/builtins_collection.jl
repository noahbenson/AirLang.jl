################################################################################
# builtins_collection.jl
#
# Sequence, map, and set operations. AirDB's verbs are reused where they exist.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

_seqvals(c::FormContainer) = c.seq
_seqvals(x) = PVector{FormValue}([_store_form(x)])

# A collection's values; a scalar is a singleton form (a scalar *is* a singleton).
_elems(c::FormContainer) = c.seq
_elems(x::Form) = Form[x]

# ---- level-aware traversal ---------------------------------------------------
#
# `depth` counts element steps down from a form: `0` is the form itself, `1` its
# elements (sequence elements and map values), `2` its elements' elements, and so
# on. A scalar is its own sole element — the same "a scalar is a singleton"
# convention every collection verb uses — so descending past a scalar stays on the
# scalar, and an extern or volatile value is opaque (it has no elements). The
# structure above the selected level is rebuilt as it was, so the verbs that take
# a `depth=` operate on a level of the tree without disturbing the rest.

# `f` applied to every node at `depth`; the tree is rebuilt around the results.
function _map_at_depth(f, x::Form, depth::Integer)
    depth <= 0 && return f(x)
    if x isa FormContainer
        seq = FormValue[_store_form(_map_at_depth(f, to_form(v), depth - 1))
                        for v in x.seq]
        map = Pair{Symbol,FormValue}[
            k => _store_form(_map_at_depth(f, to_form(v), depth - 1))
            for (k, v) in x.map]
        return FormContainer(FormSeq(seq), FormMap(map))
    elseif x isa FormScalar
        return _map_at_depth(f, x, depth - 1)
    else
        return x
    end
end

# Every node at `depth`, in encounter order (sequence elements, then map values).
function _collect_at_depth!(out::Vector{FormValue}, x::Form, depth::Integer)
    if depth <= 0
        push!(out, _store_form(x))
    elseif x isa FormContainer
        for v in x.seq
            _collect_at_depth!(out, to_form(v), depth - 1)
        end
        for (_, v) in x.map
            _collect_at_depth!(out, to_form(v), depth - 1)
        end
    elseif x isa FormScalar
        _collect_at_depth!(out, x, depth - 1)
    end
    return out
end

# Rebuild `x` with the nodes at `depth` that satisfy `dropf` removed. A removed
# node yields `nothing` (the sentinel), so a node that *is* `naught` is never
# mistaken for a removal. Dropping a scalar at depth > 0 empties its singleton.
function _drop_at_depth(dropf, x::Form, depth::Integer)
    depth <= 0 && return dropf(x) ? nothing : x
    if x isa FormContainer
        seq = FormValue[]
        for v in x.seq
            r = _drop_at_depth(dropf, to_form(v), depth - 1)
            r === nothing || push!(seq, _store_form(r))
        end
        map = Pair{Symbol,FormValue}[]
        for (k, v) in x.map
            r = _drop_at_depth(dropf, to_form(v), depth - 1)
            r === nothing || push!(map, k => _store_form(r))
        end
        return FormContainer(FormSeq(seq), FormMap(map))
    elseif x isa FormScalar
        return _drop_at_depth(dropf, x, depth - 1)
    else
        return x
    end
end

# A new sequence with `vals` inserted so that they begin at position `i`.
function _seq_insert(old, i::Int, vals)
    out = FormValue[]
    n = length(old)
    for j in 1:(i - 1)
        push!(out, old[j])
    end
    for v in vals
        push!(out, v)
    end
    for j in i:n
        push!(out, old[j])
    end
    return out
end

# Concatenate the sequence parts of a form's values into one form.
function _join_forms(x)
    x isa FormContainer || return x
    seq = FormValue[]
    for v in x.seq
        fv = to_form(v)
        if fv isa FormContainer
            for e in fv.seq
                push!(seq, e)
            end
        else
            push!(seq, _store_form(fv))
        end
    end
    return canonicalize(FormContainer(FormSeq(seq), FormMap()))
end

# ---- access ------------------------------------------------------------------

builtin!(:first, (env, scope, args) -> begin
    c = _arg(args, 1, "first")
    (c isa FormContainer && !isempty(c.seq)) || return c
    return to_form(c.seq[1])
end)

builtin!(:last, (env, scope, args) -> begin
    c = _arg(args, 1, "last")
    (c isa FormContainer && !isempty(c.seq)) || return c
    return to_form(c.seq[length(c.seq)])
end)

builtin!(:rest, (env, scope, args) -> begin
    c = _arg(args, 1, "rest")
    c isa FormContainer || return naught
    n = length(c.seq)
    return canonicalize(FormContainer(FormSeq(FormValue[c.seq[i] for i in 2:n]), c.map))
end)

builtin!(:second, (env, scope, args) -> begin
    c = _arg(args, 1, "second")
    (c isa FormContainer && length(c.seq) >= 2) ? to_form(c.seq[2]) : naught
end)
builtin!(:third, (env, scope, args) -> begin
    c = _arg(args, 1, "third")
    (c isa FormContainer && length(c.seq) >= 3) ? to_form(c.seq[3]) : naught
end)

# `(nth coll k)` — the element at integer key `k`. `0` is the whole form and a
# negative key counts from the end. An optional third argument is returned when
# the key is out of range. `hold-nth` indexes the held content instead.
function _nth_call(env::Env, scope::Scope, call::FormContainer, is_hold_fn::Bool)
    strip, held = _hold_mode(call, is_hold_fn)
    args = _call_args(env, scope, call)
    length(args) >= 2 || throw(AirEvalError("nth needs a form and an index"))
    c = strip ? _strip_hold(args[1]) : args[1]
    k = _leafof(args[2])
    k isa Integer || throw(AirEvalError("nth needs an integer index"))
    c isa FormContainer || (c = _as_container(c))
    i = try
        _index_of(k, length(c.seq))
    catch e
        e isa AirEvalError || rethrow()
        length(args) >= 3 && return args[3]
        rethrow()
    end
    r = i === nothing ? c : canonicalize(to_form(c.seq[i]))
    return held ? _ensure_hold(r) : r
end
_hold_pair!(:nth, _nth_call)

# `(insert coll i x)` — a copy of `coll` with `x` inserted before position `i`
# (1-based; `i = n + 1` appends). `with` only appends, so this is the arbitrary
# index case.
builtin!(:insert, (env, scope, args) -> begin
    c = _arg(args, 1, "insert"); i = _leafof(_arg(args, 2, "insert"))
    x = _arg(args, 3, "insert")
    (c isa FormContainer && i isa Integer) || return _mk_prefix(:insert, args)
    n = length(c.seq)
    1 <= i <= n + 1 || throw(AirEvalError("insert: index $i is out of range 1..$(n + 1)"))
    vals = FormValue[]
    for j in 1:(i - 1); push!(vals, c.seq[j]); end
    push!(vals, _store_form(x))
    for j in i:n; push!(vals, c.seq[j]); end
    return canonicalize(FormContainer(FormSeq(vals), FormMap()))
end)

# `(push-in form pos values…)` — insert values beginning at integer position
# `pos` (the next position after the last element appends):
# `(push-in (1 2 3 4) 2 99)` is `(1 99 2 3 4)`.
function _push_in_call(env::Env, scope::Scope, call::FormContainer,
                       is_hold_fn::Bool)
    strip, held = _hold_mode(call, is_hold_fn)
    args = _call_args(env, scope, call)
    length(args) >= 3 ||
        throw(AirEvalError("push-in needs a form, a position, and a value"))
    c = _as_container(strip ? _strip_hold(args[1]) : args[1])
    pos = _leafof(args[2])
    pos isa Integer || throw(AirEvalError("push-in needs an integer position"))
    i = _index_of(pos, length(c.seq); append = true)
    i === nothing &&
        throw(AirEvalError("push-in: position 0 is not an insertion point"))
    vals = [_store_form(strip ? _strip_hold(x) : x) for x in args[3:end]]
    r = canonicalize(FormContainer(FormSeq(_seq_insert(c.seq, i, vals)), c.map))
    return held ? _ensure_hold(r) : r
end
_hold_pair!(Symbol("push-in"), _push_in_call)

# `(deep-map f x)` — `f` applied to every node bottom-up (AirDB's `deep_map`).
builtin!(Symbol("deep-map"), (env, scope, args) -> begin
    f = _arg(args, 1, "deep-map"); c = _arg(args, 2, "deep-map")
    return deep_map(x -> _call(env, scope, f, [x]), c)
end)

# `(map-keys f m)` — rebuild `m` with each key `k` replaced by `(f k)` (AirDB's
# `map_keys`); the key function receives a keyword and must return a symbol.
builtin!(Symbol("map-keys"), (env, scope, args) -> begin
    f = _arg(args, 1, "map-keys"); c = _arg(args, 2, "map-keys")
    return map_keys(k -> begin
        s = _leafof(_call(env, scope, f, [Form(k)]))
        s isa Symbol ? (is_keyword(s) ? s : Symbol(":" * String(s))) : k
    end, c)
end)

builtin!(:take, (env, scope, args) -> begin
    n = _leafof(_arg(args, 1, "take")); c = _arg(args, 2, "take")
    c isa FormContainer || return c
    m = min(n, length(c.seq))
    return canonicalize(FormContainer(FormSeq(FormValue[c.seq[i] for i in 1:m]), c.map))
end)

builtin!(Symbol("drop-first"), (env, scope, args) -> begin
    n = _leafof(_arg(args, 1, "drop-first")); c = _arg(args, 2, "drop-first")
    c isa FormContainer || return c
    m = length(c.seq)
    return canonicalize(FormContainer(FormSeq(FormValue[c.seq[i] for i in (n + 1):m]), c.map))
end)

builtin!(Symbol("take-last"), (env, scope, args) -> begin
    n = _leafof(_arg(args, 1, "take-last")); c = _arg(args, 2, "take-last")
    c isa FormContainer || return c
    m = length(c.seq)
    return canonicalize(FormContainer(FormSeq(FormValue[c.seq[i] for i in max(1, m - n + 1):m]), c.map))
end)

builtin!(Symbol("drop-last"), (env, scope, args) -> begin
    n = _leafof(_arg(args, 1, "drop-last")); c = _arg(args, 2, "drop-last")
    c isa FormContainer || return c
    m = length(c.seq)
    return canonicalize(FormContainer(FormSeq(FormValue[c.seq[i] for i in 1:max(0, m - n)]), c.map))
end)

builtin!(Symbol("take-while"), (env, scope, args) -> begin
    f = _arg(args, 1, "take-while"); c = _arg(args, 2, "take-while")
    c isa FormContainer || return c
    out = FormValue[]
    for v in c.seq
        truthy(_call(env, scope, f, [to_form(v)])) || break
        push!(out, v)
    end
    return canonicalize(FormContainer(FormSeq(out), c.map))
end)

builtin!(Symbol("drop-while"), (env, scope, args) -> begin
    f = _arg(args, 1, "drop-while"); c = _arg(args, 2, "drop-while")
    c isa FormContainer || return c
    out = FormValue[]
    dropping = true
    for v in c.seq
        if dropping && truthy(_call(env, scope, f, [to_form(v)]))
            continue
        end
        dropping = false
        push!(out, v)
    end
    return canonicalize(FormContainer(FormSeq(out), c.map))
end)

builtin!(Symbol("split-at"), (env, scope, args) -> begin
    n = _leafof(_arg(args, 1, "split-at")); c = _arg(args, 2, "split-at")
    c isa FormContainer || return c
    m = length(c.seq)
    k = clamp(n, 0, m)
    a = canonicalize(FormContainer(FormSeq(FormValue[c.seq[i] for i in 1:k]), FormMap()))
    b = canonicalize(FormContainer(FormSeq(FormValue[c.seq[i] for i in (k + 1):m]), FormMap()))
    return FormContainer(FormSeq(FormValue[_store_form(a), _store_form(b)]), FormMap())
end)

# ---- combining / ordering ----------------------------------------------------

# `(join a b … k=v…)` — concatenate the sequence parts and union the maps:
# `(join (1 2 3) (4 5 6 a=10))` is `(1 2 3 4 5 6 a=10)`. Map entries written on
# the `join` call itself are merged last (so `(join () a=10)` is `(a=10)`).
function _join_call(env::Env, scope::Scope, call::FormContainer, is_hold_fn::Bool)
    strip, held = _hold_mode(call, is_hold_fn)
    args = _call_args(env, scope, call)
    strip && (args = Form[_strip_hold(a) for a in args])
    result = isempty(args) ? FormContainer(FormSeq(FormValue[]), FormMap()) :
                             _as_container(args[1])
    for a in args[2:end]
        result = _join_two(result, _as_container(a))
    end
    for (k, v) in call.map
        vv = to_form(v)
        vv = strip ? _strip_hold(vv) : air_reduce(env, scope, vv)
        result = FormContainer(result.seq,
                               push(result.map, _dynamic_key(k, env, scope) =>
                                    _store_form(vv)))
    end
    result = canonicalize(result)
    return held ? _ensure_hold(result) : result
end
_hold_pair!(:join, _join_call)

function _join_two(a::FormContainer, b::FormContainer)
    map = a.map
    for (k, v) in b.map
        map = push(map, k => v)
    end
    return FormContainer(FormSeq(FormValue[a.seq..., b.seq...]), map)
end

# `(join-in form pos other)` — splice `other`'s sequence elements into `form` at
# `pos` and merge its map entries.
function _join_in_call(env::Env, scope::Scope, call::FormContainer,
                       is_hold_fn::Bool)
    strip, held = _hold_mode(call, is_hold_fn)
    args = _call_args(env, scope, call)
    length(args) == 3 || throw(AirEvalError("join-in needs a form, a position, and a form"))
    c = _as_container(strip ? _strip_hold(args[1]) : args[1])
    pos = _leafof(args[2])
    pos isa Integer || throw(AirEvalError("join-in needs an integer position"))
    o = _as_container(strip ? _strip_hold(args[3]) : args[3])
    i = _index_of(pos, length(c.seq); append = true)
    i === nothing && throw(AirEvalError("join-in: position 0 is not an insertion point"))
    seq = _seq_insert(c.seq, i, o.seq)
    map = c.map
    for (k, v) in o.map
        map = push(map, k => v)
    end
    r = canonicalize(FormContainer(FormSeq(seq), map))
    return held ? _ensure_hold(r) : r
end
_hold_pair!(Symbol("join-in"), _join_in_call)

builtin!(:reverse, (env, scope, args) -> begin
    c = _arg(args, 1, "reverse")
    c isa FormContainer || return c
    n = length(c.seq)
    return FormContainer(FormSeq(FormValue[c.seq[i] for i in n:-1:1]), c.map)
end)

function _form_lt(a, b)
    la, lb = _leafof(to_form(a)), _leafof(to_form(b))
    # Complex values have no order; they sort by their printed spelling, as any
    # other unorderable pair does.
    (la isa Real && lb isa Real) ? la < lb : string(la) < string(lb)
end

builtin!(:sort, (env, scope, args) -> begin
    c = _arg(args, 1, "sort")
    c isa FormContainer || return c
    vals = sort(collect(c.seq); lt = _form_lt)
    return FormContainer(FormSeq(FormValue[vals...]), FormMap())
end)

builtin!(Symbol("sort-by"), (env, scope, args) -> begin
    f = _arg(args, 1, "sort-by"); c = _arg(args, 2, "sort-by")
    c isa FormContainer || return c
    vals = sort(collect(c.seq); by = x -> air_string(_call(env, scope, f, [to_form(x)])))
    return FormContainer(FormSeq(FormValue[vals...]), FormMap())
end)

builtin!(:distinct, (env, scope, args) -> begin
    c = _arg(args, 1, "distinct")
    c isa FormContainer || return c
    out = FormValue[]
    seen = Set{Form}()
    for v in c.seq
        fv = to_form(v)
        (fv in seen) && continue
        push!(seen, fv); push!(out, v)
    end
    return canonicalize(FormContainer(FormSeq(out), FormMap()))
end)

builtin!(:dedupe, (env, scope, args) -> begin
    c = _arg(args, 1, "dedupe")
    c isa FormContainer || return c
    out = FormValue[]
    prev = nothing
    for (i, v) in enumerate(c.seq)
        fv = to_form(v)
        (i > 1 && isequal(fv, prev)) && continue
        push!(out, v); prev = fv
    end
    return canonicalize(FormContainer(FormSeq(out), FormMap()))
end)

# `(shuffle coll)` — the sequence elements in a random order; map entries are
# kept. A scalar is a singleton and `naught` is empty, so both are unchanged.
builtin!(:shuffle, (env, scope, args) -> begin
    c = _arg(args, 1, "shuffle")
    c isa FormContainer || return c
    vals = shuffle!(collect(c.seq))
    return canonicalize(FormContainer(FormSeq(FormValue[vals...]), c.map))
end)

builtin!(:partition, (env, scope, args) -> begin
    n = _leafof(_arg(args, 1, "partition")); c = _arg(args, 2, "partition")
    (c isa FormContainer && n isa Integer && n > 0) || return c
    chunks = FormValue[]
    for i in 1:n:length(c.seq)
        chunk = canonicalize(FormContainer(
            FormSeq(FormValue[c.seq[j] for j in i:min(i + n - 1, length(c.seq))]),
            FormMap()))
        push!(chunks, _store_form(chunk))
    end
    return FormContainer(FormSeq(chunks), FormMap())
end)

# `(partition-by f coll)` — group ADJACENT elements by the key `(f x)`; a new
# group begins whenever the key changes. `(partition-by odd? (1 3 2 4 5))`
# → `((1 3) (2 4) (5))`. Unlike `partition`, groups are of variable size.
# `split-by` is the Mathematica name for the same operation.
function _bi_partition_by(env, scope, args)
    f = _arg(args, 1, "partition-by"); c = _arg(args, 2, "partition-by")
    c isa FormContainer || return c
    groups = FormValue[]
    cur = FormValue[]
    prev = nothing
    for (i, v) in enumerate(c.seq)
        fv = to_form(v)
        k = _call(env, scope, f, [fv])
        if i > 1 && isequal(k, prev)
            push!(cur, v)
        else
            isempty(cur) || push!(groups, _store_form(canonicalize(
                FormContainer(FormSeq(cur), FormMap()))))
            cur = FormValue[v]
        end
        prev = k
    end
    isempty(cur) || push!(groups, _store_form(canonicalize(
        FormContainer(FormSeq(cur), FormMap()))))
    return canonicalize(FormContainer(FormSeq(groups), FormMap()))
end
builtin!(Symbol("partition-by"), _bi_partition_by)
builtin!(Symbol("split-by"), _bi_partition_by)

# `(gather-by f coll)` — group ALL elements whose keys `(f x)` are equal, in the
# order the keys first appear: `(gather-by odd? (1 2 3 4))` is `((1 3) (2 4))`.
# Compare `split-by`, which groups only adjacent elements, and `group-by`, which
# returns a map keyed by the printed key.
builtin!(Symbol("gather-by"), (env, scope, args) -> begin
    f = _arg(args, 1, "gather-by"); c = _arg(args, 2, "gather-by")
    c isa FormContainer || return c
    at = Dict{Form,Int}()
    groups = Vector{FormValue}[]
    for v in c.seq
        k = _call(env, scope, f, [to_form(v)])
        i = get(at, k, 0)
        if i == 0
            push!(groups, FormValue[v]); at[k] = length(groups)
        else
            push!(groups[i], v)
        end
    end
    return canonicalize(FormContainer(FormSeq(FormValue[
        _store_form(canonicalize(FormContainer(FormSeq(g), FormMap())))
        for g in groups]), FormMap()))
end)

# ---- pattern selection -------------------------------------------------------

# The result of testing the clauses against `subject`: `nothing` when none
# matches, otherwise the matched element as it should appear — the element itself
# for a bare pattern clause, or the substituted replacement for a replacement rule
# `(pattern -> replacement)`. Clauses are data: they are not reduced, and a rule's
# `unhold=true` inserts its replacement unheld. `case` and `cases` share this.
# A bare pattern clause also accepts the rule-level guard spelling `(p \ g)`: the
# `\` splits off and tests the whole element (`(?x \ even?)` matches an even
# element), which is how a predicate on a scalar element is written.
function _first_case_match(env::Env, scope::Scope, clauses, subject::Form)
    for clause in clauses
        if _is_replacement_rule(_strip_hold(clause))
            m = _match_replacement(env, scope, clause, subject)
            m === nothing && continue
            binds, replacement, unhold = m
            out = _substitute(replacement, binds)
            return unhold ? _strip_hold(out) : out
        end
        pattern, guard = _split_rule_guard(clause)
        binds = air_match(env, scope, pattern, subject, Dict{Symbol,Form}())
        binds === nothing && continue
        if guard !== nothing
            gscope = scope_extend(scope, [n => v for (n, v) in binds])
            _cond_true(air_reduce(env, gscope, guard)) || continue
        end
        return subject
    end
    return nothing
end

# The clauses of a `cases`/`drop-cases` call (everything after the collection).
_case_clauses(call::FormContainer) =
    Form[to_form(v) for v in _sx(call.seq, 3:length(call.seq))]

# `(cases coll clause… depth=n)` — every element at depth `n` (default `1`, the
# collection's elements) that matches a clause, in encounter order. A bare pattern
# clause keeps the element as it is; a replacement-rule clause replaces it.
# Non-matching elements are omitted, and there is no default clause (unlike
# `case`), because a bare pattern is indistinguishable from one.
function _bi_cases(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("cases needs a collection"))
    _check_options(call, "cases", (DEPTH_KEY,))
    depth = _depth_opt(env, scope, call, "cases", 1)
    subject = air_reduce(env, scope, to_form(call.seq[2]))
    clauses = _case_clauses(call)
    nodes = FormValue[]
    _collect_at_depth!(nodes, subject, depth)
    out = FormValue[]
    for v in nodes
        r = _first_case_match(env, scope, clauses, to_form(v))
        r === nothing || push!(out, _store_form(r))
    end
    return canonicalize(FormContainer(FormSeq(out), FormMap()))
end
special!(Symbol("cases"), _bi_cases)

# `(drop-cases coll clause… depth=n)` — the elements at depth `n` (default `1`)
# that match no clause, with the structure above them rebuilt. A clause may be a
# bare pattern or a replacement rule; only its pattern and guard matter.
function _bi_drop_cases(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("drop-cases needs a collection"))
    _check_options(call, "drop-cases", (DEPTH_KEY,))
    depth = _depth_opt(env, scope, call, "drop-cases", 1)
    subject = air_reduce(env, scope, to_form(call.seq[2]))
    clauses = _case_clauses(call)
    isempty(clauses) && return subject
    r = _drop_at_depth(x -> _first_case_match(env, scope, clauses, x) !== nothing,
                       subject, depth)
    return canonicalize(r === nothing ? naught : r)
end
special!(Symbol("drop-cases"), _bi_drop_cases)

# Whether `matchf` holds of a node or of anything below it: the same walk as
# `replace-all` (sequence elements, then map values; externs are opaque).
function _any_match_walk(matchf, x::Form)
    matchf(x) && return true
    if x isa FormContainer
        for v in x.seq
            _any_match_walk(matchf, to_form(v)) && return true
        end
        for (_, v) in x.map
            _any_match_walk(matchf, to_form(v)) && return true
        end
    end
    return false
end

# `(matches-any? subject clause…)` — true when the subject itself or any subpart
# anywhere in the tree matches a clause. Clauses are as in `cases`: a bare
# pattern (with an optional rule-level `\` guard) or a replacement rule, of which
# only the pattern and guard matter.
function _bi_matches_any(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 3 ||
        throw(AirEvalError("matches-any? needs a subject and a pattern"))
    _check_options(call, "matches-any?", ())
    subject = air_reduce(env, scope, to_form(call.seq[2]))
    clauses = Form[to_form(v) for v in _sx(call.seq, 3:length(call.seq))]
    return _bool(_any_match_walk(
        x -> _first_case_match(env, scope, clauses, x) !== nothing, subject))
end
special!(Symbol("matches-any?"), _bi_matches_any)

# ---- locating (`where`) ------------------------------------------------------

# The paths of every node at `depth` equal to `obj`, in encounter order. A path
# is a vector of keys: an integer for a sequence element, a keyword for a map
# value; a scalar's singleton step uses the index `1`, as `cases` does. An extern
# or volatile is opaque.
function _where_paths_at!(out::Vector{Vector{Any}}, x::Form, obj::Form,
                          depth::Integer, path::Vector{Any})
    if depth <= 0
        isequal(x, obj) && push!(out, copy(path))
    elseif x isa FormContainer
        for (k, v) in pairs(x)
            push!(path, k)
            _where_paths_at!(out, to_form(v), obj, depth - 1, path)
            pop!(path)
        end
    elseif x isa FormScalar
        push!(path, 1)
        _where_paths_at!(out, x, obj, depth - 1, path)
        pop!(path)
    end
    return out
end

# Every path at any depth whose node equals `obj`, in pre-order. The root is not
# reported (it has no path), and the walk stops at a scalar: its singleton
# descent would never end, so each node is reported once.
function _where_all_paths!(out::Vector{Vector{Any}}, x::Form, obj::Form,
                           path::Vector{Any})
    if x isa FormContainer
        for (k, v) in pairs(x)
            push!(path, k)
            c = to_form(v)
            isequal(c, obj) && push!(out, copy(path))
            _where_all_paths!(out, c, obj, path)
            pop!(path)
        end
    end
    return out
end

# A path (a vector of keys) as a form, always a list: `(2)`, `(:a 2)`.
function _path_form(path::Vector{Any})
    return FormContainer(
        FormSeq(FormValue[_store_form(Form(k)) for k in path]), FormMap())
end

# `(where coll obj depth=d)` — the locations of every element of `coll` that
# equals `obj`. With no `depth`, the depth is 1 and the result is the bare keys
# of the matches in encounter order: `(where (:a :b :b) :b)` is `(2 3)`. With an
# explicit integer depth `n`, the result has one path per occurrence, each a
# list of `n` keys: `(where (a=(1 2) b=(2 3)) 2 depth=2)` is `((:a 2) (:b 1))`
# (map order is not preserved). Depth `0` names the subject itself, whose sole
# key is the whole-form key `0`, so the result is `((0))` when the subject
# equals `obj` and `()` otherwise. With `depth=:all`, every occurrence at any
# depth is reported, each as its own path, so the paths may have different
# lengths. No match is `()`. The results are plain lists of plain paths, which
# splice into `get`, `with`, and `update-in`.
function _bi_where(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 3 ||
        throw(AirEvalError("where takes a collection and an object"))
    _check_options(call, "where", (DEPTH_KEY,))
    subject = air_reduce(env, scope, to_form(call.seq[2]))
    obj = air_reduce(env, scope, to_form(call.seq[3]))
    if !haskey(call.map, DEPTH_KEY)
        paths = Vector{Any}[]
        _where_paths_at!(paths, subject, obj, 1, Any[])
        isempty(paths) && return naught
        return _ns_form(Form[Form(p[1]) for p in paths])
    end
    l = _leafof(air_reduce(env, scope, to_form(call.map[DEPTH_KEY])))
    if l === Symbol(":all")
        paths = Vector{Any}[]
        _where_all_paths!(paths, subject, obj, Any[])
        isempty(paths) && return naught
        return _ns_form(Form[_path_form(p) for p in paths])
    end
    (l isa Integer && l >= 0) || throw(AirEvalError(
        "where: depth must be a non-negative integer or :all"))
    depth = _as_int(l, "where: depth")
    depth == 0 && return isequal(subject, obj) ?
        _ns_form(Form[_path_form(Any[0])]) : naught
    paths = Vector{Any}[]
    _where_paths_at!(paths, subject, obj, depth, Any[])
    isempty(paths) && return naught
    return _ns_form(Form[_path_form(p) for p in paths])
end
special!(:where, _bi_where)

# `where-all` was folded into `where` with `depth=:all`.
special!(Symbol("where-all"), (env, scope, call) -> throw(AirEvalError(
    "where-all has been removed; write (where coll obj depth=:all)")))

# ---- generation / aggregation ------------------------------------------------

builtin!(:range, (env, scope, args) -> begin
    ls = [_leafof(a) for a in args]
    all(l -> l isa Number, ls) || return _mk_prefix(:range, args)
    r = length(ls) == 1 ? (0:(ls[1] - 1)) :
        length(ls) == 2 ? (ls[1]:(ls[2] - 1)) : (ls[1]:ls[3]:(ls[2] - 1))
    return FormContainer(FormSeq(FormValue[Form(i) for i in r]), FormMap())
end)

builtin!(:repeat, (env, scope, args) -> begin
    n = _leafof(_arg(args, 1, "repeat")); x = _arg(args, 2, "repeat")
    n isa Integer || return _mk_prefix(:repeat, args)
    return FormContainer(FormSeq(FormValue[_store_form(x) for _ in 1:n]), FormMap())
end)

# A collection's element count; a scalar is a singleton (so `(count ?g)` is 1 for
# a one-element group), and `naught` is empty.
builtin!(:count, (env, scope, args) -> begin
    c = _arg(args, 1, "count")
    c isa StreamForm && return Form(_stream_count(env, c))
    c isa FormContainer && return Form(length(c.seq))
    return Form(isequal(c, naught) ? 0 : 1)
end)

function _fold_numeric(name, c, combine, init)
    c isa FormContainer || return c
    acc = init
    for v in c.seq
        l = _leafof(to_form(v))
        l isa Number || return _mk_prefix(name, [c])
        acc = combine(acc, l)
    end
    return to_form(acc)
end
builtin!(:sum, (env, scope, args) -> _fold_numeric(:sum, _arg(args, 1, "sum"), +, 0))
builtin!(:product, (env, scope, args) -> _fold_numeric(:product, _arg(args, 1, "product"), *, 1))

# The numeric leaves of a collection (a scalar is a singleton, like the set ops),
# or `nothing` when some element is not a number.
function _numeric_leaves(c::Form)
    xs = c isa FormContainer ? c.seq : FormValue[_store_form(c)]
    ls = [_leafof(to_form(v)) for v in xs]
    all(l -> l isa Number, ls) || return nothing
    return ls
end

builtin!(:mean, (env, scope, args) -> begin
    c = _arg(args, 1, "mean")
    ls = _numeric_leaves(c)
    ls === nothing && return _mk_prefix(:mean, [c])
    isempty(ls) && return naught
    return to_form(sum(ls) / length(ls))
end)

builtin!(:median, (env, scope, args) -> begin
    c = _arg(args, 1, "median")
    ls = _numeric_leaves(c)
    ls === nothing && return _mk_prefix(:median, [c])
    isempty(ls) && return naught
    s = sort(ls); n = length(s)
    return to_form(isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
end)

# `(variance coll)` — the *sample* variance (denominator `n - 1`) of the numeric
# elements; `naught` when fewer than two are present (as for an empty `mean`).
# Non-numeric input is left as the unreduced prefix form, like `mean`.
builtin!(:variance, (env, scope, args) -> begin
    c = _arg(args, 1, "variance")
    ls = _numeric_leaves(c)
    ls === nothing && return _mk_prefix(:variance, [c])
    length(ls) < 2 && return naught
    m = sum(ls) / length(ls)
    return to_form(sum((x - m)^2 for x in ls) / (length(ls) - 1))
end)

# ---- maps --------------------------------------------------------------------

builtin!(:keys, (env, scope, args) -> begin
    c = _arg(args, 1, "keys")
    c isa FormContainer || return naught
    return FormContainer(FormSeq(FormValue[Form(k) for k in keys(c)]), FormMap())
end)

builtin!(:vals, (env, scope, args) -> begin
    c = _arg(args, 1, "vals")
    c isa FormContainer || return naught
    return FormContainer(FormSeq(FormValue[_store_form(to_form(v)) for v in values(c)]),
                         FormMap())
end)

# `update` is a special form (see `logic.jl`): it reads its arguments lazily so
# it can reject the retired logic-set form.

builtin!(:zipmap, (env, scope, args) -> begin
    ks = _arg(args, 1, "zipmap"); vs = _arg(args, 2, "zipmap")
    (ks isa FormContainer && vs isa FormContainer) || return naught
    pairs = Pair{Symbol,Any}[Symbol(":" * string(_leafof(to_form(k)))) => to_form(v)
                             for (k, v) in zip(ks.seq, vs.seq)]
    return Form(PVector{Any}(), PDict{Symbol,Any}(pairs...))
end)

builtin!(:invert, (env, scope, args) -> begin
    c = _arg(args, 1, "invert")
    c isa FormContainer || return c
    pairs = Pair{Symbol,Any}[Symbol(":" * string(_leafof(to_form(v)))) => Form(k) for (k, v) in c.map]
    return Form(PVector{Any}(), PDict{Symbol,Any}(pairs...))
end)

builtin!(Symbol("frequencies"), (env, scope, args) -> begin
    c = _arg(args, 1, "frequencies")
    c isa FormContainer || return naught
    counts = Pair{Symbol,Any}[]
    seen = Dict{Form,Int}()
    for v in c.seq
        fv = to_form(v)
        seen[fv] = get(seen, fv, 0) + 1
    end
    for (fv, n) in seen
        push!(counts, Symbol(":" * string(_leafof(fv))) => Form(n))
    end
    return Form(PVector{Any}(), PDict{Symbol,Any}(counts...))
end)

builtin!(Symbol("group-by"), (env, scope, args) -> begin
    f = _arg(args, 1, "group-by"); c = _arg(args, 2, "group-by")
    c isa FormContainer || return naught
    groups = Dict{Symbol,Vector{FormValue}}()
    order = Symbol[]
    for v in c.seq
        key = Symbol(":" * string(_leafof(_call(env, scope, f, [to_form(v)]))))
        if !haskey(groups, key)
            groups[key] = FormValue[]; push!(order, key)
        end
        push!(groups[key], v)
    end
    pairs = Pair{Symbol,Any}[k => FormContainer(FormSeq(groups[k]), FormMap()) for k in order]
    return Form(PVector{Any}(), PDict{Symbol,Any}(pairs...))
end)

# ---- with / wout -------------------------------------------------------------

# A map key written `~expr=value` is stored as `:~<printed expr>`; the expression
# is evaluated here and must yield a keyword, which becomes the actual key:
# `(form ~(keyword (name ?x))=10)` → `(form x=10)`.
function _dynamic_key(k::Symbol, env::Env, scope::Scope)
    s = String(k)
    startswith(s, ":~") || return k
    v = _leafof(air_reduce(env, scope, read_air(s[3:end])))
    (v isa Symbol && is_keyword(v)) ||
        throw(AirEvalError("a dynamic key (~$(s[3:end])=…) must evaluate to a keyword"))
    return v
end

# A path argument: a container is a sequence of keys (a nested path); anything
# else is a single key. Keys are evaluated, so `~k` and computed keywords work.
function _path_keys(env::Env, scope::Scope, x::Form)
    if x isa FormContainer
        return Any[_get_key(air_reduce(env, scope, to_form(v))) for v in x.seq]
    end
    return Any[_get_key(air_reduce(env, scope, x))]
end

# The container a setter works on: a container is used as it is, `naught` is the
# empty form, and any other scalar is promoted to a one-element form (so
# `(with 2 :a 10)` is `(2 a=10)`).
function _as_container(base::Form)
    base isa FormContainer && return base
    isequal(base, naught) && return FormContainer(FormSeq(FormValue[]), FormMap())
    return FormContainer(FormSeq(FormValue[_store_form(base)]), FormMap())
end

# The subform at key `k`, or `naught` when the key is missing.
function _at_key(c::FormContainer, k)
    if k isa Integer
        k == 0 && return c
        i = _index_or_nothing(k, length(c.seq))
        i === nothing && return naught
        return canonicalize(to_form(c.seq[i]))
    elseif k isa Symbol
        return haskey(c, k) ? canonicalize(to_form(c[k])) : naught
    end
    return naught
end

# `_index_of`, but a missing key yields `nothing` instead of raising.
function _index_or_nothing(k::Integer, n::Integer)
    return try
        _index_of(k, n)
    catch e
        e isa AirEvalError || rethrow()
        nothing
    end
end

# Set key `k` in the container to `val`. An integer index can append (`n + 1`);
# key `0` replaces the whole form. A negative index counts from the end.
function _set_key(c::FormContainer, k, val::Form)
    if k isa Integer
        i = _index_of(k, length(c.seq); append = true)
        i === nothing && return val
        n = length(c.seq)
        if i == n + 1
            return FormContainer(FormSeq(push(FormValue[c.seq...], _store_form(val))), c.map)
        end
        seq = FormValue[j == i ? _store_form(val) : c.seq[j] for j in 1:n]
        return FormContainer(FormSeq(seq), c.map)
    elseif k isa Symbol
        return FormContainer(c.seq, push(c.map, k => _store_form(val)))
    end
    throw(AirEvalError("a key must be an integer or a keyword, not $(air_string(Form(k)))"))
end

# Remove key `k` from the container. A missing key is a no-op; key `0` removes the
# whole form.
function _delete_key(c::FormContainer, k)
    if k isa Integer
        i = _index_of(k, length(c.seq))
        i === nothing && return naught
        n = length(c.seq)
        return canonicalize(FormContainer(FormSeq(FormValue[c.seq[j] for j in 1:n if j != i]),
                                          c.map))
    elseif k isa Symbol
        return FormContainer(c.seq, delete(c.map, k))
    end
    return c
end

# Set the subform at `path` to `val`, creating intermediate containers.
function _with_set(base::Form, path::Vector{Any}, val::Form)
    isempty(path) && return val
    c = _as_container(base)
    length(path) == 1 && return _set_key(c, path[1], val)
    child = _with_set(_at_key(c, path[1]), path[2:end], val)
    return _set_key(c, path[1], child)
end

# Remove the subform at `path` (the final key is the one removed).
function _wout_path(base::Form, path::Vector{Any})
    isempty(path) && return base
    c = _as_container(base)
    length(path) == 1 && return _delete_key(c, path[1])
    child = _wout_path(_at_key(c, path[1]), path[2:end])
    return _set_key(c, path[1], child)
end

# `(with form k1 v1 k2 v2 …)` — a *setter*: replace the subform at each key with
# the given value. A sequence key is a nested path, so `(with (a=(1 2)) (:a 2) 3)`
# is `(a=(1 3))`; an integer key `n + 1` appends. The form's root hold is
# transparent (the operation is on the content), inserted held values contribute
# their content, and `hold=true` wraps the result in a hold.
function _with_call(env::Env, scope::Scope, call::FormContainer, is_hold_fn::Bool)
    n = length(call.seq)
    n >= 2 || throw(AirEvalError("with needs a form"))
    (n - 2) % 2 == 0 || throw(AirEvalError("with needs key/value pairs"))
    strip, held = _hold_mode(call, is_hold_fn)
    result = air_reduce(env, scope, to_form(call.seq[2]))
    strip && (result = _strip_hold(result))
    i = 3
    while i <= n
        val = to_form(call.seq[i + 1])
        strip && (val = _strip_hold(val))
        result = _with_set(result, _path_keys(env, scope, to_form(call.seq[i])), val)
        i += 2
    end
    result = canonicalize(result)
    return held ? _holdify(result) : result
end
_hold_pair!(:with, _with_call)

# `(update-in coll k1 … kn f)` — replace the subform at the path `k1 … kn` with
# `(f old)`, where the function is the last argument. The keys follow the same
# rules as `get`/`with` (integers index a sequence, keywords a map, and a
# negative index counts from the end); a missing key yields `naught` to the
# function. Extra arguments to the function are written with `part`, as in
# `(update-in m :a (part + 10))`. `hold-update-in` treats the root hold as
# transparent and returns the result held, as usual.
function _update_in_call(env::Env, scope::Scope, call::FormContainer,
                         is_hold_fn::Bool)
    args = _call_args(env, scope, call)
    length(args) >= 3 || throw(AirEvalError(
        "update-in takes a collection, one or more keys, and a function"))
    strip, held = _hold_mode(call, is_hold_fn)
    c = _as_container(strip ? _strip_hold(args[1]) : args[1])
    path = Any[]
    for k in args[2:(length(args) - 1)]
        # A container key is a nested path, as for `get` and `with`.
        ks = k isa FormContainer ? Form[to_form(v) for v in k.seq] : Form[k]
        for v in ks
            kk = _get_key(v)
            (kk isa Integer || kk isa Symbol) ||
                throw(AirEvalError("update-in needs integer or keyword keys"))
            push!(path, kk)
        end
    end
    old = c
    for k in path
        old = old isa FormContainer ? _at_key(old, k) : naught
    end
    r = _call(env, scope, args[end], [old])
    strip && (r = _strip_hold(r))
    result = canonicalize(_with_set(c, path, r))
    return held ? _ensure_hold(result) : result
end
_hold_pair!(Symbol("update-in"), _update_in_call)

# `(wout form k…)` — remove the subform at each key (the final key of a path is
# removed), or, with no key, the last sequence element.
function _wout_call(env::Env, scope::Scope, call::FormContainer, is_hold_fn::Bool)
    n = length(call.seq)
    n >= 2 || throw(AirEvalError("wout needs a form"))
    strip, held = _hold_mode(call, is_hold_fn)
    result = air_reduce(env, scope, to_form(call.seq[2]))
    strip && (result = _strip_hold(result))
    if n == 2
        c = _as_container(result)
        m = length(c.seq)
        m == 0 || (result = canonicalize(FormContainer(
            FormSeq(FormValue[c.seq[i] for i in 1:(m - 1)]), c.map)))
    else
        for i in 3:n
            result = _wout_path(result, _path_keys(env, scope, to_form(call.seq[i])))
        end
    end
    result = canonicalize(result)
    return held ? _holdify(result) : result
end
_hold_pair!(:wout, _wout_call)

# ---- prepend / zip / interleave / flatten -----------------------------------

# `(prepend coll x…)` — the sequence elements of `coll` with `x…` in front:
# `(prepend (3 4) 1 2)` is `(1 2 3 4)`. A scalar is a one-element form.
builtin!(:prepend, (env, scope, args) -> begin
    c = _as_container(_arg(args, 1, "prepend"))
    pre = FormValue[_store_form(x) for x in args[2:end]]
    return canonicalize(FormContainer(FormSeq(FormValue[pre..., c.seq...]), c.map))
end)

# `(zip coll…)` — a sequence of argument tuples, stopping at the shortest input:
# `(zip (1 2) (3 4))` is `((1 3) (2 4))`.
builtin!(:zip, (env, scope, args) -> begin
    isempty(args) && return naught
    colls = FormContainer[_as_container(a) for a in args]
    n = minimum(length(c.seq) for c in colls)
    rows = FormValue[]
    for i in 1:n
        row = FormValue[c.seq[i] for c in colls]
        push!(rows, _store_form(FormContainer(FormSeq(row), FormMap())))
    end
    return canonicalize(FormContainer(FormSeq(rows), FormMap()))
end)

# `(interleave coll…)` — the elements of each input in turn, stopping at the
# shortest: `(interleave (1 2) (a b))` is `(1 a 2 b)`.
builtin!(:interleave, (env, scope, args) -> begin
    isempty(args) && return naught
    colls = FormContainer[_as_container(a) for a in args]
    n = minimum(length(c.seq) for c in colls)
    out = FormValue[]
    for i in 1:n, c in colls
        push!(out, c.seq[i])
    end
    return canonicalize(FormContainer(FormSeq(out), FormMap()))
end)

# `(flatten form)` — recursively splice nested sequence elements into one form:
# `(flatten ((1 2) (3 (4 5))))` is `(1 2 3 4 5)`. A hold is data and stays one
# element, and map entries are not flattened.
function _flatten_into!(out::Vector{FormValue}, x::Form)
    if x isa FormContainer && !_is_hold(x)
        for v in x.seq
            _flatten_into!(out, to_form(v))
        end
    else
        push!(out, _store_form(x))
    end
    return out
end

builtin!(:flatten, (env, scope, args) -> begin
    x = _arg(args, 1, "flatten")
    x isa FormContainer || return x
    out = FormValue[]
    for v in x.seq
        _flatten_into!(out, to_form(v))
    end
    return canonicalize(FormContainer(FormSeq(out), FormMap()))
end)

# ---- transposition, weaving, and products ------------------------------------

# `(transpose rows)` — the columns of the rows, stopping at the shortest:
# `(transpose ((1 2 3) (4 5 6)))` is `((1 4) (2 5) (3 6))`. A scalar row is a
# one-element row (a scalar is a singleton), and a row's map entries are dropped,
# as `zip` drops them.
builtin!(:transpose, (env, scope, args) -> begin
    c = _arg(args, 1, "transpose")
    c isa FormContainer || return c
    isempty(c.seq) && return naught
    rows = FormContainer[_as_container(to_form(v)) for v in c.seq]
    n = minimum(length(r.seq) for r in rows)
    cols = FormValue[]
    for i in 1:n
        col = canonicalize(FormContainer(
            FormSeq(FormValue[r.seq[i] for r in rows]), FormMap()))
        push!(cols, _store_form(col))
    end
    return canonicalize(FormContainer(FormSeq(cols), FormMap()))
end)

# `(riffle coll sep)` — insert `sep` between the elements:
# `(riffle (1 3 5) 0)` is `(1 0 3 0 5)`. When `sep` is a collection, its
# elements are used in turn and cycle when there are fewer separators than gaps,
# so `(riffle (a b c d) (x y))` is `(a x b y c x d)`. An empty separator
# collection leaves the sequence unchanged; the map is kept.
builtin!(:riffle, (env, scope, args) -> begin
    c = _arg(args, 1, "riffle"); s = _arg(args, 2, "riffle")
    c isa FormContainer || return c
    n = length(c.seq)
    n <= 1 && return c
    seps = s isa FormContainer ? FormValue[v for v in s.seq] :
           isequal(s, naught) ? FormValue[] : FormValue[_store_form(s)]
    isempty(seps) && return c
    out = FormValue[c.seq[1]]
    for i in 2:n
        push!(out, seps[mod1(i - 1, length(seps))])
        push!(out, c.seq[i])
    end
    return canonicalize(FormContainer(FormSeq(out), c.map))
end)

# The rows of the Cartesian product, the first collection varying slowest.
function _tuples_rows!(rows::Vector{Vector{FormValue}}, cur::Vector{FormValue},
                       colls::Vector{Vector{FormValue}}, i::Integer)
    if i > length(colls)
        push!(rows, copy(cur))
        return rows
    end
    for v in colls[i]
        push!(cur, v)
        _tuples_rows!(rows, cur, colls, i + 1)
        pop!(cur)
    end
    return rows
end

# `(tuples lists)` — the Cartesian product of the given collections:
# `(tuples ((a b) (1 2)))` is `((a 1) (a 2) (b 1) (b 2))`. `(tuples coll n)` is
# the n-fold product of one collection, and `(tuples coll 0)` is `naught` (a
# zero-length tuple canonicalizes away). An empty collection among the inputs
# yields no tuples.
builtin!(:tuples, (env, scope, args) -> begin
    a = _arg(args, 1, "tuples")
    colls = Vector{Vector{FormValue}}()
    if length(args) >= 2
        n = _leafof(args[2])
        (n isa Integer && n >= 0) ||
            throw(AirEvalError("tuples needs a non-negative integer count"))
        pool = FormValue[v for v in _as_container(a).seq]
        for _ in 1:n
            push!(colls, pool)
        end
    else
        a isa FormContainer || return naught
        for v in a.seq
            push!(colls, FormValue[e for e in _as_container(to_form(v)).seq])
        end
    end
    (isempty(colls) || any(isempty, colls)) && return naught
    rows = FormValue[]
    for row in _tuples_rows!(Vector{Vector{FormValue}}(), FormValue[], colls, 1)
        push!(rows, _store_form(canonicalize(FormContainer(FormSeq(row), FormMap()))))
    end
    return canonicalize(FormContainer(FormSeq(rows), FormMap()))
end)

# `(subdivide n)`, `(subdivide max n)`, `(subdivide min max n)` — `n + 1` evenly
# spaced points from `min` to `max` (defaults `0`, `1`): `(subdivide 4)` is
# `(0.0 0.25 0.5 0.75 1.0)`. Non-numeric input is left as the unreduced prefix
# form, like the other math verbs; a negative count is an error.
builtin!(:subdivide, (env, scope, args) -> begin
    ls = [_leafof(a) for a in args]
    all(l -> l isa Number, ls) || return _mk_prefix(:subdivide, args)
    lo, hi, n = length(ls) == 1 ? (0, 1, ls[1]) :
                length(ls) == 2 ? (0, ls[1], ls[2]) :
                length(ls) == 3 ? (ls[1], ls[2], ls[3]) :
                                  return _mk_prefix(:subdivide, args)
    (n isa Integer && n >= 0) ||
        throw(AirEvalError("subdivide needs a non-negative integer step count"))
    n == 0 && return to_form(float(lo))
    return FormContainer(FormSeq(FormValue[
        Form(float(lo) + (float(hi) - float(lo)) * i / n) for i in 0:n]), FormMap())
end)

# `(count-distinct coll)` — the number of distinct elements, under the same
# `eq?`-equivalent comparison as `distinct`: `(count-distinct (a b a))` is `2`.
builtin!(Symbol("count-distinct"), (env, scope, args) -> begin
    c = _arg(args, 1, "count-distinct")
    xs = c isa FormContainer ? c.seq :
         isequal(c, naught) ? FormValue[] : FormValue[_store_form(c)]
    return Form(length(Set{Form}(to_form(v) for v in xs)))
end)

# `(map-thread f coll…)` — apply `f` to the i-th element of each collection,
# stopping at the shortest: `(map-thread + (1 2) (3 4))` is `(4 6)`.
builtin!(Symbol("map-thread"), (env, scope, args) -> begin
    length(args) >= 2 ||
        throw(AirEvalError("map-thread needs a function and at least one collection"))
    f = args[1]
    colls = FormContainer[_as_container(a) for a in args[2:end]]
    n = minimum(length(c.seq) for c in colls)
    out = FormValue[]
    for i in 1:n
        push!(out, _store_form(_call(env, scope, f,
                                     Form[to_form(c.seq[i]) for c in colls])))
    end
    return canonicalize(FormContainer(FormSeq(out), FormMap()))
end)

function _outer!(env, scope, f, colls, i, chosen)
    if i > length(colls)
        return _call(env, scope, f, copy(chosen))
    end
    vals = FormValue[]
    for v in colls[i].seq
        push!(chosen, to_form(v))
        push!(vals, _store_form(_outer!(env, scope, f, colls, i + 1, chosen)))
        pop!(chosen)
    end
    return canonicalize(FormContainer(FormSeq(vals), FormMap()))
end

# `(outer f coll…)` — the outer product: `f` applied to every combination,
# nested one level per collection: `(outer * (1 2) (3 4))` is
# `((3 4) (6 8))`.
builtin!(Symbol("outer"), (env, scope, args) -> begin
    length(args) >= 2 ||
        throw(AirEvalError("outer needs a function and at least one collection"))
    colls = FormContainer[_as_container(a) for a in args[2:end]]
    return _outer!(env, scope, args[1], colls, 1, Form[])
end)

# `(trampoline f arg…)` — call `f` with the arguments; while the result is a
# replacement rule (a function), call that with no arguments. A set of
# mutually-tail-recursive steps can bounce through the trampoline instead of
# growing the stack: `(trampoline (?n -> (?n -> …)) 1)`.
builtin!(:trampoline, (env, scope, args) -> begin
    length(args) >= 1 || throw(AirEvalError("trampoline needs a function"))
    r = _call(env, scope, args[1], args[2:end])
    while _is_replacement_rule(r)
        r = _call(env, scope, r, Form[])
    end
    return r
end)

# `(array f n)` / `(array f n start)` — `(f 1) … (f n)`, or counting from
# `start`: `(array (?x -> (* x x)) 4)` is `(1 4 9 16)`. A non-integer count
# leaves the form unchanged, like `range`.
builtin!(:array, (env, scope, args) -> begin
    f = _arg(args, 1, "array")
    n = _leafof(_arg(args, 2, "array"))
    (n isa Integer && n >= 0) || return _mk_prefix(:array, args)
    start = length(args) >= 3 ? _leafof(args[3]) : 1
    start isa Integer || return _mk_prefix(:array, args)
    out = FormValue[]
    for i in start:(start + n - 1)
        push!(out, _store_form(_call(env, scope, f, Form[Form(i)])))
    end
    return canonicalize(FormContainer(FormSeq(out), FormMap()))
end)

# ---- sets --------------------------------------------------------------------

function _setop(args, keep)
    order = Form[]
    seen = Set{Form}()
    for a in args
        for v in _set_elems(a)
            fv = to_form(v)
            (fv in seen) && continue
            push!(seen, fv)
            keep(fv) && push!(order, fv)
        end
    end
    return canonicalize(FormContainer(FormSeq(FormValue[_store_form(f) for f in order]),
                                      FormMap()))
end
builtin!(:union, (env, scope, args) -> _setop(args, _ -> true))
builtin!(:intersect, (env, scope, args) -> begin
    isempty(args) && return naught
    sets = [Set{Form}(to_form(v) for v in _set_elems(a)) for a in args]
    return _setop(args, fv -> all(s -> fv in s, sets))
end)
builtin!(:difference, (env, scope, args) -> begin
    isempty(args) && return naught
    others = [Set{Form}(to_form(v) for v in _set_elems(a)) for a in args[2:end]]
    return _setop([args[1]], fv -> !any(s -> fv in s, others))
end)

# The elements a set predicate considers: a collection's sequence elements, or
# nothing for `naught` (which is the empty form, not a one-element set).
_set_elems(x::Form) = isequal(x, naught) ? FormValue[] : _elems(x)

# `(subset? a b)` — every element of `a` is an element of `b`; `(superset? a b)`
# is the reverse. A scalar is a singleton, as for the set operations above.
builtin!(Symbol("subset?"), (env, scope, args) -> begin
    a = _arg(args, 1, "subset?"); b = _arg(args, 2, "subset?")
    bs = Set{Form}(to_form(v) for v in _set_elems(b))
    return Form(all(v -> to_form(v) in bs, _set_elems(a)))
end)
builtin!(Symbol("superset?"), (env, scope, args) -> begin
    a = _arg(args, 1, "superset?"); b = _arg(args, 2, "superset?")
    as = Set{Form}(to_form(v) for v in _set_elems(a))
    return Form(all(v -> to_form(v) in as, _set_elems(b)))
end)
