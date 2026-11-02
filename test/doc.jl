@testset "doc" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    # `doc` returns a string; compare its text without the printer's quotes.
    doc(s) = (v = value(air_eval(env, read_air(s))); v isa AbstractString ? String(v) : "")

    # A literal string at the head of the body is the docstring, not part of the
    # body.
    air_eval(env, read_air(
        "(def (log ?x \\ number?) \"Returns the natural log of x.\" (x + 100))"))
    air_eval(env, read_air(
        "(def (log ?base \\ number? ?x \\ number?) \"Returns the log-base-b of x.\" (x + 200))"))
    @test ev("(log 1.0)") == "101.0"
    @test ev("(log 2 8)") == "208"

    # `(doc symbol)` lists the builtin's catalogue entry first, then every
    # documented pattern that uses the symbol, in definition order.
    @test startswith(doc("(doc log)"), "log  (builtin :math)\n")
    @test endswith(doc("(doc log)"),
        "(log ?x \\ number?)\n" *
        "  Returns the natural log of x.\n\n" *
        "(log ?base \\ number? ?x \\ number?)\n" *
        "  Returns the log-base-b of x.")

    # `(doc (form…))` holds its argument (the builtin `log` is not called) and
    # lists only the patterns that match.
    @test doc("(doc (log 1.0))") ==
        "(log ?x \\ number?)\n  Returns the natural log of x."
    @test doc("(doc (log 2.0 8.0))") ==
        "(log ?base \\ number? ?x \\ number?)\n  Returns the log-base-b of x."

    # `definitions` returns the matching defs as quoted data, with the docstring
    # moved into a `doc=` entry. It accepts the same argument as `doc`.
    air_eval(env, read_air("(def (plain ?x) (x + 1))"))
    @test ev("(definitions log)") ==
        "((' def (log ?x \\ number?) (x + 100) doc=\"Returns the natural log of x.\") " *
        "(' def (log ?base \\ number? ?x \\ number?) (x + 200) " *
        "doc=\"Returns the log-base-b of x.\"))"
    @test ev("(definitions (log 1.0))") ==
        "((' def (log ?x \\ number?) (x + 100) doc=\"Returns the natural log of x.\"))"
    @test ev("(definitions plain)") == "((' def (plain ?x) (x + 1)))"
    @test ev("(definitions frobnicate)") == "naught"

    # No match is reported, not thrown.
    @test doc("(doc frobnicate)") == "no documentation found for frobnicate"
    @test doc("(doc (log \"x\"))") == "no documentation found for (log \"x\")"

    # Multiline docstrings are deindented; a docstring-only body is `naught`.
    air_eval(env, read_air(
        "(def (greet ?name)\n" *
        "  \"Says hello.

  The second paragraph is deindented to the margin.\"
  (str \"hello \" name))"))
    @test doc("(doc greet)") ==
        "(greet ?name)\n" *
        "  Says hello.\n\n" *
        "  The second paragraph is deindented to the margin."
    # A docstring is not a body: a `def` with only a docstring is an empty-body
    # rule, so it reproduces its matched form (with its arguments reduced).
    air_eval(env, read_air("(def (nodoc ?x) \"Only documentation.\")"))
    @test ev("(nodoc (1 + 1))") == "(nodoc 2)"
    @test doc("(doc nodoc)") ==
        "(nodoc ?x)\n  Only documentation."
    @test ev("(definitions nodoc)") ==
        "((' def (nodoc ?x) doc=\"Only documentation.\"))"

    # A body that calls the runtime `unhold` is inert inside the reconstructed
    # quote (`~` is a quasiquote hole, not an unhold call).
    air_eval(env, read_air("(def (uq ?x) hold=(x) (unhold x))"))
    @test ev("(uq 5)") == "5"
    @test ev("(definitions uq)") == "((' def (uq ?x) (unhold x) hold=x))"

    # `lift` is the explicit way to build a computed quote in a body; the
    # constructor call survives `definitions`.
    air_eval(env, read_air("(def (q ?x) (lift (' a x 'b)))"))
    @test ev("(q 7)") == "(' a 7 b)"
    @test ev("(definitions q)") == "((' def (q ?x) (lift (' a x 'b))))"

    # Redefining a pattern replaces its docstring in place.
    air_eval(env, read_air(
        "(def (log ?x \\ number?) \"Returns ln(x).\" x)"))
    @test endswith(doc("(doc (log 1))"), "(log ?x \\ number?)\n  Returns ln(x).")

    # ---- the builtin catalogue ------------------------------------------------
    # Every builtin and operator name has an entry in the catalogue, so `(doc)`
    # is a complete inventory of the language. `docdef` entries that name a
    # reserved head rather than a registered builtin (`error`, `signal`, `ui`)
    # are allowed.
    for n in keys(AirLang.BUILTINS)
        @test haskey(AirLang.BUILTIN_DOCS, n)
    end
    for n in keys(AirLang.OPERATORS)
        @test haskey(AirLang.BUILTIN_DOCS, n)
    end
    @test all(!isempty(t[2]) for t in values(AirLang.BUILTIN_DOCS))

    # `(doc)` and `(doc .air)` return the index; a category name is a path form
    # to the same table.
    @test startswith(doc("(doc)"), "Air documents ")
    @test doc("(doc .air)") == doc("(doc)")
    @test occursin(":math (", doc("(doc)"))
    @test occursin("  sqrt", doc("(doc)"))

    # `.air.NAME` documents that builtin, including a reserved head (`hold`),
    # and a name with no catalogue entry reports the miss.
    @test startswith(doc("(doc .air.sqrt)"), "sqrt  (builtin :math)\n")
    @test startswith(doc("(doc hold)"), "hold  (builtin :hold)\n")
    @test doc("(doc (get . :air :sqrt))") == doc("(doc .air.sqrt)")

    # `(help)` prints an introduction; `(help :category)` and `(help :all)`
    # print an index; `(help NAME)` prints that entry.
    helpout(s) = begin
        buf = IOBuffer()
        ctx = AirLang.TaskContext(Symbol("air"), nothing, nothing, naught, buf)
        AirLang._with_context(env, ctx, () -> air_eval(env, read_air(s)))
        String(take!(buf))
    end
    @test startswith(helpout("(help)"), "Air is a ")
    @test occursin("term rewriting", helpout("(help)"))
    @test occursin("(doc .air)", helpout("(help)"))
    @test helpout("(help :table)") ==
        ":table (6)\n  table  table?  columns  schema  nrows  table-index\n"
    @test occursin("Air documents ", helpout("(help :all)"))
    @test helpout("(help :frobnicate)") ==
        "no documentation category :frobnicate\n"
    @test startswith(helpout("(help sqrt)"), "sqrt  (builtin :math)\n")
    @test helpout("(help)") == AirLang._HELP_INTRO
    @test_throws AirEvalError air_eval(env, read_air("(help a b)"))
end
