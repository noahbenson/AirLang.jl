# Shared helpers for the UI tests. A widget test opens a form under a key
# without going through air syntax, drives a terminal renderer over a scripted
# byte source, and polls for whatever the render loop applies asynchronously.
const UI_CTRL_J = UInt8(0x0a)
const UI_ENTER = UInt8(0x0d)
const UI_ESC = UInt8(0x1b)
const UI_BACKSPACE = UInt8(0x7f)
const UI_TAB = UInt8(0x09)

# The bytes of a typed string.
ui_bytes(s::AbstractString) = Vector{UInt8}(codeunits(s))

# Open a widget form under `key` without going through air syntax.
function ui_open_form!(env, key::Symbol, w)
    call = AirDB.FormContainer(
        AirDB.FormSeq(AirDB.FormValue[
            AirLang._store_form(Form(Symbol("ui-open"))),
            AirLang._store_form(Form(Symbol(":" * String(key)))),
            AirLang._store_form(w)]),
        AirDB.FormMap())
    return AirLang._bi_ui_open(env, AirLang._base_scope(env), call)
end

# Drive a terminal renderer over a scripted byte source; returns
# `((:ok, result) | (:err, exception), screen_text)`. Unless `settle=false`, wait
# for the widget's background work to land before returning: detaching no longer
# waits for an evaluation, so a test that asserts on its result lets the
# instance's own ticker apply it.
function ui_term_run(env, key::Symbol, bytes; cols = 40, rows = 12, settle = true)
    input = IOBuffer(Vector{UInt8}(bytes))
    out = IOBuffer()
    r = AirLang._TermRenderer(out; cols = Ref(cols), rows = Ref(rows),
                              readbyte = () -> eof(input) ? nothing :
                                          read(input, UInt8))
    inst = AirLang._ui_lookup(env, Form(Symbol(":" * String(key))))
    result = try
        (:ok, AirLang._ui_term_run!(r, inst))
    catch e
        (:err, e)
    end
    screen = String(take!(out))
    settle && ui_wait_idle(env, key)
    return result, screen
end

# Wait until the instance's widget has no background work left (true when it has
# no tree at all, as for an ordinary element UI).
function ui_wait_idle(env, key::Symbol; secs = 30.0)
    inst = AirLang._ui_lookup(env, Form(Symbol(":" * String(key))))
    # Read the job flag under the instance's lock: the ticker clears it and then
    # applies the result in the same locked tick, so an unlocked read can see
    # "idle" just before the widget's state is written.
    return ui_wait_for(() -> lock(inst.lock) do
        tree = inst.tree
        tree === nothing || !AirLang._comp_running(tree)
    end; secs = secs)
end

# The `showerror` text of an error a call throws ("" when it does not).
function ui_errmsg(f)
    try
        f()
        return ""
    catch e
        return sprint(showerror, e)
    end
end

# Poll a predicate the way the render loop polls its components.
function ui_wait_for(f; secs = 30.0)
    t0 = time()
    while time() - t0 < secs
        f() && return true
        sleep(0.01)
    end
    return false
end
