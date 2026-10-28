# Source positions and diagnostics: the loader records each top-level form's
# character span, a namespace entry stores its definition site as `src=`, an
# escaping error is decorated with the def site (innermost rule wins), and
# `(trace body…)` turns an error into data with its frames.
@testset "source positions" begin
    env = Env(db = MemoryDatabase())
    ev(s) = air_string(air_eval(env, read_air(s)))
    dir = mktempdir()

    # ---- the definition site of a def that errors ----------------------------
    defpath = joinpath(dir, "defs.air")
    write(defpath,
          "(def (inner ?x) (raise :oops x))\n(def (outer ?x) (inner x))\n")
    @test ev("(load-air \"$defpath\")") == "naught"

    msg = try
        ev("(inner 1)")
        ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("$defpath:1:1", msg)
    @test occursin("(def (inner ?x) (raise :oops x))", msg)

    # the innermost rule context wins
    msg = try
        ev("(outer 1)")
        ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("$defpath:1:1", msg)
    @test !occursin("(def (outer ?x)", msg)

    # an except clause still matches the original error form through the source
    # decoration
    @test ev("(do (inner 2) (except (:oops ?v) v))") == "2"

    # ---- the entry body stores `src=` ----------------------------------------
    ns = AirLang._ns_lookup(env, Symbol[Symbol("main")])
    srcs = AirLang.Form[]
    for e in AirLang._ns_entries_of(ns.vf)
        b = to_form(AirLang._entry_body(e))
        b isa AirLang.FormContainer || continue
        haskey(b, Symbol(":src")) && push!(srcs, to_form(b[Symbol(":src")]))
    end
    @test length(srcs) == 2
    src = air_string(srcs[1])
    @test occursin("name=\"$defpath\"", src)
    @test occursin("line=1", src)
    @test occursin("col=1", src)
    @test occursin("text=\"(def (inner ?x) (raise :oops x))\"", src)
    @test occursin("line=2", air_string(srcs[2]))

    # ---- a top-level form that errors ---------------------------------------
    toppath = joinpath(dir, "top.air")
    write(toppath, "(def (never ?x) x)\n(raise :top)\n")
    msg = try
        ev("(load-air \"$toppath\")")
        ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("$toppath:2:1", msg)
    @test occursin("(raise :top)", msg)

    # ---- parse errors name the file ------------------------------------------
    synpath = joinpath(dir, "syn.air")
    write(synpath, "(def (f ?x) x)\n(\n")
    @test ev("(do (load-air \"$synpath\") (except (:internal ?m) m))") ==
        "\"$synpath: unterminated form\""

    # ---- (trace body…) --------------------------------------------------------
    @test ev("(trace 1)") == "1"
    @test startswith(ev("(trace (inner 2))"), "(:trace (error :oops 2)")
    frames = ev("(get (trace (inner 2)) :frames)")
    @test occursin("name=\"$defpath\"", frames)
    @test occursin("text=\"(def (inner ?x) (raise :oops x))\"", frames)

    # a trace with no source context has no frames
    @test ev("(trace (raise :bare))") == "(:trace (error :bare) frames=())"

    # a non-air error traces as (:internal …), matching what `try` sees
    @test startswith(ev("(trace (get (1 2) 5))"), "(:trace (error :internal")
end
