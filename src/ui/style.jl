################################################################################
# ui/style.jl
#
# Attributed text. A `_UiStyle` is a foreground color, a background color, and
# a handful of attributes; a `_UiSpan` is a run of text carrying one. The
# renderers turn styles into ANSI SGR at draw time, so nothing in a widget
# spells an escape sequence and the whole palette can be recolored at run time.
#
# Colors are ANSI-16 names plus `:colorN` (xterm 256) and `:rgbHHHHHH`; the
# theme maps semantic roles (`:string`, `:comment`, `:user-bg`, …) to styles,
# and widgets name roles rather than colors. See ui/theme.jl.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    _UiStyle(fg, bg, bold, dim, italic, underline, reverse)

One attributed run's style. `fg`/`bg` are `:default`, an ANSI-16 name
(`:black`, `:red`, `:bright-blue`, …), `:colorN`, or `:rgbHHHHHH`.
"""
struct _UiStyle
    fg::Symbol
    bg::Symbol
    bold::Bool
    dim::Bool
    italic::Bool
    underline::Bool
    reverse::Bool
end

_UiStyle(; fg::Symbol = :default, bg::Symbol = :default, bold::Bool = false,
         dim::Bool = false, italic::Bool = false, underline::Bool = false,
         reverse::Bool = false) =
    _UiStyle(fg, bg, bold, dim, italic, underline, reverse)

const _UI_PLAIN = _UiStyle()

"""
    _UiSpan(text, style)

A run of text and the style it renders with.
"""
struct _UiSpan
    text::String
    style::_UiStyle
end

_UiSpan(text::AbstractString) = _UiSpan(String(text), _UI_PLAIN)

# A style like `st` with fields replaced; `nothing` keeps a field.
function _ui_style_with(st::_UiStyle; fg = nothing, bg = nothing, bold = nothing,
                        dim = nothing, italic = nothing, underline = nothing,
                        reverse = nothing)
    return _UiStyle(fg === nothing ? st.fg : Symbol(fg),
                    bg === nothing ? st.bg : Symbol(bg),
                    bold === nothing ? st.bold : Bool(bold),
                    dim === nothing ? st.dim : Bool(dim),
                    italic === nothing ? st.italic : Bool(italic),
                    underline === nothing ? st.underline : Bool(underline),
                    reverse === nothing ? st.reverse : Bool(reverse))
end

_ui_style_eq(a::_UiStyle, b::_UiStyle) = a === b || (a.fg === b.fg &&
    a.bg === b.bg && a.bold == b.bold && a.dim == b.dim && a.italic == b.italic &&
    a.underline == b.underline && a.reverse == b.reverse)

# ---- ANSI --------------------------------------------------------------------

const _UI_ANSI_NAMES = Dict{Symbol,Int}(
    :black => 30, :red => 31, :green => 32, :yellow => 33,
    :blue => 34, :magenta => 35, :cyan => 36, :white => 37,
    :bright_black => 90, :bright_red => 91, :bright_green => 92,
    :bright_yellow => 93, :bright_blue => 94, :bright_magenta => 95,
    :bright_cyan => 96, :bright_white => 97)

# The SGR code list for one color; `bg` shifts the 16-color codes by ten.
function _ui_color_codes(c::Symbol, bg::Bool = false)
    c === :default && return String[bg ? "49" : "39"]
    base = get(_UI_ANSI_NAMES, c, nothing)
    if base !== nothing
        return String[string(base + (bg ? 10 : 0))]
    end
    s = String(c)
    if startswith(s, "color")
        n = tryparse(Int, s[6:end])
        n !== nothing && 0 <= n <= 255 &&
            return String[bg ? "48" : "38", "5", string(n)]
    elseif startswith(s, "rgb") && length(s) == 9
        r = tryparse(Int, s[4:5]; base = 16)
        g = tryparse(Int, s[6:7]; base = 16)
        b = tryparse(Int, s[8:9]; base = 16)
        if r !== nothing && g !== nothing && b !== nothing
            return String[bg ? "48" : "38", "2", string(r), string(g), string(b)]
        end
    end
    return String[bg ? "49" : "39"]
end

"""
    _ui_sgr(st) -> String

The escape sequence that selects `st`, always starting from a reset so a span
never inherits the previous span's attributes.
"""
function _ui_sgr(st::_UiStyle)
    codes = String["0"]
    st.bold && push!(codes, "1")
    st.dim && push!(codes, "2")
    st.italic && push!(codes, "3")
    st.underline && push!(codes, "4")
    st.reverse && push!(codes, "7")
    append!(codes, _ui_color_codes(st.fg, false))
    append!(codes, _ui_color_codes(st.bg, true))
    return "\e[" * join(codes, ";") * "m"
end

const _UI_RESET = "\e[0m"

# ---- plain-text helpers ------------------------------------------------------

# The visible text of a span run (styles dropped).
_ui_spans_text(spans::Vector{_UiSpan}) = join((s.text for s in spans), "")

# Split a span at `n` visible columns; returns `(head, tail)` or the pair with an
# empty tail when the text fits.
function _ui_span_split(spans::Vector{_UiSpan}, n::Int)
    n <= 0 && return (_UiSpan[], spans)
    head = _UiSpan[]
    tail = _UiSpan[]
    w = 0
    inhead = true
    for s in spans
        if inhead
            cw = textwidth(s.text)
            if w + cw <= n
                push!(head, s)
                w += cw
                continue
            end
            # cut inside this span
            io = IOBuffer()
            hw = 0
            cut = 1
            chars = collect(s.text)
            for (i, c) in enumerate(chars)
                cw2 = textwidth(c)
                w + hw + cw2 > n && break
                print(io, c)
                hw += cw2
                cut = i + 1
            end
            piece = String(take!(io))
            if !isempty(piece)
                push!(head, _UiSpan(piece, s.style))
                w += hw
            end
            rest = String(chars[cut:end])
            isempty(rest) || push!(tail, _UiSpan(rest, s.style))
            inhead = false
        else
            push!(tail, s)
        end
    end
    return (head, tail)
end

# Clip a run to `width` visible columns (mirrors `_ui_clip` for plain strings).
function _ui_clip_spans(spans::Vector{_UiSpan}, width::Int)
    width <= 0 && return spans
    total = 0
    for s in spans
        total += textwidth(s.text)
    end
    total <= width && return spans
    (head, _) = _ui_span_split(spans, width)
    return head
end

# Prefix a span run with `n` spaces of the plain style.
_ui_pad_spans(spans::Vector{_UiSpan}, n::Int) =
    n <= 0 ? spans : vcat(_UiSpan[ _UiSpan(repeat(" ", n), _UI_PLAIN) ], spans)

# Pad a run to `width` with `st` (used by background blocks).
function _ui_pad_to(spans::Vector{_UiSpan}, width::Int, st::_UiStyle = _UI_PLAIN)
    w = 0
    for s in spans
        w += textwidth(s.text)
    end
    w >= width && return spans
    return vcat(spans, _UiSpan[ _UiSpan(repeat(" ", width - w), st) ])
end
