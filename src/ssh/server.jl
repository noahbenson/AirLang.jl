################################################################################
# ssh/server.jl
#
# The server registry and the air-level surface:
#
#   (ssh-server)                    ; => a generated key, e.g. :ssh-3f9a1c2b
#   (ssh-server :myserver port=2222 bind="127.0.0.1")
#   (ssh-servers)                   ; => (myserver=(owner=:air port=2222 …))
#   (ssh-host-key :myserver)        ; the public key line, for known_hosts
#   (ssh-host-key :myserver private=true)
#   (ssh-close! :myserver)          ; stops listening; keeps the host key
#
# A server exists as a process resource named by a key, like a task, rather than
# as a first-class air object. Only `air` and admins may start one, and it admits
# exactly the users its owner may assume (`air`: everyone). The host key lives in
# the process database under `.sys.ssh.<key>`, so no file exists on disk and a
# reopened server keeps its identity.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _SSH_SYS_NS = Symbol("ssh")

const _SSH_DEFAULTS = Dict{Symbol,Any}(
    :port => 2222,
    :bind => "127.0.0.1",
    :hostkey_type => "ed25519",
    :key_types => String[],
    :max_connections => 4,
    :banner => "air ssh",
)

mutable struct _SshServer
    key::Symbol
    owner::Symbol
    bind::String
    port::Int
    hostkey_type::String
    key_types::Vector{String}
    max_connections::Int
    banner::String
    # The `@` root captured at start, so a login does not depend on the ambient
    # database of whichever task later runs the server.
    dbroot::Union{Nothing,Form}
    # The environment the server runs in: every session derives its own `Env`
    # from it (sharing the rules, caches, and contexts, with a fresh budget).
    env::Env
    privkey::String
    publine::String
    bindptr::Ptr{Cvoid}
    listener::Any
    accept_task::Any
    sessions::Set{Task}
    lock::ReentrantLock
    closed::Bool
end

const _SSH_SERVERS = Dict{Symbol,_SshServer}()
const _SSH_SERVERS_LOCK = ReentrantLock()

# ---- host keys ---------------------------------------------------------------

_ssh_key_path(key::Symbol) = Symbol[_SYS, _SSH_SYS_NS, key]

# Generate a private key of `kind`; validate by its exported type name so a
# libssh enum mismatch is an error rather than a silently wrong key.
function _ssh_generate_host_key(kind::AbstractString)
    k = lowercase(String(kind))
    type, bits, want = if k == "ed25519"
        (Cint(5), 0, "ssh-ed25519")
    elseif k == "rsa"
        (Cint(2), 3072, "ssh-rsa")
    else
        throw(SshError("unsupported host key type '$kind'; use ed25519 or rsa"))
    end
    key = _ls_pki_generate(type, bits)
    try
        got = _ls_key_type_name(key)
        got == want ||
            throw(SshError("the generated $kind key reports type '$got'"))
        priv = _ls_pki_export_privkey(key)
        pub = _ls_pki_export_pubkey_base64(key)
        return (priv, pub, got)
    finally
        _ls_key_free(key)
    end
end

# The stored host key for `key`, generated (as `air`) when absent. The record is
# `.sys.ssh.<key>` with `private`, `public`, and `config` vals; `.sys` is air-only,
# and every read here runs as air, so an owner reaches it only through these
# builtins.
function _ssh_host_key(env::Env, key::Symbol, kind::AbstractString, owner::Symbol)
    path = _ssh_key_path(key)
    return _as_air(env) do
        priv = _ssh_ns_val(env, path, Symbol("private"))
        pub = _ssh_ns_val(env, path, Symbol("public"))
        if priv !== nothing && pub !== nothing
            return (_ssh_string_of(priv, "stored ssh host key"),
                    _ssh_string_of(pub, "stored ssh host key"))
        end
        try
            _ns_ensure!(env, path)
        catch e
            e isa AirError || rethrow()
            throw(SshError("the ssh host key namespace could not be created: " *
                           sprint(showerror, e)))
        end
        privstr, pubblob, typename = _ssh_generate_host_key(kind)
        publine = "$typename $pubblob air-ssh-$(key)"
        tx() do
            ns = _ns_lookup(env, path)
            cfg = _ns_form(Form[], Pair{Symbol,Form}[
                Symbol(":owner") => _keyword_form(owner),
                Symbol(":host-key-type") => Form(typename)])
            _ns_add_val!(env, ns, Form(Symbol("private")), Form(privstr);
                         owner = _AIR)
            _ns_add_val!(env, ns, Form(Symbol("public")), Form(publine);
                         owner = _AIR)
            _ns_add_val!(env, ns, Form(Symbol("config")), cfg; owner = _AIR)
        end
        return (privstr, publine)
    end
end

# The owner recorded for a stored host key, or `nothing`.
function _ssh_stored_owner(env::Env, key::Symbol)
    return _as_air(env) do
        cfg = _ssh_ns_val(env, _ssh_key_path(key), Symbol("config"))
        (cfg === nothing) && return nothing
        o = _ssh_map_get(cfg, Symbol("owner"))
        o === nothing && return nothing
        s = _symbolof(o)
        return s === nothing ? nothing : _bindname(s)
    end
end

# ---- naming and addresses ----------------------------------------------------

function _ssh_generate_key()
    return Symbol("ssh-", join(string(b, base = 16, pad = 2) for b in rand(UInt8, 4)))
end

# A server name: the keyword `:myserver` or the bare symbol `myserver`.
function _ssh_server_name(f::Form)
    s = _symbolof(f)
    s === nothing &&
        throw(AirEvalError("a server name must be a symbol, got $(air_string(f))"))
    name = _bindname(s)
    _valid_name_segment(String(name)) ||
        throw(AirEvalError("invalid server name :$name"))
    return name
end

function _ssh_parse_bind(s::AbstractString)
    s == "localhost" && return Sockets.IPv4(127, 0, 0, 1)
    try
        return parse(Sockets.IPAddr, s)
    catch
        throw(SshError("invalid bind address $(repr(String(s)))"))
    end
end

# ---- option resolution -------------------------------------------------------

# The options a `server` config or an explicit call may set, as call-map keys.
const _SSH_CALL_OPTIONS = Set([Symbol(":port"), Symbol(":bind"),
                               Symbol(":host-key-type"), Symbol(":key-types"),
                               Symbol(":max-connections"), Symbol(":banner")])

# defaults < the owner's `$.config.ssh.server` < explicit options.
function _ssh_resolved_options(env::Env, owner::Symbol, explicit::Dict{Symbol,Any})
    opts = copy(_SSH_DEFAULTS)
    c = _context(env)
    prev = c.user
    c.user = owner
    cfg = try
        _ssh_user_config(env, owner).server
    finally
        c.user = prev
    end
    merge!(opts, cfg)
    merge!(opts, explicit)
    _ssh_check_options(opts)
    return opts
end

function _ssh_check_options(opts::Dict{Symbol,Any})
    p = opts[:port]
    (p isa Integer && 0 <= p <= 65535) ||
        throw(SshError("the ssh port must be between 0 and 65535"))
    mc = opts[:max_connections]
    (mc isa Integer && mc >= 1) ||
        throw(SshError("ssh max-connections must be a positive integer"))
    k = lowercase(String(opts[:hostkey_type]))
    k in ("ed25519", "rsa") ||
        throw(SshError("unsupported host key type '$(opts[:hostkey_type])'"))
    opts[:hostkey_type] = k
    for t in opts[:key_types]
        t in _SSH_KEY_TYPE_NAMES ||
            throw(SshError("unsupported client key type '$t'"))
    end
    return nothing
end

# ---- starting and stopping ---------------------------------------------------

function _ssh_open!(env::Env, key::Symbol, owner::Symbol,
                    explicit::Dict{Symbol,Any})
    _libssh()                    # a catchable `(error :ssh …)` when absent
    @lock _SSH_SERVERS_LOCK begin
        haskey(_SSH_SERVERS, key) &&
            throw(AirEvalError("an ssh server named :$key is already running"))
    end
    opts = _ssh_resolved_options(env, owner, explicit)
    priv, pub = _ssh_host_key(env, key, opts[:hostkey_type], owner)
    bindptr = _ls_bind_new()
    ok = false
    listener = nothing
    try
        keyptr = _ls_pki_import_privkey(priv)
        _ls_bind_import_key!(bindptr, keyptr)   # the bind owns the key now
        _ls_bind_option!(bindptr, SSH_BIND_OPTIONS_BANNER, String(opts[:banner]))
        ip = _ssh_parse_bind(String(opts[:bind]))
        try
            listener = Sockets.listen(ip, Int(opts[:port]))
        catch e
            throw(SshError("the ssh server could not listen on " *
                           "$(opts[:bind]):$(opts[:port]): " * sprint(showerror, e)))
        end
        port = Int(Sockets.getsockname(listener)[2])
        server = _SshServer(key, owner, String(opts[:bind]), port,
                            opts[:hostkey_type], opts[:key_types],
                            Int(opts[:max_connections]), String(opts[:banner]),
                            _context(env).dbroot, env, priv, pub, bindptr, listener,
                            nothing, Set{Task}(), ReentrantLock(), false)
        @lock _SSH_SERVERS_LOCK begin
            haskey(_SSH_SERVERS, key) &&
                throw(AirEvalError("an ssh server named :$key is already running"))
            _SSH_SERVERS[key] = server
        end
        server.accept_task = @async _ssh_accept_loop(server)
        ok = true
        return server
    finally
        if !ok
            listener === nothing || (try close(listener) catch end)
            _ls_bind_free(bindptr)
        end
    end
end

# Accept connections until the listener closes. `accept` is libuv-backed, so it
# yields; every accepted socket becomes a session task.
function _ssh_accept_loop(server::_SshServer)
    try
        while !server.closed
            sock = try
                Sockets.accept(server.listener)
            catch
                # `ssh-close!` closes the listener, and `accept` then throws.
                break
            end
            if length(server.sessions) >= server.max_connections
                try close(sock) catch end
                continue
            end
            t = @async begin
                try
                    _ssh_session!(server, sock)
                catch e
                    # A session failure is the client's problem, never a reason to
                    # bring down the server.
                    e isa InterruptException && rethrow()
                finally
                    lock(server.lock) do
                        delete!(server.sessions, current_task())
                    end
                end
            end
            lock(server.lock) do
                push!(server.sessions, t)
            end
        end
    finally
        # No further accepts; the sessions already accepted hold their own
        # sessions, so the bind can be released.
        _ls_bind_free(server.bindptr)
    end
    return nothing
end

function _ssh_close!(env::Env, key::Symbol)
    server = @lock _SSH_SERVERS_LOCK begin
        s = get(_SSH_SERVERS, key, nothing)
        s === nothing || delete!(_SSH_SERVERS, key)
        s
    end
    server === nothing &&
        throw(AirEvalError("no ssh server named :$key is running"))
    me = _current_user(env)
    (me === _AIR || me === server.owner) ||
        throw(AirEvalError("only air or the server's owner may close :$key"))
    server.closed = true
    try
        close(server.listener)
    catch
    end
    # Sessions notice `closed` on their next poll and exit on their own; nothing
    # outside a session touches its libssh objects, which are not thread-safe.
    deadline = time() + 2.0
    while time() < deadline
        isempty(lock(server.lock) do
                    collect(server.sessions)
                end) && break
        sleep(0.01)
    end
    return _keyword_form(key)
end

# ---- the air surface ---------------------------------------------------------

# The metadata form for one server: `(owner=:air port=… connections=…)`.
function _ssh_server_form(server::_SshServer)
    conns = lock(server.lock) do
        length(server.sessions)
    end
    return _ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":owner") => _keyword_form(server.owner),
        Symbol(":bind") => Form(server.bind),
        Symbol(":port") => Form(server.port),
        Symbol(":host-key-type") => Form(server.hostkey_type),
        Symbol(":connections") => Form(conns),
        Symbol(":max-connections") => Form(server.max_connections)])
end

# `(ssh-server [name] option…)`
function _bi_ssh_server(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ssh-server", _SSH_CALL_OPTIONS)
    length(call.seq) > 2 &&
        throw(AirEvalError("ssh-server takes at most one name"))
    me = _current_user(env)
    (me === _AIR || _is_admin(env, me)) ||
        throw(AirEvalError("only air or an admin may start an ssh server"))
    key = length(call.seq) == 2 ? _ssh_server_name(to_form(call.seq[2])) :
          _ssh_generate_key()
    explicit = Dict{Symbol,Any}()
    for (k, v) in call.map
        name = _bindname(k)
        val = air_reduce(env, scope, to_form(v))
        if name === :port
            explicit[:port] = _ssh_int_of(val, "ssh port")
        elseif name === :bind
            explicit[:bind] = _ssh_string_of(val, "ssh bind address")
        elseif name === Symbol("host-key-type")
            explicit[:hostkey_type] = _ssh_string_of(val, "ssh host-key-type")
        elseif name === Symbol("key-types")
            explicit[:key_types] = _ssh_string_list(val, "ssh key-types")
        elseif name === Symbol("max-connections")
            explicit[:max_connections] = _ssh_int_of(val, "ssh max-connections")
        elseif name === Symbol("banner")
            explicit[:banner] = _ssh_string_of(val, "ssh banner")
        end
    end
    _ssh_open!(env, key, me, explicit)
    return _keyword_form(key)
end
special!(Symbol("ssh-server"), _bi_ssh_server)

# `(ssh-servers)` — the running servers the caller may see, keyed by name.
function _bi_ssh_servers(env::Env, scope::Scope, args)
    me = _current_user(env)
    out = Pair{Symbol,Form}[]
    servers = @lock _SSH_SERVERS_LOCK collect(values(_SSH_SERVERS))
    sort!(servers; by = s -> String(s.key))
    for s in servers
        (me === _AIR || me === s.owner) || continue
        push!(out, Symbol(":", String(s.key)) => _ssh_server_form(s))
    end
    return _ns_form(Form[], out)
end
builtin!(Symbol("ssh-servers"), _bi_ssh_servers)

# `(ssh-host-key name private=false)` — the public key line (for known_hosts), or
# the private key when the caller is the owner or air.
function _bi_ssh_host_key(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ssh-host-key", (Symbol(":private"),))
    length(call.seq) == 2 ||
        throw(AirEvalError("ssh-host-key takes a server name"))
    key = _ssh_server_name(to_form(call.seq[2]))
    me = _current_user(env)
    owner = @lock _SSH_SERVERS_LOCK begin
        s = get(_SSH_SERVERS, key, nothing)
        s === nothing ? nothing : s.owner
    end
    if owner === nothing
        owner = _ssh_stored_owner(env, key)
        owner === nothing &&
            throw(AirEvalError("no ssh host key is stored for :$key"))
    end
    (me === _AIR || me === owner) ||
        throw(AirEvalError("only air or the server's owner may read the " *
                           "host key for :$key"))
    path = _ssh_key_path(key)
    pub = _as_air(env) do
        _ssh_ns_val(env, path, Symbol("public"))
    end
    pub === nothing &&
        throw(AirEvalError("no ssh host key is stored for :$key"))
    private = haskey(call.map, Symbol(":private")) &&
              truthy(air_reduce(env, scope, to_form(call.map[Symbol(":private")])))
    if !private
        return _Final(Form(_ssh_string_of(pub, "stored ssh host key")))
    end
    priv = _as_air(env) do
        _ssh_ns_val(env, path, Symbol("private"))
    end
    priv === nothing &&
        throw(AirEvalError("no ssh host key is stored for :$key"))
    return _Final(Form(_ssh_string_of(priv, "stored ssh host key")))
end
special!(Symbol("ssh-host-key"), _bi_ssh_host_key)

# `(ssh-close! name)` — stop listening and let the sessions drain.
function _bi_ssh_close(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ssh-close!", ())
    length(call.seq) == 2 ||
        throw(AirEvalError("ssh-close! takes a server name"))
    key = _ssh_server_name(to_form(call.seq[2]))
    return _Final(_ssh_close!(env, key))
end
special!(Symbol("ssh-close!"), _bi_ssh_close)
