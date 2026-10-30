################################################################################
# memo.jl
#
# The process-local caches behind `memoize=` on a `def`. The *metadata* (which
# mode and, for `:lru`, the maximum size) is stored with the definition in its
# namespace; the cache itself lives on the compiled rule and is never saved.
#
# Two modes:
#
#   * `:weak` (the default; `memoize=true` is an alias) keeps each result in a
#     `WeakRef`, so an entry survives exactly as long as some other value still
#     references the result. A dead entry is discarded on the next lookup (and
#     swept opportunistically).
#   * `(:lru max)` holds results strongly in a least-recently-used cache bounded
#     by `max` entries.
#
# The key is the rule's evaluated parameter bindings (see `_memo_key`), compared
# with `eq?` equivalence: `(f 1)` and `(f 1.0)` are distinct keys, `(f (+ 1 1))`
# and `(f 2)` share one, and equal containers whose maps were written in
# different orders are the same key.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

struct _MemoConfig
    mode::Symbol     # :weak or :lru
    max::Int         # meaningful only for :lru
end

# Parse the raw `memoize=` option of a `def`. `nothing` (or `false`/`naught`)
# disables memoization; `true` and `:weak` select the weak mode; `(:lru n)` with
# a positive integer selects a bounded cache.
function _memo_parse(raw::Form, name::AbstractString = "def")
    if raw isa FormScalar
        v = value(raw)
        (v === nothing || v === false) && return nothing
        v === true && return _MemoConfig(:weak, 0)
        v === Symbol(":weak") && return _MemoConfig(:weak, 0)
        throw(AirDefError(
            "$name: memoize= must be :weak, true, false, or (:lru max), got $(air_string(raw))"))
    end
    if raw isa FormContainer && head_symbol(raw) === Symbol(":lru")
        length(raw.seq) == 2 && isempty(raw.map) ||
            throw(AirDefError("$name: (:lru max) needs exactly one maximum"))
        n = to_form(raw.seq[2])
        (n isa FormScalar && value(n) isa Integer && value(n) > 0) ||
            throw(AirDefError("$name: (:lru max) needs a positive integer maximum"))
        return _MemoConfig(:lru, _as_int(value(n), "$name: (:lru max)"))
    end
    throw(AirDefError(
        "$name: memoize= must be :weak, true, false, or (:lru max), got $(air_string(raw))"))
end

# The `memoize=` option form that reproduces a configuration.
_memo_option_form(c::_MemoConfig) =
    c.mode === :weak ? Form(Symbol(":weak")) :
    Form(PVector{Any}([Form(Symbol(":lru")), Form(c.max)]), PDict{Symbol,Any}())


mutable struct _MemoTable
    mode::Symbol
    max::Int
    values::Dict{_EqKey,Any}     # :weak → WeakRef; :lru → the result Form
    order::Vector{_EqKey}        # LRU recency, oldest first
    inserts::Int                 # drives the opportunistic weak sweep
    lock::ReentrantLock
end

_memo_table(c::_MemoConfig) =
    _MemoTable(c.mode, c.max, Dict{_EqKey,Any}(), _EqKey[], 0, ReentrantLock())

_memo_config(t::_MemoTable) = _MemoConfig(t.mode, t.max)

# The cache key for one rule application: the rule's evaluated parameter bindings
# as a single immutable form, sorted by parameter name. Held parameters appear
# exactly as matched. Using the bindings rather than the call text is what lets
# `(f (+ 1 1))` and `(f 2)` share an entry without evaluating the argument twice.
function _memo_key(subst::AbstractDict{Symbol,Form})
    seq = FormValue[FormContainer(
                FormSeq(FormValue[Form(Symbol(name)), subst[name]]), FormMap())
            for name in sort!(collect(keys(subst)); by = string)]
    return FormContainer(FormSeq(seq), FormMap())
end

# A namespace stores only the memoization *configuration* with its entry; the
# table is looked up here by the entry volatile, so rebuilding a namespace's rule
# cache (after an unrelated definition, say) does not discard the results. A
# redefined `def` makes a fresh entry, and so a fresh table. The table is
# process-local and never saved.
const _MEMO_TABLES = WeakKeyDict{Any,_MemoTable}()
const _MEMO_TABLES_LOCK = ReentrantLock()

function _memo_table_for(entry, c::_MemoConfig)
    return lock(_MEMO_TABLES_LOCK) do
        t = get(_MEMO_TABLES, entry, nothing)
        if t === nothing || t.mode !== c.mode || t.max != c.max
            t = _memo_table(c)
            _MEMO_TABLES[entry] = t
        end
        t
    end
end

# The cached value for `key`, or `(false, naught)`. A weak entry whose result has
# been collected is dropped.
function _memo_lookup(t::_MemoTable, key::Form)
    k = _EqKey(key)
    return lock(t.lock) do
        haskey(t.values, k) || return (false, naught)
        if t.mode === :weak
            v = t.values[k]
            r = v isa WeakRef ? v.value : nothing
            r === nothing && (delete!(t.values, k); return (false, naught))
            return (true, r::Form)
        end
        # A read refreshes the entry's recency, so eviction is by last use.
        i = findfirst(x -> isequal(x, k), t.order)
        i === nothing || push!(t.order, popat!(t.order, i))
        return (true, t.values[k]::Form)
    end
end

function _memo_store!(t::_MemoTable, key::Form, val::Form)
    k = _EqKey(key)
    lock(t.lock) do
        if t.mode === :weak
            t.values[k] = WeakRef(val)
            # Every so often, drop the entries whose result has been collected, so
            # an otherwise idle cache does not accumulate dead keys.
            (t.inserts += 1) % 64 == 0 &&
                filter!(kv -> kv.second isa WeakRef && kv.second.value !== nothing,
                        t.values)
            return nothing
        end
        if haskey(t.values, k)
            i = findfirst(x -> isequal(x, k), t.order)
            i === nothing || deleteat!(t.order, i)
        end
        t.values[k] = val
        push!(t.order, k)
        while length(t.order) > t.max
            old = popfirst!(t.order)
            delete!(t.values, old)
        end
        return nothing
    end
end
