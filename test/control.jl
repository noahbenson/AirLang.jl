@testset "control & functions" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # and / or / not / xor
    @test ev("(and true 1 2)") == "2"
    @test ev("(and true false 2)") == "false"
    @test ev("(and)") == "true"
    @test ev("(or naught false 5)") == "5"
    @test ev("(or naught false)") == "false"
    # the prefix forms short-circuit like the infix ones
    @test ev("(and false (raise :boom))") == "false"
    @test ev("(or true (raise :boom))") == "true"
    @test ev("(not true)") == "false"
    @test ev("(not naught)") == "true"
    @test ev("(xor true false)") == "true"
    @test ev("(xor true true)") == "false"

    # when / unless
    @test ev("(when true 1 2)") == "2"
    @test ev("(when false 1)") == "naught"
    @test ev("(unless false 1 2)") == "2"
    @test ev("(unless true 1)") == "naught"

    # a replacement rule in head position is a function
    @test ev("((?x -> (x ^ 2)) 2)") == "4"
    @test ev("(let (f=(?x -> (x ^ 2))) (f 3))") == "9"
    @test ev("(((?a ?b \\ int? ?&) -> (a * b)) 1 2 3)") == "2"
    @test !occursin("^ 2", ev("((?x -> (x ^ 2)) 2)"))       # it applied
    @test occursin("->", ev("(((?a ?b \\ int? ?&) -> (a * b)) 1 :a 3)"))  # no match: unreduced

    # `_` is bound to a hold of every argument
    @test ev("((?x -> _) 5)") == "'5"
    @test ev("(((?a ?b) -> _) 5 6)") == "(' 5 6)"
    @test ev("((?x -> _) (a b))") == "(' (a b))"
    @test ev("(let (a=5) ((?x -> _) a))") == "'5"

    # repetition: nest / nest-list / nest-while
    @test ev("(nest (?x -> (2 * x)) 5 1)") == "32"
    @test ev("(nest inc 0 1)") == "1"
    @test ev("(nest-list (?x -> (2 * x)) 3 1)") == "(1 2 4 8)"
    @test ev("(nest-list inc 0 1)") == "1"
    @test ev("(nest-while (?x -> (x // 2)) even? 8)") == "1"
    @test ev("(nest-while (?x -> (x // 2)) even? 7)") == "7"   # pred fails first
    @test ev("(nest-while (?x -> (x // 2)) even? 8 list=true)") == "(8 4 2 1)"
    @test_throws AirEvalError air_eval(env, read_air("(nest inc -1 1)"))
    @test_throws AirEvalError air_eval(env, read_air("(nest inc 1.5 1)"))
    @test_throws AirEvalError air_eval(env, read_air("(nest-list inc -1 1)"))
    @test_throws AirEvalError air_eval(env, read_air(
        "(nest-while inc even? 1 bogus=1)"))
    # a predicate that never fails is stopped by the reduction budget
    bounded = Env(max_steps = 1_000)
    @test_throws AirEvalError air_eval(bounded, read_air(
        "(nest-while inc int? 1)"))

    # higher-order functions
    @test ev("(map (?x -> (* x 2)) (1 2 3))") == "(2 4 6)"
    @test ev("(map inc (a=1))") == "(a=2)"
    @test ev("(filter odd? (1 2 3 4))") == "(1 3)"
    @test ev("(remove odd? (1 2 3 4))") == "(2 4)"
    @test ev("(reduce + 0 (1 2 3))") == "6"
    @test ev("(fold + 0 (1 2 3))") == "6"
    @test ev("(mapcat (?x -> (x x)) (1 2))") == "(1 1 2 2)"
    @test ev("(apply join ((1 2) (3 4)))") == "(1 2 3 4)"

    # for
    @test ev("(for (x (1 2 3)) x)") == "(1 2 3)"
    @test ev("(for (x (1 2 3) :if (odd? x)) (* x 10))") == "(10 30)"
    @test ev("(for (x (1 2) y (10 20)) (+ x y))") == "(11 21 12 22)"
    @test ev("(for (x (1 2) :let y (* x 10)) y)") == "(10 20)"

    # case — pattern dispatch, first matching clause wins; `_` is the subject
    @test ev("(case 5 ((?n \\ integer?) -> (n * 2)) ((?a ?b) -> (a + b)) :other)") == "10"
    @test ev("(case (a b) ((?n \\ integer?) -> (n * 2)) ((?a ?b) -> (a + b)) :other)") == "(a + b)"
    @test ev("(case :z ((?n \\ integer?) -> (n * 2)) :other)") == ":other"
    @test ev("(case :z ((?n \\ integer?) -> (n * 2)))") == "naught"
    @test ev("(case (abc 1) ((? \\ symbol? 1) -> (row=_)))") == "(row=(abc 1))"
    @test ev("(case (1 1) ((? \\ symbol? 1) -> (row=_)) :no)") == ":no"
    @test ev("(select 2 ((?n \\ integer?) -> (n + 1)))") == "3"

    # doseq / dotimes — for their effect; both return naught
    @test ev("(doseq (x (1 2 3)) x)") == "naught"
    @test ev("(dotimes (i 3) i)") == "naught"
    @test ev("(do (dotimes (i 3) (if (== i 2) (raise :done))) (except (:done) :ok))") == ":ok"
    @test ev("(do (doseq (x (1 2)) (if (== x 2) (raise :done))) (except (:done) :ok))") == ":ok"

    # memoize — a callable that caches by function and arguments
    @test ev("((memoize inc) 3)") == "4"
    @test ev("(let (g=(memoize inc)) (g 3))") == "4"
    @test ev("(map (memoize inc) (1 2))") == "(2 3)"

    # eval — evaluate a form as data
    @test ev("(eval (' 1 + 2))") == "3"
    @test ev("(eval (' inc 4))") == "5"
    @test ev("(eval (if true (' inc 1) (' dec 1)))") == "2"
end
