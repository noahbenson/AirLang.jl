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
    # filesystem access is gated by the `filesystem` permission on `.air.sys`: a
    # fresh instance grants it only to `air`, so an ordinary user is denied and a
    # denied write leaves no file behind.
    @test ev("(create-user :bob)") == ":bob"
    @test_throws AirLang.AirPermissionDenied ev("(as-user :bob (read-file \"$p\"))")
    q = tempname()
    @test_throws AirLang.AirPermissionDenied ev("(as-user :bob (write-file \"$q\" \"x\"))")
    @test !isfile(q)
    src = tempname() * ".air"
    write(src, "(str \"a\" \"b\")\n")
    @test_throws AirLang.AirPermissionDenied ev("(as-user :bob (load-air \"$src\"))")
    # only air may grant the permission (it owns `.air.sys`), and a grant opens
    # every host-path helper to the user it names
    @test_throws AirLang.AirPermissionDenied ev(
        "(as-user :bob (chmod! .air.sys filesystem=(bob=true)))")
    ev("(chmod! .air.sys filesystem=(bob=true))")
    @test ev("(as-user :bob (read-file \"$p\"))") == "\"contents\""
    @test ev("(as-user :bob (load-air \"$src\"))") == "\"ab\""
    @test ev("(as-user :bob (write-file \"$q\" \"x\"))") == "naught"
    for _ in 1:200
        isfile(q) && break
        sleep(0.01)
    end
    @test isfile(q)
    # revoking the grant closes the door again
    ev("(chmod! .air.sys filesystem=(bob=false))")
    @test_throws AirLang.AirPermissionDenied ev("(as-user :bob (read-file \"$p\"))")
    rm(p; force=true)
    rm(q; force=true)
    rm(src; force=true)
end
