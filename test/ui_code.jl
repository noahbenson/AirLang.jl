# Code awareness: the tolerant scanner, automatic indentation from the layout
# table, and the closure verdict from the reader.
@testset "ui code" begin
    B = AirLang

    @testset "scanning" begin
        toks = B._code_scan("(f 1 (g 2))")
        @test [t.kind for t in toks] ==
              [:open, :atom, :atom, :open, :atom, :atom, :close, :close]
        @test [t.depth for t in toks] == [0, 1, 1, 1, 2, 2, 1, 0]
        @test !any(t -> t.err, toks)
        # A stray closer is an error, not a crash.
        toks = B._code_scan("a) b")
        @test toks[2].kind === :close && toks[2].err
        # Strings, raw strings, and comments.
        toks = B._code_scan("(f \"a)b\" raw\"\\d+\" r\"x\" # c)\n)")
        text = [t.text for t in toks]
        @test "\"a)b\"" in text
        @test "raw\"\\d+\"" in text
        @test "# c)" in text
        @test count(t -> t.kind === :comment, toks) == 1
        # A `"` inside a comment does not open a string.
        toks = B._code_scan("# \"\n(f 1)")
        @test all(t -> !t.err, toks)
        # An unterminated string and an unterminated block comment are errors.
        @test B._code_scan("(f \"abc")[end].err
        @test B._code_scan("#| abc")[end].err
        # Nested block comments.
        toks = B._code_scan("#| a #| b |# c |# (f 1)")
        @test toks[1].kind === :comment
        @test toks[1].text == "#| a #| b |# c |#"
        @test !toks[1].err
    end

    @testset "closure" begin
        @test B._ui_closure("(f 1)")[1] === :ok
        @test B._ui_closure("(f 1) (g 2)")[1] === :ok
        @test B._ui_closure("")[1] === :ok
        @test B._ui_closure("(f 1")[1] === :incomplete
        @test B._ui_closure("\"abc")[1] === :incomplete
        @test B._ui_closure(")")[1] === :error
        @test B._ui_closure("(f 1) )")[1] === :error
        @test B._ui_closed("(f 1)")
        @test !B._ui_closed("(f 1")
        @test occursin("unclosed", B._ui_closure_message("(f"))
        @test occursin("error", B._ui_closure_message(")"))
    end

    @testset "indentation" begin
        @test B._ui_indent_at("") == 0
        @test B._ui_indent_at("(f") == 1
        # A form with no layout continues one column past the opener.
        @test B._ui_indent_at("(zzz a") == 1
        @test B._ui_indent_at("  (zzz a") == 3
        # A layout's indent is a column offset past the opener.
        @test B._ui_indent_at("(def (f x)") == 2
        @test B._ui_indent_at("  (def (f x)") == 4
        @test B._ui_indent_at("(let (x 1)") == 2
        @test B._ui_indent_at("(do") == 2
        # The innermost open form decides.
        @test B._ui_indent_at("(def (f x)\n  (if x") == 4
        # A closed inner form leaves the outer one deciding.
        @test B._ui_indent_at("(def (f x)\n  (if x)") == 2
        # The opener column comes from the innermost unclosed opener.
        @test B._ui_opener_col("(def (f x)\n  (if x") == 2
        @test B._ui_opener_col("(+ 1 2)") === nothing
        @test B._ui_open_count("(a (b (c") == 3
        @test B._ui_open_count("(a (b) c)") == 0
    end

    @testset "pairing" begin
        @test B._ui_pair_closer('(') == ')'
        @test B._ui_pair_opener(')') == '('
        @test B._ui_pair_closer('"') == '"'
        @test B._ui_pair_opener('"') == '"'
        @test B._ui_pair_closer('x') === nothing
    end

    @testset "lexical context" begin
        @test B._ui_at_context("(f \"abc", 7) === :string
        @test B._ui_at_context("(f 1)", 3) === nothing
        @test B._ui_at_context("# abc", 4) === :comment
    end

    # The round-trip rule: replaying a pretty-printed form line by line, with the
    # editor's automatic indentation standing in for the printer's leading
    # spaces, must reproduce exactly those spaces. This is the guard that the
    # editor and the printer cannot drift apart.
    function indent_roundtrip(f::AirDB.Form; width::Integer = 20)
        s = B.air_pretty_string(f; width = width)
        lines = split(s, '\n')
        text = lines[1]
        for i in 2:length(lines)
            line = lines[i]
            want = length(line) - length(lstrip(line))
            got = B._ui_indent_at(text)
            want == got || return (i, want, got, s)
            text *= "\n" * repeat(" ", got) * lstrip(line)
        end
        return nothing
    end

    @testset "indent round trip" begin
        forms = ["(def (f ?x) (g x))",
                 "(def (f ?x) \"doc\" (if x (g x) (h x)))",
                 "(let (x 1 y 2) (+ x y))",
                 "(do (f 1) (g 2) (h 3))",
                 "(namespace .util (def (f ?x) (g x)) (val v 1))",
                 "(zzz a b c d e f g)",
                 "(def (f ?a ?b) (zzz a b (yyy c d) e))"]
        for src in forms
            f = read_air(src)
            for width in (16, 20, 24, 30, 40, 80)
                bad = indent_roundtrip(f; width = width)
                @test bad === nothing
                bad === nothing || @info "indent mismatch" src width bad
            end
        end
    end

    @testset "highlighting" begin
        hl = B._hl_lines("(def (f x)\n  1)")
        @test length(hl) == 2
        @test B._hl_text(hl[1]) == "(def (f x)"
        @test B._hl_text(hl[2]) == "  1)"
        # A string keeps its style across a line break inside a triple quote.
        hl = B._hl_lines("(f \"\"\"a\nb\"\"\" 1)")
        @test length(hl) == 2
        roles = [s.style for s in hl[1]]
        @test B._ui_role(:string) in roles
        # A comment is styled as a comment.
        hl = B._hl_lines("# hi")
        @test any(s -> s.style == B._ui_role(:comment), hl[1])
        # An unterminated string is an error run.
        hl = B._hl_lines("\"abc")
        @test any(s -> s.style == B._ui_role(:error), hl[1])
        # An unmatched closer is an error run.
        hl = B._hl_lines(")")
        @test any(s -> s.style == B._ui_role(:error), hl[1])
    end
end
