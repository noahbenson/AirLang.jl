################################################################################
# env.jl
#
# The evaluation environment: lexical `Scope`s for `let`, the anchor-indexed
# `RuleStore` of global `def` patterns, and the `Env` that ties them to a
# database and a reduction budget.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- lexical scopes ----------------------------------------------------------

# A layer of namespace rules active in a scope. `RuleStore` (defined below)
# subtypes this; keeping the interface abstract lets `Scope` be defined before
# the rule store while still holding rule layers.
abstract type RuleLayer end

"""
    Scope

A lexical scope: a chain of `name => value` bindings built by `loop` and `for`
(a `let` substitutes rather than binding), plus the namespace rule layers active
at that point. A scope is immutable; extending it returns a child. `scope_get`
walks the chain; `scope_layers` collects the active rule layers, nearest first.
"""
struct Scope
    parent::Union{Nothing,Scope}
    names::Vector{Symbol}
    vals::Vector{Form}
    layers::Vector{RuleLayer}
    # The `def` rule whose body this scope is evaluating, if any. It carries the
    # rule's entry (and so its owner and ACL) through a tail call: `assume` and
    # `owner` consult the nearest rule context, and a control form inherits it.
    rule::Any
end

Scope() = Scope(nothing, Symbol[], Form[], RuleLayer[], nothing)
Scope(parent::Scope) = Scope(parent, Symbol[], Form[], RuleLayer[], parent.rule)
Scope(parent, names, vals, layers) = Scope(parent, names, vals, layers,
                                           parent isa Scope ? parent.rule : nothing)

"""
    scope_get(s, name) -> Union{Nothing,Some{Form}}

The value bound to `name` in `s` or a parent, or `nothing` if unbound. The
result is `Some` so that a binding to `naught` is distinguishable from unbound.
"""
function scope_get(s::Union{Nothing,Scope}, name::Symbol)
    while s !== nothing
        i = findfirst(==(name), s.names)
        i === nothing || return Some(s.vals[i])
        s = s.parent
    end
    return nothing
end

"""
    scope_extend(s, pairs; layers=RuleLayer[]) -> Scope

A child of `s` binding each `name => value` and activating the given namespace
rule `layers` (highest priority first).
"""
function scope_extend(s::Scope, pairs; layers::Vector{RuleLayer} = RuleLayer[],
                      rule = s.rule)
    names = Symbol[]
    vals = Form[]
    for (n, v) in pairs
        _check_not_reserved(n, AirEvalError, "bound")
        push!(names, n)
        push!(vals, v)
    end
    return Scope(s, names, vals, layers, rule)
end

# The nearest rule context active in `s`, or `nothing`.
function _scope_rule(s::Union{Nothing,Scope})
    while s !== nothing
        s.rule === nothing || return s.rule
        s = s.parent
    end
    return nothing
end

# The rule layers active in `s`, nearest scope first.
function scope_layers(s::Union{Nothing,Scope})
    out = RuleLayer[]
    while s !== nothing
        append!(out, s.layers)
        s = s.parent
    end
    return out
end

# Whether any scope in the chain activates a namespace layer; the common case is
# none, so rule matching can skip the walk.
function _scope_has_layers(s::Union{Nothing,Scope})
    while s !== nothing
        isempty(s.layers) || return true
        s = s.parent
    end
    return false
end

# A fresh scope carrying `s`'s active layers but none of its name bindings; used
# by `task` (which substitutes free names) so a spawned body keeps its
# namespace context.
_scope_layers_only(s::Scope) = Scope(nothing, Symbol[], Form[], scope_layers(s),
                                     _scope_rule(s))

# ---- binding-form structure ---------------------------------------------------

"""
    _let_groups(bform) -> Union{Nothing, Vector{FormContainer}}

The binding groups of a `let` binding form, in order. A single mapping
(`(x=1 y=2)`) is one group; a sequence of mappings (`((a=1) (b=2))`) is one group
per element, each of which can use the names bound by the groups before it.
`naught` (the same value as `()`) is an empty binding set, whether it is the
whole form or one group of the sequence. A group sequence's own map may hold the
`hold=` and `bind=` options, which name bindings rather than being bindings.
Returns `nothing` for any other shape (a sequence with any other map entry, or
an element that is not a pure mapping), so a pass that merely walks code can
leave the form alone while `let` itself reports the error.
"""
const _LET_OPTION_KEYS = Set{Symbol}([Symbol(":hold"), Symbol(":bind")])

function _let_groups(bform::Form)
    isequal(bform, naught) && return FormContainer[]
    bform isa FormContainer || return nothing
    if isempty(bform.seq)
        return FormContainer[bform]
    end
    # A group sequence may also carry the `hold=` and `bind=` options, which
    # name bindings rather than being bindings. `:let` markers need this because
    # the marker's binder form is the only place they can write options.
    all(k -> k in _LET_OPTION_KEYS, keys(bform.map)) || return nothing
    groups = FormContainer[]
    for a in bform.seq
        g = to_form(a)
        if isequal(g, naught)
            push!(groups, FormContainer(FormSeq(FormValue[]), FormMap()))
            continue
        end
        (g isa FormContainer && isempty(g.seq)) || return nothing
        push!(groups, g)
    end
    return groups
end

"""
    _let_binders(bform) -> Vector{Symbol}

Every name bound by any group of a `let` binding form, in order.
"""
function _let_binders(bform::Form)
    groups = _let_groups(bform)
    groups === nothing && return Symbol[]
    return Symbol[_bindname(k) for g in groups for (k, _) in g.map]
end

# ---- block syntax ------------------------------------------------------------

# The map options of a block form, shared by `do`/`tx` and by a `def`/`val`
# body (which is wrapped in one when it needs them).
const _LET_KEY = Symbol(":let")
const _CATCH_KEY = Symbol(":catch")

# A `def`'s own options, kept in the definition's map rather than the body.
const _TX_KEY = Symbol(":tx")
const _MEMO_KEY = Symbol(":memoize")

# The level-1 clause heads of a `do`/`tx` block. `catch` is included so a
# binder-aware pass leaves the invalid form alone; the evaluator reports it.
const _BLOCK_CLAUSE_HEADS = Set([Symbol("except"), Symbol("handle"),
                                 Symbol("finally"), Symbol("catch")])

_is_block_form(x::Form) =
    x isa FormContainer &&
    (head_symbol(x) === Symbol("do") || head_symbol(x) === Symbol("tx"))

# The sequence index at which the trailing clauses of a `do`/`tx` begin, or `0`
# when the form has no level-1 clause. The body is everything between the head
# and this index.
function _block_clause_start(x::FormContainer)
    for i in 2:length(x.seq)
        h = head_symbol(to_form(x.seq[i]))
        (h !== nothing && h in _BLOCK_CLAUSE_HEADS) && return i
    end
    return 0
end

# Rewrite the level-1 `:let` markers of a block body into nested real `let`
# forms. A marker consumes the next body form as its binding form; the rest of
# the body becomes the `let` body. Forms before the marker run first. A marker
# in the final position is inert data and is left exactly as written.
function _rewrite_body_lets(body::Vector{Form})
    i = findfirst(f -> _symbolof(f) === Symbol(":let"), body)
    i === nothing && return body
    i == length(body) && return body
    binder = body[i + 1]
    rest = _rewrite_body_lets(body[(i + 2):end])
    letform = Form(PVector{Any}([Form(Symbol("let")), binder, rest...]),
                   PDict{Symbol,Any}())
    return Form[body[1:(i - 1)]..., letform]
end

# Pure syntax expansion of the `:let` markers in the body of a `do`/`tx` form.
# The trailing clauses are left untouched (their bodies are separate scopes).
# Returns `x` itself when there is no marker to expand.
function _expand_block_markers(x::Form)
    _is_block_form(x) || return x
    start = _block_clause_start(x)
    bodyend = start == 0 ? length(x.seq) : start - 1
    bodyend < 2 && return x
    body = Form[to_form(x.seq[i]) for i in 2:bodyend]
    newbody = _rewrite_body_lets(body)
    isequal(newbody, body) && return x
    seq = FormValue[x.seq[1]]
    for f in newbody
        push!(seq, _store_form(f))
    end
    start == 0 || append!(seq, x.seq[start:length(x.seq)])
    map = Pair{Symbol,FormValue}[k => v for (k, v) in x.map]
    return FormContainer(FormSeq(seq), FormMap(map))
end

# Resolve the value expressions of a `let=` binding form, respecting its group
# structure: a name bound by an earlier group shadows an outer binding of the
# same spelling in a later group's value. Binding keys are names and are kept.
function _resolve_let_bindings(scope, bf::Form, bound::Set{Symbol})
    bf isa FormContainer || return bf
    if isempty(bf.seq)
        return _resolve_let_group(scope, bf, bound)
    end
    seq = FormValue[]
    bnd = bound
    for a in bf.seq
        g = to_form(a)
        if !(g isa FormContainer) || !isempty(g.seq)
            push!(seq, _store_form(g))
            continue
        end
        push!(seq, _store_form(_resolve_let_group(scope, g, bnd)))
        bnd = union(bnd, Symbol[_bindname(k) for (k, _) in g.map])
    end
    map = Pair{Symbol,FormValue}[k => v for (k, v) in bf.map]
    return FormContainer(FormSeq(seq), FormMap(map))
end

function _resolve_let_group(scope, g::FormContainer, bound::Set{Symbol})
    map = Pair{Symbol,FormValue}[
        k => _store_form(_resolve(scope, to_form(v), bound))
        for (k, v) in g.map]
    return FormContainer(g.seq, FormMap(map))
end

# The names a block's `let=` option binds, for the binder-aware passes.
function _block_let_binders(x::FormContainer)
    haskey(x.map, Symbol(":let")) || return Symbol[]
    return _let_binders(to_form(x.map[Symbol(":let")]))
end

# ---- scope description -------------------------------------------------------

"""
    _scope_form(form) -> Union{Nothing, NamedTuple}

For a form that introduces local names (`let`, `loop`, `for`), describe its
scope: the `binders` it introduces, and the `skip` sequence index of its binding
form (0 if none — a `let`'s binders live in its second element's mapping(s)).
Returns `nothing` for any other form, so a pass over a form simply recurses into
it. A `let` no longer binds through a scope, but its binders still shadow outer
names for the passes that reason about lexical structure.

This is the single description of each binder: evaluation, substitution, and
resolution all consult it, so none has to re-derive (and mis-handle) a binder's
structure. It is the analogue of Clojure's binding vectors and Mathematica's
`Module[{…}, …]` variable lists.
"""
function _scope_form(form::Form)
    (form isa FormContainer) || return nothing
    h = head_symbol(form)
    h === nothing && return nothing
    n = length(form.seq)
    if h === Symbol("let")
        n >= 2 || return (binders = Symbol[], skip = 2)
        return (binders = _let_binders(to_form(form.seq[2])), skip = 2)
    elseif h === Symbol("loop")
        n >= 2 || return nothing
        bs = to_form(form.seq[2])
        bs isa FormContainer || return nothing
        elems = _sx(bs.seq, 1:length(bs.seq))
        binders = Symbol[]
        for i in 1:2:length(elems)
            s = _symbolof(to_form(elems[i]))
            s === nothing && return nothing
            push!(binders, s)
        end
        return (binders = binders, skip = 2)
    elseif h === Symbol("for")
        n >= 2 || return nothing
        bf = to_form(form.seq[2])
        bf isa FormContainer || return nothing
        elems = _sx(bf.seq, 1:length(bf.seq))
        binders = Symbol[]
        i = 1
        while i <= length(elems)
            s = _symbolof(to_form(elems[i]))
            if s === Symbol(":if")
                i += 2
            elseif s === Symbol(":let")
                (i + 2 > length(elems)) && return nothing
                nm = _symbolof(to_form(elems[i + 1]))
                nm === nothing && return nothing
                push!(binders, _bindname(nm)); i += 3
            else
                (s === nothing || i + 1 > length(elems)) && return nothing
                push!(binders, s); i += 2
            end
        end
        return (binders = binders, skip = 2)
    end
    return nothing
end

# ---- the rule store ----------------------------------------------------------

"""
    Rule

A global reduction rule: the raw `pattern`, the raw `body`, every raw symbol in
the pattern (`anchors`, the index keys), the named wildcard `params`, and the
optional `doc` docstring (a literal string at the head of the body).

An `implicit` rule was written with no body (`(def (f ?x))`). Its `body` is the
pattern rewritten as a replacement (`(f x)`), so the rule reproduces the matched
form instead of replacing it; `definitions` omits that synthesized body.
"""
struct Rule
    id::Int
    pattern::Form
    body::Form
    anchors::Vector{Symbol}
    params::Vector{Symbol}
    held::Set{Symbol}   # params bound without being reduced (the `hold=` option)
    doc::Union{Nothing,String}
    implicit::Bool      # the body was synthesized from the pattern
    # The namespace entry this rule was compiled from (its volatile carries the
    # owner and ACL), and the owner's user id. Both are `nothing` for a global or
    # builtin rule, which every user may use.
    entry::Union{Nothing,VolatileForm}
    owner::Union{Nothing,Symbol}
    # The process-local result cache for a `memoize=` definition, or `nothing`.
    # Copies of a rule (`using` layers, imports) share this table; it is never
    # saved, only the memoization mode stored with the definition is.
    memo::Union{Nothing,_MemoTable}
end

"""
    RuleSnapshot

One immutable compiled state of a rule store: the rules in insertion order
(which is match priority), the index from each raw symbol to the rule positions
anchored by it, and — for a namespace's own store — the namespace volatile value
the snapshot was compiled from (compared by identity to decide whether a resync
is needed).

A snapshot is never mutated after publication. A store publishes a whole new
snapshot for every change, so a reader that takes one snapshot for the length of
a lookup always sees one consistent rule set: a definition staged by another
task is invisible until its transaction commits, and an aborted transaction
publishes nothing.
"""
struct RuleSnapshot
    rules::Vector{Rule}
    by_symbol::Dict{Symbol,Vector{Int}}
    source::Union{Nothing,Form}
end
RuleSnapshot() = RuleSnapshot(Rule[], Dict{Symbol,Vector{Int}}(), nothing)

# The index from anchor symbol to rule position for a rule vector.
function _rule_index(rules::Vector{Rule})
    by = Dict{Symbol,Vector{Int}}()
    for (i, r) in enumerate(rules)
        for s in r.anchors
            push!(get!(by, s, Int[]), i)
        end
    end
    return by
end

# Run `f` in a transaction, joining one that is already open. Air's transaction
# stages writes per task and publishes them atomically at commit, so a reader in
# another task never observes a half-applied update and an abort discards it.
@inline function _atomically(f::Function)
    return currtx() === nothing ? tx(f) : f()
end

"""
    RuleStore

A `RuleLayer` of global or compiled rules. The current contents live in an Air
`Volatile`, so a store update is transactional: staged in the writer's task and
published by one field assignment at commit. A namespace's store stamps its
snapshot with the namespace value it was compiled from (see `RuleSnapshot`).
"""
mutable struct RuleStore <: RuleLayer
    live::Volatile{RuleSnapshot}
end
RuleStore() = RuleStore(Volatile{RuleSnapshot}(RuleSnapshot()))
RuleStore(snap::RuleSnapshot) = RuleStore(Volatile{RuleSnapshot}(snap))

# The current snapshot. Outside a transaction this is one field load; inside one
# it is the transaction's (staged or committed) value and joins its read set.
@inline _snapshot(store::RuleStore) = store.live[]

# Read-modify-write a store. The read and the write are atomic with respect to
# other tasks; a concurrent update makes the commit retry this closure on the
# fresh snapshot instead of losing the other update.
function _update_rules!(f::Function, store::RuleStore)
    return _atomically() do
        snap = f(store.live[])
        store.live[] = snap
        snap
    end
end

# A private builder for compiling a store from scratch. The vectors are owned by
# the builder until it is published as one `RuleSnapshot`; a builder seeded from
# an existing snapshot gets copies of both containers and of every index vector,
# so building never mutates a published snapshot.
mutable struct _RuleBuilder
    rules::Vector{Rule}
    by_symbol::Dict{Symbol,Vector{Int}}
end
_RuleBuilder() = _RuleBuilder(Rule[], Dict{Symbol,Vector{Int}}())

_copy_index(by::Dict{Symbol,Vector{Int}}) =
    Dict{Symbol,Vector{Int}}(k => copy(v) for (k, v) in by)

# ---- namespaces --------------------------------------------------------------

"""
    UseRef

A resolved `use`/`import` spec: the source namespace's absolute `path`, the
optional name filters, and the optional `as=` binding name. Specs are resolved
into materialized entries at the point of the `use`/`import`; they are not
stored in the namespace.

A `use` installs the selected entries privately (they compile into the
namespace's rules but are absent from its map); an `import` additionally exports
them through the map.
"""
struct UseRef
    path::Vector{Symbol}
    only::Union{Nothing,Set{Symbol}}
    except::Set{Symbol}
    as::Union{Nothing,Symbol}
end

"""
    Namespace

A namespace: a `VolatileForm` holding a collection of forms (its sequence is the
append-ordered list of entries — `def`s, `val`s, imported copies, proxies, and
subnamespace markers; its map is the name index used by `.` access), the rules
compiled from those entries, and the fixed `core` entries a built-in namespace
exposes. `path` is the namespace's absolute address (`()` is the root).
`protected` names can never be removed by `clear`/`del`. The compiled rules are
a transactional `RuleStore`: each compile publishes a fresh snapshot stamped with
the volatile value it was built from, so a reader in another task never sees a
partially rebuilt store and a rolled-back definition leaves no compiled trace.
"""
mutable struct Namespace
    vf::VolatileForm
    path::Vector{Symbol}
    core::Dict{Symbol,Form}
    protected::Set{Symbol}
    rules::RuleStore
end

function Namespace(vf::VolatileForm, path::Vector{Symbol})
    return Namespace(vf, path, Dict{Symbol,Form}(), Set{Symbol}(), RuleStore())
end

"""
    ValBinding

The thread-local value behind a `val` definition: an Air `Var{Form}` whose
`initial_value` is the value the `val` was defined with. A `bind` rebinds it
dynamically for the extent of its body (and a `task` carries the current
bindings into its task). The `(path, name)` pair identifies it, so the binding is
recovered when a namespace is loaded from the database. `entry` is the namespace
entry volatile the binding's newest definition lives in (the permission checked
on every read); it is `nothing` for a global `val`.
"""
struct ValBinding
    var::Var{Form}
    path::Vector{Symbol}
    name::Symbol
    entry::Union{Nothing,VolatileForm}
end

"""
    _ValTable

The process's `val` bindings: `bindings` maps `(path, name)` to its `ValBinding`,
and `reverse` maps a `Var` back to the binding so `(bindings)` can name an
override. Held in an Air `Volatile` (see `Env.vals`) and replaced whole on a
definition, so the two tables and the bindings they hold are published as one
value and a reader never sees a half-installed `val`.
"""
struct _ValTable
    bindings::Dict{Tuple,ValBinding}
    reverse::IdDict{Any,ValBinding}
end
_ValTable() = _ValTable(Dict{Tuple,ValBinding}(), IdDict{Any,ValBinding}())

@inline _val_table(env) = env.vals[]

# Read-modify-write the binding table; `f` returns `(newtable, result)`.
function _update_vals!(f::Function, env)
    return _atomically() do
        table, result = f(env.vals[])
        env.vals[] = table
        result
    end
end

# ---- the environment ---------------------------------------------------------

"""
    TaskContext

The per-task evaluation identity: the user a task runs as, the namespace its
`def`/`val` forms target and its reductions start from, the `@` database root
(`nothing` for a system user), the current `.env` mapping, and the output sink
`(print …)` writes to (nothing for Air's global `airout`). Each task using an
`Env` gets its own context; a `task` starts with a copy of its creator's.
"""
mutable struct TaskContext
    user::Symbol
    ns::Union{Nothing,Namespace}
    dbroot::Union{Nothing,Form}
    env::Form
    out::Any
end

# A four-argument context leaves the output sink at the process default; the
# field is what lets an SSH session send a task's output to its channel.
TaskContext(user::Symbol, ns::Union{Nothing,Namespace},
            dbroot::Union{Nothing,Form}, env::Form) =
    TaskContext(user, ns, dbroot, env, nothing)

TaskContext() = TaskContext(Symbol("air"), nothing, nothing, naught)

"""
    Env(; db=nothing, max_steps=1_000_000, max_depth=2_000)

An air evaluation environment: the global `rules`, the process database `db`
backing the system namespaces (`.`, `.air`, `.sys`, `.lib`, `.main`; a fresh
`MemoryDatabase` when omitted), and a reduction budget (`max_steps` total
reductions, `max_depth` nesting). Tail calls do not consume depth, so a
tail-recursive rule is bounded only by `max_steps`.

`db` is the *process* store, not an ambient database for opened roots: a form's
database is always that of the namespace it is written in (see `_persist_db`).
"""
mutable struct Env
    rules::RuleStore
    max_steps::Int
    steps::Ref{Int}
    max_depth::Int
    depth::Ref{Int}
    # The logic-set context active while a rule handler (or a `logic` block) is
    # being evaluated, so a bare `assert`/`retract`/`update` knows which set it
    # belongs to. `nothing` outside a handler.
    logic_ctx::Any
    # The `memoize` cache: `(function form, argument form) => result`.
    memo::Dict{Any,Any}
    # The global namespace root volatile (created lazily), the process-level
    # database the system namespaces (`.`, `.air`, `.sys`, `.lib`, `.main`) live
    # in, and the path-keyed cache of namespace wrappers. `sysdb` is fixed for
    # the life of the environment (the `db` keyword), and an opened database is
    # never reachable through a system link.
    nsroot::Union{Nothing,VolatileForm}
    sysdb::AirDB.AbstractDatabase
    nscache::Dict{Tuple,Namespace}
    # The opened databases, keyed by the path of the namespace that roots each
    # one. A namespace at or under a key lives in that database rather than in
    # `sysdb`.
    dbs::Dict{Tuple,AirDB.AbstractDatabase}
    # The `val` bindings, keyed by `(path, name)`, with the reverse index from a
    # `Var` back to its binding so `bindings` can name what it reports. Held in
    # an Air `Volatile`: a definition stages a new table and publishes it at
    # commit, so another task never sees a half-installed `val` and an aborted
    # block installs nothing.
    vals::Volatile{_ValTable}
    # The per-task evaluation contexts (user, current namespace, `@` root, and
    # `.env`), the lock guarding the registry, the lock guarding the namespace
    # wrapper cache and the opened-database table, and whether `_bootstrap!` has
    # run.
    ctx::IdDict{Task,TaskContext}
    ctxlock::ReentrantLock
    metalock::ReentrantLock
    booted::Ref{Bool}
end

function Env(; db = nothing, max_steps::Int = 1_000_000, max_depth::Int = 2_000)
    sysdb = db === nothing ? MemoryDatabase() : db
    env = Env(RuleStore(), max_steps, Ref(0), max_depth, Ref(0), nothing,
              Dict{Any,Any}(), nothing, sysdb,
              Dict{Tuple,Namespace}(), Dict{Tuple,AirDB.AbstractDatabase}(),
              Volatile{_ValTable}(_ValTable()), IdDict{Task,TaskContext}(),
              ReentrantLock(), ReentrantLock(), Ref(false))
    register_constants!(env)
    register_stdlib!(env)
    _bootstrap!(env)
    return env
end

"""
    _context(env) -> TaskContext

The context of the current task, created on first use. Before boot it is the
default (`:air`, no namespace); after boot a new task starts as `air` in
`.main`. The registry is keyed by `Task`, so concurrent tasks evaluating in the
same `Env` do not disturb one another's identity.
"""
function _context(env::Env)
    t = current_task()
    c = lock(env.ctxlock) do
        get(env.ctx, t, nothing)
    end
    c === nothing || return c
    ns = env.booted[] ? _ns_lookup(env, Symbol[Symbol("main")]) : nothing
    c = TaskContext(Symbol("air"), ns, nothing, naught)
    return lock(env.ctxlock) do
        get!(env.ctx, t, c)
    end
end

# Run `f` with `ctx` as the current task's context, restoring the previous one
# (or removing the entry) when it finishes. A spawned task has no entry, so the
# task's captured copy is installed for exactly its own lifetime.
function _with_context(env::Env, ctx::TaskContext, f::Function)
    t = current_task()
    prev = lock(env.ctxlock) do
        p = get(env.ctx, t, nothing)
        env.ctx[t] = ctx
        p
    end
    try
        return f()
    finally
        lock(env.ctxlock) do
            if prev === nothing
                delete!(env.ctx, t)
            else
                env.ctx[t] = prev
            end
        end
    end
end

# The sink `(print …)` and `(println …)` write to: the task context's own writer
# when it has one (an SSH session), else Air's global actor-backed stdout.
_air_out(env::Env) = (c = _context(env); c.out === nothing ? airout : c.out)

"""
    _session_env(env) -> Env

A second environment over the same stores as `env` — the same rules, process
database, namespace and `val` caches, and task-context registry — with its own
reduction budget and memo cache. An SSH session runs on one, because `air_eval`
resets `steps`/`depth` and two concurrent sessions sharing those refs would
corrupt each other's budgets. The constructor is called positionally: `Env`'s
keyword constructor runs `_bootstrap!`, which a session must not repeat.
"""
function _session_env(env::Env)
    return Env(env.rules, env.max_steps, Ref(0), env.max_depth, Ref(0), nothing,
               Dict{Any,Any}(), env.nsroot, env.sysdb, env.nscache, env.dbs,
               env.vals, env.ctx, env.ctxlock, env.metalock, env.booted)
end

# ---- the guarded process caches ----------------------------------------------
#
# The namespace-wrapper cache and the opened-database table are ordinary
# dictionaries shared by every task using the environment. They are written only
# when a namespace is first resolved or a database is opened, but a `Dict` cannot
# be read while another task inserts into it, so every access goes through
# `env.metalock`. The lock is never held across a transaction commit: a wrapper
# is inserted under it and compiled outside it, and a database is registered or
# removed under it without any other lock held.

_ns_cached(env::Env, key) = lock(() -> get(env.nscache, key, nothing), env.metalock)
_ns_cached_values(env::Env) = lock(() -> collect(values(env.nscache)), env.metalock)
_ns_cached_keys(env::Env) = lock(() -> collect(keys(env.nscache)), env.metalock)
_db_registered(env::Env, key) = lock(() -> get(env.dbs, key, nothing), env.metalock)
_db_keys(env::Env) = lock(() -> collect(keys(env.dbs)), env.metalock)
_db_pairs(env::Env) = lock(() -> collect(env.dbs), env.metalock)

"""
    default_env() -> Env

A fresh environment with no database.
"""
default_env() = Env()

# ---- rule registration -------------------------------------------------------

# Add or replace a rule in a private builder. A pattern that is `isequal` to an
# existing one replaces it, keeping its position (and so its priority).
function _badd_rule!(b::_RuleBuilder, pattern::Form, body::Form;
                     held::Set{Symbol} = Set{Symbol}(),
                     doc::Union{Nothing,String} = nothing,
                     implicit::Bool = false,
                     entry::Union{Nothing,VolatileForm} = nothing,
                     owner::Union{Nothing,Symbol} = nothing,
                     memo::Union{Nothing,_MemoTable} = nothing)
    anchors = raw_symbols(pattern)
    params = params_of(pattern)
    for (i, r) in enumerate(b.rules)
        if isequal(r.pattern, pattern)
            b.rules[i] = Rule(i, pattern, body, anchors, params, held, doc,
                              implicit, entry, owner, memo)
            # A replacement can change the anchors, so rebuild the index.
            empty!(b.by_symbol)
            for (j, rr) in enumerate(b.rules)
                for s in rr.anchors
                    push!(get!(b.by_symbol, s, Int[]), j)
                end
            end
            return b.rules[i]
        end
    end
    id = length(b.rules) + 1
    rule = Rule(id, pattern, body, anchors, params, held, doc, implicit, entry,
                owner, memo)
    push!(b.rules, rule)
    for s in anchors
        push!(get!(b.by_symbol, s, Int[]), id)
    end
    return rule
end

# Add or replace a rule in a published store. The read-modify-write is
# transactional, so a concurrent update causes a retry rather than a lost rule,
# and a reader sees the old store until the commit.
function add_rule!(store::RuleStore, pattern::Form, body::Form;
                   held::Set{Symbol} = Set{Symbol}(),
                   doc::Union{Nothing,String} = nothing,
                   implicit::Bool = false,
                   entry::Union{Nothing,VolatileForm} = nothing,
                   owner::Union{Nothing,Symbol} = nothing,
                   memo::Union{Nothing,_MemoTable} = nothing)
    made = Ref{Union{Nothing,Rule}}(nothing)
    _update_rules!(store) do snap
        b = _RuleBuilder(copy(snap.rules), _copy_index(snap.by_symbol))
        made[] = _badd_rule!(b, pattern, body; held = held, doc = doc,
                             implicit = implicit, entry = entry, owner = owner,
                             memo = memo)
        RuleSnapshot(b.rules, b.by_symbol, snap.source)
    end
    return made[]
end

# Append an already-built rule, keeping the store's insertion order (which is
# matching priority). Used when a namespace's compiled rules are copied into a
# filtered `using` layer.
function _badd_rule_object!(b::_RuleBuilder, r::Rule)
    id = length(b.rules) + 1
    rule = Rule(id, r.pattern, r.body, r.anchors, r.params, r.held, r.doc,
                r.implicit, r.entry, r.owner, r.memo)
    push!(b.rules, rule)
    for s in rule.anchors
        push!(get!(b.by_symbol, s, Int[]), id)
    end
    return rule
end

"""
    params_of(pattern) -> Vector{Symbol}

The names of the named wildcards (`?x`) in `pattern`, in first-appearance order.
"""
function params_of(x::Form, out::Vector{Symbol} = Symbol[])
    if x isa FormScalar
        s = value(x)
        if s isa Symbol && is_wildcard(s) && s != Symbol("?")
            rm = _rest_marker(s)
            name = rm === nothing ? Symbol(String(s)[2:end]) : rm[2]
            (name !== nothing && !(name in out)) && push!(out, name)
        end
    elseif x isa FormContainer
        for a in x.seq
            params_of(to_form(a), out)
        end
        for (_, v) in x.map
            params_of(to_form(v), out)
        end
    end
    return out
end

# ---- anchor validity ---------------------------------------------------------

"""
    check_anchor(pattern)

Raise `AirDefError` unless `pattern` is a valid *global* pattern: a bare raw
symbol, or a container containing at least one raw symbol. This is the README's
anchor rule, keyed on any raw symbol (so `(?a + ?b)` is valid, anchored by `+`).
"""
function check_anchor(pattern::Form)
    _check_pattern(pattern)
    if pattern isa FormScalar
        is_raw_symbol(pattern) && return nothing
        throw(AirDefError("a global pattern must be a raw symbol or a form with a raw symbol anchor"))
    end
    pattern isa FormContainer ||
        throw(AirDefError("a global pattern must be a raw symbol or a form with a raw symbol anchor"))
    isempty(raw_symbols(pattern)) &&
        throw(AirDefError("a global pattern needs at least one raw symbol anchor"))
    return nothing
end
