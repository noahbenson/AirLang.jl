# The `tensor` extern: a mutable N-dimensional numeric array with Julia-like
# arithmetic, broadcasting, and a curated `LinearAlgebra` surface. A tensor is
# mutated only under a reservation: `{t : …}` is an inline read reservation and
# `{t :! …}` a write reservation that returns a promise-like value.
@testset "tensors" begin
    env = Env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    rd(s) = air_string(read_air(s))

    # ---- reader literals -----------------------------------------------------
    @test rd("[1 2 3]") == "(tensor-literal (' ~1 ~2 ~3))"
    @test rd("[1 2; 3 4]") == "(tensor-literal (' (~1 ~2) (~3 ~4)))"
    @test rd("[1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12]") ==
        "(tensor-literal (' ((~1 ~2) (~3 ~4) (~5 ~6)) ((~7 ~8) (~9 ~10) (~11 ~12))))"
    @test rd("[]") == "(tensor-literal ('))"
    @test rd("[a (+ 1 1)]") == "(tensor-literal (' ~a ~(+ 1 1)))"
    @test rd("{t : 1}") == "(reserve-read (t) 1)"
    @test rd("{a b :! 2}") == "(reserve (a b) 2)"
    @test rd("{a : b :! 2}") == "(reserve (a b) 2 read=(a))"
    @test rd("{a :! b : 2}") == "(reserve (a b) 2 read=(b))"
    @test_throws AirParseError read_air("[1 2")
    @test_throws AirParseError read_air("[1 2)")
    @test_throws AirParseError read_air("{t}")
    @test_throws AirParseError read_air("{: 1}")
    @test_throws AirParseError read_air("{t : 1")
    @test_throws AirParseError read_air("]")

    # ---- construction --------------------------------------------------------
    @test ev("[1 2 3]") == "#<tensor 3 Int64>"
    @test ev("[1 2; 3 4]") == "#<tensor 2×2 Int64>"
    @test ev("[1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12]") == "#<tensor 2×3×2 Int64>"
    @test ev("[]") == "#<tensor 0 Float64>"
    @test ev("(tensor? [1 2])") == "true"
    @test ev("(tensor? 3)") == "false"
    @test ev("(tensor? (table))") == "false"
    @test ev("(tensor-rank [1 2; 3 4])") == "2"
    @test ev("(tensor-rank [1 2 3])") == "1"
    @test ev("(tensor-shape [1 2; 3 4])") == "(2 2)"
    @test ev("(tensor-shape [])") == "(0)"
    @test ev("(tensor-shape [1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12])") == "(2 3 2)"
    # Cells evaluate, nested groups are axes, and contents round-trip.
    @test ev("(tensor->form [1 (+ 1 1)])") == "(1 2)"
    @test ev("(tensor->form [1 2; 3 4])") == "((1 2) (3 4))"
    @test ev("(tensor->form [1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12])") ==
        "(((1 2) (3 4) (5 6)) ((7 8) (9 10) (11 12)))"
    @test ev("(tensor->form (tensor [1 2; 3 4]))") == "((1 2) (3 4))"
    # A ragged literal and non-numeric cell are loud.
    @test ev("(do [1 2; 3] (except ?e :caught))") == ":caught"
    @test ev("(do [:a 2] (except ?e :caught))") == ":caught"
    @test ev("(do (tensor [1 (a=2)]) (except ?e :caught))") == ":caught"

    # ---- element types -------------------------------------------------------
    @test ev("(tensor-eltype [1 2])") == "int64"
    @test ev("(tensor-eltype [1 2.5])") == "float64"
    @test ev("(tensor-eltype [1//2 2])") == "rational64"
    @test ev("(tensor-eltype [99999999999999999999])") == "bigint"
    @test ev("(tensor-eltype [1.0+2.0i])") == "complex64"
    @test ev("(tensor-eltype [true false])") == "bool"
    @test ev("(tensor-eltype (tensor [1 2] eltype=:float64))") == "float64"
    @test ev("(tensor->form (tensor [1 2] eltype=:float64))") == "(1.0 2.0)"
    @test ev("(tensor-eltype (tensor [] eltype=:bigint))") == "bigint"
    @test ev("(do (tensor [1] eltype=:bogus) (except ?e :caught))") == ":caught"

    # ---- generators ----------------------------------------------------------
    @test ev("(tensor-shape (tensor-zeros 2 3))") == "(2 3)"
    @test ev("(get (tensor-ones 2) 1)") == "1.0"
    @test ev("(get (tensor-fill 7 (2 2)) 2 2)") == "7"
    @test ev("(tensor-eltype (tensor-fill 7 (2 2)))") == "int64"
    @test ev("(tensor-shape (tensor-eye 3))") == "(3 3)"
    @test ev("(get (tensor-eye 3) 2 2)") == "1.0"
    @test ev("(get (tensor-eye 3) 1 2)") == "0.0"
    @test ev("(tensor-shape (tensor-eye 2 3))") == "(2 3)"
    @test ev("(do (tensor-zeros -1) (except ?e :caught))") == ":caught"

    # ---- get -----------------------------------------------------------------
    @test ev("(get [1 2; 3 4] 1 1)") == "1"
    @test ev("(get [1 2; 3 4] 2 2)") == "4"
    @test ev("(get [1 2; 3 4] -1 -1)") == "4"
    @test ev("(tensor->form (get [1 2; 3 4] 1))") == "(1 2)"
    @test ev("(tensor->form (get [1 2; 3 4] : 2))") == "(2 4)"
    @test ev("(tensor->form (get [1 2; 3 4] (1 2) 2))") == "(2 4)"
    @test ev("(get [1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12] 2 1 2)") == "8"
    @test ev("(tensor->form (get [1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12] 2 (1 2) 2))") ==
        "(8 10)"
    @test ev("(get [1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12] 2 3 2)") == "12"
    @test ev("(get [1 2 3] 5 default=:none)") == ":none"
    @test ev("(do (get [1 2 3] 5) (except ?e :caught))") == ":caught"
    @test ev("(do (get [1 2; 3 4] 1 2 1) (except ?e :caught))") == ":caught"
    # `0` is the tensor itself; `:` is a copy; and a tensor has one handle.
    @test ev("(let (t=[1 2; 3 4]) (same? t (get t 0)))") == "true"
    @test ev("(let (t=[1 2; 3 4]) (same? t (get t)))") == "true"
    @test ev("(held? (get [1 2; 3 4] 1 hold=true))") == "true"
    @test ev("(let (t=[1 2]) (same? t (tensor-copy t)))") == "false"
    @test ev("(tensor-equal? (tensor-copy [1 2]) [1 2])") == "true"
    @test ev("(let (t=[1 2; 3 4]) (same? t (get t :)))") == "false"
    @test ev("(let (t=[1 2; 3 4]) (eq? t (get t 0)))") == "true"
    @test ev("(get (tensor->form (get [1 2; 3 4] :)) 1 2)") == "2"
    @test ev("(length [1 2; 3 4])") == "4"
    @test ev("(count [1 2; 3 4])") == "4"
    @test ev("(in 3 [1 2; 3 4])") == "true"
    @test ev("(in 9 [1 2; 3 4])") == "false"
    # `get` on a reservation awaits it.
    @test ev("(let (t=[1 2]) (get {t :! (set! t 1 9)}))") == "9"

    # ---- set! ----------------------------------------------------------------
    @test ev("(let (t=[1 2; 3 4]) (do (set! t 1 1 9) (tensor->form t)))") ==
        "((9 2) (3 4))"
    @test ev("(let (t=[1 2; 3 4]) (do (set! t 1 5) (tensor->form t)))") ==
        "((5 5) (3 4))"
    @test ev("(let (t=[1 2; 3 4]) (do (set! t 1 [9 8]) (tensor->form t)))") ==
        "((9 8) (3 4))"
    @test ev("(let (t=[1 2; 3 4]) (do (set! t 5) (tensor->form t)))") ==
        "((5 5) (5 5))"
    @test ev("(let (t=[1 2 3]) (do (set! t 1 9) (same? t t)))") == "true"
    @test ev("(let (t=[1 2]) (do (set! t 1 1.5) (tensor-eltype t)))") == "float64"
    @test ev("(let (t=[1 2]) (do (set! t [3 4]) (tensor->form t)))") == "(3 4)"
    @test ev("(do (let (t=[1 2]) (set! t [1 2 3])) (except ?e :caught))") == ":caught"
    @test ev("(do (let (t=[1 2]) (set! t (1 2 3))) (except ?e :caught))") == ":caught"
    # A write is never legal inside a transaction.
    @test ev("(let (t=[1 2 3]) (do (tx (set! t 1 9)) (except ?e :caught)))") ==
        ":caught"

    # ---- with ----------------------------------------------------------------
    @test ev("(let (t=[1 2; 3 4]) (get (with t (1 2) 99) 1 2))") == "99"
    @test ev("(let (t=[1 2; 3 4]) (do (with t (1 2) 99) (get t 1 2)))") == "2"
    @test ev("(tensor->form (with [1 2; 3 4] 1 5))") == "((5 5) (3 4))"
    @test ev("(tensor->form (with [1 2 3] 2 0))") == "(1 0 3)"
    @test ev("(held? (with [1 2 3] 2 0 hold=true))") == "true"
    @test ev("(do (with [1 2; 3 4] 1 (1 2 3)) (except ?e :caught))") == ":caught"
    @test ev("(do (with [1 2] x=1) (except ?e :caught))") == ":caught"

    # ---- reservations --------------------------------------------------------
    @test ev("(let (t=[1 2 3]) {t : (get t 2)})") == "2"
    @test ev("(let (t=[1 2 3]) (reservation? {t :! (set! t 1 9)}))") == "true"
    @test ev("(reservation? 3)") == "false"
    @test ev("(let (t=[1 2 3]) (let (r={t :! (set! t 1 9)}) (get r)))") == "9"
    @test ev("(let (t=[1 2 3]) (let (r={t :! (set! t 1 9)}) (await r)))") == "9"
    @test ev("(let (t=[1 2 3]) (let (r={t :! (set! t 1 9)}) (do (await r) (ready? r))))") ==
        "true"
    @test ev("(let (t=[1 2 3]) (reserve-read (t) (get t 1)))") == "1"
    # A mixed reservation reads `a` and writes `b`.
    @test ev("(let (a=[1 2] b=[3 4]) (let (r={a : b :! (set! b 1 9)}) (get r)))") == "9"
    @test ev("(let (a=[1 2] b=[3 4]) (do {a : b :! (set! b 1 9)} (get a 1)))") == "1"
    # An undeclared tensor is refused, read or write.
    @test ev("(let (u=(await (task [1 2 3]))) (do (get u 1) (except ?e :caught)))") ==
        ":caught"
    @test ev("(let (u=(await (task [1 2 3]))) (do (set! u 1 9) (except ?e :caught)))") ==
        ":caught"
    @test ev("(let (u=(await (task [1 2 3]))) (get {u : (get u 2)}))") == "2"
    @test ev("(let (u=(await (task [1 2 3]))) (get {u :! (set! u 1 9)}))") == "9"
    @test ev("(let (t=[1 2] u=(await (task [3 4]))) " *
             "(do {t : (get u 1)} (except ?e :caught)))") == ":caught"
    @test ev("(let (t=[1 2] u=(await (task [3 4]))) " *
             "(do (get {t :! (set! t 1 (get u 1))}) (except ?e :caught)))") ==
        ":caught"
    # A read reservation is transaction-safe; an undeclared read is not required
    # for a tensor this task made itself.
    @test ev("(let (t=[1 2 3]) (tx (get t 2)))") == "2"
    # Reservations do not nest.
    @test ev("(let (t=[1 2]) (do {t : {t : 1}} (except ?e :caught)))") == ":caught"
    # Awaiting a pending reservation inside a transaction raises. A reservation
    # made inside a transaction is commit-gated, so it is certainly pending.
    @test ev("(tx (let (t=[1 2]) (let (r={t :! (set! t 1 9)}) " *
             "(do (get r) (except ?e :caught)))))") == ":caught"
    # Two write reservations on one tensor serialize, and the second sees the
    # first's write.
    @test ev("(let (u=(await (task [0 0]))) " *
             "(let (r1={u :! (set! u 1 (+ (get u 1) 1))}) " *
             "(let (r2={u :! (set! u 1 (+ (get u 1) 1))}) " *
             "(do (get r1) (get r2)))))") == "2"
    # A write in a reservation is visible to a later read reservation.
    @test ev("(let (u=(await (task [1 2]))) " *
             "(let (r={u :! (set! u 1 9)}) (do (get r) {u : (get u 1)})))") == "9"
    # A reservation made in a discarded transaction never runs.
    @test ev("(let (u=(await (task [1 2]))) " *
             "(do (sandbox {u :! (set! u 1 9)}) {u : (get u 1)}))") == "1"

    # ---- iteration -----------------------------------------------------------
    @test ev("(for (x [1 2; 3 4]) x)") == "(1 3 2 4)"
    @test ev("(map (?x -> (x + 1)) [1 2 3])") == "(2 3 4)"
    @test ev("(filter (?x -> (x > 1)) [1 2 3])") == "(2 3)"
    @test ev("(reduce ((?a ?b) -> (a + b)) 0 [1 2; 3 4])") == "10"
    @test ev("(each (?x -> x) [1 2])") == "naught"
    @test ev("(first [1 2; 3 4])") == "1"
    @test ev("(last [1 2; 3 4])") == "4"
    @test ev("(second [1 2; 3 4])") == "3"
    @test ev("(third [1 2 3])") == "3"
    @test ev("(rest [1 2 3])") == "(2 3)"
    @test ev("(nth [1 2; 3 4] 2)") == "3"
    @test ev("(nth [1 2; 3 4] 0)") == "#<tensor 2×2 Int64>"
    @test ev("(sum [1 2; 3 4])") == "10"
    @test ev("(product [1 2; 3 4])") == "24"
    @test ev("(mean [1 2; 3 4])") == "2.5"
    @test ev("(median [1 2; 3 4])") == "2.5"
    @test ev("(variance [1 2 3])") == "1.0"
    # A tensor is not silently a sequence.
    @test ev("(do (join [1 2] (3)) (except ?e :caught))") == ":caught"
    @test ev("(do (merge [1 2] (a=1)) (except ?e :caught))") == ":caught"
    @test ev("(do (update-in [1 2] 0 (?x -> x)) (except ?e :caught))") == ":caught"

    # ---- arithmetic and broadcasting -----------------------------------------
    @test ev("(tensor->form (+ [1 2; 3 4] 10))") == "((11 12) (13 14))"
    @test ev("(tensor->form (10 + [1 2]))") == "(11 12)"
    @test ev("(tensor->form (+ [1 2] [3 4]))") == "(4 6)"
    @test ev("(tensor->form (- [5 6] 1))") == "(4 5)"
    @test ev("(tensor->form (10 - [1 2]))") == "(9 8)"
    @test ev("(tensor->form (/ [2.0 4.0] 2))") == "(1.0 2.0)"
    @test ev("(tensor->form (* [1 2] 3))") == "(3 6)"
    @test ev("(tensor->form (3 * [1 2]))") == "(3 6)"
    @test ev("(tensor->form (^ [1 2 3] 2))") == "(1 4 9)"
    @test ev("(tensor->form (mod [1 2 3 4] 2))") == "(1 0 1 0)"
    @test ev("(tensor->form (- [1 2]))") == "(-1 -2)"
    @test ev("(tensor->form (/ [2.0 4.0]))") == "(0.5 0.25)"
    # `*` follows Julia for ranks <= 2; rank > 2 raises.
    @test ev("(tensor->form (* [1 2; 3 4] [5 6; 7 8]))") == "((19 22) (43 50))"
    @test ev("(tensor->form (* [1 2; 3 4] [1 2]))") == "(5 11)"
    @test ev("(tensor->form (* [1 2] [1 2; 3 4]))") == "(7 10)"
    @test ev("(* [1 2 3] [4 5 6])") == "32"
    @test ev("(do (* [1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12] " *
             "[1 2; 3 4; 5 6 ;; 7 8; 9 10; 11 12]) (except ?e :caught))") ==
        ":caught"
    # `//` and the ordering comparisons stay symbolic; `==` is identity.
    @test ev("(// [1 2] 2)") == "(#<tensor 2 Int64> // 2)"
    @test ev("(let (t=[1 2]) (== t t))") == "true"
    @test ev("(== [1 2] [1 2])") == "false"
    @test ev("(tensor-equal? [1 2] [1 2])") == "true"
    @test ev("(tensor-equal? [1 2] [1 3])") == "false"
    @test ev("(tensor-equal? [1 2] [1 2 3])") == "false"
    @test ev("(tensor-close? [1.0 2.0] [1.0 2.0000001] atol=0.001)") == "true"
    @test ev("(tensor-close? [1.0 2.0] [1.0 3.0])") == "false"
    @test ev("(tensor-mul [1 2] [3 4])") == "#<tensor 2 Int64>"
    @test ev("(tensor->form (tensor-mul [1 2] [3 4]))") == "(3 8)"
    @test ev("(tensor->form (tensor-map (?x -> (x * 2)) [1 2]))") == "(2 4)"

    # ---- math ----------------------------------------------------------------
    @test ev("(tensor->form (abs [-1 2]))") == "(1 2)"
    @test ev("(tensor->form (sqrt [4.0 9.0]))") == "(2.0 3.0)"
    @test ev("(tensor->form (floor [1.5 2.5]))") == "(1.0 2.0)"
    @test ev("(min [1 2])") == "1"                    # aggregate
    @test ev("(min [3 1 2])") == "1"
    @test ev("(tensor->form (max [1 2] 5))") == "(5 5)"
    @test ev("(tensor->form (div [4 6] 2))") == "(2 3)"
    @test ev("(tensor->form (gcd [12 18] 6))") == "(6 6)"

    # ---- scalar math broadcasting -------------------------------------------
    @test ev("(tensor->form (sin [0.0 0.0]))") == "(0.0 0.0)"
    @test ev("(tensor->form (exp [0.0]))") == "(1.0)"
    @test ev("(tensor->form (log [1.0]))") == "(0.0)"
    @test ev("(tensor->form (log1p [0.0]))") == "(0.0)"
    @test ev("(tensor->form (expm1 [0.0]))") == "(0.0)"
    @test ev("(tensor->form (sinh [0.0]))") == "(0.0)"
    @test ev("(tensor->form (tanh [0.0]))") == "(0.0)"
    @test ev("(tensor->form (cbrt [8.0 -27.0]))") == "(2.0 -3.0)"
    @test ev("(tensor->form (rem [7 8] [3 3]))") == "(1 2)"
    @test ev("(tensor->form (hypot [3.0 5.0] [4.0 12.0]))") == "(5.0 13.0)"
    @test ev("(tensor->form (clamp [1 5 9] 2 8))") == "(2 5 8)"
    @test ev("(tensor->form (round [1.234 5.678] digits=1))") == "(1.2 5.7)"
    @test ev("(tensor->form (round [1.234 5.678] sigdigits=2))") == "(1.2 5.7)"
    @test ev("(tensor->form (real [1.0+2.0i 3.0+4.0i]))") == "(1.0 3.0)"
    @test ev("(tensor->form (imag [1.0+2.0i 3.0+4.0i]))") == "(2.0 4.0)"
    @test ev("(tensor->form (conj [1.0+2.0i]))") == "(1.0-2.0i)"
    @test ev("(tensor->form (abs [1.0+2.0i]))") == "(2.23606797749979)"
    # Elementwise predicates return a Bool tensor.
    @test ev("(tensor->form (isnan [1.0 nan]))") == "(false true)"
    @test ev("(tensor->form (isfinite [1.0 inf]))") == "(true false)"
    @test ev("(tensor->form (isinteger [1.0 1.5]))") == "(true false)"
    @test ev("(tensor-eltype (isnan [1.0]))") == "bool"

    # ---- comparison masks and where ------------------------------------------
    @test ev("(tensor->form (tensor-lt [1 4] [2 3]))") == "(true false)"
    @test ev("(tensor->form (tensor-le [1 2] [1 3]))") == "(true true)"
    @test ev("(tensor->form (tensor-gt [1 2] [1 3]))") == "(false false)"
    @test ev("(tensor->form (tensor-ge [1 2] [1 3]))") == "(true false)"
    @test ev("(tensor->form (tensor-eq [1 2] [1 3]))") == "(true false)"
    @test ev("(tensor->form (tensor-ne [1 2] [1 3]))") == "(false true)"
    @test ev("(tensor->form (tensor-where [true false] 1 2))") == "(1 2)"
    @test ev("(tensor->form (tensor-where (tensor-gt [1 5] 3) [0 0] [1 1]))") ==
        "(1 0)"
    @test ev("(do (tensor-lt 1 2) (except ?e :caught))") == ":caught"

    # ---- axis reductions -----------------------------------------------------
    @test ev("(sum [1 2; 3 4])") == "10"
    @test ev("(tensor->form (sum [1 2; 3 4] dims=1))") == "((4 6))"
    @test ev("(tensor->form (sum [1 2; 3 4] dims=2))") == "((3) (7))"
    @test ev("(tensor->form (sum [1 2; 3 4] dims=1 drop=true))") == "(4 6)"
    @test ev("(tensor->form (sum [1 2; 3 4] dims=:all))") == "((10))"
    # A negative axis counts from the end; several axes reduce together.
    @test ev("(tensor->form (sum [1 2; 3 4] dims=-1))") == "((3) (7))"
    @test ev("(tensor->form (sum [1 2; 3 4] dims=(2 1)))") == "((10))"
    @test ev("(sum [1 2; 3 4] dims=(1 2) drop=true)") == "10"
    @test ev("(tensor->form (product [1 2; 3 4] dims=1))") == "((3 8))"
    @test ev("(tensor->form (mean [1 2; 3 4] dims=2))") == "((1.5) (3.5))"
    @test ev("(tensor->form (median [1 2 3; 4 5 6] dims=1))") == "((2.5 3.5 4.5))"
    @test ev("(variance [1.0 2.0 3.0 4.0] ddof=0)") == "1.25"
    @test ev("(variance [1.0 2.0 3.0 4.0])") == "1.6666666666666667"
    @test ev("(std [1.0 2.0 3.0 4.0])") == "1.2909944487358056"
    @test ev("(tensor->form (min [3 1; 2 4] dims=1))") == "((2 1))"
    @test ev("(tensor->form (max [3 1; 2 4] dims=2 drop=true))") == "(3 4)"
    @test ev("(tensor->form (mean [1 2; 3 4] dims=1 drop=true))") == "(2.0 3.0)"

    # ---- truth reductions ----------------------------------------------------
    @test ev("(tensor-any [0 0])") == "false"
    @test ev("(tensor-all [1 2])") == "true"
    @test ev("(tensor-count [0 1 2])") == "2"
    @test ev("(tensor->form (tensor-any [0 1; 0 0] dims=1))") == "((false true))"
    @test ev("(tensor->form (tensor-all [1 1; 0 1] dims=2))") == "((true) (false))"
    @test ev("(tensor->form (tensor-count [0 1 2; 3 0 0] dims=1))") ==
        "((1 1 1))"

    # ---- cumulative operations -----------------------------------------------
    @test ev("(tensor->form (tensor-cumsum [1 2 3]))") == "(1 3 6)"
    @test ev("(tensor->form (tensor-cumsum [1 2; 3 4] dims=1))") == "((1 2) (4 6))"
    @test ev("(tensor->form (tensor-cumsum [1 2; 3 4] dims=2))") == "((1 3) (3 7))"
    @test ev("(tensor->form (tensor-cumprod [1 2 3]))") == "(1 2 6)"
    @test ev("(tensor->form (tensor-diff [1 4 9 16]))") == "(3 5 7)"
    @test ev("(tensor->form (tensor-diff [1 4; 9 16] dims=1))") == "((8 12))"

    # ---- construction helpers ------------------------------------------------
    @test ev("(tensor->form (tensor-arange 5))") == "(0 1 2 3 4)"
    @test ev("(tensor->form (tensor-arange 2 6))") == "(2 3 4 5)"
    @test ev("(tensor->form (tensor-arange 0 10 3))") == "(0 3 6 9)"
    @test ev("(tensor->form (tensor-arange 0.0 1.0 0.25))") == "(0.0 0.25 0.5 0.75)"
    @test ev("(tensor->form (tensor-linspace 0 1 n=5))") == "(0.0 0.25 0.5 0.75 1.0)"
    @test ev("(tensor->form (tensor-linspace 0 1 n=4 endpoint=false))") ==
        "(0.0 0.25 0.5 0.75)"
    @test ev("(tensor-shape (tensor-randint 0 10 3 3))") == "(3 3)"
    @test ev("(tensor->form (tensor-randint 5 6 4))") == "(5 5 5 5)"

    # ---- manipulation --------------------------------------------------------
    @test ev("(tensor->form (tensor-concat [1 2] [3 4] [5 6]))") ==
        "(1 2 3 4 5 6)"
    @test ev("(tensor-shape (tensor-concat [1 2; 3 4] [5 6; 7 8] axis=2))") ==
        "(2 4)"
    @test ev("(tensor->form (tensor-stack [1 2] [3 4]))") == "((1 2) (3 4))"
    @test ev("(tensor->form (tensor-stack [1 2] [3 4] axis=2))") ==
        "((1 3) (2 4))"
    @test ev("(tensor->form (tensor-flip [1 2; 3 4]))") == "((4 3) (2 1))"
    @test ev("(tensor->form (tensor-flip [1 2; 3 4] axis=2))") == "((2 1) (4 3))"
    @test ev("(tensor->form (tensor-roll [1 2; 3 4] 1 axis=1))") ==
        "((3 4) (1 2))"
    @test ev("(tensor-shape (tensor-tile [1 2 3] 2 3))") == "(2 9)"
    @test ev("(tensor->form (tensor-squeeze (reshape [1 2 3] (1 3))))") ==
        "(1 2 3)"
    @test ev("(tensor->form (tensor-expand-dims [1 2 3] 1))") == "((1 2 3))"
    @test ev("(tensor->form (tensor-expand-dims [1 2 3] 2))") == "((1) (2) (3))"
    @test ev("(tensor->form (tensor-diag [1 2 3; 4 5 6]))") == "(1 5)"
    @test ev("(tensor->form (tensor-diag [1 2 3; 4 5 6] k=1))") == "(2 6)"
    @test ev("(tensor-shape (tensor-diagm [1 2 3]))") == "(3 3)"
    @test ev("(tensor-shape (tensor-diagm [1 2 3] k=-1))") == "(4 4)"
    @test ev("(tensor->form (tensor-tril [1 2; 3 4]))") == "((1 0) (3 4))"
    @test ev("(tensor->form (tensor-triu [1 2; 3 4]))") == "((1 2) (0 4))"
    @test ev("(tensor->form (tensor-tril [1 2; 3 4] k=1))") == "((1 2) (3 4))"
    @test ev("(tensor->form (tensor-argsort [3 1 2]))") == "(2 3 1)"
    @test ev("(tensor->form (tensor-argsort [3 1 2] descending=true))") == "(1 3 2)"
    @test ev("(tensor-argmax [3 1; 2 4])") == "4"
    @test ev("(tensor-argmin [3 1; 2 4])") == "3"
    @test ev("(tensor->form (tensor-argmax [3 1; 2 4] dims=1))") == "((1 4))"
    @test ev("(tensor->form (tensor-argmin [3 1; 2 4] dims=2 drop=true))") ==
        "(3 2)"

    # ---- generic verbs on tensors --------------------------------------------
    @test ev("(tensor->form (sort [3 1 2]))") == "(1 2 3)"
    @test ev("(tensor->form (sort [3 1; 2 4] dims=1))") == "((2 1) (3 4))"
    @test ev("(tensor->form (sort [3 1; 2 4] dims=2 descending=true))") ==
        "((3 1) (4 2))"
    @test ev("(tensor->form (reverse [1 2 3]))") == "(3 2 1)"
    @test ev("(tensor->form (reverse [1 2; 3 4] dims=1))") == "((3 4) (1 2))"
    @test ev("(tensor->form (transpose (reshape [1 2 3 4 5 6] (2 3 1)) " *
             "perm=(3 2 1)))") == "(((1 2) (3 4) (5 6)))"

    # ---- extra LinearAlgebra -------------------------------------------------
    @test ev("(tensor->form (eigvals [2.0 0.0; 0.0 3.0]))") == "(2.0 3.0)"
    @test ev("(tensor->form (svdvals [3.0 0.0; 0.0 4.0]))") == "(4.0 3.0)"
    @test ev("(tensor->form (pinv [1.0 0.0; 0.0 2.0]))") ==
        "((1.0 0.0) (0.0 0.5))"
    @test ev("(tensor-shape (nullspace [1.0 0.0; 0.0 1.0]))") == "(2 0)"
    @test ev("(matrix-cond [1.0 0.0; 0.0 2.0])") == "2.0"
    @test ev("(tensor->form (cross [1 0 0] [0 1 0]))") == "(0 0 1)"
    @test ev("(tensor->form (kron [1 2] [3 4]))") == "(3 4 6 8)"
    @test ev("(let (f=(lu [1.0 2.0; 3.0 4.0])) " *
             "(tensor->form (* (get f :L) (get f :U))))") ==
        "((3.0 4.0) (1.0 2.0))"
    @test ev("(let (f=(lu [1.0 2.0; 3.0 4.0])) (get f :p))") == "#<tensor 2 Int64>"
    @test ev("(isposdef [2.0 0.0; 0.0 2.0])") == "true"
    @test ev("(isposdef [1.0 0.0; 0.0 -1.0])") == "false"
    @test ev("(issymmetric [1 2; 2 1])") == "true"
    @test ev("(ishermitian [1 2; 2 1])") == "true"
    @test ev("(dot [1 2; 3 4] [1 2; 3 4])") == "30"
    @test ev("(do (eigvals [1.0 2.0 3.0]) (except ?e :caught))") == ":caught"

    # ---- in-place map and clamp ----------------------------------------------
    @test ev("(let (t=[1 2 3]) (do (tensor-map! (?x -> (x + 1)) t) " *
             "(tensor->form t)))") == "(2 3 4)"
    @test ev("(let (t=[1 2 3]) (do (tensor-map! (?x -> (/ x 2)) t) " *
             "(tensor->form t)))") == "(0.5 1.0 1.5)"
    @test ev("(let (t=[1 5 9]) (do (tensor-clamp! t 2 8) (tensor->form t)))") ==
        "(2 5 8)"
    # An escaped tensor needs a write reservation.
    @test ev("(let (u=(await (task [1 2 3]))) " *
             "(do (tensor-map! (?x -> (x + 1)) u) (except ?e :caught)))") ==
        ":caught"

    # ---- reservation safety of the new verbs ---------------------------------
    @test ev("(let (u=(await (task [1 2]))) " *
             "(do (tensor-concat u [3 4]) (except ?e :caught)))") == ":caught"
    @test ev("(let (u=(await (task [1 2]))) " *
             "{u : (tensor->form (tensor-concat u [3 4]))})") == "(1 2 3 4)"
    @test ev("(let (u=(await (task [1 2; 3 4]))) " *
             "(do (tensor-diag u) (except ?e :caught)))") == ":caught"
    @test ev("(let (u=(await (task [3 1 2]))) (do (sort u) (except ?e :caught)))") ==
        ":caught"

    # ---- option errors -------------------------------------------------------
    @test ev("(do (sum [1 2; 3 4] dims=3) (except ?e :caught))") == ":caught"
    @test ev("(do (min [1 2] [3 4] dims=1) (except ?e :caught))") == ":caught"
    @test ev("(do (tensor-flip [1 2] axis=2) (except ?e :caught))") == ":caught"
    @test ev("(do (tensor-concat [1 2] [1 2; 3 4]) (except ?e :caught))") ==
        ":caught"
    @test ev("(do (tensor-squeeze (1 2)) (except ?e :caught))") == ":caught"
    @test ev("(do (tensor-tile [1 2] -1) (except ?e :caught))") == ":caught"
    @test ev("(do (tensor-diff [1 2] dims=(1 2)) (except ?e :caught))") ==
        ":caught"

    # ---- LinearAlgebra -------------------------------------------------------
    @test ev("(det [1.0 2.0; 3.0 4.0])") == "-2.0"
    @test ev("(tr [1.0 2.0; 3.0 4.0])") == "5.0"
    @test ev("(norm [3 4])") == "5.0"
    @test ev("(norm [3 4] 1)") == "7.0"
    @test ev("(dot [1 2 3] [4 5 6])") == "32"
    @test ev("(get (inv [1.0 0.0; 0.0 4.0]) 2 2)") == "0.25"
    @test ev("(tensor->form (transpose [1 2 3]))") == "((1 2 3))"
    @test ev("(tensor-shape (transpose [1 2 3]))") == "(1 3)"
    @test ev("(tensor->form (transpose [1 2; 3 4]))") == "((1 3) (2 4))"
    @test ev("(tensor-shape (adjoint [1 2 3]))") == "(1 3)"
    @test ev("(tensor-shape (reshape [1 2; 3 4] (4)))") == "(4)"
    @test ev("(do (reshape [1 2; 3 4] (3)) (except ?e :caught))") == ":caught"
    @test ev("(tensor->form (linsolve [2.0 0.0; 0.0 4.0] [2.0 8.0]))") == "(1.0 2.0)"
    @test ev("(get (eigen [2.0 0.0; 0.0 3.0]) :values)") == "#<tensor 2 Float64>"
    @test ev("(tensor-shape (get (eigen [2.0 0.0; 0.0 3.0]) :vectors))") == "(2 2)"
    @test ev("(tensor-shape (get (svd [1.0 2.0; 3.0 4.0]) :S))") == "(2)"
    @test ev("(tensor-shape (get (qr [1.0 2.0; 3.0 4.0]) :Q))") == "(2 2)"
    @test ev("(tensor->form (cholesky [4.0 0.0; 0.0 9.0]))") == "((2.0 0.0) (0.0 3.0))"
    @test ev("(matrix-rank [1.0 2.0; 2.0 4.0])") == "1"
    @test ev("(do (det [1.0 2.0 3.0]) (except ?e :caught))") == ":caught"

    # ---- in-place verbs ------------------------------------------------------
    @test ev("(let (t=[1 2 3]) (do (tensor-add! t 10) (tensor->form t)))") ==
        "(11 12 13)"
    @test ev("(let (t=[1 2 3]) (do (tensor-sub! t 1) (tensor->form t)))") == "(0 1 2)"
    @test ev("(let (t=[1 2 3]) (do (tensor-mul! t 2) (tensor->form t)))") == "(2 4 6)"
    @test ev("(let (t=[2.0 4.0]) (do (tensor-div! t 2) (tensor->form t)))") ==
        "(1.0 2.0)"
    @test ev("(let (t=[1 2 3]) (do (tensor-scale! t 3) (tensor->form t)))") == "(3 6 9)"
    @test ev("(let (t=[1 2 3]) (do (tensor-copyto! t [9 8 7]) (tensor->form t)))") ==
        "(9 8 7)"
    @test ev("(let (t=[1 2; 3 4]) (do (tensor-copyto! t [9 8; 7 6]) (tensor->form t)))") ==
        "((9 8) (7 6))"
    @test ev("(do (tensor-copyto! [1 2] [3 4 5]) (except ?e :caught))") == ":caught"

    # ---- printing and persistence -------------------------------------------
    @test ev("[1 2 3]") == "#<tensor 3 Int64>"
    @test ev("(let (t=[1 2]) (tensor? (from-json (to-json t))))") == "false"
    # A tensor cannot be stored in an opened database namespace.
    @test ev("(do (open-airdb .tdb memory=true) " *
             "(let (t=[1 2]) (namespace .tdb.work (val vt t))) " *
             "(except (:un-storable ?x) :unstorable))") == ":unstorable"
    @test ev("(close-airdb .tdb)") == "naught"

    # ---- Julia-level checks --------------------------------------------------
    @test AirLang._tower_type(Any[1, 2.5]) == Float64
    @test AirLang._tower_type(Any[1, 1//2]) == Rational{Int64}
    @test AirLang._tower_type(Any[1.0, 2.0 + 0.0im]) == ComplexF64
    @test_throws AirEvalError AirLang._tower_type(Any["x"])
    @test AirLang._canonical_data(Int32[1 2; 3 4]) isa Matrix{Int64}
    @test AirLang._sub_shape(read_air("((1 2) (3 4))")) == [2, 2]
    @test_throws AirEvalError AirLang._sub_shape(read_air("((1 2) (3))"))
end
