################################################################################
# hooks.jl
#
# Watches, filters, and finalizers on volatiles.
#
# A filter or finalizer is an air function stored in the volatile's metadata, so
# it is persisted with the volatile and survives reloads. AirDB rebuilds the
# inner `Volatile` on load without its hooks; `_ensure_hooks!` reinstalls them
# from metadata before the next write. Air's own `filter` runs when a value is
# staged and its result replaces the value; `finalize` runs after the body of a
# transaction and before the commit attempt, and it runs in the transaction's
# `:finalizing` state, where volatiles cannot be written. Both run as the user
# who installed them, in the namespace where they were installed.
#
# A watch is stored in the metadata too, as a sequence of `(key=… owner=… ns=…
# fn=…)` tables. Watches run at the end of the body of the outermost air
# transaction, before it commits: their writes are part of the same transaction,
# so a retry reruns them and a throw aborts the transaction.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- the transaction boundary ------------------------------------------------

const _WATCH_PENDING = :AirLangWatchPending

# Air form map keys carry their colon (`Symbol(":key")`), which is what `(get t
# :key)` looks up.
const _HOOK_FN_KEY = Symbol(":fn")
const _HOOK_NS_KEY = Symbol(":ns")
const _WATCH_KEY_KEY = Symbol(":key")

# ---- metadata visibility -----------------------------------------------------
#
# AirDB keeps a form's metadata in an Air `Volatile` (`metavolatile`), so
# `set_metadata!` is transactional: the committed value is visible to the next
# reader in this process as soon as the transaction returns. A check that
# follows the edit in the same air operation — the access check after `chmod!`,
# the watch table after `watch`, the filter after `set-filter!` — sees the new
# metadata without any extra work.
#
# The edit reaches the database row only when the writer actor flushes it, and
# `load!` re-reads that row along with the payload. Loading a form whose
# metadata was just edited would therefore overwrite the committed in-memory
# value with the old row value during the pre-flush window. The row must also be
# durable for other readers and for a later reload. Every metadata edit
# therefore records its database, and the transaction that carries it flushes
# before the air operation returns.

const _METADATA_DBS = :AirLangMetadataDatabases

# The databases with a metadata edit staged by the transaction in progress.
function _metadata_dbs()::Vector{AirDB.AbstractDatabase}
    d = task_local_storage()
    v = get(d, _METADATA_DBS, nothing)
    v isa Vector{AirDB.AbstractDatabase} && return v
    v = AirDB.AbstractDatabase[]
    d[_METADATA_DBS] = v
    return v
end

# Set a form's metadata and remember to wait for the edit to land.
function _set_metadata!(vf, m)
    set_metadata!(vf, m)
    dbs = _metadata_dbs()
    any(db -> db === vf.db, dbs) || push!(dbs, vf.db)
    return vf
end

# Wait until the staged metadata edits have landed. A no-op inside a
# transaction: its writes are scheduled only when it commits.
function _flush_metadata!()
    currtx() === nothing || return nothing
    dbs = _metadata_dbs()
    isempty(dbs) && return nothing
    try
        for db in dbs
            db.closed && continue   # the transaction may have closed it
            AirDB.sync(db)
        end
    finally
        empty!(dbs)
    end
    return nothing
end

# The task's `mutable => pre-transaction value` table for the transaction in
# progress. Transactions are task-local, so the table is too.
function _watch_pending()
    d = task_local_storage()
    p = get(d, _WATCH_PENDING, nothing)
    if p === nothing
        p = IdDict{VolatileForm,Form}()
        d[_WATCH_PENDING] = p
    end
    return p::IdDict{VolatileForm,Form}
end

# Run `f` as the body of a transaction. The outermost air transaction clears the
# write table at the start of every attempt (so a retry discards the failed
# attempt) and fires the watches at the end of the body, before the commit.
# Joining an already-open transaction just runs `f`.
#
# A `throw` whose catch scope is outside this transaction is deferred: the body
# returns normally so watches run and the transaction commits, then the signal is
# rethrown. A per-attempt slot is reset at the start of every attempt, so a retry
# discards a throw from the failed attempt. A watch error aborts; a watch throw
# replaces a pending one (the last throw wins).
# `_tx_boundary(env) do … end` passes the closure as the first argument (Julia's
# `do` syntax), so both argument orders are accepted.
_tx_boundary(env::Env, f::Function) = _tx_boundary(f, env)

function _tx_boundary(f::Function, env::Env)
    currtx() === nothing || return f()
    pending = _watch_pending()
    metadbs = _metadata_dbs()
    signal = Ref{Any}(nothing)
    r = try
        tx() do
            empty!(pending)
            empty!(metadbs)
            signal[] = nothing
            result = try
                f()
            catch e
                e isa AirThrowSignal || rethrow()
                signal[] = e
                naught
            end
            try
                _fire_watches!(env, pending)
            catch e
                e isa AirThrowSignal || rethrow()
                signal[] = e
            end
            result
        end
    catch
        empty!(metadbs)     # an aborted attempt staged nothing
        rethrow()
    end
    # A metadata edit landed with the commit; wait for it so a check that
    # follows this operation sees the new metadata.
    _flush_metadata!()
    s = signal[]
    s === nothing || throw(s::AirThrowSignal)
    return r
end

# ---- user and namespace context ---------------------------------------------

# Evaluate `f` as `user` in the namespace at `path`. A missing namespace leaves
# the current one in place; the function still runs as the recorded user.
# `_with_hook_context(env, user, path) do … end` passes the closure first.
_with_hook_context(f::Function, env::Env, user::Symbol, path::Vector{Symbol}) =
    _with_hook_context(env, user, path, f)

function _with_hook_context(env::Env, user::Symbol, path::Vector{Symbol},
                            f::Function)
    c = _context(env)
    prevuser, prevns = c.user, c.ns
    c.user = user
    ns = _ns_lookup(env, path; lazy = false)
    ns === nothing || (c.ns = ns)
    try
        return f()
    finally
        c.user, c.ns = prevuser, prevns
    end
end

_hook_ns_path(env::Env) = (c = _context(env);
                           c.ns isa Namespace ? copy(c.ns.path) : Symbol[])

# ---- hook tables -------------------------------------------------------------

# `(fn=… owner=… ns=…)` for a filter or finalizer, `(key=… fn=… owner=… ns=…)`
# for a watch.
_hook_table_form(fn::Form, owner::Symbol, path::Vector{Symbol}) =
    _ns_form(Form[], Pair{Symbol,Form}[
        _HOOK_FN_KEY => fn, _OWNER_KEY => Form(_user_key(owner)),
        _HOOK_NS_KEY => _ns_path_form(path)])

_watch_table_form(key::Form, fn::Form, owner::Symbol, path::Vector{Symbol}) =
    _ns_form(Form[], Pair{Symbol,Form}[
        _WATCH_KEY_KEY => key, _HOOK_FN_KEY => fn,
        _OWNER_KEY => Form(_user_key(owner)), _HOOK_NS_KEY => _ns_path_form(path)])

function _hook_table_parts(t::Form)
    t isa FormContainer || return nothing
    haskey(t, _HOOK_FN_KEY) || return nothing
    fn = to_form(t[_HOOK_FN_KEY])
    owner = if haskey(t, _OWNER_KEY)
        s = _symbolof(to_form(t[_OWNER_KEY]))
        s === nothing ? _AIR : _user_of_key(s)
    else
        _AIR
    end
    path = haskey(t, _HOOK_NS_KEY) ? _stored_path(to_form(t[_HOOK_NS_KEY])) : Symbol[]
    path === nothing && (path = Symbol[])
    return (fn = fn, owner = owner, path = path)
end

function _watch_table_parts(t::Form)
    p = _hook_table_parts(t)
    p === nothing && return nothing
    haskey(t, _WATCH_KEY_KEY) || return nothing
    return (key = to_form(t[_WATCH_KEY_KEY]), fn = p.fn, owner = p.owner,
            path = p.path)
end

# ---- filters and finalizers --------------------------------------------------

struct _AirHook <: Function
    env::Env
    kind::Symbol
    fn::Form
    owner::Symbol
    path::Vector{Symbol}
end

(h::_AirHook)(x::Form) = _with_hook_context(h.env, h.owner, h.path) do
    _apply_fn_form(h.env, h.fn, x)
end

# Apply a stored filter/finalizer form to `x`. A replacement rule is a function
# and is applied to the value; any other form is evaluated with `_` bound to the
# value (`filter=(if (_ < 0) 0 _)`).
function _apply_fn_form(env::Env, fn::Form, x::Form)
    if _is_replacement_rule(fn)
        return _call(env, _base_scope(env), fn, Form[x])
    end
    return air_reduce(env, _base_scope(env), _subst_placeholder(fn, x))
end

function _set_hook!(vf::VolatileForm, kind::Symbol, f::Function)
    if kind === :filter
        setfilter!(vf.volatile, f)
    else
        setfinalize!(vf.volatile, f)
    end
    return vf
end

# Install the filter and finalizer recorded in `vf`'s metadata, if they are not
# already installed. AirDB's `load!` replaces the inner `Volatile`, so this is
# checked before every write rather than once at creation.
function _ensure_hooks!(env::Env, vf::VolatileForm)
    for (kind, key) in ((:filter, _FILTER_KEY), (:finalize, _FINALIZE_KEY))
        cur = kind === :filter ? getfilter(vf.volatile) : getfinalize(vf.volatile)
        t = _meta_hook_table(vf, key)
        if t === nothing
            cur isa _AirHook && _set_hook!(vf, kind, identity)
        else
            p = _hook_table_parts(t)
            p === nothing && continue
            if !(cur isa _AirHook && cur.env === env && cur.kind === kind &&
                 isequal(cur.fn, p.fn) && cur.owner === p.owner &&
                 cur.path == p.path)
                _set_hook!(vf, kind, _AirHook(env, kind, p.fn, p.owner, p.path))
            end
        end
    end
    return vf
end

# ---- watches -----------------------------------------------------------------

# Record `vf`'s value before its first write in this transaction. The old value
# is read from the transaction's view, so it is the value the transaction saw.
function _record_write!(env::Env, vf::VolatileForm)
    _meta_watches(vf) === nothing && return vf
    p = _watch_pending()
    haskey(p, vf) && return vf
    p[vf] = canonicalize(vf[])
    return vf
end

# Run the watches of every mutable written in this transaction. A watch is
# called as `(fn key mutable old new)`, as its registrar, in the namespace where
# it was registered. Writes made by a watch are recorded like any others; a
# mutable whose watches have already run is not run again in this transaction.
function _fire_watches!(env::Env, pending::IdDict{VolatileForm,Form})
    isempty(pending) && return nothing
    fired = IdDict{VolatileForm,Bool}()
    while true
        todo = Tuple{VolatileForm,Form}[]
        for (vf, old) in pending
            haskey(fired, vf) || push!(todo, (vf, old))
        end
        isempty(todo) && break
        for (vf, old) in todo
            fired[vf] = true
            _fire_one!(env, vf, old)
        end
    end
    empty!(pending)
    return nothing
end

function _fire_one!(env::Env, vf::VolatileForm, old::Form)
    ws = _meta_watches(vf)
    ws === nothing && return nothing
    new = canonicalize(vf[])
    for w in ws
        p = _watch_table_parts(w)
        p === nothing && continue
        # A watch runs as its registrar; if that user can no longer read the
        # mutable, the watch is treated as absent.
        _can(env, vf, p.owner, :read) || continue
        _with_hook_context(env, p.owner, p.path) do
            _call(env, _base_scope(env), p.fn, Form[p.key, vf, old, new])
        end
    end
    return nothing
end

# ---- the builtins ------------------------------------------------------------

function _watch_target(env::Env, scope::Scope, call::FormContainer, name::String)
    length(call.seq) >= 2 || throw(AirEvalError("$name expects a mutable"))
    vf = air_reduce(env, scope, to_form(call.seq[2]))
    vf isa VolatileForm || throw(AirEvalError("$name expects a mutable"))
    return vf
end

# A watch key as a keyword form: keywords, symbols, and strings with the same
# text name the same watch.
function _watch_key_form(env::Env, scope::Scope, raw::Form)
    l = _leafof(air_reduce(env, scope, raw))
    if l isa Symbol && !is_keyword(l)
        return _keyword_form(_bindname(l))
    elseif l isa Symbol
        return _keyword_form(_bindname(l))
    elseif l isa AbstractString
        return _keyword_form(Symbol(lstrip(String(l), ':')))
    end
    throw(AirEvalError("watch: key must be a keyword, symbol, or string"))
end

function _watch_key_isequal(w::Form, key::Form)
    p = _watch_table_parts(w)
    p === nothing && return false
    return isequal(p.key, key)
end

# `(watch mutable key fn)` — register (or replace) the watch `key`. `fn` is kept
# as written; it is called with `(key mutable old new)`. Installing a watch needs
# both `watch` and `read` on the mutable.
function _bi_watch(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 4 ||
        throw(AirEvalError("watch expects a mutable, a key, and a function"))
    _check_options(call, "watch", ())
    vf = _watch_target(env, scope, call, "watch")
    _check!(env, vf, :watch)
    _check!(env, vf, :read)
    key = _watch_key_form(env, scope, to_form(call.seq[3]))
    fn = to_form(call.seq[4])
    entry = _watch_table_form(key, fn, _current_user(env), _hook_ns_path(env))
    _tx_boundary(env) do
        ws = _meta_watches(vf)
        out = Form[w for w in (ws === nothing ? Form[] : ws)
                   if !_watch_key_isequal(w, key)]
        push!(out, entry)
        _set_metadata!(vf, _meta_with_watches(vf, out))
        vf
    end
    return vf
end
special!(:watch, _bi_watch)

# `(unwatch mutable key…)` — remove the named watches, or all of them.
function _bi_unwatch(env::Env, scope::Scope, call::FormContainer)
    2 <= length(call.seq) <= 3 ||
        throw(AirEvalError("unwatch expects a mutable and an optional key"))
    _check_options(call, "unwatch", ())
    vf = _watch_target(env, scope, call, "unwatch")
    _check!(env, vf, :watch)
    key = length(call.seq) == 3 ?
        _watch_key_form(env, scope, to_form(call.seq[3])) : nothing
    _tx_boundary(env) do
        ws = _meta_watches(vf)
        ws === nothing && return vf
        out = key === nothing ? Form[] :
            Form[w for w in ws if !_watch_key_isequal(w, key)]
        _set_metadata!(vf, _meta_with_watches(vf, out))
        vf
    end
    return vf
end
special!(:unwatch, _bi_unwatch)

# `(watches mutable)` — the watch tables, held so that evaluating the result
# does not run them.
function _bi_watches(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 || throw(AirEvalError("watches expects a mutable"))
    _check_options(call, "watches", ())
    vf = _watch_target(env, scope, call, "watches")
    _check!(env, vf, :watch)
    ws = _meta_watches(vf)
    ws === nothing && return _ns_form(Form[])
    return _ns_form(Form[_holdify(w) for w in ws])
end
special!(:watches, _bi_watches)

# `(set-filter! mutable fn)` / `(set-finalize! mutable fn)` — install `fn`
# (`naught` removes it). The function is stored in metadata and reinstalled on
# the next write, so it survives a reload.
function _bi_set_hook(env::Env, scope::Scope, call::FormContainer,
                      kind::Symbol, name::Symbol)
    length(call.seq) == 3 ||
        throw(AirEvalError("$name expects a mutable and a function"))
    _check_options(call, String(name), ())
    vf = _watch_target(env, scope, call, String(name))
    _check!(env, vf, kind)
    raw = to_form(call.seq[3])
    clear = isequal(raw, naught)
    tbl = clear ? nothing : _hook_table_form(raw, _current_user(env),
                                             _hook_ns_path(env))
    _tx_boundary(env) do
        md = kind === :filter ? _metadata_like(vf; filter = tbl) :
                                _metadata_like(vf; finalize = tbl)
        _set_metadata!(vf, md)
        _ensure_hooks!(env, vf)
        vf
    end
    return vf
end
special!(Symbol("set-filter!"),
         (env, scope, call) -> _bi_set_hook(env, scope, call, :filter,
                                            Symbol("set-filter!")))
special!(Symbol("set-finalize!"),
         (env, scope, call) -> _bi_set_hook(env, scope, call, :finalize,
                                            Symbol("set-finalize!")))
