# The abstract UI: `(ui …)` trees are inert data; `ui-open` instantiates one
# into a named instance that owns values, validation, callbacks, and the facts
# its elements assert. Renderers are views over that state.
@testset "ui" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evd(s) = air_eval(env, read_air(s))
    hasfact(where, f) = occursin(f, ev("(facts $where)"))

    term_run(key, bytes; kw...) = ui_term_run(env, key, bytes; kw...)

    # ---- inertness -----------------------------------------------------------
    @test ev("(ui checkbox initval=true)") == "(ui checkbox initval=true)"
    @test ev("(ui column (ui label text=(+ 1 2)))") ==
          "(ui column (ui label text=(+ 1 2)))"
    @test ev("(ui label text=(+ 1 2))") == "(ui label text=(+ 1 2))"
    # A tree built by a `val` is still inert until opened.
    @test ev("(val t (ui checkbox initval=false))") == "naught"
    @test ev("t") == "(ui checkbox initval=false)"
    # A ui-headed rule cannot fire.
    @test ev("(def (ui ?k ?x) :bad)") == "naught"
    @test ev("(ui checkbox)") == "(ui checkbox)"

    # ---- instantiation -------------------------------------------------------
    @test ev("(ui-open :d (ui column (ui checkbox id=:c) (ui text-input id=:t)))") == ":d"
    @test ev("(ui-values :d)") == "(c=false t=\"\")"
    @test ev("(ui-value :d :t)") == "\"\""
    # initval is evaluated
    @test ev("(ui-open :e (ui int-input id=:i initval=(+ 2 3) min=0 max=10))") == ":e"
    @test ev("(ui-value :e :i)") == "5"
    # errors
    @test_throws AirLang.AirEvalError evd("(ui-open :x (ui nope))")
    @test_throws AirLang.AirEvalError evd("(ui-open :x (ui checkbox frob=1))")
    @test_throws AirLang.AirEvalError evd(
        "(ui-open :x (ui column (ui checkbox id=:q) (ui toggle id=:q)))")
    @test_throws AirLang.AirEvalError evd("(ui-open :x (ui tabs (ui checkbox)))")
    @test_throws AirLang.AirEvalError evd("(ui-open :x (ui column 5))")
    @test_throws AirLang.AirEvalError evd("(ui-open :x (ui dropdown options=(:a :b)))")
    @test_throws AirLang.AirEvalError evd("(ui-open :d (ui checkbox))")
    ev("(ui-close! :d)")
    ev("(ui-close! :e)")

    # ---- values and callbacks ------------------------------------------------
    ev("(ui-open :v (ui checkbox id=:c initval=false label=\"On\" " *
                 "on-change=((?o ?n) -> (assert (changed o n)))))")
    @test hasfact(".main", "(changed") == false     # no change event at creation
    @test ev("(ui-set! :v :c true)") == "true"
    @test hasfact(".main", "(changed false true)")
    # an equal value is not a change
    @test ev("(ui-set! :v :c true)") == "true"
    @test hasfact(".main", "(changed true true)") == false
    # a programmatic change notifies renderers
    inst = AirLang._ui_lookup(env, Form(Symbol(":v")))
    epoch = inst.epoch
    ev("(ui-set! :v :c false)")
    @test inst.epoch > epoch
    ev("(ui-close! :v)")

    # An error in a callback surfaces from ui-set!, and the value stays.
    ev("(ui-open :err (ui checkbox id=:c initval=false " *
                 "on-change=((?o ?n) -> (raise :boom))))")
    err = try
        evd("(ui-set! :err :c true)")
        nothing
    catch e
        e
    end
    @test err isa AirLang.AirThrown
    @test air_string(err.form) == "(error :boom)"
    @test ev("(ui-value :err :c)") == "true"
    ev("(ui-close! :err)")

    # ---- validation ----------------------------------------------------------
    ev("(ui-open :val (ui column " *
       "(ui int-input id=:i initval=5 min=1 max=10) " *
       "(ui slider id=:s initval=0.5 min=0.0 max=1.0 step=0.01) " *
       "(ui int-input id=:d initval=3 disabled=true) " *
       "(ui range-slider id=:r initval=(0.2 0.8) min=0.0 max=1.0) " *
       "(ui multi-select id=:m options=(:a :b :c) initval=(:a :b))))")
    isairerr(s) = try
        evd(s); false
    catch e
        e isa AirLang.AirThrown && occursin(":ui-invalid", air_string(e.form))
    end
    @test isairerr("(ui-set! :val :i 1.5)")
    @test isairerr("(ui-set! :val :i 20)")
    @test isairerr("(ui-set! :val :s 1.5)")
    @test isairerr("(ui-set! :val :s 0.555)")
    @test ev("(ui-set! :val :s 0.55)") == "0.55"
    @test isairerr("(ui-set! :val :m (:z))")
    @test ev("(ui-set! :val :m (:a :c))") == "(:a :c)"
    @test isairerr("(ui-set! :val :r (0.9 0.1))")
    @test ev("(ui-set! :val :d 7)") == "7"
    vinst = AirLang._ui_lookup(env, Form(Symbol(":val")))
    @test AirLang._ui_dispatch!(vinst, (:set, "d", Form(8))) ==
          (:invalid, "element is disabled")
    @test ev("(ui-value :val :d)") == "7"
    ev("(ui-close! :val)")

    # ---- assertions ----------------------------------------------------------
    ev("(ui-open :a (ui column " *
       "(ui text-input id=:n initval=\"abc\" assert=(experiment-name _)) " *
       "(ui checkbox id=:g initval=true assert=(if _ (enabled true) naught))))")
    @test hasfact(".main", "(experiment-name \"abc\")")
    @test hasfact(".main", "(enabled true)")
    # a value change replaces the fact
    @test ev("(ui-set! :a :n \"xyz\")") == "\"xyz\""
    @test hasfact(".main", "(experiment-name \"xyz\")")
    @test hasfact(".main", "(experiment-name \"abc\")") == false
    # naught retracts
    @test ev("(ui-set! :a :g false)") == "false"
    @test hasfact(".main", "(enabled true)") == false
    # an equal assertion is a no-op (and keeps the fact)
    @test ev("(ui-set! :a :n \"xyz\")") == "\"xyz\""
    @test hasfact(".main", "(experiment-name \"xyz\")")
    # a fact asserted by someone else under another reason survives our retraction
    ev("(assert (experiment-name \"xyz\"))")
    ev("(ui-set! :a :n \"other\")")
    @test hasfact(".main", "(experiment-name \"xyz\")")
    ev("(retract (experiment-name \"xyz\"))")
    @test hasfact(".main", "(experiment-name \"xyz\")") == false
    # closing retracts everything the instance owns
    ev("(ui-close! :a)")
    @test hasfact(".main", "(experiment-name \"other\")") == false

    # The assertion stays in the namespace the instance was opened in.
    ev("(namespace .app (ui-open :ns (ui text-input id=:x initval=\"a\" " *
                           "assert=(app-x _))))")
    @test hasfact(".app", "(app-x \"a\")")
    ev("(ui-set! :ns :x \"b\")")
    @test hasfact(".app", "(app-x \"b\")")
    @test hasfact(".main", "(app-x") == false
    ev("(ui-close! :ns)")
    @test hasfact(".app", "(app-x") == false

    # ---- ui-update! ----------------------------------------------------------
    ev("(namespace .app (ui-open :u (ui column " *
       "(ui text-input id=:x initval=\"a\" assert=(app-x _)) " *
       "(ui checkbox id=:y initval=false assert=(app-y _)))))")
    @test ev("(ui-update! :u (ui column (ui text-input id=:x initval=\"z\" " *
                           "assert=(app-x _)) " *
                           "(ui checkbox id=:new initval=true " *
                           "assert=(new-on _))))") == ":u"
    @test ev("(ui-values :u)") == "(new=true x=\"a\")"   # surviving value kept
    @test hasfact(".app", "(app-x \"a\")")               # and re-asserted
    @test hasfact(".app", "(new-on true)")
    @test hasfact(".app", "(app-y") == false             # removed element
    ev("(ui-close! :u)")
    @test hasfact(".app", "(new-on") == false

    # ---- the text renderer ---------------------------------------------------
    ev("(ui-open :r (ui column " *
       "(ui label text=\"Config\") " *
       "(ui text-input id=:n initval=\"exp-01\" label=\"Name\") " *
       "(ui dropdown id=:d options=((\"CPU\" :cpu) (\"GPU\" :gpu)) " *
       "               initval=:gpu label=\"Device\") " *
       "(ui row (ui button label=\"Run\") (ui button label=\"Done\"))))")
    @test ev("(ui-render :r width=80)") ==
          "\"Config\\nName: exp-01\\nDevice: GPU\\n[ Run ]  [ Done ]\""
    ev("(ui-close! :r)")

    # ---- the registry --------------------------------------------------------
    k = ev("(ui-open (ui checkbox))")
    key = Symbol(strip(k, ':'))
    @test startswith(String(key), "ui")
    @test occursin(k, ev("(ui-instances)"))
    ev("(ui-close! " * k * ")")
    @test occursin(k, ev("(ui-instances)")) == false
    # closing twice is a no-op, and a missing instance is an error
    ev("(ui-close! " * k * ")")
    @test_throws AirLang.AirEvalError evd("(ui-values :nope)")

    # ---- the terminal renderer ----------------------------------------------
    # Checkbox: space toggles; a lone Esc dismisses and returns naught.
    ev("(ui-open :t1 (ui column (ui checkbox id=:c initval=true label=\"On\") " *
                    "(ui text-input id=:n initval=\"abc\" label=\"Name\")))")
    (result, screen) = term_run(:t1, [0x20, 0x1b])
    @test result == (:ok, naught)
    @test ev("(ui-value :t1 :c)") == "false"
    @test occursin("\e[?1049h", screen)
    @test occursin("\e[?1049l", screen)
    @test occursin("\e[7m", screen)
    ev("(ui-close! :t1)")

    # Tab to the text field, type, Enter commits; Ctrl-C aborts.
    ev("(ui-open :t2 (ui column (ui checkbox id=:c initval=false) " *
                    "(ui text-input id=:n initval=\"abc\" label=\"Name\")))")
    (result, screen) = term_run(:t2,
        vcat(UInt8[0x09], collect(codeunits("hi")), UInt8[0x0d, 0x03]))
    @test result[1] === :err
    @test result[2] isa AirLang.AirThrown
    @test air_string(result[2].form) == "(error :ctrl-c)"
    @test ev("(ui-value :t2 :n)") == "\"abchi\""
    @test occursin("\e[?1049l", screen)
    ev("(ui-close! :t2)")

    # ESC followed immediately by `[A` is an arrow key, not a dismiss.
    ev("(ui-open :t3 (ui column (ui checkbox id=:a initval=false) " *
                    "(ui checkbox id=:b initval=false)))")
    (result, screen) = term_run(:t3, [0x1b, UInt8('['), UInt8('A'), 0x20, 0x1b])
    @test result == (:ok, naught)
    @test ev("(ui-values :t3)") == "(a=false b=true)"   # up wrapped to :b
    ev("(ui-close! :t3)")

    # An invalid value keeps the last accepted value and shows the reason.
    ev("(ui-open :t4 (ui int-input id=:i initval=5 min=1 max=10))")
    (result, screen) = term_run(:t4,
        vcat(collect(codeunits("99")), UInt8[0x0d, 0x03]))
    @test result[1] === :err
    @test ev("(ui-value :t4 :i)") == "5"
    @test occursin("at most 10", screen)
    ev("(ui-close! :t4)")
end

# The theme: roles resolve to colors, `ui-theme!` recolors one, `ui-style`
# reports a role's full style, and the defaults come back.
@testset "ui theme" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    t0 = ev("(ui-theme)")
    @test startswith(t0, "(theme ")
    # A role that only recolors its foreground prints as a bare color; a role
    # that also changes weight, background, or another field prints as a map.
    @test occursin("string=green", t0)
    @test occursin("comment=bright_black", t0)
    @test occursin("error=(bold=true fg=bright_red)", t0)
    @test occursin("selection=(bg=blue)", t0)
    @test ev("(ui-style :string)") ==
          "(style bg=default bold=false dim=false fg=green italic=false " *
          "reverse=false underline=false)"
    # A color name may be spelled with hyphens, and a string works too.
    @test ev("(ui-theme! string=:bright-yellow)") == "naught"
    @test occursin("fg=bright_yellow", ev("(ui-style :string)"))
    @test ev("(ui-theme! number=\"cyan\")") == "naught"
    @test occursin("fg=cyan", ev("(ui-style :number)"))
    # An unknown role is refused, and the defaults are restorable.
    err = ""
    try
        ev("(ui-theme! nonsense=:red)")
    catch e
        err = sprint(showerror, e)
    end
    @test occursin("unknown role", err)
    # A global entry may set any style field, and a whole saved palette installs
    # with one call, so a theme round-trips through `(ui-theme)`.
    @test ev("(ui-theme! string=(bg=:blue bold=true))") == "naught"
    @test occursin("bg=blue", ev("(ui-style :string)"))
    @test occursin("bold=true", ev("(ui-style :string)"))
    @test occursin("fg=bright_yellow", ev("(ui-style :string)"))  # kept
    @test ev("(do (val t (ui-theme)) (ui-theme! reset=true string=:red) " *
             "(ui-theme! reset=true t) (ui-style :string))") ==
          "(style bg=blue bold=true dim=false fg=bright_yellow italic=false " *
          "reverse=false underline=false)"
    @test ev("(ui-theme! reset=true)") == "naught"
    @test occursin("fg=green", ev("(ui-style :string)"))
    @test occursin("bold=false", ev("(ui-style :string)"))
    # An entry may also arrive as part of a whole theme map, bare or under the
    # `theme` head, and role entries given alongside it win.
    @test ev("(ui-theme! (theme number=:yellow comment=(bg=:blue)))") == "naught"
    @test occursin("fg=yellow", ev("(ui-style :number)"))
    @test occursin("bg=blue", ev("(ui-style :comment)"))
    @test ev("(ui-theme! (number=:cyan) number=:red)") == "naught"
    @test occursin("fg=red", ev("(ui-style :number)"))
    # An entry that names the same field twice, or names no field at all, is
    # refused rather than silently resolved.
    everr(s) = ui_errmsg(() -> ev(s))
    @test occursin("names fg twice",
                   everr("(ui-theme! string=(fg=:red color=:blue))"))
    @test occursin("names no fields", everr("(ui-theme! comment=())"))
    @test ev("(ui-theme! reset=true)") == "naught"
    # A widget may carry its own theme: it recolors the roles it names for that
    # widget's draw, keeps the rest, and is installed only while drawing.
    @test ev("(ui-open :th (ui-code text=\"(+ 1 2)\" theme=(string=:red)))") == ":th"
    inst = AirLang._ui_lookup(env, Form(Symbol(":th")))
    c = AirLang._comp_build(inst)
    th = c.base.theme
    @test th !== nothing
    @test th[:string].fg === :red
    @test th[:string].bg === :default
    @test Base.ScopedValues.with(() -> AirLang._ui_role(:string).fg,
                                 AirLang._UI_THEME_LOCAL => th) === :red
    @test AirLang._ui_role(:string).fg === :green
    ev("(ui-close! :th)")
    # The renderer installs the map around the widget's own draw, so a string
    # token in the body takes the widget's color instead of the process color.
    ev("(ui-open :thd (ui-code text=\"(f \\\"x\\\")\" theme=(string=:red)))")
    thinst = AirLang._ui_lookup(env, Form(Symbol(":thd")))
    out = IOBuffer()
    r = AirLang._TermRenderer(out; cols = Ref(40), rows = Ref(8),
                              readbyte = () -> nothing)
    r.comp = AirLang._comp_build(thinst)
    AirLang._ui_term_draw!(r, thinst)
    @test occursin("\e[0;31", String(take!(out)))
    ev("(ui-close! :thd)")
    # A theme entry must name a real role.
    @test ev("(ui-open :thn (ui-code theme=(nonsense=:red)))") == ":thn"
    inst = AirLang._ui_lookup(env, Form(Symbol(":thn")))
    @test_throws AirLang.AirEvalError AirLang._comp_build(inst)
    ev("(ui-close! :thn)")
    # An entry may instead be a map of style fields, each replacing one field of
    # the role it inherits; `color=` is a synonym for `fg=`.
    ev("(ui-open :thm (ui-code theme=(string=(fg=:red bg=:blue bold=true) " *
                       "comment=(color=:cyan dim=true))))")
    inst = AirLang._ui_lookup(env, Form(Symbol(":thm")))
    thm = AirLang._comp_build(inst).base.theme
    @test thm[:string].fg === :red
    @test thm[:string].bg === :blue
    @test thm[:string].bold
    @test !thm[:string].dim
    @test thm[:comment].fg === :cyan
    @test thm[:comment].dim
    @test !thm[:comment].bold
    ev("(ui-close! :thm)")
    # Unknown fields and non-boolean flags are refused when the widget is built.
    therr(src) = begin
        ev("(ui-open :the " * src * ")")
        inst = AirLang._ui_lookup(env, Form(Symbol(":the")))
        msg = try
            AirLang._comp_build(inst)
            ""
        catch e
            sprint(showerror, e)
        end
        ev("(ui-close! :the)")
        msg
    end
    @test occursin("unknown field", therr("(ui-code theme=(string=(frob=:red)))"))
    @test occursin("must be true or false",
                   therr("(ui-code theme=(string=(bold=1)))"))
    # The same two entry errors a global entry raises.
    @test occursin("names fg twice",
                   therr("(ui-code theme=(string=(fg=:red color=:blue)))"))
    @test occursin("names no fields", therr("(ui-code theme=(comment=()))"))
end

# The status row right-aligns as many whole key hints as fit; it never cuts one,
# and it switches to the short spelling only when that shows more hints.
@testset "status row hints" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    hints = ["ctrl-j: run" => "^J run", "esc: done" => "esc",
             "ctrl-r: run all" => "^R all"]
    longs = first.(hints)
    shorts = last.(hints)
    for w in 1:120
        row = AirLang._ui_fit_hints("code", hints, w)
        @test startswith(row, "code")
        @test textwidth(row) <= max(w - 1, 4)
        # Whatever follows is a run of whole hints in one spelling or the other.
        ok = row == "code"
        for hm in (longs, shorts), n in 1:3
            ok |= endswith(row, join(hm[1:n], "   "))
        end
        @test ok
    end
    # Room for one long hint but two short ones: the short spelling wins.
    @test endswith(AirLang._ui_fit_hints("code", hints, 20), "^J run   esc")
    # Room for all three long ones: the long spelling wins.
    @test endswith(AirLang._ui_fit_hints("code", hints, 60), join(longs, "   "))
    # A tie keeps the long spelling, and no room at all is the left part alone.
    @test endswith(AirLang._ui_fit_hints("code", hints, 17), "ctrl-j: run")
    @test AirLang._ui_fit_hints("code", hints, 10) == "code"
    # No hint at all, and a left part longer than the row, are both safe.
    @test AirLang._ui_fit_hints("code", Pair{String,String}[], 40) == "code"
    @test AirLang._ui_fit_hints(repeat("x", 50), hints, 20) == repeat("x", 50)

    # A real widget's status line obeys the same bound at every width.
    w = air_eval(env, read_air("(ui-notebook text=\"(+ 1 2)\")"))
    ui_open_form!(env, :hintnb, w)
    inst = AirLang._ui_lookup(env, Form(Symbol(":hintnb")))
    c = AirLang._comp_notebook(inst, inst.root)
    for width in (20, 30, 40, 60, 80, 120)
        row = AirLang._comp_status_line(c, inst, width)
        @test startswith(row, "notebook")
        # Either the row carries whole hints and fits, or none fit and it is the
        # left part alone (which the renderer clips).
        @test textwidth(row) <= width - 1 || !occursin("   ", row)
    end
    ev("(ui-close! :hintnb)")
end

# The terminal writer keeps the last frame and sends only the rows that differ,
# so a keystroke costs one row and a cursor move instead of a full screen.
@testset "ui frames" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))

    ev("(ui-open :fr (ui-code text=\"(+ 1 2)\"))")
    inst = AirLang._ui_lookup(env, Form(Symbol(":fr")))
    out = IOBuffer()
    r = AirLang._TermRenderer(out; cols = Ref(40), rows = Ref(8),
                              readbyte = () -> nothing)
    r.comp = AirLang._comp_build(inst)
    AirLang._ui_term_draw!(r, inst)
    first = String(take!(out))
    @test occursin("\e[K", first)

    # Nothing changed: the rows are all skipped and only the cursor is placed.
    AirLang._ui_term_draw!(r, inst)
    second = String(take!(out))
    @test !occursin("\e[K", second)
    @test occursin("\e[", second)

    # An edit redraws the rows it touches, not the whole frame.
    AirLang._tb_insert!(r.comp.buf, "(+ 1 2 3)")
    AirLang._ui_term_draw!(r, inst)
    third = String(take!(out))
    @test occursin("\e[K", third)
    @test count("\e[K", third) < count("\e[K", first)
    ev("(ui-close! :fr)")

    # Composite widgets answer `ui-render` headlessly, and building one for a
    # view starts nothing (a chat's pump belongs to a renderer session).
    ev("(def bt-one 1)")
    ev("(ui-open :hb (ui-browser))")
    @test occursin("bt-one", ev("(ui-render :hb)"))
    ev("(ui-close! :hb)")

    ev("(def hc-in (stream))")
    ev("(def hc-out (stream))")
    ev("(val hcw (ui-chat in=hc-in out=hc-out))")
    @test ev("(ui-open :hch hcw)") == ":hch"
    @test ev("(ui-render :hch)") == "\"\""
    chinst = AirLang._ui_lookup(env, Form(Symbol(":hch")))
    @test AirLang._comp_build(chinst).pump === nothing
    ev("(ui-close! :hch)")
end
