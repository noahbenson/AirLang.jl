################################################################################
# ui/highlight.jl
#
# Syntax coloring for air source. Highlighting is a pure function of the text
# and the theme: `_hl_lines` scans the buffer once and returns one styled span
# run per logical line. The scanner is ui/code.jl's (the same one auto-indent
# uses), so strings, raw strings, regex literals, and nested block comments are
# colored where the reader would treat them the same way, and the tokens are
# never re-lexed differently from the editor's own notion of structure.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# The style of an atom by its spelling.
function _hl_atom_role(text::AbstractString)
    isempty(text) && return :text
    c = text[1]
    c == ':' && return :keyword
    c == '?' && return :wildcard
    c == '\'' && return :text          # quote sugar keeps the symbol's color
    (('0' <= c <= '9') || ((c == '-' || c == '+') && length(text) > 1 &&
                           '0' <= text[2] <= '9')) && return :number
    text in ("true", "false", "naught", "Inf", "NaN") && return :keyword
    return :text
end

_hl_role_for(t::_CodeTok) =
    t.kind === :comment ? :comment :
    t.kind === :string ? :string :
    t.kind === :atom ? _hl_atom_role(t.text) :
    t.kind === :pipe ? :keyword :
    t.kind === :open ? Symbol("paren", string(t.depth % 4 + 1)) :
    t.kind === :close ? Symbol("paren", string(t.depth % 4 + 1)) : :text

_hl_style(t::_CodeTok) = t.err ? _ui_role(:error) : _ui_role(_hl_role_for(t))

# The 1-based character index at which each line starts.
function _hl_line_starts(cs::Vector{Char})
    starts = Int[1]
    for (i, c) in enumerate(cs)
        c == '\n' && push!(starts, i + 1)
    end
    return starts
end

"""
    _hl_lines(text) -> Vector{Vector{_UiSpan}}

One styled span run per logical line of `text` (a trailing newline yields a
final empty line, matching `split(text, '\\n')`).
"""
function _hl_lines(text::AbstractString)
    cs = collect(text)
    toks = _code_scan_cs(cs)
    starts = _hl_line_starts(cs)
    nlines = length(starts)
    out = Vector{_UiSpan}[]
    ti = 1
    for ln in 1:nlines
        a = starts[ln]
        b = ln < nlines ? starts[ln + 1] - 2 : length(cs)
        spans = _UiSpan[]
        pos = a
        # Skip tokens that ended before this line.
        while ti <= length(toks) && toks[ti].stop < a
            ti += 1
        end
        j = ti
        while j <= length(toks) && toks[j].start <= b
            t = toks[j]
            if t.start > pos
                push!(spans, _UiSpan(String(cs[pos:min(t.start - 1, b)])))
            end
            lo = max(t.start, a)
            hi = min(t.stop, b)
            if lo <= hi
                push!(spans, _UiSpan(String(cs[lo:hi]), _hl_style(t)))
            end
            pos = max(pos, t.stop + 1)
            j += 1
        end
        if b >= pos
            push!(spans, _UiSpan(String(cs[pos:b])))
        end
        push!(out, spans)
    end
    return out
end

# The flat text of a span run.
_hl_text(spans::Vector{_UiSpan}) = _ui_spans_text(spans)

# `spans` with the background role `:form_bg` applied to display columns
# `a`…`b` (exclusive stop), leaving every span's foreground and weights alone.
function _hl_tint(spans::Vector{_UiSpan}, a::Int, b::Int)
    b <= a && return spans
    (head, rest) = _ui_span_split(spans, max(a, 0))
    (mid, tail) = _ui_span_split(rest, b - a)
    isempty(mid) && return spans
    bg = _ui_role(:form_bg).bg
    tinted = [_UiSpan(s.text, _ui_style_with(s.style; bg = bg)) for s in mid]
    return vcat(head, tinted, tail)
end
