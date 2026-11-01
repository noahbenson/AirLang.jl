# The code-writing component: typing, automatic indentation from the layout,
# pairing, running, and the definition editor.
@testset "ui codeblock" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evd(s) = air_eval(env, read_air(s))
    B = AirLang

    # The state mutable a widget form names.
    state_of(form) = form.map[Symbol(":state")]

    open_form!(key, w) = ui_open_form!(env, key, w)
    term_run(key, bytes; kw...) = ui_term_run(env, key, bytes; kw...)
    wait_for(f; kw...) = ui_wait_for(f; kw...)
    bytes(s) = ui_bytes(s)
    CTRL_J = UI_CTRL_J
    ENTER = UI_ENTER
    ESC = UI_ESC
    BACKSPACE = UI_BACKSPACE
    TAB = UI_TAB

    # The text the component persisted into its state mutable.
    stored_text(form) = B._state_string(B.canonicalize(state_of(form)[]), :text)

    @testset "the widget form" begin
        w = evd("(ui-code)")
        @test startswith(air_string(w), "(ui code-block")
        @test w isa AirDB.FormContainer
        @test haskey(w.map, Symbol(":state"))
        @test haskey(w.map, Symbol(":ns"))
        @test B._stored_path(B.to_form(w.map[Symbol(":ns")])) == [:main]
        # text= seeds the state.
        w2 = evd("(ui-code text=\"(+ 1 2)\")")
        @test stored_text(w2) == "(+ 1 2)"
        # state= must be a mutable.
        @test_throws AirLang.AirEvalError evd("(ui-code state=1)")
    end

    @testset "typing, running, and storing" begin
        w = evd("(ui-code)")
        open_form!(:cb1, w)
        (res, out) = term_run(:cb1, vcat(bytes("(+ 1 2)"), [CTRL_J, ESC]))
        @test res[1] === :ok
        @test occursin("3", out)
        @test stored_text(w) == "(+ 1 2)"
        ev("(ui-close! :cb1)")
    end

    @testset "pairing" begin
        # An opener inserts its closer; typing the closer steps over it.
        w = evd("(ui-code)")
        open_form!(:cb2, w)
        term_run(:cb2, vcat(bytes("("), [ESC]))
        @test stored_text(w) == "()"
        ev("(ui-close! :cb2)")
        # Backspace between the auto-inserted pair deletes both.
        w = evd("(ui-code)")
        open_form!(:cb3, w)
        term_run(:cb3, vcat(bytes("("), [BACKSPACE, ESC]))
        @test stored_text(w) == ""
        ev("(ui-close! :cb3)")
        # A quote pairs; inside a string a quote steps over instead of pairing.
        w = evd("(ui-code)")
        open_form!(:cb4, w)
        term_run(:cb4, vcat(bytes("\""), [ESC]))
        @test stored_text(w) == "\"\""
        ev("(ui-close! :cb4)")
        # Enter between a pair puts the closer on its own line.
        w = evd("(ui-code)")
        open_form!(:cb5, w)
        term_run(:cb5, vcat(bytes("("), [ENTER, ESC]))
        @test stored_text(w) == "(\n \n)"
        ev("(ui-close! :cb5)")
    end

    @testset "auto-indentation while typing" begin
        w = evd("(ui-code)")
        open_form!(:cb6, w)
        term_run(:cb6, vcat(bytes("(def (f ?x)"), [ENTER], bytes("1"),
                            bytes(")"), [CTRL_J, ESC]))
        @test stored_text(w) == "(def (f ?x)\n  1)"
        # The def is now runnable in the widget's namespace.
        @test ev("(f 9)") == "1"
        ev("(ui-close! :cb6)")
    end

    @testset "an unclosed buffer refuses to run" begin
        w = evd("(ui-code text=\"(+ 1\")")
        open_form!(:cb7, w)
        (res, out) = term_run(:cb7, [CTRL_J, ESC])
        @test res[1] === :ok
        @test occursin("unclosed", out)
        @test stored_text(w) == "(+ 1"
        ev("(ui-close! :cb7)")
    end

    @testset "rendering" begin
        ev("(ui-open :cb8 (ui code-block text=\"(f 1)\" ns=(main)))")
        text = ev("(ui-render :cb8)")
        @test occursin("(f 1)", text)
        ev("(ui-close! :cb8)")
    end

    @testset "the definition editor" begin
        ev("(namespace .cbns)")
        w = evd("(ui-editor .cbns)")
        open_form!(:cb9, w)
        term_run(:cb9, vcat(bytes("(def (g ?x) (zzz x))"), [CTRL_J, ESC]))
        @test stored_text(w) == "(def (g ?x) (zzz x))"
        @test ev("(ns-entry .cbns g)") != "naught"
        ev("(ui-close! :cb9)")
        # The editor starts from the entry's source when it has one.
        ev("(val e (ui-editor .cbns target=g))")
        text = ev("(do (ui-open :cb10 e) (ui-render :cb10))")
        @test occursin("(def (g ?x)", text)
        ev("(ui-close! :cb10)")
        # Editing an entry with no stored source reconstructs the printed form.
        ev("(namespace .cbns (def (h ?x) \"doc\" (zzz x)))")
        w2 = evd("(ui-editor .cbns target=h)")
        @test stored_text(w2) == "(def (h ?x) \"doc\" (zzz x))"
    end

    @testset "tab always bubbles" begin
        w = evd("(ui-code)")
        open_form!(:cb11, w)
        (res, out) = term_run(:cb11, vcat(bytes("a"), [TAB, ESC]))
        # Tab is not an indent key: the buffer is unchanged and the renderer
        # dismissed the root.
        @test stored_text(w) == "a"
        @test res[1] === :ok
        ev("(ui-close! :cb11)")
    end

    @testset "evaluation runs in the background" begin
        w = evd("(ui-code)")
        open_form!(:cb12, w)
        inst = B._ui_lookup(env, Form(Symbol(":cb12")))
        c = B._comp_build(inst)
        B._tb_set_text!(c.buf, "(+ 20 22)")
        B._cb_run!(c, inst)
        @test B._comp_running(c)
        @test c.base.status == ""              # the job's label replaces it
        @test B._comp_job_label(c) == "running…"
        # Poll the way the render loop does until the result lands.
        wait_for(() -> (B._comp_tick!(c, inst); !B._comp_running(c)))
        @test !B._comp_running(c)
        @test any(l -> occursin("42", l.text), c.out)
        @test c.saved == "(+ 20 22)"
        @test inst.dirty

        # A second run is refused while one is in flight.
        @test B._comp_start_job!(c, inst,
            () -> (B._tb_text(c.buf), (:ok, Form[Form(1)])))
        B._cb_run!(c, inst)
        @test c.base.status == "still running"
        wait_for(() -> (B._comp_tick!(c, inst); !B._comp_running(c)))
        @test any(l -> l.text == "1", c.out)
        B._comp_close!(c, inst)
        ev("(ui-close! :cb12)")
    end

    @testset "the output survives a detach" begin
        w = evd("(ui-code text=\"(+ 40 2)\")")
        open_form!(:cb13, w)
        # The renderer leaves as soon as Esc arrives; the evaluation is a job
        # the instance's ticker finishes and applies with nobody attached.
        (res, out) = term_run(:cb13, [CTRL_J, ESC])
        @test res[1] === :ok
        @test occursin("running", out)
        # The stored state holds the output and the text that produced it, so a
        # rebuilt widget shows the result with a clean buffer.
        v = B.canonicalize(state_of(w)[])
        @test B._state_string(v, :output) == "42"
        @test B._state_string(v, Symbol(":output-for")) == "(+ 40 2)"
        open_form!(:cb14, w)
        inst = B._ui_lookup(env, Form(Symbol(":cb14")))
        c = B._comp_build(inst)
        @test any(l -> l.text == "42", c.out)
        @test c.saved == "(+ 40 2)"
        @test !B._comp_dirty(c, inst)
        ev("(ui-close! :cb14)")
    end

    @testset "an evaluation outlives the connection" begin
        w = evd("(ui-code)")
        open_form!(:cb17, w)
        inst = B._ui_lookup(env, Form(Symbol(":cb17")))
        c = B._ui_tree(inst)
        B._tb_set_text!(c.buf, "(+ 40 2)")
        # Start a run that lands well after the renderer leaves.
        @test B._comp_start_job!(c, inst,
            () -> (sleep(0.3); ("(+ 40 2)", (:ok, Form[Form(42)]))))
        # Detaching does not wait for it: the run is still in flight and the
        # widget is still alive after the renderer is gone.
        (res, _) = term_run(:cb17, [ESC]; settle = false)
        @test res[1] === :ok
        @test B._comp_running(c)
        # The instance's own ticker finishes it and stores the result with no
        # renderer attached.
        @test wait_for(() -> lock(() -> !B._comp_running(c), inst.lock))
        v = B.canonicalize(state_of(w)[])
        @test B._state_string(v, :output) == "42"
        @test B._state_string(v, Symbol(":output-for")) == "(+ 40 2)"
        @test any(l -> l.text == "42", c.out)
        # Reattaching shows the same tree, result included.
        (res2, out2) = term_run(:cb17, [ESC])
        @test res2[1] === :ok
        @test occursin("42", out2)
        ev("(ui-close! :cb17)")
    end

    @testset "a stored error is restored as an error" begin
        w = evd("(ui-code text=\"(raise :boom)\")")
        open_form!(:cb15, w)
        term_run(:cb15, [CTRL_J, ESC])
        v = B.canonicalize(state_of(w)[])
        @test B._state_flag(v, :error)
        open_form!(:cb16, w)
        inst = B._ui_lookup(env, Form(Symbol(":cb16")))
        c = B._comp_build(inst)
        @test c.failed
        @test any(l -> occursin(":boom", l.text), c.out)
        ev("(ui-close! :cb16)")
    end
end
