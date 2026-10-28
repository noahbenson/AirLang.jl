################################################################################
# operators.jl
#
# The basic operators. An operator's canonical form is the *infix* binary form
# `(a OP b)`; the prefix form `(OP a b …)` is sugar and is normalized.
#
# Operators are symbolic: when the operands are numbers they compute, and
# otherwise the form is returned unchanged (with its operands reduced).
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    Operator

A basic operator: its `name` and its `kind` — `:arith` (`+ - * / ^ // mod`),
`:eq` (`==`), `:neq` (`!=`), `:ident` (`===`), `:nident` (`!==`), or `:ord`
(`< > <= >=`). The only symbols that may contain `=` are these four.
"""
struct Operator
    name::Symbol
    kind::Symbol
end

const OPERATORS = Dict{Symbol,Operator}(
    Symbol("+") => Operator(Symbol("+"), :arith),
    Symbol("-") => Operator(Symbol("-"), :arith),
    Symbol("*") => Operator(Symbol("*"), :arith),
    Symbol("/") => Operator(Symbol("/"), :arith),
    Symbol("^") => Operator(Symbol("^"), :arith),
    Symbol("//") => Operator(Symbol("//"), :arith),
    Symbol("mod") => Operator(Symbol("mod"), :arith),
    Symbol("==") => Operator(Symbol("=="), :eq),
    Symbol("!=") => Operator(Symbol("!="), :neq),
    Symbol("===") => Operator(Symbol("==="), :ident),
    Symbol("!==") => Operator(Symbol("!=="), :nident),
    Symbol("and") => Operator(Symbol("and"), :and),
    Symbol("or") => Operator(Symbol("or"), :or),
    Symbol("<") => Operator(Symbol("<"), :ord),
    Symbol(">") => Operator(Symbol(">"), :ord),
    Symbol("<=") => Operator(Symbol("<="), :ord),
    Symbol(">=") => Operator(Symbol(">="), :ord),
)

# The operator symbols that may contain `=` (comparisons); every other symbol
# treats `=` as the key/value separator.
const EQ_SYMBOLS = Set([Symbol("=="), Symbol("!="), Symbol("==="), Symbol("!=="),
                        Symbol("<="), Symbol(">=")])

# Identity (`===`): strict equality of scalars (so `1 === 1.0` is false), and
# structural equality for containers.
function _identical(a::Form, b::Form)
    (a isa FormScalar && b isa FormScalar) && return value(a) === value(b)
    return isequal(a, b)
end

# The operator symbol in the middle of a 3-element infix form, or `nothing`.
function infix_operator(x::FormContainer)
    (length(x.seq) == 3 && isempty(x.map)) || return nothing
    # A form whose head is a builtin is a call, not an infix expression — so
    # `(partial + 1)` calls `partial`, while `(1 + 1)` is addition.
    h = x.seq[1]
    hs = h isa Symbol ? h :
        (h isa FormScalar && value(h) isa Symbol ? value(h) : nothing)
    (hs !== nothing && haskey(BUILTINS, hs)) && return nothing
    m = x.seq[2]
    s = m isa Symbol ? m :
        (m isa FormScalar && value(m) isa Symbol ? value(m) : nothing)
    (s !== nothing && haskey(OPERATORS, s)) ? s : nothing
end

_mk_infix(name::Symbol, a::Form, b::Form) =
    Form(PVector{Any}([a, Form(name), b]), PDict{Symbol,Any}())

_mk_prefix(name::Symbol, args) =
    Form(PVector{Any}([Form(name), args...]), PDict{Symbol,Any}())

function _arith(name::Symbol, x::Number, y::Number)
    name == Symbol("+") && return x + y
    name == Symbol("-") && return x - y
    name == Symbol("*") && return x * y
    name == Symbol("/") && return x / y
    name == Symbol("^") && return x ^ y
    name == Symbol("//") && return div(x, y)
    name == Symbol("mod") && return mod(x, y)
    throw(AirEvalError("unknown arithmetic operator $name"))
end

function _ord(name::Symbol, x, y)
    name == Symbol("<") && return x < y
    name == Symbol(">") && return x > y
    name == Symbol("<=") && return x <= y
    return x >= y
end

# Evaluate the infix form `(a OP b)` with reduced operands. Returns `nothing` when
# the operands are not both numbers, so the reducer falls through to the user rules
# (a rule anchored on the operator may still match).
function op_infix(name::Symbol, a::Form, b::Form)::Union{Nothing,Form}
    op = OPERATORS[name]
    op.kind == :eq && return Form(isequal(a, b))
    op.kind == :neq && return Form(!isequal(a, b))
    op.kind == :ident && return Form(_identical(a, b))
    op.kind == :nident && return Form(!_identical(a, b))
    la, lb = _leafof(a), _leafof(b)
    if la isa Number && lb isa Number
        op.kind == :arith && return to_form(_arith(name, la, lb))
        return Form(_ord(name, la, lb))
    end
    return nothing
end

# Evaluate the prefix form `(OP args…)` with reduced arguments.
function op_prefix(env::Env, scope::Scope, name::Symbol, args::Vector{Form})::Form
    op = OPERATORS[name]
    n = length(args)
    if op.kind == :eq
        n <= 1 && return Form(true)
        return Form(all(isequal(args[i], args[i + 1]) for i in 1:(n - 1)))
    elseif op.kind == :neq
        n <= 1 && return Form(true)
        return Form(all(!isequal(args[i], args[i + 1]) for i in 1:(n - 1)))
    elseif op.kind == :ident
        n <= 1 && return Form(true)
        return Form(all(_identical(args[i], args[i + 1]) for i in 1:(n - 1)))
    elseif op.kind == :nident
        n <= 1 && return Form(true)
        return Form(all(!_identical(args[i], args[i + 1]) for i in 1:(n - 1)))
    elseif op.kind == :and
        n == 0 && return Form(true)
        n == 1 && return args[1]
        return air_reduce(env, scope, _fold_infix(name, args))
    elseif op.kind == :or
        n == 0 && return naught
        n == 1 && return args[1]
        return air_reduce(env, scope, _fold_infix(name, args))
    elseif op.kind == :ord
        n <= 1 && return Form(true)
        leaves = [_leafof(a) for a in args]
        all(l -> l isa Number, leaves) || return _mk_prefix(name, args)
        return Form(all(_ord(name, leaves[i], leaves[i + 1]) for i in 1:(n - 1)))
    else
        if n == 0
            return _mk_prefix(name, args)
        elseif n == 1
            l = _leafof(args[1])
            if name == Symbol("-")
                return l isa Number ? Form(-l) : _mk_prefix(name, args)
            elseif name == Symbol("/")
                return l isa Number ? Form(1 / l) : _mk_prefix(name, args)
            else
                return args[1]   # unary `+`, `*`, `^`, …
            end
        else
            return air_reduce(env, scope, _fold_infix(name, args))
        end
    end
end

# Fold `(OP a b c …)` into nested infix `((a OP b) OP c) …`.
function _fold_infix(name::Symbol, args::Vector{Form})
    acc = _mk_infix(name, args[1], args[2])
    for i in 3:length(args)
        acc = _mk_infix(name, acc, args[i])
    end
    return acc
end
