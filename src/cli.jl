################################################################################
# cli.jl
#
# The `air` command-line entry point.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# The print width for the REPL: `COLUMNS` when the terminal reports one, else 80.
function _terminal_width()::Int
    s = get(ENV, "COLUMNS", "")
    isempty(s) && return 80
    n = tryparse(Int, s)
    (n === nothing || n < 20) && return 80
    return n
end

"""
    air_main(args::Vector{String}) -> Int

Run the air command line: no arguments starts a REPL, `-e code` evaluates `code`
and prints the result, and a file path evaluates every form in the file.
`--serve` keeps the process running once the files and `-e` chunks have been
evaluated, which is how a container stays up for its `ssh-server` and other
process resources. Returns a process exit code.
"""
function air_main(args::Vector{String})
    env = default_env()
    if isempty(args)
        _resume_jobs_quietly!(env)
        air_repl(; env = env, history = get(ENV, "AIR_HISTORY", nothing),
                 width = _terminal_width())
        return 0
    end
    serve = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--serve"
            serve = true
        elseif a == "-e"
            i += 1
            i > length(args) && (println(stderr, "air: -e needs an argument"); return 2)
            try
                println(air_string(_load_air_source(env, args[i], "<command line>")))
            catch e
                e isa AirError || rethrow()
                println(stderr, "error: ", sprint(showerror, e))
                return 1
            end
        elseif a == "-h" || a == "--help"
            println("usage: air [-e code] [file.air]… [--serve]")
            println("       air                 # read-eval-print loop; " *
                    "AIR_HISTORY names a history file")
            println("       air --serve file.air  # run the files, then stay up " *
                    "for ssh-server and other process resources")
            return 0
        else
            try
                _load_air_paths(env, [a])
            catch e
                e isa AirError || rethrow()
                println(stderr, "error: ", sprint(showerror, e))
                return 1
            end
        end
        i += 1
    end
    if serve
        _resume_jobs_quietly!(env)
        return _serve_forever()
    end
    return 0
end

# Restore SIGINT's default disposition while serving, so Ctrl-C ends the
# process at once: Julia's own handler would instead raise an
# `InterruptException` in whichever task the signal reaches — fatal when that
# task has no handler, as a server's tasks need not. Nothing needs flushing: air
# commits each transaction before it returns. SIGTERM is separate — the Julia
# runtime consumes it in a signal thread, so its disposition does not matter and
# it prints a shutdown backtrace; the container therefore stops with SIGINT
# (`stop_signal` in docker-compose.yml). Windows has no `signal`, so there the
# wait is interrupted by an `InterruptException`.
function _serve_forever()
    if Sys.iswindows()
        Base.exit_on_sigint(false)
        try
            _serve_loop()
        catch e
            e isa InterruptException || rethrow()
        end
        return 0
    end
    ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), 2, Ptr{Cvoid}(0))  # SIGINT → SIG_DFL
    _serve_loop()
    return 0
end

function _serve_loop()
    # A redirected stdout and stderr are buffered, so a startup file's output and
    # the server's debug diagnostics can sit unseen in `docker compose logs` for
    # a long time; flush once a second so a running server's log is readable.
    println(stderr, "air: serving; press Ctrl-C (SIGINT) to stop")
    while true
        flush(stdout)
        flush(stderr)
        sleep(1)
    end
end
