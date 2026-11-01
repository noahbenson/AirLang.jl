################################################################################
# AirLang.jl
#
# The air language: a Clojure/Mathematica-inspired interpreted language built on
# Air.jl (persistent data + STM) and AirDB.jl (the form value model + database).
#
# This module implements the inner (reduction) system: reading air source into
# forms, matching patterns, and reducing to a fixed point.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

module AirLang

using Air
using AirDB
using AirDB: FormSeq, FormMap
using Random
import Dates   # only qualified: `Dates` exports names (`now`, `day`, …) that
               # would shadow air's own
import TOML    # only qualified, for the TOML data format
import Downloads  # only qualified, for the agent HTTP transport
import LinearAlgebra   # only qualified, for the tensor linear-algebra surface

# Types and helpers, then the engine, then the builtin library (which registers
# itself at load time), then the public surface.
include("errors.jl")
include("forms.jl")
include("signals.jl")
include("equality.jl")
include("memo.jl")
include("env.jl")
include("reader.jl")
include("source.jl")
include("pattern.jl")
include("builtins.jl")
include("operators.jl")
include("builtins_time.jl")
include("layouts.jl")
include("reduce.jl")
include("builtins_core.jl")
include("builtins_math.jl")
include("builtins_collection.jl")
include("externs.jl")
include("bytes.jl")
include("tables.jl")
include("tensors.jl")
include("tensor_ops.jl")
include("builtins_string.jl")
include("builtins_io.jl")
include("formats.jl")
include("builtins_control.jl")
include("builtins_hold.jl")
include("builtins_iter.jl")
include("builtins_rules.jl")
include("namespaces.jl")
include("users.jl")
include("permissions.jl")
include("lib.jl")
include("database.jl")
include("persistence.jl")
include("refs.jl")
include("builtins_error.jl")
include("builtins_block.jl")
include("testing.jl")
include("hooks.jl")
include("builtins_mut.jl")
include("logic.jl")
include("builtins_extern.jl")
include("builtins_stream.jl")
include("api.jl")
include("ssh.jl")
include("ui.jl")
include("agents_providers.jl")
include("agents.jl")
include("jobs.jl")
include("events.jl")
include("cli.jl")

import PrecompileTools

# Compile the interpreter's hot path into the package image. Constructing an
# environment and evaluating one definition reaches the reducer, the evaluator,
# `def`, and the bootstrap transaction — several very large methods whose first
# call otherwise costs ~30 s in the JIT, once per process. `@compile_workload`
# runs only while the package is being precompiled, and it also records the
# dynamically dispatched callees that plain compilation would miss.
#
# The script below is a compressed `startup.air`: it goes through the same
# loader (one transaction over the whole source), creates a user, writes a
# `val` into a config namespace, opens and closes a database root, and starts
# and stops an SSH server. Those are the other few seconds of first-use
# compilation a serving process pays. Nothing here touches the host: the env is
# a throwaway in-memory database, `memory=true` opens a second one, and the
# server takes a free port and is closed before the workload ends.
PrecompileTools.@compile_workload begin
    let env = Env()
        air_eval(env, read_air("(def (air-precompile-sentinel ?x) x)"))
        air_string(air_eval(env, read_air("(+ 1 2)")))
        _load_air_source(env, """
            (create-user :air-precompile-user)
            (as-user :air-precompile-user
                (namespace \$.config.ssh (val authorized-keys ())))
            (open-airdb .air-precompile-db memory=true)
            (close-airdb .air-precompile-db)
            """, "<precompile>")
        _resume_jobs_quietly!(env)
        # `__init__` has not run at precompile time, so make libssh available
        # explicitly. The block is guarded because a host where libssh cannot
        # be loaded should still precompile — the server itself raises a
        # catchable error at run time there.
        try
            _ssh_init!()
            _load_air_source(env, """
                (ssh-server :air-precompile-sshd port=0 bind="127.0.0.1")
                (ssh-close! :air-precompile-sshd)
                """, "<precompile>")
        catch
        end
    end
end

export read_air, read_all_air, air_eval, air_repl, air_main, air_string,
    air_pretty_string,
    default_env, Env, Scope, Rule, RuleStore, canonicalize, truthy, naught,
    AirError, AirParseError, AirEvalError, AirDefError, AirThrown,
    AirPermissionDenied, AirProxyUnresolved, AirUnstorable, AirStreamError,
    AirAgentError,
    air_match, check_anchor, params_of, raw_symbols, head_symbol,
    is_keyword, is_wildcard, is_raw_symbol,
    air_register_extern!, AirPromise, AirFuture, AirRegex, AirBytes,
    AirTensor, AirReservation,
    open_airdb!, close_airdb!

end # module AirLang
