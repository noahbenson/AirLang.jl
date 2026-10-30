################################################################################
# builtins_string.jl
#
# String operations, plus `string-format` (`~name` interpolation, `~~` for a
# literal tilde) and regular expressions: `(regex "pattern" [flags])` builds a
# pattern value that the pattern-taking verbs accept in place of a literal
# string (`string-split`, `string-replace`, `string-index-of`,
# `string-contains?`, `string-match?`, `string-find`, `string-find-all`).
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

_str(x::Form, who) = (l = _leafof(x); l isa String ? l :
    throw(AirEvalError("$who expects a string, got $(air_string(x))")))
_str_or_naught(x::Form) = (l = _leafof(x); l isa String ? l : nothing)

# ---- regex -------------------------------------------------------------------

# `(regex source)` / `(regex source flags)` — a compiled pattern value. Every
# verb below that takes a pattern accepts either a string (matched literally) or
# this value (matched as a regular expression).
builtin!(:regex, (env, scope, args) -> begin
    src = _str(_arg(args, 1, "regex"), "regex")
    flags = length(args) >= 2 ? _str(args[2], "regex") : ""
    return _extern_form(AirRegex(src, flags))
end)
builtin!(Symbol("regex?"), (env, scope, args) -> begin
    x = _arg(args, 1, "regex?")
    return Form(x isa FormExtern && value(x) isa AirRegex)
end)

# The pattern a string verb should use: a literal string, or a regex value.
function _pattern_arg(x::Form, who)
    if x isa FormExtern
        v = _extern_data(x)
        v isa AirRegex ||
            throw(AirEvalError("$who expects a string or a regex, got $(air_string(x))"))
        return v.re
    end
    l = _leafof(x)
    l isa String ||
        throw(AirEvalError("$who expects a string or a regex, got $(air_string(x))"))
    return l
end

# A regex replacement template, in air's `$` spelling, as Julia's `\` spelling:
# `$0` the whole match, `$1`…`$n` groups, `$name` a named group, `$$` a literal
# `$`. Backslashes in the template are literal text (as they were in the air
# string), so they are escaped for `SubstitutionString`.
function _substitution_template(t::AbstractString)
    io = IOBuffer()
    i = 1
    n = length(t)
    while i <= n
        c = t[i]
        if c == '\\'
            print(io, "\\\\"); i += 1
        elseif c != '$'
            print(io, c); i += 1
        elseif i < n && t[i + 1] == '$'
            print(io, '$'); i += 2
        elseif i < n && isdigit(t[i + 1])
            j = i + 1
            while j <= n && isdigit(t[j])
                j += 1
            end
            print(io, '\\', t[(i + 1):(j - 1)]); i = j
        elseif i < n && (isletter(t[i + 1]) || t[i + 1] == '_')
            j = i + 1
            while j <= n && (isletter(t[j]) || isdigit(t[j]) || t[j] == '_')
                j += 1
            end
            print(io, "\\g<", t[(i + 1):(j - 1)], ">"); i = j
        else
            print(io, '$'); i += 1
        end
    end
    return String(take!(io))
end

# The captures of a match as a sequence (`naught` when the pattern has none).
function _groups_form(caps)
    isempty(caps) && return naught
    vals = FormValue[]
    for c in caps
        push!(vals, _store_form(c === nothing ? naught : Form(String(c))))
    end
    return FormContainer(FormSeq(vals), FormMap())
end

# A match as `(match=… index=… groups=…)`, with a 1-based character index.
_match_form(text::AbstractString, index::Integer) =
    Form(PVector{Any}(), PDict{Symbol,Any}(
        Symbol(":match") => Form(String(text)),
        Symbol(":index") => Form(index),
        Symbol(":groups") => naught))

# Julia reports both a regex offset and the first index of a string search in
# code units; report a 1-based character index instead.
_char_index(s::AbstractString, byteoff::Integer) =
    byteoff <= 1 ? 1 : length(SubString(s, 1, prevind(s, byteoff))) + 1

_match_form(m::RegexMatch, s::AbstractString) =
    Form(PVector{Any}(), PDict{Symbol,Any}(
        Symbol(":match") => Form(String(m.match)),
        Symbol(":index") => Form(_char_index(s, m.offset)),
        Symbol(":groups") => _groups_form(m.captures)))

# ---- verbs -------------------------------------------------------------------

builtin!(Symbol("string-length"), (env, scope, args) -> Form(length(_str(_arg(args, 1, "string-length"), "string-length"))))

builtin!(Symbol("string-join"), (env, scope, args) -> begin
    c = _arg(args, 1, "string-join"); sep = _str(_arg(args, 2, "string-join"), "string-join")
    c isa FormContainer || return Form(sep)
    return Form(join((_str(to_form(v), "string-join") for v in c.seq), sep))
end)

builtin!(Symbol("string-append"), (env, scope, args) -> begin
    io = IOBuffer()
    for a in args
        print(io, _str(a, "string-append"))
    end
    return Form(String(take!(io)))
end)

# `(substring s start end)` — 1-based, inclusive (Julia's `s[start:end]`).
builtin!(:substring, (env, scope, args) -> begin
    s = _str(_arg(args, 1, "substring"), "substring")
    a = _leafof(_arg(args, 2, "substring")); b = _leafof(_arg(args, 3, "substring"))
    (a isa Integer && b isa Integer) || throw(AirEvalError("substring needs integer bounds"))
    return Form(s[a:b])
end)

builtin!(Symbol("string-replace"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-replace"), "string-replace")
    pat = _pattern_arg(_arg(args, 2, "string-replace"), "string-replace")
    new = _str(_arg(args, 3, "string-replace"), "string-replace")
    if pat isa Regex
        # A regex replacement expands `$0`/`$1`/`$name`; a literal one is used
        # exactly as written.
        r = try
            replace(s, pat => SubstitutionString(_substitution_template(new)))
        catch e
            throw(AirEvalError("string-replace: $(sprint(showerror, e))"))
        end
        return Form(r)
    end
    return Form(replace(s, pat => new))
end)

builtin!(Symbol("string-split"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-split"), "string-split")
    sep = length(args) >= 2 ? _pattern_arg(args[2], "string-split") : " "
    parts = split(s, sep)
    return FormContainer(FormSeq(FormValue[Form(String(p)) for p in parts]), FormMap())
end)

builtin!(Symbol("string-upper"), (env, scope, args) -> Form(uppercase(_str(_arg(args, 1, "string-upper"), "string-upper"))))
builtin!(Symbol("upcase"), (env, scope, args) -> Form(uppercase(_str(_arg(args, 1, "upcase"), "upcase"))))
builtin!(Symbol("string-lower"), (env, scope, args) -> Form(lowercase(_str(_arg(args, 1, "string-lower"), "string-lower"))))
builtin!(Symbol("downcase"), (env, scope, args) -> Form(lowercase(_str(_arg(args, 1, "downcase"), "downcase"))))
builtin!(Symbol("string-trim"), (env, scope, args) -> Form(strip(_str(_arg(args, 1, "string-trim"), "string-trim"))))
builtin!(Symbol("string-trim-left"), (env, scope, args) -> Form(lstrip(_str(_arg(args, 1, "string-trim-left"), "string-trim-left"))))
builtin!(Symbol("string-trim-right"), (env, scope, args) -> Form(rstrip(_str(_arg(args, 1, "string-trim-right"), "string-trim-right"))))

# `(string-take s n)` / `(string-drop s n)` — the first `n` characters, and the
# rest. `n` is clamped to the string's length.
builtin!(Symbol("string-take"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-take"), "string-take")
    n = _leafof(_arg(args, 2, "string-take"))
    n isa Integer || throw(AirEvalError("string-take needs an integer count"))
    return Form(s[1:clamp(n, 0, length(s))])
end)
builtin!(Symbol("string-drop"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-drop"), "string-drop")
    n = _leafof(_arg(args, 2, "string-drop"))
    n isa Integer || throw(AirEvalError("string-drop needs an integer count"))
    k = clamp(n, 0, length(s))
    return Form(k >= length(s) ? "" : s[(k + 1):end])
end)

# `(string-capitalize s)` — the first character upper, the rest lower.
builtin!(Symbol("string-capitalize"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-capitalize"), "string-capitalize")
    isempty(s) && return Form("")
    return Form(uppercasefirst(lowercase(s)))
end)

builtin!(Symbol("string-starts-with?"), (env, scope, args) ->
    Form(startswith(_str(_arg(args, 1, "string-starts-with?"), "string-starts-with?"),
                    _str(_arg(args, 2, "string-starts-with?"), "string-starts-with?"))))
builtin!(Symbol("string-ends-with?"), (env, scope, args) ->
    Form(endswith(_str(_arg(args, 1, "string-ends-with?"), "string-ends-with?"),
                  _str(_arg(args, 2, "string-ends-with?"), "string-ends-with?"))))
builtin!(Symbol("string-contains?"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-contains?"), "string-contains?")
    pat = _pattern_arg(_arg(args, 2, "string-contains?"), "string-contains?")
    return Form(occursin(pat, s))
end)

# `(string-match? s pat)` — the pattern-aware spelling of `string-contains?`:
# true when `pat` matches somewhere in `s`.
builtin!(Symbol("string-match?"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-match?"), "string-match?")
    pat = _pattern_arg(_arg(args, 2, "string-match?"), "string-match?")
    return Form(occursin(pat, s))
end)

builtin!(Symbol("string-index-of"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-index-of"), "string-index-of")
    pat = _pattern_arg(_arg(args, 2, "string-index-of"), "string-index-of")
    r = findfirst(pat, s)
    return r === nothing ? naught : Form(_char_index(s, first(r)))
end)

# `(string-find s pat)` — the first match as `(match=… index=… groups=…)`, or
# `naught`. The pattern is literal text or a regex.
builtin!(Symbol("string-find"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-find"), "string-find")
    pat = _pattern_arg(_arg(args, 2, "string-find"), "string-find")
    if pat isa Regex
        m = match(pat, s)
        return m === nothing ? naught : _match_form(m, s)
    end
    r = findfirst(pat, s)
    return r === nothing ? naught : _match_form(pat, _char_index(s, first(r)))
end)

# `(string-find-all s pat)` — every non-overlapping match, in order, each as the
# same `(match=… index=… groups=…)` form.
builtin!(Symbol("string-find-all"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-find-all"), "string-find-all")
    pat = _pattern_arg(_arg(args, 2, "string-find-all"), "string-find-all")
    found = FormValue[]
    if pat isa Regex
        for m in eachmatch(pat, s)
            push!(found, _store_form(_match_form(m, s)))
        end
    else
        isempty(pat) &&
            throw(AirEvalError("string-find-all needs a non-empty literal pattern"))
        i = firstindex(s)
        while i <= ncodeunits(s)
            r = findnext(pat, s, i)
            r === nothing && break
            push!(found, _store_form(_match_form(pat, _char_index(s, first(r)))))
            i = nextind(s, last(r))
        end
    end
    return FormContainer(FormSeq(found), FormMap())
end)

# `(string-reverse s)` — the characters of `s` in reverse order.
builtin!(Symbol("string-reverse"), (env, scope, args) ->
    Form(reverse(_str(_arg(args, 1, "string-reverse"), "string-reverse"))))

builtin!(Symbol("string-repeat"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-repeat"), "string-repeat")
    n = _leafof(_arg(args, 2, "string-repeat"))
    n isa Integer || throw(AirEvalError("string-repeat needs an integer"))
    return Form(repeat(s, n))
end)

function _pad(s, n, ch, left)
    pad = repeat(ch, max(0, n - length(s)))
    return left ? pad * s : s * pad
end
builtin!(Symbol("string-pad-left"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-pad-left"), "string-pad-left")
    n = _leafof(_arg(args, 2, "string-pad-left"))
    ch = length(args) >= 3 ? _str(args[3], "string-pad-left") : " "
    return Form(_pad(s, n, ch, true))
end)
builtin!(Symbol("string-pad-right"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-pad-right"), "string-pad-right")
    n = _leafof(_arg(args, 2, "string-pad-right"))
    ch = length(args) >= 3 ? _str(args[3], "string-pad-right") : " "
    return Form(_pad(s, n, ch, false))
end)

builtin!(Symbol("string-chars"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-chars"), "string-chars")
    return FormContainer(FormSeq(FormValue[Form(string(c)) for c in s]), FormMap())
end)

builtin!(Symbol("string-lines"), (env, scope, args) -> begin
    s = _str(_arg(args, 1, "string-lines"), "string-lines")
    return FormContainer(FormSeq(FormValue[Form(l) for l in split(s, '\n')]), FormMap())
end)

# `(form->string x pretty=true width=n)` — the source text of a form. The default
# is the flat spelling; `pretty=true` breaks it across lines to fit `width`.
function _bi_form_to_string(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "form->string", (Symbol(":pretty"), Symbol(":width")))
    length(call.seq) == 2 || throw(AirEvalError("form->string takes one form"))
    x = air_reduce(env, scope, to_form(call.seq[2]))
    pretty = haskey(call.map, Symbol(":pretty")) &&
             truthy(air_reduce(env, scope, to_form(call.map[Symbol(":pretty")])))
    width = 80
    if haskey(call.map, Symbol(":width"))
        l = _leafof(air_reduce(env, scope, to_form(call.map[Symbol(":width")])))
        (l isa Integer && l >= 1) ||
            throw(AirEvalError("form->string: width must be a positive integer"))
        width = _as_int(l, "form->string: width")
    end
    return Form(pretty ? air_pretty_string(env, x; width = width) : air_string(env, x))
end
special!(Symbol("form->string"), _bi_form_to_string)
builtin!(Symbol("string->form"), (env, scope, args) -> read_air(_str(_arg(args, 1, "string->form"), "string->form")))

# ---- string-format -----------------------------------------------------------

_format_value(v::Form) = (l = _leafof(v); l isa String ? l : air_string(v))

function _format_string(fmt::AbstractString, vars::Dict{String,String})
    io = IOBuffer()
    i = 1
    n = length(fmt)
    while i <= n
        if fmt[i] == '~'
            if i + 1 <= n && fmt[i + 1] == '~'
                print(io, '~'); i += 2
            else
                j = i + 1
                while j <= n && (isletter(fmt[j]) || isdigit(fmt[j]) || fmt[j] in ('-', '_'))
                    j += 1
                end
                name = fmt[(i + 1):(j - 1)]
                haskey(vars, name) ||
                    throw(AirEvalError("string-format: no variable ~$name"))
                print(io, vars[name]); i = j
            end
        else
            print(io, fmt[i]); i += 1
        end
    end
    return String(take!(io))
end

special!(Symbol("string-format"), (env, scope, call) -> begin
    fmt = _str(air_reduce(env, scope, to_form(call.seq[2])), "string-format")
    vars = Dict{String,String}()
    for (k, v) in call.map
        name = String(k); startswith(name, ":") && (name = name[2:end])
        vars[name] = _format_value(air_reduce(env, scope, to_form(v)))
    end
    return Form(_format_string(fmt, vars))
end)
