# A scheduled event is a durable job registered in the creating user's
# `$.config.events`: it runs its body in its own task at a wall-clock time and
# delivers the value to a promise. `tx-at`/`tx-in` run the body as one
# transaction, and `durable=true` turns `task` into a registered job that reruns
# from the start after a restart, replaying its checkpoints. Every wait here is
# bounded and every job a test creates is cancelled or awaited in `finally`.
@testset "events" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evf(s) = air_eval(env, read_air(s))

    # Poll for a background worker to reach a condition.
    function waitfor(f; seconds = 5.0)
        t0 = time()
        while time() - t0 < seconds
            f() && return true
            sleep(0.02)
        end
        return f()
    end
    ready(name) = ev("(ready? $name)") == "true"
    wait_ready(name; seconds = 5.0) =
        waitfor(() -> ready(name); seconds = seconds)

    try
        # ---- firing ----------------------------------------------------------
        @test ev("(val p (do-in 0.05 (+ 1 2)))") == "naught"
        @test wait_ready("p")
        @test ev("(await p)") == "3"
        info = ev("(event p)")
        @test occursin("status=:done", info)
        @test occursin("result=3", info)
        @test occursin("kind=:event", info)
        @test occursin("owner=:air", info)
        @test occursin("attempts=1", info)

        # A time value works, and a time in the past fires at once.
        @test ev("(val q (do-at (+ (now) 0.05) (+ 2 3)))") == "naught"
        @test wait_ready("q")
        @test ev("(await q)") == "5"
        @test ev("(val r (do-at 0 (+ 3 3)))") == "naught"
        @test wait_ready("r")
        @test ev("(await r)") == "6"

        # ---- scheduled transactions -----------------------------------------
        @test ev("(val c (mut 0))") == "naught"
        @test ev("(val t1 (tx-in 0.05 (set! c 5) (raise :boom)))") == "naught"
        @test wait_ready("t1")
        @test ev("(await t1)") == "(error :boom)"
        @test ev("(value c)") == "0"
        @test occursin("status=:error", ev("(event t1)"))
        # An error the body catches itself commits the transaction.
        @test ev("(val t2 (tx-in 0.05 (set! c 7) (do (raise :boom) (except ?e :ok))))") ==
              "naught"
        @test wait_ready("t2")
        @test ev("(await t2)") == ":ok"
        @test ev("(value c)") == "7"

        # ---- registry and naming --------------------------------------------
        @test ev("(val n1 (do-in 5 name=:w1 (+ 1 1)))") == "naught"
        @test occursin("w1=", ev("(events)"))
        @test occursin("name=w1", ev("(event :w1)"))
        @test occursin("status=:pending", ev("(event :w1)"))
        # A string names a job too.
        @test occursin("name=w1", ev("(event \"w1\")"))
        # A live name cannot be reused.
        err = try
            ev("(do-in 5 name=:w1 (+ 1 1))")
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("event-exists", sprint(showerror, err))
        # An unnamed job gets a generated `e-…` name.
        @test ev("(val g (do-in 5 (+ 1 1)))") == "naught"
        ginfo = ev("(event g)")
        m = match(r"name=([^\s\)]+)", ginfo)
        @test m !== nothing && startswith(m.captures[1], "e-")
        @test occursin("status=:cancelled", ev("(cancel-event g)"))
        # A terminal record's name can be reused; the new entry shadows it.
        @test occursin("status=:cancelled", ev("(cancel-event :w1)"))
        @test ev("(val n2 (do-in 0.05 name=:w1 (+ 2 2)))") == "naught"
        @test wait_ready("n2")
        @test ev("(await n2)") == "4"
        @test occursin("status=:done", ev("(event :w1)"))

        # ---- cancel ----------------------------------------------------------
        @test ev("(val cp (do-in 5 (+ 1 1)))") == "naught"
        @test ev("(ready? cp)") == "false"
        @test occursin("status=:cancelled", ev("(cancel-event cp)"))
        @test ev("(ready? cp)") == "true"
        @test occursin(":event-cancelled", ev("(await cp)"))
        # Cancelling again is an idempotent no-op.
        @test occursin("status=:cancelled", ev("(cancel-event cp)"))
        # A cancel while the worker is sleeping is seen within a slice.
        @test ev("(val sl (do-in 30 (+ 1 1)))") == "naught"
        sleep(0.3)
        @test occursin("status=:cancelled", ev("(cancel-event sl)"))

        # ---- bindings --------------------------------------------------------
        @test ev("(val x 10)") == "naught"
        @test ev("(val b0 (do-in 0.05 x))") == "naught"
        @test wait_ready("b0")
        @test ev("(await b0)") == "10"
        @test ev("(bind (x=99) (val b1 (do-in 0.05 bindings=true x)))") == "naught"
        @test wait_ready("b1")
        @test ev("(await b1)") == "99"
        @test ev("(val b2 (do-in 0.05 bindings=(x=42) x))") == "naught"
        @test wait_ready("b2")
        @test ev("(await b2)") == "42"
        # A stream is a durable value: an event can capture one and post to it.
        @test ev("(val s (stream))") == "naught"
        @test ev("(val b3 (do-in 0.05 bindings=(s=s) (post s \"hi\")))") == "naught"
        @test wait_ready("b3")
        @test ev("(fetch s)") == "\"hi\""
        # `task` still inherits the current bindings by default.
        @test ev("(bind (x=99) (val tb0 (task x)))") == "naught"
        @test ev("(await tb0)") == "99"
        @test ev("(bind (x=99) (val tb1 (task bindings=false x)))") == "naught"
        @test ev("(await tb1)") == "10"
        @test ev("(val tb2 (task bindings=(x=7) x))") == "naught"
        @test ev("(await tb2)") == "7"
        # A binding value from another database fails at creation, not at firing.
        # A user rooted in an opened database has their job record in that
        # database, so a process-store mutable cannot be captured into it.
        ownenv = Env(db = MemoryDatabase())
        ov(s) = air_string(air_eval(ownenv, read_air(s)))
        @test ov("(create-user :dave)") == ":dave"
        @test startswith(ov("(as-user :dave (open-airdb mydb memory=true))"),
                         "(mut ")
        @test ov("(as-user :dave (namespace \$ (val v 1)))") == "naught"
        @test ov("(namespace .main (val pm (mut 1)))") == "naught"
        @test startswith(ov("(chmod! .main read=(_=true))"), "(mut ")
        @test ov("(do (as-user :dave (do-in 0.05 bindings=(v=(.main pm)) v)) " *
                  "(except (:un-storable ?e) :unstorable))") == ":unstorable"

        # ---- repeat ----------------------------------------------------------
        @test ev("(val rc (mut 0))") == "naught"
        @test ev("(val rp (do-in 0.05 repeat=true (set! rc (+ (value rc) 1))))") ==
              "naught"
        @test waitfor(() -> ev("(value rc)") != "0"; seconds = 5.0)
        sleep(0.12)
        nrep = parse(Int, ev("(value rc)"))
        @test nrep >= 2
        @test ev("(await rp)") == "1"
        fin = ev("(cancel-event rp)")
        @test occursin("status=:cancelled", fin)
        sleep(0.3)
        stopped = ev("(value rc)")
        sleep(0.3)
        @test ev("(value rc)") == stopped
        # A body error is recorded but does not stop a repeating schedule.
        @test ev("(val rc2 (mut 0))") == "naught"
        @test ev("(val rp2 (do-in 0.05 repeat=true
                    (set! rc2 (+ (value rc2) 1))
                    (raise :boom)))") == "naught"
        @test waitfor(() -> parse(Int, ev("(value rc2)")) >= 2; seconds = 5.0)
        @test waitfor(() -> occursin(":boom", ev("(event rp2)")); seconds = 5.0)
        @test !occursin("status=:done", ev("(event rp2)"))
        @test occursin("status=:cancelled", ev("(cancel-event rp2)"))

        # ---- durable tasks ---------------------------------------------------
        @test ev("(val dt (task durable=true name=:d1 (+ 2 3)))") == "naught"
        @test wait_ready("dt")
        @test ev("(await dt)") == "5"
        @test occursin("d1=", ev("(tasks)"))
        @test occursin("kind=:task", ev("(task-info :d1)"))
        @test occursin("status=:done", ev("(task-info :d1)"))
        @test ev("(val de (task durable=true (raise :nope)))") == "naught"
        @test wait_ready("de")
        @test ev("(await de)") == "(error :nope)"
        @test occursin("status=:error", ev("(task-info de)"))
        # Checkpoints replay: a rerun skips the steps a previous attempt recorded.
        @test ev("(val n (mut 0))") == "naught"
        @test ev("(val ck (task durable=true name=:ck
                    (checkpoint (set! n (+ (value n) 1)))
                    (set! n (+ (value n) 10))))") == "naught"
        @test wait_ready("ck")
        @test ev("(await ck)") == "11"
        @test ev("(value n)") == "11"
        vf = AirLang._job_lookup(env, :task, :ck, :air)
        @test vf !== nothing
        rec = AirLang._job_record_value(vf)
        cell = AirLang._job_field(rec, AirLang._JK_CHECKPOINTS)
        AirLang._tx_boundary(env) do
            setindex!(cell, AirLang._ns_form(Form[Form(5)]))
        end
        AirLang._job_update!(env, vf, r -> AirLang._job_set(r, Pair{Symbol,Form}[
            AirLang._JK_STATUS => Form(Symbol(":pending")),
            AirLang._JK_DELIVERED => Form(true)]))
        @test ev("(tasks-resume)") == "(resumed=1)"
        @test waitfor(() -> ev("(value n)") == "21"; seconds = 5.0)

        # ---- restart ---------------------------------------------------------
        # A crash leaves a `:running` record; a fresh environment resumes it.
        @test ev("(val d2 (do-at (+ (now) 3600) name=:d2 (+ 1 2)))") == "naught"
        sleep(0.4)
        vf2 = AirLang._job_lookup(env, :event, :d2, :air)
        AirLang._job_update!(env, vf2, r -> AirLang._job_set(r, Pair{Symbol,Form}[
            AirLang._JK_STATUS => Form(Symbol(":running")),
            AirLang._JK_AT => AirLang._mk_time(0.0)]))
        @test waitfor(() -> !AirLang._job_worker_running(vf2.id); seconds = 5.0)
        env3 = Env(db = db)
        ev3(s) = air_string(air_eval(env3, read_air(s)))
        @test ev3("(events-resume)") == "(resumed=1)"
        @test waitfor(() -> occursin("status=:done", ev3("(event :d2)"));
                      seconds = 5.0)

        # ---- permissions -----------------------------------------------------
        @test ev("(create-user :alice)") == ":alice"
        @test ev("(as-user :alice (val ap (do-in 5 name=:ae (+ 1 2))))") ==
              "naught"
        @test occursin("owner=:alice", ev("(event :ae :alice)"))
        @test occursin("ae=", ev("(events :alice)"))
        @test ev("(create-user :bob)") == ":bob"
        berr = try
            ev("(as-user :bob (event :ae :alice))")
            nothing
        catch e
            e
        end
        @test berr !== nothing
        @test ev("(as-user :bob (events))") == "naught"
        @test occursin("status=:cancelled", ev("(cancel-event :ae :alice)"))
        @test ev("(as-user :alice (await ap))") == "(error :event-cancelled name=ae)"
        # The body runs with the owner's identity.
        @test ev("(as-user :alice (val wp (do-in 0.05 (current-user))))") ==
              "naught"
        @test waitfor(() -> ev("(as-user :alice (ready? wp))") == "true";
                      seconds = 5.0)
        @test ev("(as-user :alice (await wp))") == ":alice"

        # ---- rejections ------------------------------------------------------
        for (src, needle) in [
                ("(tx (do-in 0.05 1))", "inside a transaction"),
                ("(do-at (+ (now) 1) 1 repeat=true)", "repeat="),
                ("(task name=:nope 1)", "name= requires durable=true"),
                ("(do-in 0.05)", "expected"),
                ("(do-in -1 1)", "negative")]
            e = try
                ev(src)
                nothing
            catch x
                x
            end
            @test e !== nothing
            @test occursin(needle, sprint(showerror, e))
        end
        # A checkpoint inside a durable run's transaction is refused at run time.
        @test ev("(val txc (task durable=true (tx (checkpoint 1))))") == "naught"
        @test wait_ready("txc")
        @test occursin("cannot run inside a transaction", ev("(await txc)"))
    finally
        # Leave no worker running.
        for name in ("p", "q", "r", "t1", "t2", "n1", "g", "n2", "cp", "b0", "b1",
                     "b2", "b3", "tb0", "tb1", "tb2", "rp", "rp2", "dt", "de",
                     "ck", "d2", "wp", "txc")
            try
                ev("(cancel-event $name)")
            catch
            end
            try
                ev("(cancel-task $name)")
            catch
            end
        end
        try
            ev("(cancel-event sl)")
        catch
        end
        try
            ev("(cancel-event :ae :alice)")
        catch
        end
    end
end
