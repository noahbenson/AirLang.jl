################################################################################
# ui/code.jl
#
# Code awareness for the text editor: a small scanner over air source that
# yields tokens with positions and paren depth, the automatic indentation rule
# derived from the form's layout, bracket pairing, and the closure verdict from
# the reader.
#
# The scanner is deliberately its own thing rather than the reader: it must work
# on *incomplete* input (a half-typed form, an unterminated string) and report
# where things are, which the reader does not. Like the reader it colors
# comments out of the token stream and understands strings, raw strings, regex
# literals, and nested `#| … |#` comments.
#
# Indentation is not a guess: it reuses the same layout table the pretty printer
# uses. A form whose head has a layout breaks its continuation lines at
# `col + indent` (or at the align column); any other form continues at `col + 1`.
# See ui/code.jl's `_ui_indent_at` and `src/layouts.jl`'s `_lo_inner`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- scanning ----------------------------------------------------------------

struct _CodeTok
    kind::Symbol      # :open :close :pipe :atom :string :comment
    start::Int        # 1-based character index of the first character
    stop::Int         # 1-based character index of the last character
    text::String      # the source text of the token
    depth::Int        # paren depth before the token (:close: after it)
    err::Bool         # an unterminated string or comment
end

_code_delim(c::Char) = c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
                       c == ',' || c == '(' || c == ')' || c == '|' ||
                       c == '#' || c == '"'

_ascii_letter(c::Char) = ('a' <= c <= 'z') || ('A' <= c <= 'Z')

# Whether the atom just before a `"` makes the string raw (no escape handling).
function _code_raw_prefix(prev::Union{Nothing,_CodeTok})
    prev === nothing && return false
    prev.kind === :atom || return false
    t = prev.text
    return t == "raw" || t == "big" || t == "r" || endswith(t, "=raw") ||
           endswith(t, "=big") || endswith(t, "=r") || t == "'raw" || t == "'big" ||
           t == "'r"
end

# The closing quote style a `"` at `i` opens: true when it is `"""`.
_code_triple(cs, i::Int) =
    i + 2 <= length(cs) && cs[i + 1] == '"' && cs[i + 2] == '"'

# Scan a string starting at `i` (the opening quote); returns the index just past
# it and whether the string was terminated.
function _code_scan_string(cs, i::Int, raw::Bool)
    n = length(cs)
    triple = _code_triple(cs, i)
    j = i + (triple ? 3 : 1)
    while j <= n
        if cs[j] == '\\' && !raw
            j += 2
            continue
        elseif triple && j + 2 <= n && cs[j] == '"' && cs[j + 1] == '"' &&
               cs[j + 2] == '"'
            return (j + 3, true)
        elseif !triple && cs[j] == '"'
            return (j + 1, true)
        end
        j += 1
    end
    return (n + 1, false)
end

# Skip a block comment starting at `i` (the `#`); returns the index just past it
# and whether it closed.
function _code_scan_block_comment(cs, i::Int)
    n = length(cs)
    depth = 1
    j = i + 2
    while j <= n
        if j + 1 <= n && cs[j] == '#' && cs[j + 1] == '|'
            depth += 1
            j += 2
        elseif j + 1 <= n && cs[j] == '|' && cs[j + 1] == '#'
            depth -= 1
            j += 2
            depth == 0 && return (j, true)
        else
            j += 1
        end
    end
    return (n + 1, false)
end

"""
    _code_scan(s) -> Vector{_CodeTok}

Tokenize air source tolerantly. Positions are character indices into `s`;
whitespace and commas are dropped, comments are kept (so a highlighter can paint
them), and an unterminated string or block comment becomes a token marked
`err`.
"""
function _code_scan(s::AbstractString)
    return _code_scan_cs(collect(s))
end

function _code_scan_cs(cs::Vector{Char})
    toks = _CodeTok[]
    prev = nothing
    depth = 0
    i = 1
    n = length(cs)
    while i <= n
        c = cs[i]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ','
            i += 1
        elseif c == '#' && i < n && cs[i + 1] == '|'
            (j, ok) = _code_scan_block_comment(cs, i)
            t = _CodeTok(:comment, i, min(j - 1, n), String(cs[i:min(j - 1, n)]),
                         depth, !ok)
            push!(toks, t); prev = t; i = j
        elseif c == '#'
            j = i
            while j <= n && cs[j] != '\n'
                j += 1
            end
            t = _CodeTok(:comment, i, j - 1, String(cs[i:j-1]), depth, false)
            push!(toks, t); prev = t; i = j
        elseif c == '('
            push!(toks, _CodeTok(:open, i, i, "(", depth, false))
            prev = toks[end]
            depth += 1
            i += 1
        elseif c == ')'
            bad = depth == 0            # a closer with no opener
            depth = max(depth - 1, 0)
            push!(toks, _CodeTok(:close, i, i, ")", depth, bad))
            prev = toks[end]
            i += 1
        elseif c == '|'
            push!(toks, _CodeTok(:pipe, i, i, "|", depth, false))
            prev = toks[end]
            i += 1
        elseif c == '"'
            raw = _code_raw_prefix(prev)
            # A raw-string or regex prefix belongs to the literal: `raw"…"` and
            # `r"…"` are one token, not an atom followed by a string.
            merged = raw && prev !== nothing && prev.kind === :atom &&
                     prev.stop + 1 == i
            start = merged ? prev.start : i
            (j, ok) = _code_scan_string(cs, i, raw)
            t = _CodeTok(:string, start, min(j - 1, n),
                         String(cs[start:min(j - 1, n)]), depth, !ok)
            merged && !isempty(toks) && pop!(toks)
            push!(toks, t); prev = t; i = j
        else
            start = i
            while i <= n && !_code_delim(cs[i])
                i += 1
            end
            t = _CodeTok(:atom, start, i - 1, String(cs[start:i-1]), depth, false)
            push!(toks, t); prev = t
        end
    end
    return toks
end

# ---- positions ---------------------------------------------------------------

# The 0-based display column of character index `idx` within its line.
function _code_col(cs::Vector{Char}, idx::Int)
    k = idx - 1
    while k >= 1 && cs[k] != '\n'
        k -= 1
    end
    return textwidth(String(cs[k+1:idx-1]))
end

# The 1-based (row, col) of character index `idx`; `col` is a character offset.
function _code_rowcol(cs::Vector{Char}, idx::Int)
    row = 1
    last = 0
    for k in 1:min(idx - 1, length(cs))
        if cs[k] == '\n'
            row += 1
            last = k
        end
    end
    return (row, idx - 1 - last)
end

# ---- elements of a container -------------------------------------------------

# The source spellings of the sequence elements of the container opened at token
# `oi`: a bare atom or string is one element, and a parenthesized run is one
# element cut at its matching close (or at the end of the scanned text).
function _code_elements(cs::Vector{Char}, toks::Vector{_CodeTok}, oi::Int)
    els = String[]
    i = oi + 1
    n = length(toks)
    while i <= n
        t = toks[i]
        if t.kind === :close
            break
        elseif t.kind === :open
            j = i + 1
            while j <= n && !(toks[j].kind === :close && toks[j].depth == t.depth)
                j += 1
            end
            stopidx = j <= n ? toks[j].stop : length(cs)
            push!(els, String(cs[t.start:min(stopidx, length(cs))]))
            i = j + 1
        elseif t.kind === :atom || t.kind === :string
            push!(els, t.text)
            i += 1
        else
            i += 1
        end
    end
    return els
end

# The layout key an element spelling names: a plain atom, else `nothing`.
function _code_head_symbol(text::AbstractString)
    isempty(text) && return nothing
    _ascii_letter(text[1]) || text[1] == '_' || return nothing
    for c in text
        (_ascii_letter(c) || ('0' <= c <= '9') || c == '-' || c == '_' ||
         c == '!' || c == '?' || c == '<' || c == '>' || c == '=' ||
         c == '*' || c == '+' || c == '/' || c == '.' || c == '&') ||
            return nothing
    end
    return Symbol(text)
end

# ---- indentation -------------------------------------------------------------

# The stack of unclosed openers in a token list, innermost last.
function _code_open_stack(toks::Vector{_CodeTok})
    stack = Int[]
    for (i, t) in enumerate(toks)
        if t.kind === :open
            push!(stack, i)
        elseif t.kind === :close && !isempty(stack)
            pop!(stack)
        end
    end
    return stack
end

"""
    _ui_indent_at(s) -> Int

The column a new line should start at when the user presses Enter with the
cursor at the end of `s`. The innermost unclosed container decides: a form whose
head has a layout continues at the layout's continuation column, computed from
the column of its opening parenthesis (with pinned head elements aligned when
the layout says `align`); any other open form continues one column past its
opener; with nothing open, the column is 0.
"""
function _ui_indent_at(s::AbstractString)
    cs = collect(s)
    toks = _code_scan_cs(cs)
    stack = _code_open_stack(toks)
    isempty(stack) && return 0
    oi = stack[end]
    o = toks[oi]
    col = _code_col(cs, o.start)
    els = _code_elements(cs, toks, oi)
    isempty(els) && return col + 1
    hs = _code_head_symbol(els[1])
    hs === nothing && return col + 1
    spec = _layout_head(hs)
    spec === nothing && return col + 1
    heads = els[1:min(spec.head, length(els))]
    return _lo_inner(spec, col, _lo_aligncol(col, heads))
end

# The canonical indentation of every line of `text`, by the same rule a newline
# uses: the innermost open form decides. A line whose first non-blank character
# is a closer instead takes the innermost opener's column, which is where that
# closer belongs. Line 1 is always column 0.
function _ui_indent_lines(text::AbstractString)
    lines = split(String(text), '\n'; keepempty = true)
    out = Int[0]
    prefix = String(lines[1])
    for i in 2:length(lines)
        line = lines[i]
        k = 1
        while k <= length(line) && (line[k] == ' ' || line[k] == '\t')
            k += 1
        end
        if k <= length(line) && line[k] == ')'
            col = _ui_opener_col(prefix)
            push!(out, col === nothing ? 0 : col)
        else
            push!(out, _ui_indent_at(prefix))
        end
        prefix = prefix * "\n" * line
    end
    return out
end

# The lines of `text` whose leading text is inside a string or block comment.
# Reindentation must not touch these: their whitespace is content, not layout.
function _ui_protected_lines(text::AbstractString)
    cs = collect(String(text))
    n = 0
    for c in cs
        c == '\n' && (n += 1)
    end
    protected = falses(n + 1)
    for t in _code_scan_cs(cs)
        (t.kind === :string || t.kind === :comment) || continue
        (r0, _) = _code_rowcol(cs, t.start)
        (r1, _) = _code_rowcol(cs, min(t.stop, length(cs)))
        for r in r0:r1
            protected[r] = true
        end
    end
    return protected
end

# The innermost unclosed opener's column, for dedenting a typed closer.
function _ui_opener_col(s::AbstractString)
    cs = collect(s)
    toks = _code_scan_cs(cs)
    stack = _code_open_stack(toks)
    isempty(stack) && return nothing
    return _code_col(cs, toks[stack[end]].start)
end

# How many forms' worth of openers are unclosed (the status line's counter).
function _ui_open_count(s::AbstractString)
    return length(_code_open_stack(_code_scan(s)))
end

# ---- lexical context at the cursor ------------------------------------------

# The kind of token the cursor sits inside (`:string`, `:comment`), or `nothing`.
function _ui_at_context(s::AbstractString, pos::Int)
    cs = collect(s)
    pos = clamp(pos, 1, length(cs) + 1)
    for t in _code_scan_cs(cs)
        if (t.kind === :string || t.kind === :comment) &&
           t.start < pos <= (t.err ? length(cs) : t.stop)
            return t.kind
        end
    end
    return nothing
end

# ---- bracket matching --------------------------------------------------------

"""
    _ui_bracket_match(text, idx) -> Union{Nothing,Tuple{Symbol,Int}}

The bracket token at 1-based character index `idx` of `text` and the index of
the token that matches it: `(:open, i)` for an opener (the closer is at `i`),
`(:close, i)` for a closer (the opener is at `i`), or `nothing` when `idx` is
not a bracket or the bracket has no partner. Only real parens count — one in a
string or a comment is text, not structure.
"""
function _ui_bracket_match(text::AbstractString, idx::Int)
    cs = collect(String(text))
    (1 <= idx <= length(cs)) || return nothing
    (cs[idx] == '(' || cs[idx] == ')') || return nothing
    toks = _code_scan_cs(cs)
    ti = findfirst(t -> (t.kind === :open || t.kind === :close) &&
                        t.start == idx, toks)
    ti === nothing && return nothing
    t = toks[ti]
    if t.kind === :open
        for j in (ti + 1):length(toks)
            if toks[j].kind === :close && toks[j].depth == t.depth
                return (:open, toks[j].start)
            end
        end
    else
        for j in (ti - 1):-1:1
            if toks[j].kind === :open && toks[j].depth == t.depth
                return (:close, toks[j].start)
            end
        end
    end
    return nothing
end

# ---- the form around the cursor ----------------------------------------------

"""
    _ui_form_span(text, pos) -> Union{Nothing,Tuple{Int,Int}}

The character span of the innermost form that contains character position
`pos` (1-based, the cursor's position in `_tb_text`): the opener's index through
its matching closer's index, or through the end of the text when the form is
unterminated. `nothing` when the cursor is not inside a form.
"""
function _ui_form_span(text::AbstractString, pos::Int)
    cs = collect(String(text))
    pos = clamp(pos, 1, length(cs) + 1)
    toks = _code_scan_cs(cs)
    stack = Int[]
    for (i, t) in enumerate(toks)
        t.start >= pos && break
        if t.kind === :open
            push!(stack, i)
        elseif t.kind === :close && !isempty(stack)
            pop!(stack)
        end
    end
    isempty(stack) && return nothing
    oi = stack[end]
    o = toks[oi]
    stopidx = length(cs)
    for j in (oi + 1):length(toks)
        t = toks[j]
        if t.kind === :close && t.depth == o.depth
            stopidx = t.start
            break
        end
    end
    return (o.start, stopidx)
end

"""
    _ui_form_segments(text, span) -> Vector{Tuple{Int,Int,Int}}

The parts of a form span on each line it touches, as `(row, startcol, stopcol)`
with 0-based display columns and an exclusive stop. Empty when the span is
empty.
"""
function _ui_form_segments(text::AbstractString, span::Tuple{Int,Int})
    cs = collect(String(text))
    starts = Int[1]
    for (i, c) in enumerate(cs)
        c == '\n' && push!(starts, i + 1)
    end
    (a, b) = span
    segs = Tuple{Int,Int,Int}[]
    for ln in 1:length(starts)
        lo = starts[ln]
        hi = ln < length(starts) ? starts[ln + 1] - 2 : length(cs)
        hi < lo && continue
        s = max(a, lo)
        e = min(b, hi)
        s > e && continue
        c0 = textwidth(String(cs[lo:(s - 1)]))
        c1 = textwidth(String(cs[lo:e]))
        push!(segs, (ln, c0, c1))
    end
    return segs
end

# ---- line comments -----------------------------------------------------------

# The 0-based column of the `#` that starts a line comment (the first non-blank
# character is `#`, and it does not open a `#| … |#` block), or `nothing`.
function _ui_line_comment_col(line::Vector{Char})
    k = 0
    while k < length(line) && (line[k + 1] == ' ' || line[k + 1] == '\t')
        k += 1
    end
    k < length(line) || return nothing
    line[k + 1] == '#' || return nothing
    (k + 2 <= length(line) && line[k + 2] == '|') && return nothing
    return k
end

# Comment or uncomment every non-blank line in `rows`, keeping the cursor and
# selection on the character they were on. Returns `(commented, n)`: whether the
# lines are now commented, and how many were changed.
function _ui_toggle_comment!(b::_TextBuffer, rows::UnitRange{Int})
    content = [r for r in rows if !_tb_line_blank(b, r)]
    isempty(content) && return (false, 0)
    commented = all(r -> _ui_line_comment_col(b.lines[r]) !== nothing, content)
    _tb_snapshot!(b)
    for r in content
        line = b.lines[r]
        k = _ui_line_comment_col(line)
        if commented
            # Drop the marker and the space a toggle normally leaves after it.
            n = (k + 2 <= length(line) && line[k + 2] == ' ') ? 2 : 1
            deleteat!(line, (k + 1):(k + n))
            shift = c -> c <= k ? c : max(k, c - n)
        else
            k = 0
            while k < length(line) && (line[k + 1] == ' ' || line[k + 1] == '\t')
                k += 1
            end
            insert!(line, k + 1, ' ')
            insert!(line, k + 1, '#')
            shift = c -> c <= k ? c : c + 2
        end
        if r == b.row
            b.col = shift(b.col)
        end
        if b.anchor !== nothing && b.anchor[1] == r
            b.anchor = (r, shift(b.anchor[2]))
        end
    end
    b.goal = -1
    return (commented, length(content))
end

# ---- closure -----------------------------------------------------------------

"""
    _ui_closure(text) -> (:ok, forms) | (:incomplete, msg) | (:error, msg)

Whether `text` is a run of complete forms. `:incomplete` means more input could
fix it (an unclosed form, string, or comment); `:error` is a genuine parse
error. A cell refuses to run unless the verdict is `:ok`.
"""
function _ui_closure(text::AbstractString)
    status, r = _read_complete(text)
    status === :ok && return (:ok, r)
    _is_incomplete(r) && return (:incomplete, r.msg)
    return (:error, r.msg)
end

_ui_closed(text::AbstractString) = _ui_closure(text)[1] === :ok

function _ui_closure_message(text::AbstractString)
    v = _ui_closure(text)
    v[1] === :ok && return ""
    return v[1] === :incomplete ? "unclosed: " * v[2] : "error: " * v[2]
end

# ---- pairing -----------------------------------------------------------------

# The closer for an opener the editor auto-inserts, or `nothing`.
_ui_pair_closer(c::Char) = c == '(' ? ')' : c == '"' ? '"' : nothing

# The opener an auto-inserted closer belongs to.
_ui_pair_opener(c::Char) = c == ')' ? '(' : c == '"' ? '"' : nothing

# The character at `(row, col)` of the buffer (0-based column), or `nothing`.
function _tb_char_at(b::_TextBuffer, row::Int, col::Int)
    (1 <= row <= length(b.lines)) || return nothing
    line = b.lines[row]
    (0 <= col < length(line)) || return nothing
    return line[col+1]
end

# The character just before the cursor, or `nothing`.
function _tb_char_before(b::_TextBuffer)
    return _tb_char_at(b, b.row, b.col - 1)
end
