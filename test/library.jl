# Loading air source from files and libraries: `load-air` is parse-first and
# atomic, nested relative loads resolve against the loading file, `AIR_LIBPATH`
# finds `<name>/init.air`, and a library loads lazily under `.lib.<name>` (also
# from a bare `import`/`using`) as `air`, leaving nothing behind on failure.
@testset "loading and libraries" begin
    env = Env(db = MemoryDatabase())
    ev(s) = air_string(air_eval(env, read_air(s)))

    dir = mktempdir()
    mkdir(joinpath(dir, "sub"))
    write(joinpath(dir, "sub", "inner.air"), "(def (rel ?x) (+ x 100))\n")
    write(joinpath(dir, "main.air"),
          "(def (top ?x) (* x 2))\n(load-air \"sub/inner.air\")\n")
    write(joinpath(dir, "value.air"), "(def (last-val ?x) x)\n42\n")
    write(joinpath(dir, "syntax.air"), "(def (parsed ?x) x)\n(\n")
    write(joinpath(dir, "runtime.air"),
          "(def (atomic ?x) (+ x 1))\n(def (partial ?x) x)\n(raise :boom)\n")

    # ---- load-air: relative nested loads and the last value ------------------
    @test ev("(load-air \"$(joinpath(dir, "main.air"))\")") == "naught"
    @test ev("(top 3)") == "6"
    @test ev("(rel 1)") == "101"
    @test ev("(load-air \"$(joinpath(dir, "value.air"))\")") == "42"
    # several paths: all parsed first, then evaluated in order
    @test ev("(load-air \"$(joinpath(dir, "value.air"))\" " *
             "\"$(joinpath(dir, "main.air"))\")") == "naught"
    # the system view exposes the same function
    @test ev("(.air.sys.load-air \"$(joinpath(dir, "value.air"))\")") == "42"

    # ---- parse-first: nothing is evaluated when a later form is malformed -----
    @test ev("(do (load-air \"$(joinpath(dir, "syntax.air"))\") " *
             "(except ?e :parse-error))") == ":parse-error"
    @test ev("(do (get . :main :parsed) (except ?e :gone))") == ":gone"

    # ---- atomic failure: a runtime error rolls back earlier forms ------------
    @test ev("(do (load-air \"$(joinpath(dir, "runtime.air"))\") " *
             "(except ?e :failed))") == ":failed"
    @test ev("(do (get . :main :atomic) (except ?e :gone))") == ":gone"
    @test ev("(do (get . :main :partial) (except ?e :gone))") == ":gone"

    # ---- libraries -----------------------------------------------------------
    libroot = mktempdir()
    other = mktempdir()
    mkdir(joinpath(libroot, "math"))
    write(joinpath(libroot, "math", "init.air"),
          "(def (twice ?x) (* x 2))\n(val note (read-file \"note.txt\"))\n")
    write(joinpath(libroot, "math", "note.txt"), "hello")
    mkdir(joinpath(libroot, "explicit"))
    write(joinpath(libroot, "explicit", "init.air"),
          "(namespace .lib.explicit (def (ee ?x) (+ x 1)))\n")
    mkdir(joinpath(libroot, "bad"))
    write(joinpath(libroot, "bad", "init.air"),
          "(def (half ?x) (/ x 2))\n(raise :badlib)\n")
    mkdir(joinpath(libroot, "bare"))
    write(joinpath(libroot, "bare", "init.air"), "(def (triple ?x) (* x 3))\n")
    for (root, which) in ((libroot, "first"), (other, "second"))
        mkdir(joinpath(root, "pick"))
        write(joinpath(root, "pick", "init.air"), "(def (which) :$which)\n")
    end
    old = get(ENV, "AIR_LIBPATH", nothing)
    ENV["AIR_LIBPATH"] = libroot * ":" * other
    try
        # a reference loads the library into `.lib.<name>`
        @test ev("(.lib.math.twice 4)") == "8"
        @test ev("(do (get .lib :math) (except ?e :gone))") != ":gone"
        # the init.air body is implicitly in `.lib.math` ...
        @test ev("(using .lib.math (twice 3))") == "6"
        # ... and a relative file path resolves against the library directory
        @test ev("(using .lib.math note)") == "\"hello\""
        # ... and may spell the namespace itself
        @test ev("(.lib.explicit.ee 1)") == "2"
        # the first search directory wins
        @test ev("(using pick (which))") == ":first"
        # a bare `import` and a bare `using` also load the library
        @test ev("(namespace .lb (import bare))") == "naught"
        @test ev("(.lb.triple 3)") == "9"
        @test ev("(using bare (triple 5))") == "15"
        # a failing library leaves nothing registered
        @test ev("(do (.lib.bad.half 4) (except ?e :badlib))") == ":badlib"
        @test ev("(do (get .lib :bad) (except ?e :gone))") == ":gone"
        # a non-air user may trigger a load; it runs as air
        @test ev("(create-user :bob)") == ":bob"
        mkdir(joinpath(libroot, "boblib"))
        write(joinpath(libroot, "boblib", "init.air"),
              "(def (six ?x) (* x 6))\n")
        @test ev("(as-user :bob (.lib.boblib.six 2))") == "12"
        # a missing library is reported as a missing namespace
        @test ev("(do (import nosuchlib) (except ?e :nope))") == ":nope"
    finally
        old === nothing ? delete!(ENV, "AIR_LIBPATH") : (ENV["AIR_LIBPATH"] = old)
    end
end

# The command line goes through the same loader: a file is parse-first and
# atomic, `-e` evaluates its forms the same way, and both report a failure as a
# nonzero exit code.
@testset "air command line loading" begin
    dir = mktempdir()
    good = joinpath(dir, "good.air")
    write(good, "(def (cli-f ?x) (+ x 1))\n(load-air \"$(joinpath(dir, "value.air"))\")\n")
    write(joinpath(dir, "value.air"), "7\n")
    bad = joinpath(dir, "bad.air")
    write(bad, "(def (cli-g ?x) x)\n(\n")

    @test air_main([good]) == 0
    @test air_main(["-e", "(+ 1 2)"]) == 0
    @test air_main(["-e", "("]) == 1
    @test air_main([bad]) == 1
    @test air_main([joinpath(dir, "missing.air")]) == 1
end
