# Opened databases: `open-airdb`/`close-airdb`, root namespace creation, `@`
# attachment, database users, ACL/principal validation, the storable-form check,
# and persistence across environments sharing one database.
@testset "databases" begin
    # ---- opening, rooting, and attaching ------------------------------------
    db = MemoryDatabase()
    env = Env(db = MemoryDatabase())
    ev(s) = air_string(air_eval(env, read_air(s)))

    @test ev("(do (open-airdb .m) (except ?e :config-error))") == ":config-error"
    @test ev("(do (open-airdb .m dbname=\"x\") (except ?e :config-error))") ==
        ":config-error"

    @test open_airdb!(env, [:m], db) isa VolatileForm
    @test ev("(== @ .m)") == "true"
    @test env.dbs[(:m,)] === db
    @test ev("(do (open-airdb .m memory=true) (except ?e :already-open))") ==
        ":already-open"
    # A namespace at or under the root lives in the opened database.
    @test ev("(namespace .m.work (def (f ?x) (+ x 1)))") == "naught"
    @test ev("(.m.work.f 2)") == "3"
    @test ev("(@.work.f 3)") == "4"
    @test AirLang._ns_db(env, Symbol[:m, :work]) === db

    # ---- database users ------------------------------------------------------
    @test ev("(create-user :bob)") == ":bob"
    @test ev("(users)") == "(:air :bob)"
    # `bob`'s record is stored in the attached database; its permissions govern
    # access to namespaces there.
    @test ev("(as-user :bob (current-user))") == ":bob"
    @test ev("(do (as-user :bob (.m.work.f 2)) " *
             "(except (:permission-denied ?p ?t) :denied))") == ":denied"
    @test ev("(chmod! .m read=(bob=true) exec=(bob=true))") != ":err"
    @test ev("(chmod! .m.work read=(bob=true) exec=(bob=true))") != ":err"
    @test ev("(chmod! .m.work.f read=(bob=true) exec=(bob=true))") != ":err"
    @test ev("(as-user :bob (.m.work.f 2))") == "3"
    # The `@` root and homes are capabilities: `bob` reaches his home even
    # though the containing user records are air-only.
    @test startswith(ev("(as-user :bob \$)"), "(mut ")
    @test ev("(as-user :bob (namespace \$ (def (h ?x) (+ x 7))))") == "naught"
    @test ev("(as-user :bob (h 1))") == "8"

    # ---- ACL principals must be database users -------------------------------
    @test ev("(namespace .m.acl (def (q ?x) x))") == "naught"
    @test ev("(do (chmod! .m.acl read=(mallory=true)) (except ?e :bad-user))") ==
        ":bad-user"
    @test ev("(do (chmod! .m.acl hide=(mallory=true)) (except ?e :bad-user))") ==
        ":bad-user"
    @test ev("(do (chown! .m.acl :mallory) (except ?e :bad-user))") == ":bad-user"
    @test ev("(chmod! .m.acl read=(_=true))") != ":err"
    @test ev("(chown! .m.acl :bob)") == ":bob"
    @test ev("(permissions .m.acl)") ==
        "(acl=(exec=(air=true) read=(_=true) write=(air=true)) owner=:bob)"
    # `air` is always a principal.
    @test ev("(chmod! .m.acl read=(air=true))") != ":err"

    # ---- storable forms ------------------------------------------------------
    # `.air` is a volatile from the process database; it cannot be linked from a
    # form bound for this database.
    @test ev("(do (namespace .m.work (val v .air)) " *
             "(except (:un-storable ?x) :unstorable))") == ":unstorable"
    @test ev("(do (namespace .m.work (val w .main)) " *
             "(except (:un-storable ?x) :unstorable))") == ":unstorable"
    @test ev("(do (get .m.work :v) (except ?e :missing))") == ":missing"
    @test ev("(do (get .m.work :w) (except ?e :missing))") == ":missing"
    # A mutable created in a database namespace belongs to that database, so an
    # entry can store it; one created in `.main` belongs to the process store.
    @test ev("(namespace .m.acl (val mv (mut 1)))") == "naught"
    @test ev(".m.acl.mv") == "(mut 1)"
    @test ev("(set! .m.acl.mv 2)") == "2"
    @test ev(".m.acl.mv") == "(mut 2)"
    @test ev("(namespace .main (val sysmut (mut 1)))") == "naught"
    @test ev("(do (namespace .m.acl (val bad (.main.sysmut))) " *
             "(except (:un-storable ?x) :unstorable))") == ":unstorable"

    # ---- persistence and metadata -------------------------------------------
    # A fresh environment over the same (still-open) database recovers every
    # namespace, entry, user, and permission.
    env2 = Env(db = MemoryDatabase())
    ev2(s) = air_string(air_eval(env2, read_air(s)))
    open_airdb!(env2, [:m], db)
    @test ev2("(.m.work.f 2)") == "3"
    @test ev2("(users)") == "(:air :bob)"
    @test ev2("(as-user :bob (.m.work.f 2))") == "3"
    @test ev2("(permissions .m.work.f)") ==
        "(acl=(exec=(bob=true) read=(bob=true) write=(air=true)) owner=:air)"
    @test ev2("(permissions .m.work)") ==
        "(acl=(exec=(bob=true) read=(bob=true) write=(air=true)) owner=:air)"
    @test ev2("(permissions .m.acl)") ==
        "(acl=(exec=(air=true) read=(air=true) write=(air=true)) owner=:bob)"
    @test ev2("(as-user :bob (h 1))") == "8"

    # ---- a nested database root ---------------------------------------------
    # Opening a second database at a nested path makes the nested root win for
    # namespaces at or under it (`_ns_db` picks the longest prefix), and it
    # becomes the task's `@`.
    db2 = MemoryDatabase()
    @test open_airdb!(env, Symbol[:m, :sub], db2) isa VolatileForm
    @test ev("(== @ .m.sub)") == "true"
    @test ev("(namespace .m.sub.work (def (g ?x) (* x 5)))") == "naught"
    @test ev("(.m.sub.work.g 2)") == "10"
    @test ev("(.m.work.f 2)") == "3"
    @test env.dbs[(:m,)] === db
    @test env.dbs[(:m, :sub)] === db2
    @test AirLang._ns_db(env, Symbol[:m, :sub, :work]) === db2
    # Users are per database: `bob` (a user of `.m`) is not a user of `.m.sub`.
    @test ev("(users)") == "(:air)"
    @test ev("(do (as-user :bob 1) (except ?e :no-user))") == ":no-user"
    @test ev("(do (chmod! .m.sub read=(bob=true)) (except ?e :bad-user))") ==
        ":bad-user"
    @test ev("(create-user :erin)") == ":erin"
    @test ev("(users)") == "(:air :erin)"

    # ---- closing -------------------------------------------------------------
    # `close-airdb` also closes databases rooted beneath the closed one; `@`
    # detaches, and the root namespace is gone.
    @test ev("(do (close-airdb .m.nope) (except ?e :not-open))") == ":not-open"
    @test ev("(close-airdb .m)") == "naught"
    @test !haskey(env.dbs, (:m,))
    @test !haskey(env.dbs, (:m, :sub))
    @test ev("(== @ .)") == "true"
    @test ev("(do (.m.work.f 2) (except ?e :gone))") == ":gone"
    @test ev("(users)") == "(:air)"
    # The databases are closed, so a second close is an error.
    @test ev("(do (close-airdb .m) (except ?e :not-open))") == ":not-open"

    # ---- an opener who is not `air` -----------------------------------------
    # Opening a database creates the opener's user record; a system admin's
    # status carries into the database.
    dbenv = Env(db = MemoryDatabase())
    dv(s) = air_string(air_eval(dbenv, read_air(s)))
    @test dv("(create-user :carol)") == ":carol"
    @test dv("(set-admin :carol true)") == ":carol"
    db3 = MemoryDatabase()
    @test open_airdb!(dbenv, [:o], db3; opener = :carol) isa VolatileForm
    # A new root belongs to its opener, even when the call comes from Julia.
    @test dv("(permissions .o)") ==
        "(acl=(exec=(carol=true) read=(carol=true) write=(carol=true)) " *
        "owner=:carol)"
    @test dv("(as-user :carol (current-user))") == ":carol"
    @test dv("(as-user :carol (create-constituent :game))") == ":carol:game"
    @test startswith(dv("(as-user :carol:game \$)"), "(mut ")
    @test dv("(as-user :carol:game (namespace \$ (def (k ?x) (+ x 2))))") ==
        "naught"
    @test dv("(as-user :carol:game (k 1))") == "3"
    # A user of another environment is not a principal in this database.
    @test dv("(namespace .o.work (def (z ?x) x))") == "naught"
    @test dv("(do (chown! .o.work :bob) (except ?e :bad-user))") == ":bad-user"
    # A root may not be opened over an existing namespace.
    @test dv("(do (open-airdb .o memory=true) (except ?e :exists))") == ":exists"

    # A non-`air` user may root a database inside their own home; `@.x`
    # addresses a namespace in it, while `.x` stays the air root.
    ownenv = Env(db = MemoryDatabase())
    ov(s) = air_string(air_eval(ownenv, read_air(s)))
    @test ov("(create-user :dave)") == ":dave"
    @test startswith(ov("(as-user :dave (open-airdb mydb memory=true))"),
                     "(mut ")
    @test ov("(as-user :dave (namespace @.w (def (f ?x) (+ x 1))))") == "naught"
    @test ov("(as-user :dave (@.w.f 2))") == "3"
    @test ov("(do (as-user :dave (.w.f 2)) (except ?e :root-missing))") ==
        ":root-missing"
    # The user's home and its descendants (including the database root) belong
    # to the user.
    @test ov("(as-user :dave (namespace \$ (def (h ?x) (* x 4))))") == "naught"
    @test ov("(as-user :dave (h 2))") == "8"
    @test ov("(as-user :dave (users))") == "(:dave)"

    # Opening a root requires write on the parent namespace, so a non-`air` user
    # cannot root a database directly under `.`.
    rootenv = Env(db = MemoryDatabase())
    rv(s) = air_string(air_eval(rootenv, read_air(s)))
    @test rv("(create-user :dave)") == ":dave"
    @test rv("(do (as-user :dave (open-airdb .dave memory=true)) " *
             "(except ?e :denied))") == ":denied"
    @test !haskey(rootenv.dbs, (:dave,))

    # ---- a PostgreSQL database, when configured ------------------------------
    # Set AIRLANG_TEST_PG_URL (a libpq URL) to exercise a real database. The
    # test uses a fresh root each run, so repeated runs do not collide.
    if haskey(ENV, "AIRLANG_TEST_PG_URL")
        url = ENV["AIRLANG_TEST_PG_URL"]
        pgroot = Symbol("pg", string(rand(UInt32)))
        pgenv = Env(db = MemoryDatabase())
        pv(s) = air_string(air_eval(pgenv, read_air(s)))
        @test startswith(pv("(open-airdb .$pgroot url=\"$url\" create=true)"),
                         "(mut ")
        @test pv("(namespace .$pgroot.data (def (q ?x) (+ x 10)))") == "naught"
        @test pv("(.$pgroot.data.q 1)") == "11"
        @test pv("(close-airdb .$pgroot)") == "naught"
        pgdb = open_database(DatabaseConfig(url))
        pgenv2 = Env(db = MemoryDatabase())
        pv2(s) = air_string(air_eval(pgenv2, read_air(s)))
        open_airdb!(pgenv2, [pgroot], pgdb)
        @test pv2("(.$pgroot.data.q 1)") == "11"
        @test pv2("(close-airdb .$pgroot)") == "naught"
    end
end
