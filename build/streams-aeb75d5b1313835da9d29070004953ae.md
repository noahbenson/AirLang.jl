# Streams

A **stream** is a reusable first-in-first-out queue: one task *posts* objects to
it and another *fetches* them, in order, any number of times. Unlike a promise,
which is assigned once, a stream lives until it is closed and can deliver
arbitrarily many objects.

A stream is a database-backed value (`AirDB.StreamForm`) stored in the
[namespace](namespaces.md) where it is created, so it follows the ordinary
persistence and transaction rules: every post and fetch is staged in the current
transaction and becomes visible at the commit.

## Creating a stream

```air
(namespace .jobs (val q (stream)))
```

`(stream)` creates an unbounded stream. `(stream maxsize=8)` bounds the queue:
once it holds `maxsize` items, a post waits (see [timeouts](#timeouts)). A
stream prints as an opaque handle, `#<stream 0b1e…>`, and reading it —
`(get q)`, `(value q)` — never consumes an item. `(stream? x)` tests the type.

## Posting and fetching

| form | meaning |
| --- | --- |
| `(post s obj timeout=n)` | append `obj`; needs `write`; returns the envelope |
| `(fetch s)` | remove and return the oldest object; needs `read` |
| `(fetch s meta=true)` | return the whole envelope instead of the object |
| `(fetch s timeout=n)` | return `naught` if nothing arrives within `n` seconds |
| `(count s)` | the queued items (`read`) |
| `(open? s)` | whether the stream still accepts deliveries (`read`) |
| `(close! s)` | stop the stream (`write`) |

Each delivery is stored as an **envelope**: the object, the posting user, and
the instant.

```air
(namespace .jobs (val q (stream)))
(post .jobs.q :build)          # => (:build sender=:air time=(time "2026-10-29T06:43:02.663Z"))
(fetch .jobs.q)                # => :build
```

`post` stamps the sender and the time itself, so `sender=` and `time=` are not
options. `(fetch s meta=true)` returns the envelope, which is how a consumer
learns who posted an object and when:

```air
(get (fetch .jobs.q meta=true) :sender)   # => :air
(get (fetch .jobs.q meta=true) :time)     # => (time "2026-10-29T06:43:02.663Z")
```

An item that is not an envelope — a stream written through the AirDB API
directly — reads back unchanged in both modes.

## Timeouts

`timeout=` is in seconds and bounds the wait in both directions:

```air
(fetch .jobs.q timeout=0.5)    # => naught when nothing arrives
```

A `naught` result means the wait expired; it does not mean the stream is
closed. On a bounded stream, a `post` that would block waits at most
`timeout=` seconds and then returns `naught`. Without a timeout, both block
until the operation can proceed.

Because `naught` is a legitimate object to deliver, `(fetch s)` reports both an
expiry and a delivered `naught` as `naught`. Use `meta=true` to tell them apart:
a delivery is an envelope, an expiry is `naught`.

## Closing

`(close! s)` stops the stream. Items already queued can still be fetched; once
the queue is empty, `fetch` raises `(error :stream-closed)`, and `post` raises it
immediately. `close!` needs `write`, because it changes what the stream accepts.

## Permissions

The stream object carries its own ACL, and the two directions map onto the two
basic permissions:

- **`read`** — receive (`fetch`, `count`, `open?`);
- **`write`** — deliver (`post`, `close!`).

The namespace entry that names the stream keeps its own permissions: a user must
be able to read the entry to reach the stream at all. Granting `read` on the
stream to another user therefore looks like this:

```air
(namespace .jobs (val q (stream)))
(chmod! .jobs read=(_=true) exec=(_=true))
(namespace .jobs (chmod! q read=(_=true) exec=(_=true)))   # the entry
(chmod! .jobs.q read=(bob=true))                            # the stream: receive only
```

Bob can now `(fetch .jobs.q)` but a `post` raises `(error :permission-denied
write :stream)`. Granting `write=(bob=true)` on the stream lets him deliver, and
the envelope then names him as the sender.

## Transactions

A post or fetch made inside a transaction is part of it: an aborted transaction
drops its posts, and a committed one keeps them, in commit order. The stream is
persisted in the namespace's database, so a post made in one environment is
visible to a fresh environment over the same database.

A blocking stream operation inside an open transaction cannot see the
transaction's own staged writes; give it a `timeout=` so it expires instead of
waiting for a commit that cannot happen. (Air reports a detected self-deadlock
as `(error :stream-deadlock)`.)

Use `(sync)` outside the transaction to wait for a committed post to reach the
database before another process reads it.

## Persistence and JSON

A stream is an ordinary database value. `(to-json s)` always writes a link,
`"&<uuid>"`, never the queue; `(from-json …)` resolves the link back to the same
stream. Two references to one stream are `eq?`; two streams created separately
are not, and `(hash s)` follows stream identity.

## A worked producer and consumer

A consumer can run on its own task while the producer posts from the main one.
A task inherits the namespace context, so it can name the stream directly:

```air
(namespace .pipeline
  (val q (stream))
  (val c (task (list (fetch q) (fetch q) (fetch q)))))

(post .pipeline.q :a)
(post .pipeline.q :b)
(post .pipeline.q :c)

(await .pipeline.c)             # => (list :a :b :c)
```

Because a stream keeps its objects, the consumer may also start *after* the
producer, or drain in a loop:

```air
(for (i (1 2 3)) (post .pipeline.q (* i i)))
(loop (n 3 acc ())
  (if (== n 0) acc (recur (- n 1) (push acc (fetch .pipeline.q)))))
                                # => (1 4 9)
```

## Errors

| tag | when |
| --- | --- |
| `:stream-closed` | `post` to, or `fetch` from, a closed and drained stream |
| `:stream-deadlock` | a blocking stream operation that cannot make progress |
| `:uncommitted-stream` | using a stream from a transaction that has not committed |
| `:aborted-stream` | using a stream from a transaction that aborted |

All are ordinary catchable [errors](errors.md):

```air
(do (post .pipeline.q :late)
    (except (:stream-closed ?m) :closed))
```
