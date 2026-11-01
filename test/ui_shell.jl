# The tab shell: tabs as widget forms, Tab/Shift-Tab, Alt-N, Esc layering with a
# discard confirmation, and opening a tab from the browser.
@testset "ui shell" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evd(s) = air_eval(env, read_air(s))
    B = AirLang

    state_of(form) = form.map[Symbol(":state")]
    state_value(form) = B.canonicalize(state_of(form)[])

    open_form!(key, w) = ui_open_form!(env, key, w)
    term_run(key, bytes; kw...) = ui_term_run(env, key, bytes; kw...)
    bytes(s) = ui_bytes(s)
    TAB = UI_TAB
    ENTER = UI_ENTER
    ESC = UI_ESC

    # The default tabs are opened when a renderer session starts the shell, not
    # when the form is built, so the helper starts it here.
    function shell_of(form)
        open_form!(:shx, form)
        inst = B._ui_lookup(env, Form(Symbol(":shx")))
        c = B._comp_shell(inst, inst.root)
        B._comp_start!(c, inst)
        return (c, inst)
    end

    titles(c) = [t.title for t in c.tabs]

    @testset "the widget form and its default tabs" begin
        w = evd("(ui-shell)")
        @test startswith(air_string(w), "(ui shell")
        @test haskey(w.map, Symbol(":state"))
        (c, inst) = shell_of(w)
        @test titles(c) == ["browser", "scratch"]
        @test c.active == 1
        @test c.tabs[1].comp isa B._Browser
        @test c.tabs[2].comp isa B._Notebook
        # The tab bar is the first line; the active widget's body follows.
        lines = B._comp_lines(c, inst, 40)
        @test occursin("browser", lines[1].text)
        @test occursin("scratch", lines[1].text)
        v = state_value(w)
        @test B._state_field(v, :tabs) isa AirDB.FormContainer
        ev("(ui-close! :shx)")
    end

    @testset "a headless render does not open the default tabs" begin
        w = evd("(ui-shell)")
        open_form!(:shh, w)
        inst = B._ui_lookup(env, Form(Symbol(":shh")))
        c = B._comp_shell(inst, inst.root)
        @test isempty(c.tabs)
        # Building the component mutates nothing: no tab form exists and the
        # state mut is still the empty value the constructor made.
        @test B._state_field(state_value(w), :tabs) === nothing
        @test occursin("(no tabs)", ev("(ui-render :shh)"))
        # Starting the shell — what a renderer session does — opens the tabs.
        B._comp_start!(c, inst)
        @test titles(c) == ["browser", "scratch"]
        @test B._state_field(state_value(w), :tabs) isa AirDB.FormContainer
        B._comp_close!(c, inst)
        ev("(ui-close! :shh)")
    end

    @testset "switching tabs" begin
        w = evd("(ui-shell)")
        (c, inst) = shell_of(w)
        B._comp_key!(c, inst, B._ui_key(:tab))
        @test c.active == 2
        B._comp_key!(c, inst, B._ui_key(:tab))
        @test c.active == 1                       # Tab wraps
        B._comp_key!(c, inst, B._ui_key(:tab; shift = true))
        @test c.active == 2                       # Shift-Tab goes back
        B._comp_key!(c, inst, B._ui_key(:char; char = '1', alt = true))
        @test c.active == 1
        B._comp_key!(c, inst, B._ui_key(:char; char = '9', alt = true))
        @test c.active == 1                       # a tab that is not there
        # Switching stores the active index.
        @test B._leafof(B._state_field(state_value(w), :active)) == 1
        ev("(ui-close! :shx)")
    end

    @testset "the cursor is offset by the tab bar" begin
        (c, inst) = shell_of(evd("(ui-shell)"))
        B._comp_key!(c, inst, B._ui_key(:tab))
        nb = c.tabs[2].comp
        (r1, _) = B._comp_cursor(nb, inst)
        @test B._comp_cursor(c, inst)[1] == r1 + 1
        ev("(ui-close! :shx)")
    end

    @testset "esc closes one layer" begin
        (c, inst) = shell_of(evd("(ui-shell)"))
        @test B._comp_key!(c, inst, B._ui_key(:esc)) === :handled
        @test titles(c) == ["scratch"]            # the active tab closes
        @test c.active == 1
        # With one tab left, Esc dismisses the whole shell.
        @test B._comp_key!(c, inst, B._ui_key(:esc)) === :dismiss
        ev("(ui-close! :shx)")
    end

    @testset "esc pops a prompt inside the active tab first" begin
        (c, inst) = shell_of(evd("(ui-shell)"))
        B._comp_key!(c, inst, B._ui_key(:tab))       # the scratch notebook
        nb = c.tabs[2].comp
        B._comp_key!(c, inst, B._ui_key(:char; char = 's', ctrl = true))
        @test nb.cells[1].prompt !== nothing
        @test occursin("search:", B._comp_prompt(c, inst))
        # Esc cancels the prompt; the tab stays. The next Esc closes it.
        @test B._comp_key!(c, inst, B._ui_key(:esc)) === :handled
        @test nb.cells[1].prompt === nothing
        @test titles(c) == ["browser", "scratch"]
        @test B._comp_key!(c, inst, B._ui_key(:esc)) === :handled
        @test titles(c) == ["browser"]
        ev("(ui-close! :shx)")
    end

    @testset "moving tabs" begin
        (c, inst) = shell_of(evd("(ui-shell)"))
        B._comp_key!(c, inst, B._ui_key(:tab))       # the scratch notebook
        @test c.active == 2
        # Alt-Left moves the active tab one place left, and it stays active.
        B._comp_key!(c, inst, B._ui_key(:left; alt = true))
        @test titles(c) == ["scratch", "browser"]
        @test c.active == 1
        @test occursin("moved \"scratch\" left", B._comp_status(c, inst))
        B._comp_key!(c, inst, B._ui_key(:right; alt = true))
        @test titles(c) == ["browser", "scratch"]
        @test c.active == 2
        # There is no wrap at either edge.
        B._comp_key!(c, inst, B._ui_key(:right; alt = true))
        @test titles(c) == ["browser", "scratch"]
        ev("(ui-close! :shx)")
    end

    @testset "closing every tab" begin
        (c, inst) = shell_of(evd("(ui-shell)"))
        # Nothing is dirty, so Alt-W closes everything at once and dismisses.
        @test B._comp_key!(c, inst, B._ui_key(:char; char = 'w', alt = true)) ===
              :dismiss
        @test isempty(c.tabs)
        # The instance outlives the connection, so a reattach onto the empty
        # shell opens the defaults again rather than stranding the user in a
        # shell with no way to open a tab.
        B._comp_attach!(c, inst)
        @test titles(c) == ["browser", "scratch"]
        ev("(ui-close! :shx)")
        # With an edit anywhere, it asks once first.
        (c, inst) = shell_of(evd("(ui-shell)"))
        B._comp_key!(c, inst, B._ui_key(:tab))
        B._comp_key!(c.tabs[2].comp, inst, B._ui_key(:char; char = 'x'))
        @test B._comp_key!(c, inst, B._ui_key(:char; char = 'w', alt = true)) ===
              :handled
        @test c.confirm === :close_all
        @test occursin("discard changes in 2 tabs", B._comp_status(c, inst))
        B._comp_key!(c, inst, B._ui_key(:char; char = 'n'))
        @test c.confirm === :none
        @test titles(c) == ["browser", "scratch"]
        B._comp_key!(c, inst, B._ui_key(:char; char = 'w', alt = true))
        @test B._comp_key!(c, inst, B._ui_key(:char; char = 'y')) === :dismiss
        @test isempty(c.tabs)
        ev("(ui-close! :shx)")
    end

    @testset "the login UI is a named instance a reconnect reuses" begin
        db = MemoryDatabase()
        envc = Env(db = db)
        (kf, form) = B._ssh_login_ui(envc, :air)
        key = B._ui_key(kf)
        @test key == B._ssh_ui_key(:air)
        inst = B._ui_lookup(envc, kf)
        @test inst.key === key
        @test !inst.ephemeral
        @test inst.widget === form
        # A second login finds the same shell — tabs and all — rather than a
        # fresh one.
        (kf2, form2) = B._ssh_login_ui(envc, :air)
        @test B._ui_lookup(envc, kf2) === inst
        @test form2 === form
        # Closing it is how a user asks for a fresh UI next time.
        air_eval(envc, read_air("(ui-close! " * air_string(kf) * ")"))
        @test_throws B.AirEvalError B._ui_lookup(envc, kf)
        (kf3, form3) = B._ssh_login_ui(envc, :air)
        @test B._ui_lookup(envc, kf3) !== inst
        @test form3 !== form
        air_eval(envc, read_air("(ui-close! " * air_string(kf3) * ")"))
    end

    @testset "closing a dirty tab asks first" begin
        w = evd("(ui-shell)")
        (c, inst) = shell_of(w)
        B._comp_key!(c, inst, B._ui_key(:tab))
        @test B._comp_dirty(c, inst) == false
        nb = c.tabs[2].comp
        B._comp_key!(nb, inst, B._ui_key(:char; char = 'x'))
        @test B._comp_dirty(c, inst)
        @test occursin("discard", B._comp_status(c, inst)) == false
        # Esc asks; anything but `y` keeps the tab.
        @test B._comp_key!(c, inst, B._ui_key(:esc)) === :handled
        @test c.confirm === :close
        @test occursin("discard", B._comp_status(c, inst))
        @test B._comp_key!(c, inst, B._ui_key(:char; char = 'n')) === :handled
        @test c.confirm === :none
        @test titles(c) == ["browser", "scratch"]
        # Esc then `y` discards.
        B._comp_key!(c, inst, B._ui_key(:esc))
        @test B._comp_key!(c, inst, B._ui_key(:char; char = 'y')) === :handled
        @test titles(c) == ["browser"]
        ev("(ui-close! :shx)")
    end

    @testset "opening a tab from the browser" begin
        ev("(def (sf ?x) (+ x 1))")
        (c, inst) = shell_of(evd("(ui-shell)"))
        br = c.tabs[1].comp
        br.cursor = findfirst(r -> r.name === :sf, br.rows)
        res = B._comp_key!(c, inst, B._ui_key(:char; char = 'j', ctrl = true))
        @test res === :handled
        @test titles(c) == ["browser", "scratch", "sf"]
        @test c.active == 3
        @test c.tabs[3].comp isa B._CodeBlock
        @test c.tabs[3].comp.mode === :editor
        @test occursin("(def (sf ?x)", B._tb_text(c.tabs[3].comp.buf))
        ev("(ui-close! :shx)")
    end

    @testset "the terminal renderer" begin
        w = evd("(ui-shell)")
        open_form!(:sh1, w)
        # Tab to the scratch notebook, then Esc twice: the first closes the
        # scratch tab, the second closes the browser and dismisses.
        (res, out) = term_run(:sh1, [TAB, ESC, ESC])
        @test res[1] === :ok
        @test occursin("browser", out)
        ev("(ui-close! :sh1)")
        # The shell survives a re-instantiation with its tabs stored.
        (c2, inst2) = shell_of(w)
        @test !isempty(c2.tabs)
        ev("(ui-close! :shx)")
    end
end
