# `memoize=` on a `def`: `:weak` (the default, also `true`) keeps results only
# while something else references them; `(:lru max)` is a bounded cache. The key
# is the call form under `eq?` equivalence, so `1` and `1.0` are distinct while
# map order does not matter. The configuration is stored with the definition; the
# cache is process-local and survives a namespace rebuild.
@testset "memoization" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- a bounded cache -----------------------------------------------------
    @test ev("(val memo-lc (mut 0))") == "naught"
    @test ev("(def (memo-lcount ?x) memoize=(:lru 2) " *
             "(do (set! memo-lc (+ (value memo-lc) 1)) x))") == "naught"
    @test ev("(memo-lcount 1)") == "1"
    @test ev("(memo-lcount 2)") == "2"
    @test ev("(memo-lcount 1)") == "1"          # hit, and it refreshes 1
    @test ev("(value memo-lc)") == "2"
    @test ev("(memo-lcount 3)") == "3"          # evicts 2, not 1
    @test ev("(value memo-lc)") == "3"
    @test ev("(memo-lcount 2)") == "2"          # miss: 1 was evicted, 3 kept
    @test ev("(value memo-lc)") == "4"
    @test ev("(memo-lcount 1)") == "1"          # miss
    @test ev("(value memo-lc)") == "5"
    @test ev("(memo-lcount 3)") == "3"          # miss
    @test ev("(value memo-lc)") == "6"

    # ---- the key is the resolved call under `eq?` ---------------------------
    @test ev("(val memo-kc (mut 0))") == "naught"
    @test ev("(def (memo-kcount ?x) memoize=(:lru 8) " *
             "(do (set! memo-kc (+ (value memo-kc) 1)) x))") == "naught"
    @test ev("(memo-kcount (+ 1 1))") == "2"
    @test ev("(memo-kcount 2)") == "2"          # the argument reduced first
    @test ev("(value memo-kc)") == "1"
    @test ev("(memo-kcount 2.0)") == "2.0"      # a distinct type is a distinct key
    @test ev("(value memo-kc)") == "2"
    @test ev("(memo-kcount (a x=1 y=2))") == "(a x=1 y=2)"
    @test ev("(memo-kcount (a y=2 x=1))") == "(a x=1 y=2)"   # same key
    @test ev("(value memo-kc)") == "3"

    # ---- weak mode -----------------------------------------------------------
    @test ev("(val memo-wc (mut 0))") == "naught"
    @test ev("(val memo-hold (mut 0))") == "naught"
    @test ev("(def (memo-wcount ?x) memoize=true " *
             "(do (set! memo-wc (+ (value memo-wc) 1)) (* x 3)))") == "naught"
    @test ev("(set! memo-hold (memo-wcount 2))") == "6"
    @test ev("(memo-wcount 2)") == "6"
    @test ev("(value memo-wc)") == "1"          # the held result kept it alive
    @test ev("(def (memo-wcount2 ?x) memoize=:weak (do " *
             "(set! memo-wc (+ (value memo-wc) 1)) (* x 3)))") == "naught"
    @test ev("(set! memo-hold (memo-wcount2 2))") == "6"
    @test ev("(memo-wcount2 2)") == "6"
    @test ev("(value memo-wc)") == "2"

    # ---- disabled ------------------------------------------------------------
    @test ev("(def (memo-none ?x) memoize=false " *
             "(do (set! memo-wc (+ (value memo-wc) 1)) x))") == "naught"
    @test ev("(memo-none 1)") == "1"
    @test ev("(memo-none 1)") == "1"
    @test ev("(value memo-wc)") == "4"
    @test ev("(def (memo-none2 ?x) memoize=naught " *
             "(do (set! memo-wc (+ (value memo-wc) 1)) x))") == "naught"
    @test ev("(memo-none2 1)") == "1"
    @test ev("(memo-none2 1)") == "1"
    @test ev("(value memo-wc)") == "6"

    # ---- the configuration round-trips --------------------------------------
    @test occursin("memoize=(:lru 2)", ev("(definitions memo-lcount)"))
    @test occursin("memoize=:weak", ev("(definitions memo-wcount)"))
    # a weak `true` is stored as `:weak`
    @test !occursin("memoize=true", ev("(definitions memo-wcount)"))
    # a disabled def emits no memoize entry at all
    @test !occursin("memoize", ev("(definitions memo-none)"))
    # the emitted form is itself a valid definition
    @test ev("(unhold (definitions memo-none))") == "naught"
    @test ev("(memo-none 2)") == "2"

    # ---- errors --------------------------------------------------------------
    @test_throws AirDefError air_eval(env, read_air("(val (memo-v) memoize=true 5)"))
    @test_throws AirDefError air_eval(env, read_air("(def (memo-e1 ?x) memoize=(:lru 0) 5)"))
    @test_throws AirDefError air_eval(env, read_air("(def (memo-e2 ?x) memoize=(:lru 2 3) 5)"))
    @test_throws AirDefError air_eval(env, read_air("(def (memo-e3 ?x) memoize=:bogus 5)"))
    @test_throws AirDefError air_eval(env, read_air("(def (memo-e4 ?x) memoize=(:bogus 2) 5)"))
    @test_throws AirDefError air_eval(env, read_air("(def (memo-e5 ?x) memoize=true)"))

    # ---- a namespace keeps its cache across a rebuild ------------------------
    @test ev("(val memo-nc (mut 0))") == "naught"
    @test ev("(namespace .memo-nm (def (ncount ?n) memoize=(:lru 4) " *
             "(do (set! memo-nc (+ (value memo-nc) 1)) (* n 2))))") == "naught"
    @test ev("(using .memo-nm (ncount 5))") == "10"
    @test ev("(using .memo-nm (ncount 5))") == "10"
    @test ev("(value memo-nc)") == "1"
    # an unrelated definition rebuilds the namespace's rules, not the cache
    @test ev("(namespace .memo-nm (def (memo-other ?n) (+ n 1)))") == "naught"
    @test ev("(using .memo-nm (ncount 5))") == "10"
    @test ev("(value memo-nc)") == "1"
    @test ev("(using .memo-nm (ncount 6))") == "12"
    @test ev("(value memo-nc)") == "2"
    # redefining the entry makes a fresh cache
    @test ev("(namespace .memo-nm (def (ncount ?n) memoize=(:lru 4) " *
             "(do (set! memo-nc (+ (value memo-nc) 100)) (* n 2))))") == "naught"
    @test ev("(using .memo-nm (ncount 5))") == "10"
    @test ev("(value memo-nc)") == "102"

    # ---- recursive use -------------------------------------------------------
    @test ev("(def (memo-fib ?n) memoize=(:lru 200) " *
             "(if (== n 0) 1 (== n 1) 1 (+ (memo-fib (- n 1)) (memo-fib (- n 2)))))") ==
        "naught"
    @test ev("(memo-fib 20)") == "10946"

    # ---- the table itself ----------------------------------------------------
    # A weak entry survives exactly as long as the result is referenced.
    t = AirLang._memo_table(AirLang._MemoConfig(:weak, 0))
    key = read_air("(memo-wc 7)")
    val = to_form(41)
    AirLang._memo_store!(t, key, val)
    @test AirLang._memo_lookup(t, key) == (true, val)
    val = nothing
    GC.gc(); GC.gc()
    @test AirLang._memo_lookup(t, key)[1] == false
    # The LRU table evicts by last use, and a hit refreshes recency.
    tl = AirLang._memo_table(AirLang._MemoConfig(:lru, 2))
    k(n) = read_air("(memo-t $n)")
    for n in (1, 2)
        AirLang._memo_store!(tl, k(n), to_form(n))
    end
    AirLang._memo_lookup(tl, k(1))
    AirLang._memo_store!(tl, k(3), to_form(3))
    @test AirLang._memo_lookup(tl, k(1))[1] == true
    @test AirLang._memo_lookup(tl, k(2))[1] == false
    @test AirLang._memo_lookup(tl, k(3))[1] == true
end
