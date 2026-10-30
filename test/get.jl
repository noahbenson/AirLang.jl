@testset "get" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # extraction and dot-accessor sugar
    @test ev("(let (f=(test=10)) f.test)") == "10"
    @test ev("(let (f=(a=(b=5))) f.a.b)") == "5"
    @test ev("(let (k=:test f=(test=10)) f.~k)") == "10"   # a computed key
    @test ev("(test=10).:test") == "10"
    @test ev("(let (f=(1 2 3)) (get f 2))") == "2"

    # a scalar is its own sole element: 1 and -1 name it and 0 names the whole
    # form, so `(get 5 1)` is `5`; anything further misses
    @test ev("(get 5 1)") == "5"
    @test ev("(get 5 -1)") == "5"
    @test ev("(get 5 0)") == "5"
    @test ev("(get 5 1 1)") == "5"                    # nested: a path of sole keys
    @test ev("(get 5 2 default=9)") == "9"
    @test ev("(unhold (get 5 1 hold=true))") == "5"
    @test_throws AirEvalError air_eval(env, read_air("(get 5 2)"))
    @test_throws AirEvalError air_eval(env, read_air("(get 5 :a)"))
    # `naught` is the empty form (zero elements, as for `nth`): only `0` names it
    @test ev("(get naught 0)") == "naught"
    @test_throws AirEvalError air_eval(env, read_air("(get naught 1)"))

    # missing keys raise, unless a default is supplied
    @test_throws AirEvalError air_eval(env, read_air("(let (f=(a=1)) (get f :b))"))
    @test ev("(let (f=(a=1)) (get f :b default=9))") == "9"

    # the wildcard key `:` names every element of an ordered level; the rest of
    # the path is mapped over each one, and the result is an ordinary sequence
    @test ev("(get (1 2 3) :)") == "(1 2 3)"
    @test ev("(get ((a=1) (a=2)) : :a)") == "(1 2)"
    @test ev("(get ((a=(1 2)) (a=(3 4))) : :a 2)") == "(2 4)"
    @test ev("(get ((a=1) (a=2)) : :a hold=true)") == "(' 1 2)"
    @test ev("(get (1 2) : 0)") == "(1 2)"
    @test ev("(get 5 :)") == "(5)"
    @test ev("(get naught :)") == "naught"
    @test ev("(get (1 2 3) : default=9)") == "(1 2 3)"
    @test_throws AirEvalError air_eval(env, read_air("(get (a=1 b=2) :)"))
    @test_throws AirEvalError air_eval(env, read_air("(get ((a=1) (b=2)) : :a)"))

    # a user rule can override get for a particular form
    air_eval(env, read_air("(def (get (widget n=?n) :size) (* n 2))"))
    @test ev("(get (widget n=3) :size)") == "6"
    @test ev("(widget n=3).:size") == "6"
    @test ev("(get (a=1) :a)") == "1"
end
