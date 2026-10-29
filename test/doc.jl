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

    # `(doc symbol)` lists every documented pattern that uses the symbol, in
    # definition order.
    @test doc("(doc log)") ==
        "(log ?x \\ number?)\n" *
        "  Returns the natural log of x.\n\n" *
        "(log ?base \\ number? ?x \\ number?)\n" *
        "  Returns the log-base-b of x."

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
    @test doc("(doc (log 1))") == "(log ?x \\ number?)\n  Returns ln(x)."
end
