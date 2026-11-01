################################################################################
# ui/constructors.jl
#
# The air-level constructors for composite widgets. Each one builds a widget
# *form* — an inert `(ui KIND …)` tree — and returns it. The form is the durable
# handle: a widget's mutable state lives in a `mut` the form names, so storing
# the form somewhere reachable (a `def`, a `val`, another mutable) keeps the
# widget's state alive, and dropping the form lets it go.
#
#     (def w (ui-code))          ; a code block with its own state
#     (ui-open w)                ; instantiate and show it
#
# A caller may supply `state=` to share one mutable between two widgets.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# The namespace a constructor targets: the optional first argument, else the
# current namespace.
function _ui_target_ns(env::Env, scope::Scope, call::FormContainer,
                       name::AbstractString)
    length(call.seq) >= 2 ||
        throw(AirEvalError("$name takes at most one namespace argument"))
    return _ns_target_path(env, scope, to_form(call.seq[2]))
end

# A `mut` holding `value`, created in the current namespace like any air mut.
function _ui_new_state!(env::Env, scope::Scope, value::Form)
    call = FormContainer(FormSeq(FormValue[_store_form(Form(Symbol("mut"))),
                                           _store_form(value)]), FormMap())
    return _bi_mut(env, scope, call)
end

# The state mutable a constructor uses: the caller's `state=`, or a fresh one.
function _ui_state_for(env::Env, scope::Scope, call::FormContainer, value::Form)
    if haskey(call.map, Symbol(":state"))
        m = air_reduce(env, scope, to_form(call.map[Symbol(":state")]))
        m isa VolatileForm && return m
        throw(AirEvalError("state= must be a mutable"))
    end
    return _ui_new_state!(env, scope, value)
end

# The widget form for a component kind.
function _ui_component_form(kind::Symbol, state::VolatileForm,
                            nspath::Vector{Symbol},
                            extra::Vector{Pair{Symbol,Form}} = Pair{Symbol,Form}[])
    map = Pair{Symbol,Form}[Symbol(":state") => state,
                            Symbol(":ns") => _ns_path_form(nspath)]
    append!(map, extra)
    return _ns_form(Form[Form(UI_HEAD), Form(kind)], map)
end

# The `theme=` map a constructor was given, appended to `extra`. A widget theme
# is a role=color map; the component resolves it when it is built.
function _ui_theme_extra!(env::Env, scope::Scope, call::FormContainer,
                          extra::Vector{Pair{Symbol,Form}})
    key = Symbol(":theme")
    haskey(call.map, key) || return extra
    t = air_reduce(env, scope, to_form(call.map[key]))
    if !(t isa FormContainer && isempty(t.seq) && !isempty(t.map))
        throw(AirEvalError("theme= must be a map of role=color entries"))
    end
    push!(extra, key => t)
    return extra
end

# The text a code widget starts with, as an air string value.
function _ui_initial_text(env::Env, scope::Scope, call::FormContainer)
    key = Symbol(":text")
    haskey(call.map, key) || return ""
    f = air_reduce(env, scope, to_form(call.map[key]))
    s = _ui_string(f)
    s === nothing && throw(AirEvalError("text= must be a string"))
    return s
end

# `(ui-code [ns] text="…" state=…)` — an editable air source buffer.
function _bi_ui_code(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-code", (Symbol(":text"), Symbol(":state"),
                                     Symbol(":height"), Symbol(":theme")))
    length(call.seq) <= 2 ||
        throw(AirEvalError("ui-code takes at most one namespace"))
    path = length(call.seq) == 2 ? _ui_target_ns(env, scope, call, "ui-code") :
                                   copy(_context(env).ns.path)
    text = _ui_initial_text(env, scope, call)
    state = _ui_state_for(env, scope, call,
                          _ns_form(Form[], Pair{Symbol,Form}[
                              Symbol(":text") => Form(text)]))
    extra = _ui_theme_extra!(env, scope, call, Pair{Symbol,Form}[])
    return _ui_component_form(Symbol("code-block"), state, path, extra)
end
special!(Symbol("ui-code"), _bi_ui_code)

# `(ui-editor [ns] target=sym text="…" state=…)` — the definition editor. The
# buffer starts from the entry's stored source (`src=`) when the caller does not
# supply `text=`, and Ctrl-J appends the definitions in the buffer to `ns`.
function _bi_ui_editor(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-editor", (Symbol(":text"), Symbol(":state"),
                                       Symbol(":target"), Symbol(":height"),
                                       Symbol(":theme")))
    length(call.seq) <= 2 ||
        throw(AirEvalError("ui-editor takes at most one namespace"))
    path = length(call.seq) == 2 ? _ui_target_ns(env, scope, call, "ui-editor") :
                                   copy(_context(env).ns.path)
    target = nothing
    if haskey(call.map, Symbol(":target"))
        l = _leafof(air_reduce(env, scope, to_form(call.map[Symbol(":target")])))
        (l isa Symbol || l isa AbstractString) ||
            throw(AirEvalError("ui-editor: target= must be a symbol"))
        s = String(l)
        target = Symbol(startswith(s, ":") ? s[2:end] : s)
    end
    text = ""
    if haskey(call.map, Symbol(":text"))
        text = _ui_initial_text(env, scope, call)
    elseif target !== nothing
        text = _editor_source_text(env, path, target)
    end
    state = _ui_state_for(env, scope, call,
                          _ns_form(Form[], Pair{Symbol,Form}[
                              Symbol(":text") => Form(text)]))
    extra = target === nothing ? Pair{Symbol,Form}[] :
                                Pair{Symbol,Form}[Symbol(":target") => Form(target)]
    _ui_theme_extra!(env, scope, call, extra)
    return _ui_component_form(Symbol("editor"), state, path, extra)
end
special!(Symbol("ui-editor"), _bi_ui_editor)

# `(ui-notebook [ns] text="…" state=… collapse-lines=n)` — a column of input
# cells with their outputs. `text=` seeds the first cell.
function _bi_ui_notebook(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-notebook", (Symbol(":text"), Symbol(":state"),
                                          Symbol(":collapse-lines"),
                                          Symbol(":height"), Symbol(":theme")))
    length(call.seq) <= 2 ||
        throw(AirEvalError("ui-notebook takes at most one namespace"))
    path = length(call.seq) == 2 ? _ui_target_ns(env, scope, call, "ui-notebook") :
                                   copy(_context(env).ns.path)
    text = _ui_initial_text(env, scope, call)
    cell = _ns_form(Form[], Pair{Symbol,Form}[Symbol(":input") => Form(text)])
    cells = FormContainer(FormSeq(FormValue[_store_form(cell)]), FormMap())
    value = _ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":cells") => cells,
        Symbol(":active") => Form(1)])
    state = _ui_state_for(env, scope, call, value)
    extra = Pair{Symbol,Form}[]
    key = Symbol(":collapse-lines")
    if haskey(call.map, key)
        l = _leafof(air_reduce(env, scope, to_form(call.map[key])))
        l isa Real || throw(AirEvalError("collapse-lines= must be a number"))
        push!(extra, key => Form(Int(l)))
    end
    _ui_theme_extra!(env, scope, call, extra)
    return _ui_component_form(Symbol("notebook"), state, path, extra)
end
special!(Symbol("ui-notebook"), _bi_ui_notebook)

# `(ui-browser [root] state=…)` — the namespace tree. The optional argument (or
# `root=`) is the namespace it lists; the default is the current one.
function _bi_ui_browser(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-browser", (Symbol(":root"), Symbol(":state"),
                                        Symbol(":height"), Symbol(":theme")))
    length(call.seq) <= 2 ||
        throw(AirEvalError("ui-browser takes at most one namespace"))
    root = length(call.seq) == 2 ? _ui_target_ns(env, scope, call, "ui-browser") :
                                   copy(_context(env).ns.path)
    key = Symbol(":root")
    if haskey(call.map, key)
        root = _ns_target_path(env, scope, to_form(call.map[key]))
    end
    value = _ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":root") => _br_path_form(root),
        Symbol(":expanded") => naught,
        Symbol(":cursor") => Form(0)])
    state = _ui_state_for(env, scope, call, value)
    extra = _ui_theme_extra!(env, scope, call, Pair{Symbol,Form}[])
    return _ui_component_form(Symbol("browser"), state, root, extra)
end
special!(Symbol("ui-browser"), _bi_ui_browser)

# `(ui-shell state=…)` — a tab bar whose tabs are widget forms. A fresh shell
# starts with a browser and a scratch notebook in the current namespace; the
# component fills those in when the state names none.
function _bi_ui_shell(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-shell", (Symbol(":state"), Symbol(":height"),
                                      Symbol(":theme")))
    length(call.seq) == 1 ||
        throw(AirEvalError("ui-shell takes no namespace argument"))
    state = _ui_state_for(env, scope, call, _ns_empty_value())
    extra = _ui_theme_extra!(env, scope, call, Pair{Symbol,Form}[])
    return _ui_component_form(Symbol("shell"), state,
                              copy(_context(env).ns.path), extra)
end
special!(Symbol("ui-shell"), _bi_ui_shell)

# A stream a chat is wired to; both directions are required — a chat with no
# input could never hear anything, and one with no output could never speak.
function _ui_chat_stream(env::Env, scope::Scope, call::FormContainer,
                         key::Symbol)
    haskey(call.map, key) ||
        throw(AirEvalError("ui-chat: $(key)= must be a stream"))
    f = air_reduce(env, scope, to_form(call.map[key]))
    f isa StreamForm || throw(AirEvalError(
        "ui-chat: $(key)= must be a stream, got $(air_string(f))"))
    return f
end

# `(ui-chat in=s-out out=s-in peer=:alice state=…)` — a conversation over a pair
# of streams. The caller owns the streams and the wiring; the widget owns the
# log, the draft, and the pump that reads `in=`.
function _bi_ui_chat(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-chat", (Symbol(":in"), Symbol(":out"),
                                     Symbol(":peer"), Symbol(":state"),
                                     Symbol(":height"), Symbol(":theme")))
    length(call.seq) <= 2 ||
        throw(AirEvalError("ui-chat takes at most one namespace"))
    path = length(call.seq) == 2 ? _ui_target_ns(env, scope, call, "ui-chat") :
                                   copy(_context(env).ns.path)
    inbox = _ui_chat_stream(env, scope, call, Symbol(":in"))
    outbox = _ui_chat_stream(env, scope, call, Symbol(":out"))
    peer = nothing
    if haskey(call.map, Symbol(":peer"))
        l = _leafof(air_reduce(env, scope, to_form(call.map[Symbol(":peer")])))
        (l isa Symbol || l isa AbstractString) || throw(AirEvalError(
            "ui-chat: peer= must be a keyword or a string"))
        s = String(l)
        peer = startswith(s, ":") ? String(s[2:end]) : s
    end
    value = _ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":log") => FormContainer(FormSeq(FormValue[]), FormMap()),
        Symbol(":draft") => Form("")])
    state = _ui_state_for(env, scope, call, value)
    extra = Pair{Symbol,Form}[Symbol(":in") => inbox, Symbol(":out") => outbox]
    peer === nothing || push!(extra, Symbol(":peer") => Form(peer))
    _ui_theme_extra!(env, scope, call, extra)
    return _ui_component_form(Symbol("chat"), state, path, extra)
end
special!(Symbol("ui-chat"), _bi_ui_chat)

# The source text of an entry: its stored `src=` frame when it has one, else the
# printed form of the definition (best effort — a comment or a layout choice is
# not recoverable).
function _editor_source_text(env::Env, path::Vector{Symbol}, name::Symbol)
    ns = _ns_lookup(env, path)
    ns === nothing && return ""
    e = _ns_named_entry(env, ns, name)
    e === nothing && return ""
    s = _ns_entry_src(e)
    s === nothing || return s
    b = _entry_body(e)
    b isa FormContainer || return ""
    return air_pretty_string(env, _strip_def_options(b); width = 78)
end

# A stored `(def pattern body…)` entry without the map options the entry keeps
# for itself (`src=`, `doc=`, the memo mode); the docstring moves back into the
# body, where the reader expects it.
function _strip_def_options(b::FormContainer)
    if !isempty(b.map)
        seq = FormValue[v for v in b.seq]
        map = Pair{Symbol,FormValue}[]
        doc = nothing
        for (k, v) in b.map
            if k === _DOC_KEY
                doc = to_form(v)
            elseif k === _SRC_KEY || k === _MEMO_KEY
                continue
            else
                push!(map, k => v)
            end
        end
        b = FormContainer(FormSeq(seq), FormMap(map))
        if doc !== nothing
            l = _leafof(doc)
            l isa AbstractString || return b
            body = FormValue[v for v in b.seq]
            insert!(body, 3, _store_form(Form(String(l))))
            b = FormContainer(FormSeq(body), FormMap(map))
        end
    end
    return b
end
