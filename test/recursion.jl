@testset "recursion & composition" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # loop / recur — a tail call that does not grow the stack
    @test ev("(loop (a 0) (if (< a 10) (recur (+ a 1)) a))") == "10"
    @test ev("(loop (a 1 acc 0) (if (> a 5) acc (recur (+ a 1) (+ acc a))))") == "15"
    @test ev("(while false 1)") == "naught"

    # ---- general tail calls --------------------------------------------------
    # A call in tail position is reduced iteratively, so it does not consume the
    # nesting budget: these recursions go far past `max_depth` (2,000).
    air_eval(env, read_air("(def (count-down ?n) (if (n == 0) :done (count-down (n - 1))))"))
    @test ev("(count-down 10000)") == ":done"
    # mutual tail recursion
    air_eval(env, read_air("(def (even-tail? ?n) (if (n == 0) true (odd-tail? (n - 1))))"))
    air_eval(env, read_air("(def (odd-tail? ?n) (if (n == 0) false (even-tail? (n - 1))))"))
    @test ev("(even-tail? 10000)") == "true"
    @test ev("(even-tail? 10001)") == "false"
    # a tail call through each control form
    air_eval(env, read_air("(def (count-do ?n) (if (n == 0) :done (do :tick (count-do (n - 1)))))"))
    @test ev("(count-do 10000)") == ":done"
    air_eval(env, read_air("(def (count-let ?n) (if (n == 0) :done (let (m=(n - 1)) (count-let m))))"))
    @test ev("(count-let 10000)") == ":done"
    air_eval(env, read_air("(def (count-when ?n) (when (> n 0) (count-when (n - 1))))"))
    @test ev("(count-when 10000)") == "naught"
    air_eval(env, read_air("(def (count-unless ?n) (unless (== n 0) (count-unless (n - 1))))"))
    @test ev("(count-unless 10000)") == "naught"
    air_eval(env, read_air("(def (count-and ?n) (and true (if (n == 0) :done (count-and (n - 1)))))"))
    @test ev("(count-and 10000)") == ":done"
    # `recur` also drives a long loop, now bounded only by the step budget
    @test ev("(loop (a 0) (if (< a 10000) (recur (+ a 1)) a))") == "10000"

    # Non-tail recursion still consumes the nesting budget.
    air_eval(env, read_air("(def (sum-non-tail ?n) (if (n == 0) 0 (n + (sum-non-tail (n - 1)))))"))
    @test ev("(sum-non-tail 100)") == "5050"
    @test_throws AirEvalError air_eval(env, read_air("(sum-non-tail 5000)"))

    # A rule that reproduces its input is a fixed point, not a spin.
    air_eval(env, read_air("(def (self-rule ?x) (self-rule x))"))
    @test ev("(self-rule 5)") == "(self-rule 5)"

    # `let` substitutes before evaluating, so a lambda written in the *body* sees
    # the binding; one bound alongside it is evaluated in the enclosing scope
    @test ev("(let (n=3) ((?x -> (x + n)) 5))") == "8"
    @test ev("(let (n=3 f=(?x -> (x + n))) (f 5))") == "(5 + n)"
    # a rule application substitutes its parameters into a returned lambda, so a
    # rule can build a function
    air_eval(env, read_air("(def (make-adder ?n) (?x -> (x + n)))"))
    @test ev("((make-adder 3) 5)") == "8"

    # the `>>` pipeline substitutes `_` textually and reduces only the final form
    @test ev("(let (x=2) (x >> (_ + 1) (f _) (result=_)))") == "(result=(f 3))"
    @test ev("(1 >> (_ + _) (' _))") == "(' (1 + 1))"
    @test ev("(>> 1 (_ * 3) (_ + 1))") == "4"        # prefix sugar
    @test ev("(1 >> _)") == "1"                       # a bare placeholder
    @test_throws AirEvalError air_eval(env, read_air("(1 >> (_ + 1) 2)"))

    # `thread` distributes a form over its sequential container elements; the head
    # is not special and a nested hold is an ordinary form
    @test ev("(thread (f (1 2 3)))") == "((f 1) (f 2) (f 3))"
    @test ev("(thread (f (1 2) (3 4)))") == "((f 1 3) (f 2 4))"
    @test ev("(thread (f a b))") == "(f a b)"
    @test ev("(thread (' f (1 2 3)))") == "((' f 1) (' f 2) (' f 3))"
    @test ev("(thread (f (' a b)))") == "((f ') (f a) (f b))"
    @test ev("(thread ((1 2 3) + (2 3 4)) hold=true)") == "(' (1 + 2) (2 + 3) (3 + 4))"
    @test ev("(hold-thread (' f (1 2 3)))") == "(' (f 1) (f 2) (f 3))"
    @test ev("(hold-thread (' f (1 2 3)) hold=false)") == "((f 1) (f 2) (f 3))"
    @test_throws AirEvalError air_eval(env, read_air("(thread (f (1 2) (3 4 5)))"))

    # composition (air-level rules)
    @test ev("(identity 7)") == "7"
    @test ev("((constantly 9) 1 2 3)") == "9"
    @test ev("((comp inc inc) 5)") == "7"
    @test ev("((complement odd?) 2)") == "true"
    @test ev("((juxt inc dec) 5)") == "(6 4)"
    air_eval(env, read_air("(def (add ?a ?b) (a + b))"))
    @test ev("((part add 10) 5)") == "15"

    # `part`/`comp` HOLD their arguments: every argument is captured, not reduced
    # (so `(part add 10)` is `(part 'add '10)`), and applying the result un-holds
    # them in every position. A `~arg` argument is evaluated on the way in.
    air_eval(env, read_air("(def (scale ?x) (x * 10))"))
    @test ev("(part add 10)") == "(part 'add '10)"
    @test ev("((part scale) 5)") == "50"
    @test ev("((part add 1) 2)") == "3"
    @test ev("((part 1 +) 2)") == "3"
    @test ev("(let (g=inc) ((part map g) (1 2 3)))") == "(2 3 4)"   # un-held in arg position
    @test ev("(let (x=3) ((part add ~x) 5))") == "8"                # explicit ~ evaluates
    @test ev("((comp scale inc) 5)") == "60"
    @test ev("((comp inc inc inc) 5)") == "8"                     # n-ary comp
end
