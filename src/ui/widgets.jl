################################################################################
# ui/widgets.jl
#
# The widget catalog: what kinds of element a `(ui …)` tree may name, what
# parameters each kind accepts, what its value type is, and how a value is
# validated. Validation lives here, in air, and nowhere in a renderer.
#
# A kind is described by a `_UiKind`:
#
#   value     :bool, :string, :int, :number, :option, :options, :range, :none —
#             the Julia/air shape of the element's current value; `:none` means
#             the element has no value at all (a button, a label, a container).
#   params    the keyword parameters the kind accepts (including the common and
#             stateful ones).
#   required  the parameters that must be present at instantiation.
#   children  :none, :any, :tab (only `tab` children), or :section.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _UI_K_ID = Symbol(":id")
const _UI_K_LABEL = Symbol(":label")
const _UI_K_DESCRIPTION = Symbol(":description")
const _UI_K_DISABLED = Symbol(":disabled")
const _UI_K_INITVAL = Symbol(":initval")
const _UI_K_ON_CHANGE = Symbol(":on-change")
const _UI_K_ASSERT = Symbol(":assert")
const _UI_K_ON_CLICK = Symbol(":on-click")
const _UI_K_OPTIONS = Symbol(":options")
const _UI_K_MIN = Symbol(":min")
const _UI_K_MAX = Symbol(":max")
const _UI_K_STEP = Symbol(":step")
const _UI_K_ORIENTATION = Symbol(":orientation")
const _UI_K_READOUT = Symbol(":readout")
const _UI_K_CONTINUOUS = Symbol(":continuous-update")
const _UI_K_PLACEHOLDER = Symbol(":placeholder")
const _UI_K_REQUIRED = Symbol(":required")
const _UI_K_ROWS = Symbol(":rows")
const _UI_K_TEXT = Symbol(":text")
const _UI_K_VALUE = Symbol(":value")

# The parameters every kind accepts, and the three that make an element
# stateful.
const _UI_COMMON_PARAMS =
    (_UI_K_ID, _UI_K_LABEL, _UI_K_DESCRIPTION, _UI_K_DISABLED)
const _UI_STATE_PARAMS = (_UI_K_INITVAL, _UI_K_ON_CHANGE, _UI_K_ASSERT)

struct _UiKind
    name::Symbol
    value::Symbol
    params::Tuple{Vararg{Symbol}}
    required::Tuple{Vararg{Symbol}}
    children::Symbol
end

# A stateful kind: it has a current value the user may change.
_ui_kind_mutable(k::_UiKind) = k.value !== :none

const _UI_KIND_LIST = _UiKind[
    # Boolean widgets.
    _UiKind(Symbol("checkbox"), :bool, (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS...),
            (), :none),
    _UiKind(Symbol("toggle"), :bool, (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS...),
            (), :none),
    # Text widgets.
    _UiKind(Symbol("text-input"), :string,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_PLACEHOLDER,
             _UI_K_REQUIRED), (), :none),
    _UiKind(Symbol("text-area"), :string,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_PLACEHOLDER,
             _UI_K_REQUIRED, _UI_K_ROWS), (), :none),
    _UiKind(Symbol("password-input"), :string,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_PLACEHOLDER,
             _UI_K_REQUIRED), (), :none),
    # Numeric widgets.
    _UiKind(Symbol("int-input"), :int,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_MIN, _UI_K_MAX,
             _UI_K_STEP), (_UI_K_INITVAL,), :none),
    _UiKind(Symbol("float-input"), :number,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_MIN, _UI_K_MAX,
             _UI_K_STEP), (_UI_K_INITVAL,), :none),
    _UiKind(Symbol("slider"), :number,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_MIN, _UI_K_MAX,
             _UI_K_STEP, _UI_K_ORIENTATION, _UI_K_READOUT, _UI_K_CONTINUOUS),
            (_UI_K_INITVAL, _UI_K_MIN, _UI_K_MAX), :none),
    _UiKind(Symbol("range-slider"), :range,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_MIN, _UI_K_MAX,
             _UI_K_STEP, _UI_K_ORIENTATION, _UI_K_READOUT, _UI_K_CONTINUOUS),
            (_UI_K_INITVAL, _UI_K_MIN, _UI_K_MAX), :none),
    # Selection widgets. `options` is optional syntax-wise but required by kind.
    _UiKind(Symbol("dropdown"), :option,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_OPTIONS),
            (_UI_K_INITVAL, _UI_K_OPTIONS), :none),
    _UiKind(Symbol("radio-group"), :option,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_OPTIONS),
            (_UI_K_INITVAL, _UI_K_OPTIONS), :none),
    _UiKind(Symbol("multi-select"), :options,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_OPTIONS),
            (_UI_K_OPTIONS,), :none),
    _UiKind(Symbol("selection-slider"), :option,
            (_UI_COMMON_PARAMS..., _UI_STATE_PARAMS..., _UI_K_OPTIONS,
             _UI_K_ORIENTATION, _UI_K_READOUT, _UI_K_CONTINUOUS),
            (_UI_K_INITVAL, _UI_K_OPTIONS), :none),
    # Action widget: no value, but a click handler.
    _UiKind(Symbol("button"), :none,
            (_UI_COMMON_PARAMS..., _UI_K_ON_CLICK), (), :none),
    # Display widgets: read-only values, updated programmatically.
    _UiKind(Symbol("label"), :none,
            (_UI_COMMON_PARAMS..., _UI_K_TEXT), (_UI_K_TEXT,), :none),
    _UiKind(Symbol("progress"), :none,
            (_UI_COMMON_PARAMS..., _UI_K_VALUE, _UI_K_MIN, _UI_K_MAX),
            (_UI_K_VALUE,), :none),
    _UiKind(Symbol("status"), :none,
            (_UI_COMMON_PARAMS..., _UI_K_VALUE), (), :none),
    # Layout widgets.
    _UiKind(Symbol("column"), :none, _UI_COMMON_PARAMS, (), :any),
    _UiKind(Symbol("row"), :none, _UI_COMMON_PARAMS, (), :any),
    _UiKind(Symbol("group"), :none, _UI_COMMON_PARAMS, (), :any),
    _UiKind(Symbol("tabs"), :none, _UI_COMMON_PARAMS, (), :tab),
    _UiKind(Symbol("tab"), :none, _UI_COMMON_PARAMS, (), :any),
    _UiKind(Symbol("accordion"), :none, _UI_COMMON_PARAMS, (), :section),
    _UiKind(Symbol("section"), :none, _UI_COMMON_PARAMS, (), :any),
]

const _UI_KINDS = Dict{String,_UiKind}(String(k.name) => k for k in _UI_KIND_LIST)

"""
    _ui_kind(name) -> _UiKind

The catalog entry for `name`, or an error naming it.
"""
function _ui_kind(name::Symbol)
    k = get(_UI_KINDS, String(name), nothing)
    k === nothing && throw(AirEvalError("unknown UI widget type $(air_string(Form(name)))"))
    return k
end

# ---- reading parameters ------------------------------------------------------

# A parameter's leaf, or `nothing` when it is not a scalar.
_ui_param_leaf(params, k) = haskey(params, k) ? _leafof(params[k]) : nothing

_ui_param_bool(params, k) = (l = _ui_param_leaf(params, k); l isa Bool ? l : nothing)

function _ui_param_number(params, k)
    l = _ui_param_leaf(params, k)
    (l isa Number && !(l isa Bool)) || return nothing
    return l
end

# The value of an integer parameter, or `nothing`.
_ui_param_int(params, k) = (l = _ui_param_leaf(params, k);
                            (l isa Integer && !(l isa Bool)) ? Int(l) : nothing)

# A number leaf of a form (used on a value, not a parameter).
_ui_number(x::Form) = (l = _leafof(x); (l isa Number && !(l isa Bool)) ? l : nothing)
_ui_int(x::Form) = (l = _leafof(x); (l isa Integer && !(l isa Bool)) ? l : nothing)
_ui_string(x::Form) = (l = _leafof(x); l isa AbstractString ? String(l) : nothing)
_ui_bool(x::Form) = (l = _leafof(x); l isa Bool ? l : nothing)

# Whether a form is a sequence of elements (an ordinary container), with its
# elements; `nothing` otherwise. `naught` is the empty sequence.
function _ui_seq_elements(x::Form)
    isequal(x, naught) && return Form[]
    x isa FormContainer || return nothing
    isempty(x.map) || return nothing
    return Form[to_form(v) for v in x.seq]
end

# A form holding exactly these sequence elements (`naught` when empty).
_ui_seq_form(els::Vector{Form}) =
    isempty(els) ? naught :
    FormContainer(FormSeq(FormValue[_store_form(e) for e in els]), FormMap())

# ---- options -----------------------------------------------------------------

# Normalize an `options=` parameter to a vector of `(label, value)` pairs. An
# element that is a two-element form `("Label" value)` carries an explicit
# label; anything else is a bare value whose label is its printed spelling.
function _ui_options(params)
    o = get(params, _UI_K_OPTIONS, nothing)
    o === nothing && throw(AirEvalError("a selection widget needs options="))
    els = _ui_seq_elements(o)
    els === nothing && throw(AirEvalError(
        "options= must be a sequence of values or (label value) forms"))
    out = Tuple{String,Form}[]
    for e in els
        if e isa FormContainer && isempty(e.map) && length(e.seq) == 2
            l = to_form(e.seq[1])
            v = to_form(e.seq[2])
            push!(out, (_ui_display_text(l), v))
        else
            push!(out, (_ui_display_text(e), e))
        end
    end
    return out
end

# The natural display spelling of a value: a string as its own text, anything
# else through the air printer.
function _ui_display_text(x::Form)
    l = _leafof(x)
    l isa AbstractString && return String(l)
    return air_string(x)
end

# Whether `value` is one of the option values.
function _ui_is_option(opts, value::Form)
    for (_, v) in opts
        _eq(v, value) && return true
    end
    return false
end

# ---- validation --------------------------------------------------------------

# Whether `v` is aligned to the `step=` grid based at `min` (or 0). A floating
# tolerance keeps binary fractions usable.
function _ui_step_ok(params, v::Number)
    step = _ui_param_number(params, _UI_K_STEP)
    step === nothing && return true
    step == 0 && return true
    base = something(_ui_param_number(params, _UI_K_MIN), 0)
    q = (Float64(v) - Float64(base)) / Float64(step)
    return abs(q - round(q)) <= 1e-9 * max(1.0, abs(q))
end

function _ui_bounds_ok(params, v::Number, what::AbstractString)
    lo = _ui_param_number(params, _UI_K_MIN)
    hi = _ui_param_number(params, _UI_K_MAX)
    lo === nothing || v >= lo || return "$what must be at least $lo"
    hi === nothing || v <= hi || return "$what must be at most $hi"
    return nothing
end

"""
    _ui_validate(kind, params, value) -> Union{Nothing, String}

Air's own validation of an incoming value for an element of `kind` with the
given evaluated parameters. `nothing` means the value is acceptable; a string
is a human-readable reason. Renderers never validate.
"""
function _ui_validate(kind::_UiKind, params, value::Form)
    v = kind.value
    if v === :bool
        _ui_bool(value) === nothing && return "expected a Boolean"
        return nothing
    elseif v === :string
        s = _ui_string(value)
        s === nothing && return "expected a string"
        if _ui_param_bool(params, _UI_K_REQUIRED) === true && isempty(s)
            return "a value is required"
        end
        return nothing
    elseif v === :int
        n = _ui_int(value)
        n === nothing && return "expected an integer"
        return _ui_bounds_ok(params, n, "value")
    elseif v === :number
        n = _ui_number(value)
        n === nothing && return "expected a number"
        r = _ui_bounds_ok(params, n, "value")
        r === nothing || return r
        _ui_step_ok(params, n) || return "value must align to the step"
        return nothing
    elseif v === :option
        _ui_is_option(_ui_options(params), value) ||
            return "value is not one of the options"
        return nothing
    elseif v === :options
        els = _ui_seq_elements(value)
        els === nothing && return "expected a sequence of option values"
        opts = _ui_options(params)
        for e in els
            _ui_is_option(opts, e) || return "value is not one of the options"
        end
        return nothing
    elseif v === :range
        els = _ui_seq_elements(value)
        (els === nothing || length(els) != 2) &&
            return "expected a two-element range (lower upper)"
        lo = _ui_number(els[1]); hi = _ui_number(els[2])
        (lo === nothing || hi === nothing) && return "range bounds must be numbers"
        lo <= hi || return "lower bound must not exceed upper bound"
        for (x, what) in ((lo, "lower bound"), (hi, "upper bound"))
            r = _ui_bounds_ok(params, x, what)
            r === nothing || return r
            _ui_step_ok(params, x) || return "$what must align to the step"
        end
        return nothing
    end
    return nothing
end

# The value an element starts with when `initval` is absent, or `nothing` when
# the kind has no default (so `initval` is required).
function _ui_default_value(kind::_UiKind)
    kind.value === :bool && return Form(false)
    kind.value === :string && return Form("")
    kind.value === :options && return naught
    return nothing
end

# ---- parameter checking ------------------------------------------------------

# Check the parameters of one element: unknown keys are an error naming the
# kind, and a parameter that is present but malformed is an error naming it.
function _ui_check_params(kind::_UiKind, params)
    allowed = kind.params
    for k in keys(params)
        k in allowed || throw(AirEvalError(
            "ui $(air_string(Form(kind.name))): unknown parameter $(air_string(Form(k)))"))
    end
    for k in kind.required
        haskey(params, k) || throw(AirEvalError(
            "ui $(air_string(Form(kind.name))): missing required parameter $(air_string(Form(k)))"))
    end
    hk(k) = haskey(params, k)
    if hk(_UI_K_DISABLED)
        _ui_param_bool(params, _UI_K_DISABLED) === nothing && throw(AirEvalError(
            "ui $(kind.name): disabled= must be a Boolean"))
    end
    if hk(_UI_K_ORIENTATION)
        o = _ui_param_leaf(params, _UI_K_ORIENTATION)
        (o === :horizontal || o === :vertical) || throw(AirEvalError(
            "ui $(kind.name): orientation= must be :horizontal or :vertical"))
    end
    for b in (_UI_K_READOUT, _UI_K_CONTINUOUS, _UI_K_REQUIRED)
        hk(b) && _ui_param_bool(params, b) === nothing && throw(AirEvalError(
            "ui $(kind.name): $(b) must be a Boolean"))
    end
    for n in (_UI_K_MIN, _UI_K_MAX, _UI_K_STEP)
        if hk(n)
            _ui_param_number(params, n) === nothing && throw(AirEvalError(
                "ui $(kind.name): $(n) must be a number"))
        end
    end
    if hk(_UI_K_STEP)
        s = _ui_param_number(params, _UI_K_STEP)
        s > 0 || throw(AirEvalError("ui $(kind.name): step= must be positive"))
    end
    if hk(_UI_K_ROWS)
        r = _ui_param_int(params, _UI_K_ROWS)
        (r !== nothing && r > 0) || throw(AirEvalError(
            "ui $(kind.name): rows= must be a positive integer"))
    end
    for s in (_UI_K_PLACEHOLDER, _UI_K_TEXT)
        hk(s) && _ui_string(params[s]) === nothing && throw(AirEvalError(
            "ui $(kind.name): $(s) must be a string"))
    end
    if hk(_UI_K_OPTIONS)
        _ui_options(params)          # validates the shape
    end
    if hk(_UI_K_MIN) && hk(_UI_K_MAX)
        lo = _ui_param_number(params, _UI_K_MIN)
        hi = _ui_param_number(params, _UI_K_MAX)
        lo <= hi || throw(AirEvalError("ui $(kind.name): min= exceeds max="))
    end
    return nothing
end
