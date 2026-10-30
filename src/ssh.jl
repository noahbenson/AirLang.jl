################################################################################
# ssh.jl
#
# An SSH server inside air: authorized-key login, a remote REPL, and SFTP v3 over
# the same namespaces a local session sees. A directory is a namespace and a file
# is a `bytes` val, so `scp weights.pt air.someuser@host:data.weights` leaves
# `$.data.weights` holding the file's bytes.
#
# The layers, in dependency order:
#
#   libssh.jl   the typed ccall surface (and the thread-pool discipline)
#   paths.jl    client paths -> air paths
#   config.jl   `$.config.ssh` — authorized keys and server defaults
#   server.jl   the registry, host keys, and the `ssh-*` builtins
#   auth.jl     public-key authentication
#   repl.jl     the channel writer, the line editor, and the REPL
#   sftp.jl     the file-transfer subsystem
#   session.jl  one connection: handshake, auth, channel, subsystem
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

include("ssh/libssh.jl")
include("ssh/paths.jl")
include("ssh/config.jl")
include("ssh/server.jl")
include("ssh/auth.jl")
include("ssh/repl.jl")
include("ssh/sftp.jl")
include("ssh/session.jl")
