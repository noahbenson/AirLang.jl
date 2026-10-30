# Implicit namespace logic sets: every namespace is a logic set, stored as the
# hidden named form `air/logic/<path>` and created lazily on the first write.
# Also the four fact/rule permissions, `query`, `defrule`, `ingest`, and the
# `depend` tombstone. Standalone logic sets keep their behavior (test/logic.jl).
@testset "logic sets in namespaces" begin
    env = Env(db = MemoryDatabase())
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- implicit sets -------------------------------------------------------
    # A namespace with no writes reads as an empty set; reads never create it.
    @test ev("(namespace .lns-a)") == "naught"
    @test ev("(facts .lns-a)") == "(')"
    @test ev("(rules .lns-a)") == "(')"
    # The set lives under the reserved `air/` prefix, so no listing shows it.
    @test ev("(namespace .lns-a (named-forms))") == "naught"
    @test AirLang.named_form(env.sysdb, "air/logic/lns-a"; create = nothing) === nothing
    # A bare operation inside a namespace block targets that namespace, and the
    # first write creates the set.
    @test ev("(namespace .lns-a (assert (p 1)))") == "(' p 1)"
    @test AirLang.named_form(env.sysdb, "air/logic/lns-a"; create = nothing) !== nothing
    @test ev("(facts .lns-a)") == "(' (p 1))"
    @test ev("(rules .lns-a)") == "(')"
    # An explicit target works from anywhere.
    @test ev("(assert .lns-a (p 2))") == "(' p 2)"
    @test ev("(facts .lns-a)") == "(' (p 1) (p 2))"
    @test ev("(retract .lns-a (p 2))") == "(' p 2)"
    @test ev("(facts .lns-a)") == "(' (p 1))"
    @test ev("(revise .lns-a (p ?x) (x=9))") == "naught"
    @test ev("(facts .lns-a)") == "(' (p 9))"
    @test ev("(revise-fact .lns-a (p 9) (p 10))") == "naught"
    @test ev("(facts .lns-a)") == "(' (p 10))"
    # Rules are facts of a separate universe.
    @test ev("(assert .lns-a (rule (p ?x) :> (q ?x)))") ==
        "(' rule (p ?x) :> (q ?x))"
    @test ev("(rules .lns-a)") == "(' (rule (p ?x) :> (q ?x)))"
    @test ev("(facts .lns-a)") == "(' (p 10) (q 10))"
    @test ev("(why .lns-a (q 10))") ==
        "((because (' rule (p ?x) :> (q ?x)) (' p 10)))"

    # A bare operation at the prompt targets the current namespace (`.main`).
    @test ev("(assert (main-fact 1))") == "(' main-fact 1)"
    @test ev("(facts .main)") == "(' (main-fact 1))"

    # A target namespace must exist; operations never create one.
    @test_throws AirEvalError air_eval(env, read_air("(assert .lns-missing (p 1))"))
    @test_throws AirEvalError air_eval(env, read_air("(facts .lns-missing)"))
    @test_throws AirEvalError air_eval(env, read_air("(logic 5 (assert (p 1)))"))

    # ---- atomicity -----------------------------------------------------------
    @test ev("(namespace .lns-at)") == "naught"
    # A `logic` block applies its edits together; an escaping error applies none.
    @test ev("(do (logic .lns-at (assert (a 1)) (assert (b 2)) (raise :boom)) " *
             "(except (:boom) :caught))") == ":caught"
    @test ev("(facts .lns-at)") == "(')"
    @test ev("(logic .lns-at (assert (a 1)) (assert (b 2)))") == "(' b 2)"
    @test ev("(facts .lns-at)") == "(' (a 1) (b 2))"
    # Reads in the block see the set as of entry.
    @test ev("(logic .lns-at (assert (z 1)) (query (z ?x)))") == "naught"
    @test ev("(facts .lns-at)") == "(' (a 1) (b 2) (z 1))"
    # Bare operations outside a block commit independently: a later failing
    # assertion leaves the earlier facts in place.
    @test ev("(assert .lns-at (d 4))") == "(' d 4)"
    @test ev("(assert .lns-at (rule (d 5) :> (raise :boom)))") ==
        "(' rule (d 5) :> (raise :boom))"
    @test ev("(do (assert .lns-at (d 5)) (except (:boom) :caught))") == ":caught"
    @test ev("(facts .lns-at)") == "(' (a 1) (b 2) (z 1) (d 4))"
    @test ev("(retract .lns-at (rule (d 5) :> (raise :boom)))") ==
        "(' rule (d 5) :> (raise :boom))"

    # ---- permissions ---------------------------------------------------------
    @test ev("(create-user :bob)") == ":bob"
    @test ev("(create-user :carol)") == ":carol"
    @test ev("(namespace .lns-perm (assert (p 1)) " *
             "(assert (rule (p ?x) :> (q ?x))))") == "(' rule (p ?x) :> (q ?x))"
    # The owner gets all four fact/rule permissions by default.
    @test ev("(get (permissions .lns-perm) :acl :writefact)") == "(air=true)"
    @test ev("(get (permissions .lns-perm) :acl :readrule)") == "(air=true)"
    # Nobody else starts with anything.
    @test ev("(as-user :bob (do (facts .lns-perm) " *
             "(except (:permission-denied ?p ?t) (list p t))))") ==
        "(list :readfact (lns-perm))"
    @test ev("(as-user :bob (do (rules .lns-perm) " *
             "(except (:permission-denied ?p ?t) (list p t))))") ==
        "(list :readrule (lns-perm))"
    @test ev("(as-user :bob (do (assert .lns-perm (z 1)) " *
             "(except (:permission-denied ?p ?t) (list p t))))") ==
        "(list :writefact (lns-perm))"
    # `readfact` reads facts (base and derived) but not rules, and cannot write.
    @test ev("(chmod! .lns-perm readfact=(bob=true))") != ":err"
    @test ev("(as-user :bob (facts .lns-perm))") == "(' (p 1) (q 1))"
    @test ev("(as-user :bob (query .lns-perm (p ?x)))") == "((x=1))"
    @test ev("(as-user :bob (do (rules .lns-perm) " *
             "(except (:permission-denied ?p ?t) (list p t))))") ==
        "(list :readrule (lns-perm))"
    # `why` on a namespace needs both read permissions.
    @test ev("(as-user :bob (do (why .lns-perm (q 1)) " *
             "(except (:permission-denied ?p ?t) (list p t))))") ==
        "(list :readrule (lns-perm))"
    @test ev("(chmod! .lns-perm readrule=(bob=true))") != ":err"
    @test ev("(as-user :bob (rules .lns-perm))") == "(' (rule (p ?x) :> (q ?x)))"
    @test ev("(as-user :bob (why .lns-perm (q 1)))") ==
        "((because (' rule (p ?x) :> (q ?x)) (' p 1)))"
    @test ev("(as-user :bob (query .lns-perm (rule (p ?y) :> (q ?y))))") ==
        "((y=?x))"
    @test ev("(as-user :bob (do (assert .lns-perm (z 1)) " *
             "(except (:permission-denied ?p ?t) (list p t))))") ==
        "(list :writefact (lns-perm))"
    # A mixed query needs both read permissions.
    @test ev("(chmod! .lns-perm readfact=(carol=true))") != ":err"
    @test ev("(as-user :carol (query .lns-perm (p ?x)))") == "((x=1))"
    @test ev("(as-user :carol (do (query .lns-perm (p ?x) " *
             "(rule (p ?y) :> (q ?y))) " *
             "(except (:permission-denied ?p ?t) (list p t))))") ==
        "(list :readrule (lns-perm))"
    # `writefact` and `writerule` are separate.
    @test ev("(chmod! .lns-perm writefact=(carol=true))") != ":err"
    @test ev("(as-user :carol (assert .lns-perm (w 5)))") == "(' w 5)"
    @test ev("(as-user :carol (do (assert .lns-perm (rule (w ?x) :> (v ?x))) " *
             "(except (:permission-denied ?p ?t) (list p t))))") ==
        "(list :writerule (lns-perm))"
    @test ev("(chmod! .lns-perm writerule=(carol=true))") != ":err"
    @test ev("(as-user :carol (assert .lns-perm (rule (w ?x) :> (v ?x))))") ==
        "(' rule (w ?x) :> (v ?x))"
    @test ev("(as-user :carol (retract .lns-perm (rule (w ?x) :> (v ?x))))") ==
        "(' rule (w ?x) :> (v ?x))"
    @test ev("(as-user :carol (retract .lns-perm (w 5)))") == "(' w 5)"
    # The core namespace is world-readable for facts and rules.
    @test ev("(get (permissions .air) :acl :readfact)") == "(_=true)"
    @test ev("(get (permissions .air) :acl :readrule)") == "(_=true)"

    # ---- query ---------------------------------------------------------------
    @test ev("(namespace .lns-q (assert (p 1)) (assert (p 2)) (assert (q 1)) " *
             "(assert (rule (p 1) :> (got 1))))") == "(' rule (p 1) :> (got 1))"
    @test ev("(query .lns-q (p ?x))") == "((x=1) (x=2))"
    # One satisfier with no bindings prints as `(naught)`; no satisfier is
    # `naught`. The canonicalization change keeps these distinct.
    @test ev("(query .lns-q (p 1))") == "(naught)"
    @test ev("(query .lns-q (nope ?x))") == "naught"
    @test ev("(query .lns-q (p ?x) (not (q ?x)))") == "((x=2))"
    # A `rule`-headed pattern searches the rule universe; constants in the rule
    # bind like constants in a fact.
    @test ev("(query .lns-q (rule (p ?y) :> (got ?z)))") == "((y=1 z=1))"
    # A mixed block searches both universes.
    @test ev("(query .lns-q (p ?x) (rule (p ?y) :> (got ?z)))") ==
        "((x=1 y=1 z=1) (x=2 y=1 z=1))"
    # Satisfiers are deduplicated after anonymous wildcards bind nothing.
    @test ev("(namespace .lns-qd (assert (a 1)) (assert (a 2)) " *
             "(assert (b 3)) (assert (b 4)))") == "(' b 4)"
    @test ev("(query .lns-qd (a ?) (b ?))") == "(naught)"
    # Rest captures become ordinary bindings.
    @test ev("(namespace .lns-qr (assert (pair :a 1)) (assert (pair :b 2)))") ==
        "(' pair :b 2)"
    @test ev("(query .lns-qr (pair ?&r))") == "((r=(:a 1)) (r=(:b 2)))"
    # A standalone handle, a `logic` block, and a namespace body all target the
    # expected set; the result is plain (not held).
    @test ev("(let (s=(logic-set :lns-qh)) (assert s (p 1)) " *
             "(query s (p ?x)))") == "((x=1))"
    @test ev("(logic .lns-q (query (p ?x)))") == "((x=1) (x=2))"
    @test ev("(namespace .lns-q (query (p ?x)))") == "((x=1) (x=2))"
    @test ev("(let (a=(query .lns-q (p ?x))) (held? a))") == "false"

    # ---- defrule -------------------------------------------------------------
    @test ev("(namespace .lns-dr)") == "naught"
    # The arguments are raw: `(+ 1 2)` stays unreduced in the rule.
    @test ev("(logic .lns-dr (defrule (m (+ 1 2)) :> (n 3)))") ==
        "(' rule (m (+ 1 2)) :> (n 3))"
    @test ev("(rules .lns-dr)") == "(' (rule (m (+ 1 2)) :> (n 3)))"
    # A bare defrule targets the current namespace and takes `reason=`.
    @test ev("(defrule (dr-p ?x) :> (dr-q ?x) reason=:mine)") ==
        "(' rule (dr-p ?x) :> (dr-q ?x))"
    @test ev("(assert (dr-p 1))") == "(' dr-p 1)"
    @test ev("(why .main (dr-q 1))") ==
        "((because (' rule (dr-p ?x) :> (dr-q ?x)) (' dr-p 1)))"
    @test_throws AirEvalError air_eval(env,
        read_air("(defrule (p ?x) :> (q ?x) foo=1)"))
    @test_throws AirEvalError air_eval(env, read_air("(defrule)"))

    # ---- ingest --------------------------------------------------------------
    @test ev("(namespace .lns-src (assert (p 1)) (assert (p 1)) " *
             "(assert (rule (p ?x) :> (q ?x))))") == "(' rule (p ?x) :> (q ?x))"
    @test ev("(facts .lns-src)") == "(' (p 1) (q 1))"
    @test ev("(namespace .lns-dst)") == "naught"
    # Base facts and rules are copied; the destination saturates to rederive the
    # consequences. Ingested facts carry the `:ingest` reason.
    @test ev("(logic .lns-dst (ingest .lns-src))") == "naught"
    @test ev("(facts .lns-dst)") == "(' (p 1) (q 1))"
    @test ev("(rules .lns-dst)") == "(' (rule (p ?x) :> (q ?x)))"
    @test ev("(why .lns-dst (p 1))") == "(:ingest)"
    @test ev("(why .lns-dst (q 1))") ==
        "((because (' rule (p ?x) :> (q ?x)) (' p 1)))"
    # A repeat ingest deduplicates.
    @test ev("(logic .lns-dst (ingest .lns-src))") == "naught"
    @test ev("(facts .lns-dst)") == "(' (p 1) (q 1))"
    # A source with no set is a no-op.
    @test ev("(namespace .lns-empty)") == "naught"
    @test ev("(logic .lns-dst (ingest .lns-empty))") == "naught"
    @test ev("(facts .lns-dst)") == "(' (p 1) (q 1))"
    @test_throws AirEvalError air_eval(env, read_air("(ingest .lns-src .lns-dst)"))
    # Inside a `logic` block the ingest joins the block, so an error rolls it
    # back with the block.
    @test ev("(namespace .lns-dst2)") == "naught"
    @test ev("(do (logic .lns-dst2 (ingest .lns-src) (raise :boom)) " *
             "(except (:boom) :caught))") == ":caught"
    @test ev("(facts .lns-dst2)") == "(')"

    # Ingest checks exactly the permissions it uses, before any mutation.
    @test ev("(namespace .lns-isrc (assert (p 1)) " *
             "(assert (rule (p ?x) :> (q ?x))))") == "(' rule (p ?x) :> (q ?x))"
    @test ev("(namespace .lns-idst)") == "naught"
    @test ev("(chmod! .lns-isrc readfact=(bob=true) readrule=(bob=true))") != ":err"
    @test ev("(chmod! .lns-idst writefact=(bob=true))") != ":err"
    @test ev("(as-user :bob (do (logic .lns-idst (ingest .lns-isrc)) " *
             "(except (:permission-denied ?p ?t) (list p t))))") ==
        "(list :writerule (lns-idst))"
    @test ev("(facts .lns-idst)") == "(')"
    @test ev("(chmod! .lns-idst writerule=(bob=true))") != ":err"
    @test ev("(as-user :bob (logic .lns-idst (ingest .lns-isrc)))") == "naught"
    @test ev("(facts .lns-idst)") == "(' (p 1) (q 1))"
    # A facts-only source needs no rule permissions.
    @test ev("(namespace .lns-fsrc (assert (f 1)))") == "(' f 1)"
    @test ev("(namespace .lns-fdst)") == "naught"
    @test ev("(chmod! .lns-fsrc readfact=(bob=true))") != ":err"
    @test ev("(chmod! .lns-fdst writefact=(bob=true))") != ":err"
    @test ev("(as-user :bob (logic .lns-fdst (ingest .lns-fsrc)))") == "naught"
    @test ev("(facts .lns-fdst)") == "(' (f 1))"

    # ---- depend --------------------------------------------------------------
    @test_throws AirEvalError air_eval(env,
        read_air("(depend .lns-src .lns-dst)"))
    @test occursin("depend is not implemented", try
        air_eval(env, read_air("(depend .lns-src .lns-dst)"))
    catch e
        e isa AirEvalError ? e.msg : ""
    end)

    # ---- persistence ---------------------------------------------------------
    # The set is an ordinary named form in the namespace's database, so it
    # survives a close and reopen; the hidden name is not listed.
    db = MemoryDatabase()
    penv = Env(db = MemoryDatabase())
    open_airdb!(penv, [Symbol("lns-root")], db)
    pv(s) = air_string(air_eval(penv, read_air(s)))
    @test pv("(namespace .lns-root.n (assert (p 1)))") == "(' p 1)"
    penv2 = Env(db = MemoryDatabase())
    open_airdb!(penv2, [Symbol("lns-root")], db)
    pv2(s) = air_string(air_eval(penv2, read_air(s)))
    @test pv2("(facts .lns-root.n)") == "(' (p 1))"
    @test pv2("(namespace .lns-root.n (named-forms))") == "naught"
    @test AirLang.named_form(db, "air/logic/lns-root/n"; create = nothing) !== nothing
    # Lazy creation: a read does not create the set, a write does.
    db2 = MemoryDatabase()
    lenv = Env(db = MemoryDatabase())
    open_airdb!(lenv, [Symbol("lns-lazy")], db2)
    lv(s) = air_string(air_eval(lenv, read_air(s)))
    @test lv("(namespace .lns-lazy.n)") == "naught"
    @test lv("(facts .lns-lazy.n)") == "(')"
    @test AirLang.named_form(db2, "air/logic/lns-lazy/n"; create = nothing) === nothing
    @test lv("(assert .lns-lazy.n (p 1))") == "(' p 1)"
    @test AirLang.named_form(db2, "air/logic/lns-lazy/n"; create = nothing) !== nothing
end
