################################################################################
# users.jl
#
# Users, homes, and the boot-time system namespaces.
#
# A user id is a keyword: `:air`, `:bob`, or a constituent `:admin:name`. System
# users live under `.sys.user`; a core user `bob` has the namespace
# `.sys.user.bob` holding its `details` and `home`, while a constituent
# `game:bob` lives at `.sys.user.game.constituent.bob`. The current user, the
# current namespace, the database root `@`, and `.env` are task-local Air `Var`s
# so a `task` inherits them and `as-user` can scope them.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _SYS = Symbol("sys")
const _USER = Symbol("user")
const _CONSTITUENT = Symbol("constituent")
const _HOME = Symbol("home")
const _DETAILS = Symbol("details")
const _ENV_VAL = Symbol("env")
const _LIB = Symbol("lib")
const _MAIN = Symbol("main")

# ---- names -------------------------------------------------------------------

# A namespace (and user) name segment: nonempty, not the single `_`, no leading
# digit, no leading `-` followed by a digit, and containing only letters, digits,
# `-`, and `_`. At least one letter or digit is required, so `-` and `_` alone are
# not names.
function _valid_name_segment(s::AbstractString)
    isempty(s) && return false
    s == "_" && return false
    (length(s) > 1 && s[1] == '-' && isdigit(s[2])) && return false
    isdigit(s[1]) && return false
    any(c -> isletter(c) || isdigit(c), s) || return false
    return all(c -> isletter(c) || isdigit(c) || c == '-' || c == '_', s)
end

_split_user_id(id::Symbol) = Symbol.(split(String(id), ':'))

# A user id has one segment (`bob`, a core user) or two (`game:bob`, a
# constituent); constituents do not nest.
function _valid_user_id(id::Symbol)
    parts = _split_user_id(id)
    (1 <= length(parts) <= 2) || return false
    return all(p -> _valid_name_segment(String(p)), parts)
end

# `(kind, admin, name)`: `kind` is `:core`, `:constituent`, or `:invalid`.
function _user_kind(id::Symbol)
    parts = _split_user_id(id)
    length(parts) == 1 && return (:core, nothing, parts[1])
    length(parts) == 2 && return (:constituent, parts[1], parts[2])
    return (:invalid, nothing, nothing)
end

# The namespace holding a system user's record, or `nothing` for a malformed id.
function _system_user_path(id::Symbol)
    kind, admin, name = _user_kind(id)
    kind === :core && return Symbol[_SYS, _USER, name]
    kind === :constituent && return Symbol[_SYS, _USER, admin, _CONSTITUENT, name]
    return nothing
end

function _system_home_path(id::Symbol)
    path = _system_user_path(id)
    path === nothing && return nothing
    return vcat(path, Symbol[_HOME])
end

# The path of the database root this task is attached to, or `nothing` when it
# is not attached to an opened database (`.` for a system user is not a root).
function _context_db_path(env::Env)
    r = _context(env).dbroot
    r isa Form || return nothing
    ns = _ns_from_value(env, r)
    return ns === nothing ? nothing : copy(ns.path)
end

# The namespace holding a user's record: `.sys.user.<name>` for a system user, or
# `@.user.<name>` in the attached database. `air` always uses its system record.
function _user_base_path(env::Env, id::Symbol)
    dbp = _context_db_path(env)
    if dbp !== nothing && id !== _AIR
        kind, admin, name = _user_kind(id)
        kind === :core && return vcat(dbp, Symbol[_USER, name])
        kind === :constituent &&
            return vcat(dbp, Symbol[_USER, admin, _CONSTITUENT, name])
    end
    return _system_user_path(id)
end

function _user_home_path(env::Env, id::Symbol)
    path = _user_base_path(env, id)
    path === nothing && return nothing
    return vcat(path, Symbol[_HOME])
end

_keyword_form(id::Symbol) = Form(Symbol(":", String(id)))

# ---- user records ------------------------------------------------------------

# The stored `details` value for a user: `(admin=true)` or, for a constituent,
# `(admin=false admin-of=:game)`.
function _user_details_form(admin::Bool, parent::Union{Nothing,Symbol})
    map = Pair{Symbol,Form}[Symbol(":admin") => Form(admin)]
    parent === nothing || push!(map, Symbol(":admin-of") => Form(parent))
    return _ns_form(Form[], map)
end

# `(admin = Bool, parent = Union{Nothing,Symbol})`, or `nothing` if the user has
# no record. Reading a record is a system operation, so it bypasses the
# air-only access control on `.sys.user`.
function _user_details(env::Env, id::Symbol)
    path = _user_base_path(env, id)
    path === nothing && return nothing
    ns = _ns_lookup(env, path)
    ns === nothing && return nothing
    marker = _ns_map_get(env, ns, Symbol(":details"))
    marker === nothing && return nothing
    v = _ns_val_value(env, marker; check = false)
    v isa FormContainer || return (admin = false, parent = nothing)
    admin = haskey(v, Symbol(":admin")) && truthy(to_form(v[Symbol(":admin")]))
    parent = if haskey(v, Symbol(":admin-of"))
        s = _symbolof(to_form(v[Symbol(":admin-of")]))
        s === nothing ? nothing : _bindname(s)
    else
        nothing
    end
    return (admin = admin, parent = parent)
end

_user_exists(env::Env, id::Symbol) = _user_details(env, id) !== nothing

function _is_admin(env::Env, id::Symbol)
    id === _AIR && return true
    d = _user_details(env, id)
    return d !== nothing && d.admin
end

# The user a task currently runs as. Before bootstrap this is `air`; the `Var` is
# set to `:air` as part of `_bootstrap!`.
function _current_user(env::Env)
    u = _context(env).user
    return u isa Symbol ? u : _AIR
end

# The home namespace of a user, or `nothing` if it is absent.
function _home_ns(env::Env, id::Symbol)
    path = _user_home_path(env, id)
    path === nothing && return nothing
    return _ns_lookup(env, path)
end

# `$` — the current user's home. It is a capability: it is returned directly, so
# the user need not be able to read the namespaces that contain it.
function _home_volatile(env::Env)
    id = _current_user(env)
    ns = _home_ns(env, id)
    ns === nothing &&
        throw(AirEvalError("user :$id has no home namespace"))
    return ns.vf
end

# `@` — the root namespace of the database the current user is attached to; for a
# system user that is `.`.
function _at_root(env::Env)
    r = _context(env).dbroot
    return r isa Form ? r : _ns_root(env)
end

# ---- creation and bootstrap --------------------------------------------------

# Evaluate `f` as `air`: a system operation (creating a user's record, say) may
# write beneath the air-only `.sys` namespace even when an admin requested it.
function _as_air(env::Env, f::Function)
    c = _context(env)
    prev = c.user
    c.user = _AIR
    try
        return f()
    finally
        c.user = prev
    end
end
_as_air(f::Function, env::Env) = _as_air(env, f)   # do-block form

# Create the user's record and home. `parent` is set only for a constituent.
function _create_system_user!(env::Env, id::Symbol; admin::Bool = false,
                              parent::Union{Nothing,Symbol} = nothing)
    _valid_user_id(id) || throw(AirEvalError("invalid user name :$id"))
    _user_exists(env, id) && throw(AirDefError("user :$id already exists"))
    path = _user_base_path(env, id)
    path === nothing && throw(AirEvalError("invalid user name :$id"))
    return _as_air(env) do
        tx() do
            ns = _ns_ensure!(env, path)
            _ns_add_val!(env, ns, Form(_DETAILS), _user_details_form(admin, parent))
            _ns_ensure!(env, _user_home_path(env, id))
            ns
        end
    end
end

# Every user id in the process, core users first under their own namespace and
# each core user's constituents after it. DB users are not included.
function _user_ids_under(env::Env, base::Vector{Symbol})
    up = _ns_lookup(env, vcat(base, Symbol[_USER]))
    up === nothing && return Symbol[]
    v = _ns_map(env, up)
    v === nothing && return Symbol[]
    ids = Symbol[]
    for (k, _) in v.map
        name = _bindname(k)
        push!(ids, name)
        cns = _ns_lookup(env, vcat(base, Symbol[_USER, name, _CONSTITUENT]))
        cns === nothing && continue
        cv = _ns_map(env, cns)
        cv === nothing && continue
        for (ck, _) in cv.map
            push!(ids, Symbol(name, ":", _bindname(ck)))
        end
    end
    return ids
end

# Every user id in scope: the system users, plus the attached database's users
# when this task is attached.
function _user_ids(env::Env)
    ids = _user_ids_under(env, Symbol[_SYS])
    dbp = _context_db_path(env)
    dbp === nothing || append!(ids, _user_ids_under(env, dbp))
    return sort!(unique!(ids); by = String)
end

# The user ids `me` may see: `air` sees everyone; an admin sees itself and its
# constituents; everyone else sees only itself.
function _visible_user_ids(env::Env, me::Symbol)
    me === _AIR && return _user_ids(env)
    ids = Symbol[me]
    d = _user_details(env, me)
    if d !== nothing && d.admin
        for id in _user_ids(env)
            kind, admin, _ = _user_kind(id)
            (kind === :constituent && admin === me) && push!(ids, id)
        end
    end
    return sort!(ids; by = String)
end

# Create the process namespaces and register `air`. `Env` calls this after the
# builtin constants and stdlib are in place. The body runs in one transaction. A
# process database that already holds the system namespaces (a reopened database
# used as `Env(db = …)`, or a second environment over one) is reused as-is.
function _bootstrap!(env::Env)
    env.booted[] && return env
    env.booted[] = true
    return tx() do
        _ns_ensure!(env, Symbol[_SYS])
        _ns_ensure!(env, Symbol[_LIB])
        _ns_ensure!(env, Symbol[_MAIN])
        _user_exists(env, _AIR) || _create_system_user!(env, _AIR; admin = true)
        root = _ns_lookup_root(env)
        if _ns_map_get(env, root, Symbol(":env")) === nothing
            _ns_add_val!(env, root, Form(_ENV_VAL), naught;
                         doc = "The task's environment mapping.")
        end
        _ensure_system_namespace!(env)
        c = _context(env)
        c.user = _AIR
        c.ns = _ns_lookup(env, Symbol[_MAIN])
        env
    end
end

# ---- user builtins -----------------------------------------------------------

# A user-id argument: a keyword (`:bob`, `:game:bob`), a raw symbol, or a string.
function _user_id_arg(env::Env, scope::Scope, form::Form)
    v = air_reduce(env, scope, form)
    l = _leafof(v)
    if l isa Symbol
        return _bindname(l)
    elseif l isa AbstractString
        return Symbol(l)
    end
    throw(AirEvalError("expected a user name, got $(air_string(v))"))
end

builtin!(Symbol("current-user"), (env, scope, args) -> begin
    isempty(args) || throw(AirEvalError("current-user takes no arguments"))
    return _keyword_form(_current_user(env))
end)

# The owner of the `def` currently being evaluated, else the current user.
builtin!(:owner, (env, scope, args) -> begin
    isempty(args) || throw(AirEvalError("owner takes no arguments"))
    r = _scope_rule(scope)
    o = (r !== nothing && r.owner !== nothing) ? r.owner : _current_user(env)
    return _keyword_form(o)
end)

builtin!(:users, (env, scope, args) -> begin
    isempty(args) || throw(AirEvalError("users takes no arguments"))
    ids = _visible_user_ids(env, _current_user(env))
    seq = FormValue[_store_form(_keyword_form(id)) for id in ids]
    return FormContainer(FormSeq(seq), FormMap())
end)

# `(as-user id body…)` — evaluate `body` as `id`, with that user's home as the
# current namespace. `air` may assume anyone; an admin may assume itself and its
# constituents; any user may assume itself. The switch is dynamic: it ends with
# the form, and a `task` created inside it inherits it.
function _bi_as_user(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("as-user needs a user"))
    id = _user_id_arg(env, scope, to_form(call.seq[2]))
    _valid_user_id(id) || throw(AirEvalError("invalid user name :$id"))
    d = _user_details(env, id)
    d === nothing && throw(AirEvalError("no such user: :$id"))
    me = _current_user(env)
    allowed = me === _AIR || me === id || (d.parent !== nothing && d.parent === me)
    allowed ||
        throw(AirEvalError("permission denied: :$me cannot assume :$id"))
    home = _home_ns(env, id)
    home === nothing && throw(AirEvalError("user :$id has no home namespace"))
    c = _context(env)
    prevuser, prevns = c.user, c.ns
    c.user, c.ns = id, home
    try
        bscope = _base_scope(env)
        r = naught
        for i in 3:length(call.seq)
            r = air_reduce(env, bscope, to_form(call.seq[i]))
        end
        return _Final(r)
    finally
        c.user, c.ns = prevuser, prevns
    end
end
special!(Symbol("as-user"), _bi_as_user)

# `(create-user name)` — `air` creates a core user with a home.
function _bi_create_user(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 || throw(AirEvalError("create-user expects a user name"))
    _current_user(env) === _AIR ||
        throw(AirEvalError("only air may create users"))
    id = _user_id_arg(env, scope, to_form(call.seq[2]))
    _valid_user_id(id) || throw(AirEvalError("invalid user name :$id"))
    _user_kind(id)[1] === :core ||
        throw(AirEvalError("a core user name cannot contain ':'"))
    _create_system_user!(env, id)
    return _keyword_form(id)
end
special!(Symbol("create-user"), _bi_create_user)

# `(create-constituent name)` — an admin creates `admin:name`. `air` creates
# `air:name`; to make `game:bob`, run this as `:game`.
function _bi_create_constituent(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 ||
        throw(AirEvalError("create-constituent expects a name"))
    me = _current_user(env)
    _is_admin(env, me) ||
        throw(AirEvalError("only an admin may create constituents"))
    _user_kind(me)[1] === :core ||
        throw(AirEvalError("a constituent cannot create constituents"))
    name = _user_id_arg(env, scope, to_form(call.seq[2]))
    _valid_name_segment(String(name)) ||
        throw(AirEvalError("invalid constituent name :$name"))
    id = Symbol(me, ":", name)
    _create_system_user!(env, id; parent = me)
    return _keyword_form(id)
end
special!(Symbol("create-constituent"), _bi_create_constituent)

# `(set-admin id flag)` — only `air`; only a core user may be made an admin (a
# constituent cannot have constituents of its own).
function _bi_set_admin(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 3 ||
        throw(AirEvalError("set-admin expects a user and a boolean"))
    _current_user(env) === _AIR ||
        throw(AirEvalError("only air may change admin status"))
    id = _user_id_arg(env, scope, to_form(call.seq[2]))
    _user_kind(id)[1] === :core ||
        throw(AirEvalError("only a core user may be an admin"))
    _user_exists(env, id) || throw(AirEvalError("no such user: :$id"))
    flag = truthy(air_reduce(env, scope, to_form(call.seq[3])))
    path = _user_base_path(env, id)
    tx() do
        ns = _ns_lookup(env, path)
        ns === nothing && throw(AirEvalError("no such user: :$id"))
        _ns_add_val!(env, ns, Form(_DETAILS), _user_details_form(flag, nothing))
    end
    return _keyword_form(id)
end
special!(Symbol("set-admin"), _bi_set_admin)

# ---- .env --------------------------------------------------------------------

# `(env)` — the current task's environment mapping.
builtin!(:env, (env, scope, args) -> begin
    isempty(args) || throw(AirEvalError("env takes no arguments"))
    return canonicalize(_context(env).env)
end)

# `(with-env mapping body…)` — merge `mapping` into `.env` for the dynamic extent
# of `body` (and for any `task` created there).
function _bi_with_env(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("with-env needs a mapping"))
    m = air_reduce(env, scope, to_form(call.seq[2]))
    (m isa FormContainer && isempty(m.seq)) ||
        throw(AirEvalError("with-env needs a single mapping"))
    cur = _context(env).env
    pairs = Pair{Symbol,Form}[]
    if cur isa FormContainer
        for (k, v) in cur.map
            push!(pairs, k => to_form(v))
        end
    end
    for (k, v) in m.map
        i = findfirst(p -> p.first == k, pairs)
        if i === nothing
            push!(pairs, k => to_form(v))
        else
            pairs[i] = k => to_form(v)
        end
    end
    merged = canonicalize(_ns_form(Form[], pairs))
    c = _context(env)
    prev = c.env
    c.env = merged
    try
        r = naught
        for i in 3:length(call.seq)
            r = air_reduce(env, scope, to_form(call.seq[i]))
        end
        return _Final(r)
    finally
        c.env = prev
    end
end
special!(Symbol("with-env"), _bi_with_env)
