# Cancellation: an evaluation stops when the token installed on its task is
# cancelled. The reducer polls the token once every 64 steps and the whole-tree
# walk verbs once every 1024 elements, so the check is amortized rather than a
# lock per step. `except`, `trace`, and `test` treat a cancellation as control
# flow, and a transaction a cancellation escapes aborts its writes. A job and a
# widget's evaluation are cancelled through the token each records, never by
# reaching into another task.
@testset "cancellation" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evd(s) = air_eval(env, read_air(s))
    B = AirLang

    # Long enough that the 64th reduction step is reached and the loop would
    # take minutes to finish on its own.
    LONG = "(loop (i 1) (if (< i 100000000) (recur (+ i 1)) i))"
    # Also past the 64-step poll, but it finishes in milliseconds, so a UI job
    # that fails to cancel fails the test instead of hanging the suite.
    SHORT = "(loop (i 1) (if (< i 200) (recur (+ i 1)) i))"

    # Evaluate `f` on this task with an already-cancelled token installed. The
    # task's own token is cleared afterward so a failed assertion cannot leak a
    # cancelled token into the rest of the suite.
    function cancelled(f; reason = "test")
        tok = CancelToken()
        Air.cancel!(tok, reason)
        Air.setcancaltoken!(tok)
        try
            return f()
        finally
            Air.setcancaltoken!(nothing)
        end
    end

    # The exception `f` throws, or `nothing`.
    thrower(f) = try
        f()
        nothing
    catch e
        e
    end

    # Whether any job worker is live in this process.
    live_workers() = lock(B._JOB_WORKERS_LOCK) do
        any(B._job_worker_live, values(B._JOB_WORKERS))
    end

    @testset "the reducer stops a cancelled evaluation" begin
        t0 = time()
        e = thrower(() -> cancelled(() -> air_eval(env, read_air(LONG))))
        @test e isa Cancelled
        @test occursin("cancelled: test", sprint(showerror, e))
        @test time() - t0 < 10
        # The cancellation did not damage the task: ordinary work resumes.
        @test ev("(+ 1 2)") == "3"
    end

    @testset "a cancelled token replaces and restores cleanly" begin
        tok = CancelToken()
        @test B._with_cancel_token(() -> 42; token = tok) == 42
        Air.cancel!(tok, "stop")
        @test thrower(() -> B._with_cancel_token(() -> 42; token = tok)) isa Cancelled
        # The task's own token was restored, so the next evaluation is normal.
        @test ev("(+ 1 2)") == "3"
    end

    @testset "a cancellation is control flow" begin
        @test thrower(() -> cancelled(() -> air_eval(env, read_air(
            "(do $LONG (except ?e :swallowed))")))) isa Cancelled
        @test thrower(() -> cancelled(() -> air_eval(env, read_air(
            "(trace $LONG)")))) isa Cancelled
        @test thrower(() -> cancelled(() -> air_eval(env, read_air(
            "(do (test :c (check true) $LONG))")))) isa Cancelled
    end

    @testset "a cancellation aborts a transaction" begin
        @test ev("(val ctm (mut 1))") == "naught"
        # The write is staged before the loop, so only the tx's rollback can
        # keep the mutable at 1.
        @test thrower(() -> cancelled(() -> air_eval(env, read_air(
            "(tx (set! ctm 2) $LONG)")))) isa Cancelled
        @test ev("(get ctm)") == "1"
    end

    @testset "the polls are amortized" begin
        tok = CancelToken()
        Air.cancel!(tok)
        Air.setcancaltoken!(tok)
        try
            p = B._CancelPoll()
            for _ in 1:B._CANCEL_WALK_MASK
                B._cancel_walk!(p)      # no check yet
            end
            @test true
            @test_throws Cancelled B._cancel_walk!(p)
            for i in 1:(B._CANCEL_STEP_MASK - 1)
                B._cancel_step!(i)      # 1…63: no check yet
            end
            @test true
            @test_throws Cancelled B._cancel_step!(B._CANCEL_STEP_MASK + 1)
        finally
            Air.setcancaltoken!(nothing)
        end
    end

    @testset "a long walk stops on a cancelled token" begin
        big = "(" * join(1:2000, " ") * ")"
        @test thrower(() -> cancelled(() -> air_eval(env, read_air(
            "(where $big 2000)")))) isa Cancelled
        @test thrower(() -> cancelled(() -> air_eval(env, read_air(
            "(sort $big)")))) isa Cancelled
    end

    @testset "a cancelled error has an air spelling" begin
        @test air_string(B._error_form(Cancelled(nothing, "why"))) ==
              "(error :cancelled reason=\"why\")"
        @test air_string(B._error_form(Cancelled(nothing, nothing))) ==
              "(error :cancelled)"
    end

    @testset "cancelling a parked job settles it and stops its worker" begin
        @test ev("(val cjp (do-in 60 (+ 1 2)))") == "naught"
        sleep(0.1)          # let the worker start and park on the due time
        @test occursin("status=:cancelled", ev("(cancel-event cjp)"))
        @test occursin("(error :event-cancelled", ev("(await cjp)"))
        @test ui_wait_for(() -> !live_workers(); secs = 5.0)
    end

    if Threads.nthreads() > 1
        @testset "cancelling a running job stops its body" begin
            @test ev("(val cjm (mut 0))") == "naught"
            @test ev("(val cjr (task durable=true name=:ct " *
                     "(do $LONG (set! cjm 1))))") == "naught"
            @test ui_wait_for(
                () -> occursin("status=:running", ev("(task-info :ct)")); secs = 10.0)
            @test occursin("status=:cancelled", ev("(cancel-task :ct)"))
            @test ev("(await cjr)") == "(error :task-cancelled name=ct)"
            @test ui_wait_for(() -> !live_workers(); secs = 10.0)
            # The body stopped before its write: only a completed body writes.
            @test ev("(get cjm)") == "0"
        end
    end

    @testset "Ctrl-C cancels a widget's job" begin
        w = evd("(ui-code text=\"(+ 1 2)\")")
        ui_open_form!(env, :canc1, w)
        inst = B._ui_lookup(env, Form(Symbol(":canc1")))
        c = B._ui_tree(inst)
        # The job sleeps past the Ctrl-C, so its evaluation starts with a
        # cancelled token and stops at once.
        @test B._comp_start_job!(c, inst,
            () -> (sleep(0.2); air_eval(env, read_air(SHORT));
                   ("(+ 1 2)", (:ok, Form[Form(3)]))))
        @test B._comp_running(c)
        @test B._comp_cancel_jobs!(c) == 1
        @test ui_wait_for(() -> (B._comp_tick!(c, inst); !B._comp_running(c)))
        @test any(l -> occursin("cancelled: ctrl-c", l.text), c.out)
        ev("(ui-close! :canc1)")
    end

    @testset "Ctrl-C in the renderer cancels the work" begin
        w = evd("(ui-code)")
        ui_open_form!(env, :canc2, w)
        inst = B._ui_lookup(env, Form(Symbol(":canc2")))
        c = B._ui_tree(inst)
        @test B._comp_start_job!(c, inst,
            () -> (sleep(0.2); air_eval(env, read_air(SHORT));
                   ("(+ 1 2)", (:ok, Form[Form(3)]))))
        (res, _) = ui_term_run(env, :canc2, [UInt8(0x03)]; settle = false)
        @test res[1] === :err
        @test air_string(res[2].form) == "(error :ctrl-c)"
        @test ui_wait_for(() -> (B._comp_tick!(c, inst); !B._comp_running(c)))
        @test any(l -> occursin("cancelled: ctrl-c", l.text), c.out)
        ev("(ui-close! :canc2)")
    end
end
