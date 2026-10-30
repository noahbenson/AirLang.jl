# Times are the ordinary immutable form `(time SECONDS)` — UTC epoch seconds with
# no map — so they persist, serialize, hash, and compare like any other form. The
# printer renders one as ISO-8601 (`(time "2026-10-28T21:15:00.123Z")`), the
# `time` verbs construct, parse, and format one, and `+`/`-`/ordering reach the
# ordinary operator dispatch. `lib/time` adds readable duration spellings.
@testset "times" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- the value and the printer ------------------------------------------
    @test ev("(time? (time 1))") == "true"
    @test ev("(time? 1)") == "false"
    @test ev("(time? (now))") == "true"
    @test ev("(time (time 5))") == "(time \"1970-01-01T00:00:05Z\")"
    @test occursin(r"^\(time \"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z\"\)$",
                   ev("(now)"))
    # a time is an ordinary form: exactly one sequence element, no map
    t = air_eval(env, read_air("(time 1761686100.123)"))
    @test t isa AirDB.FormContainer
    @test length(t.seq) == 2
    @test isempty(t.map)
    # and it round-trips through its printed spelling
    @test air_eval(env, read_air(air_string(t))) == t
    @test air_string(air_eval(env, read_air("(time \"2026-10-28T21:15:00.123Z\")"))) ==
          "(time \"2026-10-28T21:15:00.123Z\")"
    # a value DateTime cannot carry keeps its numeric spelling, so printing is
    # always exact (here: sub-millisecond precision, and a huge value)
    @test air_string(air_eval(env, read_air("(time 0.0000001)"))) ==
          "(time 1.0e-7)"
    big = air_eval(env, read_air("(time 1e18)"))
    @test air_eval(env, read_air(air_string(big))) == big
    # the flat print is what governs a layout's width measurement too
    @test air_pretty_string(t; width = 5) ==
          "(time \"2025-10-28T21:15:00.123Z\")"

    # ---- parsing -------------------------------------------------------------
    @test ev("(time \"2026-10-28\")") == "(time \"2026-10-28T00:00:00Z\")"
    @test ev("(time \"2026-10-28T21:15\")") == "(time \"2026-10-28T21:15:00Z\")"
    @test ev("(time \"2026-10-28 21:15:00\")") == "(time \"2026-10-28T21:15:00Z\")"
    @test ev("(time \"2026-10-28T21:15:00.123Z\")") ==
          "(time \"2026-10-28T21:15:00.123Z\")"
    # an offset shifts the instant to UTC
    @test ev("(time \"2026-10-28T21:15:00.123+02:00\")") ==
          "(time \"2026-10-28T19:15:00.123Z\")"
    @test ev("(time \"2026-10-28T21:15:00-0230\")") ==
          "(time \"2026-10-28T23:45:00Z\")"
    # a number is UTC epoch seconds already
    @test ev("(time 1761686100.123)") == "(time \"2025-10-28T21:15:00.123Z\")"
    # a non-time argument stays symbolic, like every other math verb
    @test ev("(time ?x)") == "(time ?x)"
    @test ev("(do (time \"nope\") (except ?e :caught))") == ":caught"
    @test ev("(do (time \"2026-13-40\") (except ?e :caught))") == ":caught"

    # ---- formatting ----------------------------------------------------------
    @test ev("(time-str (time 1761686100.123))") == "\"2025-10-28T21:15:00.123Z\""
    @test ev("(time-str (time 1761686100.0))") == "\"2025-10-28T21:15:00Z\""
    @test ev("(time-str (time 1761686100.12))") == "\"2025-10-28T21:15:00.12Z\""
    # `format` is a Julia `Dates.DateFormat`: `MM` is minutes and `SS` seconds
    @test ev("(time-str (time 1761686100.123) format=\"yyyy-mm-dd HH:MM:SS\")") ==
          "\"2025-10-28 21:15:00\""
    @test ev("(time-str (time 1761686100.123) offset=\"+02:00\")") ==
          "\"2025-10-28T23:15:00.123+02:00\""
    @test ev("(time-str (time 1761686100.123) offset=(- 3600))") ==
          "\"2025-10-28T20:15:00.123-01:00\""
    @test ev("(do (time-str 5) (except ?e :caught))") == ":caught"
    @test ev("(do (time-str (time 1) format=5) (except ?e :caught))") == ":caught"
    @test ev("(do (time-str (time 1) fmt=\"yyyy\") (except ?e :caught))") == ":caught"

    # ---- arithmetic ----------------------------------------------------------
    @test ev("(+ (time 10) 5)") == "(time \"1970-01-01T00:00:15Z\")"
    @test ev("(+ 5 (time 10))") == "(time \"1970-01-01T00:00:15Z\")"
    @test ev("(- (time 10) 3)") == "(time \"1970-01-01T00:00:07Z\")"
    # a time difference is a duration in seconds
    @test ev("(- (time 10) (time 4))") == "6.0"
    @test ev("(- (now) (now))") == "0.0"
    # time + time is not a time: the form stays symbolic
    @test ev("(+ (time 10) (time 4))") ==
          "((time \"1970-01-01T00:00:10Z\") + (time \"1970-01-01T00:00:04Z\"))"
    @test ev("(- (time 10))") == "(- (time \"1970-01-01T00:00:10Z\"))"
    @test ev("(* (time 10) 2)") ==
          "((time \"1970-01-01T00:00:10Z\") * 2)"

    # ---- ordering and comparison --------------------------------------------
    @test ev("(< (time 1) (time 2))") == "true"
    @test ev("(<= (time 1) (time 1))") == "true"
    @test ev("(> (time 2) (time 1))") == "true"
    # a time and a plain number do not compare: the form stays symbolic
    @test ev("(< (time 1) 2)") == "(< (time \"1970-01-01T00:00:01Z\") 2)"
    @test ev("(before? (time 1) (time 2))") == "true"
    @test ev("(before? (time 2) (time 2))") == "false"
    @test ev("(after? (time 2) (time 1))") == "true"
    @test ev("(between? (time 1) (time 0) (time 2))") == "true"
    @test ev("(between? (time 1) (time 1) (time 2))") == "true"
    @test ev("(between? (time 3) (time 0) (time 2))") == "false"
    # the comparison verbs also take plain numbers
    @test ev("(between? 1 0 2)") == "true"
    @test ev("(before? 1 2)") == "true"
    @test ev("(after? 2 1)") == "true"
    # a symbolic argument leaves the form unchanged
    @test ev("(before? ?x (time 2))") == "(before? ?x (time \"1970-01-01T00:00:02Z\"))"

    # ---- equality, hashing, and JSON ----------------------------------------
    @test ev("(eq? (time 1) (time 1))") == "true"
    @test ev("(eq? (time 1) (time 1.0))") == "true"
    @test ev("(eq? (time 1) (time 2))") == "false"
    @test ev("(eq? (time 1) 1)") == "false"
    @test ev("(== (time 1) (time 1.0))") == "true"
    @test ev("(== (hash (time 1)) (hash (time 1.0)))") == "true"
    @test ev("(from-json (to-json (time 1761686100.123)))") ==
          "(time \"2025-10-28T21:15:00.123Z\")"
    # a time carries no database resource, so it encodes as an ordinary form
    @test ev("(to-json (time 0.5))") == "\"[[\\\":time\\\", 0.5], {}]\""

    # ---- the `time` library --------------------------------------------------
    repo_lib = joinpath(dirname(@__DIR__), "lib")
    old = get(ENV, "AIR_LIBPATH", nothing)
    ENV["AIR_LIBPATH"] = repo_lib
    try
        @test ev("(using time (seconds 90))") == "90"
        @test ev("(using time (minutes 90))") == "5400"
        @test ev("(using time (hours 2))") == "7200"
        @test ev("(using time (days 1))") == "86400"
        @test ev("(using time (weeks 1))") == "604800"
        @test ev("(.lib.time.days 2)") == "172800"
        # `since` is an elapsed duration; `ago` is an instant
        @test ev("(time? (.lib.time.ago (hours 1)))") == "true"
        @test ev("(let (t=(now)) (between? (.lib.time.since t) -1 5))") == "true"
        @test ev("(let (t=(now)) (between? (.lib.time.ago 60) (- t 61) (+ t 1)))") ==
              "true"
        @test ev("(using time (hours 1))") == "3600"
    finally
        old === nothing ? delete!(ENV, "AIR_LIBPATH") : (ENV["AIR_LIBPATH"] = old)
    end
end
