################################################################################
# ui/core.jl
#
# The UI runtime: instantiating an inert `(ui …)` tree, holding each element's
# current value, validating changes, running callbacks, and maintaining the
# `assert` facts in the namespace the instance was opened in.
#
# An instance is a process-global, named resource like an SSH server:
# `(ui-open [key] tree)` registers it and returns the key; renderers attach to
# it; `(ui-close! key)` retracts its assertions and drops it.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- elements ----------------------------------------------------------------

"""
    _UiNode

One element of an instantiated UI tree: its catalog kind, optional explicit
`id` (normalized to its text), structural path (used for identity and assertion
labels), evaluated parameters, current value (`naught` for a kind with no
value), and children. The parent link lets a renderer walk upward for layout.
"""
mutable struct _UiNode
    kind::_UiKind
    id::Union{Nothing,String}
    path::String
    params::Dict{Symbol,Form}
    value::Form
    parent::Union{Nothing,_UiNode}
    children::Vector{_UiNode}
end

"""
    _UiInstance

A named UI instance and everything needed to keep it alive independently of
the task that opened it: the captured task context (so assertions target the
namespace that was current at instantiation), the namespace layers active then,
and the `val` bindings. `asserts` maps an element's structural path to the fact
that element currently owns; `renderers` are the attached views.
"""
mutable struct _UiInstance
    key::Symbol
    owner::Symbol
    root::Union{Nothing,_UiNode}
    nodes::Vector{_UiNode}
    byid::Dict{String,_UiNode}
    asserts::Dict{String,Form}
    env::Env
    ctx::TaskContext
    lscope::Scope
    bindings::IdDict{Air.Var,Any}
    renderers::Vector{_UiRenderer}
    epoch::Int
    dirty::Bool
    dismissed::Bool
    closed::Bool
    lock::ReentrantLock
end

const _UI_INSTANCES = Dict{Symbol,_UiInstance}()
const _UI_INSTANCES_LOCK = ReentrantLock()
const _UI_KEY_COUNTER = Ref(0)

# ---- keys --------------------------------------------------------------------

# The instance key a form names: a keyword, a bare symbol, or a string. The
# colon of a keyword is dropped, so `:prefs` and `prefs` name the same instance.
function _ui_key(x::Form)
    l = _leafof(x)
    if l isa Symbol
        s = String(l)
        key = startswith(s, ":") ? s[2:end] : s
        isempty(key) && throw(AirEvalError("a UI instance key may not be empty"))
        return Symbol(key)
    elseif l isa AbstractString
        isempty(l) && throw(AirEvalError("a UI instance key may not be empty"))
        return Symbol(l)
    end
    throw(AirEvalError(
        "a UI instance key must be a keyword, symbol, or string, got $(air_string(x))"))
end

_ui_key_form(key::Symbol) = Form(Symbol(":" * String(key)))

function _ui_new_key()
    n = lock(_UI_INSTANCES_LOCK) do
        _UI_KEY_COUNTER[] += 1
    end
    return Symbol("ui" * string(n))
end

# The instance `x` names, checked against the caller's identity and liveness.
function _ui_lookup(env::Env, x::Form)
    key = _ui_key(x)
    inst = lock(_UI_INSTANCES_LOCK) do
        get(_UI_INSTANCES, key, nothing)
    end
    inst === nothing && throw(AirEvalError(
        "no UI instance $(air_string(_ui_key_form(key)))"))
    user = _context(env).user
    (user === :air || inst.owner === user) || throw(AirEvalError(
        "UI instance $(air_string(_ui_key_form(key))) is owned by " *
        string(inst.owner)))
    inst.closed && throw(AirEvalError(
        "UI instance $(air_string(_ui_key_form(key))) is closed"))
    return inst
end

# ---- capturing scope ---------------------------------------------------------

# Capture the lexical scope of a `assert`/`on-change`/`on-click` form that will
# run later. Like `_capture_form`, but `_` is left alone: in an assertion it is
# the current value, not a reference to an outer binding.
function _ui_capture(scope::Scope, x::Form)
    cand = Dict{Symbol,Form}()
    _collect_free!(cand, scope, x, Set{Symbol}([PLACEHOLDER]))
    isempty(cand) && return x
    return _subst_params(x, cand)
end

# Run `f` under the instance's captured context and `val` bindings.
function _ui_in_context(inst::_UiInstance, f::Function)
    return _with_context(inst.env, inst.ctx,
                         () -> Air.setvars(f, inst.bindings))
end

# `_ui_in_context(inst) do … end` passes the closure first.
_ui_in_context(f::Function, inst::_UiInstance) = _ui_in_context(inst, f)

# ---- evaluation helpers ------------------------------------------------------

# Evaluate an element's `assert` form with `_` bound to its current value. The
# result is `nothing` for `naught`, else the raw (held-stripped) fact.
function _ui_eval_assert(inst::_UiInstance, node::_UiNode)
    f = get(node.params, _UI_K_ASSERT, nothing)
    f === nothing && return nothing
    r = _ui_in_context(inst) do
        s = scope_extend(inst.lscope, [PLACEHOLDER => node.value])
        air_reduce(inst.env, s, f)
    end
    isequal(r, naught) && return nothing
    return _strip_hold(_factify(r))
end

# The reason label an element asserts under. A keyword (the logic engine accepts
# nothing else), unique per instance and element, so retracting our fact never
# disturbs an equal fact asserted elsewhere by air.
_ui_label(inst::_UiInstance, node::_UiNode) =
    Symbol(":ui/", String(inst.key), "/", node.path)

# Apply one logic operation for a fact we own.
function _ui_fact_call(inst::_UiInstance, node::_UiNode, op::Symbol, fact::Form)
    label = _ui_label(inst, node)
    seq = FormValue[_store_form(Form(op)), _store_form(_holdify(fact))]
    mp = Pair{Symbol,FormValue}[_REASON_KEY => _store_form(Form(label))]
    call = FormContainer(FormSeq(seq), FormMap(mp))
    op === :assert ? _bi_assert(inst.env, inst.lscope, call) :
                     _bi_retract(inst.env, inst.lscope, call)
    return nothing
end

# Replace the fact an element owns with `newfact` (or `nothing`), as one logical
# revision. An identical fact is a no-op.
function _ui_revise!(inst::_UiInstance, node::_UiNode, newfact)
    old = get(inst.asserts, node.path, nothing)
    old === nothing && newfact === nothing && return nothing
    (old !== nothing && newfact !== nothing && _eq(old, newfact)) && return nothing
    _ui_in_context(inst) do
        _tx_boundary(inst.env) do
            old === nothing || _ui_fact_call(inst, node, :retract, old)
            newfact === nothing || _ui_fact_call(inst, node, :assert, newfact)
        end
    end
    newfact === nothing ? delete!(inst.asserts, node.path) :
                          (inst.asserts[node.path] = newfact)
    return nothing
end

# Retract every fact the instance owns, in one transaction.
function _ui_retract_all!(inst::_UiInstance)
    isempty(inst.asserts) && return nothing
    _ui_in_context(inst) do
        _tx_boundary(inst.env) do
            for (path, fact) in inst.asserts
                node = _ui_node_by_path(inst, path)
                node === nothing || _ui_fact_call(inst, node, :retract, fact)
            end
        end
    end
    empty!(inst.asserts)
    return nothing
end

function _ui_node_by_path(inst::_UiInstance, path::AbstractString)
    for n in inst.nodes
        n.path == path && return n
    end
    return nothing
end

# The selection string a renderer or air uses for an element: its explicit id,
# or its structural path when it has none.
_ui_sel(node::_UiNode) = node.id === nothing ? node.path : node.id

# Resolve a selection string: an explicit id first, else a structural path.
function _ui_find_node(inst::_UiInstance, sel::AbstractString)
    node = get(inst.byid, String(sel), nothing)
    node === nothing || return node
    return _ui_node_by_path(inst, String(sel))
end

# Invoke a callback (on-change/on-click) under the captured context.
function _ui_invoke!(inst::_UiInstance, handler::Form, args::Vector{Form})
    _ui_in_context(inst) do
        _call(inst.env, inst.lscope, handler, args)
    end
    return nothing
end

# ---- instantiation -----------------------------------------------------------

"""
    _ui_build!(env, scope, inst, form, parent, path, nodes) -> _UiNode

Instantiate one `(ui …)` form, evaluating its parameters in `scope`. Children
are built recursively; every node is appended to `nodes`.
"""
function _ui_build!(env::Env, scope::Scope, inst::_UiInstance, form::Form,
                    parent::Union{Nothing,_UiNode}, path::AbstractString,
                    nodes::Vector{_UiNode})
    (form isa FormContainer && head_symbol(form) === UI_HEAD) ||
        throw(AirEvalError("expected a (ui …) form, got $(air_string(form))"))
    form = form::FormContainer
    n = length(form.seq)
    n >= 2 || throw(AirEvalError("a (ui …) form needs a widget type"))
    ksym = _symbolof(to_form(form.seq[2]))
    ksym === nothing && throw(AirEvalError(
        "a UI widget type must be a symbol, got $(air_string(to_form(form.seq[2])))"))
    kind = _ui_kind(ksym)
    _check_options(form, "ui " * String(kind.name), kind.params)

    # Evaluate parameters. `assert` stays raw (evaluated per value); callbacks
    # keep the lexical names they will need when they fire.
    params = Dict{Symbol,Form}()
    for (k, v) in form.map
        f = to_form(v)
        if k === _UI_K_ASSERT
            params[k] = _ui_capture(scope, f)
        else
            r = air_reduce(env, scope, f)
            params[k] = (k === _UI_K_ON_CHANGE || k === _UI_K_ON_CLICK) ?
                        _ui_capture(scope, r) : r
        end
    end
    _ui_check_params(kind, params)

    id = nothing
    if haskey(params, _UI_K_ID)
        l = _leafof(params[_UI_K_ID])
        l isa Symbol || l isa AbstractString || throw(AirEvalError(
            "ui $(kind.name): id= must be a keyword, symbol, or string"))
        s = String(l)
        id = startswith(s, ":") ? s[2:end] : s
        isempty(id) && throw(AirEvalError("ui $(kind.name): id= may not be empty"))
    end

    # The initial (and current) value.
    value = naught
    if _ui_kind_mutable(kind)
        v = get(params, _UI_K_INITVAL, nothing)
        if v === nothing
            v = _ui_default_value(kind)
            v === nothing && throw(AirEvalError(
                "ui $(kind.name): initval= is required"))
            params[_UI_K_INITVAL] = v
        end
        reason = _ui_validate(kind, params, v)
        reason === nothing || throw(AirEvalError(
            "ui $(kind.name): invalid initval: $reason"))
        value = v
    end

    node = _UiNode(kind, id, String(path), params, value, parent, _UiNode[])
    push!(nodes, node)

    if kind.children === :none
        n == 2 || throw(AirEvalError(
            "ui $(kind.name) does not take child elements"))
    else
        for i in 3:n
            c = to_form(form.seq[i])
            child = _ui_build!(env, scope, inst, c, node, "$path/$(i - 1)", nodes)
            if kind.children === :tab && child.kind.name !== Symbol("tab")
                throw(AirEvalError("ui $(kind.name) only takes ui tab children"))
            elseif kind.children === :section && child.kind.name !== Symbol("section")
                throw(AirEvalError("ui $(kind.name) only takes ui section children"))
            end
            push!(node.children, child)
        end
    end
    return node
end

# Create an instance from a tree without registering or asserting anything.
function _ui_instantiate(env::Env, scope::Scope, key::Symbol, tree::Form)
    nodes = _UiNode[]
    c = _context(env)
    inst = _UiInstance(key, c.user, nothing, nodes, Dict{String,_UiNode}(),
                       Dict{String,Form}(), _session_env(env),
                       TaskContext(c.user, c.ns, c.dbroot, c.env, c.out),
                       _scope_layers_only(scope), Air.vars(), _UiRenderer[],
                       0, true, false, false, ReentrantLock())
    root = _ui_build!(env, scope, inst, tree, nothing, "root", nodes)
    inst.root = root
    for node in nodes
        node.id === nothing && continue
        haskey(inst.byid, node.id) && throw(AirEvalError(
            "duplicate UI element id $(air_string(Form(Symbol(":" * node.id))))"))
        inst.byid[node.id] = node
    end
    return inst
end

# Establish every initial assertion. On error, retract what was already
# asserted and rethrow, so a failed instantiation leaves no facts behind.
function _ui_assert_initial!(inst::_UiInstance)
    try
        for node in inst.nodes
            haskey(node.params, _UI_K_ASSERT) || continue
            fact = _ui_eval_assert(inst, node)
            fact === nothing && continue
            _ui_revise!(inst, node, fact)
        end
    catch
        try
            _ui_retract_all!(inst)
        catch
        end
        rethrow()
    end
    return nothing
end

# ---- the air surface ---------------------------------------------------------

# `(ui-open [key] tree)` — instantiate `tree` and register it; returns the key.
function _bi_ui_open(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-open", ())
    seq = [to_form(v) for v in call.seq]
    (2 <= length(seq) <= 3) || throw(AirEvalError(
        "ui-open takes an optional key and a UI tree"))
    if length(seq) == 2
        key = _ui_new_key()
        tree = seq[2]
    else
        key = _ui_key(seq[2])
        tree = seq[3]
    end
    reduced = air_reduce(env, scope, tree)
    inst = _ui_instantiate(env, scope, key, reduced)
    lock(_UI_INSTANCES_LOCK) do
        haskey(_UI_INSTANCES, key) && throw(AirEvalError(
            "a UI instance $(air_string(_ui_key_form(key))) already exists"))
        _UI_INSTANCES[key] = inst
    end
    try
        _ui_assert_initial!(inst)
    catch
        lock(_UI_INSTANCES_LOCK) do
            get(_UI_INSTANCES, key, nothing) === inst && delete!(_UI_INSTANCES, key)
        end
        rethrow()
    end
    return _ui_key_form(key)
end
special!(Symbol("ui-open"), _bi_ui_open)

# `(ui-values key)` — the current values of the identified interactive elements,
# as a mapping.
function _ui_values_form(inst::_UiInstance)
    ids = sort!(String[n.id for n in inst.nodes
                       if n.id !== nothing && _ui_kind_mutable(n.kind)])
    isempty(ids) && return naught
    mp = Pair{Symbol,FormValue}[]
    for id in ids
        push!(mp, Symbol(":" * id) => _store_form(inst.byid[id].value))
    end
    return FormContainer(FormSeq(FormValue[]), FormMap(mp))
end

function _bi_ui_values(env::Env, scope::Scope, args::Vector{Form})
    length(args) == 1 || throw(AirEvalError("ui-values takes a UI instance key"))
    return _ui_values_form(_ui_lookup(env, args[1]))
end
builtin!(Symbol("ui-values"), _bi_ui_values)

# `(ui-value key id)` — one element's current value.
function _bi_ui_value(env::Env, scope::Scope, args::Vector{Form})
    length(args) == 2 || throw(AirEvalError("ui-value takes a key and an element id"))
    inst = _ui_lookup(env, args[1])
    id = _ui_element_id(args[2])
    node = _ui_find_node(inst, id)
    node === nothing && throw(AirEvalError(
        "no UI element $(air_string(Form(Symbol(":" * id)))) in $(air_string(args[1]))"))
    _ui_kind_mutable(node.kind) || throw(AirEvalError(
        "UI element $(air_string(Form(Symbol(":" * id)))) has no value"))
    return node.value
end
builtin!(Symbol("ui-value"), _bi_ui_value)

# The text of an element id argument.
function _ui_element_id(x::Form)
    l = _leafof(x)
    l isa Symbol && return startswith(String(l), ":") ? String(l)[2:end] : String(l)
    l isa AbstractString && return String(l)
    throw(AirEvalError(
        "a UI element id must be a keyword, symbol, or string, got $(air_string(x))"))
end

"""
    _ui_apply!(inst, id, value; origin=:user) -> (:ok, old, new) | (:invalid, reason)

The single update path for both renderer events and `ui-set!`. Validates,
installs, revises the assertion, and runs `on-change`. An invalid value changes
nothing. `origin=:user` refuses a disabled element; `origin=:program` is air
itself and may update one.
"""
function _ui_apply!(inst::_UiInstance, id::AbstractString, value::Form;
                    origin::Symbol = :user)
    lock(inst.lock) do
        inst.closed && throw(AirEvalError("UI instance is closed"))
        node = _ui_find_node(inst, id)
        node === nothing && throw(AirEvalError(
            "no UI element $(air_string(Form(Symbol(":" * id))))"))
        _ui_kind_mutable(node.kind) || throw(AirEvalError(
            "UI element $(air_string(Form(Symbol(":" * id)))) has no value"))
        if origin === :user &&
           _ui_param_bool(node.params, _UI_K_DISABLED) === true
            return (:invalid, "element is disabled")
        end
        reason = _ui_validate(node.kind, node.params, value)
        reason === nothing || return (:invalid, reason)
        old = node.value
        _eq(old, value) && return (:ok, old, old)
        node.value = value
        haskey(node.params, _UI_K_ASSERT) &&
            _ui_revise!(inst, node, _ui_eval_assert(inst, node))
        h = get(node.params, _UI_K_ON_CHANGE, nothing)
        h === nothing || _ui_invoke!(inst, h, Form[old, value])
        _ui_notify!(inst)
        return (:ok, old, value)
    end
end

# `(ui-set! key id value)` — a programmatic update.
function _bi_ui_set(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-set!", ())
    length(call.seq) == 4 || throw(AirEvalError(
        "ui-set! takes a key, an element id, and a value"))
    inst = _ui_lookup(env, air_reduce(env, scope, to_form(call.seq[2])))
    id = _ui_element_id(air_reduce(env, scope, to_form(call.seq[3])))
    value = air_reduce(env, scope, to_form(call.seq[4]))
    r = _ui_apply!(inst, id, value; origin = :program)
    if r[1] === :invalid
        throw(AirThrown(_error_object(Form(Symbol(":ui-invalid")), Form(id),
                                      Form(r[2]))))
    end
    return value
end
special!(Symbol("ui-set!"), _bi_ui_set)

# `(ui-dismiss! key)` — leave the renderer; `ui-show` returns.
function _bi_ui_dismiss(env::Env, scope::Scope, args::Vector{Form})
    length(args) == 1 || throw(AirEvalError("ui-dismiss! takes a UI instance key"))
    inst = _ui_lookup(env, args[1])
    inst.dismissed = true
    _ui_notify!(inst)
    return naught
end
builtin!(Symbol("ui-dismiss!"), _bi_ui_dismiss)

# `(ui-close! key)` — retract the instance's assertions and forget it.
function _bi_ui_close(env::Env, scope::Scope, args::Vector{Form})
    length(args) == 1 || throw(AirEvalError("ui-close! takes a UI instance key"))
    _ui_close_key(env, air_reduce(env, scope, args[1]))
    return naught
end
builtin!(Symbol("ui-close!"), _bi_ui_close)

function _ui_close_key(env::Env, keyform::Form)
    key = _ui_key(keyform)
    inst = lock(_UI_INSTANCES_LOCK) do
        get(_UI_INSTANCES, key, nothing)
    end
    # Closing is idempotent: a missing instance is already closed, so a cleanup
    # path need not know whether the UI closed itself.
    inst === nothing && return nothing
    user = _context(env).user
    (user === :air || inst.owner === user) || throw(AirEvalError(
        "UI instance $(air_string(_ui_key_form(key))) is owned by " *
        string(inst.owner)))
    lock(inst.lock) do
        inst.closed && return nothing
        _ui_retract_all!(inst)
        inst.closed = true
        inst.dismissed = true
    end
    lock(_UI_INSTANCES_LOCK) do
        get(_UI_INSTANCES, inst.key, nothing) === inst &&
            delete!(_UI_INSTANCES, inst.key)
    end
    return nothing
end

# `(ui-instances)` — the keys of the caller's open instances.
function _bi_ui_instances(env::Env, scope::Scope, args::Vector{Form})
    user = _context(env).user
    keys = lock(_UI_INSTANCES_LOCK) do
        sort!([String(k) for (k, i) in _UI_INSTANCES
               if (user === :air || i.owner === user) && !i.closed])
    end
    isempty(keys) && return naught
    seq = FormValue[_store_form(_ui_key_form(Symbol(k))) for k in keys]
    return FormContainer(FormSeq(seq), FormMap())
end
builtin!(Symbol("ui-instances"), _bi_ui_instances)

# `(ui-update! key tree)` — replace an instance's tree. Elements whose id
# survives keep their value when it is still valid; removed elements' facts are
# retracted and new ones asserted, in one revision.
function _bi_ui_update(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-update!", ())
    length(call.seq) == 3 || throw(AirEvalError(
        "ui-update! takes a UI instance key and a UI tree"))
    inst = _ui_lookup(env, air_reduce(env, scope, to_form(call.seq[2])))
    tree = air_reduce(env, scope, to_form(call.seq[3]))
    lock(inst.lock) do
        inst.closed && throw(AirEvalError("UI instance is closed"))
        fresh = _ui_instantiate(env, scope, inst.key, tree)
        # Assertions remain in the namespace the instance was opened in, even
        # when the update is made from elsewhere.
        fresh.ctx = inst.ctx
        # Keep a surviving element's value when the new kind still accepts it.
        for (id, newnode) in fresh.byid
            oldnode = get(inst.byid, id, nothing)
            oldnode === nothing && continue
            _ui_kind_mutable(oldnode.kind) || continue
            _ui_kind_mutable(newnode.kind) || continue
            v = oldnode.value
            _ui_validate(newnode.kind, newnode.params, v) === nothing || continue
            newnode.value = v
        end
        # Evaluate every new assertion before touching the namespace.
        newfacts = Dict{String,Form}()
        for node in fresh.nodes
            haskey(node.params, _UI_K_ASSERT) || continue
            fact = _ui_eval_assert(fresh, node)
            fact === nothing || (newfacts[node.path] = fact)
        end
        # One transaction retracts the old facts and asserts the new ones.
        _ui_in_context(inst) do
            _tx_boundary(inst.env) do
                for (path, fact) in inst.asserts
                    node = _ui_node_by_path(inst, path)
                    node === nothing || _ui_fact_call(inst, node, :retract, fact)
                end
                for (path, fact) in newfacts
                    node = _ui_node_by_path(fresh, path)
                    node === nothing || _ui_fact_call(fresh, node, :assert, fact)
                end
            end
        end
        inst.root = fresh.root
        inst.nodes = fresh.nodes
        inst.byid = fresh.byid
        inst.asserts = newfacts
        inst.dismissed = false
        _ui_notify!(inst)
    end
    return _ui_key_form(inst.key)
end
special!(Symbol("ui-update!"), _bi_ui_update)

# ---- events ------------------------------------------------------------------

"""
    _ui_dispatch!(inst, event)

Route a renderer event to the runtime: `(:set id value)`, `(:click id)`,
`(:dismiss)`. (`:resize` is handled by the renderer itself.)
"""
function _ui_dispatch!(inst::_UiInstance, event)
    kind = event[1]
    if kind === :set
        return _ui_apply!(inst, event[2], event[3]; origin = :user)
    elseif kind === :click
        return _ui_click!(inst, String(event[2]))
    elseif kind === :dismiss
        inst.dismissed = true
        _ui_notify!(inst)
        return nothing
    end
    throw(AirEvalError("unknown UI event $(kind)"))
end

function _ui_click!(inst::_UiInstance, id::AbstractString)
    lock(inst.lock) do
        inst.closed && throw(AirEvalError("UI instance is closed"))
        node = _ui_find_node(inst, id)
        node === nothing && throw(AirEvalError(
            "no UI element $(air_string(Form(Symbol(":" * id))))"))
        node.kind.name === Symbol("button") || throw(AirEvalError(
            "UI element $(air_string(Form(Symbol(":" * id)))) is not a button"))
        if _ui_param_bool(node.params, _UI_K_DISABLED) === true
            return (:invalid, "element is disabled")
        end
        h = get(node.params, _UI_K_ON_CLICK, nothing)
        h === nothing || _ui_invoke!(inst, h, Form[])
        _ui_notify!(inst)
        return :ok
    end
end
