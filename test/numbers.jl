# AirDB's numeric tower: `Int64`, `BigInt`, `Float64`, `BigFloat`,
# `Rational{Int64}`, `Rational{BigInt}`, `ComplexF64`, and `Complex{BigFloat}`.
# Air supplies the literals, the printed spelling (which must re-read as the same
# value at any depth), the predicates, and AirDB's equivalence; arithmetic and
# promotion stay Julia's.
@testset "numeric tower" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    leaf(s) = AirLang._leafof(air_eval(env, read_air(s)))

    # ---- reader literals -----------------------------------------------------
    @test leaf("9223372036854775807") isa Int64
    @test leaf("9223372036854775808") isa BigInt
    @test leaf("123456789012345678901234567890") isa BigInt
    @test leaf("-123456789012345678901234567890") isa BigInt
    @test leaf("1//3") isa Rational{Int64}
    @test ev("1//3") == "1//3"
    @test ev("-1//3") == "-1//3"
    @test ev("1//-3") == "-1//3"       # the sign moves to the numerator
    @test ev("4//2") == "2//1"
    @test leaf("big\"1.5\"") isa BigFloat
    @test leaf("big\"2.0\"i") isa Complex{BigFloat}
    @test leaf("2i") isa ComplexF64
    @test leaf("Inf") === Inf
    @test leaf("-Inf") === -Inf
    @test leaf("NaN") isa Float64
    @test isnan(leaf("NaN"))
    @test ev("-0.0") == "-0.0"
    # the prefixed literal works wherever a form may appear
    @test ev("(f x=big\"1.5\")") == "(f x=big\"1.5\")"
    @test ev("(big\"1.5\")") == "(big\"1.5\")"
    @test ev("'big\"1.5\"") == "'big\"1.5\""     # a hold of one scalar keeps the quote

    # ---- constructors --------------------------------------------------------
    @test ev("(rational 1 3)") == "1//3"
    @test ev("(rational 4 2)") == "2//1"
    @test leaf("(rational 123456789012345678901234567890 3)") isa Rational{BigInt}
    @test ev("(complex 1 2)") == "1.0+2.0i"
    @test ev("(complex 1.5 2.0)") == "1.5+2.0i"
    @test ev("(bigfloat \"1.5\")") == "big\"1.5\""
    @test ev("(bigfloat \"1.5\" precision=512)") == "(bigfloat \"1.5\" precision=512)"
    @test_throws AirEvalError air_eval(env, read_air("(// 1 0)"))
    @test_throws AirEvalError air_eval(env, read_air("(rational 1 0)"))
    # a part with no exact leaf spelling is an air error, not a raw Julia one
    @test_throws AirEvalError air_eval(env, read_air("(complex 1//3 0)"))
    @test_throws AirEvalError air_eval(env, read_air("(div 1 0)"))

    # ---- printer: every leaf re-reads as the same value, at depth -------------
    # a form with `x` as its sole argument, so the leaf is tested at depth
    depth1(x) = AirLang.FormContainer(
        AirLang.FormSeq(AirLang.FormValue[Form(Symbol("f")), AirLang._store_form(x)]),
        AirLang.FormMap())
    setprecision(BigFloat, 512) do
        vals = Any[
            0, 1, -1, big(2)^100, -(big(2)^100), 1//3, -2//3, 1//(big(2)^100),
            BigFloat("1.5"), BigFloat("3.14159265358979323846"),
            0.0, -0.0, 1.5, Inf, -Inf, NaN,
            complex(1.5, 2.0), complex(1.5, -2.0), complex(0.0, 2.0),
            complex(NaN, 1.0), complex(big"1.5", big"-2.0"),
            true, :sym, "text", nothing,
        ]
        for v in vals
            x = to_form(v)
            for y in (x, depth1(x))
                s = air_string(y)
                z = air_eval(env, read_air(s))
                @test AirDB.isequiv(y, z)
            end
        end
    end

    # at the ambient precision `big"…"` is enough; anything else must carry the
    # precision, or reading it back would silently change the value
    local p512 = setprecision(BigFloat, 512) do
        BigFloat("1.5")
    end
    let y = depth1(to_form(p512))
        s = air_string(y)
        @test s == "(f (bigfloat \"1.5\" precision=512))"
        z = air_eval(env, read_air(s))
        @test AirDB.isequiv(y, z)
        @test precision(AirLang.value(to_form(z.seq[2]))) == 512
    end

    # ---- fixed points: a `NaN` leaf is a value, not a change ------------------
    # AirDB's container `isequal` compares children with `==`, under which a
    # `NaN` is never equal to itself; the reducer's own fixed-point test must not
    # inherit that, or a form holding a `NaN` reduces forever.
    @test ev("(f NaN)") == "(f NaN)"
    @test ev("(f (complex NaN 1.0))") == "(f (complex NaN 1.0))"
    @test ev("(g (f 1) NaN)") == "(g (f 1) NaN)"

    # ---- arithmetic is Julia's -------------------------------------------------
    @test ev("(7 // 2)") == "7//2"
    @test ev("(div 7 2)") == "3"
    @test ev("(div -7 2)") == "-3"      # `div` truncates toward zero, as in Julia
    @test ev("(+ 1//3 1//6)") == "1//2"
    @test ev("(* 1//3 3)") == "1//1"
    @test ev("(/ 1 2)") == "0.5"
    @test ev("(/ 1//2 2)") == "1//4"       # dividing exact values stays exact
    @test ev("(+ 1//3 0.5)") == "0.8333333333333333"
    @test ev("(* 1267650600228229401496703205376 2)") ==
        "2535301200456458802993406410752"
    # `^` is Int64 arithmetic, so an exponent that overflows wraps; an exact
    # result needs an exact operand
    @test ev("(^ 2 62)") == "4611686018427387904"
    @test ev("(^ 2//1 10)") == "1024//1"

    # ---- predicates ------------------------------------------------------------
    @test ev("(int? 1267650600228229401496703205376)") == "true"
    @test ev("(integer? -1267650600228229401496703205376)") == "true"
    @test ev("(float? big\"1.5\")") == "true"
    @test ev("(complex? big\"2.0\"i)") == "true"
    @test ev("(number? big\"2.0\"i)") == "true"
    @test ev("(number? 1//3)") == "true"
    @test ev("(int? 1//1)") == "false"
    @test ev("(float? 1)") == "false"
    @test ev("(even? 1267650600228229401496703205376)") == "true"
    @test ev("(nan? NaN)") == "true"
    @test ev("(infinite? -Inf)") == "true"

    # ---- equivalence (AirDB's `isequiv`) --------------------------------------
    # a signed zero is one value under equivalence, as it is under `==`
    @test ev("(eq? -0.0 0.0)") == "true"
    @test ev("(=== -0.0 0.0)") == "true"
    @test ev("(eq? (hash -0.0) (hash 0.0))") == "true"
    @test ev("(== -0.0 0.0)") == "true"
    # `NaN` is equivalent to itself, but content equality is Julia's `==`, where
    # a `NaN` is equal to nothing
    @test ev("(eq? NaN NaN)") == "true"
    @test ev("(== NaN NaN)") == "false"
    @test ev("(!= NaN NaN)") == "true"
    @test ev("(=== NaN NaN)") == "true"
    @test ev("(eq? (hash NaN) (hash NaN))") == "true"
    @test ev("(eq? (f NaN) (f NaN))") == "true"
    # type is part of equivalence; content equality still merges numbers
    @test ev("(eq? 1 1.0)") == "false"
    @test ev("(== 1 1.0)") == "true"
    @test ev("(=== 1 1.0)") == "false"
    @test ev("(eq? 1//1 1)") == "false"
    @test ev("(eq? big\"1.0\" 1.0)") == "false"
    # a `BigInt` 1 and an `Int64` 1 are content-equal but not equivalent
    let bigone = "(+ 1267650600228229401496703205376 -1267650600228229401496703205375)"
        @test leaf(bigone) isa BigInt
        @test leaf(bigone) == 1
        @test ev("(eq? $(bigone) 1)") == "false"
        @test ev("(== $(bigone) 1)") == "true"
        @test ev("(eq? (hash $(bigone)) (hash $(bigone)))") == "true"
    end
    # equivalence-keyed tables merge the signed zeros
    d = Dict{AirLang._EqKey,Int}()
    d[AirLang._EqKey(read_air("-0.0"))] = 1
    @test d[AirLang._EqKey(read_air("0.0"))] == 1
    @test length(d) == 1
    d[AirLang._EqKey(read_air("1"))] = 2
    d[AirLang._EqKey(read_air("1.0"))] = 3      # `1` and `1.0` stay apart
    @test length(d) == 3
    @test d[AirLang._EqKey(read_air("1"))] == 2

    # ---- ordering and aggregation ---------------------------------------------
    @test ev("(< 1//3 1//2)") == "true"
    @test ev("(<= 1//3 1//3)") == "true"
    @test ev("(compare 1//3 1//2)") == "-1"
    @test ev("(compare 1//3 1//3)") == "0"
    @test ev("(compare (complex 1 2) (complex 1 2))") == "0"
    # a complex value has no order, so the comparison stays symbolic
    @test ev("(< 1 (complex 2 1))") == "(< 1 2.0+1.0i)"
    @test ev("(< (complex 2 1) 1)") == "(< 2.0+1.0i 1)"
    @test ev("(min 1//3 1//2 0.4)") == "0.3333333333333333"
    @test ev("(abs -1//3)") == "1//3"
    @test ev("(sum (1//3 1//6))") == "1//2"

    # ---- a checked `Int` conversion -------------------------------------------
    @test_throws AirEvalError air_eval(
        env, read_air("(replace (a b) ?x 0 depth=123456789012345678901234567890)"))
    @test_throws AirEvalError air_eval(
        env, read_air("(stream maxsize=123456789012345678901234567890)"))

    # ---- JSON round-trip -------------------------------------------------------
    for s in ["1//3", "123456789012345678901234567890", "big\"1.5\"", "NaN", "-Inf",
              "1.5+2.0i", "(f NaN)", "(complex big\"1.0\" big\"2.0\")",
              "(bigfloat \"1.5\" precision=512)"]
        @test ev("(eq? (from-json (to-json $(s))) $(s))") == "true"
    end
    json(s) = AirLang.value(air_eval(env, read_air(s)))
    @test json("(to-json 1//3)") == "\"#rat:1/3\""
    @test json("(to-json 123456789012345678901234567890)") ==
        "\"#big:123456789012345678901234567890\""
    @test json("(to-json NaN)") == "\"#nan\""
    @test json("(to-json -Inf)") == "\"#-inf\""
end
