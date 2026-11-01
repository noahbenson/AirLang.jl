# An agent is a constituent user account marked `:agent` whose inference
# settings live in its own `$.config.agent`. A session is a durable mutable
# holding a channel — an inbox, an outbox, and a notification queue — that a
# worker drains: a text message becomes a model turn, a keyword-headed form
# becomes a command, and the answer is posted back to the inbox. The transport
# is replaced by a stub, so no network is touched.
@testset "agents" begin
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evf(s) = air_eval(env, read_air(s))

    # The stub is one stable function: a worker task is spawned on the first
    # message, and calling a *newly defined* closure from it would be a
    # world-age error, so the behavior is selected through `mode` and counted
    # in `seen`.
    mode = Ref{Symbol}(:openai)
    flaky = Ref(0)
    seen = Any[]
    function stub(method, url, headers, body, timeout)
        push!(seen, (method = method, url = url, headers = headers, body = body))
        if mode[] === :anthropic
            return (status = 200, body =
                "{\"content\":[{\"type\":\"text\",\"text\":\"claude says hi\"}]," *
                "\"stop_reason\":\"end_turn\"," *
                "\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}")
        elseif mode[] === :summary
            return (status = 200, body =
                "{\"choices\":[{\"message\":{\"content\":\"SUMMARY\"}," *
                "\"finish_reason\":\"stop\"}]," *
                "\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":2}}")
        elseif mode[] === :e401
            return (status = 401, body = "{\"error\":{\"message\":\"bad key\"}}")
        elseif mode[] === :e400
            return (status = 400, body = "{\"error\":{\"message\":\"nope\"}}")
        elseif mode[] === :badjson
            return (status = 200, body = "{not json")
        elseif mode[] === :flaky && flaky[] > 0
            flaky[] -= 1
            return (status = 429, body = "{\"error\":\"slow down\"}")
        end
        return (status = 200, body =
            "{\"choices\":[{\"message\":{\"content\":\"answer\"}," *
            "\"finish_reason\":\"stop\"}]," *
            "\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}")
    end
    AirLang._AGENT_HTTP_OVERRIDE[] = stub

    asform(f, args...; map = Pair{Symbol,Form}[]) =
        AirLang._ns_form(Form[Form(f), args...], map)
    game(envx::Env, f, args...; map = Pair{Symbol,Form}[]) =
        air_eval(envx, asform(Symbol("as-user"), Form(Symbol(":game")),
                              asform(f, args...; map = map)))
    game(f, args...; map = Pair{Symbol,Form}[]) = game(env, f, args...; map = map)
    post!(h, v) = game(Symbol("session-post"), h, to_form(v))
    fetch!(h; timeout = 10) = game(Symbol("session-fetch"), h;
                                   map = Pair{Symbol,Form}[
                                       Symbol(":timeout") => Form(timeout)])
    info(h) = air_string(game(Symbol("session-info"), h))
    hist(h) = air_string(game(Symbol("session-history"), h))

    # Wait for the background hook watcher to reach a condition.
    function await(f; seconds = 5.0)
        t0 = time()
        while time() - t0 < seconds
            f() && return true
            sleep(0.05)
        end
        return f()
    end

    try
        # ---- account kinds ---------------------------------------------------
        @test ev("(create-user :game)") == ":game"
        @test ev("(set-admin :game true)") == ":game"
        @test ev("(user-kind :game)") == ":human"
        @test ev("(as-user :game (create-constituent :kid))") == ":game:kid"
        @test ev("(user-kind :game:kid)") == ":human"
        @test ev("(agent? :game:kid)") == "false"

        # a non-admin cannot create one, and a constituent never can
        @test ev("(create-user :pleb)") == ":pleb"
        @test_throws AirEvalError evf(
            "(as-user :pleb (create-agent :bot provider=:fireworks model=\"m\"))")
        @test_throws AirEvalError evf(
            "(as-user :game:kid (create-agent :bot provider=:fireworks model=\"m\"))")

        # ---- configuration ---------------------------------------------------
        @test ev("""
            (as-user :game (create-agent :bot provider=:fireworks model="m1"
                                         api-key="k1" system="be nice"))""") ==
            "(agent base-url=\"https://api.fireworks.ai/inference/v1\" " *
            "dialect=:openai id=:game:bot model=\"m1\" provider=:fireworks)"
        @test ev("(user-kind :game:bot)") == ":agent"
        @test ev("(as-user :game (agent? :bot))") == "true"
        @test ev("(as-user :game (agent? :kid))") == "false"
        @test ev("(as-user :game (agents))") == "(:game:bot)"
        # `set-admin` rewrites the details form of a core user; the kind
        # survives, and an agent (always a constituent) may not be an admin
        @test ev("(set-admin :pleb true)") == ":pleb"
        @test ev("(user-kind :pleb)") == ":human"
        @test_throws AirEvalError evf("(set-admin :game:bot true)")

        # the key is redacted unless `secrets=true`
        @test occursin("api-key=\"***\"", ev("(as-user :game (agent-config :bot))"))
        @test occursin("model=\"m1\"", ev("(as-user :game (agent-config :bot))"))
        @test occursin("api-key=\"k1\"",
                       ev("(as-user :game (agent-config :bot secrets=true))"))
        # a human account is not an agent, and a stranger may not look
        @test_throws AirAgentError evf("(as-user :game (agent-config :kid))")
        @test_throws AirPermissionDenied evf(
            "(as-user :pleb (agent-config :game:bot))")

        # updating the config
        @test occursin("model=\"m2\"",
                       ev("(as-user :game (agent-config! :bot model=\"m2\"))"))
        @test occursin("model=\"m2\"", ev("(as-user :game (agent-config :bot))"))
        ev("(as-user :game (agent-config! :bot model=\"m1\"))")
        # provider defaults and the `:compatible` rule
        @test occursin("base-url=\"https://api.anthropic.com\"",
                       ev("(as-user :game (create-agent :cc provider=:anthropic " *
                          "model=\"c\" api-key=\"k\" system=\"csys\"))"))
        @test_throws AirAgentError evf(
            "(as-user :game (create-agent :cp provider=:compatible model=\"c\"))")
        @test_throws AirAgentError evf(
            "(as-user :game (create-agent :bx provider=:nonesuch model=\"c\"))")
        @test_throws AirDefError evf(
            "(as-user :game (create-agent :bot provider=:fireworks model=\"m\"))")
        # a missing provider defaults to Anthropic
        @test occursin("provider=:anthropic",
                       ev("(as-user :game (create-agent :nod model=\"m\"))"))

        # a missing key fails when a session opens, not at creation
        @test ev("(as-user :game (create-agent :nokey provider=:fireworks " *
                 "model=\"m\"))") isa AbstractString
        @test_throws AirAgentError evf("(as-user :game (open-session :nokey))")
        ev("(as-user :game (agent-config! :nokey api-key=\"late\"))")

        # ---- sessions --------------------------------------------------------
        h = evf("(as-user :game (open-session :bot))")
        @test startswith(air_string(h), "(session")
        @test occursin("agent=:game:bot", air_string(h))
        @test occursin("channel=(channel", air_string(h))
        # the channel's state is the session state, not a copy
        @test AirLang._agent_field(AirLang._agent_field(h, :channel), :state) ===
            AirLang._agent_field(h, :state)
        @test_throws AirAgentError evf("(as-user :game (open-session :kid))")
        @test_throws AirAgentError evf("(as-user :game (open-session :ghost))")
        @test occursin(":s-", ev("(as-user :game (keys (sessions :bot)))"))
        # a short name resolves against the caller's own account, so a
        # stranger must name the agent outright to reach a permission check
        @test_throws AirAgentError evf("(as-user :pleb (sessions :bot))")
        @test_throws AirPermissionDenied evf("(as-user :pleb (sessions :game:bot))")
        @test_throws Exception evf("(as-user :pleb (open-session :bot))")
        @test_throws AirAgentError evf(
            "(as-user :game (open-session :bot id=\"s-ffffffff\"))")
        @test_throws AirEvalError evf(
            "(as-user :game (open-session :bot bogus=1))")
        @test_throws AirEvalError evf(
            "(as-user :game (open-session :bot api-key=\"k2\"))")

        @test occursin("messages=0", info(h))
        @test occursin("status=:open", info(h))
        @test occursin("hook=false", info(h))

        # ---- one turn (OpenAI dialect) --------------------------------------
        mode[] = :openai
        post!(h, Form("hi"))
        reply = fetch!(h)
        @test head_symbol(reply) === :reply
        @test air_string(AirLang._agent_field(reply, :text)) == "\"answer\""
        @test air_string(AirLang._agent_field(reply, :model)) == "\"m1\""
        @test air_string(AirLang._agent_field(reply, :stop)) == "\"stop\""
        @test occursin("usage=(input=5 output=2 total=7)", air_string(reply))
        @test occursin("last-input=5", info(h))
        @test occursin("messages=2", info(h))
        @test occursin("calls=1", info(h))
        @test occursin("(role=:user text=\"hi\")", hist(h))
        @test occursin("(role=:assistant text=\"answer\")", hist(h))
        @test seen[end].url ==
              "https://api.fireworks.ai/inference/v1/chat/completions"
        @test ("authorization" => "Bearer k1") in seen[end].headers
        @test occursin("\"model\":\"m1\"", seen[end].body)
        @test occursin("\"role\":\"system\"", seen[end].body)
        @test occursin("\"content\":\"be nice\"", seen[end].body)

        # the second turn's request carries the first
        post!(h, Form("again"))
        fetch!(h)
        @test occursin("\"content\":\"hi\"", seen[end].body)
        @test occursin("\"content\":\"answer\"", seen[end].body)
        @test occursin("calls=2", info(h))
        @test occursin("messages=4", info(h))

        # ---- commands --------------------------------------------------------
        post!(h, read_air("(:help)"))
        help = fetch!(h)
        @test head_symbol(help) === Symbol(":ack")
        @test occursin(":compact", air_string(help))
        @test occursin("messages=4", info(h))     # a command is not a turn

        post!(h, read_air("(:model \"m3\")"))
        @test air_string(fetch!(h)) == "(:ack :model model=\"m3\")"
        @test occursin("model=\"m3\"", info(h))
        post!(h, read_air("(:system \"be strict\")"))
        @test air_string(fetch!(h)) == "(:ack :system)"
        post!(h, Form("check"))
        fetch!(h)
        @test occursin("\"content\":\"be strict\"", seen[end].body)
        @test occursin("\"model\":\"m3\"", seen[end].body)

        post!(h, read_air("(:context)"))
        ctx = fetch!(h)
        @test head_symbol(ctx) === Symbol(":context")
        @test occursin("messages=6", air_string(ctx))
        @test occursin("estimate=", air_string(ctx))

        post!(h, read_air("(:nonsense)"))
        err = fetch!(h)
        @test head_symbol(err) === Symbol("error")
        @test air_string(AirLang._agent_field(err, :head)) == ":nonsense"

        post!(h, read_air("(:reset)"))
        @test air_string(fetch!(h)) == "(:ack :reset)"
        @test hist(h) == "naught"
        @test occursin("messages=0", info(h))

        # ---- pause and resume ------------------------------------------------
        post!(h, read_air("(:stop)"))
        @test air_string(fetch!(h)) == "(:ack :stop)"
        post!(h, Form("while paused"))
        @test air_string(fetch!(h; timeout = 0.5)) == "naught"
        @test occursin("status=:paused", info(h))
        @test occursin("queued-out=1", info(h))
        game(Symbol("session-resume"), h)
        @test head_symbol(fetch!(h)) === :reply
        @test occursin("status=:open", info(h))

        # ---- the Anthropic dialect -------------------------------------------
        hc = evf("(as-user :game (open-session :cc))")
        mode[] = :anthropic
        post!(hc, Form("hey"))
        r = fetch!(hc)
        @test air_string(AirLang._agent_field(r, :text)) == "\"claude says hi\""
        @test air_string(AirLang._agent_field(r, :stop)) == "\"end_turn\""
        @test occursin("input=7", air_string(r))
        @test seen[end].url == "https://api.anthropic.com/v1/messages"
        @test ("x-api-key" => "k") in seen[end].headers
        @test ("anthropic-version" => "2023-06-01") in seen[end].headers
        @test occursin("\"system\":\"csys\"", seen[end].body)
        # `(:model …)` changes the session, not the agent record
        post!(hc, read_air("(:model \"c2\")"))
        fetch!(hc)
        @test occursin("model=\"c2\"", info(hc))
        @test occursin("model=\"c\"", ev("(as-user :game (agent-config :cc))"))

        # ---- failures --------------------------------------------------------
        mode[] = :e401
        post!(h, Form("unauthorized"))
        r = fetch!(h)
        @test head_symbol(r) === Symbol("error")
        @test occursin("agent-http", air_string(r))
        @test occursin("401", air_string(r))
        mode[] = :openai
        post!(h, Form("recovered"))
        @test head_symbol(fetch!(h)) === :reply

        mode[] = :e400
        post!(h, Form("bad request"))
        @test occursin("agent-http", air_string(fetch!(h)))

        mode[] = :badjson
        post!(h, Form("bad json"))
        @test occursin("valid JSON", air_string(fetch!(h)))

        # 429 is retried, then succeeds
        mode[] = :flaky
        flaky[] = 1
        post!(h, Form("flaky"))
        @test head_symbol(fetch!(h)) === :reply
        @test flaky[] == 0

        # ---- hooks -----------------------------------------------------------
        # installed in the owner's own namespace, so a def there resolves
        @test ev("(as-user :game (val hook-log (stream)))") == "naught"
        @test ev("(as-user :game (def (agent-test-hook ?msg) " *
                 "(post \$.hook-log (current-user))))") == "naught"
        mode[] = :openai
        game(Symbol("session-hook!"), h, Form(Symbol("agent-test-hook")))
        @test occursin("hook=true", info(h))
        post!(h, Form("hooked"))
        @test head_symbol(fetch!(h)) === :reply
        @test await(() -> ev("(as-user :game (count \$.hook-log))") == "1")
        # the hook ran as the receiving end's owner
        @test ev("(as-user :game (fetch \$.hook-log))") == ":game"

        # a failing hook is recorded and does not stop the next message
        ev("(as-user :game (def (agent-test-bad ?msg) (raise :boom)))")
        game(Symbol("session-hook!"), h, Form(Symbol("agent-test-bad")))
        post!(h, Form("bad hook"))
        @test head_symbol(fetch!(h)) === :reply
        @test await(() -> occursin("last-hook-error=(error", info(h)))
        # the original reply is still fetchable after a hook failure
        post!(h, Form("after bad hook"))
        @test head_symbol(fetch!(h)) === :reply

        # unhook stops the copies
        game(Symbol("channel-unhook!"), game(Symbol("session-channel"), h))
        @test occursin("hook=false", info(h))
        n = ev("(as-user :game (count \$.hook-log))")
        post!(h, Form("unhooked"))
        @test head_symbol(fetch!(h)) === :reply
        sleep(0.4)
        @test ev("(as-user :game (count \$.hook-log))") == n

        # ---- compaction ------------------------------------------------------
        @test ev("(as-user :game (create-agent :tiny provider=:fireworks " *
                 "model=\"t1\" api-key=\"k\" context=120 compact-keep=2))") isa String
        ht = evf("(as-user :game (open-session :tiny))")
        mode[] = :summary
        for i in 1:6
            post!(ht, Form("message " * string(i) * " " * "x"^90))
            @test head_symbol(fetch!(ht)) === :reply
        end
        @test occursin("role=:summary", hist(ht))
        @test occursin("limit=120", info(ht))
        @test !occursin("compactions=0", info(ht))
        # the summary reaches the next request as a system message
        post!(ht, Form("after compaction"))
        fetch!(ht)
        @test occursin("SUMMARY", seen[end].body)

        # ---- closing ---------------------------------------------------------
        game(Symbol("session-close!"), h)
        @test occursin("status=:closed", info(h))
        game(Symbol("session-close!"), h)    # idempotent
        @test_throws Exception post!(h, Form("after close"))

        # ---- durability and lazy resume --------------------------------------
        mode[] = :openai
        ev("(as-user :game (create-agent :dur provider=:fireworks model=\"d1\" " *
           "api-key=\"k\"))")
        hd = evf("(as-user :game (open-session :dur))")
        post!(hd, Form("first"))
        @test head_symbol(fetch!(hd)) === :reply
        hst = AirLang._agent_field(hd, :state)
        sid = AirLang._agent_string(
            AirLang._agent_field(AirLang._session_value(hst), :id))
        @test startswith(sid, "s-")
        @test ev("(as-user :game (keys (sessions :dur)))") ==
            "(:$(Symbol(sid)))"

        # "down": a message is queued, the status stays :open, and no worker is
        # registered; a second Env over the same database is the restart
        post!(hd, read_air("(:stop)"))
        fetch!(hd)
        post!(hd, Form("queued while down"))
        AirLang._agent_update!(env, hst) do cur
            AirLang._agent_set(cur,
                               [Symbol(":status") => AirLang._keyword_form(:open)])
        end
        empty!(AirLang._AGENT_WORKERS)
        env2 = Env(db = db)
        h2 = air_eval(env2, read_air("(as-user :game (open-session :dur id=\"$sid\"))"))
        @test occursin("(role=:user text=\"first\")",
                       air_string(game(env2, Symbol("session-history"), h2)))
        r = game(env2, Symbol("session-fetch"), h2;
                 map = Pair{Symbol,Form}[Symbol(":timeout") => Form(10)])
        @test head_symbol(r) === :reply
        @test occursin("\"content\":\"first\"", seen[end].body)
        @test occursin("\"content\":\"queued while down\"", seen[end].body)
        @test occursin("messages=4",
                       air_string(game(env2, Symbol("session-info"), h2)))
        game(env2, Symbol("session-close!"), h2)
    finally
        AirLang._AGENT_HTTP_OVERRIDE[] = nothing
        empty!(AirLang._AGENT_WORKERS)
        empty!(AirLang._AGENT_HOOKS)
    end
end
