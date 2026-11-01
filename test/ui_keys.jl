# The key parser: the control bytes the notebook relies on, and the two
# encodings that make Ctrl-Shift-J and Alt-Enter expressible.
@testset "ui keys" begin
    B = AirLang

    keys_of(bytes) = B._ui_kp_feed!(B._UiKeyParser(), collect(codeunits(bytes)))
    byte_keys(b) = B._ui_kp_feed!(B._UiKeyParser(), UInt8(b))

    @testset "control bytes" begin
        for (b, name) in ((0x0e, "Ctrl-n"), (0x10, "Ctrl-p"),
                          (0x04, "Ctrl-d"), (0x0a, "Ctrl-j"),
                          (0x12, "Ctrl-r"), (0x16, "Ctrl-v"))
            ks = byte_keys(b)
            @test length(ks) == 1
            @test B._ui_key_string(ks[1]) == name
        end
        @test B._ui_key_string(only(byte_keys(0x0d))) == "enter"
        @test B._ui_key_string(only(byte_keys(0x09))) == "tab"
        @test B._ui_key_string(only(byte_keys(0x7f))) == "backspace"
    end

    @testset "CSI-u" begin
        # `ESC [ code ; modifiers u`; modifiers are 1 + the bit set.
        k = only(keys_of("\e[106;6u"))              # Ctrl-Shift-J
        @test k.name === :char && k.char == 'j'
        @test k.ctrl && k.shift && !k.alt
        # An uppercase code point is the same key: terminals disagree.
        k2 = only(keys_of("\e[74;6u"))
        @test k2.name === :char && k2.char == 'j' && k2.ctrl && k2.shift
        # Named control keys stay named.
        k3 = only(keys_of("\e[13;2u"))
        @test k3.name === :enter && k3.shift && !k3.ctrl
        k4 = only(keys_of("\e[127;5u"))
        @test k4.name === :backspace && k4.ctrl
        # An unknown code point is nothing rather than a bogus key.
        @test isempty(keys_of("\e[0;1u"))
    end

    @testset "modifyOtherKeys and Alt-Enter" begin
        # `ESC [ 27 ; modifiers ; code ~`.
        k = only(keys_of("\e[27;3;13~"))            # Alt-Enter
        @test k.name === :enter && k.alt && !k.ctrl && !k.shift
        k2 = only(keys_of("\e[27;6;106~"))          # Ctrl-Shift-J
        @test k2.name === :char && k2.char == 'j' && k2.ctrl && k2.shift
        # The portable spelling: ESC then the key.
        k3 = only(keys_of("\e\r"))
        @test k3.name === :enter && k3.alt
        # Ordinary sequences are unaffected.
        k4 = only(keys_of("\e[1;2A"))
        @test k4.name === :up && k4.shift
        k5 = only(keys_of("\e[A"))
        @test k5.name === :up && !k5.shift
    end

    @testset "two adjacent Esc bytes are two keys" begin
        # The second is held until the escape timeout names it.
        kp = B._UiKeyParser()
        ks = B._ui_kp_feed!(kp, UInt8[0x1b, 0x1b])
        @test length(ks) == 1 && ks[1].name === :esc
        t = B._ui_kp_timeout!(kp, time() + 1.0)
        @test t !== nothing && t.name === :esc
    end
end
