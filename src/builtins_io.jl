################################################################################
# builtins_io.jl
#
# Side effects. Printing and file writes go through Air actors, so a side effect
# is deferred to the transaction's commit and dropped if the transaction aborts
# (the README's "actor-backed I/O"). Reads are direct.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# A form's text: a string leaf prints as its content, anything else as air source.
# The environment is supplied so an unreadable volatile prints opaquely.
_print_str(env::Env, v::Form) =
    (l = _leafof(v); l isa String ? l : air_string(env, v))

# `(print args…)` — write each argument to the task's output sink: Air's
# actor-backed stdout, or the SSH session channel when the task is running in
# one (see `_air_out` and `TaskContext.out`).
builtin!(:print, (env, scope, args) -> begin
    out = _air_out(env)
    for a in args
        write(out, _print_str(env, a))
    end
    return naught
end)

builtin!(:println, (env, scope, args) -> begin
    out = _air_out(env)
    for a in args
        write(out, _print_str(env, a))
    end
    write(out, "\n")
    return naught
end)

# `(str args…)` — concatenate the arguments into a string.
builtin!(:str, (env, scope, args) -> Form(join((_print_str(env, a) for a in args))))

# `(read-file path)` — the file's contents as a string (a direct read). A
# relative path resolves against the directory of the file being loaded, so a
# library's `init.air` reads its own data files; outside a load that is `pwd()`.
builtin!(Symbol("read-file"), (env, scope, args) -> begin
    _require_filesystem(env, "read-file")
    Form(read(_resolve_air_path(_str(_arg(args, 1, "read-file"), "read-file")),
              String))
end)

# File writes go through a single writer actor, so a `(write-file …)` inside a
# transaction is deferred to commit and dropped on abort.
const _FILE_ACTOR = Actor{Nothing}(nothing)

builtin!(Symbol("write-file"), (env, scope, args) -> begin
    _require_filesystem(env, "write-file")
    path = _resolve_air_path(_str(_arg(args, 1, "write-file"), "write-file"))
    content = _str(_arg(args, 2, "write-file"), "write-file")
    send(_FILE_ACTOR) do st
        write(path, content)
        return st
    end
    return naught
end)
