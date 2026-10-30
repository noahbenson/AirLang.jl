# The outer system (logic-set + RETE rules) runs against an in-memory database,
# so these tests need no Postgres. A rule is the structured
# `(rule conditions… instructions…)` form; `:>` is a tracked consequence and
# `:+` / `:-` / `:=` are side effects for an assertion / retraction / revision
# trigger.
@testset "logic-set / RETE" begin
    db = MemoryDatabase()
    env = AirLang.Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- rules, consequences, and provenance --------------------------------

    # Transitive closure. Conditions are an implicit conjunction; a `:>`
    # consequence is the derived fact and needs no explicit reason.
    @test ev("""
        (let (s=(logic-set :family))
          (assert s (parent :abe :bob))
          (assert s (parent :bob :carl))
          (assert s (rule (parent ?x ?y) :> (ancestor ?x ?y)))
          (assert s (rule (parent ?x ?z) (ancestor ?z ?y) :> (ancestor ?x ?y)))
          (facts s))
    """) == "(' (parent :abe :bob) (parent :bob :carl) (ancestor :abe :bob) (ancestor :bob :carl) (ancestor :abe :carl))"

    # provenance is `(because RULE PREMISES…)`
    @test ev("(let (s=(logic-set :family)) (why s (ancestor :abe :carl)))") ==
        "((because (' rule (parent ?x ?z) (ancestor ?z ?y) :> (ancestor ?x ?y)) " *
        "(' parent :abe :bob) (' ancestor :bob :carl)))"

    # the set lists its rules as held forms
    @test ev("(let (s=(logic-set :family)) (rules s))") == "(' (rule (parent ?x ?y) :> (ancestor ?x ?y)) (rule (parent ?x ?z) (ancestor ?z ?y) :> (ancestor ?x ?y)))"

    # retraction removes the base fact and everything derived only from it
    @test ev("(let (s=(logic-set :family)) (retract s (parent :bob :carl)) (facts s))") == "(' (parent :abe :bob) (ancestor :abe :bob))"

    # the set persists: a second environment on the same database sees it
    env2 = AirLang.Env(db = db)
    @test air_string(air_eval(env2, read_air("(facts (logic-set :family))"))) == "(' (parent :abe :bob) (ancestor :abe :bob))"

    # a derived fact is tracked: retracting the premise drops the conclusion
    @test ev("""
        (let (s=(logic-set :tracked))
          (assert s (p 1))
          (assert s (rule (p ?x) :> (q ?x)))
          (retract s (p 1))
          (facts s))
    """) == "(')"

    # a cascading diagnosis
    @test ev("""
        (let (s=(logic-set :diag))
          (assert s (rule (symptom ?s) :> (cause :overheat)))
          (assert s (rule (cause ?c) :> (fix :check-fan)))
          (assert s (symptom :loud))
          (facts s))
    """) == "(' (symptom :loud) (cause :overheat) (fix :check-fan))"

    # asserting the same fact twice makes one fact (two reason records)
    @test ev("""
        (let (s=(logic-set :once))
          (assert s (a 1))
          (assert s (a 1))
          (facts s))
    """) == "(' (a 1))"

    # a form containing `->` is an ordinary fact, not a rule
    @test ev("""
        (let (s=(logic-set :arrow))
          (assert s ((a ?x) -> (b ?x)))
          (facts s))
    """) == "(' ((a ?x) -> (b ?x)))"

    # an error during saturation aborts the whole operation
    @test ev("""
        (let (s=(logic-set :rb))
          (assert s (rule (go ?x) :> (raise :boom x)))
          (do (assert s (go 1)) (except (:boom ?e) :caught))
          (facts s))
    """) == "(')"

    # ---- triggers, consequence slots, and guard flips -----------------------

    # a revised premise gives the downstream rule a revision trigger, so only
    # its `:=` side effect runs (10 came from the initial `:+`)
    @test ev("""
        (let (c=(mut 0))
          (let (s=(logic-set :rev))
            (assert s (counter :a 1))
            (assert s (rule (counter ?k ?v) :> (q ?v)))
            (assert s (rule (q ?v) :+ (set! c (+ (value c) 10))
                                  := (set! c (+ (value c) 1))))
            (revise s (counter ?k ?v) (v=2))
            (value c)))
    """) == "11"

    # an unchanged `:>` slot creates no event at all
    @test ev("""
        (let (c=(mut 0))
          (let (s=(logic-set :slot))
            (assert s (counter :a 1))
            (assert s (rule (counter ?k ?v) :> (same :x) :> (q ?v)))
            (assert s (rule (same ?z) :+ (set! c (+ (value c) 1))))
            (revise s (counter ?k ?v) (v=2))
            (value c)))
    """) == "1"

    # `:if` gates the instructions and `:>` counts as naught when it fails:
    # opening the gate asserts, closing it retracts
    @test ev("""
        (let (s=(logic-set :gate))
          (assert s (counter :a 1))
          (assert s (rule (counter ?k ?v) :if (v < 2) :> (low ?v)))
          (facts s))
    """) == "(' (counter :a 1) (low 1))"
    @test ev("(let (s=(logic-set :gate)) (revise s (counter ?k ?v) (v=5)) (facts s))") == "(' (counter :a 5))"
    @test ev("(let (s=(logic-set :gate)) (revise s (counter ?k ?v) (v=1)) (facts s))") == "(' (counter :a 1) (low 1))"

    # a false gate at assertion time derives nothing
    @test ev("""
        (let (s=(logic-set :nogate))
          (assert s (p 1))
          (assert s (rule (p ?x) :if false :> (q ?x)))
          (facts s))
    """) == "(' (p 1))"

    # `:let` instructions are sequential; later ones see earlier values
    @test ev("""
        (let (s=(logic-set :lets))
          (assert s (n 3))
          (assert s (rule (n ?x) :let (y=(x * 2)) :let (z=(y + 1)) :> (out z)))
          (facts s))
    """) == "(' (n 3) (out 7))"

    # `_:` names the changed wildcards (to their new values) in `:=`
    @test ev("""
        (let (m=(mut 0))
          (let (s=(logic-set :underscore))
            (assert s (counter :a 1))
            (assert s (rule (counter ?k ?v) := (set! m (push _ :v))))
            (revise s (counter ?k ?v) (v=2))
            (value m)))
    """) == "(:v v=2)"

    # `:-` runs on a retraction with the vanished activation's bindings
    @test ev("""
        (let (s=(logic-set :retfx))
          (assert s (rule (p ?x) :- (assert (gone ?x) reason=:r)))
          (assert s (p 1))
          (retract s (p 1))
          (facts s))
    """) == "(' (gone 1))"

    # ---- reasons and revisions ----------------------------------------------

    # every explicit assertion records its label
    @test ev("""
        (let (s=(logic-set :labels))
          (assert s (a 1) reason=:r1)
          (assert s (a 1) reason=:r2)
          (assert s (a 1))
          (why s (a 1)))
    """) == "(:r1 :r2 naught)"

    # retracting one label leaves the fact (another reason holds it)
    @test ev("""
        (let (s=(logic-set :labels2))
          (assert s (a 1) reason=:r1)
          (assert s (a 1) reason=:r2)
          (retract s (a 1) reason=:r1)
          (facts s))
    """) == "(' (a 1))"
    @test ev("""
        (let (s=(logic-set :labels3))
          (assert s (a 1) reason=:r2)
          (retract s (a 1) reason=:r2)
          (facts s))
    """) == "(')"

    # revising one of two reasons leaves the old fact and asserts the new one,
    # so downstream sees an assertion
    @test ev("""
        (let (s=(logic-set :mr))
          (assert s (a 1) reason=:r1)
          (assert s (a 1) reason=:r2)
          (revise s (a ?x) (x=2) reason=:r1)
          (facts s))
    """) == "(' (a 1) (a 2))"
    @test ev("""
        (let (c=(mut 0))
          (let (s=(logic-set :mr2))
            (assert s (a 1) reason=:r1)
            (assert s (a 1) reason=:r2)
            (assert s (rule (a ?x) :+ (set! c (+ (value c) 10))
                                  := (set! c (+ (value c) 1))))
            (revise s (a ?x) (x=2) reason=:r1)
            (value c)))
    """) == "20"

    # revising the sole reason moves the fact's identity, so downstream sees a
    # revision rather than a retract/assert pair
    @test ev("""
        (let (c=(mut 0))
          (let (s=(logic-set :mr3))
            (assert s (a 1) reason=:r1)
            (assert s (rule (a ?x) :+ (set! c (+ (value c) 10))
                                  := (set! c (+ (value c) 1))))
            (revise s (a ?x) (x=2) reason=:r1)
            (value c)))
    """) == "11"

    # `revise` outside a handler defaults the reason to naught
    @test ev("""
        (let (s=(logic-set :defreason))
          (assert s (a 1))
          (revise s (a ?x) (x=2))
          (facts s))
    """) == "(' (a 2))"

    # a condition that matches nothing is a no-op
    @test ev("(let (s=(logic-set :nomatch)) (assert s (a 1)) (revise s (b ?x) (x=2)) (facts s))") == "(' (a 1))"

    # `revise` and `revise-fact` target base facts only
    @test_throws AirEvalError air_eval(env, read_air("""
        (let (s=(logic-set :deronly))
          (assert s (p 1))
          (assert s (rule (p ?x) :> (q ?x)))
          (revise s (q ?x) (x=2)))
    """))
    @test_throws AirEvalError air_eval(env, read_air("""
        (let (s=(logic-set :deronly2))
          (assert s (p 1))
          (assert s (rule (p ?x) :> (q ?x)))
          (revise-fact s (q 1) (q 2)))
    """))

    # a side effect must name its reason
    @test_throws AirEvalError air_eval(env, read_air("""
        (let (s=(logic-set :gated))
          (assert s (rule (p ?x) :+ (assert (q ?x))))
          (assert s (p 1)))
    """))

    # a handler may revise a base fact it names explicitly
    @test ev("""
        (let (s=(logic-set :hrev))
          (assert s (stat 5))
          (assert s (rule (p ?x) :+ (revise-fact (stat 5) (stat 6) reason=naught)))
          (assert s (p 1))
          (facts s))
    """) == "(' (p 1) (stat 6))"

    # ---- atomic `logic` blocks ----------------------------------------------

    @test ev("""
        (let (s=(logic-set :block))
          (logic s (assert (a 1)) (assert (a 2)))
          (facts s))
    """) == "(' (a 1) (a 2))"

    # reads inside the block see the snapshot from entry
    @test ev("""
        (let (s=(logic-set :snap))
          (assert s (a 1))
          (logic s (assert (b 1)) (facts s)))
    """) == "(' (a 1))"

    # two revisions in one call collapse to one revision event; in two calls
    # they do not
    @test ev("""
        (let (c=(mut 0))
          (let (s=(logic-set :collapse))
            (assert s (counter :a 1))
            (assert s (rule (counter ?k ?v) := (set! c (+ (value c) 1))))
            (logic s (revise s (counter ?k ?v) (v=2))
                    (revise s (counter ?k ?v) (v=3)))
            (value c)))
    """) == "1"
    @test ev("""
        (let (s=(logic-set :collapse)) (facts s))
    """) == "(' (counter :a 3))"
    @test ev("""
        (let (c=(mut 0))
          (let (s=(logic-set :nocollapse))
            (assert s (counter :a 1))
            (assert s (rule (counter ?k ?v) := (set! c (+ (value c) 1))))
            (revise s (counter ?k ?v) (v=2))
            (revise s (counter ?k ?v) (v=3))
            (value c)))
    """) == "2"

    # a failed block rolls back entirely
    @test ev("""
        (let (s=(logic-set :rbblock))
          (assert s (rule (go ?x) :> (raise :boom x)))
          (do (logic s (assert (go 1))) (except (:boom ?e) :caught))
          (facts s))
    """) == "(')"

    # ---- accumulators --------------------------------------------------------

    # the listed variables bind to vectors; unlisted ones are group keys
    @test ev("""
        (let (s=(logic-set :school))
          (assert s (student class=:math grade=90))
          (assert s (student class=:math grade=80))
          (assert s (student class=:art grade=70))
          (assert s (rule (student class=?c grade=?g) :accum (g)
                          :> (all class=?c grades=?g)))
          (facts s))
    """) == "(' (student class=:math grade=90) (student class=:math grade=80) (student class=:art grade=70) (all class=:math grades=(90 80)) (all class=:art grades=(70)))"

    # per-variable aggregators
    @test ev("""
        (let (s=(logic-set :aggs))
          (assert s (v :a 10))
          (assert s (v :a 20))
          (assert s (v :a 30))
          (assert s (rule (v ?k ?x) :accum (x=:min) :> (amin ?x)))
          (assert s (rule (v ?k ?x) :accum (x=:max) :> (amax ?x)))
          (assert s (rule (v ?k ?x) :accum (x=:sum) :> (asum ?x)))
          (assert s (rule (v ?k ?x) :accum (x=:mean) :> (amean ?x)))
          (assert s (rule (v ?k ?x) :accum (x=:median) :> (amed ?x)))
          (assert s (rule (v ?k ?x) :accum (x=:first) :> (afirst ?x)))
          (assert s (rule (v ?k ?x) :accum (x=:last) :> (alast ?x)))
          (facts s))
    """) == "(' (v :a 10) (v :a 20) (v :a 30) (amin 10) (amax 30) (asum 60) (amean 20.0) (amed 20) (afirst 10) (alast 30))"

    # `:take` selects a row: (min v), (max v), :first, :last
    @test ev("""
        (let (s=(logic-set :takes))
          (assert s (student class=:m grade=90))
          (assert s (student class=:m grade=80))
          (assert s (rule (student class=?c grade=?g) :accum (c g :take :first)
                          :> (head c=?c g=?g)))
          (assert s (rule (student class=?c grade=?g) :accum (c g :take (max g))
                          :> (best c=?c g=?g)))
          (assert s (rule (student class=?c grade=?g) :accum (c g :take (min g))
                          :> (least c=?c g=?g)))
          (facts s))
    """) == "(' (student class=:m grade=90) (student class=:m grade=80) (head c=:m g=90) (best c=:m g=90) (least c=:m g=80))"

    # `:last` is the most recently inserted fact
    @test ev("""
        (let (s=(logic-set :lastrow))
          (assert s (v :a 1))
          (assert s (v :a 2))
          (assert s (rule (v ?k ?x) :accum (k x :take :last) :> (tailx ?x)))
          (facts s))
    """) == "(' (v :a 1) (v :a 2) (tailx 2))"

    # nested specs: the outer level partitions and the final level aggregates,
    # producing parallel sequences
    @test ev("""
        (let (s=(logic-set :nest))
          (assert s (student class=:m dept=:sci grade=90))
          (assert s (student class=:m dept=:sci grade=80))
          (assert s (student class=:m dept=:eng grade=60))
          (assert s (student class=:a dept=:hum grade=70))
          (assert s (rule (student class=?c dept=?d grade=?g)
                          :accum (d) :accum (g=:mean)
                          :> (roll class=?c depts=?d means=?g)))
          (facts s))
    """) == "(' (student class=:m dept=:sci grade=90) (student class=:m dept=:sci grade=80) (student class=:m dept=:eng grade=60) (student class=:a dept=:hum grade=70) (roll class=:m depts=(:sci :eng) means=(85.0 60.0)) (roll class=:a depts=(:hum) means=(70.0)))"

    # insertion order is preserved and a revision keeps its position
    @test ev("""
        (let (s=(logic-set :order))
          (assert s (v :a 1))
          (assert s (v :a 2))
          (assert s (rule (v ?k ?x) :accum (x) :> (vec ?x)))
          (assert s (rule (v ?k ?x) :accum (x=:first) :> (firstx ?x)))
          (revise-fact s (v :a 2) (v :a 2.5))
          (facts s))
    """) == "(' (v :a 1) (v :a 2.5) (vec (1 2.5)) (firstx 1))"
    @test ev("(let (s=(logic-set :order)) (assert s (v :a 9)) (facts s))") == "(' (v :a 1) (v :a 2.5) (v :a 9) (vec (1 2.5 9)) (firstx 1))"

    # only the final level may aggregate or take
    @test_throws AirEvalError air_eval(env, read_air("""
        (let (s=(logic-set :badagg))
          (assert s (rule (v ?k ?x) :accum (x=:mean) :accum (k) :> (o ?x))))
    """))
    @test_throws AirEvalError air_eval(env, read_air("""
        (let (s=(logic-set :badtake))
          (assert s (rule (v ?k ?x) :accum (k :take :first) :accum (x) :> (o ?x))))
    """))

    # ---- negation ------------------------------------------------------------

    @test ev("""
        (let (s=(logic-set :sp))
          (assert s (parent :a :b))
          (assert s (parent :b :c))
          (assert s (rule (parent ?x ?y) (not (married ?x))
                          :> (single-parent ?x ?y)))
          (facts s))
    """) == "(' (parent :a :b) (parent :b :c) (single-parent :a :b) (single-parent :b :c))"

    # adding a fact that falsifies the negation retracts what it justified
    @test ev("(let (s=(logic-set :sp)) (assert s (married :b)) (facts s))") == "(' (parent :a :b) (parent :b :c) (married :b) (single-parent :a :b))"

    # ---- `because` and `rule?` ----------------------------------------------

    @test ev("(because (rule (p ?x) :> (q ?x)) :a :b)") ==
        "(because (rule (p ?x) :> (q ?x)) :a :b)"
    @test ev("(because naught :a)") == "(because naught :a)"
    @test ev("(because :r :a)") == "(because :r :a)"
    @test ev("(rule? (rule (p ?x) :> (q ?x)))") == "true"
    @test ev("(rule? (p 1))") == "false"
    @test_throws AirEvalError air_eval(env, read_air("(because 5)"))
end
