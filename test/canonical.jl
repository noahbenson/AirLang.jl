@testset "canonicalize" begin
    # canonicalization unifies only the empty container with `naught`; it never
    # changes the shape of a one-element form
    @test isequal(canonicalize(form()), naught)
    @test isequal(canonicalize(form(10)), form(10))
    @test isequal(canonicalize(form(form(10))), form(form(10)))
    @test air_string(canonicalize(form(10))) == "(10)"
    @test air_string(canonicalize(form(form(10)))) == "((10))"
    @test air_string(canonicalize(form(1, 2))) == "(1 2)"
    @test air_string(canonicalize(read_air("(a=1)"))) == "(a=1)"   # a mapping is kept
    @test isequal(canonicalize(naught), naught)
    @test isequal(canonicalize(Form(5)), Form(5))

    # `()` and `naught` are the same value at any depth, so no empty container
    # survives construction
    has_empty_container(x::Form) =
        x isa FormContainer &&
        ((isempty(x.seq) && isempty(x.map)) ||
         any(v -> has_empty_container(AirLang.to_form(v)), x.seq) ||
         any(p -> has_empty_container(AirLang.to_form(p[2])), x.map))
    for src in ("()", "naught", "(a ())", "(a (() ()))", "(' ())", "(' a ())",
                "(a=())", "(f (g) ())", "((a ()))")
        x = read_air(src)
        @test !has_empty_container(x)
        @test !has_empty_container(canonicalize(x))
    end
    @test read_air("()") === naught
    @test read_air("naught") === naught
    @test isequal(read_air("(a ())"), read_air("(a naught)"))
    @test read_air("(a ())").seq[2] === nothing
    # ingress normalization for forms built outside the reader
    raw = AirLang.FormContainer(
        AirLang.FormSeq(AirLang.FormValue[AirLang.Form(:a),
                                          AirLang.FormContainer(
                                              AirLang.FormSeq(AirLang.FormValue[]),
                                              AirLang.FormMap())]),
        AirLang.FormMap())
    @test !has_empty_container(AirLang._normalize_empty(raw))
    @test AirLang._normalize_empty(raw).seq[2] === nothing
    # JSON ingress is normalized too: `[seq, map]` is a container, so `[]` in
    # either slot is `naught` at any depth
    env = default_env()
    @test air_string(air_eval(env, read_air("(from-json \"[[], {}]\")"))) ==
          "naught"
    jx = air_eval(env, read_air("(from-json \"[[[[], {}]], {}]\")"))
    @test !has_empty_container(jx)
    @test jx.seq[1] === nothing
    @test air_string(air_eval(env, read_air(
        "(same? (get (from-json \"[[[[], {}]], {}]\") 1) naught)"))) == "true"
    # builtin-constructed values never embed an empty container
    for src in ("(with (a b) 1 ())", "(push () ())", "(join () a=())",
                "(cases (1 () 2) ())")
        @test !has_empty_container(air_eval(env, read_air(src)))
    end
    air_eval(env, read_air("(namespace .ee (val v 1))"))
    @test !has_empty_container(air_eval(env, read_air("(get . :ee)")))

    @test truthy(Form(false)) == false
    @test truthy(naught) == false
    @test truthy(form()) == false
    @test truthy(Form(0)) == true
    @test truthy(Form("")) == true
    @test truthy(form(1, 2)) == true

    # raw_symbols collects symbols anywhere, for the anchor index
    @test sort(raw_symbols(read_air("(1 + 1)"))) == [Symbol("+")]
    @test sort(raw_symbols(read_air("(f (g ?x) a=h)"))) == [Symbol("f"), Symbol("g"), Symbol("h")]
    @test raw_symbols(read_air("(?a + ?b)")) == [Symbol("+")]
end
