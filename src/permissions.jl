################################################################################
# permissions.jl
#
# Ownership and access control for volatiles. Every namespace and every
# namespace entry is a `VolatileForm`; its `metadata` carries the owner, an ACL,
# and (for an entry) its name. The ACL is a mapping from permission to a mapping
# from user to boolean:
#
#     acl=(read=(_=true bob=true)
#          write=(alice=true)
#          exec=(_=true)
#          assume=(game:bob=true)
#          hide=(mallory=true))
#
# `:_` means every user. The defaults give the owner `read`, `write`, and `exec`;
# `assume` is off and every other user has nothing. `hide` is a veto: a listed
# user has no access of any kind. `air` bypasses every check, and a core admin
# has ownership privileges over its constituents' data.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _OWNER_KEY = Symbol(":owner")
const _ACL_KEY = Symbol(":acl")
const _ENTRY_KEY = Symbol(":entry")
const _NAME_KEY = Symbol(":name")
const _ANCHOR_KEY = Symbol(":anchor")
const _SOURCE_META_KEY = Symbol(":source")
const _LINK_KEY = Symbol(":link")
const _HIDDEN_KEY = Symbol(":hidden")
const _WATCH_KEY = Symbol(":watch")
const _FILTER_KEY = Symbol(":filter")
const _FINALIZE_KEY = Symbol(":finalize")
# `filesystem` is the grant that admits a user to the host-path tools; it is
# checked on `.air.sys` rather than on an entry, and no policy grants it by
# default, so a fresh instance admits only `air` (see `_require_filesystem`).
const _PERM_NAMES = (:read, :write, :exec, :readfact, :writefact, :readrule,
                     :writerule, :assume, :hide, :watch, :filter, :finalize,
                     :filesystem)

# The fact/rule permissions a namespace target uses, and the entry permission a
# standalone logic set maps each onto.
const _FACT_RULE_PERMS = (:readfact, :writefact, :readrule, :writerule)
_standalone_logic_perm(perm::Symbol) =
    perm === :readfact || perm === :readrule ? :read : :write
const _ALL_USERS = Symbol("_")

_perm_key(p::Symbol) = Symbol(":", String(p))
_user_key(u::Symbol) = Symbol(":", String(u))
_user_of_key(k::Symbol) = _bindname(k)

# ---- encoding ----------------------------------------------------------------

_perms_acl(owner::Symbol) = Dict{Symbol,Dict{Symbol,Bool}}(
    :read => Dict(owner => true), :write => Dict(owner => true),
    :exec => Dict(owner => true),
    :readfact => Dict(owner => true), :writefact => Dict(owner => true),
    :readrule => Dict(owner => true), :writerule => Dict(owner => true))

# World read/execute, owner write: the core and library namespaces. Facts and
# rules are world-readable too, so `.air` and `.lib` logic is usable by anyone.
_world_read_exec_acl(owner::Symbol = _AIR) = Dict{Symbol,Dict{Symbol,Bool}}(
    :read => Dict(_ALL_USERS => true), :write => Dict(owner => true),
    :exec => Dict(_ALL_USERS => true),
    :readfact => Dict(_ALL_USERS => true), :readrule => Dict(_ALL_USERS => true),
    :writefact => Dict(owner => true), :writerule => Dict(owner => true))

# One permission mapping `(bob=true game:bob=false)` as a user=>bool dict.
function _acl_user_map(x::Form)
    out = Dict{Symbol,Bool}()
    x isa FormContainer || return out
    if isempty(x.seq)
        for (k, v) in x.map
            out[_user_of_key(k)] = truthy(to_form(v))
        end
    else
        # Also accept a flat list of usernames, all granted.
        for v in x.seq
            s = _symbolof(to_form(v))
            s === nothing || (out[_user_of_key(s)] = true)
        end
    end
    return out
end

# An ACL dictionary as a form of permission mappings, in a stable order.
function _acl_form(acl::Dict{Symbol,Dict{Symbol,Bool}})
    pairs = Pair{Symbol,Form}[]
    for p in _PERM_NAMES
        d = get(acl, p, nothing)
        (d === nothing || isempty(d)) && continue
        inner = Pair{Symbol,Form}[_user_key(u) => Form(v)
                                  for (u, v) in sort!(collect(d); by = x -> String(x[1]))]
        isempty(inner) && continue
        push!(pairs, _perm_key(p) => _ns_form(Form[], inner))
    end
    return _ns_form(Form[], pairs)
end

# The metadata a new volatile gets.
function _metadata_form(owner::Symbol; acl = nothing, entry::Bool = false,
                        name::Union{Nothing,Symbol} = nothing,
                        anchor::Bool = false,
                        source::Union{Nothing,Vector{Symbol}} = nothing,
                        link::Union{Nothing,Vector{Symbol}} = nothing,
                        hidden::Bool = false,
                        watch::Union{Nothing,Form} = nothing,
                        filter::Union{Nothing,Form} = nothing,
                        finalize::Union{Nothing,Form} = nothing)
    pairs = Pair{Symbol,Form}[_OWNER_KEY => Form(_user_key(owner))]
    entry && push!(pairs, _ENTRY_KEY => Form(true))
    name === nothing || push!(pairs, _NAME_KEY => Form(_user_key(name)))
    anchor && push!(pairs, _ANCHOR_KEY => Form(true))
    source === nothing || push!(pairs, _SOURCE_META_KEY => _ns_path_form(source))
    link === nothing || push!(pairs, _LINK_KEY => _ns_path_form(link))
    hidden && push!(pairs, _HIDDEN_KEY => Form(true))
    watch === nothing || push!(pairs, _WATCH_KEY => watch)
    filter === nothing || push!(pairs, _FILTER_KEY => filter)
    finalize === nothing || push!(pairs, _FINALIZE_KEY => finalize)
    (acl === nothing || isempty(acl)) || push!(pairs, _ACL_KEY => _acl_form(acl))
    return _ns_form(Form[], pairs)
end

# The metadata of `vf` with selected fields replaced; the hook tables travel with
# the metadata so that `chmod!`/`chown!` never drop a watch, filter, or finalizer.
function _metadata_like(vf::VolatileForm; owner::Symbol = _meta_owner(vf),
                        acl = _meta_acl(vf),
                        anchor::Union{Nothing,Bool} = nothing,
                        watch = _meta_get(vf, _WATCH_KEY),
                        filter = _meta_get(vf, _FILTER_KEY),
                        finalize = _meta_get(vf, _FINALIZE_KEY))
    a = anchor === nothing ? _meta_anchor(vf) : anchor
    return _metadata_form(owner; acl = acl, entry = _is_entry_vf(vf),
                          name = _meta_name(vf), anchor = a,
                          source = _meta_source(vf), link = _meta_link(vf),
                          hidden = _meta_hidden(vf), watch = watch,
                          filter = filter, finalize = finalize)
end

# ---- decoding ----------------------------------------------------------------

_vf_metadata(vf::VolatileForm) = try
    metadata(vf)
catch
    vf.metadata
end

function _meta_form(vf::VolatileForm)
    m = _vf_metadata(vf)
    return m isa FormContainer ? m : nothing
end

function _meta_get(vf::VolatileForm, key::Symbol)
    m = _meta_form(vf)
    (m === nothing || !haskey(m, key)) && return nothing
    return to_form(m[key])
end

function _meta_owner(vf::VolatileForm)
    x = _meta_get(vf, _OWNER_KEY)
    x === nothing && return _AIR
    s = _symbolof(x)
    return s === nothing ? _AIR : _user_of_key(s)
end

function _meta_name(vf::VolatileForm)
    x = _meta_get(vf, _NAME_KEY)
    x === nothing && return nothing
    s = _symbolof(x)
    return s === nothing ? nothing : _user_of_key(s)
end

function _meta_anchor(vf::VolatileForm)
    x = _meta_get(vf, _ANCHOR_KEY)
    return x !== nothing && truthy(x)
end

function _meta_source(vf::VolatileForm)
    x = _meta_get(vf, _SOURCE_META_KEY)
    x === nothing && return nothing
    return _stored_path(x)
end

function _meta_link(vf::VolatileForm)
    x = _meta_get(vf, _LINK_KEY)
    x === nothing && return nothing
    return _stored_path(x)
end

function _meta_hidden(vf::VolatileForm)
    x = _meta_get(vf, _HIDDEN_KEY)
    return x !== nothing && truthy(x)
end

function _meta_acl(vf::VolatileForm)
    out = Dict{Symbol,Dict{Symbol,Bool}}()
    x = _meta_get(vf, _ACL_KEY)
    x isa FormContainer || return out
    for (k, v) in x.map
        perm = _user_of_key(k)
        perm in _PERM_NAMES || continue
        out[perm] = _acl_user_map(to_form(v))
    end
    return out
end

_is_entry_vf(vf::VolatileForm) = _meta_get(vf, _ENTRY_KEY) !== nothing &&
    truthy(_meta_get(vf, _ENTRY_KEY))

# ---- stream metadata ---------------------------------------------------------
#
# A `StreamForm` carries owner+ACL metadata but none of the volatile-only fields
# (entry, name, anchor, source, link, hooks). Its metadata lives in the database
# row and is read lazily, so an unloaded stream must be read through the AirDB
# accessor — reading the raw field would see "no metadata" and bypass the ACL.
# Printing a stream on a closed database must not raise, hence the fallback.

_vf_metadata(sf::StreamForm) = try
    AirDB.metadata(sf)
catch
    sf.metadata
end

_meta_form(sf::StreamForm) =
    (m = _vf_metadata(sf); m isa FormContainer ? m : nothing)

_meta_get(sf::StreamForm, key::Symbol) = begin
    m = _meta_form(sf)
    (m === nothing || !haskey(m, key)) && return nothing
    to_form(m[key])
end

_meta_owner(sf::StreamForm) = begin
    x = _meta_get(sf, _OWNER_KEY)
    s = x === nothing ? nothing : _symbolof(x)
    s === nothing ? _AIR : _user_of_key(s)
end

_meta_acl(sf::StreamForm) = begin
    out = Dict{Symbol,Dict{Symbol,Bool}}()
    x = _meta_get(sf, _ACL_KEY)
    if x isa FormContainer
        for (k, v) in x.map
            perm = _user_of_key(k)
            perm in _PERM_NAMES || continue
            out[perm] = _acl_user_map(to_form(v))
        end
    end
    out
end

_meta_name(::StreamForm) = nothing
_meta_anchor(::StreamForm) = false
_meta_source(::StreamForm) = nothing
_meta_link(::StreamForm) = nothing
_meta_hidden(sf::StreamForm) = (x = _meta_get(sf, _HIDDEN_KEY); x !== nothing && truthy(x))
_is_entry_vf(::StreamForm) = false

_metadata_like(sf::StreamForm; owner::Symbol = _meta_owner(sf),
               acl = _meta_acl(sf), anchor::Bool = false,
               watch = nothing, filter = nothing, finalize = nothing) =
    _metadata_form(owner; acl = acl)

# The stored watch table: a sequence of `(key=… owner=… ns=… fn=…)` forms, in
# registration order. A single watch may be stored as the table itself.
function _meta_watches(vf::VolatileForm)
    x = _meta_get(vf, _WATCH_KEY)
    x === nothing && return nothing
    x isa FormContainer || return nothing
    isempty(x.map) || return Form[x]
    return Form[to_form(v) for v in x.seq]
end

_meta_hook_table(vf::VolatileForm, key::Symbol) = _meta_get(vf, key)

# Replace the watch table, or remove it when `ws` is empty.
_meta_with_watches(vf::VolatileForm, ws::Vector{Form}) =
    _metadata_like(vf; watch = isempty(ws) ? nothing : _ns_form(ws))

# ---- the checks --------------------------------------------------------------

# Whether `user` holds `perm` on `vf`. A non-volatile (a rule without an entry,
# say) is unrestricted. `air` bypasses every check; a hidden user holds nothing.
# A stream carries owner+ACL metadata like a volatile, so it is gated by the same
# logic: `read` is receiving from it and `write` is delivering to it.
function _can(env::Env, vf, user::Symbol, perm::Symbol)
    (vf isa VolatileForm || vf isa StreamForm) || return true
    user === _AIR && return true
    # A volatile with no metadata is unmanaged (an ordinary `mut` created before
    # ownership existed); its contents are unrestricted.
    _meta_form(vf) === nothing && return true
    acl = _meta_acl(vf)
    hide = get(acl, :hide, nothing)
    if hide !== nothing && (get(hide, user, false) || get(hide, _ALL_USERS, false))
        return false
    end
    owner = _meta_owner(vf)
    if owner === user
        perm === :assume && return get(get(acl, :assume, Dict{Symbol,Bool}()), user, false)
        return true
    end
    if perm !== :assume && _admin_of(env, user, owner)
        return true
    end
    d = get(acl, perm, nothing)
    if d === nothing && perm in _FACT_RULE_PERMS
        # Metadata written before the fact/rule permissions existed falls back
        # to the entry permission it split from.
        d = get(acl, _standalone_logic_perm(perm), nothing)
    end
    d === nothing && return false
    haskey(d, user) && return d[user]
    return get(d, _ALL_USERS, false)
end

_can(env::Env, vf, perm::Symbol) = _can(env, vf, _current_user(env), perm)

# A core admin has ownership privileges over its constituents' data.
function _admin_of(env::Env, user::Symbol, owner::Symbol)
    kind, admin, _ = _user_kind(owner)
    kind === :constituent || return false
    admin === user || return false
    return _is_admin(env, user)
end

function _vf_target(env::Env, vf::VolatileForm)
    ns = _ns_from_value(env, vf)
    ns === nothing || return _ns_path_form(ns.path)
    name = _meta_name(vf)
    return name === nothing ? Form(Symbol(":volatile")) : _keyword_form(name)
end

_vf_target(env::Env, ::StreamForm) = Form(Symbol(":stream"))

# Raise unless `user` (by default the current one) holds `perm` on `vf`.
function _check!(env::Env, vf, perm::Symbol, target::Union{Nothing,Form} = nothing;
                 user::Union{Nothing,Symbol} = nothing)
    u = user === nothing ? _current_user(env) : user
    _can(env, vf, u, perm) && return vf
    t = target === nothing ? _vf_target(env, vf) : target
    throw(AirPermissionDenied(perm, t))
end

_check_ns!(env::Env, ns::Namespace, perm::Symbol) =
    _check!(env, ns.vf, perm, _ns_path_form(ns.path))

# A rule compiled from a namespace entry is gated by its entry: calling a `def`
# needs `exec`, resolving a `val` needs `read`. A global or builtin rule is
# unrestricted.
function _check_rule!(env::Env, rule)
    e = rule.entry
    e isa VolatileForm || return true
    _check!(env, e, _is_ns_val(rule.body) ? :read : :exec)
    return true
end

# ---- target resolution -------------------------------------------------------

# The entry volatile a namespace's newest definition of `name` lives in, or
# `nothing`.
function _ns_entry_for(env::Env, ns::Namespace, name::Symbol)
    for e in Iterators.reverse(_ns_entries_of(ns.vf))
        e isa VolatileForm || continue
        b = _entry_body(e)
        b isa FormContainer || continue
        h = head_symbol(b)
        if h === NS_PROXY
            _ns_name_of_fn(b) === name && return e
            continue
        end
        (h === _DEF_HEAD || h === _VAL_HEAD) || continue
        length(b.seq) >= 2 || continue
        _def_name(to_form(b.seq[2])) === name && return e
    end
    return nothing
end

# The volatile a `chmod`/`chown`/`permissions` target names: a volatile value,
# a namespace marker, or a bare name in the current namespace.
function _perm_target(env::Env, scope::Scope, form::Form)
    if form isa FormScalar
        s = _symbolof(form)
        if s !== nothing && s !== HOME_ROOT && s !== AT_ROOT && s !== DOT_ROOT
            name = _user_of_key(s)
            ns = _write_ns(env)
            ns === nothing &&
                throw(AirEvalError("no current namespace for $name"))
            e = _ns_entry_for(env, ns, name)
            e === nothing && throw(AirEvalError(
                "no definition named $name in $(_ns_display(ns.path))"))
            return e
        end
    end
    v = air_reduce(env, scope, form)
    (v isa VolatileForm || v isa StreamForm) && return v
    if _is_ns_proxy(v)
        # An imported proxy is stored in the namespace that imported it; a
        # proxy's marker names the source, so its own entry is found by name in
        # the current namespace.
        name = _ns_name_of_fn(v)
        ns = _write_ns(env)
        e = name === nothing || ns === nothing ? nothing :
            _ns_entry_for(env, ns, name)
        e === nothing && throw(AirEvalError(
            "cannot resolve imported target $(air_string(v))"))
        return e
    end
    if _is_ns_fn(v) || _is_ns_val(v)
        path = _ns_path_of_marker(v)
        name = _ns_name_of_fn(v)
        (path === nothing || name === nothing) &&
            throw(AirEvalError("cannot resolve target $(air_string(v))"))
        ns = _ns_lookup(env, path)
        ns === nothing &&
            throw(AirEvalError("no namespace at $(_ns_display(path))"))
        e = _ns_entry_for(env, ns, name)
        e === nothing && throw(AirEvalError(
            "no definition named $name in $(_ns_display(path))"))
        return e
    end
    throw(AirEvalError("expected a namespace or definition, got $(air_string(v))"))
end

# ---- builtins ----------------------------------------------------------------

function _permissions_form(vf::VolatileForm)
    m = _meta_form(vf)
    m === nothing && return _metadata_form(_AIR; acl = _perms_acl(_AIR))
    pairs = Pair{Symbol,Form}[_OWNER_KEY => Form(_user_key(_meta_owner(vf)))]
    acl = _meta_acl(vf)
    isempty(acl) || push!(pairs, _ACL_KEY => _acl_form(acl))
    _meta_anchor(vf) && push!(pairs, _ANCHOR_KEY => Form(true))
    src = _meta_source(vf)
    src === nothing || push!(pairs, _SOURCE_META_KEY => _ns_path_form(src))
    return _ns_form(Form[], pairs)
end

# A stream has no anchor, name, or source: its permissions are its owner and ACL.
function _permissions_form(sf::StreamForm)
    m = _meta_form(sf)
    m === nothing && return _metadata_form(_AIR; acl = _perms_acl(_AIR))
    pairs = Pair{Symbol,Form}[_OWNER_KEY => Form(_user_key(_meta_owner(sf)))]
    acl = _meta_acl(sf)
    isempty(acl) || push!(pairs, _ACL_KEY => _acl_form(acl))
    return _ns_form(Form[], pairs)
end

# `(permissions target)` — the target's owner and ACL as a mapping.
function _bi_permissions(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 ||
        throw(AirEvalError("permissions expects a single target"))
    vf = _perm_target(env, scope, to_form(call.seq[2]))
    return _permissions_form(vf)
end
special!(:permissions, _bi_permissions)

# `(chmod! target read=(user=true …) write=… exec=… assume=… hide=…)` — replace
# the listed permission mappings. Needs write on the target.
function _bi_chmod(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 || throw(AirEvalError("chmod! expects a target"))
    vf = _perm_target(env, scope, to_form(call.seq[2]))
    _check!(env, vf, :write)
    vf isa StreamForm && haskey(call.map, _ANCHOR_KEY) &&
        throw(AirEvalError("chmod!: a stream has no anchor"))
    acl = _meta_acl(vf)
    anchor = _meta_anchor(vf)
    for (k, v) in call.map
        perm = _user_of_key(k)
        if perm === :anchor
            anchor = truthy(air_reduce(env, scope, to_form(v)))
            continue
        end
        perm in _PERM_NAMES ||
            throw(AirEvalError("unknown permission $(_user_of_key(k))"))
        acl[perm] = _acl_user_map(air_reduce(env, scope, to_form(v)))
    end
    # A database stores permissions only for its own users.
    _check_db_acl!(env, vf.db, acl)
    md = _metadata_like(vf; acl = acl, anchor = anchor)
    tx() do
        _set_metadata!(vf, md)
    end
    _flush_metadata!()      # the grant must be visible to the next check
    return vf
end
special!(Symbol("chmod!"), _bi_chmod)

# `(chown! target user)` — give the target a new owner. Needs write on the
# target; `air` may always do it.
function _bi_chown(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 3 || throw(AirEvalError("chown! expects a target and a user"))
    vf = _perm_target(env, scope, to_form(call.seq[2]))
    _check!(env, vf, :write)
    user = _user_id_arg(env, scope, to_form(call.seq[3]))
    vf.db === env.sysdb || _db_user_exists(env, vf.db, user) ||
        throw(AirEvalError("no such user: :$user"))
    _user_exists(env, user) || throw(AirEvalError("no such user: :$user"))
    md = _metadata_like(vf; owner = user)
    tx() do
        _set_metadata!(vf, md)
    end
    _flush_metadata!()      # the new owner must be visible to the next check
    return _keyword_form(user)
end
special!(Symbol("chown!"), _bi_chown)

# ---- assuming an owner's identity --------------------------------------------

# `(assume body…)` — evaluate `body` with `current-user` set to the owner of the
# `def` being evaluated. Legal only inside a namespace definition whose entry
# grants `assume` to the caller, so an owner can expose a controlled operation on
# its own data without granting read or write on the data itself. `owner` still
# reports the definition's owner.
function _bi_assume(env::Env, scope::Scope, call::FormContainer)
    rule = _scope_rule(scope)
    rule === nothing &&
        throw(AirEvalError("assume must appear inside a def"))
    e = rule.entry
    e isa VolatileForm ||
        throw(AirEvalError("assume requires a namespace definition"))
    _check!(env, e, :assume)
    c = _context(env)
    prev = c.user
    c.user = rule.owner === nothing ? prev : rule.owner
    try
        out = naught
        for i in 2:length(call.seq)
            out = air_reduce(env, scope, to_form(call.seq[i]))
        end
        return _Final(out)
    finally
        c.user = prev
    end
end
special!(:assume, _bi_assume)

# ---- permission-aware printing -----------------------------------------------

# `air_string(env, x)` — print `x`, showing a volatile the current user cannot
# read opaquely instead of revealing its body.
air_string(env::Env, x::Form) =
    task_local_storage(() -> air_string(x), :airlang_show_env, env)

# The pretty-printing counterpart: the same permission-aware view, broken across
# lines by `air_pretty_string`.
air_pretty_string(env::Env, x::Form; width::Integer = 80) =
    task_local_storage(() -> air_pretty_string(x; width = width),
                       :airlang_show_env, env)
