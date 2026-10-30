# The `bytes` extern: an immutable opaque byte string. It is the value a
# transferred file becomes, so it must print opaquely, compare and hash by
# content, and survive a database write.
@testset "bytes" begin
    env = Env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- construction --------------------------------------------------------
    # A string's bytes are its UTF-8 octets; a sequence of integers is the other
    # spelling, and both produce the same value.
    @test ev("(bytes-length (bytes \"hi\"))") == "2"
    @test ev("(bytes-length (bytes (104 105)))") == "2"
    @test ev("(eq? (bytes \"hi\") (bytes (104 105)))") == "true"
    @test ev("(eq? (bytes \"é\") (bytes (195 169)))") == "true"
    @test ev("(bytes-length (bytes))") == "0"
    @test ev("(bytes? (bytes \"x\"))") == "true"
    @test ev("(bytes? 3)") == "false"
    @test ev("(bytes? \"x\")") == "false"
    @test ev("(bytes? (regex \"a\"))") == "false"

    # An octet outside 0–255 or a non-integer element is refused.
    @test ev("(do (bytes (256)) (except ?e :caught))") == ":caught"
    @test ev("(do (bytes (1.5)) (except ?e :caught))") == ":caught"
    @test ev("(do (bytes 3) (except ?e :caught))") == ":caught"

    # ---- access --------------------------------------------------------------
    @test ev("(bytes-string (bytes \"hi\"))") == "\"hi\""
    @test ev("(bytes-index (bytes \"hi\") 1)") == "104"
    @test ev("(bytes-index (bytes \"hi\") 2)") == "105"
    @test ev("(do (bytes-index (bytes \"hi\") 0) (except ?e :caught))") == ":caught"
    @test ev("(do (bytes-index (bytes \"hi\") 3) (except ?e :caught))") == ":caught"
    # A slice is inclusive and returns a new bytes value; an empty slice is legal.
    @test ev("(bytes-string (bytes-slice (bytes \"hello\") 2 3))") == "\"el\""
    @test ev("(bytes-string (bytes-slice (bytes \"hello\") 3))") == "\"llo\""
    @test ev("(bytes-length (bytes-slice (bytes \"hello\") 2 1))") == "0"
    @test ev("(do (bytes-slice (bytes \"hello\") 1 6) (except ?e :caught))") == ":caught"
    # A non-bytes argument raises a catchable error rather than a Julia one.
    @test ev("(do (bytes-length 3) (except ?e :caught))") == ":caught"
    @test ev("(do (bytes-length (regex \"a\")) (except ?e :caught))") == ":caught"

    # ---- printing ------------------------------------------------------------
    # A bytes value prints its length and never its contents, at any size.
    @test air_string(air_eval(env, read_air("(bytes \"hi\")"))) == "#<bytes 2>"
    @test air_string(air_eval(env, read_air("(bytes \"hello\")"))) == "#<bytes 5>"
    @test !occursin("hello", air_string(air_eval(env, read_air("(bytes \"hello\")"))))
    big = "a"^1000000
    @test air_string(air_eval(env, read_air("(bytes \"" * big * "\")"))) ==
        "#<bytes 1000000>"
    # The printer is the only form; there is no source spelling, so a bytes value
    # is opaque inside a container too.
    @test air_string(air_eval(env, read_air("(list (bytes \"hi\"))"))) ==
        "(list #<bytes 2>)"

    # ---- equivalence and hashing --------------------------------------------
    # Two equal byte strings are the same air value; the hash follows `eq?`.
    @test ev("(eq? (bytes \"ab\") (bytes \"ab\"))") == "true"
    @test ev("(eq? (bytes \"ab\") (bytes \"ac\"))") == "false"
    @test ev("(eq? (bytes \"ab\") (bytes \"abc\"))") == "false"
    @test ev("(eq? (hash (bytes \"ab\")) (hash (bytes \"ab\")))") == "true"
    @test ev("(eq? (hash (bytes \"ab\")) (hash (bytes \"ac\")))") == "false"
    # Content equivalence is `eq?`'s; identity (`same?`) still distinguishes two
    # constructions, since each makes its own extern.
    @test ev("(same? (bytes \"ab\") (bytes \"ab\"))") == "false"

    # ---- persistence ---------------------------------------------------------
    # A bytes value survives a database write, restoring by content; the second
    # environment reads the same row.
    db = MemoryDatabase()
    open_airdb!(env, [:b], db)
    @test ev("(namespace .b.work (val x (bytes \"hi\")))") == "naught"
    @test ev(".b.work.x") == "#<bytes 2>"
    @test ev("(eq? .b.work.x (bytes \"hi\"))") == "true"
    @test ev("(bytes-length .b.work.x)") == "2"
    env2 = Env()
    open_airdb!(env2, [:b], db)
    ev2(s) = air_string(air_eval(env2, read_air(s)))
    @test ev2(".b.work.x") == "#<bytes 2>"
    @test ev2("(bytes-string .b.work.x)") == "\"hi\""
    @test ev2("(eq? .b.work.x (bytes \"hi\"))") == "true"

    # ---- JSON ----------------------------------------------------------------
    # AirDB's codec writes an extern as a reference, and an unnamed extern has no
    # id, so the contents are not carried. This asserts the documented behavior
    # rather than a round trip; if AirDB ever embeds a payload, this test should
    # become the round trip.
    @test AirLang._leafof(air_eval(env, read_air("(to-json (bytes \"hi\"))"))) isa
        AbstractString
    @test ev("(bytes? (from-json (to-json (bytes \"hi\"))))") == "false"
end
