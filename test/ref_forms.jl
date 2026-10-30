# The database-backed reference forms: `delay`, `actor`, and `promise`. A delay
# holds a body and its context, computes once on the first `get`, and stores the
# result in the database; an actor is a persisted sequential worker; a promise is
# a single-assignment value that serializes as a link until delivered.
@testset "reference forms" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- delays --------------------------------------------------------------
    @test ev("(delay? (delay 1))") == "true"
    @test ev("(delay? 1)") == "false"
    @test ev("(get (delay (+ 1 2)))") == "3"
    @test ev("(get (delay (+ 1 2)) 0)") == "3"
    @test ev("(value (delay (+ 1 2)))") == "3"
    # a delay vanishes on the get path, just as a mutable does
    @test ev("(get (delay ((a 1) (b 2))) 2 2)") == "2"
    @test ev("(get (delay (a=1 b=2)) :a)") == "1"
    # a delay is not forced by printing or by serialization
    @test occursin("delay", ev("(to-json (delay (+ 1 2)))"))
    # free lexical names are captured by substitution, like a task
    @test ev("(let (x=5) (get (delay (* x 2))))") == "10"
    @test ev("(loop (i 2 acc 0) " *
             " (if (< i 4) (recur (+ i 1) (+ acc (get (delay (* i 10))))) acc))") == "50"
    # capture respects inner binders: a lambda's parameter shadows an enclosing
    # loop name, while a free name inside the lambda is still captured
    @test ev("(for (x (1)) (get (delay ((?x -> (+ x 1)) 5))))") == "(6)"
    @test ev("(for (x (1)) (get (delay ((?y -> (+ y x)) 5))))") == "(6)"
    # the active namespace layers are captured: `f` resolves from `.rfl`
    @test ev("(do (namespace .rfl (def (f ?x) (* x 3)) (val cell (mut 0))) naught)") ==
          "naught"
    @test startswith(ev("(using .rfl (set! cell (delay (f 4))))"), "#<delay :air")
    @test ev("(get (get .rfl.cell))") == "12"
    # the active `val` bindings are captured too
    @test ev("(do (namespace .rfb (val v 1) (val cell (mut 0))) naught)") == "naught"
    @test startswith(ev("(using .rfb (set! cell (delay v)))"), "#<delay :air")
    @test ev("(get (get .rfb.cell))") == "1"
    @test startswith(ev("(using .rfb (bind (v=9) (set! cell (delay v))))"), "#<delay :air")
    @test ev("(get (get .rfb.cell))") == "9"

    # an error in the body leaves the delay unforced, and a body that forces its
    # own delay is a catchable error rather than a runaway recursion
    @test ev("(let (d=(delay (raise :boom))) " *
             " (list (do (get d) (except ?e :caught)) (ready? d)))") ==
          "(list :caught false)"
    @test ev("(do (namespace .rfs (val d (delay (get d)))) naught)") == "naught"
    @test ev("(do (get .rfs.d) (except ?e (get e 3)))") ==
          "\"a delay cannot force itself\""

    # ---- the value is computed once and cached in the database ---------------
    @test ev("(do (namespace .rfc (val n (mut 0)) " *
             " (def (bump) (set! n (+ (get n) 1))) (val d (delay (bump)))) naught)") ==
          "naught"
    @test ev("(get .rfc.d)") == "1"
    @test ev("(get .rfc.n)") == "1"
    @test ev("(get .rfc.d)") == "1"
    @test ev("(get .rfc.n)") == "1"
    @test ev("(ready? .rfc.d)") == "true"

    # a fresh environment over the same database finds the cached value rather
    # than running the body again
    db = MemoryDatabase()
    denv = Env(db = MemoryDatabase())
    dv(s) = air_string(air_eval(denv, read_air(s)))
    open_airdb!(denv, [:rf], db)
    @test dv("(namespace .rf.work (val n (mut 0)) " *
             " (def (bump) (set! n (+ (get n) 1))) (val d (delay (bump))))") ==
          "naught"
    @test dv("(get .rf.work.d)") == "1"
    @test dv("(get .rf.work.n)") == "1"
    denv2 = Env(db = MemoryDatabase())
    dv2(s) = air_string(air_eval(denv2, read_air(s)))
    open_airdb!(denv2, [:rf], db)
    @test dv2("(ready? .rf.work.d)") == "true"
    @test dv2("(get .rf.work.d)") == "1"
    @test dv2("(get .rf.work.n)") == "1"

    # ---- actors --------------------------------------------------------------
    @test ev("(actor? (actor 0))") == "true"
    @test ev("(actor? 0)") == "false"
    @test ev("(get (actor 5))") == "5"
    # a send is deferred; `sync` flushes it
    @test ev("(let (a=(actor 0)) (send a (?x -> (+ x 1))) (sync) (get a))") == "1"
    @test ev("(let (a=(actor 0)) (tx (send a (?x -> (+ x 5)))) (sync) (get a))") == "5"
    @test ev("(let (a=(actor 5)) (reset! a 9) (sync) (get a))") == "9"
    @test ev("(let (a=(actor 0)) (send a (?x -> (+ x 1))) (send a (?x -> (* x 10))) " *
             " (sync) (get a))") == "10"
    # a send keeps the sender's layers and `val` bindings but does not capture
    # lexical names: a `let` has already substituted, and a `loop`/`for` binding
    # must not shadow the function's own parameter of the same name
    @test ev("(let (a=(actor 0)) (let (k=5) (send a (?x -> (+ x k)))) (sync) (get a))") == "5"
    @test ev("(let (a=(actor 0)) (for (x (1 2 3)) (send a (?x -> (+ x 1)))) " *
             " (sync) (get a))") == "3"
    # ... and a free loop name inside the sent function is captured
    @test ev("(let (a=(actor 0)) (for (x (1 2 3)) (send a (?y -> (+ y x)))) " *
             " (sync) (get a))") == "6"
    @test ev("(do (namespace .rfc (val v 100) (val a (actor 0))) naught)") == "naught"
    @test startswith(ev("(using .rfc (send a (?x -> (+ x v))))"), "#<actor ")
    @test ev("(sync)") == "naught"
    @test ev("(get .rfc.a)") == "100"
    # the actor's value is persisted in its namespace's database
    adb = MemoryDatabase()
    aenv = Env(db = MemoryDatabase())
    av(s) = air_string(air_eval(aenv, read_air(s)))
    open_airdb!(aenv, [:ar], adb)
    @test av("(namespace .ar.work (val a (actor 0)))") == "naught"
    @test startswith(av("(using .ar.work (send a (?x -> (+ x 1))))"), "#<actor ")
    @test av("(sync)") == "naught"
    aenv2 = Env(db = MemoryDatabase())
    av2(s) = air_string(air_eval(aenv2, read_air(s)))
    open_airdb!(aenv2, [:ar], adb)
    @test av2("(get .ar.work.a)") == "1"

    # ---- promises ------------------------------------------------------------
    @test ev("(promise? (promise))") == "true"
    @test ev("(promise? 0)") == "false"
    @test ev("(ready? (promise))") == "false"
    @test ev("(let (p=(promise)) (deliver p 3) (list (ready? p) (get p) (await p)))") ==
          "(list true 3 3)"
    # a promise serializes as a link whether it is pending or delivered, so a
    # reader waits on the same promise rather than on a copy of its value
    s = ev("(let (p=(promise)) (to-json p))")
    @test startswith(s, "\"\\\"~")
    d = ev("(let (p=(promise)) (deliver p 7) (to-json p))")
    @test startswith(d, "\"\\\"~")
    # a promise stored in a form is not forced by reading the form
    @test ev("(promise? (get (join () x=(promise)) :x))") == "true"

    # a promise persists through a database: an undelivered one is unready on
    # reload, and a delivered one carries its value across environments
    pdb = MemoryDatabase()
    penv = Env(db = MemoryDatabase())
    pv(s) = air_string(air_eval(penv, read_air(s)))
    open_airdb!(penv, [:pr], pdb)
    @test pv("(namespace .pr.work (val p (promise)))") == "naught"
    @test pv("(deliver .pr.work.p 7)") == "7"
    penv2 = Env(db = MemoryDatabase())
    pv2(s) = air_string(air_eval(penv2, read_air(s)))
    open_airdb!(penv2, [:pr], pdb)
    @test pv2("(ready? .pr.work.p)") == "true"
    @test pv2("(get .pr.work.p)") == "7"

    # a task returns that same kind of database promise
    @test pv("(namespace .pr.task (val p (task (+ 1 2))))") == "naught"
    @test pv("(await .pr.task.p)") == "3"
    @test pv2("(get .pr.task.p)") == "3"

    # ---- history and permission modes ---------------------------------------
    # an actor with history=false still commits and reloads its latest value
    @test ev("(let (a=(actor 0 history=false)) (send a (?x -> (+ x 3))) " *
             "(sync) (get a))") == "3"

    # a restricted namespace denies a non-owner before the delay's body runs:
    # the cached counter stays 0 under the failed read and 1 after the owner
    # forces it
    @test ev("(do (namespace .rfq (val n (mut 0)) (def (bump) (set! n (+ (get n) 1))) " *
             "(val d (delay (bump)))) naught)") == "naught"
    @test ev("(do (as-user :bob (get .rfq.d)) (except ?e :denied))") == ":denied"
    @test ev("(do (as-user :bob (get .rfq.n)) (except ?e :denied))") == ":denied"
    @test ev("(get .rfq.n)") == "0"
    @test ev("(get .rfq.d)") == "1"
    @test ev("(get .rfq.n)") == "1"
end
