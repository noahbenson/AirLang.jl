@testset "replace" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # the whole-form `replace`, first matching rule wins; a rule is
    # `(pattern -> replacement)`, which is inert data
    @test ev("(replace 10 ((?int \\ integer?) -> (2 * int)))") == "20"
    @test ev("(replace 3 (?int -> (2 * int)))") == "6"
    @test ev("(replace (1 2 3) ((?a ?b ?c) -> (?c ?b ?a)))") == "(3 2 1)"
    @test ev("(replace (1 2 3) ((?a ?b) -> 0))") == "(1 2 3)"   # no match -> subject
    @test ev("((?a ?b) -> 0)") == "((?a ?b) -> 0)"
    @test ev("(a -> (1 + 2))") == "(a -> (1 + 2))"

    # `unhold=true` inserts the replacement unheld, so it is evaluated
    @test ev("(replace x (x -> (' 1 + 2)))") == "(' 1 + 2)"
    @test ev("(replace x (x -> (' 1 + 2) unhold=true))") == "3"
    @test ev("(replace x (x -> (' 1 + b) unhold=true))") == "(1 + b)"
    @test ev("(replace x (x -> (1 + 2) unhold=false))") == "3"

    # a guard restricts a rule
    @test ev("(replace \"hi\" ((?h \\ string?) -> 0))") == "0"
    @test ev("(replace 5 ((?h \\ string?) -> 0))") == "5"

    # replace-all walks, deepest first
    @test ev("(replace-all (1 (2 3) 4) ((?x \\ int?) -> (10 * x)))") == "(10 (20 30) 40)"

    # repeated replacement to a fixed point
    @test ev("(rreplace (wrap (wrap x)) ((wrap ?x) -> x))") == "x"
    @test ev("(rreplace-all (wrap (wrap x)) ((wrap ?x) -> x))") == "x"

    # depth= selects the level the rules operate on; 0 (the default for
    # replace/rreplace) is the subject itself, 1 its elements (sequence and map
    # values), and so on, with the structure above the level rebuilt
    @test ev("(replace ((a 1) (a 2)) ((a ?x) -> x))") == "((a 1) (a 2))"
    @test ev("(replace ((a 1) (a 2)) ((a ?x) -> x) depth=1)") == "(1 2)"
    @test ev("(replace ((a 1) (a 2)) ((a ?x) -> x) depth=2)") == "((a 1) (a 2))"
    @test ev("(replace (x=(a 1) y=2) ((?v \\ number?) -> (inc v)) depth=1)") ==
          "(x=(a 1) y=3)"

    # replace-all with no depth is the whole tree; depth=n is exactly that level
    @test ev("(replace-all (a (a 1)) ((a ?x) -> x))") == "1"
    @test ev("(replace-all (a (a 1)) ((a ?x) -> x) depth=0)") == "(a 1)"
    @test ev("(replace-all (a (a 1)) ((a ?x) -> x) depth=1)") == "(a 1)"
    @test ev("(replace-all (a (a 1)) ((a ?x) -> x) depth=2)") == "(a (a 1))"

    # rreplace at a level: the rule must reach a fixed point there
    @test ev("(rreplace (6 7 2) ((?x \\ (>= x 5)) -> 5) depth=1)") == "(5 5 2)"
    @test ev("(rreplace ((a 1) (a 2)) ((a ?x) -> x) depth=1)") == "(1 2)"

    # options are validated
    @test_throws AirEvalError air_eval(env, read_air(
        "(replace 1 (1 -> 0) depth=(0 - 1))"))
    @test_throws AirEvalError air_eval(env, read_air(
        "(replace 1 (1 -> 0) bogus=1)"))

    # The replace family rewrites a quoted form's content structurally, but the
    # result stays held, so the replacement is not evaluated.
    @test ev("(replace-all (' a (1 + 1) b) ((?x + ?y) -> (2 * 3)))") == "(' a (2 * 3) b)"
    @test ev("(replace-all (a b c) ((? ? ?) -> (1 + 1)))") == "2"

    # the splat
    @test ev("(f a... b)") == "(f a b)"
    @test ev("(1 2... 3)") == "(1 2 3)"
    @test ev("(1 (2 (3 4)...) 5)") == "(1 (2 3 4) 5)"
    @test ev("((1 a=2 b=3)... 4)") == "(1 4 a=2 b=3)"
    @test ev("(let (a=(1 2)) (f a... 3))") == "(f 1 2 3)"
    @test ev("(let (a=naught) (f a... 3))") == "(f 3)"
    # a `~` hole's value splices too: `~(expr)...` evaluates `expr` and inserts
    # the sequence, and the same holds for a held map value.
    @test ev("(f ~(1 2 3)...)") == "(f 1 2 3)"
    @test ev("(let (a=(1 2)) (f ~a... 3))") == "(f 1 2 3)"
    @test ev("(f ~(a=1 b=2)... 3)") == "(f 3 a=1 b=2)"
    @test ev("(f ~(1 + 2)...)") == "(f 3)"
end
