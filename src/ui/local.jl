################################################################################
# ui/local.jl
#
# The local terminal backend: the process's own stdin/stdout, made into a byte
# source the renderer can poll. It is the local counterpart of `_SshBackend`
# (ui/terminal.jl) and obeys the same contract (ui/term.jl): enter/leave the
# alternate screen, report a size, hand over available bytes, accept output.
#
# Unlike a channel, stdin has no non-blocking read of its own — `bytesavailable`
# on a TTY reports nothing — so a reader task blocks on `read(stdin, UInt8)` and
# parks the bytes in a channel that the renderer drains each tick. The task must
# *not* outlive the frame: a reader left behind would steal input from the REPL
# that resumes when the UI detaches. `schedule(t, InterruptException(); error=true)`
# is the one way to unblock a task parked on a TTY read, and the terminal is
# usable for ordinary reads again immediately afterwards.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

mutable struct _LocalBackend <: _TermBackend
    in::IO
    out::IO
    tty::Bool
    term::Any                       # a Base.Terminals.TTYTerminal when tty
    chan::Channel{UInt8}
    reader::Union{Nothing,Task}
    pushback::Vector{UInt8}
    cols::Int
    rows::Int
    entered::Bool
end

function _LocalBackend(; in::IO = stdin, out::IO = stdout, tty::Bool = false,
                       cols::Int = 80, rows::Int = 24)
    term = nothing
    if tty && in isa Base.TTY && out isa Base.TTY
        term = try
            Base.Terminals.TTYTerminal(get(ENV, "TERM", "xterm"), in, out, stderr)
        catch
            nothing
        end
    end
    return _LocalBackend(in, out, tty, term, Channel{UInt8}(65536), nothing,
                         UInt8[], cols, rows, false)
end

# Whether this backend can actually take over a terminal.
_loc_tty(b::_LocalBackend) = b.tty && b.term !== nothing

function _loc_start!(b::_LocalBackend)
    b.reader === nothing || return nothing
    io = b.in
    ch = b.chan
    b.reader = @async begin
        try
            while true
                put!(ch, read(io, UInt8))
            end
        catch e
            e isa InterruptException || e isa EOFError || e isa Base.IOError || nothing
        end
    end
    return nothing
end

function _loc_stop!(b::_LocalBackend)
    t = b.reader
    b.reader = nothing
    t === nothing && return nothing
    istaskdone(t) && return nothing
    try
        schedule(t, InterruptException(); error = true)
    catch
    end
    try
        wait(t)
    catch
    end
    return nothing
end

function _tb_enter!(b::_LocalBackend)
    _loc_tty(b) && try
        Base.Terminals.raw!(b.term, true)
    catch
    end
    _tb_enter_standard!(b)
    b.entered = true
    _loc_start!(b)
    return nothing
end

function _tb_leave!(b::_LocalBackend)
    _loc_stop!(b)
    _tb_leave_standard!(b)
    _loc_tty(b) && try
        Base.Terminals.raw!(b.term, false)
    catch
    end
    b.entered = false
    return nothing
end

_tb_close!(b::_LocalBackend) = _loc_stop!(b)

function _tb_drain!(b::_LocalBackend)
    out = UInt8[]
    if !isempty(b.pushback)
        append!(out, b.pushback)
        empty!(b.pushback)
    end
    while isready(b.chan)
        push!(out, take!(b.chan))
    end
    return out
end

function _tb_unread!(b::_LocalBackend, data)
    isempty(data) && return nothing
    b.pushback = vcat(Vector{UInt8}(data), b.pushback)
    return nothing
end

function _tb_size(b::_LocalBackend)
    if b.entered && b.out isa Base.TTY
        d = try
            displaysize(b.out)
        catch
            nothing
        end
        if d !== nothing && d[1] > 0 && d[2] > 0
            b.rows = d[1]
            b.cols = d[2]
        end
    end
    return (b.cols, b.rows)
end

function _tb_write(b::_LocalBackend, data)
    write(b.out, data)
    flush(b.out)
    return nothing
end
