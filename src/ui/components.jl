################################################################################
# ui/components.jl
#
# Composite widgets. The legacy catalog in ui/widgets.jl describes *elements*:
# small, stateless-per-frame leaves whose value air validates and stores. A
# component is the other kind of thing — a widget that owns its own interaction
# model (a text editor, a notebook, a browser, a chat) and is driven by the
# renderer's key loop rather than by the element focus ring.
#
# The split is deliberate. Air still owns a component's durable state: a
# component's widget form names a `mut` in its `state=` parameter, and the
# component reads and writes it through the same hooks an air-level `set!`
# would. What lives only in the component is the transient view: the current
# selection, the scroll position, the undo history.
#
# The protocol is small. A component answers five questions and reacts to keys:
#
#   _comp_lines(c, inst, width)   the body lines to draw
#   _comp_cursor(c, inst)         `(row, col)` of the text cursor, or nothing
#   _comp_status(c, inst)         a transient status message
#   _comp_key!(c, inst, key)      :handled, :bubble, or :dismiss
#   _comp_hints(c)                the key hints the status row may show
#   _comp_flush!(c, inst)         copy the widget's state into its `mut`
#   _comp_close!(c, inst)         flush, then release anything held (pumps)
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    _Comp

The supertype of every composite widget. A concrete component keeps a
`_CompBase` in its `base` field and adds its own interaction state.
"""
abstract type _Comp end

"""
    _UiJob

One piece of background work a widget started: a task and the one-shot channel
it delivers its result on. The instance's ticker polls the channel and applies
the result on its own task, so every durable state write still happens on one
task — and it keeps happening after the connection that showed the widget is
gone.
"""
mutable struct _UiJob
    chan::Channel{Any}
    label::String                   # shown while the job runs
end

"""
    _CompBase

The state every component shares: the widget node it was built from, the
durable `mut` the widget names, the namespace it evaluates in, the scroll
position, the transient status message, and the background job (if any).
"""
mutable struct _CompBase
    node::_UiNode
    state::Union{Nothing,VolatileForm}
    nspath::Vector{Symbol}
    status::String
    top::Int
    left::Int
    theme::Union{Nothing,Dict{Symbol,_UiStyle}}
    job::Union{Nothing,_UiJob}
end

_CompBase(node::_UiNode; state = nothing, nspath::Vector{Symbol} = Symbol[]) =
    _CompBase(node, state, nspath, "", 1, 0,
              _comp_theme_params(node.params), nothing)

# ---- the protocol ------------------------------------------------------------

_comp_node(c::_Comp) = c.base.node
_comp_title(c::_Comp) = String(_comp_node(c).kind.name)

_comp_lines(c::_Comp, inst::_UiInstance, width::Int) = _UiLine[]
_comp_cursor(c::_Comp, inst::_UiInstance) = nothing
_comp_status(c::_Comp, inst::_UiInstance) = c.base.status
_comp_dirty(c::_Comp, inst::_UiInstance) = false
_comp_key!(c::_Comp, inst::_UiInstance, k::_UiKey) = :bubble

# Copy the widget's on-screen state into its durable `mut`. The renderer flushes
# when it detaches, so what was typed or drawn survives a connection that comes
# and goes even though the widget itself stays alive.
_comp_flush!(c::_Comp, inst::_UiInstance) = nothing
_comp_close!(c::_Comp, inst::_UiInstance) = nothing

# Start anything the widget owns once it is alive (a chat pump). Called when the
# instance's tree is built, never by a headless view.
_comp_start!(c::_Comp, inst::_UiInstance) = nothing

# ---- background work ---------------------------------------------------------

_comp_running(c::_Comp) = c.base.job !== nothing

# What the status row says while work is in flight. A container answers with
# whichever of its children is running.
_comp_job_label(c::_Comp) =
    c.base.job === nothing ? "running…" : c.base.job.label

"""
    _comp_start_job!(c, inst, f; label = "running…") -> Bool

Run `f()` on a spawned task. `f` may evaluate air but must not write the
widget's durable state; it returns whatever the component's `_comp_job_done!`
expects. The completed job delivers `(:ok, value)`, or `(:error, message)` when
an exception escaped, and the instance's ticker applies it. False when a job is
already running.
"""
function _comp_start_job!(c::_Comp, inst::_UiInstance, f::Function;
                          label::AbstractString = "running…")
    _comp_running(c) && return false
    chan = Channel{Any}(1)
    c.base.job = _UiJob(chan, String(label))
    Threads.@spawn begin
        # Block scopes do not cross a task boundary; this is the same start a
        # `(task …)` makes.
        _reset_block_scopes!()
        res = try
            (:ok, f())
        catch e
            e isa InterruptException && rethrow()
            (:error, sprint(showerror, e))
        end
        try
            put!(chan, res)
        catch
        end
        nothing
    end
    return true
end

# Apply a finished job's result. The component decides what it means; the
# result is `(:ok, value)` or `(:error, message)`.
_comp_job_done!(c::_Comp, inst::_UiInstance, res) = nothing

"""
    _comp_tick!(c, inst) -> Bool

Poll the widget's background job and apply a finished result. Returns true when
one was applied (and the screen needs a redraw). The instance's ticker calls
this; attaching a renderer does not.
"""
function _comp_tick!(c::_Comp, inst::_UiInstance)
    j = c.base.job
    j === nothing && return false
    isready(j.chan) || return false
    res = take!(j.chan)
    c.base.job = nothing
    try
        _comp_job_done!(c, inst, res)
    catch e
        e isa AirError || rethrow()
        c.base.status = "error: " * sprint(showerror, e)
    end
    lock(inst.lock) do
        inst.dirty = true
    end
    return true
end

# ---- parameters --------------------------------------------------------------

# A map key as air stores it: the colon is part of the symbol name, so `text=`
# is the key `Symbol(":text")`. Accept either spelling at a call site.
_map_key(k::Symbol) = startswith(String(k), ":") ? k : Symbol(":", k)

# A component parameter by keyword, or `nothing`.
_comp_param(c::_Comp, k::Symbol) = get(_comp_node(c).params, _map_key(k), nothing)

# The string a parameter holds, or `nothing`.
_comp_param_string(c::_Comp, k::Symbol) =
    (f = _comp_param(c, k); f === nothing ? nothing : _ui_string(f))

# The durable state mutable a widget form names, or `nothing`.
function _comp_state_mut(params)
    f = get(params, _map_key(:state), nothing)
    f === nothing && return nothing
    v = f isa VolatileForm ? f : (f isa FormContainer ? nothing : to_form(f))
    return v isa VolatileForm ? v : nothing
end

# A widget's own `theme=` map, resolved to role styles, or `nothing`. Each entry
# is either a bare color (a foreground recolor) or a map of style fields, so a
# widget can tint a role's background or weight as well as its ink; either way it
# starts from the role it inherits, so a widget that names only `string=` keeps
# every other field and every other role. The entry grammar is shared with
# `ui-theme!`, so both validate a role, its fields, and its flags the same way.
function _comp_theme_params(params)
    f = get(params, _map_key(:theme), nothing)
    f isa FormContainer || return nothing
    d = Dict{Symbol,_UiStyle}()
    for (k, v) in f.map
        role = Symbol(replace(lstrip(String(k), ':'), "-" => "_"))
        _ui_role_exists(role) ||
            throw(AirEvalError("ui: theme: unknown role " * air_string(Form(k))))
        d[role] = _ui_theme_style(_ui_role(role), to_form(v),
                                  "ui: theme: " * air_string(Form(k)))
    end
    return isempty(d) ? nothing : d
end

# The namespace path a widget names, or the captured namespace when it names
# none. A widget form stores the path as data (`(main util)`, or `.` for the
# root), so building it needs no environment.
function _comp_namespace(params, fallback::Vector{Symbol})
    f = get(params, _map_key(:ns), nothing)
    f === nothing && return fallback
    p = _stored_path(to_form(f))
    return p === nothing ? fallback : p
end

# ---- durable state -----------------------------------------------------------

# The current value of the component's state mut, or `naught`.
function _comp_state(c::_Comp, inst::_UiInstance)
    m = c.base.state
    m === nothing && return naught
    return _ui_in_context(inst) do
        canonicalize(m[])
    end
end

# Write the component's state mut inside the instance's captured context, with
# the same hooks and transaction an air-level `set!` uses.
function _comp_set_state!(c::_Comp, inst::_UiInstance, value::Form)
    m = c.base.state
    m === nothing && return nothing
    _ui_in_context(inst) do
        env = inst.env
        _check!(env, m, :write)
        _tx_boundary(env) do
            _ensure_hooks!(env, m)
            _record_write!(env, m)
            setindex!(m, value)
            value
        end
    end
    return nothing
end

# A field of a stored state container, or `nothing`.
function _state_field(v::Form, key::Symbol)
    v isa FormContainer || return nothing
    k = _map_key(key)
    haskey(v.map, k) || return nothing
    return to_form(v.map[k])
end

# A stored state field as a string ("" when absent).
function _state_string(v::Form, key::Symbol)
    f = _state_field(v, key)
    f === nothing && return ""
    s = _ui_string(f)
    s === nothing || return s
    return air_string(f)
end

# A stored boolean field; absent is false.
function _state_flag(v::Form, key::Symbol)
    f = _state_field(v, key)
    return f !== nothing && _leafof(f) === true
end

# The canonicalized value of a widget's state mut, or `nothing` when the form
# names no mut.
function _comp_state_value(inst::_UiInstance,
                           state::Union{Nothing,VolatileForm})
    state === nothing && return nothing
    return _ui_in_context(inst) do
        canonicalize(state[])
    end
end

# ---- evaluation --------------------------------------------------------------

# The namespace a component's code runs in, or `nothing` when it names none.
_comp_ns(c::_Comp, inst::_UiInstance) = _ns_lookup(inst.env, c.base.nspath)

# The task context a component's code runs in: the captured context, with the
# component's namespace current so a `def` lands where the widget says (the same
# in-place swap `namespace` makes).
function _comp_context(c::_Comp, inst::_UiInstance, ns::Union{Nothing,Namespace})
    ns === nothing && return inst.ctx
    ctx = inst.ctx
    return TaskContext(ctx.user, ns, ctx.dbroot, ctx.env, ctx.out)
end

# Evaluate `text` in the component's namespace, returning
# `(:ok, [values])` or `(:error, message)`.
function _comp_eval(c::_Comp, inst::_UiInstance, text::AbstractString)
    status, forms = _read_complete(text)
    if status === :error
        return (:error, sprint(showerror, forms))
    end
    values = Form[]
    env = inst.env
    ns = _comp_ns(c, inst)
    ctx = _comp_context(c, inst, ns)
    try
        _with_context(env, ctx, () -> Air.setvars(() -> begin
            for f in forms
                # The namespace's layers are re-read per form, so a `def`
                # earlier in the buffer is visible to a later form.
                scope = ns === nothing ? inst.lscope :
                        _ns_scope(env, inst.lscope, ns)
                push!(values, air_reduce(env, scope, f))
            end
        end, inst.bindings))
    catch e
        e isa AirError || rethrow()
        return (:error, sprint(showerror, e))
    end
    return (:ok, values)
end

# ---- building ----------------------------------------------------------------

"""
    _comp_build_node(inst, node) -> Union{Nothing,_Comp}

Build the component a node names. A composite kind carries `value =
:component`, so the element builder leaves it alone; everything a component
needs comes from its own parameters.
"""
function _comp_build_node(inst::_UiInstance, node::_UiNode)
    name = node.kind.name
    name === Symbol("code-block") && return _comp_code_block(inst, node)
    name === Symbol("editor") && return _comp_editor(inst, node)
    name === Symbol("notebook") && return _comp_notebook(inst, node)
    name === Symbol("browser") && return _comp_browser(inst, node)
    name === Symbol("shell") && return _comp_shell(inst, node)
    name === Symbol("chat") && return _comp_chat(inst, node)
    return nothing
end

"""
    _comp_build(inst) -> Union{Nothing,_Comp}

Build the component a UI instance's root names.
"""
function _comp_build(inst::_UiInstance)
    root = inst.root
    root === nothing && return nothing
    return _comp_build_node(inst, root)
end

# ---- the instance's tree -----------------------------------------------------

# How often the ticker looks for finished background work.
const _UI_TICK_SECS = 0.03

"""
    _ui_tree(inst) -> Union{Nothing,_Comp}

The instance's component tree, built once and kept. A widget lives with its
instance rather than with the connection that shows it: attaching only starts
painting the tree and detaching only stops, so the cursor, the run queue, and a
running evaluation all survive a disconnect.
"""
function _ui_tree(inst::_UiInstance)
    lock(inst.lock) do
        inst.tree !== nothing && return inst.tree
        # A bad `theme=` names an unknown role or field and a failed start (a
        # closed chat stream) throws here; either way nothing is kept, so a
        # later attach retries rather than reusing a broken tree.
        tree = _comp_build(inst)
        tree === nothing && return nothing
        _comp_start!(tree, inst)
        inst.tree = tree
        _ui_start_ticker!(inst)
        return tree
    end
end

"""
    _ui_start_ticker!(inst)

Apply finished background work even when no renderer is attached, so an
evaluation a widget started outlives the connection that showed it. The ticker
mutates the tree only under the instance lock, which the renderer also takes
around its keys and its drawing; results are therefore applied exactly once and
the display never races the store.
"""
function _ui_start_ticker!(inst::_UiInstance)
    t = inst.ticker
    (t !== nothing && !istaskdone(t)) && return nothing
    inst.ticker = Threads.@spawn begin
        _reset_block_scopes!()
        while true
            stop = lock(inst.lock) do
                inst.closed && return true
                try
                    tree = inst.tree
                    if tree !== nothing && _comp_tick!(tree, inst)
                        inst.dirty = true
                    end
                catch e
                    e isa InterruptException && rethrow()
                    tree = inst.tree
                    tree === nothing ||
                        (tree.base.status = "background error: " *
                                            sprint(showerror, e))
                end
                inst.closed
            end
            stop && break
            sleep(_UI_TICK_SECS)
        end
        nothing
    end
    return nothing
end

# The namespace the instance was captured in, as a path.
_comp_captured_ns(inst::_UiInstance) =
    inst.ctx.ns === nothing ? Symbol[] : copy(inst.ctx.ns.path)

# ---- root key handling -------------------------------------------------------

# A component's answer to a key; at the root, a bubble on Esc means "dismiss".
function _comp_root_key!(c::_Comp, r, inst::_UiInstance, k::_UiKey)
    res = _comp_key!(c, inst, k)
    if res === :dismiss || (res === :bubble && k.name === :esc)
        r.quit = :dismiss
    elseif res isa Tuple && !isempty(res) && res[1] === :open
        # Only a shell can open a tab; a widget shown on its own says so.
        c.base.status = "open this in a shell to use tabs"
    end
    r.need_redraw = true
    return nothing
end

# ---- root drawing ------------------------------------------------------------

# Drop the first `n` display columns from a line's span run.
function _ui_shift_spans(spans::Vector{_UiSpan}, n::Int)
    n <= 0 && return spans
    (_, tail) = _ui_span_split(spans, n)
    return tail
end

function _ui_shift_line(l::_UiLine, n::Int)
    n <= 0 && return l
    spans = _ui_shift_spans(_ui_line_spans(l), n)
    return _UiLine(_ui_spans_text(spans), l.node, spans)
end

# The status row: the title, a dirty marker, the closure verdict, the component's
# message, and the key hints that fit.
function _comp_status_line(c::_Comp, inst::_UiInstance, width::Int)
    parts = String[]
    title = _comp_title(c)
    _comp_dirty(c, inst) && (title *= "*")
    push!(parts, title)
    if !isempty(c.base.nspath)
        push!(parts, _ns_display(c.base.nspath))
    end
    msg = _comp_running(c) ? _comp_job_label(c) : _comp_status(c, inst)
    isempty(msg) || push!(parts, msg)
    left = join(parts, "  ·  ")
    return _ui_fit_hints(left, _comp_hints(c), width)
end

# The key hints a component offers, each as `(long, short)`. The status row shows
# whole hints only and prefers the long spelling; it switches to the short one
# when that shows more of them, so a narrow terminal loses hints rather than
# cutting one in half.
_comp_hints(c::_Comp) = ["ctrl-j: run" => "^J run", "esc: done" => "esc"]

# How many whole hints fit after `left` in `room` columns.
function _ui_hint_fit(hints, room::Int, short::Bool)
    n = 0
    w = 0
    for h in hints
        s = short ? last(h) : first(h)
        add = textwidth(s) + (n == 0 ? 0 : 3)
        w + add > room && break
        w += add
        n += 1
    end
    return n
end

# `left`, then a right-aligned run of whole hints. The row is written into
# `width - 1` columns, so a pad of at least one always separates the two; when
# not even one short hint fits, the row is `left` alone.
function _ui_fit_hints(left::AbstractString, hints, width::Int)
    room = width - 1 - textwidth(left) - 1
    (isempty(hints) || room < 1) && return left
    long_n = _ui_hint_fit(hints, room, false)
    short_n = _ui_hint_fit(hints, room, true)
    short = short_n > long_n
    n = short ? short_n : long_n
    n == 0 && return left
    text = join((short ? last(h) : first(h) for h in hints[1:n]), "   ")
    pad = width - 1 - textwidth(left) - textwidth(text)
    pad < 1 && return left
    return left * repeat(" ", pad) * text
end

# Draw a component with its own theme installed, so a `theme=` map applies to
# every line and every status row the widget draws (including the tabs a shell
# draws for its children).
function _comp_draw_themed!(c::_Comp, r, inst::_UiInstance, width::Int, height::Int)
    t = c.base.theme
    f = () -> _comp_root_draw!(c, r, inst, width, height)
    return t === nothing ? f() :
           Base.ScopedValues.with(f, _UI_THEME_LOCAL => t)
end

function _comp_root_draw!(c::_Comp, r, inst::_UiInstance, width::Int, height::Int)
    body = max(height - 1, 1)
    lines = _comp_lines(c, inst, width)
    b = c.base
    cur = _comp_cursor(c, inst)
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
    end
    _term_emit_body!(r.frame, lines, width, body, b.top)
    status = _comp_status_line(c, inst, width)
    _term_emit_row!(r.frame, height, _ui_line(status, nothing), width,
                    _ui_role(:status))
    if cur !== nothing && cur[1] >= b.top && cur[1] < b.top + body
        (row, col) = cur
        _term_move!(r.backend, row - b.top + 1, min(col - b.left + 1, width))
    else
        _term_move!(r.backend, height, 1; visible = false)
    end
    return nothing
end
