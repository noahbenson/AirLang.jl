################################################################################
# formats/yaml.jl
#
# A safe YAML reader and writer for plain air data. The reader covers the
# practical subset a configuration file uses: block and flow collections, plain
# and quoted scalars, block scalars (`|` and `>`), comments, anchors and
# aliases with expansion limits, merge keys, and multi-document streams.
#
# It constructs data only. A tag is never instantiated — the core tags
# (`!!str`, `!!int`, …) are understood, and anything else is an error — so a
# YAML file cannot execute code through this reader.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _YAML_MAX_DEPTH = 256
const _YAML_MAX_NODES = 1_000_000

struct _YEmptyNode end
const _Y_EMPTY = _YEmptyNode()

mutable struct _YamlParser
    lines::Vector{String}
    i::Int
    anchors::Dict{String,Any}
    sizes::Dict{String,Int}
    nodes::Int
    depth::Int
end

_yaml_error(p::_YamlParser, msg::AbstractString) =
    throw(AirEvalError("invalid YAML at line $(p.i): $msg"))

function _y_node!(p::_YamlParser, n::Integer = 1)
    p.nodes += n
    p.nodes > _YAML_MAX_NODES && throw(AirEvalError(
        "invalid YAML: the document is too large " *
        "(more than $(_YAML_MAX_NODES) nodes)"))
    return nothing
end

# ---- lines -------------------------------------------------------------------

function _y_blank_or_comment(l::AbstractString)
    t = lstrip(l, [' ', '\t'])
    return isempty(t) || startswith(t, "#")
end

function _y_indent_of(p::_YamlParser, l::AbstractString)
    n = 0
    for c in l
        if c == ' '
            n += 1
        elseif c == '\t'
            _yaml_error(p, "a tab in indentation")
        else
            break
        end
    end
    return n
end

function _y_skip!(p::_YamlParser)
    while p.i <= length(p.lines) && _y_blank_or_comment(p.lines[p.i])
        p.i += 1
    end
    return nothing
end

_y_is_doc_start(l::AbstractString) =
    startswith(l, "---") &&
    (ncodeunits(l) == 3 || l[4] == ' ' || l[4] == '\t')

_y_is_doc_end(l::AbstractString) =
    startswith(l, "...") &&
    (ncodeunits(l) == 3 || l[4] == ' ' || l[4] == '\t')

_y_is_seq_item(s::AbstractString) =
    startswith(s, "-") && (length(s) == 1 || s[2] in (' ', '\t'))

# ---- document splitting ------------------------------------------------------

# The text of each document in a stream. `---` starts one and `...` ends one;
# directives are ignored.
function _yaml_documents(text::AbstractString)
    raw = split(replace(String(text), "\r\n" => "\n", "\r" => "\n"), '\n')
    docs = String[]
    cur = String[]
    started = false
    for l in raw
        if !started && startswith(l, "%")
            continue
        elseif _y_is_doc_start(l)
            rest = lstrip(l[4:end])
            if started || any(x -> !_y_blank_or_comment(x), cur)
                push!(docs, join(cur, "\n"))
                empty!(cur)
            end
            started = true
            (isempty(rest) || startswith(rest, "#")) || push!(cur, rest)
        elseif _y_is_doc_end(l)
            rest = strip(l[4:end])
            (isempty(rest) || startswith(rest, "#")) ||
                throw(AirEvalError("invalid YAML: content after a document end marker"))
            push!(docs, join(cur, "\n"))
            empty!(cur)
            started = false
        else
            push!(cur, l)
        end
    end
    if started || any(x -> !_y_blank_or_comment(x), cur)
        push!(docs, join(cur, "\n"))
    end
    return docs
end

# ---- entry points ------------------------------------------------------------

"""
    _yaml_decode(text; documents=false) -> Form

Parse a YAML stream into air data. With `documents=true` the result is a
sequence of documents; otherwise the stream must hold one document (an empty
stream is `naught`).
"""
function _yaml_decode(text::AbstractString; documents::Bool = false)
    texts = _yaml_documents(text)
    if !documents
        length(texts) <= 1 || throw(AirEvalError(
            "invalid YAML: the stream has $(length(texts)) documents; " *
            "pass documents=true to decode them all"))
        isempty(texts) && return naught
        return _data_to_form(_yaml_parse_document(texts[1]); who = "yaml")
    end
    isempty(texts) && return naught
    return _seq_form(Form[_data_to_form(_yaml_parse_document(t); who = "yaml")
                           for t in texts])
end

function _yaml_parse_document(text::AbstractString)
    ls = split(text, '\n')
    # The split of a newline-terminated text has a trailing empty element that
    # is not a line of its own; dropping it keeps block-scalar chomping exact.
    endswith(text, "\n") && !isempty(ls) && pop!(ls)
    p = _YamlParser(ls, 1, Dict{String,Any}(), Dict{String,Int}(), 0, 0)
    _y_skip!(p)
    p.i > length(p.lines) && return nothing
    ind = _y_indent_of(p, p.lines[p.i])
    v = _y_block!(p, ind)
    _y_skip!(p)
    p.i <= length(p.lines) &&
        _yaml_error(p, "unexpected content after the document")
    return v === _Y_EMPTY ? nothing : v
end

# ---- block structure ---------------------------------------------------------

function _y_block!(p::_YamlParser, indent::Int)
    p.depth += 1
    p.depth > _YAML_MAX_DEPTH &&
        throw(AirEvalError("invalid YAML: the document is nested too deeply"))
    try
        _y_skip!(p)
        p.i > length(p.lines) && return _Y_EMPTY
        l = p.lines[p.i]
        ind = _y_indent_of(p, l)
        ind < indent && return _Y_EMPTY
        ind > indent && _yaml_error(p, "unexpected indentation")
        body = l[(ind + 1):end]
        _y_is_seq_item(body) && return _y_seq!(p, ind)
        _y_map_key_split(body) !== nothing && return _y_map!(p, ind)
        p.lines[p.i] = ""
        return _y_inline!(p, body, ind)
    finally
        p.depth -= 1
    end
end

# The value of a key (or of an empty sequence item) whose remainder is empty:
# a block on the following lines, a same-indent sequence (a mapping value only),
# or null.
function _y_block_value!(p::_YamlParser, base_indent::Int, same_seq::Bool)
    _y_skip!(p)
    p.i > length(p.lines) && return nothing
    l = p.lines[p.i]
    ind = _y_indent_of(p, l)
    body = l[(ind + 1):end]
    if ind > base_indent
        v = _y_block!(p, ind)
        return v === _Y_EMPTY ? nothing : v
    elseif same_seq && ind == base_indent && _y_is_seq_item(body)
        return _y_seq!(p, ind)
    end
    return nothing
end

function _y_seq!(p::_YamlParser, indent::Int)
    out = Any[]
    _y_node!(p)
    while true
        _y_skip!(p)
        p.i > length(p.lines) && break
        l = p.lines[p.i]
        ind = _y_indent_of(p, l)
        ind < indent && break
        ind > indent && _yaml_error(p, "unexpected indentation in a sequence")
        body = l[(ind + 1):end]
        _y_is_seq_item(body) || break
        cs = collect(body)
        k = 2
        while k <= length(cs) && cs[k] in (' ', '\t')
            k += 1
        end
        rest = k <= length(cs) ? String(cs[k:end]) : ""
        startswith(rest, "#") && (rest = "")
        if isempty(rest)
            p.i += 1
            push!(out, _y_block_value!(p, ind, false))
        else
            content_indent = ind + (k - 1)
            p.lines[p.i] = repeat(" ", content_indent) * rest
            v = _y_block!(p, content_indent)
            push!(out, v === _Y_EMPTY ? nothing : v)
        end
    end
    return out
end

function _y_map!(p::_YamlParser, indent::Int)
    entries = Dict{String,Any}()
    merges = Any[]
    _y_node!(p)
    while true
        _y_skip!(p)
        p.i > length(p.lines) && break
        l = p.lines[p.i]
        ind = _y_indent_of(p, l)
        ind < indent && break
        ind > indent && _yaml_error(p, "unexpected indentation in a mapping")
        kv = _y_map_key_split(l[(ind + 1):end])
        kv === nothing && _yaml_error(p, "expected a mapping entry")
        key, rest = kv
        line = p.i
        p.i += 1
        v = isempty(rest) ? _y_block_value!(p, ind, true) : _y_inline!(p, rest, ind)
        if key == "<<"
            push!(merges, v)
        elseif haskey(entries, key)
            throw(AirEvalError("invalid YAML at line $line: duplicate key " *
                               repr(key)))
        else
            entries[key] = v
        end
    end
    # Merge keys supply defaults; an explicit entry always wins, and an earlier
    # source wins over a later one.
    out = Dict{String,Any}()
    for src in merges
        for m in (src isa AbstractVector ? src : Any[src])
            m isa AbstractDict ||
                _yaml_error(p, "the merge key needs a mapping or a list of mappings")
            for (k, v) in m
                haskey(out, k) || (out[k] = v)
            end
        end
    end
    for (k, v) in entries
        out[k] = v
    end
    return out
end

# Split `key: rest` from a line body. A plain key ends at the first ':' that is
# followed by whitespace or the end of the line; a quoted key is read as a
# scalar. `nothing` when the line is not a mapping entry.
function _y_map_key_split(s::AbstractString)
    cs = collect(s)
    isempty(cs) && return nothing
    c = cs[1]
    if c == '"' || c == '\''
        r = _y_quoted_at(cs, 1)
        r === nothing && return nothing
        val, j = r
        while j <= length(cs) && cs[j] in (' ', '\t')
            j += 1
        end
        (j <= length(cs) && cs[j] == ':') || return nothing
        rest = j < length(cs) ? String(cs[(j + 1):end]) : ""
        return (String(val), lstrip(rest))
    end
    c in ('[', '{', '&', '*', '!', '|', '>', '#', '?') && return nothing
    if c == '-'
        (length(cs) == 1 || cs[2] in (' ', '\t')) && return nothing
    end
    for i in 1:length(cs)
        if cs[i] == '#' && (i == 1 || cs[i - 1] in (' ', '\t'))
            return nothing
        elseif cs[i] == ':' && (i == length(cs) || cs[i + 1] in (' ', '\t'))
            key = rstrip(String(cs[1:(i - 1)]))
            isempty(key) && return nothing
            return (key, i < length(cs) ? lstrip(String(cs[(i + 1):end])) : "")
        end
    end
    return nothing
end

# ---- inline values -----------------------------------------------------------

function _y_inline!(p::_YamlParser, s::AbstractString, base_indent::Int)
    p.depth += 1
    p.depth > _YAML_MAX_DEPTH &&
        throw(AirEvalError("invalid YAML: the document is nested too deeply"))
    try
        t = lstrip(s)
        anchor = nothing
        tag = nothing
        while true
            if startswith(t, "&")
                name, t = _y_token(t[2:end])
                isempty(name) && _yaml_error(p, "an anchor needs a name")
                anchor = name
                t = lstrip(t)
            elseif startswith(t, "!")
                tag, t = _y_token(t)
                t = lstrip(t)
            else
                break
            end
        end
        start = p.nodes
        if startswith(t, "*")
            name, tail = _y_token(t[2:end])
            isempty(name) && _yaml_error(p, "an alias needs a name")
            isempty(_y_strip_comment(tail)) ||
                _yaml_error(p, "an alias must stand alone")
            haskey(p.anchors, name) || _yaml_error(p, "unknown alias *$name")
            v = p.anchors[name]
            _y_node!(p, get(p.sizes, name, 1))
            tag === nothing || _yaml_error(p, "a tagged alias is not supported")
            size = p.nodes - start
        else
            v = _y_inline_value!(p, t, base_indent, tag)
            size = p.nodes - start
        end
        anchor === nothing || _y_anchor!(p, anchor, v, size)
        return v
    finally
        p.depth -= 1
    end
end

function _y_anchor!(p::_YamlParser, name::AbstractString, v, size::Int)
    p.anchors[String(name)] = v
    p.sizes[String(name)] = size
    return v
end

# The name part of a `&anchor`, `*alias`, or `!tag` token.
function _y_token(s::AbstractString)
    cs = collect(s)
    i = 1
    while i <= length(cs) && !(cs[i] in (' ', '\t', ',', ']', '}', ':'))
        i += 1
    end
    return String(cs[1:(i - 1)]), String(cs[i:end])
end

function _y_inline_value!(p::_YamlParser, t::AbstractString, base_indent::Int,
                          tag)
    s = lstrip(t)
    if isempty(s)
        v = _y_block_value!(p, base_indent, false)
        tag === nothing || (v = _y_apply_tag!(p, tag, v))
        return v
    end
    c = s[1]
    if c == '|' || c == '>'
        tag === nothing || _yaml_error(p, "a tagged block scalar is not supported")
        return _y_block_scalar!(p, s, base_indent)
    elseif c == '[' || c == '{'
        tag === nothing || _yaml_error(p, "a tagged flow collection is not supported")
        return _y_flow!(p, s)
    elseif c == '"' || c == '\''
        r = _y_quoted_at(collect(s), 1)
        r === nothing && _yaml_error(p, "a malformed quoted scalar")
        v, j = r
        cs = collect(s)
        tail = _y_strip_comment(String(cs[j:end]))
        isempty(tail) || _yaml_error(p, "unexpected content after a quoted scalar")
        _y_node!(p)
        return tag === nothing ? v : _y_apply_tag!(p, tag, v)
    end
    raw = _y_strip_comment(s)
    isempty(raw) && return nothing
    return _y_plain_value!(p, raw, tag)
end

# Drop a trailing comment: a '#' at the start or after whitespace.
function _y_strip_comment(s::AbstractString)
    cs = collect(s)
    for i in 1:length(cs)
        if cs[i] == '#' && (i == 1 || cs[i - 1] in (' ', '\t'))
            return rstrip(String(cs[1:(i - 1)]))
        end
    end
    return rstrip(String(cs))
end

function _y_quoted_at(cs::Vector{Char}, i::Int)
    q = cs[i]
    out = Char[]
    i += 1
    while i <= length(cs)
        c = cs[i]
        if q == '\''
            if c == '\''
                if i + 1 <= length(cs) && cs[i + 1] == '\''
                    push!(out, '\'')
                    i += 2
                else
                    return (String(out), i + 1)
                end
            else
                push!(out, c)
                i += 1
            end
        else
            if c == '"'
                return (String(out), i + 1)
            elseif c != '\\'
                push!(out, c)
                i += 1
            else
                i + 1 <= length(cs) || return nothing
                e = cs[i + 1]
                i += 2
                if e == 'n'
                    push!(out, '\n')
                elseif e == 't'
                    push!(out, '\t')
                elseif e == 'r'
                    push!(out, '\r')
                elseif e == '0'
                    push!(out, '\0')
                elseif e == 'b'
                    push!(out, '\b')
                elseif e == 'f'
                    push!(out, '\f')
                elseif e == 'a'
                    push!(out, '\a')
                elseif e == 'v'
                    push!(out, '\v')
                elseif e == 'e'
                    push!(out, '\e')
                elseif e == '"'
                    push!(out, '"')
                elseif e == '\\'
                    push!(out, '\\')
                elseif e == '/'
                    push!(out, '/')
                elseif e == ' '
                    push!(out, ' ')
                elseif e == 'N'
                    push!(out, '')
                elseif e == '_'
                    push!(out, ' ')
                elseif e == 'L'
                    push!(out, ' ')
                elseif e == 'P'
                    push!(out, ' ')
                elseif e == 'x' || e == 'u' || e == 'U'
                    n = e == 'x' ? 2 : e == 'u' ? 4 : 8
                    i + n - 1 <= length(cs) || return nothing
                    cp = 0
                    for _ in 1:n
                        d = cs[i]
                        i += 1
                        h = '0' <= d <= '9' ? Int(d - '0') :
                            'a' <= d <= 'f' ? Int(d - 'a' + 10) :
                            'A' <= d <= 'F' ? Int(d - 'A' + 10) : return nothing
                        cp = (cp << 4) | h
                    end
                    (cp <= 0x10ffff && !(0xd800 <= cp <= 0xdfff)) || return nothing
                    push!(out, Char(cp))
                else
                    return nothing
                end
            end
        end
    end
    return nothing
end

# ---- plain scalars -----------------------------------------------------------

"""
    _yaml_plain(s) -> Any

Resolve a plain scalar with the YAML 1.2 core schema. Null-like words are
`nothing`, `true`/`false` (any case of the initial letter) are Booleans, and
integer and float spellings are numbers; everything else — including
`yes`/`no`/`on`/`off` and a date — stays a string.
"""
function _yaml_plain(s::AbstractString)
    t = String(s)
    (t == "" || t == "~" || t == "null" || t == "Null" || t == "NULL") &&
        return nothing
    (t == "true" || t == "True" || t == "TRUE") && return true
    (t == "false" || t == "False" || t == "FALSE") && return false
    if occursin(r"^[-+]?[0-9]+$", t)
        i = tryparse(Int64, t)
        return i === nothing ? parse(BigInt, t) : i
    elseif occursin(r"^[-+]?0[xX][0-9a-fA-F]+$", t)
        neg = startswith(t, "-")
        return (neg ? -1 : 1) * parse(BigInt, t[(neg || startswith(t, "+") ? 4 : 3):end];
                                      base = 16)
    elseif occursin(r"^[-+]?0[oO][0-7]+$", t)
        neg = startswith(t, "-")
        return (neg ? -1 : 1) * parse(BigInt, t[(neg || startswith(t, "+") ? 4 : 3):end];
                                      base = 8)
    end
    if occursin(r"^[-+]?([0-9]+\.[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$", t) ||
       occursin(r"^[-+]?[0-9]+[eE][-+]?[0-9]+$", t)
        return parse(Float64, t)
    elseif occursin(r"^[-+]?\.(inf|Inf|INF)$", t)
        return startswith(t, "-") ? -Inf : Inf
    elseif occursin(r"^\.(nan|NaN|NAN)$", t)
        return NaN
    end
    return t
end

function _y_plain_value!(p::_YamlParser, raw::AbstractString, tag)
    _y_node!(p)
    if tag === nothing
        return _yaml_plain(raw)
    end
    kind = _y_tag_kind(p, tag)
    if kind == "str"
        return String(raw)
    elseif kind == "int"
        v = _yaml_plain(raw)
        v isa Integer || _yaml_error(p, "!!int needs an integer value")
        return v
    elseif kind == "float"
        v = _yaml_plain(raw)
        v isa Real || _yaml_error(p, "!!float needs a number value")
        return Float64(v)
    elseif kind == "bool"
        v = _yaml_plain(raw)
        v isa Bool || _yaml_error(p, "!!bool needs a boolean value")
        return v
    elseif kind == "null"
        _yaml_plain(raw) === nothing || _yaml_error(p, "!!null needs an empty value")
        return nothing
    end
    _yaml_error(p, "the tag $tag cannot apply to a scalar")
end

const _YAML_CORE_TAGS = ("str", "int", "float", "bool", "null", "map", "seq")

function _y_tag_kind(p::_YamlParser, tag)
    t = String(tag)
    startswith(t, "!!") || _yaml_error(p, "unsupported tag $t")
    kind = t[3:end]
    kind in _YAML_CORE_TAGS || _yaml_error(p, "unsupported tag $t")
    return kind
end

function _y_apply_tag!(p::_YamlParser, tag, v)
    kind = _y_tag_kind(p, tag)
    if kind == "str"
        v isa AbstractString || _yaml_error(p, "!!str needs a string value")
        return String(v)
    elseif kind == "int"
        v isa Integer && return v
        v isa AbstractString || _yaml_error(p, "!!int needs an integer value")
        x = _yaml_plain(v)
        x isa Integer || _yaml_error(p, "!!int needs an integer value")
        return x
    elseif kind == "float"
        v isa Real && return Float64(v)
        v isa AbstractString || _yaml_error(p, "!!float needs a number value")
        x = _yaml_plain(v)
        x isa Real || _yaml_error(p, "!!float needs a number value")
        return Float64(x)
    elseif kind == "bool"
        v isa Bool && return v
        v isa AbstractString || _yaml_error(p, "!!bool needs a boolean value")
        x = _yaml_plain(v)
        x isa Bool || _yaml_error(p, "!!bool needs a boolean value")
        return x
    elseif kind == "null"
        v === nothing || _yaml_error(p, "!!null needs an empty value")
        return nothing
    elseif kind == "map"
        v isa AbstractDict || _yaml_error(p, "!!map needs a mapping value")
        return v
    elseif kind == "seq"
        v isa AbstractVector || _yaml_error(p, "!!seq needs a sequence value")
        return v
    end
    _yaml_error(p, "unsupported tag $tag")
end

# ---- block scalars -----------------------------------------------------------

function _y_block_scalar!(p::_YamlParser, t::AbstractString, base_indent::Int)
    cs = collect(t)
    style = cs[1]
    chomp = nothing
    digit = nothing
    i = 2
    while i <= length(cs)
        c = cs[i]
        if c == '+' || c == '-'
            chomp === nothing || _yaml_error(p, "a bad block-scalar header")
            chomp = c
        elseif '1' <= c <= '9'
            digit === nothing || _yaml_error(p, "a bad block-scalar header")
            digit = Int(c - '0')
        elseif c == '0'
            _yaml_error(p, "a block-scalar indentation indicator is 1–9")
        else
            break
        end
        i += 1
    end
    isempty(_y_strip_comment(String(cs[i:end]))) ||
        _yaml_error(p, "a bad block-scalar header $(repr(String(cs)))")
    lines = String[]
    content_indent = digit === nothing ? nothing : base_indent + digit
    while p.i <= length(p.lines)
        l = p.lines[p.i]
        if isempty(strip(l))
            push!(lines, "")
            p.i += 1
            continue
        end
        ind = _y_indent_of(p, l)
        ind <= base_indent && break
        content_indent === nothing && (content_indent = ind)
        ind >= content_indent ||
            _yaml_error(p, "an under-indented line in a block scalar")
        push!(lines, String(l[(content_indent + 1):end]))
        p.i += 1
    end
    _y_node!(p)
    isempty(lines) && return ""
    body = style == '|' ? join(lines, "\n") : _y_fold(lines)
    if chomp == '-'
        return rstrip(body, '\n')
    elseif chomp == '+'
        return body * "\n"
    end
    return isempty(rstrip(body, '\n')) ? "" : rstrip(body, '\n') * "\n"
end

# Folded-scalar line breaks: a break between two ordinary lines is a space; a
# break next to a blank or more-indented line is kept.
function _y_fold(lines::Vector{String})
    io = IOBuffer()
    printed = false
    prev_indented = false
    pending = 0                 # line breaks seen since the last content line
    for l in lines
        if isempty(l)
            pending += 1
            continue
        end
        indented = startswith(l, " ") || startswith(l, "\t")
        if !printed
            print(io, "\n"^pending)
        elseif !indented && !prev_indented && pending == 0
            print(io, " ")
        elseif indented || prev_indented
            print(io, "\n"^(pending + 1))
        else
            print(io, "\n"^pending)
        end
        print(io, l)
        printed = true
        prev_indented = indented
        pending = 0
    end
    printed && print(io, "\n"^pending)
    return String(take!(io))
end

# ---- flow collections --------------------------------------------------------

function _y_flow_scan(s::AbstractString)
    depth = 0
    mx = 0
    q = nothing
    esc = false
    for c in s
        if q !== nothing
            if esc
                esc = false
            elseif q == '"' && c == '\\'
                esc = true
            elseif c == q
                q = nothing
            end
        elseif c == '"' || c == '\''
            q = c
        elseif c == '[' || c == '{'
            depth += 1
            mx = max(mx, depth)
        elseif c == ']' || c == '}'
            depth -= 1
        end
    end
    return (depth, mx)
end

# The bracket balance (0 when the collection is complete) and its maximum
# nesting depth.
_y_flow_balance(s::AbstractString) = _y_flow_scan(s)[1]
_y_flow_nesting(s::AbstractString) = _y_flow_scan(s)[2]

function _y_flow!(p::_YamlParser, t::AbstractString)
    buf = String(t)
    _y_flow_nesting(buf) > _YAML_MAX_DEPTH && throw(AirEvalError(
        "invalid YAML: the document is nested too deeply"))
    while _y_flow_balance(buf) > 0
        p.i > length(p.lines) && _yaml_error(p, "an unterminated flow collection")
        buf *= " " * p.lines[p.i]
        p.i += 1
        _y_flow_nesting(buf) > _YAML_MAX_DEPTH && throw(AirEvalError(
            "invalid YAML: the document is nested too deeply"))
    end
    f = _YFlowParser(collect(buf), 1, p)
    v = _y_flow_value!(f)
    _y_flow_ws!(f)
    f.i <= length(f.cs) && _yaml_error(p, "unexpected content after a flow collection")
    return v
end

mutable struct _YFlowParser
    cs::Vector{Char}
    i::Int
    p::_YamlParser
end

function _y_flow_ws!(f::_YFlowParser)
    while f.i <= length(f.cs) && f.cs[f.i] in (' ', '\t', '\n', '\r')
        f.i += 1
    end
    return nothing
end

function _y_flow_name!(f::_YFlowParser)
    start = f.i
    while f.i <= length(f.cs) && !(f.cs[f.i] in (' ', '\t', '\n', '\r',
                                                 ',', ']', '}', ':'))
        f.i += 1
    end
    return String(f.cs[start:(f.i - 1)])
end

function _y_flow_value!(f::_YFlowParser)
    _y_flow_ws!(f)
    f.i > length(f.cs) && _yaml_error(f.p, "expected a flow value")
    c = f.cs[f.i]
    if c == '['
        f.i += 1
        out = Any[]
        _y_node!(f.p)
        while true
            _y_flow_ws!(f)
            if f.i <= length(f.cs) && f.cs[f.i] == ']'
                f.i += 1
                break
            end
            push!(out, _y_flow_value!(f))
            _y_flow_ws!(f)
            if f.i <= length(f.cs) && f.cs[f.i] == ','
                f.i += 1
            elseif f.i <= length(f.cs) && f.cs[f.i] == ']'
                f.i += 1
                break
            else
                _yaml_error(f.p, "expected ',' or ']' in a flow sequence")
            end
        end
        return out
    elseif c == '{'
        f.i += 1
        out = Dict{String,Any}()
        merges = Any[]
        _y_node!(f.p)
        while true
            _y_flow_ws!(f)
            if f.i <= length(f.cs) && f.cs[f.i] == '}'
                f.i += 1
                break
            end
            k = _y_flow_value!(f)
            _y_flow_ws!(f)
            if f.i <= length(f.cs) && f.cs[f.i] == ':'
                f.i += 1
                v = _y_flow_value!(f)
            else
                v = nothing
            end
            kt = _data_key_text(k, "yaml")
            if kt == "<<"
                push!(merges, v)
            elseif haskey(out, kt)
                _yaml_error(f.p, "duplicate key $(repr(kt))")
            else
                out[kt] = v
            end
            _y_flow_ws!(f)
            if f.i <= length(f.cs) && f.cs[f.i] == ','
                f.i += 1
            elseif f.i <= length(f.cs) && f.cs[f.i] == '}'
                f.i += 1
                break
            else
                _yaml_error(f.p, "expected ',' or '}' in a flow mapping")
            end
        end
        isempty(merges) && return out
        merged = Dict{String,Any}()
        for src in merges
            for m in (src isa AbstractVector ? src : Any[src])
                m isa AbstractDict ||
                    _yaml_error(f.p, "the merge key needs a mapping or a list of mappings")
                for (k, v) in m
                    haskey(merged, k) || (merged[k] = v)
                end
            end
        end
        for (k, v) in out
            merged[k] = v
        end
        return merged
    elseif c == '"' || c == '\''
        r = _y_quoted_at(f.cs, f.i)
        r === nothing && _yaml_error(f.p, "a malformed quoted scalar")
        f.i = r[2]
        _y_node!(f.p)
        return r[1]
    elseif c == '&'
        f.i += 1
        name = _y_flow_name!(f)
        isempty(name) && _yaml_error(f.p, "an anchor needs a name")
        _y_flow_ws!(f)
        start = f.p.nodes
        v = _y_flow_value!(f)
        _y_anchor!(f.p, name, v, f.p.nodes - start)
        return v
    elseif c == '*'
        f.i += 1
        name = _y_flow_name!(f)
        isempty(name) && _yaml_error(f.p, "an alias needs a name")
        haskey(f.p.anchors, name) || _yaml_error(f.p, "unknown alias *$name")
        _y_node!(f.p, get(f.p.sizes, name, 1))
        return f.p.anchors[name]
    elseif c == '!'
        _yaml_error(f.p, "tags inside a flow collection are not supported")
    end
    start = f.i
    while f.i <= length(f.cs)
        ch = f.cs[f.i]
        (ch == ',' || ch == ']' || ch == '}') && break
        if ch == ':' && (f.i == length(f.cs) ||
                         f.cs[f.i + 1] in (' ', '\t', '\n', '\r', ',', ']', '}'))
            break
        end
        f.i += 1
    end
    raw = strip(String(f.cs[start:(f.i - 1)]))
    _y_node!(f.p)
    return _yaml_plain(raw)
end

# ---- writer ------------------------------------------------------------------

"""
    _yaml_encode(v) -> String

Encode air data as block-style YAML. Map keys are emitted in sorted order.
"""
function _yaml_encode(v::Form)
    io = IOBuffer()
    kind, x = _data_shape(v, "encode")
    if kind === :leaf
        print(io, _yaml_scalar_data(_leaf_data(x, "encode")...), "\n")
    elseif kind === :null
        print(io, "null\n")
    else
        _yaml_write!(io, v, 0, kind, x)
    end
    return String(take!(io))
end

function _yaml_write!(io::IO, v::Form, indent::Int, kind::Symbol, x)
    if kind === :object
        for (k, e) in _map_pairs(x)
            print(io, " "^indent, _yaml_key(k), ":")
            ek, ex = _data_shape(e, "encode")
            if ek === :leaf || ek === :null
                print(io, " ", ek === :null ? "null" :
                      _yaml_scalar_data(_leaf_data(ex, "encode")...), "\n")
            else
                print(io, "\n")
                _yaml_write!(io, e, indent + 2, ek, ex)
            end
        end
    elseif kind === :array
        for e in _seq_elems(x)
            ek, ex = _data_shape(e, "encode")
            if ek === :leaf || ek === :null
                print(io, " "^indent, "- ",
                      ek === :null ? "null" : _yaml_scalar_data(_leaf_data(ex, "encode")...),
                      "\n")
            else
                print(io, " "^indent, "-\n")
                _yaml_write!(io, e, indent + 2, ek, ex)
            end
        end
    elseif kind === :leaf
        print(io, " "^indent, _yaml_scalar_data(_leaf_data(x, "encode")...), "\n")
    else
        print(io, " "^indent, "null\n")
    end
    return nothing
end

function _yaml_scalar_data(kind::Symbol, x)
    kind === :null && return "null"
    kind === :bool && return x ? "true" : "false"
    kind === :int && return string(x)
    if kind === :float
        isnan(x) && return ".nan"
        isinf(x) && return x < 0 ? "-.inf" : ".inf"
        s = string(x)
        (occursin('.', s) || occursin('e', s) || occursin('E', s)) || (s *= ".0")
        return s
    end
    return _yaml_string(String(x))
end

function _yaml_plain_safe(s::AbstractString)
    isempty(s) && return false
    s == strip(s) || return false
    _yaml_plain(s) isa AbstractString || return false
    (s == "---" || s == "...") && return false
    s[1] in ('-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*', '!', '|',
             '>', '\'', '"', '%', '@', '`') && return false
    endswith(s, ":") && return false
    occursin(": ", s) && return false
    occursin(" #", s) && return false
    any(c -> c < ' ' || c == '\x7f', s) && return false
    return true
end

_yaml_string(s::AbstractString) =
    _yaml_plain_safe(s) ? String(s) : _yaml_quote(String(s))

function _yaml_quote(s::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\0'
            print(io, "\\0")
        elseif c < ' ' || c == '\x7f'
            print(io, "\\x", lpad(string(UInt8(c); base = 16), 2, '0'))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end

function _yaml_key(k::AbstractString)
    if !isempty(k) && !startswith(k, "-") && !startswith(k, ".") &&
       all(c -> isletter(c) || isdigit(c) || c in ('_', '-', '.'), k) &&
       _yaml_plain(k) isa AbstractString
        return String(k)
    end
    return _yaml_quote(String(k))
end
