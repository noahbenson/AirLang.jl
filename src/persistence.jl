################################################################################
# persistence.jl
#
# The persistence surface: the database a form belongs to, AirDB named forms,
# flushing and status, form identity, and the JSON codec.
#
# A form's database is always the database of the namespace a form is written
# in: `sysdb` for the system namespaces and the current namespace of a system
# user, and the opened database that roots the namespace otherwise. There is no
# ambient database, so `mut`, logic sets, and named forms all agree.
#
# AirDB's name table maps a name to a `VolatileForm` — never to an immutable
# form. A named form is therefore an alias for a volatile, and a logic set is
# just a named volatile whose value has the logic-set shape.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# Names beginning `air/` belong to air itself (`air/ns/...` is the namespace
# table); the user-facing surface cannot see or create them.
const _NAMED_RESERVED = "air/"

const _NAMED_CREATE_KEY = Symbol(":create")
const _NAMED_VALUE_KEY = Symbol(":value")
const _NAMED_HISTORY_KEY = Symbol(":history")

# ---- the persistence database ------------------------------------------------

"""
    _persist_db(env) -> AbstractDatabase

The database the current namespace lives in. A form's database is a property of
where it is written, not of the environment, so this is the single rule used by
`mut`, `logic-set`, the named-form builtins, and the JSON codec.
"""
function _persist_db(env::Env)
    ns = _context(env).ns
    ns isa Namespace ||
        throw(AirEvalError("no database is available: there is no current namespace"))
    return _ns_db(env, ns)
end

# The namespace that roots `db` in `env`, or `nothing` when `db` is not open.
function _persist_root(env::Env, db::AirDB.AbstractDatabase)
    path = db === env.sysdb ? Symbol[] : _db_root_path(env, db)
    path === nothing && return nothing
    return _ns_lookup(env, path)
end

# The database a `sync`/`status` target belongs to.
function _db_target(env::Env, scope::Scope, form::Form)
    v = air_reduce(env, scope, to_form(form))
    v isa VolatileForm && return v.db
    throw(AirEvalError("expected a namespace or volatile, got $(air_string(v))"))
end

# ---- names -------------------------------------------------------------------

# The form a permission denial about a named form reports.
_named_target(name::AbstractString) = Form(Symbol(":" * String(name)))

# A name argument is a symbol/keyword or a string; keywords lose their colon, and
# the internal `air/` prefix is reserved.
function _named_name_arg(env::Env, scope::Scope, form::Form)
    v = _leafof(air_reduce(env, scope, to_form(form)))
    name = if v isa Symbol
        String(_bindname(v))
    elseif v isa AbstractString
        String(v)
    else
        throw(AirEvalError(
            "expected a symbol or string name, got $(air_string(to_form(v)))"))
    end
    isempty(name) && throw(AirEvalError("a named form needs a non-empty name"))
    startswith(name, _NAMED_RESERVED) &&
        throw(AirEvalError("the name \"$name\" is reserved: \"$(_NAMED_RESERVED)\" " *
                           "is the air-internal namespace"))
    return name
end

# `create=` — false (lookup, error if absent), true (create), or naught (lookup,
# naught if absent).
function _named_create_opt(env::Env, scope::Scope, call::FormContainer)
    haskey(call.map, _NAMED_CREATE_KEY) || return false
    l = _leafof(air_reduce(env, scope, to_form(call.map[_NAMED_CREATE_KEY])))
    l === nothing && return nothing
    l isa Bool && return l
    throw(AirEvalError("create must be true, false, or naught"))
end

function _named_bool_opt(env::Env, scope::Scope, call::FormContainer, key::Symbol,
                         default::Bool)
    haskey(call.map, key) || return default
    l = _leafof(air_reduce(env, scope, to_form(call.map[key])))
    l isa Bool && return l
    throw(AirEvalError("$(_user_of_key(key)) must be true or false"))
end

# Run an AirDB name-table operation, turning its `ArgumentError`s (a duplicate
# or missing name) into air errors.
function _named_call(f::Function)
    return try
        f()
    catch e
        e isa ArgumentError && throw(AirEvalError(sprint(showerror, e)))
        rethrow()
    end
end

# Creating a name publishes state from the current namespace, so it needs write
# there; the name must also be free, so no one else's entry is replaced.
function _check_named_create!(env::Env)
    me = _current_user(env)
    db = _persist_db(env)
    _check_db_principal!(env, db, me)
    ns = _context(env).ns
    _check!(env, ns.vf, :write, _ns_path_form(ns.path))
    return me
end

# ---- named-form builtins -----------------------------------------------------

# `(named-form name create=… value=… history=…)` — open (or create) the volatile
# registered under `name` in the current database.
function _bi_named_form(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("named-form needs a name"))
    _check_options(call, "named-form",
                   (_NAMED_CREATE_KEY, _NAMED_VALUE_KEY, _NAMED_HISTORY_KEY))
    name = _named_name_arg(env, scope, to_form(call.seq[2]))
    db = _persist_db(env)
    create = _named_create_opt(env, scope, call)
    existing = _named_call(() -> named_form(db, name; create = nothing))
    if create === nothing
        existing === nothing && return naught
        _check!(env, existing, :read, _named_target(name))
        return existing
    elseif create === false
        existing === nothing && throw(AirEvalError("no form is named \"$name\""))
        _check!(env, existing, :read, _named_target(name))
        return existing
    end
    existing === nothing ||
        throw(AirEvalError("the name \"$name\" is already in use"))
    me = _check_named_create!(env)
    haskey(call.map, _NAMED_VALUE_KEY) || return _named_call() do
        named_form(db, name; create = true, value = form(),
                   metadata = _metadata_form(me; acl = _perms_acl(me)),
                   history = _named_bool_opt(env, scope, call, _NAMED_HISTORY_KEY, true))
    end
    value = air_reduce(env, scope, to_form(call.map[_NAMED_VALUE_KEY]))
    if value isa VolatileForm
        value.db === db || throw(AirUnstorable(value))
        _check!(env, value, :read, _named_target(name))
        return _named_call(() -> named_form(db, name; create = true, value = value))
    end
    _check_storable!(env, db, value)
    return _named_call() do
        named_form(db, name; create = true, value = value,
                   metadata = _metadata_form(me; acl = _perms_acl(me)),
                   history = _named_bool_opt(env, scope, call, _NAMED_HISTORY_KEY, true))
    end
end
special!(Symbol("named-form"), _bi_named_form)

# `(name-form! name volatile)` — point `name` at an existing volatile. A free
# name is created like `named-form`; overwriting an existing alias needs write on
# the form currently named (or on the database root, for its administrator).
function _bi_name_form(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 3 ||
        throw(AirEvalError("name-form! needs a name and a volatile form"))
    _check_options(call, "name-form!", ())
    name = _named_name_arg(env, scope, to_form(call.seq[2]))
    vf = air_reduce(env, scope, to_form(call.seq[3]))
    vf isa VolatileForm ||
        throw(AirEvalError("name-form! expects a volatile form, got $(air_string(vf))"))
    db = _persist_db(env)
    vf.db === db || throw(AirUnstorable(vf))
    _check!(env, vf, :read, _named_target(name))
    existing = _named_call(() -> named_form(db, name; create = nothing))
    if existing === nothing
        _check_named_create!(env)
    elseif !_can(env, existing, :write)
        root = _persist_root(env, db)
        root === nothing ? _check!(env, existing, :write) :
            _check!(env, root.vf, :write, _ns_path_form(root.path))
    end
    return _named_call(() -> name_form!(db, name, vf))
end
special!(Symbol("name-form!"), _bi_name_form)

# `(named-forms)` — the readable, non-internal names in the current database, as
# a mapping from keyword name to volatile.
function _bi_named_forms(env::Env, scope::Scope, args)
    isempty(args) || throw(AirEvalError("named-forms takes no arguments"))
    db = _persist_db(env)
    pairs = Pair{Symbol,Form}[]
    for (name, vf) in named_forms(db)
        nm = String(name)
        startswith(nm, _NAMED_RESERVED) && continue
        _can(env, vf, :read) || continue
        push!(pairs, Symbol(":" * nm) => vf)
    end
    sort!(pairs; by = p -> String(first(p)))
    return _ns_form(Form[], pairs)
end
builtin!(Symbol("named-forms"), _bi_named_forms)

# ---- sync and status ---------------------------------------------------------

# Flush `db` from a task with no open transaction. Air defers a `send` made inside
# a transaction until the transaction commits, so a flush message sent from there
# would wait for a message that cannot be delivered yet. A fresh task has no
# transaction of its own, so the barrier runs immediately there and covers every
# write already scheduled; the enclosing transaction's writes are scheduled only
# when it commits, after this call returns.
function _sync_database(db::AirDB.AbstractDatabase)
    currtx() === nothing && return AirDB.sync(db)
    ch = Channel{Any}(1)
    t = Task() do
        try
            AirDB.sync(db)
            put!(ch, nothing)
        catch e
            put!(ch, e)
        end
    end
    schedule(t)
    r = take!(ch)
    r === nothing || throw(r)
    return nothing
end

# `(sync)` / `(sync target)` — wait until every write committed before the call
# has been flushed. This is a barrier, not a drain: writes committed by other
# tasks after the flush message is queued do not delay it, and the writer actor
# is sequential, so the flush cannot be starved by continuing activity.
function _bi_sync(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) <= 2 || throw(AirEvalError("sync takes at most one target"))
    _check_options(call, "sync", ())
    db = length(call.seq) == 2 ? _db_target(env, scope, to_form(call.seq[2])) :
        _persist_db(env)
    _sync_database(db)
    return naught
end
special!(:sync, _bi_sync)

# `(status)` / `(status target)` — `(pending=N error=naught)`.
function _bi_status(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) <= 2 || throw(AirEvalError("status takes at most one target"))
    _check_options(call, "status", ())
    db = length(call.seq) == 2 ? _db_target(env, scope, to_form(call.seq[2])) :
        _persist_db(env)
    npending, err = AirDB.status(db)
    return _ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":pending") => Form(Int(npending)),
        Symbol(":error") => (err === nothing ? naught : Form(sprint(showerror, err)))])
end
special!(:status, _bi_status)

# ---- identity and loading ----------------------------------------------------

# `(form-id volatile)` — the form's UUID as a string.
builtin!(Symbol("form-id"), (env, scope, args) -> begin
    x = _arg(args, 1, "form-id")
    x isa VolatileForm ||
        throw(AirEvalError("form-id expects a volatile form, got $(air_string(x))"))
    return Form(string(x.id))
end)

# `(form-at id)` — the volatile with that UUID in the current database. The body
# is not loaded; an unknown id yields a handle that fails when it is read.
builtin!(Symbol("form-at"), (env, scope, args) -> begin
    x = _arg(args, 1, "form-at")
    l = _leafof(x)
    l isa AbstractString ||
        throw(AirEvalError("form-at expects a UUID string, got $(air_string(x))"))
    id = try
        Base.UUID(l)
    catch
        throw(AirEvalError("\"$l\" is not a UUID"))
    end
    return get_form(_persist_db(env), id)
end)

# `(loaded? volatile)` — whether the body has been read into memory.
builtin!(Symbol("loaded?"), (env, scope, args) -> begin
    x = _arg(args, 1, "loaded?")
    x isa VolatileForm ||
        throw(AirEvalError("loaded? expects a volatile form, got $(air_string(x))"))
    return Form(isloaded(x))
end)

# `(history volatile)` — whether the form records its history.
builtin!(Symbol("history"), (env, scope, args) -> begin
    x = _arg(args, 1, "history")
    x isa VolatileForm ||
        throw(AirEvalError("history expects a volatile form, got $(air_string(x))"))
    return Form(history(x))
end)

# ---- JSON --------------------------------------------------------------------

# A bare volatile is written as a JSON link string; `to_JSON(vf)` gives the bare
# link text, which then needs its quotes.
_json_text(x::Form) = x isa VolatileForm ? string('"', to_JSON(x), '"') : to_JSON(x)

# `(to-json value)` — the value as JSON text. Volatiles become `"@uuid"` links,
# so cyclic structures encode.
builtin!(Symbol("to-json"), (env, scope, args) -> begin
    x = _arg(args, 1, "to-json")
    s = try
        _json_text(x)
    catch e
        throw(AirEvalError("could not encode JSON: " * sprint(showerror, e)))
    end
    return Form(s)
end)

# `(from-json text)` — read a form, resolving `"@uuid"` links through the current
# database and extern references through its resource registry.
builtin!(Symbol("from-json"), (env, scope, args) -> begin
    x = _arg(args, 1, "from-json")
    l = _leafof(x)
    l isa AbstractString ||
        throw(AirEvalError("from-json expects a string, got $(air_string(x))"))
    return try
        _normalize_empty(from_JSON(_persist_db(env), l))
    catch e
        e isa AirDB.FormNotFound && rethrow()
        throw(AirEvalError("invalid JSON: " * sprint(showerror, e)))
    end
end)
