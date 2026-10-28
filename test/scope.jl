# A binder inside a rule body must not be disturbed when the rule's parameters are
# in play: `let`/`loop`/`for` and a replacement rule declare their scope, so a
# parameter with the same name is shadowed rather than captured.
@testset "scope in rule bodies" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # a `loop` inside a rule body, with the loop variable shadowing the parameter
    @test ev("""
        (do (def (fact ?n) (loop (n n acc 1) (if (== n 0) acc (recur (- n 1) (* acc n)))))
            (fact 10))
    """) == "3628800"

    # `let` shadowing a parameter
    @test ev("(do (def (g ?x) (let (x=(inc 1)) (* x 10))) (g 5))") == "20"

    # in a grouped `let`, a later group sees the earlier group's binder rather
    # than a same-named rule parameter
    @test ev("(do (def (m ?a) (let ((a=1) (b=a)) b)) (m 99))") == "1"
    @test ev("(do (def (m ?a) (let ((a=1) (a=(a + 1))) a)) (m 99))") == "2"

    # a lambda pattern shadowing a parameter
    @test ev("(do (def (h ?x) ((?x -> (* x 2)) (inc x))) (h 5))") == "12"

    # a lambda is data: scope resolution must not rewrite the rule while reducing
    # the form that contains it. Here the enclosing rule binds `acc`; the lambda's
    # own `?acc` shadows it, and the outer value must not leak into the body.
    @test ev("""
        (do (def (r ?acc) (reduce ((?acc ?x) -> (acc + x)) 10 (1 2)))
            (r 100))
    """) == "13"

    # Data nested in an argument position is opaque to lexical resolution too.
    # A hold's bare names stay literal — only its own `~` holes evaluate — and a
    # RETE rule's code is not rewritten by an enclosing binding.
    @test ev("(loop (x 99) (identity (' a x)))") == "(' a x)"
    @test ev("(loop (x 99) (identity (' a ~x)))") == "(' a 99)"
    @test ev("(loop (x 99) (identity (rule (foo ?y) :> (bar x))))") ==
          "(rule (foo ?y) :> (bar x))"

    # `for` shadowing a parameter
    @test ev("(do (def (k ?n) (for (n (range n)) (* n 2))) (k 3))") == "(0 2 4)"

    # a rule body still sees the *resolved* parameter (the differentiation case).
    # Later definitions match first, so the generic rules come first and the
    # more specific shapes shadow them.
    @test ev("""
        (do (def (d ?c ?x) 0)
            (def (d ?x ?x) 1)
            (def (d (?f + ?g) ?x) ((d f x) + (d g x)))
            (def (d (?f * ?g) ?x) (((d f x) * g) + (f * (d g x))))
            (d (x * x) x))
    """) == "((1 * x) + (x * 1))"
end
