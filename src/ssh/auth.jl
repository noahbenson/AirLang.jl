################################################################################
# ssh/auth.jl
#
# Public-key authentication against a user's `authorized-keys`.
#
# The claimed identity comes from the client and from nowhere else:
# `ssh_message_auth_user` names the account, with `.` standing in for the `:`
# that a POSIX login name cannot hold (`air.someuser` → `:air:someuser`). The
# name is re-read on every authentication message, never cached from the first,
# because libssh makes two round trips for a publickey attempt (one offering the
# key, one carrying the signature) and a client is free to name different users.
#
# A key is compared by its advertised type name and its exported base64 blob, so
# no libssh key-type enum is involved and a mismatch is impossible. Every failure
# — an unknown user, no config, an absent key, a user outside the server's scope
# — is refused identically, so the server does not enumerate its users.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _SSH_MAX_AUTH_FAILURES = 6

# The user id a client name claims, or `nothing` when the name cannot be one.
function _ssh_login_id(name::AbstractString)
    s = replace(String(name), "." => ":")
    isempty(s) && return nothing
    id = Symbol(s)
    _valid_user_id(id) || return nothing
    return id
end

# Whether `key` (an `ssh_key` from the message) is one of `entries`. `allowed` is
# the server's `key-types`: empty means any type, otherwise only the named ones
# may authenticate at all.
function _ssh_key_authorized(entries::Vector{SshKeyEntry}, key::Ptr{Cvoid},
                             allowed::Vector{String})
    type_name, blob = _ls_public_identity(key)
    (isempty(allowed) || type_name in allowed) || return false
    return any(e -> e.type == type_name && e.blob == blob, entries)
end

"""
    _SshAuth(server, env)

The state of one session's authentication: the users the server admits (computed
once, as its owner, over the server's captured database), the client-name mapping
that produced them, and the failure counter.
"""
mutable struct _SshAuth
    server::_SshServer
    env::Env
    admitted::Set{Symbol}
    claimed::Union{Nothing,Symbol}
    entries::Vector{SshKeyEntry}
    failures::Int
end

# The user ids this server admits: air admits everyone, an admin admits itself and
# its constituents. Recomputed per login so a user created after the server
# started is admitted. The lookup runs under the server owner's identity and its
# captured database root, so it does not depend on the ambient `@` of whichever
# task started the server.
function _ssh_admitted_users(env::Env, server::_SshServer)
    ctx = TaskContext(server.owner, nothing, server.dbroot, naught)
    ids = _with_context(env, ctx, () -> _visible_user_ids(env, server.owner))
    return Set{Symbol}(ids)
end

function _ssh_auth_new(env::Env, server::_SshServer)
    return _SshAuth(server, env, _ssh_admitted_users(env, server), nothing,
                    SshKeyEntry[], 0)
end

# Resolve the claimed user's authorized keys, or `nothing` when the identity is
# not acceptable. The config read is done as the *target* user, so their own home
# is the one inspected. A malformed config refuses the login rather than ending
# the session, so every refusal looks the same from the outside; the reason stays
# reachable through `@debug`.
function _ssh_admit(auth::_SshAuth, id::Symbol)
    (id in auth.admitted) || return nothing
    c = _context(auth.env)
    prev = c.user
    c.user = id
    keys = try
        _ssh_user_config(auth.env, id).keys
    catch e
        e isa InterruptException && rethrow()
        @debug "air ssh config error" user = id exception = (e, catch_backtrace())
        return nothing
    finally
        c.user = prev
    end
    return isempty(keys) ? nothing : keys
end

"""
    _ssh_handle_auth!(auth, message) -> Bool

Service one authentication message. Returns `true` when the message completed a
login. A refusal replies with the default failure so the client sees exactly what
it would for any other rejected method.
"""
function _ssh_handle_auth!(auth::_SshAuth, message::Ptr{Cvoid})
    t = _ls_message_type(message)
    if t == SSH_REQUEST_SERVICE
        # libssh hands the client's `ssh-userauth` service request to the server
        # rather than answering it; nothing else may be accepted.
        if _ls_message_service_service(message) == "ssh-userauth"
            _ls_message_service_reply_success(message)
        else
            _ls_message_reply_default(message)
        end
        return false
    end
    t == SSH_REQUEST_AUTH || begin
        _ls_message_reply_default(message)
        return false
    end
    _ls_message_subtype(message) == SSH_AUTH_METHOD_PUBLICKEY || begin
        _ls_message_reply_default(message)
        return false
    end
    name = _ls_auth_user(message)
    id = name === nothing ? nothing : _ssh_login_id(name)
    entries = id === nothing ? nothing : _ssh_admit(auth, id)
    key = _ls_auth_pubkey(message)
    state = _ls_auth_publickey_state(message)
    ok = entries !== nothing && key != C_NULL &&
         _ssh_key_authorized(entries, key, auth.server.key_types)
    if ok && state == SSH_PUBLICKEY_STATE_VALID
        _ls_auth_reply_success(message)
        auth.claimed = id
        auth.entries = entries
        return true
    elseif ok && state == SSH_PUBLICKEY_STATE_NONE
        # The client is only offering the key; libssh will send the signature in
        # a second message, which is checked again from scratch.
        _ls_auth_reply_pk_ok(message)
        return false
    end
    _ls_message_reply_default(message)
    auth.failures += 1
    return false
end

# The session's authentication phase. Runs in blocking mode, so every libssh call
# goes through the thread pool; the session timeout bounds a stalled client.
function _ssh_authenticate!(auth::_SshAuth, session::Ptr{Cvoid})
    _ls_set_auth_methods(session, SSH_AUTH_METHOD_PUBLICKEY)
    while auth.failures < _SSH_MAX_AUTH_FAILURES
        message = _ls_message_get(session)
        message == C_NULL && break
        try
            _ssh_handle_auth!(auth, message) && return true
        finally
            _ls_message_free(message)
        end
    end
    return false
end
