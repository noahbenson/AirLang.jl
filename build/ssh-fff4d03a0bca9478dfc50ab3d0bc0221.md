# SSH access

An air process can serve SSH. A user logs in with a key listed in their own
configuration and lands as themselves, in their home namespace, at a REPL; the
same account serves SFTP, so `scp` and `sftp` move files in and out. A
transferred file is an immutable [`bytes`](externs.md#5-bytes-an-immutable-extern)
value and a directory is a namespace — there are no files in air, only paths.

The server is a process resource named by a key, like a task, not a value you
pass around:

```air
(ssh-server :myserver port=2222)
(ssh-servers)                     ; => (myserver=(owner=:air …))
(ssh-host-key :myserver)          ; the public key line, for known_hosts
(ssh-close! :myserver)            ; stop listening; keep the host key
```

Only `air` or an admin may start a server (`(ssh-server)` with no name generates
one, e.g. `:ssh-3f9a1c2b`), and a server admits exactly the users its owner may
assume: `air` admits everyone, and an admin admits itself and its constituents.
The admitted set is recomputed at each login, so a user created after the server
started can log in. `(ssh-servers)` lists the servers the caller may see — all
of them for `air`, its own for an admin.

## Configuring a user

Keys live in the user's own home, under `$.config.ssh`, and the server options
come from the owner's. The namespace shape:

```air
(create-user :alice)
(as-user :alice
  (namespace $.config.ssh
    (val authorized-keys
      ("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA… alice@laptop"))))
```

A server owner also sets the defaults its servers start with:

```air
(namespace $.config.ssh
  (val server (port=2222 bind="127.0.0.1" host-key-type="ed25519"
               max-connections=4 banner="air ssh" key-types=("ssh-ed25519"))))
```

The second accepted shape is a single `ssh` val in `$.config`:

```air
(namespace $.config
  (val ssh (authorized-keys=("ssh-ed25519 AAAA… alice@laptop"))))
```

The namespace wins where both are present, and the two need not hold the same
entries. `authorized-keys` is a list; each entry is an OpenSSH one-line string
with **no options** (an entry with options, or one naming an unknown type, is
rejected with an error naming the user) or a mapping
`(type="ssh-ed25519" key="AAAA…" comment="…")`. A user with no readable entry
simply cannot log in.

Options are merged **defaults < the owner's `$.config.ssh.server` < the explicit
call**, and `(ssh-server …)`'s own options are the same set:

| option | default | meaning |
| --- | --- | --- |
| `port` | `2222` | the listening port; `0` picks a free one |
| `bind` | `"127.0.0.1"` | the address to listen on |
| `host-key-type` | `"ed25519"` | the generated host key's type (`ed25519` or `rsa`) |
| `key-types` | `()` | client key types allowed to authenticate at all; empty allows any |
| `max-connections` | `4` | concurrent sessions per server |
| `banner` | `"air ssh"` | the protocol banner |

The host key is generated on first use and stored in the process database at
`.sys.ssh.<key>`, so no file exists on disk and `(ssh-close! :myserver)` followed
by a new `(ssh-server :myserver …)` is the same host. `(ssh-host-key :myserver)`
returns the public line (put it in `known_hosts`), and `private=true` the
private key; reading either needs `air` or the server's owner.

## Logging in

A POSIX login name cannot contain `:`, so the client name maps `.` to `:` —
`alice` is `:alice`, `air.bob` is `:air:bob`, `game.kid` is `:game:kid`:

```sh
ssh -p 2222 -i ~/.ssh/id_ed25519 alice@localhost
```

```text
air> (current-user)
:alice
air> (def (twice ?x) (x * 2))
naught
air> (exit)
```

Public-key authentication is the only method; a password is never accepted and
never offered. Every refusal — an unknown user, a wrong key, a user outside the
server's scope, a malformed config — looks the same to the client, so the server
does not enumerate its users, and the connection is dropped after six failed
attempts.

## The remote REPL

The session is the local REPL with a line editor: history (Up/Down), `Ctrl-A`,
`Ctrl-E`, `Ctrl-K`, `Ctrl-U`, `Ctrl-W`, arrow keys, Home/End, and Delete, with
the prompt and results redrawn over the terminal width the client reports.

* An incomplete form continues on the next line under a `...> ` prompt.
* `Ctrl-C` evaluates `(raise :ctrl-c)`: the line being edited is discarded and
  the error is printed, and the session continues. Evaluation is not
  preemptible, so a byte sent while a form runs is read when that form finishes.
* `Ctrl-D` on an empty line, a channel EOF, and `(exit)` all end the session.
  `(exit value)` delivers `value` to the session task and prints nothing.

`def` and `val` typed at the prompt are written to the session user's home
namespace, because `$` is the current namespace there — durable, and readable
afterwards as `air` at `.sys.user.<name>.home.…`.

Output goes to the client: `(print …)`/`(println …)` in a session write to the
channel, including from a `task` the session spawns. There is no
non-interactive exec: `ssh host command` is refused (it opens a channel request
air does not serve).

## Paths, directories, and files

A remote path is an air path. It is split on both `.` and `/`, empty segments
dropped; a leading `.` or `/` is absolute (a root path), and anything else is
relative to the session user's `$`:

| client path | air path |
| --- | --- |
| `data.weights` | `$.data.weights` |
| `./data/weights` | `$.data.weights` |
| `.sys.user.alice.home.data.weights` | the same namespace, spelled absolutely |
| `/main.config` | `.main.config` |

Any `..` in a path is rejected: a path never climbs, so an `sftp` batch that
does `cd ..` fails rather than escaping the home. `REALPATH(".")` answers the
session home in dotted absolute form (`sys.user.alice.home`), so a client that
canonicalizes a relative path still lands in the same place.

Directories are namespaces and files are `bytes` vals:

* Listing a namespace shows its subnamespaces as directories and its `val`s as
  files, each filtered by the caller's `read` permission; a `def` is not a file
  and is not listed. A `val` that does not hold `bytes` still lists (with size
  `0`) but refuses to open.
* `OPEN` for writing buffers the whole transfer and `CLOSE` installs it as one
  new `bytes` val in a single transaction, creating missing parent namespaces.
  Partial files never appear and a failed upload leaves nothing behind, but a
  large upload is held in memory rather than streamed — see the limitations.
* A destination holding anything but `bytes` is refused (`OPEN`/`CLOSE`/
  `REMOVE`), so a transfer can never overwrite a definition or a config.
* Because `.` separates path segments, `dir/file.bin` is the `file` namespace
  holding the `bin` val inside `dir`: a directory's contents are always one
  level down. `rmdir` is not recursive, so an `sftp` batch removes
  `dir/file.bin`, then `dir/file`, then `dir`.

SFTP is version 3 with no extensions. The modern `scp` (which uses SFTP) works;
the legacy protocol (`scp -O`, which asks the server to run a command) does not.

## Limitations

* **Buffered uploads.** A written file is assembled in memory and committed at
  `CLOSE`, because `bytes` is immutable. Transfers are correct and atomic but
  not incremental.
* **No exec, no recursive delete.** There is no command channel and `RMDIR`
  requires an empty namespace.
* **Ctrl-C is not preemptive.** It is delivered when the running form finishes.
* **Listening is opt-in per address.** A server binds `127.0.0.1` unless told
  otherwise; there is no host-key exchange with an external `sshd` and no
  password or certificate authentication.
