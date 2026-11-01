# The chat: a conversation over a pair of streams, the input pinned to the
# bottom, code mode sending the result and never the source, and the pump that
# brings the peer's messages in while the renderer runs.
    @testset "ui chat" begin
    B = AirLang
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evd(s) = air_eval(env, read_air(s))

    ESC = UI_ESC
    ENTER = UI_ENTER
    CTRL_J = UI_CTRL_J

    errmsg(f) = ui_errmsg(f)
    wait_for(f; kw...) = ui_wait_for(f; kw...)

    state_of(w) = w.map[Symbol(":state")]
    state_value(w) = B.canonicalize(state_of(w)[])

    open_form!(key, w) = ui_open_form!(env, key, w)

    # Drive a widget with a fixed byte script; Esc ends the run.
    term_run(key, bytes; kw...) = ui_term_run(env, key, bytes; kw...)

    bytes(s) = ui_bytes(s)

    # `(post s v)` / `(fetch s timeout=…)` from the test, so a stream is read
    # without going through the widget.
    function post!(s, v::Form)
        call = AirDB.FormContainer(
            AirDB.FormSeq(AirDB.FormValue[B._store_form(Form(:post)), s,
                                          B._store_form(v)]),
            AirDB.FormMap())
        return B._bi_post(env, B._base_scope(env), call)
    end

    function fetch!(s)
        call = AirDB.FormContainer(
            AirDB.FormSeq(AirDB.FormValue[B._store_form(Form(:fetch)), s]),
            AirDB.FormMap(Pair{Symbol,AirDB.FormValue}[
                Symbol(":timeout") => B._store_form(Form(0.05))]))
        return B._bi_fetch(env, B._base_scope(env), call)
    end

    function drain(s)
        out = Form[]
        while true
            v = fetch!(s)
            v === naught && break
            push!(out, v)
        end
        return out
    end

    # A stream pair for one scenario, as vals so air source can name them.
    stream_val!(name::Symbol) = (ev("(val $(name) (stream))");
                                 evd("(value .main.$(name))"))

    # The stored log as `(from, kind, body)` triples.
    function log_of(w)
        v = state_value(w)
        l = B._state_field(v, :log)
        l isa AirDB.FormContainer || return Tuple{Symbol,Symbol,String}[]
        return [(B._chat_leaf_symbol(B._state_field(to_form(el), :from), :peer),
                 B._chat_leaf_symbol(B._state_field(to_form(el), :kind), :text),
                 B._state_string(to_form(el), :body)) for el in l.seq]
    end

    draft_of(w) = B._state_string(state_value(w), :draft)

    @testset "the widget form" begin
        stream_val!(:w_in)
        stream_val!(:w_out)
        w = evd("(ui-chat in=w_in out=w_out peer=:alice)")
        @test startswith(air_string(w), "(ui chat")
        @test haskey(w.map, Symbol(":state"))
        @test haskey(w.map, Symbol(":in"))
        @test haskey(w.map, Symbol(":out"))
        @test B._chat_leaf_text(w.map[Symbol(":peer")]) == "alice"
        @test log_of(w) == Tuple{Symbol,Symbol,String}[]
        @test draft_of(w) == ""
        # Both directions are required, and only streams are accepted.
        @test occursin("in=", errmsg(() -> ev("(ui-chat out=w_out)")))
        @test occursin("must be a stream",
                       errmsg(() -> ev("(ui-chat in=\"x\" out=w_out)")))
        @test occursin("must be a stream", errmsg(() -> ev("(ui-chat in=w_in)")))
    end

    @testset "sending text" begin
        sin = stream_val!(:t_in)
        sout = stream_val!(:t_out)
        w = evd("(ui-chat in=t_in out=t_out peer=:alice)")
        open_form!(:ch1, w)
        (res, _) = term_run(:ch1, vcat(bytes("hello"), [CTRL_J, ESC]))
        @test res[1] === :ok
        got = drain(sout)
        @test length(got) == 1
        @test air_string(got[1]) == "\"hello\""
        @test log_of(w) == [(:me, :text, "hello")]
        @test draft_of(w) == ""
        # Nothing came back on the inbox stream.
        @test isempty(drain(sin))
        ev("(ui-close! :ch1)")
    end

    @testset "enter inserts a newline; ctrl-j sends" begin
        stream_val!(:n_in)
        sout = stream_val!(:n_out)
        w = evd("(ui-chat in=n_in out=n_out)")
        open_form!(:ch2, w)
        (res, _) = term_run(:ch2, vcat(bytes("ab"), [ENTER], bytes("cd"),
                                       [CTRL_J, ESC]))
        @test res[1] === :ok
        got = drain(sout)
        @test length(got) == 1
        @test air_string(got[1]) == "\"ab\\ncd\""
        @test log_of(w) == [(:me, :text, "ab\ncd")]
        ev("(ui-close! :ch2)")
    end

    @testset "code mode sends the result, never the source" begin
        stream_val!(:c_in)
        sout = stream_val!(:c_out)
        w = evd("(ui-chat in=c_in out=c_out peer=:alice)")
        open_form!(:ch3, w)
        (res, _) = term_run(:ch3, vcat(bytes("(- 10 4)"), [CTRL_J, ESC]))
        @test res[1] === :ok
        # The sender sees the source and the result; the peer sees only the
        # value.
        @test log_of(w) == [(:me, :code, "(- 10 4)"), (:me, :result, "6")]
        got = drain(sout)
        @test length(got) == 1
        @test air_string(got[1]) == "6"
        ev("(ui-close! :ch3)")
    end

    @testset "an error stays on the sender's side" begin
        stream_val!(:e_in)
        sout = stream_val!(:e_out)
        w = evd("(ui-chat in=e_in out=e_out)")
        open_form!(:ch4, w)
        (res, _) = term_run(:ch4, vcat(bytes("(raise :boom)"), [CTRL_J, ESC]))
        @test res[1] === :ok
        log = log_of(w)
        @test length(log) == 2
        @test log[1] == (:me, :code, "(raise :boom)")
        @test log[2][1] === :me && log[2][2] === :error
        @test occursin("boom", log[2][3])
        @test isempty(drain(sout))
        ev("(ui-close! :ch4)")
    end

    @testset "the pump receives, and the two sides are tinted differently" begin
        sin = stream_val!(:r_in)
        sout = stream_val!(:r_out)
        w = evd("(ui-chat in=r_in out=r_out peer=:alice)")
        open_form!(:ch5, w)
        queue = UInt8[]
        out = IOBuffer()
        bk = B._StreamBackend(out; cols = Ref(40), rows = Ref(12),
                              readbyte = () -> isempty(queue) ? nothing :
                                          popfirst!(queue))
        r = B._TermRenderer(bk)
        inst = B._ui_lookup(env, Form(Symbol(":ch5")))
        t = @async B._ui_term_run!(r, inst)
        try
            @test wait_for(() -> r.comp isa B._Chat)
            post!(sin, Form("hi from alice"))
            @test wait_for(() -> r.comp isa B._Chat &&
                                 any(m -> m.body == "hi from alice",
                                     r.comp.msgs))
            # Reply so both backgrounds are in one frame.
            append!(queue, vcat(bytes("hi bob"), [CTRL_J]))
            @test wait_for(() -> any(m -> m.body == "hi bob", r.comp.msgs))
            frame = String(take!(out))
            @test occursin("48;5;238", frame)          # the peer's tint
            @test occursin("48;5;236", frame)          # this side's tint
            @test occursin("peer: alice", frame)
            @test occursin("hi from alice", frame)
            @test occursin("hi bob", frame)
        finally
            push!(queue, ESC)
            wait_for(() -> istaskdone(t))
        end
        @test log_of(w) == [(:peer, :text, "hi from alice"),
                            (:me, :text, "hi bob")]
        @test length(drain(sout)) == 1
        ev("(ui-close! :ch5)")
    end

    @testset "the draft survives a detach" begin
        stream_val!(:d_in)
        stream_val!(:d_out)
        w = evd("(ui-chat in=d_in out=d_out)")
        open_form!(:ch6, w)
        (res, _) = term_run(:ch6, vcat(bytes("unfinished"), [ESC]))
        @test res[1] === :ok
        @test draft_of(w) == "unfinished"
        # Reopening the same widget restores it.
        inst = B._ui_lookup(env, Form(Symbol(":ch6")))
        c = B._comp_chat(inst, inst.root)
        @test B._tb_text(c.input.buf) == "unfinished"
        B._comp_close!(c, inst)
        ev("(ui-close! :ch6)")
    end

    @testset "messages that arrive while scrolled away are marked unread" begin
        stream_val!(:u_in)
        stream_val!(:u_out)
        w = evd("(ui-chat in=u_in out=u_out peer=:alice)")
        open_form!(:ch7, w)
        inst = B._ui_lookup(env, Form(Symbol(":ch7")))
        c = B._comp_chat(inst, inst.root)
        c.log_rows = 6
        # A message read at the bottom of the log is not unread.
        B._chat_receive!(c, inst, Form("one"))
        @test c.unread == 0
        # Scrolling away and then receiving counts what is below the window.
        c.stick = false
        c.scroll = 1
        B._chat_receive!(c, inst, Form("two"))
        B._chat_receive!(c, inst, Form("three"))
        @test c.unread == 2
        st = B._comp_status(c, inst)
        @test occursin("2 new", st)
        @test occursin("peer: alice", st)
        @test B._comp_hints(c)[2].first == "ctrl-v: 2 new"
        # The log draws a rule where the unseen messages begin.
        lines = [l.text for l in B._chat_window(c, 30, 6)]
        d = findfirst(l -> occursin("2 new", l), lines)
        @test d !== nothing
        @test findfirst(l -> startswith(l, "two"), lines) > d
        # Reaching the bottom clears the count.
        ctrl_v = B._ui_key(:char; char = 'v', ctrl = true)
        B._comp_key!(c, inst, ctrl_v)
        B._comp_key!(c, inst, ctrl_v)
        @test c.stick
        @test c.unread == 0
        @test !occursin("new", B._comp_status(c, inst))
        @test B._comp_hints(c)[2].first == "ctrl-v: scroll"
        @test all(l -> !occursin("2 new", l),
                  [l.text for l in B._chat_window(c, 30, 6)])
        # While stuck, the next one is read as it lands.
        B._chat_receive!(c, inst, Form("four"))
        @test c.unread == 0
        @test any(l -> startswith(l.text, "four"),
                  B._chat_window(c, 30, 6))
        B._comp_close!(c, inst)
        ev("(ui-close! :ch7)")
    end
end
