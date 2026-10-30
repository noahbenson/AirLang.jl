# Layouts declare how a form breaks across lines when it does not fit the print
# width. A declaration is `(layout PATTERN head=N indent=M map=inline|block)`;
# the pattern is matched structurally (wildcards, no conditions), and the newest
# matching user declaration wins, then the built-in defaults, then the generic
# greedy layout. The flat `air_string` is never affected.
@testset "layouts" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    fit(s, w) = all(textwidth(l) <= w for l in split(s, "\n"))

    # ---- the default `def` layout: head=2, indent=2, map=block --------------
    x = read_air("(def (long-name ?x ?y) (alpha 1) (beta 2) (gamma 3) (delta 4))")
    # a form that fits the width keeps its one-line spelling
    @test air_pretty_string(x; width = 80) ==
          "(def (long-name ?x ?y) (alpha 1) (beta 2) (gamma 3) (delta 4))"
    # narrowing it pins `def` and the pattern to the opening line and indents
    # the body by two past the "("
    @test air_pretty_string(x; width = 40) ==
          "(def (long-name ?x ?y) (alpha 1)\n  (beta 2) (gamma 3) (delta 4))"
    @test air_pretty_string(x; width = 30) ==
          "(def (long-name ?x ?y)\n  (alpha 1) (beta 2)\n  (gamma 3) (delta 4))"
    for w in (20, 25, 30, 40, 60)
        s = air_pretty_string(x; width = w)
        @test fit(s, w)
        @test air_string(read_air(s)) == air_string(x)
    end

    # `map=block` puts each map entry on its own line
    y = read_air("(def (g ?x) memoize=true tx=false (* x 2))")
    @test air_pretty_string(y; width = 30) ==
          "(def (g ?x) (* x 2)\n  memoize=true\n  tx=false)"
    @test air_string(read_air(air_pretty_string(y; width = 30))) == air_string(y)

    # a head with no declaration falls back to the generic layout: one pinned
    # element and a one-column continuation indent
    z = read_air("(foo (alpha 1) (beta 2) (gamma 3) (delta 4))")
    @test air_pretty_string(z; width = 22) ==
          "(foo (alpha 1)\n (beta 2) (gamma 3)\n (delta 4))"
    @test air_pretty_string(z; width = 80) ==
          "(foo (alpha 1) (beta 2) (gamma 3) (delta 4))"
    # a nested form inside a pinned head uses the generic layout at its own column
    @test air_pretty_string(x; width = 20) ==
          "(def (long-name ?x\n      ?y) (alpha 1)\n  (beta 2)\n  (gamma 3)\n  (delta 4))"

    # ---- `indent=align` ------------------------------------------------------
    @test ev("(layout (al ?a ?&rest) head=2 indent=align)") == "naught"
    a = read_air("(al shortone (alpha 1) (beta 2) (gamma 3) (delta 4))")
    @test air_pretty_string(a; width = 30) ==
          "(al shortone (alpha 1)\n    (beta 2) (gamma 3)\n    (delta 4))"

    # ---- `(layouts)`, `(clear-layout …)`, and `(reset-layouts)` --------------
    @test occursin("(layout (al ?a ?&rest) head=2 indent=align map=inline)",
                   ev("(layouts)"))
    @test ev("(clear-layout :al)") == "naught"
    @test !occursin("(al ?a", ev("(layouts)"))
    # the defaults survive a clear
    @test air_pretty_string(x; width = 40) ==
          "(def (long-name ?x ?y) (alpha 1)\n  (beta 2) (gamma 3) (delta 4))"
    # re-registering the same pattern replaces its declaration
    @test ev("(layout (rep ?&rest) head=1)") == "naught"
    @test ev("(layout (rep ?&rest) head=2 indent=4 map=block)") == "naught"
    decls = ev("(layouts)")
    @test length(collect(eachmatch(r"\(layout \(rep", decls))) == 1
    @test occursin("head=2 indent=4 map=block", decls)
    w = read_air("(rep a=1 (bbb 2) (ccc 3) (ddd 4) (eee 5))")
    @test air_pretty_string(w; width = 25) ==
          "(rep (bbb 2) (ccc 3)\n    (ddd 4) (eee 5)\n    a=1)"
    @test ev("(reset-layouts)") == "naught"
    @test ev("(layouts)") == "(')"

    # ---- a declaration is process-global, not a definition -------------------
    # a sandbox discards database writes, but a layout is not one
    @test ev("(sandbox (layout (sbx ?a ?&rest) head=3))") == "naught"
    @test occursin("(layout (sbx", ev("(layouts)"))
    @test ev("(clear-layout :all)") == "naught"
    @test ev("(layouts)") == "(')"
    @test air_pretty_string(x; width = 40) ==
          "(def (long-name ?x ?y) (alpha 1)\n  (beta 2) (gamma 3) (delta 4))"

    # ---- a declaration is validated -----------------------------------------
    @test ev(raw"(do (layout :bad) (except ?e :caught))") == ":caught"
    @test ev(raw"(do (layout (?x ?&r)) (except ?e :caught))") == ":caught"
    @test ev(raw"(do (layout (:kw ?&r)) (except ?e :caught))") == ":caught"
    @test ev(raw"(do (layout (h ?&r x)) (except ?e :caught))") == ":caught"
    @test ev(raw"(do (layout (h ?x a=1)) (except ?e :caught))") == ":caught"
    @test ev(raw"(do (layout (h ?x (\ even?))) (except ?e :caught))") == ":caught"
    @test ev(raw"(do (layout (h ?x) head=(- 1)) (except ?e :caught))") == ":caught"
    @test ev(raw"(do (layout (h ?x) indent=sometimes) (except ?e :caught))") == ":caught"
    @test ev(raw"(do (layout (h ?x) map=sideways) (except ?e :caught))") == ":caught"
    @test ev(raw"(do (layout (h ?x) bogus=1) (except ?e :caught))") == ":caught"
    @test ev("(layouts)") == "(')"

    # ---- shape selects the layout, not the evaluated arguments ---------------
    # a wildcard pattern matches a form whose second element is any form
    @test ev("(layout (shape ?kind ?&rest) head=2 indent=3)") == "naught"
    s1 = read_air("(shape (thing 1) (aaa 2) (bbb 3) (ccc 4) (ddd 5))")
    @test air_pretty_string(s1; width = 24) ==
          "(shape (thing 1)\n   (aaa 2) (bbb 3)\n   (ccc 4) (ddd 5))"
    @test ev("(reset-layouts)") == "naught"

    # ---- `form->string` -----------------------------------------------------
    @test ev("(namespace .lay (val v (foo (alpha 1) (beta 2) (gamma 3) (delta 4))))") ==
          "naught"
    # the default is the flat spelling
    @test ev("(form->string .lay.v)") ==
          "\"(foo (alpha 1) (beta 2) (gamma 3) (delta 4))\""
    @test ev("(form->string .lay.v pretty=true)") ==
          "\"(foo (alpha 1) (beta 2) (gamma 3) (delta 4))\""
    @test ev("(form->string .lay.v pretty=true width=22)") ==
          "\"(foo (alpha 1)\\n (beta 2) (gamma 3)\\n (delta 4))\""
    @test ev("(form->string .lay.v pretty=false width=22)") ==
          "\"(foo (alpha 1) (beta 2) (gamma 3) (delta 4))\""
    @test ev("(do (form->string .lay.v width=0) (except ?e :caught))") == ":caught"

    # ---- the REPL prints results at its width --------------------------------
    out = IOBuffer()
    air_repl(IOBuffer("(foo (alpha 1) (beta 2) (gamma 3) (delta 4))\n"), out;
             env = default_env(), width = 22)
    text = String(take!(out))
    @test occursin("(foo (alpha 1)\n (beta 2) (gamma 3)\n (delta 4))\n", text)
    @test fit(replace(text, "air> " => ""), 22)
end
