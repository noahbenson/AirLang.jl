@testset "pretty printing & repl" begin
    env = default_env()

    # air_pretty_string leaves a form that fits `width` on one line
    @test air_pretty_string(air_eval(env, read_air("(1 2 3)")); width = 40) == "(1 2 3)"
    @test air_pretty_string(air_eval(env, read_air("'a")); width = 40) == "'a"
    @test air_pretty_string(air_eval(env, read_air("(hold (a b c))")); width = 40) ==
        "(' (a b c))"

    # a narrow width breaks the sequence across lines and indents continuations
    x = air_eval(env, read_air("(join (1 2 3 4 5 6 7 8 9 10) (a=1 b=2))"))
    s = air_pretty_string(x; width = 20)
    lines = split(s, "\n")
    @test length(lines) > 1
    @test all(length(l) <= 20 for l in lines)
    @test startswith(lines[1], "(")
    @test all(startswith(l, " ") for l in lines[2:end])
    @test endswith(s, ")")

    # the pretty output reads back to the same form
    @test air_string(read_air(s)) == air_string(x)

    # a scalar is printed as-is regardless of width
    @test air_pretty_string(air_eval(env, read_air("(+ 1 2)")); width = 1) == "3"

    # multi-line input keeps reading under the continuation prompt
    out = IOBuffer()
    air_repl(IOBuffer("(let (x=1)\n (+ x 2))\n(4 * 5)\n"), out; env = default_env())
    text = String(take!(out))
    @test occursin("...> ", text)
    @test occursin("...> 3\n", text)
    @test occursin("20", text)

    # a block comment or string also continues
    out = IOBuffer()
    air_repl(IOBuffer("#| a\n b |# (1 + 2)\n"), out; env = default_env())
    text = String(take!(out))
    @test occursin("...> ", text)
    @test occursin("3", text)

    # input left incomplete at EOF is an error, not a crash
    out = IOBuffer()
    air_repl(IOBuffer("(1 2\n"), out; env = default_env())
    text = String(take!(out))
    @test occursin("error:", text)

    # the history file holds one flattened line per complete input
    path, io = mktemp()
    close(io)
    out = IOBuffer()
    air_repl(IOBuffer("(let (x=1)\n (+ x 2))\n(4 * 5)\n"), out;
             env = default_env(), history = path)
    hist = read(path, String)
    @test hist == "(let (x=1) (+ x 2))\n(4 * 5)\n"
    rm(path; force = true)

    # the width option reaches the printed result
    out = IOBuffer()
    air_repl(IOBuffer("(join (1 2 3 4 5 6 7 8 9 10) (a=1 b=2))\n"), out;
             env = default_env(), width = 20)
    text = String(take!(out))
    @test occursin("\n ", text)

    # pretty=false prints the flat form
    out = IOBuffer()
    air_repl(IOBuffer("(join (1 2 3 4 5 6 7 8 9 10) (a=1 b=2))\n"), out;
             env = default_env(), width = 20, pretty = false)
    text = String(take!(out))
    @test !occursin("\n ", text)
end
