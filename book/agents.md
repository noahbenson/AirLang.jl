(agents)=
# Agents

An **agent** is a user account that talks to a language-model server. It is an
ordinary `:agent` [account](permissions.md#account-kinds), created by an
administrator as a constituent of that administrator (`:game:bot` for
`:game`'s agent `:bot`), and everything it can do it does with the authority of
that account. A **session** is a durable conversation with one agent: a small
database value holding the transcript, the usage counters, and a **channel** —
a pair of streams through which the administrator sends messages and receives
replies.

The layer is deliberately narrow. It connects air to a provider, manages the
context window, and turns text into a reply; the agent does not evaluate air
code, call tools, or stream tokens (see [Limits](#limits)).

## Creating an agent

```air
(as-user :game
  (create-agent :bot provider=:fireworks model="accounts/fireworks/models/llama-v3p3-70b-instruct"
                        api-key="fw_…" system="You are a careful assistant."))
;; => (agent base-url="https://api.fireworks.ai/inference/v1" dialect=:openai
;;           id=:game:bot model="…" provider=:fireworks)
```

Only an administrator (or `air`) may create an agent, and only a *core* user
may; a constituent cannot. The name is one segment and the account is always
`:agent`'s own id, `:<admin>:<name>`. `(user-kind :game:bot)` is `:agent`,
`(agent? :game:bot)` is true, and `(agents)` lists the agent accounts the
caller can see (`air` sees every agent).

The options are the inference settings; they are stored in the agent's home, in
`$.config.agent`:

| key | meaning | default |
| --- | --- | --- |
| `provider` | `:anthropic`, `:openai`, `:fireworks`, `:deepseek`, `:compatible` | `:anthropic` |
| `dialect` | `:anthropic` or `:openai` request/response shape | the provider's |
| `base-url` | the endpoint root | the provider's |
| `model` | the model name | required |
| `api-key` | the credential | none; `open-session` raises until it is set |
| `system` | the system prompt | `""` |
| `max-tokens` | the reply cap per call | `4096` |
| `params` | extra request-body entries, e.g. `(temperature=0.2)` | none |
| `context` | the model's window, in tokens; enables automatic compaction | none |
| `compact-at` | compact when the estimate crosses this fraction of `context` | `0.8` |
| `compact-keep` | transcript entries compaction keeps verbatim | `4` |
| `timeout` | one HTTP call's timeout, in seconds | `120` |
| `retries` | retries for a 429, a 5xx, or a network failure | `2` |

The provider fixes the dialect and the base URL unless they are given:

| provider | dialect | base URL |
| --- | --- | --- |
| `:anthropic` | `:anthropic` | `https://api.anthropic.com` |
| `:openai` | `:openai` | `https://api.openai.com/v1` |
| `:fireworks` | `:openai` | `https://api.fireworks.ai/inference/v1` |
| `:deepseek` | `:openai` | `https://api.deepseek.com/v1` |
| `:compatible` | `:openai` | required (`base-url=`) |

`:compatible` is the escape hatch for any server that speaks the OpenAI
chat-completions API — a vLLM or Ollama instance, a gateway, a proxy — so
`provider=:compatible base-url="http://localhost:8000/v1"` reaches a local
model. `params=` carries anything the dialect does not build itself (a
reserved key such as `model` or `messages` raises).

### Reading and changing the configuration

```air
(agent-config :bot)                  ; => (api-key="***" …)
(agent-config :bot secrets=true)     ; => (api-key="fw_…" …)
(agent-config! :bot model="…" system="Be terse.")
```

`agent-config` redacts `api-key` unless `secrets=true`.

```{warning}
The API key is stored **verbatim** in the agent's `$.config.agent`. It is an
ordinary namespace entry, so the ordinary ownership rules protect it: the
agent, its administrator, and `air` can read it, and a stranger is denied with
`(error :permission-denied …)`. It is nonetheless in the database, so a dump or
backup contains it.
```

The key is read live from `$.config.agent` on every call, so
`agent-config!` rotating it takes effect in sessions that are already open. The
rest of the configuration is snapshotted when a session opens (below).

## Sessions

```air
(val s (open-session :bot))                       ; a new session
(val s (open-session :bot id="s-3f9a1c2d"))       ; reopen an existing one
(val s (open-session :bot model="…" context=200000))  ; new, with overrides
```

`open-session` returns a handle:

```air
(session id="s-3f9a1c2d" agent=:game:bot owner=:game state=<mut>
         channel=(channel id="c-3f9a1c2d" agent=:game:bot owner=:game
                          state=<mut> in=<stream> out=<stream> in-notify=<stream>))
```

The handle is a convenience value. The **state** mutable is the durable root:
it holds the status, the configuration snapshot, the transcript, the usage
counters, the last error, and the three streams. A session is stored behind the
named form `agent/<agent>/sessions/<sid>` in the agent's home database, so a
session survives a process restart and can be reopened in a fresh environment
over the same database. The session belongs to the agent, so its administrator
reaches it through the ordinary administrator rules, and `air` bypasses every
check.

Opening a session validates the configuration: a missing model or API key
raises `(error :agent-misconfigured…)` at `open-session`, not at creation. The
snapshot options — `provider`, `dialect`, `base-url`, `model`, `system`,
`max-tokens`, `params`, `context`, `compact-at`, `compact-keep`, `timeout`,
`retries` — become that session's settings and can differ from the agent's
record. `api-key` is not one of them; it is read live.

| form | meaning |
| --- | --- |
| `(sessions agent)` | a map `sid → handle` for every session of the agent |
| `(session-info s)` | status, model, message count, estimate, usage, queue counts, hook flag, timestamps, errors |
| `(session-history s limit=n)` | the transcript, or its last `n` entries |
| `(session-channel s)` | the session's channel handle |
| `(session-post s msg)` | send a message (same as `channel-post`) |
| `(session-fetch s meta=false timeout=n)` | receive the oldest reply |
| `(session-hook! s form)` | install the `on-receive` hook |
| `(session-resume s)` | reopen a paused session and wake its worker |
| `(session-close! s)` | close the session and its streams; idempotent |

Sessions are listed for the agent's administrator; another user is denied by
the access check. A closed session stays readable — its state, its transcript,
and its streams — but a post to it raises `(error :stream-closed)`.

## Messages and replies

A message posted to a session is either **text for the model** or a
**command**:

* a string, or any form whose head is not a keyword, is a turn. A string
  contributes its contents; anything else is rendered with the ordinary
  printer, so `(session-post s (list 1 2 3))` sends `(1 2 3)`.
* a form whose head is a keyword is a command, handled below.

A turn appends `(role=:user text="…")` to the transcript, calls the provider,
and appends `(role=:assistant text="…")`. The reply arrives on the inbox:

```air
(session-post s "Summarize the plan.")
(session-fetch s)     ; => (reply text="…" model="…" stop="end_turn"
                      ;           usage=(input=12 output=8 total=20)
                      ;           time=(time "2026-10-30T…"))
```

`session-fetch` supports the stream options: `timeout=n` returns `naught` when
nothing arrives, and `meta=true` returns the envelope — the reply with
`sender=` and `time=` — instead of the object. `channel-ready?` and
`channel-count` poll without blocking. Writes never block unless a bounded
stream is full, and the session's streams are unbounded.

A failed call posts an error object instead of a reply and leaves the session
usable:

| tag | when |
| --- | --- |
| `:agent-http` | a provider answered with an error status, or with something that is not valid JSON |
| `:agent-network` | the request never completed |
| `:agent-misconfigured` | a required setting is missing or invalid |
| `:agent-context` | the transcript does not fit the window even after compaction |
| `:agent-not-found` | no such agent account; `:not-an-agent` for a human one |
| `:agent-session` | a session value is malformed or lacks its streams |
| `:agent-command` | an unknown command |

A 429 or a 5xx is retried `retries` times with exponential backoff before it is
reported; another 4xx is immediate. The key is never included in an error or a
message.

### Commands

A keyword-headed message is a command; it never enters the transcript.

| form | effect | answer |
| --- | --- | --- |
| `(:help)` | list the commands | `(:ack :help commands=…)` |
| `(:context)` | report the token estimate, the limit, and the usage | `(:context messages=… estimate=… usage=…)` |
| `(:reset)` | clear the transcript (the system prompt stays) | `(:ack :reset)` |
| `(:system "…")` | replace the system prompt | `(:ack :system)` |
| `(:model "…")` | change this session's model | `(:ack :model model="…")` |
| `(:compact)` | summarize the older turns now | `(:ack :compact before=… after=… usage=…)` |
| `(:stop)` | pause the session after this message | `(:ack :stop)` |
| anything else | — | `(error :agent-command head=:foo)` |

`(:stop)` sets the session to `:paused`: later posts queue up and no worker
reads them until `(session-resume s)`, which reopens the session and drains the
queue. `(:reset)`, `(:system)`, and `(:model)` change the session only, never
the agent's record.

## Channels

A channel is the pair of streams a session is built on. Directions are from the
**owner's** point of view — the administrator who opened the session:

| field | direction |
| --- | --- |
| `out` | the owner's outbox: a message posted here goes *to* the agent |
| `in` | the owner's inbox: the agent's replies arrive here |
| `in-notify` | the private copy queue for the owner's hook |

| form | meaning |
| --- | --- |
| `(channel? x)` | whether `x` is a channel handle |
| `(channel-post ch msg)` | append to `out` and wake the agent |
| `(channel-fetch ch meta=false timeout=n)` | take from `in` |
| `(channel-ready? ch)` | whether a reply is waiting |
| `(channel-count ch)` | the queued replies |
| `(channel-hook! ch form)` | install the `on-receive` hook |
| `(channel-unhook! ch)` | remove it |
| `(channel-close! ch)` | close the session's streams |

The channel handle carries the state mutable, so a hook installed after a
handle was made is seen through it. The streams are created by and owned by the
agent, so they carry its owner-only ACL; the administrator reaches them through
the ordinary administrator rules and `air` bypasses the checks.

## The `on-receive` hook

A hook lets the owner react to each reply without polling:

```air
(as-user :game
  (def (log-reply ?msg) (post $.replies (get msg :text))))
(as-user :game (session-hook! s 'log-reply))
```

* **A hook gets a copy.** When the agent delivers a reply, an installed hook
  receives a *copy* while the original stays queued for `session-fetch`, so the
  two never steal from each other.
* **It runs as the receiving end's owner, in the registering namespace.** The
  hook form is evaluated in the namespace where it was installed and with the
  owner's identity, so `(current-user)` is the owner and a `def` that exists
  only in that namespace resolves.
* **It is called as a function of the message:** `(form msg)` — a symbol naming
  a `def`, a replacement-rule lambda, or any form.
* **Its errors are contained.** A failing hook is recorded in
  `(session-info s)`'s `last-hook-error` (as the air error object) and the next
  reply still reaches both the hook and the session.
* **Installing replaces and drains.** `session-hook!` discards stale copies
  before it installs, and a copy that was already waiting when the hook was
  replaced runs the *new* hook; `channel-unhook!` stops delivery. Only the
  owner (or `air`) may install or remove one.
* **The copy queue is unbounded.** A hook slower than the replies lets
  `in-notify` grow.

The agent end has a built-in `on-receive` — its worker consumes the outbox
directly — so no user-installed hook exists on that side.

## The context window and compaction

The estimate is a characters-over-four heuristic over the system prompt and the
transcript, floored by the last response's exact input-token count; it is
deliberately approximate, so compaction may trigger a little early or late.

With `context=` set, the worker compacts before a call when the estimate
crosses `compact-at × context`. Compaction keeps the system prompt and the last
`compact-keep` entries verbatim and replaces everything older with a single
`(role=:summary text="…")` entry, which is sent as part of the system prompt
(Anthropic) or as a leading system message (OpenAI-compatible). The
summarizer's own usage counts toward the session totals. The request's
`max-tokens` is clamped down when the estimate plus the reply cap would exceed
the window; if even compaction leaves no room, the turn fails with
`(error :agent-context …)`. `(:compact)` compacts on demand, with or without a
configured window; `(:context)` reports the numbers.

Without `context=`, nothing compacts automatically and the transcript grows
until the provider refuses it.

## Durability and lazy resume

Sessions, transcripts, and channels are database values. A restart loses
nothing, but it also leaves no worker running: **no process starts a worker
until a message arrives**. A session is woken by a post
(`session-post`/`channel-post`), by `open-session` with a queued message, or by
`(session-resume s)`. Messages posted while the process was down are therefore
processed on the next post or the next `open-session`/`session-resume`.

One worker runs per session per process; a second process over the same
database is not coordinated with the first, so it is best to treat a session as
belonging to one running process at a time.

## Limits

* No streaming: a reply arrives whole.
* No tools or function calling, and the agent does not evaluate air code.
* The token estimate is a heuristic, not a tokenizer.
* Sessions accumulate; there is no purge or garbage collection yet.
