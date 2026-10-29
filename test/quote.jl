# Keywords and quotes are distinct: `:x` is an inert keyword, `'x` a quoted symbol,
# and `(' …)` a quoted form. Only `~` substitutes inside a quote.
@testset "quote and unquote" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # keywords never reduce
    @test ev(":a") == ":a"
    @test ev("(unhold :a)") == ":a"
    @test_throws AirParseError read_air(":(a b)")   # the old syntax is an error

    # quoted atoms: `'x` is `(hold x)` for every `x`, so even a literal is held
    @test ev("'a") == "'a"
    @test ev("(unhold 'a)") == "a"
    @test ev("':a") == "':a"
    @test ev("'5") == "'5"

    # a quote stays quoted; only `~` substitutes at evaluation, but a `let`
    # substitutes its names textually, before the quote is evaluated
    @test ev("(' a b)") == "(' a b)"
    @test ev("(let (x=2) (' a x b))") == "(' a 2 b)"
    @test ev("(let (x=2) (' a ~x b))") == "(' a 2 b)"
    @test ev("(let (x=2) (' a ~(+ x 1) b))") == "(' a 3 b)"

    # `~` is a quasiquote hole, distinct from the runtime `(unhold x)`: an
    # explicit call is literal data inside a quote (though `let` still substitutes
    # the variable textually).
    @test ev("(let (x=2) (' a (unhold x) b))") == "(' a (unhold 2) b)"
    # `~` is `(preval x)`, so it evaluates wherever it appears, quoted or not
    @test ev("(~ 1)") == "(1)"   # `(~ 1)` is a one-element form around the hole
    @test ev("(preval (1 + 2))") == "3"

    # each quote owns its own `~`
    @test ev("(let (x=2) (' a (' b ~x)))") == "(' a (' b 2))"

    # `lift` builds the same quote explicitly
    @test ev("(let (x=2) (lift ('a x 'b)))") == "(' a 2 b)"

    # `lower` pushes the quote down
    @test ev("(lower (' a (f x) b))") == "('a (' f x) 'b)"

    # a quoted form is data: it does not evaluate
    @test ev("(' + 1 2)") == "(' + 1 2)"
    @test ev("(get (' f a b) 2)") == "f"
end
