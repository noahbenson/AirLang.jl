################################################################################
# ui/keys.jl
#
# The key model and a byte-level parser. Terminals send bytes, not keys: Ctrl-A
# is 0x01, an arrow is `ESC [ A`, Shift-Up is `ESC [ 1 ; 2 A`, and a paste is
# bracketed by `ESC [ 200 ~` … `ESC [ 201 ~`. The parser turns those into a
# `_UiKey` with explicit modifiers so the keymaps can name what they mean.
#
# Two control bytes deserve a note. In raw mode CR (0x0D) is Enter and LF (0x0A)
# is Ctrl-J, so the notebook's run key is distinguishable from Enter on xterm and
# every terminal that preserves CR/LF; a terminal or client that maps Enter to LF
# loses that distinction. A lone ESC is the prefix of every CSI/SS3 sequence, so
# it is held briefly (`_UI_ESC_TIMEOUT`) before being reported as Esc.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _UI_ESC_TIMEOUT = 0.025

"""
    _UiKey(name, char, text, ctrl, alt, shift)

One key press. `name` is `:char`, `:paste`, `:enter`, `:tab`, `:backtab`,
`:esc`, `:up`, `:down`, `:left`, `:right`, `:home`, `:end`, `:pageup`,
`:pagedown`, `:insert`, `:delete`, `:backspace`, or `:f1`…`:f12`. `char` is set
for `:char`, `text` for `:paste`.
"""
struct _UiKey
    name::Symbol
    char::Union{Nothing,Char}
    text::String
    ctrl::Bool
    alt::Bool
    shift::Bool
end

_ui_key(name::Symbol; char = nothing, text = "", ctrl::Bool = false,
        alt::Bool = false, shift::Bool = false) =
    _UiKey(name, char === nothing ? nothing : Char(char), String(text), ctrl, alt,
           shift)

_is_text_key(k::_UiKey) = k.name === :char

function _ui_key_eq(a::_UiKey, b::_UiKey)
    return a.name === b.name && a.char == b.char && a.text == b.text &&
           a.ctrl == b.ctrl && a.alt == b.alt && a.shift == b.shift
end

function _ui_key_string(k::_UiKey)
    parts = String[]
    k.ctrl && push!(parts, "Ctrl")
    k.alt && push!(parts, "Alt")
    k.shift && push!(parts, "Shift")
    if k.name === :char
        push!(parts, string(k.char))
    elseif k.name === :paste
        push!(parts, "Paste")
    else
        push!(parts, String(k.name))
    end
    return join(parts, "-")
end

# ---- parser ------------------------------------------------------------------

mutable struct _UiKeyParser
    state::Symbol            # :ground, :esc, :csi, :ss3, :paste
    seq::Vector{UInt8}       # CSI/SS3 parameter bytes
    paste::Vector{UInt8}     # bracketed-paste payload
    utf8::Vector{UInt8}      # an unfinished UTF-8 character
    since::Float64           # when the current partial sequence started (0 = none)
end

_UiKeyParser() = _UiKeyParser(:ground, UInt8[], UInt8[], UInt8[], 0.0)

_ui_kp_idle(kp::_UiKeyParser) = kp.state === :ground && isempty(kp.utf8)

# Decode the next UTF-8 character, or `nothing` while incomplete.
function _ui_kp_utf8!(kp::_UiKeyParser, b::UInt8)
    push!(kp.utf8, b)
    need = _utf8_len(kp.utf8[1])
    length(kp.utf8) < need && return nothing
    bytes = copy(kp.utf8)
    empty!(kp.utf8)
    return try
        only(collect(String(bytes)))
    catch
        Char(0xfffd)
    end
end

# The key a single ground-state byte means (without ESC handling).
function _ui_kp_byte(b::UInt8)
    b == 0x03 && return _ui_key(:char; char = 'c', ctrl = true)
    b == 0x04 && return _ui_key(:char; char = 'd', ctrl = true)
    b == 0x07 && return _ui_key(:char; char = 'g', ctrl = true)
    b == 0x16 && return _ui_key(:char; char = 'v', ctrl = true)
    b == 0x08 && return _ui_key(:backspace)
    b == 0x7f && return _ui_key(:backspace)
    b == 0x09 && return _ui_key(:tab)
    b == 0x0a && return _ui_key(:char; char = 'j', ctrl = true)
    b == 0x0d && return _ui_key(:enter)
    b == 0x1b && return _ui_key(:esc)
    if 0x01 <= b <= 0x1a
        return _ui_key(:char; char = Char(Int('a') + Int(b) - 1), ctrl = true)
    elseif b == 0x1c
        return _ui_key(:char; char = '\\', ctrl = true)
    elseif b == 0x1d
        return _ui_key(:char; char = ']', ctrl = true)
    elseif b == 0x1e
        return _ui_key(:char; char = '^', ctrl = true)
    elseif b == 0x1f
        return _ui_key(:char; char = '_', ctrl = true)
    end
    return nothing
end

# A Unicode code point as a key, for the CSI-u and modifyOtherKeys encodings.
# Control characters keep their ordinary names, and a Ctrl-modified letter is
# lowercased because terminals disagree about reporting the shifted spelling.
function _ui_kp_code_key(code::Int, shift::Bool, alt::Bool, ctrl::Bool)
    if code == 8 || code == 127
        return _ui_key(:backspace; shift = shift, alt = alt, ctrl = ctrl)
    end
    code == 9 && return _ui_key(:tab; shift = shift, alt = alt, ctrl = ctrl)
    code == 13 && return _ui_key(:enter; shift = shift, alt = alt, ctrl = ctrl)
    code == 27 && return _ui_key(:esc; shift = shift, alt = alt, ctrl = ctrl)
    (0 < code <= 0x10ffff) || return nothing
    ch = Char(code)
    ctrl && (ch = lowercase(ch))
    return _ui_key(:char; char = ch, shift = shift, alt = alt, ctrl = ctrl)
end

# Final byte of a CSI sequence and its parameter string.
function _ui_kp_csi(seq::AbstractString, final::Char)
    params = split(seq, ';')
    num(i, d) = i <= length(params) ? something(tryparse(Int, params[i]), d) : d
    mods = num(2, 1)
    m = max(mods - 1, 0)
    shift = (m & 1) != 0
    alt = (m & 2) != 0
    ctrl = (m & 4) != 0
    function named(n)
        return _ui_key(n; shift = shift, alt = alt, ctrl = ctrl)
    end
    if final == 'u'
        # CSI-u: `code ; modifiers [; text] u`.
        k = _ui_kp_code_key(num(1, 0), shift, alt, ctrl)
        return k === nothing ? _UiKey[] : [k]
    end
    if final == 'A'
        return [named(:up)]
    elseif final == 'B'
        return [named(:down)]
    elseif final == 'C'
        return [named(:right)]
    elseif final == 'D'
        return [named(:left)]
    elseif final == 'H'
        return [named(:home)]
    elseif final == 'F'
        return [named(:end)]
    elseif final == 'Z'
        return [_ui_key(:tab; shift = true)]
    elseif final == '~'
        n = num(1, 0)
        if n == 27 && length(params) >= 3
            # modifyOtherKeys: `CSI 27 ; modifiers ; code ~`.
            k = _ui_kp_code_key(num(3, 0), shift, alt, ctrl)
            return k === nothing ? _UiKey[] : [k]
        end
        n == 1 || n == 7 ? [named(:home)] :
        n == 4 || n == 8 ? [named(:end)] :
        n == 2 ? [named(:insert)] :
        n == 3 ? [named(:delete)] :
        n == 5 ? [named(:pageup)] :
        n == 6 ? [named(:pagedown)] :
        n == 11 ? [named(:f1)] : n == 12 ? [named(:f2)] :
        n == 13 ? [named(:f3)] : n == 14 ? [named(:f4)] :
        n == 15 ? [named(:f5)] :
        n == 17 ? [named(:f6)] : n == 18 ? [named(:f7)] :
        n == 19 ? [named(:f8)] : n == 20 ? [named(:f9)] :
        n == 21 ? [named(:f10)] : n == 23 ? [named(:f11)] :
        n == 24 ? [named(:f12)] : _UiKey[]
    end
    return _UiKey[]
end

function _ui_kp_ss3(final::UInt8)
    c = Char(final)
    if c == 'A'
        return [_ui_key(:up)]
    elseif c == 'B'
        return [_ui_key(:down)]
    elseif c == 'C'
        return [_ui_key(:right)]
    elseif c == 'D'
        return [_ui_key(:left)]
    elseif c == 'H'
        return [_ui_key(:home)]
    elseif c == 'F'
        return [_ui_key(:end)]
    elseif c == 'P'
        return [_ui_key(:f1)]
    elseif c == 'Q'
        return [_ui_key(:f2)]
    elseif c == 'R'
        return [_ui_key(:f3)]
    elseif c == 'S'
        return [_ui_key(:f4)]
    end
    return _UiKey[]
end

"""
    _ui_kp_feed!(kp, b, now) -> Vector{_UiKey}

Feed one byte; returns the keys it completed (often none, since a key may span
several bytes).
"""
function _ui_kp_feed!(kp::_UiKeyParser, b::UInt8, now::Float64 = time())
    if kp.state === :paste
        # Everything is payload until `ESC [ 201 ~`.
        if b == 0x1b
            kp.state = :paste_esc
            return _UiKey[]
        end
        push!(kp.paste, b)
        return _UiKey[]
    elseif kp.state === :paste_esc
        b == UInt8('[') && (kp.state = :paste_201; return _UiKey[])
        push!(kp.paste, 0x1b, b)
        kp.state = :paste
        return _UiKey[]
    elseif kp.state === :paste_201
        b == UInt8('2') && (kp.state = :paste_201_2; return _UiKey[])
        append!(kp.paste, UInt8[0x1b, UInt8('['), b])
        kp.state = :paste
        return _UiKey[]
    elseif kp.state === :paste_201_2
        b == UInt8('0') && (kp.state = :paste_201_0; return _UiKey[])
        append!(kp.paste, UInt8[0x1b, UInt8('['), UInt8('2'), b])
        kp.state = :paste
        return _UiKey[]
    elseif kp.state === :paste_201_0
        b == UInt8('1') && (kp.state = :paste_201_1; return _UiKey[])
        append!(kp.paste, UInt8[0x1b, UInt8('['), UInt8('2'), UInt8('0'), b])
        kp.state = :paste
        return _UiKey[]
    elseif kp.state === :paste_201_1
        if b == UInt8('~')
            text = String(copy(kp.paste))
            empty!(kp.paste)
            kp.state = :ground
            return [_ui_key(:paste; text = text)]
        end
        append!(kp.paste, UInt8[0x1b, UInt8('['), UInt8('2'), UInt8('0'),
                             UInt8('1'), b])
        kp.state = :paste
        return _UiKey[]
    elseif kp.state === :csi
        if 0x40 <= b <= 0x7e
            kp.state = :ground
            kp.since = 0.0
            k = _ui_kp_csi(String(kp.seq), Char(b))
            empty!(kp.seq)
            return k
        end
        push!(kp.seq, b)
        return _UiKey[]
    elseif kp.state === :ss3
        kp.state = :ground
        kp.since = 0.0
        return _ui_kp_ss3(b)
    elseif kp.state === :esc
        kp.state = :ground
        if b == UInt8('[')
            kp.state = :csi
            kp.since = now
            empty!(kp.seq)
            return _UiKey[]
        elseif b == UInt8('O')
            kp.state = :ss3
            kp.since = now
            return _UiKey[]
        elseif b == 0x1b
            # ESC ESC: the first is a bare Esc; hold the second.
            kp.state = :esc
            kp.since = now
            return [_ui_key(:esc)]
        end
        # Alt + the key this byte means.
        base = _ui_kp_byte(b)
        if base === nothing
            if b >= 0x20
                c = _ui_kp_utf8!(kp, b)
                c === nothing && return _UiKey[]
                return [_ui_key(:char; char = c, alt = true)]
            end
            return [_ui_key(:esc)]
        end
        return [_UiKey(base.name, base.char, base.text, base.ctrl, true,
                       base.shift)]
    end

    # Ground state.
    if b == 0x1b
        kp.state = :esc
        kp.since = now
        return _UiKey[]
    end
    base = _ui_kp_byte(b)
    base === nothing || return [base]
    b < 0x20 && return _UiKey[]          # 0x00 and other unassigned controls
    b < 0x80 && return [_ui_key(:char; char = Char(b))]   # printable ASCII
    c = _ui_kp_utf8!(kp, b)
    c === nothing && return _UiKey[]
    return [_ui_key(:char; char = c)]
end

function _ui_kp_feed!(kp::_UiKeyParser, bytes, now::Float64 = time())
    out = _UiKey[]
    for b in bytes
        append!(out, _ui_kp_feed!(kp, b, now))
    end
    return out
end

"""
    _ui_kp_timeout!(kp, now) -> Union{Nothing,_UiKey}

A lone ESC (or an abandoned partial sequence) becomes an Esc after
`_UI_ESC_TIMEOUT`. Returns the key when the timeout fired.
"""
function _ui_kp_timeout!(kp::_UiKeyParser, now::Float64 = time())
    kp.since == 0.0 && return nothing
    now - kp.since < _UI_ESC_TIMEOUT && return nothing
    st = kp.state
    kp.state = :ground
    kp.since = 0.0
    empty!(kp.seq)
    st === :esc && return _ui_key(:esc)
    st === :csi && return _ui_key(:esc)      # an abandoned sequence: treat as Esc
    return nothing
end
