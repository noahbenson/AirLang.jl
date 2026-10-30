################################################################################
# builtins_time.jl
#
# Times are the ordinary immutable form `(time SECONDS)` (see `forms.jl`), so
# they need no new form type: these verbs construct one, parse and format one,
# and compare one. The arithmetic (`+`, `-`, `<`, …) lives in `operators.jl`,
# where the ordinary symbolic operator dispatch reaches it.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# The numeric value a form contributes to a comparison: a time contributes its
# seconds, a number itself, and anything else `nothing`.
_cmp_value(x::Form) = _is_time_form(x) ? _time_secs(x) :
    (l = _leafof(x); l isa Real ? l : nothing)

# ---- construction ------------------------------------------------------------

# `(now)` — the current instant, to millisecond precision so that it prints as
# ISO-8601 rather than falling back to seconds. Reading the clock is a pure
# value: it needs no database and is unaffected by a transaction.
builtin!(:now, (env, scope, args) -> begin
    isempty(args) || throw(AirEvalError("now takes no arguments"))
    return _mk_time(_now_secs())
end)

# ---- parsing -----------------------------------------------------------------

# `2026-10-28`, `2026-10-28T21:15`, `2026-10-28 21:15:00.123`, with an optional
# `Z` or `±hh:mm`/`±hhmm` offset. A missing time is midnight; a missing offset is
# UTC.
const _ISO_TIME_RE = r"^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?(Z|z|[+-]\d{2}:?\d{2})?$"

# The offset in seconds and the text that names it (used in place of `Z`).
function _parse_offset(o::Form)
    l = _leafof(o)
    l isa Real && (r = _as_int(round(l), "time-str: offset");
                   return (r, _offset_text(r)))
    l isa AbstractString || throw(AirEvalError("time-str: offset must be a string or a number"))
    s = strip(String(l))
    (s == "Z" || s == "z" || s == "UTC" || s == "+00:00") && return (0, "Z")
    m = match(r"^([+-])(\d{2}):?(\d{2})$", s)
    m === nothing && throw(AirEvalError("time-str: bad offset $(repr(s))"))
    secs = parse(Int, m[2]) * 3600 + parse(Int, m[3]) * 60
    secs = m[1] == "-" ? -secs : secs
    return (secs, _offset_text(secs))
end

function _offset_text(secs::Integer)
    a = abs(secs)
    return string(secs < 0 ? "-" : "+", lpad(a ÷ 3600, 2, '0'), ":",
                  lpad((a % 3600) ÷ 60, 2, '0'))
end

# The epoch seconds an ISO-8601 string names, or `nothing` when it is not one.
function _parse_iso_time(s::AbstractString)
    m = match(_ISO_TIME_RE, strip(String(s)))
    m === nothing && return nothing
    y, mo, d = parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3])
    h = m[4] === nothing ? 0 : parse(Int, m[4])
    mi = m[5] === nothing ? 0 : parse(Int, m[5])
    se = m[6] === nothing ? 0 : parse(Int, m[6])
    frac = m[7] === nothing ? 0.0 : parse(Float64, "0." * m[7])
    offs = 0
    if m[8] !== nothing
        (offs, _) = _parse_offset(Form(String(m[8])))
    end
    base = try
        Dates.datetime2unix(Dates.DateTime(y, mo, d, h, mi, se))
    catch
        return nothing
    end
    return base + frac - offs
end

# `(time x)` — the value of `x` as a time. A number is UTC epoch seconds, an
# ISO-8601 string is parsed, and a time is already one. Anything else stays
# symbolic, like every other math builtin, so `(time ?x)` is a fixed point.
builtin!(:time, (env, scope, args) -> begin
    x = _arg(args, 1, "time")
    length(args) == 1 || throw(AirEvalError("time takes exactly one argument"))
    _is_time_form(x) && return x
    l = _leafof(x)
    l isa Real && return _mk_time(l)
    if l isa AbstractString
        t = _parse_iso_time(l)
        t === nothing &&
            throw(AirEvalError("time: not an ISO-8601 time: $(repr(String(l)))"))
        return _mk_time(t)
    end
    return _mk_prefix(:time, args)
end)

builtin!(Symbol("time?"), (env, scope, args) -> Form(_is_time_form(_arg(args, 1, "time?"))))

# ---- formatting --------------------------------------------------------------

# `(time-str t; format="…", offset="+02:00")` — the text of a time. The default
# is ISO-8601 UTC with milliseconds (trailing zeros trimmed); `format` is a Julia
# `Dates.DateFormat` string; `offset` shifts the instant and replaces the `Z`.
function _bi_time_str(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "time-str", (Symbol(":format"), Symbol(":offset")))
    length(call.seq) == 2 || throw(AirEvalError("time-str takes one time"))
    t = air_reduce(env, scope, to_form(call.seq[2]))
    _is_time_form(t) ||
        throw(AirEvalError("time-str needs a time, got $(air_string(t))"))
    fmt = nothing
    if haskey(call.map, Symbol(":format"))
        f = _leafof(air_reduce(env, scope, to_form(call.map[Symbol(":format")])))
        f isa AbstractString ||
            throw(AirEvalError("time-str: format must be a string"))
        fmt = String(f)
    end
    offs, offtext = 0, "Z"
    if haskey(call.map, Symbol(":offset"))
        offs, offtext = _parse_offset(air_reduce(env, scope,
                                                 to_form(call.map[Symbol(":offset")])))
    end
    return Form(_format_time(_time_secs(t) + offs, fmt, offtext))
end
special!(Symbol("time-str"), _bi_time_str)

function _format_time(secs::Float64, fmt::Union{Nothing,String}, offtext::String)
    if fmt === nothing
        txt = _time_text(secs)
        (offtext != "Z" && endswith(txt, "Z")) || return txt
        return txt[1:(end - 1)] * offtext
    end
    dt = try
        Dates.unix2datetime(secs)
    catch
        throw(AirEvalError("time-str: time is outside the range DateTime can format"))
    end
    try
        return Dates.format(dt, Dates.DateFormat(fmt))
    catch
        throw(AirEvalError("time-str: bad format $(repr(fmt))"))
    end
end

# ---- comparison --------------------------------------------------------------
#
# `between?`, `before?`, and `after?` accept times and numbers alike: a time
# contributes its seconds, so they are ordinary numeric comparisons. A symbolic
# argument leaves the form unchanged, as the math verbs do.

function _between(args::Vector{Form})
    length(args) == 3 || return nothing
    a, b, c = _cmp_value(args[1]), _cmp_value(args[2]), _cmp_value(args[3])
    (a === nothing || b === nothing || c === nothing) && return nothing
    return b <= a <= c
end

builtin!(Symbol("between?"), (env, scope, args) -> begin
    _arg(args, 3, "between?")
    r = _between(args)
    r === nothing ? _mk_prefix(Symbol("between?"), args) : Form(r)
end)

builtin!(Symbol("before?"), (env, scope, args) -> begin
    a = _arg(args, 1, "before?"); b = _arg(args, 2, "before?")
    va, vb = _cmp_value(a), _cmp_value(b)
    (va === nothing || vb === nothing) && return _mk_prefix(Symbol("before?"), [a, b])
    return Form(va < vb)
end)

builtin!(Symbol("after?"), (env, scope, args) -> begin
    a = _arg(args, 1, "after?"); b = _arg(args, 2, "after?")
    va, vb = _cmp_value(a), _cmp_value(b)
    (va === nothing || vb === nothing) && return _mk_prefix(Symbol("after?"), [a, b])
    return Form(va > vb)
end)
