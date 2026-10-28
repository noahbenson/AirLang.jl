# Randomized round-trip properties over a small grammar of forms: printing,
# evaluating the printed form, hashing, and the JSON codec should all agree with
# the original value. A tiny fixed-seed generator keeps a failure reproducible
# without adding a test dependency.
@testset "form round-trips" begin
    atoms = ["0", "1", "-2", "3.5", "2.0", "\"hi\"", "\"a b\"", ":a", ":b",
             "a", "b", "true", "false", "naught"]

    # A 64-bit linear congruential generator; `pick(rng, n)` is uniform in 0:n-1.
    mutable struct LCG
        state::UInt64
    end
    function pick(rng::LCG, n::Integer)
        rng.state = rng.state * 0x5851f42d4c957f2d + 0x14057b7ef767814f
        return Int((rng.state >> 33) % UInt32(n))
    end

    function gen(rng, d)
        d <= 0 && return atoms[pick(rng, length(atoms)) + 1]
        kind = pick(rng, 3)
        if kind == 1
            keys = unique([":k$(i)" for i in 1:pick(rng, 3)])
            items = vcat([gen(rng, d - 1) for _ in 1:pick(rng, 4)],
                         [k * "=" * gen(rng, d - 1) for k in keys])
            isempty(items) && return "naught"
            return "(" * join(items, " ") * ")"
        end
        "(" * join([gen(rng, d - 1) for _ in 1:pick(rng, 4)], " ") * ")"
    end

    function check_roundtrips(n::Integer, seed::Integer)
        env = default_env()
        rng = LCG(UInt64(seed))
        for _ in 1:n
            src = gen(rng, 3)
            x = air_eval(env, read_air(src))
            s = air_string(x)
            # printing and reading back is the same value, and it hashes alike
            y = air_eval(env, read_air(s))
            @test isequal(x, y)
            @test hash(x) == hash(y)
            # the JSON codec round-trips the same value
            j = air_eval(env, read_air("(to-json " * s * ")"))
            z = air_eval(env, read_air("(from-json " * air_string(j) * ")"))
            @test isequal(x, z)
        end
    end

    check_roundtrips(200, 1234)
end
