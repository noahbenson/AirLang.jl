# `(sandbox body…)` evaluates a block exactly as `tx` does, then aborts its
# transaction and yields the body's value, so nothing it wrote survives. The body
# runs in a transaction of its own (on a private task, since Air's `tx` joins an
# open transaction rather than nesting), which also means it reads committed
# state rather than an enclosing transaction's staged writes.
@testset "sandbox" begin
    env = Env(db = MemoryDatabase())
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- the value ----------------------------------------------------------
    @test ev("(sandbox (+ 1 2))") == "3"
    @test ev("(sandbox)") == "naught"
    @test ev("(sandbox (let (x=2) (* x 3)))") == "6"
    # The full `do` grammar works, and `let=`/`except` are inside the sandbox.
    @test ev("(sandbox let=(x=4) (+ x 1))") == "5"
    @test ev("(sandbox (do (raise :nope) (except (:nope) :ok)))") == ":ok"

    # ---- facts and rules ----------------------------------------------------
    @test ev("(assert (keep 1))") == "(' keep 1)"
    # The body sees its own writes ...
    @test ev("(sandbox (assert (gone 1)) (facts .main))") == "(' (keep 1) (gone 1))"
    # ... and none of them survive.
    @test ev("(facts .main)") == "(' (keep 1))"
    @test ev("(sandbox (assert (rule (keep ?x) :> (derived ?x))))") ==
        "(' rule (keep ?x) :> (derived ?x))"
    @test ev("(rules .main)") == "(')"
    @test ev("(facts .main)") == "(' (keep 1))"

    # ---- def, val, and mutables ---------------------------------------------
    @test ev("(def (seed ?x) (+ x 1))") == "naught"
    @test ev("(seed 1)") == "2"
    # A definition is usable inside the sandbox and gone afterwards.
    @test ev("(sandbox (def (sbx-def ?x) (* x 100)) (sbx-def 2))") == "200"
    @test ev("(sbx-def 2)") == "(sbx-def 2)"
    @test ev("(seed 1)") == "2"
    @test ev("(sandbox (val sbx-val 7) sbx-val)") == "7"
    @test ev("sbx-val") == "sbx-val"
    @test ev("(sandbox (let (m=(mut 0)) (set! m 5) (value m)))") == "5"

    # A namespace created in a sandbox is gone afterwards.
    @test ev("(sandbox (namespace .sbx-new (assert (p 1))) (facts .sbx-new))") ==
        "(' (p 1))"
    @test_throws AirEvalError air_eval(env, read_air("(facts .sbx-new)"))

    # ---- the enclosing transaction ------------------------------------------
    # The sandbox cannot abort the transaction around it: it reads that
    # transaction's *committed* state (its staged writes are invisible) and its
    # own writes are discarded, while the outer block still commits.
    @test ev("(tx (assert (staged 2)) (sandbox (facts .main)))") == "(' (keep 1))"
    @test ev("(facts .main)") == "(' (keep 1) (staged 2))"
    @test ev("(tx (assert (kept 3)) " *
             "(do (sandbox (assert (dropped 4)) (raise :boom)) " *
             "(except (:boom) naught)))") == "naught"
    @test ev("(facts .main)") == "(' (keep 1) (staged 2) (kept 3))"

    # ---- errors and control flow --------------------------------------------
    # An error aborts the sandbox (nothing it wrote survives) and propagates.
    @test ev("(do (sandbox (assert (nope 1)) (raise :boom)) " *
             "(except (:boom) :caught))") == ":caught"
    @test ev("(facts .main)") == "(' (keep 1) (staged 2) (kept 3))"
    @test_throws AirThrown air_eval(env, read_air("(sandbox (raise :unhandled))"))
    # A throw reaches an enclosing `catch=`, and one in the body is caught there.
    @test ev("(do catch=:tag (sandbox (throw :tag 5)) v)") == "5"
    @test ev("(sandbox (do catch=:tag (throw :tag 5) v))") == "5"
    # A notify reaches an enclosing handler, whose body runs in the sandbox.
    @test ev("(do (sandbox (notify :p 40)) (handle (:p ?n) (+ n 1)))") == "41"
end
