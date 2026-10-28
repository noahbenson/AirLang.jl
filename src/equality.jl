################################################################################
# equality.jl
#
# Air *equivalence* and the hash that goes with it. The `==` operator stays
# content equality (`(1 == 1.0)` is true); `eq?` is equivalence:
#
#   * two scalars are equivalent when their values are the same **and** their
#     types agree, so `1` and `1.0` are not equivalent (a string, symbol,
#     keyword, boolean, or `naught` compares by value);
#   * two containers are equivalent when their sequences are elementwise
#     equivalent and their maps hold equivalent values under the same keys
#     (map order does not matter — a form's map is unordered);
#   * a volatile is equivalent only to a volatile with the same identity, and
#     an extern (a promise, regex, socket, …) only to one wrapping the same
#     underlying object;
#   * `same?` remains object identity (`===`), which is stricter than `eq?`.
#
# The hash used by `(hash x)` and by equivalence-keyed tables follows exactly
# this relation: a scalar hashes its value together with its type, a container
# hashes its structure, and a volatile or extern hashes its identity without
# ever descending into the mutable object. An immutable form that *contains* a
# mutable object is therefore still hashable: the mutable part contributes only
# its identity, which never changes.
#
# MIT License
# Copyright (c) 2026 Noah C. Benson

# Two leaves (the values a scalar form holds) are equivalent when they have the
# same type and `isequal` value. Requiring the type is what keeps `1` and `1.0`
# distinct; `isequal` is what makes `NaN` equivalent to itself.
_eq_leaf(a::FormLeaf, b::FormLeaf) =
    typeof(a) === typeof(b) && isequal(a, b)

function _eq(a::Form, b::Form)
    a === b && return true
    if a isa FormScalar
        return b isa FormScalar && _eq_leaf(value(a), value(b))
    elseif a isa FormContainer
        b isa FormContainer || return false
        length(a.seq) == length(b.seq) || return false
        for i in 1:length(a.seq)
            _eq(to_form(a.seq[i]), to_form(b.seq[i])) || return false
        end
        length(a.map) == length(b.map) || return false
        for (k, v) in a.map
            haskey(b.map, k) || return false
            _eq(to_form(v), to_form(b.map[k])) || return false
        end
        return true
    elseif a isa VolatileForm
        return b isa VolatileForm && a.id == b.id
    elseif a isa FormExtern
        return b isa FormExtern && isequal(a, b)
    elseif a isa ActorForm
        return b isa ActorForm && a.id == b.id
    elseif a isa PromiseForm
        return b isa PromiseForm && a.id == b.id
    elseif a isa DelayForm
        # A delay compares by its serialization, never by forcing it: two delays
        # that would compute the same value are still distinct computations.
        return b isa DelayForm && a.type === b.type && _eq(a.form, b.form)
    end
    return false
end

const _EQ_SCALAR_TAG = Symbol("air-scalar")
const _EQ_CONTAINER_TAG = Symbol("air-container")
const _EQ_VOLATILE_TAG = Symbol("air-volatile")
const _EQ_EXTERN_TAG = Symbol("air-extern")
const _EQ_ACTOR_TAG = Symbol("air-actor")
const _EQ_PROMISE_TAG = Symbol("air-promise")
const _EQ_DELAY_TAG = Symbol("air-delay")

function _eq_hash(x::Form, h::UInt)
    if x isa FormScalar
        v = value(x)
        return hash(v, hash(typeof(v), hash(_EQ_SCALAR_TAG, h)))
    elseif x isa FormContainer
        h = hash(length(x.seq), hash(_EQ_CONTAINER_TAG, h))
        for v in x.seq
            h = _eq_hash(to_form(v), h)
        end
        # The map is unordered, so combine its entries commutatively.
        acc = zero(UInt)
        for (k, v) in x.map
            acc ⊻= hash(k, _eq_hash(to_form(v), zero(UInt)))
        end
        return hash(length(x.map), hash(acc, h))
    elseif x isa VolatileForm
        return hash(x.id, hash(_EQ_VOLATILE_TAG, h))
    elseif x isa FormExtern
        # AirDB's extern hash already uses the handle's id (or `objectid` when
        # it has none); it matches that type's `isequal`.
        return hash(x, hash(_EQ_EXTERN_TAG, h))
    elseif x isa ActorForm
        return hash(x.id, hash(_EQ_ACTOR_TAG, h))
    elseif x isa PromiseForm
        return hash(x.id, hash(_EQ_PROMISE_TAG, h))
    elseif x isa DelayForm
        return _eq_hash(x.form, hash(x.type, hash(_EQ_DELAY_TAG, h)))
    end
    return hash(_EQ_SCALAR_TAG, h)
end

# A form used as a `Dict` key under equivalence rather than `isequal` (which
# would merge `1` and `1.0`). `_eq_hash` never descends into a mutable object, so
# such a key is safe to hash.
struct _EqKey
    form::Form
end

Base.isequal(a::_EqKey, b::_EqKey) = _eq(a.form, b.form)
Base.hash(a::_EqKey, h::UInt) = hash(_eq_hash(a.form, zero(UInt)), h)
