# Connections: the durable `.io.conn` records, their ACLs, and attaching a
# widget to a byte source and detaching it again.
@testset "ui connections" begin
    B = AirLang
    db = MemoryDatabase()
    env = Env(db = db)
    ev(s) = air_string(air_eval(env, read_air(s)))
    evd(s) = air_eval(env, read_air(s))

    ESC = UI_ESC

    errmsg(f) = ui_errmsg(f)
    wait_for(f; kw...) = ui_wait_for(f; kw...)

    # A connection over a byte queue the test feeds: the renderer sees no input
    # until the test pushes it, which keeps "while attached" deterministic.
    made = B._ConnHandle[]
    function scripted(user::Symbol; kind::Symbol = :std, e::Env = env)
        queue = UInt8[]
        out = IOBuffer()
        bk = B._StreamBackend(out; cols = Ref(40), rows = Ref(12),
                              readbyte = () -> isempty(queue) ? nothing :
                                          popfirst!(queue))
        h = B._conn_open!(e, kind, user; backend = bk)
        push!(made, h)
        return (h, queue)
    end

    records(vf) = B._conn_records(vf[])
    record(vf, id) = only(filter(r -> B._conn_record_id(r) == id, records(vf)))
    txt(x) = air_string(x)
    field(r, k) = txt(B._conn_field(r, Symbol(":", String(k))))
    conn(h) = "." * join(String.(h.path), ".")

    try
        # Compile the attach path once, synchronously, in a scratch environment.
        # A first attach inside a spawned task can take seconds to compile, which
        # the polls below would read as a hang.
        @testset "warm-up" begin
            envw = Env(db = MemoryDatabase())
            (h0, q0) = scripted(:air; e = envw)
            push!(q0, ESC)
            @test air_string(air_eval(envw,
                read_air("(ui-attach! $(conn(h0)) (ui-notebook))"))) == "naught"
            B._conn_close!(envw, h0)
        end

        @testset "registration and paths" begin
            (h1, _) = scripted(:air)
            @test h1.id === :std
            @test h1.path == [:io, :conn, :air, :std]
            @test conn(h1) == ".io.conn.air.std"
            vf1 = B._conn_state(env, h1.path)
            @test vf1 isa VolatileForm
            @test length(records(vf1)) == 1
            r1 = record(vf1, :std)
            # A record is a `(conn …)` map form of inert data.
            @test startswith(txt(r1), "(conn ")
            @test field(r1, :id) == ":std"
            @test field(r1, :kind) == ":std"
            @test field(r1, :user) == ":air"
            @test field(r1, :principal) == ":air"
            @test field(r1, :tty) == "false"
            @test field(r1, :cols) == "80"
            @test field(r1, :rows) == "24"
            @test field(r1, :attached) == "naught"
            @test field(r1, :closed) == "naught"
            @test startswith(field(r1, :since), "(time ")
            # Every field is inert, so the record survives a store and reload.
            @test ev("(value .io.conn.air.std)") == txt(B._conn_records_form([r1]))
            @test air_string(air_eval(env, read_air(txt(B._conn_records_form([r1]))))) ==
                  txt(B._conn_records_form([r1]))

            # Air's next connection is a named endpoint of its own.
            (h2, _) = scripted(:air)
            @test h2.id === :s1
            @test h2.path == [:io, :conn, :air, :s1]
            @test length(records(B._conn_state(env, h2.path))) == 1

            # A core user's records live at `.io.conn.<user>`.
            @test ev("(create-user :carol)") == ":carol"
            (h3, _) = scripted(:carol; kind = :ssh)
            @test h3.id === :s1
            @test h3.path == [:io, :conn, :carol]
            @test field(record(B._conn_state(env, h3.path), :s1), :user) == ":carol"
            # A second connection by the same user shares the endpoint.
            (h3b, _) = scripted(:carol; kind = :ssh)
            @test h3b.path == h3.path
            @test h3b.id === :s2
            @test length(records(B._conn_state(env, h3.path))) == 2

            # A constituent's record is a named entry under its admin.
            @test ev("(create-constituent :bob)") == ":air:bob"
            (h4, _) = scripted(Symbol("air:bob"); kind = :ssh)
            @test h4.id === :s1
            @test h4.path == [:io, :conn, :air, :bob]
            @test conn(h4) == ".io.conn.air.bob"
            @test field(record(B._conn_state(env, h4.path), :s1), :user) == ":air:bob"
        end

        @testset "the record is readable, not editable, by its user" begin
            (h, _) = scripted(Symbol("air:bob"); kind = :ssh)
            vf = B._conn_state(env, h.path)
            acl = B._meta_acl(vf)
            @test get(get(acl, :read, Dict{Symbol,Bool}()), B._ALL_USERS, false)
            @test get(get(acl, :exec, Dict{Symbol,Bool}()), B._ALL_USERS, false)
            @test get(acl[:write], :air, false)
            @test !get(acl[:write], Symbol("air:bob"), false)
            # The named user reaches the record through the ordinary path,
            # which means `.io` and `.io.conn` are world read-executable.
            @test occursin("conn ", ev("(as-user :air:bob (value .io.conn.air.bob))"))
            @test occursin("permission denied",
                           errmsg(() -> ev("(as-user :air:bob (set! .io.conn.air.bob ()))")))
            # The system writes it, even though the user may not.
            h.cols = 100
            B._conn_persist!(env, h)
            @test occursin("cols=100",
                           ev("(as-user :air:bob (value .io.conn.air.bob))"))
        end

        @testset "attach and detach" begin
            # Make this the only live connection, so the no-argument forms
            # (`(ui-attach!)`, `(ui-attached)`) resolve to it.
            for old in made
                old.env === env || continue
                try
                    B._conn_close!(env, old)
                catch
                end
            end
            empty!(made)
            (h, queue) = scripted(:air)
            w = conn(h)
            t = @async evd("(ui-attach! $w (ui-notebook))")
            @test wait_for(() -> h.inst !== nothing)
            inst = h.inst
            # An attach's projection is not a named resource: nothing outside
            # the attach can look the instance up.
            @test inst.ephemeral
            @test !haskey(B._UI_INSTANCES, inst.key)
            # `(ui-attached)` names the element: the form to store to keep it.
            @test ev("(ui-attached $w)") == ev("(ui-attached)")
            @test occursin("(ui notebook ", ev("(ui-attached)"))
            # The record says a projection is attached, without naming it.
            @test field(record(B._conn_state(env, h.path), h.id), :attached) == "true"
            # The element records its controller transactionally.
            sk = B._map_key(:state)
            @test haskey(inst.widget.map, sk)
            st = to_form(inst.widget.map[sk])
            @test st isa VolatileForm
            controller() = B._ui_in_context(inst) do
                B._state_field(canonicalize(st[]), :controller)
            end
            @test B._stored_path(controller()) == h.path
            # One root widget per connection is the rule, not a stack.
            @test occursin(":ui-attached",
                           errmsg(() -> ev("(ui-attach! $w (ui-notebook))")))
            # Esc dismisses the notebook; the attach returns, the record clears,
            # and the controller is gone while the element itself still exists.
            push!(queue, ESC)
            @test wait_for(() -> istaskdone(t))
            @test txt(evd("(ui-attached $w)")) == "naught"
            @test field(record(B._conn_state(env, h.path), h.id), :attached) == "naught"
            @test controller() === nothing
            @test !haskey(B._UI_INSTANCES, inst.key)
        end

        @testset "an ephemeral attach outlives its renderer for a job" begin
            (h, queue) = scripted(:air)
            w = conn(h)
            # A long enough evaluation that the renderer leaves before it lands.
            slow = "(loop (i 0) (if (< i 20000) (recur (+ i 1)) i))"
            t = @async evd("(ui-attach! $w (ui-code text=\"$slow\"))")
            @test wait_for(() -> h.inst !== nothing)
            inst = h.inst
            st = to_form(inst.widget.map[B._map_key(:state)])
            push!(queue, UI_CTRL_J, ESC)
            @test wait_for(() -> istaskdone(t))
            # The renderer is gone; the projection is not released while the job
            # runs, and its result is written into the element's state.
            state() = B._ui_in_context(inst) do
                canonicalize(st[])
            end
            @test wait_for(() -> begin
                v = state()
                s = B._state_string(v, :output)
                !isempty(s) && s == "20000"
            end)
            @test wait_for(() -> inst.closed)
            # Releasing the projection left the element intact.
            @test B._state_string(state(), :text) == slow
        end

        @testset "a widget attached elsewhere is not taken over" begin
            (h1, q1) = scripted(:air)
            (h2, _) = scripted(:air)
            @test ev("(ui-open :busy (ui-notebook))") == ":busy"
            t = @async evd("(ui-attach! $(conn(h1)) :busy)")
            @test wait_for(() -> h1.inst !== nothing)
            @test h2.inst === nothing
            @test occursin(":ui-attached",
                           errmsg(() -> ev("(ui-attach! $(conn(h2)) :busy)")))
            push!(q1, ESC)
            @test wait_for(() -> istaskdone(t))
            @test ev("(ui-close! :busy)") == "naught"
        end

        @testset "detaching keeps the instance" begin
            (h, _) = scripted(:air)
            w = conn(h)
            @test ev("(ui-open :keep (ui-notebook))") == ":keep"
            t = @async evd("(ui-attach! $w :keep)")
            @test wait_for(() -> h.inst !== nothing)
            @test h.inst.key === :keep
            @test ev("(ui-detach! $w)") == "naught"
            @test wait_for(() -> istaskdone(t))
            @test h.inst === nothing
            # The instance is a process resource the attach did not own.
            @test occursin(":keep", ev("(ui-instances)"))
            @test ev("(ui-values :keep)") == "naught"
            @test ev("(ui-close! :keep)") == "naught"
        end

        @testset "attach by connection id and by record" begin
            (h, queue) = scripted(:air)
            w = conn(h)
            t = @async evd("(ui-attach! :$(h.id) (ui-notebook))")
            @test wait_for(() -> h.inst !== nothing)
            push!(queue, ESC)
            @test wait_for(() -> istaskdone(t))

            # A dotted string names a connection too.
            (h2, queue2) = scripted(:air; kind = :ssh)
            w2 = conn(h2)
            t2 = @async evd("(ui-attach! \"$(w2[2:end])\" (ui-notebook))")
            @test wait_for(() -> h2.inst !== nothing)
            push!(queue2, ESC)
            @test wait_for(() -> istaskdone(t2))

            # The mutable itself is a connection argument too.
            t3 = @async evd("(ui-attach! $w2 (ui-notebook))")
            @test wait_for(() -> h2.inst !== nothing)
            push!(queue2, ESC)
            wait_for(() -> istaskdone(t3))
        end

        @testset "a closed connection refuses a widget" begin
            (h, _) = scripted(:air)
            w = conn(h)
            B._conn_close!(env, h)
            @test field(record(B._conn_state(env, h.path), h.id), :closed) != "naught"
            @test occursin(":conn-closed",
                           errmsg(() -> ev("(ui-attach! $w (ui-notebook))")))
        end

        @testset "(ui-connection) and (ui-connections)" begin
            (h, _) = scripted(:air)
            w = conn(h)
            (hb, _) = scripted(Symbol("air:bob"); kind = :ssh)
            @test occursin("conn ", ev("(ui-connection)"))
            @test occursin("conn ", ev("(ui-connection $w)"))
            @test occursin("id=:$(h.id)", ev("(ui-connections)"))
            @test occursin("id=:$(h.id)", ev("(ui-connections :air)"))
            @test occursin("id=:$(hb.id)", ev("(ui-connections :air:bob)"))
            # A constituent sees its own connections and nobody else's.
            bob = ev("(as-user :air:bob (ui-connections))")
            @test occursin("principal=:air:bob", bob)
            @test !occursin("id=:$(h.id)", bob)
            @test occursin("permission denied",
                           errmsg(() -> ev("(as-user :air:bob (ui-connections :air))")))
        end

        @testset "ui-show needs a connection or a session channel" begin
            env2 = Env(db = MemoryDatabase())
            ev2(s) = air_string(air_eval(env2, read_air(s)))
            @test ev2("(ui-open :bare (ui-notebook))") == ":bare"
            @test occursin(":no-renderer", errmsg(() -> ev2("(ui-show :bare)")))
            @test ev2("(ui-close! :bare)") == "naught"
        end
    finally
        for h in made
            try
                B._conn_close!(h.env, h)
            catch
            end
        end
    end

    # The local backend is the process's own stdin/stdout. A reader task parks
    # bytes in a channel (a TTY has no usable non-blocking read) and the
    # renderer drains them each tick; this is testable over ordinary IOs.
    @testset "the local terminal backend" begin
        out = IOBuffer()
        b = B._LocalBackend(in = IOBuffer(UInt8[0x61, 0x62]), out = out,
                            tty = false, cols = 30, rows = 10)
        @test B._tb_size(b) == (30, 10)
        B._tb_enter!(b)
        @test occursin("\e[?1049h", String(take!(out)))
        @test wait_for(() -> B._tb_drain!(b) == UInt8[0x61, 0x62])
        # Bytes handed back are read next, ahead of anything new.
        B._tb_unread!(b, UInt8[0x62])
        @test B._tb_drain!(b) == UInt8[0x62]
        B._tb_leave!(b)
        @test occursin("\e[?1049l", String(take!(out)))

        # The renderer runs over it like any other backend.
        env2 = Env(db = MemoryDatabase())
        ev2(s) = air_string(air_eval(env2, read_air(s)))
        ev2("(val lbw (ui-code))")
        ev2("(ui-open :lb lbw)")
        out2 = IOBuffer()
        b2 = B._LocalBackend(in = IOBuffer(vcat(UInt8[0x61, 0x62], [ESC])),
                             out = out2, tty = false, cols = 40, rows = 12)
        r2 = B._TermRenderer(b2)
        inst = B._ui_lookup(env2, Form(Symbol(":lb")))
        @test B._ui_term_run!(r2, inst) === naught
        txt = String(take!(out2))
        @test occursin("\e[?1049h", txt) && occursin("\e[?1049l", txt)
        @test occursin("ab", txt)
        ev2("(ui-close! :lb)")
    end
end
