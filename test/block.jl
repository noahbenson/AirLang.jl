# The `do`/`tx` block form: `:let` markers and the `let=` scope, scoped
# `catch=`/`throw`, `except` clauses, dynamically scoped `handle`/`signal`/
# `notify`, and `finally`. `tx` accepts the same grammar inside a transaction.
@testset "do/tx blocks" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- :let markers --------------------------------------------------------
    # A level-1 `:let` consumes the next body form as a binding form; the rest of
    # the body becomes its body. A marker may appear anywhere, and markers nest.
    @test ev("(do :let (a=10 b=:abc) a)") == "10"
    @test ev("(do :let (a=10) (a + 1))") == "11"
    @test ev("(do 1 :let (a=2) (a + 3))") == "5"
    @test ev("(do :let (a=2) :let (b=(a + 1)) (a + b))") == "5"
    @test ev("(do :let (a=1) :let (a=2) a)") == "2"
    # a trailing marker has no body left to bind, so it is inert data
    @test ev("(do 1 :let)") == ":let"
    @test ev("(do :let)") == ":let"
    @test ev("(do :let (a=1) :let)") == ":let"
    # marker values see the enclosing scope and the `let=` scope
    @test ev("(let (x=1) (do :let (y=(x + 2)) y))") == "3"
    @test ev("(do let=(a=1 b=2) :let (a=(a + b)) a)") == "3"
    # ... and shadow it in the rest of the body
    @test ev("(do let=(a=1) :let (a=2) a)") == "2"
    # a malformed binding form is reported by `let`
    @test_throws AirEvalError air_eval(env, read_air("(do :let 5 1)"))

    # `:let` names are not visible to the clauses: those run in the block scope,
    # where only `let=` bindings exist.
    @test ev("(do let=(a=5) :let (a=2) (raise :x) (except (:x) a))") == "5"
    @test ev("(do let=(a=5) :let (a=2) (notify :s) (handle (:s) a))") == "5"
    @test ev("(let (l=(mut 0)) (do let=(a=5) :let (a=2) 1 " *
             "(finally (set! l a))) (value l))") == "5"

    # ---- let= ----------------------------------------------------------------
    # `let=` wraps the whole block: a real lexical scope rather than a textual
    # substitution, with `let`'s group behavior.
    @test ev("(do let=(a=2) (a + 3))") == "5"
    @test ev("(do let=((a=1) (b=(a + 1))) b)") == "2"
    @test ev("(do let=((a=1) (a=(a + 2))) a)") == "3"
    @test ev("(do let=(a=7) (notify :s) (handle (:s) a))") == "7"
    @test_throws AirEvalError air_eval(env, read_air("(do let=5 1)"))
    # Unlike `let`, it does not rewrite inside a hold or a computed key.
    @test ev("(do let=(a=2) (' x a))") == "(' x a)"

    # ---- markers through the binder-aware passes ----------------------------
    # `let` substitutes textually, so a marker inside its body must still open a
    # new binding and a `do` clause must not be skipped over by the walk.
    @test ev("(let (x=1) (do :let (x=2) x))") == "2"
    @test ev("(let (x=1) (do :let (y=2) (raise :q) (except (:q) 7)))") == "7"
    # A marker binder shadows a `def` parameter in the body; the parameter is
    # still visible to the marker's value.
    air_eval(env, read_air("(def (block-f ?x) (do :let (x=2) x))"))
    air_eval(env, read_air("(def (block-g ?x) (do :let (y=(x + 1)) y))"))
    air_eval(env, read_air(
        "(def (block-h ?x) (do (raise :a 7) (except (:a ?x) x)))"))
    air_eval(env, read_air(
        "(def (block-i ?x) (do (notify :sig 7) (handle (:sig ?x) x)))"))
    @test ev("(block-f 9)") == "2"
    @test ev("(block-g 9)") == "10"
    # A clause pattern is data: its wildcard shadows an outer `let` or parameter.
    @test ev("(block-h 9)") == "7"
    @test ev("(block-i 9)") == "7"
    @test ev("(let (x=5) (do (raise :a 7) (except (:a ?x) x)))") == "7"
    @test ev("(let (x=5) (do (notify :sig 7) (handle (:sig ?x) x)))") == "7"

    # ---- catch= and throw ----------------------------------------------------
    @test ev("(let (x=16) (do catch=:tag " *
             "(if (< x 0) (throw :tag :undef)) (sqrt x)))") == "4.0"
    @test ev("(let (x=-1) (do catch=:tag " *
             "(if (< x 0) (throw :tag :undef)) (sqrt x)))") == ":undef"
    # catch=true accepts the one-argument and zero-argument throw
    @test ev("(do catch=true (throw :undef))") == ":undef"
    @test ev("(do catch=true (throw))") == "naught"
    @test ev("(do catch=true (throw (+ 1 2)))") == "3"
    # a tag list and a computed tag
    @test ev("(do catch=(:a :b) (throw :b 5))") == "5"
    @test ev("(let (t=:a) (do catch=~t (throw ~t 7)))") == "7"
    # a parenthesized computed tag: `catch=~(expr)` is a preval hole, evaluated
    # at block entry
    @test ev("(do catch=~(keyword \"a\") (throw :a 5))") == "5"
    @test ev("(let (k=\"a\") (do catch=~(keyword k) (throw :a 5)))") == "5"
    @test ev("(do catch=(~(keyword \"a\") :b) (throw :b 6))") == "6"
    @test ev("(do catch=(:b ~(keyword \"a\")) (throw :a 6))") == "6"
    # same-tag nesting selects the innermost active block
    @test ev("(do catch=:t (do catch=:t (throw :t 1)) 2)") == "2"
    @test ev("(do catch=:a (do catch=:b (throw :a 3)))") == "3"
    # a throw from an except body is caught by the same block
    @test ev("(do catch=:t (do (raise :x) (except (:x) (throw :t 9))))") == "9"
    # ... but one from finally is not: the catch scope is closed first
    @test_throws AirThrown air_eval(env,
        read_air("(do catch=:t 1 (finally (throw :t 9)))"))
    @test ev("(do catch=:t (do catch=:t 1 (finally (throw :t 9))))") == "9"
    # with no matching catch, a throw is the error (:uncaught-throw tag value)
    @test ev("(do (do (throw :tag 3)) " *
             "(except (:uncaught-throw ?t ?v) (t v)))") == "(:tag 3)"
    @test_throws AirThrown air_eval(env, read_air("(do catch=:a (throw :b 5))"))
    # validation
    @test_throws AirEvalError air_eval(env,
        read_air("(do catch=(:a (b c)) 1)"))                    # non-scalar tag
    @test_throws AirEvalError air_eval(env, read_air("(do catch=() 1)"))
    @test_throws AirEvalError air_eval(env, read_air("(do catch=(:a x=1) 1)"))
    @test_throws AirEvalError air_eval(env,
        read_air("(do catch=true (throw :a 1 2))"))
    @test_throws AirEvalError air_eval(env,
        read_air("(do catch=true (throw :a x=1))"))
    @test_throws AirEvalError air_eval(env, read_air("(do 1 (catch (:x) 2))"))

    # ---- signal objects and handle ------------------------------------------
    # `signal` is an inert object, like `error`: it never reduces, at any depth.
    @test ev("(signal :s 1)") == "(signal :s 1)"
    @test ev("(signal)") == "(signal)"
    @test ev("(1 + (signal :s (+ 1 2)))") == "(1 + (signal :s (+ 1 2)))"
    @test ev("(signal :s a=(+ 1 2))") == "(signal :s a=(+ 1 2))"
    # a notify builds a signal from its evaluated arguments and map, or dispatches
    # an exact signal object unchanged
    @test ev("(do (notify :sig (+ 1 2)) (handle (:sig ?x) x))") == "3"
    @test ev("(do (notify :sig a=(+ 1 2)) (handle (:sig ?*k) k))") == "(a=3)"
    @test ev("(do (notify (signal :s 2)) (handle (:s ?x) (+ x 1)))") == "3"
    # the handler's value becomes notify's value and execution continues
    @test ev("(do (+ (notify :sig 1) 10) (handle (:sig ?x) x))") == "11"
    # first matching handler wins, innermost block first
    @test ev("(do (notify :sig 1) (handle (:sig ?x) :first) " *
             "(handle (:sig ?x) :second))") == ":first"
    @test ev("(do (do (notify :sig 1) (handle (:sig ?x) :inner)) " *
             "(handle (:sig ?x) :outer))") == ":inner"
    # a bare wildcard handler binds the whole signal object
    @test ev("(do (notify :sig 1) (handle ?s s))") == "(signal :sig 1)"
    # a handler runs in its defining block's scope, not the notify site's
    @test ev("(do (loop (i 0) (if (< i 1) (recur (+ i 1)) (notify :s i))) " *
             "(handle (:s ?x) x))") == "1"
    # handlers are active in an except body and in finally...
    @test ev("(do (raise :x) (except (:x) (do (notify :sig 1) " *
             "(handle (:sig ?x) (+ x 1)))))") == "2"
    @test ev("(let (m=(mut 0)) (do 1 (handle (:sig ?x) (set! m x)) " *
             "(finally (notify :sig 4))) (value m))") == "4"
    # ... but an error raised by a handler is an ordinary error
    @test ev("(do (notify :sig) (handle (:sig) (raise :h)) " *
             "(except (:h) :caught))") == ":caught"
    # no handler: (:unhandled-signal <signal>), from the notify form
    @test ev("(do (notify :sig 1) (except (:unhandled-signal ?s) s))") ==
        "(signal :sig 1)"
    @test_throws AirThrown air_eval(env,
        read_air("(do (do 1 (handle (:sig ?x) x)) (notify :sig 1))"))
    # notify-or holds its default and evaluates it only when nothing matches
    @test ev("(do (notify-or :default :other) (handle (:sig) :handled))") ==
        ":default"
    @test ev("(do (notify-or (raise :boom) :sig 1) " *
             "(handle (:sig ?x) (+ x 1)))") == "2"
    @test ev("(do (notify-or :other))") == ":other"
    @test_throws AirEvalError air_eval(env, read_air("(do (notify-or) 1)"))
    # catch and handler scopes are task-local; a task starts fresh
    @test ev("(do (await (task (throw :t 1))) " *
             "(except (:uncaught-throw ?t ?v) (t v)))") == "(:t 1)"
    @test ev("(do (await (task (notify :sig 1))) " *
             "(except (:unhandled-signal ?s) s))") == "(signal :sig 1)"

    # ---- finally -------------------------------------------------------------
    @test ev("(do 1 (finally 42))") == "1"
    @test ev("(let (l=(mut 0)) (do catch=:t (throw :t 1) " *
             "(finally (set! l 2))) (value l))") == "2"
    @test ev("(let (l=(mut 0)) (do (do catch=:t (throw :t 1)) " *
             "(finally (set! l 3))) (value l))") == "3"
    # the block's handle scope is active in finally, its catch scope is closed
    @test ev("(let (l=(mut 0)) (do catch=:t 1 " *
             "(handle (:sig ?x) (set! l x)) (finally (notify :sig 6))) " *
             "(value l))") == "6"
    @test_throws AirThrown air_eval(env,
        read_air("(do catch=:t 1 (finally (throw :t 9)))"))
    # a finally error replaces the result or the in-flight error
    @test_throws AirThrown air_eval(env, read_air("(do 1 (finally (raise :fin)))"))
    @test ev("(do (do (raise :boom) (finally (raise :fin))) " *
             "(except ?e e))") == "(error :fin from=(error :boom))"
    # a failure while preparing the block (a `let=` value, a catch tag) is not
    # handled by the same block and does not run its finally; an outer block can
    @test ev("(let (l=(mut 0)) (do (do let=(a=(raise :x)) 1 " *
             "(finally (set! l 1))) (except (:x) (value l))))") == "0"
    # recur passes through a finally
    @test ev("(loop (i 0) (do (if (< i 3) (recur (+ i 1)) i) " *
             "(finally naught)))") == "3"

    # ---- tx ------------------------------------------------------------------
    @test ev("(let (m=(mut 0)) (tx (set! m 5)) (value m))") == "5"
    @test ev("(tx :let (a=2) (a + 3))") == "5"
    @test ev("(tx let=(a=1) catch=:t (if (> a 0) (throw :t (+ a 1))) 0)") == "2"
    @test ev("(tx 1 (finally 42))") == "1"
    # a throw caught inside the transaction commits
    @test ev("(let (m=(mut 0)) (tx catch=:t (set! m 5) (throw :t 1)) " *
             "(value m))") == "5"
    # an error caught by the tx's own except commits too
    @test ev("(let (m=(mut 0)) (tx (set! m 5) (raise :x) (except (:x) 1)) " *
             "(value m))") == "5"
    # an error escaping the transaction aborts its writes
    @test ev("(let (m=(mut 0)) (do (tx (set! m 5) (raise :x)) " *
             "(except (:x) 1)) (value m))") == "0"
    # a throw escaping to an outer catch commits before it is rethrown
    @test ev("(let (m=(mut 0)) (do catch=:t (tx (set! m 5) (throw :t 1))) " *
             "(value m))") == "5"
    # watches run on that commit-then-rethrow path
    @test ev("(let (m=(mut 0) l=(mut 0)) " *
             "(watch m :k ((?key ?m ?old ?new) -> (set! l new))) " *
             "(do catch=:t (tx (set! m 5) (throw :t 1))) (value l))") == "5"
    # ... but an aborted transaction fires no watch
    @test ev("(let (m=(mut 0) l=(mut 0)) " *
             "(watch m :k ((?key ?m ?old ?new) -> (set! l new))) " *
             "(do (tx (set! m 5) (raise :x)) (except (:x) 1)) (value l))") == "0"
    # a nested tx joins the outer one, so its error is caught at that boundary
    @test ev("(let (m=(mut 0)) (tx (set! m 1) (tx (raise :x)) " *
             "(except (:x) 2)) (value m))") == "1"
    # a handler notified in the transaction runs in it, and a later abort
    # rolls its writes back
    @test ev("(let (m=(mut 0)) (do (tx (notify :s 5) " *
             "(handle (:s ?x) (set! m x))) (value m)))") == "5"
    @test ev("(let (m=(mut 0)) (do (tx (notify :s 5) (raise :x) " *
             "(handle (:s ?x) (set! m x))) (except (:x) 1)) " *
             "(value m))") == "0"
    # a finally error still aborts the transaction
    @test ev("(let (m=(mut 0)) (do (tx (set! m 5) (finally (raise :f))) " *
             "(except (:f) 1)) (value m))") == "0"

    # ---- tail position -------------------------------------------------------
    # A clause-free block (including one with `:let`/`let=`) keeps its last body
    # form in tail position, so a tail-recursive rule runs in constant stack.
    air_eval(env, read_air(
        "(def (block-count-let ?n) " *
        "(if (n == 0) :done (do let=(m=(n - 1)) :let (k=0) " *
        "(block-count-let (+ m k)))))"))
    @test ev("(block-count-let 10000)") == ":done"
    # A block with a catch scope is not a tail form; `tx` never is.
    air_eval(env, read_air(
        "(def (block-count-catch ?n) " *
        "(if (n == 0) :done (do catch=:t (block-count-catch (n - 1)))))"))
    @test ev("(block-count-catch 100)") == ":done"

    # ---- try is gone ---------------------------------------------------------
    @test_throws AirEvalError air_eval(env, read_air("(try 1)"))
    @test ev("(except :x)") == "(except :x)"
    # a throw signal passes through trace and test unchanged
    @test ev("(do catch=:t (trace (throw :t 5)))") == "5"
    @test ev("(do catch=:t (test \"t\" (throw :t 5)))") == "5"
end
