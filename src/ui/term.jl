################################################################################
# ui/term.jl
#
# Terminal plumbing shared by the renderers: a byte backend (an SSH channel, the
# process's own terminal, or a scripted IO), the alternate-screen/raw-mode
# contract, and the frame writer. A backend knows only how to produce bytes,
# report its size, and accept output; everything about layout and keys lives in
# the renderer.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

abstract type _TermBackend end

_tb_enter!(b::_TermBackend) = nothing
_tb_leave!(b::_TermBackend) = nothing
_tb_close!(b::_TermBackend) = nothing
_tb_resize!(b::_TermBackend) = nothing
_tb_size(b::_TermBackend) = (80, 24)
_tb_drain!(b::_TermBackend) = UInt8[]
_tb_unread!(b::_TermBackend, data) = nothing
_tb_write(b::_TermBackend, data) = nothing

const _TERM_ENTER = "\e[?1049h\e[?25l\e[?2004h"
const _TERM_LEAVE = "\e[?2004l\e[?25h\e[?1049l"

# The standard enter/leave for a byte-channel backend (used by the SSH and
# stream backends; the local backend additionally changes the terminal mode).
function _tb_enter_standard!(b::_TermBackend)
    _tb_write(b, Vector{UInt8}(codeunits(_TERM_ENTER)))
    return nothing
end

function _tb_leave_standard!(b::_TermBackend)
    _tb_write(b, Vector{UInt8}(codeunits(_TERM_LEAVE)))
    return nothing
end

# ---- a scripted/directed backend --------------------------------------------

# An IO plus a one-byte read function and a size function. This is what the
# tests drive (`readbyte` over an IOBuffer) and what a plain pipe would use.
mutable struct _StreamBackend <: _TermBackend
    io::IO
    cols::Ref{Int}
    rows::Ref{Int}
    readbyte::Function
    resize::Function
    pushback::Vector{UInt8}
end

_StreamBackend(io::IO; cols::Ref{Int} = Ref(80), rows::Ref{Int} = Ref(24),
               readbyte::Function = () -> nothing,
               resize::Function = () -> nothing) =
    _StreamBackend(io, cols, rows, readbyte, resize, UInt8[])

_tb_size(b::_StreamBackend) = (b.cols[], b.rows[])
_tb_resize!(b::_StreamBackend) = b.resize()
_tb_write(b::_StreamBackend, data) = (write(b.io, data); flush(b.io); nothing)

function _tb_drain!(b::_StreamBackend)
    out = UInt8[]
    if !isempty(b.pushback)
        append!(out, b.pushback)
        empty!(b.pushback)
    end
    while true
        x = b.readbyte()
        x === nothing && break
        push!(out, x isa UInt8 ? x : UInt8(x))
    end
    return out
end

function _tb_unread!(b::_StreamBackend, data)
    isempty(data) && return nothing
    b.pushback = vcat(Vector{UInt8}(data), b.pushback)
    return nothing
end

_tb_enter!(b::_StreamBackend) = _tb_enter_standard!(b)
_tb_leave!(b::_StreamBackend) = _tb_leave_standard!(b)

# ---- the frame cache ---------------------------------------------------------

# What was last drawn on each screen row, so a redraw sends only the rows that
# changed. A full frame over SSH is a few kilobytes and a keystroke usually
# changes one row and the cursor, so the difference is what makes typing feel
# local on a slow link. The cache is positional: a row's payload is its styled
# text, and the row number is written when the payload changes.
mutable struct _FrameCache
    backend::_TermBackend
    rows::Dict{Int,String}
    width::Int
    height::Int
end

_FrameCache(b::_TermBackend) = _FrameCache(b, Dict{Int,String}(), 0, 0)

# Forget everything: call after entering the alternate screen or whenever a
# resize may have reflowed the screen from under us.
function _frame_reset!(f::_FrameCache)
    empty!(f.rows)
    f.width = 0
    f.height = 0
    return nothing
end

# Start a frame at this size; a size change invalidates every cached row.
function _frame_begin!(f::_FrameCache, width::Int, height::Int)
    if f.width != width || f.height != height
        empty!(f.rows)
        f.width = width
        f.height = height
    end
    return nothing
end

# Append row `row` to `io` if its payload differs from what is on screen.
# Returns true when the row was written.
function _frame_row!(f::_FrameCache, io::IO, row::Int, payload::AbstractString)
    row >= 1 || return false
    get(f.rows, row, nothing) == payload && return false
    f.rows[row] = String(payload)
    print(io, "\e[", row, ";1H\e[K", payload)
    return true
end

# ---- the frame writer --------------------------------------------------------

# The styled bytes for one line, clipped to `width` columns. A `reverse` line
# (the focused element) is wrapped in the classic `ESC[7m`/`ESC[0m` pair so the
# legacy focus look is preserved byte for byte.
function _term_line_bytes(l::_UiLine, width::Int; reverse::Bool = false)
    io = IOBuffer()
    if reverse
        print(io, "\e[7m")
        print(io, _ui_clip(l.text, width))
        print(io, "\e[0m")
        return take!(io)
    end
    spans = _ui_clip_spans(_ui_line_spans(l), width)
    st = _UI_PLAIN
    for s in spans
        if !_ui_style_eq(s.style, st)
            print(io, _ui_sgr(s.style))
            st = s.style
        end
        print(io, s.text)
    end
    !_ui_style_eq(st, _UI_PLAIN) && print(io, _UI_RESET)
    return take!(io)
end

# Write `rows` body lines starting at `row` (1-based), clearing each line and
# padding the screen below. Only rows whose content changed are written; the
# caller positions the cursor afterwards.
function _term_emit_body!(f::_FrameCache, lines::Vector{_UiLine}, width::Int,
                          rows::Int, top::Int; reversepath = nothing, row::Int = 1)
    io = IOBuffer()
    for i in 1:rows
        j = top + i - 1
        payload = ""
        if j <= length(lines)
            l = lines[j]
            rev = reversepath !== nothing && l.node !== nothing &&
                  l.node.path == reversepath
            payload = String(_term_line_bytes(l, width - 1; reverse = rev))
        end
        _frame_row!(f, io, row + i - 1, payload)
    end
    data = take!(io)
    isempty(data) || _tb_write(f.backend, data)
    return nothing
end

# A single line at `row` (1-based), clearing to the end of the line.
function _term_emit_row!(f::_FrameCache, row::Int, line::_UiLine, width::Int,
                         st::_UiStyle = _UI_PLAIN)
    io = IOBuffer()
    spans = _ui_clip_spans(_ui_line_spans(line), width - 1)
    print(io, _ui_sgr(st))
    for s in spans
        print(io, s.text)
    end
    print(io, _UI_RESET)
    payload = String(take!(io))
    out = IOBuffer()
    _frame_row!(f, out, row, payload)
    data = take!(out)
    isempty(data) || _tb_write(f.backend, data)
    return nothing
end

function _term_move!(b::_TermBackend, row::Int, col::Int; visible::Bool = true)
    io = IOBuffer()
    print(io, "\e[", max(row, 1), ";", max(col, 1), "H")
    print(io, visible ? "\e[?25h" : "\e[?25l")
    _tb_write(b, take!(io))
    return nothing
end

# The visible column of a character index within a line (1-based).
function _term_col_of(line::AbstractString, index::Int)
    idx = clamp(index, 1, length(line) + 1)
    return textwidth(String(collect(line)[1:idx-1])) + 1
end
