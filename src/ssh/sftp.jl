################################################################################
# ssh/sftp.jl
#
# SFTP version 3, the subset a modern `scp` and `sftp` actually use. A directory
# is a namespace and a file is a `bytes` val, so a transfer is a namespace read or
# a single transactional `val` write: an upload appears whole or not at all, and
# a namespace listing is filtered by the caller's `read` permission.
#
# Packets are `uint32 length | uint8 type | uint32 request-id | payload` in
# network byte order. Only version 3 is advertised and no extensions, so a client
# issues plain requests.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- packet types ------------------------------------------------------------

const _SFTP_INIT = UInt8(1)
const _SFTP_VERSION = UInt8(2)
const _SFTP_OPEN = UInt8(3)
const _SFTP_CLOSE = UInt8(4)
const _SFTP_READ = UInt8(5)
const _SFTP_WRITE = UInt8(6)
const _SFTP_LSTAT = UInt8(7)
const _SFTP_FSTAT = UInt8(8)
const _SFTP_SETSTAT = UInt8(9)
const _SFTP_FSETSTAT = UInt8(10)
const _SFTP_OPENDIR = UInt8(11)
const _SFTP_READDIR = UInt8(12)
const _SFTP_REMOVE = UInt8(13)
const _SFTP_MKDIR = UInt8(14)
const _SFTP_RMDIR = UInt8(15)
const _SFTP_REALPATH = UInt8(16)
const _SFTP_STAT = UInt8(17)
const _SFTP_RENAME = UInt8(18)
const _SFTP_READLINK = UInt8(19)
const _SFTP_SYMLINK = UInt8(20)

const _SFTP_STATUS = UInt8(101)
const _SFTP_HANDLE = UInt8(102)
const _SFTP_DATA = UInt8(103)
const _SFTP_NAME = UInt8(104)
const _SFTP_ATTRS = UInt8(105)

# Status codes.
const _SFTP_OK = UInt32(0)
const _SFTP_EOF = UInt32(1)
const _SFTP_NO_SUCH_FILE = UInt32(2)
const _SFTP_PERMISSION_DENIED = UInt32(3)
const _SFTP_FAILURE = UInt32(4)
const _SFTP_OP_UNSUPPORTED = UInt32(8)

# Attribute flags, and the two modes every entry here reports.
const _SFTP_ATTR_SIZE = UInt32(0x00000001)
const _SFTP_ATTR_PERMISSIONS = UInt32(0x00000004)
const _SFTP_MODE_DIR = UInt32(0o040755)
const _SFTP_MODE_FILE = UInt32(0o100644)

# Open flags.
const _SFTP_OPEN_READ = UInt32(0x0001)
const _SFTP_OPEN_WRITE = UInt32(0x0002)
const _SFTP_OPEN_APPEND = UInt32(0x0004)
const _SFTP_OPEN_CREAT = UInt32(0x0008)
const _SFTP_OPEN_TRUNC = UInt32(0x0010)
const _SFTP_OPEN_EXCL = UInt32(0x0020)

################################################################################
# Wire format

"""
    _SftpBuf(data)

A big-endian reader over one packet's payload.
"""
mutable struct _SftpBuf
    data::Vector{UInt8}
    pos::Int
end

_SftpBuf(data::Vector{UInt8}) = _SftpBuf(data, 1)

_sftp_malformed() = throw(SshError("malformed sftp packet"))

function _sb_u8!(b::_SftpBuf)
    b.pos + 1 <= length(b.data) || _sftp_malformed()
    v = b.data[b.pos]
    b.pos += 1
    return Int(v)
end

function _sb_u32!(b::_SftpBuf)
    b.pos + 3 <= length(b.data) || _sftp_malformed()
    d = b.data
    v = (UInt32(d[b.pos]) << 24) | (UInt32(d[b.pos + 1]) << 16) |
        (UInt32(d[b.pos + 2]) << 8) | UInt32(d[b.pos + 3])
    b.pos += 4
    return v
end

_sb_u64!(b::_SftpBuf) = (hi = UInt64(_sb_u32!(b)); lo = UInt64(_sb_u32!(b));
                         (hi << 32) | lo)

function _sb_str!(b::_SftpBuf)
    n = Int(_sb_u32!(b))
    b.pos + n - 1 <= length(b.data) || _sftp_malformed()
    s = String(b.data[b.pos:(b.pos + n - 1)])
    b.pos += n
    return s
end

function _sb_bytes!(b::_SftpBuf)
    n = Int(_sb_u32!(b))
    b.pos + n - 1 <= length(b.data) || _sftp_malformed()
    d = b.data[b.pos:(b.pos + n - 1)]
    b.pos += n
    return d
end

function _pk_u32!(out::Vector{UInt8}, x::Integer)
    v = UInt32(x & 0xffffffff)
    push!(out, UInt8(v >> 24), UInt8((v >> 16) & 0xff),
          UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
    return out
end

function _pk_u64!(out::Vector{UInt8}, x::Integer)
    v = UInt64(x)
    _pk_u32!(out, v >> 32)
    _pk_u32!(out, v & 0xffffffff)
    return out
end

function _pk_str!(out::Vector{UInt8}, s::AbstractString)
    d = codeunits(String(s))
    _pk_u32!(out, length(d))
    append!(out, d)
    return out
end

function _sftp_send!(chan::Ptr{Cvoid}, typ::UInt8, rid::Integer,
                     payload::Vector{UInt8})
    out = UInt8[]
    _pk_u32!(out, 5 + length(payload))
    push!(out, typ)
    _pk_u32!(out, rid)
    append!(out, payload)
    _ssh_write_channel!(chan, out)
    return nothing
end

function _sftp_status!(st, rid::Integer, code::UInt32, msg::AbstractString)
    p = UInt8[]
    _pk_u32!(p, code)
    _pk_str!(p, msg)
    _pk_str!(p, "")
    _sftp_send!(st.chan, _SFTP_STATUS, rid, p)
    return nothing
end

function _sftp_pack_attrs!(out::Vector{UInt8}, mode::UInt32, size::Integer)
    _pk_u32!(out, _SFTP_ATTR_SIZE | _SFTP_ATTR_PERMISSIONS)
    _pk_u64!(out, size)
    _pk_u32!(out, mode)
    return out
end

# One directory entry as `sftp` renders it. Clients build their own format, but a
# longname is required and should not be empty.
function _sftp_longname(name::AbstractString, mode::UInt32, size::Integer)
    kind = mode == _SFTP_MODE_DIR ? 'd' : '-'
    return string(kind, "rwxr-xr-x    1 air      air      ", lpad(size, 8), " ",
                  name)
end

################################################################################
# Session state

# A failed request; the dispatcher turns it into a status reply.
struct _SftpStatus <: Exception
    code::UInt32
    msg::String
end

mutable struct _SftpDir
    path::Vector{Symbol}
    entries::Vector{Tuple{String,UInt32,UInt64}}
    pos::Int
end

mutable struct _SftpFile
    path::Vector{Symbol}
    writing::Bool
    buf::Vector{UInt8}
end

mutable struct _SftpState
    env::Env
    server::_SshServer
    session::Ptr{Cvoid}
    chan::Ptr{Cvoid}
    user::Symbol
    home::Vector{Symbol}
    buf::Vector{UInt8}
    handles::Dict{UInt32,Any}
    next::UInt32
end

# ---- reading ----------------------------------------------------------------

# The next complete packet as `(type, payload)`, or `nothing` when the channel
# holds no complete one yet. INIT carries no request id, so the id is parsed by
# the dispatcher for every other type.
function _sftp_poll!(st::_SftpState)
    tmp = Vector{UInt8}(undef, 65536)
    while true
        if length(st.buf) >= 4
            d = st.buf
            n = (Int(d[1]) << 24) | (Int(d[2]) << 16) | (Int(d[3]) << 8) | Int(d[4])
            if length(st.buf) >= 4 + n
                data = st.buf[5:(4 + n)]
                deleteat!(st.buf, 1:(4 + n))
                n >= 1 || continue
                return (data[1], data[2:end])
            end
        end
        k = _ls_channel_read_nonblocking(st.chan, pointer(tmp), length(tmp))
        if k > 0
            append!(st.buf, tmp[1:Int(k)])
            continue
        elseif k == SSH_ERROR
            throw(SshError("the sftp channel closed"))
        end
        _ls_channel_is_eof(st.chan) && throw(SshError("the sftp channel closed"))
        return nothing
    end
end

# ---- path resolution --------------------------------------------------------

_sftp_path!(st::_SftpState, raw::AbstractString) = _ssh_abs_path(st.home, raw)

# The `bytes` value a form holds, or `nothing` when it is not one.
function _sftp_form_bytes(v::Form)
    v isa FormExtern || return nothing
    d = try
        _extern_data(v)
    catch
        return nothing
    end
    return d isa AirBytes ? d : nothing
end

# The value bound to `name` in `ns`, or `nothing`.
function _sftp_ns_value(env::Env, ns::Namespace, name::Symbol)
    b = _val_binding(env, ns.path, name)
    return b === nothing ? nothing : to_form(b.var[])
end

# One entry of a namespace as `(name, mode, size)` — a subnamespace or a `bytes`
# val the user may read. Everything else is not a file and is omitted, as is any
# entry the user may not read, so a listing never fails on a hidden name.
function _sftp_entry(env::Env, ns::Namespace, key::Symbol, user::Symbol)
    name = _bindname(key)
    marker = _ns_map_get(env, ns, key; lazy = false)
    marker === nothing && return nothing
    if _is_ns_sub(marker)
        sub = _ns_lookup(env, vcat(ns.path, name); lazy = false)
        sub === nothing && return nothing
        _can(env, sub.vf, user, :read) || return nothing
        return (String(name), _SFTP_MODE_DIR, UInt64(0))
    end
    _is_ns_val(marker) || return nothing
    b = _val_binding(env, ns.path, name)
    b === nothing && return nothing
    _can(env, b.entry, user, :read) || return nothing
    d = _sftp_form_bytes(to_form(b.var[]))
    size = d === nothing ? UInt64(0) : UInt64(length(d.data))
    return (String(name), _SFTP_MODE_FILE, size)
end

function _sftp_list(env::Env, ns::Namespace, user::Symbol)
    out = Tuple{String,UInt32,UInt64}[]
    m = _ns_map(env, ns)
    m === nothing && return out
    for (k, _) in m.map
        e = _sftp_entry(env, ns, k, user)
        e === nothing || push!(out, e)
    end
    sort!(out; by = first)
    return out
end

# Resolve a path to `(mode, size)` for a stat; throws the status to reply.
function _sftp_stat_path(st::_SftpState, path::Vector{Symbol})
    ns = _ns_lookup(st.env, path; lazy = false)
    if ns !== nothing
        _can(st.env, ns.vf, st.user, :read) ||
            throw(_SftpStatus(_SFTP_PERMISSION_DENIED, "permission denied"))
        return (_SFTP_MODE_DIR, UInt64(0))
    end
    isempty(path) && throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such path"))
    pns = _ns_lookup(st.env, path[1:(end - 1)]; lazy = false)
    pns === nothing && throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such path"))
    name = path[end]
    marker = _ns_map_get(st.env, pns, Symbol(":", String(name)); lazy = false)
    (marker === nothing || !_is_ns_val(marker)) &&
        throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such path"))
    b = _val_binding(st.env, pns.path, name)
    b === nothing && throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such path"))
    _can(st.env, b.entry, st.user, :read) ||
        throw(_SftpStatus(_SFTP_PERMISSION_DENIED, "permission denied"))
    d = _sftp_form_bytes(to_form(b.var[]))
    return (_SFTP_MODE_FILE, d === nothing ? UInt64(0) : UInt64(length(d.data)))
end

################################################################################
# Handles

function _sftp_new_handle!(st::_SftpState, obj)
    id = st.next
    st.next += UInt32(1)
    st.handles[id] = obj
    return string(id)
end

function _sftp_handle!(st::_SftpState, rid::Integer, b::_SftpBuf, ::Type{T}) where {T}
    s = _sb_str!(b)
    id = try
        UInt32(parse(Int, s; base = 10))
    catch
        throw(_SftpStatus(_SFTP_FAILURE, "invalid handle"))
    end
    h = get(st.handles, id, nothing)
    (h === nothing || !(h isa T)) &&
        throw(_SftpStatus(_SFTP_FAILURE, "invalid handle"))
    return (id, h)
end

################################################################################
# Requests

function _sftp_open!(st::_SftpState, rid::Integer, path::Vector{Symbol},
                     flags::UInt32)
    isempty(path) && throw(_SftpStatus(_SFTP_FAILURE, "cannot open the root"))
    name = path[end]
    pns = _ns_lookup(st.env, path[1:(end - 1)]; lazy = false)
    writing = (flags & (_SFTP_OPEN_WRITE | _SFTP_OPEN_APPEND)) != 0
    existing = nothing
    if pns !== nothing
        marker = _ns_map_get(st.env, pns, Symbol(":", String(name)); lazy = false)
        if marker !== nothing
            _is_ns_val(marker) ||
                throw(_SftpStatus(_SFTP_FAILURE, "$(_ssh_display(path)) is not a file"))
            b = _val_binding(st.env, pns.path, name)
            existing = b === nothing ? nothing : to_form(b.var[])
        end
    end
    if writing
        (flags & _SFTP_OPEN_EXCL) != 0 && existing !== nothing &&
            throw(_SftpStatus(_SFTP_FAILURE, "$(_ssh_display(path)) exists"))
        if pns !== nothing
            _can(st.env, pns.vf, st.user, :write) ||
                throw(_SftpStatus(_SFTP_PERMISSION_DENIED, "permission denied"))
        end
        d = existing === nothing ? nothing : _sftp_form_bytes(existing)
        (existing !== nothing && d === nothing) &&
            throw(_SftpStatus(_SFTP_FAILURE,
                              "$(_ssh_display(path)) is not a file"))
        initial = if d === nothing || (flags & _SFTP_OPEN_TRUNC) != 0
            UInt8[]
        else
            copy(d.data)
        end
        h = _sftp_new_handle!(st, _SftpFile(path, true, initial))
        payload = UInt8[]
        _pk_str!(payload, h)
        return _sftp_send!(st.chan, _SFTP_HANDLE, rid, payload)
    end
    ns = _ns_lookup(st.env, path; lazy = false)
    ns !== nothing &&
        throw(_SftpStatus(_SFTP_FAILURE, "$(_ssh_display(path)) is a directory"))
    d = existing === nothing ? nothing : _sftp_form_bytes(existing)
    (existing !== nothing && d === nothing) &&
        throw(_SftpStatus(_SFTP_FAILURE, "$(_ssh_display(path)) is not a file"))
    d === nothing &&
        throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such file"))
    if pns !== nothing
        b = _val_binding(st.env, pns.path, name)
        _can(st.env, b.entry, st.user, :read) ||
            throw(_SftpStatus(_SFTP_PERMISSION_DENIED, "permission denied"))
    end
    h = _sftp_new_handle!(st, _SftpFile(path, false, copy(d.data)))
    payload = UInt8[]
    _pk_str!(payload, h)
    return _sftp_send!(st.chan, _SFTP_HANDLE, rid, payload)
end

# Store a whole uploaded file as one new `bytes` val, replacing any previous
# value. Immutability means a transfer is all-or-nothing: an interrupted upload
# leaves the old value untouched.
function _sftp_commit!(st::_SftpState, path::Vector{Symbol}, data::Vector{UInt8})
    isempty(path) && throw(_SftpStatus(_SFTP_FAILURE, "cannot write the root"))
    name = path[end]
    parent = path[1:(end - 1)]
    ns = _ns_ensure!(st.env, parent)
    _can(st.env, ns.vf, st.user, :write) ||
        throw(_SftpStatus(_SFTP_PERMISSION_DENIED, "permission denied"))
    tx() do
        entries = _ns_entries_of(ns.vf)
        for e in entries
            (_entry_export_name(e) === name && _entry_head(e) !== _VAL_HEAD) &&
                throw(_SftpStatus(_SFTP_FAILURE,
                                  "$(_ssh_display(path)) is not a file"))
        end
        # Only a `bytes` val is a file; a val holding anything else (a config
        # list, a mutable, …) is not, so a transfer never replaces it.
        prev = _val_binding(st.env, ns.path, name)
        (prev !== nothing && _sftp_form_bytes(to_form(prev.var[])) === nothing) &&
            throw(_SftpStatus(_SFTP_FAILURE,
                              "$(_ssh_display(path)) is not a file"))
        keep = Form[e for e in entries
                    if !(_entry_export_name(e) === name &&
                         _entry_head(e) === _VAL_HEAD)]
        length(keep) == length(entries) || _ns_store_entries!(st.env, ns, keep)
        _ns_add_val!(st.env, ns, Form(name), _extern_form(AirBytes(data)))
    end
    return nothing
end

function _sftp_remove!(st::_SftpState, path::Vector{Symbol})
    isempty(path) && throw(_SftpStatus(_SFTP_FAILURE, "cannot remove the root"))
    name = path[end]
    pns = _ns_lookup(st.env, path[1:(end - 1)]; lazy = false)
    pns === nothing && throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such file"))
    marker = _ns_map_get(st.env, pns, Symbol(":", String(name)); lazy = false)
    (marker === nothing || !_is_ns_val(marker)) &&
        throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such file"))
    b = _val_binding(st.env, pns.path, name)
    (b !== nothing && _sftp_form_bytes(to_form(b.var[])) === nothing) &&
        throw(_SftpStatus(_SFTP_FAILURE,
                          "$(_ssh_display(path)) is not a file"))
    (b === nothing || !_can(st.env, b.entry, st.user, :write)) &&
        throw(_SftpStatus(_SFTP_PERMISSION_DENIED, "permission denied"))
    tx() do
        keep = Form[e for e in _ns_entries_of(pns.vf)
                    if !(_entry_export_name(e) === name &&
                         _entry_head(e) === _VAL_HEAD)]
        _ns_store_entries!(st.env, pns, keep)
    end
    return nothing
end

function _sftp_rmdir!(st::_SftpState, path::Vector{Symbol})
    isempty(path) && throw(_SftpStatus(_SFTP_FAILURE, "cannot remove the root"))
    name = path[end]
    pns = _ns_lookup(st.env, path[1:(end - 1)]; lazy = false)
    pns === nothing && throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such directory"))
    child = _ns_lookup(st.env, path; lazy = false)
    child === nothing && throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such directory"))
    isempty(_ns_entries_of(child.vf)) ||
        throw(_SftpStatus(_SFTP_FAILURE, "directory is not empty"))
    _can(st.env, pns.vf, st.user, :write) ||
        throw(_SftpStatus(_SFTP_PERMISSION_DENIED, "permission denied"))
    tx() do
        keep = Form[e for e in _ns_entries_of(pns.vf)
                    if !(_entry_export_name(e) === name &&
                         _entry_head(e) === NS_SUB)]
        _ns_store_entries!(st.env, pns, keep)
    end
    return nothing
end

# A rename copies the file to the new path and removes the old one. Namespaces
# are not renamed: a whole subtree is not a file.
function _sftp_rename!(st::_SftpState, old::Vector{Symbol}, new::Vector{Symbol})
    ns_old = _ns_lookup(st.env, old; lazy = false)
    ns_old !== nothing && throw(_SftpStatus(_SFTP_OP_UNSUPPORTED,
                                            "cannot rename a directory"))
    mode, _ = _sftp_stat_path(st, old)
    mode == _SFTP_MODE_DIR && throw(_SftpStatus(_SFTP_OP_UNSUPPORTED,
                                                "cannot rename a directory"))
    pns = _ns_lookup(st.env, old[1:(end - 1)]; lazy = false)
    pns === nothing && throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such file"))
    b = _val_binding(st.env, pns.path, old[end])
    d = b === nothing ? nothing : _sftp_form_bytes(to_form(b.var[]))
    d === nothing && throw(_SftpStatus(_SFTP_FAILURE, "not a file"))
    _sftp_commit!(st, new, copy(d.data))
    _sftp_remove!(st, old)
    return nothing
end

################################################################################
# The dispatcher

function _sftp_request!(st::_SftpState, typ::UInt8, rid::Integer, b::_SftpBuf)
    if typ == _SFTP_REALPATH
        path = _sftp_path!(st, _sb_str!(b))
        mode, size = try
            _sftp_stat_path(st, path)
        catch
            (_SFTP_MODE_DIR, UInt64(0))
        end
        p = UInt8[]
        _pk_u32!(p, 1)
        _pk_str!(p, _ssh_display(path))
        _pk_str!(p, _ssh_display(path))
        _sftp_pack_attrs!(p, mode, size)
        return _sftp_send!(st.chan, _SFTP_NAME, rid, p)
    elseif typ == _SFTP_STAT || typ == _SFTP_LSTAT
        path = _sftp_path!(st, _sb_str!(b))
        mode, size = _sftp_stat_path(st, path)
        p = UInt8[]
        _sftp_pack_attrs!(p, mode, size)
        return _sftp_send!(st.chan, _SFTP_ATTRS, rid, p)
    elseif typ == _SFTP_FSTAT
        id, h = _sftp_handle!(st, rid, b, _SftpFile)
        st.handles[id] = h
        p = UInt8[]
        _sftp_pack_attrs!(p, _SFTP_MODE_FILE, UInt64(length(h.buf)))
        return _sftp_send!(st.chan, _SFTP_ATTRS, rid, p)
    elseif typ == _SFTP_OPENDIR
        path = _sftp_path!(st, _sb_str!(b))
        ns = _ns_lookup(st.env, path; lazy = false)
        ns === nothing &&
            throw(_SftpStatus(_SFTP_NO_SUCH_FILE, "no such directory"))
        _can(st.env, ns.vf, st.user, :read) ||
            throw(_SftpStatus(_SFTP_PERMISSION_DENIED, "permission denied"))
        h = _sftp_new_handle!(st, _SftpDir(path, _sftp_list(st.env, ns, st.user), 1))
        p = UInt8[]
        _pk_str!(p, h)
        return _sftp_send!(st.chan, _SFTP_HANDLE, rid, p)
    elseif typ == _SFTP_READDIR
        _, h = _sftp_handle!(st, rid, b, _SftpDir)
        if h.pos > length(h.entries)
            return _sftp_status!(st, rid, _SFTP_EOF, "")
        end
        out = UInt8[]
        n = 0
        while h.pos <= length(h.entries) && n < 64
            (name, mode, size) = h.entries[h.pos]
            h.pos += 1
            n += 1
            _pk_str!(out, name)
            _pk_str!(out, _sftp_longname(name, mode, size))
            _sftp_pack_attrs!(out, mode, size)
        end
        p = UInt8[]
        _pk_u32!(p, n)
        append!(p, out)
        return _sftp_send!(st.chan, _SFTP_NAME, rid, p)
    elseif typ == _SFTP_OPEN
        path = _sftp_path!(st, _sb_str!(b))
        flags = _sb_u32!(b)
        return _sftp_open!(st, rid, path, flags)
    elseif typ == _SFTP_CLOSE
        id, h = _sftp_handle!(st, rid, b, Any)
        delete!(st.handles, id)
        if h isa _SftpFile && h.writing
            _sftp_commit!(st, h.path, h.buf)
        end
        return _sftp_status!(st, rid, _SFTP_OK, "")
    elseif typ == _SFTP_READ
        _, h = _sftp_handle!(st, rid, b, _SftpFile)
        off = Int(_sb_u64!(b))
        len = Int(_sb_u32!(b))
        h.writing && throw(_SftpStatus(_SFTP_FAILURE, "the handle is not readable"))
        off >= length(h.buf) && return _sftp_status!(st, rid, _SFTP_EOF, "")
        n = min(len, length(h.buf) - off)
        p = UInt8[]
        _pk_u32!(p, n)
        append!(p, @view h.buf[(off + 1):(off + n)])
        return _sftp_send!(st.chan, _SFTP_DATA, rid, p)
    elseif typ == _SFTP_WRITE
        _, h = _sftp_handle!(st, rid, b, _SftpFile)
        off = Int(_sb_u64!(b))
        data = _sb_bytes!(b)
        h.writing || throw(_SftpStatus(_SFTP_FAILURE, "the handle is not writable"))
        if off > length(h.buf)
            append!(h.buf, zeros(UInt8, off - length(h.buf)))
        end
        off + length(data) > length(h.buf) && resize!(h.buf, off + length(data))
        copyto!(h.buf, off + 1, data, 1, length(data))
        return _sftp_status!(st, rid, _SFTP_OK, "")
    elseif typ == _SFTP_SETSTAT || typ == _SFTP_FSETSTAT
        return _sftp_status!(st, rid, _SFTP_OK, "")
    elseif typ == _SFTP_MKDIR
        path = _sftp_path!(st, _sb_str!(b))
        isempty(path) && throw(_SftpStatus(_SFTP_FAILURE, "already exists"))
        _ns_lookup(st.env, path; lazy = false) === nothing ||
            throw(_SftpStatus(_SFTP_FAILURE, "already exists"))
        _ns_ensure!(st.env, path)
        return _sftp_status!(st, rid, _SFTP_OK, "")
    elseif typ == _SFTP_RMDIR
        _sftp_rmdir!(st, _sftp_path!(st, _sb_str!(b)))
        return _sftp_status!(st, rid, _SFTP_OK, "")
    elseif typ == _SFTP_REMOVE
        _sftp_remove!(st, _sftp_path!(st, _sb_str!(b)))
        return _sftp_status!(st, rid, _SFTP_OK, "")
    elseif typ == _SFTP_RENAME
        old = _sftp_path!(st, _sb_str!(b))
        new = _sftp_path!(st, _sb_str!(b))
        _sftp_rename!(st, old, new)
        return _sftp_status!(st, rid, _SFTP_OK, "")
    end
    return _sftp_status!(st, rid, _SFTP_OP_UNSUPPORTED, "unsupported request")
end

# A guest whose failure must become a status reply, never an exception out of the
# loop. An air permission denial is the client's own `read`/`write` gate.
function _sftp_dispatch!(st::_SftpState, typ::UInt8, rid::Integer, b::_SftpBuf)
    try
        return _sftp_request!(st, typ, rid, b)
    catch e
        e isa _SftpStatus && return _sftp_status!(st, rid, e.code, e.msg)
        e isa AirPermissionDenied &&
            return _sftp_status!(st, rid, _SFTP_PERMISSION_DENIED,
                                 "permission denied")
        e isa AirError && return _sftp_status!(st, rid, _SFTP_FAILURE,
                                               sprint(showerror, e))
        rethrow()
    end
end

"""
    _ssh_sftp!(env, server, session, chan, user)

Run the sftp subsystem on `chan` as `user` until the client closes it or the
server stops.
"""
function _ssh_sftp!(env::Env, server::_SshServer, session::Ptr{Cvoid},
                    chan::Ptr{Cvoid}, user::Symbol)
    home = _user_home_path(env, user)
    home === nothing && return nothing
    st = _SftpState(env, server, session, chan, user, home, UInt8[],
                    Dict{UInt32,Any}(), UInt32(1))
    while !server.closed
        pkt = try
            _sftp_poll!(st)
        catch e
            e isa SshError && break
            rethrow()
        end
        if pkt === nothing
            sleep(0.005)
            continue
        end
        typ, data = pkt
        if typ == _SFTP_INIT
            # VERSION carries no request id: `length | type | uint32 version`.
            p = UInt8[]
            _pk_u32!(p, 5)
            push!(p, _SFTP_VERSION)
            _pk_u32!(p, 3)
            _ssh_write_channel!(chan, p)
            continue
        end
        b = _SftpBuf(data)
        rid = _sb_u32!(b)
        _sftp_dispatch!(st, typ, rid, b)
    end
    return nothing
end
