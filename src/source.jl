################################################################################
# source.jl
#
# Source positions and error frames.
#
# Air source is data, so positions are not attached to forms; instead the reader
# records the character span of every container it parses, and the loader
# installs that record, task-locally, while it evaluates the forms. An error that
# escapes a top-level form is decorated with the form's position (name, line,
# column, and text); an error raised while a namespace `def` is executing is
# decorated with the definition's stored `src=(…)` instead. Positions are
# best-effort: an environment that evaluates a bare form (a REPL call, a test)
# has no source record and reports no position.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# The source record active while a file (or a library) is being evaluated.
struct AirSource
    name::String
    text::String
    spans::Dict{Form,Tuple{Int,Int}}
end

const _SOURCE_KEY = :AirLangSource

_air_source() = (x = get(task_local_storage(), _SOURCE_KEY, nothing);
                 x isa AirSource ? x : nothing)

function _with_air_source(f::Function, src::AirSource)
    return task_local_storage(_SOURCE_KEY, src) do
        f()
    end
end

# The 1-based (line, column) of character position `pos`.
function _line_col(src::AirSource, pos::Int)
    cs = collect(src.text)
    line, col = 1, 1
    for i in 1:min(pos - 1, length(cs))
        if cs[i] == '\n'
            line += 1
            col = 1
        else
            col += 1
        end
    end
    return line, col
end

_span_text(src::AirSource, sp::Tuple{Int,Int}) = begin
    cs = collect(src.text)
    String(cs[sp[1]:min(sp[2], length(cs))])
end

# A source frame `(name=… line=… col=… text=…)`.
function _source_info(src::AirSource, sp::Tuple{Int,Int})
    line, col = _line_col(src, sp[1])
    return _ns_form(Form[], Pair{Symbol,Form}[
        Symbol(":name") => Form(src.name),
        Symbol(":line") => Form(line),
        Symbol(":col") => Form(col),
        Symbol(":text") => Form(_span_text(src, sp))])
end

# The source frame of `form`, when the active source knows its span.
function _form_source_info(form::Form)
    src = _air_source()
    src === nothing && return nothing
    sp = get(src.spans, form, nothing)
    sp === nothing && return nothing
    return _source_info(src, sp)
end

# Attach `info` as the innermost frame of an air error, unless it already has one
# (the innermost frame is the most useful).
function _located(e::AirError, info::Form)
    e isa AirTraced && return e
    if e isa AirThrown
        return isempty(e.frames) ? AirThrown(e.form, Form[info]) : e
    elseif e isa AirEvalError
        return isempty(e.frames) ? AirEvalError(e.msg, Form[info]) : e
    end
    return AirTraced(e, info)
end

# The frames of an air error, innermost first.
_error_frames(e::AirThrown) = e.frames
_error_frames(e::AirEvalError) = e.frames
_error_frames(e::AirTraced) = Form[e.frame]
_error_frames(e) = Form[]

# Evaluate `f` as the body of the top-level source form `form`, decorating any
# escaping air error with that form's position. A form with no recorded span is
# evaluated without a position.
function _with_form_source(f::Function, form::Form)
    info = _form_source_info(form)
    info === nothing && return f()
    try
        return f()
    catch e
        e isa InterruptException && rethrow()
        e isa AirError || rethrow()
        throw(_located(e, info))
    end
end

# The `src` frame stored in a namespace entry's body, if any. The body is gated
# by the entry's `read` permission like any other body; diagnostics read it
# internally.
function _entry_source_info(vf::VolatileForm)
    b = _entry_body(vf)
    b isa FormContainer || return nothing
    key = Symbol(":src")
    haskey(b, key) || return nothing
    return to_form(b[key])
end

# Decorate an error escaping a reduction with the source of the `def` body being
# evaluated. The innermost rule context wins, so an error inside `g`'s body when
# `f` calls `g` reports `g`'s definition.
function _annotate_error(e::AirError, scope::Scope)
    e isa AirTraced && return e
    rule = _scope_rule(scope)
    rule === nothing && return e
    rule.entry === nothing && return e
    info = _entry_source_info(rule.entry)
    info === nothing && return e
    return _located(e, info)
end
