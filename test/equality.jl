# `same?` (identity), `eq?` (equivalence), `==` (content equality), and `hash`,
# which follows `eq?`. The distinction matters for memoization keys and any
# equivalence-keyed table: `eq?` separates `1` from `1.0` while `==` does not,
# and map order never matters.
@testset "equality and hashing" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- identity and equivalence -------------------------------------------
    @test ev("(same? 1 1)") == "true"
    @test ev("(let (m=(mut 1)) (same? m m))") == "true"
    @test ev("(same? (mut 1) (mut 1))") == "false"
    @test ev("(let (p=(task 1)) (same? p p))") == "true"

    @test ev("(eq? 1 1)") == "true"
    # equivalence is type-sensitive: `==` is content equality
    @test ev("(eq? 1 1.0)") == "false"
    @test ev("(== 1 1.0)") == "true"
    @test ev("(eq? 1 true)") == "false"
    @test ev("(eq? naught ())") == "true"
    @test ev("(eq? \"a\" \"a\")") == "true"
    @test ev("(eq? :a :a)") == "true"
    @test ev("(eq? 'a :a)") == "false"
    @test ev("(eq? (name 'a) 'a)") == "false"
    # an extern follows its own `isequal`: two promises differ, an equal regex
    # value does not
    @test ev("(eq? (task 1) (task 1))") == "false"
    @test ev("(eq? (regex \"a\") (regex \"a\"))") == "true"
    @test ev("(let (r=(regex \"a\")) (eq? r r))") == "true"

    # ---- containers ----------------------------------------------------------
    @test ev("(eq? (a (1 2) x=3) (a (1 2) x=3))") == "true"
    @test ev("(eq? (a (1 2) x=3) (a (1 2) x=4))") == "false"
    @test ev("(eq? (a (1 2) x=3) (a (1 3) x=3))") == "false"
    @test ev("(eq? (a x=1 y=2) (a y=2 x=1))") == "true"
    @test ev("(eq? (a x=1) (a x=1.0))") == "false"
    @test ev("(eq? (a x=1) (a y=1))") == "false"
    @test ev("(eq? (a x=(1 2)) (a x=(1 2)))") == "true"
    @test ev("(eq? (a (1 2)) (a (1 2) b=3))") == "false"
    # a mutable inside an immutable form contributes only its identity, so such
    # forms are comparable (and hashable) even though they contain a mutable
    @test ev("(eq? (a (mut 1)) (a (mut 1)))") == "false"
    @test ev("(let (m=(mut 1)) (eq? (a m) (a m)))") == "true"
    @test ev("(let (m=(mut 1) n=(mut 1)) (eq? (a m) (a n)))") == "false"
    @test ev("(eq? (' a b) (' a b))") == "true"

    # ---- hash agrees with eq? ------------------------------------------------
    @test ev("(eq? (hash (a x=1 y=2)) (hash (a x=1 y=2)))") == "true"
    @test ev("(eq? (hash (a x=1 y=2)) (hash (a y=2 x=1)))") == "true"
    @test ev("(eq? (hash (a (1 (b x=2)))) (hash (a (1 (b x=2)))))") == "true"
    @test ev("(let (x=5) (eq? (hash (a x)) (hash (a 5))))") == "true"
    # a hash never descends into a mutable: identity is all it contributes
    @test ev("(let (m=(mut 1)) (eq? (hash (a m)) (hash (a m))))") == "true"
    @test ev("(eq? (hash (mut 1)) (hash (mut 1)))") == "false"
    @test ev("(let (m=(mut 1)) (eq? (hash m) (hash m)))") == "true"
    @test ev("(eq? (hash 1) (hash 1))") == "true"
    @test ev("(eq? (hash \"a\") (hash \"a\"))") == "true"

    # ---- equivalence-keyed tables -------------------------------------------
    d = Dict{AirLang._EqKey,Int}()
    d[AirLang._EqKey(read_air("(a x=1 y=2)"))] = 1
    @test d[AirLang._EqKey(read_air("(a y=2 x=1)"))] == 1
    @test length(d) == 1
    d[AirLang._EqKey(read_air("(a x=1.0 y=2)"))] = 2
    @test length(d) == 2
    @test d[AirLang._EqKey(read_air("(a x=1.0 y=2)"))] == 2
    # a key containing a volatile is hashable: the mutable part is its id
    m = air_eval(env, read_air("(mut 5)"))
    raw = read_air("(a b)")
    key = AirLang.FormContainer(
        AirLang.FormSeq(AirLang.FormValue[AirLang.to_form(raw.seq[1]), m]), raw.map)
    d[AirLang._EqKey(key)] = 3
    @test d[AirLang._EqKey(key)] == 3
    # `_eq` directly distinguishes the types `isequal` would merge
    @test !AirLang._eq(to_form(1), to_form(1.0))
    @test AirLang._eq(to_form(1), to_form(1))
end
