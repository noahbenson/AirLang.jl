@testset "api" begin
    @test air_string(air_eval("(1 + 1)")) == "2"
    @test air_string(air_eval("(push 1 2)")) == "(1 2)"
    @test air_string(air_eval(read_air("(* 3 4)"))) == "12"

    env = Env()
    @test air_string(air_eval(env, "(def (sq ?x) (* x x))")) == "naught"
    @test air_string(air_eval(env, "(sq 7)")) == "49"

    # the repl reads several forms per line and recovers from errors
    io = IOBuffer()
    air_repl(IOBuffer("(1 + 1)\n(2 * 3)\n(bogus\n(3 + 3)\n"), io)
    out = String(take!(io))
    @test occursin("2", out)
    @test occursin("6", out)
    @test occursin("error:", out)
    @test occursin("air> ", out)
end
