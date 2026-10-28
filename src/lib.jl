################################################################################
# lib.jl
#
# Loading air source from files and libraries.
#
# `(load-air path…)` reads and parses every form in every named file *before*
# evaluating any of them, then evaluates them in order inside one transaction;
# a nested relative path resolves against the directory of the file that is
# being loaded, not against the process working directory. `air file.air` and
# `air -e` go through the same loader.
#
# A library is a directory named like a name segment holding an `init.air`.
# `AIR_LIBPATH` is a `:`-separated list of search directories (default:
# `<repo>/lib` and `~/.air/lib`). Referring to `.lib.<name>` — or importing the
# bare name `<name>` — loads the library lazily, as `air`, with `.lib.<name>` as
# the current namespace and the library directory as the loading directory, in
# one transaction under a per-library lock. A failed load leaves no namespace
# registered.
#
# The system functions are also reachable as `.air.sys.<name>`.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# ---- system namespace --------------------------------------------------------

# The functions `.air.sys` exposes by name. The map values are the raw symbols,
# so `.air.sys.load-air` dispatches the builtin exactly as `load-air` does.
const _SYS_FUNCTIONS = (Symbol("load-air"), Symbol("read-file"), Symbol("write-file"),
                        Symbol("open-airdb"), Symbol("close-airdb"),
                        Symbol("sync"), Symbol("status"))

function _system_core()
    return Dict{Symbol,Form}(n => Form(n) for n in _SYS_FUNCTIONS
                             if haskey(BUILTINS, n))
end

# Create `.air.sys` and register it under `.air`. It has no entries; its map is
# the fixed table of system function names (see `_ns_wrap`).
function _ensure_system_namespace!(env::Env)
    path = Symbol[_AIR, _SYS]
    _ns_lookup(env, path; lazy = false) === nothing || return nothing
    return tx() do
        parent = _ns_ensure!(env, _AIR_PATH)
        entries = _ns_entries_of(parent.vf)
        if !any(e -> _entry_head(e) === NS_SUB &&
                     _ns_sub_name(_entry_body(e)) === _SYS, entries)
            _ns_store_entries!(env, parent, vcat(entries, [_ns_sub_entry(_SYS)]))
        end
        map = Pair{Symbol,Form}[Symbol(":", String(n)) => Form(n)
                                for n in keys(_system_core())]
        _ns_named_volatile(env, path; value = _ns_form(Form[], map))
        return nothing
    end
end

# ---- task-local source directory --------------------------------------------

# The directory of the file currently being loaded by this task; a relative
# `load-air` path resolves against it. Task-local rather than a process-wide
# `cd`, so concurrent loads do not interfere.
const _FILE_DIR_KEY = :AirLangFileDir

function _file_dir()
    d = task_local_storage()
    x = get(d, _FILE_DIR_KEY, nothing)
    return x isa AbstractString ? x : pwd()
end

function _with_file_dir(f::Function, dir::AbstractString)
    return task_local_storage(_FILE_DIR_KEY, String(dir)) do
        f()
    end
end

_resolve_air_path(p::AbstractString) =
    isabspath(p) ? normpath(p) : normpath(joinpath(_file_dir(), p))

# ---- parsing -----------------------------------------------------------------

function _parse_air_source(src::AbstractString, name::AbstractString)
    try
        return read_all_air_spans(src)
    catch e
        e isa AirParseError || rethrow()
        throw(AirParseError(string(name, ": ", e.msg), e.pos))
    end
end

# The source text, forms, and source record of a file.
function _read_air_file(path::AbstractString)
    src = try
        read(path, String)
    catch e
        throw(AirEvalError("cannot read $path: " * sprint(showerror, e)))
    end
    forms, spans = _parse_air_source(src, path)
    return (src = src, forms = forms, source = AirSource(path, src, spans))
end

# ---- load-air -----------------------------------------------------------------

# Parse every named file before evaluating anything, then evaluate every form in
# order inside one transaction. Returns the last value (`naught` if none).
function _load_air_paths(env::Env, paths::Vector{String})
    files = NamedTuple[]
    for p in paths
        path = _resolve_air_path(p)
        push!(files, _read_air_file(path))
    end
    r = _tx_boundary(env) do
        result = naught
        for file in files
            path = file.source.name
            _with_air_source(file.source) do
                _with_file_dir(dirname(path)) do
                    for f in file.forms
                        result = _with_form_source(f) do
                            air_eval(env, f)
                        end
                    end
                end
            end
        end
        result
    end
    return r
end

# Evaluate a source string (the `-e` case) with the same parse-first policy.
function _load_air_source(env::Env, src::AbstractString, name::AbstractString)
    forms, spans = _parse_air_source(src, name)
    source = AirSource(name, String(src), spans)
    r = _tx_boundary(env) do
        result = naught
        _with_air_source(source) do
            for f in forms
                result = _with_form_source(f) do
                    air_eval(env, f)
                end
            end
        end
        result
    end
    return r
end

function _load_path_arg(v::Form)
    l = _leafof(v)
    l isa AbstractString && return String(l)
    l isa Symbol && return String(_bindname(l))
    throw(AirEvalError("load-air expects file paths, got $(air_string(v))"))
end

# `(load-air path…)` — evaluate every form in each file, in order, atomically.
function _bi_load_air(env::Env, scope::Scope, call::FormContainer)
    paths = String[]
    for i in 2:length(call.seq)
        push!(paths, _load_path_arg(air_reduce(env, scope, to_form(call.seq[i]))))
    end
    isempty(paths) && return naught
    return _Final(_load_air_paths(env, paths))
end
special!(Symbol("load-air"), _bi_load_air)

# ---- libraries ---------------------------------------------------------------

function _default_lib_paths()
    repo = normpath(joinpath(@__DIR__, ".."))
    return String[joinpath(repo, "lib"), joinpath(homedir(), ".air", "lib")]
end

# The library search path. `AIR_LIBPATH` is `:`-separated (`;` on Windows); each
# call reads it, so a test (or a shell) may set it before a library is first
# used. An empty or unset value selects the default.
function _lib_paths()
    raw = get(ENV, "AIR_LIBPATH", "")
    isempty(raw) && return _default_lib_paths()
    sep = Sys.iswindows() ? ';' : ':'
    return String[normpath(strip(d)) for d in split(raw, sep)
                  if !isempty(strip(d))]
end

# The directory of the library `name`, or `nothing` if no search directory has a
# matching `<name>/init.air`.
function _find_library(name::Symbol)
    seg = String(name)
    _valid_name_segment(seg) || return nothing
    for dir in _lib_paths()
        candidate = normpath(joinpath(dir, seg))
        isfile(joinpath(candidate, "init.air")) && return candidate
    end
    return nothing
end

# The libraries this task is currently loading: a recursive reference must not
# recurse forever.
const _LIB_LOADING_KEY = :AirLangLibLoading

function _lib_loading_set()
    d = task_local_storage()
    s = get(d, _LIB_LOADING_KEY, nothing)
    s isa Set{Symbol} && return s
    s = Set{Symbol}()
    task_local_storage(_LIB_LOADING_KEY, s)
    return s
end

const _LIB_LOCKS = Dict{String,ReentrantLock}()
const _LIB_LOCKS_GUARD = ReentrantLock()

_lib_lock(dir::AbstractString) =
    lock(_LIB_LOCKS_GUARD) do
        get!(_LIB_LOCKS, dir, ReentrantLock())
    end

# Drop the wrappers and `val` bindings at or under `path` that an in-memory
# structure may still hold (a rolled-back load, a closed database); the
# namespace volatile itself is gone.
function _purge_namespace_prefix!(env::Env, path::Vector{Symbol})
    n = length(path)
    for key in collect(keys(env.nscache))
        (length(key) >= n && key[1:n] == Tuple(path)) && delete!(env.nscache, key)
    end
    for (key, b) in collect(env.vals)
        p = key[1]
        (length(p) >= n && p[1:n] == Tuple(path)) || continue
        delete!(env.vals, key)
        get(env.valof, b.var, nothing) === b && delete!(env.valof, b.var)
    end
    return nothing
end

# Evaluate a library's `init.air` as `air`, in one transaction, with `.lib.<name>`
# current and its directory as the loading directory. On any error nothing is
# registered.
function _load_library_dir!(env::Env, name::Symbol, dir::AbstractString)
    file = _read_air_file(joinpath(dir, "init.air"))
    path = Symbol[_LIB, name]
    c = _context(env)
    prevns = c.ns
    try
        _as_air(env) do
            _tx_boundary(env) do
                ns = _ns_ensure!(env, path)
                c.ns = ns
                _with_air_source(file.source) do
                    _with_file_dir(dir) do
                        for f in file.forms
                            _with_form_source(f) do
                                air_eval(env, f)
                            end
                        end
                    end
                end
                _ns_lookup(env, path; lazy = false)
            end
        end
    catch
        _purge_namespace_prefix!(env, path)
        rethrow()
    finally
        c.ns = prevns
    end
end

# Load the library `name` if it is not already present. Returns the namespace
# wrapper, or `nothing` when no library of that name exists (or a recursive load
# is already in progress).
function _load_library!(env::Env, name::Symbol)
    _valid_name_segment(String(name)) || return nothing
    path = Symbol[_LIB, name]
    ns = _ns_lookup(env, path; lazy = false)
    ns === nothing || return ns
    loading = _lib_loading_set()
    name in loading && return nothing
    dir = _find_library(name)
    dir === nothing && return nothing
    lk = _lib_lock(dir)
    lock(lk)
    try
        ns = _ns_lookup(env, path; lazy = false)
        ns === nothing || return ns
        push!(loading, name)
        try
            return _load_library_dir!(env, name, dir)
        finally
            delete!(loading, name)
        end
    finally
        unlock(lk)
    end
end

# Trigger a load when `key` names an unloaded library in the `.lib` namespace.
# Returns whether the namespace changed (so the caller can look again).
function _lib_trigger!(env::Env, ns::Namespace, key::Symbol)
    ns.path == Symbol[_LIB] || return false
    name = _bindname(key)
    _valid_name_segment(String(name)) || return false
    name in _lib_loading_set() && return false
    _find_library(name) === nothing && return false
    return _load_library!(env, name) !== nothing
end

# A namespace spec: an ordinary lookup, then — for a bare root-level name — the
# library of that name, loaded lazily.
function _lookup_ns_or_library(env::Env, path::Vector{Symbol})
    ns = _ns_lookup(env, path)
    ns === nothing || return ns
    length(path) == 1 || return _ns_lookup(env, path)
    return _load_library!(env, path[1])
end
