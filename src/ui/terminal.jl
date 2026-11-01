################################################################################
# ui/terminal.jl
#
# The full-screen terminal renderer. It owns no application state: legacy
# widgets are read from the instance and every accepted change goes through
# `_ui_dispatch!`; composite widgets (notebook, browser, chat, shell) own their
# own interaction state and are driven through the same key loop.
#
# Two exits are distinguished:
#
#   Esc      pop one layer; at the root, dismiss (`ui-show` returns `naught`)
#   Ctrl-C   abort: restore the screen, raise `(error :ctrl-c)`
#
# The byte source is a `_TermBackend` (ui/term.jl): an SSH channel, the local
# terminal, or a scripted IO in tests.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- the SSH backend ---------------------------------------------------------

# The session channel writer plus its non-blocking reader. Typed-ahead bytes the
# REPL pushed into `out.pending` are drained first, then whatever the channel
# has.
mutable struct _SshBackend <: _TermBackend
    out::_SshChannelIO
end

_tb_size(b::_SshBackend) = (b.out.cols[], b.out.rows[])
_tb_enter!(b::_SshBackend) = _tb_enter_standard!(b)
_tb_leave!(b::_SshBackend) = _tb_leave_standard!(b)

function _tb_resize!(b::_SshBackend)
    size = _ssh_poll_channel!(b.out.session, b.out.cols[], b.out.rows[])
    size === nothing && return nothing
    size[1] > 0 && (b.out.cols[] = size[1])
    size[2] > 0 && (b.out.rows[] = size[2])
    return nothing
end

function _tb_drain!(b::_SshBackend)
    out = UInt8[]
    if !isempty(b.out.pending)
        append!(out, b.out.pending)
        empty!(b.out.pending)
    end
    data = _ssh_read_available!(b.out.chan, b.out.inbuf)
    data === nothing || append!(out, data)
    return out
end

_tb_write(b::_SshBackend, data) = _ssh_write!(b.out, data)

# Bytes the renderer did not consume go back where the REPL expects them.
function _tb_unread!(b::_SshBackend, data)
    isempty(data) && return nothing
    prepend!(b.out.pending, data)
    return nothing
end

# ---- the renderer ------------------------------------------------------------

mutable struct _TermRenderer <: _UiRenderer
    backend::_TermBackend
    kp::_UiKeyParser
    focus::Union{Nothing,String}
    editing::Bool
    editing_path::Union{Nothing,String}
    buf::String
    cursor::Int
    status::String
    quit::Symbol             # :none, :dismiss, :abort
    need_redraw::Bool
    sel::Dict{String,Int}    # per-element option cursor for multi-select
    comp::Any                # a composite root widget, or `nothing`
    frame::_FrameCache       # what is on screen, so a redraw sends only changes
end

function _TermRenderer(backend::_TermBackend)
    return _TermRenderer(backend, _UiKeyParser(), nothing, false, nothing, "", 0,
                         "", :none, true, Dict{String,Int}(), nothing,
                         _FrameCache(backend))
end

# The scripted-IO constructor the tests use.
function _TermRenderer(io::IO; cols::Ref{Int} = Ref(80), rows::Ref{Int} = Ref(24),
                       readbyte::Function = () -> nothing,
                       resize::Function = () -> nothing)
    return _TermRenderer(_StreamBackend(io; cols = cols, rows = rows,
                                        readbyte = readbyte, resize = resize))
end

# ---- focus -------------------------------------------------------------------

_ui_term_focus_list(inst::_UiInstance) = _ui_focus_order(inst)

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

_ui_term_options(node::_UiNode) = _ui_options(node.params)

function _ui_term_option_index(opts, value)
    for (i, (_, v)) in enumerate(opts)
        _eq(v, value) && return i
    end
    return 0
end

function _ui_term_apply!(r::_TermRenderer, inst::_UiInstance, node::_UiNode,
                         v::Form)
    res = _ui_dispatch!(inst, (:set, _ui_sel(node), v))
    if res isa Tuple && res[1] === :invalid
        r.status = res[2]
    else
        r.status = ""
    end
    r.need_redraw = true
    return nothing
end

# ---- single-line editing -----------------------------------------------------

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

# Paste into a single-line field: newlines are dropped, not inserted.
function _ui_term_insert!(r::_TermRenderer, text::AbstractString)
    for c in text
        if c != '\n' && c != '\r'
            _ui_term_insert!(r, c)
        end
    end
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

# ---- keys --------------------------------------------------------------------

function _ui_term_edit_key!(r::_TermRenderer, inst::_UiInstance, node::_UiNode,
                            k::_UiKey)
    if k.name === :enter
        _ui_term_commit!(r, inst, node)
        return nothing
    elseif k.name === :tab && !k.shift
        _ui_term_commit!(r, inst, node)
        _ui_term_move_focus!(r, inst, 1)
        return nothing
    elseif k.name === :tab || k.name === :backtab
        _ui_term_commit!(r, inst, node)
        _ui_term_move_focus!(r, inst, -1)
        return nothing
    elseif k.name === :esc
        _ui_term_cancel_edit!(r)
        return nothing
    elseif k.name === :backspace
        if r.cursor > 0
            s = collect(r.buf)
            deleteat!(s, r.cursor)
            r.buf = String(s)
            r.cursor -= 1
            r.need_redraw = true
        end
        return nothing
    elseif k.name === :delete
        if r.cursor < length(r.buf)
            s = collect(r.buf)
            deleteat!(s, r.cursor + 1)
            r.buf = String(s)
            r.need_redraw = true
        end
        return nothing
    elseif k.name === :left
        r.cursor = max(0, r.cursor - 1); r.need_redraw = true
        return nothing
    elseif k.name === :right
        r.cursor = min(length(r.buf), r.cursor + 1); r.need_redraw = true
        return nothing
    elseif k.name === :home
        r.cursor = 0; r.need_redraw = true
        return nothing
    elseif k.name === :end
        r.cursor = length(r.buf); r.need_redraw = true
        return nothing
    elseif k.name === :char && k.ctrl && k.char == 'a'
        r.cursor = 0; r.need_redraw = true
        return nothing
    elseif k.name === :char && k.ctrl && k.char == 'e'
        r.cursor = length(r.buf); r.need_redraw = true
        return nothing
    elseif k.name === :char && k.ctrl && k.char == 'k'
        r.buf = String(collect(r.buf)[1:min(r.cursor, length(r.buf))])
        r.need_redraw = true
        return nothing
    elseif k.name === :char && k.ctrl && k.char == 'u'
        cs = collect(r.buf)
        r.buf = String(cs[min(r.cursor + 1, length(cs) + 1):end])
        r.cursor = 0
        r.need_redraw = true
        return nothing
    elseif k.name === :char && k.ctrl && k.char == 'w'
        cs = collect(r.buf)
        i = r.cursor
        while i >= 1 && cs[i] == ' '
            i -= 1
        end
        while i >= 1 && cs[i] != ' '
            i -= 1
        end
        r.buf = String(vcat(cs[1:i], cs[(r.cursor + 1):end]))
        r.cursor = i
        r.need_redraw = true
        return nothing
    elseif k.name === :char && k.char !== nothing && isprint(k.char) &&
           !k.ctrl && !k.alt
        _ui_term_insert!(r, k.char)
        return nothing
    elseif k.name === :paste
        _ui_term_insert!(r, k.text)
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

# Ctrl-C anywhere aborts the renderer.
_ui_term_ctrl_c(k::_UiKey) =
    k.name === :char && k.ctrl && !k.alt && k.char == 'c'

function _ui_term_key!(r::_TermRenderer, inst::_UiInstance, k::_UiKey)
    _ui_term_ctrl_c(k) && (r.quit = :abort; return nothing)
    # A composite root (the shell) handles its own keys after the global two.
    if r.comp !== nothing
        _comp_root_key!(r.comp, r, inst, k)
        r.need_redraw = true
        return nothing
    end
    node = _ui_term_focused(r, inst)
    if r.editing
        node === nothing && return nothing
        _ui_term_edit_key!(r, inst, node, k)
        return nothing
    end
    node === nothing && return nothing
    if k.name === :esc
        r.quit = :dismiss
    elseif k.name === :tab && !k.shift
        _ui_term_move_focus!(r, inst, 1)
    elseif k.name === :tab || k.name === :backtab
        _ui_term_move_focus!(r, inst, -1)
    elseif k.name === :up
        _ui_term_move_focus!(r, inst, -1)
    elseif k.name === :down
        _ui_term_move_focus!(r, inst, 1)
    elseif k.name === :enter
        _ui_term_activate!(r, inst, node)
    elseif k.name === :left || k.name === :right || k.name === :home ||
           k.name === :end
        _ui_term_adjust!(r, inst, node, k.name)
    elseif k.name === :char && k.ctrl && k.char == 'j'
        # Ctrl-J is the notebook's run key; the legacy widgets treat it as Enter
        # so a client that sends LF for Enter still works.
        _ui_term_activate!(r, inst, node)
    elseif k.name === :char && k.char == ' '
        kk = node.kind.name
        if kk === Symbol("checkbox") || kk === Symbol("toggle") ||
           kk === Symbol("button")
            _ui_term_activate!(r, inst, node)
        elseif _ui_term_editable(node)
            _ui_term_begin_edit!(r, node)
            _ui_term_insert!(r, ' ')
        end
    elseif k.name === :char && k.char !== nothing && isprint(k.char) &&
           !k.ctrl && !k.alt && _ui_term_editable(node)
        _ui_term_begin_edit!(r, node)
        _ui_term_insert!(r, k.char)
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
    width = max(_tb_size(r.backend)[1], 20)
    height = max(_tb_size(r.backend)[2], 3)
    _frame_begin!(r.frame, width, height)
    if r.comp !== nothing
        _comp_draw_themed!(r.comp, r, inst, width, height)
        r.need_redraw = false
        return nothing
    end
    node = _ui_term_focused(r, inst)
    focuspath = node === nothing ? nothing : node.path
    edit = nothing
    if r.editing && node !== nothing && r.editing_path == node.path
        edit = (node.path, r.buf, r.cursor)
    end
    lines = _ui_lines(inst, inst.root, width; edit = edit)

    # Scroll so the focused element is visible (the last row is the status bar).
    body = height - 1
    focusrow = node === nothing ? 0 :
               something(findfirst(l -> l.node !== nothing &&
                                        l.node.path === focuspath, lines), 0)
    start = 1
    if length(lines) > body
        f = focusrow == 0 ? 1 : focusrow
        start = clamp(f - body ÷ 2, 1, max(1, length(lines) - body + 1))
    end
    _term_emit_body!(r.frame, lines, width, body, start;
                     reversepath = focuspath)
    status = isempty(r.status) ?
             "tab: next   enter: activate/edit   esc: done   ctrl-c: abort" :
             r.status
    _term_emit_row!(r.frame, height,
                    _ui_line(_ui_clip(status, width)), width,
                    _ui_role(:status))
    if edit !== nothing
        col = _ui_term_edit_col(node, r.buf, r.cursor)
        row = focusrow == 0 ? 1 : clamp(focusrow - start + 1, 1, body)
        _term_move!(r.backend, row, col)
    else
        _term_move!(r.backend, height, 1; visible = false)
    end
    r.need_redraw = false
    return nothing
end

# ---- the loop ----------------------------------------------------------------

function _ui_term_tick!(r::_TermRenderer, inst::_UiInstance)
    try
        _tb_resize!(r.backend)
    catch
    end
    bytes = try
        _tb_drain!(r.backend)
    catch e
        e isa SshError || rethrow()
        r.quit = :dismiss
        UInt8[]
    end
    # The instance's ticker applies finished background work on its own task; it
    # takes the same lock, so the keys that mutate the tree and the draw that
    # reads it never race a result being applied.
    lock(inst.lock) do
        # Feed one byte at a time and stop as soon as the renderer decides to
        # quit: whatever follows (a whole line the user typed ahead) belongs to
        # the REPL, so hand the unconsumed tail back to the backend.
        done = () -> r.quit !== :none || inst.dismissed || inst.closed
        i = 1
        while i <= length(bytes) && !done()
            keys = _ui_kp_feed!(r.kp, bytes[i])
            i += 1
            for k in keys
                done() && break
                _ui_term_key!(r, inst, k)
            end
        end
        i <= length(bytes) && _tb_unread!(r.backend, @view bytes[i:end])
        t = done() ? nothing : _ui_kp_timeout!(r.kp)
        t === nothing || _ui_term_key!(r, inst, t)
        if inst.dirty || r.need_redraw
            _ui_term_draw!(r, inst)
            inst.dirty = false
        end
    end
    return nothing
end

function _ui_term_run!(r::_TermRenderer, inst::_UiInstance;
                       controller::Union{Nothing,Form} = nothing)
    # Attaching the renderer comes first: the tree's ticker treats "no renderer
    # and no work" as the end of a projection, so it must never see a window
    # where the widget is built and nobody is watching it.
    _ui_attach!(r, inst)
    # A second attach to the same instance reuses its tree; clear the previous
    # session's dismissal so it does not leave again immediately.
    lock(inst.lock) do
        inst.closed || (inst.dismissed = false)
        c = _ui_tree(inst)
        if c !== nothing && controller !== nothing
            try
                _comp_set_controller!(c, inst, controller)
            catch e
                e isa AirError || rethrow()
            end
        end
        r.comp = c
    end
    _tb_enter!(r.backend)
    _frame_reset!(r.frame)      # the alternate screen starts blank
    # The component leaves the renderer in the `finally`; the abort path below
    # still needs it, so it is declared here rather than only assigned there.
    c = nothing
    try
        while true
            _ui_term_tick!(r, inst)
            (inst.dismissed || inst.closed || r.quit !== :none) && break
            sleep(0.01)
        end
    finally
        # Leaving stops drawing, nothing more. The tree, its interaction state,
        # and any running evaluation stay with the instance; the ticker applies
        # a result and writes it to the widget's state even with nobody watching.
        c = r.comp
        r.comp = nothing
        if c !== nothing
            lock(inst.lock) do
                try
                    _comp_flush!(c, inst)
                catch
                end
                # The controller leaves with the renderer, before the instance
                # is detached: the element is no longer being shown, and doing
                # it here keeps the ticker from releasing an ephemeral
                # projection while a stale controller is still stored in it.
                if controller !== nothing && !inst.closed
                    try
                        _comp_set_controller!(c, inst, nothing)
                    catch
                    end
                end
            end
        end
        try
            _tb_leave!(r.backend)
        catch
        end
        _ui_detach!(r, inst)
    end
    if r.quit === :abort
        # Ctrl-C aborts the work as well as the renderer: the renderer is the
        # only place a user can signal it, and a job left running would finish
        # unseen. Dismissal is different — Esc leaves the work in flight on
        # purpose, so its result still lands in the widget's state.
        c === nothing || _comp_cancel_jobs!(c)
        throw(AirThrown(_error_object(Form(Symbol(":ctrl-c")))))
    end
    return naught
end

# ---- ui-show -----------------------------------------------------------------

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
    # A registered connection knows which byte source this session is on; when
    # there is none (a channel the connection registry never saw), fall back to
    # the session's own channel.
    h = _conn_current(env)
    h === nothing || return _conn_attach!(env, scope, h, _ui_key_form(inst.key))
    out = _context(env).out
    (out isa _SshChannelIO && out.tty) || throw(AirThrown(_error_object(
        Form(Symbol(":no-renderer")),
        Form("ui-show requires an interactive terminal session"))))
    r = _TermRenderer(_SshBackend(out))
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
