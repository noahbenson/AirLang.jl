using Aqua

# Air and AirDB are local, unregistered checkouts, so the dependency checks that
# assume a registry are disabled (as in AirDB's own Aqua suite).
Aqua.test_all(AirLang;
    deps_compat = false,
    stale_deps = false,
    project_extras = false)
