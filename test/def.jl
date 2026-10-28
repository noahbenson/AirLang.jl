@testset "def" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    air_eval(env, read_air(
        "(def (fib ?n) (if (== n 0) 1 (== n 1) 1 (+ (fib (- n 1)) (fib (- n 2)))))"))
    @test ev("(fib 0)") == "1"
    @test ev("(fib 1)") == "1"
    @test ev("(fib 5)") == "8"
    @test ev("(fib 10)") == "89"

    # an infix rule defined by the user, anchored by a non-head symbol
    air_eval(env, read_air("(def (?a contains ?b) (in b a))"))
    @test ev("((1 2 3) contains 2)") == "true"
    @test ev("((1 2 3) contains 9)") == "false"

    # match? / matches / replace
    @test ev("(match? (f ?x) (f 5))") == "true"
    @test ev("(match? (f ?x) (g 5))") == "false"
    @test ev("(matches (f ?x) (f 5))") == "(x=5)"
    @test ev("(replace (1 2 3) ((?a ?b ?c) -> (?c ?b ?a)))") == "(3 2 1)"
    @test ev("(replace (1 2 3) ((?a ?b) -> 0))") == "(1 2 3)"

    # redefinition replaces in place
    air_eval(env, read_air("(def (fib ?n) 0)"))
    @test ev("(fib 5)") == "0"

    # anchor errors
    @test_throws AirDefError air_eval(env, read_air("(def (?f ?x) x)"))
end
