################################################################################
# ssh/config.jl
#
# Where a user's SSH settings live. Two shapes are accepted, and they merge with
# the namespace winning:
#
#   ; the namespace form
#   (namespace $.config.ssh
#     (val authorized-keys ("ssh-ed25519 AAAA… alice@laptop"))
#     (val server (port=2222 bind="127.0.0.1")))
#
#   ; the val form
#   (namespace $.config
#     (val ssh (authorized-keys=("ssh-ed25519 AAAA…"))))
#
# `authorized-keys` is a list of entries; each entry is an OpenSSH one-line string
# without options, or a mapping `(type="ssh-ed25519" key="AAAA…" comment="…")`.
# `server` (read from the server owner's home) supplies the server defaults.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    SshKeyEntry(type, blob, comment)

One authorized key: its OpenSSH type name (`ssh-ed25519`, `ssh-rsa`, …), the
base64 wire blob, and an optional comment.
"""
struct SshKeyEntry
    type::String
    blob::String
    comment::String
end

# The key types this server understands. A type outside the set is refused when
# the key is offered, and a malformed entry is refused when the config is read.
const _SSH_KEY_TYPE_NAMES = Set([
    "ssh-ed25519", "ssh-rsa",
    "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
])

"""
    SshUserConfig(keys, server)

A user's SSH configuration: the `authorized-keys` they may log in with, and the
`server` option mapping (meaningful only for a server owner's home).
"""
struct SshUserConfig
    keys::Vector{SshKeyEntry}
    server::Dict{Symbol,Any}
end

# ---- reading forms -----------------------------------------------------------

_ssh_leaf(v::Form) = _leafof(to_form(v))

function _ssh_string_of(v::Form, what::AbstractString)
    l = _ssh_leaf(v)
    l isa AbstractString && return String(l)
    l isa Symbol && return String(_bindname(l))
    throw(SshError("$what must be a string, got $(air_string(v))"))
end

function _ssh_int_of(v::Form, what::AbstractString)
    l = _ssh_leaf(v)
    l isa Integer || throw(SshError("$what must be an integer, got $(air_string(v))"))
    (typemin(Int) <= l <= typemax(Int)) ||
        throw(SshError("$what is out of range: $(air_string(v))"))
    return Int(l)
end

# The `map` of a mapping form (or `nothing`).
_ssh_map_of(v::Form) = v isa FormContainer ? v.map : nothing

# The value of a val entry in a namespace, or `nothing`.
function _ssh_ns_val(env::Env, path::Vector{Symbol}, name::Symbol)
    ns = _ns_lookup(env, path)
    ns === nothing && return nothing
    m = _ns_map_get(env, ns, Symbol(":", String(name)); lazy = false)
    m === nothing && return nothing
    v = _ns_val_value(env, m; check = false)
    return v isa Form ? to_form(v) : nothing
end

# The `name` entry of a mapping form, or `nothing`.
_ssh_map_get(v::Form, name::Symbol) =
    (m = _ssh_map_of(v); (m === nothing || !haskey(m, Symbol(":", String(name)))) ?
     nothing : to_form(m[Symbol(":", String(name))]))

# ---- authorized keys ---------------------------------------------------------

# One entry. A string must be an OpenSSH one-line key with no options; a mapping
# names its parts. A malformed entry names the user so the mistake is findable.
function _ssh_key_entry(v::Form, who::Symbol)
    l = _leafof(v)
    if l isa AbstractString
        toks = split(strip(String(l)))
        if isempty(toks)
            throw(SshError("user :$who has an empty authorized key entry"))
        end
        typ = String(toks[1])
        if occursin('=', typ) || occursin(',', typ)
            throw(SshError("user :$who has an authorized key with options; " *
                           "SSH key options are not supported (entry: $l)"))
        end
        (typ in _SSH_KEY_TYPE_NAMES) ||
            throw(SshError("user :$who has an authorized key of unsupported type " *
                           "'$typ' (entry: $l)"))
        length(toks) < 2 &&
            throw(SshError("user :$who has an authorized key entry with no key " *
                           "blob: $l"))
        blob = String(toks[2])
        _ssh_valid_base64(blob) ||
            throw(SshError("user :$who has an authorized key entry whose key " *
                           "blob is not base64: $l"))
        comment = join(toks[3:end], " ")
        return SshKeyEntry(typ, blob, comment)
    end
    m = _ssh_map_of(v)
    m === nothing &&
        throw(SshError("user :$who has an authorized key entry that is neither a " *
                       "string nor a mapping: $(air_string(v))"))
    haskey(m, Symbol(":type")) && haskey(m, Symbol(":key")) ||
        throw(SshError("user :$who has an authorized key mapping without type= " *
                       "and key=: $(air_string(v))"))
    typ = _ssh_string_of(to_form(m[Symbol(":type")]), "authorized key type")
    (typ in _SSH_KEY_TYPE_NAMES) ||
        throw(SshError("user :$who has an authorized key of unsupported type " *
                       "'$typ'"))
    blob = _ssh_string_of(to_form(m[Symbol(":key")]), "authorized key blob")
    _ssh_valid_base64(blob) ||
        throw(SshError("user :$who has an authorized key whose key blob is not " *
                       "base64"))
    comment = haskey(m, Symbol(":comment")) ?
              _ssh_string_of(to_form(m[Symbol(":comment")]), "authorized key comment") :
              ""
    return SshKeyEntry(typ, blob, comment)
end

function _ssh_valid_base64(s::AbstractString)
    isempty(s) && return false
    return occursin(r"^[A-Za-z0-9+/]+={0,2}$", s)
end

# A list of entries. A single entry form and a one-element list are both accepted,
# so a user may write `"…"` or `("…")`.
function _ssh_key_entries(v::Form, who::Symbol)
    if v isa FormContainer && isempty(v.map) && !_ssh_is_key_mapping(v)
        return SshKeyEntry[_ssh_key_entry(to_form(e), who) for e in v.seq]
    end
    return SshKeyEntry[_ssh_key_entry(v, who)]
end

# Whether a container is a single key mapping (`type=`, `key=`) rather than a
# list of entries.
function _ssh_is_key_mapping(v::FormContainer)
    m = v.map
    return haskey(m, Symbol(":type")) || haskey(m, Symbol(":key"))
end

# ---- server options ----------------------------------------------------------

# The option names a `server` mapping may hold, as written in air.
const _SSH_SERVER_OPTIONS = Set([:port, Symbol("bind"), Symbol("host-key-type"),
                                 Symbol("key-types"), Symbol("max-connections"),
                                 Symbol("banner")])

function _ssh_server_options(v::Form, who::Symbol)
    m = _ssh_map_of(v)
    m === nothing &&
        throw(SshError("user :$who has a server config that is not a mapping"))
    out = Dict{Symbol,Any}()
    for (k, val) in m
        name = _bindname(k)
        name in _SSH_SERVER_OPTIONS ||
            throw(SshError("user :$who has an unknown ssh server option " *
                           "$(String(name))"))
        f = to_form(val)
        if name === :port
            out[:port] = _ssh_int_of(f, "ssh port")
        elseif name === :bind
            out[:bind] = _ssh_string_of(f, "ssh bind address")
        elseif name === Symbol("host-key-type")
            out[:hostkey_type] = _ssh_string_of(f, "ssh host-key-type")
        elseif name === Symbol("key-types")
            out[:key_types] = _ssh_string_list(f, "ssh key-types")
        elseif name === Symbol("max-connections")
            out[:max_connections] = _ssh_int_of(f, "ssh max-connections")
        elseif name === Symbol("banner")
            out[:banner] = _ssh_string_of(f, "ssh banner")
        end
    end
    return out
end

function _ssh_string_list(v::Form, what::AbstractString)
    if v isa FormContainer && isempty(v.map)
        return String[_ssh_string_of(to_form(e), what) for e in v.seq]
    end
    return String[_ssh_string_of(v, what)]
end

# ---- the user's settings -----------------------------------------------------

"""
    _ssh_user_config(env, id) -> SshUserConfig

Read `id`'s SSH settings from their home: the `\$.config.ssh` namespace first,
then the `ssh` val of `\$.config`. The namespace wins where both are present.
"""
function _ssh_user_config(env::Env, id::Symbol)
    home = _user_home_path(env, id)
    home === nothing && return SshUserConfig(SshKeyEntry[], Dict{Symbol,Any}())
    keys = SshKeyEntry[]
    server = Dict{Symbol,Any}()
    ns_path = vcat(home, Symbol[Symbol("config"), Symbol("ssh")])
    if _ns_lookup(env, ns_path) !== nothing
        k = _ssh_ns_val(env, ns_path, Symbol("authorized-keys"))
        k === nothing || append!(keys, _ssh_key_entries(k, id))
        s = _ssh_ns_val(env, ns_path, Symbol("server"))
        s === nothing || merge!(server, _ssh_server_options(s, id))
    end
    if isempty(keys) || isempty(server)
        val = _ssh_ns_val(env, vcat(home, Symbol[Symbol("config")]), Symbol("ssh"))
        if val !== nothing && val isa FormContainer
            if isempty(keys)
                k = _ssh_map_get(val, Symbol("authorized-keys"))
                k === nothing || append!(keys, _ssh_key_entries(k, id))
            end
            if isempty(server)
                s = _ssh_map_get(val, Symbol("server"))
                s === nothing || merge!(server, _ssh_server_options(s, id))
            end
        end
    end
    return SshUserConfig(keys, server)
end
