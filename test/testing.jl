@testset "testing" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # `check` outside a test body is just a truth test, with nothing recorded
    @test ev("(check (== 1 1))") == "true"
    @test ev("(check (== 1 2))") == "false"
    @test_throws AirEvalError air_eval(env, read_air("(check)"))
    @test_throws AirEvalError air_eval(env, read_air("(check 1 2)"))

    # `test` reports pass/fail counts and the failing expressions (held)
    @test ev("(test \"ok\" (check (== 1 1)) (check (== 1 2)))") ==
        "(fail=1 failures=((' == 1 2)) name=\"ok\" pass=1)"
    @test ev("(test \"empty\")") == "(fail=0 failures=naught name=\"empty\" pass=0)"
    @test ev("(test \"plain\" (check false))") ==
        "(fail=1 failures=('false) name=\"plain\" pass=0)"
    @test ev("(test (+ 1 2) (check true))") == "(fail=0 failures=naught name=3 pass=1)"

    # an uncaught error is one failure and ends the body's remaining checks
    @test ev("(test \"err\" (check (== 1 1)) (raise :boom \"bad\"))") ==
        "(fail=1 failures=((' error :boom \"bad\")) name=\"err\" pass=1)"

    # a nested test keeps its own counts
    @test ev("(test \"outer\" (check true) (test \"inner\" (check false)) (check true))") ==
        "(fail=0 failures=naught name=\"outer\" pass=2)"

    @test_throws AirEvalError air_eval(env, read_air("(test)"))

    # the summary is inert data: re-evaluating it must not run a failed
    # expression again
    @test ev("(def (tf) (test \"again\" (check false)))") == "naught"
    @test ev("(tf)") == "(fail=1 failures=('false) name=\"again\" pass=0)"
    @test ev("(tf)") == "(fail=1 failures=('false) name=\"again\" pass=0)"
end
