# The data formats: JSON, YAML, TOML, and `.env`, plus the `read-data` and
# `write-data` file helpers. Every format converts plain data only — an object
# is a map form, an array a sequence form, and null or an empty container is
# `naught` — so decoding is safe by construction.
@testset "formats" begin
    env = default_env()
    ev(s) = air_string(air_eval(env, read_air(s)))
    # Decode a string literal in a format, and encode a form.
    dec(s, fmt) = ev("(decode $(repr(s)) format=:$fmt)")
    enc(src, fmt) = ev("(encode $src format=:$fmt)")

    # ---- format and option validation ---------------------------------------
    @test dec("{\"a\": 1}", "json") == "(a=1)"
    @test dec("[1, 2]", "json") == "(1 2)"
    @test dec("null", "json") == "naught"
    @test dec("\"x\"", "json") == "\"x\""
    @test_throws AirLang.AirEvalError ev("(decode \"{}\" format=:xml)")
    @test_throws AirLang.AirEvalError ev("(decode \"{}\" format=:json nope=1)")
    @test_throws AirLang.AirEvalError ev("(decode \"{}\" 1)")
    @test_throws AirLang.AirEvalError ev("(decode 1 format=:json)")
    # a `bytes` value decodes like its text, and invalid UTF-8 raises
    @test ev("(decode (bytes \"[1]\") format=:json)") == "(1)"
    @test_throws AirLang.AirEvalError ev("(decode (bytes (255 254)) format=:json)")
    # a leading BOM is dropped
    @test ev("(decode \"\ufeff{}\" format=:json)") == "naught"

    # ---- JSON round trips ----------------------------------------------------
    @test dec("{\"a\": [1, 2.5, true, null]}", "json") == "(a=(1 2.5 true naught))"
    @test dec("{\"a\": {\"b\": [{}, []]}}", "json") == "(a=(b=(naught naught)))"
    # numbers: Int64 when it fits, BigInt otherwise; a fraction or exponent is a
    # Float64
    @test dec("9223372036854775807", "json") == "9223372036854775807"
    @test dec("9223372036854775808", "json") == "9223372036854775808"
    @test air_eval(env, read_air("(get (decode \"9223372036854775808\" format=:json) 1)")) isa
          AirDB.FormScalar{BigInt}
    @test dec("1.0", "json") == "1.0"
    @test dec("1e3", "json") == "1000.0"
    @test dec("-0", "json") == "0"
    # string escapes
    @test dec("\"a\\nb\\t\\\"c\\\"\\u00e9\\ud83d\\ude00\"", "json") ==
          "\"a\\nb\\t\\\"c\\\"é😀\""
    @test_throws AirLang.AirEvalError ev("(decode \"\\\"\\\\ud83d\\\"\" format=:json)")     # an unpaired surrogate
    @test_throws AirLang.AirEvalError ev("(decode \"\" format=:json)")
    @test_throws AirLang.AirEvalError ev("(decode \"{\" format=:json)")
    @test_throws AirLang.AirEvalError ev("(decode \"{} {}\" format=:json)")
    @test_throws AirLang.AirEvalError ev("(decode \"{\\\"a\\\":1,\\\"a\\\":2}\" format=:json)")
    @test_throws AirLang.AirEvalError ev("(decode \"01\" format=:json)")
    @test_throws AirLang.AirEvalError ev("(decode \"1.\" format=:json)")
    @test_throws AirLang.AirEvalError ev("(decode \"nul\" format=:json)")
    # encode: keys sorted, non-finite floats rejected
    @test enc("(b=2 a=1)", "json") == "\"{\\\"a\\\":1,\\\"b\\\":2}\""
    @test enc("(1 \"x\" true naught)", "json") == "\"[1,\\\"x\\\",true,null]\""
    @test enc("naught", "json") == "\"null\""
    @test_throws AirLang.AirEvalError ev("(encode (/ 1.0 0.0) format=:json)")
    @test_throws AirLang.AirEvalError ev("(encode (1 a=2) format=:json)")

    # ---- YAML: block and flow -------------------------------------------------
    @test dec("a: 1\nb:\n  c: [1, 2]\n  d: {x: 1}\n", "yaml") ==
          "(a=1 b=(c=(1 2) d=(x=1)))"
    @test dec("- 1\n- - 2\n  - 3\n- k: v\n", "yaml") == "(1 (2 3) (k=\"v\"))"
    @test dec("a:\n  - 1\n  - 2\n", "yaml") == "(a=(1 2))"
    @test dec("a:\nb: 1\n", "yaml") == "(a=naught b=1)"
    @test dec("", "yaml") == "naught"
    @test dec("# only a comment\n", "yaml") == "naught"
    # quoted and numeric keys: a key's text is its name
    @test ev("(get (decode \"\\\"a b\\\": 1\\n1: x\\n\" format=:yaml) " *
             "~(keyword \"a b\"))") == "1"
    @test ev("(get (decode \"\\\"a b\\\": 1\\n1: x\\n\" format=:yaml) " *
             "~(keyword \"1\"))") == "\"x\""
    # scalars resolve by the YAML 1.2 core schema; yes/no/on/off and dates stay
    # strings
    @test dec("a: true\nb: no\nc: 2026-10-30\nd: ~\ne: 0x10\nf: 1.5\n",
              "yaml") == "(a=true b=\"no\" c=\"2026-10-30\" d=naught e=16 f=1.5)"
    # quoted scalars
    @test dec("a: 'it''s'\nb: \"x\\ty\"\n", "yaml") == "(a=\"it's\" b=\"x\\ty\")"
    @test dec("a: \"\\u00e9\"\n", "yaml") == "(a=\"é\")"
    # block scalars: literal, folded, and the chomp modes
    @test dec("a: |\n  x\n  y\n", "yaml") == "(a=\"x\\ny\\n\")"
    @test dec("a: |-\n  x\n  y\n", "yaml") == "(a=\"x\\ny\")"
    @test dec("a: |+\n  x\n\n", "yaml") == "(a=\"x\\n\\n\")"
    @test dec("a: >\n  x\n  y\n\n  z\n", "yaml") == "(a=\"x y\\nz\\n\")"
    # anchors, aliases, and merge keys
    @test dec("a: &x {p: 1}\nb: *x\n", "yaml") == "(a=(p=1) b=(p=1))"
    @test dec("base: &b {p: 1, q: 2}\nd: {<<: *b, q: 3}\n", "yaml") ==
          "(base=(p=1 q=2) d=(p=1 q=3))"
    # flow collections may span lines
    @test dec("a: [1,\n  2,\n  3]\n", "yaml") == "(a=(1 2 3))"
    # multi-document streams need documents=true
        @test ev("(decode \"---\\na: 1\\n---\\nb: 2\\n\" format=:yaml documents=true)") ==
          "((a=1) (b=2))"
    @test_throws AirLang.AirEvalError ev("(decode \"---\\na: 1\\n---\\nb: 2\\n\" format=:yaml)")
    # tags: core tags apply, anything else is refused rather than constructed
    @test dec("a: !!str 1\n", "yaml") == "(a=\"1\")"
    @test dec("a: !!int \"5\"\n", "yaml") == "(a=5)"
    @test_throws AirLang.AirEvalError ev("(decode \"a: !!python/object x\\n\" format=:yaml)")
    @test_throws AirLang.AirEvalError ev("(decode \"a: !custom x\\n\" format=:yaml)")
    # errors: duplicate keys, tabs, bad indentation, trailing content
    @test_throws AirLang.AirEvalError ev("(decode \"a: 1\\na: 2\\n\" format=:yaml)")
    @test_throws AirLang.AirEvalError ev("(decode \"a: 1\\n b: 2\\n\" format=:yaml)")
    @test_throws AirLang.AirEvalError ev("(decode \"\\ta: 1\\n\" format=:yaml)")
    @test_throws AirLang.AirEvalError ev("(decode \"a: [1\\n\" format=:yaml)")
    @test_throws AirLang.AirEvalError ev("(decode \"a: *missing\\n\" format=:yaml)")
    # encode in block style
    @test enc("(b=2 a=(1 2) c=(d=1))", "yaml") ==
          "\"a:\\n  - 1\\n  - 2\\nb: 2\\nc:\\n  d: 1\\n\""
    @test enc("naught", "yaml") == "\"null\\n\""
    @test_throws AirLang.AirEvalError ev("(encode (1 a=2) format=:yaml)")

    # ---- TOML ----------------------------------------------------------------
    @test dec("a = 1\nb = \"x\"\nc = [1, 2]\n", "toml") == "(a=1 b=\"x\" c=(1 2))"
    @test dec("[t]\nx = 1\n[t.u]\ny = 2\n", "toml") == "(t=(u=(y=2) x=1))"
    @test dec("a = {b = 1, c = 2}\n", "toml") == "(a=(b=1 c=2))"
    @test dec("", "toml") == "naught"
    # dates, times, and datetimes become marker forms
    @test dec("d = 2026-10-30\n", "toml") == "(d=(toml-date \"2026-10-30\"))"
    @test dec("t = 12:30:00\n", "toml") == "(t=(toml-time \"12:30:00\"))"
    @test dec("k = 2026-10-30T12:30:00\n", "toml") ==
          "(k=(toml-datetime \"2026-10-30T12:30:00\"))"
    @test enc("(d=(toml-date \"2026-10-30\"))", "toml") == "\"d = 2026-10-30\\n\""
    @test enc("(k=(toml-datetime \"2026-10-30T12:30:00\"))", "toml") ==
          "\"k = 2026-10-30T12:30:00\\n\""
    # an offset date-time survives the standard library's parser, which rejects
    # an offset and drops a `Z`; the marker keeps the literal exactly as written
    @test dec("k = 2026-10-30T12:30:00-08:00\n", "toml") ==
          "(k=(toml-datetime \"2026-10-30T12:30:00-08:00\"))"
    @test dec("k = 2026-10-30T12:30:00Z\n", "toml") ==
          "(k=(toml-datetime \"2026-10-30T12:30:00Z\"))"
    @test dec("k = 2026-10-30T12:30:00.125+05:30\n", "toml") ==
          "(k=(toml-datetime \"2026-10-30T12:30:00.125+05:30\"))"
    @test dec("k = 2026-10-30 12:30:00z\n", "toml") ==
          "(k=(toml-datetime \"2026-10-30 12:30:00z\"))"
    @test dec("k = [2026-10-30T12:30:00Z, 2026-10-30T13:30:00-08:00]\n", "toml") ==
          "(k=((toml-datetime \"2026-10-30T12:30:00Z\") " *
          "(toml-datetime \"2026-10-30T13:30:00-08:00\")))"
    @test dec("k = {a = 2026-10-30T12:30:00Z}\n", "toml") ==
          "(k=(a=(toml-datetime \"2026-10-30T12:30:00Z\")))"
    @test enc("(k=(toml-datetime \"2026-10-30T12:30:00-08:00\"))", "toml") ==
          "\"k = 2026-10-30T12:30:00-08:00\\n\""
    @test ev("(decode (encode (k=(toml-datetime \"2026-10-30T12:30:00Z\")) " *
             "format=:toml) format=:toml)") ==
          "(k=(toml-datetime \"2026-10-30T12:30:00Z\"))"
    # a date-time in a string or a comment is data, not a value
    @test dec("k = \"2026-10-30T12:30:00Z\"\n", "toml") == "(k=\"2026-10-30T12:30:00Z\")"
    @test dec("# 2026-10-30T12:30:00Z\nk = 1\n", "toml") == "(k=1)"
    @test dec("k = 1 # 2026-10-30T12:30:00Z\n", "toml") == "(k=1)"
    # a malformed marker is just data
    @test_throws AirLang.AirEvalError ev("(encode (d=(toml-date \"nope\")) format=:toml)")
    # errors: duplicate keys, bad syntax, a top-level non-object, naught values,
    # and an integer that 64 bits cannot hold
    @test_throws AirLang.AirEvalError ev("(decode \"a = 1\\na = 2\\n\" format=:toml)")
    @test_throws AirLang.AirEvalError ev("(decode \"a = \\n\" format=:toml)")
    @test_throws AirLang.AirEvalError ev("(encode (1 2) format=:toml)")
    @test_throws AirLang.AirEvalError ev("(encode (a=naught) format=:toml)")
    @test_throws AirLang.AirEvalError ev("(encode (a=9223372036854775808) format=:toml)")
    # encode: scalars first, then tables
    @test enc("(b=(x=1) a=2)", "toml") == "\"a = 2\\n\\n[b]\\nx = 1\\n\""
    @test enc("naught", "toml") == "\"\""

    # ---- .env ----------------------------------------------------------------
    @test dec("A=1\nB=x y\n", "env") == "(A=\"1\" B=\"x y\")"
    @test dec("# c\nexport A=1\n", "env") == "(A=\"1\")"
    @test dec("A=\n", "env") == "(A=\"\")"
    @test dec("A=\"x # y\"\nB='a b'\n", "env") == "(A=\"x # y\" B=\"a b\")"
    @test dec("A=x # comment\n", "env") == "(A=\"x\")"
    @test dec("A=\"a\\nb\"\n", "env") == "(A=\"a\\nb\")"
    @test dec("", "env") == "naught"
    @test_throws AirLang.AirEvalError ev("(decode \"1A=x\\n\" format=:env)")
    @test_throws AirLang.AirEvalError ev("(decode \"A=1\\nA=2\\n\" format=:env)")
    @test_throws AirLang.AirEvalError ev("(decode \"A=1\\nB\\n\" format=:env)")
    @test enc("(b=\"x y\" a=1)", "env") == "\"a=1\\nb=\\\"x y\\\"\\n\""
    @test enc("(a=naught)", "env") == "\"a=\\n\""
    @test_throws AirLang.AirEvalError ev("(encode (1 2) format=:env)")
    @test_throws AirLang.AirEvalError ev("(encode (a=(1 2)) format=:env)")

    # ---- CSV and TSV ---------------------------------------------------------
    # A decode yields a table; the first record is a header unless it holds a
    # plain number.
    @test dec("name,age\nBob,51\nSue,42", "csv") == "#table(2×2: name, age)"
    @test ev("(eq? (decode \"name,age\\nBob,51\\nSue,42\" format=:csv) " *
             "(table name=(\"Bob\" \"Sue\") age=(51 42)))") == "true"
    @test dec("Bob,51\nSue,42", "csv") == "#table(2×2: col1, col2)"
    @test dec("1,2\n3,4", "csv") == "#table(2×2: col1, col2)"
    @test ev("(schema (decode \"a,b\\n1,2\" format=:csv header=false))") ==
          "(col1=(na=NA type=:any) col2=(na=NA type=:any))"
    @test ev("(decode \"a,b\\n1,2\" format=:csv header=false)") == "#table(2×2: col1, col2)"
    @test ev("(decode \"a,b\\n1,2\" format=:csv header=true)") == "#table(1×2: a, b)"
    @test ev("(decode \"a,b\\n1,2\" format=:csv header=(\"x\" \"y\"))") ==
          "#table(2×2: x, y)"
    # An empty label falls back to `:colN`; a repeated name raises.
    @test ev("(decode \",b\\n1,2\" format=:csv)") == "#table(1×2: col1, b)"
    @test_throws AirLang.AirEvalError ev("(decode \"a,a\\n1,2\" format=:csv)")
    @test_throws AirLang.AirEvalError ev("(decode \"a,b\\n1\" format=:csv)")
    # Quoting: a column delimiter, a doubled quote, an embedded newline.
    @test ev("(get (decode \"a,b\\n\\\"x,y\\\",2\" format=:csv) :a)") == "(\"x,y\")"
    @test ev("(get (decode \"a\\n\\\"x\\\"\\\"y\\\"\" format=:csv) :a)") == "(\"x\\\"y\")"
    @test ev("(get (decode \"a\\n\\\"l1\\nl2\\\"\" format=:csv) :a)") == "(\"l1\\nl2\")"
    # A quote inside an unquoted field, text after a closing quote, and an
    # unterminated field all raise.
    @test_throws AirLang.AirEvalError ev("(decode \"a\\n1\\\"x\" format=:csv)")
    @test_throws AirLang.AirEvalError ev("(decode \"a\\n\\\"x\\\"y\" format=:csv)")
    @test_throws AirLang.AirEvalError ev("(decode \"a\\n\\\"x\" format=:csv)")
    # Records end at CRLF, LF, or CR; a trailing terminator adds no row.
    @test ev("(decode \"a\\n1\\r\\n2\\r3\" format=:csv)") == "#table(3×1: a)"
    @test ev("(decode \"a\\n1\\n\" format=:csv)") == "#table(1×1: a)"
    @test ev("(decode \"\" format=:csv)") == "#table(0×0)"
    @test ev("(decode \"a,b\" format=:csv)") == "#table(0×2: a, b)"
    # Delimiters: a custom column delimiter, a custom row delimiter (which makes
    # CR and LF ordinary data), and a multi-character error.
    @test ev("(decode \"a;b\\n1;2\" format=:csv column-delimiter=\";\")") ==
          "#table(1×2: a, b)"
    @test ev("(decode \"a|1|2\" format=:csv row-delimiter=\"|\")") == "#table(2×1: a)"
    @test_throws AirLang.AirEvalError ev(
        "(decode \"a\" format=:csv column-delimiter=\",,\")")
    # TSV is RFC 4180 quoting with a tab delimiter.
    @test ev("(decode \"a\\tb\\n1\\t2\" format=:tsv)") == "#table(1×2: a, b)"
    @test ev("(decode \"a\\tb\" format=:csv)") == "#table(0×1: a\tb)"
    # Canonical inference: ints, finite floats, bools; `007` stays text and a
    # leading-zero integer is not a header row.
    @test ev("(schema (decode \"a,b\\n1,2.5\" format=:csv))") ==
          "(a=(na=NA type=:int) b=(na=NaN type=:float))"
    @test ev("(schema (decode \"a\\n1\\n2.5\" format=:csv))") ==
          "(a=(na=NaN type=:number))"
    @test ev("(schema (decode \"a\\ntrue\\nfalse\" format=:csv))") ==
          "(a=(na=NA type=:bool))"
    @test ev("(get (decode \"a\\n007\\n1e3\\ntrue\\nNA\" format=:csv) :a)") ==
          "(\"007\" 1000.0 true NA)"
    # Missing data is in band: an empty field is the column NA, and `NA`/`NaN`
    # are missing unless the column declares another marker.
    @test ev("(get (decode \"a,b\\n,2\" format=:csv) :a)") == "(NA)"
    @test ev("(schema (decode \"a\\nNA\\nNaN\" format=:csv))") ==
          "(a=(na=NA type=:naught))"
    @test ev("(schema (decode \"a\\n1\\n2\" format=:csv na=(a=0)))") ==
          "(a=(na=0 type=:int))"
    @test ev("(get (decode \"a\\n1\\n0\" format=:csv na=(a=0)) :a)") == "(1 0)"
    @test_throws AirLang.AirEvalError ev("(decode \"a\\n1\" format=:csv na=(zzz=0))")
    @test_throws AirLang.AirEvalError ev("(decode \"a\\n1\" format=:csv types=(zzz=:int))")
    # `types=` overrides inference; a text type keeps the field text.
    @test ev("(get (decode \"a\\n1\\n2\" format=:csv types=(a=:float)) :a)") == "(1.0 2.0)"
    @test ev("(get (decode \"a\\n1\\n2\" format=:csv types=(a=:string)) :a)") ==
          "(\"1\" \"2\")"
    @test ev("(get (decode \"a\\n1\\n007\" format=:csv types=(a=:int)) :a)") == "(1 7)"
    @test ev("(get (decode \"a\\nx\\ny\" format=:csv types=(a=:keyword)) :a)") ==
          "(:x :y)"
    # A `bytes` value and a BOM decode like text.
    @test ev("(decode (bytes \"a,b\\n1,2\") format=:csv)") == "#table(1×2: a, b)"
    @test ev("(decode \"\ufeffa,b\\n1,2\" format=:csv)") == "#table(1×2: a, b)"
    # An index column may be declared on decode.
    @test ev("(get (decode \"n,a\\nBob,1\\nSue,2\" format=:csv index=:n) \"Bob\")") ==
          "(a=1 n=\"Bob\")"
    @test_throws AirLang.AirEvalError ev(
        "(decode \"n,a\\nBob,1\\nBob,2\" format=:csv index=:n)")
    @test_throws AirLang.AirEvalError ev(
        "(decode \"n,a\\nBob,1\\nNA,2\" format=:csv index=:n)")
    @test_throws AirLang.AirEvalError ev(
        "(decode \"a\\n1\" format=:csv columns=(:a))")
    # Encode from a table or from a non-empty sequence of row maps.
    @test enc("(table a=(1 2) b=(\"x\" \"y\"))", "csv") == "\"a,b\\n1,x\\n2,y\\n\""
    @test enc("((a=1 b=\"x\") (a=2 b=\"y\"))", "csv") == "\"a,b\\n1,x\\n2,y\\n\""
    @test ev("(encode (table a=(1 2) b=(\"x\" \"y\")) format=:csv header=false)") ==
          "\"1,x\\n2,y\\n\""
    @test ev("(encode (table a=(1)) format=:csv header=(\"A\"))") == "\"A\\n1\\n\""
    @test ev("(encode (table a=(1 2) b=(3 4)) format=:csv columns=(:b))") ==
          "\"b\\n3\\n4\\n\""
    @test ev("(encode (table columns=(:a :b) types=(a=:int)) format=:csv)") ==
          "\"a,b\\n\""
    @test ev("(encode (table a=(1 2)) format=:csv types=(a=:float))") ==
          "\"a\\n1.0\\n2.0\\n\""
    @test_throws AirLang.AirEvalError ev(
        "(encode (table a=(1 2) b=(3 4)) format=:csv columns=(:zzz))")
    @test_throws AirLang.AirEvalError ev("(encode (table a=(1)) format=:csv index=:a)")
    @test_throws AirLang.AirEvalError ev("(encode ((a=1) (b=2)) format=:csv)")
    @test_throws AirLang.AirEvalError ev("(encode (1 2) format=:csv)")
    @test_throws AirLang.AirEvalError ev("(encode naught format=:csv)")
    @test_throws AirLang.AirEvalError ev("(encode (table a=(1//2)) format=:csv)")
    # A cell equal to the column's NA writes as an empty field; a non-finite
    # float that is not the NA raises.
    @test ev("(encode (table a=(1 NA) b=(NaN 2.0)) format=:csv)") ==
          "\"a,b\\n1,\\n,2.0\\n\""
    @test_throws AirLang.AirEvalError ev("(encode (table a=(Inf)) format=:csv)")
    # A round trip preserves the schema, including NA and the index.
    @test ev("(schema (decode (encode (table a=(1.0 NaN) b=(\"x\" \"y\")) " *
             "format=:csv) format=:csv))") ==
          "(a=(na=NaN type=:float) b=(na=NA type=:string))"
    @test ev("(decode (encode (table n=(\"x\" \"y\") a=(1 NA) index=:n) " *
             "format=:csv) format=:csv index=:n)") ==
          "#table(2×2: a, n; index=n)"
    # Fields that look like CSV syntax are quoted on the way out.
    @test ev("(encode (table a=(\"x,y\" \"z\\\"\\\"w\" \"p\\nq\")) format=:csv)") ==
          "\"a\\n\\\"x,y\\\"\\n\\\"z\\\"\\\"\\\"\\\"w\\\"\\n\\\"p\\nq\\\"\\n\""
    @test ev("(encode (table a=(\"x\\ty\")) format=:tsv)") == "\"a\\n\\\"x\\ty\\\"\\n\""
    # A CSV-only option is rejected by another format.
    @test_throws AirLang.AirEvalError ev("(decode \"{}\" format=:json header=true)")
    @test_throws AirLang.AirEvalError ev("(encode (a=1) format=:yaml types=(a=:int))")
    # A table also has a plain-data shape: an array of row objects.
    @test ev("(encode (table a=(1 2) b=(\"x\" \"y\")) format=:json)") ==
          "\"[{\\\"a\\\":1,\\\"b\\\":\\\"x\\\"},{\\\"a\\\":2,\\\"b\\\":\\\"y\\\"}]\""

    # ---- cross-format equality ----------------------------------------------
    # The same data through every format is the same form.
    js = "{ \"a\": [1, 2, 3], \"b\": \"x\" }"
    ym = "a: [1, 2, 3]\nb: x\n"
    tm = "a = [1, 2, 3]\nb = \"x\"\n"
    @test dec(js, "json") == dec(ym, "yaml")
    @test dec(ym, "yaml") == dec(tm, "toml")
    @test dec(js, "json") == "(a=(1 2 3) b=\"x\")"
    # decode(encode(x)) is x for plain data
    @test ev("(decode (encode (a=(1 2) b=\"x\") format=:json) format=:json)") ==
          "(a=(1 2) b=\"x\")"
    @test ev("(decode (encode (a=\"x\" b=1) format=:yaml) format=:yaml)") ==
          "(a=\"x\" b=1)"
    @test ev("(decode (encode (a=(x=1) b=2) format=:toml) format=:toml)") ==
          "(a=(x=1) b=2)"
    @test ev("(decode (encode (A=\"x\" B=\"y\") format=:env) format=:env)") ==
          "(A=\"x\" B=\"y\")"
    # keywords and symbols encode as their text
    @test enc("(a=:b)", "json") == "\"{\\\"a\\\":\\\"b\\\"}\""

    # ---- read-data / write-data ---------------------------------------------
    dir = mktempdir()
    # extension inference, in both directions
    p = joinpath(dir, "conf.json")
    @test ev("(write-data $(repr(p)) (a=1))") == "naught"
    for _ in 1:200
        isfile(p) && break
        sleep(0.01)
    end
    @test isfile(p)
    @test ev("(read-data $(repr(p)))") == "(a=1)"
    @test read(p, String) == "{\"a\":1}\n" || read(p, String) == "{\"a\":1}"
    # a format override wins over the extension
    q = joinpath(dir, "conf.txt")
    @test ev("(write-data $(repr(q)) (a=1) format=:yaml)") == "naught"
    for _ in 1:200
        isfile(q) && break
        sleep(0.01)
    end
    @test ev("(read-data $(repr(q)) format=:yaml)") == "(a=1)"
    # `.env` is recognized by name, and `yml` is a yaml alias
    e = joinpath(dir, ".env")
    @test ev("(write-data $(repr(e)) (A=\"x\"))") == "naught"
    for _ in 1:200
        isfile(e) && break
        sleep(0.01)
    end
    @test ev("(read-data $(repr(e)))") == "(A=\"x\")"
    y = joinpath(dir, "c.yml")
    @test ev("(write-data $(repr(y)) (a=1))") == "naught"
    for _ in 1:200
        isfile(y) && break
        sleep(0.01)
    end
    @test ev("(read-data $(repr(y)))") == "(a=1)"
    # `.csv` and `.tsv` infer their formats, and a write is deferred to the
    # transaction commit like `write-file`.
    t = joinpath(dir, "data.csv")
    @test ev("(write-data $(repr(t)) (table a=(1 2) b=(\"x\" \"y\")))") == "naught"
    for _ in 1:200
        isfile(t) && break
        sleep(0.01)
    end
    @test read(t, String) == "a,b\n1,x\n2,y\n"
    @test ev("(eq? (read-data $(repr(t))) (table a=(1 2) b=(\"x\" \"y\")))") == "true"
    t2 = joinpath(dir, "data.tsv")
    @test ev("(write-data $(repr(t2)) (table a=(1 2) b=(\"x\" \"y\")))") == "naught"
    for _ in 1:200
        isfile(t2) && break
        sleep(0.01)
    end
    @test read(t2, String) == "a\tb\n1\tx\n2\ty\n"
    @test ev("(eq? (read-data $(repr(t2)) types=(a=:float)) " *
             "(table a=(1.0 2.0) b=(\"x\" \"y\")))") == "true"
    # An aborted transaction drops the write.
    aborted = joinpath(dir, "aborted.csv")
    @test ev("(do (tx (write-data $(repr(aborted)) (table a=(1))) (raise :nope)) " *
             "(except ?e :caught))") == ":caught"
    sleep(0.2)
    @test !isfile(aborted)
    # filesystem access is gated by the `filesystem` permission on `.air.sys`,
    # which a fresh instance grants only to `air`; a grant admits an ordinary
    # user to the helpers, and a revocation closes the door again.
    @test ev("(create-user :bob)") == ":bob"
    @test_throws AirLang.AirPermissionDenied ev("(as-user :bob (read-data $(repr(p))))")
    denied = joinpath(dir, "denied.json")
    @test_throws AirLang.AirPermissionDenied ev("(as-user :bob (write-data $(repr(denied)) (a=1)))")
    @test !isfile(denied)
    # the `.air.sys` spelling dispatches the same gated helper
    @test ev("(.air.sys.read-data $(repr(p)))") == "(a=1)"
    @test_throws AirLang.AirPermissionDenied ev(
        "(as-user :bob (.air.sys.read-data $(repr(p))))")
    # `.air` grants the permission; `decode`/`encode` need no grant at all
    ev("(chmod! .air.sys filesystem=(bob=true))")
    @test ev("(as-user :bob (read-data $(repr(p))))") == "(a=1)"
    @test ev("(as-user :bob (write-data $(repr(denied)) (a=2)))") == "naught"
    for _ in 1:200
        isfile(denied) && break
        sleep(0.01)
    end
    @test isfile(denied)
    @test ev("(as-user :bob (decode \"{\\\"a\\\": 1}\"))") == "(a=1)"
    @test ev("(as-user :bob (encode (a=1)))") == "\"{\\\"a\\\":1}\""
    ev("(chmod! .air.sys filesystem=(bob=false))")
    @test_throws AirLang.AirPermissionDenied ev("(as-user :bob (read-data $(repr(p))))")
    # errors: an unknown extension, a missing file, and a bad encode
    @test_throws AirLang.AirEvalError ev("(read-data $(repr(joinpath(dir, "x.txt"))))")
    @test_throws AirLang.AirEvalError ev("(read-data $(repr(joinpath(dir, "no.json"))))")
    @test_throws AirLang.AirEvalError ev("(write-data $(repr(joinpath(dir, "b.toml"))) (a=naught))")
    rm(dir; force=true, recursive=true)
end
