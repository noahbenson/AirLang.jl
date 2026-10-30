################################################################################
# equality.jl
#
# Air *equivalence* and the hash that goes with it. The `==` operator stays
# content equality (`(1 == 1.0)` is true); `eq?` is equivalence, and it is
# AirDB's `isequiv` — one relation, shared with the database:
#
#   * two leaves are equivalent when they have the same type and an equal value,
#     so `1` and `1.0` are not equivalent while `NaN` is equivalent to itself and
#     `-0.0` to `0.0` (AirDB normalizes a signed zero, as `==` does);
#   * two containers are equivalent when their sequences are elementwise
#     equivalent and their maps hold equivalent values under the same keys
#     (map order does not matter — a form's map is unordered);
#   * a volatile, actor, promise, or stream is equivalent only to itself, and an
#     immutable extern follows the equality its type registered (AirLang interns
#     equal regexes, so two equal patterns are the same value);
#   * a delay compares by its type and serialization and is never forced;
#   * `same?` remains object identity (`===`), which is stricter than `eq?`.
#
# The hash used by `(hash x)` and by equivalence-keyed tables follows exactly
# this relation (`equivhash`): a leaf hashes its value together with its type, a
# container hashes its structure, and a mutable hashes its identity without ever
# descending into it. An immutable form that *contains* a mutable object is
# therefore still hashable: the mutable part contributes only its identity.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# Equivalence and the hash consistent with it are AirDB's, so air and the
# database agree on what "the same value" means. These two names are the whole
# air-level relation; `eq?`, `(hash …)`, and the `_EqKey` tables use them.
_eq(a::Form, b::Form) = AirDB.isequiv(a, b)
_eq_hash(x::Form, h::UInt = zero(UInt)) = AirDB.equivhash(x, h)

# Content equality is AirDB's `==` on forms: numeric-friendly, so `1` and `1.0`
# are equal, `-0.0` and `0.0` are equal, and a `NaN` is not equal to itself (as
# in Julia). It is also what the database uses, so a form compares the same way
# in air and in storage. `isequal` would instead keep a signed zero apart at the
# top level while merging it inside a container.
_eq_content(a::Form, b::Form) = a == b

# ---- structural sameness -----------------------------------------------------
#
# The reducer's fixed-point test answers "did this rebuild change anything?", so
# a leaf must compare equal to itself. AirDB's container `isequal` compares its
# children with `==` (`collections.jl:39`), which is *content* equality: `1` and
# `1.0` are the same value there, and a `NaN` is not equal even to itself, so a
# form holding a `NaN` is never `isequal` to itself and every rebuild of it looks
# like a change. `_same_value` descends with `isequal` at the leaves instead, so
# a no-op rebuild is recognized as one.
_same_value(a::Form, b::Form) =
    (a isa FormContainer && b isa FormContainer) ? _same_contents(a, b) :
    (a isa FormContainer || b isa FormContainer) ? false : isequal(a, b)
_same_value(a, b) = isequal(_plain_leaf(a), _plain_leaf(b))

_plain_leaf(x) = x isa FormScalar ? value(x) : x

function _same_contents(a::FormContainer, b::FormContainer)
    (length(a.seq) == length(b.seq) && length(a.map) == length(b.map)) || return false
    for i in eachindex(a.seq)
        _same_value(a.seq[i], b.seq[i]) || return false
    end
    for (k, v) in a.map
        (haskey(b.map, k) && _same_value(v, b.map[k])) || return false
    end
    return true
end

# A form used as a `Dict` key under equivalence rather than `isequal` (which
# would merge `1` and `1.0`). `_eq_hash` never descends into a mutable object, so
# such a key is safe to hash.
struct _EqKey
    form::Form
end

Base.isequal(a::_EqKey, b::_EqKey) = _eq(a.form, b.form)
Base.hash(a::_EqKey, h::UInt) = hash(_eq_hash(a.form, zero(UInt)), h)
