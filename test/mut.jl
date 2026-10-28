# `(tx body…)` joins an open transaction and yields the body's last value, so the
# outermost `tx` is the commit/rollback boundary. These run on the in-memory
# process database, so they need no Postgres.
@testset "tx" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    @test ev("(tx)") == "naught"
    @test ev("(tx 1 2 3)") == "3"
    @test ev("(tx (tx 5))") == "5"

    m = air_eval(env, read_air("(mut 0)"))
    AirLang.add_rule!(env.rules, Form(Symbol("tmm")), m)

    # an error escaping the outermost transaction rolls its writes back
    @test_throws AirThrown air_eval(env, read_air("(tx (set! tmm 1) (raise :boom))"))
    @test ev("(value tmm)") == "0"
    @test ev("(do (tx (set! tmm 1) (raise :boom)) (except (:boom)))") == "naught"
    @test ev("(value tmm)") == "0"

    # a caught error commits; a nested `tx` joins the outer transaction
    @test ev("(tx (set! tmm 7) (do (raise :boom) (except (:boom))))") == "naught"
    @test ev("(value tmm)") == "7"
    @test ev("(do (tx (tx (set! tmm 9) (raise :boom))) (except (:boom)))") == "naught"
    @test ev("(value tmm)") == "7"

    # the body's value is the last expression, and its writes commit
    @test ev("(tx 1 (set! tmm 8) 42)") == "42"
    @test ev("(value tmm)") == "8"
end

# `set!`, `swap!`/`alter!`, `get`, filters, finalizers, and watches. These run
# on the in-memory process database.
@testset "mutables" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    @test ev("(create-user :bob)") == ":bob"

    # `set!` returns the inserted value; `get` reads the mutable like `value`
    @test ev("(let (m=(mut 1)) (do (set! m 2) (value m)))") == "2"
    @test ev("(let (m=(mut 1)) (do (set! m 2) (get m)))") == "2"
    @test ev("(let (m=(mut 1)) (do (set! m 2) (get m 0)))") == "2"
    @test ev("(let (m=(mut 1)) (do (set! m 2) (get m 1)))") == "2"
    @test ev("(let (m=(mut 1)) (do (set! m 2) (get m)))") == "2"

    # swap!/alter! are one atomic read-modify-write
    @test ev("(let (m=(mut 1)) (swap! m (?x -> (x + 1))))") == "2"
    @test ev("(let (m=(mut 1)) (alter! m (?x -> (x + 1))))") == "2"
    @test ev("(let (m=(mut 1)) (swap! m (((?x ?y) -> (x + y))) 4))") == "5"
    @test ev("(let (m=(mut 1)) (do (swap! m (?x -> (x + 1))) (value m)))") == "2"

    # a filter applies to the creation value and to every write; a finalizer runs
    # at the end of the setting transaction. A replacement rule is applied as a
    # function; any other form is evaluated with `_` bound to the value.
    @test ev("(value (mut -5 filter=(if (_ < 0) 0 _)))") == "0"
    @test ev("(let (m=(mut 1 filter=(if (_ < 0) 0 _))) (do (set! m -3) (value m)))") == "0"
    @test ev("(let (m=(mut 1 filter=(?x -> (x * 2)))) (do (set! m 3) (value m)))") == "6"
    @test ev("(let (m=(mut 1 finalize=(if (_ > 9) 9 _))) (do (set! m 20) (value m)))") == "9"
    @test ev("(let (m=(mut 1)) (do (set-filter! m (if (_ < 0) 0 _)) (set! m -2) (value m)))") == "0"
    @test ev("(let (m=(mut 1)) (do (set-finalize! m (if (_ > 9) 9 _)) (set! m 20) (value m)))") == "9"
    @test ev("(let (m=(mut 1)) (do (set-filter! m (if (_ < 0) 0 _)) (set-filter! m naught) (set! m -2) (value m)))") == "-2"

    # watches: `(fn key mutable old new)`, once per mutable per transaction,
    # fired inside the transaction before it commits.
    wm = air_eval(env, read_air("(mut 0)"))
    wl = air_eval(env, read_air("(mut ())"))
    AirLang.add_rule!(env.rules, Form(Symbol("wm")), wm)
    AirLang.add_rule!(env.rules, Form(Symbol("wlog")), wl)
    ev("(watch wm :k (((?key ?m ?old ?new) -> (set! wlog (push (value wlog) new)))))")
    @test ev("(set! wm 1)") == "1"
    @test ev("(value wlog)") == "1"
    @test ev("(tx (set! wm 2) (set! wm 5))") == "5"
    @test ev("(value wlog)") == "(1 5)"          # once, with the transaction's new value
    @test ev("(value wm)") == "5"

    # a watch table lists the key, the function, the registrar, and its namespace
    @test ev("(get (watches wm) :key)") == ":k"
    @test ev("(get (watches wm) :owner)") == ":air"
    @test ev("(get (watches wm) :ns)") == "main"

    # a throwing watch aborts the transaction and rolls the write back
    ev("(watch wm :boom (((?key ?m ?old ?new) -> (raise :boom))))")
    @test ev("(do (set! wm 100) (except (:boom)))") == "naught"
    @test ev("(value wm)") == "5"
    @test ev("(value wlog)") == "(1 5)"

    # unwatch removes one key or all of them
    ev("(unwatch wm :boom)")
    @test ev("(set! wm 6)") == "6"
    @test ev("(value wlog)") == "(1 5 6)"
    ev("(unwatch wm)")
    @test ev("(set! wm 7)") == "7"
    @test ev("(value wlog)") == "(1 5 6)"
    @test ev("(count (watches wm))") == "0"

    # installing a watch needs `watch` on the mutable (owner-only by default)
    @test ev("(do (as-user :bob (watch wm :x (?x -> x))) (except (:permission-denied ?p ?t) p))") == ":watch"
    # a mutable's owner may watch and filter it
    bobm = air_eval(env, read_air("(as-user :bob (mut 0))"))
    AirLang.add_rule!(env.rules, Form(Symbol("bobm")), bobm)
    @test ev("(as-user :bob (watch bobm :x (?x -> x)))") == "(mut 0)"
    @test ev("(get (as-user :bob (watches bobm)) :owner)") == ":bob"
    @test ev("(as-user :bob (set-filter! bobm (if (_ < 0) 0 _)))") == "(mut 0)"
    @test ev("(as-user :bob (do (set! bobm -4) (value bobm)))") == "0"
end

# `mut`/`set!` use the database of the current namespace. These tests run against
# the Postgres started by AirDB's `docker compose up -d` and are skipped when it
# is absent.
@testset "mut/set!" begin
    cfg = DatabaseConfig(;
        host = get(ENV, "AIRDB_TEST_HOST", "localhost"),
        port = parse(Int, get(ENV, "AIRDB_TEST_PORT", "5432")),
        dbname = get(ENV, "AIRDB_TEST_DBNAME", "airdb_test"),
        user = get(ENV, "AIRDB_TEST_USER", "airdb"),
        password = get(ENV, "AIRDB_TEST_PASSWORD", "airdb"),
        readpoolsize = 2)

    db = try
        create_database(cfg; overwrite = true)
    catch e
        @info "skipping mut/set tests: no test database" exception = e
        nothing
    end

    if db === nothing
        @test_skip "no test database"
    else
        try
            # `mut` uses the database of the current namespace; the default
            # environment's process database is an in-memory one.
            @test air_string(air_eval(default_env(), read_air("(value (mut 1))"))) == "1"

            env = Env(db = db)
            ev(s) = air_string(air_eval(env, read_air(s)))

            @test ev("(value (mut (1 2)))") == "(1 2)"

            # a `let` binding holds one mutable for the body's duration
            @test ev("(let (m=(mut (1 (2 3)))) (value m))") == "(1 (2 3))"
            @test ev("(let (m=(mut (1 (2 3)))) (do (set! m 2 2 9) (value m)))") == "(1 (2 9))"
            @test ev("(let (m=(mut (1 2 3))) (do (set! m (9 9 9)) (value m)))") == "(9 9 9)"

            # setting a persistent form with no mutable on the path raises
            @test_throws Exception air_eval(env, read_air("(set! (1 2 3) 1 9)"))

            # STM: an uncaught error aborts the enclosing transaction; a caught
            # one lets it commit. Bind a stable mutable to a symbol rule.
            m = air_eval(env, read_air("(mut 0)"))
            AirLang.add_rule!(env.rules, Form(Symbol("m")), m)

            @test_throws AirThrown tx() do
                air_eval(env, read_air("(set! m 1)"))
                air_eval(env, read_air("(raise :boom)"))
            end
            @test ev("(value m)") == "0"                # rolled back

            tx() do
                air_eval(env, read_air("(set! m 7)"))
                air_eval(env, read_air("(do (raise :boom) (except (:boom)))"))
            end
            @test ev("(value m)") == "7"                # committed
        finally
            close(db)
        end
    end
end
