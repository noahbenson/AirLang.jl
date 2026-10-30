@testset "operators & math" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # infix operators
    @test ev("(2 ^ 10)") == "1024"
    @test ev("(7 // 2)") == "7//2"      # exact rational, as in Julia
    @test ev("(7 / 2)") == "3.5"
    @test ev("(div 7 2)") == "3"        # integer division
    @test ev("(+ 1//3 1//6)") == "1//2"
    @test ev("(+ 7//2 1)") == "9//2"
    @test ev("(7 mod 3)") == "1"
    @test ev("(1 <= 2)") == "true"
    @test ev("(3 >= 2)") == "true"
    @test ev("(1 != 2)") == "true"
    @test ev("(2 ^ (3 ^ 2))") == "512"
    @test ev("(^ 2 10)") == "1024"

    # symbolic on non-numbers
    @test ev("(x ^ 2)") == "(x ^ 2)"
    @test ev("(2 ^ x)") == "(2 ^ x)"
    @test ev("(x <= y)") == "(x <= y)"

    # constants
    @test ev("pi") == "3.141592653589793"
    @test ev("(> pi 3)") == "true"

    # math functions
    @test ev("(sqrt 16)") == "4.0"
    @test ev("(abs -3)") == "3"
    @test ev("(sign -2)") == "-1"
    @test ev("(min 3 1 2)") == "1"
    @test ev("(max 3 1 2)") == "3"
    @test ev("(gcd 12 18)") == "6"
    @test ev("(lcm 4 6)") == "12"
    @test ev("(factorial 5)") == "120"
    @test ev("(binomial 5 2)") == "10"
    @test ev("(floor 3.7)") == "3.0"
    @test ev("(round 3.2)") == "3.0"
    @test ev("(sin 0)") == "0.0"
    @test ev("(sqrt x)") == "(sqrt x)"

    # bitwise functions (symbolic on non-integers; a boolean is an integer)
    @test ev("(bit-and 12 10)") == "8"
    @test ev("(bit-or 12 10)") == "14"
    @test ev("(bit-xor 12 10)") == "6"
    @test ev("(bit-xor 1 3 5)") == "7"
    @test ev("(bit-not 0)") == "-1"
    @test ev("(bit-shift-left 1 4)") == "16"
    @test ev("(bit-shift-right 32 3)") == "4"
    @test ev("(bit-and true 1)") == "1"
    @test ev("(bit-and x 1)") == "(bit-and x 1)"
    @test ev("(bit-not x)") == "(bit-not x)"
    @test ev("(bit-shift-left x 2)") == "(bit-shift-left x 2)"
end
