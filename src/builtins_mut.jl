################################################################################
# builtins_mut.jl
#
# `mut` creates a mutable (`VolatileForm`); `set!` writes it. The mutable belongs
# to the database of the current namespace (see `_persist_db`), so an entry in
# that namespace may store it. `set!` writes the deepest mutable on the path,
# inside an Air transaction, exactly as AirDB's `setindex!` does.
#
# The `!` marks the operations that edit a volatile in a transaction: `set!`,
# `swap!`, and `alter!` here, and `chmod!`/`chown!` in permissions.jl. `mut` is
# not one of them: it creates rather than edits an existing volatile.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# `(mut)` / `(mut value filter=… finalize=…)` — a new mutable holding the
# (reduced, filtered) value. It belongs to the creating user, who has read,
# write, and execute on it. `filter` and `finalize` are kept as written and
# stored in the mutable's metadata; a replacement rule receives the value as its
# argument, while any other form is evaluated with `_` bound to the value. The
# filter also applies to the initial value, as Air's own filter constructor does;
# the finalizer runs only on later writes inserted in a transaction.
function _bi_mut(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "mut", (_FILTER_KEY, _FINALIZE_KEY))
    length(call.seq) <= 2 || throw(AirEvalError("mut takes at most one value"))
    db = _persist_db(env)
    me = _current_user(env)
    _check_db_principal!(env, db, me)
    body = length(call.seq) == 2 ?
        air_reduce(env, scope, to_form(call.seq[2])) : form()
    ffn = haskey(call.map, _FILTER_KEY) ? to_form(call.map[_FILTER_KEY]) : nothing
    nfn = haskey(call.map, _FINALIZE_KEY) ? to_form(call.map[_FINALIZE_KEY]) : nothing
    path = _hook_ns_path(env)
    filter = ffn === nothing ? nothing : _hook_table_form(ffn, me, path)
    finalize = nfn === nothing ? nothing : _hook_table_form(nfn, me, path)
    r = _tx_boundary(env) do
        ffn === nothing || (body = _apply_fn_form(env, ffn, body))
        _check_storable!(env, db, body)
        md = _metadata_form(me; acl = _perms_acl(me), filter = filter,
                            finalize = finalize)
        vf = VolatileForm(db, body; metadata = md)
        _ensure_hooks!(env, vf)
        vf
    end
    return r
end
special!(:mut, _bi_mut)

# `(set! mutable value)` or `(set! form path… value)`.
function _bi_set(env::Env, scope::Scope, call::FormContainer)
    n = length(call.seq)
    n >= 3 || throw(AirEvalError("set! needs a target and a value"))
    target = air_reduce(env, scope, to_form(call.seq[2]))
    target isa VolatileForm || throw(AirEvalError("set! expects a mutable"))
    _check!(env, target, :write)
    if n == 3
        value = air_reduce(env, scope, to_form(call.seq[3]))
        _tx_boundary(env) do
            _ensure_hooks!(env, target)
            _record_write!(env, target)
            setindex!(target, value)
            value
        end
        return value
    else
        path = Any[_keyof(air_reduce(env, scope, to_form(a))) for a in _sx(call.seq, 3:(n - 1))]
        value = air_reduce(env, scope, to_form(call.seq[n]))
        _tx_boundary(env) do
            _ensure_hooks!(env, target)
            _record_write!(env, target)
            setindex!(target, value, path...)
            value
        end
        return value
    end
end
special!(Symbol("set!"), _bi_set)

# `(swap! mutable fn args…)` — atomically replace the mutable's value with
# `(fn value args…)` and return the new value. The read, the call, and the write
# are one transaction, so a concurrent writer causes a retry rather than a lost
# update. `alter!` is an alias.
function _bi_swap(env::Env, scope::Scope, call::FormContainer)
    n = length(call.seq)
    n >= 3 || throw(AirEvalError("swap! needs a mutable and a function"))
    target = air_reduce(env, scope, to_form(call.seq[2]))
    target isa VolatileForm || throw(AirEvalError("swap! expects a mutable"))
    _check!(env, target, :write)
    f = air_reduce(env, scope, to_form(call.seq[3]))
    args = Form[air_reduce(env, scope, to_form(a)) for a in _sx(call.seq, 4:n)]
    r = _tx_boundary(env) do
        _check!(env, target, :read)
        old = canonicalize(target[])
        newv = _call(env, scope, f, Form[old, args...])
        _ensure_hooks!(env, target)
        _record_write!(env, target)
        setindex!(target, newv)
        newv
    end
    return r
end
special!(Symbol("swap!"), _bi_swap)
special!(Symbol("alter!"), _bi_swap)

# `(tx body…)` — evaluate the block inside one STM transaction and yield its last
# value. It accepts the full `do` grammar (`:let`, `let=`, `catch=`/`throw`,
# `except`, `handle`, and `finally`), all prepared and run inside the boundary.
# Air's `tx` joins an already-open transaction rather than nesting one, so the
# effective commit/rollback boundary is the outermost `tx` (`namespace`,
# `load-air`, a logic-set edit, and `set!` are transactional too). An uncaught
# error aborts that outermost transaction; a throw caught outside it commits
# first (see `_tx_boundary`). Watches run at the end of the body of that outermost
# transaction, so their effects are part of it.
function _bi_tx(env::Env, scope::Scope, call::FormContainer)
    block = _parse_block(call, "tx")
    r = _tx_boundary(env) do
        prep = _prepare_block(env, scope, block, "tx")
        _run_block(env, prep)
    end
    return _Final(r)
end
special!(:tx, _bi_tx)
