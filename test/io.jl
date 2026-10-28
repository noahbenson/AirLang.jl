@testset "io" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # `str` concatenates; strings print unquoted, other forms as air source
    @test ev("(str \"a\" 1 \"b\")") == "\"a1b\""
    @test ev("(str (1 2) \"x\")") == "\"(1 2)x\""

    # `print` / `println` write through `airout` and return `naught`
    @test ev("(print \"x\")") == "naught"
    @test ev("(println \"x\")") == "naught"

    # file writes are actor-backed; wait for the write to land, then read it back
    p = tempname()
    @test ev("(write-file \"$p\" \"contents\")") == "naught"
    for _ in 1:200
        isfile(p) && break
        sleep(0.01)
    end
    @test isfile(p)
    @test ev("(read-file \"$p\")") == "\"contents\""
    rm(p; force=true)
end
