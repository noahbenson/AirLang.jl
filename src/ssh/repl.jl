################################################################################
# ssh/repl.jl
#
# The interactive session: a channel writer, a line editor, and a small
# read-eval-print loop. It reuses the local REPL's input policy — an incomplete
# form continues on the next line under a `...> ` prompt, each result prints with
# the permission-aware pretty printer at the terminal width — and adds the line
# editing a pty deserves.
#
# Two control bytes have fixed meanings, per the air session contract:
#
#   Ctrl-C  (0x03)  evaluate `(raise :ctrl-c)`; the session continues
#   Ctrl-D  (0x04)  on an empty line, end the session (it closes the input)
#
# `(exit v)` also ends the session: the signal escapes the evaluation and ends
# this session task, so it never reaches a server task. Air evaluation is not
# preemptible, so a byte sent while a form runs is read when that form finishes.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- the channel writer ------------------------------------------------------

"""
    _SshChannelIO(chan, closed, session, tty, cols, rows)

An `IO` that writes to an SSH channel, retrying while libssh's window is full.
It also carries the session handle, its pty flag, the current window size, and
the bytes typed ahead of the form being evaluated, so the terminal UI renderer
(`ui-show`) can read keys, follow window changes, and refuse a non-interactive
channel. It is the session's `io_out` and its `TaskContext.out`, so `(print …)`
and the
REPL both reach the client.
"""
mutable struct _SshChannelIO <: IO
    chan::Ptr{Cvoid}
    closed::Bool
    # The session the channel belongs to and whether it has a pty, so the UI
    # renderer can service window changes and refuse a non-interactive channel.
    session::Ptr{Cvoid}
    tty::Bool
    cols::Ref{Int}
    rows::Ref{Int}
    # Bytes typed ahead of a form being evaluated; the UI renderer reads them as
    # keys. `inbuf` is the scratch buffer for non-blocking channel reads.
    pending::Vector{UInt8}
    inbuf::Vector{UInt8}
end

_SshChannelIO(chan::Ptr{Cvoid}, closed::Bool, session::Ptr{Cvoid}, tty::Bool,
              cols::Int, rows::Int) =
    _SshChannelIO(chan, closed, session, tty, Ref(cols), Ref(rows), UInt8[],
                  Vector{UInt8}(undef, 4096))

function _ssh_write_channel!(chan::Ptr{Cvoid}, data::Vector{UInt8})
    off = 1
    n = length(data)
    while off <= n
        rc = _ls_channel_write(chan, pointer(data, off), n - off + 1)
        if rc == SSH_ERROR
            throw(SshError("the session channel closed while writing"))
        elseif rc <= 0
            # No window yet: let the scheduler run and try again.
            sleep(0.005)
        else
            off += Int(rc)
        end
    end
    return nothing
end

function _ssh_write!(io::_SshChannelIO,
                     data::Union{Vector{UInt8},Base.CodeUnits{UInt8,String},
                                 SubArray{UInt8,1}})
    io.closed && throw(SshError("the session channel is closed"))
    isempty(data) && return nothing
    _ssh_write_channel!(io.chan, data isa Vector{UInt8} ? data : collect(data))
    return nothing
end

Base.isopen(io::_SshChannelIO) = !io.closed
Base.close(io::_SshChannelIO) = (io.closed = true; nothing)
Base.flush(io::_SshChannelIO) = nothing
# Base's `write` methods for strings and characters funnel into `unsafe_write`,
# so only that and the single-byte form are specialized — Base's byte form is
# abstract and refuses an `IO` that has not declared one. Adding the string and
# character forms here as well would be both redundant and, for the
# `AbstractString` spelling Base itself uses, ambiguous.
Base.write(io::_SshChannelIO, b::UInt8) = (_ssh_write!(io, UInt8[b]); 1)
function Base.unsafe_write(io::_SshChannelIO, p::Ptr{UInt8}, n::UInt)
    n == 0 && return 0
    _ssh_write!(io, unsafe_wrap(Vector{UInt8}, p, Int(n)))
    return Int(n)
end

# ---- the line editor ---------------------------------------------------------

"""
    _LineEditor(out, tty)

Per-session line editing state. With a pty it echoes and supports the usual
editing keys and history; without one it is a plain line reader (the client is a
pipe, so echoing would be noise). `feed!` takes one input byte and returns
`nothing`, `(:line, text)`, `(:eof,)`, or `(:interrupt,)`.
"""
mutable struct _LineEditor
    out::IO
    tty::Bool
    prompt::String
    line::Vector{Char}
    pos::Int
    history::Vector{String}
    hidx::Int
    saved::String
    escape::String
    utf8::Vector{UInt8}
end

_LineEditor(out::IO, tty::Bool; prompt::AbstractString = "air> ") =
    _LineEditor(out, tty, String(prompt), Char[], 1, String[], 0, "",
                "", UInt8[])

function _ed_text(ed::_LineEditor)
    return String(ed.line)
end

# Redraw the line in place: erase, then write prompt, text, and a cursor move.
function _ed_refresh!(ed::_LineEditor)
    ed.tty || return nothing
    back = length(ed.line) - ed.pos + 1
    print(ed.out, "\r\x1b[K", ed.prompt, _ed_text(ed))
    back > 1 && print(ed.out, "\x1b[", back - 1, "D")
    return nothing
end

function _ed_prompt!(ed::_LineEditor, prompt::AbstractString)
    ed.prompt = String(prompt)
    print(ed.out, ed.prompt)
    return nothing
end

function _ed_insert!(ed::_LineEditor, c::Char)
    insert!(ed.line, ed.pos, c)
    ed.pos += 1
    if ed.tty
        if ed.pos == length(ed.line) + 1
            print(ed.out, c)
        else
            _ed_refresh!(ed)
        end
    end
    return nothing
end

function _ed_backspace!(ed::_LineEditor)
    ed.pos == 1 && return nothing
    deleteat!(ed.line, ed.pos - 1)
    ed.pos -= 1
    _ed_refresh!(ed)
    return nothing
end

function _ed_delete!(ed::_LineEditor)
    ed.pos > length(ed.line) && return nothing
    deleteat!(ed.line, ed.pos)
    _ed_refresh!(ed)
    return nothing
end

function _ed_move!(ed::_LineEditor, pos::Int)
    ed.pos = clamp(pos, 1, length(ed.line) + 1)
    _ed_refresh!(ed)
    return nothing
end

# Replace the whole line with `s` (used by history navigation).
function _ed_set!(ed::_LineEditor, s::AbstractString)
    ed.line = collect(Char, s)
    ed.pos = length(ed.line) + 1
    _ed_refresh!(ed)
    return nothing
end

function _ed_history!(ed::_LineEditor, delta::Int)
    isempty(ed.history) && return nothing
    if ed.hidx == 0
        ed.saved = _ed_text(ed)
    end
    h = clamp(ed.hidx + delta, 0, length(ed.history))
    ed.hidx = h
    _ed_set!(ed, h == 0 ? ed.saved : ed.history[end - h + 1])
    return nothing
end

function _ed_submit!(ed::_LineEditor)
    s = _ed_text(ed)
    ed.tty && print(ed.out, "\r\n")
    if !isempty(strip(s))
        push!(ed.history, s)
        length(ed.history) > 100 && popfirst!(ed.history)
    end
    empty!(ed.line)
    ed.pos = 1
    ed.hidx = 0
    ed.saved = ""
    return (:line, s)
end

# Handle a complete escape sequence (`\e[…` or `\eO…`).
function _ed_escape!(ed::_LineEditor, seq::AbstractString)
    body = seq[2:end]        # the introducer is already stripped
    startswith(body, "[") && (body = body[2:end])
    body = replace(body, "O" => "")
    if body == "A"
        _ed_history!(ed, 1)
    elseif body == "B"
        _ed_history!(ed, -1)
    elseif body == "C"
        _ed_move!(ed, ed.pos + 1)
    elseif body == "D"
        _ed_move!(ed, ed.pos - 1)
    elseif body in ("H", "1~", "7~")
        _ed_move!(ed, 1)
    elseif body in ("F", "4~", "8~")
        _ed_move!(ed, length(ed.line) + 1)
    elseif body == "3~"
        _ed_delete!(ed)
    end
    return nothing
end

# How many bytes the UTF-8 character starting with `b` occupies.
_utf8_len(b::UInt8) =
    b < 0x80 ? 1 : (b >> 5) == 0x06 ? 2 : (b >> 4) == 0x0e ? 3 :
    (b >> 3) == 0x1e ? 4 : 1

function _ed_feed!(ed::_LineEditor, b::UInt8)
    # An escape sequence in progress consumes bytes until its final byte.
    if !isempty(ed.escape)
        ed.escape *= Char(b)
        lastb = b
        if length(ed.escape) >= 2 && (0x40 <= lastb <= 0x7e) &&
           !(length(ed.escape) == 2 && (lastb == '[' || lastb == 'O'))
            seq = ed.escape
            ed.escape = ""
            _ed_escape!(ed, seq)
        end
        return nothing
    end
    if b == 0x1b
        ed.escape = "\e"
        return nothing
    end
    if b == 0x03
        if ed.tty
            print(ed.out, "^C\r\n")
        end
        empty!(ed.line)
        ed.pos = 1
        ed.hidx = 0
        ed.saved = ""
        return (:interrupt,)
    end
    if b == 0x04
        isempty(ed.line) && return (:eof,)
        _ed_delete!(ed)
        return nothing
    end
    if b == 0x7f || b == 0x08
        _ed_backspace!(ed)
        return nothing
    end
    if b == 0x0d
        return ed.tty ? _ed_submit!(ed) : nothing
    end
    if b == 0x0a
        return _ed_submit!(ed)
    end
    if b == 0x01                   # Ctrl-A
        _ed_move!(ed, 1)
        return nothing
    elseif b == 0x05               # Ctrl-E
        _ed_move!(ed, length(ed.line) + 1)
        return nothing
    elseif b == 0x0b               # Ctrl-K: kill to end
        resize!(ed.line, ed.pos - 1)
        _ed_refresh!(ed)
        return nothing
    elseif b == 0x15               # Ctrl-U: kill to start
        deleteat!(ed.line, 1:(ed.pos - 1))
        ed.pos = 1
        _ed_refresh!(ed)
        return nothing
    elseif b == 0x17               # Ctrl-W: kill the previous word
        i = ed.pos - 1
        while i >= 1 && ed.line[i] == ' '
            i -= 1
        end
        while i >= 1 && ed.line[i] != ' '
            i -= 1
        end
        deleteat!(ed.line, (i + 1):(ed.pos - 1))
        ed.pos = i + 1
        _ed_refresh!(ed)
        return nothing
    end
    if b < 0x20
        return nothing              # other control bytes are ignored
    end
    # A printable byte: assemble a whole UTF-8 character before inserting it.
    push!(ed.utf8, b)
    need = _utf8_len(ed.utf8[1])
    if length(ed.utf8) < need
        return nothing
    end
    bytes = copy(ed.utf8)
    empty!(ed.utf8)
    c = try
        only(collect(String(bytes)))
    catch
        '�'
    end
    _ed_insert!(ed, c)
    return nothing
end

# ---- the REPL ----------------------------------------------------------------

# Read whatever is available from the channel without blocking: `nothing` when
# there is no data yet, or the bytes when there are some. Throws when the
# channel closed.
function _ssh_read_available!(chan::Ptr{Cvoid}, buf::Vector{UInt8})
    n = _ls_channel_read_nonblocking(chan, pointer(buf), length(buf))
    n > 0 && return buf[1:Int(n)]
    n == SSH_ERROR && throw(SshError("the session channel closed"))
    return nothing
end

# Service any channel-level messages (a window change gives the session new
# dimensions). Runs in non-blocking mode; returns the new `(width, height)` or
# `nothing`. A dimension the client did not report is `0`.
function _ssh_poll_channel!(session::Ptr{Cvoid}, cols::Int, rows::Int = 24)
    newsize = nothing
    while true
        m = _ls_message_get(session)
        m == C_NULL && break
        try
            if _ls_message_type(m) == SSH_REQUEST_CHANNEL &&
               _ls_message_subtype(m) == SSH_CHANNEL_REQUEST_WINDOW_CHANGE
                w = Int(_ls_channel_request_pty_width(m))
                h = Int(_ls_channel_request_pty_height(m))
                (w > 0 || h > 0) && (newsize = (max(w, 0), max(h, 0)))
                _ls_channel_request_reply_success(m)
            else
                _ls_message_reply_default(m)
            end
        finally
            _ls_message_free(m)
        end
    end
    return newsize
end

"""
    _ssh_repl!(env, server, session, chan, out; cols=80, rows=24, tty=false)

Run the remote REPL on `chan` until the client disconnects, sends Ctrl-D on an
empty line, a form calls `(exit)`, or the server closes. `out` is the session's
channel writer and the sink the caller installed in the session context, so
`(print …)` reaches the client too.
"""
function _ssh_repl!(env::Env, server::_SshServer, session::Ptr{Cvoid},
                    chan::Ptr{Cvoid}, out::_SshChannelIO;
                    cols::Int = 80, rows::Int = 24, tty::Bool = false)
    ed = _LineEditor(out, tty)
    pend = String[]
    input = Vector{UInt8}(undef, 4096)
    _ed_prompt!(ed, "air> ")
    while !server.closed
        newsize = try
            _ssh_poll_channel!(session, cols, rows)
        catch
            return nothing
        end
        if newsize !== nothing
            newsize[1] > 0 && (cols = newsize[1])
            newsize[2] > 0 && (rows = newsize[2])
            out.cols[] = cols
            out.rows[] = rows
        end
        data = try
            _ssh_read_available!(chan, input)
        catch e
            e isa SshError && return nothing
            rethrow()
        end
        if data === nothing
            _ls_channel_is_eof(chan) && return nothing
            sleep(0.01)
            continue
        end
        i = 1
        while i <= length(data)
            b = data[i]
            i += 1
            r = _ed_feed!(ed, b)
            r === nothing && continue
            if r[1] === :eof
                return nothing
            elseif r[1] === :interrupt
                empty!(pend)
                _ssh_eval_line!(env, out, "(raise :ctrl-c)"; cols)
                _ed_prompt!(ed, "air> ")
                continue
            end
            push!(pend, r[2])
            src = join(pend, "\n")
            status, val = _read_complete(src)
            if status === :error && _is_incomplete(val)
                _ed_prompt!(ed, "...> ")
                continue
            end
            empty!(pend)
            if status === :error
                println(out, "error: ", sprint(showerror, val))
                _ed_prompt!(ed, "air> ")
                continue
            end
            # Bytes typed after this line belong to the form being evaluated: a
            # `(ui-show …)` renderer consumes them as keys.
            if i <= length(data)
                append!(out.pending, data[i:end])
                i = length(data) + 1
            end
            for x in val
                if !_ssh_eval_form!(env, out, x; cols)
                    return nothing
                end
            end
            # Whatever the form did not consume is ordinary input again.
            if !isempty(out.pending)
                extra = copy(out.pending)
                empty!(out.pending)
                data = vcat(extra, data[i:end])
                i = 1
            end
            _ed_prompt!(ed, "air> ")
        end
    end
    return nothing
end

# Evaluate one input line exactly as the local REPL does. `(exit)` ends the
# session (returns `false` to the loop).
function _ssh_eval_line!(env::Env, out::IO, src::AbstractString; cols::Int = 80)
    status, val = _read_complete(src)
    status === :error &&
        (println(out, "error: ", sprint(showerror, val)); return true)
    for x in val
        _ssh_eval_form!(env, out, x; cols) || return false
    end
    return true
end

# Evaluate one form and print its result (or its error). Returns `false` when the
# form called `(exit)`.
function _ssh_eval_form!(env::Env, out::IO, x::Form; cols::Int = 80)
    try
        r = air_eval(env, x)
        println(out, air_pretty_string(env, r; width = cols))
        return true
    catch e
        e isa ExitSignal && return false
        e isa InterruptException && rethrow()
        # A session survives any failure in an evaluated form.
        println(out, "error: ", sprint(showerror, e))
        return true
    end
end
