# Host-level extern objects: the `promise`/`task` primitives, the `(extern …)`
# surface, and the dead-extern behaviour on persistence.
@testset "extern objects" begin
    db = MemoryDatabase()
    env = AirLang.Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))

    # a database promise is a first-class value, and `task` returns one
    @test ev("(promise? (promise))") == "true"
    @test ev("(promise? 5)") == "false"
    @test ev("(promise? (task 1))") == "true"

    # a promise flows through forms without being forced
    @test ev("(promise? (get (join () x=(promise)) :x))") == "true"
    @test ev("(promise? (last (1 (promise))))") == "true"

    # deliver / await / ready?
    @test ev("(let (p=(promise)) (deliver p 42) (await p))") == "42"
    @test ev("(let (p=(promise)) (deliver p 42) (get p))") == "42"
    @test ev("(let (p=(promise)) (list (ready? p) (do (deliver p 1) (ready? p))))") ==
          "(list false true)"
    # a promise is delivered once
    @test ev("(do (let (p=(promise)) (deliver p 1) (deliver p 2)) (except ?e :caught))") ==
          ":caught"

    # a task runs on another Julia task; `await` returns its value
    @test ev("(await (task (inc 41)))") == "42"
    # a task delivering to a promise (nested lets: bindings are parallel)
    @test ev("(let (p=(promise)) (let (f=(task (deliver p (inc 1)))) (await p)))") == "2"
    @test ev("(let (a=(task (inc 1))) (let (b=(task (inc 2))) (+ (await a) (await b))))") == "5"
    # capture respects inner binders: a lambda's parameter shadows an enclosing
    # loop name, while a free name inside the lambda is still captured
    @test ev("(for (x (1)) (await (task ((?x -> (+ x 1)) 5))))") == "(6)"
    @test ev("(for (x (1)) (await (task ((?y -> (+ y x)) 5))))") == "(6)"

    # a failed task still delivers (an error form), so reading it never hangs;
    # `await` rethrows the original condition and `ready?` is true afterwards
    @test ev("(let (p=(task (raise :boom))) (do (await p) (except ?e :caught)))") ==
          ":caught"
    @test ev("(let (p=(task (raise :boom))) (do (await p) (except ?e (ready? p))))") ==
          "true"
    # `future` is the old name and is rejected rather than silently accepted
    @test_throws AirEvalError air_eval(env, read_air("(future 1)"))

    # printing: a promise is opaque by identity and printing never blocks
    @test startswith(ev("(promise)"), "#<promise ")
    delivered = AirLang.AirPromise()
    AirLang._deliver!(delivered, Form(5))
    s = air_string(to_form(delivered))
    @test s == "(extern :promise 5)"
    @test ev("(await $s)") == "5"

    # a regex is a value: the same source and flags are the same air value
    @test ev("(eq? (regex \"a+\") (regex \"a+\"))") == "true"
    @test ev("(same? (regex \"a+\") (regex \"a+\"))") == "true"
    @test ev("(eq? (regex \"a+\") (regex \"a\"))") == "false"

    # persistence: an unnamed extern has no stored data, so it reads back dead.
    # Touching one is a catchable `(error :extern-expired :type)`.
    dead = from_JSON(to_JSON(to_form(AirLang.AirPromise())))
    @test dead isa FormExtern
    @test AirLang.value(dead) isa DeadExtern
    @test air_string(dead) == "#<extern promise (expired)>"
    @test AirLang._extern_type_name(dead) == :promise
    @test_throws AirLang.ExternExpiredError AirLang._extern_data(dead)
    @test_throws AirLang.ExternExpiredError air_eval(env, form(Symbol("await"), dead))
    @test air_string(AirLang._error_form(AirLang.ExternExpiredError(:promise))) ==
          "(error :extern-expired :promise)"
    # a delivered promise is not recoverable either, for the same reason
    @test AirLang.value(from_JSON(to_JSON(to_form(delivered)))) isa DeadExtern
end
