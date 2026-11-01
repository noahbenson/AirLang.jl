################################################################################
# agents.jl
#
# Inference-backed agent accounts, durable sessions, and channels.
#
# An agent is an ordinary constituent user account whose `details` say
# `kind=:agent`. Its inference settings live in its own `$.config.agent`
# namespace, so only the agent, its administrator, and `air` can read them.
#
# A session is a mutable stored behind the named form
# `agent/<agent>/sessions/<sid>` in the agent's home database. The mutable's
# value is the durable session state: the status, the model snapshot, the
# transcript, the usage counters, and the three streams that form the channel.
# A handle — `(session id=… agent=… owner=… state=<mut> channel=…)` — is a
# convenience value; the mutable is the durable root.
#
# A channel is a pair of streams plus a private notification copy queue:
#
#   out       the owner's outbox — a message posted here goes TO the agent
#   in        the owner's inbox  — the agent's replies arrive here
#   in-notify the copy queue for the owner's `on-receive` hook
#
# The agent's worker consumes `out` and posts replies to `in`. When an
# `on-receive` hook is installed, the same reply is also copied to `in-notify`
# in the same transaction; the hook drains that copy queue, so a hook gets every
# reply while `channel-fetch` still sees the queued original. The watcher runs
# whichever hook is installed when a copy is dequeued — not the one it saw
# before waiting — so replacing a hook is felt by copies already queued, and a
# copy that outlives the hook is simply dropped.
#
# One worker runs per session per process, in `_AGENT_WORKERS` (keyed by the
# state mutable's id). That registry is only an optimization and a handle:
# durability is the mutable, and a session reopens lazily on the next message.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- names and state ---------------------------------------------------------

const _SESSION_HEAD = Symbol("session")
const _CHANNEL_HEAD = Symbol("channel")
const _AGENT_HEAD = Symbol("agent")
const _AGENT_SESSION_PREFIX = "agent/"

# The inference settings `create-agent`/`agent-config!` accept.
const _AGENT_CONFIG_OPTIONS = Set{Symbol}([
    :provider, :dialect, Symbol("base-url"), :model, Symbol("api-key"), :system,
    Symbol("max-tokens"), :params, :context, Symbol("compact-at"),
    Symbol("compact-keep"), :timeout, :retries])

# The fields a session snapshots from the configuration.
const _AGENT_SNAPSHOT_KEYS = ((:provider), (:dialect), (Symbol("base-url")),
                              (:model), (:system), (Symbol("max-tokens")),
                              (:params), (:context), (Symbol("compact-at")),
                              (Symbol("compact-keep")), (:timeout), (:retries))

# ---- agent identity and access ----------------------------------------------

# A user record reached by a name that may be relative to the caller: for a core
# user `:bot` also means `:<me>:bot`, and a constituent may name itself.
function _agent_lookup(env::Env, id::Symbol)
    d = _user_details(env, id)
    d === nothing || return (id = id, details = d)
    occursin(':', String(id)) && return nothing
    me = _current_user(env)
    kind, _, short = _user_kind(me)
    cands = Symbol[]
    kind === :core && push!(cands, Symbol(me, ":", id))
    (kind === :constituent && short === id) && push!(cands, me)
    for cand in cands
        d2 = _user_details(env, cand)
        d2 === nothing || return (id = cand, details = d2)
    end
    return nothing
end

# Resolve an agent name: a full id, or a bare name relative to the caller.
function _resolve_agent_id(env::Env, id::Symbol)
    found = _agent_lookup(env, id)
    found === nothing && throw(AirAgentError(Symbol("agent-not-found"),
                                             "no such agent: :$id"))
    id, d = found.id, found.details
    d.kind === :agent ||
        throw(AirAgentError(Symbol("not-an-agent"), ":$id is not an agent account"))
    return (id = id, details = d)
end

# An agent argument: a name, an `(agent id=…)` handle, or a session.
function _agent_arg(env::Env, scope::Scope, form::Form)
    v = air_reduce(env, scope, to_form(form))
    if v isa FormContainer && head_symbol(v) === _AGENT_HEAD
        f = _agent_field(v, :id)
    elseif v isa FormContainer && head_symbol(v) === _SESSION_HEAD
        f = _agent_field(v, :agent)
    else
        return _user_id_arg(env, scope, v)
    end
    s = f === nothing ? nothing : _symbolof(f)
    s === nothing && throw(AirEvalError("expected an agent, got $(air_string(v))"))
    return _bindname(s)
end

# The agent's administrator (the session's owner), or `air`.
_agent_owner(id::Symbol, d) = d.parent === nothing ? _AIR : d.parent

function _agent_require_access(env::Env, id::Symbol, d)
    me = _current_user(env)
    (me === _AIR || me === id || (d.parent !== nothing && d.parent === me)) &&
        return nothing
    throw(AirPermissionDenied(:read, _keyword_form(id)))
end

# ---- configuration reading and writing --------------------------------------

# The namespace path holding `id`'s inference settings.
function _agent_config_path(env::Env, id::Symbol)
    home = _user_home_path(env, id)
    home === nothing &&
        throw(AirAgentError(Symbol("agent-not-found"), "no such agent: :$id"))
    return vcat(home, Symbol[_CONFIG_NS, _AGENT_NS])
end

# The reduced option values of an agent call, rejecting unknown options.
function _agent_option_vals(env::Env, scope::Scope, call::FormContainer,
                            who::AbstractString)
    vals = Dict{Symbol,Form}()
    for (k, v) in call.map
        name = _bindname(k)
        name in _AGENT_CONFIG_OPTIONS ||
            throw(AirEvalError("$who: unknown option $(name)"))
        x = air_reduce(env, scope, to_form(v))
        if name === :model && _agent_string(x) === nothing
            throw(_agent_misconfigured("model must be a string"))
        elseif name === Symbol("api-key") && _agent_string(x) === nothing &&
               !isequal(x, naught)
            throw(_agent_misconfigured("api-key must be a string"))
        end
        vals[name] = x
    end
    return vals
end

# Run `f` with the agent's identity, home namespace, and database root.
function _agent_context(env::Env, id::Symbol, home::Vector{Symbol}, dbroot)
    ns = _ns_lookup(env, home; lazy = false)
    return TaskContext(id, ns, dbroot, naught)
end

# The `@` root to give an agent whose session lives in `db`: the caller's root
# when it belongs to that database, else `nothing`.
function _agent_dbroot_in(env::Env, db)
    r = _context(env).dbroot
    r isa VolatileForm || return nothing
    return r.db === db ? r : nothing
end

# Write every resolved configuration val as the agent, creating `$.config.agent`.
function _agent_write_config!(env::Env, id::Symbol, cfg::_AgentConfig,
                              home::Vector{Symbol}, dbroot)
    vals = _agent_config_vals(cfg)
    ctx = _agent_context(env, id, home, dbroot)
    _with_context(env, ctx, () -> _tx_boundary(env) do
        path = vcat(home, Symbol[_CONFIG_NS, _AGENT_NS])
        ns = _ns_ensure!(env, path)
        for (k, v) in vals
            _ns_add_val!(env, ns, Form(Symbol(String(k))), v)
        end
    end)
    return nothing
end

# Every resolved configuration field as a val value. An unset model or API key is
# omitted rather than written as `naught`.
function _agent_config_vals(cfg::_AgentConfig)
    pairs = Pair{Symbol,Form}[
        :provider => _keyword_form(cfg.provider),
        :dialect => _keyword_form(cfg.dialect),
        Symbol("base-url") => Form(cfg.base_url),
        :system => Form(cfg.system),
        Symbol("max-tokens") => Form(cfg.max_tokens),
        :params => cfg.params,
        :context => cfg.context === nothing ? naught : Form(cfg.context),
        Symbol("compact-at") => Form(cfg.compact_at),
        Symbol("compact-keep") => Form(cfg.compact_keep),
        :timeout => Form(cfg.timeout),
        :retries => Form(cfg.retries)]
    cfg.model === nothing || pushfirst!(pairs, :model => Form(cfg.model))
    cfg.api_key === nothing ||
        pushfirst!(pairs, Symbol("api-key") => Form(cfg.api_key))
    return pairs
end

# The stored configuration as a mapping, redacting the API key.
function _agent_config_form(env::Env, id::Symbol; secrets::Bool = false)
    path = _agent_config_path(env, id)
    pairs = Pair{Symbol,Form}[]
    for name in (:provider, :dialect, Symbol("base-url"), :model,
                 Symbol("api-key"), :system, Symbol("max-tokens"), :params,
                 :context, Symbol("compact-at"), Symbol("compact-keep"),
                 :timeout, :retries)
        v = _agent_ns_val(env, path, name)
        v === nothing && continue
        if name === Symbol("api-key") && !secrets && !isequal(v, naught)
            v = Form("***")
        end
        push!(pairs, Symbol(":", String(name)) => v)
    end
    return _ns_form(Form[], pairs)
end

# A state snapshot built from an option table, for validating a configuration.
function _agent_option_state(vals::AbstractDict{Symbol,Form})
    pairs = Pair{Symbol,Form}[Symbol(":", String(k)) => v for (k, v) in vals]
    return _ns_form(Form[], pairs)
end

# ---- create-agent ------------------------------------------------------------

# `(create-agent :bot provider=:fireworks model="…" api-key="…" …)` — create an
# `:agent` constituent of the caller and store its configuration.
function _bi_create_agent(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 ||
        throw(AirEvalError("create-agent needs a name"))
    me = _current_user(env)
    _is_admin(env, me) ||
        throw(AirEvalError("only an admin may create an agent"))
    _user_kind(me)[1] === :core ||
        throw(AirEvalError("a constituent cannot create agents"))
    name = _user_id_arg(env, scope, to_form(call.seq[2]))
    _valid_name_segment(String(name)) ||
        throw(AirEvalError("invalid agent name :$name"))
    id = Symbol(me, ":", name)
    _user_exists(env, id) && throw(AirDefError("user :$id already exists"))
    vals = _agent_option_vals(env, scope, call, "create-agent")
    haskey(vals, :model) || throw(_agent_misconfigured(
        "create-agent needs a model"))
    key = get(vals, Symbol("api-key"), naught)
    cfg = _agent_cfg_resolve(_agent_option_state(vals),
                             n -> n === Symbol("api-key") ? key : nothing)
    _tx_boundary(env) do
        _create_system_user!(env, id; parent = me, kind = :agent)
        home = _user_home_path(env, id)
        home === nothing &&
            throw(AirAgentError(Symbol("agent-not-found"), "no such agent: :$id"))
        dbroot = _agent_dbroot_in(env, _persist_db_in(env, home))
        _agent_write_config!(env, id, cfg, home, dbroot)
    end
    return _agent_form(id, cfg)
end
special!(Symbol("create-agent"), _bi_create_agent)

# The `(agent id=…)` value `create-agent` returns.
function _agent_form(id::Symbol, cfg::_AgentConfig)
    model = cfg.model === nothing ? naught : Form(cfg.model)
    return _ns_form(Form[Form(_AGENT_HEAD)], Pair{Symbol,Form}[
        Symbol(":id") => _keyword_form(id),
        Symbol(":provider") => _keyword_form(cfg.provider),
        Symbol(":dialect") => _keyword_form(cfg.dialect),
        Symbol(":base-url") => Form(cfg.base_url),
        Symbol(":model") => model])
end

# `(agent? x)` — whether `x` names an agent account.
builtin!(Symbol("agent?"), (env, scope, args) -> begin
    x = _arg(args, 1, "agent?")
    id = if x isa FormContainer && head_symbol(x) === _AGENT_HEAD
        idf = _agent_field(x, :id)
        s = idf === nothing ? nothing : _symbolof(idf)
        s === nothing ? nothing : _bindname(s)
    else
        s = _symbolof(x)
        s === nothing ? nothing : _bindname(s)
    end
    id === nothing && return Form(false)
    found = _agent_lookup(env, id)
    return Form(found !== nothing && found.details.kind === :agent)
end)

# `(agent-config agent secrets=false)` — the stored inference settings.
function _bi_agent_config(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "agent-config", (Symbol(":secrets"),))
    length(call.seq) == 2 || throw(AirEvalError("agent-config needs an agent"))
    id = _resolve_agent_id(env, _agent_arg(env, scope, to_form(call.seq[2]))).id
    _agent_require_access(env, id, _user_details(env, id))
    secrets = haskey(call.map, Symbol(":secrets")) &&
              truthy(air_reduce(env, scope, to_form(call.map[Symbol(":secrets")])))
    return _agent_config_form(env, id; secrets = secrets)
end
special!(Symbol("agent-config"), _bi_agent_config)

# `(agent-config! agent key=value …)` — update the listed settings.
function _bi_agent_config_update(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 ||
        throw(AirEvalError("agent-config! needs an agent"))
    isempty(call.map) &&
        throw(AirEvalError("agent-config! needs at least one setting"))
    id = _resolve_agent_id(env, _agent_arg(env, scope, to_form(call.seq[2]))).id
    _agent_require_access(env, id, _user_details(env, id))
    vals = _agent_option_vals(env, scope, call, "agent-config!")
    # Validate the merged configuration before writing anything.
    _agent_cfg(env, id, _agent_option_state(vals))
    home = _user_home_path(env, id)
    home === nothing &&
        throw(AirAgentError(Symbol("agent-not-found"), "no such agent: :$id"))
    dbroot = _agent_dbroot_in(env, _persist_db_in(env, home))
    ctx = _agent_context(env, id, home, dbroot)
    _with_context(env, ctx, () -> _tx_boundary(env) do
        path = vcat(home, Symbol[_CONFIG_NS, _AGENT_NS])
        ns = _ns_ensure!(env, path)
        for (k, v) in vals
            _ns_add_val!(env, ns, Form(Symbol(String(k))), v)
        end
    end)
    return _agent_config_form(env, id)
end
special!(Symbol("agent-config!"), _bi_agent_config_update)

# ---- session state and handles ----------------------------------------------

_agent_session_name(id::Symbol, sid::AbstractString) =
    _AGENT_SESSION_PREFIX * String(id) * "/sessions/" * String(sid)

# A fresh session id that is not in use in `db`.
function _agent_new_sid(env::Env, db, id::Symbol)
    for _ in 1:64
        sid = "s-" * join(string(b; base = 16, pad = 2) for b in rand(UInt8, 4))
        name = _agent_session_name(id, sid)
        existing = _named_call(() -> named_form(db, name; create = nothing))
        existing === nothing && return sid
    end
    throw(AirAgentError(Symbol("agent-session"), "could not allocate a session id"))
end

# The status keyword of a state value.
function _agent_status(s::Form)
    v = _agent_kw(_agent_field(s, :status))
    return v === nothing ? :open : v
end

# The transcript entries of a state value, as forms.
function _agent_transcript(s::Form)
    tr = _agent_field(s, :transcript)
    return tr isa FormContainer ? Form[to_form(x) for x in tr.seq] : Form[]
end

_agent_transcript_form(tr::Vector{Form}) = _ns_form(tr)

# A transcript entry: `(role=:user text="…")`.
_agent_entry(role::Symbol, text::AbstractString) =
    _ns_form(Form[], Pair{Symbol,Form}[Symbol(":role") => _keyword_form(role),
                                       Symbol(":text") => Form(String(text))])

# The usage counters of a state value.
function _agent_usage(s::Form)
    u0 = _agent_field(s, :usage)
    u = u0 === nothing ? naught : u0
    geti(name, default) = something(_agent_int_field(u, name), default)
    return (input = geti(:input, 0),
            output = geti(:output, 0),
            total = geti(:total, 0),
            calls = geti(:calls, 0),
            compactions = geti(:compactions, 0),
            last_input = _agent_int_field(u, Symbol("last-input")))
end

_agent_usage_form(u) = _ns_form(Form[], Pair{Symbol,Form}[
    Symbol(":input") => Form(u.input),
    Symbol(":output") => Form(u.output),
    Symbol(":total") => Form(u.total),
    Symbol(":calls") => Form(u.calls),
    Symbol(":compactions") => Form(u.compactions),
    Symbol(":last-input") => u.last_input === nothing ? naught : Form(u.last_input)])

# Add one call's or one compaction's usage to the counters. `last_input` is the
# exact input count of the most recent chat call (the estimate's floor).
function _agent_usage_add(u, input, output; compaction::Bool = false,
                          last_input = nothing)
    i = input === nothing ? 0 : Int(input)
    o = output === nothing ? 0 : Int(output)
    return (input = u.input + i, output = u.output + o, total = u.total + i + o,
            calls = u.calls + (compaction ? 0 : 1),
            compactions = u.compactions + (compaction ? 1 : 0),
            last_input = last_input === nothing ? u.last_input : Int(last_input))
end

# The session state value behind a handle (live, from the mutable).
function _session_state_vf(env::Env, h::Form, who::AbstractString)
    h isa FormContainer ||
        throw(AirEvalError("$who expects a session, got $(air_string(h))"))
    st = _agent_field(h, :state)
    st isa VolatileForm ||
        throw(AirEvalError("$who expects a session, got $(air_string(h))"))
    _check!(env, st, :read)
    return st
end

# The channel state mutable behind a channel handle.
function _channel_state_vf(env::Env, ch::Form, who::AbstractString)
    ch isa FormContainer ||
        throw(AirEvalError("$who expects a channel, got $(air_string(ch))"))
    st = _agent_field(ch, :state)
    st isa VolatileForm ||
        throw(AirEvalError("$who expects a channel, got $(air_string(ch))"))
    _check!(env, st, :read)
    return st
end

_session_value(st::VolatileForm) = canonicalize(to_form(st[]))

# The `dbroot` a state records, as a TaskContext field.
function _agent_dbroot_value(s::Form)
    v = _agent_field(s, :dbroot)
    (v === nothing || isequal(v, naught)) && return nothing
    return v isa VolatileForm ? v : nothing
end

# The agent's task context, rebuilt from a state value.
function _agent_ctx_from_state(env::Env, s::Form)
    agent = _agent_kw(_agent_field(s, :agent))
    agent === nothing &&
        throw(AirAgentError(Symbol("agent-session"), "the session has no agent"))
    hp = _agent_field(s, :home)
    home = hp === nothing ? nothing : _stored_path(hp)
    ns = home === nothing ? nothing : _ns_lookup(env, home; lazy = false)
    return TaskContext(agent, ns, _agent_dbroot_value(s), naught)
end

# A state value with selected map entries replaced.
function _agent_set(s::FormContainer, pairs::AbstractVector)
    mp = Pair{Symbol,Form}[k => to_form(v) for (k, v) in s.map]
    for (k, v) in pairs
        i = findfirst(p -> p.first === k, mp)
        i === nothing ? push!(mp, k => v) : (mp[i] = k => v)
    end
    seq = Form[to_form(x) for x in s.seq]
    return _ns_form(seq, mp)
end

# Read-modify-write the session state in one transaction, returning the new
# value. `f` receives the current value; returning `nothing` leaves it alone.
function _agent_update!(env::Env, st::VolatileForm, f::Function)
    return _tx_boundary(env) do
        _ensure_hooks!(env, st)
        _record_write!(env, st)
        cur = canonicalize(to_form(st[]))
        cur isa FormContainer || throw(AirAgentError(
            Symbol("agent-session"), "the session state is not a mapping"))
        new = f(cur)
        if new !== nothing
            _check_storable!(env, st.db, new)
            setindex!(st, new)
        end
        new === nothing ? cur : new
    end
end
_agent_update!(f::Function, env::Env, st::VolatileForm) = _agent_update!(env, st, f)

# A state field, or `naught` when the state does not carry it.
function _agent_or_naught(s::Form, k::Symbol)
    v = _agent_field(s, k)
    return v === nothing ? naught : v
end

# A user-id field of a state value as a keyword form.
_agent_user_form(s::Form, k::Symbol) = begin
    u = _agent_kw(_agent_field(s, k))
    _keyword_form(u === nothing ? _AIR : u)
end

# The channel handle for a state value.
function _agent_channel_handle(s::Form, st::VolatileForm)
    cid = _agent_string(_agent_field(s, Symbol("channel-id")))
    return _ns_form(Form[Form(_CHANNEL_HEAD)], Pair{Symbol,Form}[
        Symbol(":id") => Form(cid === nothing ? "" : cid),
        Symbol(":agent") => _agent_user_form(s, :agent),
        Symbol(":owner") => _agent_user_form(s, :owner),
        Symbol(":state") => st,
        Symbol(":in") => _agent_or_naught(s, :in),
        Symbol(":out") => _agent_or_naught(s, :out),
        Symbol(":in-notify") => _agent_or_naught(s, Symbol("in-notify"))])
end

# The session handle for a state value and its mutable.
function _agent_handle(s::Form, st::VolatileForm)
    sid = _agent_string(_agent_field(s, :id))
    return _ns_form(Form[Form(_SESSION_HEAD)], Pair{Symbol,Form}[
        Symbol(":id") => Form(sid === nothing ? "" : sid),
        Symbol(":agent") => _agent_user_form(s, :agent),
        Symbol(":owner") => _agent_user_form(s, :owner),
        Symbol(":state") => st,
        Symbol(":channel") => _agent_channel_handle(s, st)])
end

# The channel of a session handle.
function _session_channel_form(h::Form)
    ch = _agent_field(h, :channel)
    ch === nothing && throw(AirEvalError("not a session"))
    return ch
end

# ---- opening and reopening sessions -----------------------------------------

# `(open-session agent opts…)` — create a session, or reopen one by `id=`.
function _bi_open_session(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 || throw(AirEvalError("open-session needs an agent"))
    for k in keys(call.map)
        name = _bindname(k)
        (name === :id || name in _AGENT_CONFIG_OPTIONS) ||
            throw(AirEvalError("open-session: unknown option $(name)"))
    end
    resolved = _resolve_agent_id(env, _agent_arg(env, scope, to_form(call.seq[2])))
    id, d = resolved.id, resolved.details
    _agent_require_access(env, id, d)
    haskey(call.map, Symbol(":api-key")) &&
        throw(AirEvalError("open-session: the api-key comes from agent-config!"))
    overwrites = Dict{Symbol,Form}()
    for k in _AGENT_SNAPSHOT_KEYS
        kk = Symbol(":", String(k))
        haskey(call.map, kk) &&
            (overwrites[k] = air_reduce(env, scope, to_form(call.map[kk])))
    end
    if haskey(call.map, Symbol(":id"))
        sid = _agent_sid_arg(env, scope, to_form(call.map[Symbol(":id")]))
        return _agent_reopen!(env, id, sid)
    end
    return _agent_open_new!(env, id, d, overwrites)
end
special!(Symbol("open-session"), _bi_open_session)

# A session id argument: the string (or symbol) as stored, `s-…`.
function _agent_sid_arg(env::Env, scope::Scope, form::Form)
    l = _leafof(air_reduce(env, scope, to_form(form)))
    s = l isa AbstractString ? String(l) :
        l isa Symbol ? String(_bindname(l)) : nothing
    s === nothing && throw(AirEvalError(
        "a session id must be a string, got $(air_string(to_form(l)))"))
    startswith(s, "s-") || (s = "s-" * s)
    all(c -> isletter(c) || isdigit(c) || c == '-', s) ||
        throw(AirEvalError("invalid session id $(repr(s))"))
    return s
end

# Create a fresh session: the streams, the state mutable, and its name.
function _agent_open_new!(env::Env, id::Symbol, d, overwrites)
    home = _user_home_path(env, id)
    home === nothing &&
        throw(AirAgentError(Symbol("agent-not-found"), "no such agent: :$id"))
    snap = _agent_option_state(overwrites)
    cfg = _agent_cfg(env, id, snap)
    cfg.model === nothing &&
        throw(_agent_misconfigured("no model is configured for :$id"))
    cfg.api_key === nothing &&
        throw(_agent_misconfigured("no api-key is configured for :$id"))
    owner = _agent_owner(id, d)
    db = _persist_db_in(env, home)
    sid = _agent_new_sid(env, db, id)
    dbroot = _agent_dbroot_in(env, db)
    ctx = _agent_context(env, id, home, dbroot)
    statevf = _with_context(env, ctx, () -> _tx_boundary(env) do
        sdb = _persist_db(env)
        md = _metadata_form(id; acl = _perms_acl(id))
        ins = StreamForm(sdb; metadata = md)
        outs = StreamForm(sdb; metadata = md)
        notif = StreamForm(sdb; metadata = md)
        now = _mk_time(_now_secs())
        pairs = vcat(
            Pair{Symbol,Form}[
                Symbol(":id") => Form(sid),
                Symbol(":agent") => _keyword_form(id),
                Symbol(":owner") => _keyword_form(owner),
                Symbol(":status") => _keyword_form(:open),
                Symbol(":home") => _ns_path_form(home),
                Symbol(":dbroot") => dbroot === nothing ? naught : dbroot,
                Symbol(":channel-id") => Form("c-" * sid[3:end]),
                Symbol(":in") => ins,
                Symbol(":out") => outs,
                Symbol(":in-notify") => notif,
                Symbol(":in-hook") => naught],
            _agent_snapshot_pairs(cfg),
            Pair{Symbol,Form}[
                Symbol(":transcript") => naught,
                Symbol(":usage") => _agent_usage_form(_agent_usage(naught)),
                Symbol(":created") => now,
                Symbol(":updated") => now,
                Symbol(":last-error") => naught,
                Symbol(":last-hook-error") => naught])
        sval = _ns_form(Form[Form(_SESSION_HEAD)], pairs)
        _check_storable!(env, sdb, sval)
        vf = VolatileForm(sdb, sval; metadata = md)
        _ensure_hooks!(env, vf)
        _named_call(() -> named_form(sdb, _agent_session_name(id, sid);
                                     create = true, value = vf))
        vf
    end)
    return _agent_handle(_session_value(statevf), statevf)
end

# The database a namespace path lives in.
function _persist_db_in(env::Env, path::Vector{Symbol})
    ns = _ns_lookup(env, path; lazy = false)
    ns === nothing &&
        throw(AirAgentError(Symbol("agent-not-found"), "no namespace at $(_ns_display(path))"))
    return ns.vf.db
end

# Reopen an existing session by id.
function _agent_reopen!(env::Env, id::Symbol, sid::AbstractString)
    home = _user_home_path(env, id)
    home === nothing &&
        throw(AirAgentError(Symbol("agent-not-found"), "no such agent: :$id"))
    db = _persist_db_in(env, home)
    name = _agent_session_name(id, sid)
    vf = _named_call(() -> named_form(db, name; create = nothing))
    vf === nothing && throw(AirAgentError(
        Symbol("agent-not-found"), "no session \"$sid\" for :$id"))
    _check!(env, vf, :read)
    s = _session_value(vf)
    h = _agent_handle(s, vf)
    if _agent_status(s) === :open
        _agent_wake_if_queued!(env, vf, s)
        _agent_wake_hook!(env, s, vf)
    end
    return h
end

# ---- the session registry ----------------------------------------------------

mutable struct _AgentWorker
    task::Union{Nothing,Task}
    done::Bool
end

const _AGENT_WORKERS = Dict{Base.UUID,_AgentWorker}()
const _AGENT_WORKERS_LOCK = ReentrantLock()
const _AGENT_HOOKS = Dict{Base.UUID,_AgentWorker}()
const _AGENT_HOOKS_LOCK = ReentrantLock()

_agent_worker_live(w::Union{Nothing,_AgentWorker}) =
    w !== nothing && w.task !== nothing && !istaskdone(w.task) && !w.done

"""
    _ensure_worker!(env, st, s) -> nothing

Start the session's worker unless one is already running. The worker runs as
the agent, in the agent's home namespace, under its recorded `@` root.
"""
function _ensure_worker!(env::Env, st::VolatileForm, s::Form)
    _agent_status(s) === :open || return nothing
    key = st.id
    ctx = _agent_ctx_from_state(env, s)
    lock(_AGENT_WORKERS_LOCK)
    try
        w = get(_AGENT_WORKERS, key, nothing)
        _agent_worker_live(w) && return nothing
        w = _AgentWorker(nothing, false)
        _AGENT_WORKERS[key] = w
        se = _session_env(env)
        t = Threads.@spawn begin
            _reset_block_scopes!()
            try
                _with_context(se, ctx, () -> _agent_worker_loop(se, st))
            catch e
                e isa InterruptException && rethrow()
            finally
                w.done = true
                lock(_AGENT_WORKERS_LOCK) do
                    cur = get(_AGENT_WORKERS, key, nothing)
                    cur === w && delete!(_AGENT_WORKERS, key)
                end
            end
        end
        w.task = t
    finally
        unlock(_AGENT_WORKERS_LOCK)
    end
    return nothing
end

# Start the worker only when its outbox already has a message.
function _agent_wake_if_queued!(env::Env, st::VolatileForm, s::Form)
    out = _agent_field(s, :out)
    out isa StreamForm || return nothing
    _agent_stream_count(out) > 0 || return nothing
    return _ensure_worker!(env, st, s)
end

# Start the hook watcher when the state has an `on-receive` hook installed.
function _agent_wake_hook!(env::Env, s::Form, st::VolatileForm)
    hook = _agent_field(s, Symbol("in-hook"))
    (hook === nothing || isequal(hook, naught)) && return nothing
    return _ensure_hook_watcher!(env, st)
end

# ---- the worker --------------------------------------------------------------

# The keyword head of a command form, or `nothing` for a chat message.
function _agent_command_head(msg::Form)
    msg isa FormContainer || return nothing
    isempty(msg.seq) && return nothing
    s = _symbolof(to_form(msg.seq[1]))
    (s === nothing || !is_keyword(s)) && return nothing
    return Symbol(String(s)[2:end])
end

# The transport-independent text of a chat message.
function _agent_message_text(msg::Form)
    l = _leafof(msg)
    l isa AbstractString && return String(l)
    return air_string(msg)
end

# The worker's loop: consume the outbox, one message at a time.
function _agent_worker_loop(env::Env, st::VolatileForm)
    while true
        s = _session_value(st)
        _agent_status(s) === :open || return nothing
        out = _agent_field(s, :out)
        out isa StreamForm || return nothing
        item = try
            take(out; timeout = 0.5)
        catch e
            e isa Air.ReaderTimeout && continue
            e isa Air.StreamClosed && return nothing
            e isa Air.StreamDeadlock && return nothing
            e isa UncommittedStream && return nothing
            e isa AbortedStream && return nothing
            rethrow()
        end
        r = _agent_dispatch!(env, st, _stream_object(to_form(item)))
        (r === :stop || r === :closed) && return nothing
    end
end

# Handle one message. Returns `:stop`/`:closed` to end the worker.
function _agent_dispatch!(env::Env, st::VolatileForm, msg::Form)
    cmd = _agent_command_head(msg)
    try
        cmd === nothing ? _agent_turn!(env, st, msg) :
            _agent_command!(env, st, msg::FormContainer)
        return nothing
    catch e
        e isa InterruptException && rethrow()
        if e isa AirStreamError && e.tag === Symbol("stream-closed")
            return :closed
        elseif e isa Air.StreamClosed
            return :closed
        end
        form = try
            _error_form(e)
        catch
            return :closed
        end
        ok = try
            _agent_update!(env, st) do cur
                out = _agent_set(cur, [Symbol(":last-error") => form])
                _agent_post!(env, out, form)
                out
            end
            true
        catch
            false
        end
        return ok ? nothing : :closed
    end
end

# Post `reply` to the owner's inbox, and its copy to the notification queue
# when a hook is installed. Runs inside the caller's transaction.
function _agent_post!(env::Env, s::Form, reply::Form)
    ins = _agent_field(s, :in)
    ins isa StreamForm || return nothing
    envform = _stream_envelope(reply, _current_user(env), _now_secs())
    put!(ins, envform)
    hook = _agent_field(s, Symbol("in-hook"))
    if hook !== nothing && !isequal(hook, naught)
        n = _agent_field(s, Symbol("in-notify"))
        n isa StreamForm && put!(n, envform)
    end
    return nothing
end

# Post a reply that does not change the session state.
function _agent_post_only!(env::Env, st::VolatileForm, reply::Form)
    s = _session_value(st)
    _tx_boundary(env) do
        _agent_post!(env, s, reply)
    end
    return nothing
end

# ---- one model turn ----------------------------------------------------------

# Compaction of a transcript: the kept tail, an optional summary prefix, and the
# summarizer's usage.
struct _AgentCompaction
    transcript::Vector{Form}
    input::Union{Nothing,Int}
    output::Union{Nothing,Int}
    changed::Bool
end

# Summarize all but the last `compact-keep` entries.
function _agent_compact(cfg::_AgentConfig, tr::Vector{Form})
    n = length(tr)
    keep = min(cfg.compact_keep, n)
    nk = n - keep
    nk <= 0 && return _AgentCompaction(tr, nothing, nothing, false)
    prefix = tr[1:nk]
    tail = tr[(nk + 1):end]
    text = join((string("$(_agent_entry_role(e)): $(_agent_entry_text(e))")
                 for e in prefix), "\n\n")
    r = _agent_summarize(cfg, text)
    newtr = vcat(Form[_agent_entry(:summary, r.summary)], tail)
    return _AgentCompaction(newtr, r.input, r.output, true)
end

# The `(reply …)` form for one answer.
function _agent_reply_form(cfg::_AgentConfig, r)
    input = r.input === nothing ? 0 : Int(r.input)
    output = r.output === nothing ? 0 : Int(r.output)
    return _ns_form(Form[Form(Symbol("reply"))], Pair{Symbol,Form}[
        Symbol(":text") => Form(r.text),
        Symbol(":model") => Form(_agent_model!(cfg)),
        Symbol(":stop") => r.stop === nothing ? naught : Form(r.stop),
        Symbol(":usage") => _ns_form(Form[], Pair{Symbol,Form}[
            Symbol(":input") => Form(input),
            Symbol(":output") => Form(output),
            Symbol(":total") => Form(input + output)]),
        Symbol(":time") => _mk_time(_now_secs())])
end

# Persist a transcript/usage update and return the new state.
function _agent_store_turn!(env::Env, st::VolatileForm, tr::Vector{Form}, u)
    return _agent_update!(env, st) do cur
        _agent_set(cur, [Symbol(":transcript") => _agent_transcript_form(tr),
                         Symbol(":usage") => _agent_usage_form(u),
                         Symbol(":updated") => _mk_time(_now_secs())])
    end
end

# Run one model turn for `msg`: compact if needed, call the model, record the
# answer, and post the reply.
function _agent_turn!(env::Env, st::VolatileForm, msg::Form)
    text = _agent_message_text(msg)
    s = _session_value(st)
    agent = _agent_kw(_agent_field(s, :agent))
    agent === nothing &&
        throw(AirAgentError(Symbol("agent-session"), "the session names no agent"))
    cfg = _agent_cfg(env, agent, s)
    tr = vcat(_agent_transcript(s), Form[_agent_entry(:user, text)])
    u = _agent_usage(s)
    # Compact before the call when the estimate crosses the trigger.
    if cfg.context !== nothing
        est = _agent_estimate_tokens(cfg.system, tr, u.last_input)
        if est > cfg.compact_at * cfg.context
            c = _agent_compact(cfg, tr)
            if c.changed
                tr = c.transcript
                u = _agent_usage_add(u, c.input, c.output; compaction = true)
            end
        end
    end
    est = _agent_estimate_tokens(cfg.system, tr, u.last_input)
    # Record the user turn before the request, so a failed call leaves it in
    # the transcript (and a retried call sees it again).
    _agent_store_turn!(env, st, tr, u)
    maxtok = cfg.max_tokens
    if cfg.context !== nothing
        room = cfg.context - est
        if room <= 0
            c = _agent_compact(cfg, tr)
            c.changed || throw(AirAgentError(
                Symbol("agent-context"),
                "about $est tokens do not fit the $(cfg.context)-token window"))
            tr = c.transcript
            u = _agent_usage_add(u, c.input, c.output; compaction = true)
            est = _agent_estimate_tokens(cfg.system, tr, u.last_input)
            room = cfg.context - est
            room > 0 || throw(AirAgentError(
                Symbol("agent-context"),
                "about $est tokens do not fit the $(cfg.context)-token window"))
            _agent_store_turn!(env, st, tr, u)
        end
        maxtok = min(maxtok, max(1, room))
    end
    system, msgs = _agent_messages(cfg.system, tr)
    r = _agent_complete(cfg, system, msgs, maxtok)
    reply = _agent_reply_form(cfg, r)
    _agent_update!(env, st) do cur
        tr2 = vcat(_agent_transcript(cur), Form[_agent_entry(:assistant, r.text)])
        u2 = _agent_usage_add(_agent_usage(cur), r.input, r.output;
                              last_input = r.input)
        out = _agent_set(cur, [
            Symbol(":transcript") => _agent_transcript_form(tr2),
            Symbol(":usage") => _agent_usage_form(u2),
            Symbol(":updated") => _mk_time(_now_secs()),
            Symbol(":last-error") => naught])
        _agent_post!(env, out, reply)
        out
    end
    return nothing
end

# ---- commands ----------------------------------------------------------------

# The text argument of a command, reduced in the agent's namespace.
function _agent_command_text(env::Env, msg::FormContainer, name::AbstractString)
    length(msg.seq) >= 2 ||
        throw(AirAgentError(Symbol("agent-command"), "$name needs a value"))
    v = air_reduce(env, _base_scope(env), to_form(msg.seq[2]))
    return _agent_message_text(v)
end

_agent_ack(cmd::Symbol; pairs = Pair{Symbol,Form}[]) =
    _ns_form(Form[Form(Symbol(":ack")), Form(Symbol(":" * String(cmd)))], pairs)

# Handle a keyword-headed command. Returns `:stop` for `(:stop)`.
function _agent_command!(env::Env, st::VolatileForm, msg::FormContainer)
    cmd = _agent_command_head(msg)
    s = _session_value(st)
    agent = _agent_kw(_agent_field(s, :agent))
    tr = _agent_transcript(s)
    u = _agent_usage(s)
    if cmd === :help
        cmds = _ns_form(Form[Form(Symbol(":" * String(c)))
                            for c in (:compact, :model, :system, :context,
                                      :reset, :stop, :help)])
        _agent_post_only!(env, st, _agent_ack(:help; pairs = Pair{Symbol,Form}[Symbol(":commands") => cmds]))
        return nothing
    elseif cmd === :context
        system = _agent_string(_agent_field(s, :system))
        est = _agent_estimate_tokens(system === nothing ? "" : system, tr,
                                     u.last_input)
        lim = _agent_field(s, :context)
        pairs = Pair{Symbol,Form}[
            Symbol(":messages") => Form(length(tr)),
            Symbol(":estimate") => Form(est),
            Symbol(":usage") => _agent_usage_form(u)]
        isempty(tr) || push!(pairs, Symbol(":system") => Form(system === nothing ? "" : system))
        lim === nothing ||
            isequal(lim, naught) ||
            push!(pairs, Symbol(":limit") => lim)
        _agent_post_only!(env, st, _ns_form(Form[Form(Symbol(":context"))], pairs))
        return nothing
    elseif cmd === :reset
        _agent_update!(env, st) do cur
            out = _agent_set(cur, [Symbol(":transcript") => naught,
                                   Symbol(":updated") => _mk_time(_now_secs())])
            _agent_post!(env, out, _agent_ack(:reset))
            out
        end
        return nothing
    elseif cmd === :system
        v = _agent_command_text(env, msg, "(:system …)")
        _agent_update!(env, st) do cur
            out = _agent_set(cur, [Symbol(":system") => Form(v),
                                   Symbol(":updated") => _mk_time(_now_secs())])
            _agent_post!(env, out, _agent_ack(:system))
            out
        end
        return nothing
    elseif cmd === :model
        v = _agent_command_text(env, msg, "(:model …)")
        _agent_update!(env, st) do cur
            out = _agent_set(cur, [Symbol(":model") => Form(v),
                                   Symbol(":updated") => _mk_time(_now_secs())])
            _agent_post!(env, out, _agent_ack(:model;
                                              pairs = Pair{Symbol,Form}[Symbol(":model") => Form(v)]))
            out
        end
        return nothing
    elseif cmd === :compact
        cfg = _agent_cfg(env, agent, s)
        system = cfg.system
        before = _agent_estimate_tokens(system, tr, u.last_input)
        c = _agent_compact(cfg, tr)
        u2 = _agent_usage_add(u, c.input, c.output; compaction = c.changed)
        after = _agent_estimate_tokens(system, c.transcript, u2.last_input)
        _agent_update!(env, st) do cur
            out = _agent_set(cur, [
                Symbol(":transcript") => _agent_transcript_form(c.transcript),
                Symbol(":usage") => _agent_usage_form(u2),
                Symbol(":updated") => _mk_time(_now_secs())])
            _agent_post!(env, out, _agent_ack(:compact; pairs = Pair{Symbol,Form}[
                Symbol(":before") => Form(before),
                Symbol(":after") => Form(after),
                Symbol(":usage") => _agent_usage_form(u2)]))
            out
        end
        return nothing
    elseif cmd === :stop
        _agent_update!(env, st) do cur
            out = _agent_set(cur, [Symbol(":status") => _keyword_form(:paused),
                                   Symbol(":updated") => _mk_time(_now_secs())])
            _agent_post!(env, out, _agent_ack(:stop))
            out
        end
        return :stop
    end
    _agent_post_only!(env, st,
                      _error_object(Form[Form(Symbol(":agent-command"))],
                                    Pair{Symbol,Form}[
                                        Symbol(":head") =>
                                            Form(Symbol(":" * String(cmd)))]))
    return nothing
end

# ---- channels ----------------------------------------------------------------

# A safe stream item count (a closed or absent stream counts as zero).
function _agent_stream_count(s::StreamForm)
    try
        return Int(length(s))
    catch
        return 0
    end
end

# Drain a stream without blocking (outside a transaction).
function _agent_drain!(s::StreamForm)
    while _agent_stream_count(s) > 0
        try
            take(s; timeout = 0.05)
        catch
            return nothing
        end
    end
    return nothing
end

# `(channel? x)` — whether `x` is a channel handle.
builtin!(Symbol("channel?"), (env, scope, args) -> begin
    x = _arg(args, 1, "channel?")
    return Form(x isa FormContainer && head_symbol(x) === _CHANNEL_HEAD &&
                _agent_field(x, :state) isa VolatileForm)
end)

# The shared body of `channel-post` and `session-post`.
function _do_channel_post(env::Env, ch::Form, value::Form)
    st = _channel_state_vf(env, ch, "channel-post")
    s = _session_value(st)
    out = _agent_field(s, :out)
    out isa StreamForm || throw(AirAgentError(
        Symbol("agent-session"), "the session has no outbox"))
    _check!(env, out, :write)
    v = value
    _check_storable!(env, out.db, v)
    envform = _stream_envelope(v, _current_user(env), _now_secs())
    r = _stream_op(() -> (put!(out, envform); envform))
    r === _STREAM_TIMEOUT && return naught
    _agent_wake_if_queued!(env, st, s)
    return envform
end

# `(channel-post ch value)` — send a message to the agent.
function _bi_channel_post(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "channel-post", ())
    length(call.seq) == 3 || throw(AirEvalError("channel-post needs a channel and a value"))
    ch = air_reduce(env, scope, to_form(call.seq[2]))
    v = air_reduce(env, scope, to_form(call.seq[3]))
    return _do_channel_post(env, ch, v)
end
special!(Symbol("channel-post"), _bi_channel_post)

# The shared body of `channel-fetch` and `session-fetch`.
function _do_channel_fetch(env::Env, ch::Form, meta::Bool, timeout)
    st = _channel_state_vf(env, ch, "channel-fetch")
    s = _session_value(st)
    ins = _agent_field(s, :in)
    ins isa StreamForm || throw(AirAgentError(
        Symbol("agent-session"), "the session has no inbox"))
    _check!(env, ins, :read)
    r = _stream_op(() -> take(ins; timeout = timeout))
    r === _STREAM_TIMEOUT && return naught
    return meta ? r : _stream_object(r)
end

# `(channel-fetch ch meta=false timeout=n)` — receive the oldest reply.
function _bi_channel_fetch(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "channel-fetch", (Symbol(":meta"), _TIMEOUT_KEY))
    length(call.seq) == 2 || throw(AirEvalError("channel-fetch needs a channel"))
    ch = air_reduce(env, scope, to_form(call.seq[2]))
    timeout = _stream_timeout(env, scope, call)
    meta = haskey(call.map, Symbol(":meta")) &&
           truthy(air_reduce(env, scope, to_form(call.map[Symbol(":meta")])))
    return _do_channel_fetch(env, ch, meta, timeout)
end
special!(Symbol("channel-fetch"), _bi_channel_fetch)

# `(channel-ready? ch)` — whether a reply is waiting.
function _bi_channel_ready(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "channel-ready?", ())
    length(call.seq) == 2 || throw(AirEvalError("channel-ready? needs a channel"))
    ch = air_reduce(env, scope, to_form(call.seq[2]))
    st = _channel_state_vf(env, ch, "channel-ready?")
    ins = _agent_field(_session_value(st), :in)
    ins isa StreamForm || return Form(false)
    _check!(env, ins, :read)
    return Form(_stream_ready(env, ins))
end
special!(Symbol("channel-ready?"), _bi_channel_ready)

# `(channel-count ch)` — the number of queued replies.
function _bi_channel_count(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "channel-count", ())
    length(call.seq) == 2 || throw(AirEvalError("channel-count needs a channel"))
    ch = air_reduce(env, scope, to_form(call.seq[2]))
    st = _channel_state_vf(env, ch, "channel-count")
    ins = _agent_field(_session_value(st), :in)
    ins isa StreamForm || return Form(0)
    _check!(env, ins, :read)
    return Form(_stream_count(env, ins))
end
special!(Symbol("channel-count"), _bi_channel_count)

# The shared body of `channel-hook!` and `session-hook!`.
function _do_channel_hook(env::Env, ch::Form, fn::Form)
    st = _channel_state_vf(env, ch, "channel-hook!")
    s = _session_value(st)
    me = _current_user(env)
    owner = _agent_kw(_agent_field(s, :owner))
    _check!(env, st, :write)
    (me === owner || me === _AIR) ||
        throw(AirPermissionDenied(:write, _keyword_form(owner)))
    n = _agent_field(s, Symbol("in-notify"))
    n isa StreamForm || throw(AirAgentError(
        Symbol("agent-session"), "the session has no notification queue"))
    _agent_drain!(n)
    tbl = _ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":fn") => fn,
        Symbol(":owner") => _keyword_form(owner),
        Symbol(":by") => _keyword_form(me),
        Symbol(":ns") => _ns_path_form(_hook_ns_path(env)),
        Symbol(":installed") => _mk_time(_now_secs())])
    _agent_update!(env, st) do cur
        _agent_set(cur, [Symbol(":in-hook") => tbl])
    end
    _ensure_hook_watcher!(env, st)
    return st
end

# `(channel-hook! ch form)` — install an `on-receive` hook.
function _bi_channel_hook(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "channel-hook!", ())
    length(call.seq) == 3 || throw(AirEvalError("channel-hook! needs a channel and a function"))
    ch = air_reduce(env, scope, to_form(call.seq[2]))
    fn = to_form(call.seq[3])
    return _do_channel_hook(env, ch, fn)
end
special!(Symbol("channel-hook!"), _bi_channel_hook)

# `(channel-unhook! ch)` — remove the hook.
function _bi_channel_unhook(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "channel-unhook!", ())
    length(call.seq) == 2 || throw(AirEvalError("channel-unhook! needs a channel"))
    ch = air_reduce(env, scope, to_form(call.seq[2]))
    st = _channel_state_vf(env, ch, "channel-unhook!")
    s = _session_value(st)
    me = _current_user(env)
    owner = _agent_kw(_agent_field(s, :owner))
    _check!(env, st, :write)
    (me === owner || me === _AIR) ||
        throw(AirPermissionDenied(:write, _keyword_form(owner)))
    _agent_update!(env, st) do cur
        _agent_set(cur, [Symbol(":in-hook") => naught])
    end
    return st
end
special!(Symbol("channel-unhook!"), _bi_channel_unhook)

# Close the session's streams (tolerating ones already closed).
function _agent_close_streams!(s::Form)
    for k in (:in, :out, Symbol("in-notify"))
        sf = _agent_field(s, k)
        sf isa StreamForm || continue
        try
            close(sf)
        catch
        end
    end
    return nothing
end

# The shared body of `channel-close!` and `session-close!`.
function _do_session_close!(env::Env, st::VolatileForm)
    _check!(env, st, :write)
    s = _agent_update!(env, st) do cur
        _agent_set(cur, [Symbol(":status") => _keyword_form(:closed),
                         Symbol(":updated") => _mk_time(_now_secs())])
    end
    _agent_close_streams!(s)
    return st
end

# `(channel-close! ch)` — stop the channel.
function _bi_channel_close(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "channel-close!", ())
    length(call.seq) == 2 || throw(AirEvalError("channel-close! needs a channel"))
    ch = air_reduce(env, scope, to_form(call.seq[2]))
    st = _channel_state_vf(env, ch, "channel-close!")
    _do_session_close!(env, st)
    return ch
end
special!(Symbol("channel-close!"), _bi_channel_close)

# ---- session builtins --------------------------------------------------------

# `(sessions agent)` — every session of the agent, by id.
function _bi_sessions(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "sessions", ())
    length(call.seq) == 2 || throw(AirEvalError("sessions needs an agent"))
    resolved = _resolve_agent_id(env, _agent_arg(env, scope, to_form(call.seq[2])))
    id = resolved.id
    _agent_require_access(env, id, resolved.details)
    home = _user_home_path(env, id)
    home === nothing &&
        throw(AirAgentError(Symbol("agent-not-found"), "no such agent: :$id"))
    db = _persist_db_in(env, home)
    prefix = _AGENT_SESSION_PREFIX * String(id) * "/sessions/"
    pairs = Pair{Symbol,Form}[]
    for (nm, vf) in named_forms(db)
        name = String(nm)
        startswith(name, prefix) || continue
        sid = name[(length(prefix) + 1):end]
        _can(env, vf, :read) || continue
        push!(pairs, Symbol(":" * sid) => _agent_handle(_session_value(vf), vf))
    end
    sort!(pairs; by = p -> String(first(p)))
    return _ns_form(Form[], pairs)
end
special!(Symbol("sessions"), _bi_sessions)

# `(session-info s)` — the session's status, configuration, and counters.
function _bi_session_info(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "session-info", ())
    length(call.seq) == 2 || throw(AirEvalError("session-info needs a session"))
    h = air_reduce(env, scope, to_form(call.seq[2]))
    st = _session_state_vf(env, h, "session-info")
    s = _session_value(st)
    tr = _agent_transcript(s)
    u = _agent_usage(s)
    system = _agent_string(_agent_field(s, :system))
    est = _agent_estimate_tokens(system === nothing ? "" : system, tr, u.last_input)
    hook = _agent_field(s, Symbol("in-hook"))
    ins = _agent_field(s, :in)
    out = _agent_field(s, :out)
    pairs = Pair{Symbol,Form}[
        Symbol(":id") => _agent_or_naught(s, :id),
        Symbol(":agent") => _agent_or_naught(s, :agent),
        Symbol(":owner") => _agent_or_naught(s, :owner),
        Symbol(":status") => _agent_or_naught(s, :status),
        Symbol(":model") => _agent_or_naught(s, :model),
        Symbol(":provider") => _agent_or_naught(s, :provider),
        Symbol(":dialect") => _agent_or_naught(s, :dialect),
        Symbol(":messages") => Form(length(tr)),
        Symbol(":estimate") => Form(est),
        Symbol(":usage") => _agent_usage_form(u),
        Symbol(":queued-in") => Form(ins isa StreamForm ? _agent_stream_count(ins) : 0),
        Symbol(":queued-out") => Form(out isa StreamForm ? _agent_stream_count(out) : 0),
        Symbol(":hook") => Form(hook !== nothing && !isequal(hook, naught))]
    lim = _agent_field(s, :context)
    (lim === nothing || isequal(lim, naught)) ||
        push!(pairs, Symbol(":limit") => lim)
    append!(pairs, Pair{Symbol,Form}[
        Symbol(":created") => _agent_or_naught(s, :created),
        Symbol(":updated") => _agent_or_naught(s, :updated),
        Symbol(":last-error") => _agent_or_naught(s, Symbol("last-error")),
        Symbol(":last-hook-error") => _agent_or_naught(s, Symbol("last-hook-error"))])
    return _ns_form(Form[], pairs)
end
special!(Symbol("session-info"), _bi_session_info)

# `(session-history s limit=n)` — the transcript, or its last `n` entries.
function _bi_session_history(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "session-history", (Symbol(":limit"),))
    length(call.seq) == 2 || throw(AirEvalError("session-history needs a session"))
    h = air_reduce(env, scope, to_form(call.seq[2]))
    st = _session_state_vf(env, h, "session-history")
    tr = _agent_transcript(_session_value(st))
    if haskey(call.map, Symbol(":limit"))
        l = _leafof(air_reduce(env, scope, to_form(call.map[Symbol(":limit")])))
        l isa Integer && l >= 0 ||
            throw(AirEvalError("session-history: limit must be a non-negative integer"))
        n = _as_int(l, "session-history: limit")
        tr = n >= length(tr) ? tr : tr[(end - n + 1):end]
    end
    return _ns_form(tr)
end
special!(Symbol("session-history"), _bi_session_history)

# `(session-channel s)` — the session's channel handle.
function _bi_session_channel(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "session-channel", ())
    length(call.seq) == 2 || throw(AirEvalError("session-channel needs a session"))
    h = air_reduce(env, scope, to_form(call.seq[2]))
    st = _session_state_vf(env, h, "session-channel")
    return _agent_channel_handle(_session_value(st), st)
end
special!(Symbol("session-channel"), _bi_session_channel)

# `(session-post s value)` — send a message to the agent.
function _bi_session_post(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "session-post", ())
    length(call.seq) == 3 || throw(AirEvalError("session-post needs a session and a value"))
    h = air_reduce(env, scope, to_form(call.seq[2]))
    v = air_reduce(env, scope, to_form(call.seq[3]))
    return _do_channel_post(env, _session_channel_form(h), v)
end
special!(Symbol("session-post"), _bi_session_post)

# `(session-fetch s meta=false timeout=n)` — receive the oldest reply.
function _bi_session_fetch(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "session-fetch", (Symbol(":meta"), _TIMEOUT_KEY))
    length(call.seq) == 2 || throw(AirEvalError("session-fetch needs a session"))
    h = air_reduce(env, scope, to_form(call.seq[2]))
    timeout = _stream_timeout(env, scope, call)
    meta = haskey(call.map, Symbol(":meta")) &&
           truthy(air_reduce(env, scope, to_form(call.map[Symbol(":meta")])))
    return _do_channel_fetch(env, _session_channel_form(h), meta, timeout)
end
special!(Symbol("session-fetch"), _bi_session_fetch)

# `(session-hook! s form)` — install an `on-receive` hook.
function _bi_session_hook(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "session-hook!", ())
    length(call.seq) == 3 || throw(AirEvalError("session-hook! needs a session and a function"))
    h = air_reduce(env, scope, to_form(call.seq[2]))
    return _do_channel_hook(env, _session_channel_form(h), to_form(call.seq[3]))
end
special!(Symbol("session-hook!"), _bi_session_hook)

# `(session-resume s)` — reopen a paused session and start its worker.
function _bi_session_resume(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "session-resume", ())
    length(call.seq) == 2 || throw(AirEvalError("session-resume needs a session"))
    h = air_reduce(env, scope, to_form(call.seq[2]))
    st = _session_state_vf(env, h, "session-resume")
    _check!(env, st, :write)
    s = _agent_update!(env, st) do cur
        _agent_set(cur, [Symbol(":status") => _keyword_form(:open),
                         Symbol(":updated") => _mk_time(_now_secs())])
    end
    _ensure_worker!(env, st, s)
    _agent_wake_hook!(env, s, st)
    return h
end
special!(Symbol("session-resume"), _bi_session_resume)

# `(session-close! s)` — close the session and its streams; idempotent.
function _bi_session_close(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "session-close!", ())
    length(call.seq) == 2 || throw(AirEvalError("session-close! needs a session"))
    h = air_reduce(env, scope, to_form(call.seq[2]))
    st = _session_state_vf(env, h, "session-close!")
    _do_session_close!(env, st)
    return h
end
special!(Symbol("session-close!"), _bi_session_close)

# ---- the on-receive hook watcher --------------------------------------------

# Start the notification-copy watcher for a session, unless it is running.
function _ensure_hook_watcher!(env::Env, st::VolatileForm)
    key = st.id
    lock(_AGENT_HOOKS_LOCK)
    try
        w = get(_AGENT_HOOKS, key, nothing)
        _agent_worker_live(w) && return nothing
        w = _AgentWorker(nothing, false)
        _AGENT_HOOKS[key] = w
        se = _session_env(env)
        t = Threads.@spawn begin
            _reset_block_scopes!()
            try
                _agent_hook_loop(se, st)
            catch e
                e isa InterruptException && rethrow()
            finally
                w.done = true
                lock(_AGENT_HOOKS_LOCK) do
                    cur = get(_AGENT_HOOKS, key, nothing)
                    cur === w && delete!(_AGENT_HOOKS, key)
                end
            end
        end
        w.task = t
    finally
        unlock(_AGENT_HOOKS_LOCK)
    end
    return nothing
end

# Drain the notification copy queue and run the hook for each copy.
function _agent_hook_loop(env::Env, st::VolatileForm)
    while true
        s = _session_value(st)
        _agent_status(s) === :closed && return nothing
        hook = _agent_field(s, Symbol("in-hook"))
        if hook === nothing || isequal(hook, naught)
            sleep(0.2)
            continue
        end
        n = _agent_field(s, Symbol("in-notify"))
        n isa StreamForm || return nothing
        item = try
            take(n; timeout = 0.5)
        catch e
            e isa Air.ReaderTimeout && continue
            return nothing            # closed, deadlocked, or aborted
        end
        # A copy may have waited while the hook was replaced or removed, so the
        # live state decides which hook runs, not the one read before the wait.
        s2 = _session_value(st)
        hook2 = _agent_field(s2, Symbol("in-hook"))
        if hook2 === nothing || isequal(hook2, naught)
            continue                  # unhooked while the copy waited
        end
        parts = _hook_table_parts(hook2)
        parts === nothing && continue
        _agent_run_hook!(env, s2, st, parts, _stream_object(to_form(item)))
    end
end

# Run one hook call as the receiving end's owner, in the registering namespace.
function _agent_run_hook!(env::Env, s::Form, st::VolatileForm,
                          parts, msg::Form)
    ctx = TaskContext(parts.owner, _ns_lookup(env, parts.path; lazy = false),
                      _agent_dbroot_value(s), naught)
    try
        _with_context(env, ctx,
                      () -> _call(env, _base_scope(env), parts.fn, Form[msg]))
        return nothing
    catch e
        e isa InterruptException && rethrow()
        form = try
            _error_form(e)
        catch
            return nothing
        end
        try
            _agent_update!(env, st) do cur
                _agent_set(cur, [Symbol(":last-hook-error") => form])
            end
        catch
        end
        return nothing
    end
end
