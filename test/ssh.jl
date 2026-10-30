# SSH: an air-started server, authorized-key login, the remote REPL, and SFTP,
# exercised end to end against the real OpenSSH client.
import OpenSSH_jll

# The client binaries. `OpenSSH_jll.<tool>()` resolves the artifact and returns
# a command carrying the environment the binary needs (its library search path);
# resolving lazily means a missing artifact skips the set instead of breaking the
# include.
const _SSH_CMDS = Dict{Symbol,Cmd}()

_ssh_binary(name::Symbol) =
    get!(() -> getproperty(OpenSSH_jll, name)(), _SSH_CMDS, name)

# Whether the client binaries can actually run here; when they cannot (an
# unsupported platform, a missing artifact) the whole set is skipped with a
# warning rather than failing the suite.
function _ssh_client_works()
    try
        buf = IOBuffer()
        p = run(pipeline(ignorestatus(`$(_ssh_binary(:ssh)) -V`);
                         stdout = buf, stderr = buf))
        return Base.process_exited(p) && p.exitcode == 0
    catch
        return false
    end
end

# Run a client command with an input script and bounded wait; a hung client
# fails its own test instead of the suite.
function _ssh_run(cmd; input::Union{Nothing,String} = nothing, timeout::Real = 60)
    out = IOBuffer()
    err = IOBuffer()
    p = input === nothing ?
        run(pipeline(ignorestatus(cmd), stdout = out, stderr = err); wait = false) :
        run(pipeline(ignorestatus(cmd), stdin = IOBuffer(input), stdout = out,
                     stderr = err); wait = false)
    t0 = time()
    while !Base.process_exited(p) && time() - t0 < timeout
        sleep(0.01)
    end
    if !Base.process_exited(p)
        kill(p)
        wait(p)
        return ("", "the ssh client timed out after $(timeout)s\n" *
                   String(take!(err)), -1)
    end
    return (String(take!(out)), String(take!(err)), p.exitcode)
end

# The shared client options: no user config, no known-hosts state, no agent, and
# key-only authentication so a refusal is immediate.
_SSH_BASE_OPTS = ["-F", "/dev/null", "-o", "BatchMode=yes",
                  "-o", "StrictHostKeyChecking=no",
                  "-o", "UserKnownHostsFile=/dev/null",
                  "-o", "IdentitiesOnly=yes",
                  "-o", "PreferredAuthentications=publickey",
                  "-o", "NumberOfPasswordPrompts=0"]

# A command for one of the artifact's tools, carrying the environment the JLL
# gives it (the artifact's library search path). `scp` and `sftp` run `ssh` by
# its compiled-in path rather than searching PATH, so they are always given `-S`.
_ssh_exe(name::Symbol) = _ssh_binary(name).exec[1]

_ssh_cmd(name::Symbol, args::Vector{String}) =
    setenv(Cmd(vcat([_ssh_exe(name)], args)), _ssh_binary(name).env)

_ssh_client_cmd(port::Integer, key::AbstractString, user::AbstractString;
                tty::Bool = false) =
    _ssh_cmd(:ssh, ["-p", string(port), "-i", key, tty ? "-tt" : "-T",
                    _SSH_BASE_OPTS..., user * "@127.0.0.1"])

_ssh_scp_cmd(port::Integer, key::AbstractString, src::AbstractString,
             dst::AbstractString) =
    _ssh_cmd(:scp, ["-q", "-S", _ssh_exe(:ssh), "-P", string(port), "-i", key,
                    _SSH_BASE_OPTS..., src, dst])

_ssh_sftp_cmd(port::Integer, key::AbstractString, batchfile::AbstractString,
              user::AbstractString) =
    _ssh_cmd(:sftp, ["-q", "-S", _ssh_exe(:ssh), "-b", batchfile,
                     "-P", string(port), "-i", key, _SSH_BASE_OPTS...,
                     user * "@127.0.0.1"])

@testset "ssh" begin
    if !_ssh_client_works()
        @warn "the OpenSSH client from OpenSSH_jll does not run here; skipping the ssh tests"
    else
        env = default_env()
        ev(s) = air_string(air_eval(env, read_air(s)))
        dir = mktempdir()

        # ---- keys and users -------------------------------------------------
        # Five ed25519/rsa key pairs: alice (the namespace config), air:bob (the
        # `ssh`-val config), game:kid (an admin's constituent), carl (no config
        # at all), and air (the root-absolute transfer tests).
        function mkkey(name::AbstractString; rsa::Bool = false)
            path = joinpath(dir, name)
            args = rsa ? `$(_ssh_binary(:ssh_keygen)) -q -t rsa -b 2048 -N "" -f $path` :
                         `$(_ssh_binary(:ssh_keygen)) -q -t ed25519 -N "" -f $path`
            run(pipeline(ignorestatus(args), stdout = devnull, stderr = devnull))
            return (path, strip(read(path * ".pub", String)))
        end
        alicekey, alicepub = mkkey("alice")
        bobkey, bobpub = mkkey("bob"; rsa = true)
        kidkey, kidpub = mkkey("kid")
        carlkey, carlpub = mkkey("carl")
        airkey, airpub = mkkey("air")
        @test ev("(create-user :alice)") == ":alice"
        @test ev("(create-constituent :bob)") == ":air:bob"
        @test ev("(create-user :game)") == ":game"
        @test ev("(set-admin :game true)") == ":game"
        @test ev("(as-user :game (create-constituent :kid))") == ":game:kid"
        @test ev("(create-user :carl)") == ":carl"

        # The namespace-shaped config, the `ssh`-val-shaped config, and air's own.
        @test ev("(as-user :alice (namespace \$.config.ssh " *
                 "(val authorized-keys (\"$alicepub\"))))") == "naught"
        @test ev("(as-user :air:bob (namespace \$.config " *
                 "(val ssh (authorized-keys=(\"$bobpub\")))))") == "naught"
        @test ev("(as-user :game:kid (namespace \$.config.ssh " *
                 "(val authorized-keys (\"$kidpub\"))))") == "naught"
        @test ev("(namespace \$.config.ssh (val authorized-keys (\"$airpub\")))") ==
              "naught"

        # A malformed entry is a clear error, not a silent refusal.
        @test ev("(as-user :carl (namespace \$.config.ssh " *
                 "(val authorized-keys ((\"nonsense\")))))") == "naught"

        servers = Symbol[]
        try
            # ---- starting a server -----------------------------------------
            @test ev("(ssh-server :t port=0)") == ":t"
            push!(servers, :t)
            port = parse(Int, ev("(get (ssh-servers) :t :port)"))
            @test 0 < port <= 65535
            @test ev("(get (ssh-servers) :t :owner)") == ":air"
            @test ev("(get (ssh-servers) :t :bind)") == "\"127.0.0.1\""
            @test ev("(get (ssh-servers) :t :host-key-type)") == "\"ed25519\""

            # ---- the REPL ---------------------------------------------------
            # A plain (no pty) session runs the plain line reader.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice");
                                    input = "(println (+ 1 2))\n(exit)\n")
            @test rc == 0
            @test occursin("3", out)

            # A pty session gets the line editor and its prompt.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice";
                                                    tty = true);
                                    input = "(+ 20 22)\n(exit)\n")
            @test rc == 0
            @test occursin("air> ", out)
            @test occursin("42", out)

            # Multi-line input continues under the continuation prompt.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice";
                                                    tty = true);
                                    input = "(let (x=1)\n (+ x 2))\n(exit)\n")
            @test rc == 0
            @test occursin("...> ", out)
            @test occursin("3", out)

            # A failing form prints its error and the session survives.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice");
                                    input = "(raise :oops)\n(+ 1 2)\n(exit)\n")
            @test rc == 0
            @test occursin("(error :oops)", out)
            @test occursin("3", out)

            # Ctrl-C evaluates `(raise :ctrl-c)`, and the session survives it.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice";
                                                    tty = true);
                                    input = "(+ 1 2)\n\003(+ 3 4)\n(exit)\n")
            @test rc == 0
            @test occursin("(error :ctrl-c)", out)
            @test occursin("7", out)

            # A UI runs in the alternate screen: Space toggles the focused
            # checkbox, Tab focuses the Done button, and Enter clicks it, which
            # dismisses and returns to the prompt with the value kept.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice";
                                                    tty = true);
                input = "(ui-open :uiform (ui column " *
                        "(ui checkbox id=:on initval=false label=\"On\") " *
                        "(ui button label=\"Done\" " *
                        "on-click=(() -> (ui-dismiss! :uiform)))))\n" *
                        "(ui-show :uiform)\n" *
                        " \t\r" *
                        "(ui-values :uiform)\n(ui-close! :uiform)\n(exit)\n")
            @test rc == 0
            @test occursin("\e[?1049h", out)      # entered the alternate screen
            @test occursin("\e[?1049l", out)      # and restored it
            @test occursin("(on=true)", out)
            @test occursin("air> ", out)          # back at the prompt

            # Ctrl-D on an empty line ends the session cleanly.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice";
                                                    tty = true);
                                    input = "(+ 1 2)\n\004")
            @test rc == 0
            @test occursin("3", out)

            # `(exit v)` ends the session without printing the value, and without
            # an error.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice";
                                                    tty = true);
                                    input = "(println :before)\n(exit 42)\n")
            @test rc == 0
            @test occursin(":before", out)
            # Nothing follows the echoed exit line: no value, no error.
            @test endswith(strip(out), "(exit 42)")

            # ---- identity ---------------------------------------------------
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice");
                                    input = "(current-user)\n(exit)\n")
            @test rc == 0
            @test occursin(":alice", out)
            # `$` is that user's home: a def typed at the prompt lands there.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice");
                                    input = "(def (twice ?x) (x * 2))\n(exit)\n")
            @test rc == 0
            @test ev("(.sys.user.alice.home.twice 21)") == "42"
            # It landed in alice's home, not in the server's own namespace.
            @test ev("(do (.main.twice 1) (except ?e :err))") == ":err"
            # A session job writes to its channel, not to the server's console.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice");
                                    input = "(await (task (println :from-task)))\n(exit)\n")
            @test rc == 0
            @test occursin(":from-task", out)
            # The `ssh`-val config shape logs in too, and the dotted login name
            # maps back to the colon-separated user id.
            out, err, rc = _ssh_run(_ssh_client_cmd(port, bobkey, "air.bob");
                                    input = "(current-user)\n(exit)\n")
            @test rc == 0
            @test occursin(":air:bob", out)

            # ---- refusals ----------------------------------------------------
            # A wrong key, a user with no keys, and a user with an unparsable
            # key all fail identically.
            let (out, err, rc) = _ssh_run(_ssh_client_cmd(port, carlkey, "alice"))
                @test rc != 0
                @test occursin("Permission denied", err)
            end
            let (out, err, rc) = _ssh_run(_ssh_client_cmd(port, carlkey, "carl"))
                @test rc != 0
                @test occursin("Permission denied", err)
            end
            let (out, err, rc) = _ssh_run(_ssh_client_cmd(port, alicekey, "nobody"))
                @test rc != 0
            end
            # Only an admin or air may start a server.
            @test ev("(do (as-user :alice (ssh-server :nope port=0)) " *
                     "(except ?e :err))") == ":err"
            @test ev("(do (as-user :alice (ssh-host-key :t)) (except ?e :err))") == ":err"

            # ---- transfers ---------------------------------------------------
            srcfile = joinpath(dir, "blob.bin")
            blob = rand(UInt8, 1024 * 1024)
            write(srcfile, blob)
            out, err, rc = _ssh_run(_ssh_scp_cmd(port, alicekey, srcfile,
                                                "alice@127.0.0.1:data.weights"))
            @test rc == 0
            @test ev("(bytes-length .sys.user.alice.home.data.weights)") == "1048576"
            @test ev("(bytes? .sys.user.alice.home.data.weights)") == "true"
            backfile = joinpath(dir, "back.bin")
            out, err, rc = _ssh_run(_ssh_scp_cmd(port, alicekey,
                                                "alice@127.0.0.1:data.weights", backfile))
            @test rc == 0
            @test read(backfile) == blob
            # A dotted destination creates its parent namespaces.
            out, err, rc = _ssh_run(_ssh_scp_cmd(port, alicekey, srcfile,
                                                "alice@127.0.0.1:nested.path.file"))
            @test rc == 0
            @test ev("(bytes-length .sys.user.alice.home.nested.path.file)") == "1048576"
            @test startswith(ev("(get . :sys :user :alice :home :nested :path :file)"),
                             "#<bytes ")
            # A `/`-rooted and a `.`-rooted destination are the same absolute
            # path; as air they address `.main`.
            @test ev("(namespace .main (val notbytes (1 2 3)))") == "naught"
            out, err, rc = _ssh_run(_ssh_scp_cmd(port, airkey, srcfile,
                                                "air@127.0.0.1:.main.transfer.bin"))
            @test rc == 0
            @test ev("(bytes-length .main.transfer.bin)") == "1048576"
            out, err, rc = _ssh_run(_ssh_scp_cmd(port, airkey, srcfile,
                                                "air@127.0.0.1:/main.transfer2.bin"))
            @test rc == 0
            @test ev("(bytes-length .main.transfer2.bin)") == "1048576"
            # A destination holding anything but `bytes` is refused, and the
            # value is untouched.
            out, err, rc = _ssh_run(_ssh_scp_cmd(port, airkey, srcfile,
                                                "air@127.0.0.1:.main.notbytes"))
            @test rc != 0
            @test ev(".main.notbytes") == "(1 2 3)"
            # A missing file is an error for the client, not a crash.
            out, err, rc = _ssh_run(_ssh_scp_cmd(port, alicekey,
                                                "alice@127.0.0.1:no.such.file",
                                                joinpath(dir, "missing.bin")))
            @test rc != 0
            @test !isfile(joinpath(dir, "missing.bin"))

            # ---- sftp batch ---------------------------------------------------
            batch = joinpath(dir, "batch.txt")
            got = joinpath(dir, "sftp-back.bin")
            # `batchdir/blob.bin` is the `blob` namespace inside `batchdir` (dots
            # separate path segments), so finishing the cleanup means removing
            # that namespace too — `rmdir` is never recursive.
            write(batch, """
                mkdir batchdir
                put $srcfile batchdir/blob.bin
                get batchdir/blob.bin $got
                ls -l batchdir
                rm batchdir/blob.bin
                rmdir batchdir/blob
                rmdir batchdir
                """)
            out, err, rc = _ssh_run(_ssh_sftp_cmd(port, alicekey, batch, "alice"))
            @test rc == 0
            @test read(got) == blob
            @test occursin("blob.bin", out)
            home = AirLang._user_home_path(env, :alice)
            @test AirLang._ns_lookup(env, vcat(home, [:batchdir])) === nothing

            # ---- lifecycle ----------------------------------------------------
            hostkey = ev("(ssh-host-key :t)")
            @test startswith(hostkey, "\"ssh-ed25519 ")
            @test occursin("air-ssh-t", hostkey)
            @test startswith(ev("(ssh-host-key :t private=true)"),
                             "\"-----BEGIN OPENSSH PRIVATE KEY-----")
            # A second server with a running name is refused.
            @test ev("(do (ssh-server :t port=0) (except ?e :err))") == ":err"
            # Closing removes it from the listing but keeps the host key, so
            # reopening the name is the same host.
            @test ev("(ssh-close! :t)") == ":t"
            deleteat!(servers, findfirst(==(:t), servers))
            @test ev("(do (get (ssh-servers) :t) (except ?e :err))") == ":err"
            @test ev("(do (ssh-close! :t) (except ?e :err))") == ":err"
            @test ev("(ssh-host-key :t)") == hostkey
            @test ev("(ssh-server :t port=0)") == ":t"
            push!(servers, :t)
            @test ev("(ssh-host-key :t)") == hostkey
            port = parse(Int, ev("(get (ssh-servers) :t :port)"))
            out, err, rc = _ssh_run(_ssh_client_cmd(port, alicekey, "alice");
                                    input = "(current-user)\n(exit)\n")
            @test rc == 0
            @test occursin(":alice", out)
            # The defs a session wrote survive a close and a reopen.
            @test ev("(.sys.user.alice.home.twice 5)") == "10"

            # ---- an admin's server admits only its own subtree ------------------
            @test ev("(as-user :game (ssh-server :adm port=0))") == ":adm"
            push!(servers, :adm)
            admport = parse(Int, ev("(get (ssh-servers) :adm :port)"))
            out, err, rc = _ssh_run(_ssh_client_cmd(admport, kidkey, "game.kid");
                                    input = "(current-user)\n(exit)\n")
            @test rc == 0
            @test occursin(":game:kid", out)
            # Outside the admin's subtree — even air — is not admitted.
            let (out, err, rc) = _ssh_run(_ssh_client_cmd(admport, alicekey, "alice"))
                @test rc != 0
                @test occursin("Permission denied", err)
            end
            let (out, err, rc) = _ssh_run(_ssh_client_cmd(admport, airkey, "air"))
                @test rc != 0
            end
            # The owner sees its own server in the listing; another admin sees
            # only its own.
            @test ev("(as-user :game (get (ssh-servers) :adm :owner))") == ":game"
            @test ev("(do (as-user :game (get (ssh-servers) :t)) " *
                     "(except ?e :err))") == ":err"
        finally
            for s in servers
                try
                    air_eval(env, read_air("(ssh-close! :$s)"))
                catch
                end
            end
        end
    end
end
