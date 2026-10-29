@testset "error" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- error objects are constants -----------------------------------------
    @test ev("(error :io (+ 1 2))") == "(error :io (+ 1 2))"   # never evaluates
    @test ev("(error :io)") == "(error :io)"
    @test ev("(error)") == "(error)"
    @test ev("(1 + (error :x))") == "(1 + (error :x))"         # inert at any depth
    @test ev("(error :x a=(+ 1 2))") == "(error :x a=(+ 1 2))" # map entries too

    # ---- raise ---------------------------------------------------------------
    @test_throws AirThrown air_eval(env, read_air("(raise :io (+ 1 2))"))
    @test ev("(do (raise :io (+ 1 2)) (except (:io ?x) x))") == "3"   # raise evaluates
    @test_throws AirThrown air_eval(env, read_air("(raise)"))
    @test ev("(do (raise) (except () :empty))") == ":empty"
    @test ev("(do (raise :io) (except (:io) :ok))") == ":ok"
    @test ev("(do (raise :io a=1) (except (:io ?*k) k))") == "(a=1)"

    # a single object argument is raised exactly; a second argument rebuilds
    @test ev("(do (raise (error :io (+ 1 2))) (except ?e e))") ==
        "(error :io (+ 1 2))"
    @test ev("(do (raise (error :io) \"abc\") (except ?e e))") ==
        "(error (error :io) \"abc\")"

    # ---- except: content matching, bare wildcard binds the object ------------
    @test ev("(do (raise :arg :a) (except (:arg ?x) x))") == ":a"
    @test ev("(do (raise :arg :a) (except (:arg ?x \\ symbol? ??) x))") == ":a"
    @test_throws AirThrown air_eval(env,
        read_air("(do (raise :arg 5) (except (:arg ?x \\ symbol? ??) 0))"))
    @test ev("(do (raise :io \"lost\") (except ?e e))") == "(error :io \"lost\")"
    @test ev("(do (raise :io \"lost\" a=1) (except (:io ??d) d))") ==
        "(\"lost\" a=1)"
    # map options are part of the content and match with ?* / ??
    @test ev("(do (raise :x a=1 cause=(error :r)) (except (:x ?*k) k))") ==
        "(a=1 cause=(error :r))"
    @test ev("(do (raise :x 5 a=1) (except (:x ??d) d))") == "(5 a=1)"

    # clause order: the first matching clause wins
    @test ev("(do (raise :io) (except (:arg) 1) (except (:io) 2) (except ?e 3))") == "2"
    # no matching clause: the error escapes
    @test_throws AirThrown air_eval(env,
        read_air("(do (raise :boom) (except (:io) 1))"))
    # nested blocks: an inner escape is caught by an outer clause
    @test ev("(do (do (raise :a) (except (:b) 1)) (except (:a) 2))") == "2"

    # internal errors surface as (:internal …)
    @test ev("(do (get (1 2) 5) (except (:internal ?m) m))") ==
        "\"key 5 is out of range for a form of 2 elements\""
    @test_throws AirEvalError air_eval(env,
        read_air("(do (get (1 2) 5) (except (:other) 1))"))

    # a stale catch clause is an error; except outside a block is ordinary data
    @test_throws AirEvalError air_eval(env, read_air("(do 1 (catch (:x) 2))"))
    @test ev("(except :x)") == "(except :x)"

    # ---- reraise resumes the original error ----------------------------------
    @test ev("(do (raise :io \"x\") (except (:io ?m) reraise) " *
             "(except (:io ?m) m))") == "\"x\""
    @test_throws AirThrown air_eval(env,
        read_air("(do (raise :io \"x\") (except (:io ?m) reraise))"))
    # side effects before reraise are kept, and a later clause sees the original
    @test ev("(let (l=(mut ())) " *
             "(do (raise :x) " *
             "(except (:x) (do (set! l (push (value l) 1)) reraise)) " *
             "(except (:x) (value l))))") == "(1)"
    # a raise in a handler is a new error; it does not reach later clauses
    @test ev("(do (do (raise :a) (except (:a) (raise :b))) " *
             "(except (:b ?*k) :outer))") == ":outer"

    # ---- finally -------------------------------------------------------------
    @test ev("(do 1 (finally 42))") == "1"           # value discarded
    @test ev("(do (raise :a) (except (:a) 2) (finally 42))") == "2"
    @test ev("(do (raise :a) (except (:a) 2) (finally 3) )") == "2"
    @test ev("(let (l=(mut ())) (do 1 (finally (set! l (push (value l) :fin)))) " *
             "(value l))") == "(:fin)"
    # finally runs before an escaping error leaves the block
    @test ev("(let (l=(mut ())) " *
             "(do (do (raise :x) (finally (set! l (push (value l) :fin)))) " *
             "(except (:x) (value l))))") == "(:fin)"
    # ... and after a reraise
    @test ev("(let (l=(mut ())) " *
             "(do (do (raise :x) (except (:x) reraise) " *
             "(finally (set! l (push (value l) :fin)))) " *
             "(except (:x) (value l))))") == "(:fin)"
    # an error raised by finally replaces the result / in-flight error
    @test_throws AirThrown air_eval(env, read_air("(do 1 (finally (raise :fin)))"))
    @test ev("(do (do (raise :boom) (finally (raise :fin))) " *
             "(except ?e e))") == "(error :fin from=(error :boom))"
    # ... but a handled error is no longer in flight
    @test ev("(do (do (raise :a) (except (:a) 1) (finally (raise :f))) " *
             "(except ?e e))") == "(error :f)"

    # ---- error chains --------------------------------------------------------
    @test ev("(do (do (raise :top) (except (:top) (raise :wrap))) " *
             "(except ?e e))") == "(error :wrap from=(error :top))"
    @test ev("(do (do (raise :top) (except (:top) (raise :wrap from=naught))) " *
             "(except ?e e))") == "(error :wrap)"
    @test ev("(do (do (raise :top) (except (:top) " *
             "(raise :wrap cause=(error :root)))) (except ?e e))") ==
        "(error :wrap cause=(error :root) from=(error :top))"
    @test ev("(do (do (raise :top) (except (:top) (raise :wrap from=(error :c)))) " *
             "(except ?e e))") == "(error :wrap from=(error :c))"
    # an exactly-raised object is unchanged (no automatic from)
    @test ev("(do (do (raise :top) (except (:top) (raise (error :x)))) " *
             "(except ?e e))") == "(error :x)"

    # showerror prints the chain
    msg = try
        air_eval(env, read_air("(do (raise :outer) (except (:outer) (raise :inner)))"))
        ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("during handling of:", msg)
    @test occursin("(error :outer)", msg)
    @test occursin("(error :inner", msg)

    # handling context is popped when the handler ends
    @test ev("(do (do (do (raise :a) (except (:a) 1)) (raise :b)) " *
             "(except ?e e))") == "(error :b)"

    # an explicit cause is printed with its own label
    msg = try
        air_eval(env, read_air(
            "(raise :save-failed cause=(error :disk-full))"))
        ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("direct cause:", msg)
    @test occursin("(error :disk-full)", msg)

    # ---- clause validation ---------------------------------------------------
    @test_throws AirEvalError air_eval(env,
        read_air("(do 1 (finally 2) (except (:x) 3))"))   # finally must be last
    @test_throws AirEvalError air_eval(env,
        read_air("(do 1 (finally 2) (finally 3))"))       # at most one
    @test_throws AirEvalError air_eval(env,
        read_air("(do 1 (except) 2)"))                    # a pattern is required
    @test_throws AirEvalError air_eval(env,
        read_air("(do 1 (except (:x) 2) (bogus 3))"))     # not a clause

    # ---- reraise is reserved -------------------------------------------------
    @test_throws AirEvalError air_eval(env, read_air("(let (reraise=1) 2)"))
    @test_throws AirDefError air_eval(env, read_air("(def (f ?reraise) 1)"))
    @test_throws AirDefError air_eval(env, read_air("(def (reraise ?x) 1)"))
    @test_throws AirDefError air_eval(env, read_air("(val reraise 1)"))
    @test_throws AirDefError air_eval(env, read_air("((?reraise -> 1) 2)"))
end
