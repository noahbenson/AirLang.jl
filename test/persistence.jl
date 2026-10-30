# Persistence: the database a form belongs to, named volatiles, sync/status,
# form identity, the JSON codec, and cycle-safe printing. The database cases run
# against an in-memory database; the PostgreSQL cases are gated by
# AIRLANG_TEST_PG_URL, as in test/database.jl.
@testset "persistence" begin
    env = Env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    # The raw Julia leaf of a result (a string's value, say), for JSON tests.
    leaf(s) = AirLang._leafof(air_eval(env, read_air(s)))

    # ---- one database per namespace -----------------------------------------
    # `mut` works in the default environment: `.main` lives in the process
    # database, which is a MemoryDatabase by default.
    @test ev("(value (mut 1))") == "1"

    db = MemoryDatabase()
    open_airdb!(env, [:p], db)
    @test ev("(namespace .p.work (val m (mut 0)))") == "naught"
    @test ev("(set! .p.work.m 5)") == "5"
    @test ev(".p.work.m") == "(mut 5)"
    # A mutable made in `.main` belongs to the process store, not this database.
    @test ev("(do (namespace .p.work " *
             "(val bad (namespace .main (mut 1)))) " *
             "(except (:un-storable ?x) :unstorable))") == ":unstorable"

    # ---- named volatiles -----------------------------------------------------
    # `named-form` creates a volatile; the name table maps a name to a volatile.
    @test ev("(namespace .p (named-form :a create=true value=42))") == "(mut 42)"
    @test ev("(namespace .p (value (named-form :a)))") == "42"
    @test ev("(namespace .p (named-form :a))") == "(mut 42)"
    @test ev("(namespace .p (named-form \"a\"))") == "(mut 42)"
    @test ev("(namespace .p (named-form :missing create=naught))") == "naught"
    @test ev("(do (namespace .p (named-form :missing)) (except ?e :missing))") ==
        ":missing"
    @test ev("(do (namespace .p (named-form :a create=true)) " *
             "(except ?e :in-use))") == ":in-use"
    @test ev("(do (namespace .p (named-form \"air/ns/p\")) " *
             "(except ?e :reserved))") == ":reserved"

    # `value=` may name an existing volatile (an alias), and history is fixed.
    @test ev("(namespace .p (named-form :b create=true value=(named-form :a)))") ==
        "(mut 42)"
    @test ev("(namespace .p (value (named-form :b)))") == "42"
    @test ev("(namespace .p (named-form :h create=true history=false))") == "(mut naught)"
    @test ev("(namespace .p (history (named-form :h)))") == "false"
    @test ev("(namespace .p (history (named-form :a)))") == "true"
    # `name-form!` repoints a name at an existing volatile.
    @test ev("(namespace .p (name-form! :c (named-form :a)))") == "(mut 42)"
    @test ev("(namespace .p (value (named-form :c)))") == "42"

    # `named-forms` lists readable, non-internal names.
    @test ev("(namespace .p (named-forms))") ==
        "(a=(mut 42) b=(mut 42) c=(mut 42) h=(mut naught))"
    @test !occursin("air/", ev("(namespace .p (named-forms))"))

    # A logic set is just a named volatile; its name is normalized (`:s` → "s").
    @test ev("(namespace .p (logic-set :s))") ==
        "(mut (active=naught base=naught facts=naught ids=naught reasons=naught rules=naught why=naught))"
    @test occursin("s=(mut", ev("(namespace .p (named-forms))"))
    @test ev("(namespace .p (facts (logic-set :s)))") == "(')"

    # ---- persistence across environments ------------------------------------
    # A second environment over the same (still-open) database recovers the
    # names, the logic set, and the values.
    env2 = Env()
    open_airdb!(env2, [:p], db)
    ev2(s) = air_string(air_eval(env2, read_air(s)))
    @test ev2("(namespace .p (value (named-form :a)))") == "42"
    @test ev2("(namespace .p (facts (logic-set :s)))") == "(')"
    # A handle to a form that is not in the database is unloaded, and reading it
    # reports the missing form; a real one is loaded once its body is read.
    @test ev("(loaded? (form-at \"00000000-0000-0000-0000-000000000001\"))") ==
        "false"
    @test ev("(namespace .p (value (named-form :a)))") == "42"
    @test ev("(namespace .p (loaded? (named-form :a)))") == "true"

    # A filter, finalizer, and watch live in the mutable's metadata, so they
    # survive a reload even though AirDB rebuilds the inner volatile without
    # hooks; the next write reinstalls them from metadata.
    @test ev("(namespace .p.hooks (do " *
             "(val f (mut 1 filter=(if (_ < 0) 0 _))) " *
             "(val w (mut 0)) (val log (mut ())) " *
             "(watch w :k ((?key ?m ?old ?new) -> " *
             "(set! log (push (value log) new)))) naught))") == "naught"
    @test ev2("(set! .p.hooks.f -2)") == "-2"
    @test ev2("(value .p.hooks.f)") == "0"
    @test ev2("(namespace .p.hooks (value w))") == "0"
    @test ev2("(namespace .p.hooks (set! w 5))") == "5"
    @test ev2("(namespace .p.hooks (value log))") == "(5)"

    # ---- form identity ------------------------------------------------------
    id = leaf("(namespace .p (form-id (named-form :a)))")
    @test id isa AbstractString
    @test ev("(namespace .p (form-id (form-at \"$id\")))") == "\"$id\""
    @test ev("(namespace .p (value (form-at \"$id\")))") == "42"
    @test ev("(do (value (form-at \"00000000-0000-0000-0000-000000000000\")) " *
             "(except (:form-not-found ?id) :no-form))") == ":no-form"
    @test ev("(do (form-at \"not-a-uuid\") (except ?e :bad-id))") == ":bad-id"

    # ---- permissions --------------------------------------------------------
    @test ev("(create-user :bob)") == ":bob"
    # The default ACL is owner-only, so `bob` can neither open nor read the set.
    @test ev("(as-user :bob (do (logic-set :s) " *
             "(except (:permission-denied ?p ?t) :denied)))") == ":denied"
    # `named-forms` filters out names the user cannot read.
    @test !occursin("s=", ev("(as-user :bob (named-forms))"))
    @test ev("(namespace .p (chmod! (named-form :s) read=(bob=true)))") != ":err"
    @test ev("(as-user :bob (facts (logic-set :s)))") == "(')"
    # Reading is not writing: `bob` may query but not assert until granted.
    @test ev("(as-user :bob (do (assert (logic-set :s) (p 1)) " *
             "(except (:permission-denied ?p ?t) :denied)))") == ":denied"
    @test ev("(namespace .p (chmod! (named-form :s) write=(bob=true)))") != ":err"
    @test ev("(as-user :bob (assert (logic-set :s) (p 1)))") == "(' p 1)"
    @test ev("(namespace .p (facts (logic-set :s)))") == "(' (p 1))"

    # `bob` may create a named form in his own home, and `air` can see it; but he
    # may not overwrite an alias owned by someone else.
    @test ev("(as-user :bob (named-form :bobname create=true value=7))") == "(mut 7)"
    @test ev("(namespace .p (value (named-form :bobname)))") == "7"
    @test ev("(do (as-user :bob (name-form! :a (named-form :bobname))) " *
             "(except (:permission-denied ?p ?t) :denied))") == ":denied"

    # ---- sync and status ----------------------------------------------------
    @test ev("(status)") == "(error=naught pending=0)"
    @test ev("(sync)") == "naught"
    @test ev("(namespace .p (status))") == "(error=naught pending=0)"
    @test ev("(namespace .p (sync))") == "naught"

    # ---- JSON ---------------------------------------------------------------
    jv(s) = leaf(s)
    @test jv("(to-json 5)") == "5"
    @test jv("(to-json 1.5)") == "1.5"
    # A keyword is a symbol whose name carries its colon, so the JSON string is
    # `"::x"`; an air string keeps its reader quote inside the JSON string.
    @test jv("(to-json :x)") == "\"::x\""
    @test jv("(to-json \"hi\")") == "\"'hi\""
    @test jv("(to-json naught)") == "null"
    @test ev("(from-json \"5\")") == "5"
    @test ev("(from-json (to-json :x))") == ":x"
    @test ev("(from-json (to-json \"hi\"))") == "\"hi\""
    @test ev("(from-json \"null\")") == "naught"
    # A non-finite float is a marked JSON string; a string that merely looks like
    # one is still a string, since the `#` marker is not a string marker.
    @test jv("(to-json inf)") == "\"#inf\""
    @test jv("(to-json (0 - inf))") == "\"#-inf\""
    @test jv("(to-json nan)") == "\"#nan\""
    @test jv("(to-json \"#inf\")") == "\"'#inf\""
    @test ev("(from-json (to-json inf))") == "Inf"
    @test ev("(from-json (to-json (0 - inf)))") == "-Inf"
    @test ev("(nan? (from-json (to-json nan)))") == "true"
    @test ev("(from-json (to-json \"#inf\"))") == "\"#inf\""
    # A round trip preserves a container, including its keyword keys.
    @test ev("(let (f=(join () a=1 b=2)) (== (from-json (to-json f)) f))") == "true"
    # A volatile is a link, and reading the link back yields the same form.
    @test ev("(let (m=(mut 42)) (== m (get (from-json (to-json (join () x=m))) :x)))") ==
        "true"
    @test ev("(let (m=(mut 42)) (== (form-id m) " *
             "(form-id (get (from-json (to-json (join () x=m))) :x))))") == "true"
    @test ev("(do (from-json \"[\") (except ?e :bad-json))") == ":bad-json"

    # ---- cycle-safe printing ------------------------------------------------
    # A volatile that contains itself prints opaquely instead of overflowing.
    cyc = ev("(let (m=(mut 0)) (do (set! m (join () x=m)) m))")
    @test occursin("#<volatile", cyc)
    @test occursin("(mut", cyc)
    # ... and it still encodes to JSON (links are never expanded).
    @test occursin("@", ev("(let (m=(mut 0)) (do (set! m (join () x=m)) (to-json (value m))))"))

    # ---- a PostgreSQL database, when configured ------------------------------
    # Named forms, logic sets, identity, and sync are durable across a close and
    # reopen. Set AIRLANG_TEST_PG_URL (a libpq URL) to run this block.
    if haskey(ENV, "AIRLANG_TEST_PG_URL")
        url = ENV["AIRLANG_TEST_PG_URL"]
        root = Symbol("persist", string(rand(UInt32)))
        pgenv = Env()
        pv(s) = air_string(air_eval(pgenv, read_air(s)))
        @test startswith(pv("(open-airdb .$root url=\"$url\" create=true)"), "(mut ")
        @test pv("(namespace .$root (named-form :n create=true value=9))") == "(mut 9)"
        @test pv("(namespace .$root (assert (logic-set :ls) (p 1)))") == "(' p 1)"
        # A non-finite float survives the JSON codec, which has no such number.
        @test pv("(namespace .$root.num (val big inf) " *
                 "(val small (0 - inf)) (val notnum nan))") == "naught"
        nid = AirLang._leafof(air_eval(pgenv, read_air("(namespace .$root " *
                                                       "(form-id (named-form :n)))")))
        @test pv("(sync)") == "naught"
        @test pv("(get (status) :pending)") == "0"
        @test pv("(close-airdb .$root)") == "naught"

        pgdb = open_database(DatabaseConfig(url))
        pgenv2 = Env()
        pv2(s) = air_string(air_eval(pgenv2, read_air(s)))
        open_airdb!(pgenv2, [root], pgdb)
        @test pv2("(namespace .$root (value (named-form :n)))") == "9"
        @test pv2("(namespace .$root (facts (logic-set :ls)))") == "(' p 1)"
        @test pv2("(namespace .$root (form-id (form-at \"$nid\")))") == "\"$nid\""
        @test pv2("(get . :$root :num :big)") == "Inf"
        @test pv2("(get . :$root :num :small)") == "-Inf"
        @test pv2("(nan? (get . :$root :num :notnum))") == "true"
        @test pv2("(close-airdb .$root)") == "naught"

        # A real database can be the *process* store. The generated `.air` must
        # flush, including its non-finite constants, and `sync` is a working
        # barrier there.
        pgdb2 = open_database(DatabaseConfig(url))
        try
            pgenv3 = Env(db = pgdb2)
            pv3(s) = air_string(air_eval(pgenv3, read_air(s)))
            @test pv3("(value (mut 4))") == "4"
            @test pv3("(.air.inf)") == "Inf"
            @test pv3("(sync)") == "naught"
            @test pv3("(get (status) :pending)") == "0"
        finally
            close(pgdb2)
        end
    end
end
