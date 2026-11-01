# The namespace browser: the tree built from `ns-entries`, expansion, state, and
# what Ctrl-J / Alt-J open.
@testset "ui browser" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evd(s) = air_eval(env, read_air(s))
    B = AirLang

    state_of(form) = form.map[Symbol(":state")]
    state_value(form) = B.canonicalize(state_of(form)[])

    open_form!(key, w) = ui_open_form!(env, key, w)

    function browser_of(form)
        open_form!(:brx, form)
        inst = B._ui_lookup(env, Form(Symbol(":brx")))
        return (B._comp_browser(inst, inst.root), inst)
    end

    names(c) = [r.name for r in c.rows]
    shapes(c) = [(r.name, r.kind, r.depth) for r in c.rows]

    ctrl_j = B._ui_key(:char; char = 'j', ctrl = true)
    alt_j = B._ui_key(:char; char = 'j', alt = true)

    @testset "the widget form" begin
        w = evd("(ui-browser)")
        @test startswith(air_string(w), "(ui browser")
        @test haskey(w.map, Symbol(":state"))
        v = state_value(w)
        @test B._state_string(v, :root) == "main"     # the current namespace
        @test B._state_field(v, :cursor) !== nothing
        @test startswith(air_string(evd("(ui-browser .)")), "(ui browser")
    end

    @testset "the tree" begin
        ev("(def (f ?x) (+ x 1))")
        ev("(val h 42)")
        ev("(namespace .main.util (def (k ?x) (* x 2)))")
        (c, inst) = browser_of(evd("(ui-browser .main)"))
        @test names(c) == [:f, :h, :util]
        @test shapes(c) == [(:f, :def, 0), (:h, :val, 0), (:util, :sub, 0)]
        # Enter on a sub namespace expands it in place; Enter again collapses.
        c.cursor = 3
        B._comp_key!(c, inst, B._ui_key(:enter))
        @test shapes(c) == [(:f, :def, 0), (:h, :val, 0), (:util, :sub, 0),
                            (:k, :def, 1)]
        @test c.cursor == 3
        B._comp_key!(c, inst, B._ui_key(:enter))
        @test names(c) == [:f, :h, :util]
        # Down/Up move; PageDown and Home/End stay in range.
        c.cursor = 1
        B._comp_key!(c, inst, B._ui_key(:down))
        @test c.cursor == 2
        B._comp_key!(c, inst, B._ui_key(:home))
        @test c.cursor == 1
        B._comp_key!(c, inst, B._ui_key(:end))
        @test c.cursor == 3
        # The rendered lines carry the markers and the doc of a val.
        c.cursor = 2
        lines = [l.text for l in B._comp_lines(c, inst, 60)]
        @test any(l -> startswith(l, "· h"), lines)
        @test any(l -> startswith(l, "▸ util"), lines)
        ev("(ui-close! :brx)")
    end

    @testset "expansion is stored" begin
        w = evd("(ui-browser .main)")
        (c, inst) = browser_of(w)
        c.cursor = 3
        B._comp_key!(c, inst, B._ui_key(:enter))
        v = state_value(w)
        e = B._state_field(v, :expanded)
        @test e isa AirDB.FormContainer
        @test [B._ui_string(to_form(x)) for x in e.seq] == ["main.util"]
        @test B._leafof(B._state_field(v, :cursor)) == 3
        ev("(ui-close! :brx)")
        # Reopening the same form restores the expansion.
        (c2, inst2) = browser_of(w)
        @test length(c2.rows) == 4
        @test c2.cursor == 3
        ev("(ui-close! :brx)")
    end

    @testset "opening entries" begin
        w = evd("(ui-browser .main)")
        (c, inst) = browser_of(w)
        # Ctrl-J on a def opens the editor in the definition's namespace.
        c.cursor = 1
        res = B._comp_key!(c, inst, ctrl_j)
        @test res isa Tuple && res[1] === :open
        @test res[2] == "f"
        @test startswith(air_string(res[3]), "(ui editor")
        @test occursin("target", air_string(res[3]))
        # Ctrl-J on a val opens a notebook seeded with the val's name.
        c.cursor = 2
        res = B._comp_key!(c, inst, ctrl_j)
        @test res isa Tuple && res[1] === :open
        @test startswith(air_string(res[3]), "(ui notebook")
        # Alt-J on a val opens the editor for its definition.
        res = B._comp_key!(c, inst, alt_j)
        @test res isa Tuple && res[1] === :open
        @test startswith(air_string(res[3]), "(ui editor")
        # Ctrl-J on a sub expands instead of opening.
        c.cursor = 3
        @test B._comp_key!(c, inst, ctrl_j) === nothing
        @test length(c.rows) == 4
        ev("(ui-close! :brx)")
    end

    @testset "the filter line" begin
        ev("(def (alpha ?x) (+ x 1))")
        ev("(val beta 42)")
        ev("(namespace .main.util (def (printer ?x) (* x 2)))")
        w = evd("(ui-browser .main)")
        (c, inst) = browser_of(w)
        full = length(c.rows)
        ctrl_s = B._ui_key(:char; char = 's', ctrl = true)
        type!(s) = for ch in s
            B._comp_key!(c, inst, B._ui_key(:char; char = ch))
        end
        # Ctrl-S opens the line; it is a prompt, so the shell shows it and its
        # keys stay here.
        @test B._comp_prompt(c, inst) === nothing
        @test B._comp_key!(c, inst, ctrl_s) === :handled
        @test B._comp_prompt(c, inst) !== nothing
        @test B._comp_prompt_hints(c) ==
              ["enter: accept" => "enter", "esc: cancel" => "esc"]
        # Typing narrows live, across collapsed namespaces, and shows the path.
        type!("print")
        @test names(c) == [:printer]
        @test c.rows[1].path == [:main, :util]
        @test c.cursor == 1
        st = B._comp_status(c, inst)
        @test startswith(st, "filter: print")
        @test occursin("1 of", st)
        lines = [l.text for l in B._comp_lines(c, inst, 60)]
        @test any(l -> startswith(l, "main.util.· printer"), lines)
        # The line owns every key while it is open, so Ctrl-J is not the tree's.
        @test B._comp_key!(c, inst, ctrl_j) === :handled
        # Enter accepts the text and closes the line; the rows stay narrowed.
        B._comp_key!(c, inst, B._ui_key(:enter))
        @test c.prompt === nothing
        @test c.filter == "print"
        @test names(c) == [:printer]
        @test occursin("filter: print", B._comp_status(c, inst))
        @test B._comp_prompt(c, inst) === nothing
        # A match opens exactly as it would in the tree.
        res = B._comp_key!(c, inst, ctrl_j)
        @test res isa Tuple && res[1] === :open
        @test occursin("printer", air_string(res[3]))
        # The accepted filter is part of the view, so it is stored and restored.
        @test B._state_string(state_value(w), :filter) == "print"
        ev("(ui-close! :brx)")
        (c2, inst2) = browser_of(w)
        @test c2.filter == "print"
        @test names(c2) == [:printer]
        # Esc clears the narrowing; only a second Esc leaves the browser.
        @test B._comp_key!(c2, inst2, B._ui_key(:esc)) === :handled
        @test isempty(c2.filter)
        @test length(c2.rows) == full
        @test B._comp_key!(c2, inst2, B._ui_key(:esc)) === :bubble
        type2!(s) = for ch in s
            B._comp_key!(c2, inst2, B._ui_key(:char; char = ch))
        end
        # A query with no match says so, and Backspace brings the matches back.
        B._comp_key!(c2, inst2, B._ui_key(:char; char = 's', ctrl = true))
        type2!("prinz")
        @test isempty(c2.rows)
        @test occursin("no match", B._comp_status(c2, inst2))
        @test [l.text for l in B._comp_lines(c2, inst2, 40)] == ["(no match)"]
        B._comp_key!(c2, inst2, B._ui_key(:backspace))
        @test names(c2) == [:printer]
        # Up/Down move through the matches while the line stays open.
        @test B._comp_key!(c2, inst2, B._ui_key(:esc)) === :handled
        @test c2.prompt === nothing
        B._comp_key!(c2, inst2, B._ui_key(:char; char = 's', ctrl = true))
        type2!("a")
        n = length(c2.rows)
        @test n >= 2
        B._comp_key!(c2, inst2, B._ui_key(:down))
        @test c2.cursor == 2
        B._comp_key!(c2, inst2, B._ui_key(:up))
        @test c2.cursor == 1
        # Esc cancels the line, restoring the tree and the accepted filter.
        @test B._comp_key!(c2, inst2, B._ui_key(:esc)) === :handled
        @test c2.prompt === nothing
        @test isempty(c2.filter)
        @test length(c2.rows) == full
        # A matching subnamespace is a jump: it becomes the root and the
        # narrowing drops away.
        B._comp_key!(c2, inst2, B._ui_key(:char; char = 's', ctrl = true))
        type2!("util")
        @test names(c2) == [:util]
        @test c2.rows[1].kind === :sub
        # Enter accepts the line first; the next Enter acts on the row.
        B._comp_key!(c2, inst2, B._ui_key(:enter))
        @test c2.prompt === nothing
        @test names(c2) == [:util]
        @test B._comp_key!(c2, inst2, B._ui_key(:enter)) === :handled
        @test c2.root == [:main, :util]
        @test isempty(c2.filter) && c2.prompt === nothing
        @test names(c2) == [:k, :printer]
        ev("(ui-close! :brx)")
    end

    @testset "unreadable entries are absent" begin
        ev("(create-user :bob)")
        ev("(namespace .secret (def (s ?x) x))")
        # Air may read everything, so the namespace and its definition show.
        (c, inst) = browser_of(evd("(ui-browser .)"))
        @test :secret in names(c)
        ev("(ui-close! :brx)")
        # Bob may not read `.secret`, so it is absent — not greyed out.
        ev("(as-user :bob (ui-open :brb (ui-browser .)))")
        instb = B._ui_lookup(env, Form(Symbol(":brb")))
        cb = B._comp_browser(instb, instb.root)
        @test !(:secret in names(cb))
        @test !(:main in names(cb))            # air's namespace is air's
        @test :air in names(cb)                # the core namespace stays readable
        ev("(ui-close! :brb)")
    end
end
