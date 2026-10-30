################################################################################
# ui.jl
#
# The abstract user interface: `(ui …)` trees, the runtime that instantiates
# them, and the renderers that present them. See widgets.jl for the catalog,
# core.jl for values/validation/callbacks/assertions, render.jl for the
# renderer protocol and the headless text renderer, and terminal.jl for the
# full-screen renderer used over SSH.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

"""
    _UiRenderer

The protocol a view implements: it reads an instance and reports semantic
events (`(:set id value)`, `(:click id)`, `(:dismiss)`) through
`_ui_dispatch!`. It never validates or stores a value.
"""
abstract type _UiRenderer end

include("ui/widgets.jl")
include("ui/core.jl")
include("ui/render.jl")
include("ui/terminal.jl")
