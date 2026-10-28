@testset "pattern" begin
    m(p, s) = air_match(default_env(), Scope(), read_air(p), read_air(s), Dict{Symbol,Form}())

    # exact match and named wildcards
    @test m("(f ?x)", "(f 5)") !== nothing
    @test m("(f ?x)", "(f 5)")[:x] == Form(5)
    @test m("(f 5)", "(f 5)") !== nothing
    @test m("(f 5)", "(f 6)") === nothing
    @test m("(f ?x)", "(g 5)") === nothing
    @test m("(f ?x)", "(f 5 6)") === nothing
    @test m("(?h 10 ?h)", "(1 10 1)") !== nothing
    @test m("(?h 10 ?h)", "(1 10 2)") === nothing
    @test m("(? 10 ?)", "(1 10 2)") !== nothing

    # keywords are literal; map keys must agree
    @test m("(f :a)", "(f :a)") !== nothing
    @test m("(f :a)", "(f :b)") === nothing
    @test m("(f a=?x)", "(f a=1)") !== nothing
    @test m("(f a=?x)", "(f b=1)") === nothing

    # the sequence rest `?&`
    @test m("(f ?&r)", "(f 1 2 3)")[:r] == read_air("(1 2 3)")
    @test m("(f 1 ?&r 4)", "(f 1 2 3 4)")[:r] == read_air("(2 3)")
    @test m("(f ?&r)", "(f)") !== nothing
    @test m("(f ?&r)", "(f a=1)") === nothing          # `?&` does not capture keywords
    @test m("(f ?&)", "(f 1 2)") !== nothing

    # the keyword rest `?*`
    @test m("(f ?*k)", "(f a=1 b=2)")[:k] == read_air("(a=1 b=2)")
    @test m("(f ?*k)", "(f 1 a=2)") === nothing        # `?*` does not capture sequence
    @test m("(f ?*k)", "(f a=1)") !== nothing

    # the any rest `??`
    @test m("(f ??r)", "(f 1 2 a=3)")[:r] == read_air("(1 2 a=3)")

    # alternatives: `|` groups adjacent elements into `(alt …)`; branches are
    # tried in order, the first match wins, and a failed branch leaks no bindings
    @test m("(a | b)", "a") !== nothing
    @test m("(a | b)", "b") !== nothing
    @test m("(a | b)", "c") === nothing
    @test m("(f (a | b))", "(f b)") !== nothing
    @test m("(f (a | b | c))", "(f c)") !== nothing
    @test m("((f | g) ?x)", "(g 7)")[:x] == Form(7)
    @test m("((f | g) ?x)", "(h 7)") === nothing
    @test m("(f ((g ?x) | (h ?y)))", "(f (h 9))")[:y] == Form(9)
    @test !haskey(m("(f ((g ?x) | (h ?y)))", "(f (h 9))"), :x)
    @test m("(f (?x | ?y))", "(f 5)")[:x] == Form(5)
    @test check_anchor(read_air("((f | g) ?x)")) === nothing
    @test_throws AirDefError check_anchor(read_air("(alt ?x ?y)"))
    @test params_of(read_air("(f (?a | ?b))")) == [Symbol("a"), Symbol("b")]

    # conditions
    @test m("(f ?x \\ int?)", "(f 5)") !== nothing
    @test m("(f ?x \\ int?)", "(f \"a\")") === nothing
    @test m("(?h \\ (string? h) 10)", "(\"a\" 10)") !== nothing
    @test m("(?h \\ (string? h) 10)", "(1 10)") === nothing
    @test m("(f 5 \\ int?)", "(f 5)") !== nothing      # a condition on a literal
    @test m("(f ?x \\ int? ?&r)", "(f 3 4 5)")[:r] == read_air("(4 5)")

    # anchor validity and structural errors
    @test check_anchor(read_air("(f ?x)")) === nothing
    @test check_anchor(read_air("(?a + ?b)")) === nothing
    @test check_anchor(Form(Symbol("f"))) === nothing
    @test_throws AirDefError check_anchor(read_air("(?f ?x)"))
    @test_throws AirDefError check_anchor(read_air("(?x 1)"))
    @test_throws AirDefError check_anchor(Form(5))
    @test_throws AirDefError check_anchor(read_air("(f ?&a ?&b)"))   # two rest markers

    # params_of finds named wildcards (including rest names) in order
    @test params_of(read_air("(f ?a ?b ?a)")) == [Symbol("a"), Symbol("b")]
    @test params_of(read_air("(f ?a ?&r ?*k)")) == [Symbol("a"), Symbol("r"), Symbol("k")]

    # Mutables, actors, and promises are opaque atoms to the matcher: they match
    # only by identity (`isequal` on the AirDB id), never by their value, and the
    # matcher never descends into a mutable's value.
    penv = default_env()
    pev(s) = air_string(air_eval(penv, read_air(s)))
    @test pev("(let (m=(mut 1)) (match? m m))") == "true"
    @test pev("(let (m=(mut 1)) (let (n=(mut 1)) (match? m n)))") == "false"
    @test pev("(let (m=(mut 1)) (match? ?x m))") == "true"
    @test pev("(let (m=(mut 1)) (match? (?x) m))") == "false"
    @test pev("(let (m=(mut 1)) (match? (?x 1) m))") == "false"
    @test pev("(let (a=(actor 1)) (match? a a))") == "true"
    @test pev("(let (a=(actor 1)) (let (b=(actor 1)) (match? a b)))") == "false"
    @test pev("(let (p=(promise)) (match? p p))") == "true"
    @test pev("(let (p=(promise)) (let (q=(promise)) (match? p q)))") == "false"
    # a replace at the containing level hands the mutable through unchanged
    @test pev("(let (m=(mut 1)) (let (r=(replace (join () a=m) ((a ?x) -> x) " *
               "depth=1)) (eq? (get r :a) m)))") == "true"

    # an alternative works wherever a pattern does: replace, case, and def
    @test pev("(replace (g 7) (((f | g) ?x) -> x))") == "7"
    @test pev("(case b ((a | b) -> :sym) :other)") == ":sym"
    @test pev("(do (def (alt-f (a | b)) :hit) (alt-f b))") == ":hit"
    @test pev("(do (def (alt-f (a | b)) :hit) (alt-f c))") == "(alt-f c)"
end
