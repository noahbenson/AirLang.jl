################################################################################
# builtins_stream.jl
#
# A stream is a reusable FIFO: `post` delivers an object to it and `fetch`
# receives one, in order, any number of times. AirDB's `StreamForm` persists the
# whole queue in the current namespace's database and stages every operation
# through the writer actor, so the ordinary transaction model applies unchanged.
#
# Each delivery is stored as an envelope `(value sender=:alice time=(time …))`;
# `fetch` returns the value, or the whole envelope with `meta=true`. The stream
# object's own ACL gates the two directions: `read` is receiving, `write` is
# delivering.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _SENDER_KEY = Symbol(":sender")
const _TIME_KEY = Symbol(":time")
const _TIMEOUT_KEY = Symbol(":timeout")

# ---- options -----------------------------------------------------------------

# The `timeout=` option in seconds, or `nothing` for "block forever".
function _stream_timeout(env::Env, scope::Scope, call::FormContainer)::Union{Nothing,Float64}
    haskey(call.map, _TIMEOUT_KEY) || return nothing
    l = _leafof(air_reduce(env, scope, to_form(call.map[_TIMEOUT_KEY])))
    (l isa Real && l >= 0) ||
        throw(AirEvalError("timeout must be a non-negative number of seconds"))
    return Float64(l)
end

# ---- envelopes ---------------------------------------------------------------

# The form a delivery stores: the object, the posting user, and the instant.
function _stream_envelope(value::Form, user::Symbol, secs::Real)
    return _ns_form(Form[value],
                    Pair{Symbol,Form}[_SENDER_KEY => Form(_user_key(user)),
                                      _TIME_KEY => _mk_time(secs)])
end

# Whether `x` is an envelope (as opposed to an item written into the stream by
# something other than `post`).
function _is_envelope(x::Form)
    x isa FormContainer || return false
    length(x.seq) == 1 || return false
    haskey(x.map, _SENDER_KEY) && haskey(x.map, _TIME_KEY) || return false
    return is_keyword(to_form(x.map[_SENDER_KEY])) &&
           _is_time_form(to_form(x.map[_TIME_KEY]))
end

_stream_object(x::Form) = _is_envelope(x) ? to_form(x.seq[1]) : x

# ---- error mapping -----------------------------------------------------------

# A `timeout=` expiration, distinct from a delivered value (`naught` is a
# perfectly good value to deliver).
struct _StreamTimeout end
const _STREAM_TIMEOUT = _StreamTimeout()

# Run a stream operation, mapping Air's and AirDB's exceptions to air errors so a
# `do` block can catch them. A `ReaderTimeout` is reported to the caller, which
# turns it into `naught`.
function _stream_op(f::Function)
    try
        return f()
    catch e
        e isa AirError && rethrow()
        e isa Air.ReaderTimeout && return _STREAM_TIMEOUT
        e isa Air.StreamClosed &&
            throw(AirStreamError(Symbol("stream-closed"), "the stream is closed"))
        e isa Air.StreamDeadlock &&
            throw(AirStreamError(Symbol("stream-deadlock"),
                  "a stream operation cannot block inside its own transaction"))
        e isa UncommittedStream &&
            throw(AirStreamError(Symbol("uncommitted-stream"),
                  "the stream belongs to a transaction that has not committed"))
        e isa AbortedStream &&
            throw(AirStreamError(Symbol("aborted-stream"),
                  "the stream belongs to a transaction that aborted"))
        rethrow()
    end
end

# The stream a verb's first argument names, or an error.
function _stream_arg(env::Env, scope::Scope, call::FormContainer, name::AbstractString)
    s = air_reduce(env, scope, to_form(call.seq[2]))
    s isa StreamForm || throw(AirEvalError("$name needs a stream, got $(air_string(s))"))
    return s
end

# ---- construction ------------------------------------------------------------

# `(stream maxsize=n)` — a new stream in the current namespace's database.
# `maxsize` bounds the queue; without it the stream is unbounded.
function _bi_stream(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "stream", (Symbol(":maxsize"),))
    length(call.seq) == 1 ||
        throw(AirEvalError("stream takes no positional arguments"))
    maxsize = nothing
    if haskey(call.map, Symbol(":maxsize"))
        l = _leafof(air_reduce(env, scope, to_form(call.map[Symbol(":maxsize")])))
        (l isa Integer && l >= 1) ||
            throw(AirEvalError("stream: maxsize must be a positive integer"))
        maxsize = _as_int(l, "stream: maxsize")
    end
    db = _persist_db(env)
    me = _current_user(env)
    _check_db_principal!(env, db, me)
    return _tx_boundary(env) do
        StreamForm(db; maxsize = maxsize,
                   metadata = _metadata_form(me; acl = _perms_acl(me)))
    end
end
special!(:stream, _bi_stream)

# ---- delivering and receiving ------------------------------------------------

# `(post s value timeout=n)` — append `value`, stamped with the posting user and
# instant. Needs `write` on the stream. Returns the envelope; `naught` when a
# `timeout=` expired on a full stream.
function _bi_post(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "post", (_TIMEOUT_KEY,))
    length(call.seq) == 3 ||
        throw(AirEvalError("post needs a stream and a value"))
    s = _stream_arg(env, scope, call, "post")
    _check!(env, s, :write)
    timeout = _stream_timeout(env, scope, call)
    v = air_reduce(env, scope, to_form(call.seq[3]))
    _check_storable!(env, s.db, v)
    env_ = _stream_envelope(v, _current_user(env), _now_secs())
    r = _stream_op(() -> (put!(s, env_; timeout = timeout); env_))
    return r === _STREAM_TIMEOUT ? naught : r
end
special!(:post, _bi_post)

# `(fetch s meta=true timeout=n)` — remove and return the oldest object (or, with
# `meta=true`, the whole envelope). Needs `read`; blocks until an item arrives,
# unless `timeout=` bounds the wait, in which case an expiry is `naught`.
function _bi_fetch(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "fetch", (Symbol(":meta"), _TIMEOUT_KEY))
    length(call.seq) == 2 || throw(AirEvalError("fetch takes one stream"))
    s = _stream_arg(env, scope, call, "fetch")
    _check!(env, s, :read)
    timeout = _stream_timeout(env, scope, call)
    meta = haskey(call.map, Symbol(":meta")) &&
           truthy(air_reduce(env, scope, to_form(call.map[Symbol(":meta")])))
    r = _stream_op(() -> take(s; timeout = timeout))
    r === _STREAM_TIMEOUT && return naught
    return meta ? r : _stream_object(r)
end
special!(:fetch, _bi_fetch)

# ---- inspection --------------------------------------------------------------

builtin!(Symbol("stream?"),
         (env, scope, args) -> Form(_arg(args, 1, "stream?") isa StreamForm))

# `(open? s)` — whether the stream still accepts deliveries.
function _stream_open(env::Env, s::StreamForm)
    _check!(env, s, :read)
    return _stream_op(() -> isopen(s))
end
builtin!(Symbol("open?"), (env, scope, args) -> begin
    s = _arg(args, 1, "open?")
    s isa StreamForm || throw(AirEvalError("open? needs a stream"))
    Form(_stream_open(env, s))
end)

# The queued item count, used by `count`.
function _stream_count(env::Env, s::StreamForm)
    _check!(env, s, :read)
    return _stream_op(() -> length(s))
end

# Whether a `fetch` would return immediately, used by `ready?`.
function _stream_ready(env::Env, s::StreamForm)
    _check!(env, s, :read)
    return _stream_op(() -> isready(s)) === true
end

# `(close! s)` — stop the stream. A later `post` is `(error :stream-closed)`; a
# `fetch` drains what remains and then raises it too. Needs `write`.
function _bi_close(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "close!", ())
    length(call.seq) == 2 || throw(AirEvalError("close! takes one stream"))
    s = _stream_arg(env, scope, call, "close!")
    _check!(env, s, :write)
    return _stream_op(() -> (close(s); s))
end
special!(Symbol("close!"), _bi_close)
