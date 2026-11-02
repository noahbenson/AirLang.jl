# Strings and regexes

A string is an immutable sequence of characters written between double quotes
(`"…"` or `"""…"""`) with Julia's escape rules: `\n`, `\t`, `\"`, `\\`, `\u…`,
and the rest. A **raw string** — `raw"…"` or `raw"""…"""` — suppresses escape
processing (only `\"` escapes a quote), so `raw"\d+"` is the three characters
`\d+`. Triple-quoted strings may span lines and are commonly used for source
text and docstrings.

A string is a scalar value: `(string? x)` tests one, and a string never
reduces. The string verbs below are ordinary functions, and a verb that takes a
pattern accepts either a **literal string** (matched literally) or a **regex
value** (matched as a regular expression).

## Characters and indices

Air counts **characters**, not bytes, and indices are **1-based**:

```air
(string-length "héllo")        # => 5
(string-chars "abc")           # => ("a" "b" "c")
(string-take "abcdef" 3)       # => "abc"
(string-drop "abcdef" 3)       # => "def"
(substring "abcdef" 2 4)       # => "bcd"   (start and end are inclusive)
```

`string-chars` returns a sequence of one-character strings and `string-lines`
splits on line boundaries. `string-reverse` reverses the characters,
`string-repeat` repeats a string, and `string-pad-left`/`string-pad-right` pad
with spaces to a width.

## Building and converting

`str` concatenates its arguments as the printer renders them — the everyday way
to build a string from values:

```air
(str "hello " name " #" n)     # => "hello Ada #7"
(string-append "a" "b" "c")    # => "abc"
(string-join ("a" "b" "c") ", ")   # => "a, b, c"
```

`string-join` renders each element with the ordinary printer and joins them.
The scalar conversions are `keyword` (`(keyword "x")` is `:x`), `symbol`
(`(symbol "x")` is `x`), and `name` (`(name :x)` and `(name 'x)` are `"x"`; a
string is unchanged). `form->string` renders a form as air source, with
`pretty=true` for the wrapping printer, and `string->form` reads source text
into a form. Structured data formats are separate: see
[Data formats](formats.md).

## Case, trimming, and tests

```air
(string-upper "Abc")           # => "ABC"      (upcase is an alias)
(string-lower "Abc")           # => "abc"      (downcase is an alias)
(string-capitalize "hELLO")    # => "Hello"
(string-trim "  x  ")          # => "x"        (also -left and -right)
(string-starts-with? "abc" "ab")   # => true
(string-ends-with? "abc" "bc")     # => true
(string-contains? "abc" "b")       # => true   (literal text)
(string-match? "abc" r"b")         # => true   (pattern-aware)
```

`string-contains?` treats its argument as literal text; `string-match?` is its
pattern-aware spelling and is true when the pattern matches anywhere.
`starts-with?` and `ends-with?` (no `string-` prefix) are the generic
predicates over sequences as well as strings.

## Splitting, replacing, and searching

```air
(string-split "a,b,c" ",")          # => ("a" "b" "c")
(string-split "a1b22c" r"\d+")      # => ("a" "b" "c")
(string-replace "a1b2" r"\d" "#")   # => "a#b#"
(string-index-of "abcabc" "bc")     # => 2, or naught when absent
(string-find "a1b22" r"\d+")        # => (match="1" index=2 groups=(…))
```

`string-find` returns the first match as `(match=… index=… groups=…)`, or
`naught`; `string-find-all` returns every non-overlapping match in order.
`index` is a 1-based character index, and `groups` holds the capture strings
(`naught` when the pattern has no capture groups). A regex replacement expands
`$0` (the whole match), `$1`…`$n`, and `$name` (a named group); `$$` is a
literal dollar. A literal pattern's replacement is used exactly as written.

## Regular expressions

A regex literal `r"a+"` (or `r"""…"""`) is a raw string compiled at read time;
the letters `i`, `m`, `s`, `x`, and `a` immediately after the closing quote are
flags. The literal builds the same value as `(regex "a+")` or
`(regex "a+" "i")`, prints back as the literal, and is an ordinary value —
`regex?` tests one, it can be stored in a database, and it round-trips through
`to-json`. Julia's regex syntax applies, including named groups `(?<name>…)`.

The pattern-taking verbs are `string-split`, `string-replace`,
`string-match?`, `string-find`, and `string-find-all`; `string-index-of` takes
literal text. A plain string used as a pattern is matched literally, so
`(string-split s ".")` splits on a period rather than on any character; write
`r"\."` when you mean the regular expression.

## Formatting

`string-format` fills a template by name:

```air
(string-format "~name is ~age" name="Ada" age=36)    # => "Ada is 36"
(string-format "~~ literal")                          # => "~ literal"
```

Each `~name` is replaced by the printed value under that map entry and `~~` is
a literal tilde. For most work `str` is simpler; `string-format` is for a
template that is fixed while its values vary (a message, a path, a report
line).

## Printing and `str`

`print` and `println` write to the task's output sink — air's stdout, or the
SSH session's channel when the task runs in one — and return `naught`. A
string prints as its content; anything else prints as air source. `str` uses
the same rendering but returns the text. Inside a transaction the write is a
side effect that happens at commit. See [Printing and layouts](printing.md)
for `form->string` and the pretty printer.

## Bytes and data

`bytes` is a separate immutable extern for binary content — `(bytes s)`,
`(bytes-of coll)`, `bytes-length`, `bytes-string`, `bytes-index`, `bytes-slice`,
and `bytes?` — used by SFTP transfers (see [SSH access](ssh.md)). Text in a
structured format (JSON, YAML, TOML, CSV, TSV, `.env`) is decoded with
`decode`/`encode` or read with `read-data`/`write-data`; see
[Data formats](formats.md).
