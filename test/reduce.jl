@testset "reduce" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # atoms and unbound symbols self-evaluate
    @test ev("10") == "10"
    @test ev("x") == "x"
    @test ev("(f x)") == "(f x)"

    # infix operators are canonical; prefix is sugar
    @test ev("(1 + 1)") == "2"
    @test ev("(+ 1 2 3)") == "6"
    @test ev("(- 5)") == "-5"
    @test ev("(- 5 3)") == "2"
    @test ev("(* 2 3 4)") == "24"
    @test ev("(/ 6 3)") == "2.0"
    @test ev("(== 1 1)") == "true"
    @test ev("(=== 1 1)") == "true"
    @test ev("(=== 1 1.0)") == "false"   # identity is strict about type
    @test ev("(< 1 2 3)") == "true"
    @test ev("(> 3 2 1)") == "true"
    @test ev("((1 + 2) + 3)") == "6"

    # operators are symbolic on non-numeric operands
    @test ev("(x + y)") == "(x + y)"
    @test ev("(+ x 1)") == "(x + 1)"
    @test ev("(2 * int)") == "(2 * int)"
    @test ev("(?a + ?b)") == "(?a + ?b)"
    @test ev("(naught + 1)") == "(naught + 1)"
    @test ev("(== x x)") == "true"
    @test ev("(== 1 2)") == "false"
    @test ev("(< x y)") == "(< x y)"

    # a rule anchored on an operator fires when the operands are symbolic, while
    # numeric operands still compute (the infix rule fires first)
    @test ev("(def (?x * 0) 0)") == "naught"
    @test ev("(x * 0)") == "0"
    @test ev("(1 * 0)") == "0"
    @test ev("(x + y)") == "(x + y)"

    # complex numbers: a no-space literal, and the spaced infix sum
    @test ev("4.4+2.0i") == "4.4 + 2.0i"
    @test ev("(4.4 + 2.0i)") == "4.4 + 2.0i"
    @test ev("(2i)") == "0.0 + 2.0i"

    # a symbol rule
    air_eval(env, read_air("(def n 4)"))
    @test ev("n") == "4"
    @test ev("(+ n 1)") == "5"

    # rule-first, then children
    air_eval(env, read_air("(def (inc ?x) (+ x 1))"))
    @test ev("(inc n)") == "5"
    @test ev("(inc 10)") == "11"

    # canonicalization is applied by the reducer
    @test ev("(1)") == "1"
    @test ev("()") == "naught"
    @test ev("(1 (2))") == "(1 2)"

    # the loop guard
    bad = default_env()
    air_eval(bad, read_air("(def (loop ?x) (loop (+ x 1)))"))
    @test_throws AirEvalError air_eval(bad, read_air("(loop 1)"))
end
