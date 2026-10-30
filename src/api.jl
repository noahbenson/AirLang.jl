################################################################################
# api.jl
#
# The public surface: evaluating a form or a string, and the REPL.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    air_eval(env::Env, x::Form) -> Form
    air_eval(x::Form; env=default_env()) -> Form
    air_eval(s::AbstractString; env=default_env(), db=nothing) -> Form

Reduce `x` (or the single form in the string `s`) in `env` and return the result.
"""
function air_eval(env::Env, x::Form)
    env.steps[] = 0
    env.depth[] = 0
    return air_reduce(env, _base_scope(env), x)
end

air_eval(env::Env, s::AbstractString) = air_eval(env, read_air(s))

function air_eval(x::Form; env::Env = default_env())
    return air_eval(env, x)
end

function air_eval(s::AbstractString; env::Union{Nothing,Env} = nothing, db = nothing)
    e = env === nothing ? Env(db = db) : env
    return air_eval(e, read_air(s))
end

# A reader error that more input could fix: an unterminated form, string, raw
# string, or block comment. The REPL reads another line instead of reporting it.
_is_incomplete(e::AirParseError) = startswith(e.msg, "unterminated")

# Read every form in `src`, reporting a parse error rather than throwing.
function _read_complete(src::AbstractString)
    try
        return (:ok, read_all_air(src))
    catch e
        e isa AirParseError || rethrow()
        return (:error, e)
    end
end

# Append one complete input to the history file when one is configured. A
# multi-line input is flattened, since a history file holds one entry per line.
# A missing or unwritable file must not break the REPL.
function _record_history!(path::Union{Nothing,AbstractString}, src::AbstractString)
    path === nothing && return nothing
    s = strip(src)
    isempty(s) && return nothing
    try
        open(path, "a") do io
            println(io, replace(s, r"\s+" => " "))
        end
    catch
    end
    return nothing
end

"""
    air_repl(io_in=stdin, io_out=stdout; env=default_env(), pretty=true,
             width=80, history=nothing)

A read-eval-print loop over `io_in`/`io_out`. Input may span lines: while the
reader reports an unterminated form, string, or block comment, another line is
read under a `...> ` continuation prompt. Each complete input may hold several
forms; each result is printed as air source, broken across lines to fit `width`
when `pretty` is true. Parse and eval errors are printed and the loop continues.
An `(exit)` in an input ends the loop and the REPL returns its value (`naught`
when none was given), printing nothing for that form.

When `history` is a path, every complete input is appended to it as one line (a
multi-line input is flattened with spaces). The REPL has no line editor of its
own, so the file is meant for external tools such as `rlwrap`; the `air` command
passes `AIR_HISTORY` here when that variable is set.
"""
function air_repl(io_in::IO = stdin, io_out::IO = stdout; env::Env = default_env(),
                  pretty::Bool = true, width::Integer = 80,
                  history::Union{Nothing,AbstractString} = nothing)
    buf = String[]
    print(io_out, "air> ")
    for line in eachline(io_in)
        push!(buf, String(line))
        src = join(buf, "\n")
        status, val = _read_complete(src)
        if status === :error && _is_incomplete(val)
            print(io_out, "...> ")
            continue
        end
        empty!(buf)
        if status === :error
            println(io_out, "error: ", sprint(showerror, val))
        else
            _record_history!(history, src)
            for x in val
                try
                    r = air_eval(env, x)
                    println(io_out, pretty ? air_pretty_string(env, r; width = width) :
                                            air_string(env, r))
                catch e
                    # `(exit v)` ends the loop and returns `v` from the REPL.
                    e isa ExitSignal && return e.value
                    e isa AirError || rethrow()
                    println(io_out, "error: ", sprint(showerror, e))
                end
            end
        end
        print(io_out, "air> ")
    end
    # Input that ended at EOF still incomplete: report why it could not be read.
    if !isempty(buf)
        status, val = _read_complete(join(buf, "\n"))
        status === :error && println(io_out, "error: ", sprint(showerror, val))
    end
    return nothing
end
