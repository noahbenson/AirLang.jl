################################################################################
# agents_providers.jl
#
# The inference-server layer: how an agent's configuration becomes an HTTP
# request, and how the answer is parsed. Two dialects are spoken — Anthropic's
# Messages API and the OpenAI-compatible chat-completions API (Fireworks,
# OpenAI, DeepSeek, vLLM, Ollama, …).
#
# Nothing here is durable: an `_AgentConfig` is rebuilt from the agent's
# `$.config.agent` vals and the session's snapshot each time it is needed. The
# transport is `Downloads.request`; tests replace it through
# `_AGENT_HTTP_OVERRIDE`, which receives `(method, url, headers, body, timeout)`
# and returns `(status=Int, body=String)`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- configuration values ----------------------------------------------------

# A user's inference settings live in `$.config.agent`, so the namespace a user
# creates for themselves and an agent inherit from the same policy.
const _CONFIG_NS = Symbol("config")
const _AGENT_NS = Symbol("agent")

# The provider defaults: the dialect and base URL a provider implies.
const _AGENT_PROVIDERS = Dict{Symbol,NamedTuple}(
    :anthropic => (dialect = :anthropic,
                   base = "https://api.anthropic.com"),
    :openai => (dialect = :openai,
                base = "https://api.openai.com/v1"),
    :fireworks => (dialect = :openai,
                   base = "https://api.fireworks.ai/inference/v1"),
    :deepseek => (dialect = :openai,
                  base = "https://api.deepseek.com/v1"),
    :compatible => (dialect = :openai, base = nothing))

const _AGENT_DIALECTS = (:anthropic, :openai)

const _AGENT_DEFAULT_MAX_TOKENS = 4096
const _AGENT_DEFAULT_COMPACT_AT = 0.8
const _AGENT_DEFAULT_COMPACT_KEEP = 4
const _AGENT_DEFAULT_TIMEOUT = 120.0
const _AGENT_DEFAULT_RETRIES = 2
const _AGENT_SUMMARY_MAX_TOKENS = 1024

# A keyword or bare symbol as an uncolonized `Symbol`; `nothing` when not one.
function _agent_kw(x)
    x isa Form || return nothing
    s = _symbolof(x)
    return s === nothing ? nothing : _bindname(s)
end

# The same, but a string counts too: a keyword, symbol, or string from a form
# or from a decoded JSON body.
function _agent_symbol(x)
    k = _agent_kw(x)
    k === nothing || return k
    s = _agent_string(x)
    return s === nothing ? nothing : Symbol(s)
end

# The string a form holds, or `nothing`.
function _agent_string(x)
    x isa Form || return nothing
    l = _leafof(x)
    return l isa AbstractString ? String(l) : nothing
end

# A short excerpt of a response body, for an error message.
function _agent_truncate(s::AbstractString; limit::Int = 200)
    t = String(s)
    length(t) <= limit && return t
    return first(t, limit) * "…"
end

function _agent_number(x)
    x isa Form || return nothing
    l = _leafof(x)
    return l isa Real ? l : nothing
end

# The value of a val entry in a namespace path, or `nothing`.
function _agent_ns_val(env::Env, path::Vector{Symbol}, name::Symbol)
    ns = _ns_lookup(env, path)
    ns === nothing && return nothing
    m = _ns_map_get(env, ns, Symbol(":", String(name)); lazy = false)
    m === nothing && return nothing
    v = _ns_val_value(env, m; check = false)
    return v isa Form ? to_form(v) : nothing
end

# A field of a mapping form, or `nothing`.
function _agent_field(f::Form, name::Symbol)
    (f isa FormContainer && haskey(f, Symbol(":", String(name)))) || return nothing
    return to_form(f[Symbol(":", String(name))])
end

# ---- the resolved configuration ---------------------------------------------

"""
    _AgentConfig

The effective inference configuration for one call: the provider and dialect,
the endpoint, the model, the API key, the system prompt, and the request
settings. `api_key` is `nothing` until one is set.
"""
struct _AgentConfig
    provider::Symbol
    dialect::Symbol
    base_url::String
    model::Union{Nothing,String}
    api_key::Union{Nothing,String}
    system::String
    max_tokens::Int
    params::Form
    context::Union{Nothing,Int}
    compact_at::Float64
    compact_keep::Int
    timeout::Float64
    retries::Int
end

_agent_misconfigured(msg::AbstractString) =
    AirAgentError(Symbol("agent-misconfigured"), msg)

# Resolve the configuration of an agent, preferring the session's snapshot in
# `state` and falling back to `$.config.agent`. The API key always comes from
# the live configuration, so rotating it affects open sessions. The home
# namespace path is taken from the session when it records one, so a session
# opened in an attached database keeps resolving after a restart.
function _agent_cfg(env::Env, agent::Symbol, state::Form)
    home = _agent_field(state, :home)
    homepath = home === nothing ? nothing : _stored_path(home)
    homepath === nothing && (homepath = _user_home_path(env, agent))
    homepath === nothing &&
        throw(_agent_misconfigured("no such agent :$agent"))
    cfgpath = vcat(homepath, Symbol[_CONFIG_NS, _AGENT_NS])
    raw(name::Symbol) = _agent_ns_val(env, cfgpath, name)
    return _agent_cfg_resolve(state, raw)
end

# Resolve the effective configuration from a state snapshot, using `raw(name)`
# for any field the snapshot does not carry.
function _agent_cfg_resolve(state::Form, raw::Function)
    pick(name::Symbol) = begin
        v = _agent_field(state, name)
        v === nothing ? raw(name) : v
    end
    provider = _agent_symbol(pick(:provider))
    provider === nothing && (provider = :anthropic)
    haskey(_AGENT_PROVIDERS, provider) ||
        throw(_agent_misconfigured("unknown provider :$provider"))
    spec = _AGENT_PROVIDERS[provider]
    dialect = _agent_symbol(pick(:dialect))
    dialect === nothing && (dialect = spec.dialect)
    dialect in _AGENT_DIALECTS ||
        throw(_agent_misconfigured("unknown dialect :$dialect"))
    base = _agent_string(pick(Symbol("base-url")))
    base === nothing && (base = spec.base)
    base === nothing &&
        throw(_agent_misconfigured(
            "provider :$provider needs a base-url"))
    model = _agent_string(pick(:model))
    key = _agent_string(raw(Symbol("api-key")))
    system = _agent_string(pick(:system))
    system === nothing && (system = "")
    maxtok = _agent_int_opt(pick(Symbol("max-tokens")), Symbol("max-tokens"),
                            _AGENT_DEFAULT_MAX_TOKENS; min = 1)
    params = pick(:params)
    (params === nothing || _agent_naught(params)) && (params = naught)
    _agent_naught(params) || params isa FormContainer ||
        throw(_agent_misconfigured("params must be a mapping"))
    ctx = _agent_context_opt(pick(:context))
    compact_at = _agent_float_opt(pick(Symbol("compact-at")), Symbol("compact-at"),
                                  _AGENT_DEFAULT_COMPACT_AT; lo = 0.0, hi = 1.0)
    keep = _agent_int_opt(pick(Symbol("compact-keep")), Symbol("compact-keep"),
                          _AGENT_DEFAULT_COMPACT_KEEP; min = 1)
    timeout = _agent_float_opt(pick(:timeout), :timeout, _AGENT_DEFAULT_TIMEOUT;
                               lo = 0.0, hi = Inf)
    retries = _agent_int_opt(pick(:retries), :retries, _AGENT_DEFAULT_RETRIES;
                             min = 0)
    return _AgentConfig(provider, dialect, _agent_strip_slash(base), model, key,
                        system, maxtok, params, ctx, compact_at, keep, timeout,
                        retries)
end

_agent_strip_slash(s::AbstractString) = begin
    t = String(s)
    while endswith(t, "/")
        t = t[1:(end - 1)]
    end
    t
end

function _agent_int_opt(x, name::Symbol, default::Int; min::Int = typemin(Int))
    x === nothing && return default
    l = _agent_number(x)
    l isa Integer ||
        throw(_agent_misconfigured("$name must be an integer"))
    n = _as_int(l, "agent: $name")
    n >= min || throw(_agent_misconfigured("$name must be at least $min"))
    return n
end

function _agent_float_opt(x, name::Symbol, default::Float64; lo::Float64 = -Inf,
                          hi::Float64 = Inf)
    x === nothing && return default
    l = _agent_number(x)
    l === nothing && throw(_agent_misconfigured("$name must be a number"))
    f = Float64(l)
    (f >= lo && f <= hi) ||
        throw(_agent_misconfigured("$name is out of range: $f"))
    return f
end

# Whether a form is `naught` (the empty scalar or an empty container).
_agent_naught(x) = x isa FormScalar ? value(x) === nothing :
    (x isa FormContainer && isempty(x.seq) && isempty(x.map))

# `context=` is optional; `naught` means "no window is known".
function _agent_context_opt(x)
    x === nothing && return nothing
    _agent_naught(x) && return nothing
    l = _agent_number(x)
    l isa Integer && l > 0 ||
        throw(_agent_misconfigured("context must be a positive integer"))
    return _as_int(l, "agent: context")
end

_agent_model!(cfg::_AgentConfig) =
    cfg.model === nothing ?
        throw(_agent_misconfigured("no model is configured")) : cfg.model

_agent_key!(cfg::_AgentConfig) =
    cfg.api_key === nothing ?
        throw(_agent_misconfigured("no api-key is configured")) : cfg.api_key

# The session-snapshot fields of a config, as `key => value` pairs for a
# session's state mapping. The API key is deliberately absent: it is read from
# the live configuration on every call.
function _agent_snapshot_pairs(cfg::_AgentConfig)
    return Pair{Symbol,Form}[
        Symbol(":provider") => _keyword_form(cfg.provider),
        Symbol(":dialect") => _keyword_form(cfg.dialect),
        Symbol(":base-url") => Form(cfg.base_url),
        Symbol(":model") => (cfg.model === nothing ? naught : Form(cfg.model)),
        Symbol(":system") => Form(cfg.system),
        Symbol(":max-tokens") => Form(cfg.max_tokens),
        Symbol(":params") => cfg.params,
        Symbol(":context") => (cfg.context === nothing ? naught : Form(cfg.context)),
        Symbol(":compact-at") => Form(cfg.compact_at),
        Symbol(":compact-keep") => Form(cfg.compact_keep),
        Symbol(":timeout") => Form(cfg.timeout),
        Symbol(":retries") => Form(cfg.retries)]
end

# ---- messages ----------------------------------------------------------------

# Render a transcript entry as `(role, text)`.
_agent_entry_role(e::Form) = _agent_kw(_agent_field(e, :role))
_agent_entry_text(e::Form) = _agent_string(_agent_field(e, :text))

# Turn transcript entries into provider messages. A `:summary` entry folds into
# the system prompt; consecutive same-role entries are merged, and a leading
# assistant entry is dropped (both APIs expect the first turn to be the user's).
# Returns `(system, [(role, text), …])`.
function _agent_messages(system::AbstractString, entries)
    parts = String[]
    isempty(system) || push!(parts, system)
    msgs = Pair{Symbol,String}[]
    for e in entries
        role = _agent_entry_role(e)
        text = _agent_entry_text(e)
        text === nothing && continue
        if role === :summary
            push!(parts, text)
            continue
        end
        role in (:user, :assistant) || continue
        if !isempty(msgs) && msgs[end].first === role
            msgs[end] = role => msgs[end].second * "\n\n" * text
        else
            push!(msgs, role => text)
        end
    end
    while !isempty(msgs) && msgs[1].first === :assistant
        popfirst!(msgs)
    end
    return (join(parts, "\n\n"), msgs)
end

# ---- requests ----------------------------------------------------------------

# The endpoint for a dialect. The base URL is stored without a trailing slash,
# so the suffix is appended directly: an Anthropic base is the host and the
# suffix carries `/v1`, while an OpenAI-compatible base already ends in its
# version segment (or is a gateway path).
function _agent_anthropic_url(cfg)
    b = cfg.base_url
    endswith(b, "/v1/messages") && return b
    endswith(b, "/v1") && return b * "/messages"
    return b * "/v1/messages"
end

function _agent_openai_url(cfg)
    b = cfg.base_url
    endswith(b, "/chat/completions") && return b
    return b * "/chat/completions"
end

# A provider message map: `(role="user" content="…")`.
_agent_message_form(role::Symbol, text::AbstractString) =
    _ns_form(Form[], Pair{Symbol,Form}[Symbol(":role") => Form(String(role)),
                                       Symbol(":content") => Form(String(text))])

# A sequence of provider message maps.
function _agent_message_forms(msgs)
    return _ns_form(Form[_agent_message_form(r, t) for (r, t) in msgs])
end

# Merge the `params=` map into a body, refusing keys the dialect builds itself.
function _agent_merge_params!(pairs::Vector{Pair{Symbol,Form}}, cfg::_AgentConfig,
                              reserved)
    cfg.params isa FormContainer || return pairs
    for (k, v) in cfg.params.map
        k in reserved && continue
        i = findfirst(p -> p.first == k, pairs)
        i === nothing ? push!(pairs, k => to_form(v)) : (pairs[i] = k => to_form(v))
    end
    return pairs
end

const _ANTHROPIC_RESERVED =
    (Symbol(":model"), Symbol(":max_tokens"), Symbol(":messages"), Symbol(":system"))
const _OPENAI_RESERVED =
    (Symbol(":model"), Symbol(":messages"), Symbol(":max_tokens"),
     Symbol(":max_completion_tokens"))

"""
    _agent_request_form(cfg, system, messages, max_tokens) -> Form

The JSON body of a chat request, as a map form.
"""
function _agent_request_form(cfg::_AgentConfig, system::AbstractString,
                             messages, max_tokens::Integer)
    model = _agent_model!(cfg)
    if cfg.dialect === :anthropic
        pairs = Pair{Symbol,Form}[
            Symbol(":model") => Form(model),
            Symbol(":max_tokens") => Form(Int(max_tokens)),
            Symbol(":messages") => _agent_message_forms(messages)]
        isempty(system) ||
            push!(pairs, Symbol(":system") => Form(String(system)))
        _agent_merge_params!(pairs, cfg, _ANTHROPIC_RESERVED)
        return _ns_form(Form[], pairs)
    end
    msgs = Vector{Pair{Symbol,String}}(messages)
    isempty(system) || pushfirst!(msgs, :system => String(system))
    pairs = Pair{Symbol,Form}[
        Symbol(":model") => Form(model),
        Symbol(":max_tokens") => Form(Int(max_tokens)),
        Symbol(":messages") => _agent_message_forms(msgs)]
    _agent_merge_params!(pairs, cfg, _OPENAI_RESERVED)
    return _ns_form(Form[], pairs)
end

# The request headers for a dialect.
function _agent_headers(cfg::_AgentConfig)
    key = _agent_key!(cfg)
    if cfg.dialect === :anthropic
        return ["x-api-key" => key,
                "anthropic-version" => "2023-06-01",
                "content-type" => "application/json"]
    end
    return ["authorization" => "Bearer " * key,
            "content-type" => "application/json"]
end

_agent_url_for(cfg::_AgentConfig) =
    cfg.dialect === :anthropic ? _agent_anthropic_url(cfg) :
    _agent_openai_url(cfg)

# ---- responses ---------------------------------------------------------------

# An integer field of a mapping form, or `nothing`.
function _agent_int_field(f::Form, name::Symbol)
    x = _agent_field(f, name)
    l = _agent_number(x)
    return l isa Integer ? Int(l) : nothing
end

# The text of an Anthropic content block sequence.
function _agent_anthropic_text(body::Form)
    content = _agent_field(body, :content)
    content isa FormContainer ||
        throw(AirAgentError(Symbol("agent-http"), "the response has no content"))
    parts = String[]
    for blk in content.seq
        b = to_form(blk)
        (_agent_symbol(_agent_field(b, :type)) === :text) || continue
        t = _agent_string(_agent_field(b, :text))
        t === nothing || push!(parts, t)
    end
    return join(parts, "")
end

# `(text, input, output, stop)` from a decoded response body.
function _agent_parse(cfg::_AgentConfig, body::Form)
    body isa FormContainer ||
        throw(AirAgentError(Symbol("agent-http"), "the response is not a JSON object"))
    if cfg.dialect === :anthropic
        text = _agent_anthropic_text(body)
        usage = _agent_field(body, :usage)
        input = usage === nothing ? nothing : _agent_int_field(usage, :input_tokens)
        output = usage === nothing ? nothing : _agent_int_field(usage, :output_tokens)
        stop = _agent_string(_agent_field(body, :stop_reason))
        return (text = text, input = input, output = output, stop = stop)
    end
    choices = _agent_field(body, :choices)
    (choices isa FormContainer && !isempty(choices.seq)) ||
        throw(AirAgentError(Symbol("agent-http"), "the response has no choices"))
    choice = to_form(choices.seq[1])
    message = _agent_field(choice, :message)
    text = message === nothing ? nothing : _agent_string(_agent_field(message, :content))
    text === nothing &&
        throw(AirAgentError(Symbol("agent-http"), "the response has no message content"))
    usage = _agent_field(body, :usage)
    input = usage === nothing ? nothing : _agent_int_field(usage, :prompt_tokens)
    output = usage === nothing ? nothing : _agent_int_field(usage, :completion_tokens)
    stop = _agent_string(_agent_field(choice, :finish_reason))
    return (text = text, input = input, output = output, stop = stop)
end

# ---- transport ---------------------------------------------------------------

# A test replaces this with `(method, url, headers, body, timeout) ->
# (status=Int, body=String)`; `nothing` uses `Downloads`.
const _AGENT_HTTP_OVERRIDE = Ref{Any}(nothing)

"""
    _agent_http(method, url, headers, body, timeout) -> (status, body, error)

Send one request. `error` is a message when no response was received at all
(`status` is then 0); a non-2xx HTTP status still yields `error === nothing`.
"""
function _agent_http(method::AbstractString, url::AbstractString, headers, body,
                     timeout::Real)
    stub = _AGENT_HTTP_OVERRIDE[]
    if stub !== nothing
        r = stub(method, url, headers, body, timeout)
        return (status = Int(get(r, :status, 0)),
                body = String(get(r, :body, "")),
                error = get(r, :error, nothing))
    end
    out = IOBuffer()
    hdrs = Pair{String,String}[String(k) => String(v) for (k, v) in headers]
    data = Vector{UInt8}(codeunits(String(body)))
    push!(hdrs, "content-length" => string(length(data)))
    r = try
        Downloads.request(String(url); method = String(method),
                          input = IOBuffer(data), output = out,
                          headers = hdrs, timeout = Float64(timeout), throw = false)
    catch e
        return (status = 0, body = "", error = sprint(showerror, e))
    end
    if r isa Downloads.RequestError
        return (status = 0, body = "",
                error = "the request failed: " * sprint(showerror, r))
    end
    return (status = Int(r.status), body = String(take!(out)), error = nothing)
end

# A short description of the provider's error body, when it has one.
function _agent_error_message(body::AbstractString)
    isempty(strip(body)) && return ""
    decoded = try
        _json_decode(body)
    catch
        return String(body)
    end
    err = _agent_field(decoded, :error)
    if err isa Form
        msg = _agent_string(_agent_field(err, :message))
        msg === nothing || return msg
        s = _agent_string(err)
        s === nothing || return s
    end
    msg = _agent_string(_agent_field(decoded, :message))
    msg === nothing || return msg
    return String(body)
end

"""
    _agent_complete(cfg, system, messages, max_tokens) -> NamedTuple

Run one chat completion: build the request, send it (retrying 429, 5xx, and
transport failures `cfg.retries` times), and parse the answer. Returns
`(text, input, output, stop)` where the token counts may be `nothing`.
"""
function _agent_complete(cfg::_AgentConfig, system::AbstractString, messages,
                         max_tokens::Integer)
    url = _agent_url_for(cfg)
    headers = _agent_headers(cfg)
    body = _json_encode(_agent_request_form(cfg, system, messages, max_tokens))
    attempt = 0
    while true
        r = _agent_http("POST", url, headers, body, cfg.timeout)
        if r.status >= 200 && r.status < 300
            decoded = try
                _json_decode(r.body)
            catch
                throw(AirAgentError(
                    Symbol("agent-http"), "the provider's response is not valid JSON",
                    Form[Form(r.status),
                         Form("the response is not valid JSON: " *
                              _agent_truncate(r.body))]))
            end
            return _agent_parse(cfg, decoded)
        end
        retriable = r.status == 0 || r.status == 429 || r.status >= 500
        if retriable && attempt < cfg.retries
            attempt += 1
            sleep(min(8.0, 1.0 * 2.0^(attempt - 1)))
            continue
        end
        if r.error !== nothing
            throw(AirAgentError(Symbol("agent-network"),
                                "the request to $(url) failed: $(r.error)",
                                Form[Form(r.error)]))
        end
        detail = _agent_error_message(r.body)
        msg = "the provider returned HTTP $(r.status)" *
              (isempty(detail) ? "" : ": " * detail)
        throw(AirAgentError(Symbol("agent-http"), msg, Form[Form(r.status), Form(detail)]))
    end
end

# ---- context accounting ------------------------------------------------------

# An approximate token count: a character heuristic over the system prompt and
# transcript, floored by the exact input count of the previous call. Deliberately
# rough — the provider is the authority, and compaction only needs a trigger.
function _agent_estimate_tokens(system::AbstractString, entries,
                                last::Union{Nothing,Integer})
    n = length(system)
    for e in entries
        t = _agent_entry_text(e)
        t === nothing || (n += length(t))
    end
    est = cld(n, 4)
    last === nothing || (est = max(est, Int(last)))
    return est
end

# The instruction the summarizer receives. It is deliberately terse: the output
# replaces older turns, so it must be self-contained.
const _AGENT_SUMMARY_SYSTEM =
    "You compress conversations. Summarize the transcript you are given so " *
    "the conversation can continue with the summary in place of the older " *
    "turns. Preserve the user's goals, decisions, constraints, names, and any " *
    "facts needed to continue. Do not invent. Reply with the summary only."

"""
    _agent_summarize(cfg, text) -> (summary, usage)

Summarize `text` with the configured model.
"""
function _agent_summarize(cfg::_AgentConfig, text::AbstractString)
    r = _agent_complete(cfg, _AGENT_SUMMARY_SYSTEM,
                        Pair{Symbol,String}[:user => String(text)],
                        min(cfg.max_tokens, _AGENT_SUMMARY_MAX_TOKENS))
    return (summary = r.text, input = r.input, output = r.output)
end
