################################################################################
# namespaces.jl
#
# Namespaces: ordered, volatile collections of `def`/`val` entries addressed by
# a dotted path (`.util.algebra`). A namespace is a `VolatileForm` whose value
# is a container: its sequence is the append-ordered entry list and its map is
# the name index that `.` access reads. Each namespace layer is therefore
# updated atomically in a transaction, and a `namespace` block is itself a
# transaction.
#
# `.` alone is the global root; `.air` is the core namespace, whose entries are
# the builtins, operators, constants, and stdlib names.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _AIR = Symbol("air")
const _AIR_PATH = Symbol[_AIR]
const _DEF_HEAD = Symbol("def")
const _VAL_HEAD = Symbol("val")
# The map key under which an entry body keeps its source frame.
const _SRC_KEY = Symbol(":src")
const _ALL_KEYWORD = Symbol(":all")
const _ONLY_KEY = Symbol(":only")
const _EXCEPT_KEY = Symbol(":except")
const _AS_KEY = Symbol(":as")
const _HOLD_KEY = Symbol(":hold")
const _DOC_KEY = Symbol(":doc")
const _USING_KEY = Symbol(":using")

# The namespace name table prefix: the root is "air/ns", and a namespace's
# absolute path is appended after a slash. Named forms give each namespace a
# stable UUID that survives reloads, so subnamespace markers only need the path.
const _NS_NAME_ROOT = "air/ns"

_ns_name(path::Vector{Symbol}) =
    isempty(path) ? _NS_NAME_ROOT : _NS_NAME_ROOT * "/" * join(String.(path), "/")

function _ns_path_from_name(name::AbstractString)
    name == _NS_NAME_ROOT && return Symbol[]
    prefix = _NS_NAME_ROOT * "/"
    startswith(name, prefix) || return nothing
    return Symbol.(split(name[(length(prefix) + 1):end], "/"))
end

_ns_display(path::Vector{Symbol}) = isempty(path) ? "." : "." * join(String.(path), ".")

# ---- form helpers ------------------------------------------------------------

# A container from full forms, storing scalars as leaves. An empty listing or
# payload is `naught` — the same value as `()`.
function _ns_form(seq::Vector{Form}, map::Vector{Pair{Symbol,Form}} = Pair{Symbol,Form}[])
    return canonicalize(FormContainer(FormSeq(FormValue[_store_form(x) for x in seq]),
                                      FormMap(Pair{Symbol,FormValue}[k => _store_form(v)
                                                                    for (k, v) in map])))
end

_ns_empty_value() = _ns_form(Form[])

# The absolute path as a form: the root marker for `()`, otherwise a container
# of the bare path symbols.
_ns_path_form(path::Vector{Symbol}) =
    isempty(path) ? Form(DOT_ROOT) : _ns_form(Form[Form(s) for s in path])

# Read a stored absolute path form, or `nothing` if it is not one.
function _stored_path(x::Form)
    (x isa FormScalar && value(x) === DOT_ROOT) && return Symbol[]
    x isa FormContainer || return nothing
    out = Symbol[]
    for v in x.seq
        s = _symbolof(to_form(v))
        (s === nothing || !is_raw_symbol(s)) && return nothing
        push!(out, s)
    end
    return out
end

# The marker a namespace map holds for a defined name: `(ns-fn <path> :name)`.
_ns_fn_marker(path::Vector{Symbol}, name::Symbol) =
    _ns_form(Form[Form(NS_FN), _ns_path_form(path),
                  Form(Symbol(":", String(name)))])

# The marker for a `val` name: `(ns-val <path> :name)`. It dereferences to the
# binding's current thread-local value (see `_ns_val_value`).
_ns_val_marker(path::Vector{Symbol}, name::Symbol) =
    _ns_form(Form[Form(NS_VAL), _ns_path_form(path),
                  Form(Symbol(":", String(name)))])

# The marker for a subnamespace: `(ns-sub <path>)`.
_ns_sub_marker(path::Vector{Symbol}) =
    _ns_form(Form[Form(NS_SUB), _ns_path_form(path)])

# The marker for an imported proxy: `(ns-proxy <source path> :name)`.
_ns_proxy_marker(path::Vector{Symbol}, name::Symbol) =
    _ns_form(Form[Form(NS_PROXY), _ns_path_form(path),
                  Form(Symbol(":", String(name)))])

# An imported subnamespace: `(ns-sub-link <source path>)`.
_ns_sub_link_entry(path::Vector{Symbol}) =
    _ns_form(Form[Form(NS_SUB_LINK), _ns_path_form(path)])

_ns_sub_link_path(x::Form) = _ns_path_of_marker(x)

_ns_sub_link_name(x::Form) = begin
    p = _ns_sub_link_path(x)
    (p === nothing || isempty(p)) ? nothing : p[end]
end

# A `use`/`import` spec's `as=` alias: `(ns-alias <source path> :name)`.
_ns_alias_entry(path::Vector{Symbol}, name::Symbol) =
    _ns_form(Form[Form(NS_ALIAS), _ns_path_form(path),
                  Form(Symbol(":", String(name)))])

_ns_alias_name(x::Form) = _ns_name_of_fn(x)

# ---- thread-local `val` bindings ---------------------------------------------

# A `val`'s identity is `(absolute path, name)`: the root path `()` is a
# top-level (global) `val`, and any other path is the namespace that holds it.
_val_key(path::Vector{Symbol}, name::Symbol) = (Tuple(path), name)

"""
    _val_binding!(env, path, name, value) -> ValBinding

The thread-local binding for `path`'s `val` named `name`, creating it (or
replacing it when the definition value changed) with `value` as its default.
Each binding is an Air `Var{Form}`, so a `bind` can shadow it for a dynamic
extent without disturbing other tasks.
"""
function _val_binding!(env::Env, path::Vector{Symbol}, name::Symbol, value::Form;
                       entry::Union{Nothing,VolatileForm} = nothing)
    key = _val_key(path, name)
    b = get(env.vals, key, nothing)
    if b !== nothing && isequal(b.var.initial_value, value)
        # The same definition seen again: keep the live `Var` (a `bind` on it
        # must survive a namespace resync) but point the binding at the entry
        # that currently defines it.
        if entry !== nothing && (b.entry === nothing || b.entry.id != entry.id)
            b = ValBinding(b.var, b.path, b.name, entry)
            env.vals[key] = b
            env.valof[b.var] = b
        end
        return b
    end
    b = ValBinding(Var{Form}(value), copy(path), name, entry)
    env.vals[key] = b
    env.valof[b.var] = b
    return b
end

_val_binding(env::Env, path::Vector{Symbol}, name::Symbol) =
    get(env.vals, _val_key(path, name), nothing)

# Give `path`'s `val` named `name` a binding that shares `src`'s `Var`, so an
# imported `val` observes every rebinding of the source while keeping its own
# entry (and therefore its own read ACL). The source binding stays the reverse
# index's owner of the shared `Var`; a `bind` reports the same name either way.
function _val_share!(env::Env, path::Vector{Symbol}, name::Symbol,
                     src::ValBinding, entry::VolatileForm)
    key = _val_key(path, name)
    cur = get(env.vals, key, nothing)
    if cur !== nothing && cur.var === src.var && cur.entry === entry
        return cur
    end
    b = ValBinding(src.var, copy(path), name, entry)
    env.vals[key] = b
    haskey(env.valof, src.var) || (env.valof[src.var] = b)
    return b
end

# The current value of a `(ns-val <path> :name)` marker, or the marker itself
# when it names no live binding (the reducer then leaves it inert). Reading a
# `val` requires `r` on its defining entry.
function _ns_val_value(env::Env, marker::Form; check::Bool = true)
    _is_ns_val(marker) || return marker
    path = _ns_path_of_marker(marker)
    name = _ns_name_of_fn(marker)
    (path === nothing || name === nothing) && return marker
    b = _val_binding(env, path, name)
    b === nothing && return marker
    check && _check!(env, b.entry, :read, _keyword_form(name))
    return b.var[]
end

# The binding a bare `name` resolves to as a `val`: the nearest active rule layer
# (a `using`/`import`ed namespace) that has a bare-symbol rule whose body is a
# `val` marker, then the global rule store. `nothing` when no `val` defines it.
function _find_val_binding(env::Env, scope::Scope, name::Symbol)
    stores = RuleLayer[]
    _scope_has_layers(scope) && append!(stores, scope_layers(scope))
    push!(stores, env.rules)
    for store in stores
        for i in get(store.by_symbol, name, Int[])
            r = store.rules[i]
            isequal(r.pattern, Form(name)) || continue
            _is_ns_val(r.body) || continue
            path = _ns_path_of_marker(r.body)
            nm = _ns_name_of_fn(r.body)
            (path === nothing || nm === nothing) && continue
            b = _val_binding(env, path, nm)
            b === nothing || return b
        end
    end
    return nothing
end

# The stored entry that records a subnamespace: `(ns-sub <name>)`.
_ns_sub_entry(name::Symbol) = _ns_form(Form[Form(NS_SUB), Form(name)])

_ns_sub_name(entry::Form) =
    (s = _symbolof(to_form(entry.seq[2])); s === nothing ? nothing : _bindname(s))

_ns_path_of_marker(x::Form) = _stored_path(to_form(x.seq[2]))

function _ns_name_of_fn(x::Form)
    s = _symbolof(to_form(x.seq[3]))
    return s === nothing ? nothing : _bindname(s)
end

# A path as a namespace: `(ns-fn …)` / `(ns-sub …)` hold one.
_ns_path_of_form(x::Form) = _path_from_form(x)

# ---- the database and the root ----------------------------------------------

# The process-level database the system namespaces live in. It is deliberately
# never the environment's `db`: `.`, `.air`, `.sys`, `.lib`, and `.main` hold
# process state and must not be persisted into (or cross-linked with) an opened
# user database.
#
# A namespace at or under an opened database root (see `database.jl`) lives in
# that database instead; the longest matching prefix wins, and `sysdb` is the
# fallback.
function _ns_db(env::Env, path::Vector{Symbol})
    t = Tuple(path)
    while true
        db = get(env.dbs, t, nothing)
        db === nothing || return db
        isempty(t) && return env.sysdb
        t = t[1:(end - 1)]
    end
end

# The database a namespace wrapper's volatile belongs to.
_ns_db(env::Env, ns::Namespace) = ns.vf.db

# The user id whose home a namespace path is (or is under), or `nothing`. A core
# user's home is `.sys.user.<u>.home`; a constituent's is
# `.sys.user.<admin>.constituent.<name>.home`.
function _home_owner(env::Env, path::Vector{Symbol})
    idx = findfirst(==(_USER), path)
    idx === nothing && return nothing
    prefix = path[1:(idx - 1)]
    (prefix == Symbol[_SYS] || haskey(env.dbs, Tuple(prefix))) || return nothing
    rest = path[(idx + 1):end]
    # A home and everything beneath it belong to its user.
    length(rest) >= 2 && rest[2] === _HOME && return rest[1]
    length(rest) >= 4 && rest[2] === _CONSTITUENT && rest[4] === _HOME &&
        return Symbol(rest[1], ":", rest[3])
    return nothing
end

# The policy for a namespace in a database's user tree (`<root>.user…`): the
# records are system-managed (air-owned), while a user's home and its
# descendants belong to that user. `nothing` when `path` is not in that tree at
# the longest database root above it.
function _db_user_policy(env::Env, path::Vector{Symbol})
    n = -1
    for k in keys(env.dbs)
        m = length(k)
        if m > n && m <= length(path) && Tuple(path[1:m]) == k
            n = m
        end
    end
    n < 0 && return nothing
    rest = path[(n + 1):end]
    (isempty(rest) || rest[1] !== _USER) && return nothing
    length(rest) == 1 && return (_AIR, _perms_acl(_AIR))
    length(rest) >= 3 && rest[3] === _HOME &&
        return (rest[2], _perms_acl(rest[2]))
    if length(rest) >= 5 && rest[3] === _CONSTITUENT && rest[5] === _HOME
        id = Symbol(rest[2], ":", rest[4])
        return (id, _perms_acl(id))
    end
    return (_AIR, _perms_acl(_AIR))
end

# The owner and ACL a namespace created at `path` gets. `.` and `.air` and
# `.lib` are air-owned and world read/execute; `.sys` and `.main` (and the user
# records) are air-only; a home and its descendants belong to its user; any
# other namespace belongs to whoever created it.
function _ns_policy(env::Env, path::Vector{Symbol})
    isempty(path) && return (_AIR, _world_read_exec_acl(_AIR))
    (path == _AIR_PATH || path == Symbol[_AIR, _SYS] || path[1] === _LIB) &&
        return (_AIR, _world_read_exec_acl(_AIR))
    dbp = _db_user_policy(env, path)
    dbp === nothing || return dbp
    owner = _home_owner(env, path)
    owner === nothing || return (owner, _perms_acl(owner))
    (path[1] === _SYS || path[1] === _MAIN) && return (_AIR, _perms_acl(_AIR))
    me = _current_user(env)
    return (me, _perms_acl(me))
end

# Give a namespace volatile the metadata its path policy calls for, if it has
# none (a namespace created before permissions, or loaded from an older store).
function _ensure_ns_metadata!(env::Env, vf::VolatileForm, path::Vector{Symbol})
    metadata(vf) === nothing || return vf
    owner, acl = _ns_policy(env, path)
    owner = _check_db_principal!(env, _ns_db(env, path), owner)
    md = _metadata_form(owner; acl = acl)
    tx() do
        set_metadata!(vf, md)
    end
    return vf
end

# The named volatile for a namespace path, created (transactionally) if needed.
function _ns_named_volatile(env::Env, path::Vector{Symbol}; value = nothing)
    db = _ns_db(env, path)
    nm = _ns_name(path)
    vf = named_form(db, nm; create = nothing)
    vf === nothing || return _ensure_ns_metadata!(env, vf, path)
    return tx() do
        existing = named_form(db, nm; create = nothing)
        existing === nothing || return _ensure_ns_metadata!(env, existing, path)
        v = value === nothing ? _ns_empty_value() : value
        _check_storable!(env, db, v)
        owner, acl = _ns_policy(env, path)
        owner = _check_db_principal!(env, db, owner)
        md = _metadata_form(owner; acl = acl)
        try
            return named_form(db, nm; create = true, value = v, metadata = md)
        catch e
            e isa ArgumentError || rethrow()
            # another task created it first
            return _ensure_ns_metadata!(env, named_form(db, nm), path)
        end
    end
end

# The core `.air` values: every builtin and operator name is a raw-symbol proxy
# (so `(.air.string-join …)` dispatches normally), while a constant resolves to
# its value.
const _AIR_CONSTANTS = (:pi, :e, :tau, :inf, :nan)
const _AIR_STDLIB = (:identity, :constantly)

function _constant_value(env::Env, name::Symbol)
    for i in get(env.rules.by_symbol, name, Int[])
        r = env.rules.rules[i]
        if r.pattern isa FormScalar && isequal(r.pattern, Form(name)) &&
           r.body isa FormScalar
            return r.body
        end
    end
    return Form(name)
end

# The value `.air` stores for a constant. A constant is stored outright, so a
# lookup yields the value.
function _air_core(env::Env)
    core = Dict{Symbol,Form}()
    for name in keys(BUILTINS)
        core[name] = Form(name)
    end
    for name in keys(OPERATORS)
        core[name] = Form(name)
    end
    for name in _AIR_STDLIB
        core[name] = Form(name)
    end
    for name in _AIR_CONSTANTS
        core[name] = _constant_value(env, name)
    end
    return core
end

function _air_value(env::Env)
    core = _air_core(env)
    map = Pair{Symbol,Form}[Symbol(":", String(k)) => v for (k, v) in core]
    return _ns_form(Form[], map)
end

# The root namespace volatile, created on first use with `.air` registered.
function _ns_root(env::Env)
    env.nsroot !== nothing && return env.nsroot
    return tx() do
        env.nsroot !== nothing && return env.nsroot
        _ns_named_volatile(env, _AIR_PATH; value = _air_value(env))
        rootvf = _ns_named_volatile(env, Symbol[];
                                    value = _ns_form(
                                        Form[_ns_sub_entry(_AIR)],
                                        Pair{Symbol,Form}[Symbol(":air") =>
                                                          _ns_sub_marker(_AIR_PATH)]))
        entries = _ns_entries_of(rootvf)
        if !any(e -> _entry_head(e) === NS_SUB &&
                     _ns_sub_name(_entry_body(e)) === _AIR, entries)
            rootvf[] = _ns_form(vcat(entries, [_ns_sub_entry(_AIR)]),
                                Pair{Symbol,Form}[Symbol(":air") =>
                                                  _ns_sub_marker(_AIR_PATH)])
        end
        env.nsroot = rootvf
        return rootvf
    end
end

_ns_entries_of(vf::VolatileForm) = _ns_entries_value(vf[])

function _ns_entries_value(v::Form)
    v isa FormContainer || return Form[]
    return Form[to_form(x) for x in v.seq]
end

# ---- namespace entries -------------------------------------------------------

# An entry of a namespace's sequence is either an embedded volatile (a `def`,
# `val`, imported copy or proxy, carrying its owner and ACL in its metadata) or a
# plain form (a local subnamespace marker). The *body* is the form the entry
# stores; the sequence holds the volatile so the metadata travels with it.
_entry_body(e::VolatileForm) = e[]
_entry_body(e::Form) = to_form(e)

_entry_head(e::Form) = head_symbol(_entry_body(e))

# Create an embedded entry volatile holding `body`. Must run inside a transaction
# (constructing a volatile stages its write). The entry belongs to the database
# of the namespace it is installed in, so a database namespace's entries persist
# with it; a value carrying a volatile from another database is refused here
# rather than stored as a dangling link.
function _ns_new_entry!(env::Env, ns::Namespace, body::Form;
                        owner::Symbol = _current_user(env), acl = nothing,
                        name::Union{Nothing,Symbol} = nothing,
                        source = nothing, link = nothing,
                        anchor::Bool = false, hidden::Bool = false)
    db = _ns_db(env, ns)
    _check_storable!(env, db, body)
    owner = _check_db_principal!(env, db, owner)
    _check_db_acl!(env, db, acl)
    md = _metadata_form(owner; entry = true, name = name, acl = acl,
                        source = source, link = link, anchor = anchor,
                        hidden = hidden)
    return VolatileForm(db, body; metadata = md)
end

# The ACL a new entry gets: an entry in a world-readable namespace (`.air`,
# `.lib`) is world read/execute; otherwise it is owner-only.
function _ns_entry_acl(env::Env, ns::Namespace, owner::Symbol)
    acl = _meta_acl(ns.vf)
    if get(get(acl, :read, Dict{Symbol,Bool}()), _ALL_USERS, false)
        return _world_read_exec_acl(owner)
    end
    return _perms_acl(owner)
end

# ---- namespace wrappers ------------------------------------------------------

function _ns_wrap(env::Env, vf::VolatileForm, path::Vector{Symbol})
    key = Tuple(path)
    cached = get(env.nscache, key, nothing)
    if cached !== nothing && cached.vf.id == vf.id
        _ns_sync!(env, cached)
        return cached
    end
    ns = Namespace(vf, path)
    if path == _AIR_PATH
        ns.core = _air_core(env)
        for name in keys(ns.core)
            push!(ns.protected, name)
        end
    elseif path == Symbol[_AIR, _SYS]
        # `.air.sys` exposes the system functions by name; its map is fixed, so a
        # nonempty `core` also tells `_ns_sync!` not to rebuild it.
        ns.core = _system_core()
        for name in keys(ns.core)
            push!(ns.protected, name)
        end
    end
    env.nscache[key] = ns
    _ns_sync!(env, ns)
    return ns
end

# The first raw symbol a pattern names, or `nothing`: the pattern's head when it
# is a raw symbol, else its first raw-symbol anchor.
function _def_name(pattern::Form)
    if _is_alt(pattern)
        # `alt` is syntax, not the definition's name: use the first branch that
        # has one (the reader's alternatives are normally nested in a pattern
        # element, where the anchor search below already does the right thing).
        for i in 2:length(pattern.seq)
            n = _def_name(to_form(pattern.seq[i]))
            n === nothing || return n
        end
        return nothing
    elseif pattern isa FormContainer
        h = head_symbol(pattern)
        (h !== nothing && is_raw_symbol(h)) && return h
    else
        s = _symbolof(pattern)
        (s !== nothing && is_raw_symbol(s)) && return s
    end
    anchors = raw_symbols(pattern)
    return isempty(anchors) ? nothing : anchors[1]
end

function _entry_doc(e::FormContainer)
    haskey(e.map, _DOC_KEY) || return nothing
    l = _leafof(to_form(e.map[_DOC_KEY]))
    return l isa AbstractString ? String(l) : nothing
end

function _entry_held(e::FormContainer)
    return _held_names(e)
end

# Compile one stored `def` entry into the namespace's rule store. The entry
# volatile rides on the rule so its exec ACL is checked when the rule fires and
# its owner is the context `assume`/`owner` report.
function _compile_def!(store::RuleStore, entry::VolatileForm, e::FormContainer)
    pattern = to_form(e.seq[2])
    implicit = length(e.seq) < 3
    body = implicit ? naught : to_form(e.seq[3])
    memo = if haskey(e.map, _MEMO_KEY)
        c = _memo_parse(to_form(e.map[_MEMO_KEY]), "def")
        c === nothing ? nothing : _memo_table_for(entry, c)
    else
        nothing
    end
    _add_rule_object!(store, Rule(0, pattern, body, raw_symbols(pattern),
                                  params_of(pattern), _entry_held(e), _entry_doc(e),
                                  implicit, entry, _meta_owner(entry), memo))
    return store
end

# Compile one stored `val` entry into a rule that dereferences the name's
# thread-local binding. The value stored in the entry is the definition-time
# default; the rule body is the `(ns-val …)` marker, so a `bind` is visible
# through every use. A `val` requires `r` rather than `x`; `_match_store` knows
# the difference by the marker body.
function _compile_val!(store::RuleStore, entry::VolatileForm, e::FormContainer,
                       path::Vector{Symbol})
    pattern = to_form(e.seq[2])
    name = _def_name(pattern)
    body = name === nothing ? to_form(e.seq[3]) : _ns_val_marker(path, name)
    _add_rule_object!(store, Rule(0, pattern, body, raw_symbols(pattern),
                                  params_of(pattern), Set{Symbol}(), _entry_doc(e),
                                  false, entry, _meta_owner(entry), nothing))
    return store
end

# The argument name a compiled proxy rule matches. It is a rest wildcard over
# both the sequence and the map, so a proxied definition accepts any number of
# positional and keyword arguments.
const _PROXY_SPEC = Symbol("??airproxyargs")
const _PROXY_ARG = Symbol("airproxyargs")

# The source entry a proxy body names, or `nothing` when the source namespace (or
# the name) is gone.
function _proxy_source_entry(env::Env, b::FormContainer)
    path = _ns_path_of_marker(b)
    name = _ns_name_of_fn(b)
    (path === nothing || name === nothing) && return nothing
    src = _ns_lookup(env, path)
    src === nothing && return nothing
    return _ns_entry_for(env, src, name)
end

# Compile a proxy entry into the target namespace's rule store. A proxied `val`
# becomes a val rule that dereferences the *source* binding; a proxied `def`
# becomes a call rule that hands the whole call to `(ns-proxy-apply …)`, which
# applies the source namespace's rules lazily. The proxy entry itself is the
# rule's entry, so its (inherited) ACL gates the call.
function _compile_proxy!(env::Env, store::RuleStore, entry::VolatileForm,
                         b::FormContainer)
    path = _ns_path_of_marker(b)
    name = _ns_name_of_fn(b)
    (path === nothing || name === nothing) && return store
    src = _proxy_source_entry(env, b)
    if src !== nothing && head_symbol(_entry_body(src)) === _VAL_HEAD
        _add_rule_object!(store, Rule(0, Form(name), _ns_val_marker(path, name),
                                      [name], Symbol[], Set{Symbol}(), nothing,
                                      false, entry, _meta_owner(entry), nothing))
        return store
    end
    pattern = _ns_form(Form[Form(name), Form(_PROXY_SPEC)])
    args = _ns_form(Form[Form(Symbol("'")), Form(_PROXY_ARG)])
    body = _ns_form(Form[Form(NS_PROXY_APPLY), _ns_path_form(path),
                          Form(Symbol(":", String(name))), args])
    _add_rule_object!(store, Rule(0, pattern, body, raw_symbols(pattern),
                                  [_PROXY_ARG], Set([_PROXY_ARG]), nothing,
                                  false, entry, _meta_owner(entry), nothing))
    return store
end

# The arguments a `(ns-proxy-apply …)` body carries: the held rest container
# (its sequence is the positional arguments, its map the keyword arguments).
function _proxy_args(x::Form)
    x = _strip_hold(x)
    x isa FormContainer && return (Form[to_form(v) for v in x.seq], x.map)
    isequal(x, naught) && return (Form[], FormMap())
    return (Form[x], FormMap())
end

# Apply a proxy to `args`: reconstruct the call in the source namespace and match
# it against the source's own rules, which carry the source entry (its exec ACL)
# and owner (for `assume`). Read access to the source namespace is deliberately
# *not* required — that is what an exec-only import is for.
function _proxy_apply(env::Env, scope::Scope, path::Vector{Symbol},
                      name::Symbol, args::Vector{Form}, kwmap::FormMap)
    src = _ns_lookup(env, path)
    src === nothing && throw(AirProxyUnresolved(path))
    # The source entry is the proxy's target; when it is gone the import is
    # unresolvable (a call with the wrong arity still just stays inert).
    _ns_entry_for(env, src, name) === nothing && throw(AirProxyUnresolved(path))
    seq = FormValue[_store_form(Form(name))]
    for a in args
        push!(seq, _store_form(a))
    end
    subject = FormContainer(FormSeq(seq), kwmap)
    sscope = _ns_scope(env, scope, src)
    m, matched = _match_ns_call(src, env, scope, sscope, subject)
    m === nothing && return canonicalize(subject)
    return _apply_rule_checked(env, sscope, m, matched)
end

# Apply a `(ns-proxy <path> :name)` marker found in head position.
function _apply_proxy(env::Env, scope::Scope, headf::Form,
                      args::Vector{Form}, call::FormContainer)
    path = _ns_path_of_marker(headf)
    name = _ns_name_of_fn(headf)
    (path === nothing || name === nothing) && return nothing
    return _proxy_apply(env, scope, path, name, args, call.map)
end

# The value a `(ns-proxy …)` map marker exposes. A proxied `val` resolves through
# the source binding (so it shares the source's thread-local value and read ACL);
# a proxied `def` stays the marker, to be applied in head position.
function _ns_proxy_value(env::Env, marker::Form)
    path = _ns_path_of_marker(marker)
    path === nothing && return marker
    src = _proxy_source_entry(env, marker)
    src === nothing && throw(AirProxyUnresolved(path))
    head_symbol(_entry_body(src)) === _VAL_HEAD || return marker
    path = _ns_path_of_marker(marker)
    name = _ns_name_of_fn(marker)
    (path === nothing || name === nothing) && return marker
    return _ns_val_value(env, _ns_val_marker(path, name))
end

# The `val` binding an entry installs, honoring an imported `val`'s shared `Var`.
function _entry_val_binding!(env::Env, ns::Namespace, e::VolatileForm,
                             b::FormContainer, name::Symbol)
    link = _meta_link(e)
    if link !== nothing
        sb = _val_binding(env, link, name)
        if sb !== nothing
            _val_share!(env, ns.path, name, sb, e)
            return sb
        end
    end
    return _val_binding!(env, ns.path, name, to_form(b.seq[3]); entry = e)
end

# The names a namespace's map exposes, or `nothing` if the map is absent.
function _ns_map(env::Env, ns::Namespace)
    _ns_sync!(env, ns)
    v = ns.vf[]
    v isa FormContainer || return nothing
    return v
end

# Look a name up in a namespace's map. A missing name under `.lib` triggers a
# lazy library load (see `lib.jl`); `lazy=false` is used by the loader itself and
# by the namespace-creation path, where a missing name means what it says.
function _ns_map_get(env::Env, ns::Namespace, key::Symbol; lazy::Bool = true)
    v = _ns_map(env, ns)
    if (v === nothing || !haskey(v, key)) && lazy
        _lib_trigger!(env, ns, key) || return nothing
        v = _ns_map(env, ns)
    end
    (v === nothing || !haskey(v, key)) && return nothing
    return to_form(v[key])
end

# Rebuild the namespace's compiled rules and (for an ordinary namespace) its name
# map from the volatile's entry sequence.
function _ns_sync!(env::Env, ns::Namespace)
    val = ns.vf[]
    ns.synced === val && return ns
    ns.busy && return ns
    ns.busy = true
    try
        entries = _ns_entries_value(val)
        _clear_rules!(ns.rules)
        # Later definitions match first, so compile the entry sequence in reverse.
        seen_vals = Set{Symbol}()
        for e in Iterators.reverse(entries)
            e isa VolatileForm || continue
            b = _entry_body(e)
            b isa FormContainer || continue
            h = head_symbol(b)
            if h === NS_PROXY
                _compile_proxy!(env, ns.rules, e, b)
                continue
            end
            (h === _DEF_HEAD || h === _VAL_HEAD) || continue
            length(b.seq) >= 2 || continue
            if h === _DEF_HEAD
                _compile_def!(ns.rules, e, b)
            else
                _compile_val!(ns.rules, e, b, ns.path)
                # Recover the thread-local binding (a namespace loaded from the
                # database has entries but no in-memory binding yet). The entry
                # sequence is walked newest-first, so the first entry for a name
                # is the one that wins; an older duplicate must not reset it.
                name = _def_name(to_form(b.seq[2]))
                if name !== nothing && length(b.seq) >= 3 && !(name in seen_vals)
                    push!(seen_vals, name)
                    _entry_val_binding!(env, ns, e, b, name)
                end
            end
        end
        # `.air` keeps its fixed core map instead of compiling one.
        if isempty(ns.core)
            map = _ns_build_map(env, ns, entries)
            newval = _ns_form(entries, map)
            isequal(newval, val) || (ns.vf[] = newval)
        end
        ns.synced = ns.vf[]
    finally
        ns.busy = false
    end
    return ns
end

# The names a `use`/`import` spec selects from a source namespace's map.
function _import_filter(u::UseRef, key::Symbol)
    name = _bindname(key)
    u.only !== nothing && !(name in u.only) && return false
    name in u.except && return false
    return true
end

function _ns_build_map(env::Env, ns::Namespace, entries::Vector{Form})
    map = Dict{Symbol,Form}()
    subs = Set{Symbol}()
    # `.air`'s core names are generated, not stored as entries, so rebuilding
    # its map after a `def` must not drop them.
    for (name, v) in ns.core
        map[Symbol(":", String(name))] = v
    end
    for e in entries
        b = _entry_body(e)
        b isa FormContainer || continue
        h = head_symbol(b)
        # A `use`d entry is private: it compiles into the namespace's rules but
        # is absent from its map (and so from `.` lookup).
        (e isa VolatileForm && _meta_hidden(e)) && continue
        if h === _DEF_HEAD || h === _VAL_HEAD
            length(b.seq) >= 2 || continue
            name = _def_name(to_form(b.seq[2]))
            name === nothing && continue
            key = Symbol(":", String(name))
            # A `def` is a function, applied through its namespace's rules; a
            # `val` is a thread-local value, so `.` access exposes its marker.
            v = h === _VAL_HEAD && length(b.seq) >= 3 ?
                _ns_val_marker(ns.path, name) : _ns_fn_marker(ns.path, name)
            _ns_map_set!(map, subs, key, v, ns)
        elseif h === NS_PROXY
            name = _ns_name_of_fn(b)
            name === nothing && continue
            key = Symbol(":", String(name))
            _ns_map_set!(map, subs, key, b, ns)
        elseif h === NS_SUB
            name = _ns_sub_name(b)
            name === nothing && continue
            key = Symbol(":", String(name))
            _ns_map_set!(map, subs, key, _ns_sub_marker(vcat(ns.path, name)), ns)
        elseif h === NS_SUB_LINK
            path = _ns_sub_link_path(b)
            name = _ns_sub_link_name(b)
            (path === nothing || name === nothing) && continue
            key = Symbol(":", String(name))
            _ns_map_set!(map, subs, key, _ns_sub_marker(path), ns)
        end
    end
    return Pair{Symbol,Form}[k => v for (k, v) in map]
end

# A subnamespace may not shadow a definition, and a definition may not shadow a
# subnamespace — never, in either order.
function _ns_map_set!(map::Dict{Symbol,Form}, subs::Set{Symbol}, key::Symbol,
                      val::Form, ns::Namespace)
    if haskey(map, key)
        (key in subs) != _is_ns_sub(val) && _ns_shadow_error(ns, key)
    end
    map[key] = val
    if _is_ns_sub(val)
        push!(subs, key)
    else
        delete!(subs, key)
    end
    return map
end

_ns_shadow_error(ns::Namespace, key::Symbol) =
    throw(AirDefError("the name $(_bindname(key)) in namespace $(_ns_display(ns.path)) " *
                      "cannot be both a definition and a subnamespace"))

function _ns_is_sub_name(env::Env, ns::Namespace, name::Symbol)
    entry = _ns_map_get(env, ns, Symbol(":", String(name)); lazy = false)
    return entry !== nothing && _is_ns_sub(entry)
end

# ---- lookup ------------------------------------------------------------------

function _ns_root_ns(env::Env)
    return _ns_lookup_root(env)
end

function _ns_lookup(env::Env, path::Vector{Symbol}; lazy::Bool = true)
    isempty(path) && return _ns_lookup_root(env)
    # Walk the parent chain, so a namespace rolled back with a failed
    # transaction (or otherwise absent) is never served from the cache.
    parent = _ns_lookup(env, path[1:(end - 1)]; lazy = lazy)
    parent === nothing && return nothing
    entry = _ns_map_get(env, parent, Symbol(":", String(path[end])); lazy = lazy)
    (entry === nothing || !_is_ns_sub(entry)) && return nothing
    p = _ns_path_of_marker(entry)
    (p === nothing || p != path) && return nothing
    vf = named_form(_ns_db(env, path), _ns_name(path); create = nothing)
    vf === nothing && return nothing
    return _ns_wrap(env, vf, path)
end

function _ns_lookup_root(env::Env)
    vf = _ns_root(env)
    cached = get(env.nscache, (), nothing)
    if cached !== nothing && cached.vf.id == vf.id
        _ns_sync!(env, cached)
        return cached
    end
    return _ns_wrap(env, vf, Symbol[])
end

# The wrapper for a namespace value, scanning the cache and then the name table.
function _ns_from_value(env::Env, v::Form)
    v isa VolatileForm || return nothing
    for ns in values(env.nscache)
        ns.vf.id == v.id && return _ns_sync!(env, ns)
    end
    for (nm, vf) in named_forms(v.db)
        vf.id == v.id || continue
        path = _ns_path_from_name(String(nm))
        path === nothing && continue
        return _ns_lookup(env, path)
    end
    return nothing
end

# ---- namespace forms ---------------------------------------------------------

# A form written as a namespace address: `.`, `.a.b`, `@.a.b`, or a bare
# root-level name. `@` is the database root (`.` for a system user), so it is an
# address root just like `.`. A bare `$` is a capability, not a static path: it
# is resolved by evaluation, like a scope-bound symbol.
function _path_from_form(x::Form)
    if x isa FormScalar
        v = value(x)
        (v === DOT_ROOT || v === AT_ROOT) && return Symbol[]
    end
    s = _symbolof(x)
    (s !== nothing && is_raw_symbol(s) && s !== HOME_ROOT && s !== AT_ROOT) &&
        return Symbol[s]
    x isa FormContainer || return nothing
    head_symbol(x) === Symbol("get") || return nothing
    length(x.seq) >= 2 || return nothing
    root = to_form(x.seq[2])
    (root isa FormScalar && (value(root) === DOT_ROOT || value(root) === AT_ROOT)) ||
        return nothing
    out = Symbol[]
    for i in 3:length(x.seq)
        k = _symbolof(to_form(x.seq[i]))
        (k === nothing || !is_keyword(k)) && return nothing
        push!(out, _bindname(k))
    end
    return out
end

# The address root an address form names: `:dot` for `.`, `:at` for `@`, and
# `:bare` for a bare root-level name. `nothing` when the form is not an address.
function _path_root(x::Form)
    if x isa FormScalar
        v = value(x)
        v === AT_ROOT && return :at
        v === DOT_ROOT && return :dot
        return nothing
    end
    (x isa FormContainer && head_symbol(x) === Symbol("get")) || return nothing
    length(x.seq) >= 2 || return nothing
    root = to_form(x.seq[2])
    root isa FormScalar || return nothing
    value(root) === AT_ROOT && return :at
    value(root) === DOT_ROOT && return :dot
    return nothing
end

# An address path with an `@` root made absolute: `@` is the attached database's
# root, so `@.a` denotes db-root `.a` while `.a` denotes `.a` at the air root.
function _ns_address_path(env::Env, x::Form)
    path = _path_from_form(x)
    path === nothing && return nothing
    _path_root(x) === :at || return path
    dbp = _context_db_path(env)
    return dbp === nothing ? path : vcat(dbp, path)
end

# The absolute path a namespace form denotes, evaluating it when it is an
# expression rather than an address.
function _ns_target_path(env::Env, scope::Scope, form::Form)
    s = _symbolof(form)
    if s !== nothing && is_raw_symbol(s) && scope_get(scope, s) !== nothing
        ns = _ns_from_value(env, air_reduce(env, scope, form))
        ns === nothing &&
            throw(AirEvalError("expected a namespace, got $(air_string(form))"))
        return copy(ns.path)
    end
    path = _ns_address_path(env, form)
    path === nothing || return path
    v = air_reduce(env, scope, form)
    ns = _ns_from_value(env, v)
    ns === nothing &&
        throw(AirEvalError("expected a namespace, got $(air_string(v))"))
    return copy(ns.path)
end

# Create (or fetch) a namespace and every missing ancestor, registering each
# subnamespace in its parent.
function _ns_ensure!(env::Env, path::Vector{Symbol})
    isempty(path) && return _ns_lookup_root(env)
    for seg in path
        _valid_name_segment(String(seg)) ||
            throw(AirDefError("invalid name segment '$seg' in namespace " *
                              "$(_ns_display(path))"))
    end
    parent = _ns_ensure!(env, path[1:(end - 1)])
    name = path[end]
    key = Symbol(":", String(name))
    entry = _ns_map_get(env, parent, key; lazy = false)
    if entry !== nothing
        if !_is_ns_sub(entry)
            throw(AirDefError("namespace $(_ns_display(path)) conflicts with the " *
                              "definition of $name"))
        end
        p = _ns_path_of_marker(entry)
        if p !== nothing && p == path
            ns = _ns_lookup(env, path)
            # The marker may outlive its named form (a failed open, a purged
            # namespace); recreate the namespace rather than return nothing.
            ns === nothing || return ns
        end
    end
    # Creating a subnamespace writes into its parent.
    _check_ns!(env, parent, :write)
    return tx() do
        entries = _ns_entries_of(parent.vf)
        if !any(e -> _entry_head(e) === NS_SUB &&
                     _ns_sub_name(_entry_body(e)) === name, entries)
            _ns_store_entries!(env, parent, vcat(entries, [_ns_sub_entry(name)]))
        end
        vf = _ns_named_volatile(env, path)
        return _ns_wrap(env, vf, path)
    end
end

# Replace a namespace's entry sequence and rebuild its map and rules.
function _ns_store_entries!(env::Env, ns::Namespace, entries::Vector{Form})
    map = _ns_build_map(env, ns, entries)
    ns.vf[] = _ns_form(entries, map)
    ns.synced = nothing
    _ns_sync!(env, ns)
    return ns
end

function _ns_append!(env::Env, ns::Namespace, entry::Form)
    return tx() do
        entries = _ns_entries_of(ns.vf)
        _ns_store_entries!(env, ns, vcat(entries, [entry]))
    end
end

# The entry body for a namespace's own `def`. `src` is the source frame
# `(name=… line=… col=… text=…)` of the definition, kept for error reporting.
function _ns_def_entry(pattern::Form, body::Form, implicit::Bool,
                       held::Set{Symbol}, doc, src = nothing, memo = nothing)
    seq = Form[Form(_DEF_HEAD), pattern]
    implicit || push!(seq, body)
    map = Pair{Symbol,Form}[]
    isempty(held) || push!(map, _HOLD_KEY => _hold_option(held))
    doc === nothing || push!(map, _DOC_KEY => Form(doc))
    memo === nothing || push!(map, _MEMO_KEY => _memo_option_form(memo))
    src === nothing || push!(map, _SRC_KEY => src)
    return _ns_form(seq, map)
end

function _ns_add_def!(env::Env, ns::Namespace, pattern::Form, body::Form;
                      held::Set{Symbol} = Set{Symbol}(), doc = nothing,
                      implicit::Bool = false, owner::Union{Nothing,Symbol} = nothing,
                      src = nothing, memo::Union{Nothing,_MemoConfig} = nothing)
    _check_ns!(env, ns, :write)
    name = _def_name(pattern)
    name === RERAISE && throw(AirDefError(
        "reraise is a reserved symbol and cannot be defined"))
    _check_reserved_pattern(pattern)
    if name !== nothing && _ns_is_sub_name(env, ns, name)
        _ns_shadow_error(ns, Symbol(":", String(name)))
    end
    return tx() do
        o = owner === nothing ? _current_user(env) : owner
        entry = _ns_new_entry!(env, ns,
                               _ns_def_entry(pattern, body, implicit, held, doc, src,
                                             memo);
                               owner = o, acl = _ns_entry_acl(env, ns, o),
                               name = name)
        _ns_append!(env, ns, entry)
        return ns
    end
end

# The entry body for a namespace's own `val`; the value is already evaluated.
function _ns_val_entry(pattern::Form, value::Form, doc, src = nothing)
    map = Pair{Symbol,Form}[]
    doc === nothing || push!(map, _DOC_KEY => Form(doc))
    src === nothing || push!(map, _SRC_KEY => src)
    return _ns_form(Form[Form(_VAL_HEAD), pattern, value], map)
end

function _ns_add_val!(env::Env, ns::Namespace, pattern::Form, value::Form;
                      doc = nothing, owner::Union{Nothing,Symbol} = nothing,
                      src = nothing)
    _check_ns!(env, ns, :write)
    name = _def_name(pattern)
    name === RERAISE && throw(AirDefError(
        "reraise is a reserved symbol and cannot be defined"))
    _check_reserved_pattern(pattern)
    if name !== nothing && _ns_is_sub_name(env, ns, name)
        _ns_shadow_error(ns, Symbol(":", String(name)))
    end
    return tx() do
        o = owner === nothing ? _current_user(env) : owner
        entry = _ns_new_entry!(env, ns, _ns_val_entry(pattern, value, doc, src);
                               owner = o, acl = _ns_entry_acl(env, ns, o),
                               name = name)
        _ns_append!(env, ns, entry)
        name === nothing || _val_binding!(env, ns.path, name, value; entry = entry)
        return ns
    end
end

# ---- namespace specs ---------------------------------------------------------

# A set of bare names from a spec's `only=`/`except=` value.
function _name_set(x::Form)
    out = Set{Symbol}()
    if x isa FormContainer
        for v in x.seq
            s = _symbolof(to_form(v))
            s === nothing || push!(out, _bindname(s))
        end
        for (k, _) in x.map
            push!(out, _bindname(k))
        end
    else
        s = _symbolof(x)
        s === nothing || push!(out, _bindname(s))
    end
    return out
end

const _SPEC_OPTIONS = Set([Symbol(":only"), Symbol(":except"), Symbol(":as")])
const _SPEC_OPTION_NAMES = Set([:only, :except, :as])

function _has_spec_options(form::FormContainer)
    any(v -> (s = _symbolof(to_form(v)); s !== nothing && s in _SPEC_OPTIONS),
        form.seq) && return true
    return any(k -> _bindname(k) in _SPEC_OPTION_NAMES, keys(form.map))
end

# Split a spec into its base namespace form and its options. Options may be
# written in the sequence as keyword pairs (`(.util :only inv)`) or in the map
# (`(.util only=(inv))`).
function _spec_options(form::Form)
    form isa FormContainer || return (form, nothing, Set{Symbol}(), nothing)
    seq = Form[to_form(v) for v in form.seq]
    base = nothing
    only = nothing
    except = Set{Symbol}()
    as = nothing
    i = 1
    while i <= length(seq)
        s = _symbolof(seq[i])
        if s === _ONLY_KEY
            i < length(seq) || throw(AirEvalError("the :only option needs names"))
            only = _name_set(seq[i + 1]); i += 2
        elseif s === _EXCEPT_KEY
            i < length(seq) || throw(AirEvalError("the :except option needs names"))
            except = _name_set(seq[i + 1]); i += 2
        elseif s === _AS_KEY
            i < length(seq) || throw(AirEvalError("the :as option needs a name"))
            nm = _symbolof(seq[i + 1])
            nm === nothing && throw(AirEvalError("the :as option needs a symbol"))
            as = _bindname(nm); i += 2
        else
            base === nothing ||
                throw(AirEvalError("a namespace spec has one namespace; " *
                                   "use a list for several"))
            base = seq[i]; i += 1
        end
    end
    for (k, v) in form.map
        b = _bindname(k)
        if b === :only
            only = _name_set(to_form(v))
        elseif b === :except
            except = _name_set(to_form(v))
        elseif b === :as
            nm = _symbolof(to_form(v))
            nm === nothing && throw(AirEvalError("the as= option needs a symbol"))
            as = _bindname(nm)
        end
    end
    base === nothing && throw(AirEvalError("a namespace spec needs a namespace"))
    return (base, only, except, as)
end

# Resolve a base namespace form (after any options have been split off).
function _resolve_spec_base(env::Env, scope::Scope, base::Form)
    s = _symbolof(base)
    if s !== nothing && is_raw_symbol(s) && scope_get(scope, s) !== nothing
        ns = _ns_from_value(env, air_reduce(env, scope, base))
        ns === nothing &&
            throw(AirEvalError("expected a namespace, got $(air_string(base))"))
        return copy(ns.path)
    end
    path = _ns_address_path(env, base)
    if path === nothing
        ns = _ns_from_value(env, air_reduce(env, scope, base))
        ns === nothing &&
            throw(AirEvalError("expected a namespace, got $(air_string(base))"))
        return copy(ns.path)
    end
    ns = _lookup_ns_or_library(env, path)
    ns === nothing &&
        throw(AirEvalError("no namespace or library at $(_ns_display(path))"))
    return copy(ns.path)
end

# Resolve one namespace spec to its absolute source and filters.
function _resolve_spec(env::Env, scope::Scope, form::Form)
    # A whole form that is itself an address (`.util`, `.util.algebra`) is a spec
    # with no options; splitting it as if its elements were options would be
    # wrong (`(get . :util)` is one path, not three parts).
    s = _symbolof(form)
    bound = s !== nothing && is_raw_symbol(s) && scope_get(scope, s) !== nothing
    path = bound ? nothing : _ns_address_path(env, form)
    if path !== nothing
        ns = _lookup_ns_or_library(env, path)
        ns === nothing &&
            throw(AirEvalError("no namespace or library at $(_ns_display(path))"))
        return UseRef(copy(ns.path), nothing, Set{Symbol}(), nothing)
    end
    base, only, except, as = _spec_options(form)
    return UseRef(_resolve_spec_base(env, scope, base), only, except, as)
end

# The specs of `using`, whose single argument may be one spec or a list of them.
function _using_specs(env::Env, scope::Scope, form::Form)
    if form isa FormContainer && !_has_spec_options(form) &&
       _path_from_form(form) === nothing
        return UseRef[_resolve_spec(env, scope, to_form(v)) for v in form.seq]
    end
    return UseRef[_resolve_spec(env, scope, form)]
end

_names_form(names::Set{Symbol}) =
    _ns_form(Form[Form(s) for s in sort!(collect(names); by = String)])

# The public name an entry defines, imports, or aliases.
function _entry_export_name(e::Form)
    b = _entry_body(e)
    b isa FormContainer || return nothing
    h = head_symbol(b)
    if h === _DEF_HEAD || h === _VAL_HEAD
        return length(b.seq) >= 2 ? _def_name(to_form(b.seq[2])) : nothing
    elseif h === NS_PROXY || h === NS_ALIAS
        return _ns_name_of_fn(b)
    elseif h === NS_SUB_LINK
        return _ns_sub_link_name(b)
    elseif h === NS_SUB
        return _ns_sub_name(b)
    end
    return nothing
end

# The source namespace a stored entry was imported from, or `nothing`.
_entry_source(e::Form) = e isa VolatileForm ? _meta_source(e) : nothing

# Remove every entry `pred` selects, then install `entry` (if it is not
# `nothing`). `pred` runs on the entry and its export name.
function _ns_replace_entries!(env::Env, ns::Namespace, pred, entry)
    entries = _ns_entries_of(ns.vf)
    keep = Form[e for e in entries if !pred(e, _entry_export_name(e))]
    entry === nothing || push!(keep, entry)
    _ns_store_entries!(env, ns, keep)
    return ns
end

# Materialize one imported name in `ns`. The target owns a copied entry; a
# private proxy keeps the source's owner and ACL so it executes as the source.
function _ns_import_one!(env::Env, ns::Namespace, src::Namespace,
                         name::Symbol, srcval::Form, u::UseRef; exports::Bool)
    hidden = !exports
    target_owner = _meta_owner(ns.vf)
    if _is_ns_sub(srcval)
        path = _ns_path_of_marker(srcval)
        path === nothing && return nothing
        return _ns_new_entry!(env, ns, _ns_sub_link_entry(path);
                              owner = _meta_owner(src.vf),
                              acl = _meta_acl(src.vf), name = name,
                              source = u.path, hidden = hidden)
    end
    e = _ns_entry_for(env, src, name)
    e === nothing && return nothing
    b = _entry_body(e)
    b isa FormContainer || return nothing
    h = head_symbol(b)
    if _meta_anchor(e) || _is_ns_proxy(b) || !_can(env, e, :read)
        _can(env, e, :exec) || return nothing
        path = _is_ns_proxy(b) ? _ns_path_of_marker(b) : u.path
        path === nothing && return nothing
        return _ns_new_entry!(env, ns, _ns_proxy_marker(path, name);
                              owner = _meta_owner(e), acl = _meta_acl(e),
                              name = name, anchor = _meta_anchor(e),
                              source = u.path, hidden = hidden)
    end
    if h === _DEF_HEAD
        return _ns_new_entry!(env, ns, b; owner = target_owner, acl = _meta_acl(e),
                              name = name, source = u.path, hidden = hidden)
    elseif h === _VAL_HEAD && length(b.seq) >= 3
        return _ns_new_entry!(env, ns, b; owner = target_owner, acl = _meta_acl(e),
                              name = name, source = u.path, link = u.path,
                              hidden = hidden)
    end
    return nothing
end

# `(use spec…)` / `(import spec…)` — materialize the selected names of the
# source namespaces as entries of the current namespace block. `use` keeps them
# private (they compile into the rules but are absent from the map); `import`
# exports them. Re-importing a name replaces the previous copy from that source.
function _ns_materialize!(env::Env, ns::Namespace, u::UseRef; exports::Bool)
    _check_ns!(env, ns, :write)
    src = _ns_lookup(env, u.path)
    src === nothing &&
        throw(AirEvalError("no namespace at $(_ns_display(u.path))"))
    _check_ns!(env, src, :read)
    return tx() do
        srcval = src.vf[]
        srcval isa FormContainer || return ns
        for (k, v) in srcval.map
            _import_filter(u, k) || continue
            name = _bindname(k)
            entry = _ns_import_one!(env, ns, src, name, to_form(v), u;
                                    exports = exports)
            entry === nothing && continue
            _ns_replace_entries!(env, ns,
                (e, n) -> n === name && _entry_source(e) == u.path, entry)
        end
        if u.as !== nothing
            entry = _ns_new_entry!(env, ns, _ns_alias_entry(u.path, u.as);
                                   owner = _meta_owner(src.vf),
                                   acl = _meta_acl(src.vf), name = u.as,
                                   source = u.path, hidden = true)
            _ns_replace_entries!(env, ns,
                (e, n) -> n === u.as && _entry_source(e) == u.path, entry)
        end
        return ns
    end
end

# ---- activating a namespace --------------------------------------------------

# A copy of a namespace's own rules selected by `only`/`except`.
function _filtered_store(ns::Namespace, only, except)
    (only === nothing && isempty(except)) && return ns.rules
    store = RuleStore()
    for r in ns.rules.rules
        name = _def_name(r.pattern)
        name === nothing && continue
        only !== nothing && !(name in only) && continue
        name in except && continue
        _add_rule_object!(store, r)
    end
    return store
end

# The rule layers active in a namespace. Imports are materialized entries, so a
# namespace has exactly its own store: a copied `def` compiles locally, a proxy
# applies the source lazily, and a nested `use` copies or proxies again.
function _ns_active_layers(env::Env, ns::Namespace)
    return RuleStore[ns.rules]
end

# The `as=` names a namespace's `use`/`import` specs bind.
function _ns_use_bindings(env::Env, ns::Namespace)
    pairs = Pair{Symbol,Form}[]
    for e in _ns_entries_of(ns.vf)
        b = _entry_body(e)
        _is_ns_alias(b) || continue
        path = _ns_path_of_marker(b)
        name = _ns_alias_name(b)
        (path === nothing || name === nothing) && continue
        src = _ns_lookup(env, path)
        src === nothing && continue
        push!(pairs, name => src.vf)
    end
    return pairs
end

# The lexical names of `scope`, with every rule layer removed. A namespace body
# or function application keeps the caller's bindings (so a `let` value is still
# visible) but not the caller's definitions: a namespace runs in its own context
# (its own rules, including materialized imports), which is what makes
# `(namespace .air …)` and a `.util` function pristine.
function _scope_without_layers(scope::Scope)
    stack = Scope[]
    s = scope
    while s !== nothing
        push!(stack, s)
        s = s.parent
    end
    out = Scope()
    for t in Iterators.reverse(stack)
        # A scope that carries only a rule context (no bindings) is kept too: it
        # is what lets `assume`/`owner` see the definition a namespace body runs
        # under after the caller's layers are dropped.
        (isempty(t.names) && t.rule === nothing) && continue
        out = Scope(out, copy(t.names), copy(t.vals), RuleLayer[], t.rule)
    end
    return out
end

# The scope a namespace's body or function runs in: the caller's lexical names
# plus the namespace's active rule layers and `as=` bindings.
function _ns_scope(env::Env, scope::Scope, ns::Namespace)
    layers = RuleLayer[_ns_active_layers(env, ns)...]
    return scope_extend(_scope_without_layers(scope), _ns_use_bindings(env, ns);
                        layers = layers)
end

# The namespace a `def`/`val`/`use`/`del` targets, or `nothing` before boot (when
# the stdlib itself is being defined into `env.rules`).
_write_ns(env::Env) = (ns = _context(env).ns; ns isa Namespace ? ns : nothing)

# The scope an evaluation starts from: the current namespace's active rules, with
# no lexical bindings. `air_eval` and `eval` use it; a namespace function uses
# `_ns_scope`.
function _base_scope(env::Env)
    ns = _context(env).ns
    ns isa Namespace || return Scope()
    return Scope(nothing, Symbol[], Form[], RuleLayer[_ns_active_layers(env, ns)...])
end

# ---- applying a namespace function -------------------------------------------

# `(.util.foo a b)` — a `(ns-fn …)` marker in head position applies that
# namespace's rules for `foo` to the reconstructed call `(foo a b)`.
function _apply_ns_fn(env::Env, scope::Scope, headf::FormContainer,
                      args::Vector{Form}, call::FormContainer)
    path = _ns_path_of_marker(headf)
    name = _ns_name_of_fn(headf)
    (path === nothing || name === nothing) && return nothing
    ns = _ns_lookup(env, path)
    ns === nothing && return nothing
    _check_ns!(env, ns, :read)
    seq = FormValue[_store_form(Form(name))]
    for a in args
        push!(seq, _store_form(a))
    end
    subject = FormContainer(FormSeq(seq), call.map)
    sscope = _ns_scope(env, scope, ns)
    m, matched = _match_ns_call(ns, env, scope, sscope, subject)
    m === nothing && return canonicalize(call)
    return _apply_rule_checked(env, sscope, m, matched)
end

# Match the reconstructed call `(name args…)` against a namespace's rules. The
# raw call is tried first (a rule holding a parameter sees it exactly as written,
# and a zero-argument `(f)` matches the one-element pattern `(f)`), then the
# call with the caller's scope resolved into it. If that also fails, a
# one-element call is tried as its sole element, which is how a scalar `def` for
# `f` (`(def f 7)`) matches its zero-argument call `(f)`. This is an explicit
# fallback, not canonicalization: `(f)` stays a one-element form.
function _match_ns_call(ns::Namespace, env::Env, scope::Scope, sscope::Scope,
                        subject::FormContainer)
    m = _match_store(ns.rules, env, sscope, subject; want_held = true)
    m === nothing || return (m, subject)
    rsub = _scope_empty(scope) ? subject : _resolve(scope, subject)
    m = _match_store(ns.rules, env, sscope, rsub; want_held = false)
    m === nothing || return (m, rsub)
    if length(rsub.seq) == 1 && isempty(rsub.map)
        csub = to_form(rsub.seq[1])
        m = _match_store(ns.rules, env, sscope, csub; want_held = false)
        m === nothing || return (m, csub)
    end
    return (nothing, subject)
end

# ---- the special forms -------------------------------------------------------

# The extra rule layers a `namespace` form's `using=` option activates. They sit
# below the namespace's own rules, so a definition in the block shadows a
# namespace named by `using=`.
function _namespace_using_layers(env::Env, scope::Scope, call::FormContainer)
    haskey(call.map, _USING_KEY) || return RuleLayer[]
    specs = _using_specs(env, scope, to_form(call.map[_USING_KEY]))
    layers = RuleLayer[]
    for u in Iterators.reverse(specs)
        src = _ns_lookup(env, u.path)
        src === nothing &&
            throw(AirEvalError("no namespace at $(_ns_display(u.path))"))
        ls = _ns_active_layers(env, src)
        if u.only !== nothing || !isempty(u.except)
            ls = RuleStore[_filtered_store(src, u.only, u.except); ls[2:end]]
        end
        append!(layers, ls)
    end
    return layers
end

# `(namespace ns body…; using=(ns…))` — evaluate `body` in a transaction with
# `ns` as the current namespace; every `def`/`val` in it is appended to `ns`.
# The body does *not* inherit the caller's definitions: it runs with `ns`'s rule
# layers (plus `using=`), while the caller's lexical bindings remain visible.
function _bi_namespace(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 ||
        throw(AirEvalError("namespace needs a name"))
    path = _ns_target_path(env, scope, to_form(call.seq[2]))
    extra = _namespace_using_layers(env, scope, call)
    names = _scope_without_layers(scope)
    r = _tx_boundary(env) do
        ns = _ns_ensure!(env, path)
        _check_ns!(env, ns, :read)
        c = _context(env)
        prev = c.ns
        c.ns = ns
        try
            r = naught
            for i in 3:length(call.seq)
                layers = RuleLayer[_ns_active_layers(env, ns)...]
                append!(layers, extra)
                sscope = scope_extend(names, _ns_use_bindings(env, ns);
                                      layers = layers)
                r = air_reduce(env, sscope, to_form(call.seq[i]))
            end
            return _Final(r)
        finally
            c.ns = prev
        end
    end
    return r
end

special!(:namespace, _bi_namespace)

# `(using ns body…)` — evaluate `body` with `ns` (a spec or a list of specs)
# made local: its rules are active and `as=` bindings are in scope.
function _bi_using(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 ||
        throw(AirEvalError("using needs a namespace"))
    specs = _using_specs(env, scope, to_form(call.seq[2]))
    layers = RuleLayer[]
    bindings = Pair{Symbol,Form}[]
    # Later specs have priority, so add them nearest-first.
    for u in Iterators.reverse(specs)
        src = _ns_lookup(env, u.path)
        src === nothing &&
            throw(AirEvalError("no namespace at $(_ns_display(u.path))"))
        ls = _ns_active_layers(env, src)
        if u.only !== nothing || !isempty(u.except)
            ls = RuleStore[_filtered_store(src, u.only, u.except); ls[2:end]]
        end
        append!(layers, ls)
        u.as === nothing || push!(bindings, u.as => src.vf)
    end
    sscope = scope_extend(scope, bindings; layers = layers)
    r = naught
    for i in 3:length(call.seq)
        r = air_reduce(env, sscope, to_form(call.seq[i]))
    end
    return r
end
special!(:using, _bi_using)

# `(use spec…)` / `(import spec…)` — materialize the selected names of each spec
# as entries of the current namespace block.
function _bi_use_import(env::Env, scope::Scope, call::FormContainer, is_import::Bool)
    length(call.seq) >= 2 ||
        throw(AirEvalError((is_import ? "import" : "use") * " needs a namespace"))
    target = _write_ns(env)
    target === nothing &&
        throw(AirEvalError((is_import ? "import" : "use") *
                           " requires a current namespace"))
    return tx() do
        for i in 2:length(call.seq)
            u = _resolve_spec(env, scope, to_form(call.seq[i]))
            _ns_materialize!(env, target, u; exports = is_import)
        end
        return naught
    end
end
special!(:use, (env, scope, call) -> _bi_use_import(env, scope, call, false))
special!(:import, (env, scope, call) -> _bi_use_import(env, scope, call, true))

# The generated body of a proxied call rule: `(ns-proxy-apply <path> :name args)`
# where `args` is a held rest container. Apply the source namespace's rules.
function _bi_ns_proxy_apply(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 4 ||
        throw(AirEvalError("internal proxy application is malformed"))
    path = _ns_path_of_marker(call)
    name = _ns_name_of_fn(call)
    (path === nothing || name === nothing) &&
        throw(AirEvalError("internal proxy application is malformed"))
    args, kwmap = _proxy_args(to_form(call.seq[4]))
    return _proxy_apply(env, scope, path, name, args, kwmap)
end
special!(NS_PROXY_APPLY, _bi_ns_proxy_apply)

# Names that may never be deleted from the global (root) rule store.
function _global_protected(name::Symbol)
    return haskey(BUILTINS, name) || haskey(OPERATORS, name) ||
           name in _AIR_CONSTANTS || name in _AIR_STDLIB
end

function _del_global!(env::Env, name::Symbol)
    _global_protected(name) && return naught
    rules = env.rules.rules
    for i in Iterators.reverse(eachindex(rules))
        name in rules[i].anchors && deleteat!(rules, i)
    end
    _reindex!(env.rules)
    return naught
end

# Whether `clear name` removes `e`: a `def`/`val` anchored on `name`, or an
# imported/aliased entry exported as `name`.
function _entry_matches_clear(e::Form, name::Symbol)
    b = _entry_body(e)
    b isa FormContainer || return false
    h = head_symbol(b)
    if h === _DEF_HEAD || h === _VAL_HEAD
        length(b.seq) >= 2 || return false
        return name in raw_symbols(to_form(b.seq[2]))
    end
    return _entry_export_name(e) === name
end

# The entries `(clear :all)` removes: definitions, imported copies, proxies,
# aliases, and imported subnamespace links. Local subnamespaces stay.
function _entry_clearable(e::Form)
    b = _entry_body(e)
    b isa FormContainer || return false
    h = head_symbol(b)
    return h === _DEF_HEAD || h === _VAL_HEAD || h === NS_PROXY ||
           h === NS_ALIAS || h === NS_SUB_LINK
end

function _ns_clear!(env::Env, ns::Namespace, name::Symbol)
    (name in ns.protected || _global_protected(name)) && return naught
    _check_ns!(env, ns, :write)
    return tx() do
        entries = _ns_entries_of(ns.vf)
        keep = Form[e for e in entries if !_entry_matches_clear(e, name)]
        _ns_store_entries!(env, ns, keep)
        return naught
    end
end

function _ns_clear_all!(env::Env, ns::Namespace)
    _check_ns!(env, ns, :write)
    return tx() do
        entries = _ns_entries_of(ns.vf)
        keep = Form[e for e in entries if !_entry_clearable(e)]
        _ns_store_entries!(env, ns, keep)
        return naught
    end
end

# `(clear sym)` / `(clear :all)` — remove the current block's definitions that
# use `sym` (or every definition and import for `:all`). `del` is an alias.
# Outside a namespace block `clear` targets the global rule store.
function _bi_clear(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 ||
        throw(AirEvalError("clear expects a single symbol or :all"))
    arg = to_form(call.seq[2])
    name = _symbolof(arg)
    name === nothing && throw(AirEvalError("clear expects a symbol"))
    ns = _write_ns(env)
    if name === _ALL_KEYWORD
        ns === nothing && return naught
        return _ns_clear_all!(env, ns)
    end
    sym = _user_of_key(name)
    ns === nothing && return _del_global!(env, sym)
    return _ns_clear!(env, ns, sym)
end
special!(:clear, _bi_clear)
special!(:del, _bi_clear)

# `(unuse ns [names…])` — remove the current block's imports from `ns`: all of
# them, or just the listed names. Provenance is the entry's `source=`.
function _bi_unuse(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("unuse needs a namespace"))
    ns = _write_ns(env)
    ns === nothing && throw(AirEvalError("unuse requires a current namespace"))
    path = _ns_target_path(env, scope, to_form(call.seq[2]))
    names = Set{Symbol}()
    for i in 3:length(call.seq)
        s = _symbolof(to_form(call.seq[i]))
        s === nothing && throw(AirEvalError("unuse expects name symbols"))
        push!(names, _user_of_key(s))
    end
    _check_ns!(env, ns, :write)
    return tx() do
        entries = _ns_entries_of(ns.vf)
        keep = Form[]
        for e in entries
            src = _entry_source(e)
            if src == path && (isempty(names) || _entry_export_name(e) in names)
                continue
            end
            push!(keep, e)
        end
        _ns_store_entries!(env, ns, keep)
        return naught
    end
end
special!(:unuse, _bi_unuse)

# ---- thread-local rebinding --------------------------------------------------

# `(bind (x=v …) body…)` — rebind the `val`s named by the keys of the mapping for
# the dynamic extent of `body`. The binding form is evaluated first, so its values
# are ordinary expressions (and `(bind (bindings) body)` re-installs the current
# thread's bindings, which is how a spawned task can inherit them). Each name is
# resolved to the `val` its namespace context matches, so `x` may come from a
# `using`ed namespace or from a global `val`; a name that is not a `val` errors.
# The bindings are task-local and are undone when `body` finishes.
function _bi_bind(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("bind needs a binding form"))
    bf = air_reduce(env, scope, to_form(call.seq[2]))
    # `(bindings)` with no active overrides is `naught`; binding nothing is a
    # no-op body, which keeps `(bind (bindings) body)` uniform.
    if !(bf isa FormContainer)
        isequal(bf, naught) || throw(AirEvalError(
            "bind needs a mapping of names to values, got $(air_string(bf))"))
        bf = FormContainer(FormSeq(FormValue[]), FormMap())
    end
    isempty(bf.seq) || throw(AirEvalError(
        "bind needs a single mapping of names to values"))
    binds = IdDict{Var,Any}()
    for (k, v) in bf.map
        name = _bindname(k)
        b = _find_val_binding(env, scope, name)
        b === nothing && throw(AirEvalError(
            "bind: $name is not a thread-local value in this context"))
        _check!(env, b.entry, :read, _keyword_form(name))
        binds[b.var] = canonicalize(to_form(v))
    end
    body() = begin
        r = naught
        for i in 3:length(call.seq)
            r = air_reduce(env, scope, to_form(call.seq[i]))
        end
        r
    end
    return Air.withvars(body, binds)
end
special!(:bind, _bi_bind)

# `(bindings)` — the current thread's `val` overrides as a mapping of names to
# values. Only bindings whose value has been changed (by `bind`, or by a `task`
# carrying them in) are listed; every other `val` still has its definition value.
function _bindings_form(env::Env)
    pairs = Pair{Symbol,Any}[]
    for (v, val) in Air.vars()
        b = get(env.valof, v, nothing)
        b === nothing && continue
        push!(pairs, Symbol(":", String(b.name)) => val)
    end
    return Form(PVector{Any}(), PDict{Symbol,Any}(pairs...))
end

builtin!(:bindings, (env, scope, args) -> begin
    isempty(args) || throw(AirEvalError("bindings takes no arguments"))
    return _bindings_form(env)
end)

# ---- namespace-aware lookup from the core builtins ---------------------------

# The contents a lookup walks: a `val` marker dereferences to its binding, a
# volatile is transparent, and a subnamespace marker resolves through its path.
# Used by `get` (see builtins_core.jl).
function _ns_contents(env::Env, form::Form)
    form = _ns_val_value(env, form)
    _is_ns_proxy(form) && (form = _ns_proxy_value(env, form))
    if form isa VolatileForm
        _check!(env, form, :read)
        form = form[]
    end
    while _is_ns_sub(form)
        path = _ns_path_of_marker(form)
        path === nothing && return form
        ns = _ns_lookup(env, path)
        ns === nothing && return form
        _check_ns!(env, ns, :read)
        form = ns.vf[]
    end
    return _force_ref_form(env, form)
end

# A map entry (or any form reached through `.` access) as the value it exposes: a
# `val` marker becomes the binding's current value, a subnamespace marker becomes
# the subnamespace's volatile, and everything else is returned as stored.
function _ns_value(env::Env, v::Form)
    _is_ns_val(v) && return _ns_val_value(env, v)
    _is_ns_proxy(v) && return _ns_proxy_value(env, v)
    _is_ns_sub(v) || return v
    path = _ns_path_of_marker(v)
    path === nothing && return v
    ns = _ns_lookup(env, path)
    ns === nothing && return v
    _check_ns!(env, ns, :read)
    return ns.vf
end
