################################################################################
# builtins_iter.jl
#
# Iteration and tail recursion: `loop`/`recur` and `while`. A `(recur …)` is a
# tail call — it unwinds to its enclosing `loop` (via an exception) and re-enters
# with fresh bindings, so it does not grow the stack.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

struct _Recur <: Exception
    args::Vector{Form}
end

# `(recur args…)` — re-enter the enclosing `loop` with new bindings.
function _bi_recur(env::Env, scope::Scope, call::FormContainer)
    args = Form[air_reduce(env, scope, to_form(v))
               for v in _sx(call.seq, 2:length(call.seq))]
    throw(_Recur(args))
end
special!(:recur, _bi_recur)

# `(loop (a 0 b 1 …) body…)` — bind the name/value pairs, evaluate the body, and
# if it reaches a `(recur …)`, rebind and re-enter.
function _bi_loop(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("loop needs a binding form"))
    bindings = to_form(call.seq[2])
    bindings isa FormContainer || throw(AirEvalError("loop needs a binding form"))
    bs = _sx(bindings.seq, 1:length(bindings.seq))
    length(bs) % 2 == 0 || throw(AirEvalError("loop bindings must be name/value pairs"))
    names = Symbol[]
    vals = Form[]
    for i in 1:2:length(bs)
        n = _leafof(to_form(bs[i]))
        n isa Symbol || throw(AirEvalError("loop binding names must be symbols"))
        push!(names, n)
        push!(vals, air_reduce(env, scope, to_form(bs[i + 1])))
    end
    body = _sx(call.seq, 3:length(call.seq))
    s = scope_extend(scope, [names[i] => vals[i] for i in eachindex(names)])
    while true
        try
            result = naught
            for b in body
                result = air_reduce(env, s, to_form(b))
            end
            return result
        catch e
            e isa _Recur || rethrow()
            length(e.args) == length(names) ||
                throw(AirEvalError("recur: expected $(length(names)) argument(s)"))
            s = scope_extend(scope, [names[i] => e.args[i] for i in eachindex(names)])
        end
    end
end
special!(:loop, _bi_loop)

# `(while cond body…)` — evaluate the body while `cond` is truthy.
function _bi_while(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 || throw(AirEvalError("while needs a condition"))
    result = naught
    while truthy(air_reduce(env, scope, to_form(call.seq[2])))
        for a in _sx(call.seq, 3:length(call.seq))
            result = air_reduce(env, scope, to_form(a))
        end
    end
    return result
end
special!(:while, _bi_while)
