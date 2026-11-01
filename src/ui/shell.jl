################################################################################
# ui/shell.jl
#
# The tab shell: a row of tabs, each holding another widget form. The shell is
# what a connection attaches to, so it is the only component that opens and
# closes other components.
#
# Three rules, all of them the user's:
#
#   * Tab and Shift-Tab always switch tabs. No widget uses Tab for editing
#     (indentation is automatic), so the key is free here.
#   * Esc pops exactly one layer. It leaves a modal inside the active widget
#     first, then closes the active tab, and only then dismisses the shell. A
#     tab whose edits would be lost asks once before it closes.
#   * A tab is just a widget form. The shell stores the forms in its own state
#     mut, so a tab survives as long as the shell does — and no longer.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    _Tab

One tab: its title, the widget form it shows, and the live component built from
that form. The form is the durable part; the component is the transient view.
"""
mutable struct _Tab
    title::String
    form::Form
    comp::Union{Nothing,_Comp}
end

mutable struct _Shell <: _Comp
    base::_CompBase
    tabs::Vector{_Tab}
    active::Int
    confirm::Symbol                 # :none | :close
    width::Int
end

_comp_title(c::_Shell) = "shell"

# ---- construction ------------------------------------------------------------

# Build the component a tab's widget form names — the same node builder an
# instance uses, so a tab behaves exactly like a root widget.
function _sh_build_comp(inst::_UiInstance, form::Form)
    nodes = _UiNode[]
    node = _ui_build!(inst.env, inst.lscope, inst, form, nothing, "tab", nodes)
    return _comp_build_node(inst, node)
end

# Add a tab, activate it, and persist the shell.
function _sh_open!(c::_Shell, inst::_UiInstance, title::AbstractString, form::Form)
    tab = _Tab(String(title), form, nothing)
    try
        tab.comp = _ui_in_context(inst) do
            _sh_build_comp(inst, form)
        end
    catch e
        e isa AirError || rethrow()
        c.base.status = "cannot open " * String(title) * ": " *
                        sprint(showerror, e)
        tab.comp = nothing
    end
    push!(c.tabs, tab)
    c.active = length(c.tabs)
    c.base.top = 1
    if tab.comp !== nothing
        try
            _comp_start!(tab.comp, inst)
        catch e
            e isa AirError || rethrow()
            c.base.status = "cannot start " * String(title) * ": " *
                            sprint(showerror, e)
        end
    end
    _sh_store!(c, inst)
    return nothing
end

function _comp_shell(inst::_UiInstance, node::_UiNode)
    state = _comp_state_mut(node.params)
    base = _CompBase(node; state = state, nspath = _comp_captured_ns(inst))
    c = _Shell(base, _Tab[], 1, :none, 80)
    active = 1
    if state !== nothing
        v = _ui_in_context(inst) do
            canonicalize(state[])
        end
        tabs = _state_field(v, :tabs)
        if tabs isa FormContainer
            for el in tabs.seq
                f = to_form(el)
                spec = _state_field(f, :spec)
                spec === nothing && continue
                title = _state_string(f, :title)
                push!(c.tabs, _Tab(isempty(title) ? "tab" : title, spec, nothing))
            end
        end
        a = _state_field(v, :active)
        if a !== nothing
            l = _leafof(a)
            l isa Real && (active = Int(l))
        end
    end
    # The default tabs are opened by `_comp_start!`, not here: a headless render
    # of `(ui-shell)` must neither create muts nor write the state.
    c.active = clamp(active, 1, max(length(c.tabs), 1))
    _sh_build_tabs!(c, inst)
    return c
end

# Build the component for any tab that has none yet: the stored tabs keep their
# forms, and the default tabs start as forms only.
function _sh_build_tabs!(c::_Shell, inst::_UiInstance)
    for tab in c.tabs
        tab.comp === nothing || continue
        try
            tab.comp = _ui_in_context(inst) do
                _sh_build_comp(inst, tab.form)
            end
        catch e
            e isa AirError || rethrow()
            c.base.status = "cannot open " * tab.title * ": " *
                            sprint(showerror, e)
        end
    end
    return nothing
end

# The tabs a fresh shell starts with: a browser of this namespace and a scratch
# notebook in it.
function _sh_default_tabs!(c::_Shell, inst::_UiInstance)
    env = inst.env
    scope = inst.lscope
    c.tabs = _Tab[]
    for (head, title) in ((Symbol("ui-browser"), "browser"),
                          (Symbol("ui-notebook"), "scratch"))
        call = FormContainer(FormSeq(FormValue[_store_form(Form(head))]), FormMap())
        form = _ui_in_context(inst) do
            head === Symbol("ui-browser") ? _bi_ui_browser(env, scope, call) :
                                            _bi_ui_notebook(env, scope, call)
        end
        push!(c.tabs, _Tab(title, form, nothing))
    end
    c.active = 1
    return nothing
end

# ---- persistence -------------------------------------------------------------

function _sh_state_form(c::_Shell)
    tabs = FormContainer(FormSeq(FormValue[
        _store_form(_ns_form(Form[], Pair{Symbol,Form}[
            Symbol(":title") => Form(t.title),
            Symbol(":spec") => t.form])) for t in c.tabs]), FormMap())
    return _ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":tabs") => tabs,
        Symbol(":active") => Form(c.active)])
end

function _sh_store!(c::_Shell, inst::_UiInstance)
    c.base.state === nothing && return nothing
    _comp_set_state!(c, inst, _sh_state_form(c))
    return nothing
end

function _comp_flush!(c::_Shell, inst::_UiInstance)
    for t in c.tabs
        t.comp === nothing && continue
        try
            _comp_flush!(t.comp, inst)
        catch e
            e isa AirError || rethrow()
        end
    end
    _sh_store!(c, inst)
    return nothing
end

function _comp_close!(c::_Shell, inst::_UiInstance)
    for t in c.tabs
        t.comp === nothing && continue
        try
            _comp_close!(t.comp, inst)
        catch e
            e isa AirError || rethrow()
        end
    end
    _sh_store!(c, inst)
    return nothing
end

# ---- the active tab ----------------------------------------------------------

_sh_comp(c::_Shell) = (1 <= c.active <= length(c.tabs)) ? c.tabs[c.active].comp :
                                                          nothing

_sh_title(c::_Shell) = (1 <= c.active <= length(c.tabs)) ? c.tabs[c.active].title :
                                                          ""

_comp_dirty(c::_Shell, inst::_UiInstance) = any(
    t -> t.comp !== nothing && _comp_dirty(t.comp, inst), c.tabs)

# A shell owns no background work itself; its tabs do, so it starts and polls
# them on their behalf. A fresh shell also opens its default tabs here — starting
# is the moment the shell becomes a live widget, and a headless `ui-render` never
# starts one, so it shows no tabs.
function _comp_start!(c::_Shell, inst::_UiInstance)
    fresh = isempty(c.tabs)
    if fresh
        _sh_default_tabs!(c, inst)
        _sh_build_tabs!(c, inst)
        _sh_store!(c, inst)
    end
    for t in c.tabs
        t.comp === nothing && continue
        try
            _comp_start!(t.comp, inst)
        catch e
            e isa AirError || rethrow()
            c.base.status = "cannot start " * t.title * ": " * sprint(showerror, e)
        end
    end
    return nothing
end

_comp_running(c::_Shell) =
    any(t -> t.comp !== nothing && _comp_running(t.comp), c.tabs)

function _comp_job_label(c::_Shell)
    for t in c.tabs
        t.comp !== nothing && _comp_running(t.comp) || continue
        return _comp_job_label(t.comp)
    end
    return "running…"
end

function _comp_tick!(c::_Shell, inst::_UiInstance)
    done = false
    for t in c.tabs
        t.comp === nothing && continue
        _comp_tick!(t.comp, inst) && (done = true)
    end
    done || return false
    lock(inst.lock) do
        inst.dirty = true
    end
    return true
end

# Close the active tab (after saving its state). Returns the shell's fate: with
# no tabs left there is nothing to show, so the shell dismisses.
function _sh_close_active!(c::_Shell, inst::_UiInstance)
    if !isempty(c.tabs)
        t = c.tabs[c.active]
        if t.comp !== nothing
            try
                _comp_close!(t.comp, inst)
            catch e
                e isa AirError || rethrow()
            end
        end
        deleteat!(c.tabs, c.active)
    end
    c.base.status = ""
    c.base.top = 1
    if isempty(c.tabs)
        _sh_store!(c, inst)
        return :dismiss
    end
    c.active = clamp(c.active, 1, length(c.tabs))
    _sh_store!(c, inst)
    return :handled
end

# Switch to tab `i`.
function _sh_select!(c::_Shell, inst::_UiInstance, i::Int)
    (1 <= i <= length(c.tabs)) || return :handled
    c.active = i
    c.base.status = ""
    c.base.top = 1
    _sh_store!(c, inst)
    return :handled
end

# ---- rendering ---------------------------------------------------------------

function _sh_bar(c::_Shell, width::Int)
    spans = _UiSpan[]
    for (i, t) in enumerate(c.tabs)
        i > 1 && push!(spans, _UiSpan("│", _ui_role(:border)))
        role = i == c.active ? :tab_active : :tab_inactive
        push!(spans, _UiSpan(" " * t.title * " ", _ui_role(role)))
    end
    isempty(c.tabs) && push!(spans, _UiSpan(" (no tabs)", _ui_role(:muted)))
    return _ui_styled(spans)
end

function _comp_lines(c::_Shell, inst::_UiInstance, width::Int)
    c.width = width
    out = _UiLine[_sh_bar(c, width)]
    child = _sh_comp(c)
    child === nothing && return out
    append!(out, _comp_lines(child, inst, width))
    return out
end

_comp_cursor(c::_Shell, inst::_UiInstance) = begin
    child = _sh_comp(c)
    cur = child === nothing ? nothing : _comp_cursor(child, inst)
    cur === nothing ? (1, 0) : (cur[1] + 1, cur[2])
end

function _comp_status(c::_Shell, inst::_UiInstance)
    if c.confirm === :close
        return string("discard changes in \"", _sh_title(c), "\"?  y/n")
    end
    isempty(c.base.status) || return c.base.status
    child = _sh_comp(c)
    child === nothing && return "no tabs — esc: quit"
    msg = _comp_status(child, inst)
    head = string(length(c.tabs), " tab", length(c.tabs) == 1 ? "" : "s")
    return isempty(msg) ? head : head * "  ·  " * msg
end

_comp_hints(c::_Shell) = c.confirm === :close ?
    ["y: discard" => "y", "n: cancel" => "n"] :
    ["tab: next" => "tab", "alt-1..9: jump" => "alt-1..9",
     "esc: close tab" => "esc"]

# The shell draws its own frame: the tab bar owns row 1, the active widget's
# body fills rows 2…height-1, and the status row stays at the bottom.
function _comp_root_draw!(c::_Shell, r, inst::_UiInstance, width::Int, height::Int)
    _term_emit_row!(r.frame, 1, _sh_bar(c, width), width)
    body = max(height - 2, 1)
    child = _sh_comp(c)
    cur = nothing
    lines = child === nothing ?
        _UiLine[_ui_styled([_UiSpan("(no tabs)", _ui_role(:muted))])] :
        _comp_lines(child, inst, width)
    if child !== nothing
        cur = _comp_cursor(child, inst)
        b = child.base
        if cur !== nothing
            (row, col) = cur
            row < b.top && (b.top = row)
            row >= b.top + body && (b.top = row - body + 1)
            col < b.left && (b.left = col)
            col >= b.left + width - 1 && (b.left = max(col - width + 2, 0))
        end
        b.top = clamp(b.top, 1, max(1, length(lines) - body + 1))
        b.left = max(b.left, 0)
        if b.left > 0
            lines = [_ui_shift_line(l, b.left) for l in lines]
            cur === nothing || (cur = (cur[1], cur[2] - b.left))
        end
    end
    _term_emit_body!(r.frame, lines, width, body, 1; row = 2)
    status = _comp_status_line(c, inst, width)
    _term_emit_row!(r.frame, height, _ui_line(status, nothing), width,
                    _ui_role(:status))
    if cur !== nothing && 1 <= cur[1] <= body
        _term_move!(r.backend, cur[1] + 1, min(max(cur[2], 0) + 1, width))
    else
        _term_move!(r.backend, height, 1; visible = false)
    end
    return nothing
end

# ---- keys --------------------------------------------------------------------

# Whether a key is an unmodified `c`.
_sh_char(k::_UiKey, c::Char) =
    k.name === :char && !k.ctrl && !k.alt && k.char == c

function _comp_key!(c::_Shell, inst::_UiInstance, k::_UiKey)
    if c.confirm === :close
        # Only `y` discards. Anything else — `n`, Esc, a stray key — keeps the
        # tab and drops back to it, so the destructive answer is never guessed.
        if _sh_char(k, 'y') || _sh_char(k, 'Y')
            c.confirm = :none
            return _sh_close_active!(c, inst)
        end
        c.confirm = :none
        return :handled
    end

    if k.name === :tab || k.name === :backtab
        isempty(c.tabs) && return :handled
        d = (k.name === :backtab || k.shift) ? -1 : 1
        i = mod1(c.active + d, length(c.tabs))
        return _sh_select!(c, inst, i)
    end

    if k.name === :char && k.alt && k.char !== nothing &&
       '1' <= k.char <= '9'
        return _sh_select!(c, inst, Int(k.char) - Int('0'))
    end

    if k.name === :esc
        child = _sh_comp(c)
        if child !== nothing && _comp_dirty(child, inst)
            c.confirm = :close
            return :handled
        end
        return _sh_close_active!(c, inst)
    end

    child = _sh_comp(c)
    child === nothing && return :bubble
    res = _comp_key!(child, inst, k)
    if res isa Tuple && !isempty(res) && res[1] === :open
        _sh_open!(c, inst, res[2], res[3])
        return :handled
    end
    return res
end
