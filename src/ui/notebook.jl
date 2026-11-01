################################################################################
# ui/notebook.jl
#
# The notebook: a column of input cells, each paired with the output of its
# last run. It is the air analogue of a lab notebook — write a form, Ctrl-J, see
# the result under the cell, keep writing.
#
# Two ideas shape it. First, the document is continuous: the cursor moves line by
# line from one input cell into the next, so moving down at the last line of a
# cell lands on the first line of the next one. Long cells collapse to a window
# around the cursor; Enter opens the cell on its own (the scrolling, editable
# view) and Esc returns to the document.
#
# Second, an output belongs to the *text that produced it*. Each cell records
# `output-for`; when the input changes, the old output stays in place but is
# drawn dimmed (it is stale, not wrong), and running again replaces it.
#
# Every cell is a `_CodeBlock`, so editing (pairing, automatic indentation from
# the layout, highlighting) is exactly the code block's behavior; the notebook
# only adds the document around the cells.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

mutable struct _Notebook <: _Comp
    base::_CompBase
    cells::Vector{_CodeBlock}
    active::Int
    collapse::Int                   # lines shown for a long cell
    mode::Symbol                    # :nav (editing) | :scroll (one cell) | :select
    width::Int
    cur_row::Int                    # the cursor's document row, from the last draw
    cur_col::Int
    queue::Vector{Int}              # cells waiting for run-all, in order
    chord::Char                     # a pending two-key command, '\0' for none
    last_deleted::Union{Nothing,Tuple{Int,_CodeBlock}}
end

_comp_title(c::_Notebook) = "notebook"

# ---- construction ------------------------------------------------------------

# A fresh cell: an empty code block sharing the notebook's namespace.
function _nb_new_cell(inst::_UiInstance, nspath::Vector{Symbol};
                      text::AbstractString = "", saved::AbstractString = "")
    base = _CompBase(inst.root; state = nothing, nspath = nspath)
    return _CodeBlock(base, _TextBuffer(text), String(saved), :code, nothing,
                      _UiLine[], "", false, nothing, nothing, 80, nothing, "")
end

# Rebuild a cell from its stored form.
function _nb_cell_from_form(inst::_UiInstance, nspath::Vector{Symbol}, f::Form)
    text = _state_string(f, :input)
    output = _state_string(f, :output)
    out_for = _state_string(f, Symbol(":output-for"))
    failed = _state_flag(f, :error)
    cell = _nb_new_cell(inst, nspath; text = text, saved = out_for)
    cell.elapsed = _state_number(f, :time)
    if !isempty(output) || !isempty(out_for)
        role = failed ? :error : :text
        cell.out = [_ui_styled([_UiSpan(String(l), _ui_role(role))])
                    for l in split(output, '\n')]
        cell.out_for = out_for
        cell.failed = failed
    end
    return cell
end

function _comp_notebook(inst::_UiInstance, node::_UiNode)
    state = _comp_state_mut(node.params)
    nspath = _comp_namespace(node.params, _comp_captured_ns(inst))
    f = get(node.params, _map_key(Symbol(":collapse-lines")), nothing)
    collapse = f === nothing ? 20 : (l = _leafof(f); l isa Real ? Int(l) : 20)
    base = _CompBase(node; state = state, nspath = nspath)
    c = _Notebook(base, _CodeBlock[], 1, max(collapse, 4), :nav, 80, 0, 2, Int[],
                  '\0', nothing)
    active = 1
    v = _comp_state_value(inst, state)
    if v !== nothing
        cells = _state_field(v, :cells)
        if cells isa FormContainer
            for el in cells.seq
                push!(c.cells, _nb_cell_from_form(inst, nspath, to_form(el)))
            end
        end
        a = _state_field(v, :active)
        if a !== nothing
            l = _leafof(a)
            l isa Real && (active = Int(l))
        end
    end
    if isempty(c.cells)
        push!(c.cells, _nb_new_cell(inst, nspath; text = _comp_initial_text(node, v)))
    end
    c.active = clamp(active, 1, length(c.cells))
    return c
end

# ---- persistence -------------------------------------------------------------

# The state value: `(cells=((input=… output=… output-for=…) …) active=n)`.
function _nb_state_form(c::_Notebook)
    cells = FormValue[]
    for cell in c.cells
        map = Pair{Symbol,Form}[
            Symbol(":input") => Form(_tb_text(cell.buf)),
            Symbol(":output") => Form(join((l.text for l in cell.out), "\n")),
            Symbol(":output-for") => Form(cell.out_for)]
        cell.failed && push!(map, Symbol(":error") => Form(true))
        cell.elapsed === nothing ||
            push!(map, Symbol(":time") => Form(cell.elapsed))
        push!(cells, _store_form(_ns_form(Form[], map)))
    end
    seq = FormContainer(FormSeq(cells), FormMap())
    return _ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":cells") => seq,
        Symbol(":active") => Form(c.active)])
end

function _nb_store!(c::_Notebook, inst::_UiInstance)
    c.base.state === nothing && return nothing
    _comp_set_state!(c, inst, _nb_state_form(c))
    return nothing
end

_comp_flush!(c::_Notebook, inst::_UiInstance) = _nb_store!(c, inst)
_comp_close!(c::_Notebook, inst::_UiInstance) = _nb_store!(c, inst)

# Any cell can be running (each owns its job), so the notebook polls them all
# and persists the results as they land.
_comp_running(c::_Notebook) = any(_comp_running, c.cells)

function _comp_job_label(c::_Notebook)
    i = findfirst(_comp_running, c.cells)
    return i === nothing ? "running…" : _comp_job_label(c.cells[i])
end

# Cancelling also drops the rest of a run-all queue: the document action is
# over, and leaving the queue would start the next cell after the abort.
function _comp_cancel_jobs!(c::_Notebook)
    n = 0
    for cell in c.cells
        n += _comp_cancel_jobs!(cell)
    end
    empty!(c.queue)
    return n
end

function _comp_tick!(c::_Notebook, inst::_UiInstance)
    done = false
    for cell in c.cells
        _comp_tick!(cell, inst) && (done = true)
    end
    done || return false
    # A queued cell starts only once the running one has landed, so run-all
    # evaluates the document in order and each result is stored before the next
    # cell begins.
    _nb_run_next!(c, inst)
    _nb_store!(c, inst)
    lock(inst.lock) do
        inst.dirty = true
    end
    return true
end

# ---- run-all -----------------------------------------------------------------

# Queue every non-empty cell and start the first: Ctrl-R. Cells run one at a
# time so a later cell sees what an earlier one defined.
function _nb_run_all!(c::_Notebook, inst::_UiInstance)
    if _comp_running(c)
        c.base.status = "a cell is still running"
        return nothing
    end
    c.queue = [i for (i, cell) in enumerate(c.cells)
               if !isempty(strip(_tb_text(cell.buf)))]
    if isempty(c.queue)
        c.base.status = "no cells to run"
        return nothing
    end
    c.mode === :scroll && (c.mode = :nav)   # run-all is not a per-cell view
    c.base.status = ""
    _nb_run_next!(c, inst)
    return nothing
end

# Start the next queued cell unless one is already running. A cell that refuses
# before it runs (unclosed input, an empty cell) stops the queue so its message
# stays on the status row.
function _nb_run_next!(c::_Notebook, inst::_UiInstance)
    _comp_running(c) && return nothing
    while !isempty(c.queue)
        i = popfirst!(c.queue)
        1 <= i <= length(c.cells) || continue
        cell = c.cells[i]
        isempty(strip(_tb_text(cell.buf))) && continue
        c.active = i
        _nb_place!(cell.buf, :first)
        _cb_run!(cell, inst; label = "running cell $i…")
        if !_comp_running(cell)
            empty!(c.queue)
            c.base.status = cell.base.status
            return nothing
        end
        c.base.status = ""
        return nothing
    end
    c.base.status = ""
    return nothing
end

# Clear the active cell's output (Ctrl-O) or every cell's (Alt-O); a running
# cell keeps what it is about to write.
function _nb_clear!(c::_Notebook, inst::_UiInstance, all::Bool)
    n = 0
    for cell in c.cells
        (all || cell === c.cells[c.active]) || continue
        _comp_running(cell) && continue
        (isempty(cell.out) && isempty(cell.out_for)) && continue
        empty!(cell.out)
        cell.out_for = ""
        cell.failed = false
        cell.elapsed = nothing       # the duration belonged to the cleared run
        n += 1
    end
    c.base.status = n === 0 ? "no output to clear" :
        (all ? "cleared all output" : "cleared output")
    n == 0 || _nb_store!(c, inst)
    return nothing
end

# ---- rendering ---------------------------------------------------------------

# The line window shown for a cell: `(from, to, hidden-above, hidden-below)`.
function _nb_window(n::Int, row::Int, collapse::Int, active::Bool)
    n <= collapse && return (1, n, 0, 0)
    active || return (1, collapse, 0, n - collapse)
    from = clamp(row - collapse ÷ 2, 1, n - collapse + 1)
    return (from, from + collapse - 1, from - 1, n - (from + collapse - 1))
end

_nb_gutter(active::Bool, select::Bool = false) =
    select && active ? _UiSpan("▌ ", _ui_role(:selection)) :
    _UiSpan(active ? "▌ " : "│ ", _ui_role(active ? :accent : :border))

function _nb_push_cell!(c::_Notebook, doc::Vector{_UiLine}, cell::_CodeBlock,
                        is_active::Bool, full::Bool)
    b = cell.buf
    text = _tb_text(b)
    hl = _cb_render_lines(cell, is_active)
    n = _tb_nlines(b)
    (from, to, above, below) = full ? (1, n, 0, 0) :
        _nb_window(n, is_active ? b.row : 1, c.collapse, is_active)
    gut = _nb_gutter(is_active, !full && c.mode === :select)
    above > 0 && push!(doc, _ui_styled([gut, _UiSpan(
        string("… ", above, " lines above"), _ui_role(:muted))]))
    for k in from:to
        spans = k <= length(hl) ? hl[k] : _UiSpan[]
        if is_active && k == b.row
            c.cur_row = length(doc) + 1
            c.cur_col = textwidth(gut.text) + _tb_display_col(b)
        end
        push!(doc, _ui_styled(vcat([gut], spans)))
    end
    below > 0 && push!(doc, _ui_styled([gut, _UiSpan(
        string("… ", below, " more lines — enter to open"), _ui_role(:muted))]))
    if !isempty(cell.out) || cell.elapsed !== nothing
        stale = cell.out_for != text
        push!(doc, _ui_styled(vcat([gut,
            _ui_ruler(max(c.width - 3, 8), cell.elapsed; stale = stale).spans...])))
        for l in cell.out
            spans = _ui_line_spans(l)
            stale && (spans = [_UiSpan(s.text, _ui_role(:muted)) for s in spans])
            push!(doc, _ui_styled(vcat([gut], spans)))
        end
    end
    return nothing
end

function _comp_lines(c::_Notebook, inst::_UiInstance, width::Int)
    c.width = width
    doc = _UiLine[]
    c.cur_row = 0
    c.cur_col = 2
    if c.mode === :scroll
        _nb_push_cell!(c, doc, c.cells[c.active], true, true)
        return doc
    end
    for (i, cell) in enumerate(c.cells)
        i > 1 && push!(doc, _ui_styled(_UiSpan[]))
        _nb_push_cell!(c, doc, cell, i == c.active, false)
    end
    return doc
end

_comp_cursor(c::_Notebook, inst::_UiInstance) =
    c.mode === :select ? nothing : (c.cur_row, c.cur_col)

_comp_dirty(c::_Notebook, inst::_UiInstance) =
    any(cell -> _tb_text(cell.buf) != cell.saved, c.cells)

function _comp_status(c::_Notebook, inst::_UiInstance)
    isempty(c.base.status) || return c.base.status
    if c.mode === :select
        s = string("cell ", c.active, "/", length(c.cells), "  ·  select")
        if c.chord != '\0'
            what = c.chord == 'd' ? "delete" : "interrupt"
            s *= string("  ·  ", c.chord, "… (", c.chord, ": ", what, ")")
        end
        return s
    end
    cell = c.cells[c.active]
    v = _ui_closure(_tb_text(cell.buf))
    verdict = v[1] === :ok ? "closed" :
              v[1] === :incomplete ? "unclosed" : "error"
    s = string("cell ", c.active, "/", length(c.cells), "  ·  ",
               _tb_nlines(cell.buf), " lines  ·  ", verdict)
    # A cell can have something to say of its own (a comment toggle); it is
    # transient, cleared by the next key the notebook forwards.
    isempty(cell.base.status) || (s *= "  ·  " * cell.base.status)
    c.mode === :scroll && (s *= "  ·  esc: document")
    return s
end

# A prompt open in the active cell belongs to the notebook too.
function _comp_prompt(c::_Notebook, inst::_UiInstance)
    return _comp_prompt(c.cells[c.active], inst)
end

function _comp_prompt_hints(c::_Notebook)
    return _comp_prompt_hints(c.cells[c.active])
end

_comp_hints(c::_Notebook) =
    c.mode === :scroll ? ["ctrl-j: run" => "^J run", "esc: document" => "esc"] :
    c.mode === :select ?
        ["enter: edit" => "enter", "j/k: cell" => "j/k",
         "a/b: insert" => "a/b", "i,i: interrupt" => "i,i",
         "ctrl-j: run" => "^J run", "esc: close" => "esc"] :
        ["ctrl-j: run" => "^J run", "ctrl-shift-j: run & next" => "^J next",
         "ctrl-r: all" => "^R all", "esc: select" => "esc"]

# ---- cell motion -------------------------------------------------------------

# Put the cursor at the first (`:first`) or last (`:last`) line of a cell,
# keeping the column when it fits.
function _nb_place!(b::_TextBuffer, which::Symbol)
    b.row = which === :first ? 1 : _tb_nlines(b)
    b.col = min(b.col, length(b.lines[b.row]))
    b.anchor = nothing
    b.goal = -1
    return nothing
end

# Move the active cell by `d`, placing the cursor at the near end.
function _nb_jump!(c::_Notebook, d::Int)
    c.active = clamp(c.active + d, 1, length(c.cells))
    _nb_place!(c.cells[c.active].buf, d >= 0 ? :first : :last)
    c.base.status = ""
    return nothing
end

# A page move inside the cell; at an edge the move crosses into the next cell.
function _nb_page!(c::_Notebook, delta::Int)
    b = c.cells[c.active].buf
    before = b.row
    _tb_move_v!(b, delta)
    moved = b.row - before
    at_edge = b.row == 1 || b.row == _tb_nlines(b)
    if abs(moved) < abs(delta) && at_edge
        d = delta < 0 ? -1 : 1
        if (d < 0 && c.active > 1) || (d > 0 && c.active < length(c.cells))
            _nb_jump!(c, d)
        end
    end
    return :handled
end

# Insert a blank cell `after` the active one (0 = above, 1 = below).
function _nb_insert!(c::_Notebook, inst::_UiInstance, after::Int)
    cell = _nb_new_cell(inst, c.base.nspath)
    pos = c.active + after
    insert!(c.cells, pos, cell)
    c.queue = [q >= pos ? q + 1 : q for q in c.queue]
    c.active = pos
    c.mode = :nav
    c.base.status = "inserted a cell"
    _nb_store!(c, inst)
    return nothing
end

# ---- running a cell from the document ----------------------------------------

# Run the active cell in place (the notebook's Ctrl-J); true when a job started.
# A refused run (unclosed input) leaves its explanation as the status.
function _nb_run_active!(c::_Notebook, inst::_UiInstance)
    if _comp_running(c)
        c.base.status = "a cell is still running"
        return false
    end
    cell = c.cells[c.active]
    _cb_run!(cell, inst)
    c.base.status = cell.base.status
    _nb_store!(c, inst)
    return _comp_running(cell)
end

# Ctrl-Shift-J / Alt-Enter: run the active cell, then move to the cell below —
# inserting one when the active cell is the last. `mode` is `:nav` when the
# document was being edited and `:select` when a cell was selected.
function _nb_run_advance!(c::_Notebook, inst::_UiInstance, mode::Symbol)
    _nb_run_active!(c, inst) || return nothing
    i = c.active < length(c.cells) ? c.active + 1 : 0
    if i == 0
        push!(c.cells, _nb_new_cell(inst, c.base.nspath))
        i = length(c.cells)
    end
    c.active = i
    c.mode = mode
    _nb_place!(c.cells[i].buf, :first)
    _nb_store!(c, inst)
    return nothing
end

# ---- delete, restore, and interrupt ------------------------------------------

# Remove the active cell and keep it for `z`; deleting the only cell clears it
# instead, since a notebook always has a cell to type in.
function _nb_delete!(c::_Notebook, inst::_UiInstance)
    pos = c.active
    if length(c.cells) == 1
        cell = c.cells[1]
        if _comp_running(cell)
            c.base.status = "a cell is still running"
            return nothing
        end
        _tb_set_text!(cell.buf, "")
        cell.saved = ""
        empty!(cell.out)
        cell.out_for = ""
        cell.failed = false
        cell.elapsed = nothing
        cell.base.status = ""
        c.base.status = "cleared the last cell"
        _nb_store!(c, inst)
        return nothing
    end
    cell = c.cells[pos]
    deleteat!(c.cells, pos)
    c.queue = [q > pos ? q - 1 : q for q in c.queue if q != pos]
    c.last_deleted = (pos, cell)
    c.active = clamp(pos, 1, length(c.cells))
    c.base.status = "deleted a cell — z restores it"
    _nb_store!(c, inst)
    return nothing
end

# `z`: put the last deleted cell back where it was.
function _nb_restore_deleted!(c::_Notebook, inst::_UiInstance)
    c.last_deleted === nothing && (c.base.status = "nothing to restore")
    d = c.last_deleted
    d === nothing && return nothing
    c.last_deleted = nothing
    pos = clamp(d[1], 1, length(c.cells) + 1)
    insert!(c.cells, pos, d[2])
    c.queue = [q >= pos ? q + 1 : q for q in c.queue]
    c.active = pos
    c.base.status = "restored a cell"
    _nb_store!(c, inst)
    return nothing
end

# `i,i`: stop the running cell (its job's token makes Air's blocking primitives
# and the evaluation loop yield) and abandon any queued run-all.
function _nb_interrupt!(c::_Notebook, inst::_UiInstance)
    empty!(c.queue)
    n = 0
    for cell in c.cells
        _comp_cancel_job!(cell) && (n += 1)
    end
    c.base.status = n == 0 ? "nothing to interrupt" : "interrupting…"
    return nothing
end

# ---- keys --------------------------------------------------------------------

function _comp_key!(c::_Notebook, inst::_UiInstance, k::_UiKey)
    cell = c.cells[c.active]
    # A prompt inside the cell owns every key until it closes: otherwise the
    # notebook would run, insert a cell, or clear output as the user types a
    # search query.
    if cell.prompt !== nothing
        res = _comp_key!(cell, inst, k)
        return res === :bubble ? :bubble : :handled
    end
    c.mode === :select && return _nb_select_key!(c, inst, k)
    # Any key but a bare motion ends a transient message; clearing before the
    # key is handled lets the key itself leave a new one (a comment toggle).
    if !_nb_nav_key(k)
        c.base.status = ""
        cell.base.status = ""
    end
    if k.name === :esc
        if c.mode === :scroll
            c.mode = :nav
            return :handled
        end
        # Editing → selecting; selecting → the shell (Esc pops one layer at a
        # time, and the tab close is the layer below).
        c.mode = :select
        c.chord = '\0'
        c.base.status = ""
        return :handled
    elseif k.name === :tab
        return :bubble
    elseif k.name === :enter && k.alt
        _nb_run_advance!(c, inst, :nav)
        return :handled
    elseif k.name === :enter && c.mode === :nav &&
           _tb_nlines(cell.buf) > c.collapse
        c.mode = :scroll
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'j' && k.shift
        _nb_run_advance!(c, inst, :nav)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'j'
        _nb_run_active!(c, inst)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'r'
        _nb_run_all!(c, inst)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'o'
        _nb_clear!(c, inst, false)
        return :handled
    elseif k.name === :char && k.alt && k.char == 'o'
        _nb_clear!(c, inst, true)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'g'
        _nb_insert!(c, inst, 1)
        return :handled
    elseif k.name === :char && k.alt && k.char == 'g'
        _nb_insert!(c, inst, 0)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'v'
        _nb_jump!(c, 1)
        return :handled
    elseif k.name === :char && k.alt && k.char == 'v'
        _nb_jump!(c, -1)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && !k.shift && k.char == 'n' &&
           cell.buf.row == _tb_nlines(cell.buf) && c.active < length(c.cells)
        _nb_jump!(c, 1)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && !k.shift && k.char == 'p' &&
           cell.buf.row == 1 && c.active > 1
        _nb_jump!(c, -1)
        return :handled
    elseif k.name === :up && c.mode === :nav && cell.buf.row == 1 && c.active > 1
        _nb_jump!(c, -1)
        return :handled
    elseif k.name === :down && c.mode === :nav &&
           cell.buf.row == _tb_nlines(cell.buf) && c.active < length(c.cells)
        _nb_jump!(c, 1)
        return :handled
    elseif k.name === :pageup
        return _nb_page!(c, -10)
    elseif k.name === :pagedown
        return _nb_page!(c, 10)
    end
    res = _comp_key!(cell, inst, k)
    return res === :bubble ? :bubble : :handled
end

# Select mode is Jupyter's command mode: single-key commands, no typing. Every
# key is swallowed here (an unbound key does nothing rather than escaping into
# the buffer); only Esc bubbles, closing the tab one layer down.
function _nb_select_key!(c::_Notebook, inst::_UiInstance, k::_UiKey)
    chord = c.chord
    c.chord = '\0'
    if chord != '\0'
        if k.name === :char && !k.ctrl && !k.alt && k.char == chord
            chord == 'd' ? _nb_delete!(c, inst) : _nb_interrupt!(c, inst)
        end
        return :handled
    end
    plain = k.name === :char && !k.ctrl && !k.alt && k.char !== nothing
    if k.name === :esc
        c.base.status = ""
        return :bubble
    elseif k.name === :enter && k.alt
        _nb_run_advance!(c, inst, :select)
        return :handled
    elseif k.name === :enter
        c.mode = :nav
        c.base.status = ""
        return :handled
    elseif k.name === :up || (plain && k.char == 'k')
        _nb_jump!(c, -1)
        return :handled
    elseif k.name === :down || (plain && k.char == 'j')
        _nb_jump!(c, 1)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && !k.shift && k.char == 'p'
        _nb_jump!(c, -1)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && !k.shift && k.char == 'n'
        _nb_jump!(c, 1)
        return :handled
    elseif k.name === :home
        _nb_jump!(c, 1 - c.active)
        return :handled
    elseif k.name === :end
        _nb_jump!(c, length(c.cells) - c.active)
        return :handled
    elseif k.name === :pageup
        _nb_jump!(c, -10)
        return :handled
    elseif k.name === :pagedown
        _nb_jump!(c, 10)
        return :handled
    elseif plain && k.char == 'a'
        _nb_insert!(c, inst, 0)
        return :handled
    elseif plain && k.char == 'b'
        _nb_insert!(c, inst, 1)
        return :handled
    elseif plain && k.char == 'd'
        c.chord = 'd'
        c.base.status = ""
        return :handled
    elseif plain && k.char == 'i'
        c.chord = 'i'
        c.base.status = ""
        return :handled
    elseif plain && k.char == 'z'
        _nb_restore_deleted!(c, inst)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'j' && k.shift
        _nb_run_advance!(c, inst, :select)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'j'
        _nb_run_active!(c, inst)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'r'
        _nb_run_all!(c, inst)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'o'
        _nb_clear!(c, inst, false)
        return :handled
    elseif k.name === :char && k.alt && k.char == 'o'
        _nb_clear!(c, inst, true)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'g'
        _nb_insert!(c, inst, 1)
        return :handled
    elseif k.name === :char && k.alt && k.char == 'g'
        _nb_insert!(c, inst, 0)
        return :handled
    elseif k.name === :char && k.ctrl && !k.alt && k.char == 'v'
        _nb_jump!(c, 1)
        return :handled
    elseif k.name === :char && k.alt && k.char == 'v'
        _nb_jump!(c, -1)
        return :handled
    end
    return :handled
end

# Whether a key only moves (so it leaves the transient status message alone).
_nb_nav_key(k::_UiKey) = k.name in (:up, :down, :left, :right, :home, :end)
