@testset "reader" begin
    # atoms
    @test air_string(read_air("10")) == "10"
    @test air_string(read_air("-3")) == "-3"
    @test air_string(read_air("1.5")) == "1.5"
    @test isequal(read_air("2+3i"), Form(2.0 + 3.0im))
    @test isequal(read_air("2i"), Form(0.0 + 2.0im))
    @test isequal(read_air("4.4+2.0i"), Form(4.4 + 2.0im))
    @test isequal(read_air("4.4-2.0i"), Form(4.4 - 2.0im))
    @test air_string(read_air("4.4+2.0i")) == "4.4 + 2.0i"
    # raw strings: backslashes are literal (only `\"` and `\\` are escapes), and
    # a triple-quoted raw string follows Julia's indentation handling
    @test isequal(read_air("raw\"\\d+\""), Form("\\d+"))
    @test isequal(read_air("raw\"a\\\"b\""), Form("a\"b"))
    @test isequal(read_air("raw\"a\\\\b\""), Form("a\\\\b"))
    @test isequal(read_air("raw\"\"\"a\n        b\"\"\""), Form("a\nb"))
    @test_throws AirParseError read_air("raw\"abc")

    @test isequal(read_air("i"), Form(Symbol("i")))       # bare i is a symbol
    @test read_all_air("2 i") == [Form(2), Form(Symbol("i"))]  # spaced i is separate
    @test_throws AirParseError read_air("2im")            # only `i`, not `im`
    @test air_string(read_air("true")) == "true"
    @test air_string(read_air("false")) == "false"
    @test air_string(read_air("naught")) == "naught"
    @test isequal(read_air("x"), Form(Symbol("x")))
    @test isequal(read_air(":kw"), Form(Symbol(":kw")))
    @test isequal(read_air("?w"), Form(Symbol("?w")))
    @test isequal(read_air("+"), Form(Symbol("+")))
    @test isequal(read_air("<="), Form(Symbol("<=")))   # not a k=v split

    # `=` is a key/value separator, not an operator; only the comparison symbols
    # may contain `=` and survive as symbols.
    @test isequal(read_air("=="), Form(Symbol("==")))
    @test isequal(read_air("!="), Form(Symbol("!=")))
    @test isequal(read_air("==="), Form(Symbol("===")))
    @test isequal(read_air("!=="), Form(Symbol("!==")))
    @test air_string(read_air("(a = b)")) == "(a=b)"    # spaced `=`
    @test air_string(read_air("(a =b)")) == "(a=b)"     # `=value` after an element
    @test air_string(read_air("(a=b)")) == "(a=b)"
    @test air_string(read_air("(form ~(keyword (name ?x))=10)")) ==
        "(form ~(keyword (name ?x))=10)"                # a computed key
    @test air_string(read_air("(form ~(keyword (name ?x)) = 10)")) ==
        "(form ~(keyword (name ?x))=10)"
    @test air_string(read_air("(a !=b)")) == "(a !=b)"  # `!` is a key
    @test_throws AirParseError read_air("(a !==b)")     # `=b` is not a symbol
    @test_throws AirParseError read_air("(a ==b)")

    # `:` is a hold marker, not a symbol; after `=` it holds the following form
    @test_throws AirParseError read_air(":")
    @test_throws AirParseError read_air("::")
    @test air_string(read_air("(f=(' sq 6))")) == "(f=(' sq 6))"

    # strings
    @test isequal(read_air("\"hi\""), Form("hi"))
    @test isequal(read_air("\"\"\"hi\"\"\""), Form("hi"))
    @test isequal(read_air("\"a\\nb\""), Form("a\nb"))

    # forms
    @test air_string(read_air("(1 2 3)")) == "(1 2 3)"
    @test air_string(read_air("()")) == "()"
    @test air_string(read_air("(1)")) == "(1)"          # no read-time canonicalization
    @test air_string(read_air("(1 (2 3))")) == "(1 (2 3))"

    # the | pattern-alternative sugar: it joins the adjacent sequence elements
    @test air_string(read_air("(a |b)")) == "(alt a b)"
    @test air_string(read_air("(a | b | c)")) == "(alt a b c)"
    @test air_string(read_air("(f a | b)")) == "(f (alt a b))"
    @test air_string(read_air("(f a b | c)")) == "(f a (alt b c))"
    @test air_string(read_air("(1 2 |3 4)")) == "(1 (alt 2 3) 4)"
    # the alt operand keeps its postfix; a pipe needs a sequence element on each
    # side, and cannot take a map entry
    @test air_string(read_air("(f (g x).a | h)")) == "(f (alt (get (g x) :a) h))"
    @test_throws AirParseError read_air("(|a b)")
    @test_throws AirParseError read_air("(a |)")
    @test_throws AirParseError read_air("(a | b=1)")
    @test_throws AirParseError read_air("(a=1 | b)")
    # a map entry is not a sequence element on either side of a pipe, even when
    # an earlier element would otherwise be available to pair with
    @test_throws AirParseError read_air("(f a=1 | b)")
    @test_throws AirParseError read_air("(f 1 a=2 | b)")
    @test air_string(read_air("(f a=1 2 | b)")) == "(f (alt 2 b) a=1)"

    # mappings and hybrid forms
    @test air_string(read_air("(a=1 b=2)")) == "(a=1 b=2)"
    @test air_string(read_air("(f 1 2 a=3)")) == "(f 1 2 a=3)"
    @test air_string(read_air("(a=(1 2))")) == "(a=(1 2))"

    # comments and separators
    @test air_string(read_air("1 # a comment\n")) == "1"
    @test air_string(read_air("(1, 2, 3)")) == "(1 2 3)"
    # block comments nest and may span lines or sit inside a form
    @test air_string(read_air("#| a comment |# 1")) == "1"
    @test air_string(read_air("#| a\nb |# 1")) == "1"
    @test air_string(read_air("(1 #| a |# 2)")) == "(1 2)"
    @test air_string(read_air("(a #| x ) ( |# b)")) == "(a b)"
    @test air_string(read_air("#| a #| b |# c |# 1")) == "1"
    @test air_string(read_air("#| a # comment\n |# 1")) == "1"
    @test air_string(read_air("1 # #| not a block |#\n")) == "1"
    @test air_string(read_air("\"#| not a comment |#\"")) == "\"#| not a comment |#\""
    @test_throws AirParseError read_air("#| unterminated")
    @test_throws AirParseError read_air("#| a #| b |#")

    # several forms
    @test length(read_all_air("1 2 3")) == 3
    @test length(read_all_air("(a) (b)")) == 2

    # the `.` accessor — keys are held, `~` evaluates one
    @test air_string(read_air("f.key")) == "(get f :key)"
    @test air_string(read_air("f.a.b")) == "(get f :a :b)"
    @test air_string(read_air("f.:test")) == "(get f :test)"
    @test air_string(read_air("(test=10).:test")) == "(get (test=10) :test)"
    @test air_string(read_air("(f 1).x")) == "(get (f 1) :x)"
    @test air_string(read_air("f.~k")) == "(get f ~k)"
    @test air_string(read_air("f.~a.b")) == "(get f ~a :b)"

    # the `...` splat
    @test air_string(read_air("x...")) == "x..."
    @test air_string(read_air("(f a... b)")) == "(f a... b)"
    @test air_string(read_air("(3 4)...")) == "(3 4)..."

    # `~` holes: the suffix `...` applies to the whole hole (it splices the
    # hole's value; it is not a preval of a splice), and a map value may itself
    # be a `~(…)` hole. Printing is ambiguous here, so inspect the structure.
    hole = AirLang.to_form(read_air("(f ~(1 + 2)...)").seq[2])
    @test AirLang.head_symbol(hole) === AirLang.SPLAT
    @test AirLang.head_symbol(AirLang.to_form(hole.seq[2])) === AirLang.PREVAL
    atomhole = read_air("~a...")
    @test AirLang.head_symbol(atomhole) === AirLang.SPLAT
    @test AirLang.head_symbol(AirLang.to_form(atomhole.seq[2])) === AirLang.PREVAL
    mapform = read_air("(f x=~(1 + 2))")
    @test length(mapform.seq) == 1 && !isempty(mapform.map)
    @test AirLang.head_symbol(AirLang.to_form(mapform[Symbol(":x")])) ===
        AirLang.PREVAL
    # ... in all the separators the reader allows (`=`, `=~`, `~` after a space)
    for s in ["(f x=(preval (1 + 2)))", "(f x =~(1 + 2))",
              "(f x= ~(1 + 2))", "(f x = ~(1 + 2))"]
        g = read_air(s)
        @test AirLang.head_symbol(AirLang.to_form(g[Symbol(":x")])) ===
            AirLang.PREVAL
        @test length(g.seq) == 1
    end
    @test isequal(read_air("1.5"), Form(1.5))       # a number is not split
    @test isequal(read_air(".5"), Form(0.5))
    @test isequal(read_air("a-b"), Form(Symbol("a-b")))

    # errors
    @test_throws AirParseError read_air("(1 2")
    @test_throws AirParseError read_air(")")
    @test_throws AirParseError read_air("1 2")
    @test_throws AirParseError read_air("")
end
