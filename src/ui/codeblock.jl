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
    _CodePrompt

A transient input line inside a code buffer: `:search` (an incremental find) or
`:goto` (a line number). `origin` is the cursor when the prompt began, so
cancelling restores it; `pos` and `hits` describe the current match and the
total for the status line.
"""
mutable struct _CodePrompt
    kind::Symbol                          # :search | :goto
    text::String
    origin::Tuple{Int,Int}
    pos::Union{Nothing,Tuple{Int,Int}}
    hits::Int
end

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
    elapsed::Union{Nothing,Float64}     # seconds the last run took
    pair::Union{Nothing,Tuple{Int,Int}} # position of an auto-inserted pair
    width::Int                          # the width of the last draw
    prompt::Union{Nothing,_CodePrompt}  # the transient search/goto input line
    last_find::String                   # the query the last search used
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
                   false, nothing, nothing, 80, nothing, "")
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

# The highlighted text lines, with the form around the cursor tinted when this
# is the buffer the cursor is in. Both the standalone block and the notebook's
# active cell draw through this, so the tint means the same thing in both.
function _cb_render_lines(c::_CodeBlock, active::Bool)
    text = _tb_text(c.buf)
    hl = _hl_lines(text)
    active || return hl
    span = _ui_form_span(text, _tb_index(c.buf))
    span === nothing && return hl
    for (row, a, b) in _ui_form_segments(text, span)
        row <= length(hl) && (hl[row] = _hl_tint(hl[row], a, b))
    end
    return hl
end

function _comp_lines(c::_CodeBlock, inst::_UiInstance, width::Int)
    c.width = width
    hl = _cb_render_lines(c, true)
    out = _UiLine[]
    for i in 1:_tb_nlines(c.buf)
        spans = i <= length(hl) ? hl[i] : _UiSpan[]
        push!(out, _ui_styled(spans))
    end
    if !isempty(c.out) || (c.elapsed !== nothing && c.mode === :code)
        push!(out, _ui_ruler(max(width - 1, 8), c.elapsed))
        append!(out, c.out)
    end
    return out
end

_comp_cursor(c::_CodeBlock, inst::_UiInstance) =
    (c.buf.row, _tb_display_col(c.buf))

_comp_dirty(c::_CodeBlock, inst::_UiInstance) = _tb_text(c.buf) != c.saved

_comp_hints(c::_CodeBlock) =
    c.mode === :editor ?
        ["ctrl-j: save" => "^J save", "ctrl-s: find" => "^S find",
         "esc: done" => "esc"] :
        ["ctrl-j: run" => "^J run", "ctrl-s: find" => "^S find",
         "esc: done" => "esc"]

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
    # A closer typed on an otherwise blank line belongs at its opener's column.
    if ch == ')' && !hadsel &&
       all(c -> c == ' ' || c == '\t', b.lines[b.row][1:b.col])
        col = _ui_opener_col(_tb_text_before_cursor(b))
        (col === nothing || col == b.col) || _tb_set_indent!(b, b.row, col)
    end
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

# Reindent the lines below an edit when the edit changed the form they are in.
# `old` is the text as it was before the edit; a line that sat at its canonical
# indent moves with the structure, a line with extra spaces keeps them, and a
# deliberately reduced indent is left alone. Lines inside strings and block
# comments are content, not layout, so they are never touched.
function _cb_reindent_after!(c::_CodeBlock, old::AbstractString, edit_row::Int)
    b = c.buf
    newtext = _tb_text(b)
    oldind = _ui_indent_lines(old)
    newind = _ui_indent_lines(newtext)
    protected = _ui_protected_lines(newtext)
    shifted = _tb_nlines(b) - length(oldind)
    for r in (edit_row + 1):_tb_nlines(b)
        (1 <= r <= length(protected)) && protected[r] && continue
        old_r = r - shifted
        old_canon = 1 <= old_r <= length(oldind) ? oldind[old_r] : nothing
        cur = _tb_leading_spaces(b, r)
        firstnz = findfirst(ch -> ch != ' ' && ch != '\t', b.lines[r])
        closer = firstnz !== nothing && b.lines[r][firstnz] == ')'
        target = if closer || _tb_line_blank(b, r)
            newind[r]
        elseif old_canon === nothing
            cur
        elseif cur >= old_canon
            max(cur + (newind[r] - old_canon), 0)
        else
            cur
        end
        target != cur && _tb_set_indent!(b, r, target)
    end
    return nothing
end

# Run an editing operation and reindent the lines whose context it changed.
function _cb_edit!(c::_CodeBlock, f::Function)
    old = _tb_text(c.buf)
    f()
    _cb_reindent_after!(c, old, c.buf.row)
    return nothing
end

# ---- running ------------------------------------------------------------------

# Append one value's text to the output area.
function _cb_push_output!(c::_CodeBlock, text::AbstractString, role::Symbol)
    for line in split(text, '\n'; keepempty = true)
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
# an edit made meanwhile leaves the output visibly stale. `res` is the
# evaluation's `(status, payload, printed)`. `elapsed` is the job's measured
# duration; it says how long *this* run took, which is what the status row and
# the output ruler show.
#
# The output area shows what the run printed and then the last reduced form
# only; a final `naught` contributes nothing, and a run with no visible output
# still gets a ruler (its timing is information too).
function _cb_apply!(c::_CodeBlock, inst::_UiInstance, text::AbstractString,
                    res; elapsed::Float64 = 0.0)
    empty!(c.out)
    c.elapsed = elapsed > 0 ? elapsed : nothing
    status, payload, printed = res
    isempty(printed) || _cb_push_output!(c, chomp(printed), :text)
    if status === :error
        _cb_push_output!(c, "error: " * payload, :error)
        c.base.status = _ui_join_took("error", c.elapsed)
        c.out_for = text
        c.failed = true
        _cb_store!(c, inst)
        return nothing
    elseif status === :cancelled
        _cb_push_output!(c, "interrupted", :warning)
        c.base.status = _ui_join_took("interrupted", c.elapsed)
        c.out_for = text
        c.failed = false
        _cb_store!(c, inst)
        return nothing
    end
    c.failed = false
    values = payload
    width = max(c.width - 1, 8)
    if !isempty(values) && !isequal(values[end], naught)
        _cb_push_output!(c, air_pretty_string(inst.env, values[end];
                                             width = width), :text)
    end
    c.out_for = text
    c.saved = text
    msg = c.mode === :editor ? "saved" :
        (isempty(values) ? "ok" :
         string(length(values), " form", length(values) == 1 ? "" : "s"))
    c.base.status = _ui_join_took(msg, c.elapsed)
    _cb_store!(c, inst)
    return nothing
end

# A finished run: the job delivers `(text, (status, payload, printed))`, where
# `text` is the buffer as it was when the run started.
function _comp_job_done!(c::_CodeBlock, inst::_UiInstance, res,
                         elapsed::Float64 = 0.0)
    tag, value = res
    if tag === :cancelled
        empty!(c.out)
        c.elapsed = elapsed > 0 ? elapsed : nothing
        _cb_push_output!(c, "interrupted", :warning)
        c.base.status = _ui_join_took("interrupted", c.elapsed)
        c.out_for = _tb_text(c.buf)
        c.failed = false
        _cb_store!(c, inst)
        return nothing
    elseif tag !== :ok
        empty!(c.out)
        c.elapsed = elapsed > 0 ? elapsed : nothing
        _cb_push_output!(c, "error: " * value, :error)
        c.base.status = _ui_join_took("error", c.elapsed)
        c.failed = true
        _cb_store!(c, inst)
        return nothing
    end
    text, res = value
    _cb_apply!(c, inst, text, res; elapsed = elapsed)
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
    c.elapsed === nothing || push!(map, Symbol(":time") => Form(c.elapsed))
    _comp_set_state!(c, inst, _ns_form(Form[], map))
    return nothing
end

# Rebuild the output a stored widget drew, exactly as the notebook rebuilds a
# cell's; `saved` tracks the text that produced it.
function _cb_restore!(c::_CodeBlock, v::Union{Nothing,Form})
    v === nothing && return nothing
    output = _state_string(v, :output)
    out_for = _state_string(v, Symbol(":output-for"))
    c.elapsed = _state_number(v, :time)
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

# ---- search, go-to-line, bracket match, and comments -------------------------

# Recompute the search matches for the prompt's query and put the cursor on the
# first one at or after the place the search started (wrapping to the top).
function _cb_search_refresh!(c::_CodeBlock)
    p = c.prompt
    b = c.buf
    ms = _tb_matches(b, p.text)
    p.hits = length(ms)
    p.pos = nothing
    if isempty(ms)
        _tb_place!(b, p.origin[1], p.origin[2])
        return nothing
    end
    i = findfirst(m -> m >= p.origin, ms)
    i === nothing && (i = 1)
    p.pos = ms[i]
    _tb_place!(b, p.pos[1], p.pos[2], length(p.text))
    return nothing
end

# Move to the next (d > 0) or previous (d < 0) match, wrapping at the ends.
function _cb_search_step!(c::_CodeBlock, d::Int)
    p = c.prompt
    ms = _tb_matches(c.buf, p.text)
    isempty(ms) && return nothing
    i = p.pos === nothing ? 0 : something(findfirst(==(p.pos), ms), 0)
    i = i == 0 ? (d > 0 ? 1 : length(ms)) : mod1(i + d, length(ms))
    p.pos = ms[i]
    p.hits = length(ms)
    _tb_place!(c.buf, p.pos[1], p.pos[2], length(p.text))
    return nothing
end

# Ctrl-S: open an incremental search seeded with the last query. A second Ctrl-S
# after accepting therefore starts at the cursor, which is the end of the last
# match — that is, it finds the next one.
function _cb_open_search!(c::_CodeBlock)
    b = c.buf
    c.prompt = _CodePrompt(:search, c.last_find, (b.row, b.col), nothing, 0)
    c.base.status = ""
    _cb_search_refresh!(c)
    return nothing
end

# Alt-L: ask for a line number and put the cursor at its start.
function _cb_open_goto!(c::_CodeBlock)
    b = c.buf
    c.prompt = _CodePrompt(:goto, "", (b.row, b.col), nothing, 0)
    c.base.status = ""
    return nothing
end

function _cb_goto_apply!(c::_CodeBlock)
    p = c.prompt
    n = tryparse(Int, p.text)
    c.prompt = nothing
    if n === nothing
        c.base.status = "no line number"
        return nothing
    end
    _tb_place!(c.buf, n, 0)
    c.base.status = ""
    return nothing
end

# Alt-]: jump to the bracket matching the one at (or just before) the cursor,
# selecting it. Pressing it again comes back.
function _cb_match_bracket!(c::_CodeBlock)
    b = c.buf
    text = _tb_text(b)
    cs = collect(text)
    idx = _tb_index(b)
    if !(1 <= idx <= length(cs)) || !(cs[idx] == '(' || cs[idx] == ')')
        idx -= 1
    end
    res = 1 <= idx <= length(cs) ? _ui_bracket_match(text, idx) : nothing
    if res === nothing
        c.base.status = "no matching bracket"
        return nothing
    end
    (row, col) = _code_rowcol(cs, res[2])
    _tb_place!(b, row, col, 1)
    c.base.status = ""
    return nothing
end

# Alt-;: comment or uncomment the current line, or every line the selection
# touches (a selection that ends at column 0 does not include that line).
function _cb_toggle_comment!(c::_CodeBlock)
    b = c.buf
    sel = _tb_selection(b)
    rows = if sel === nothing
        b.row:b.row
    else
        (a, e) = sel
        last = (e[2] == 0 && e[1] > a[1]) ? e[1] - 1 : e[1]
        a[1]:last
    end
    (now, n) = _ui_toggle_comment!(b, rows)
    if n == 0
        c.base.status = "nothing to comment"
    else
        c.base.status = string(now ? "uncommented " : "commented ", n, " line",
                               n == 1 ? "" : "s")
    end
    return nothing
end

# The prompt line, shown in place of the status while one is open.
function _comp_prompt(c::_CodeBlock, inst::_UiInstance)
    p = c.prompt
    p === nothing && return nothing
    p.kind === :goto && return string("go to line: ", p.text)
    s = string("search: ", p.text)
    isempty(p.text) && return s
    p.hits == 0 && return s * "  ·  no match"
    i = p.pos === nothing ? 0 : something(findfirst(==(p.pos),
                                                    _tb_matches(c.buf, p.text)), 0)
    return string(s, "  ·  ", i, "/", p.hits)
end

function _comp_prompt_hints(c::_CodeBlock)
    p = c.prompt
    p === nothing && return _comp_hints(c)
    p.kind === :goto && return ["enter: go" => "go", "esc: cancel" => "esc"]
    return ["ctrl-s: next" => "next", "up: previous" => "prev",
            "enter: accept" => "enter", "esc: cancel" => "esc"]
end

# A key while a prompt is open goes to the prompt, never to the buffer.
function _cb_prompt_key!(c::_CodeBlock, k::_UiKey)
    p = c.prompt
    b = c.buf
    if k.name === :esc
        c.prompt = nothing
        _tb_place!(b, p.origin[1], p.origin[2])
        c.base.status = ""
        return :handled
    elseif k.name === :enter
        if p.kind === :goto
            _cb_goto_apply!(c)
        else
            c.prompt = nothing
            c.last_find = p.text
            c.base.status = p.hits == 0 && !isempty(p.text) ?
                            "no match: " * p.text : ""
        end
        return :handled
    elseif k.name === :backspace
        isempty(p.text) || (p.text = chop(p.text; tail = 1))
        p.kind === :search && _cb_search_refresh!(c)
        return :handled
    elseif k.name === :char && !k.ctrl && !k.alt && k.char !== nothing &&
           isprint(k.char)
        if p.kind === :goto
            isdigit(k.char) && (p.text *= string(k.char))
        else
            p.text *= string(k.char)
            _cb_search_refresh!(c)
        end
        return :handled
    elseif p.kind === :search && k.name === :char && k.ctrl && !k.alt &&
           k.char == 's'
        _cb_search_step!(c, 1)
        return :handled
    elseif p.kind === :search && k.name === :down
        _cb_search_step!(c, 1)
        return :handled
    elseif p.kind === :search && k.name === :up
        _cb_search_step!(c, -1)
        return :handled
    end
    return :handled
end

# ---- keys ---------------------------------------------------------------------

# The motions every text widget shares.
function _cb_motion_key!(c::_CodeBlock, k::_UiKey)
    b = c.buf
    sel = k.shift
    # The Emacs line motions, so the keys a notebook user knows work in a cell.
    if k.name === :char && k.ctrl && !k.alt
        if k.char == 'n' || k.char == 'N'
            _tb_move_v!(b, 1; select = sel)
            return true
        elseif k.char == 'p' || k.char == 'P'
            _tb_move_v!(b, -1; select = sel)
            return true
        end
    end
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
    c.prompt !== nothing && return _cb_prompt_key!(c, k)
    _cb_motion_key!(c, k) && return :handled
    if k.name === :paste
        _cb_edit!(c, () -> _cb_paste!(c, k.text))
        return :handled
    elseif k.name === :enter
        _cb_edit!(c, () -> _cb_newline!(c))
        return :handled
    elseif k.name === :backspace
        _cb_edit!(c, () -> _cb_backspace!(c))
        return :handled
    elseif k.name === :delete
        _cb_edit!(c, () -> _tb_delete!(b))
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
            elseif ch == 'd'
                _cb_edit!(c, () -> _tb_delete!(b))
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
            elseif ch == 's'
                _cb_open_search!(c)
            end
            return :handled
        elseif k.alt
            if ch == 'b'
                _tb_word_left!(b)
            elseif ch == 'f'
                _tb_word_right!(b)
            elseif ch == 'z'
                _tb_redo!(b)
            elseif ch == 'l'
                _cb_open_goto!(c)
            elseif ch == ']'
                _cb_match_bracket!(c)
            elseif ch == ';'
                _cb_toggle_comment!(c)
            else
                return :bubble
            end
            return :handled
        end
        isprint(ch) && _cb_edit!(c, () -> _cb_insert!(c, ch))
        return :handled
    end
    return :bubble
end

_comp_flush!(c::_CodeBlock, inst::_UiInstance) = _cb_store!(c, inst)
_comp_close!(c::_CodeBlock, inst::_UiInstance) = _cb_store!(c, inst)
