# The `table` extern: immutable, column-major tabular data with typed columns,
# an optional unique index, and in-band NA markers. A table is plain immutable
# data — every update returns a new table — and the collection verbs treat it as
# a sequence of row maps.
@testset "tables" begin
    env = Env()
    ev(s) = air_string(air_eval(env, read_air(s)))

    # ---- construction --------------------------------------------------------
    @test ev("(table)") == "#table(0×0)"
    @test ev("(table? (table))") == "true"
    @test ev("(table? 3)") == "false"
    # Rows and columns build the same table.
    @test ev("(eq? (table (name=\"a\" age=1) (name=\"b\" age=2)) " *
             "(table name=(\"a\" \"b\") age=(1 2)))") == "true"
    @test ev("(table (name=\"a\" age=1) (name=\"b\" age=2))") ==
        "#table(2×2: age, name)"
    @test ev("(columns (table b=(1) a=(2)))") == "(:a :b)"
    @test ev("(columns (table b=(1) a=(2) columns=(:b :a)))") == "(:b :a)"
    # A scalar column value is a one-element column; naught is empty.
    @test ev("(get (table a=1) :a)") == "(1)"
    @test ev("(get (table a=naught) :a)") == "naught"
    # A typed, empty table.
    @test ev("(table columns=(:a :b) types=(a=:int))") == "#table(0×2: a, b)"
    @test ev("(schema (table columns=(:a) types=(a=:int)))") ==
        "(a=(na=NA type=:int))"
    # Values are reduced.
    @test ev("(get (table a=(+ 1 2)) :a)") == "(3)"
    # Malformed construction is loud.
    @test ev("(do (table (a=1) (b=2)) (except ?e :caught))") == ":caught"
    @test ev("(do (table a=(1) b=(1 2)) (except ?e :caught))") == ":caught"
    @test ev("(do (table (a=1) b=(2)) (except ?e :caught))") == ":caught"
    @test ev("(do (table (a=1) 2) (except ?e :caught))") == ":caught"
    @test ev("(do (table a=(1) types=(a=:bogus)) (except ?e :caught))") == ":caught"
    @test ev("(do (table a=(\"x\") types=(a=:int)) (except ?e :caught))") == ":caught"
    @test ev("(do (table (a=(bytes \"x\"))) (except ?e :caught))") == ":caught"

    # ---- NA ------------------------------------------------------------------
    # The default NA is the symbol `NA` for every type but float/number, where it
    # is NaN.
    @test ev("(schema (table a=(1 2)))") == "(a=(na=NA type=:int))"
    @test ev("(schema (table a=(1.0 2.0)))") == "(a=(na=NaN type=:float))"
    @test ev("(eq? (get (table a=(1 NA)) :a) (1 NA))") == "true"
    @test ev("(schema (table a=(1.0 NaN)))") == "(a=(na=NaN type=:float))"
    # A declared marker wins, and then the canonical markers are ordinary data.
    @test ev("(schema (table a=(1 NA) na=(a=0)))") == "(a=(na=0 type=:any))"
    @test ev("(get (table a=(1 NA) na=(a=0)) :a)") == "(1 NA)"
    @test ev("(schema (table a=(1 0) na=(a=0)))") == "(a=(na=0 type=:int))"
    # A missing index cell is refused; a non-index duplicate is allowed.
    @test ev("(do (table n=(\"x\" NA) index=:n) (except ?e :caught))") == ":caught"
    @test ev("(table n=(\"x\" \"x\"))") == "#table(2×1: n)"

    # ---- NA is a fixed point -------------------------------------------------
    @test ev("NA") == "NA"
    @test ev("(let (x=NA) x)") == "NA"
    @test ev("(do (let (NA=5) NA) (except ?e :caught))") == ":caught"
    @test ev("(do (def (NA) 1) (except ?e :caught))") == ":caught"
    @test ev("(eq? NA :NA)") == "false"
    @test ev("(eq? NA \"NA\")") == "false"

    # ---- types ---------------------------------------------------------------
    @test ev("(schema (table a=(true false)))") == "(a=(na=NA type=:bool))"
    @test ev("(schema (table a=(1 2.5)))") == "(a=(na=NaN type=:number))"
    @test ev("(schema (table a=(\"x\" \"y\")))") == "(a=(na=NA type=:string))"
    @test ev("(schema (table a=(:x :y)))") == "(a=(na=NA type=:keyword))"
    @test ev("(schema (table a=(x y)))") == "(a=(na=NA type=:symbol))"
    @test ev("(schema (table a=(NA NA)))") == "(a=(na=NA type=:naught))"
    @test ev("(schema (table a=(1 \"x\")))") == "(a=(na=NA type=:any))"
    @test ev("(schema (table a=(\"1\" \"2\") types=(a=:int)))") ==
        "(a=(na=NA type=:int))"
    @test ev("(get (table a=(\"1\" \"2\") types=(a=:int)) :a)") == "(1 2)"
    @test ev("(schema (table a=(1 2) types=(a=:float)))") ==
        "(a=(na=NaN type=:float))"

    # ---- access --------------------------------------------------------------
    t = "(table name=(\"Bob\" \"Sue\") age=(51 42))"
    @test ev("(get $t :age)") == "(51 42)"
    @test ev("(get $t \"age\")") == "(51 42)"
    @test ev("(get $t 1)") == "(age=51 name=\"Bob\")"
    @test ev("(get $t -1)") == "(age=42 name=\"Sue\")"
    @test ev("(get $t 1 :age)") == "51"
    @test ev("(get $t :age 1)") == "51"
    @test ev("(get $t 0)") == "#table(2×2: age, name)"
    @test ev("(get $t 9 default=:none)") == ":none"
    @test ev("(do (get $t 9) (except ?e :caught))") == ":caught"
    @test ev("(nth $t 2)") == "(age=42 name=\"Sue\")"
    @test ev("(first $t)") == "(age=51 name=\"Bob\")"
    @test ev("(last $t)") == "(age=42 name=\"Sue\")"
    @test ev("(second $t)") == "(age=42 name=\"Sue\")"
    @test ev("(count $t)") == "2"
    @test ev("(length $t)") == "2"
    @test ev("(nrows $t)") == "2"
    @test ev("(rest $t)") == "((age=42 name=\"Sue\"))"
    @test ev("(haskey $t :age)") == "true"
    @test ev("(haskey $t \"age\")") == "true"
    @test ev("(haskey $t 2)") == "true"
    @test ev("(haskey $t :nope)") == "false"
    @test ev("(in (age=42 name=\"Sue\") $t)") == "true"

    # ---- with ----------------------------------------------------------------
    @test ev("(get (with $t :age (60 70)) :age)") == "(60 70)"
    @test ev("(get (with $t (: :age) (60 70)) :age)") == "(60 70)"
    @test ev("(get (with $t 2 (age=99)) 2)") == "(age=99 name=\"Sue\")"
    @test ev("(get (with $t (2 :) (age=99)) 2)") == "(age=99 name=\"Sue\")"
    @test ev("(get (with $t (2 :age) 99) 2)") == "(age=99 name=\"Sue\")"
    # A partial row update leaves the other columns alone.
    @test ev("(get (with $t 2 (age=99)) 2 :name)") == "\"Sue\""
    # A new column is inferred; column values are reduced.
    @test ev("(schema (with $t score=(1.5 2.5)))") ==
        "(age=(na=NA type=:int) name=(na=NA type=:string) score=(na=NaN type=:float))"
    @test ev("(get (with $t score=((+ 1 1) (+ 2 2))) :score)") == "(2 4)"
    # The original table is untouched.
    @test ev("(let (u=$t) (with u :age (60 70)) (get u :age))") == "(51 42)"
    # Bad updates raise.
    @test ev("(do (with $t :age (1)) (except ?e :caught))") == ":caught"
    @test ev("(do (with $t 9 (age=1)) (except ?e :caught))") == ":caught"
    @test ev("(do (with $t 1 (nope=1)) (except ?e :caught))") == ":caught"
    @test ev("(do (with $t (1 :age) \"x\") (except ?e :caught))") == ":caught"
    @test ev("(do (with $t : (age=1)) (except ?e :caught))") == ":caught"

    # ---- push, pop, drop, wout -----------------------------------------------
    @test ev("(push $t (name=\"Z\" age=3))") == "#table(3×2: age, name)"
    @test ev("(get (push $t (name=\"Z\" age=3)) 3)") == "(age=3 name=\"Z\")"
    @test ev("(columns (push $t score=(1 2)))") == "(:age :name :score)"
    @test ev("(get (push $t score=(3 4)) :score)") == "(3 4)"
    @test ev("(eq? (push $t) $t)") == "true"
    @test ev("(do (push $t (name=\"Z\")) (except ?e :caught))") == ":caught"
    @test ev("(do (push $t score=(1)) (except ?e :caught))") == ":caught"
    @test ev("(pop $t)") == "#table(1×2: age, name)"
    @test ev("(pop (table))") == "naught"
    @test ev("(drop $t 1)") == "#table(1×2: age, name)"
    @test ev("(wout $t 1)") == "#table(1×2: age, name)"
    @test ev("(columns (wout $t :age))") == "(:name)"
    @test ev("(get (wout $t (1 :age)) :age)") == "(NA 42)"
    @test ev("(wout (table a=(1)))") == "#table(0×1: a)"

    # ---- index ---------------------------------------------------------------
    ti = "(table name=(\"Bob\" \"Sue\") age=(51 42) index=:name)"
    @test ev("(table-index $ti)") == ":name"
    @test ev("(table-index $t)") == "naught"
    @test ev("(get $ti \"Bob\")") == "(age=51 name=\"Bob\")"
    @test ev("(get (with $ti (\"Bob\" :age) 99) \"Bob\")") ==
        "(age=99 name=\"Bob\")"
    @test ev("(get $ti 1)") == "(age=51 name=\"Bob\")"
    @test ev("(get (push $ti (name=\"Z\" age=3)) \"Z\")") == "(age=3 name=\"Z\")"
    @test ev("(get (pop $ti) \"Bob\")") == "(age=51 name=\"Bob\")"
    @test ev("(get (drop $ti 1) \"Sue\")") == "(age=42 name=\"Sue\")"
    @test ev("(get (with $ti :name (\"Sue\" \"Bob\")) \"Sue\")") ==
        "(age=51 name=\"Sue\")"
    @test ev("(table-index (wout $ti :name))") == "naught"
    @test ev("(do (table n=(\"x\" \"x\") index=:n) (except ?e :caught))") == ":caught"
    @test ev("(do (with $ti (1 :name) \"Sue\") (except ?e :caught))") == ":caught"

    # ---- iteration -----------------------------------------------------------
    @test ev("(for (r $t) r.age)") == "(51 42)"
    @test ev("(map (?r -> r.age) $t)") == "(51 42)"
    @test ev("(map (?r -> r.age) $t depth=0)") == "(51 42)"
    @test ev("(filter (?r -> (r.age > 45)) $t)") == "((age=51 name=\"Bob\"))"
    @test ev("(mapcat (?r -> r.age) $t)") == "(51 42)"
    @test ev("(reduce ((?a ?r) -> (a + r.age)) 0 $t)") == "93"
    @test ev("(any? (?r -> (r.age > 45)) $t)") == "true"
    @test ev("(all? (?r -> (r.age > 45)) $t)") == "false"
    @test ev("(none? (?r -> (r.age > 100)) $t)") == "true"
    @test ev("(count (filter (?r -> true) (table)))") == "0"
    # A table is not silently a sequence.
    @test ev("(do (join $t (1)) (except ?e :caught))") == ":caught"
    @test ev("(do (merge $t (x=1)) (except ?e :caught))") == ":caught"
    @test ev("(do (update-in $t 0 (?x -> x)) (except ?e :caught))") == ":caught"

    # ---- equality and hashing ------------------------------------------------
    @test ev("(eq? (table a=(1 2) b=(3 4)) (table b=(3 4) a=(1 2)))") == "true"
    @test ev("(eq? (table a=(1 2)) (table a=(1 2.0)))") == "false"
    @test ev("(eq? (table a=(1 2)) (table a=(1 2) na=(a=0)))") == "false"
    @test ev("(eq? (table a=(\"x\" \"y\")) (table a=(\"x\" \"y\") index=:a))") ==
        "false"
    @test ev("(let (u=(table a=(1))) (same? u u))") == "true"
    @test ev("(eq? (hash (table a=(1 2))) (hash (table a=(1 2))))") == "true"

    # ---- printing ------------------------------------------------------------
    @test ev("(eq? (table a=(1)) (table a=(1)))") == "true"
    @test ev("(get (table a=(1 2)) :a)") == "(1 2)"
    @test ev("(table a=(1//2 2))") == "#table(2×1: a)"

    # ---- serialization -------------------------------------------------------
    e1 = air_eval(env, read_air("(table n=(\"x\" \"y\") a=(1.0 NaN) index=:n)"))
    io = IOBuffer()
    AirLang._table_serialize(e1.handle.data, io)
    bytes = take!(io)
    e2 = AirLang._extern_form(AirLang._table_deserialize(IOBuffer(bytes)))
    @test AirDB.isequiv(e1, e2)
    @test AirDB.equivhash(e1, UInt(0)) == AirDB.equivhash(e2, UInt(0))
    @test occursin("\"#nan\"", String(bytes))
    # A table is data for the JSON emitter: an array of row objects.
    @test ev("(encode (table a=(1 2) b=(\"x\" \"y\")) format=:json)") ==
        "\"[{\\\"a\\\":1,\\\"b\\\":\\\"x\\\"},{\\\"a\\\":2,\\\"b\\\":\\\"y\\\"}]\""
end
