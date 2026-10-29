@testset "held forms" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # reader / printer: `'x` is sugar for `(' x)`, so holding a scalar is
    # visible too
    @test air_string(read_air("(' f a b)")) == "(' f a b)"
    @test air_string(read_air("(' x)")) == "'x"
    @test air_string(read_air(":x")) == ":x"
    @test air_string(read_air("(' 5)")) == "'5"
    @test air_string(read_air("':x")) == "':x"
    @test air_string(read_air("''x")) == "(' 'x)"         # quotes stack
    @test air_string(read_air("~x")) == "~x"

    # held forms do not evaluate; `get` indexes the form as it is, so index 1 is
    # the `'` head and index 2 is the first element of the held content
    @test ev("(' + 1 2)") == "(' + 1 2)"
    @test ev("(get (' f a b) 1)") == "'"
    @test ev("(get (' f a b) 2)") == "f"

    # unhold evaluates; a hold's sole element is its content, so `(' (1))`
    # unholds to the one-element list `(1)` and `(' ())` to `naught`
    @test ev("(unhold 'x)") == "x"
    @test ev("(unhold (' + 1 2))") == "3"
    @test ev("(unhold (' (1)))") == "(1)"
    @test ev("(unhold (' ()))") == "naught"
    # the empty form inside a hold or `naught` is the same singleton
    @test ev("(same? (get (' ()) 2) (get (' naught) 2))") == "true"
    @test ev("(eq? (' ()) (' naught))") == "true"
    # `~` is `(preval x)`: it evaluates wherever it appears, quoted or not
    @test ev("~'x") == "'x"
    @test ev("(hold (a ~(1 + 2)))") == "(' (a 3))"

    # lower, and lift as its inverse
    @test ev("(lower (' f (a b)))") == "('f (' a b))"
    @test ev("(lower (' f (a (b c))) -1)") == "('f ('a ('b 'c)))"
    @test ev("(lower (f a b))") == "(f a b)"              # no-op on an unheld form
    @test ev("(lift ('f (' a b)))") == "(' f (a b))"
    @test ev("(lift ('f ('a ('b 'c))))") == "(' f (a (b c)))"
    @test ev("(let (x=3) (lift ('a (x + 1) 'b)))") == "(' a 4 b)"
    @test ev("(let (x=(' 1 2)) (lift ('a x 'b)))") == "(' a (1 2) b)"

    # matching respects held
    @test ev("(match? (' f ?x) (' f 5))") == "true"
    @test ev("(match? (' f ?x) (f 5))") == "false"
    @test ev("(match? (f ?x) (f 5))") == "true"

    # held is part of a form's identity (AirDB)
    @test !isequal(read_air("(' f a b)"), read_air("(f a b)"))
    @test ev("(== (' f a b) (' f a b))") == "true"
    @test ev("(== (' f a b) (f a b))") == "false"
end

@testset "hold= and optional keys" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # A held parameter is inserted into the replacement *exactly as matched* and is
    # not held, so the replacement's own reduction still applies to it; a non-held
    # parameter is reduced at binding time. The `is-plus` rules make the difference
    # visible: a raw `(2 + 3)` still has the infix shape a reduced `5` lacks.
    # Later definitions match first, so the general fallback is installed before
    # the `+`-shaped pattern it must not shadow.
    air_eval(env, read_air("(def (is-plus ?x) false)"))
    air_eval(env, read_air("(def (is-plus (?a + ?b)) true)"))
    air_eval(env, read_air("(def (g ?x) hold=x (is-plus x))"))
    air_eval(env, read_air("(def (h ?x) hold=x (unhold x))"))
    air_eval(env, read_air("(def (k ?x) (is-plus x))"))
    @test ev("(g (2 + 3))") == "true"    # the raw match reaches the downstream rule
    @test ev("(h (2 + 3))") == "5"       # `(unhold x)` evaluates the raw match
    @test ev("(k (2 + 3))") == "false"   # no hold: the argument is reduced at binding
    @test ev("((?x -> x hold=(x)) 5)") == "5"

    # The replacement keeps the raw argument even when its *own* reduction applies:
    # `(1 + 1)` is inserted as-is (so `saw` sees the infix shape) and only then
    # reduces to `2`; `(2 + 2)` is a non-held parameter and is already `4`.
    air_eval(env, read_air("(def (saw ?a ?c) false)"))
    air_eval(env, read_air("(def (saw (?a + ?b) ?c) true)"))
    air_eval(env, read_air("(def (f ?x ?y) hold=x (saw x y))"))
    @test ev("(f (1 + 1) (2 + 2))") == "true"
    # A held parameter that matched a bare symbol is inserted as-is, so the symbol
    # resolves through the caller's scope (and an unheld parameter is reduced).
    @test ev("(let (x=5 y=6) (f x y))") == "false"

    # A held occurrence (`'x`) in the body receives the *held* match, so the raw
    # argument survives inside a quote.
    air_eval(env, read_air("(def (q ?x ?y) hold=x (let (u=x v='x) (' ~u ~v)))"))
    @test ev("(q (1 + 1) (2 + 2))") == "(' 2 (' (1 + 1)))"

    # The raw match is in the replacement *before* a downstream held rule sees it:
    # `gg` receives `(1 + 1)`, not the parameter name `x`.
    air_eval(env, read_air("(def (gg ?a) hold=a 'a)"))
    air_eval(env, read_air("(def (ff ?x) hold=x (gg x))"))
    @test ev("(ff (1 + 1))") == "(' (1 + 1))"

    # optional keyword patterns
    @test ev("(matches (f ?x ?m=naught) (f 10 m=:newton))") == "(m=:newton x=10)"
    @test ev("(matches (f ?x ?m=naught) (f 10))") == "(m=naught x=10)"
    @test ev("(matches (f ?x m=?y) (f 10 m=5))") == "(x=10 y=5)"
end

@testset "unhold as an air rule" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # `hold` is reserved, but `unhold` is an ordinary call and a user rule anchored
    # on it takes precedence; the builtin is the fallback for other operands.
    air_eval(env, read_air("(def (unhold (myhold ??args)) (args...))"))
    @test ev("(unhold (myhold (1 + 1)))") == "(2)"
    @test ev("(unhold (myhold (f x)))") == "((f x))"
    @test ev("(unhold (myhold x))") == "(x)"
    @test ev("(unhold (' + 1 2))") == "3"
end

@testset "def with no body" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # An empty-body def declares a rule that reproduces its matched form: the
    # arguments reduce, but the form itself does not (`(f ?x)` stands for `(f x)`).
    air_eval(env, read_air("(def (f ?x))"))
    @test ev("(f (1 + 1))") == "(f 2)"
    @test ev("(f 2)") == "(f 2)"
    @test ev("(f :a)") == "(f :a)"

    # With `hold=`, the argument is inserted exactly as matched, so the raw form
    # survives: it is neither reduced to `(g 2)` nor held as `(g (' 1 + 1))`.
    air_eval(env, read_air("(def (g ?x) hold=x)"))
    @test ev("(g (1 + 1))") == "(g (1 + 1))"
    @test ev("(g 3)") == "(g 3)"
    @test ev("(let (x=5) (g x))") == "(g 5)"     # substitution happens before the match

    # Only the named parameters are affected: an unheld one still reduces.
    air_eval(env, read_air("(def (h ?x ?y) hold=y)"))
    @test ev("(h (1 + 1) (2 + 2))") == "(h 2 (2 + 2))"

    # A nested pattern works the same way.
    air_eval(env, read_air("(def (k (?a + ?b)))"))
    @test ev("(k ((1 + 1) + (2 + 2)))") == "(k 6)"

    # `definitions` omits the synthesized body and keeps the `hold=` option.
    @test ev("(definitions f)") == "((' def (f ?x)))"
    @test ev("(definitions g)") == "((' def (g ?x) hold=x))"

    # An anonymous wildcard, a rest marker, and an optional key all reproduce a
    # replacement; the matched parts still reduce.
    air_eval(env, read_air("(def (m ?))"))
    @test ev("(m (1 + 1))") == "(m 2)"
    air_eval(env, read_air("(def (r ?&rest))"))
    @test ev("(r (1 + 1) (2 + 2))") == "(r 2 4)"
    air_eval(env, read_air("(def (o ?x=1))"))
    @test ev("(o 5)") == "(o 5)"
    @test ev("(o)") == "(o)"                    # `(o)` is a one-element form
end

# A hold is an ordinary container: index 1 is `'` and index 2 is the first
# element of its content. `hold=true` makes the root hold transparent and
# returns the extracted subpart held. The other accessors see the raw form, so
# `(first (' a b c))` is `'`.
@testset "accessors on a held form" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    @test ev("(get (' a b (inc 10)) 1)") == "'"
    @test ev("(get (' a b (inc 10)) 2)") == "a"
    @test ev("(get (' a b (inc 10)) 4)") == "11"
    @test ev("(get (' a b (inc 10)) 3 hold=true)") == "(' inc 10)"
    @test ev("(get (' (inc 1) b) 2)") == "2"
    @test ev("(get (' (inc 1) b) 1 hold=true)") == "(' inc 1)"
    @test ev("(get (' a=(inc 1)) :a)") == "2"
    @test ev("(get (' a=(inc 1)) :a hold=true)") == "(' inc 1)"
    @test ev("(get (hold (a b c)) 1 hold=true)") == "'a"
    # `hold=true` works for any form that keeps its arguments as data, not just
    # `hold`: `(part add 10)` is `(part 'add '10)`.
    @test ev("(get (part add 10) 2 hold=true)") == "'add"
    @test ev("(first (' a b c))") == "'"
    @test ev("(count (' a b c))") == "4"
    # integer keys: 0 is the whole form and a negative key counts from the end
    @test ev("(get (1 2 3) 0)") == "(1 2 3)"
    @test ev("(get (1 2 3) -1)") == "3"
    @test ev("(get (' 1 2 3) 2 hold=true)") == "'2"
    @test_throws AirEvalError air_eval(env, read_air("(get (1 2 3) 4)"))
end

# `with … hold=true` strips the form's root hold, sets the subforms, and re-holds
# the result; a held value contributes its content. With `hold=false` the result
# is unheld and therefore reduces.
@testset "with and holds" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    @test ev("(with (' a b c) 2 'z hold=true)") == "(' a z c)"
    @test ev("(with (' f (1 + 2)) 2 (' 3 + 4) hold=true)") == "(' f (3 + 4))"
    @test ev("(with (' f x=1) :x 10 hold=true)") == "(' f x=10)"
    @test ev("(with (' 1 1 1) 2 * 3 (' a + b) hold=true)") == "(' 1 * (a + b))"
    @test ev("(with (1 1 1) 2 + hold=true)") == "(' 1 + 1)"
    @test ev("(with (a b c) 2 (' 1 + 1) hold=true)") == "(' a (1 + 1) c)"
    # Without hold mode the inserted value is a value, so a held one stays held.
    @test ev("(with (a b c) 2 (' 1 + 1))") == "(a (' 1 + 1) c)"
end

@testset "basic collection operations" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    # `get` is the one accessor: an integer indexes the seq, a keyword the map
    @test ev("(get (1 2 3) 2)") == "2"
    @test ev("(get (a=1 b=2) :b)") == "2"
    @test ev("(second (1 2 3))") == "2"
    @test ev("(third (1 2 3))") == "3"
    @test ev("(insert (1 2 3 4) 2 99)") == "(1 99 2 3 4)"
    @test ev("(insert (1 2) 3 99)") == "(1 2 99)"
    @test ev("(map-keys (?k -> (keyword (upcase (name k)))) (a=1 b=2))") == "(A=1 B=2)"
    @test ev("(deep-map (?x -> (if (number? x) (inc x) x)) (a=(b=1) c=2))") ==
        "(a=(b=2) c=3)"
end

# A held form is canonical as it stands: the `'` head is never collapsed, and a
# hold of one container keeps that container whole. `(hold e…)` is the reserved
# alias for `(' e…)`.
@testset "held forms are canonical" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    @test air_string(AirLang._holdify(canonicalize(read_air("((a b))")))) == "(' (a b))"
    @test air_string(AirLang._holdify(canonicalize(read_air("(a)")))) == "'a"
    @test air_string(AirLang._holdify(canonicalize(read_air("()")))) == "'naught"
    @test air_string(AirLang._holdify(canonicalize(read_air("((a b) (c d))")))) ==
        "(' (a b) (c d))"
    @test ev("(' (a))") == "(' (a))"      # a hold of a container keeps it whole
    @test ev("(hold (a))") == "(' (a))"
    @test ev("(hold a b c)") == "(' a b c)"
    @test ev("(hold a x=1)") == "(' a x=1)"
end

# `hold=true` keeps an extracted subpart held; `held?` reports heldness without
# evaluating, and can test a subpart by path.
@testset "held? and hold=true" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    @test ev("(get (' f (1 + 2)) 3)") == "3"
    @test ev("(get (' f (1 + 2)) 2 hold=true)") == "(' 1 + 2)"
    @test ev("(held? (' f (1 + 2)))") == "true"
    @test ev("(held? (' f (1 + 2)) 3)") == "false"
    @test ev("(held? (' f (' 1 + 2)) 3)") == "true"
    @test ev("(held? 3)") == "false"
    @test ev("(held? 'a)") == "true"
    @test ev("(held? :a)") == "false"
    # a scalar's sole element is the scalar, as for `get` (and is never held)
    @test ev("(held? 3 1)") == "false"
    @test ev("(held? 3 -1)") == "false"
    @test ev("(held? 3 0)") == "false"
    @test_throws AirEvalError air_eval(env, read_air("(held? 3 2)"))
    @test_throws AirEvalError air_eval(env, read_air("(held? 3 :a)"))
    # `naught` is the empty form, so only the whole-form key names it
    @test ev("(held? naught 0)") == "false"
    @test_throws AirEvalError air_eval(env, read_air("(held? naught 1)"))
    @test ev("(held? (' f a=1) :a)") == "false"
    @test ev("(held? (' f b=(' 1 + 2)) :b)") == "true"
    @test_throws AirEvalError air_eval(env, read_air("(held? (' f a=1) :z)"))
end

# Each collection operation has a `hold-` version: the primary form's root hold
# is transparent (the operation is on the content), inserted held values
# contribute their content, and the result is held. `hold=` selects the result's
# heldness; plain `F` accepts `hold=true` for the same treatment.
@testset "hold- operations" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    @test ev("(get (1 2 3) 2 hold=true)") == "'2"
    @test ev("(hold-get (' 1 2 3) 2)") == "'2"
    @test ev("(hold-get (' 1 2 3) 2 hold=false)") == "2"
    @test ev("(hold-get (' 1 2 3) 9 default=:none)") == ":none"
    @test ev("(hold-nth (' 1 2 3) 9 :none)") == ":none"
    @test ev("(hold-get (' f (a b)) 2)") == "(' a b)"
    @test ev("(hold-nth (' a b c) 2)") == "'b"
    @test ev("(hold-nth (' a b c) -1 hold=false)") == "c"
    @test ev("(hold-with (' 1 1 1) 2 * 3 (' a + b))") == "(' 1 * (a + b))"
    @test ev("(hold-with (' 1 1 1) 2 * 3 (' a + b) hold=false)") == "(1 * (a + b))"
    @test ev("(hold-wout (' a b c) 2)") == "(' a c)"
    @test ev("(hold-push (' 1 2) (' 3 + 4))") == "(' 1 2 (3 + 4))"
    @test ev("(hold-push (' 1 2) 3)") == "(' 1 2 3)"
    @test ev("(hold-push-in (' 1 2 3) 2 99)") == "(' 1 99 2 3)"
    @test ev("(hold-join (' 1 2) (' 3 4 a=5))") == "(' 1 2 3 4 a=5)"
    @test ev("(hold-join-in (' 1 4) 2 (' 2 3))") == "(' 1 2 3 4)"
    @test ev("(hold-update (' 1 2 3) 2 inc)") == "(' 1 3 3)"
    @test ev("(hold-held? (' f (' 1 + 2)) 2)") == "true"
    @test ev("(hold-held? (' (' 1 + 2)))") == "true"
    @test ev("(held? (' f (1 + 2)) hold=true)") == "false"
end

# Facts and rules enter a logic-set held, and are returned held.
@testset "facts are held" begin
    env = AirLang.Env(db = MemoryDatabase())
    ev(s) = air_string(air_eval(env, read_air(s)))
    @test ev("(let (s=(logic-set :h)) (assert s (foo :a)) (facts s))") == "((' foo :a))"
    @test ev("(let (s=(logic-set :h2)) (assert s (foo :a)) (assert s (bar :b)) (facts s))") ==
        "((' foo :a) (' bar :b))"
end
