################################################################################
# ui/terminal.jl
#
# The terminal renderer: a full-screen alternate-buffer view driven by a byte
# source. It owns no state — every accepted change goes through
# `_ui_dispatch!` — and it distinguishes two exits:
#
#   Esc      dismiss gracefully: restore the screen, `ui-show` returns `naught`
#   Ctrl-C   abort: restore the screen, `ui-show` raises `(error :ctrl-c)`
#
# A lone Esc is also the prefix of every CSI/SS3 sequence, so a bare ESC is held
# briefly (~50 ms); a continuation byte turns it into an arrow or function key.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- the key parser ----------------------------------------------------------

# A Julia literal cannot spell a hyphenated symbol (`:ctrl-c` is a subtraction),
# so the multi-word tokens get names.
const _KT_CTRL_C = Symbol("ctrl-c")
const _KT_SHIFT_TAB = Symbol("shift-tab")
const _KT_PAGE_UP = Symbol("page-up")
const _KT_PAGE_DOWN = Symbol("page-down")

mutable struct _KeyParser
    state::Symbol            # :ground, :esc, :csi, :ss3
    seq::Vector{UInt8}
    utf8::Vector{UInt8}
end

_KeyParser() = _KeyParser(:ground, UInt8[], UInt8[])

# A token is a symbol (:up, :enter, …) or `(:text, c)`.
function _kp_feed!(kp::_KeyParser, b::UInt8)
    if kp.state === :esc
        kp.state = :ground
        if b == UInt8('[')
            kp.state = :csi
            empty!(kp.seq)
            return Any[]
        elseif b == UInt8('O')
            kp.state = :ss3
            return Any[]
        end
        out = Any[:escape]
        append!(out, _kp_feed!(kp, b))
        return out
    elseif kp.state === :csi
        if 0x40 <= b <= 0x7e
            kp.state = :ground
            return _kp_csi(kp.seq, b)
        end
        push!(kp.seq, b)
        return Any[]
    elseif kp.state === :ss3
        kp.state = :ground
        return b == UInt8('A') ? Any[:up] :
               b == UInt8('B') ? Any[:down] :
               b == UInt8('C') ? Any[:right] :
               b == UInt8('D') ? Any[:left] :
               b == UInt8('H') ? Any[:home] :
               b == UInt8('F') ? Any[:end] : Any[]
    end
    # Ground state.
    if b == 0x1b
        kp.state = :esc
        empty!(kp.seq)
        return Any[]
    elseif b == 0x03
        return Any[_KT_CTRL_C]
    elseif b == 0x0d || b == 0x0a
        return Any[:enter]
    elseif b == 0x09
        return Any[:tab]
    elseif b == 0x7f || b == 0x08
        return Any[:backspace]
    elseif b < 0x20
        return Any[]
    elseif b < 0x80
        return Any[(:text, Char(b))]
    end
    push!(kp.utf8, b)
    need = _utf8_len(kp.utf8[1])
    length(kp.utf8) < need && return Any[]
    bytes = copy(kp.utf8)
    empty!(kp.utf8)
    c = try
        only(collect(String(bytes)))
    catch
        Char(0xfffd)
    end
    return Any[(:text, c)]
end

function _kp_csi(seq::Vector{UInt8}, final::UInt8)
    s = String(seq)
    # Ignore modifier parameters (`1;5A` is Shift-Up).
    semi = findfirst(';', s)
    semi === nothing || (s = s[1:semi-1])
    if final == UInt8('A')
        return Any[:up]
    elseif final == UInt8('B')
        return Any[:down]
    elseif final == UInt8('C')
        return Any[:right]
    elseif final == UInt8('D')
        return Any[:left]
    elseif final == UInt8('H')
        return Any[:home]
    elseif final == UInt8('F')
        return Any[:end]
    elseif final == UInt8('Z')
        return Any[_KT_SHIFT_TAB]
    elseif final == UInt8('~')
        n = tryparse(Int, s)
        n === nothing && return Any[]
        return n in (1, 7) ? Any[:home] :
               n in (4, 8) ? Any[:end] :
               n == 2 ? Any[:insert] :
               n == 3 ? Any[:delete] :
               n == 5 ? Any[_KT_PAGE_UP] :
               n == 6 ? Any[_KT_PAGE_DOWN] : Any[]
    end
    return Any[]
end

# A bare ESC with no continuation: emit the dismiss token.
function _kp_bare_escape!(kp::_KeyParser)
    kp.state = :ground
    return :escape
end

# ---- the renderer ------------------------------------------------------------

mutable struct _TermRenderer <: _UiRenderer
    io::IO
    readbyte::Function
    resize::Function
    cols::Ref{Int}
    rows::Ref{Int}
    kp::_KeyParser
    esc_at::Float64
    focus::Union{Nothing,String}
    editing::Bool
    editing_path::Union{Nothing,String}
    buf::String
    cursor::Int
    status::String
    quit::Symbol             # :none, :dismiss, :abort
    need_redraw::Bool
    sel::Dict{String,Int}    # per-element option cursor for multi-select
end

function _TermRenderer(io::IO; cols::Ref{Int} = Ref(80), rows::Ref{Int} = Ref(24),
                       readbyte::Function = () -> nothing,
                       resize::Function = () -> nothing)
    return _TermRenderer(io, readbyte, resize, cols, rows, _KeyParser(), 0.0,
                         nothing, false, nothing, "", 0, "", :none, true,
                         Dict{String,Int}())
end

# ---- focus -------------------------------------------------------------------

function _ui_term_focus_list(inst::_UiInstance)
    return _ui_focus_order(inst)
end

function _ui_term_focused(r::_TermRenderer, inst::_UiInstance)
    f = _ui_term_focus_list(inst)
    isempty(f) && return nothing
    r.focus === nothing && (r.focus = _ui_sel(f[1]); return f[1])
    for n in f
        _ui_sel(n) == r.focus && return n
    end
    r.focus = _ui_sel(f[1])
    return f[1]
end

function _ui_term_move_focus!(r::_TermRenderer, inst::_UiInstance, delta::Int)
    f = _ui_term_focus_list(inst)
    isempty(f) && return nothing
    cur = _ui_term_focused(r, inst)
    i = findfirst(n -> n === cur, f)
    i = i === nothing ? 1 : mod1(i + delta, length(f))
    r.focus = _ui_sel(f[i])
    r.need_redraw = true
    return nothing
end

# ---- values ------------------------------------------------------------------

function _ui_term_step(params, k::_UiKind, lo, hi)
    s = _ui_param_number(params, _UI_K_STEP)
    s !== nothing && return s
    k.value === :int && return 1
    return hi > lo ? (Float64(hi) - Float64(lo)) / 100 : 0.01
end

function _ui_term_snap(v, lo, step)
    step == 0 && return v
    q = (Float64(v) - Float64(lo)) / Float64(step)
    return lo + round(q) * step
end

function _ui_term_num_form(k::_UiKind, v)
    if k.value === :int
        return Form(round(Int64, v))
    end
    return Form(Float64(v))
end

function _ui_term_options(node::_UiNode)
    return _ui_options(node.params)
end

function _ui_term_option_index(opts, value)
    for (i, (_, v)) in enumerate(opts)
        _eq(v, value) && return i
    end
    return 0
end

function _ui_term_apply!(r::_TermRenderer, inst::_UiInstance, node::_UiNode, v::Form)
    res = _ui_dispatch!(inst, (:set, _ui_sel(node), v))
    if res isa Tuple && res[1] === :invalid
        r.status = res[2]
    else
        r.status = ""
    end
    r.need_redraw = true
    return nothing
end

# ---- editing -----------------------------------------------------------------

function _ui_term_text_value(node::_UiNode)
    k = node.kind.name
    if k === Symbol("text-input") || k === Symbol("text-area") ||
       k === Symbol("password-input")
        return something(_ui_string(node.value), "")
    elseif k === Symbol("int-input") || k === Symbol("float-input") ||
           k === Symbol("slider")
        return _ui_display_text(node.value)
    elseif k === Symbol("range-slider")
        els = _ui_seq_elements(node.value)
        (els === nothing || length(els) != 2) && return ""
        return _ui_display_text(els[1]) * ", " * _ui_display_text(els[2])
    end
    return ""
end

function _ui_term_editable(node::_UiNode)
    k = node.kind.name
    return k === Symbol("text-input") || k === Symbol("text-area") ||
           k === Symbol("password-input") || k === Symbol("int-input") ||
           k === Symbol("float-input") || k === Symbol("slider") ||
           k === Symbol("range-slider")
end

function _ui_term_begin_edit!(r::_TermRenderer, node::_UiNode)
    r.editing = true
    r.editing_path = node.path
    r.buf = _ui_term_text_value(node)
    r.cursor = length(r.buf)
    r.status = ""
    r.need_redraw = true
    return nothing
end

function _ui_term_cancel_edit!(r::_TermRenderer)
    r.editing = false
    r.editing_path = nothing
    r.buf = ""
    r.cursor = 0
    r.need_redraw = true
    return nothing
end

function _ui_term_insert!(r::_TermRenderer, c::Char)
    s = collect(r.buf)
    insert!(s, min(r.cursor + 1, length(s) + 1), c)
    r.buf = String(s)
    r.cursor += 1
    r.need_redraw = true
    return nothing
end

function _ui_term_parse_value(node::_UiNode, s::AbstractString)
    k = node.kind.name
    t = strip(s)
    if k === Symbol("text-input") || k === Symbol("text-area") ||
       k === Symbol("password-input")
        return Form(String(s))
    elseif k === Symbol("int-input")
        v = tryparse(Int64, t)
        v !== nothing && return Form(v)
        b = tryparse(BigInt, t)
        b === nothing && return nothing
        return Form(b)
    elseif k === Symbol("float-input") || k === Symbol("slider")
        v = tryparse(Float64, t)
        return v === nothing ? nothing : Form(v)
    elseif k === Symbol("range-slider")
        parts = split(t, r"[,\s]+"; keepempty = false)
        length(parts) == 2 || return nothing
        a = tryparse(Float64, parts[1]); b = tryparse(Float64, parts[2])
        (a === nothing || b === nothing) && return nothing
        return _ui_seq_form(Form[Form(a), Form(b)])
    end
    return nothing
end

function _ui_term_commit!(r::_TermRenderer, inst::_UiInstance, node::_UiNode)
    v = _ui_term_parse_value(node, r.buf)
    if v === nothing
        r.status = "invalid value"
        r.need_redraw = true
        return false
    end
    _ui_term_apply!(r, inst, node, v)
    r.editing = false
    r.editing_path = nothing
    r.buf = ""
    r.cursor = 0
    return true
end

# ---- key handling ------------------------------------------------------------

function _ui_term_edit_key!(r::_TermRenderer, inst::_UiInstance, node::_UiNode, tok)
    if tok === :enter
        _ui_term_commit!(r, inst, node)
        return nothing
    elseif tok === :tab
        _ui_term_commit!(r, inst, node)
        _ui_term_move_focus!(r, inst, 1)
        return nothing
    elseif tok === _KT_SHIFT_TAB
        _ui_term_commit!(r, inst, node)
        _ui_term_move_focus!(r, inst, -1)
        return nothing
    elseif tok === :escape
        _ui_term_cancel_edit!(r)
        return nothing
    elseif tok === :backspace
        if r.cursor > 0
            s = collect(r.buf)
            deleteat!(s, r.cursor)
            r.buf = String(s)
            r.cursor -= 1
            r.need_redraw = true
        end
        return nothing
    elseif tok === :delete
        if r.cursor < length(r.buf)
            s = collect(r.buf)
            deleteat!(s, r.cursor + 1)
            r.buf = String(s)
            r.need_redraw = true
        end
        return nothing
    elseif tok === :left
        r.cursor = max(0, r.cursor - 1); r.need_redraw = true
        return nothing
    elseif tok === :right
        r.cursor = min(length(r.buf), r.cursor + 1); r.need_redraw = true
        return nothing
    elseif tok === :home
        r.cursor = 0; r.need_redraw = true
        return nothing
    elseif tok === :end
        r.cursor = length(r.buf); r.need_redraw = true
        return nothing
    elseif tok isa Tuple && tok[1] === :text && isprint(tok[2])
        _ui_term_insert!(r, tok[2])
        return nothing
    end
    return nothing
end

function _ui_term_activate!(r::_TermRenderer, inst::_UiInstance, node::_UiNode)
    k = node.kind.name
    if k === Symbol("checkbox") || k === Symbol("toggle")
        _ui_term_apply!(r, inst, node, Form(_ui_bool(node.value) !== true))
    elseif k === Symbol("button")
        res = _ui_dispatch!(inst, (:click, _ui_sel(node)))
        res isa Tuple && res[1] === :invalid && (r.status = res[2])
        r.need_redraw = true
    elseif k === Symbol("dropdown") || k === Symbol("radio-group") ||
           k === Symbol("selection-slider")
        _ui_term_cycle_option!(r, inst, node, 1)
    elseif k === Symbol("multi-select")
        _ui_term_toggle_multi!(r, inst, node)
    elseif _ui_term_editable(node)
        _ui_term_begin_edit!(r, node)
    end
    return nothing
end

function _ui_term_cycle_option!(r::_TermRenderer, inst::_UiInstance,
                                node::_UiNode, delta::Int)
    opts = _ui_term_options(node)
    isempty(opts) && return nothing
    i = _ui_term_option_index(opts, node.value)
    i = i == 0 ? 1 : mod1(i + delta, length(opts))
    _ui_term_apply!(r, inst, node, opts[i][2])
    return nothing
end

function _ui_term_toggle_multi!(r::_TermRenderer, inst::_UiInstance, node::_UiNode)
    opts = _ui_term_options(node)
    isempty(opts) && return nothing
    i = clamp(get(r.sel, node.path, 0) + 1, 1, length(opts))
    v = opts[i][2]
    els = _ui_seq_elements(node.value)
    els === nothing && (els = Form[])
    j = findfirst(e -> _eq(e, v), els)
    if j === nothing
        push!(els, v)
    else
        deleteat!(els, j)
    end
    _ui_term_apply!(r, inst, node, _ui_seq_form(els))
    return nothing
end

function _ui_term_adjust!(r::_TermRenderer, inst::_UiInstance, node::_UiNode,
                          tok::Symbol)
    k = node.kind.name
    opts = _ui_term_options(node)
    if k === Symbol("dropdown") || k === Symbol("radio-group") ||
       k === Symbol("selection-slider")
        if tok === :left
            _ui_term_cycle_option!(r, inst, node, -1)
        elseif tok === :right
            _ui_term_cycle_option!(r, inst, node, 1)
        elseif tok === :home && !isempty(opts)
            _ui_term_apply!(r, inst, node, opts[1][2])
        elseif tok === :end && !isempty(opts)
            _ui_term_apply!(r, inst, node, opts[end][2])
        end
        return nothing
    elseif k === Symbol("multi-select")
        isempty(opts) && return nothing
        cur = get(r.sel, node.path, 0)
        if tok === :left
            cur = mod(cur - 1, length(opts))
        elseif tok === :right
            cur = mod(cur + 1, length(opts))
        end
        r.sel[node.path] = cur
        r.need_redraw = true
        return nothing
    end
    if !(k === Symbol("int-input") || k === Symbol("float-input") ||
         k === Symbol("slider") || k === Symbol("range-slider"))
        return nothing
    end
    lo = something(_ui_param_number(node.params, _UI_K_MIN), 0)
    hi = something(_ui_param_number(node.params, _UI_K_MAX), 1)
    step = _ui_term_step(node.params, node.kind, lo, hi)
    if k === Symbol("range-slider")
        els = _ui_seq_elements(node.value)
        (els === nothing || length(els) != 2) && return nothing
        a = _ui_number(els[1]); b = _ui_number(els[2])
        (a === nothing || b === nothing) && return nothing
        d = tok === :left ? -step : tok === :right ? step : 0
        d == 0 && return nothing
        na = clamp(_ui_term_snap(a + d, lo, step), lo, b)
        _ui_term_apply!(r, inst, node, _ui_seq_form(Form[Form(na), els[2]]))
        return nothing
    end
    v = _ui_number(node.value)
    v === nothing && return nothing
    if tok === :home
        nv = lo
    elseif tok === :end
        nv = hi
    elseif tok === :left
        nv = clamp(_ui_term_snap(v - step, lo, step), lo, hi)
    elseif tok === :right
        nv = clamp(_ui_term_snap(v + step, lo, step), lo, hi)
    else
        return nothing
    end
    _ui_term_apply!(r, inst, node, _ui_term_num_form(node.kind, nv))
    return nothing
end

function _ui_term_key!(r::_TermRenderer, inst::_UiInstance, tok)
    tok === _KT_CTRL_C && (r.quit = :abort; return nothing)
    node = _ui_term_focused(r, inst)
    if r.editing
        node === nothing && return nothing
        _ui_term_edit_key!(r, inst, node, tok)
        return nothing
    end
    node === nothing && return nothing
    if tok === :escape
        r.quit = :dismiss
        return nothing
    elseif tok === :tab
        _ui_term_move_focus!(r, inst, 1)
    elseif tok === _KT_SHIFT_TAB
        _ui_term_move_focus!(r, inst, -1)
    elseif tok === :up
        _ui_term_move_focus!(r, inst, -1)
    elseif tok === :down
        _ui_term_move_focus!(r, inst, 1)
    elseif tok === :enter
        _ui_term_activate!(r, inst, node)
    elseif tok === :left || tok === :right || tok === :home || tok === :end
        _ui_term_adjust!(r, inst, node, tok)
    elseif tok isa Tuple && tok[1] === :text && tok[2] == ' '
        k = node.kind.name
        if k === Symbol("checkbox") || k === Symbol("toggle") || k === Symbol("button")
            _ui_term_activate!(r, inst, node)
        elseif _ui_term_editable(node)
            _ui_term_begin_edit!(r, node)
            _ui_term_insert!(r, ' ')
        end
    elseif tok isa Tuple && tok[1] === :text && isprint(tok[2]) &&
           _ui_term_editable(node)
        _ui_term_begin_edit!(r, node)
        _ui_term_insert!(r, tok[2])
    end
    return nothing
end

# ---- drawing -----------------------------------------------------------------

function _ui_term_edit_col(node::_UiNode, buf::AbstractString, cursor::Int)
    tag = _ui_label_text(node)
    prefix = isempty(tag) ? "" : tag * ": "
    before = String(collect(buf)[1:min(cursor, length(buf))])
    return textwidth(prefix) + textwidth(before) + 1
end

function _ui_term_draw!(r::_TermRenderer, inst::_UiInstance)
    width = max(r.cols[], 20)
    height = max(r.rows[], 3)
    node = _ui_term_focused(r, inst)
    focuspath = node === nothing ? nothing : node.path
    edit = nothing
    if r.editing && node !== nothing && r.editing_path == node.path
        edit = (node.path, r.buf, r.cursor)
    end
    lines = _ui_lines(inst, inst.root, width; edit = edit)

    # Scroll so the focused element is visible (the last row is the status bar).
    body = height - 1
    start = 1
    if length(lines) > body
        foc = node === nothing ? 1 :
              something(findfirst(l -> l.node !== nothing && l.node.path === focuspath,
                                  lines), 1)
        start = clamp(foc - body ÷ 2, 1, max(1, length(lines) - body + 1))
    end
    stop = min(length(lines), start + body - 1)

    io = IOBuffer()
    print(io, "\e[H")
    row = 0
    focusrow = 0
    for i in start:stop
        l = lines[i]
        text = _ui_clip(l.text, width - 1)
        if l.node !== nothing && l.node.path === focuspath
            print(io, "\e[K\e[7m", text, "\e[0m")
            focusrow == 0 && (focusrow = row + 1)
        else
            print(io, "\e[K", text)
        end
        print(io, "\r\n")
        row += 1
    end
    while row < body
        print(io, "\e[K\r\n")
        row += 1
    end
    status = isempty(r.status) ?
             "tab: next   enter: activate/edit   esc: done   ctrl-c: abort" :
             r.status
    print(io, "\e[K", _ui_clip(status, width - 1))
    if edit !== nothing
        col = _ui_term_edit_col(node, r.buf, r.cursor)
        print(io, "\e[", max(focusrow, 1), ";", col, "H\e[?25h")
    else
        print(io, "\e[?25l")
    end
    print(r.io, String(take!(io)))
    flush(r.io)
    r.need_redraw = false
    return nothing
end

# ---- the loop ----------------------------------------------------------------

function _ui_term_tick!(r::_TermRenderer, inst::_UiInstance)
    try
        r.resize()
    catch
    end
    while r.quit === :none && !inst.dismissed && !inst.closed
        was = r.kp.state
        b = try
            r.readbyte()
        catch e
            e isa SshError || rethrow()
            r.quit = :dismiss
            break
        end
        b === nothing && break
        toks = _kp_feed!(r.kp, b)
        if r.kp.state === :esc && was !== :esc
            r.esc_at = time()
        elseif r.kp.state !== :esc
            r.esc_at = 0.0
        end
        for t in toks
            _ui_term_key!(r, inst, t)
        end
    end
    if r.kp.state === :esc && r.esc_at > 0.0 && (time() - r.esc_at) >= 0.05
        _kp_bare_escape!(r.kp)
        r.esc_at = 0.0
        _ui_term_key!(r, inst, :escape)
    end
    if inst.dirty || r.need_redraw
        lock(inst.lock) do
            _ui_term_draw!(r, inst)
        end
        inst.dirty = false
    end
    return nothing
end

function _ui_term_run!(r::_TermRenderer, inst::_UiInstance)
    _ui_attach!(r, inst)
    print(r.io, "\e[?1049h")
    print(r.io, "\e[?25l")
    flush(r.io)
    try
        while !inst.dismissed && !inst.closed && r.quit === :none
            _ui_term_tick!(r, inst)
            sleep(0.01)
        end
    finally
        try
            print(r.io, "\e[?25h")
            print(r.io, "\e[?1049l")
            flush(r.io)
        catch
        end
        _ui_detach!(r, inst)
    end
    if r.quit === :abort
        throw(AirThrown(_error_object(Form(Symbol(":ctrl-c")))))
    end
    return naught
end

# ---- ui-show -----------------------------------------------------------------

# Bytes the renderer consumes: any typed-ahead bytes the REPL pushed back, then
# whatever the channel has. `nothing` when the channel is quiet.
function _ssh_ui_readbyte!(out::_SshChannelIO)
    if isempty(out.pending)
        data = _ssh_read_available!(out.chan, out.inbuf)
        data === nothing && return nothing
        append!(out.pending, data)
    end
    return popfirst!(out.pending)
end

function _ssh_ui_resize!(out::_SshChannelIO)
    size = _ssh_poll_channel!(out.session, out.cols[], out.rows[])
    size === nothing && return nothing
    size[1] > 0 && (out.cols[] = size[1])
    size[2] > 0 && (out.rows[] = size[2])
    return nothing
end

"""
    (ui-show key)

Attach the current session's terminal renderer to the instance and block until
it is dismissed (Esc or a `(ui-dismiss! key)`), aborted (Ctrl-C, which raises
`(error :ctrl-c)`), or closed.
"""
function _bi_ui_show(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-show", ())
    length(call.seq) == 2 || throw(AirEvalError("ui-show takes a UI instance key"))
    inst = _ui_lookup(env, air_reduce(env, scope, to_form(call.seq[2])))
    out = _context(env).out
    (out isa _SshChannelIO && out.tty) || throw(AirThrown(_error_object(
        Form(Symbol(":no-renderer")),
        Form("ui-show requires an interactive terminal session"))))
    r = _TermRenderer(out; cols = out.cols, rows = out.rows,
                      readbyte = () -> _ssh_ui_readbyte!(out),
                      resize = () -> _ssh_ui_resize!(out))
    return _ui_term_run!(r, inst)
end
special!(Symbol("ui-show"), _bi_ui_show)

# `(ui-run tree)` — open, show, and close, returning the final values.
function _bi_ui_run(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-run", ())
    length(call.seq) == 2 || throw(AirEvalError("ui-run takes a UI tree"))
    key = _bi_ui_open(env, scope, FormContainer(
        FormSeq(FormValue[_store_form(Form(Symbol("ui-open"))),
                          call.seq[2]]), FormMap()))
    inst = _ui_lookup(env, key)
    try
        _bi_ui_show(env, scope, FormContainer(
            FormSeq(FormValue[_store_form(Form(Symbol("ui-show"))),
                              _store_form(key)]), FormMap()))
        return _ui_values_form(inst)
    finally
        _ui_close_key(env, key)
    end
end
special!(Symbol("ui-run"), _bi_ui_run)
