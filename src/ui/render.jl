################################################################################
# ui/render.jl
#
# The renderer protocol and the headless text renderer.
#
# A renderer is a view: it reads the instance's tree, values, and validation
# reasons, shapes them for its medium, and reports only semantic events back
# through `_ui_dispatch!`. It never validates, stores, or asserts anything. The
# runtime notifies every attached renderer after an accepted change (including
# a programmatic one), which is how multiple views stay in step.
#
# `_UiLine` is the shared layout unit: a line of text tagged with the element it
# belongs to. The text renderer drops the tag; the terminal renderer uses it to
# highlight the focused element.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

struct _UiLine
    text::String
    node::Union{Nothing,_UiNode}
end

_ui_line(text::AbstractString, node::Union{Nothing,_UiNode} = nothing) =
    _UiLine(String(text), node)

# ---- attachments -------------------------------------------------------------

function _ui_attach!(r::_UiRenderer, inst::_UiInstance)
    r in inst.renderers || push!(inst.renderers, r)
    return nothing
end

function _ui_detach!(r::_UiRenderer, inst::_UiInstance)
    filter!(x -> x !== r, inst.renderers)
    return nothing
end

# Mark the instance changed so every attached renderer redraws on its next tick.
function _ui_notify!(inst::_UiInstance)
    inst.epoch += 1
    inst.dirty = true
    return nothing
end

_ui_focusable(node::_UiNode) =
    _ui_kind_mutable(node.kind) || node.kind.name === Symbol("button")

# The focusable elements in pre-order (the renderer's tab order).
function _ui_focus_order(inst::_UiInstance)
    out = _UiNode[]
    _ui_collect_focus!(out, inst.root)
    return out
end

function _ui_collect_focus!(out::Vector{_UiNode}, node::_UiNode)
    _ui_focusable(node) && push!(out, node)
    for c in node.children
        _ui_collect_focus!(out, c)
    end
    return nothing
end

# ---- value spelling ----------------------------------------------------------

# The printable text of a value: strings as themselves, anything else via air.
_ui_vtext(x::Form) = _ui_display_text(x)

function _ui_bar(v, lo, hi, w::Int)
    t = hi == lo ? 1.0 : (Float64(v) - Float64(lo)) / (Float64(hi) - Float64(lo))
    t = clamp(t, 0.0, 1.0)
    n = clamp(round(Int, t * w), 0, w)
    return "[" * repeat("#", n) * repeat("-", w - n) * "]"
end

function _ui_range_bar(lo, hi, minv, maxv, w::Int)
    span = maxv == minv ? 1.0 : Float64(maxv) - Float64(minv)
    a = clamp(round(Int, (Float64(lo) - Float64(minv)) / span * w), 0, w)
    b = clamp(round(Int, (Float64(hi) - Float64(minv)) / span * w), 0, w)
    a, b = minmax(a, b)
    return "[" * repeat("-", a) * repeat("#", b - a) * repeat("-", w - b) * "]"
end

# The option label whose value is `v`, or the printed value.
function _ui_option_text(opts, v::Form)
    for (label, value) in opts
        _eq(value, v) && return label
    end
    return _ui_vtext(v)
end

function _ui_multi_text(node::_UiNode)
    els = _ui_seq_elements(node.value)
    els === nothing && return _ui_vtext(node.value)
    opts = _ui_options(node.params)
    parts = String[]
    for (label, value) in opts
        on = any(e -> _eq(e, value), els)
        push!(parts, (on ? "[x] " : "[ ] ") * label)
    end
    return join(parts, "  ")
end

function _ui_radio_text(node::_UiNode)
    opts = _ui_options(node.params)
    parts = String[]
    for (label, value) in opts
        push!(parts, (_eq(value, node.value) ? "(*) " : "( ) ") * label)
    end
    return join(parts, "  ")
end

function _ui_selslider_text(node::_UiNode)
    opts = _ui_options(node.params)
    parts = String[]
    for (label, value) in opts
        push!(parts, (_eq(value, node.value) ? "(o) " : "  ") * label)
    end
    return join(parts, "  ")
end

# ---- layout ------------------------------------------------------------------

_ui_indent(lines::Vector{_UiLine}, n::Int) =
    [_ui_line(repeat(" ", n) * l.text, l.node) for l in lines]

function _ui_clip(s::AbstractString, width::Int)
    width <= 0 && return String(s)
    textwidth(s) <= width && return String(s)
    io = IOBuffer()
    w = 0
    for c in s
        cw = textwidth(c)
        w + cw > width && break
        print(io, c)
        w += cw
    end
    return String(take!(io))
end

function _ui_label_text(node::_UiNode)
    haskey(node.params, _UI_K_LABEL) || return ""
    return _ui_vtext(node.params[_UI_K_LABEL])
end

function _ui_leaf_text(inst::_UiInstance, node::_UiNode;
                       edit = nothing)
    k = node.kind.name
    label = _ui_label_text(node)
    tag = isempty(label) ? "" : label * ": "
    v = node.value
    if k === Symbol("checkbox")
        return (_ui_bool(v) === true ? "[x] " : "[ ] ") * label
    elseif k === Symbol("toggle")
        return (_ui_bool(v) === true ? "(on) " : "(off) ") * label
    elseif k === Symbol("text-input") || k === Symbol("password-input")
        if edit !== nothing && edit[1] == node.path
            s = String(edit[2])
        elseif k === Symbol("password-input")
            s = repeat("•", length(something(_ui_string(v), "")))
        else
            s = something(_ui_string(v), "")
        end
        isempty(s) && haskey(node.params, _UI_K_PLACEHOLDER) &&
            (s = _ui_vtext(node.params[_UI_K_PLACEHOLDER]))
        return tag * s
    elseif k === Symbol("text-area")
        s = something(_ui_string(v), "")
        parts = split(s, "\n")
        isempty(parts) && return tag
        head = isempty(label) ? String[] : String[label * ":"]
        return join(vcat(head, ["  " * p for p in parts]), "\n")
    elseif k === Symbol("int-input") || k === Symbol("float-input")
        return tag * _ui_vtext(v)
    elseif k === Symbol("slider")
        lo = something(_ui_param_number(node.params, _UI_K_MIN), 0)
        hi = something(_ui_param_number(node.params, _UI_K_MAX), 1)
        n = _ui_number(v)
        n === nothing && return tag * _ui_vtext(v)
        return tag * _ui_bar(n, lo, hi, 24) * " " * _ui_vtext(v)
    elseif k === Symbol("range-slider")
        els = _ui_seq_elements(v)
        (els === nothing || length(els) != 2) && return tag * _ui_vtext(v)
        lo = something(_ui_param_number(node.params, _UI_K_MIN), 0)
        hi = something(_ui_param_number(node.params, _UI_K_MAX), 1)
        a = _ui_number(els[1]); b = _ui_number(els[2])
        (a === nothing || b === nothing) && return tag * _ui_vtext(v)
        return tag * _ui_range_bar(a, b, lo, hi, 24) * " " *
               _ui_vtext(els[1]) * ".." * _ui_vtext(els[2])
    elseif k === Symbol("dropdown")
        return tag * _ui_option_text(_ui_options(node.params), v)
    elseif k === Symbol("radio-group")
        return tag * _ui_radio_text(node)
    elseif k === Symbol("multi-select")
        return tag * _ui_multi_text(node)
    elseif k === Symbol("selection-slider")
        return tag * _ui_selslider_text(node)
    elseif k === Symbol("button")
        return "[ " * label * " ]"
    elseif k === Symbol("label")
        return _ui_vtext(get(node.params, _UI_K_TEXT, naught))
    elseif k === Symbol("progress")
        lo = something(_ui_param_number(node.params, _UI_K_MIN), 0)
        hi = something(_ui_param_number(node.params, _UI_K_MAX), 1)
        n = _ui_number(get(node.params, _UI_K_VALUE, naught))
        n === nothing && return tag * _ui_vtext(get(node.params, _UI_K_VALUE, naught))
        frac = hi == lo ? 1.0 : clamp((Float64(n) - Float64(lo)) /
                                      (Float64(hi) - Float64(lo)), 0.0, 1.0)
        return tag * _ui_bar(n, lo, hi, 24) * " " *
               string(round(Int, 100 * frac)) * "%"
    elseif k === Symbol("status")
        return tag * _ui_vtext(get(node.params, _UI_K_VALUE, naught))
    end
    return label
end

"""
    _ui_lines(inst, node, width; edit=nothing) -> Vector{_UiLine}

Lay out one element and its children. `edit` is an optional
`(path, buffer, cursor)` triple for a text field being edited by the terminal
renderer; the headless renderer passes `nothing`.
"""
function _ui_lines(inst::_UiInstance, node::_UiNode, width::Int;
                   edit = nothing)
    k = node.kind.name
    if k === Symbol("column")
        out = _UiLine[]
        for c in node.children
            append!(out, _ui_lines(inst, c, width; edit = edit))
        end
        return out
    elseif k === Symbol("row")
        parts = [_ui_lines(inst, c, width; edit = edit) for c in node.children]
        if all(p -> length(p) == 1, parts) && !isempty(parts)
            return [_ui_line(join([p[1].text for p in parts], "  "), node)]
        end
        out = _UiLine[]
        for p in parts
            append!(out, p)
        end
        return out
    elseif k === Symbol("group")
        out = _UiLine[]
        label = _ui_label_text(node)
        isempty(label) || push!(out, _ui_line(label, node))
        kids = _UiLine[]
        for c in node.children
            append!(kids, _ui_lines(inst, c, width - 2; edit = edit))
        end
        append!(out, _ui_indent(kids, 2))
        return out
    elseif k === Symbol("tabs")
        bar = String[]
        for c in node.children
            push!(bar, _ui_label_text(c))
        end
        out = _UiLine[]
        isempty(bar) || push!(out, _ui_line("( " * join(bar, " | ") * " )", node))
        # The headless renderer shows the first tab.
        isempty(node.children) && return out
        first = node.children[1]
        kids = _UiLine[]
        for c in first.children
            append!(kids, _ui_lines(inst, c, width - 2; edit = edit))
        end
        append!(out, _ui_indent(kids, 2))
        return out
    elseif k === Symbol("tab")
        kids = _UiLine[]
        for c in node.children
            append!(kids, _ui_lines(inst, c, width - 2; edit = edit))
        end
        return kids
    elseif k === Symbol("accordion")
        out = _UiLine[]
        for c in node.children
            label = _ui_label_text(c)
            push!(out, _ui_line("▾ " * label, c))
            kids = _UiLine[]
            for g in c.children
                append!(kids, _ui_lines(inst, g, width - 2; edit = edit))
            end
            append!(out, _ui_indent(kids, 2))
        end
        return out
    elseif k === Symbol("section")
        out = _UiLine[]
        label = _ui_label_text(node)
        isempty(label) || push!(out, _ui_line(label, node))
        kids = _UiLine[]
        for c in node.children
            append!(kids, _ui_lines(inst, c, width - 2; edit = edit))
        end
        append!(out, _ui_indent(kids, 2))
        return out
    else
        text = _ui_leaf_text(inst, node; edit = edit)
        return [_ui_line(part, node) for part in split(text, "\n")]
    end
end

"""
    _ui_render_text(inst; width=80) -> String

A deterministic text rendering of the instance, for documentation and tests.
"""
function _ui_render_text(inst::_UiInstance; width::Int = 80)
    lines = _ui_lines(inst, inst.root, width)
    return join([_ui_clip(l.text, width) for l in lines], "\n")
end

# `(ui-render key width=80)` — the headless renderer.
function _bi_ui_render(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-render", (Symbol(":width"),))
    length(call.seq) == 2 || throw(AirEvalError("ui-render takes a UI instance key"))
    width = 80
    if haskey(call.map, Symbol(":width"))
        w = air_reduce(env, scope, to_form(call.map[Symbol(":width")]))
        l = _leafof(w)
        (l isa Integer && !(l isa Bool) && l > 0) || throw(AirEvalError(
            "ui-render: width= must be a positive integer"))
        width = Int(l)
    end
    inst = _ui_lookup(env, air_reduce(env, scope, to_form(call.seq[2])))
    lock(inst.lock) do
        return Form(_ui_render_text(inst; width = width))
    end
end
special!(Symbol("ui-render"), _bi_ui_render)
