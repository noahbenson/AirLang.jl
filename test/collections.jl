@testset "collections" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # access
    @test ev("(first (1 2 3))") == "1"
    @test ev("(last (1 2 3))") == "3"
    @test ev("(rest (1 2 3))") == "(2 3)"
    @test ev("(get (1 2 3) 2)") == "2"
    @test ev("(take 2 (1 2 3 4))") == "(1 2)"
    @test ev("(drop-first 1 (1 2 3))") == "(2 3)"
    @test ev("(take-last 2 (1 2 3 4))") == "(3 4)"
    @test ev("(drop-last 1 (1 2 3))") == "(1 2)"
    @test ev("(take-while odd? (1 3 2 5))") == "(1 3)"
    @test ev("(drop-while odd? (1 3 2 5))") == "(2 5)"
    @test ev("(split-at 2 (1 2 3 4))") == "((1 2) (3 4))"

    # combining / ordering
    @test ev("(join (1 2) (3 4))") == "(1 2 3 4)"
    @test ev("(reverse (1 2 3))") == "(3 2 1)"
    @test ev("(sort (3 1 2))") == "(1 2 3)"
    @test ev("(sort-by string (b a c))") == "(a b c)"
    @test ev("(distinct (1 2 1 3 2))") == "(1 2 3)"
    @test ev("(dedupe (1 1 2 2 3))") == "(1 2 3)"
    @test ev("(dedupe (1 2 1))") == "(1 2 1)"
    @test ev("(partition 2 (1 2 3 4 5))") == "((1 2) (3 4) 5)"
    @test ev("(partition-by odd? (1 3 2 4 5))") == "((1 3) (2 4) 5)"  # adjacent groups
    @test ev("(partition-by odd? (2 4 1 3))") == "((2 4) (1 3))"

    # generation / aggregation
    @test ev("(range 3)") == "(0 1 2)"
    @test ev("(range 2 5)") == "(2 3 4)"
    @test ev("(repeat 3 :x)") == "(:x :x :x)"
    @test ev("(count (1 2 3))") == "3"
    @test ev("(sum (1 2 3))") == "6"
    @test ev("(product (1 2 3 4))") == "24"

    # aggregation over a collection (a scalar is a singleton, as for the set ops)
    @test ev("(mean (1 2 3))") == "2.0"
    @test ev("(median (1 2 3))") == "2"
    @test ev("(median (1 2 3 4))") == "2.5"
    @test ev("(min (3 1 2))") == "1"
    @test ev("(max (3 1 2))") == "3"
    @test ev("(count 5)") == "1"

    # maps
    @test ev("(keys (a=1 b=2))") == "(:a :b)"
    @test ev("(vals (a=1 b=2))") == "(1 2)"
    @test ev("(update (a=1) :a inc)") == "(a=2)"
    @test ev("(zipmap (a b) (1 2))") == "(a=1 b=2)"
    @test ev("(invert (a=1 b=2))") == "(1=:a 2=:b)"
    @test ev("(frequencies (a b a))") == "(a=2 b=1)"
    @test ev("(group-by odd? (1 2 3 4))") == "(false=(2 4) true=(1 3))"

    # with / wout: `with` is a setter, `join` merges forms
    @test ev("(join () a=10)") == "(a=10)"           # `()` is `naught`: empty base
    @test ev("(let (a=:x) (join () ~a=10))") == "(x=10)"   # a dynamic key

    # computed keys: `~expr=value`; the expression must yield a keyword
    @test ev("(form ~(keyword (name ?x))=10)") == "(form x=10)"
    @test ev("(let (a=:y) (form ~a=10))") == "(form y=10)"
    @test ev("(let (a=:y) (form ~a = 10))") == "(form y=10)"
    @test ev("(let (a=:y) (form ~(keyword (name a))=10))") == "(form y=10)"
    @test ev("(let (a=:y) (' form ~a=10))") == "(' form y=10)"
    @test_throws AirEvalError air_eval(env, read_air("(let (a=1) (form ~a=10))"))
    @test ev("(wout (a=10) :a)") == "naught"
    @test ev("(join (1 2 c=3 d=4) (a b) c=d)") == "(1 2 a b c=d d=4)"
    @test ev("(wout (1 2 a=3 b=4) :b)") == "(1 2 a=3)"
    @test ev("(wout (1 2 3))") == "(1 2)"
    @test ev("(with (a=(b=1)) (:a :c) 2)") == "(a=(b=1 c=2))"
    @test ev("(wout (a=(b=1 c=2)) (:a :b))") == "(a=(c=2))"

    # integer keys are uniform: 0 is the whole form, 1…n index, negative keys
    # count from the end, n + 1 appends to a setter, and anything further raises
    @test ev("(with (1 2) 0 9)") == "9"
    @test ev("(with (1 2) 3 9)") == "(1 2 9)"
    @test ev("(with (1 2) -1 9)") == "(1 9)"
    @test ev("(nth (1 2 3) -1)") == "3"
    @test ev("(wout (1 2 3) -1)") == "(1 2)"
    @test ev("(update (1 2 3) -1 inc)") == "(1 2 4)"

    # update-in: a deep `update`; the keys name a path, and a missing key is
    # `naught` to the function
    @test ev("(update-in (a=(b 1 2)) :a 2 inc)") == "(a=(b 2 2))"
    @test ev("(update-in (a=(b 1 2)) (:a 2) inc)") == "(a=(b 2 2))"   # path form
    @test ev("(update-in ((1 2) (3 4)) 1 2 inc)") == "((1 3) (3 4))"
    @test ev("(update-in (1 2 3) -1 inc)") == "(1 2 4)"
    @test ev("(update-in (a=1) :a (?x -> (+ x 1)))") == "(a=2)"
    @test ev("(update-in () :a :b (?x -> 1))") == "(a=(b=1))"
    @test ev("(update-in (a=1) :zz (?x -> 5))") == "(a=1 zz=5)"
    @test ev("(update-in (a=1) :a (part + 10))") == "(a=11)"
    @test ev("(unhold (hold-update-in (' (a=1)) :a inc))") == "(a=2)"
    @test_throws AirEvalError air_eval(env, read_air("(update-in (a=1) :a)"))
    @test_throws AirEvalError air_eval(env, read_air("(update-in (a=1) 1.5 inc)"))

    # where: the keys of matching elements, one element per dimension; a
    # dimension with one match is its bare key, and no match is `()`
    @test ev("(where (:a :b :c :d :e) :b)") == "2"
    @test ev("(where (:a :b :b :c) :b)") == "(2 3)"
    @test ev("(where (:a :b :b :c) :z)") == "naught"
    @test ev("(where (a=1 b=2) 2)") == ":b"
    @test ev("(where (a=1 b=2) 1)") == ":a"
    @test ev("(where (:a (:x :y :b) :c) :b depth=2)") == "(2 3)"
    @test ev("(where ((1 2) (3 2)) 2 depth=2)") == "((1 2) (2 2))"
    @test ev("(get (where ((1 2) (3 2)) 2 depth=2) 1)") == "(1 2)"
    @test ev("(get (get (where ((1 2) (3 2)) 2 depth=2) 2) 2)") == "2"
    # the access formula holds for a single match too: the dimension's bare key
    # is a scalar, and a scalar is its own sole element
    @test ev("(let (w=(where (:a :b :c) :b)) (get (get w 1) 1))") == "2"
    # depth 0: the subject itself, named by the whole-form key 0
    @test ev("(where (1 2) (1 2) depth=0)") == "0"
    @test ev("(where 5 5 depth=0)") == "0"
    @test ev("(where (1 2) 9 depth=0)") == "naught"
    @test ev("(get (1 2) (where (1 2) (1 2) depth=0))") == "(1 2)"
    @test_throws AirEvalError air_eval(env, read_air("(where (1 2) 1 depth=-1)"))
    @test_throws AirEvalError air_eval(env, read_air("(where (1 2) 1 depth=:all)"))
    @test_throws AirEvalError air_eval(env, read_air("(where (1 2) 1 extra)"))

    # where-all: a held list of every path at any depth; a path splices into
    # `get`/`update-in`
    @test ev("(where-all (:a :b (:a :b) :c) :b)") == "(' 2 (3 2))"
    @test ev("(where-all (1 (2 (1 2))) 1)") == "(' 1 (2 2 1))"
    @test ev("(where-all (:a :b) :z)") == "naught"
    @test ev("(unhold (where-all (:a :b (:a :b) :c) :b))") == "(2 (3 2))"
    @test ev("(let (p=(unhold (where-all ((1 2) (3 4)) 4))) (get ((1 2) (3 4)) p...))") == "4"
    @test ev("(let (p=(unhold (where-all ((1 2) (3 4)) 4))) (update-in ((1 2) (3 4)) p... inc))") ==
        "((1 2) (3 5))"
    @test ev("(let (p=(unhold (where-all (a=(b 1) c=(b 2)) 2))) (get (a=(b 1) c=(b 2)) p...))") == "2"
    @test_throws AirEvalError air_eval(env, read_air("(where-all (1 2) 1 depth=1)"))

    @test_throws AirEvalError air_eval(env, read_air("(with (1 2) 4 9)"))
    @test_throws AirEvalError air_eval(env, read_air("(with (1 2) -3 9)"))
    @test_throws AirEvalError air_eval(env, read_air("(wout (1 2 3) 4)"))

    # prepend / zip / interleave / flatten
    @test ev("(prepend (3 4) 1 2)") == "(1 2 3 4)"
    @test ev("(prepend () 1)") == "1"
    @test ev("(prepend 2 1)") == "(1 2)"
    @test ev("(zip (1 2) (a b))") == "((1 a) (2 b))"
    @test ev("(zip (1 2 3) (a b))") == "((1 a) (2 b))"
    @test ev("(interleave (1 2) (a b))") == "(1 a 2 b)"
    @test ev("(interleave (1 2) (a b c))") == "(1 a 2 b)"
    @test ev("(flatten ((1 2) (3 (4 5))))") == "(1 2 3 4 5)"
    @test ev("(flatten (1 (2) 3))") == "(1 2 3)"
    @test ev("(flatten ((' a b) 1))") == "((' a b) 1)"   # a hold is data

    # sets
    @test ev("(union (1 2) (2 3))") == "(1 2 3)"
    @test ev("(intersect (1 2 3) (2 3 4))") == "(2 3)"
    @test ev("(difference (1 2 3) (2 4))") == "(1 3)"
    # `()` is `naught`, the empty set (not a one-element set)
    @test ev("(union () (1 2))") == "(1 2)"
    @test ev("(intersect () (1 2))") == "naught"
    @test ev("(difference (1 2) ())") == "(1 2)"

    # subset? / superset? (a scalar is a singleton; `()` is the empty set)
    @test ev("(subset? (1 2) (1 2 3))") == "true"
    @test ev("(subset? (1 4) (1 2 3))") == "false"
    @test ev("(subset? () (1))") == "true"
    @test ev("(subset? (1) ())") == "false"
    @test ev("(subset? (1 1) (1))") == "true"
    @test ev("(subset? 1 (1 2))") == "true"
    @test ev("(superset? (1 2 3) (1 2))") == "true"
    @test ev("(superset? (1) (1 2))") == "false"
    @test ev("(superset? (1 2) 2)") == "true"

    # variance is the sample variance (n - 1), naught when n < 2
    @test ev("(variance (1 2 3 4 5))") == "2.5"
    @test ev("(variance (2 4))") == "2.0"
    @test ev("(variance (1))") == "naught"
    @test ev("(variance (a b))") == "(variance (a b))"

    # shuffle: the same elements in a random order (compare after sorting)
    @test ev("(sort (shuffle (3 1 2)))") == "(1 2 3)"
    @test ev("(count (shuffle (1 2 3 4)))") == "4"
    @test ev("(get (shuffle (a=1 2 3)) :a)") == "1"
    @test ev("(shuffle 5)") == "5"
    @test ev("(shuffle ())") == "naught"

    # map at a requested depth (default 1: sequence elements and map values)
    @test ev("(map (?x -> (wrap x)) (1 2))") == "((wrap 1) (wrap 2))"
    @test ev("(map (?x -> (wrap x)) (1 2) depth=1)") == "((wrap 1) (wrap 2))"
    @test ev("(map (?x -> (wrap x)) (1 2) depth=0)") == "(wrap (1 2))"
    @test ev("(map (?x -> (wrap x)) (a=(1 2) b=3) depth=2)") ==
          "(a=((wrap 1) (wrap 2)) b=(wrap 3))"
    @test ev("(map (?x -> (wrap x)) ((1 2) 3) depth=2)") ==
          "(((wrap 1) (wrap 2)) (wrap 3))"
    @test ev("(map (?x -> (wrap x)) 3)") == "(wrap 3)"
    @test_throws AirEvalError air_eval(env, read_air(
        "(map (?x -> x) (1 2) depth=(0 - 1))"))

    # cases / drop-cases: pattern selection at a level (default 1)
    @test ev("(cases (1 2 3 4) (?x \\ even?))") == "(2 4)"
    @test ev("(cases (1 2 3 4) ((?x \\ even?) -> (10 * x)))") == "(20 40)"
    @test ev("(cases (1 2 3) 2)") == "2"
    @test ev("(cases (1 2 3) 9)") == "naught"
    @test ev("(cases (a=1 b=2 c=3) (?x \\ even?))") == "2"
    @test ev("(cases ((1 2) (3 4)) (?x \\ even?))") == "naught"
    @test ev("(cases ((1 2) (3 4)) (?x \\ even?) depth=2)") == "(2 4)"
    @test ev("(drop-cases (1 2 3 4) (?x \\ even?))") == "(1 3)"
    @test ev("(drop-cases (1 2 3 4) ((?x \\ even?) -> x))") == "(1 3)"
    @test ev("(drop-cases (a=1 b=2 c=3) (?x \\ even?))") == "(a=1 c=3)"
    @test ev("(drop-cases ((1 2) (3 4)) 2 depth=2)") == "(1 (3 4))"
    @test ev("(drop-cases (1 2 3) 9)") == "(1 2 3)"
    @test ev("(drop-cases 3 3)") == "naught"
    @test ev("(drop-cases (1 2 3) ((?x \\ even?) -> x) depth=0)") == "(1 2 3)"
    @test_throws AirEvalError air_eval(env, read_air(
        "(cases (1 2) 2 depth=(0 - 1))"))
    @test_throws AirEvalError air_eval(env, read_air("(cases (1 2) 2 bogus=1)"))
    @test_throws AirEvalError air_eval(env, read_air("(drop-cases (1 2) 2 bogus=1)"))

    # matches-any? walks the whole tree, including the subject itself
    @test ev("(matches-any? (a (b 1)) b)") == "true"
    @test ev("(matches-any? (a (b 1)) c)") == "false"
    @test ev("(matches-any? (a (b 1)) (?x \\ int?))") == "true"
    @test ev("(matches-any? (a=(1 2) b=3) 3)") == "true"
    @test ev("(matches-any? 1 1)") == "true"
    @test ev("(matches-any? (1 2 3) 4)") == "false"
    @test ev("(matches-any? (1 2 3) 4 2)") == "true"
    @test ev("(matches-any? (1 2 3) (?x \\ even?) (?y \\ odd?))") == "true"
    @test ev("(matches-any? (1 3) (?x \\ even?))") == "false"
    @test_throws AirEvalError air_eval(env, read_air("(matches-any? (1 2))"))
    @test_throws AirEvalError air_eval(env, read_air(
        "(matches-any? (1 2) 2 bogus=1)"))

    # a scalar argument is a singleton
    @test ev("(union (1 2) 3)") == "(1 2 3)"
    @test ev("(intersect (1 2 3) 2)") == "2"
    @test ev("(difference (1 2 3) 2)") == "(1 3)"
    @test ev("(join (1 2) 3)") == "(1 2 3)"
end

@testset "collection verbs" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # transpose: columns, stopping at the shortest; a scalar row is a singleton
    @test ev("(transpose ((1 2 3) (4 5 6)))") == "((1 4) (2 5) (3 6))"
    @test ev("(transpose ((1 2) (3 4) (5 6)))") == "((1 3 5) (2 4 6))"
    @test ev("(transpose ((1 2 3) (4 5)))") == "((1 4) (2 5))"
    @test ev("(transpose ())") == "naught"
    @test ev("(transpose 5)") == "5"

    # riffle: a separator between elements, cycled when it is a collection
    @test ev("(riffle (1 3 5) 0)") == "(1 0 3 0 5)"
    @test ev("(riffle (a b c d) (x y))") == "(a x b y c x d)"
    @test ev("(riffle (1) 0)") == "1"
    @test ev("(riffle () 0)") == "naught"
    @test ev("(riffle (1 2 3) ())") == "(1 2 3)"
    @test ev("(riffle (a b) 0 k=1)") == "(a 0 b)"      # the map is kept

    # tuples: Cartesian product; the power form repeats (tuples c n)
    @test ev("(tuples ((a b) (1 2)))") == "((a 1) (a 2) (b 1) (b 2))"
    @test ev("(tuples (a b) 2)") == "((a a) (a b) (b a) (b b))"
    @test ev("(tuples (a b) 1)") == "(a b)"
    @test ev("(tuples (a b) 0)") == "naught"
    @test ev("(tuples ((a b) ()))") == "naught"
    @test ev("(tuples ())") == "naught"
    @test ev("(tuples 5)") == "naught"
    @test_throws AirEvalError air_eval(env, read_air("(tuples (a b) -1)"))

    # subdivide: n + 1 evenly spaced points; symbolic on non-numbers
    @test ev("(subdivide 4)") == "(0.0 0.25 0.5 0.75 1.0)"
    @test ev("(subdivide 2 4)") == "(0.0 0.5 1.0 1.5 2.0)"
    @test ev("(subdivide 1 3 2)") == "(1.0 2.0 3.0)"
    @test ev("(subdivide 0)") == "0.0"
    @test ev("(subdivide x 4)") == "(subdivide x 4)"
    @test ev("(subdivide 1 2 3 4)") == "(subdivide 1 2 3 4)"
    @test_throws AirEvalError air_eval(env, read_air("(subdivide -1)"))

    # count-distinct: like `distinct`, but a count (a scalar is a singleton)
    @test ev("(count-distinct (a b a c b))") == "3"
    @test ev("(count-distinct ())") == "0"
    @test ev("(count-distinct 5)") == "1"

    # gather-by groups all equal keys; split-by is an alias of partition-by
    @test ev("(gather-by odd? (1 2 3 4))") == "((1 3) (2 4))"
    @test ev("(gather-by odd? (2 1 4 3))") == "((2 4) (1 3))"
    @test ev("(gather-by (?x -> 0) (1 2 3))") == "(1 2 3)"
    @test ev("(split-by odd? (1 3 2 4 5))") == "((1 3) (2 4) 5)"
    @test ev("(partition-by odd? (1 3 2 4 5))") == "((1 3) (2 4) 5)"

    # map-thread applies a function across the i-th elements
    @test ev("(map-thread + (1 2) (3 4))") == "(4 6)"
    @test ev("(map-thread (?x -> (* x 2)) (1 2 3))") == "(2 4 6)"
    @test ev("(map-thread list (1 2) (a b) (x y))") == "((list 1 a x) (list 2 b y))"
    @test_throws AirEvalError air_eval(env, read_air("(map-thread +)"))

    # outer is the nested product
    @test ev("(outer * (1 2) (3 4))") == "((3 4) (6 8))"
    @test ev("(outer + (1 2))") == "(1 2)"
    @test ev("(outer list (1 2) (a b))") ==
        "(((list 1 a) (list 1 b)) ((list 2 a) (list 2 b)))"
    @test_throws AirEvalError air_eval(env, read_air("(outer +)"))

    # trampoline bounces on returned functions; a deep chain does not grow the
    # stack, since each step is called after the previous one has returned
    @test ev("(trampoline (?x -> (* x 2)) 5)") == "10"
    ev("(def (countdown ?n) (if (== n 0) :done (? -> (countdown (n - 1)))))")
    @test ev("(trampoline countdown 20000)") == ":done"

    # array builds (f start) … (f start + n - 1)
    @test ev("(array (?x -> (* x x)) 4)") == "(1 4 9 16)"
    @test ev("(array (?x -> (* x 2)) 3 5)") == "(10 12 14)"
    @test ev("(array (?x -> x) 0)") == "naught"
    @test ev("(array (?x -> x) n)") == "(array (?x -> x) n)"
end
