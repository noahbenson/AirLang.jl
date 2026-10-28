################################################################################
# builtins.jl
#
# The builtin table. Builtins are head-dispatched (a form whose first sequence
# element is a builtin's symbol) and reserved: a `def` cannot shadow one.
#
# An *eager* builtin receives its arguments already reduced; a *special* form
# receives the raw call and reduces what it chooses (needed by `def`, `let`,
# `if`, `set`, and friends).
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    Builtin

A built-in operation. `special` distinguishes a special form (raw call,
`fn(env, scope, call)`) from an eager builtin (reduced args,
`fn(env, scope, args)`). An `overridable` builtin lets a user rule of the same
head take precedence (used by `get`).
"""
struct Builtin
    name::Symbol
    special::Bool
    overridable::Bool
    fn::Function
end

const BUILTINS = Dict{Symbol,Builtin}()

"""
    builtin!(name, fn; overridable=false)

Register an eager builtin: `fn(env, scope, args::Vector{Form}) -> Form`.
"""
builtin!(name::Symbol, fn::Function; overridable::Bool = false) =
    (BUILTINS[name] = Builtin(name, false, overridable, fn))

"""
    special!(name, fn; overridable=false)

Register a special form: `fn(env, scope, call::FormContainer) -> Form`.
"""
special!(name::Symbol, fn::Function; overridable::Bool = false) =
    (BUILTINS[name] = Builtin(name, true, overridable, fn))

# Apply a builtin to a call form. Eager builtins get their sequence arguments
# reduced first; special forms get the raw call.
function apply_builtin(env::Env, scope::Scope, b::Builtin, call::FormContainer)
    if b.special
        return b.fn(env, scope, call)
    else
        args = Form[air_reduce(env, scope, to_form(x)) for x in _sx(call.seq, 2:length(call.seq))]
        return b.fn(env, scope, args)
    end
end

# ---- the hold-aware operation family -----------------------------------------
#
# Every collection operation that takes a primary form argument comes in a plain
# version `F` and a `hold-F` version. The primary form's root hold is treated as
# transparent when the operation runs "inside a hold": for `hold-F` always, and
# for `F` when the `hold=true` option is given. In that mode inserted held values
# contribute their content, and the result is held (the `hold=` option selects
# this for `hold-F` too; its default is true there and false for `F`).
const HOLD_KEY = Symbol(":hold")

# The `depth=` option shared by the level-aware verbs: `0` is the subject
# itself, `n > 0` every node at depth `n` (see `_map_at_depth`).
const DEPTH_KEY = Symbol(":depth")

# The `list=` option of the repetition verbs: return the accumulated values.
const LIST_KEY = Symbol(":list")

# Read the `depth=` option of a call, reducing its value; `default` when absent.
function _depth_opt(env::Env, scope::Scope, call::FormContainer, name::AbstractString,
                    default::Integer)
    haskey(call.map, DEPTH_KEY) || return Int(default)
    l = _leafof(air_reduce(env, scope, to_form(call.map[DEPTH_KEY])))
    (l isa Integer && l >= 0) ||
        throw(AirEvalError("$name: depth must be a non-negative integer"))
    return Int(l)
end

# Reject options a verb does not understand, so a typo cannot pass silently.
function _check_options(call::FormContainer, name::AbstractString, allowed)
    for k in keys(call.map)
        k in allowed ||
            throw(AirEvalError("$name: unknown option $(air_string(Form(k)))"))
    end
    return nothing
end

function _hold_mode(call::FormContainer, is_hold_fn::Bool)
    opt = haskey(call.map, HOLD_KEY) ? _hold_opt(call) : nothing
    is_hold_fn && return (true, opt === nothing ? true : opt)
    h = opt !== nothing && opt
    return (h, h)
end

# The call's reduced sequence arguments (without the head).
_call_args(env::Env, scope::Scope, call::FormContainer) =
    Form[air_reduce(env, scope, to_form(v)) for v in _sx(call.seq, 2:length(call.seq))]

# Register `F` and `hold-F` on one implementation:
# `impl(env, scope, call, is_hold_fn) -> Form`.
function _hold_pair!(name::Symbol, impl::Function)
    special!(name, (env, scope, call) -> impl(env, scope, call, false))
    special!(Symbol("hold-" * String(name)),
             (env, scope, call) -> impl(env, scope, call, true))
end

# ---- argument helpers --------------------------------------------------------

_arg(args, i, name) = length(args) >= i ? args[i] :
    throw(AirEvalError("$(name) expects at least $i argument(s)"))

_num(x::Form, name) = (l = _leafof(x); l isa Number ? l :
    throw(AirEvalError("$(name) expects a number, got $(air_string(x))")))

_bool(b::Bool) = Form(b)
