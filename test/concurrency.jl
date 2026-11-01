# Concurrent readers and writers. A task that reads a namespace while another
# task redefines its entries or adds new ones must always see one complete
# compiled state: a `val` resolves through its binding (never to the bare
# symbol or to a stale definition), every rule a lookup indexes exists at that
# position in the same snapshot, and no definition is lost to a concurrent
# append. Most of the interesting behavior only appears with more than one
# Julia thread; the same assertions run at one thread as a plain regression.
@testset "concurrency" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    rounds = Threads.nthreads() > 1 ? 200 : 40

    # A `val` read by a spawned task while the parent recompiles the namespace
    # that defines it. The task must see the inherited binding (7), never the
    # definition value (10) and never an unresolved bare `x`.
    @test ev("(val x 10)") == "naught"
    bad = 0
    for i in 1:rounds
        ev("(bind (x=7) (val t (task x)))")
        ev("(await t)") == "7" || (bad += 1)
    end
    @test bad == 0

    # The same scope with no override resolves to the definition value.
    @test ev("(val t0 (task x))") == "naught"
    @test ev("(await t0)") == "10"

    # One task redefines `f` in a loop while another applies it. Every result
    # must be one of the two complete versions, in either order.
    @test ev("(namespace .cc (def (f ?x) (+ x 1)))") == "naught"
    @test ev("(val wr (task (do (for (i (range 1 $rounds)) " *
                   "(namespace .cc (def (f ?x) (+ x 2)))) naught)))") == "naught"
    @test ev("(val rr (task (let (bad=(mut 0)) " *
                   "(for (i (range 1 $rounds)) " *
                   "(do let=(r=(.cc.f 1)) " *
                   "(if (or (== r 2) (== r 3)) naught " *
                   "(set! bad (+ (value bad) 1))))) " *
                   "(value bad))))") == "naught"
    @test ev("(await wr)") == "naught"
    @test ev("(await rr)") == "0"

    # Concurrent appends to one namespace: no definition may be lost to a lost
    # update, and each remains callable afterwards.
    for i in 1:8
        @test ev("(val c$i (task (namespace .mt (def (h$i ?x) (* x $i)))))") ==
              "naught"
    end
    for i in 1:8
        @test ev("(await c$i)") == "naught"
    end
    for i in 1:8
        @test ev("(.mt.h$i 2)") == "$(2i)"
    end

    # A cyclic proxy import compiles each namespace once: the re-entrant sync
    # returns the committed snapshot instead of recursing.
    @test ev("(namespace .px (def (fx ?n) (+ n 1)))") == "naught"
    @test ev("(namespace .py (def (fy ?n) (+ n 2)))") == "naught"
    @test ev("(chmod! (get . :px :fx) anchor=true)") != "naught"
    @test ev("(chmod! (get . :py :fy) anchor=true)") != "naught"
    @test ev("(namespace .px (use .py) (def (callpy ?n) (fy n)))") == "naught"
    @test ev("(namespace .py (use .px) (def (callpx ?n) (fx n)))") == "naught"
    @test ev("(.px.callpy 1)") == "3"
    @test ev("(.py.callpx 1)") == "2"

    # A definition rolled back by an escaping error leaves no compiled trace.
    @test ev("(namespace .rb (def (k ?x) 1))") == "naught"
    @test ev("(do (tx (namespace .rb (def (k ?x) 2)) (raise :boom)) " *
             "(except ?e naught))") == "naught"
    @test ev("(.rb.k 0)") == "1"
end
