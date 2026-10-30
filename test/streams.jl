# A stream is a reusable FIFO persisted in the current namespace's database:
# `post` delivers an object and `fetch` receives one, in order, any number of
# times. Each delivery is stored as `(obj sender=:user time=(time …))`, and the
# stream's own ACL gates the directions — `read` receives, `write` delivers.
@testset "streams" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evd(s) = air_eval(env, read_air(s))

    # ---- the value -----------------------------------------------------------
    @test ev("(stream? 1)") == "false"
    @test ev("(stream? (stream))") == "true"
    @test ev("(namespace .s0 (val s (stream)))") == "naught"
    @test ev("(stream? .s0.s)") == "true"
    # a stream prints as an opaque handle and never inspects its queue
    @test occursin(r"^#<stream [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}>$",
                   air_string(evd(".s0.s")))
    @test ev("(do (stream maxsize=0) (except ?e :caught))") == ":caught"
    @test ev("(do (stream maxsize=1.5) (except ?e :caught))") == ":caught"
    @test ev("(do (stream 3) (except ?e :caught))") == ":caught"

    # ---- delivering and receiving -------------------------------------------
    @test ev("(namespace .st (val s (stream)))") == "naught"
    # `post` returns the stored envelope: the object plus sender and instant
    envelope = evd("(post .st.s 1)")
    @test air_string(AirDB.to_form(envelope.seq[1])) == "1"
    @test air_string(AirDB.to_form(envelope.map[Symbol(":sender")])) == ":air"
    @test ev("(time? (get (get (post .st.s 2) :time)))") == "true"
    @test ev("(get (post .st.s 3) :sender)") == ":air"
    @test ev("(get (post .st.s 4) :sender)") == ":air"
    @test ev("(get (post .st.s 5) :sender)") == ":air"
    @test ev("(count .st.s)") == "5"
    # reading the stream as a value or through `get` does not consume anything
    @test ev("(stream? (value .st.s))") == "true"
    @test ev("(stream? (get .st.s))") == "true"
    @test ev("(count .st.s)") == "5"
    # FIFO order
    @test ev("(fetch .st.s)") == "1"
    @test ev("(fetch .st.s)") == "2"
    # `meta=true` returns the whole envelope instead of the object
    @test ev("(get (fetch .st.s meta=true) 1)") == "3"
    @test ev("(get (fetch .st.s meta=true) :sender)") == ":air"
    @test ev("(time? (get (fetch .st.s meta=true) :time))") == "true"
    @test ev("(count .st.s)") == "0"
    # nothing queued: an unbounded wait is not tested, but a timeout is `naught`
    @test ev("(fetch .st.s timeout=0.05)") == "naught"
    # `naught` is a legitimate object to deliver, so a timeout reports it too;
    # `meta=true` tells the two apart (an expiry is never an envelope)
    @test ev("(post .st.s naught)") != "naught"
    @test ev("(fetch .st.s)") == "naught"
    @test ev("(post .st.s naught)") != "naught"
    @test ev("(get (fetch .st.s meta=true) :sender)") == ":air"
    @test ev("(fetch .st.s timeout=0.05)") == "naught"
    # `post` stamps the sender and instant itself; declaring either is rejected
    @test ev("(do (post .st.s 1 sender=:bob) (except ?e :caught))") == ":caught"
    @test ev("(do (post .st.s 1 time=(now)) (except ?e :caught))") == ":caught"
    # an item that is not an envelope reads back unchanged either way
    @test ev("(count .st.s)") == "0"
    sf = evd(".st.s")
    AirDB.put!(sf, AirDB.Form(42))
    @test ev("(fetch .st.s)") == "42"
    AirDB.put!(sf, AirDB.Form(43))
    @test ev("(fetch .st.s meta=true)") == "43"

    # ---- a bounded stream ----------------------------------------------------
    @test ev("(namespace .bnd (val s (stream maxsize=1)))") == "naught"
    @test ev("(post .bnd.s 1)") != "naught"
    @test ev("(post .bnd.s 2 timeout=0.05)") == "naught"
    @test ev("(count .bnd.s)") == "1"
    @test ev("(fetch .bnd.s)") == "1"
    @test ev("(post .bnd.s 3)") != "naught"

    # ---- closing -------------------------------------------------------------
    @test ev("(open? .bnd.s)") == "true"
    @test ev("(stream? (close! .bnd.s))") == "true"
    @test ev("(open? .bnd.s)") == "false"
    # a close drains what was already queued, then raises
    @test ev("(fetch .bnd.s)") == "3"
    @test ev(raw"(do (fetch .bnd.s) (except (?tag ?&d) tag))") == ":stream-closed"
    @test ev(raw"(do (fetch .bnd.s timeout=0.05) (except (?tag ?&d) tag))") ==
          ":stream-closed"
    @test ev(raw"(do (post .bnd.s 4) (except (?tag ?&d) tag))") == ":stream-closed"
    @test ev("(do (open? 5) (except ?e :caught))") == ":caught"
    @test ev("(do (post 5 1) (except ?e :caught))") == ":caught"
    @test ev("(do (fetch 5) (except ?e :caught))") == ":caught"

    # ---- identity, equality, hashing, ordering, JSON -------------------------
    @test ev("(eq? .st.s .st.s)") == "true"
    @test ev("(do (namespace .st2 (val s (stream))) (eq? .st.s .st2.s))") == "false"
    @test ev("(compare .st.s .st.s)") == "0"
    @test ev("(do (namespace .st3 (val s (stream))) " *
             "(not (== (compare .st.s .st3.s) 0)))") == "true"
    @test ev("(== (hash .st.s) (hash .st.s))") == "true"
    @test ev("(do (namespace .st4 (val s (stream))) " *
             "(== (hash .st.s) (hash .st4.s)))") == "false"
    # JSON always writes a link, and reading it back finds the same stream
    # (the air string literal `"\"&uuid\""` is the JSON string `"&uuid"`)
    json = ev("(to-json .st.s)")
    @test startswith(json, "\"\\\"&")
    @test endswith(json, "\\\"\"")
    @test ev("(eq? .st.s (from-json (to-json .st.s)))") == "true"
    @test ev("(eq? (get (from-json (to-json (list .st.s))) 2) .st.s)") == "true"

    # ---- transactions --------------------------------------------------------
    @test ev("(namespace .txs (val s (stream)))") == "naught"
    # a committed post is durable ...
    @test ev("(stream? (tx (post .txs.s :a)))") == "false"
    @test ev("(fetch .txs.s)") == ":a"
    # ... while an aborted transaction drops its post
    @test ev("(do (tx (post .txs.s :b) (raise :boom)) (except ?e naught))") == "naught"
    @test ev("(count .txs.s)") == "0"
    # a bounded wait inside a transaction expires rather than deadlocks
    @test ev("(tx (fetch .txs.s timeout=0.05))") == "naught"

    # ---- persistence ---------------------------------------------------------
    @test ev("(namespace .prs (val s (stream)))") == "naught"
    @test ev("(post .prs.s :saved)") != "naught"
    env2 = Env(db = db)
    ev2(s) = air_string(air_eval(env2, read_air(s)))
    @test ev2("(fetch .prs.s)") == ":saved"
    @test ev2("(count .prs.s)") == "0"

    # ---- permissions: read receives, write delivers --------------------------
    @test ev("(create-user :bob)") == ":bob"
    @test ev("(create-user :alice)") == ":alice"
    @test ev("(namespace .pst (val s (stream)))") == "naught"
    # the entry must be visible for bob to reach the stream at all ...
    @test ev("(chmod! .pst read=(_=true) exec=(_=true))") != "naught"
    @test ev("(namespace .pst (chmod! s read=(_=true) exec=(_=true)))") != "naught"
    # ... and then the stream's own ACL gates each direction
    @test ev("(chmod! .pst.s read=(bob=true))") != "naught"
    @test ev("(post .pst.s :hello)") != "naught"
    @test ev("(as-user :bob (fetch .pst.s))") == ":hello"
    @test ev("(as-user :bob (count .pst.s))") == "0"
    @test ev(raw"(do (as-user :bob (post .pst.s :x)) (except (?tag ?&d) tag))") ==
          ":permission-denied"
    @test ev(raw"(do (as-user :alice (fetch .pst.s timeout=0.05)) (except (?tag ?&d) tag))") ==
          ":permission-denied"
    # granting write lets bob deliver, and the envelope names him
    @test ev("(chmod! .pst.s write=(bob=true))") != "naught"
    @test ev("(as-user :bob (post .pst.s :from-bob))") != "naught"
    @test ev("(post .pst.s :from-air)") != "naught"
    @test ev("(get (fetch .pst.s meta=true) :sender)") == ":bob"
    @test ev("(get (fetch .pst.s meta=true) :sender)") == ":air"
    @test ev("(get (permissions .pst.s) :owner)") == ":air"
    @test ev("(get (permissions .pst.s) :acl :read :bob)") == "true"
    # closing needs write
    @test ev(raw"(do (as-user :alice (close! .pst.s)) (except (?tag ?&d) tag))") ==
          ":permission-denied"
    @test ev("(as-user :bob (close! .pst.s))") != "naught"
end
