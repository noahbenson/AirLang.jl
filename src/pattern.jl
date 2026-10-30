################################################################################
# pattern.jl
#
# The pattern matcher. Patterns are ordinary forms; a wildcard is a symbol whose
# name starts with `?`. Supported: exact structural matching, named and unnamed
# wildcards, rest wildcards (`?&` sequence, `?*` keywords, `??` any), and
# conditions (`\`) attached to the pattern form before them.
#
# A rest wildcard is a sequence element of a pattern form and acts as a marker
# (not a value). Elements before it match the leading subject sequence elements
# and elements after it match the trailing ones; the marker captures the middle
# sequence and/or the leftover map entries per its kind. A kind that does not
# capture a part requires that part to match exactly.
#
# A condition is written `pattern \ cond`. A bare-symbol condition `pred` is
# shorthand for `(pred <pattern with each ?x replaced by x>)`, so `(?a 1) \ fn?`
# means `(fn? (a 1))`. A condition passes only when it evaluates to `true`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# The local name a wildcard binds (a rest marker contributes its name, and the
# unnamed wildcard binds nothing).
function _pattern_binding_name(s::Symbol)
    rm = _rest_marker(s)
    rm !== nothing && return rm[2]
    s == Symbol("?") && return nothing
    return Symbol(String(s)[2:end])
end

# Reject binding a reserved symbol (`reraise`, `NA`) at match time, so that a
# replacement-rule lambda, `replace`, or `case` pattern cannot bind it either.
function _check_binding_name(name::Symbol)
    _check_not_reserved(name, AirDefError, "bound")
    return name
end

# Reject a pattern that binds a reserved symbol.
function _check_reserved_pattern(x::Form)
    if x isa FormContainer
        for v in x.seq
            _check_reserved_pattern(to_form(v))
        end
        for (_, v) in x.map
            _check_reserved_pattern(to_form(v))
        end
    elseif x isa FormScalar
        s = value(x)
        if s isa Symbol && is_wildcard(s) && _reserved_binding(_pattern_binding_name(s))
            _check_not_reserved(_pattern_binding_name(s), AirDefError, "bound")
        end
    end
    return nothing
end

# A pattern element paired with an optional condition and an optional rest marker.
mutable struct _PatItem
    form::Form
    cond::Union{Nothing,Form}
    rest::Union{Nothing,Tuple{Symbol,Union{Nothing,Symbol}}}
end

# Split a pattern sequence into items: plain elements (with an optional `\ cond`),
# and at most one rest marker.
function _parse_pattern_items(seq)
    items = _PatItem[]
    rest_seen = false
    i = 1
    n = length(seq)
    while i <= n
        f = to_form(seq[i])
        s = _symbolof(f)
        s === COND_MARK && throw(AirDefError("'\\' must follow a pattern element"))
        rm = s === nothing ? nothing : _rest_marker(s)
        if rm !== nothing
            rest_seen && throw(AirDefError("a pattern may have at most one rest marker"))
            rest_seen = true
            push!(items, _PatItem(naught, nothing, rm))
        else
            push!(items, _PatItem(f, nothing, nothing))
        end
        i += 1
        if i <= n && _symbolof(to_form(seq[i])) === COND_MARK
            i + 1 <= n || throw(AirDefError("'\\' needs a condition after it"))
            items[end].rest === nothing ||
                throw(AirDefError("a rest marker cannot carry a condition"))
            items[end].cond = to_form(seq[i + 1])
            i += 2
        end
    end
    return items
end

# A condition: a bare raw symbol `pred` becomes `(pred <pattern with ?x -> x>)`;
# anything else is used as written. The unnamed wildcard `?` binds no name, so its
# condition tests the matched `subject` directly — `(? \ symbol?)` is
# `(symbol? <subject>)`.
function _normalize_condition(form::Form, cond::Form, subject = nothing)
    if cond isa FormScalar && value(cond) isa Symbol && is_raw_symbol(value(cond))
        # An alternative matched through exactly one branch, so only the subject
        # itself is a well-defined target for a bare predicate. A rule-level
        # guard has no subject here; it applies to `_`, which a replacement rule
        # binds to the whole matched subject.
        use_subject = subject !== nothing &&
                      (_symbolof(form) === Symbol("?") || _is_alt(form))
        target = use_subject ? subject :
                 _is_alt(form) ? Form(PLACEHOLDER) :
                 _strip_wildcards(form)
        return Form(PVector{Any}([cond, target]), PDict{Symbol,Any}())
    end
    return cond
end

# Validate a pattern, raising on a misplaced rest marker or condition.
function _check_pattern(x::Form)
    if _is_alt(x)
        # The branches are whole patterns, not sequence elements, so a bare rest
        # marker cannot sit directly in a branch.
        for i in 2:length(x.seq)
            b = to_form(x.seq[i])
            s = _symbolof(b)
            (s !== nothing && _rest_marker(s) !== nothing) &&
                throw(AirDefError("a rest marker must be a sequence element of a pattern form"))
            _check_pattern(b)
        end
        return nothing
    elseif x isa FormContainer
        for it in _parse_pattern_items(x.seq)
            it.form isa FormContainer && _check_pattern(it.form)
        end
        for (_, v) in x.map
            _check_pattern(to_form(v))
        end
    elseif x isa FormScalar
        s = value(x)
        (s isa Symbol && _rest_marker(s) !== nothing) &&
            throw(AirDefError("a rest marker must be a sequence element of a pattern form"))
    end
    return nothing
end

"""
    air_match(env, scope, pattern, subject, binds) -> Union{Dict{Symbol,Form},Nothing}

Match `pattern` against `subject`, extending `binds` with each named wildcard's
value. Returns the (possibly extended) `binds`, or `nothing` if there is no
match. Conditions are evaluated in `scope` (with the bindings so far) and must
yield `true`.
"""
function air_match(env::Env, scope::Scope, pattern::Form, subject::Form,
                   binds::Dict{Symbol,Form})
    # A pattern alternative `(alt p q …)` tries each branch in turn against the
    # same subject; the first branch that matches wins, and its bindings are the
    # result. Each branch starts from a copy, so a failed branch leaks nothing.
    if _is_alt(pattern)
        for i in 2:length(pattern.seq)
            b = air_match(env, scope, to_form(pattern.seq[i]), subject, copy(binds))
            b === nothing || return b
        end
        return nothing
    end
    if pattern isa FormScalar
        s = value(pattern)
        if s isa Symbol && is_wildcard(s)
            _rest_marker(s) !== nothing &&
                throw(AirDefError("a rest marker must be a sequence element of a pattern form"))
            s == Symbol("?") && return binds
            name = _check_binding_name(Symbol(String(s)[2:end]))
            if haskey(binds, name)
                return isequal(binds[name], subject) ? binds : nothing
            end
            binds[name] = subject
            return binds
        end
        return isequal(pattern, subject) ? binds : nothing
    elseif pattern isa FormContainer
        return _match_container(env, scope, pattern, subject, binds)
    else
        return isequal(pattern, subject) ? binds : nothing
    end
end

function _match_container(env::Env, scope::Scope, pattern::FormContainer, subject::Form,
                          binds::Dict{Symbol,Form})
    subject isa FormContainer || return nothing
    items = _parse_pattern_items(pattern.seq)
    ridx = findfirst(it -> it.rest !== nothing, items)
    if ridx === nothing
        length(items) == length(subject.seq) || return nothing
        for j in 1:length(items)
            binds = _match_item(env, scope, items[j], to_form(subject.seq[j]), binds)
            binds === nothing && return nothing
        end
        return _match_map(env, scope, pattern.map, subject.map, binds, false)
    end
    kind, name = items[ridx].rest
    before = items[1:(ridx - 1)]
    after = items[(ridx + 1):end]
    nb, na, ns = length(before), length(after), length(subject.seq)
    captures_seq = kind === :seq || kind === :both
    captures_map = kind === :map || kind === :both
    if captures_seq
        ns >= nb + na || return nothing
    else
        ns == nb + na || return nothing
    end
    for j in 1:nb
        binds = _match_item(env, scope, before[j], to_form(subject.seq[j]), binds)
        binds === nothing && return nothing
    end
    for j in 1:na
        binds = _match_item(env, scope, after[j], to_form(subject.seq[ns - na + j]), binds)
        binds === nothing && return nothing
    end
    cap_seq = FormValue[captures_seq ? subject.seq[i] : nothing
                        for i in (nb + 1):(ns - na)]
    cap_map = Pair{Symbol,FormValue}[]
    if captures_map
        all(k -> haskey(subject.map, k), keys(pattern.map)) || return nothing
        cap_map = Pair{Symbol,FormValue}[k => subject.map[k]
                                         for k in keys(subject.map) if !haskey(pattern.map, k)]
        binds = _match_map(env, scope, pattern.map, subject.map, binds, true)
        binds === nothing && return nothing
    else
        binds = _match_map(env, scope, pattern.map, subject.map, binds, false)
        binds === nothing && return nothing
    end
    # An empty capture is `naught`, the same value as `()`: a rest that matched
    # nothing is not an empty container.
    seq_form = canonicalize(FormContainer(FormSeq(cap_seq), FormMap()))
    map_form = canonicalize(FormContainer(FormSeq(FormValue[]), FormMap(cap_map)))
    if name !== nothing
        _check_binding_name(name)
        captured = kind === :seq ? seq_form :
            kind === :map ? map_form :
            canonicalize(FormContainer(FormSeq(cap_seq), FormMap(cap_map)))
        if haskey(binds, name)
            return isequal(binds[name], captured) ? binds : nothing
        end
        binds[name] = captured
    end
    return binds
end

# Match one item, then evaluate its condition (if any) with the bindings so far.
function _match_item(env::Env, scope::Scope, it::_PatItem, subject::Form,
                     binds::Dict{Symbol,Form})
    binds = air_match(env, scope, it.form, subject, binds)
    binds === nothing && return nothing
    it.cond === nothing && return binds
    cond = _normalize_condition(it.form, it.cond, subject)
    _cond_true(air_reduce(env, scope_extend(scope, [n => v for (n, v) in binds]), cond)) ||
        return nothing
    return binds
end

function _match_map(env::Env, scope::Scope, pmap, smap, binds::Dict{Symbol,Form},
                    subset::Bool)
    # A key written `?k=default` (stored as `:?k`) is optional: the real key is
    # `:k`, and the wildcard `k` binds the subject's value or the default.
    req = Symbol[]
    allowed = Set{Symbol}()
    for (k, _) in pmap
        if startswith(String(k), ":?")
            push!(allowed, Symbol(":", String(k)[3:end]))   # the real optional key
        else
            push!(req, k)
            push!(allowed, k)
        end
    end
    if !subset
        all(k -> k in allowed, keys(smap)) || return nothing   # no extra keys
        all(k -> k in Set(keys(smap)), req) || return nothing  # required present
    end
    for (k, v) in pmap
        s = String(k)
        if startswith(s, ":?")
            # The value is the default; bind the wildcard to the subject's value
            # (or the default when the key is absent).
            name = _check_binding_name(Symbol(s[3:end]))
            realk = Symbol(":", s[3:end])
            binds[name] = haskey(smap, realk) ? to_form(smap[realk]) : to_form(v)
        else
            haskey(smap, k) || return nothing
            binds = air_match(env, scope, to_form(v), to_form(smap[k]), binds)
        end
        binds === nothing && return nothing
    end
    return binds
end
