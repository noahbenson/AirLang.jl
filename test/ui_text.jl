# The text buffer: the one editable-text model behind every code widget.
@testset "ui text" begin
    B = AirLang

    @testset "text and construction" begin
        b = B._TextBuffer()
        @test B._tb_text(b) == ""
        @test B._tb_nlines(b) == 1
        b = B._TextBuffer("ab\ncd")
        @test B._tb_text(b) == "ab\ncd"
        @test B._tb_nlines(b) == 2
        @test B._tb_cursor(b) == (1, 0)
        @test B._tb_text(B._TextBuffer("x\n")) == "x\n"
        @test B._tb_nlines(B._TextBuffer("x\n")) == 2
    end

    @testset "insertion and deletion" begin
        b = B._TextBuffer("ac")
        B._tb_move_h!(b, 1)
        B._tb_insert!(b, 'b')
        @test B._tb_text(b) == "abc"
        @test B._tb_cursor(b) == (1, 2)
        B._tb_backspace!(b)
        @test B._tb_text(b) == "ac"
        B._tb_delete!(b)
        @test B._tb_text(b) == "a"
        # Backspace at the start of a line joins it with the previous one.
        b = B._TextBuffer("ab\ncd")
        B._tb_move_v!(b, 1)
        @test B._tb_cursor(b) == (2, 0)
        B._tb_backspace!(b)
        @test B._tb_text(b) == "abcd"
        @test B._tb_cursor(b) == (1, 2)
        # Delete at the end of a line joins it with the next one.
        b = B._TextBuffer("ab\ncd")
        B._tb_move_h!(b, 2)
        B._tb_delete!(b)
        @test B._tb_text(b) == "abcd"
        @test B._tb_cursor(b) == (1, 2)
        # A newline takes the requested indentation.
        b = B._TextBuffer("ab")
        B._tb_move_h!(b, 2)
        B._tb_newline!(b, 4)
        @test B._tb_text(b) == "ab\n    "
        @test B._tb_cursor(b) == (2, 4)
    end

    @testset "motion" begin
        b = B._TextBuffer("abc\ndefgh\nij")
        B._tb_move_h!(b, 3)
        @test B._tb_cursor(b) == (1, 3)
        B._tb_move_h!(b, 1)                      # crosses into the next line
        @test B._tb_cursor(b) == (2, 0)
        B._tb_move_v!(b, 1)
        @test B._tb_cursor(b) == (3, 0)
        # The goal column survives a short line.
        b = B._TextBuffer("abcdef\nx\nabcdef")
        B._tb_move_h!(b, 5)
        B._tb_move_v!(b, 1)
        @test B._tb_cursor(b) == (2, 1)
        B._tb_move_v!(b, 1)
        @test B._tb_cursor(b) == (3, 5)
        B._tb_home!(b)
        @test B._tb_cursor(b) == (3, 0)
        B._tb_end!(b)
        @test B._tb_cursor(b) == (3, 6)
        # Home goes to the first non-blank character and then to column 0.
        b = B._TextBuffer("    abc")
        B._tb_end!(b)
        B._tb_home!(b)
        @test B._tb_cursor(b) == (1, 4)
        B._tb_home!(b)
        @test B._tb_cursor(b) == (1, 0)
        # Word motion: forward skips to the end of the next word, back to its
        # start.
        b = B._TextBuffer("foo (bar baz)")
        B._tb_word_right!(b)
        @test B._tb_cursor(b) == (1, 3)
        B._tb_word_right!(b)
        @test B._tb_cursor(b) == (1, 8)
        B._tb_word_left!(b)
        @test B._tb_cursor(b) == (1, 5)
    end

    @testset "selection" begin
        b = B._TextBuffer("abcd")
        B._tb_move_h!(b, 2)
        B._tb_move_h!(b, 2; select = true)
        @test B._tb_selected_text(b) == "cd"
        B._tb_move_h!(b, -1; select = true)
        @test B._tb_selected_text(b) == "c"
        @test B._tb_selected(b, 1, 2)
        @test !B._tb_selected(b, 1, 1)
        B._tb_insert!(b, "X")
        @test B._tb_text(b) == "abXd"
        B._tb_select_all!(b)
        @test B._tb_selected_text(b) == "abXd"
        B._tb_delete_selection!(b)
        @test B._tb_text(b) == ""
    end

    @testset "kill and yank" begin
        b = B._TextBuffer("abcdef")
        B._tb_move_h!(b, 3)
        B._tb_kill_line!(b)
        @test B._tb_text(b) == "abc"
        B._tb_yank!(b)
        @test B._tb_text(b) == "abcdef"
        b = B._TextBuffer("abc def")
        B._tb_end!(b)
        B._tb_kill_word!(b)
        @test B._tb_text(b) == "abc "
        b = B._TextBuffer("abc def")
        B._tb_move_h!(b, 5)
        B._tb_kill_start!(b)
        @test B._tb_text(b) == "ef"
        @test B._tb_cursor(b) == (1, 0)
    end

    @testset "undo and redo" begin
        b = B._TextBuffer("a")
        B._tb_end!(b)
        B._tb_insert!(b, 'b')
        B._tb_insert!(b, 'c')
        @test B._tb_text(b) == "abc"
        @test B._tb_undo!(b)
        @test B._tb_text(b) == "ab"
        @test B._tb_undo!(b)
        @test B._tb_text(b) == "a"
        @test !B._tb_undo!(b)
        @test B._tb_redo!(b)
        @test B._tb_text(b) == "ab"
        # A fresh edit clears the redo stack.
        B._tb_insert!(b, 'z')
        @test !B._tb_redo!(b)
        @test B._tb_text(b) == "abz"
    end

    @testset "reindent" begin
        b = B._TextBuffer("    abc")
        B._tb_end!(b)
        @test B._tb_reindent!(b, 2)
        @test B._tb_text(b) == "  abc"
        @test B._tb_leading_spaces(b) == 2
        @test !B._tb_reindent!(b, 2)
        @test B._tb_line_blank(B._TextBuffer("   "))
        @test !B._tb_line_blank(B._TextBuffer("  x "))
    end
end
