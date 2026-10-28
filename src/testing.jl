################################################################################
# testing.jl
#
# The air-level test verbs. `(test name body…)` runs a body and returns a summary
# of its `(check expr)` checks; `(check expr)` evaluates its expression and
# records whether it was truthy. The counts are task-local, so tests running on
# separate tasks do not interfere and a nested `test` reports only its own body.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# One running `(test …)` body: its pass count and the raw expressions (or error
# forms) of its failures, in the order they occurred.
mutable struct _TestFrame
    passes::Int
    failures::Vector{Form}
end

const _TEST_FRAMES_KEY = :airlang_test_frames

# The task's stack of open test frames, created on first use.
function _test_frames()
    return get!(() -> _TestFrame[], task_local_storage(), _TEST_FRAMES_KEY)
end

# `(check expr)` — evaluate `expr`; when it is truthy record a pass, otherwise
# record the expression as a failure. Outside a `(test …)` body it is simply a
# truth test, with nothing to record. Returns a boolean.
function _bi_check(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) == 2 ||
        throw(AirEvalError("check takes one expression, as in (check (== a b))"))
    expr = to_form(call.seq[2])
    ok = truthy(air_reduce(env, scope, expr))
    frames = _test_frames()
    if !isempty(frames)
        frame = frames[end]
        ok ? (frame.passes += 1) : push!(frame.failures, expr)
    end
    return Form(ok)
end
special!(:check, _bi_check)

# `(test name body…)` — evaluate the body forms with a fresh count. Each `check`
# in the body is recorded, and an uncaught error becomes a failure without aborting
# the caller. Returns the summary
# `(name=<name> pass=<n> fail=<n> failures=(<held-expr-or-error>…))`; the name is
# evaluated, so it may be a string, keyword, or any other value. A failure is
# held so that re-evaluating the summary does not run the failed expression.
function _bi_test(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) >= 2 ||
        throw(AirEvalError("test needs a name, as in (test \"name\" body…)"))
    name = air_reduce(env, scope, to_form(call.seq[2]))
    frame = _TestFrame(0, Form[])
    frames = _test_frames()
    push!(frames, frame)
    try
        for i in 3:length(call.seq)
            air_reduce(env, scope, to_form(call.seq[i]))
        end
    catch e
        _is_control_exception(e) && rethrow()   # never swallow Ctrl-C, a throw, or a recur
        push!(frame.failures, e isa AirThrown ? e.form : _error_form(e))
    finally
        pop!(frames)
    end
    # A failure is reported held, so the summary stays inert even if the caller
    # evaluates it again (the failed expression must not run a second time).
    failures = _ns_form(Form[_holdify(f) for f in frame.failures])
    # The summary is data, not a call: it has no head element, and `_Final` keeps
    # the reducer from touching it at all.
    return _Final(_ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":name") => name,
        Symbol(":pass") => Form(frame.passes),
        Symbol(":fail") => Form(length(frame.failures)),
        Symbol(":failures") => failures]))
end
special!(:test, _bi_test)
