# Namespaces: dotted `.` access, `namespace` blocks, `using`/`use`/`import`,
# subnamespaces, `del`, and the thread-local `val`/`bind`/`bindings` machinery
# (including `task` inheriting bindings across tasks).
@testset "namespaces" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- reading dotted names ------------------------------------------------
    @test air_string(read_air(".")) == "."
    @test air_string(read_air(".air")) == "(get . :air)"
    @test air_string(read_air(".util.a.b")) == "(get . :util :a :b)"
    @test air_string(read_air("(f .util.a)")) == "(f (get . :util :a))"
    # a spaced `.` is a literal symbol, not a path
    @test air_string(read_air("(f . a)")) == "(f . a)"

    # ---- the core namespace --------------------------------------------------
    @test ev("(get . :air :pi)") == "3.141592653589793"
    @test ev("(.air.inc 1)") == "2"
    @test ev("(.air.string-join (\"a\" \"b\") \"-\")") == "\"a-b\""
    # `.` alone is the root volatile, and `.air` is always registered
    @test startswith(ev("(get . :air)"), "(mut ")

    # ---- defining a namespace ------------------------------------------------
    @test ev("(namespace .util (def (twice ?x) (* x 2)) (val answer 42))") == "naught"
    @test ev("(.util.twice 4)") == "8"
    @test ev("(.util.answer)") == "42"
    @test ev("(get . :util :answer)") == "42"
    @test ev("(do (val before (get . :util :answer)) before)") == "42"

    # a zero-argument call applies too, including a scalar `def`
    @test ev("(namespace .zero (def (z) 7) (def scalarz 8))") == "naught"
    @test ev("(.zero.z)") == "7"
    @test ev("(.zero.scalarz)") == "8"

    # subnamespaces are created automatically and addressed by a longer path
    @test ev("(namespace .util.algebra (def (square ?x) (* x x)))") == "naught"
    @test ev("(.util.algebra.square 5)") == "25"
    @test ev("(get . :util :algebra)") != "naught"   # a namespace value

    # later definitions match first
    @test ev("(namespace .later (def (f ?x) 1) (def (f ?x) 2))") == "naught"
    @test ev("(.later.f 0)") == "2"

    # a subnamespace may not shadow a definition, in either order
    @test ev("(do (namespace .clash (def (s ?x) x) (namespace .clash.s)) " *
             "(except ?e :err))") == ":err"
    @test ev("(do (namespace .clash2 (namespace .clash2.s) (def (s ?x) x)) " *
             "(except ?e :err))") == ":err"
    @test ev("(do (get . :clash) (except ?e :missing))") == ":missing"

    # ---- transactions --------------------------------------------------------
    # a namespace block is a transaction: a failure rolls it back entirely
    @test ev("(do (namespace .rolled (def (f ?x) x) (raise :no)) " *
             "(except ?e :ok))") == ":ok"
    @test ev("(do (get . :rolled) (except ?e :missing))") == ":missing"

    # ---- using ---------------------------------------------------------------
    @test ev("(do (namespace .u1 (def (inc2 ?x) (+ x 2))) " *
             "(using .u1 (inc2 1)))") == "3"
    # a list of namespaces; later specs have priority
    @test ev("(do (namespace .p (def (f ?x) 1)) (namespace .q (def (f ?x) 2)) " *
             "(using (.p .q) (f 0)))") == "2"
    @test ev("(do (namespace .p (def (f ?x) 1)) (namespace .q (def (f ?x) 2)) " *
             "(using (.q .p) (f 0)))") == "1"
    # only= / except= filter the names a spec contributes
    @test ev("(do (namespace .o (val a 1) (val b 2) (val c 3)) " *
             "(namespace .p2 (use (.o :only (a c))) (def (t) (a + c))) " *
             "(.p2.t))") == "4"
    @test ev("(do (namespace .o2 (def (a ?x) 1) (def (b ?x) 2)) " *
             "(namespace .p3 (use (.o2 :except (b))) (def (t ?x) (a x))) " *
             "(.p3.t 0))") == "1"
    # as= gives the namespace a local name
    @test ev("(do (namespace .n (def (u ?x) (+ x 1)) (val k 4)) " *
             "(using (.n :as nn) (get nn :k)))") == "4"
    @test ev("(do (namespace .n2 (def (u ?x) (+ x 1))) " *
             "(using (.n2 :as nn) (get nn :u)))") == "(ns-fn (n2) :u)"

    # `use` is private; `import` exports the selected names in the map
    @test ev("(do (namespace .src (def (s ?x) (+ x 1)) (val k 5)) " *
             "(namespace .dst (import .src)))") == "naught"
    @test ev("(.dst.s 1)") == "2"
    @test ev("(get . :dst :k)") == "5"
    @test ev("(do (namespace .src2 (def (s ?x) (+ x 1))) " *
             "(namespace .q2 (use .src2)) (namespace .q3 (use .q2)))") == "naught"
    @test ev("(namespace .q4 (use .src2) (def (r ?x) (s x)))") == "naught"
    @test ev("(.q4.r 1)") == "2"
    @test ev("(do (get . :q4 :s) (except ?e :not-exported))") == ":not-exported"

    # ---- del -----------------------------------------------------------------
    @test ev("(do (namespace .del1 (def (a ?x) (* x 2)) (def (b ?x) (* x 3)) " *
             "(val c 9) (del a)) (get . :del1))") ==
          "(mut ((def (b ?x) (* x 3)) (val c 9) b=(ns-fn (del1) :b) " *
          "c=(ns-val (del1) :c)))"
    # builtin air definitions can never be deleted
    @test ev("(namespace .del2 (del inc))") == "naught"
    @test ev("(.air.inc 1)") == "2"

    # ---- docstrings ----------------------------------------------------------
    @test ev("(namespace .docd (def (h ?x) \"hilbert\" (+ x 1)))") == "naught"
    @test ev("(using .docd (doc h))") == "\"(h ?x)\\n  hilbert\""
    @test ev("(namespace .docd2 (def (k ?x) \"nested\" x) (doc k))") ==
          "\"(k ?x)\\n  nested\""

    # ---- the root namespace --------------------------------------------------
    @test ev("(namespace . (val rootval 1))") == "naught"
    # the root's definitions are not global; `using .` activates them
    @test ev("rootval") == "rootval"
    @test ev("(using . rootval)") == "1"
end

@testset "thread-local vals" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    @test ev("(val x 10)") == "naught"
    @test ev("x") == "10"
    # a val is evaluated at definition time and does not act as a function
    @test ev("(val y (x + 1))") == "naught"
    @test ev("y") == "11"
    @test ev("(do (def (uses-x) x) (uses-x))") == "10"

    # bind rebinds a global val thread-locally and restores it afterwards
    @test ev("(bind (x=99) x)") == "99"
    @test ev("(bind (x=99) (uses-x))") == "99"
    @test ev("(bind (x=99) (list x (bind (x=1) x) x))") == "(list 99 1 99)"
    @test ev("x") == "10"

    # the binding form's values are expressions evaluated in the enclosing scope
    @test ev("(bind (x=(x + 1)) x)") == "11"

    # binding a name that is not a val is an error
    @test ev("(do (bind (nope=1) 1) (except ?e :err))") == ":err"

    # bindings reports the current overrides as a mapping
    @test ev("(bindings)") == "naught"
    @test ev("(bind (x=1 y=2) (bindings))") == "(x=1 y=2)"
    # and a mapping from `bindings` can be reinstalled with `bind`
    @test ev("(bind (x=5) (bind (bindings) x))") == "5"

    # a namespace val is rebound by name in that namespace's context
    @test ev("(namespace .nv (val answer 42) (def (twice ?x) (answer + x)) " *
             "(def (with7 ?x) (bind (answer=7) (twice x))))") == "naught"
    @test ev("(.nv.twice 1)") == "43"
    @test ev("(.nv.with7 1)") == "8"
    @test ev("(using .nv (.nv :only answer) (bind (answer=1) (twice 1)))") == "2"
    # `.` access through the namespace reads the same binding
    @test ev("(using .nv (.nv :only answer) (bind (answer=7) (.nv.answer)))") == "7"
    @test ev("(.nv.answer)") == "42"
end

@testset "tasks and bindings" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    @test ev("(val x 10)") == "naught"

    # task returns a promise immediately and delivers the final form's value
    @test ev("(promise? (task (+ x 1)))") == "true"
    @test ev("(await (task (+ x 1)))") == "11"
    @test ev("(await (task (+ x 1) (+ x 10)))") == "20"

    # task holds its arguments: nothing runs until the promise is awaited
    @test ev("(let (p=(task (raise :late))) :created)") == ":created"
    @test ev("(let (p=(task (' a b))) (await p))") == "(' a b)"

    # a task inherits the current thread's bindings
    @test ev("(bind (x=100) (await (task x)))") == "100"
    @test ev("(bind (x=100) (await (task (bindings))))") == "(x=100)"
    # ... and a value computed before the task is still its own
    @test ev("(let (v=x) (bind (x=5) (await (task v))))") == "10"

    # an error in the task is rethrown by await and is catchable
    @test ev("(do (await (task (raise :boom))) (except ?t :caught))") == ":caught"

    # a task sees namespace context captured at creation
    @test ev("(namespace .fu (val answer 42) (def (twice ?x) (answer + x)) " *
             "(def (async-twice ?x) (await (task (twice x)))))") == "naught"
    @test ev("(.fu.async-twice 1)") == "43"
end
