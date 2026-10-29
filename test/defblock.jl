# A `def` (and `val`) body is a block: it accepts the `do`/`tx` options
# (`let=`, `catch=`, `tx=`), level-1 `:let` markers, and trailing `except`/
# `handle`/`finally` clauses. The body is wrapped in a `(do …)`/`(tx …)` only
# when it needs one, so a single plain body form stays stored as written and
# `definitions` round-trips.
@testset "def/val block bodies" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- let= and :let -------------------------------------------------------
    @test ev("(def (dbk1 ?x) let=(y=(x + 1)) y)") == "naught"
    @test ev("(dbk1 4)") == "5"
    @test ev("(def (dbk2 ?x) :let (y=2) (+ x y))") == "naught"
    @test ev("(dbk2 3)") == "5"
    # markers nest and see the enclosing block's names, as in a `do`
    @test ev("(def (dbk3 ?x) :let (a=1) :let (b=(x + a)) (+ a b))") == "naught"
    @test ev("(dbk3 2)") == "4"

    # ---- catch= / throw ------------------------------------------------------
    @test ev("(def (dbc1 ?x) catch=:tag (if (< x 0) (throw :tag :undef)) (sqrt x))") ==
        "naught"
    @test ev("(dbc1 16)") == "4.0"
    @test ev("(dbc1 -1)") == ":undef"
    @test ev("(def (dbc2 ?x) catch=true (if (== x 0) (throw :zero)) (x + 1))") == "naught"
    @test ev("(dbc2 2)") == "3"
    @test ev("(dbc2 0)") == ":zero"

    # ---- except / handle / finally ------------------------------------------
    @test ev("(def (dbe1 ?x) (if (< x 0) (raise :neg x)) (* x 2))") == "naught"
    @test ev("(dbe1 3)") == "6"
    @test ev("(do (dbe1 -2) (except (:neg ?v) v))") == "-2"
    @test ev("(def (dbh1 ?x) (notify :sig x) (handle (:sig ?v) (+ v 1)))") == "naught"
    @test ev("(dbh1 4)") == "5"
    @test ev("(val db-f (mut 0))") == "naught"
    @test ev("(def (dbf1 ?x) (raise :q) (finally (set! db-f 9)))") == "naught"
    @test ev("(do (dbf1 1) (except (:q) :caught))") == ":caught"
    @test ev("(value db-f)") == "9"

    # ---- tx=true -------------------------------------------------------------
    @test ev("(val db-t1 (mut 0))") == "naught"
    # without a transaction, the write before the error survives
    @test ev("(def (dbn1 ?x) (set! db-t1 1) (raise :e))") == "naught"
    @test ev("(do (dbn1 1) (except (:e) 0))") == "0"
    @test ev("(value db-t1)") == "1"
    # with `tx=true` the whole body is one transaction, so the error aborts it
    @test ev("(set! db-t1 0)") == "0"
    @test ev("(def (dbx1 ?x) tx=true (set! db-t1 2) (raise :e))") == "naught"
    @test ev("(do (dbx1 1) (except (:e) 0))") == "0"
    @test ev("(value db-t1)") == "0"
    # an error caught inside the body commits
    @test ev("(def (dbx2 ?x) tx=true (set! db-t1 5) (raise :e) (except (:e) 0))") ==
        "naught"
    @test ev("(dbx2 1)") == "0"
    @test ev("(value db-t1)") == "5"
    # an escaping throw commits before it is rethrown, as an explicit `tx` does
    @test ev("(val db-t2 (mut 0))") == "naught"
    @test ev("(def (dbx3 ?x) tx=true (set! db-t2 1) (throw :tt 9))") == "naught"
    @test ev("(do catch=:tt (dbx3 1))") == "9"
    @test ev("(value db-t2)") == "1"
    # `tx=false` is the default: not a transaction
    @test ev("(def (dbn2 ?x) tx=false (set! db-t2 2) (raise :e))") == "naught"
    @test ev("(do (dbn2 1) (except (:e) 0))") == "0"
    @test ev("(value db-t2)") == "2"

    # ---- val block bodies ----------------------------------------------------
    @test ev("(val dbv1 let=(y=2) (+ 1 y))") == "naught"
    @test ev("dbv1") == "3"
    @test ev("(val dbv2 :let (y=2) (+ 1 y))") == "naught"
    @test ev("dbv2") == "3"
    @test ev("(val dbv3 catch=:t (throw :t 5))") == "naught"
    @test ev("dbv3") == "5"
    @test ev("(val dbv4 tx=true (raise :x) (except (:x) 9))") == "naught"
    @test ev("dbv4") == "9"
    # several body forms evaluate in sequence, as by `do`
    @test ev("(val dbv5 1 2)") == "naught"
    @test ev("dbv5") == "2"
    @test ev("(val (dbv6) let=(y=2) (+ 1 y))") == "naught"
    @test ev("(dbv6)") == "3"
    @test ev("(val dbv7 \"doc\" let=(y=2) y)") == "naught"
    @test ev("(doc dbv7)") == "\"dbv7\\n  doc\""

    # ---- docstrings ----------------------------------------------------------
    @test ev("(def (dbd1 ?x) \"docs here\" let=(y=(x + 1)) y)") == "naught"
    @test ev("(dbd1 4)") == "5"
    @test ev("(doc dbd1)") == "\"(dbd1 ?x)\\n  docs here\""
    @test ev("(def (dbd2 ?x) doc=\"d2\" catch=:t (if (== x 0) (throw :t 7) x))") ==
        "naught"
    @test ev("(doc dbd2)") == "\"(dbd2 ?x)\\n  d2\""

    # ---- `definitions` round-trips ------------------------------------------
    # a single plain body form is stored as written
    @test ev("(def (dbr1 ?x) (- x 1))") == "naught"
    @test ev("(definitions dbr1)") == "((' def (dbr1 ?x) (- x 1)))"
    # a block option wraps the body in a `do` (or `tx`)
    @test ev("(def (dbr2 ?x) tx=true (+ x 1))") == "naught"
    @test ev("(definitions dbr2)") == "((' def (dbr2 ?x) (tx (+ x 1))))"
    @test ev("(def (dbr3 ?x) catch=:t (if (== x 0) (throw :t 7) x))") == "naught"
    @test ev("(definitions dbr3)") ==
        "((' def (dbr3 ?x) (do (if (== x 0) (throw :t 7) x) catch=:t)))"
    @test ev("(def (dbr4 ?x) let=(y=(x + 1)) y)") == "naught"
    @test ev("(definitions dbr4)") == "((' def (dbr4 ?x) (do y let=(y=(x + 1)))))"
    # the emitted form is itself a valid definition
    @test ev("(unhold (first (definitions dbr2)))") == "naught"
    @test ev("(dbr2 1)") == "2"
    @test ev("(unhold (first (definitions dbr3)))") == "naught"
    @test ev("(dbr3 0)") == "7"
    @test ev("(unhold (first (definitions dbr4)))") == "naught"
    @test ev("(dbr4 4)") == "5"

    # ---- option validation ---------------------------------------------------
    @test_throws AirDefError air_eval(env, read_air("(def (dve1 ?x) tx=:yes 5)"))
    @test_throws AirDefError air_eval(env, read_air("(def (dve2 ?x) tx=1 5)"))
    @test_throws AirDefError air_eval(env, read_air("(def (dve3 ?x) bogus=1 5)"))
    @test_throws AirDefError air_eval(env, read_air("(val (dve4) bogus=1 5)"))
    @test_throws AirDefError air_eval(env, read_air("(def (dve5 ?x) \"a\" doc=\"b\" 5)"))
    @test_throws AirDefError air_eval(env, read_air("(def (dve6 ?x) let=(y=1))"))
    @test_throws AirDefError air_eval(env, read_air("(def (dve7 ?x) catch=:t)"))
    @test_throws AirDefError air_eval(env, read_air("(def (dve8 ?x) tx=true)"))
    @test_throws AirDefError air_eval(env, read_air("(val (dve9) memoize=true 5)"))
end
