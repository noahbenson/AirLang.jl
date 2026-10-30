################################################################################
# errors.jl
#
# The error types air raises. All subtype `AirError` so the REPL can catch them
# as a family and print a message instead of a stack trace.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    AirError

The abstract supertype of the errors air raises: [`AirParseError`](@ref),
[`AirEvalError`](@ref), and [`AirDefError`](@ref).
"""
abstract type AirError <: Exception end

# ---- error objects -----------------------------------------------------------

# The head of an error object: `(error :io data…)`. The form is a constant — the
# reducer returns it unchanged — so it can be matched, stored, and compared like
# any other data. The first element after the head is conventionally the type but
# air never inspects it.
const ERROR_HEAD = :error

# The reserved symbol that, as the final value of an `except` body, resumes the
# original error.
const RERAISE = :reraise

function _is_error_object(x)
    x isa FormContainer && !isempty(x.seq) || return false
    return _symbolof(to_form(x.seq[1])) === ERROR_HEAD
end

_is_reraise(x) = x isa FormScalar && value(x) === RERAISE

# A map entry of an error object, or `nothing`.
function _error_field(x::Form, key::Symbol)
    (x isa FormContainer && haskey(x, key)) || return nothing
    return to_form(x[key])
end


"""
    AirParseError(msg, pos)

A syntax error while reading air source, at character position `pos`.
"""
struct AirParseError <: AirError
    msg::String
    pos::Int
end

"""
    AirEvalError(msg, frames = Form[])

A failure while reducing a form. `frames` holds source frames
`(name=… line=… col=… text=…)`, innermost first, when a position is known.
"""
struct AirEvalError <: AirError
    msg::String
    frames::Vector{Form}
end
AirEvalError(msg::AbstractString) = AirEvalError(String(msg), Form[])

"""
    AirDefError(msg)

A failure while registering a global pattern with `def`.
"""
struct AirDefError <: AirError
    msg::String
end

"""
    AirPermissionDenied(perm, target)

An access check failed: the current user lacks `perm` (`:read`, `:write`,
`:exec`, or `:assume`) on `target`. A `do` block sees it as the air error
`(:permission-denied :perm target)`.
"""
struct AirPermissionDenied <: AirError
    perm::Symbol
    target::Form
end

Base.showerror(io::IO, e::AirParseError) =
    print(io, "air parse error at position ", e.pos, ": ", e.msg)
Base.showerror(io::IO, e::AirDefError) = print(io, "air def error: ", e.msg)
Base.showerror(io::IO, e::AirPermissionDenied) =
    print(io, "air permission denied: ", e.perm, " ", air_string(e.target))

"""
    AirProxyUnresolved(path)

An imported proxy entry names a source namespace that no longer exists. A `do`
block sees it as the air error `(:proxy-unresolved <path>)`.
"""
struct AirProxyUnresolved <: AirError
    path::Vector{Symbol}
end

Base.showerror(io::IO, e::AirProxyUnresolved) =
    print(io, "air proxy unresolved: ", air_string(_ns_path_form(e.path)))

"""
    AirUnstorable(target)

A form cannot be stored in the database it was being written to: it holds a
volatile belonging to another database (or to the system namespaces). A `do`
block sees it as the air error `(:un-storable target)`.
"""
struct AirUnstorable <: AirError
    target::Form
end

Base.showerror(io::IO, e::AirUnstorable) =
    print(io, "cannot store this form in the database: ", air_string(e.target))

"""
    AirStreamError(tag, msg, data = Form[])

A stream operation failed: the stream is closed, the operation would deadlock
inside its own transaction, or the stream belongs to an uncommitted or aborted
transaction. A `do` block sees it as the air error `(error :tag data…)`.
"""
struct AirStreamError <: AirError
    tag::Symbol
    msg::String
    data::Vector{Form}
end
AirStreamError(tag::Symbol, msg::AbstractString) =
    AirStreamError(tag, String(msg), Form[])

Base.showerror(io::IO, e::AirStreamError) =
    print(io, "air stream error: ", e.msg)

"""
    AirThrown(form)

An air error thrown by `(raise …)`. It carries the error object `form` — a form
headed by `error`, e.g. `(error :io "Connection lost")` — whose content (the
object without its head) the `except` patterns of a `do` block are matched
against.
"""
struct AirThrown <: AirError
    form::Form
    frames::Vector{Form}
end
AirThrown(form::Form) = AirThrown(form, Form[])

"""
    AirTraced(err, frame)

An air error raised from a form whose source is known but whose own type carries
no frames. `do` still sees the underlying error's form; `showerror` adds the
position. The frame is `(name=… line=… col=… text=…)`.
"""
struct AirTraced <: AirError
    err::AirError
    frame::Form
end

# ---- source frames -----------------------------------------------------------

# The scalar value of a frame's field, or `nothing`.
function _frame_field(frame::Form, key::Symbol)
    frame isa FormContainer || return nothing
    haskey(frame, key) || return nothing
    x = to_form(frame[key])
    return x isa FormScalar ? value(x) : nothing
end

# `name:line:col` for a source frame (the name defaults to `<interactive>`).
function _frame_location(frame::Form)
    n = _frame_field(frame, Symbol(":name"))
    name = n isa AbstractString ? String(n) : "<interactive>"
    l = _frame_field(frame, Symbol(":line"))
    c = _frame_field(frame, Symbol(":col"))
    return string(name, ":", l isa Integer ? l : 1, ":", c isa Integer ? c : 1)
end

# The position suffix and the (short) source line, for `showerror`.
function _print_frames(io::IO, frames::Vector{Form})
    isempty(frames) && return nothing
    print(io, " (at ", _frame_location(frames[1]), ")")
    t = _frame_field(frames[1], Symbol(":text"))
    if t isa AbstractString && !isempty(t)
        txt = String(t)
        occursin('\n', txt) && (txt = first(split(txt, '\n')))
        print(io, "\n  ", txt)
    end
    return nothing
end

# Print the `cause=` and `from=` chain of an error object, recursively. The depth
# limit guards against a chain built circularly as data.
const _CHAIN_LIMIT = 16

function _print_error_chain(io::IO, x::Form, depth::Int)
    (depth >= _CHAIN_LIMIT || !(x isa FormContainer)) && return nothing
    cause = _error_field(x, Symbol(":cause"))
    context = _error_field(x, Symbol(":from"))
    if cause !== nothing && !isequal(cause, x)
        print(io, "\n\ndirect cause:\n  ", air_string(cause))
        _print_error_chain(io, cause, depth + 1)
    end
    if context !== nothing && !isequal(context, x)
        print(io, "\n\nduring handling of:\n  ", air_string(context))
        _print_error_chain(io, context, depth + 1)
    end
    return nothing
end

Base.showerror(io::IO, e::AirEvalError) =
    (print(io, "air eval error: ", e.msg); _print_frames(io, e.frames))
Base.showerror(io::IO, e::AirThrown) =
    (print(io, "air error: ", air_string(e.form)); _print_frames(io, e.frames);
     _print_error_chain(io, e.form, 0))
Base.showerror(io::IO, e::AirTraced) =
    (showerror(io, e.err); _print_frames(io, Form[e.frame]))
