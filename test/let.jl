@testset "let" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    @test ev("(let (a=1) a)") == "1"
    @test ev("(let (a=2 b=3) (+ a b))") == "5"
    @test ev("(let (a=1) (let (b=2) (+ a b)))") == "3"
    @test ev("(let (a=5) (do 1 2 a))") == "5"
    @test ev("(let (x=1))") == "naught"

    # the load-bearing canonicalization case
    @test ev("(let (a=(1 2)) (drop a 2))") == "(1)"

    # a let binding shadows a global rule
    air_eval(env, read_air("(def n 4)"))
    @test ev("(let (n=9) n)") == "9"
    @test ev("n") == "4"

    # A self-binding is a fixed point: replacing `db` by itself stops the
    # reducer. A one-element form is no longer the same case: `(db)` is an
    # ordinary form and stays one.
    @test ev("(let (db=db) db)") == "db"
    @test ev("(let (db=(db)) db)") == "(db)"

    # A value whose head is its own name is fine: `let` substitutes instead of
    # binding, so the inserted value is not re-resolved through a scope.
    @test ev("(let (db=(db 1)) db)") == "(db 1)"

    # Grouped bindings feed one another: earlier groups substitute into later
    # groups' value expressions; within a group the bindings stay parallel.
    @test ev("(let ((a=1 b=2) (c=(a + b))) c)") == "3"
    @test ev("(let ((a=1) (b=a) (c=b)) c)") == "1"
    @test ev("(let ((a=(1 + 1)) (b=a)) b)") == "2"
    @test ev("(let (() (a=1)) a)") == "1"
    @test ev("(let (naught (a=1)) a)") == "1"   # `()` and `naught` are the same
    @test ev("(let ((a=1 b=(a + 1))) b)") == "(a + 1)"

    # A rebound name refers to its *previous* value inside its own new value.
    @test ev("(let ((x=1) (x=(x + 2))) x)") == "3"
    @test ev("(let ((x=1) (x=x)) x)") == "1"

    # A held binding is not evaluated, but earlier groups still substitute into it;
    # `hold=` applies to every instance of the name.
    @test ev("(let ((a=1 b=2) (c=(a + b))) hold=c (hold c))") == "(' (1 + 2))"
    @test ev("(let ((a=1 b=2) (c=(a + b))) (hold c))") == "'3"

    # Mixed and malformed binding forms are rejected.
    @test_throws AirEvalError air_eval(env, read_air("(let (a=1 (b=2)) a)"))
    @test_throws AirEvalError air_eval(env, read_air("(let ((a=1) b=2) a)"))
end
