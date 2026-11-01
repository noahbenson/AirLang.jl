################################################################################
# ui/browser.jl
#
# The namespace browser: a tree of one namespace's readable entries, built from
# `ns-entries` (never from Air's internal marker forms). Subnamespaces expand in
# place; a definition opens in the editor; a `val` opens in a notebook.
#
# What the tree lists is exactly what the caller may read — an entry it cannot
# read is absent, not greyed out, which is also what `doc` and `using` do.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

mutable struct _BrRow
    path::Vector{Symbol}            # the namespace that holds the entry
    name::Symbol
    kind::Symbol                    # :def :val :proxy :alias :sub
    depth::Int
    doc::String
end

mutable struct _Browser <: _Comp
    base::_CompBase
    root::Vector{Symbol}
    expanded::Vector{Vector{Symbol}}
    cursor::Int
    rows::Vector{_BrRow}
    width::Int
    cur_row::Int
    cur_col::Int
    filter::String                      # the accepted narrowing ("" = none)
    prompt::Union{Nothing,String}       # the filter line while it is being typed
    narrowed::Bool                      # the rows came from a narrowing walk
    scanned::Int                        # entries the last narrowing walk considered
    truncated::Bool                     # the walk hit a bound before finishing
end

# A narrowing walk is bounded: a large database can hold thousands of entries,
# and a keystroke must stay cheap.
const _BR_SEARCH_MAX_ROWS = 400
const _BR_SEARCH_MAX_SCAN = 4000
const _BR_SEARCH_MAX_DEPTH = 8

_comp_title(c::_Browser) = "browser"

# ---- entries -----------------------------------------------------------------

# The path as stored data: its dotted spelling (`"main.util"`), `""` for the
# root. A string is inert, so the value survives reduction — which matters
# because a widget's state value is written through `(mut …)` and read back
# through `_ui_build!`, and both reduce their input (a bare symbol would reduce,
# and `.` would become the namespace itself). A namespace segment never contains
# a dot, so the spelling is unambiguous.
_br_path_form(path::Vector{Symbol}) =
    Form(isempty(path) ? "" : join(String.(path), "."))

# Read a stored path form back.
function _br_stored_path(x::Form)
    s = _ui_string(x)
    s === nothing && return nothing
    return isempty(s) ? Symbol[] : Symbol.(split(s, '.'))
end

# The path as an *address* form — `(get . :main :util)` — which is what a
# constructor's positional namespace argument accepts.
function _br_address_form(path::Vector{Symbol})
    isempty(path) && return Form(DOT_ROOT)
    seq = Form[Form(Symbol("get")), Form(DOT_ROOT)]
    for s in path
        push!(seq, Form(Symbol(":", String(s))))
    end
    return _ns_form(seq)
end

# Run `f` with `ns` as the current namespace (the same in-place swap `namespace`
# makes), so a listing call that names no target reads exactly that namespace.
function _br_in_ns(env::Env, ns::Namespace, f::Function)
    ctx = _context(env)
    return _with_context(env, TaskContext(ctx.user, ns, ctx.dbroot, ctx.env,
                                          ctx.out), f)
end

# The readable entries of a namespace as `(name, kind, doc)` triples, deduped by
# name (the last definition wins) and sorted.
function _br_list(env::Env, path::Vector{Symbol})
    ns = _ns_lookup(env, path)
    ns === nothing && return Tuple{Symbol,Symbol,String}[]
    call = FormContainer(FormSeq(FormValue[
        _store_form(Form(Symbol("ns-entries")))]), FormMap())
    r = _br_in_ns(env, ns, () -> _bi_ns_entries(env, _base_scope(env), call))
    r isa FormContainer || return Tuple{Symbol,Symbol,String}[]
    byname = Dict{Symbol,Tuple{Symbol,Symbol,String}}()
    for el in r.seq
        f = to_form(el)
        n = lstrip(_state_string(f, Symbol(":name")), ':')
        isempty(n) && continue
        k = _state_field(f, Symbol(":kind"))
        kl = k === nothing ? nothing : _leafof(k)
        kl isa Symbol || (kl = :def)
        push!(byname, Symbol(n) => (Symbol(n), Symbol(lstrip(String(kl), ':')), _state_string(f, Symbol(":doc"))))
    end
    return sort(collect(values(byname)); by = t -> String(t[1]))
end

# The query the rows are narrowed by: the filter line while it is open, else the
# accepted filter.
_br_query(c::_Browser) = c.prompt === nothing ? c.filter : c.prompt

# Recompute the visible rows from the root and the expansion set.
function _br_refresh!(c::_Browser, env::Env)
    # A stored root can outlive its namespace; fall back to the tree's top.
    if !isempty(c.root) && _ns_lookup(env, c.root) === nothing
        c.root = Symbol[]
        empty!(c.expanded)
    end
    rows = _BrRow[]
    c.scanned = 0
    c.truncated = false
    q = strip(_br_query(c))
    c.narrowed = !isempty(q)
    if c.narrowed
        _br_search!(c, rows, env, c.root, 0, lowercase(q))
    else
        _br_walk!(rows, env, c.root, 0, c.expanded)
    end
    c.rows = rows
    isempty(c.rows) && (c.cursor = 0)
    c.cursor = clamp(c.cursor, 0, length(c.rows))
    return nothing
end

# Every non-subnamespace entry below `path` whose name contains `q`, with the
# namespaces in between as context in the row's path. The walk descends into
# every subnamespace — expansion is a tree-view notion, and a search should not
# be blinded by what happens to be collapsed — but it is bounded so a keystroke
# never turns into a scan of a whole database.
function _br_search!(c::_Browser, rows::Vector{_BrRow}, env::Env,
                     path::Vector{Symbol}, depth::Int, q::AbstractString)
    depth > _BR_SEARCH_MAX_DEPTH && return nothing
    for (name, kind, doc) in _br_list(env, path)
        if length(rows) >= _BR_SEARCH_MAX_ROWS ||
           c.scanned >= _BR_SEARCH_MAX_SCAN
            c.truncated = true
            return nothing
        end
        child = vcat(path, [name])
        if kind === :sub
            occursin(q, lowercase(String(name))) &&
                push!(rows, _BrRow(path, name, kind, 0, doc))
            _br_search!(c, rows, env, child, depth + 1, q)
            continue
        end
        c.scanned += 1
        occursin(q, lowercase(String(name))) &&
            push!(rows, _BrRow(path, name, kind, 0, doc))
    end
    return nothing
end

function _br_walk!(rows::Vector{_BrRow}, env::Env, path::Vector{Symbol}, depth::Int,
                   expanded::Vector{Vector{Symbol}})
    for (name, kind, doc) in _br_list(env, path)
        push!(rows, _BrRow(path, name, kind, depth, doc))
        child = vcat(path, [name])
        if kind === :sub && any(p -> p == child, expanded)
            childns = _ns_lookup(env, child)
            childns === nothing && continue
            _br_walk!(rows, env, child, depth + 1, expanded)
        end
    end
    return nothing
end

# Whether a sub entry is expanded.
_br_open(c::_Browser, r::_BrRow) = any(p -> p == vcat(r.path, [r.name]), c.expanded)

# ---- construction ------------------------------------------------------------

function _comp_browser(inst::_UiInstance, node::_UiNode)
    state = _comp_state_mut(node.params)
    path = _comp_namespace(node.params, _comp_captured_ns(inst))
    if haskey(node.params, Symbol(":root"))
        p = _stored_path(to_form(node.params[Symbol(":root")]))
        p === nothing || (path = p)
    end
    base = _CompBase(node; state = state, nspath = path)
    c = _Browser(base, path, Vector{Symbol}[], 0, _BrRow[], 80, 0, 0, "",
                 nothing, false, 0, false)
    if state !== nothing
        v = _ui_in_context(inst) do
            canonicalize(state[])
        end
        r = _state_field(v, Symbol(":root"))
        if r !== nothing
            p = _br_stored_path(to_form(r))
            p === nothing || (c.root = p)
        end
        e = _state_field(v, Symbol(":expanded"))
        if e isa FormContainer
            for el in e.seq
                p = _br_stored_path(to_form(el))
                p === nothing || push!(c.expanded, p)
            end
        end
        cur = _state_field(v, Symbol(":cursor"))
        if cur !== nothing
            l = _leafof(cur)
            l isa Real && (c.cursor = Int(l))
        end
        # An accepted filter is part of the view the user left behind, so a
        # reopened browser comes back narrowed; the line being typed is not.
        c.filter = _state_string(v, Symbol(":filter"))
    end
    c.base.nspath = c.root
    _ui_in_context(inst) do
        _br_refresh!(c, inst.env)
    end
    return c
end

# ---- persistence -------------------------------------------------------------

function _br_state_form(c::_Browser)
    expanded = FormContainer(FormSeq(FormValue[
        _store_form(_br_path_form(p)) for p in c.expanded]), FormMap())
    entries = Pair{Symbol,Form}[
        Symbol(":root") => _br_path_form(c.root),
        Symbol(":expanded") => expanded,
        Symbol(":cursor") => Form(c.cursor)]
    isempty(c.filter) || push!(entries, Symbol(":filter") => Form(c.filter))
    return _ns_form(Form[], entries)
end

function _br_store!(c::_Browser, inst::_UiInstance)
    c.base.state === nothing && return nothing
    _comp_set_state!(c, inst, _br_state_form(c))
    return nothing
end

_comp_flush!(c::_Browser, inst::_UiInstance) = _br_store!(c, inst)
_comp_close!(c::_Browser, inst::_UiInstance) = _br_store!(c, inst)

# ---- rendering ---------------------------------------------------------------

function _comp_lines(c::_Browser, inst::_UiInstance, width::Int)
    c.width = width
    lines = _UiLine[]
    c.cur_row = 0
    c.cur_col = 0
    for (i, r) in enumerate(c.rows)
        active = i == c.cursor
        spans = _UiSpan[]
        label = ""
        if c.narrowed
            # A match is shown flat with its namespace for context, because the
            # tree above it is not what the user is looking at.
            if !isempty(r.path)
                p = join(String.(r.path), ".") * "."
                push!(spans, _UiSpan(p, _ui_role(:muted)))
                label *= p
            end
            mark = r.kind === :sub ? "▸ " : "· "
            label *= mark * String(r.name)
            push!(spans, _UiSpan(mark * String(r.name),
                                 _ui_role(active ? :accent : :text)))
        else
            ind = repeat("  ", r.depth)
            mark = r.kind === :sub ? (_br_open(c, r) ? "▾ " : "▸ ") : "· "
            label = ind * mark * String(r.name)
            push!(spans, _UiSpan(label, _ui_role(active ? :accent : :text)))
        end
        kindtag = r.kind === :sub ? "" : string("  ", r.kind)
        if !isempty(kindtag)
            push!(spans, _UiSpan(kindtag, _ui_role(:muted)))
        end
        room = width - textwidth(label) - textwidth(kindtag) - 4
        if !isempty(r.doc) && room > 8
            doc = textwidth(r.doc) > room ? first(r.doc, room - 1) * "…" : r.doc
            push!(spans, _UiSpan("  " * doc, _ui_role(:comment)))
        end
        active && (c.cur_row = i; c.cur_col = 0)
        push!(lines, _ui_styled(spans))
    end
    isempty(lines) &&
        push!(lines, _ui_styled([_UiSpan(c.narrowed ? "(no match)" : "(no entries)",
                                         _ui_role(:muted))]))
    return lines
end

_comp_cursor(c::_Browser, inst::_UiInstance) = (c.cur_row, c.cur_col)

# The filter line, shown in place of the status while the prompt is open.
function _br_filter_line(c::_Browser)
    s = string("filter: ", c.prompt)
    isempty(strip(c.prompt)) && return s
    n = length(c.rows)
    n == 0 && return s * "  ·  no match"
    s *= string("  ·  ", n, " of ", c.scanned, " entr", c.scanned == 1 ? "y" : "ies")
    c.truncated && (s *= "  ·  first " * string(_BR_SEARCH_MAX_ROWS))
    return s
end

function _comp_status(c::_Browser, inst::_UiInstance)
    c.prompt !== nothing && return _br_filter_line(c)
    isempty(c.base.status) || return c.base.status
    n = length(c.rows)
    s = string(n, " entr", n == 1 ? "y" : "ies")
    isempty(c.filter) ||
        (s = string(n, " of ", c.scanned, " entr", c.scanned == 1 ? "y" : "ies",
                    "  ·  filter: ", c.filter))
    return s
end

_comp_hints(c::_Browser) =
    !isempty(c.filter) ?
    ["ctrl-s: filter" => "^S filter", "esc: clear filter" => "esc"] :
    ["ctrl-j: open" => "^J open", "ctrl-s: filter" => "^S filter",
     "enter: expand" => "enter"]

# While the filter line is open it is the prompt: the shell shows it in the
# status row and leaves its keys alone.
_comp_prompt(c::_Browser, inst::_UiInstance) =
    c.prompt === nothing ? nothing : _br_filter_line(c)

_comp_prompt_hints(c::_Browser) =
    c.prompt === nothing ? _comp_hints(c) :
    ["enter: accept" => "enter", "esc: cancel" => "esc"]

# ---- keys --------------------------------------------------------------------

# Toggle the sub entry under the cursor.
function _br_toggle!(c::_Browser, inst::_UiInstance)
    (1 <= c.cursor <= length(c.rows)) || return nothing
    r = c.rows[c.cursor]
    r.kind === :sub || return nothing
    child = vcat(r.path, [r.name])
    if _br_open(c, r)
        c.expanded = [p for p in c.expanded if p != child]
    else
        push!(c.expanded, child)
    end
    _ui_in_context(inst) do
        _br_refresh!(c, inst.env)
        for (i, row) in enumerate(c.rows)
            if row.path == r.path && row.name == r.name
                c.cursor = i
                break
            end
        end
    end
    _br_store!(c, inst)
    return nothing
end

# ---- the filter line ---------------------------------------------------------

# Ctrl-S: open the filter line seeded with the accepted filter. Typing narrows
# the tree live; Enter accepts the text, Esc cancels back to what was accepted.
function _br_filter_open!(c::_Browser)
    c.prompt = c.filter
    c.base.status = ""
    return nothing
end

function _br_filter_changed!(c::_Browser, inst::_UiInstance)
    _ui_in_context(inst) do
        _br_refresh!(c, inst.env)
    end
    c.cursor = isempty(c.rows) ? 0 : 1
    c.base.top = 1
    return nothing
end

function _br_filter_accept!(c::_Browser, inst::_UiInstance)
    c.filter = strip(c.prompt)
    c.prompt = nothing
    _br_filter_changed!(c, inst)
    _br_store!(c, inst)
    return nothing
end

function _br_filter_cancel!(c::_Browser, inst::_UiInstance)
    c.prompt = nothing
    _br_filter_changed!(c, inst)
    return nothing
end

function _br_filter_clear!(c::_Browser, inst::_UiInstance)
    c.filter = ""
    c.prompt = nothing
    _br_filter_changed!(c, inst)
    _br_store!(c, inst)
    return :handled
end

function _br_filter_key!(c::_Browser, inst::_UiInstance, k::_UiKey)
    if k.name === :esc
        _br_filter_cancel!(c, inst)
    elseif k.name === :enter
        _br_filter_accept!(c, inst)
    elseif k.name === :backspace
        isempty(c.prompt) || (c.prompt = chop(c.prompt; tail = 1))
        _br_filter_changed!(c, inst)
    elseif k.name === :up || k.name === :down
        # The cursor moves through the matches while the line stays open.
        n = length(c.rows)
        c.cursor = clamp(c.cursor + (k.name === :down ? 1 : -1), 1, max(n, 1))
    elseif k.name === :char && !k.ctrl && !k.alt && k.char !== nothing &&
           isprint(k.char)
        c.prompt *= string(k.char)
        _br_filter_changed!(c, inst)
    end
    return :handled
end

# Entering a namespace shown by a narrowing walk: that is the whole reason the
# subnamespace is in the list, so it becomes the root and the filter drops away.
function _br_enter_ns!(c::_Browser, inst::_UiInstance, r::_BrRow)
    c.root = vcat(r.path, [r.name])
    empty!(c.expanded)
    c.filter = ""
    c.prompt = nothing
    c.cursor = 1
    c.base.status = ""
    c.base.top = 1
    _ui_in_context(inst) do
        _br_refresh!(c, inst.env)
    end
    _br_store!(c, inst)
    return :handled
end

# Ctrl-J on an entry: a sub expands, a definition opens the editor in its
# namespace, a `val` opens a notebook seeded with a reference to it.
function _br_open!(c::_Browser, inst::_UiInstance, row::_BrRow)
    row.kind === :sub &&
        return (c.narrowed ? _br_enter_ns!(c, inst, row) : _br_toggle!(c, inst))
    env = inst.env
    pathform = _br_address_form(row.path)
    if row.kind === :def || row.kind === :proxy
        call = FormContainer(FormSeq(FormValue[
            _store_form(Form(Symbol("ui-editor"))),
            _store_form(pathform)]), FormMap(Pair{Symbol,FormValue}[
            # A keyword, not a bare symbol: `target=` is evaluated, and a
            # bare symbol would be reduced (a definition named after another
            # definition would arrive as that definition's value).
            Symbol(":target") => _store_form(Form(Symbol(":", row.name)))]))
        return (:open, String(row.name),
                _bi_ui_editor(env, _base_scope(env), call))
    else
        call = FormContainer(FormSeq(FormValue[
            _store_form(Form(Symbol("ui-notebook"))),
            _store_form(pathform)]), FormMap(Pair{Symbol,FormValue}[
            Symbol(":text") => _store_form(Form(String(row.name)))]))
        return (:open, String(row.name),
                _bi_ui_notebook(env, _base_scope(env), call))
    end
end

function _comp_key!(c::_Browser, inst::_UiInstance, k::_UiKey)
    c.prompt !== nothing && return _br_filter_key!(c, inst, k)
    n = length(c.rows)
    if k.name === :up
        c.cursor = max(c.cursor - 1, 1)
        return :handled
    elseif k.name === :down
        c.cursor = min(c.cursor + 1, n)
        return :handled
    elseif k.name === :home
        c.cursor = 1
        return :handled
    elseif k.name === :end
        c.cursor = n
        return :handled
    elseif k.name === :pageup
        c.cursor = max(c.cursor - 10, 1)
        return :handled
    elseif k.name === :pagedown
        c.cursor = min(c.cursor + 10, n)
        return :handled
    elseif k.name === :enter || k.name === :right
        (1 <= c.cursor <= n) || return :handled
        r = c.rows[c.cursor]
        if r.kind === :sub
            _br_open!(c, inst, r)
        elseif k.name === :enter
            return _br_open!(c, inst, r)
        end
        return :handled
    elseif k.name === :left
        (1 <= c.cursor <= n) || return :handled
        r = c.rows[c.cursor]
        if r.kind === :sub && _br_open(c, r)
            _br_toggle!(c, inst)
        elseif r.depth > 0
            for i in (c.cursor - 1):-1:1
                if c.rows[i].depth < r.depth
                    c.cursor = i
                    break
                end
            end
        end
        return :handled
    elseif k.name === :char && k.ctrl && k.char == 's'
        _br_filter_open!(c)
        return :handled
    elseif k.name === :esc
        # A narrowing is a layer: Esc clears it before the shell closes the tab.
        isempty(c.filter) && return :bubble
        return _br_filter_clear!(c, inst)
    elseif k.name === :char && k.ctrl && k.char == 'j'
        (1 <= c.cursor <= n) || return :handled
        return _br_open!(c, inst, c.rows[c.cursor])
    elseif k.name === :char && k.alt && k.char == 'j'
        (1 <= c.cursor <= n) || return :handled
        r = c.rows[c.cursor]
        r.kind === :val || return :handled
        return _br_open!(c, inst, _BrRow(r.path, r.name, :def, r.depth, r.doc))
    end
    return :bubble
end
