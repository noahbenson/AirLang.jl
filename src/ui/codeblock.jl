################################################################################
# ui/codeblock.jl
#
# The code-writing component: an editable air source buffer with automatic
# indentation, bracket and quote pairing, syntax highlighting, and a closure
# verdict from the reader. The same component is the definition editor (`ui
# editor`, which saves into a namespace) and the notebook's input cell.
#
# Three rules shape the keymap:
#
#   * Tab is never an indent key. Indentation comes from the layout of the form
#     being typed (ui/code.jl), so Tab stays free for the shell's tab switch.
#   * Esc pops exactly one layer: it leaves the editor and the shell decides
#     whether that discards anything.
#   * Ctrl-J runs the buffer. Enter only inserts a newline.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    _CodeBlock

An editable source buffer. `mode` is `:code` (run and show the result) or
`:editor` (apply the definitions to the namespace and record the text as saved).
"""
mutable struct _CodeBlock <: _Comp
    base::_CompBase
    buf::_TextBuffer
    saved::String                       # the text as last run/saved
    mode::Symbol                        # :code | :editor
    target::Union{Nothing,Symbol}       # the definition this editor edits
    out::Vector{_UiLine}                # output of the last run
    out_for::String                     # the text that produced `out`
    failed::Bool                        # the last run produced an error
    pair::Union{Nothing,Tuple{Int,Int}} # position of an auto-inserted pair
    width::Int                          # the width of the last draw
end

# ---- text helpers ------------------------------------------------------------

# The text before the cursor, which is what auto-indentation reads.
function _tb_text_before_cursor(b::_TextBuffer)
    parts = String[String(b.lines[r]) for r in 1:(b.row - 1)]
    push!(parts, String(b.lines[b.row][1:b.col]))
    return join(parts, "\n")
end

# The cursor's 1-based character index in `_tb_text(b)`.
function _tb_index(b::_TextBuffer)
    n = b.col
    for r in 1:(b.row - 1)
        n += length(b.lines[r]) + 1
    end
    return n + 1
end

# The display column of the cursor (0-based), for placing the terminal cursor.
_tb_display_col(b::_TextBuffer) =
    textwidth(String(b.lines[b.row][1:b.col]))

# ---- construction ------------------------------------------------------------

# The text a widget form seeds its buffer with: the state mutable's stored text
# when it has one, else the `text=` parameter. `v` is the canonicalized state
# value (`_comp_state_value`), or `nothing`.
function _comp_initial_text(node::_UiNode, v::Union{Nothing,Form})
    if v !== nothing
        t = _state_field(v, Symbol(":text"))
        if t !== nothing
            s = _ui_string(t)
            return s === nothing ? air_string(t) : s
        end
    end
    f = get(node.params, Symbol(":text"), nothing)
    f === nothing && return ""
    s = _ui_string(f)
    return s === nothing ? air_string(f) : s
end

function _comp_code_block(inst::_UiInstance, node::_UiNode)
    state = _comp_state_mut(node.params)
    v = _comp_state_value(inst, state)
    text = _comp_initial_text(node, v)
    base = _CompBase(node; state = state,
                     nspath = _comp_namespace(node.params, _comp_captured_ns(inst)))
    c = _CodeBlock(base, _TextBuffer(text), text, :code, nothing, _UiLine[], "",
                   false, nothing, 80)
    _cb_restore!(c, v)
    return c
end

function _comp_editor(inst::_UiInstance, node::_UiNode)
    c = _comp_code_block(inst, node)
    c.mode = :editor
    t = get(node.params, Symbol(":target"), nothing)
    if t !== nothing
        l = _leafof(t)
        if l isa Symbol
            s = String(l)
            c.target = Symbol(startswith(s, ":") ? s[2:end] : s)
        elseif l isa AbstractString
            c.target = Symbol(l)
        end
    end
    return c
end

# ---- rendering ----------------------------------------------------------------

_comp_title(c::_CodeBlock) = c.mode === :editor ? "editor" : "code"

function _comp_lines(c::_CodeBlock, inst::_UiInstance, width::Int)
    c.width = width
    text = _tb_text(c.buf)
    hl = _hl_lines(text)
    out = _UiLine[]
    for i in 1:_tb_nlines(c.buf)
        spans = i <= length(hl) ? hl[i] : _UiSpan[]
        push!(out, _ui_styled(spans))
    end
    if !isempty(c.out)
        ruler = repeat("─", max(width - 1, 8))
        push!(out, _ui_styled([_UiSpan(ruler, _ui_role(:border))]))
        append!(out, c.out)
    end
    return out
end

_comp_cursor(c::_CodeBlock, inst::_UiInstance) =
    (c.buf.row, _tb_display_col(c.buf))

_comp_dirty(c::_CodeBlock, inst::_UiInstance) = _tb_text(c.buf) != c.saved

_comp_hints(c::_CodeBlock) =
    c.mode === :editor ? ["ctrl-j: save" => "^J save", "esc: done" => "esc"] :
                         ["ctrl-j: run" => "^J run", "esc: done" => "esc"]

# The status fragment: the last message, else the buffer's shape and verdict.
function _comp_status(c::_CodeBlock, inst::_UiInstance)
    isempty(c.base.status) || return c.base.status
    v = _ui_closure(_tb_text(c.buf))
    verdict = v[1] === :ok ? "closed" :
              v[1] === :incomplete ? "unclosed " * v[2] : "error: " * v[2]
    return string(_tb_nlines(c.buf), " lines  ·  ", verdict)
end

# ---- editing ------------------------------------------------------------------

# Whether the cursor sits just after an auto-inserted opener with its closer
# immediately ahead.
function _cb_pair_at_cursor(c::_CodeBlock)
    c.pair === nothing && return false
    return c.pair == (c.buf.row, c.buf.col)
end

# Insert a typed character with pairing: an opener inserts its closer with the
# cursor between, and a closer sitting at the cursor steps over it.
function _cb_insert!(c::_CodeBlock, ch::Char)
    b = c.buf
    hadsel = _tb_has_selection(b)
    ctx = _ui_at_context(_tb_text(b), _tb_index(b))
    nextc = _tb_char_at(b, b.row, b.col)
    quoted = (ctx === :string || ctx === :comment)
    # Typing the closer that is already ahead steps over it: `)` anywhere, and a
    # `"` only when the scan says we are inside a string (that is its closer).
    if !hadsel && nextc == ch && (ch == ')' || (ch == '"' && ctx === :string))
        b.col += 1
        b.goal = -1
        c.pair = nothing
        return nothing
    end
    _tb_insert!(b, ch)
    c.pair = nothing
    closer = _ui_pair_closer(ch)
    if closer !== nothing && !hadsel && !quoted
        _tb_insert_raw!(b, string(closer))
        b.col -= 1
        c.pair = (b.row, b.col)
    end
    return nothing
end

# Backspace: an empty auto-inserted pair deletes together; otherwise the plain
# buffer delete.
function _cb_backspace!(c::_CodeBlock)
    b = c.buf
    if _cb_pair_at_cursor(c)
        before = _tb_char_before(b)
        after = _tb_char_at(b, b.row, b.col)
        if before !== nothing && after !== nothing &&
           _ui_pair_closer(before) == after
            _tb_snapshot!(b)
            deleteat!(b.lines[b.row], b.col + 1)
            deleteat!(b.lines[b.row], b.col)
            b.col -= 1
            b.goal = -1
            c.pair = nothing
            return nothing
        end
    end
    if _tb_backspace!(b)
        c.pair = nothing
    end
    return nothing
end

# Insert a newline with automatic indentation. Between an empty pair the closer
# moves to the line below at the opener's column.
function _cb_newline!(c::_CodeBlock)
    b = c.buf
    before = _tb_char_before(b)
    after = _tb_char_at(b, b.row, b.col)
    text_before = _tb_text_before_cursor(b)
    indent = _ui_indent_at(text_before)
    if before !== nothing && after !== nothing && _ui_pair_closer(before) == after
        _tb_snapshot!(b)
        _tb_delete_selection!(b)
        _tb_newline_raw!(b, indent)
        opencol = _ui_opener_col(text_before)
        opencol === nothing && (opencol = 0)
        _tb_insert_raw!(b, "\n" * repeat(" ", opencol))
        c.pair = nothing
        return nothing
    end
    _tb_newline!(b, indent)
    c.pair = nothing
    return nothing
end

# Insert pasted text verbatim.
function _cb_paste!(c::_CodeBlock, s::AbstractString)
    _tb_insert!(c.buf, s)
    c.pair = nothing
    return nothing
end

# Recompute the current line's indentation from the form being typed.
function _cb_reindent!(c::_CodeBlock)
    _tb_reindent!(c.buf, _ui_indent_at(_tb_text_before_cursor(c.buf)))
    return nothing
end

# ---- running ------------------------------------------------------------------

# Append one value's text to the output area.
function _cb_push_output!(c::_CodeBlock, text::AbstractString, role::Symbol)
    for line in split(text, '\n')
        push!(c.out, _ui_styled([_UiSpan(String(line), _ui_role(role))]))
    end
    return nothing
end

# Ctrl-J: evaluate the buffer. In an editor, saving *is* evaluating a definition
# form in the namespace, so both modes take the same path; the editor just
# records the buffer as saved.
function _cb_run!(c::_CodeBlock, inst::_UiInstance;
                  label::AbstractString = "running…")
    text = _tb_text(c.buf)
    verdict = _ui_closure(text)
    if verdict[1] !== :ok
        c.base.status = verdict[1] === :incomplete ?
            "unclosed input: " * verdict[2] : "parse error: " * verdict[2]
        empty!(c.out)
        _cb_push_output!(c, _ui_closure_message(text), :error)
        c.out_for = text
        c.failed = true
        return nothing
    end
    if c.mode === :editor && isempty(strip(text))
        c.base.status = "nothing to save"
        return nothing
    end
    # The evaluation runs in the background so the widget stays live while it
    # works; `_cb_apply!` lands the result on the instance's ticker.
    if !_comp_start_job!(c, inst, () -> (text, _comp_eval(c, inst, text));
                         label = label)
        c.base.status = "still running"
        return nothing
    end
    c.base.status = ""
    return nothing
end

# Apply a finished run. `text` is the buffer as it was when the run started, so
# an edit made meanwhile leaves the output visibly stale.
function _cb_apply!(c::_CodeBlock, inst::_UiInstance, text::AbstractString,
                    status::Symbol, result)
    empty!(c.out)
    if status === :error
        _cb_push_output!(c, "error: " * result, :error)
        c.base.status = "error"
        c.out_for = text
        c.failed = true
        _cb_store!(c, inst)
        return nothing
    end
    c.failed = false
    width = max(c.width - 1, 8)
    for v in result
        _cb_push_output!(c, air_pretty_string(inst.env, v; width = width), :text)
    end
    c.out_for = text
    c.saved = text
    c.base.status = c.mode === :editor ? "saved" :
        string(length(result), " result", length(result) == 1 ? "" : "s")
    _cb_store!(c, inst)
    return nothing
end

# A finished run: the job delivers `(text, (status, values))`, where `text` is
# the buffer as it was when the run started.
function _comp_job_done!(c::_CodeBlock, inst::_UiInstance, res)
    tag, value = res
    if tag !== :ok
        empty!(c.out)
        _cb_push_output!(c, "error: " * value, :error)
        c.base.status = "error"
        c.failed = true
        _cb_store!(c, inst)
        return nothing
    end
    text, (status, result) = value
    _cb_apply!(c, inst, text, status, result)
    return nothing
end

# Persist the buffer, the output, and the text that produced it in the state mut,
# so a standalone widget reopens with its result still under the buffer.
function _cb_store!(c::_CodeBlock, inst::_UiInstance)
    c.base.state === nothing && return nothing
    map = Pair{Symbol,Form}[Symbol(":text") => Form(_tb_text(c.buf))]
    c.target === nothing || push!(map, Symbol(":target") => Form(c.target))
    isempty(c.out_for) || push!(map, Symbol(":output-for") => Form(c.out_for))
    isempty(c.out) ||
        push!(map, Symbol(":output") => Form(join((l.text for l in c.out), "\n")))
    c.failed && push!(map, Symbol(":error") => Form(true))
    _comp_set_state!(c, inst, _ns_form(Form[], map))
    return nothing
end

# Rebuild the output a stored widget drew, exactly as the notebook rebuilds a
# cell's; `saved` tracks the text that produced it.
function _cb_restore!(c::_CodeBlock, v::Union{Nothing,Form})
    v === nothing && return nothing
    output = _state_string(v, :output)
    out_for = _state_string(v, Symbol(":output-for"))
    isempty(output) && isempty(out_for) && return nothing
    failed = _state_flag(v, :error)
    if !isempty(output)
        role = failed ? :error : :text
        c.out = [_ui_styled([_UiSpan(String(l), _ui_role(role))])
                 for l in split(output, '\n')]
    end
    c.out_for = out_for
    c.failed = failed
    isempty(out_for) || (c.saved = out_for)
    return nothing
end

# ---- keys ---------------------------------------------------------------------

# The motions every text widget shares.
function _cb_motion_key!(c::_CodeBlock, k::_UiKey)
    b = c.buf
    sel = k.shift
    if k.name === :left
        _tb_move_h!(b, -1; select = sel)
    elseif k.name === :right
        _tb_move_h!(b, 1; select = sel)
    elseif k.name === :up
        _tb_move_v!(b, -1; select = sel)
    elseif k.name === :down
        _tb_move_v!(b, 1; select = sel)
    elseif k.name === :home
        _tb_home!(b; select = sel)
    elseif k.name === :end
        _tb_end!(b; select = sel)
    elseif k.name === :pageup
        _tb_move_v!(b, -10; select = sel)
    elseif k.name === :pagedown
        _tb_move_v!(b, 10; select = sel)
    else
        return false
    end
    return true
end

function _comp_key!(c::_CodeBlock, inst::_UiInstance, k::_UiKey)
    b = c.buf
    _cb_motion_key!(c, k) && return :handled
    if k.name === :paste
        _cb_paste!(c, k.text)
        return :handled
    elseif k.name === :enter
        _cb_newline!(c)
        return :handled
    elseif k.name === :backspace
        _cb_backspace!(c)
        return :handled
    elseif k.name === :delete
        _tb_delete!(b)
        return :handled
    elseif k.name === :tab
        return :bubble                       # the shell's tab switch
    elseif k.name === :esc
        return :bubble
    elseif k.name === :char
        ch = k.char
        ch === nothing && return :handled
        if k.ctrl
            if ch == 'j'
                _cb_run!(c, inst)
            elseif ch == 'a'
                _tb_home!(b)
            elseif ch == 'e'
                _tb_end!(b)
            elseif ch == 'b'
                _tb_move_h!(b, -1)
            elseif ch == 'f'
                _tb_move_h!(b, 1)
            elseif ch == 'k'
                _tb_kill_line!(b)
            elseif ch == 'u'
                _tb_kill_start!(b)
            elseif ch == 'w'
                _tb_kill_word!(b)
            elseif ch == 'y'
                _tb_yank!(b)
            elseif ch == 'z'
                _tb_undo!(b)
            elseif ch == 'l'
                _cb_reindent!(c)
            end
            return :handled
        elseif k.alt
            if ch == 'b'
                _tb_word_left!(b)
            elseif ch == 'f'
                _tb_word_right!(b)
            elseif ch == 'z'
                _tb_redo!(b)
            else
                return :bubble
            end
            return :handled
        end
        isprint(ch) && _cb_insert!(c, ch)
        return :handled
    end
    return :bubble
end

_comp_flush!(c::_CodeBlock, inst::_UiInstance) = _cb_store!(c, inst)
_comp_close!(c::_CodeBlock, inst::_UiInstance) = _cb_store!(c, inst)
