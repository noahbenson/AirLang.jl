################################################################################
# ui/chat.jl
#
# The chat component: a conversation with a peer over a pair of streams. One
# stream carries what this side sends, the other what this side receives, so a
# chat is a widget the caller wires up rather than a widget that finds its own
# transport:
#
#     (def to-alice   (stream))
#     (def from-alice (stream))
#     (ui-open (ui-chat in=from-alice out=to-alice peer=:alice))
#
# Three rules shape it, and all three come from the same idea — a message is a
# *value*, and code is not sent:
#
#   * **Messages are cells.** Each one renders as a block with its sender's
#     background (`:user_bg` for this side, `:peer_bg` for the other), so the
#     two directions are distinguishable at a glance. A string body is plain
#     text; any other body is syntax-highlighted source.
#   * **Enter inserts a newline; Ctrl-J sends.** The input is a full code block,
#     so the draft gets automatic indentation, pairing, and highlighting.
#   * **A draft beginning with `(` is code.** On send, the source is appended to
#     the sender's log only, evaluated in the chat's namespace under the
#     captured context, and the *result* is appended to both logs and posted.
#     The peer never receives the source — only what it evaluated to.
#
# A pump task per attached widget `fetch`es the incoming stream with a short
# timeout and appends what it finds, so the log is live without the input loop
# ever blocking on it.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    _ChatMsg

One message: who sent it (`:me` or `:peer`), what it is (`:text`, `:code`,
`:result`, or `:error`), its text, and when it arrived.
"""
mutable struct _ChatMsg
    from::Symbol
    kind::Symbol
    body::String
    at::Float64
end

"""
    _Chat

A conversation widget. `input` is a `_CodeBlock` used only for editing — it is
never run, so its output area stays empty. `inbox`/`outbox` hold the stream
externs; `pump` is the task reading `inbox`.
"""
mutable struct _Chat <: _Comp
    base::_CompBase
    input::_CodeBlock
    msgs::Vector{_ChatMsg}
    lock::ReentrantLock             # guards `stopped`
    peer::String
    inbox::Union{Nothing,Form}
    outbox::Union{Nothing,Form}
    pump::Union{Nothing,Task}
    stopped::Bool
    width::Int
    stick::Bool                     # pin the log to its newest message
    scroll::Int                     # first message in view when not stuck
    log_rows::Int                   # the log's height, from the last draw
end

_comp_title(c::_Chat) = "chat"

# ---- small helpers -----------------------------------------------------------

# A map-form field whose leaf is a keyword or string, as plain text.
function _chat_leaf_text(f)
    f = to_form(f)
    s = _ui_string(f)
    s === nothing || return String(s)
    l = _leafof(f)
    return l isa Symbol ? lstrip(String(l), ':') : ""
end

# A stored `from=`/`kind=` field as a symbol (`:me`, `:text`, …).
function _chat_leaf_symbol(f, default::Symbol)
    l = _leafof(to_form(f))
    l isa Symbol || return default
    return Symbol(lstrip(String(l), ':'))
end

_chat_clock(secs::Real) =
    secs > 0 ? Dates.format(Dates.unix2datetime(secs), "HH:MM") : ""

# ---- construction ------------------------------------------------------------

function _chat_msg_from_form(f::Form)
    from = _state_field(f, :from)
    kind = _state_field(f, :kind)
    at = _state_field(f, :at)
    t = at !== nothing && _is_time_form(at) ? _time_secs(at) : 0.0
    return _ChatMsg(from === nothing ? :peer : _chat_leaf_symbol(from, :peer),
                    kind === nothing ? :text : _chat_leaf_symbol(kind, :text),
                    _state_string(f, :body), t)
end

function _comp_chat(inst::_UiInstance, node::_UiNode)
    state = _comp_state_mut(node.params)
    nspath = _comp_namespace(node.params, _comp_captured_ns(inst))
    inbox = get(node.params, _map_key(:in), nothing)
    outbox = get(node.params, _map_key(:out), nothing)
    peer = get(node.params, _map_key(:peer), nothing)
    base = _CompBase(node; state = state, nspath = nspath)
    # The input shares the widget node (so its title and namespace match) but
    # owns no state of its own: the chat persists the draft with the log.
    input = _CodeBlock(_CompBase(node; state = nothing, nspath = nspath),
                       _TextBuffer(""), "", :code, nothing, _UiLine[], "", false,
                       nothing, nothing, 80, nothing, "")
    c = _Chat(base, input, _ChatMsg[], ReentrantLock(),
              peer === nothing ? "" : _chat_leaf_text(peer),
              inbox isa StreamForm ? inbox : nothing,
              outbox isa StreamForm ? outbox : nothing,
              nothing, false, 80, true, 1, 1)
    if state !== nothing
        v = _ui_in_context(inst) do
            canonicalize(state[])
        end
        log = _state_field(v, :log)
        if log isa FormContainer
            for el in log.seq
                push!(c.msgs, _chat_msg_from_form(to_form(el)))
            end
        end
        draft = _state_string(v, :draft)
        isempty(draft) || _tb_set_text!(c.input.buf, draft)
    end
    c.stick = true
    c.scroll = max(length(c.msgs), 1)
    return c
end

# The pump belongs to a renderer session, not to the widget: a headless
# `ui-render` builds the component and must not leave a fetching task behind.
function _comp_start!(c::_Chat, inst::_UiInstance)
    c.inbox === nothing || _chat_start!(c, inst)
    return nothing
end

# ---- persistence -------------------------------------------------------------

# The state value: `(log=((from=:me kind=:text body="…" at=(time …)) …) draft="…")`.
function _chat_state_form(c::_Chat)
    log = FormValue[]
    for m in c.msgs
        push!(log, _store_form(_ns_form(Form[], Pair{Symbol,Form}[
            Symbol(":from") => Form(Symbol(":", String(m.from))),
            Symbol(":kind") => Form(Symbol(":", String(m.kind))),
            Symbol(":body") => Form(m.body),
            Symbol(":at") => _mk_time(m.at)])))
    end
    return _ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":log") => FormContainer(FormSeq(log), FormMap()),
        Symbol(":draft") => Form(_tb_text(c.input.buf))])
end

function _chat_store!(c::_Chat, inst::_UiInstance)
    c.base.state === nothing && return nothing
    _comp_set_state!(c, inst, _chat_state_form(c))
    return nothing
end

# ---- sending -----------------------------------------------------------------

# Run a stream verb on the chat's own streams, inside the instance's context.
function _chat_stream_call(name::Symbol, args::Vector{FormValue}, extra::Pair...)
    map = Pair{Symbol,FormValue}[k => _store_form(v) for (k, v) in extra]
    seq = FormValue[_store_form(Form(name))]
    append!(seq, args)
    return FormContainer(FormSeq(seq), FormMap(map))
end

_chat_scope(c::_Chat, inst::_UiInstance) =
    (ns = _comp_ns(c, inst);
     ns === nothing ? inst.lscope : _ns_scope(inst.env, inst.lscope, ns))

# Whether the draft is in code mode (it begins with an opening paren).
_chat_code_mode(c::_Chat) = startswith(lstrip(_tb_text(c.input.buf)), "(")

# Append one message to the log. It must not yield: it is the pump's only
# mutation of `msgs`. The view's anchoring is the caller's business — a send
# re-sticks, an arriving message leaves a reader who scrolled away in place.
function _chat_append!(c::_Chat, from::Symbol, kind::Symbol, body::AbstractString)
    push!(c.msgs, _ChatMsg(from, kind, String(body), _now_secs()))
    return nothing
end

# `post` one value to the peer. A full stream would block the input loop, so the
# wait is bounded and an expiry is reported instead.
function _chat_post!(c::_Chat, inst::_UiInstance, v::Form)
    if c.outbox === nothing
        c.base.status = "no output stream"
        return nothing
    end
    call = _chat_stream_call(Symbol("post"),
                             FormValue[c.outbox, _store_form(v)],
                             Symbol(":timeout") => Form(_CHAT_POST_TIMEOUT))
    try
        r = _ui_in_context(inst) do
            _bi_post(inst.env, _chat_scope(c, inst), call)
        end
        r === naught && (c.base.status = "the peer is not reading")
    catch e
        e isa AirError || rethrow()
        c.base.status = "send failed: " * sprint(showerror, e)
    end
    return nothing
end

const _CHAT_POST_TIMEOUT = 2.0
const _CHAT_FETCH_TIMEOUT = 0.1

# Clear the input after a send.
function _chat_clear_draft!(c::_Chat)
    _tb_set_text!(c.input.buf, "")
    c.input.pair = nothing
    return nothing
end

# Ctrl-J: send the draft. A code draft is evaluated in the background, logged
# to this side only, and its result is what travels (see `_comp_job_done!`);
# the peer never receives the source.
function _chat_send!(c::_Chat, inst::_UiInstance)
    text = _tb_text(c.input.buf)
    if isempty(strip(text))
        c.base.status = "nothing to send"
        return nothing
    end
    if _chat_code_mode(c)
        if _comp_running(c)
            c.base.status = "still running"
            return nothing
        end
        _chat_append!(c, :me, :code, text)
        # The draft clears and the log persists before evaluation starts, so a
        # slow form never holds the input hostage.
        _chat_clear_draft!(c)
        _chat_store!(c, inst)
        _comp_start_job!(c, inst, () -> _comp_eval(c, inst, text);
                         label = "evaluating…")
        c.base.status = ""
        return nothing
    end
    c.base.status = ""
    _chat_append!(c, :me, :text, text)
    _chat_post!(c, inst, Form(text))
    _chat_clear_draft!(c)
    c.stick = true
    _chat_store!(c, inst)
    return nothing
end

# Apply a finished code send: log the results, then post each value.
function _comp_job_done!(c::_Chat, inst::_UiInstance, res)
    tag, value = res
    if tag !== :ok
        _chat_append!(c, :me, :error, "error: " * value)
        c.base.status = "error"
    else
        status, result = value
        if status === :error
            _chat_append!(c, :me, :error, "error: " * result)
            c.base.status = "error"
        else
            width = max(c.width - 2, 8)
            for v in result
                _chat_append!(c, :me, :result,
                              air_pretty_string(inst.env, v; width = width))
                _chat_post!(c, inst, v)
            end
            c.base.status = ""
        end
    end
    c.stick = true
    _chat_store!(c, inst)
    return nothing
end

# ---- receiving ---------------------------------------------------------------

# Tell the renderer to draw again from outside the key loop.
_chat_dirty!(inst::_UiInstance) = lock(inst.lock) do
    inst.dirty = true
end

# Append one received value: a string is text, everything else is source.
function _chat_receive!(c::_Chat, inst::_UiInstance, v::Form)
    s = _ui_string(v)
    if s === nothing
        s = air_pretty_string(inst.env, v; width = max(c.width - 2, 8))
        _chat_append!(c, :peer, :code, s)
    else
        _chat_append!(c, :peer, :text, s)
    end
    _chat_store!(c, inst)
    _chat_dirty!(inst)
    return nothing
end

# The pump: fetch with a short timeout, append, repeat. It stops on close, and a
# stream error (a closed stream, a permission denial) ends it with a status
# message rather than an unobserved task failure.
function _chat_start!(c::_Chat, inst::_UiInstance)
    c.stopped = false
    c.pump = @async _chat_pump!(c, inst)
    return nothing
end

function _chat_pump!(c::_Chat, inst::_UiInstance)
    while true
        lock(c.lock) do
            c.stopped && return nothing
        end
        call = _chat_stream_call(Symbol("fetch"), FormValue[c.inbox],
                                 Symbol(":timeout") => Form(_CHAT_FETCH_TIMEOUT))
        v = try
            _ui_in_context(inst) do
                _bi_fetch(inst.env, _chat_scope(c, inst), call)
            end
        catch e
            e isa InterruptException && return nothing
            lock(c.lock) do
                c.base.status = "receive failed: " * sprint(showerror, e)
            end
            _chat_dirty!(inst)
            return nothing
        end
        v === naught && continue
        _chat_receive!(c, inst, v)
    end
end

_comp_flush!(c::_Chat, inst::_UiInstance) = _chat_store!(c, inst)
_comp_close!(c::_Chat, inst::_UiInstance) = _chat_stop!(c, inst)

function _chat_stop!(c::_Chat, inst::_UiInstance)
    lock(c.lock) do
        c.stopped = true
    end
    p = c.pump
    if p !== nothing
        # The pump is inside a bounded fetch; wait for it to notice, but never
        # let a stuck stream hold a detach open.
        t0 = time()
        while !istaskdone(p) && time() - t0 < 0.5
            sleep(0.005)
        end
        c.pump = nothing
    end
    _chat_store!(c, inst)
    return nothing
end

# ---- rendering ---------------------------------------------------------------

# Pad a run of spans to the drawing width with the message's background, so a
# cell's tint spans the whole row.
function _chat_pad!(spans::Vector{_UiSpan}, width::Int, st::_UiStyle)
    used = 0
    for s in spans
        used += textwidth(s.text)
    end
    pad = width - used
    pad > 0 && push!(spans, _UiSpan(repeat(" ", pad), st))
    return spans
end

# The body spans of a message, one vector per logical line.
function _chat_body_spans(m::_ChatMsg)
    m.kind === :text && return [[_UiSpan(String(l), _ui_role(:text))]
                                for l in split(m.body, '\n')]
    m.kind === :error && return [[_UiSpan(String(l), _ui_role(:error))]
                                 for l in split(m.body, '\n')]
    return _hl_lines(m.body)
end

# One message as a styled block: a header row naming the sender, then the body.
function _chat_msg_lines(c::_Chat, m::_ChatMsg, width::Int)
    bg = m.from === :me ? _ui_role(:user_bg) : _ui_role(:peer_bg)
    fg = _ui_style_with(_ui_role(:muted); bg = bg.bg)
    head = m.from === :me ? "you" : (isempty(c.peer) ? "peer" : c.peer)
    clock = _chat_clock(m.at)
    isempty(clock) || (head *= "  " * clock)
    out = _UiLine[]
    push!(out, _ui_styled(_chat_pad!([_UiSpan(head, fg)], width, fg)))
    body = _ui_style_with(_ui_role(:text); bg = bg.bg)
    for spans in _chat_body_spans(m)
        styled = Vector{_UiSpan}()
        for s in spans
            push!(styled, _UiSpan(s.text, _ui_style_with(s.style; bg = bg.bg)))
        end
        push!(out, _ui_styled(_chat_pad!(styled, width, body)))
    end
    return out
end

# The message block as it would be drawn at the current width (used for paging).
function _chat_msg_height(c::_Chat, i::Int)
    return length(_chat_msg_lines(c, c.msgs[i], max(c.width - 1, 8)))
end

# The window of message lines to draw, anchored at the bottom when stuck and at
# `scroll` otherwise. A single message taller than the window shows its tail (at
# the bottom) or its head (while anchored).
function _chat_window(c::_Chat, width::Int, rows::Int)
    n = length(c.msgs)
    if n == 0
        c.scroll = 1
        return _UiLine[]
    end
    blocks = Vector{Vector{_UiLine}}()
    if c.stick
        # Fill from the newest message back. The newest block always joins the
        # window, even when it alone overflows; its tail is then clipped below.
        total = 0
        i = n
        while i >= 1
            blk = _chat_msg_lines(c, c.msgs[i], width)
            !isempty(blocks) && total + length(blk) > rows && break
            pushfirst!(blocks, blk)
            total += length(blk)
            i -= 1
        end
        # `i` now names the newest message that did not fit: it leads next time.
        c.scroll = clamp(i + 1, 1, n)
        lines = _UiLine[]
        for b in blocks
            append!(lines, b)
        end
        length(lines) > rows && (lines = lines[end - rows + 1:end])
        return lines
    end
    total = 0
    j = clamp(c.scroll, 1, n)
    while j <= n
        blk = _chat_msg_lines(c, c.msgs[j], width)
        if total + length(blk) > rows
            isempty(blocks) && push!(blocks, blk)
            break
        end
        push!(blocks, blk)
        total += length(blk)
        j += 1
    end
    lines = _UiLine[]
    for b in blocks
        append!(lines, b)
    end
    length(lines) > rows && (lines = lines[1:rows])
    return lines
end

function _comp_lines(c::_Chat, inst::_UiInstance, width::Int)
    return _chat_window(c, max(width - 1, 8), max(c.log_rows, 1))
end

_comp_cursor(c::_Chat, inst::_UiInstance) =
    (c.input.buf.row, _tb_display_col(c.input.buf))

_comp_dirty(c::_Chat, inst::_UiInstance) = !isempty(strip(_tb_text(c.input.buf)))

function _comp_status(c::_Chat, inst::_UiInstance)
    isempty(c.base.status) || return c.base.status
    if _chat_code_mode(c)
        v = _ui_closure(_tb_text(c.input.buf))
        return v[1] === :ok ? "code · closed" :
               v[1] === :incomplete ? "code · unclosed" : "code · error"
    end
    return isempty(c.peer) ? "" : "peer: " * c.peer
end

_comp_hints(c::_Chat) =
    ["ctrl-j: send" => "^J send", "ctrl-v: scroll" => "^V scroll",
     "esc: done" => "esc"]

# ---- scrolling ---------------------------------------------------------------

# Move the view by `d` messages, positive toward the newest.
function _chat_scroll_msg!(c::_Chat, d::Int)
    n = length(c.msgs)
    n == 0 && return nothing
    (d > 0 && c.stick) && return nothing
    c.stick = false
    c.scroll = clamp(c.scroll + d, 1, n)
    c.scroll >= n && (c.stick = true)
    return nothing
end

# Move the view by a page of message rows, in either direction.
function _chat_scroll_page!(c::_Chat, dir::Int)
    n = length(c.msgs)
    n == 0 && return nothing
    c.stick = false
    acc = 0
    i = clamp(c.scroll, 1, n)
    if dir > 0
        while i <= n && acc < c.log_rows
            acc += _chat_msg_height(c, i)
            i += 1
        end
        c.scroll = clamp(i, 1, n)
        c.scroll >= n && (c.stick = true)
    else
        while i > 1 && acc < c.log_rows
            i -= 1
            acc += _chat_msg_height(c, i)
        end
        c.scroll = clamp(i, 1, n)
    end
    return nothing
end

# ---- keys --------------------------------------------------------------------

function _comp_key!(c::_Chat, inst::_UiInstance, k::_UiKey)
    if k.name === :esc || k.name === :tab || k.name === :backtab
        return :bubble
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'j'
        _chat_send!(c, inst)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'v'
        _chat_scroll_msg!(c, 1)
        return :handled
    elseif k.name === :char && k.alt && k.char == 'v'
        _chat_scroll_msg!(c, -1)
        return :handled
    elseif k.name === :pageup && c.log_rows > 0
        _chat_scroll_page!(c, -1)
        return :handled
    elseif k.name === :pagedown && c.log_rows > 0
        _chat_scroll_page!(c, 1)
        return :handled
    elseif k.name === :char && k.alt && k.char in ('l', ']', ';')
        # The buffer's editor extras (go to line, bracket match, comment toggle)
        # have nowhere to show their prompts here; the draft is a few lines.
        return :bubble
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 's'
        return :bubble
    end
    c.base.status = ""
    res = _comp_key!(c.input, inst, k)
    return res === :bubble ? :bubble : :handled
end

# ---- drawing -----------------------------------------------------------------

# The chat is not a document with a cursor somewhere inside it: the log scrolls
# on its own and the input is pinned to the bottom. So it draws its own frame —
# the log window, a rule, the input (1–5 rows), and the status row — rather than
# using the shared root draw, which scrolls to keep the cursor visible.
function _comp_root_draw!(c::_Chat, r, inst::_UiInstance, width::Int, height::Int)
    c.width = width
    b = c.input.buf
    input_h = clamp(_tb_nlines(b), 1, 5)
    log_rows = max(height - 1 - input_h - 1, 0)
    c.log_rows = log_rows
    doc = _UiLine[]
    win = log_rows > 0 ? _chat_window(c, max(width - 1, 8), log_rows) : _UiLine[]
    # The log hugs the rule above the input; unused rows are blank above it.
    for _ in 1:max(log_rows - length(win), 0)
        push!(doc, _ui_styled(_UiSpan[]))
    end
    append!(doc, win)
    push!(doc, _ui_styled([_UiSpan(repeat("─", max(width - 1, 8)),
                                   _ui_role(:border))]))
    ilines = _comp_lines(c.input, inst, width)
    in_top = clamp(b.row - input_h + 1, 1, max(1, length(ilines) - input_h + 1))
    for k in in_top:min(length(ilines), in_top + input_h - 1)
        push!(doc, ilines[k])
    end
    while length(doc) < height - 1
        push!(doc, _ui_styled(_UiSpan[]))
    end
    _term_emit_body!(r.frame, doc, width, height - 1, 1)
    _term_emit_row!(r.frame, height,
                    _ui_line(_comp_status_line(c, inst, width)), width,
                    _ui_role(:status))
    currow = log_rows + 1 + (b.row - in_top + 1)
    curcol = _tb_display_col(b) + 1
    _term_move!(r.backend, currow, min(curcol, width))
    return nothing
end
