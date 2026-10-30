################################################################################
# ssh/libssh.jl
#
# The thin libssh surface the server uses: no wrapper library, just typed calls
# into the C API from `libssh_jll`. Two rules govern every call here.
#
# 1. Nothing may block the Julia scheduler. The test suite runs with
#    JULIA_NUM_THREADS=1, so a blocking ccall made from a task would freeze the
#    whole process. Every libssh entry point used while the session is in
#    *blocking* mode (the handshake and authentication) is issued through
#    `Base.@threadcall` on the libuv thread pool, and bounded by the session's
#    `SSH_OPTIONS_TIMEOUT`. Once the channel is up the session is switched to
#    non-blocking mode and the data phase polls.
# 2. Ownership is explicit. A generated or imported private key belongs to the
#    `ssh_bind` that imported it; a message is freed by its handler; a session,
#    channel, and key are freed by whoever created them.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

import libssh_jll
# `Sockets` is imported only for its qualified names: it exports `send`, which
# would collide with air's own `send` at module scope.
import Sockets

"""
    SshError(msg)

An SSH failure: a libssh call reported an error, a configuration entry was
malformed, or a server could not start. Air sees it as `(error :ssh msg)`.
"""
struct SshError <: AirError
    msg::String
end

Base.showerror(io::IO, e::SshError) = print(io, e.msg)

# Air-level tag for the error object an `except` clause matches.
_error_form(e::SshError) = _error_object(Form(Symbol(":ssh")), Form(e.msg))

# ---- library loading ---------------------------------------------------------

# The resolved library path, or `nothing` when the artifact cannot be loaded.
# `_ssh_init!` runs from the module's `__init__`; the builtins raise a catchable
# error when the library is missing rather than a Julia `UndefVarError`.
const _LIBSSH = Ref{String}("")
const _LIBSSH_ERROR = Ref{Union{Nothing,String}}(nothing)

function _ssh_init!()
    try
        ccall((:ssh_version, libssh_jll.libssh), Cint, (Cint,), 0)
        _LIBSSH[] = libssh_jll.libssh
        _LIBSSH_ERROR[] = nothing
    catch e
        _LIBSSH_ERROR[] = sprint(showerror, e)
    end
    return nothing
end

function _libssh()::String
    isempty(_LIBSSH[]) &&
        throw(SshError("the libssh library is unavailable" *
                       (_LIBSSH_ERROR[] === nothing ? "" :
                        ": " * _LIBSSH_ERROR[])))
    return _LIBSSH[]
end

# ---- constants ---------------------------------------------------------------

const SSH_OK = Cint(0)
const SSH_ERROR = Cint(-1)
const SSH_AGAIN = Cint(-2)

# `ssh_bind_options_e`
const SSH_BIND_OPTIONS_BINDADDR = Cint(0)
const SSH_BIND_OPTIONS_BINDPORT = Cint(1)
const SSH_BIND_OPTIONS_BANNER = Cint(6)
const SSH_BIND_OPTIONS_IMPORT_KEY = Cint(10)

# `ssh_options_e`
const SSH_OPTIONS_TIMEOUT = Cint(9)

# `ssh_requests_e`
const SSH_REQUEST_AUTH = Cint(1)
const SSH_REQUEST_CHANNEL_OPEN = Cint(2)
const SSH_REQUEST_CHANNEL = Cint(3)
const SSH_REQUEST_SERVICE = Cint(4)
const SSH_REQUEST_GLOBAL = Cint(5)

# `ssh_channel_type_e`
const SSH_CHANNEL_SESSION = Cint(1)

# `ssh_channel_requests_e`
const SSH_CHANNEL_REQUEST_PTY = Cint(1)
const SSH_CHANNEL_REQUEST_EXEC = Cint(2)
const SSH_CHANNEL_REQUEST_SHELL = Cint(3)
const SSH_CHANNEL_REQUEST_ENV = Cint(4)
const SSH_CHANNEL_REQUEST_SUBSYSTEM = Cint(5)
const SSH_CHANNEL_REQUEST_WINDOW_CHANGE = Cint(6)

# `ssh_publickey_state_e`
const SSH_PUBLICKEY_STATE_NONE = Cint(0)
const SSH_PUBLICKEY_STATE_VALID = Cint(1)

# `ssh_auth_e`
const SSH_AUTH_METHOD_PUBLICKEY = Cint(0x0004)

# ---- errors ------------------------------------------------------------------

# The last error a libssh object recorded, as a string.
_ssh_error(obj) = (m = ccall((:ssh_get_error, libssh_jll.libssh), Cstring, (Ptr{Cvoid},), obj);
                   m == C_NULL ? "unknown libssh error" : unsafe_string(m))

_fail(obj, what) = throw(SshError("$what: $(_ssh_error(obj))"))

# Check a libssh return code, raising `SshError` on SSH_ERROR.
function _check(rc::Integer, obj, what::AbstractString)
    rc == SSH_ERROR && _fail(obj, what)
    return Cint(rc)
end

# A `char*` libssh allocated and handed to us: copy it and free it.
function _take_string(p::Ptr{Cchar})
    p == C_NULL && return nothing
    s = unsafe_string(p)
    ccall((:ssh_string_free_char, libssh_jll.libssh), Cvoid, (Ptr{Cchar},), p)
    return s
end

# ---- bind --------------------------------------------------------------------

_ls_bind_new() = ccall((:ssh_bind_new, libssh_jll.libssh), Ptr{Cvoid}, ())

_ls_bind_free(b::Ptr{Cvoid}) =
    ccall((:ssh_bind_free, libssh_jll.libssh), Cvoid, (Ptr{Cvoid},), b)

# `ssh_bind_options_set`, with the value passed as the C type the option expects.
_ls_bind_option!(b::Ptr{Cvoid}, opt::Cint, value::Ref{Cint}) =
    _check(ccall((:ssh_bind_options_set, libssh_jll.libssh), Cint,
                 (Ptr{Cvoid}, Cint, Ptr{Cint}), b, opt, value), b, "ssh_bind_options_set")

function _ls_bind_option!(b::Ptr{Cvoid}, opt::Cint, value::AbstractString)
    return _check(ccall((:ssh_bind_options_set, libssh_jll.libssh), Cint,
                        (Ptr{Cvoid}, Cint, Cstring), b, opt, value),
                  b, "ssh_bind_options_set")
end

# `SSH_BIND_OPTIONS_IMPORT_KEY` takes the `ssh_key` itself, not a pointer to it.
_ls_bind_import_key!(b::Ptr{Cvoid}, key::Ptr{Cvoid}) =
    _check(ccall((:ssh_bind_options_set, libssh_jll.libssh), Cint,
                 (Ptr{Cvoid}, Cint, Ptr{Cvoid}), b, SSH_BIND_OPTIONS_IMPORT_KEY, key),
           b, "ssh_bind_options_set")

# Accept an already-connected socket into the session, in blocking mode.
_ls_bind_accept_fd(b::Ptr{Cvoid}, s::Ptr{Cvoid}, fd::Cint) =
    Cint(Base.@threadcall((:ssh_bind_accept_fd, libssh_jll.libssh), Cint,
                          (Ptr{Cvoid}, Ptr{Cvoid}, Cint), b, s, fd))

# ---- sessions ----------------------------------------------------------------

_ls_new() = ccall((:ssh_new, libssh_jll.libssh), Ptr{Cvoid}, ())
_ls_free(s::Ptr{Cvoid}) = ccall((:ssh_free, libssh_jll.libssh), Cvoid, (Ptr{Cvoid},), s)
_ls_set_blocking(s::Ptr{Cvoid}, blocking::Bool) =
    ccall((:ssh_set_blocking, libssh_jll.libssh), Cvoid, (Ptr{Cvoid}, Cint), s, Cint(blocking))
_ls_get_fd(s::Ptr{Cvoid}) = ccall((:ssh_get_fd, libssh_jll.libssh), Cint, (Ptr{Cvoid},), s)
_ls_is_connected(s::Ptr{Cvoid}) =
    ccall((:ssh_is_connected, libssh_jll.libssh), Cint, (Ptr{Cvoid},), s) != 0
_ls_set_auth_methods(s::Ptr{Cvoid}, methods::Cint) =
    ccall((:ssh_set_auth_methods, libssh_jll.libssh), Cvoid, (Ptr{Cvoid}, Cint), s, methods)

function _ls_set_timeout(s::Ptr{Cvoid}, seconds::Integer)
    t = Ref{Clong}(Clong(seconds))
    return _check(ccall((:ssh_options_set, libssh_jll.libssh), Cint,
                        (Ptr{Cvoid}, Cint, Ptr{Clong}), s, SSH_OPTIONS_TIMEOUT, t),
                  s, "ssh_options_set(TIMEOUT)")
end

# Key exchange and the authentication phase run in blocking mode, so they go to
# the thread pool; the session timeout bounds each call.
_ls_handle_key_exchange(s::Ptr{Cvoid}) =
    Cint(Base.@threadcall((:ssh_handle_key_exchange, libssh_jll.libssh), Cint,
                          (Ptr{Cvoid},), s))

# ---- messages ----------------------------------------------------------------

# In blocking mode this waits for the next message; in non-blocking mode it
# returns `C_NULL` when none is pending. Both forms go through the thread pool,
# because libssh may have buffered data and a blocking-mode call waits on the
# socket.
_ls_message_get(s::Ptr{Cvoid}) =
    Base.@threadcall((:ssh_message_get, libssh_jll.libssh), Ptr{Cvoid}, (Ptr{Cvoid},), s)
_ls_message_free(m::Ptr{Cvoid}) =
    ccall((:ssh_message_free, libssh_jll.libssh), Cvoid, (Ptr{Cvoid},), m)
_ls_message_type(m::Ptr{Cvoid}) =
    Cint(ccall((:ssh_message_type, libssh_jll.libssh), Cint, (Ptr{Cvoid},), m))
_ls_message_subtype(m::Ptr{Cvoid}) =
    Cint(ccall((:ssh_message_subtype, libssh_jll.libssh), Cint, (Ptr{Cvoid},), m))

_ls_message_reply_default(m::Ptr{Cvoid}) =
    Cint(Base.@threadcall((:ssh_message_reply_default, libssh_jll.libssh), Cint,
                          (Ptr{Cvoid},), m))

function _ls_message_service_service(m::Ptr{Cvoid})
    p = ccall((:ssh_message_service_service, libssh_jll.libssh), Cstring,
              (Ptr{Cvoid},), m)
    return p == C_NULL ? nothing : unsafe_string(p)
end

# The client's `ssh-userauth` service request is a message the server must answer
# itself; `SERVICE_ACCEPT` is the only reply the protocol allows.
_ls_message_service_reply_success(m::Ptr{Cvoid}) =
    Cint(Base.@threadcall((:ssh_message_service_reply_success, libssh_jll.libssh),
                          Cint, (Ptr{Cvoid},), m))

function _ls_auth_user(m::Ptr{Cvoid})
    p = ccall((:ssh_message_auth_user, libssh_jll.libssh), Cstring, (Ptr{Cvoid},), m)
    return p == C_NULL ? nothing : unsafe_string(p)
end

_ls_auth_publickey_state(m::Ptr{Cvoid}) =
    Cint(Base.@threadcall((:ssh_message_auth_publickey_state, libssh_jll.libssh), Cint,
                          (Ptr{Cvoid},), m))

# The offered key. It belongs to the message and must not be freed here.
_ls_auth_pubkey(m::Ptr{Cvoid}) =
    Base.@threadcall((:ssh_message_auth_pubkey, libssh_jll.libssh), Ptr{Cvoid},
                     (Ptr{Cvoid},), m)

_ls_auth_reply_pk_ok(m::Ptr{Cvoid}) =
    Cint(Base.@threadcall((:ssh_message_auth_reply_pk_ok_simple, libssh_jll.libssh), Cint,
                          (Ptr{Cvoid},), m))
_ls_auth_reply_success(m::Ptr{Cvoid}) =
    Cint(Base.@threadcall((:ssh_message_auth_reply_success, libssh_jll.libssh), Cint,
                          (Ptr{Cvoid}, Cint), m, Cint(0)))

function _ls_channel_open_accept(m::Ptr{Cvoid})
    ch = Base.@threadcall((:ssh_message_channel_request_open_reply_accept, libssh_jll.libssh),
                          Ptr{Cvoid}, (Ptr{Cvoid},), m)
    ch == C_NULL && _fail(m, "channel open failed")
    return ch
end

_ls_channel_request_reply_success(m::Ptr{Cvoid}) =
    Cint(Base.@threadcall((:ssh_message_channel_request_reply_success, libssh_jll.libssh),
                          Cint, (Ptr{Cvoid},), m))
_ls_channel_request_channel(m::Ptr{Cvoid}) =
    Base.@threadcall((:ssh_message_channel_request_channel, libssh_jll.libssh), Ptr{Cvoid},
                     (Ptr{Cvoid},), m)
_ls_channel_request_pty_width(m::Ptr{Cvoid}) =
    Cint(ccall((:ssh_message_channel_request_pty_width, libssh_jll.libssh), Cint,
               (Ptr{Cvoid},), m))
_ls_channel_request_pty_height(m::Ptr{Cvoid}) =
    Cint(ccall((:ssh_message_channel_request_pty_height, libssh_jll.libssh), Cint,
               (Ptr{Cvoid},), m))

function _ls_channel_request_subsystem(m::Ptr{Cvoid})
    p = ccall((:ssh_message_channel_request_subsystem, libssh_jll.libssh), Cstring,
              (Ptr{Cvoid},), m)
    return p == C_NULL ? nothing : unsafe_string(p)
end

# ---- channels ----------------------------------------------------------------

_ls_channel_free(ch::Ptr{Cvoid}) =
    ccall((:ssh_channel_free, libssh_jll.libssh), Cvoid, (Ptr{Cvoid},), ch)
_ls_channel_close(ch::Ptr{Cvoid}) =
    Cint(Base.@threadcall((:ssh_channel_close, libssh_jll.libssh), Cint, (Ptr{Cvoid},), ch))
# The client reports the session's exit status; without one `ssh` exits 255.
_ls_channel_send_exit_status(ch::Ptr{Cvoid}, status::Integer) =
    Cint(ccall((:ssh_channel_request_send_exit_status, libssh_jll.libssh), Cint,
               (Ptr{Cvoid}, Cint), ch, Cint(status)))
_ls_channel_is_eof(ch::Ptr{Cvoid}) =
    ccall((:ssh_channel_is_eof, libssh_jll.libssh), Cint, (Ptr{Cvoid},), ch) != 0
_ls_channel_is_closed(ch::Ptr{Cvoid}) =
    ccall((:ssh_channel_is_closed, libssh_jll.libssh), Cint, (Ptr{Cvoid},), ch) != 0

# Non-blocking reads/writes: 0 (or SSH_AGAIN) means "not now", not an error.
_ls_channel_read_nonblocking(ch::Ptr{Cvoid}, buf::Ptr{UInt8}, len::Integer) =
    Cint(ccall((:ssh_channel_read_nonblocking, libssh_jll.libssh), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, Cuint, Cint), ch, buf, Cuint(len), Cint(0)))
_ls_channel_write(ch::Ptr{Cvoid}, buf::Ptr{UInt8}, len::Integer) =
    Cint(ccall((:ssh_channel_write, libssh_jll.libssh), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, Cuint), ch, buf, Cuint(len)))

# ---- keys --------------------------------------------------------------------

# `ssh_pki_generate` returns a private key; `parameter` is the bit count for RSA
# and ignored for ed25519. The result is validated by its exported type name so a
# libssh enum mismatch surfaces as an error, never as a wrong key.
function _ls_pki_generate(type::Cint, parameter::Integer)
    ref = Ref{Ptr{Cvoid}}(C_NULL)
    rc = ccall((:ssh_pki_generate, libssh_jll.libssh), Cint,
               (Cint, Cint, Ptr{Ptr{Cvoid}}), type, Cint(parameter), ref)
    (rc == SSH_ERROR || ref[] == C_NULL) && throw(SshError("key generation failed"))
    return ref[]
end

function _ls_pki_import_privkey(b64::AbstractString)
    ref = Ref{Ptr{Cvoid}}(C_NULL)
    rc = ccall((:ssh_pki_import_privkey_base64, libssh_jll.libssh), Cint,
               (Cstring, Cstring, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Ptr{Cvoid}}),
               b64, C_NULL, C_NULL, C_NULL, ref)
    (rc == SSH_ERROR || ref[] == C_NULL) &&
        throw(SshError("the stored host key could not be imported"))
    return ref[]
end

function _ls_pki_export_privkey(key::Ptr{Cvoid})
    ref = Ref{Ptr{Cchar}}(C_NULL)
    rc = ccall((:ssh_pki_export_privkey_base64, libssh_jll.libssh), Cint,
               (Ptr{Cvoid}, Ptr{Cchar}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Ptr{Cchar}}),
               key, C_NULL, C_NULL, C_NULL, ref)
    rc == SSH_ERROR && throw(SshError("the host key could not be exported"))
    s = _take_string(ref[])
    s === nothing && throw(SshError("the host key could not be exported"))
    return s
end

function _ls_pki_export_pubkey_base64(key::Ptr{Cvoid})
    ref = Ref{Ptr{Cchar}}(C_NULL)
    rc = ccall((:ssh_pki_export_pubkey_base64, libssh_jll.libssh), Cint,
               (Ptr{Cvoid}, Ptr{Ptr{Cchar}}), key, ref)
    rc == SSH_ERROR && throw(SshError("the public key could not be exported"))
    s = _take_string(ref[])
    s === nothing && throw(SshError("the public key could not be exported"))
    return s
end

_ls_key_free(key::Ptr{Cvoid}) =
    ccall((:ssh_key_free, libssh_jll.libssh), Cvoid, (Ptr{Cvoid},), key)

_ls_key_type(key::Ptr{Cvoid}) =
    Cint(ccall((:ssh_key_type, libssh_jll.libssh), Cint, (Ptr{Cvoid},), key))

# The short name of a key type (`ssh-ed25519`, `rsa`, …). Comparing names keeps
# the authorized-key check independent of libssh's enum values.
function _ls_key_type_name(key::Ptr{Cvoid})
    p = ccall((:ssh_key_type_to_char, libssh_jll.libssh), Cstring, (Cint,), _ls_key_type(key))
    return p == C_NULL ? "unknown" : unsafe_string(p)
end

# `(type, base64 blob)` for a public key — the pair an authorized-key entry holds.
_ls_public_identity(key::Ptr{Cvoid}) =
    (_ls_key_type_name(key), _ls_pki_export_pubkey_base64(key))
