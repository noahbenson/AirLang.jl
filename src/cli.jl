################################################################################
# cli.jl
#
# The `air` command-line entry point.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    air_main(args::Vector{String}) -> Int

Run the air command line: no arguments starts a REPL, `-e code` evaluates `code`
and prints the result, and a file path evaluates every form in the file. Returns
a process exit code.
"""
function air_main(args::Vector{String})
    env = default_env()
    if isempty(args)
        air_repl(; history = get(ENV, "AIR_HISTORY", nothing))
        return 0
    end
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "-e"
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
            println("usage: air [-e code] [file.air]")
            println("       air                 # read-eval-print loop; " *
                    "AIR_HISTORY names a history file")
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
    return 0
end
