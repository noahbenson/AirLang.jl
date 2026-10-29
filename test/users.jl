# Users, boot identity, homes and roots, and the task-local namespace context.
@testset "users and roots" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- boot ---------------------------------------------------------------
    # A fresh environment runs as `air` in `.main`; `.env` is empty.
    @test ev("(current-user)") == ":air"
    @test ev("(owner)") == ":air"
    @test ev("(users)") == "(:air)"
    @test ev("(env)") == "naught"

    # A top-level `def` is written to the current namespace, so it is durable
    # and addressable as `.main.f` (not merely a process-global rule).
    @test ev("(def (f ?x) (+ x 1))") == "naught"
    @test ev("(f 2)") == "3"
    @test ev("(.main.f 2)") == "3"
    @test ev("(get . :main :f)") == "(ns-fn (main) :f)"

    # ---- roots --------------------------------------------------------------
    # `$` is the current user's home namespace (a volatile capability) and `@`
    # is the database root; an unattached system user's `@` is `.`.
    @test startswith(ev(raw"($)"), "((mut ")
    @test ev("(== @ .)") == "true"
    @test ev(raw"(== $ (get . :sys :user :air :home))") == "true"
    # `$` and `@` are ordinary symbols: a local binding shadows the root, and a
    # `let` may rebind either.
    @test ev(raw"(let (@=7) @)") == "7"
    @test ev(raw"(let ($=8) $)") == "8"
    @test ev(raw"(get (@=5) :@)") == "5"

    # ---- namespace context --------------------------------------------------
    # A namespace body runs in its own context: it does not see the caller's
    # definitions, but `.air` is always available.
    @test ev("(namespace .air (f 2))") == "(f 2)"
    @test ev("(namespace .air (current-user))") == ":air"
    @test ev("(namespace .n (f 2))") == "(f 2)"
    @test ev("(.air.inc 1)") == "2"
    # `using=` activates a namespace for the body without nesting it.
    @test ev("(namespace .u1 using=(.main) (f 2))") == "3"
    @test ev("(using .main (f 2))") == "3"

    # ---- creating users -----------------------------------------------------
    @test ev("(create-user :bob)") == ":bob"
    @test ev("(do (create-user :bob) (except ?e :err))") == ":err"
    @test ev("(users)") == "(:air :bob)"
    @test ev("(as-user :bob (current-user))") == ":bob"
    @test ev("(as-user :bob (owner))") == ":bob"
    @test ev("(as-user :bob (users))") == "(:bob)"
    @test ev("(as-user :air (current-user))") == ":air"
    @test ev("(do (as-user :nobody 1) (except ?e :err))") == ":err"
    # Only `air` creates users or changes admin status, and a non-admin may not
    # assume another user.
    @test ev("(do (as-user :bob (create-user :carl)) (except ?e :err))") == ":err"
    @test ev("(do (as-user :bob (set-admin :bob true)) (except ?e :err))") == ":err"
    @test ev("(do (as-user :bob (as-user :air 1)) (except ?e :err))") == ":err"

    # ---- homes --------------------------------------------------------------
    # `def` in a user's context lands in that user's home, which other contexts
    # cannot reach by name; `.`/`.main`/`.air` stay explicitly reachable.
    @test ev("(as-user :bob (def (bobf ?x) (+ x 10)))") == "naught"
    @test ev("(as-user :bob (bobf 1))") == "11"
    @test ev("(bobf 1)") == "(bobf 1)"
    @test ev("(do (.main.bobf 1) (except ?e :err))") == ":err"
    # `.main` is air's private startup namespace; bob may call `.air` (world
    # read/execute) but not `.main`.
    @test ev("(do (as-user :bob (.main.f 2)) (except ?e :err))") == ":err"
    @test ev("(do (as-user :bob (get . :main)) (except ?e :err))") == ":err"
    @test ev("(as-user :bob (.air.inc 1))") == "2"
    # `$` is a capability: bob works in his home without being able to read the
    # `.sys` namespace that contains it.
    @test ev(raw"(as-user :bob (namespace $ (def (at-home ?x) (+ x 20))))") == "naught"
    @test ev(raw"(as-user :bob ($.at-home 1))") == "21"
    @test ev("(do (as-user :bob (get . :sys :user :bob)) (except ?e :err))") == ":err"
    @test ev(raw"(== $ (get . :sys :user :bob :home))") == "false"
    @test startswith(ev("(as-user :bob @)"), "(mut ")
    # a `let` value remains visible across an `as-user` boundary
    @test ev("(let (x=1) (as-user :bob (+ x 1)))") == "2"

    # ---- admins and constituents --------------------------------------------
    @test ev("(create-user :game)") == ":game"
    # a non-admin cannot create constituents...
    @test ev("(do (as-user :game (create-constituent :kid)) (except ?e :err))") == ":err"
    # ...an admin can, and sees its own constituents
    @test ev("(set-admin :game true)") == ":game"
    @test ev("(as-user :game (create-constituent :kid))") == ":game:kid"
    @test ev("(as-user :game:kid (current-user))") == ":game:kid"
    @test ev("(as-user :game (users))") == "(:game :game:kid)"
    @test ev("(as-user :game:kid (users))") == "(:game:kid)"
    @test ev("(users)") == "(:air :bob :game :game:kid)"
    # constituents do not nest, and only `air` changes admin status
    @test ev("(do (as-user :game:kid (create-constituent :x)) (except ?e :err))") == ":err"
    @test ev("(do (as-user :game (set-admin :game false)) (except ?e :err))") == ":err"
    @test ev("(do (create-user :a:b:c) (except ?e :err))") == ":err"
    @test ev("(do (create-user :_) (except ?e :err))") == ":err"

    # ---- .env and tasks ---------------------------------------------------
    @test ev("(with-env (a=1) (env))") == "(a=1)"
    @test ev("(with-env (a=1) (with-env (b=2) (env)))") == "(a=1 b=2)"
    @test ev("(env)") == "naught"
    # A task inherits the task context (user, namespace, `.env`) and the `val`
    # bindings; `clean=true` clears the `val` bindings and `.env` but not identity.
    @test ev("(with-env (a=1) (await (task (env))))") == "(a=1)"
    @test ev("(with-env (a=1) (await (task clean=true (env))))") == "naught"
    @test ev("(as-user :bob (await (task (current-user))))") == ":bob"
    @test ev("(as-user :bob (with-env (a=1) (await (task (env)))))") == "(a=1)"
    @test ev("(as-user :bob (await (task (bobf 1))))") == "11"
    @test ev("(current-user)") == ":air"
end
