################################################################################
# builtins_core.jl
#
# The eager builtin library: predicates, accessors, collection verbs, and
# arithmetic. Each receives its arguments already reduced.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- predicates --------------------------------------------------------------

builtin!(Symbol("form?"), (env, scope, args) -> Form(true))
builtin!(Symbol("int?"), (env, scope, args) -> _bool(_leafof(_arg(args, 1, "int?")) isa Int64))
builtin!(Symbol("integer?"), (env, scope, args) -> _bool(_leafof(_arg(args, 1, "integer?")) isa Int64))
builtin!(Symbol("float?"), (env, scope, args) -> _bool(_leafof(_arg(args, 1, "float?")) isa Float64))
builtin!(Symbol("string?"), (env, scope, args) -> _bool(_leafof(_arg(args, 1, "string?")) isa String))
builtin!(Symbol("bool?"), (env, scope, args) -> _bool(_leafof(_arg(args, 1, "bool?")) isa Bool))
builtin!(Symbol("symbol?"), (env, scope, args) -> _bool(_leafof(_arg(args, 1, "symbol?")) isa Symbol))
builtin!(Symbol("keyword?"), (env, scope, args) -> _bool(is_keyword(_arg(args, 1, "keyword?"))))
builtin!(Symbol("wildcard?"), (env, scope, args) -> _bool(is_wildcard(_arg(args, 1, "wildcard?"))))
builtin!(Symbol("coll?"), (env, scope, args) -> _bool(_arg(args, 1, "coll?") isa FormContainer))
builtin!(Symbol("atom?"), (env, scope, args) -> _bool(_arg(args, 1, "atom?") isa FormScalar))
builtin!(Symbol("naught?"), (env, scope, args) -> _bool(isequal(_arg(args, 1, "naught?"), naught)))
builtin!(Symbol("mut?"), (env, scope, args) -> _bool(_arg(args, 1, "mut?") isa VolatileForm))
builtin!(Symbol("imm?"), (env, scope, args) -> _bool(!(_arg(args, 1, "imm?") isa VolatileForm)))
builtin!(Symbol("true?"), (env, scope, args) -> _bool(isequal(_arg(args, 1, "true?"), Form(true))))
builtin!(Symbol("false?"), (env, scope, args) -> _bool(isequal(_arg(args, 1, "false?"), Form(false))))
builtin!(Symbol("empty?"), (env, scope, args) -> _bool(isequal(_arg(args, 1, "empty?"), naught)))
builtin!(Symbol("complex?"), (env, scope, args) -> _bool(_leafof(_arg(args, 1, "complex?")) isa ComplexF64))
builtin!(Symbol("number?"), (env, scope, args) -> _bool(_leafof(_arg(args, 1, "number?")) isa Number))
builtin!(Symbol("zero?"), (env, scope, args) -> _bool((l = _leafof(_arg(args, 1, "zero?")); l isa Number && iszero(l))))
builtin!(Symbol("even?"), (env, scope, args) -> _bool((l = _leafof(_arg(args, 1, "even?")); l isa Integer && iseven(l))))
builtin!(Symbol("odd?"), (env, scope, args) -> _bool((l = _leafof(_arg(args, 1, "odd?")); l isa Integer && isodd(l))))
builtin!(Symbol("positive?"), (env, scope, args) -> _bool((l = _leafof(_arg(args, 1, "positive?")); l isa Real && l > 0)))
builtin!(Symbol("negative?"), (env, scope, args) -> _bool((l = _leafof(_arg(args, 1, "negative?")); l isa Real && l < 0)))
builtin!(Symbol("nan?"), (env, scope, args) -> _bool((l = _leafof(_arg(args, 1, "nan?")); l isa Real && isnan(l))))
builtin!(Symbol("infinite?"), (env, scope, args) -> _bool((l = _leafof(_arg(args, 1, "infinite?")); l isa Real && isinf(l))))
builtin!(Symbol("seq?"), (env, scope, args) -> _bool((x = _arg(args, 1, "seq?"); x isa FormContainer && isempty(x.map))))
builtin!(Symbol("map?"), (env, scope, args) -> _bool((x = _arg(args, 1, "map?"); x isa FormContainer && !isempty(x.map))))
builtin!(Symbol("associative?"), (env, scope, args) ->
    _bool((x = _arg(args, 1, "associative?"); x isa FormContainer && !isempty(x.map))))
builtin!(Symbol("counted?"), (env, scope, args) -> begin
    x = _arg(args, 1, "counted?")
    return _bool(x isa FormContainer || _leafof(x) isa AbstractString)
end)
builtin!(Symbol("same?"), (env, scope, args) -> _bool(_arg(args, 1, "same?") === _arg(args, 2, "same?")))
builtin!(Symbol("eq?"), (env, scope, args) ->
    _bool(_eq(_arg(args, 1, "eq?"), _arg(args, 2, "eq?"))))
builtin!(Symbol("contains?"), (env, scope, args) -> begin
    c = _arg(args, 1, "contains?"); k = _get_key(_arg(args, 2, "contains?"))
    (c isa FormContainer && (k isa Integer || k isa Symbol)) || return Form(false)
    return _bool(haskey(c, k))
end)
builtin!(Symbol("member?"), (env, scope, args) -> begin
    x = _arg(args, 1, "member?"); c = _arg(args, 2, "member?")
    c isa FormContainer || return Form(false)
    return _bool(any(v -> isequal(to_form(v), x), values(c)))
end)

function _quantify(env::Env, scope::Scope, f::Form, coll::Form, mode::Symbol)
    if coll isa FormContainer
        for v in values(coll)
            r = truthy(_call(env, scope, f, [to_form(v)]))
            mode === :all && !r && return Form(false)
            mode === :any && r && return Form(true)
            mode === :none && r && return Form(false)
        end
    end
    return Form(mode !== :any)
end
builtin!(Symbol("all?"), (env, scope, args) -> _quantify(env, scope, _arg(args, 1, "all?"), _arg(args, 2, "all?"), :all))
builtin!(Symbol("any?"), (env, scope, args) -> _quantify(env, scope, _arg(args, 1, "any?"), _arg(args, 2, "any?"), :any))
builtin!(Symbol("none?"), (env, scope, args) -> _quantify(env, scope, _arg(args, 1, "none?"), _arg(args, 2, "none?"), :none))

builtin!(Symbol("starts-with?"), (env, scope, args) -> begin
    s = _leafof(_arg(args, 1, "starts-with?")); p = _leafof(_arg(args, 2, "starts-with?"))
    return _bool(s isa String && p isa String && startswith(s, p))
end)
builtin!(Symbol("ends-with?"), (env, scope, args) -> begin
    s = _leafof(_arg(args, 1, "ends-with?")); p = _leafof(_arg(args, 2, "ends-with?"))
    return _bool(s isa String && p isa String && endswith(s, p))
end)
builtin!(Symbol("blank?"), (env, scope, args) -> begin
    x = _arg(args, 1, "blank?")
    isequal(x, naught) && return Form(true)
    l = _leafof(x)
    return _bool(l isa String && isempty(l))
end)
builtin!(Symbol("present?"), (env, scope, args) -> begin
    x = _arg(args, 1, "present?")
    isequal(x, naught) && return Form(false)
    l = _leafof(x)
    return _bool(!(l isa String && isempty(l)))
end)

# `(inc x)` / `(dec x)` — one more / less; symbolic on non-numbers.
builtin!(:inc, (env, scope, args) -> begin
    x = _arg(args, 1, "inc"); l = _leafof(x)
    l isa Number ? to_form(l + 1) : _mk_prefix(:inc, [x])
end)
builtin!(:dec, (env, scope, args) -> begin
    x = _arg(args, 1, "dec"); l = _leafof(x)
    l isa Number ? to_form(l - 1) : _mk_prefix(:dec, [x])
end)

# ---- accessors ---------------------------------------------------------------

# `value` dereferences a mutable; for any other form it is the form itself, since
# in air every value is a form.
builtin!(:value, (env, scope, args) -> begin
    x = _arg(args, 1, "value")
    if x isa VolatileForm
        _check!(env, x, :read)
        return canonicalize(x[])
    end
    return _force_ref_form(env, x)
end)

builtin!(:seqpart, (env, scope, args) -> begin
    x = _arg(args, 1, "seqpart")
    x isa FormContainer || return naught
    return canonicalize(Form(PVector{Any}([v for v in x.seq]), PDict{Symbol,Any}()))
end)

builtin!(:mappart, (env, scope, args) -> begin
    x = _arg(args, 1, "mappart")
    x isa FormContainer || return naught
    return canonicalize(Form(PVector{Any}(), PDict{Symbol,Any}([k => v for (k, v) in x.map]...)))
end)

# ---- collections -------------------------------------------------------------

# `(push coll x…)` — pure, variadic append: `(push (1 2) 3 4)` is `(1 2 3 4)`.
# `(push form value…)` — append values. Held values contribute their content in
# hold mode (`hold-push`, or `hold=true`), which also holds the result.
function _push_call(env::Env, scope::Scope, call::FormContainer, is_hold_fn::Bool)
    strip, held = _hold_mode(call, is_hold_fn)
    args = _call_args(env, scope, call)
    isempty(args) && throw(AirEvalError("push needs a form"))
    c = _as_container(strip ? _strip_hold(args[1]) : args[1])
    seq = FormValue[c.seq...]
    for x in args[2:end]
        push!(seq, _store_form(strip ? _strip_hold(x) : x))
    end
    r = canonicalize(FormContainer(FormSeq(seq), c.map))
    return held ? _ensure_hold(r) : r
end
_hold_pair!(:push, _push_call)

builtin!(:pop, (env, scope, args) -> begin
    c = _arg(args, 1, "pop")
    c isa FormContainer ? canonicalize(pop(c)) : naught
end)

builtin!(:drop, (env, scope, args) -> begin
    c = _arg(args, 1, "drop"); k = _keyof(_arg(args, 2, "drop"))
    c isa FormContainer || throw(AirEvalError("drop expects a collection"))
    k isa Integer || k isa Symbol ||
        throw(AirEvalError("drop expects an integer or keyword key"))
    return canonicalize(delete(c, k))
end)

builtin!(:length, (env, scope, args) -> Form(length(_arg(args, 1, "length"))))

builtin!(:haskey, (env, scope, args) -> begin
    c = _arg(args, 1, "haskey"); k = _keyof(_arg(args, 2, "haskey"))
    (k isa Integer || k isa Symbol) || return Form(false)
    c isa FormContainer || return Form(false)
    return _bool(haskey(c, k))
end)

# `(get form key…)` extracts a subform. A path of more than one key rewrites to
# nested gets — `(get f a b)` → `(get (get f a) b)` — so a user rule can override
# `get` for a particular form. A `default` map element supplies a value when a
# key on the path is missing; otherwise a missing key raises. With `hold=true`
# the form's root hold is transparent, the path indexes its content without
# reducing intermediates, and the result is returned held.
function _bi_get(env::Env, scope::Scope, call::FormContainer, is_hold_fn::Bool = false)
    n = length(call.seq)
    if n == 2
        # `(get form)` is the whole form, exactly as key `0` names it, and a
        # mutable is dereferenced: `(get m)` is `(value m)`.
        strip, held = _hold_mode(call, is_hold_fn)
        form = air_reduce(env, scope, to_form(call.seq[2]))
        strip && (form = _strip_hold(form))
        if form isa VolatileForm
            _check!(env, form, :read)
            form = form[]
        end
        v = canonicalize(_force_ref_form(env, form))
        return held ? _ensure_hold(v) : v
    end
    n >= 3 || throw(AirEvalError("get needs a form and a key"))
    default = haskey(call.map, Symbol(":default")) ?
        to_form(call.map[Symbol(":default")]) : nothing
    strip, held = _hold_mode(call, is_hold_fn)
    form0 = call.seq[2]
    path = _sx(call.seq, 3:length(call.seq))
    if length(path) > 1 && !strip
        # Plain `get`: a path is nested lookups — `(get f a b)` is
        # `(get (get f a) b)` — so a user rule can override `get` for a subform.
        inner = Form(PVector{Any}([Form(Symbol("get")), form0, path[1]]), PDict{Symbol,Any}())
        mp = Pair{Symbol,Any}[]
        default === nothing || push!(mp, Symbol(":default") => default)
        rest = Form(PVector{Any}([Form(Symbol("get")), inner, path[2:end]...]),
                    PDict{Symbol,Any}(mp...))
        return air_reduce(env, scope, rest)
    end
    form = air_reduce(env, scope, to_form(form0))
    if strip
        # The form's root hold is transparent: the path indexes the held
        # *content*, the walk does not reduce intermediate values, and the
        # result is held when `hold=true`.
        form = _strip_hold(form)
        for i in 1:(length(path) - 1)
            k = air_reduce(env, scope, to_form(path[i]))
            form = _get_one(env, scope, form, k, default, false)
        end
        lastkey = air_reduce(env, scope, to_form(path[end]))
        return _get_one(env, scope, form, lastkey, default, held)
    end
    key = air_reduce(env, scope, to_form(path[1]))
    return _get_one(env, scope, form, key, default, false)
end
special!(:get, (env, scope, call) -> _bi_get(env, scope, call, false);
         overridable = true)
special!(Symbol("hold-get"),
         (env, scope, call) -> _bi_get(env, scope, call, true); overridable = true)

# `get`'s single lookup. A hold is an ordinary form here, so `(get (' a b c) 1)`
# is `'` and `(get (' a b c) 2)` is `a`. An integer key indexes the sequence
# (`0` is the whole form, positive counts from the front, negative from the
# end); a symbol key looks in the map. A scalar is its own sole sequence, so
# `(get 5 1)` is `5`. `held` returns the subpart held, so
# `(get (f (inc 1)) 3 hold=true)` is `(' inc 1)` rather than `2`.
function _get_one(env::Env, scope::Scope, form::Form, key::Form, default, held::Bool = false)
    k = _get_key(key)
    src = form
    form = _ns_contents(env, form)
    # A missing name under `.lib` may be an unloaded library; the loader triggers
    # on the namespace object, so recover it from the volatile we were handed.
    if k isa Symbol && !(form isa FormContainer && haskey(form, k)) &&
       src isa VolatileForm
        ns = _ns_from_value(env, src)
        if ns !== nothing && _lib_trigger!(env, ns, k)
            form = _ns_contents(env, ns.vf)
        end
    end
    if form isa FormContainer
        if k isa Integer
            i = try
                _index_of(k, length(form.seq))
            catch e
                e isa AirEvalError || rethrow()
                default === nothing || return air_reduce(env, scope, default)
                rethrow()
            end
            if i === nothing
                return held ? _ensure_hold(form) : form
            end
            v = _ns_value(env, canonicalize(to_form(form.seq[i])))
            return held ? _ensure_hold(v) : v
        elseif k isa Symbol && haskey(form, k)
            v = _ns_value(env, canonicalize(to_form(form[k])))
            return held ? _ensure_hold(v) : v
        end
    elseif form isa FormScalar && k isa Integer
        # A scalar is its own sole element, so keys `1` and `-1` name it and `0`
        # names the whole form: `(get 5 1)` is `5`. `naught` is the empty form
        # (zero elements, as for `nth`), so only `0` names it.
        n = _leafof(form) === nothing ? 0 : 1
        try
            _index_of(k, n)
        catch e
            e isa AirEvalError || rethrow()
            default === nothing || return air_reduce(env, scope, default)
            rethrow()
        end
        return held ? _ensure_hold(form) : form
    end
    default === nothing &&
        throw(AirEvalError("key $(air_string(key)) not found in $(air_string(form))"))
    return air_reduce(env, scope, default)
end

builtin!(:in, (env, scope, args) -> begin
    x = _arg(args, 1, "in"); c = _arg(args, 2, "in")
    if c isa FormContainer
        any(v -> isequal(to_form(v), x), c.seq) && return Form(true)
        any(v -> isequal(to_form(v), x), values(c.map)) && return Form(true)
    elseif c isa VolatileForm
        return Form(isequal(x, c))
    end
    return Form(false)
end)

builtin!(:merge, (env, scope, args) -> begin
    length(args) >= 1 || throw(AirEvalError("merge expects at least one argument"))
    result = args[1]
    for a in args[2:end]
        (result isa FormContainer && a isa FormContainer) ||
            throw(AirEvalError("merge expects collections"))
        result = merge(result, a)
    end
    return result
end)

# ---- arithmetic and comparison -----------------------------------------------

# The basic operators (`+ - * / = < >`) are not builtins; they are native and
# infix-canonical, dispatched in `reduce.jl` and implemented in `operators.jl`.

# The type rank `compare` uses: numbers before strings before symbols before
# containers, with `naught` first and containers last.
function _cmp_rank(x::Form)
    x isa FormContainer && return 7
    (x isa VolatileForm || x isa ActorForm || x isa PromiseForm || x isa DelayForm) && return 5
    x isa FormExtern && return 6
    l = _leafof(x)
    l === nothing && return 0
    l isa Bool && return 1
    l isa Number && return 2
    l isa AbstractString && return 3
    l isa Symbol && return is_keyword(l) ? 4 : 4
    return 6
end

# A total order over forms, used by `compare`. Same-rank values compare
# naturally; containers compare lexicographically over their sequences and then
# their map entries.
function _cmp_forms(a::Form, b::Form)
    ra, rb = _cmp_rank(a), _cmp_rank(b)
    ra == rb || return ra < rb ? -1 : 1
    if a isa FormContainer && b isa FormContainer
        na, nb = length(a.seq), length(b.seq)
        for i in 1:min(na, nb)
            c = _cmp_forms(to_form(a.seq[i]), to_form(b.seq[i]))
            c == 0 || return c
        end
        na == nb || return na < nb ? -1 : 1
        ka = sort!(String[String(k) for k in keys(a.map)])
        kb = sort!(String[String(k) for k in keys(b.map)])
        ka == kb || return cmp(join(ka, '\0'), join(kb, '\0'))
        for k in sort!(collect(keys(a.map)))
            c = _cmp_forms(to_form(a.map[k]), to_form(b.map[k]))
            c == 0 || return c
        end
        return 0
    elseif a isa VolatileForm || b isa VolatileForm || a isa FormExtern || b isa FormExtern ||
           a isa ActorForm || b isa ActorForm || a isa PromiseForm || b isa PromiseForm ||
           a isa DelayForm || b isa DelayForm
        return isequal(a, b) ? 0 : cmp(air_string(a), air_string(b))
    end
    la, lb = _leafof(a), _leafof(b)
    if la isa Number && lb isa Number
        return la < lb ? -1 : (la > lb ? 1 : 0)
    elseif la isa AbstractString && lb isa AbstractString
        return cmp(la, lb)
    elseif la isa Symbol && lb isa Symbol
        return cmp(String(la), String(lb))
    elseif la isa Bool && lb isa Bool
        return la == lb ? 0 : (la ? 1 : -1)
    end
    return 0
end

# `(compare a b)` — -1, 0, or 1 ordering two forms (see `_cmp_forms`).
builtin!(:compare, (env, scope, args) ->
    Form(_cmp_forms(_arg(args, 1, "compare"), _arg(args, 2, "compare"))))

# `(hash x)` — a stable-within-a-session integer hash of the form, consistent
# with `eq?`: equivalent forms hash alike, and a mutable part contributes only
# its identity (see equality.jl).
builtin!(:hash, (env, scope, args) ->
    Form(reinterpret(Int64, UInt64(_eq_hash(_arg(args, 1, "hash"), zero(UInt))))))

# ---- keywords and names ------------------------------------------------------

# `(keyword x)` — a keyword from a string or symbol: `(keyword "host")` → `:host`.
builtin!(:keyword, (env, scope, args) -> begin
    x = _arg(args, 1, "keyword")
    s = x isa FormScalar ? value(x) : nothing
    s isa Symbol && return Form(is_keyword(s) ? s : Symbol(":" * String(s)))
    s isa AbstractString && return Form(Symbol(":" * String(s)))
    return _mk_prefix(:keyword, args)
end)

# `(symbol x)` — a symbol from a string or symbol: `(symbol "x")` → `x`,
# `(symbol "?y")` → the wildcard `?y`.
builtin!(:symbol, (env, scope, args) -> begin
    x = _arg(args, 1, "symbol")
    s = x isa FormScalar ? value(x) : nothing
    s isa Symbol && return Form(Symbol(String(s)))
    s isa AbstractString && return Form(Symbol(s))
    return _mk_prefix(:symbol, args)
end)

# `(name x)` — the text of a keyword, symbol, or wildcard, without the leading
# `:` or `?`: `(name :host)` → `"host"`, `(name ?x)` → `"x"`.
builtin!(:name, (env, scope, args) -> begin
    x = _arg(args, 1, "name")
    s = x isa FormScalar ? value(x) : nothing
    s isa Symbol && return Form(lstrip(String(s), ['?', ':']))
    s isa AbstractString && return Form(String(s))
    return _mk_prefix(:name, args)
end)
