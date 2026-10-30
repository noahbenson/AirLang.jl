@testset "strings" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    @test ev("(string-length \"hello\")") == "5"
    @test ev("(string-join (\"a\" \"b\" \"c\") \"-\")") == "\"a-b-c\""
    @test ev("(string-append \"a\" \"b\")") == "\"ab\""
    @test ev("(substring \"hello\" 1 3)") == "\"hel\""
    @test ev("(string-replace \"a-b-c\" \"-\" \"+\")") == "\"a+b+c\""
    @test ev("(string-split \"a,b,c\" \",\")") == "(\"a\" \"b\" \"c\")"
    @test ev("(string-upper \"abc\")") == "\"ABC\""
    @test ev("(upcase \"abc\")") == "\"ABC\""
    @test ev("(string-lower \"ABC\")") == "\"abc\""
    @test ev("(string-trim \"  x  \")") == "\"x\""
    @test ev("(string-starts-with? \"hello\" \"he\")") == "true"
    @test ev("(string-ends-with? \"hello\" \"lo\")") == "true"
    @test ev("(string-contains? \"hello\" \"ell\")") == "true"
    @test ev("(string-index-of \"hello\" \"l\")") == "3"
    @test ev("(string-repeat \"ab\" 3)") == "\"ababab\""
    @test ev("(string-pad-left \"7\" 3 \"0\")") == "\"007\""
    @test ev("(string-pad-right \"7\" 3 \"0\")") == "\"700\""
    @test ev("(string-chars \"ab\")") == "(\"a\" \"b\")"
    @test ev("(string-lines \"a\\nb\")") == "(\"a\" \"b\")"
    @test ev("(form->string (1 2))") == "\"(1 2)\""
    @test ev("(string->form \"(1 2)\")") == "(1 2)"

    @test ev("(string-take \"hello\" 3)") == "\"hel\""
    @test ev("(string-take \"hi\" 9)") == "\"hi\""
    @test ev("(string-drop \"hello\" 2)") == "\"llo\""
    @test ev("(string-drop \"hi\" 9)") == "\"\""
    @test ev("(string-capitalize \"hELLO\")") == "\"Hello\""
    @test ev("(string-capitalize \"\")") == "\"\""
    @test ev("(string-trim-left \"  x  \")") == "\"x  \""
    @test ev("(string-trim-right \"  x  \")") == "\"  x\""

    # string-format
    @test ev("(string-format \"x=~x\" x=3)") == "\"x=3\""
    @test ev("(string-format \"hi ~name!\" name=\"Bob\")") == "\"hi Bob!\""
    @test ev("(string-format \"~~x\")") == "\"~x\""

    # string-reverse
    @test ev("(string-reverse \"abc\")") == "\"cba\""
    @test ev("(string-reverse \"\")") == "\"\""

    # regex values: a string pattern is literal, a regex value is compiled
    @test ev("(regex? (regex \"a+\"))") == "true"
    @test ev("(regex? \"a+\")") == "false"
    @test ev("(form->string (regex \"a+\" \"i\"))") == "\"r\\\"a+\\\"i\""
    let r = air_eval(env, read_air("(regex \"a+\" \"i\")"))
        @test air_eval(env, read_air(air_string(r))) == r
    end
    @test_throws AirEvalError air_eval(env, read_air("(regex \"a[\")"))
    @test_throws AirEvalError air_eval(env, read_air("(regex \"ab\" \"q\")"))

    # the pattern-aware verbs accept a literal string or a regex
    @test ev("(string-match? \"abc\" \"b\")") == "true"
    @test ev("(string-match? \"a1b\" (regex \"\\\\d\"))") == "true"
    @test ev("(string-contains? \"a1b\" (regex \"\\\\d\"))") == "true"
    @test ev("(string-index-of \"a1b\" (regex \"\\\\d\"))") == "2"
    @test ev("(string-index-of \"aéb\" (regex \"b\"))") == "3"
    @test ev("(string-index-of \"aéb\" \"b\")") == "3"
    @test ev("(string-split \"a1b22c\" (regex \"\\\\d+\"))") == "(\"a\" \"b\" \"c\")"
    @test ev("(string-split \"a--b--c\" \"--\")") == "(\"a\" \"b\" \"c\")"
    @test_throws AirEvalError air_eval(env, read_air("(string-contains? \"abc\" 3)"))

    # a regex replacement expands $0, $1, and $name; $$ is a literal dollar
    @test ev("(string-replace \"a1b2\" (regex \"(\\\\d)\") \"<\$1>\")") ==
          "\"a<1>b<2>\""
    @test ev("(string-replace \"a1b2\" (regex \"\\\\d\") \"\$0\$0\")") ==
          "\"a11b22\""
    @test ev("(string-replace \"ab\" (regex \"(?<x>a)\") \"[\$x]\")") == "\"[a]b\""
    @test ev("(string-replace \"a1\" (regex \"(\\\\d)\") \"\$\$1\")") == "\"a\\\$1\""
    @test ev("(string-replace \"a-b\" \"-\" \"+\")") == "\"a+b\""

    # string-find / string-find-all return (match=… index=… groups=…)
    @test ev("(string-find \"x=42\" (regex \"(\\\\w+)=(\\\\d+)\"))") ==
          "(groups=(\"x\" \"42\") index=1 match=\"x=42\")"
    @test ev("(string-find \"abc\" \"bc\")") ==
          "(groups=naught index=2 match=\"bc\")"
    @test ev("(string-find \"abc\" \"zz\")") == "naught"
    @test ev("(string-find-all \"a1b22c\" (regex \"\\\\d+\"))") ==
          "((groups=naught index=2 match=\"1\") (groups=naught index=4 match=\"22\"))"
    @test ev("(string-find-all \"aXbXc\" \"X\")") ==
          "((groups=naught index=2 match=\"X\") (groups=naught index=4 match=\"X\"))"
    @test ev("(string-find-all \"aéa\" \"a\")") ==
          "((groups=naught index=1 match=\"a\") (groups=naught index=3 match=\"a\"))"
    @test ev("(string-find-all \"abc\" \"z\")") == "naught"
    @test_throws AirEvalError air_eval(env, read_air("(string-find-all \"abc\" \"\")"))
end
