################################################################################
# ssh/session.jl
#
# One accepted connection, from the socket to the last byte.
#
# The socket comes from Julia's libuv listener, but libssh owns it from the moment
# `ssh_bind_accept_fd` sees it. To keep that ownership unambiguous the accepted
# descriptor is duplicated and the `TCPSocket` closed at once, so libssh closes
# exactly one descriptor and Julia closes the other.
#
# The handshake, authentication, channel open, and channel-request phase all run
# with the session in blocking mode; every blocking entry point goes through the
# libuv thread pool (`@threadcall` in `libssh.jl`) and is bounded by
# `SSH_OPTIONS_TIMEOUT`, so a stalled client cannot freeze a single-threaded air
# process. Once the shell or sftp request is answered the session switches to
# non-blocking mode and the data phase polls.
#
# A session evaluates as the user it authenticated as, in that user's home
# namespace, with the database root captured when the server started, and with
# its channel as the output sink for `(print …)`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _SSH_HANDSHAKE_TIMEOUT = 10

# Julia hands a stream's descriptor back as a `RawFD`, which `Int` does not
# accept; `Base.cconvert` is the conversion the ccall machinery itself uses.
_ssh_fd(sock) = Base.cconvert(Cint, Base._fd(sock))

"""
    _ssh_session!(server, sock)

Service one accepted socket: handshake, authenticate, and then either a remote
REPL, an sftp subsystem, or nothing at all. Everything libssh owns is released
here; a failure ends this connection only.
"""
function _ssh_session!(server::_SshServer, sock)
    fd = ccall(:dup, Cint, (Cint,), _ssh_fd(sock))
    close(sock)
    if fd < 0
        @debug "air ssh connection dropped: the socket could not be duplicated"
        return nothing
    end
    session = _ls_new()
    if session == C_NULL
        ccall(:close, Cint, (Cint,), fd)
        @debug "air ssh connection dropped: libssh could not allocate a session"
        return nothing
    end
    chan = C_NULL
    # libssh owns the descriptor as soon as the session holds it; until then it
    # is ours to close. `_ls_get_fd` is the authority on which it is.
    owned = true
    try
        # The descriptor we hand over came from Julia's non-blocking listener, so
        # the session must be told to block explicitly; otherwise every libssh
        # call becomes a non-blocking poll and the handshake reads as "no data".
        _ls_set_blocking(session, true)
        _ls_set_timeout(session, _SSH_HANDSHAKE_TIMEOUT)
        rc = _ls_bind_accept_fd(server.bindptr, session, fd)
        owned = !(fd > 0 && Int(_ls_get_fd(session)) == fd)
        if rc == SSH_ERROR
            @debug "air ssh connection dropped during accept" error = _ssh_error(server.bindptr)
            return nothing
        end
        if _ls_handle_key_exchange(session) == SSH_ERROR
            @debug "air ssh connection dropped during key exchange" error = _ssh_error(session)
            return nothing
        end
        # A session task has no context of its own, so give it the server's
        # captured database root. `_ssh_admit` reads a user's `$.config.ssh` as
        # that user and the subsystem starts in their home; both paths resolve
        # through `@`, and without this the session would look in the process
        # store instead of the database the server was started over. The context
        # is per task, so setting `user` inside it does not disturb anyone else.
        ctx = TaskContext(server.owner, nothing, server.dbroot, naught)
        run_session = function ()
            auth = _ssh_auth_new(server.env, server)
            if !_ssh_authenticate!(auth, session)
                @debug "air ssh connection dropped: authentication failed" failures = auth.failures
                return nothing
            end
            id = auth.claimed
            if id === nothing
                @debug "air ssh connection dropped: authentication completed without a user"
                return nothing
            end
            chan = _ssh_channel_open!(session)
            if chan == C_NULL
                @debug "air ssh connection dropped: no session channel" user = id
                return nothing
            end
            _ssh_serve!(server, session, chan, id)
            return nothing
        end
        _with_context(server.env, ctx, run_session)
    catch e
        # A client's failure is that client's problem; it never reaches the
        # server's task. `@debug` keeps the diagnosis reachable without making a
        # hostile or merely broken client noisy.
        e isa InterruptException && rethrow()
        @debug "air ssh session failed" exception = (e, catch_backtrace())
    finally
        if chan != C_NULL
            try
                _ssh_finish_channel!(chan)
                _ssh_wait_client_close!(session)
            catch
            end
            _ls_channel_free(chan)
        end
        # No `ssh_disconnect` here: a cleanly closed channel is the end of the
        # conversation, and an explicit disconnect message makes the client
        # report "Connection to … closed by remote host" after a successful
        # session. `ssh_free` closes the socket.
        _ls_free(session)
        owned && ccall(:close, Cint, (Cint,), fd)
    end
    return nothing
end

# End the channel politely: report a zero exit status and an EOF, then pump the
# socket until the client acknowledges the close (or two seconds pass). Without
# the exit status the client reports 255 instead of success, and closing the
# channel before the client has read its last bytes truncates the output. The
# session is non-blocking here, so a send that libssh has no room for is retried
# on the next pass rather than dropped.
function _ssh_finish_channel!(chan::Ptr{Cvoid})
    sent_status = sent_close = false
    buf = Vector{UInt8}(undef, 256)
    deadline = time() + 2.0
    while time() < deadline
        if !sent_status
            rc = _ls_channel_send_exit_status(chan, 0)
            sent_status = rc != SSH_AGAIN && rc != SSH_ERROR
        end
        if !sent_close
            # `ssh_channel_close` sends EOF along with the close itself.
            rc = _ls_channel_close(chan)
            sent_close = rc != SSH_AGAIN && rc != SSH_ERROR
        end
        _ls_channel_is_closed(chan) && break
        # Any read pumps the incoming packets the close needs.
        _ls_channel_read_nonblocking(chan, pointer(buf), length(buf)) == SSH_ERROR &&
            break
        sleep(0.005)
    end
    return nothing
end

# Let the client hang up first. A client that has seen the channel close sends its
# own disconnect and closes the socket; dropping the connection underneath it
# makes `ssh` report "Connection to … closed by remote host" after a session that
# actually succeeded. Bounded, because a client is free to linger.
function _ssh_wait_client_close!(session::Ptr{Cvoid})
    deadline = time() + 1.0
    while time() < deadline && _ls_is_connected(session)
        m = _ls_message_get(session)
        if m == C_NULL
            sleep(0.005)
        else
            _ls_message_reply_default(m)
            _ls_message_free(m)
        end
    end
    return nothing
end

# Wait for the client's channel open and accept it. Everything else is refused.
function _ssh_channel_open!(session::Ptr{Cvoid})
    while true
        m = _ls_message_get(session)
        m == C_NULL && return C_NULL
        try
            if _ls_message_type(m) == SSH_REQUEST_CHANNEL_OPEN &&
               _ls_message_subtype(m) == SSH_CHANNEL_SESSION
                return _ls_channel_open_accept(m)
            end
            _ls_message_reply_default(m)
        finally
            _ls_message_free(m)
        end
    end
end

# Answer the channel requests that precede a shell or sftp subsystem. A pty
# request records the initial size; `env` requests are accepted and ignored.
# `exec` is refused: air sessions are interactive or sftp, nothing else.
function _ssh_channel_kind!(session::Ptr{Cvoid}, chan::Ptr{Cvoid})
    cols, rows, tty = 80, 24, false
    while true
        m = _ls_message_get(session)
        m == C_NULL && return (nothing, cols, rows, tty)
        try
            if _ls_message_type(m) != SSH_REQUEST_CHANNEL ||
               _ls_channel_request_channel(m) != chan
                _ls_message_reply_default(m)
                continue
            end
            st = _ls_message_subtype(m)
            if st == SSH_CHANNEL_REQUEST_PTY
                cols = max(20, Int(_ls_channel_request_pty_width(m)))
                rows = max(5, Int(_ls_channel_request_pty_height(m)))
                tty = true
                _ls_channel_request_reply_success(m)
            elseif st == SSH_CHANNEL_REQUEST_ENV
                _ls_channel_request_reply_success(m)
            elseif st == SSH_CHANNEL_REQUEST_SHELL
                _ls_channel_request_reply_success(m)
                return (:repl, cols, rows, tty)
            elseif st == SSH_CHANNEL_REQUEST_SUBSYSTEM &&
                   _ls_channel_request_subsystem(m) == "sftp"
                _ls_channel_request_reply_success(m)
                return (:sftp, cols, rows, tty)
            elseif st == SSH_CHANNEL_REQUEST_WINDOW_CHANGE
                _ls_channel_request_reply_success(m)
            else
                _ls_message_reply_default(m)
            end
        finally
            _ls_message_free(m)
        end
    end
end

# The key a user's default UI is registered under. The length-prefixed user id
# keeps two ids that differ only in punctuation (`:a:b` and `:a_b`) apart.
function _ssh_ui_key(id::Symbol)
    s = String(id)
    return Symbol("ssh-ui-", length(s), "_", replace(s, ':' => '_'))
end

# The UI an interactive login opens: a tab shell whose browser and notebook sit
# in the session's current namespace (the user's home). It is a named instance,
# so an SSH reconnect finds the same shell — tabs, buffers, and all — where the
# last session left it; only when the user closed it does a login open a fresh
# one under the same key. The returned form is the one to bind `(current-ui)` to.
function _ssh_login_ui(env::Env, id::Symbol)
    key = _ssh_ui_key(id)
    kf = _ui_key_form(key)
    inst = try
        _ui_lookup(env, kf)
    catch e
        e isa AirEvalError || rethrow()
        nothing
    end
    inst === nothing || return (kf, inst.widget)
    tree = FormContainer(FormSeq(FormValue[_store_form(Form(Symbol("ui-shell")))]),
                         FormMap())
    call = FormContainer(FormSeq(FormValue[
        _store_form(Form(Symbol("ui-open"))),
        _store_form(kf),
        _store_form(tree)]), FormMap())
    try
        _bi_ui_open(env, Scope(), call)
    catch e
        # Another login for this user won the race; use the instance it made.
        e isa AirEvalError || rethrow()
        return (kf, _ui_lookup(env, kf).widget)
    end
    return (kf, _ui_lookup(env, kf).widget)
end

# Hand the accepted, authenticated channel to its subsystem.
function _ssh_serve!(server::_SshServer, session::Ptr{Cvoid}, chan::Ptr{Cvoid},
                     id::Symbol)
    kind, cols, rows, tty = _ssh_channel_kind!(session, chan)
    if kind === nothing
        @debug "air ssh session ended: no shell or sftp request" user = id
        return nothing
    end
    env = _session_env(server.env)
    home = _home_ns(env, id)
    if home === nothing
        @debug "air ssh session ended: user has no home namespace" user = id
        return nothing
    end
    _ls_set_blocking(session, false)
    if kind === :sftp
        ctx = TaskContext(id, home, server.dbroot, naught)
        _with_context(env, ctx, () -> _ssh_sftp!(env, server, session, chan, id))
    else
        out = _SshChannelIO(chan, false, session, tty, cols, rows)
        ctx = TaskContext(id, home, server.dbroot, naught, out)
        _with_context(env, ctx, () -> begin
            # The default UI is the session's UI: `(current-ui)` names its form
            # from the REPL after it is dismissed. It is a named instance, so a
            # reconnect attaches the same shell again instead of a fresh one. A
            # login must survive a UI that cannot open, so this is best effort.
            ui = nothing
            if tty && _ssh_login_ui_enabled(env, id)
                try
                    ui = _ssh_login_ui(env, id)
                catch e
                    e isa InterruptException && rethrow()
                    @debug "air ssh default ui failed to open" exception = (e, catch_backtrace())
                end
            end
            # Register the connection so `(ui-attach! .io.conn… widget)` has a
            # byte source to render on. Registration is best effort: a session
            # must log in even when its record cannot be written (a database
            # user, say), in which case `ui-show` still renders on the channel.
            conn = try
                _conn_open!(env, :ssh, id; out = out, tty = tty, cols = cols,
                            rows = rows)
            catch e
                @debug "air ssh connection registration failed" exception = (e, catch_backtrace())
                nothing
            end
            body = () -> begin
                try
                    if ui !== nothing && conn !== nothing
                        try
                            _conn_attach!(env, Scope(), conn, ui[1])
                        catch e
                            # A login must survive a UI that cannot start; the
                            # plain line editor is always available.
                            e isa InterruptException && rethrow()
                            @debug "air ssh default ui failed" exception = (e, catch_backtrace())
                        end
                    end
                    _ssh_repl!(env, server, session, chan, out; cols = cols,
                               rows = rows, tty = tty)
                finally
                    conn === nothing || _conn_close!(env, conn)
                end
            end
            Base.ScopedValues.with(body, _UI_CURRENT =>
                                   (ui === nothing ? nothing : ui[2]))
        end)
    end
    return nothing
end
