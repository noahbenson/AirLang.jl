################################################################################
# database.jl
#
# Opened databases: `(open-airdb name opts…)` creates or opens an AirDB
# `Database`, roots a namespace at `name` in it, and attaches `@` to that root
# for the current task; `(close-airdb name)` detaches it.
#
# A namespace at or under an opened root lives in that database rather than in
# the process-level `sysdb` (see `_ns_db`). Its users live under `@.user.<name>`
# and hydrate lazily, like any other database-backed form. A database holds
# permissions only for its own users and refuses a form that embeds a volatile
# from another database (`(:un-storable …)`).
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- database roots ----------------------------------------------------------

# The path of the namespace rooting `db`, or `nothing` if it is not open.
function _db_root_path(env::Env, db::AirDB.AbstractDatabase)
    for (t, d) in env.dbs
        d === db && return Symbol[t...]
    end
    return nothing
end

# The record path of a user of `db`.
function _db_user_record_path(env::Env, db::AirDB.AbstractDatabase, id::Symbol)
    root = _db_root_path(env, db)
    root === nothing && return nothing
    kind, admin, name = _user_kind(id)
    kind === :core && return vcat(root, Symbol[_USER, name])
    kind === :constituent &&
        return vcat(root, Symbol[_USER, admin, _CONSTITUENT, name])
    return nothing
end

function _db_user_ids(env::Env, db::AirDB.AbstractDatabase)
    root = _db_root_path(env, db)
    root === nothing && return Symbol[]
    return _user_ids_under(env, root)
end

function _db_user_exists(env::Env, db::AirDB.AbstractDatabase, id::Symbol)
    path = _db_user_record_path(env, db, id)
    path === nothing && return false
    return _ns_lookup(env, path) !== nothing
end

# A principal stored in a database must be one of that database's users (`air`
# is always allowed). The opener of a brand-new database is accepted so that the
# root namespace can be created before its first user record exists.
function _check_db_principal!(env::Env, db::AirDB.AbstractDatabase, id::Symbol)
    db === env.sysdb && return id
    (id === _AIR || _db_user_exists(env, db, id)) && return id
    (id === _current_user(env) && isempty(_db_user_ids(env, db))) && return id
    throw(AirEvalError(":$id is not a user of this database"))
end

# Every user named in an ACL must belong to the database (or `_`).
function _check_db_acl!(env::Env, db::AirDB.AbstractDatabase, acl)
    db === env.sysdb && return nothing
    acl === nothing && return nothing
    for (_, users) in acl
        for u in keys(users)
            u === _ALL_USERS && continue
            _check_db_principal!(env, db, u)
        end
    end
    return nothing
end

# ---- storable forms ----------------------------------------------------------

# Walk `x` and refuse any volatile that does not belong to `db`: a form bound for
# a database must not embed a link it cannot resolve there.
function _walk_storable!(db::AirDB.AbstractDatabase, x::Form)
    if x isa VolatileForm || x isa ActorForm || x isa StreamForm
        x.db === db || throw(AirUnstorable(x))
    elseif x isa PromiseForm
        x.db === db || throw(AirUnstorable(x))
        # A delivered promise is stored as its value, so that value's own links
        # must resolve in this database too.
        isready(x) && _walk_storable!(db, x[])
    elseif x isa DelayForm
        # The delay itself is inline; the cell it names must live here.
        _walk_storable!(db, x.form)
    elseif x isa FormContainer
        for a in x.seq
            _walk_storable!(db, to_form(a))
        end
        for (_, v) in x.map
            _walk_storable!(db, to_form(v))
        end
    end
    return nothing
end

_check_storable!(env::Env, db::AirDB.AbstractDatabase, x::Form) =
    db === env.sysdb ? nothing : _walk_storable!(db, x)

# ---- options -----------------------------------------------------------------

_db_opt(env::Env, scope::Scope, call::FormContainer, name::Symbol) = begin
    key = Symbol(":", String(name))
    haskey(call.map, key) || return nothing
    return air_reduce(env, scope, to_form(call.map[key]))
end

function _db_str_opt(env::Env, scope::Scope, call, name::Symbol)
    v = _db_opt(env, scope, call, name)
    v === nothing && return nothing
    l = _leafof(v)
    l isa AbstractString && return String(l)
    l isa Symbol && return String(_bindname(l))
    throw(AirEvalError("$name must be a string"))
end

function _db_int_opt(env::Env, scope::Scope, call, name::Symbol)
    v = _db_opt(env, scope, call, name)
    v === nothing && return nothing
    l = _leafof(v)
    l isa Integer && return _as_int(l, String(name))
    throw(AirEvalError("$name must be an integer"))
end

function _db_bool_opt(env::Env, scope::Scope, call, name::Symbol)
    v = _db_opt(env, scope, call, name)
    v === nothing && return nothing
    return truthy(v)
end

# Build (or open) the database an `open-airdb` call describes. `memory=true`
# selects an in-memory database, which is what tests use; otherwise `url=` (or
# `conninfo=`) is passed to libpq verbatim, or `dbname=`/`user=`/… configure the
# connection.
function _make_database(env::Env, scope::Scope, call::FormContainer)
    _db_bool_opt(env, scope, call, :memory) === true && return MemoryDatabase()
    url = _db_str_opt(env, scope, call, :url)
    url === nothing && (url = _db_str_opt(env, scope, call, :conninfo))
    create = _db_bool_opt(env, scope, call, :create)
    if url !== nothing
        cfg = DatabaseConfig(url)
    else
        dbname = _db_str_opt(env, scope, call, :dbname)
        user = _db_str_opt(env, scope, call, :user)
        (dbname === nothing || user === nothing) &&
            throw(AirEvalError("open-airdb needs dbname= and user=, or url="))
        host = _db_str_opt(env, scope, call, :host)
        password = _db_str_opt(env, scope, call, :password)
        sslmode = _db_str_opt(env, scope, call, :sslmode)
        port = _db_int_opt(env, scope, call, :port)
        cfg = DatabaseConfig(; dbname = dbname, user = user,
                             host = host === nothing ? "localhost" : host,
                             port = port === nothing ? 5432 : port,
                             password = password,
                             sslmode = sslmode === nothing ? "prefer" : sslmode)
    end
    if create === true
        return create_database(cfg)
    elseif create === false
        return open_database(cfg)
    end
    try
        return open_database(cfg)
    catch
        return create_database(cfg)
    end
end

# The path a database root gets: a bare name is created in the current
# namespace, an explicit `.path` (or `@.path`) is absolute.
function _open_target_path(env::Env, scope::Scope, form::Form)
    s = _symbolof(form)
    if s !== nothing && is_raw_symbol(s) && s !== DOT_ROOT && s !== HOME_ROOT &&
       s !== AT_ROOT && scope_get(scope, s) === nothing
        cur = _context(env).ns
        base = cur isa Namespace ? copy(cur.path) : Symbol[]
        return vcat(base, Symbol[_bindname(s)])
    end
    return _ns_target_path(env, scope, form)
end

# Create the opener's user record in a new database (unless the opener is `air`,
# which is always a principal). `details` is the opener's system record, whose
# admin/parent status carries over.
function _ensure_db_user!(env::Env, db::AirDB.AbstractDatabase, opener::Symbol,
                          details)
    opener === _AIR && return nothing
    _db_user_exists(env, db, opener) && return nothing
    _create_system_user!(env, opener;
                         admin = details === nothing ? false : details.admin,
                         parent = details === nothing ? nothing : details.parent)
    return nothing
end

"""
    open_airdb!(env, path, db; opener = current-user) -> VolatileForm

Root the namespace at `path` in `db` and attach `@` to it for the current task.
An existing root (and everything stored under it) is reused, which is how a
reopened database recovers its namespaces. The Julia-level entry point for
`(open-airdb …)`, and the way a test opens a `MemoryDatabase` directly.
"""
function open_airdb!(env::Env, path::Vector{Symbol}, db::AirDB.AbstractDatabase;
                     opener::Symbol = _current_user(env))
    key = Tuple(path)
    c = _context(env)
    prevroot = c.dbroot
    registered = false
    try
        # The opener's system record, read before attachment changes where a
        # user record is looked for.
        details = _user_details(env, opener)
        root = tx() do
            haskey(env.dbs, key) && throw(AirEvalError(
                "a database is already open at $(_ns_display(path))"))
            # A namespace rooted in another database cannot become this
            # database's root.
            _ns_lookup(env, path; lazy = false) === nothing ||
                throw(AirEvalError(
                    "a namespace already exists at $(_ns_display(path))"))
            env.dbs[key] = db
            registered = true
            existed = named_form(db, _ns_name(path); create = nothing) !== nothing
            ns = _ns_ensure!(env, path)
            c.dbroot = ns.vf
            _ensure_db_user!(env, db, opener, details)
            # A newly created root belongs to its opener, even when the call
            # came from Julia with an opener other than the current user.
            if !existed && opener !== _AIR
                _check_db_principal!(env, db, opener)
                _set_metadata!(ns.vf, _metadata_form(opener;
                                                     acl = _perms_acl(opener)))
            end
            ns.vf
        end
        _flush_metadata!()  # a new root's policy must be in place before use
        return root
    catch
        c.dbroot = prevroot
        registered && delete!(env.dbs, key)
        _purge_namespace_prefix!(env, path)
        try
            close(db)
        catch
        end
        rethrow()
    end
end

# `(open-airdb name opts…)` — open or create a database, root `name` in it, and
# attach `@` to that root for the current task.
function _bi_open_airdb(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("open-airdb needs a name"))
    path = _open_target_path(env, scope, to_form(call.seq[2]))
    db = _make_database(env, scope, call)
    return open_airdb!(env, path, db)
end
special!(Symbol("open-airdb"), _bi_open_airdb)

# Remove a subnamespace marker from its parent's entry list.
function _ns_remove_sub!(env::Env, parent::Namespace, name::Symbol)
    entries = _ns_entries_of(parent.vf)
    kept = Form[e for e in entries
                if !(_entry_head(e) === NS_SUB &&
                     _ns_sub_name(_entry_body(e)) === name)]
    length(kept) == length(entries) && return nothing
    _ns_store_entries!(env, parent, kept)
    return nothing
end

"""
    close_airdb!(env, path) -> nothing

Flush and close the database rooted at `path`, remove the namespace from its
parent, and detach `@` if it pointed at this root.
"""
function close_airdb!(env::Env, path::Vector{Symbol})
    key = Tuple(path)
    # A database rooted beneath this one lives inside a namespace this close
    # removes; close it first, or it is left open and unreachable.
    for k in sort!(collect(keys(env.dbs)); by = length, rev = true)
        (length(k) > length(key) && k[1:length(key)] == key) || continue
        close_airdb!(env, Symbol[k...])
    end
    db = pop!(env.dbs, key, nothing)
    db === nothing &&
        throw(AirEvalError("no open database at $(_ns_display(path))"))
    c = _context(env)
    was_root = c.dbroot isa VolatileForm && c.dbroot.db === db
    try
        _as_air(env) do
            tx() do
                parent = _ns_lookup(env, path[1:(end - 1)])
                parent === nothing || _ns_remove_sub!(env, parent, path[end])
            end
        end
    finally
        _purge_namespace_prefix!(env, path)
        was_root && (c.dbroot = nothing)
        try
            sync(db)
        catch
        end
        try
            close(db)
        catch
        end
    end
    return nothing
end

# `(close-airdb name)` — flush and close the database, remove the namespace, and
# detach `@` (when it pointed at this root).
function _bi_close_airdb(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("close-airdb needs a name"))
    path = _open_target_path(env, scope, to_form(call.seq[2]))
    close_airdb!(env, path)
    return naught
end
special!(Symbol("close-airdb"), _bi_close_airdb)
