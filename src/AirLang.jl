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
include("builtins_string.jl")
include("builtins_io.jl")
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
include("cli.jl")

export read_air, read_all_air, air_eval, air_repl, air_main, air_string,
    air_pretty_string,
    default_env, Env, Scope, Rule, RuleStore, canonicalize, truthy, naught,
    AirError, AirParseError, AirEvalError, AirDefError, AirThrown,
    AirPermissionDenied, AirProxyUnresolved, AirUnstorable, AirStreamError,
    air_match, check_anchor, params_of, raw_symbols, head_symbol,
    is_keyword, is_wildcard, is_raw_symbol,
    air_register_extern!, AirPromise, AirFuture, AirRegex,
    open_airdb!, close_airdb!

end # module AirLang
