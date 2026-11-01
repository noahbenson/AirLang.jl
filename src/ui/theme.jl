################################################################################
# ui/theme.jl
#
# The semantic palette. Widgets name roles (`:string`, `:comment`, `:user-bg`,
# `:focus`, …); the renderer resolves them to a `_UiStyle` at draw time. The
# default is ANSI-16 plus a few 256-color background tints, so it works on any
# xterm-compatible terminal; `(ui-theme! string=:bright_yellow …)` recolors the
# process, and a widget may carry its own `theme=` map.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

const _UI_THEME_LOCK = ReentrantLock()

const _UI_THEME = Dict{Symbol,_UiStyle}()

# The palette as shipped, so `(ui-theme)` can spell a role as a bare color when
# only its foreground departs from the default and as a map when more does.
const _UI_THEME_DEFAULTS = Dict{Symbol,_UiStyle}()

function _ui_theme_defaults!()
    d = _UI_THEME_DEFAULTS
    empty!(d)
    d[:text] = _UiStyle()
    d[:muted] = _UiStyle(fg = :bright_black)
    d[:accent] = _UiStyle(fg = :bright_blue, bold = true)
    d[:string] = _UiStyle(fg = :green)
    d[:comment] = _UiStyle(fg = :bright_black)
    d[:number] = _UiStyle(fg = :magenta)
    d[:keyword] = _UiStyle(fg = :cyan)
    d[:wildcard] = _UiStyle(fg = :yellow)
    d[:symbol] = _UiStyle()
    d[:paren1] = _UiStyle(fg = :bright_blue)
    d[:paren2] = _UiStyle(fg = :bright_magenta)
    d[:paren3] = _UiStyle(fg = :bright_cyan)
    d[:paren4] = _UiStyle(fg = :bright_green)
    d[:error] = _UiStyle(fg = :bright_red, bold = true)
    d[:success] = _UiStyle(fg = :bright_green)
    d[:warning] = _UiStyle(fg = :bright_yellow)
    d[:selection] = _UiStyle(bg = :blue)
    d[:cursor] = _UiStyle(fg = :black, bg = :white)
    d[:focus] = _UiStyle(reverse = true)
    d[:user_bg] = _UiStyle(bg = :color236)
    d[:peer_bg] = _UiStyle(bg = :color238)
    d[:code_bg] = _UiStyle(bg = :color234)
    d[:tab_active] = _UiStyle(fg = :black, bg = :white, bold = true)
    d[:tab_inactive] = _UiStyle(fg = :bright_black)
    d[:status] = _UiStyle(fg = :bright_black)
    d[:prompt] = _UiStyle(fg = :bright_yellow, bold = true)
    d[:border] = _UiStyle(fg = :bright_black)
    lock(_UI_THEME_LOCK) do
        empty!(_UI_THEME)
        merge!(_UI_THEME, d)
    end
    return nothing
end

_ui_theme_defaults!()

# A widget may carry its own `theme=` map. The renderer installs it here for the
# duration of that widget's draw, so every role lookup inside sees it.
const _UI_THEME_LOCAL = Base.ScopedValues.ScopedValue{Any}(nothing)

# The style for a role; an unknown role is plain text. Keyword arguments replace
# fields: `_ui_role(:muted; bg = :user_bg)`. A widget's installed theme wins over
# the process-global one.
function _ui_role(name::Symbol; kw...)
    st = nothing
    ov = _UI_THEME_LOCAL[]
    ov === nothing || (st = get(ov, name, nothing))
    if st === nothing
        st = lock(_UI_THEME_LOCK) do
            get(_UI_THEME, name, _UI_PLAIN)
        end
    end
    return isempty(kw) ? st : _ui_style_with(st; kw...)
end

function _ui_role_set!(name::Symbol, st::_UiStyle)
    lock(_UI_THEME_LOCK) do
        _UI_THEME[name] = st
    end
    return nothing
end

_ui_role_exists(name::Symbol) = lock(_UI_THEME_LOCK) do
    haskey(_UI_THEME, name)
end

# A style that is a role's background over a role's foreground.
_ui_role_on(bg::Symbol, fg::Symbol) =
    _ui_style_with(_ui_role(fg); bg = _ui_role(bg).bg)

# ---- the air surface ---------------------------------------------------------

# A color keyword or string as the internal spelling `:colorN`/`:bright_yellow`
# (`-` and `_` are interchangeable, and a keyword's leading `:` is dropped).
# `what` names the place in the message, e.g. `"ui-theme!: string"`.
function _ui_theme_color(x::Form, what::AbstractString)
    l = _leafof(x)
    if l isa Symbol || l isa AbstractString
        return Symbol(lstrip(replace(String(l), "-" => "_"), ':'))
    end
    throw(AirEvalError("$what must be a color name"))
end

# The style fields an entry's map may set, and the `_UiStyle` field each names.
# `color=` is a synonym for `fg=`, so naming both is an error.
const _UI_STYLE_FIELDS = Dict{Symbol,Symbol}(
    Symbol(":color") => :fg, Symbol(":fg") => :fg, Symbol(":bg") => :bg,
    Symbol(":bold") => :bold, Symbol(":dim") => :dim,
    Symbol(":italic") => :italic, Symbol(":underline") => :underline,
    Symbol(":reverse") => :reverse)

# One role's entry: a bare color sets the foreground; a map sets the fields it
# names and leaves the rest of the inherited style alone. An entry that names no
# fields at all is an error rather than a silent no-op.
function _ui_theme_style(st::_UiStyle, v::Form, what::AbstractString)
    isequal(v, naught) && throw(AirEvalError("$what names no fields"))
    v isa FormContainer ||
        return _ui_style_with(st; fg = _ui_theme_color(v, what))
    isempty(v.seq) ||
        throw(AirEvalError("$what must be a color or a map of style fields"))
    isempty(v.map) && throw(AirEvalError("$what names no fields"))
    kw = Pair{Symbol,Any}[]
    seen = Symbol[]
    for (fk, fv) in v.map
        fname = Symbol(lstrip(String(fk), ':'))
        field = get(_UI_STYLE_FIELDS, Symbol(":", fname), nothing)
        field === nothing &&
            throw(AirEvalError("$what: unknown field " *
                               air_string(Form(fk))))
        field in seen &&
            throw(AirEvalError("$what names $field twice"))
        push!(seen, field)
        if field === :fg || field === :bg
            push!(kw, field => _ui_theme_color(to_form(fv), "$what: $fname"))
        else
            l = _leafof(to_form(fv))
            l isa Bool ||
                throw(AirEvalError("$what: $fname must be true or false"))
            push!(kw, field => l)
        end
    end
    return _ui_style_with(st; kw...)
end

# One role's stored spelling: a bare color when the foreground is the only thing
# that differs from plain text, else the map of fields that do.
#
# A field is named when it departs from plain text — so a role that carries a
# background or a weight prints as a map, whatever its default is — or when it
# departs from the role's own default, so a role deliberately restored to plain
# text still round-trips through `(ui-theme! reset=true (ui-theme))`.
function _ui_theme_entry_form(st::_UiStyle, base::_UiStyle)
    fields = Pair{Symbol,Form}[]
    fg_named = st.fg !== base.fg || st.fg !== _UI_PLAIN.fg
    bg_named = st.bg !== base.bg || st.bg !== _UI_PLAIN.bg
    fg_named && push!(fields, Symbol(":fg") => Form(st.fg))
    bg_named && push!(fields, Symbol(":bg") => Form(st.bg))
    for (name, a, b, p) in ((:bold, st.bold, base.bold, _UI_PLAIN.bold),
                            (:dim, st.dim, base.dim, _UI_PLAIN.dim),
                            (:italic, st.italic, base.italic, _UI_PLAIN.italic),
                            (:underline, st.underline, base.underline,
                             _UI_PLAIN.underline),
                            (:reverse, st.reverse, base.reverse, _UI_PLAIN.reverse))
        (a !== b || a !== p) || continue
        push!(fields, Symbol(":", name) => Form(a))
    end
    if isempty(fields) ||
       (length(fields) == 1 && first(fields).first === Symbol(":fg"))
        return Form(st.fg)
    end
    return _ns_form(Form[], fields)
end

# `(ui-theme)` — the current palette as `(theme role=entry …)`.
function _bi_ui_theme(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-theme", ())
    length(call.seq) == 1 || throw(AirEvalError("ui-theme takes no arguments"))
    pairs = Pair{Symbol,Form}[]
    lock(_UI_THEME_LOCK) do
        for k in sort!(collect(keys(_UI_THEME)))
            base = get(_UI_THEME_DEFAULTS, k, _UI_PLAIN)
            push!(pairs, Symbol(":", replace(String(k), "_" => "-")) =>
                         _ui_theme_entry_form(_UI_THEME[k], base))
        end
    end
    return _ns_form(Form[Form(:theme)], pairs)
end
special!(Symbol("ui-theme"), _bi_ui_theme)

# Install a whole theme map: `(theme role=entry …)`, or the bare map.
function _ui_theme_install!(v::Form, what::AbstractString)
    v isa FormContainer ||
        throw(AirEvalError("$what: a theme must be a map of role entries"))
    if !isempty(v.seq)
        h = _leafof(to_form(v.seq[1]))
        ok = length(v.seq) == 1 &&
             (h === Symbol("theme") || h === Symbol(":theme"))
        ok || throw(AirEvalError(
            "$what: a theme must be a map of role entries"))
    end
    for (k, val) in v.map
        role = Symbol(replace(lstrip(String(k), ':'), "-" => "_"))
        _ui_role_exists(role) ||
            throw(AirEvalError("$what: unknown role " * air_string(Form(k))))
        _ui_role_set!(role, _ui_theme_style(_ui_role(role), to_form(val),
                                            "$what: " * air_string(Form(k))))
    end
    return nothing
end

# `(ui-theme! role=color-or-style-map … [theme])` — set roles process-wide, or
# install a saved theme map. `reset=true` restores the defaults first; the role
# entries are applied after the map, so they win.
function _bi_ui_theme_set(env::Env, scope::Scope, call::FormContainer)
    length(call.seq) <= 2 || throw(AirEvalError(
        "ui-theme! takes role entries, one theme map, and reset="))
    reset = false
    for (k, v) in call.map
        k === Symbol(":reset") || continue
        reset = _leafof(to_form(v)) === true
    end
    reset && _ui_theme_defaults!()
    length(call.seq) == 2 &&
        _ui_theme_install!(air_reduce(env, scope, to_form(call.seq[2])),
                           "ui-theme!")
    for (k, v) in call.map
        k === Symbol(":reset") && continue
        role = Symbol(replace(lstrip(String(k), ':'), "-" => "_"))
        _ui_role_exists(role) ||
            throw(AirEvalError("ui-theme!: unknown role " *
                               air_string(Form(k))))
        _ui_role_set!(role, _ui_theme_style(_ui_role(role), to_form(v),
                                            "ui-theme!: " *
                                            air_string(Form(k))))
    end
    return naught
end
special!(Symbol("ui-theme!"), _bi_ui_theme_set)

# `(ui-theme role)` — one role's style as `(style fg=… bg=… bold=… …)`.
function _bi_ui_theme_role(env::Env, scope::Scope, call::FormContainer)
    _check_options(call, "ui-style", ())
    length(call.seq) == 2 ||
        throw(AirEvalError("ui-style takes a role name"))
    l = _leafof(air_reduce(env, scope, to_form(call.seq[2])))
    l isa Symbol || throw(AirEvalError("ui-style: role must be a keyword"))
    role = Symbol(replace(String(l), ':' => "", "-" => "_"))
    st = _ui_role(role)
    pairs = Pair{Symbol,Form}[
        Symbol(":fg") => Form(st.fg), Symbol(":bg") => Form(st.bg),
        Symbol(":bold") => Form(st.bold), Symbol(":dim") => Form(st.dim),
        Symbol(":italic") => Form(st.italic),
        Symbol(":underline") => Form(st.underline),
        Symbol(":reverse") => Form(st.reverse)]
    return _ns_form(Form[Form(:style)], pairs)
end
special!(Symbol("ui-style"), _bi_ui_theme_role)
