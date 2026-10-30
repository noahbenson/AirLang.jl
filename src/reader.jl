################################################################################
# reader.jl
#
# The air reader: tokenize source and parse it directly into AirDB `Form`s. No
# separate AST — air code *is* air data.
#
# Supported in this milestone: atoms (plain symbols, keywords, wildcards,
# strings, raw strings (`raw"…"`), regex literals (`r"…"`), numbers, booleans,
# `naught`), parenthesized forms, the `|`
# pattern-alternative sugar, `#` line comments, and `k=v` mapping/hybrid form
# elements. The
# reader normalizes the empty form to `naught` (so `()` is `naught` at every
# depth) but keeps one-element forms as written — `(1)` is a one-element
# container; collapsing is never done.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- tokens ------------------------------------------------------------------

struct _Token
    kind::Symbol   # :lparen :rparen :pipe :string :atom
    text::String   # atom text, or the decoded value of a string
    pos::Int       # 1-based source position of the first character
    stop::Int      # 1-based source position of the last character
    value::Union{Nothing,Form}  # a literal's value (a regex); see `_token_form`
end
_Token(kind::Symbol, text::String, pos::Int, stop::Int) =
    _Token(kind, text, pos, stop, nothing)

# The form a literal token denotes: a string is its own text, while a regex token
# was compiled when it was scanned.
_token_form(t::_Token) = t.value === nothing ? Form(t.text) : t.value

# Delimiters end an atom. A comma is treated as a separator (whitespace), as in
# Mathematica; the README's symbol character set does not include it.
const _DELIMS = (' ', '\t', '\n', '\r', ',', '(', ')', '|', '#', '"')

function _tokenize(s::AbstractString)
    cs = collect(s)
    n = length(cs)
    toks = _Token[]
    i = 1
    while i <= n
        c = cs[i]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ','
            i += 1
        elseif c == '#' && i < n && cs[i + 1] == '|'
            i = _skip_block_comment(cs, i)
        elseif c == '#'
            while i <= n && cs[i] != '\n'
                i += 1
            end
        elseif c == '('
            push!(toks, _Token(:lparen, "(", i, i)); i += 1
        elseif c == ')'
            push!(toks, _Token(:rparen, ")", i, i)); i += 1
        elseif c == '|'
            push!(toks, _Token(:pipe, "|", i, i)); i += 1
        elseif c == '"'
            tok, i = _scan_string(cs, i)
            push!(toks, tok)
        elseif c == 'r' && i + 3 <= n && cs[i + 1] == 'a' && cs[i + 2] == 'w' &&
               cs[i + 3] == '"'
            tok, i = _scan_raw_string(cs, i)
            push!(toks, tok)
        elseif c == 'r' && i + 1 <= n && cs[i + 1] == '"'
            tok, i = _scan_regex(cs, i)
            push!(toks, tok)
        elseif c == 'b' && i + 3 <= n && cs[i + 1] == 'i' && cs[i + 2] == 'g' &&
               cs[i + 3] == '"'
            tok, i = _scan_big_string(cs, i)
            push!(toks, tok)
        else
            start = i
            while i <= n && !(cs[i] in _DELIMS)
                i += 1
            end
            i = _push_atom!(toks, cs, start, i)
        end
    end
    return toks
end

# The prefix of a literal that begins immediately after an atom, and its length:
# the `x=` of a map value (`x=r"…"`, `x=raw"…"`, `x=big"…"`) or the quote sugar
# (`'r"…"`, `'big"…"`). The quote is a delimiter, so the atom stops before it;
# splitting there lets the literal be one form, as `x="…"` already reads.
function _literal_prefix(text::AbstractString)
    (endswith(text, "=raw") || text == "'raw") && return (:raw, 3)
    (endswith(text, "=big") || text == "'big") && return (:big, 3)
    (endswith(text, "=r") || text == "'r") && return (:regex, 1)
    return (:none, 0)
end

# Push the atom spanning `start:(i - 1)` and return the index of the next
# character to tokenize, splitting off a literal prefix (see above) when the
# next character opens one.
function _push_atom!(toks::Vector{_Token}, cs, start::Int, i::Int)
    text = String(cs[start:(i - 1)])
    kind, npre = i <= length(cs) && cs[i] == '"' ? _literal_prefix(text) : (:none, 0)
    if npre > 0
        prefix = text[1:(end - npre)]
        if !isempty(prefix)
            push!(toks, _Token(:atom, prefix, start, start + length(prefix) - 1))
            litstart = start + length(prefix)
            tok, j = kind === :raw ? _scan_raw_string(cs, litstart) :
                     kind === :big ? _scan_big_string(cs, litstart) :
                     _scan_regex(cs, litstart)
            push!(toks, tok)
            return j
        end
    end
    push!(toks, _Token(:atom, text, start, i - 1))
    return i
end

# Skip a `#| … |#` block comment, returning the index just past its close. Block
# comments nest, so `#| a #| b |# c |#` is one comment; an unterminated one is a
# parse error at the opening `#|`.
function _skip_block_comment(cs, i)
    n = length(cs)
    start = i
    i += 2
    depth = 1
    while i <= n
        if cs[i] == '#' && i < n && cs[i + 1] == '|'
            depth += 1; i += 2
        elseif cs[i] == '|' && i < n && cs[i + 1] == '#'
            depth -= 1; i += 2
            depth == 0 && return i
        else
            i += 1
        end
    end
    throw(AirParseError("unterminated block comment", start))
end

# Scan a string literal, triple-quoted or not, returning the decoded value.
function _scan_string(cs, i)
    n = length(cs)
    start = i
    if i + 2 <= n && cs[i + 1] == '"' && cs[i + 2] == '"'
        j = i + 3
        while j + 2 <= n && !(cs[j] == '"' && cs[j + 1] == '"' && cs[j + 2] == '"')
            j += 1
        end
        j + 2 <= n || throw(AirParseError("unterminated triple-quoted string", start))
        return _Token(:string, _decode_string(String(cs[start:(j + 2)])), start, j + 2),
               j + 3
    else
        j = i + 1
        while j <= n
            if cs[j] == '\\'
                j += 2
                continue
            elseif cs[j] == '"'
                break
            end
            j += 1
        end
        j <= n || throw(AirParseError("unterminated string", start))
        return _Token(:string, _decode_string(String(cs[start:j])), start, j), j + 1
    end
end

# `raw"…"` (and `raw"""…"""`) is a raw string: its backslashes are literal, except
# that `\"` is a quote and `\\` is a backslash. The whole token is handed to
# Julia's parser, so the result has exactly Julia's raw-string semantics (a
# triple-quoted literal is dedented as well). This is what makes a regex pattern
# readable: `raw"\d+"` is the three characters `\d+`.
function _scan_raw_string(cs, i)
    (val, stop) = _scan_raw_literal(cs, i + 3, i, "raw string")
    return _Token(:string, val, i, stop), stop + 1
end

# Scan the literal whose opening quote is at `q`, returning its decoded content
# and the index of its closing quote. `start` is the token's first character and
# `what` names the literal in an error message. The whole literal is handed to
# Julia's parser as a raw string, so the result has exactly Julia's raw-string
# semantics — only `\"` and `\\` are escapes — and a triple-quoted literal is
# dedented as well.
function _scan_raw_literal(cs, q::Int, start::Int, what::AbstractString)
    n = length(cs)
    triple = q + 2 <= n && cs[q + 1] == '"' && cs[q + 2] == '"'
    body = triple ? q + 3 : q + 1
    j = body
    while j <= n
        if cs[j] == '\\'
            j += 2
            continue
        end
        if triple
            (j + 2 <= n && cs[j] == '"' && cs[j + 1] == '"' && cs[j + 2] == '"') && break
        elseif cs[j] == '"'
            break
        end
        j += 1
    end
    if triple
        j + 2 <= n || throw(AirParseError("unterminated $what", start))
        stop = j + 2
    else
        j <= n || throw(AirParseError("unterminated $what", start))
        stop = j
    end
    text = "raw" * String(cs[q:stop])
    val = try
        v = Meta.parse(text)
        if v isa AbstractString
            String(v)
        elseif v isa Expr && v.head === :macrocall && !isempty(v.args) &&
               v.args[end] isa AbstractString
            # A non-standard string literal parses as its macro call; the parser
            # has already applied the raw-string rules (and, for a triple-quoted
            # literal, its indentation handling) to the literal argument.
            String(v.args[end])
        else
            nothing
        end
    catch
        nothing
    end
    if val === nothing
        triple && throw(AirParseError("invalid $what", start))
        val = _raw_unescape(String(cs[body:(stop - 1)]))
    end
    return (val, stop)
end

# The letters a regex literal may carry immediately after its closing quote
# (`r"a+"i`); a letter outside this set ends the literal. These are Julia's.
const _REGEX_FLAGS = ('a', 'i', 'm', 's', 'x')

# `r"…"` (and `r"""…"""`) is a regex literal: a raw string — the same escaping,
# so `r"\d+"` is the three patterns `\d+` — compiled into a regex value as it is
# read, followed by any flag letters. It builds the same value as
# `(regex "…" "flags")`, so the two spellings are equal, and it is a value
# wherever a form may appear (including inside a hold).
function _scan_regex(cs, i)
    n = length(cs)
    (src, stop) = _scan_raw_literal(cs, i + 1, i, "regular expression")
    j = stop + 1
    fstart = j
    while j <= n && cs[j] in _REGEX_FLAGS
        j += 1
    end
    flags = String(cs[fstart:(j - 1)])
    val = try
        _extern_form(AirRegex(src, flags))
    catch e
        e isa AirEvalError || rethrow()
        throw(AirParseError(e.msg, i))
    end
    return _Token(:string, src, i, j - 1, val), j
end

# `big"…"` (and `big"""…"""`) is a `BigFloat` literal: the quoted digits are
# parsed at the ambient precision, exactly as Julia's `big"…"` macro does. A
# trailing `i`, attached with no space, makes it the imaginary part, so
# `big"2.0"i` is a `Complex{BigFloat}` with a zero real part (`2i` is the same
# sugar for `ComplexF64`).
function _scan_big_string(cs, i)
    n = length(cs)
    (src, stop) = _scan_raw_literal(cs, i + 3, i, "bigfloat literal")
    v = try
        parse(BigFloat, src)
    catch
        throw(AirParseError("malformed bigfloat literal: $src", i))
    end
    j = stop + 1
    if j <= n && cs[j] == 'i' && (j == n || cs[j + 1] in _DELIMS)
        v = Complex{BigFloat}(zero(BigFloat), v)
        j += 1
    end
    return _Token(:string, src, i, j - 1, to_form(v)), j
end

# The fallback decoder for a single-quoted raw string: only `\"` is an escape;
# every other backslash (including `\\`) is literal, as in Julia's raw strings.
function _raw_unescape(inner::String)
    io = IOBuffer()
    i = 1
    n = length(inner)
    while i <= n
        if inner[i] == '\\' && i < n && inner[i + 1] == '"'
            print(io, '"'); i += 2
        else
            print(io, inner[i]); i += 1
        end
    end
    return String(take!(io))
end

# Decode a raw Julia-style string literal by delegating to Julia's parser, so air
# strings follow "the same formatting rules as Julia's strings".
function _decode_string(raw::String)
    try
        v = Meta.parse(raw)
        v isa String && return v
    catch
    end
    inner = startswith(raw, "\"\"\"") ? raw[4:(end - 3)] : raw[2:(end - 1)]
    return Base.unescape_string(inner)
end

# ---- atoms -------------------------------------------------------------------

function _parse_atom(text::AbstractString, pos::Int)
    # `:=` is the revision instruction of the RETE rule DSL; the `:` marks a
    # keyword and the `=` is part of its name.
    text == ":=" && return Form(Symbol(":="))
    text == "true" && return Form(true)
    text == "false" && return Form(false)
    text == "naught" && return Form(nothing)
    # A leading `'` quotes the atom that follows: `'a` is `(' a)`, `'5` is
    # `(' 5)`, and `'~x` is `(' (preval x))`. A bare `'` is the reserved hold
    # head itself, an ordinary symbol everywhere but the first position.
    startswith(text, "'") &&
        return length(text) == 1 ? Form(Symbol("'")) : _mk_hold(_parse_atom(text[2:end], pos))
    # A lone `:` is the wildcard symbol — all rows or all columns in a table
    # path. A run of two or more colons is still not a symbol, and `:(…)` is
    # rejected by the parser in favor of the canonical `(' …)` spelling.
    text == ":" && return Form(Symbol(":"))
    _is_colon_atom(text) && throw(AirParseError("':' is not a symbol (a keyword needs a name)", pos))
    # A trailing `...` splices, and is read before any number (`2...` splices 2).
    # The suffix binds looser than the `~` prefix, so `~x...` splices the value of
    # the hole (`(... (preval x))`), not a preval of a splice.
    if endswith(text, "...") && length(text) > 3
        return _mk_splat(_parse_atom(text[1:(end - 3)], pos))
    end
    # `~expr` is a `preval` hole (evaluated when the enclosing hold is built).
    if startswith(text, "~") && length(text) > 1
        return _mk_preval(_parse_atom(text[2:end], pos))
    end
    # A non-finite float is spelled the way it prints, so printing round-trips.
    if text == "Inf" || text == "-Inf" || text == "NaN"
        return to_form(text == "NaN" ? NaN : text == "Inf" ? Inf : -Inf)
    end
    if _looks_numeric(text)
        v = _try_number(text)
        v === nothing && throw(AirParseError("malformed number: $text", pos))
        # `to_form` rather than `Form`, so AirDB canonicalizes the leaf (a
        # `BigInt` that would fit an `Int64`, a `Rational{BigInt}` with small
        # components, a `Complex` whose parts are exactly `Float64`).
        return to_form(v)
    end
    # A leading dot is a namespace path from the global root: `.` alone is the
    # root volatile and `.air.string-join` is `(get . :air :string-join)`. The
    # postfix `.key` accessor is still accepted when the atom is *adjacent* to
    # the form it follows (see `_apply_postfix`), so `f.a` is a lookup.
    text == "." && return Form(DOT_ROOT)
    (startswith(text, ".") && !_looks_numeric(text)) && return _parse_ns_path(text, pos)
    occursin('.', text) && return _parse_dotted(text, pos)
    # `=` may only appear in the four comparison symbols; anywhere else it is a
    # key/value separator (`a=b`) and must not survive as part of a symbol.
    (occursin('=', text) && !(Symbol(text) in EQ_SYMBOLS)) &&
        throw(AirParseError("'=' may only appear in ==, !=, ===, !==: $text", pos))
    return Form(Symbol(text))
end

function _looks_numeric(t::AbstractString)
    isempty(t) && return false
    c = t[1]
    isdigit(c) && return true
    (c == '+' || c == '-' || c == '.') && length(t) > 1 && isdigit(t[2]) && return true
    return false
end

function _try_number(t::AbstractString)
    v = tryparse(Int64, t)
    v === nothing || return v
    # An integer too large for `Int64` is exact, so it becomes a `BigInt` rather
    # than falling through to the `Float64` branch below.
    b = _try_integer(t)
    b === nothing || return b
    f = tryparse(Float64, t)
    f === nothing || return f
    # `n//d` is an exact rational. It must be written with no spaces: the spaced
    # `(n // d)` is the rational operator, and the adjacent characters are one
    # atom, as for every other literal.
    r = _try_rational(t)
    r === nothing || return r
    # A trailing `i`, attached to the number with no space, marks the imaginary
    # unit, so `2i` and `4.4+2.0i` are complex literals. Julia's `im` is not
    # accepted; the spaced `4.4 + 2.0i` is the infix sum `(+ 4.4 2.0i)`.
    if endswith(t, "i")
        c = tryparse(ComplexF64, t[1:(end - 1)] * "im")
        c === nothing || return c
    end
    return nothing
end

# The `BigInt` a decimal integer literal denotes, or `nothing` when the text is
# not an (optionally signed) run of digits. `Int64` is tried first, so this is
# only reached for a value that does not fit it.
function _try_integer(t::AbstractString)
    s = startswith(t, "+") || startswith(t, "-") ? t[2:end] : t
    (isempty(s) || !all(isdigit, s)) && return nothing
    return tryparse(BigInt, t)
end

# The integer an integer literal denotes (`Int64` when it fits, else `BigInt`),
# or `nothing`.
function _try_int_text(s::AbstractString)
    v = tryparse(Int64, s)
    v === nothing || return v
    return _try_integer(s)
end

# The `Rational` an `n//d` literal denotes, or `nothing`. A zero denominator is
# not a rational (and is reported as a malformed number by the caller).
function _try_rational(t::AbstractString)
    k = findfirst("//", t)
    k === nothing && return nothing
    n = _try_int_text(String(t[1:(k.start - 1)]))
    n === nothing && return nothing
    d = _try_int_text(String(t[(k.stop + 1):end]))
    d === nothing && return nothing
    iszero(d) && return nothing
    return n // d
end

# ---- the `.` accessor and `...` splat ----------------------------------------

# An atom that begins with `.` (and is not a number) is a postfix operator:
# `.key` extracts a subform, `...` splices.
_is_postfix_dot(text::AbstractString) = startswith(text, ".") && !_looks_numeric(text)

_mk_get(form::Form, keys::Vector{Form}) =
    Form(PVector{Any}([Form(Symbol("get")), form, keys...]), PDict{Symbol,Any}())

_mk_splat(form::Form) =
    Form(PVector{Any}([Form(Symbol("...")), form]), PDict{Symbol,Any}())

_mk_preval(form::Form) =
    Form(PVector{Any}([Form(PREVAL), form]), PDict{Symbol,Any}())

# The reader's quote sugar `'x`: a hold whose single element is `x`.
_mk_hold(form::Form) =
    Form(PVector{Any}([Form(Symbol("'")), form]), PDict{Symbol,Any}())

# An alternative pattern `(alt a b …)`. `a | b` joins its two neighbours; an
# adjacent alt on either side is spliced in, so `a | b | c` is n-ary rather than
# nested: `(alt a b c)`. Outside a pattern the result is ordinary inert data.
_mk_alt(left::Form, right::Form) =
    Form(PVector{Any}([Form(ALT), _alt_branches(left)..., _alt_branches(right)...]),
         PDict{Symbol,Any}())

_alt_branches(x::Form) =
    _is_alt(x) ? Form[to_form(x.seq[i]) for i in 2:length(x.seq)] : Form[x]

# An atom consisting only of `:` is not a symbol (keywords need a name).
_is_colon_atom(text::AbstractString) = !isempty(text) && all(c -> c == ':', text)
_is_quote_atom(text::AbstractString) = text == "'"

# A `.`-suffix key is held data: a bare `a` becomes the keyword `:a`, so
# `f.a` is `(get f :a)` even when a variable `a` is bound. `~e` is the escape
# hatch — `f.~a` evaluates `a` (through the ordinary `preval` rule) and uses its
# value as the key. A numeric suffix indexes a sequence and a written keyword
# (`f.:a`) is kept as written.
function _dot_key(text::AbstractString, pos::Int)
    if startswith(text, "~") && length(text) > 1
        return _mk_preval(_parse_atom(text[2:end], pos))
    end
    (_looks_numeric(text) || startswith(text, ":")) && return _parse_atom(text, pos)
    return Form(Symbol(":" * text))
end

# An inline atom like `f.key` or `f.a.b`.
function _parse_dotted(text::AbstractString, pos::Int)
    parts = split(text, ".")
    head = parts[1]
    isempty(head) && throw(AirParseError("unexpected '.': $text", pos))
    keys = Form[_dot_key(p, pos) for p in parts[2:end]]
    return _mk_get(_parse_atom(head, pos), keys)
end

# A leading-dot atom is an absolute namespace path: `.air.string-join` reads as
# `(get . :air :string-join)`. Each segment is a literal name (a held keyword, as
# with the `.` accessor), so a variable cannot alter the path.
function _parse_ns_path(text::AbstractString, pos::Int)
    rest = text[2:end]
    isempty(rest) && return Form(DOT_ROOT)
    parts = split(rest, ".")
    for p in parts
        (isempty(p) || _looks_numeric(p) || startswith(p, ":")) &&
            throw(AirParseError("invalid namespace path: $text", pos))
    end
    keys = Form[Form(Symbol(":" * p)) for p in parts]
    return _mk_get(Form(DOT_ROOT), keys)
end

# A postfix atom (`.key…`, `...`) applied to the form before it.
function _postfix_apply(text::AbstractString, form::Form, pos::Int)
    text == "..." && return _mk_splat(form)
    keys = Form[_dot_key(p, pos) for p in split(text[2:end], ".")]
    return _mk_get(form, keys)
end

# ---- parsing -----------------------------------------------------------------

mutable struct _Frame
    seq::Vector{Any}
    map::Vector{Pair{Symbol,Any}}
    alt::Bool        # a `|` occurred directly in this frame
    last_stop::Int   # source end of the last element/token in this frame
    last_map::Bool   # the last element read in this frame was a map entry
    start::Int       # source position of the opening `(`
end

mutable struct _Parser
    toks::Vector{_Token}
    i::Int
    last_stop::Int   # source end of the last token consumed
    # The source span `(start, stop)` of every container parsed, used to report
    # the position of a definition and of the form being evaluated.
    spans::Dict{Form,Tuple{Int,Int}}
end

_Parser(toks::Vector{_Token}, i::Int) = _Parser(toks, i, 0, Dict{Form,Tuple{Int,Int}}())

function _record_span!(p::_Parser, f::Form, start::Int, stop::Int)
    stop >= start && (p.spans[f] = (start, stop))
    return f
end

# Whether the next token begins a form (so `:`/`~` can consume it).
_next_is_form(p::_Parser) =
    p.i <= length(p.toks) && p.toks[p.i].kind in (:lparen, :string, :atom)

# `:(…)` is a held-form spelling mistake; a lone `:` followed by a space is the
# wildcard symbol. `p.i` names the token after the colon run.
function _colon_form_error(p::_Parser, t::_Token)
    _is_colon_atom(t.text) || return false
    p.i <= length(p.toks) || return false
    nx = p.toks[p.i]
    t.text != ":" && return nx.kind in (:lparen, :string, :atom)
    return nx.kind == :lparen && nx.pos == t.stop + 1
end

# A bare `'` whose character sits at `qpos`. Attached atoms (`'a`, `'5`) never
# reach here — the tokenizer keeps them together and `_parse_atom` handles them.
# Here the quote can only be followed by a string (`'"hi"`, adjacent) or a form;
# `'(…)` is rejected in favor of the canonical `(' …)` spelling. A `'` with a
# space after it is the ordinary symbol.
function _parse_quote(p::_Parser, qpos::Int)::Form
    if p.i <= length(p.toks)
        nx = p.toks[p.i]
        adjacent = nx.pos == qpos + 1
        if adjacent && nx.kind == :string
            p.i += 1
            return _mk_hold(_token_form(nx))
        elseif adjacent && nx.kind == :lparen
            throw(AirParseError("a held form is written (' …), not '(…)", qpos))
        end
    end
    return Form(Symbol("'"))
end

# Apply any run of *adjacent* postfix `.`-atoms to `form`. A whitespace-separated
# leading-dot atom begins a new namespace reference instead, so `(using .air …)`
# is a path while `(test=10).:test` is a lookup.
function _apply_postfix(p::_Parser, form::Form)
    while p.i <= length(p.toks)
        t = p.toks[p.i]
        adjacent = t.pos == p.last_stop + 1
        (t.kind == :atom && _is_postfix_dot(t.text) &&
         (t.text == "..." || adjacent)) || break
        p.i += 1
        form = _postfix_apply(t.text, form, t.pos)
        p.last_stop = t.stop
    end
    return form
end

# Parse one primary form — a container, atom, or string — without any postfix
# accessor or splice. `_parse_top` and `_parse_preval_operand` add those.
function _parse_primary(p::_Parser)::Form
    t = p.toks[p.i]
    if t.kind == :lparen
        return _parse_container(p)
    elseif t.kind == :atom
        p.i += 1
        if _is_quote_atom(t.text)
            a = _parse_quote(p, t.pos)
            p.last_stop = t.stop
            return a
        elseif _colon_form_error(p, t)
            throw(AirParseError("a held form is written (' …), not :(…)", t.pos))
        elseif t.text == "~" && _next_is_form(p)
            # The operand owns `.key` accessors, but a trailing `...` belongs to
            # the hole: `~(list 1 2)...` splices the hole's value into the
            # enclosing sequence. Leave `last_stop` at the operand so the caller
            # can apply that splice.
            return _mk_preval(_parse_preval_operand(p))
        else
            a = _parse_atom(t.text, t.pos)
            p.last_stop = t.stop
            return a
        end
    elseif t.kind == :string
        p.i += 1
        p.last_stop = t.stop
        return _token_form(t)
    else
        throw(AirParseError("unexpected '$(t.text)'", t.pos))
    end
end

# The operand of a standalone `~`: a primary form plus any adjacent `.key`
# accessors, stopping before a `...` so the splice applies to the entire hole
# rather than to its operand (`(f ~(g x)...)` is `(f (... (preval (g x))))`).
function _parse_preval_operand(p::_Parser)::Form
    form = _parse_primary(p)
    while p.i <= length(p.toks)
        t = p.toks[p.i]
        (t.kind == :atom && t.text != "..." && _is_postfix_dot(t.text) &&
         t.pos == p.last_stop + 1) || break
        p.i += 1
        form = _postfix_apply(t.text, form, t.pos)
        p.last_stop = t.stop
    end
    return form
end

function _parse_top(p::_Parser)::Form
    return _apply_postfix(p, _parse_primary(p))
end

function _finish_frame(f::_Frame)::Form
    # `(a |b)` is the alternative itself, not a one-element form around it: when
    # a pipe run covers the whole container, the container *is* `(alt a b)`.
    # A container without a pipe, or with a map alongside, keeps its parens.
    if f.alt && isempty(f.map) && length(f.seq) == 1
        v = to_form(f.seq[1])
        _is_alt(v) && return v
    end
    isempty(f.seq) && isempty(f.map) && return naught
    seq = PVector{Any}(f.seq)
    map = isempty(f.map) ? PDict{Symbol,Any}() : PDict{Symbol,Any}(f.map...)
    return Form(seq, map)
end

# One element to the right of a `|`. It must be an ordinary sequence element, not
# a map entry, a closing `)`, or another `|`.
function _parse_alt_operand(p::_Parser, pipe::_Token)::Form
    p.i > length(p.toks) &&
        throw(AirParseError("'|' needs an element on its right", pipe.pos))
    t = p.toks[p.i]
    (t.kind == :rparen || t.kind == :pipe) &&
        throw(AirParseError("'|' needs an element on its right", pipe.pos))
    if t.kind == :atom &&
       (t.text == "=" ||
        (occursin('=', t.text) && !(Symbol(t.text) in EQ_SYMBOLS) &&
         _split_kv(t.text) !== nothing))
        throw(AirParseError("'|' cannot be followed by a map entry", t.pos))
    end
    p.last_stop = pipe.stop
    return _parse_top(p)
end

function _parse_container(p::_Parser)::Form
    opening = p.toks[p.i]
    stack = _Frame[_Frame(Any[], Pair{Symbol,Any}[], false, opening.stop, false, opening.pos)]
    p.i += 1
    while !isempty(stack)
        p.i > length(p.toks) && throw(AirParseError("unterminated form", opening.pos))
        t = p.toks[p.i]
        if t.kind == :lparen
            push!(stack, _Frame(Any[], Pair{Symbol,Any}[], false, t.stop, false, t.pos))
            p.i += 1
        elseif t.kind == :rparen
            p.i += 1
            top = pop!(stack)
            f = _finish_frame(top)
            # `naught` is a shared singleton: recording a span under it would
            # associate a position with every `()` and `naught` in the program.
            f === naught || _record_span!(p, f, top.start, t.stop)
            if isempty(stack)
                p.last_stop = t.stop
                return f
            end
            parent = stack[end]
            push!(parent.seq, f)
            parent.last_stop = t.stop
            parent.last_map = false
        elseif t.kind == :pipe
            p.i += 1
            frame = stack[end]
            isempty(frame.seq) &&
                throw(AirParseError("'|' needs an element on its left", t.pos))
            frame.last_map &&
                throw(AirParseError("'|' cannot follow a map entry", t.pos))
            left = to_form(pop!(frame.seq))
            right = _parse_alt_operand(p, t)
            alt = _mk_alt(left, right)
            _record_span!(p, alt, t.pos, p.last_stop)
            push!(frame.seq, alt)
            frame.alt = true
            frame.last_stop = p.last_stop
        elseif t.kind == :atom
            p.i += 1
            frame = stack[end]
            n_map = length(frame.map)
            if _is_postfix_dot(t.text)
                adjacent = t.pos == frame.last_stop + 1
                if t.text == "..." || (!isempty(frame.seq) && adjacent)
                    isempty(frame.seq) &&
                        throw(AirParseError("unexpected '$(t.text)'", t.pos))
                    frame.seq[end] =
                        _postfix_apply(t.text, to_form(frame.seq[end]), t.pos)
                else
                    # A whitespace-separated leading-dot atom is a namespace
                    # reference, not a postfix accessor.
                    push!(frame.seq, _parse_atom(t.text, t.pos))
                end
            elseif _is_quote_atom(t.text)
                push!(frame.seq, _parse_quote(p, t.pos))
            elseif _colon_form_error(p, t)
                throw(AirParseError("a held form is written (' …), not :(…)", t.pos))
            elseif t.text == "~" && _next_is_form(p)
                push!(frame.seq, _mk_preval(_parse_preval_operand(p)))
            else
                _handle_atom!(p, frame, t)
            end
            frame.last_map = length(frame.map) > n_map
            frame.last_stop = p.toks[p.i - 1].stop
        elseif t.kind == :string
            p.i += 1
            push!(stack[end].seq, _token_form(t))
            stack[end].last_stop = t.stop
            stack[end].last_map = false
        else
            throw(AirParseError("unexpected '$(t.text)'", t.pos))
        end
    end
    throw(AirParseError("unterminated form", opening.pos))
end

# The map key denoted by the form that precedes `=`. A symbol is a key (a bare
# symbol becomes a keyword). `~expr` — parsed as a `preval` hole — is a computed
# key, stored as the symbol `:~<printed expr>` and resolved when the form is
# reduced (see `_dynamic_key`).
function _key_symbol(x::Form)::Union{Symbol,Nothing}
    if x isa FormScalar
        s = value(x)
        s isa Symbol || return nothing
        return is_keyword(s) ? s : Symbol(":" * String(s))
    elseif head_symbol(x) === PREVAL && length(x.seq) == 2 && isempty(x.map)
        return Symbol(":" * "~" * air_string(to_form(x.seq[2])))
    end
    return nothing
end

function _handle_atom!(p::_Parser, frame::_Frame, t::_Token)
    # `=`, `=value`, or `= value` is a key/value separator: `(a = b)` and
    # `(a =b)` both read as `(a=b)`. A `~expr` element before it is a computed
    # key: `(f ~(keyword (name ?x))=10)`.
    if t.text == "=" ||
       (startswith(t.text, "=") && length(t.text) > 1 &&
        !(Symbol(t.text) in EQ_SYMBOLS))
        isempty(frame.seq) && throw(AirParseError("unexpected '='", t.pos))
        key = _key_symbol(to_form(pop!(frame.seq)))
        key === nothing && throw(AirParseError("'=' needs a symbol key", t.pos))
        val = if t.text == "="
            _parse_top(p)
        else
            rest = t.text[2:end]
            if rest == "'"
                _parse_quote(p, t.pos + length(t.text) - 1)
            elseif rest == "~" && _next_is_form(p)
                _mk_preval(_parse_preval_operand(p))
            else
                _parse_atom(rest, t.pos)
            end
        end
        push!(frame.map, key => _store_form(val))
        return nothing
    end
    kv = _split_kv(t.text)
    if kv === nothing
        push!(frame.seq, _parse_atom(t.text, t.pos))
    else
        key, rest = kv
        if isempty(rest)
            push!(frame.map, Symbol(":" * key) => _parse_top(p))
        else
            val = if rest == "'"
                _parse_quote(p, t.pos + length(t.text) - 1)
            elseif rest == "~" && _next_is_form(p)
                # `key=~(expr)` is a `preval` hole in the map value, exactly as
                # `key=~name` is: the value is evaluated before any hold sees it.
                _mk_preval(_parse_preval_operand(p))
            else
                _parse_atom(rest, t.pos)
            end
            push!(frame.map, Symbol(":" * key) => val)
        end
    end
    return nothing
end

# Split `key=value` at the first `=`, but only when the key is plausible (starts
# with a letter, `_`, `:`, `?`, `~`, `!`, `$`, or `@`). The four operator symbols
# that may contain `=` (`==`, `!=`, `===`, `!==`) are never split, so they stay
# whole. `$` and `@` are ordinary symbols, so `(let ($=1) $)` and `(@=1)` bind
# them like any other name.
function _split_kv(text::String)
    Symbol(text) in EQ_SYMBOLS && return nothing
    # `:=` is the revision instruction of the RETE rule DSL, not a map entry.
    text == ":=" && return nothing
    i = findfirst('=', text)
    i === nothing && return nothing
    key = text[1:(i - 1)]
    rest = text[(i + 1):end]
    isempty(key) && return nothing
    c = key[1]
    (isletter(c) || c == '_' || c == ':' || c == '?' || c == '~' || c == '!' ||
     c == '$' || c == '@') || return nothing
    return key, rest
end

# ---- public reader -----------------------------------------------------------

"""
    read_all_air(s) -> Vector{Form}

Every form in the source `s`.
"""
function read_all_air(s::AbstractString)
    p = _Parser(_tokenize(s), 1)
    forms = Form[]
    while p.i <= length(p.toks)
        push!(forms, _parse_top(p))
    end
    return forms
end

"""
    read_all_air_spans(s) -> (Vector{Form}, Dict{Form,Tuple{Int,Int}})

Every form in the source `s`, together with the character span `(start, stop)`
of every container parsed. `start` is the position of the opening `(` (or `|`)
and `stop` the closing `)`; positions index `collect(s)`. A parser error carries
the same position as `read_all_air`'s.
"""
function read_all_air_spans(s::AbstractString)
    p = _Parser(_tokenize(s), 1)
    forms = Form[]
    while p.i <= length(p.toks)
        push!(forms, _parse_top(p))
    end
    return forms, p.spans
end

"""
    read_air(s) -> Form

The single form in the source `s`. Raises `AirParseError` if there is not
exactly one.
"""
function read_air(s::AbstractString)
    forms = read_all_air(s)
    isempty(forms) && throw(AirParseError("no form found", 1))
    length(forms) == 1 ||
        throw(AirParseError("expected one form, found $(length(forms))", 1))
    return forms[1]
end
