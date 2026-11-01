################################################################################
# cancel.jl
#
# Cancellation: air's use of Air's `CancelToken`. An evaluation stops when the
# token installed on its task is cancelled; the reducer polls that token once
# every `_CANCEL_STEP_MASK + 1` steps, and the long air-level walks poll it once
# every `_CANCEL_WALK_MASK + 1` elements. Both intervals are a power of two so
# the check is a mask against the counter the loop already keeps, and a poll
# costs a few nanoseconds amortized, not a lock per step.
#
# A token belongs to the task that runs the evaluation, not to the language, and
# `task`, a write-mode `reserve`, a `sandbox`, a job worker, and an agent worker
# all start a fresh task. Cancellation therefore does not cross a task boundary:
# cancelling a task does not reach work it spawned. The pieces of the engine
# that create background work record the token they install — the job engine in
# its worker registry, a UI widget in its `_UiJob` — so a canceller holding that
# record can cancel the work directly.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# Reduction steps between cancellation checks; the first check is step 64.
const _CANCEL_STEP_MASK = 0x3f
# Elements between cancellation checks in a whole-tree walk; the first check is
# element 1024.
const _CANCEL_WALK_MASK = 0x3ff

# Throw if the calling task's token has been cancelled. This is the only place
# the reducer and the walks consult Air's cancellation machinery.
_cancel_point() = Air.checkcancel(Air.canceltoken())

# Called with the new value of `env.steps[]` after every reduction step.
@inline function _cancel_step!(n::Integer)
    (n & _CANCEL_STEP_MASK) == 0 && _cancel_point()
    return nothing
end

# A per-walk counter. A walk helper takes one as a trailing defaulted argument,
# so its recursive calls share the counter while every top-level call starts
# fresh.
mutable struct _CancelPoll
    n::Int
end
_CancelPoll() = _CancelPoll(0)

@inline function _cancel_walk!(p::_CancelPoll)
    ((p.n += 1) & _CANCEL_WALK_MASK) == 0 && _cancel_point()
    return nothing
end

"""
    _with_cancel_token(f; token = nothing) -> f()

Run `f()` with `token` installed as the calling task's cancellation token, and
restore the token the task had before. With no token, a fresh one is installed:
a token is one-way, so an evaluation that may be cancelled gets its own, and a
cancelled evaluation never poisons the task that ran it.
"""
function _with_cancel_token(f::Function;
                            token::Union{Nothing,CancelToken} = nothing)
    prev = Air.canceltoken()
    tok = token === nothing ? CancelToken() : token
    Air.setcancaltoken!(tok)
    try
        _cancel_point()
        return f()
    finally
        Air.setcancaltoken!(prev)
    end
end

# The error object a `Cancelled` becomes when it is delivered rather than thrown
# — a job's promise, for example. `showerror` gives the same text a REPL shows.
function _cancel_error_form(e::Cancelled)
    reason = getfield(e, :reason)
    reason === nothing &&
        return _error_object(Form(Symbol(":cancelled")))
    return _error_object(Form[Form(Symbol(":cancelled"))],
                         Pair{Symbol,FormValue}[
                             Symbol(":reason") => Form(string(reason))])
end
