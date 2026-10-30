################################################################################
# ssh/paths.jl
#
# Remote paths are air paths: a namespace is a directory and a `bytes` val is a
# file. A client composes its paths with `/` (after its own `realpath(".")`), and
# a person types them with dots, so both separators are accepted.
#
#   data.weights        relative to the session user's `$` (their home)
#   data/weights        the same path
#   ./data/weights      the same path (what `sftp` sends for a relative name)
#   .                   the session's home, i.e. "here"
#   .sys.user.alice.home  absolute (from the air root)
#   /sys/user/alice/home  the same path, with `/` separators
#
# `..` is rejected: a namespace is a capability, so a session must not walk out
# of one.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# Split a client path into `(absolute, segments)`; raises on `..` and on a
# segment that cannot name an air entry. A path is absolute when it starts with
# `/` or is a dotted air path (`.sys.user.alice.home`); `.` and `./x` are the
# client's "here" and so stay relative to the session's home.
function _ssh_split_path(raw::AbstractString)
    s = String(raw)
    occursin("..", s) && throw(SshError("paths may not contain '..': $s"))
    absolute = startswith(s, "/") ||
               (startswith(s, ".") && s != "." && !startswith(s, "./"))
    segs = Symbol[]
    for part in split(s, r"[./]")
        isempty(part) && continue
        _valid_name_segment(part) ||
            throw(SshError("invalid path segment '$part' in $s"))
        push!(segs, Symbol(part))
    end
    return (absolute, segs)
end

# The absolute air path a client path denotes, given the session user's home.
function _ssh_abs_path(home::Vector{Symbol}, raw::AbstractString)
    absolute, segs = _ssh_split_path(raw)
    return absolute ? segs : vcat(home, segs)
end

# The dotted absolute spelling of a path: `.a.b`, or `.` for the root.
_ssh_display(path::Vector{Symbol}) =
    isempty(path) ? "." : "." * join(String.(path), ".")

# The basename of a path (the last segment), or `nothing` at the root.
_ssh_basename(path::Vector{Symbol}) = isempty(path) ? nothing : path[end]
