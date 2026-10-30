# The abstract UI: `(ui …)` trees are inert data; `ui-open` instantiates one
# into a named instance that owns values, validation, callbacks, and the facts
# its elements assert. Renderers are views over that state.
@testset "ui" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evd(s) = air_eval(env, read_air(s))
    hasfact(where, f) = occursin(f, ev("(facts $where)"))

    # Drive a terminal renderer over a scripted byte source.
    function term_run(key::Symbol, bytes; cols = 40, rows = 12)
        input = IOBuffer(Vector{UInt8}(bytes))
        out = IOBuffer()
        r = AirLang._TermRenderer(out; cols = Ref(cols), rows = Ref(rows),
                                  readbyte = () -> eof(input) ? nothing :
                                              read(input, UInt8))
        inst = AirLang._ui_lookup(env, Form(Symbol(":" * String(key))))
        result = try
            (:ok, AirLang._ui_term_run!(r, inst))
        catch e
            (:err, e)
        end
        return result, String(take!(out))
    end

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
