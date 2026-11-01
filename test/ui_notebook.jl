# The notebook: cells, running in place, the continuous document, collapse and
# the scrolling view, insertion, and stale-output dimming.
@testset "ui notebook" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evd(s) = air_eval(env, read_air(s))
    B = AirLang

    state_of(form) = form.map[Symbol(":state")]
    state_value(form) = B.canonicalize(state_of(form)[])

    open_form!(key, w) = ui_open_form!(env, key, w)
    term_run(key, bytes; kw...) = ui_term_run(env, key, bytes; kw...)
    wait_for(f; kw...) = ui_wait_for(f; kw...)
    bytes(s) = ui_bytes(s)
    CTRL_G = UInt8(0x07)
    CTRL_J = UI_CTRL_J
    CTRL_R = UInt8(0x12)
    CTRL_V = UInt8(0x16)
    ENTER = UI_ENTER
    ESC = UI_ESC

    cells_of(form) = begin
        v = state_value(form)
        c = B._state_field(v, :cells)
        [B._state_string(to_form(el), :input) for el in c.seq]
    end
    outputs_of(form) = begin
        v = state_value(form)
        c = B._state_field(v, :cells)
        [B._state_string(to_form(el), :output) for el in c.seq]
    end

    # The component behind a widget form, for inspecting what the renderer sees.
    function notebook_of(form)
        open_form!(:nbx, form)
        inst = B._ui_lookup(env, Form(Symbol(":nbx")))
        return B._comp_notebook(inst, inst.root), inst
    end

    @testset "the widget form" begin
        w = evd("(ui-notebook text=\"(+ 1 2)\")")
        @test startswith(air_string(w), "(ui notebook")
        @test haskey(w.map, Symbol(":state"))
        @test cells_of(w) == ["(+ 1 2)"]
        @test outputs_of(w) == [""]
        @test ev("(ui-notebook collapse-lines=8)") isa String
    end

    @testset "a prompt in a cell owns the notebook keys" begin
        w = evd("(ui-notebook text=\"(def (f x))\n(def (g y))\")")
        (c, inst) = notebook_of(w)
        n = length(c.cells)
        B._comp_key!(c, inst, B._ui_key(:char; char = 's', ctrl = true))
        B._comp_key!(c, inst, B._ui_key(:char; char = 'd'))
        @test occursin("search: d", B._comp_prompt(c, inst))
        # The notebook's own keys do not fire while the prompt is open.
        B._comp_key!(c, inst, B._ui_key(:char; char = 'g', ctrl = true))
        @test length(c.cells) == n
        B._comp_key!(c, inst, B._ui_key(:char; char = 'r', ctrl = true))
        @test !B._comp_running(c)
        # Esc closes the prompt, not the document.
        @test B._comp_key!(c, inst, B._ui_key(:esc)) === :handled
        @test c.cells[1].prompt === nothing
        ev("(ui-close! :nbx)")
    end

    @testset "running a cell" begin
        w = evd("(ui-notebook text=\"(+ 1 2)\")")
        open_form!(:nb1, w)
        (res, _) = term_run(:nb1, [CTRL_J, ESC, ESC])
        @test res[1] === :ok
        @test outputs_of(w) == ["3"]
        @test occursin("3", ev("(ui-render :nb1)"))
        ev("(ui-close! :nb1)")
    end

    @testset "(current-ui) inside a widget evaluation" begin
        # Outside any UI evaluation there is no current UI.
        @test air_string(evd("(current-ui)")) == "naught"
        # Inside one, the evaluation sees the very form its instance was built
        # from, so a user can store it and keep the widget.
        w = evd("(ui-notebook text=\"(current-ui)\")")
        open_form!(:nb0, w)
        (res, _) = term_run(:nb0, [CTRL_J, ESC, ESC])
        @test res[1] === :ok
        out = outputs_of(w)[1]
        @test startswith(out, "(ui notebook ")
        @test occursin("state=(mut ", out)
        ev("(ui-close! :nb0)")
    end

    @testset "inserting cells" begin
        w = evd("(ui-notebook text=\"a\")")
        open_form!(:nb2, w)
        term_run(:nb2, vcat([CTRL_G], bytes("b"), [ESC, ESC]))
        @test cells_of(w) == ["a", "b"]
        ev("(ui-close! :nb2)")
        w = evd("(ui-notebook text=\"a\")")
        open_form!(:nb3, w)
        term_run(:nb3, vcat([ESC], bytes("g"), [ESC, ESC]))   # Alt-G inserts above
        @test length(cells_of(w)) == 2
        @test cells_of(w)[1] == ""
        ev("(ui-close! :nb3)")
    end

    @testset "the document is continuous" begin
        w = evd("(ui-notebook text=\"a\")")
        open_form!(:nb4, w)
        # One cell, one line: Down would leave the notebook, so it stays.
        term_run(:nb4, vcat([CTRL_G], bytes("b"), [ESC, ESC]))
        cells = cells_of(w)
        @test cells == ["a", "b"]
        ev("(ui-close! :nb4)")
        # Navigation: Down at the last line of the first cell lands in the
        # second one, and typing goes there.
        w = evd("(ui-notebook text=\"a\")")
        open_form!(:nb5, w)
        term_run(:nb5, vcat([CTRL_G], bytes("b"), [ESC, ESC]))
        open_form!(:nb6, w)
        # The second cell is active after the insert; go up to the first, down
        # again, and append to the second cell.
        (res, _) = term_run(:nb6, vcat([0x1b], bytes("["), bytes("A"),        # Up
                                       [0x1b], bytes("["), bytes("B"),        # Down
                                       bytes("c"), [ESC, ESC]))
        @test res[1] === :ok
        # Moving into a cell keeps the column, so typing lands at the start.
        @test cells_of(w) == ["a", "cb"]
        ev("(ui-close! :nb5)")
        ev("(ui-close! :nb6)")
    end

    @testset "cell jumping" begin
        w = evd("(ui-notebook text=\"a\")")
        open_form!(:nb7, w)
        term_run(:nb7, vcat([CTRL_G, CTRL_G], bytes("z"), [ESC, ESC]))
        @test cells_of(w) == ["a", "", "z"]
        ev("(ui-close! :nb7)")
        # Ctrl-V / Alt-V jump one cell and typing lands in the new one.
        w = evd("(ui-notebook text=\"a\")")
        open_form!(:nb8, w)
        term_run(:nb8, vcat([CTRL_G, CTRL_G, CTRL_V], bytes("down"), [ESC, ESC]))
        @test cells_of(w) == ["a", "", "down"]
        ev("(ui-close! :nb8)")
        w = evd("(ui-notebook text=\"a\")")
        open_form!(:nb9, w)
        term_run(:nb9, vcat([CTRL_G, CTRL_G, 0x1b], bytes("v"), bytes("up"), [ESC, ESC]))
        @test cells_of(w) == ["a", "up", ""]
        ev("(ui-close! :nb9)")
    end

    @testset "collapse and the scrolling view" begin
        longtext = join(["line" * string(i) for i in 1:25], "\\n")
        w = evd("(ui-notebook text=\"" * longtext * "\")")
        open_form!(:nb10, w)
        text = ev("(ui-render :nb10)")
        @test occursin("more lines", text)
        @test !occursin("line25", text)
        # Enter opens the cell in full (the scrolling, editable view); Esc goes
        # back to the document.
        (c, inst) = notebook_of(w)
        @test c.mode === :nav
        B._comp_key!(c, inst, B._ui_key(:enter))
        @test c.mode === :scroll
        full = B._comp_lines(c, inst, 40)
        @test any(l -> endswith(l.text, "line25"), full)
        B._comp_key!(c, inst, B._ui_key(:esc))
        @test c.mode === :nav
        # And the terminal renderer dismisses from the document view.
        (res, out) = term_run(:nb10, [ENTER, ESC, ESC, ESC]; rows = 30)
        @test res[1] === :ok
        ev("(ui-close! :nb10)")
        ev("(ui-close! :nbx)")
    end

    @testset "stale output is dimmed" begin
        w = evd("(ui-notebook text=\"(+ 1 2)\")")
        open_form!(:nb11, w)
        term_run(:nb11, [CTRL_J, ESC, ESC])
        (c, inst) = notebook_of(w)
        @test length(c.cells) == 1
        @test c.cells[1].out_for == "(+ 1 2)"
        @test !B._comp_dirty(c, inst)
        # Editing the input makes the stored output stale: the output lines
        # render in the muted role rather than the text role.
        c.cells[1].buf = B._TextBuffer("(+ 1 3)")
        doc = B._comp_lines(c, inst, 40)
        outlines = [l for l in doc if endswith(l.text, "3")]
        @test !isempty(outlines)
        @test all(s -> s.style === B._ui_role(:muted),
                  filter(s -> s.text == "3", B._ui_line_spans(outlines[1])))
        @test B._comp_dirty(c, inst)
        ev("(ui-close! :nbx)")
    end

    @testset "run-all evaluates the document in order" begin
        w = evd("(ui-notebook text=\"(+ 1 2)\")")
        open_form!(:nb13, w)
        inst = B._ui_lookup(env, Form(Symbol(":nb13")))
        c = B._comp_notebook(inst, inst.root)
        B._nb_insert!(c, inst, 1)
        B._tb_set_text!(c.cells[2].buf, "(* 6 7)")
        B._comp_key!(c, inst, B._ui_key(:char; char = 'r', ctrl = true))
        # The first cell starts at once; the rest wait behind it.
        @test B._comp_job_label(c) == "running cell 1…"
        @test c.active == 1
        wait_for(() -> (B._comp_tick!(c, inst); !B._comp_running(c)))
        @test outputs_of(w) == ["3", "42"]
        @test c.active == 2                     # focus follows execution
        # Ctrl-O clears the active cell's output; Alt-O clears every output.
        c.active = 1
        B._comp_key!(c, inst, B._ui_key(:char; char = 'o', ctrl = true))
        @test outputs_of(w) == ["", "42"]
        B._comp_key!(c, inst, B._ui_key(:char; char = 'o', alt = true))
        @test outputs_of(w) == ["", ""]
        # Ctrl-J and Ctrl-R are refused while any cell is in flight.
        cell = c.cells[1]
        @test B._comp_start_job!(cell, inst,
                                 () -> ("(+ 1 2)", (:ok, Form[Form(3)], "")))
        B._comp_key!(c, inst, B._ui_key(:char; char = 'j', ctrl = true))
        @test c.base.status == "a cell is still running"
        B._comp_key!(c, inst, B._ui_key(:char; char = 'r', ctrl = true))
        @test c.base.status == "a cell is still running"
        wait_for(() -> (B._comp_tick!(c, inst); !B._comp_running(c)))
        B._comp_close!(c, inst)
        ev("(ui-close! :nb13)")
    end

    @testset "each cell records how long it took" begin
        w = evd("(ui-notebook text=\"(+ 1 2)\")")
        open_form!(:nb20, w)
        (res, _) = term_run(:nb20, [CTRL_J, ESC, ESC])
        @test res[1] === :ok
        (c, inst) = notebook_of(w)
        @test c.cells[1].elapsed !== nothing
        # The cell's own form keeps the duration with its output, and the
        # notebook's state carries that form, so a rebuilt document still knows.
        v = state_value(w)
        el = to_form(B._state_field(v, :cells).seq[1])
        @test B._state_number(el, :time) !== nothing
        open_form!(:nb21, w)
        inst2 = B._ui_lookup(env, Form(Symbol(":nb21")))
        c2 = B._comp_notebook(inst2, inst2.root)
        @test c2.cells[1].elapsed !== nothing
        doc = B._comp_lines(c2, inst2, 40)
        @test any(l -> any(s -> occursin(r"µs|ms|\d s", s.text),
                           B._ui_line_spans(l)), doc)
        # Clearing the output clears the timing with it.
        B._comp_key!(c, inst, B._ui_key(:char; char = 'o', ctrl = true))
        @test c.cells[1].elapsed === nothing
        ev("(ui-close! :nb20)")
        ev("(ui-close! :nb21)")
        ev("(ui-close! :nbx)")
    end

    @testset "a run-all stops at a cell that refuses to run" begin
        w = evd("(ui-notebook text=\"(+ 1\")")
        open_form!(:nb14, w)
        inst = B._ui_lookup(env, Form(Symbol(":nb14")))
        c = B._comp_notebook(inst, inst.root)
        B._nb_insert!(c, inst, 1)
        B._tb_set_text!(c.cells[2].buf, "(+ 2 2)")
        B._comp_key!(c, inst, B._ui_key(:char; char = 'r', ctrl = true))
        @test !B._comp_running(c)
        @test isempty(c.queue)
        @test occursin("unclosed", c.base.status)
        @test outputs_of(w)[2] == ""
        B._comp_close!(c, inst)
        ev("(ui-close! :nb14)")
    end

    @testset "a run-all continues after the ui detaches" begin
        w = evd("(ui-notebook text=\"(+ 1 2)\")")
        open_form!(:nb15, w)
        inst = B._ui_lookup(env, Form(Symbol(":nb15")))
        c = B._ui_tree(inst)
        B._nb_insert!(c, inst, 1)
        B._tb_set_text!(c.cells[2].buf, "(* 6 7)")
        # Ctrl-R queues both cells and Esc leaves at once; the queue belongs to
        # the notebook, so the ticker runs the rest with no renderer attached.
        (res, _) = term_run(:nb15, [CTRL_R, ESC, ESC]; settle = false)
        @test res[1] === :ok
        @test wait_for(() -> lock(() -> !B._comp_running(c), inst.lock))
        @test outputs_of(w) == ["3", "42"]
        @test c.active == 2
        ev("(ui-close! :nb15)")
    end

    @testset "an unclosed cell refuses to run" begin
        w = evd("(ui-notebook text=\"(+ 1\")")
        open_form!(:nb12, w)
        (res, out) = term_run(:nb12, [CTRL_J, ESC, ESC])
        @test res[1] === :ok
        @test occursin("unclosed", out)
        @test outputs_of(w) == ["unclosed: unterminated form"]
        ev("(ui-close! :nb12)")
    end

    @testset "Ctrl-N and Ctrl-P move and cross cells" begin
        w = evd("(ui-notebook text=\"ab\ncd\")")
        (c, inst) = notebook_of(w)
        B._nb_insert!(c, inst, 1)
        B._tb_set_text!(c.cells[2].buf, "xy")
        c.active = 1
        B._tb_place!(c.cells[1].buf, 1, 0)
        # Inside a cell they are ordinary line motions.
        B._comp_key!(c, inst, B._ui_key(:char; char = 'n', ctrl = true))
        @test c.active == 1 && c.cells[1].buf.row == 2
        # At the last line they cross into the next cell, and back at the first.
        B._comp_key!(c, inst, B._ui_key(:char; char = 'n', ctrl = true))
        @test c.active == 2 && c.cells[2].buf.row == 1
        B._comp_key!(c, inst, B._ui_key(:char; char = 'p', ctrl = true))
        @test c.active == 1 && c.cells[1].buf.row == 2
        # Ctrl-D deletes forward.
        B._tb_place!(c.cells[1].buf, 1, 0)
        B._comp_key!(c, inst, B._ui_key(:char; char = 'd', ctrl = true))
        @test B._tb_text(c.cells[1].buf) == "b\ncd"
        B._comp_close!(c, inst)
        ev("(ui-close! :nbx)")
    end

    @testset "the current cell's containing form is tinted" begin
        w = evd("(ui-notebook text=\"(do\n  (+ 1 2)\n)\")")
        (c, inst) = notebook_of(w)
        cell = c.cells[1]
        cell.buf.row = 2
        cell.buf.col = 4                     # inside `(+ 1 2)`
        doc = B._comp_lines(c, inst, 40)
        bg = B._ui_role(:form_bg).bg
        @test any(s -> s.style.bg === bg, B._ui_line_spans(doc[2]))
        # Only the inner form is tinted; the outer form's other lines are not.
        @test all(s -> s.style.bg !== bg, B._ui_line_spans(doc[1]))
        @test all(s -> s.style.bg !== bg, B._ui_line_spans(doc[3]))
        # Only the active cell draws a tint: with a second, empty cell active,
        # the first cell's text is drawn plain.
        B._nb_insert!(c, inst, 1)
        @test c.active == 2
        doc = B._comp_lines(c, inst, 40)
        @test !any(l -> any(s -> s.style.bg === bg, B._ui_line_spans(l)), doc)
        B._comp_close!(c, inst)
        ev("(ui-close! :nbx)")
    end

    @testset "stdout is captured into the output cell" begin
        w = evd("(ui-notebook text=\"(do (println \\\"hi\\\") (+ 1 2))\")")
        open_form!(:nb30, w)
        (res, _) = term_run(:nb30, [CTRL_J, ESC, ESC])
        @test res[1] === :ok
        @test outputs_of(w) == ["hi\n3"]
        ev("(ui-close! :nb30)")

        # A final `naught` prints nothing, but the run's own output stays.
        w = evd("(ui-notebook text=\"(do (println \\\"hi\\\") naught)\")")
        open_form!(:nb31, w)
        term_run(:nb31, [CTRL_J, ESC, ESC])
        @test outputs_of(w) == ["hi"]
        ev("(ui-close! :nb31)")

        # A run that reduces to `naught` alone is an empty output with a ruler
        # and a time, not the word `naught`.
        w = evd("(ui-notebook text=\"naught\")")
        open_form!(:nb32, w)
        term_run(:nb32, [CTRL_J, ESC, ESC])
        @test outputs_of(w) == [""]
        (c, inst) = notebook_of(w)
        @test c.cells[1].elapsed !== nothing
        doc = B._comp_lines(c, inst, 40)
        @test any(l -> any(s -> occursin(r"µs|ms|\d s", s.text),
                           B._ui_line_spans(l)), doc)
        B._comp_close!(c, inst)
        ev("(ui-close! :nbx)")
        ev("(ui-close! :nb32)")

        # Only the last form's value is shown, though every form reduces.
        w = evd("(ui-notebook text=\"(+ 1 2)\n(* 3 4)\")")
        open_form!(:nb33, w)
        term_run(:nb33, [CTRL_J, ESC, ESC])
        @test outputs_of(w) == ["12"]
        ev("(ui-close! :nb33)")
    end

    @testset "indentation follows the form as it changes" begin
        w = evd("(ui-notebook text=\"(do\n  (f 1)\n)\")")
        (c, inst) = notebook_of(w)
        cell = c.cells[1]
        cell.buf.row = 1
        cell.buf.col = 3                     # end of `(do`
        # Opening a form on line 1 moves line 2 to the new canonical indent.
        B._comp_key!(c, inst, B._ui_key(:paste; text = " (g"))
        lines = [String(l) for l in cell.buf.lines]
        @test lines[1] == "(do (g"
        @test lines[2] == "     (f 1)"
        B._comp_close!(c, inst)
        ev("(ui-close! :nbx)")
    end

    @testset "a closer typed on a blank line dedents" begin
        w = evd("(ui-notebook text=\"(do\n    \n)\")")
        (c, inst) = notebook_of(w)
        c.cells[1].buf.row = 2
        c.cells[1].buf.col = 4
        B._comp_key!(c, inst, B._ui_key(:char; char = ')'))
        @test [String(l) for l in c.cells[1].buf.lines] == ["(do", ")", ")"]
        B._comp_close!(c, inst)
        ev("(ui-close! :nbx)")
    end

    @testset "run and advance" begin
        w = evd("(ui-notebook text=\"(+ 1 2)\")")
        (c, inst) = notebook_of(w)
        # Ctrl-Shift-J runs the cell and puts the cursor in a fresh cell below.
        B._comp_key!(c, inst,
                     B._ui_key(:char; char = 'j', ctrl = true, shift = true))
        @test length(c.cells) == 2
        @test c.active == 2
        @test c.mode === :nav
        @test wait_for(() -> (B._comp_tick!(c, inst); !B._comp_running(c)))
        @test outputs_of(w)[1] == "3"
        # Alt-Enter is the portable spelling; from select mode it stays selecting.
        B._comp_key!(c, inst, B._ui_key(:esc))
        @test c.mode === :select
        B._comp_key!(c, inst, B._ui_key(:enter; alt = true))
        @test length(c.cells) == 3
        @test c.mode === :select
        wait_for(() -> (B._comp_tick!(c, inst); !B._comp_running(c)))
        B._comp_close!(c, inst)
        ev("(ui-close! :nbx)")
    end

    @testset "select mode is Jupyter's command mode" begin
        w = evd("(ui-notebook text=\"a\")")
        (c, inst) = notebook_of(w)
        B._nb_insert!(c, inst, 1)
        @test length(c.cells) == 2
        B._comp_key!(c, inst, B._ui_key(:esc))
        @test c.mode === :select
        @test B._comp_cursor(c, inst) === nothing
        @test occursin("select", B._comp_status(c, inst))
        # j/k and Ctrl-N/Ctrl-P move between cells; Home and End jump.
        c.active = 1
        B._comp_key!(c, inst, B._ui_key(:char; char = 'j'))
        @test c.active == 2
        B._comp_key!(c, inst, B._ui_key(:char; char = 'k'))
        @test c.active == 1
        B._comp_key!(c, inst, B._ui_key(:char; char = 'n', ctrl = true))
        @test c.active == 2
        B._comp_key!(c, inst, B._ui_key(:char; char = 'p', ctrl = true))
        @test c.active == 1
        B._comp_key!(c, inst, B._ui_key(:end))
        @test c.active == 2
        B._comp_key!(c, inst, B._ui_key(:home))
        @test c.active == 1
        # d,d deletes a cell and z puts it back.
        B._comp_key!(c, inst, B._ui_key(:char; char = 'd'))
        @test c.chord == 'd'
        @test occursin("d: delete", B._comp_status(c, inst))
        B._comp_key!(c, inst, B._ui_key(:char; char = 'd'))
        @test length(c.cells) == 1
        @test c.chord == '\0'
        B._comp_key!(c, inst, B._ui_key(:char; char = 'z'))
        @test length(c.cells) == 2
        # An unbound key is swallowed: it neither types nor changes anything.
        B._comp_key!(c, inst, B._ui_key(:char; char = 'q'))
        @test cells_of(w) == ["a", ""]
        # Enter returns to editing; Esc bubbles out (the shell's layer).
        B._comp_key!(c, inst, B._ui_key(:enter))
        @test c.mode === :nav
        B._comp_key!(c, inst, B._ui_key(:esc))
        @test c.mode === :select
        @test B._comp_key!(c, inst, B._ui_key(:esc)) === :bubble
        B._comp_close!(c, inst)
        ev("(ui-close! :nbx)")
    end

    @testset "i,i interrupts a running cell" begin
        w = evd("(ui-notebook text=\"(let (s=(stream)) (fetch s timeout=100))\")")
        (c, inst) = notebook_of(w)
        B._comp_key!(c, inst, B._ui_key(:char; char = 'j', ctrl = true))
        @test B._comp_running(c)
        B._comp_key!(c, inst, B._ui_key(:esc))
        B._comp_key!(c, inst, B._ui_key(:char; char = 'i'))
        @test c.chord == 'i'
        @test occursin("i: interrupt", B._comp_status(c, inst))
        B._comp_key!(c, inst, B._ui_key(:char; char = 'i'))
        @test wait_for(() -> (B._comp_tick!(c, inst); !B._comp_running(c));
                       secs = 20)
        @test outputs_of(w)[1] == "interrupted"
        B._comp_close!(c, inst)
        ev("(ui-close! :nbx)")
    end
end
