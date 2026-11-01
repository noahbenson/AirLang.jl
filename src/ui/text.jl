################################################################################
# ui/text.jl
#
# The one editable-text implementation. A `_TextBuffer` is a sequence of lines,
# a cursor, an optional selection anchor, an undo/redo history, and a kill
# buffer. Everything that edits text — a code block, a notebook cell, the
# definition editor, the chat draft — is a buffer plus a policy for how keys map
# onto these operations.
#
# The buffer knows nothing about air syntax. Auto-indentation lives in
# ui/code.jl and is applied by the widget at the moment it inserts a newline, so
# the buffer stays a plain text model.
#
# Columns are 0-based character counts (`col` is the number of characters before
# the cursor); rows are 1-based. A buffer always has at least one line.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _TB_MAX_UNDO = 100

mutable struct _TextBuffer
    lines::Vector{Vector{Char}}
    row::Int
    col::Int
    anchor::Union{Nothing,Tuple{Int,Int}}   # selection anchor (row, col)
    goal::Int                                # desired column; -1 when unset
    undo::Vector{Any}
    redo::Vector{Any}
    kill::String
end

_TextBuffer() = _TextBuffer([Char[]], 1, 0, nothing, -1, Any[], Any[], "")

function _TextBuffer(s::AbstractString)
    b = _TextBuffer()
    _tb_set_text!(b, s)
    return b
end

# ---- text --------------------------------------------------------------------

_tb_nlines(b::_TextBuffer) = length(b.lines)

_tb_line(b::_TextBuffer, i::Int) = String(b.lines[clamp(i, 1, length(b.lines))])

_tb_text(b::_TextBuffer) = join((String(l) for l in b.lines), "\n")

# Replace every line; the cursor goes to the start and the history is kept.
function _tb_set_text!(b::_TextBuffer, s::AbstractString)
    parts = split(String(s), '\n'; keepempty = true)
    b.lines = [collect(p) for p in parts]
    isempty(b.lines) && (b.lines = [Char[]])
    b.row = 1
    b.col = 0
    b.anchor = nothing
    b.goal = -1
    return b
end

# The text of the current line and the cursor's position in it.
_tb_curline(b::_TextBuffer) = b.lines[b.row]
_tb_linelen(b::_TextBuffer) = length(b.lines[b.row])

# ---- history -----------------------------------------------------------------

function _tb_snapshot!(b::_TextBuffer)
    push!(b.undo, ([copy(l) for l in b.lines], b.row, b.col))
    length(b.undo) > _TB_MAX_UNDO && popfirst!(b.undo)
    empty!(b.redo)
    return nothing
end

function _tb_restore!(b::_TextBuffer, snap)
    (b.lines, b.row, b.col) = ([copy(l) for l in snap[1]], snap[2], snap[3])
    b.anchor = nothing
    b.goal = -1
    return nothing
end

function _tb_undo!(b::_TextBuffer)
    isempty(b.undo) && return false
    push!(b.redo, ([copy(l) for l in b.lines], b.row, b.col))
    _tb_restore!(b, pop!(b.undo))
    return true
end

function _tb_redo!(b::_TextBuffer)
    isempty(b.redo) && return false
    push!(b.undo, ([copy(l) for l in b.lines], b.row, b.col))
    _tb_restore!(b, pop!(b.redo))
    return true
end

# ---- selection ---------------------------------------------------------------

# The selection as `((row, col), (row, col))` with the earlier position first.
function _tb_selection(b::_TextBuffer)
    b.anchor === nothing && return nothing
    a = b.anchor
    c = (b.row, b.col)
    a == c && return nothing
    return (a < c) ? (a, c) : (c, a)
end

_tb_has_selection(b::_TextBuffer) = _tb_selection(b) !== nothing

# Start, extend, or clear a selection. `keep` is the caller's Shift state.
function _tb_anchor!(b::_TextBuffer, keep::Bool)
    if keep
        b.anchor === nothing && (b.anchor = (b.row, b.col))
    else
        b.anchor = nothing
    end
    return nothing
end

# The selected text (empty when there is no selection).
function _tb_selected_text(b::_TextBuffer)
    sel = _tb_selection(b)
    sel === nothing && return ""
    (a, c) = sel
    if a[1] == c[1]
        return String(b.lines[a[1]][a[2]+1:c[2]])
    end
    parts = String[String(b.lines[a[1]][a[2]+1:end])]
    for r in (a[1] + 1):(c[1] - 1)
        push!(parts, String(b.lines[r]))
    end
    push!(parts, String(b.lines[c[1]][1:c[2]]))
    return join(parts, "\n")
end

function _tb_select_all!(b::_TextBuffer)
    b.anchor = (1, 0)
    b.row = length(b.lines)
    b.col = length(b.lines[b.row])
    b.goal = -1
    return nothing
end

# Delete the selected range; returns whether anything was deleted.
function _tb_delete_selection!(b::_TextBuffer)
    sel = _tb_selection(b)
    sel === nothing && return false
    (a, c) = sel
    head = b.lines[a[1]][1:a[2]]
    tail = b.lines[c[1]][c[2]+1:end]
    b.lines[a[1]] = vcat(head, tail)
    for r in c[1]:-1:(a[1] + 1)
        deleteat!(b.lines, r)
    end
    b.row = a[1]
    b.col = a[2]
    b.anchor = nothing
    b.goal = -1
    return true
end

# ---- insertion ---------------------------------------------------------------

# Insert text as one undoable edit. Newlines split lines.
function _tb_insert!(b::_TextBuffer, s::AbstractString)
    isempty(s) && return nothing
    _tb_snapshot!(b)
    _tb_delete_selection!(b)
    _tb_insert_raw!(b, s)
    return nothing
end

function _tb_insert_raw!(b::_TextBuffer, s::AbstractString)
    for c in s
        if c == '\n'
            line = b.lines[b.row]
            tail = line[b.col+1:end]
            b.lines[b.row] = line[1:b.col]
            insert!(b.lines, b.row + 1, collect(tail))
            b.row += 1
            b.col = 0
        else
            insert!(b.lines[b.row], b.col + 1, c)
            b.col += 1
        end
    end
    b.goal = -1
    return nothing
end

# Insert one character, replacing the selection first.
function _tb_insert!(b::_TextBuffer, c::Char)
    _tb_insert!(b, string(c))
    return nothing
end

# Split the line at the cursor and start the new line with `indent` spaces.
function _tb_newline!(b::_TextBuffer, indent::Int)
    _tb_snapshot!(b)
    _tb_delete_selection!(b)
    _tb_newline_raw!(b, indent)
    return nothing
end

function _tb_newline_raw!(b::_TextBuffer, indent::Int)
    line = b.lines[b.row]
    tail = line[b.col+1:end]
    b.lines[b.row] = line[1:b.col]
    fresh = vcat(Char[' ' for _ in 1:max(indent, 0)], tail)
    insert!(b.lines, b.row + 1, fresh)
    b.row += 1
    b.col = min(indent, length(fresh))
    b.goal = -1
    return nothing
end

# ---- deletion ----------------------------------------------------------------

function _tb_backspace!(b::_TextBuffer)
    _tb_selection(b) !== nothing && (_tb_snapshot!(b);
                                    _tb_delete_selection!(b); return true)
    if b.col > 0
        _tb_snapshot!(b)
        deleteat!(b.lines[b.row], b.col)
        b.col -= 1
        b.goal = -1
        return true
    elseif b.row > 1
        _tb_snapshot!(b)
        prev = b.lines[b.row - 1]
        cur = b.lines[b.row]
        b.col = length(prev)
        b.lines[b.row - 1] = vcat(prev, cur)
        deleteat!(b.lines, b.row)
        b.row -= 1
        b.goal = -1
        return true
    end
    return false
end

function _tb_delete!(b::_TextBuffer)
    _tb_selection(b) !== nothing && (_tb_snapshot!(b);
                                    _tb_delete_selection!(b); return true)
    if b.col < length(b.lines[b.row])
        _tb_snapshot!(b)
        deleteat!(b.lines[b.row], b.col + 1)
        b.goal = -1
        return true
    elseif b.row < length(b.lines)
        _tb_snapshot!(b)
        b.lines[b.row] = vcat(b.lines[b.row], b.lines[b.row + 1])
        deleteat!(b.lines, b.row + 1)
        b.goal = -1
        return true
    end
    return false
end

# ---- motion ------------------------------------------------------------------

function _tb_move_h!(b::_TextBuffer, d::Int; select::Bool = false)
    _tb_anchor!(b, select)
    if d < 0
        for _ in 1:(-d)
            if b.col > 0
                b.col -= 1
            elseif b.row > 1
                b.row -= 1
                b.col = length(b.lines[b.row])
            end
        end
    else
        for _ in 1:d
            if b.col < length(b.lines[b.row])
                b.col += 1
            elseif b.row < length(b.lines)
                b.row += 1
                b.col = 0
            end
        end
    end
    select || (b.anchor = nothing)
    b.goal = -1
    return nothing
end

function _tb_move_v!(b::_TextBuffer, d::Int; select::Bool = false)
    _tb_anchor!(b, select)
    b.goal < 0 && (b.goal = b.col)
    b.row = clamp(b.row + d, 1, length(b.lines))
    b.col = min(b.goal, length(b.lines[b.row]))
    select || (b.anchor = nothing)
    return nothing
end

function _tb_home!(b::_TextBuffer; select::Bool = false)
    _tb_anchor!(b, select)
    # Home goes to the first non-blank character, then to column 0.
    first = findfirst(c -> c != ' ' && c != '\t', b.lines[b.row])
    target = first === nothing ? 0 : first - 1
    b.col = (b.col == target) ? 0 : target
    select || (b.anchor = nothing)
    b.goal = -1
    return nothing
end

function _tb_end!(b::_TextBuffer; select::Bool = false)
    _tb_anchor!(b, select)
    b.col = length(b.lines[b.row])
    select || (b.anchor = nothing)
    b.goal = -1
    return nothing
end

function _tb_buffer_home!(b::_TextBuffer; select::Bool = false)
    _tb_anchor!(b, select)
    b.row = 1
    b.col = 0
    select || (b.anchor = nothing)
    b.goal = -1
    return nothing
end

function _tb_buffer_end!(b::_TextBuffer; select::Bool = false)
    _tb_anchor!(b, select)
    b.row = length(b.lines)
    b.col = length(b.lines[b.row])
    select || (b.anchor = nothing)
    b.goal = -1
    return nothing
end

# Word characters: everything that is not whitespace or a delimiter.
_tb_word_char(c::Char) = !isspace(c) && !(c in ('(', ')', '[', ']', '{', '}',
                                              '|', ',', '"', ';'))

function _tb_word_left!(b::_TextBuffer; select::Bool = false)
    _tb_anchor!(b, select)
    # Back up over non-word characters, then over a word.
    while b.col > 0 && !_tb_word_char(b.lines[b.row][b.col])
        b.col -= 1
    end
    if b.col == 0 && b.row > 1
        b.row -= 1
        b.col = length(b.lines[b.row])
        while b.col > 0 && !_tb_word_char(b.lines[b.row][b.col])
            b.col -= 1
        end
    end
    while b.col > 0 && _tb_word_char(b.lines[b.row][b.col])
        b.col -= 1
    end
    select || (b.anchor = nothing)
    b.goal = -1
    return nothing
end

function _tb_word_right!(b::_TextBuffer; select::Bool = false)
    _tb_anchor!(b, select)
    n = length(b.lines[b.row])
    while b.col < n && !_tb_word_char(b.lines[b.row][b.col + 1])
        b.col += 1
    end
    if b.col == n && b.row < length(b.lines)
        b.row += 1
        b.col = 0
        while b.col < length(b.lines[b.row]) &&
              !_tb_word_char(b.lines[b.row][b.col + 1])
            b.col += 1
        end
    end
    while b.col < length(b.lines[b.row]) &&
          _tb_word_char(b.lines[b.row][b.col + 1])
        b.col += 1
    end
    select || (b.anchor = nothing)
    b.goal = -1
    return nothing
end

# ---- searching ---------------------------------------------------------------

# Every occurrence of `q` in one line, as 0-based start columns. The match is
# literal and case-sensitive, and never spans a line: a buffer search is a line
# search, so a match is always something the reader could have told you about
# within one row.
function _tb_line_find_all(line::Vector{Char}, q::Vector{Char})
    out = Int[]
    m = length(q)
    m == 0 && return out
    for i in 0:(length(line) - m)
        ok = true
        for j in 1:m
            if line[i + j] != q[j]
                ok = false
                break
            end
        end
        ok && push!(out, i)
    end
    return out
end

# Every occurrence of `q` in the buffer, in document order, as `(row, col)`
# pairs with a 0-based column.
function _tb_matches(b::_TextBuffer, q::AbstractString)
    out = Tuple{Int,Int}[]
    isempty(q) && return out
    qc = collect(q)
    for (r, line) in enumerate(b.lines)
        for c in _tb_line_find_all(line, qc)
            push!(out, (r, c))
        end
    end
    return out
end

# Put the cursor at `(row, col)` and, when `len > 0`, select the run of `len`
# characters that starts there (the cursor sits after it).
function _tb_place!(b::_TextBuffer, row::Int, col::Int, len::Int = 0)
    b.row = clamp(row, 1, length(b.lines))
    col = clamp(col, 0, length(b.lines[b.row]))
    b.col = col
    b.anchor = len > 0 ? (b.row, col) : nothing
    b.col = min(col + len, length(b.lines[b.row]))
    b.goal = -1
    return nothing
end

# ---- kill and yank -----------------------------------------------------------

function _tb_kill!(b::_TextBuffer, s::String)
    b.kill = s
    return nothing
end

# Ctrl-K: everything from the cursor to the end of the line.
function _tb_kill_line!(b::_TextBuffer)
    (sel = _tb_selection(b)) !== nothing && begin
        _tb_snapshot!(b)
        _tb_kill!(b, _tb_selected_text(b))
        _tb_delete_selection!(b)
        return nothing
    end
    _tb_snapshot!(b)
    line = b.lines[b.row]
    _tb_kill!(b, String(line[b.col+1:end]))
    b.lines[b.row] = line[1:b.col]
    b.goal = -1
    return nothing
end

# Ctrl-U: everything from the start of the line to the cursor.
function _tb_kill_start!(b::_TextBuffer)
    _tb_snapshot!(b)
    line = b.lines[b.row]
    _tb_kill!(b, String(line[1:b.col]))
    b.lines[b.row] = line[b.col+1:end]
    b.col = 0
    b.goal = -1
    return nothing
end

# Ctrl-W: the word before the cursor.
function _tb_kill_word!(b::_TextBuffer)
    _tb_snapshot!(b)
    line = b.lines[b.row]
    i = b.col
    while i > 0 && !_tb_word_char(line[i])
        i -= 1
    end
    while i > 0 && _tb_word_char(line[i])
        i -= 1
    end
    _tb_kill!(b, String(line[i+1:b.col]))
    b.lines[b.row] = vcat(line[1:i], line[b.col+1:end])
    b.col = i
    b.goal = -1
    return nothing
end

# Ctrl-Y: insert the kill buffer.
function _tb_yank!(b::_TextBuffer)
    isempty(b.kill) && return nothing
    _tb_insert!(b, b.kill)
    return nothing
end

# ---- indentation of a whole line --------------------------------------------

# Set the current line's leading whitespace to exactly `n` spaces, keeping the
# cursor on the same character where possible.
function _tb_reindent!(b::_TextBuffer, n::Int)
    line = b.lines[b.row]
    k = 0
    while k < length(line) && (line[k + 1] == ' ' || line[k + 1] == '\t')
        k += 1
    end
    n = max(n, 0)
    k == n && return false
    body = line[k+1:end]
    b.lines[b.row] = vcat(Char[' ' for _ in 1:n], body)
    b.col = clamp(b.col - k + n, 0, length(b.lines[b.row]))
    b.goal = -1
    return true
end

_tb_leading_spaces(b::_TextBuffer, row::Int = b.row) =
    (line = b.lines[row]; k = 0;
     while k < length(line) && line[k + 1] == ' '
         k += 1
     end; k)

_tb_line_blank(b::_TextBuffer, row::Int = b.row) =
    all(c -> c == ' ' || c == '\t', b.lines[row])

# ---- rendering helpers -------------------------------------------------------

# `(row, col)` for the cursor and for an anchor, in the order they appear.
_tb_cursor(b::_TextBuffer) = (b.row, b.col)

# Whether a row and column fall inside the selection.
function _tb_selected(b::_TextBuffer, row::Int, col::Int)
    sel = _tb_selection(b)
    sel === nothing && return false
    (a, c) = sel
    return a <= (row, col) < c
end

# The cursor's index if the selection is backwards (for reverse-highlighting the
# cursor cell), else `nothing`.
function _tb_reverse_cursor(b::_TextBuffer)
    sel = _tb_selection(b)
    sel === nothing && return nothing
    return (b.row, b.col) == sel[1]
end
