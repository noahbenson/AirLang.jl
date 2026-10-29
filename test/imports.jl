# Materialized imports: `use`/`import` copy a readable `def`, share a readable
# `val`'s binding, and proxy an entry the importer may only execute (or one
# marked `anchor=true`). Also provenance, reimport/refresh, `unuse`, and `clear`.
@testset "imports" begin
    env = Env(db = MemoryDatabase())
    ev(s) = air_string(air_eval(env, read_air(s)))

    @test ev("(create-user :alice)") == ":alice"
    @test ev("(create-user :bob)") == ":bob"

    @test ev("(namespace .src (def (s ?x) (+ x 1)) (val k 5))") == "naught"
    @test ev("(namespace .dst (import .src))") == "naught"

    # ---- copies are ordinary entries of the importing namespace --------------
    @test ev("(.dst.s 1)") == "2"
    @test ev("(get . :dst :k)") == "5"
    # the copy records where it came from
    @test ev("(get (permissions (get . :dst :s)) :source)") == "(src)"
    # and is owned by the importing namespace's owner
    @test ev("(get (permissions (get . :dst :s)) :owner)") == ":air"

    # ---- a linked `val` shares the source binding ----------------------------
    # A `bind` on either side is seen by the other.
    @test ev("(using .src (bind (k=9) (.dst.k)))") == "(9)"
    @test ev("(using .dst (bind (k=8) (.src.k)))") == "(8)"
    @test ev("(get . :dst :k)") == "5"
    # deleting the source entry does not break the imported copy
    @test ev("(namespace .src (clear k))") == "naught"
    @test ev("(get . :dst :k)") == "5"
    # ... and the source's remaining definitions are unaffected
    @test ev("(.src.s 2)") == "3"
    @test ev("(.dst.s 2)") == "3"

    # ---- private `use` -------------------------------------------------------
    @test ev("(namespace .priv (use .src))") == "naught"
    @test ev("(do (get . :priv :s) (except ?e :hidden))") == ":hidden"
    @test ev("(namespace .priv (def (caller ?x) (s x)))") == "naught"
    @test ev("(.priv.caller 1)") == "2"

    # ---- refresh by reimport -------------------------------------------------
    @test ev("(namespace .rs (def (f ?x) (+ x 1)))") == "naught"
    @test ev("(namespace .rd (import .rs))") == "naught"
    @test ev("(.rd.f 1)") == "2"
    @test ev("(namespace .rs (def (f ?x) (+ x 10)))") == "naught"
    @test ev("(namespace .rd (import .rs))") == "naught"
    @test ev("(.rd.f 1)") == "11"

    # ---- clear and unuse -----------------------------------------------------
    @test ev("(namespace .ud (def (own ?x) x) (import .rs))") == "naught"
    @test ev("(get . :ud :own)") != "naught"
    @test ev("(namespace .ud (unuse .rs))") == "naught"
    @test ev("(get . :ud :own)") != "naught"
    @test ev("(do (get . :ud :f) (except ?e :gone))") == ":gone"
    @test ev("(namespace .ud2 (import .rs) (unuse .rs :f))") == "naught"
    @test ev("(do (get . :ud2 :f) (except ?e :gone))") == ":gone"
    # `clear` removes a named definition and `del` is an alias
    @test ev("(namespace .cl (def (a ?x) 1) (def (b ?x) 2) (clear a))") == "naught"
    @test ev("(do (get . :cl :a) (except ?e :gone))") == ":gone"
    @test ev("(get . :cl :b)") != "naught"
    @test ev("(namespace .cl (del b))") == "naught"
    @test ev("(do (get . :cl :b) (except ?e :gone))") == ":gone"
    # `(clear :all)` drops every definition and import but keeps subnamespaces
    @test ev("(namespace .cl.kid (def (z ?x) x))") == "naught"
    @test ev("(namespace .cl (def (a ?x) 1) (import .rs) (clear :all))") == "naught"
    @test ev("(do (get . :cl :a) (except ?e :gone))") == ":gone"
    @test ev("(do (get . :cl :f) (except ?e :gone))") == ":gone"
    @test ev("(get . :cl :kid)") != "naught"
    @test ev("(.cl.kid.z 4)") == "4"

    # ---- execute without read: a proxy --------------------------------------
    # `.px` is world read/execute; the entry itself is executable by everyone but
    # readable by air only. bob imports it and executes it through a proxy.
    @test ev("(namespace .px (def (g ?x) \"triple\" (* x 3)))") == "naught"
    @test ev("(chmod! .px read=(_=true) exec=(_=true) write=(bob=true))") != "naught"
    @test ev("(chmod! (get . :px :g) read=(_=false) exec=(_=true))") != "naught"
    @test ev("(as-user :bob (namespace .px (def (h ?x) (g x))))") == "naught"
    @test ev("(as-user :bob (.px.h 2))") == "6"
    # the proxy is stored in the importing namespace ...
    @test ev("(namespace .pxd)") == "naught"
    @test ev("(chmod! .pxd read=(_=true) exec=(_=true) write=(bob=true))") != "naught"
    @test ev("(as-user :bob (namespace .pxd (import (.px :only (g)))))") == "naught"
    @test ev("(as-user :bob (get . :pxd :g))") == "(ns-proxy (px) :g)"
    @test ev("(as-user :bob (.pxd.g 2))") == "6"
    # ... and does not expose the body
    @test ev("(as-user :bob (using .px (doc g)))") ==
          "\"no documentation found for g\""
    @test ev("(using .px (doc g))") == "\"(g ?x)\\n  triple\""
    # bob may not read the source entry, so a bare import is impossible
    @test ev("(as-user :bob (do (.px.g 2) (except ?e :err)))") == "6"

    # ---- anchor forces a proxy ----------------------------------------------
    @test ev("(namespace .an (def (q ?x) (+ x 1)))") == "naught"
    @test ev("(chmod! (get . :an :q) anchor=true)") != "naught"
    @test ev("(get (permissions (get . :an :q)) :anchor)") == "true"
    @test ev("(namespace .and (import (.an :only (q))))") == "naught"
    @test ev("(get . :and :q)") == "(ns-proxy (an) :q)"
    @test ev("(.and.q 1)") == "2"

    # ---- proxy to a missing source ------------------------------------------
    @test ev("(namespace .pm (def (p ?x) x))") == "naught"
    @test ev("(chmod! (get . :pm :p) anchor=true)") != "naught"
    @test ev("(namespace .pmd (import (.pm :only (p))))") == "naught"
    @test ev("(namespace .pm (clear p))") == "naught"
    @test ev("(do (.pmd.p 1) (except (:proxy-unresolved ?s) (list s)))") ==
          "(list (pm))"
end
