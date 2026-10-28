@testset "canonicalize" begin
    @test isequal(canonicalize(form()), naught)
    @test isequal(canonicalize(form(10)), Form(10))
    @test isequal(canonicalize(form(form(10))), Form(10))
    @test air_string(canonicalize(form(1, 2))) == "(1 2)"
    @test air_string(canonicalize(read_air("(a=1)"))) == "(a=1)"   # a mapping is kept
    @test isequal(canonicalize(naught), naught)
    @test isequal(canonicalize(Form(5)), Form(5))

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
