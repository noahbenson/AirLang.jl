################################################################################
# events.jl
#
# Scheduled events and scheduled transactions:
#
#   (do-at <time> body…)      run body at a wall-clock time
#   (do-in <interval> body…)  run body after a delay (repeat=true re-arms)
#   (tx-at <time> body…)      the same, but body is one transaction
#   (tx-in <interval> body…)  the same, but body is one transaction
#
# Each call registers a durable job (see jobs.jl) in the creating user's
# `$.config.events` and returns the promise the job fills. The body is rebuilt
# into a real `(do …)` — or `(tx …)` — container from the positional forms and
# the block's `let=`/`catch=` entries, then captured like a task's body, so the
# ordinary block grammar applies when the event fires.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _JOB_NAME_KEY = Symbol(":name")
const _JOB_BINDINGS_KEY = Symbol(":bindings")
const _JOB_REPEAT_KEY = Symbol(":repeat")

# The scheduling heads, with whether each takes a time or a delay and whether
# its body is a transaction.
const _JOB_SCHED_HEADS = Dict{Symbol,NamedTuple{(:delay, :tx),Tuple{Bool,Bool}}}(
    Symbol("do-at") => (delay = false, tx = false),
    Symbol("do-in") => (delay = true, tx = false),
    Symbol("tx-at") => (delay = false, tx = true),
    Symbol("tx-in") => (delay = true, tx = true))

# A time argument: a time value or a number of UTC epoch seconds.
function _job_time_arg(env::Env, scope::Scope, x::Form)
    v = air_reduce(env, scope, to_form(x))
    _is_time_form(v) && return _time_secs(v)
    l = _leafof(v)
    l isa Real && return Float64(l)
    throw(AirEvalError(
        "a scheduled time must be a time or epoch seconds, got $(air_string(v))"))
end

# An interval argument: a non-negative number of seconds.
function _job_interval_arg(env::Env, scope::Scope, x::Form)
    v = air_reduce(env, scope, to_form(x))
    l = _leafof(v)
    l isa Real || throw(AirEvalError(
        "a scheduled interval must be a number of seconds, got $(air_string(v))"))
    s = Float64(l)
    s >= 0 || throw(AirEvalError("a scheduled interval cannot be negative"))
    return s
end

# The event body: every positional form after the time plus the block's
# `let=`/`catch=` entries, rebuilt as a `(do …)` or `(tx …)` container. The
# rebuilt container — not the call — is captured, so `name=`, `bindings=`, and
# `repeat=` never enter the stored body.
function _job_block_body(call::FormContainer, head::Symbol)
    elems = Form[to_form(v) for v in _sx(call.seq, 3:length(call.seq))]
    isempty(elems) && throw(AirEvalError(
        "$(head_symbol(call)): a scheduled body needs at least one form"))
    map = Pair{Symbol,Form}[]
    for k in (_LET_KEY, _CATCH_KEY)
        haskey(call.map, k) && push!(map, k => to_form(call.map[k]))
    end
    return _ns_form(vcat(Form[Form(head)], elems), map)
end

# One of the four scheduling special forms.
function _job_schedule(env::Env, scope::Scope, call::FormContainer, head::Symbol)
    spec = _JOB_SCHED_HEADS[head]
    if !spec.delay && haskey(call.map, _JOB_REPEAT_KEY)
        throw(AirEvalError(
            "$(head): repeat= is not supported; use do-in or tx-in to repeat"))
    end
    allowed = spec.delay ?
        (_JOB_NAME_KEY, _JOB_BINDINGS_KEY, _JOB_REPEAT_KEY, _LET_KEY, _CATCH_KEY) :
        (_JOB_NAME_KEY, _JOB_BINDINGS_KEY, _LET_KEY, _CATCH_KEY)
    _check_options(call, String(head), allowed)
    length(call.seq) >= 3 || throw(AirEvalError(
        "$(head): expected a time or interval and a body"))
    repeat = false
    interval = nothing
    at = if spec.delay
        when = _job_interval_arg(env, scope, to_form(call.seq[2]))
        if haskey(call.map, _JOB_REPEAT_KEY) &&
           truthy(air_reduce(env, scope, to_form(call.map[_JOB_REPEAT_KEY])))
            when > 0 || throw(AirEvalError(
                "$(head): repeat=true needs a positive interval"))
            repeat = true
            interval = when
        end
        _now_secs() + when
    else
        _job_time_arg(env, scope, to_form(call.seq[2]))
    end
    name = haskey(call.map, _JOB_NAME_KEY) ?
        _job_name_arg(env, scope, to_form(call.map[_JOB_NAME_KEY]), String(head)) :
        nothing
    bindings = haskey(call.map, _JOB_BINDINGS_KEY) ?
        _job_bindings_form(env, scope,
                           air_reduce(env, scope,
                                      to_form(call.map[_JOB_BINDINGS_KEY])), false) :
        _ns_empty_value()
    body = _job_block_body(call, spec.tx ? Symbol("tx") : Symbol("do"))
    made = _job_create!(env, scope, :event; body = Form[body], bindings = bindings,
                        name = name, tx = spec.tx, repeat = repeat,
                        at = at, interval = interval)
    return made.promise
end

for head in keys(_JOB_SCHED_HEADS)
    special!(head, (env, scope, call) -> _job_schedule(env, scope, call, head))
end
