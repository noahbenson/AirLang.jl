# Ownership and access control: default owner-only access, `chmod`/`chown`/
# `permissions`, execute-without-read, `assume`, denial forms, printing, and the
# permissions of `mut` volatiles.
@testset "permissions" begin
    env = Env(db = MemoryDatabase())
    ev(s) = air_string(air_eval(env, read_air(s)))

    @test ev("(create-user :alice)") == ":alice"
    @test ev("(create-user :bob)") == ":bob"

    # ---- defaults ------------------------------------------------------------
    # A namespace and its entries belong to their creator. `.main` is air's
    # private namespace; `.air` is world read/execute.
    @test ev("(do (as-user :alice (get . :main)) (except ?e :err))") == ":err"
    @test ev("(as-user :alice (.air.inc 1))") == "2"
    # The namespace the user creates in its own home is theirs.
    @test ev(raw"(as-user :alice (namespace $ (def (mine ?x) (+ x 1))))") == "naught"
    @test ev(raw"(as-user :alice ($.mine 1))") == "2"
    @test ev("(do (as-user :bob (get . :sys)) (except ?e :err))") == ":err"

    # A permission failure is a catchable error form.
    @test ev("(as-user :bob (do (get . :main) " *
             "(except (:permission-denied ?p ?t) (list p t))))") ==
          "(list :read main)"

    # ---- chmod ---------------------------------------------------------------
    # air opens a namespace for reading and calling, and for bob to write.
    @test ev("(namespace .shared (def (f ?x) (+ x 10)))") == "naught"
    @test ev("(do (as-user :bob (get . :shared)) (except ?e :err))") == ":err"
    @test ev("(chmod! .shared read=(_=true) exec=(_=true) write=(bob=true))") != "naught"
    @test ev("(as-user :bob (get . :shared))") != "naught"
    # Entries created while the namespace is world-readable are world-executable.
    @test ev("(as-user :bob (namespace .shared (def (g ?x) (* x 3))))") == "naught"
    @test ev("(as-user :alice (.shared.g 2))") == "6"

    # ---- chown and permissions ----------------------------------------------
    @test ev("(chown! .shared :bob)") == ":bob"
    @test ev("(get (permissions .shared) :owner)") == ":bob"
    @test ev("(get (permissions .shared) :acl :write :bob)") == "true"
    # bob owns it now but has not granted alice write.
    @test ev("(do (as-user :alice (namespace .shared (def (h ?x) x))) " *
             "(except ?e :err))") == ":err"
    # ... until bob grants it.
    @test ev("(as-user :bob (chmod! .shared write=(_=true)))") != "naught"
    @test ev("(as-user :alice (namespace .shared (def (h ?x) x)))") == "naught"
    @test ev("(.shared.h 7)") == "7"

    # ---- execute without read ------------------------------------------------
    @test ev("(namespace .exec (def (g ?x) \"triple\" (* x 3)))") == "naught"
    @test ev("(chmod! .exec read=(_=true) exec=(_=true))") != "naught"
    # The entry itself is executable by everyone but readable by air only.
    @test ev("(chmod! (get . :exec :g) read=(_=false) exec=(_=true))") != "naught"
    @test ev("(as-user :bob (.exec.g 2))") == "6"
    # `doc`/`definitions` treat an unreadable definition as absent ...
    @test ev("(as-user :bob (using .exec (doc g)))") ==
          "\"no documentation found for g\""
    @test ev("(using .exec (doc g))") == "\"(g ?x)\\n  triple\""
    # ... and printing the namespace does not reveal the body.
    @test occursin("#<entry ", ev("(as-user :bob (form->string (get . :exec)))"))
    @test !occursin("triple", ev("(as-user :bob (form->string (get . :exec)))"))

    # ---- assume --------------------------------------------------------------
    # An owner can expose a controlled peek at its own data without granting
    # read on the data itself.
    @test ev("(namespace .vault (val hidden 41) (def (peek) (assume hidden)))") ==
          "naught"
    @test ev("(chmod! .vault read=(_=true) exec=(_=true))") != "naught"
    @test ev("(chmod! (get . :vault :peek) exec=(_=true) assume=(bob=true))") != "naught"
    # bob may not read the value directly ...
    @test ev("(as-user :bob (do (.vault.hidden) (except ?e :err)))") == ":err"
    # ... but `peek` assumes air's identity to read it.
    @test ev("(as-user :bob (.vault.peek))") == "41"
    # `assume` needs the explicit grant.
    @test ev("(namespace .vault (def (peek2) (assume hidden)))") == "naught"
    @test ev("(as-user :bob (do (.vault.peek2) (except ?e :err)))") == ":err"
    # Outside a definition there is no owner to assume.
    @test ev("(do (assume 1) (except ?e :err))") == ":err"

    # ---- mut permissions -----------------------------------------------------
    @test ev(raw"(as-user :bob (namespace $ (val m (mut 5))))") == "naught"
    @test ev(raw"(as-user :bob (value $.m))") == "5"
    # bob shares the mutable through a world-readable namespace, but the writable
    # value stays bob's.
    @test ev(raw"(as-user :bob (namespace .shared (val shared-m $.m)))") == "naught"
    @test ev("(as-user :alice (do (value (.shared.shared-m)) (except ?e :err)))") ==
          ":err"
    @test ev("(as-user :bob (value (.shared.shared-m)))") == "5"
end
