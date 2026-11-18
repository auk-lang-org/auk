/// tests/check2.rs: patterns (exhaustiveness, reachability: E0400–E0403) and effects
/// (E0410–E0415) through `auk check`: exact codes, messages, spans, notes and fix-its.
///
/// Differences from Rust: the `check --json` report is read with json.auk (Rust has a minimal
/// reader of its own, strict here: a missing key or a value of the wrong kind fails the test);
/// a scratch directory is a fresh `fs.temp_dir()` (Rust's `auk-check2-<pid>-<n>` under the temp
/// dir).

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("clause_group_missing_variant", clause_group_missing_variant),
  t.test("match_missing_variant_inserts_arm", match_missing_variant_inserts_arm),
  t.test("one_line_match_inserts_with_comma", one_line_match_inserts_with_comma),
  t.test("int_literals_need_a_catch_all", int_literals_need_a_catch_all),
  t.test("float_str_char_literals_need_a_catch_all", float_str_char_literals_need_a_catch_all),
  t.test("bool_and_tuples", bool_and_tuples),
  t.test("struct_patterns_with_rest", struct_patterns_with_rest),
  t.test("nested_enums", nested_enums),
  t.test("options_and_results", options_and_results),
  t.test("typed_error_enum", typed_error_enum),
  t.test(
    "typed_error_payload_on_plain_err_needs_catch_all",
    typed_error_payload_on_plain_err_needs_catch_all,
  ),
  t.test("value_variants", value_variants),
  t.test("more_than_three_missing_inserts_catch_all", more_than_three_missing_inserts_catch_all),
  t.test("lists_empty_plus_rest_is_exhaustive", lists_empty_plus_rest_is_exhaustive),
  t.test("lists_missing_lengths", lists_missing_lengths),
  t.test(
    "multi_parameter_clause_group_keeps_signature_style",
    multi_parameter_clause_group_keeps_signature_style,
  ),
  t.test("list_arm_unreachable_after_rest", list_arm_unreachable_after_rest),
  t.test("open_maps_are_never_exhaustive", open_maps_are_never_exhaustive),
  t.test("string_prefixes", string_prefixes),
  t.test("unreachable_clause_names_the_covering_one", unreachable_clause_names_the_covering_one),
  t.test("unreachable_by_several_arms_together", unreachable_by_several_arms_together),
  t.test("guards_dont_count_toward_exhaustiveness", guards_dont_count_toward_exhaustiveness),
  t.test("guarded_arm_after_catch_all_is_unreachable", guarded_arm_after_catch_all_is_unreachable),
  t.test(
    "guarded_arm_doesnt_make_later_arm_unreachable",
    guarded_arm_doesnt_make_later_arm_unreachable,
  ),
  t.test("let_else_that_always_matches", let_else_that_always_matches),
  t.test("refutable_let_without_else", refutable_let_without_else),
  t.test("missing_effect_adds_uses", missing_effect_adds_uses),
  t.test("missing_effect_appends_to_list", missing_effect_appends_to_list),
  t.test("missing_effect_without_return_type", missing_effect_without_return_type),
  t.test("missing_effect_through_a_closure", missing_effect_through_a_closure),
  t.test("missing_effect_through_a_function_value", missing_effect_through_a_function_value),
  t.test("missing_effect_through_a_shape_vtable", missing_effect_through_a_shape_vtable),
  t.test(
    "conversion_to_any_shape_checks_method_effects",
    conversion_to_any_shape_checks_method_effects,
  ),
  t.test("missing_effect_through_a_generic_instance", missing_effect_through_a_generic_instance),
  t.test("unused_effect_is_a_warning", unused_effect_is_a_warning),
  t.test("impure_imprint_and_constants", impure_imprint_and_constants),
  t.test("tests_print_and_peek_are_free", tests_print_and_peek_are_free),
  t.test("main_gets_no_implicit_permission", main_gets_no_implicit_permission),
  t.test("unknown_effect_name", unknown_effect_name),
  t.test("package_ceiling", package_ceiling),
  t.test(
    "dependency_checked_against_its_own_manifest",
    dependency_checked_against_its_own_manifest,
  ),
  t.test(
    "missing_and_unused_effects_get_one_combined_fix",
    missing_and_unused_effects_get_one_combined_fix,
  ),
  t.test("closure_arity_mismatch_reports_only_e0204", closure_arity_mismatch_reports_only_e0204),
  t.test("pointless_try_under_fallible_return", pointless_try_under_fallible_return),
  t.test("try_on_shadowing_fallible_fn_is_fine", try_on_shadowing_fallible_fn_is_fine),
  t.test("irrefutable_struct_let_else_is_e0255", irrefutable_struct_let_else_is_e0255),
]

fn auk(args: [str]): cmd.Out uses env, ffi, time = t.run_auk(args)

fn scratch(): str uses fs = t.must(fs.temp_dir(), "temp dir")

struct D {
  code: str,
  severity: str,
  file: str?,
  line: int,
  col: int,
  message: str,
  notes: [str],
  /// (line, col, end_line, end_col, text)
  fixes: [(int, int, int, int, str)],
}

/// `check --json` on a file: the diagnostics, and whether the exit code was 0.
fn check_path(path: str): ([D], bool) uses env, ffi, time {
  let out = auk(["check", path, "--json"])
  let text = out.stdout
  let v = match json.parse(text) {
    ok(v) => v
    err(Bad(e)) => t.bail("{e}: {text}")
  }
  let ds = jget(v, "diagnostics").jarr().map(d => D {
    code: jget(d, "code").jstr(),
    severity: jget(d, "severity").jstr(),
    file: match d.get("file") {
      Null => none
      f => some(f.jstr())
    },
    line: jget(d, "line").jnum(),
    col: jget(d, "col").jnum(),
    message: jget(d, "message").jstr(),
    notes: jget(d, "notes").jarr().map(n => n.jstr()),
    fixes: jget(d, "fixes").jarr().map(
      f => (
        jget(f, "line").jnum(),
        jget(f, "col").jnum(),
        jget(f, "end_line").jnum(),
        jget(f, "end_col").jnum(),
        jget(f, "text").jstr(),
      ),
    ),
  })
  let errors = ds.filter(d => d.severity == "error").len()
  let ok = v.get("ok") == json.Json.Bool(true)
  t.check(ok == (errors == 0), "`ok` vs errors: {text}")
  t.check(out.success() == (errors == 0), "exit status vs errors: {text}")
  (ds, out.success())
}

/// Rust's strict reader: the key must be there (a `null` value counts as missing, as json.auk
/// can't tell them apart; the report has no nulls).
fn jget(j: json.Json, k: str): json.Json = match j.get(k) {
  Null => t.bail("no key {k} in {j.text()}")
  v => v
}

fn jarr(j: json.Json): [json.Json] = match j {
  Arr(xs) => xs
  _ => t.bail("not an array: {j.text()}")
}

fn jstr(j: json.Json): str = match j {
  Str(s) => s
  _ => t.bail("not a string: {j.text()}")
}

/// A number as u32 (`as` saturates).
fn jnum(j: json.Json): int = match j {
  Num(n) => if n <= 0.0 { 0 } else { int(n) }
  _ => t.bail("not a number: {j.text()}")
}

fn check(src: str): [D] uses env, fs, ffi, time {
  let dir = scratch()
  let path = paths.join(dir, "t.auk")
  t.write(path, src)
  let (ds, _) = check_path(path)
  t.rm_rf(dir)
  ds
}

/// The single diagnostic of `src`, with this code and message.
fn one(src: str, code: str, message: str): D uses env, fs, ffi, time {
  let ds = check(src)
  t.check(ds.len() == 1, "expected exactly one diagnostic for:\n{src}\ngot: {ds}")
  let d = ds[0]
  t.check((d.code, d.message) == (code, message), "{d}")
  d
}

fn clean(src: str) uses env, fs, ffi, time {
  let ds = check(src)
  t.check(ds.len() == 0, "expected no diagnostics for:\n{src}\ngot: {ds}")
}

fn at(d: D, line: int, col: int) {
  t.check((d.line, d.col) == (line, col), "{d}")
}

fn has_note(d: D, part: str) {
  t.check(d.notes.any(n => n.contains(part)), "no note containing {part.show()}: {d}")
}

fn fix(d: D, at: (int, int, int, int), text: str) {
  t.check(
    d.fixes.any(f => (f.0, f.1, f.2, f.3) == at && f.4 == text),
    "no fix {at} -> {text.show()}: {d}",
  )
}

/// Apply one fix-it (1-based line/col, end exclusive) to `src`.
fn apply_fix(src: str, f: (int, int, int, int, str)): str {
  let lines = src.split("\n")
  // the char offset of (line, col): the lines before it (each with its `\n`), then col - 1
  let offset = (line: int, col: int) => lines.take(line - 1).map(l => l.len() + 1).sum() + col - 1
  let (a, b) = (offset(f.0, f.1), offset(f.2, f.3))
  src[0..a] + f.4 + src[b..src.len()]
}

let SHAPE = "enum Shape {{ Circle(r: float), Rect(w: float, h: float) }}\n"

// ---- exhaustiveness: enums and clause groups ----

fn clause_group_missing_variant() uses env, fs, ffi, time {
  let src =
    "{SHAPE}fn area(Circle(r)): float = 3.14 * r * r\nfn main() {{ print(area(Circle(1.0))) }}\n"
  let d = one(
    src,
    "E0400",
    "the clauses of `area` don't cover every case: `area(Rect(_, _))` is not handled",
  )
  at(d, 2, 4)
  has_note(d, "add a clause for each missing case")
  fix(d, (2, 41, 2, 41), "\nfn area(Rect(w, h)): float = ??")
}

fn match_missing_variant_inserts_arm() uses env, fs, ffi, time {
  let src = "{SHAPE}fn area(s: Shape): float {{\n  match s {{\n    Circle(r) => 3.14 * r * r\n  }}\n}}\nfn main() {{}}\n"
  let d = one(src, "E0400", "this `match` doesn't cover every case: `Rect(_, _)` is not handled")
  at(d, 3, 3)
  fix(d, (4, 30, 4, 30), "\n    Rect(w, h) => ??")
}

fn one_line_match_inserts_with_comma() uses env, fs, ffi, time {
  let d = one(
    "enum K {{ A, B, C }}\nfn f(k: K): int = match k {{ A => 1, B => 2 }}\nfn main() {{}}\n",
    "E0400",
    "this `match` doesn't cover every case: `C` is not handled",
  )
  fix(d, (2, 43, 2, 43), ", C => ??")
}

fn int_literals_need_a_catch_all() uses env, fs, ffi, time {
  let d = one(
    "fn fib(0): int = 0\nfn fib(1): int = 1\nfn main() {{}}\n",
    "E0400",
    "the clauses of `fib` don't cover every case: `fib(_)` is not handled",
  )
  fix(d, (2, 19, 2, 19), "\nfn fib(_): int = ??")
}

fn float_str_char_literals_need_a_catch_all() uses env, fs, ffi, time {
  for (ty, a, b) in [("float", "1.0", "2.5"), ("str", "\"a\"", "\"b\""), ("char", "'a'", "'b'")] {
    let src =
      "fn f(x: {ty}): int {{\n  match x {{\n    {a} => 1\n    {b} => 2\n  }}\n}}\nfn main() {{}}\n"
    let d = one(src, "E0400", "this `match` doesn't cover every case: `_` is not handled")
    fix(d, (4, 13 + b.len() - 3, 4, 13 + b.len() - 3), "\n    _ => ??")
  }
}

fn bool_and_tuples() uses env, fs, ffi, time {
  let d = one(
    "fn f(a: bool, b: bool): int {{\n  match (a, b) {{\n    (true, true) => 1\n    (false, false) => 2\n  }}\n}}\nfn main() {{}}\n",
    "E0400",
    "this `match` doesn't cover every case: `(false, true)` and `(true, false)` are not handled",
  )
  fix(d, (4, 24, 4, 24), "\n    (false, true) => ??\n    (true, false) => ??")
  clean("fn g(true): int = 1\nfn g(false): int = 0\nfn main() {{}}\n")
}

fn struct_patterns_with_rest() uses env, fs, ffi, time {
  let d = one(
    "struct P {{ on: bool, n: int }}\nfn f(P {{ on: true, .. }}): int = 1\nfn main() {{}}\n",
    "E0400",
    "the clauses of `f` don't cover every case: `f(P {{ on: false, .. }})` is not handled",
  )
  fix(d, (2, 34, 2, 34), "\nfn f(P {{ on: false, .. }}): int = ??")
  clean("struct P {{ on: bool, n: int }}\nfn f(P {{ on: true, .. }}): int = 1\nfn f(P {{ n, .. }}): int = n\nfn main() {{}}\n")
}

fn nested_enums() uses env, fs, ffi, time {
  let src = "{SHAPE}fn f(x: Shape?): float {{\n  match x {{\n    some(Circle(r)) => r\n    none => 0.0\n  }}\n}}\nfn main() {{}}\n"
  let d = one(
    src,
    "E0400",
    "this `match` doesn't cover every case: `some(Rect(_, _))` is not handled",
  )
  fix(d, (5, 16, 5, 16), "\n    some(Rect(w, h)) => ??")
  let deep = "enum T {{ Leaf, Node(l: T, r: T) }}\nfn f(Leaf): int = 0\nfn f(Node(Leaf, _)): int = 1\nfn f(Node(Node(_, _), Node(_, _))): int = 2\nfn main() {{}}\n"
  let d = one(
    deep,
    "E0400",
    "the clauses of `f` don't cover every case: `f(Node(Node(_, _), Leaf))` is not handled",
  )
  fix(d, (4, 44, 4, 44), "\nfn f(Node(Node(l, r), Leaf)): int = ??")
}

fn options_and_results() uses env, fs, ffi, time {
  let d = one(
    "fn f(x: int?): int {{\n  match x {{\n    some(n) => n\n  }}\n}}\nfn main() {{}}\n",
    "E0400",
    "this `match` doesn't cover every case: `none` is not handled",
  )
  fix(d, (3, 17, 3, 17), "\n    none => ??")
  let d = one(
    "fn f(x: int!): int {{\n  match x {{\n    ok(n) => n\n  }}\n}}\nfn main() {{}}\n",
    "E0400",
    "this `match` doesn't cover every case: `err(_)` is not handled",
  )
  fix(d, (3, 15, 3, 15), "\n    err(e) => ??")
  clean("fn f(x: int?): int {{\n  match x {{\n    some(n) => n\n    none => 0\n  }}\n}}\nfn main() {{}}\n")
}

fn typed_error_enum() uses env, fs, ffi, time {
  let d = one(
    "enum E {{ A, B(k: int) }}\nfn f(x: int!E): int {{\n  match x {{\n    ok(n) => n\n    err(A) => 0\n  }}\n}}\nfn main() {{}}\n",
    "E0400",
    "this `match` doesn't cover every case: `err(B(_))` is not handled",
  )
  fix(d, (5, 16, 5, 16), "\n    err(B(k)) => ??")
}

fn typed_error_payload_on_plain_err_needs_catch_all() uses env, fs, ffi, time {
  let src = "enum E {{ A, B(k: int) }}\nfn f(x: int!): int {{\n  match x {{\n    ok(n) => n\n    err(A) => 0\n    err(B(k)) => k\n  }}\n}}\nfn main() {{}}\n"
  let d = one(src, "E0400", "this `match` doesn't cover every case: `err(_)` is not handled")
  fix(d, (6, 19, 6, 19), "\n    err(e) => ??")
  clean(src.replace("    err(B(k)) => k\n", "    err(B(k)) => k\n    err(e) => 1\n"))
}

fn value_variants() uses env, fs, ffi, time {
  let src = "fn f(v: Value): int {{\n  match v {{\n    Null => 0\n    Int(i) => i\n  }}\n}}\nfn main() {{}}\n"
  let d = one(
    src,
    "E0400",
    "this `match` doesn't cover every case: `Bool(_)`, `Float(_)`, `Str(_)` and more are not handled",
  )
  has_note(d, "catch-all")
  fix(d, (4, 16, 4, 16), "\n    _ => ??")
  let d = one(
    "fn f(v: Value): int {{\n  match v {{\n    Null => 0\n    Bool(b) => 1\n    Int(i) => i\n    Float(x) => 2\n    Str(s) => 3\n    List(xs) => 4\n  }}\n}}\nfn main() {{}}\n",
    "E0400",
    "this `match` doesn't cover every case: `Map(_)` is not handled",
  )
  fix(d, (8, 18, 8, 18), "\n    Map(m) => ??")
}

fn more_than_three_missing_inserts_catch_all() uses env, fs, ffi, time {
  let d = one(
    "enum D {{ N, E, S, W, X }}\nfn f(N): int = 0\nfn main() {{}}\n",
    "E0400",
    "the clauses of `f` don't cover every case: `f(E)`, `f(S)`, `f(W)` and more are not handled",
  )
  fix(d, (2, 17, 2, 17), "\nfn f(_): int = ??")
}

// ---- lists ----

fn lists_empty_plus_rest_is_exhaustive() uses env, fs, ffi, time {
  clean("fn len([]): int = 0\nfn len([_, ..t]: [int]): int = 1 + len(t)\nfn main() {{}}\n")
  clean("fn last([]): int = 0\nfn last([.., x]: [int]): int = x\nfn main() {{}}\n")
  clean("fn f(xs: [int]): int {{\n  match xs {{\n    [] => 0\n    [a] => a\n    [a, b, .._] => a + b\n  }}\n}}\nfn main() {{}}\n")
}

fn lists_missing_lengths() uses env, fs, ffi, time {
  let d = one(
    "fn f(xs: [int]): int {{\n  match xs {{\n    [] => 0\n    [a] => a\n  }}\n}}\nfn main() {{}}\n",
    "E0400",
    "this `match` doesn't cover every case: `[_, _, ..]` is not handled",
  )
  fix(d, (4, 13, 4, 13), "\n    [_, _, ..] => ??")
  let d = one(
    "fn f([h, ..t]: [int]): int = h\nfn main() {{}}\n",
    "E0400",
    "the clauses of `f` don't cover every case: `f([])` is not handled",
  )
  fix(d, (1, 31, 1, 31), "\nfn f([]: [int]): int = ??")
  let d = one(
    "fn f(xs: [int]): int {{\n  match xs {{\n    [] => 0\n    [a, b, ..] => a\n  }}\n}}\nfn main() {{}}\n",
    "E0400",
    "this `match` doesn't cover every case: `[_]` is not handled",
  )
  fix(d, (4, 20, 4, 20), "\n    [_] => ??")
}

fn multi_parameter_clause_group_keeps_signature_style() uses env, fs, ffi, time {
  let d = one(
    "fn len([], acc: int): int = acc\nfn len([_, _, ..t]: [int], acc: int): int = len(t, acc + 2)\nfn main() {{}}\n",
    "E0400",
    "the clauses of `len` don't cover every case: `len([_], _)` is not handled",
  )
  at(d, 1, 4)
  fix(d, (2, 60, 2, 60), "\nfn len([_]: [int], acc: int): int = ??")
}

fn list_arm_unreachable_after_rest() uses env, fs, ffi, time {
  let d = one(
    "fn f(xs: [int]): int {{\n  match xs {{\n    [] => 0\n    [.., last] => last\n    [a, b] => a\n  }}\n}}\nfn main() {{}}\n",
    "E0401",
    "this arm is unreachable",
  )
  at(d, 5, 5)
  has_note(d, "the arm `[.., last]` at line 4 already matches every value this one matches")
}

// ---- open maps and string prefixes ----

fn open_maps_are_never_exhaustive() uses env, fs, ffi, time {
  let d = one(
    "fn f({{\"a\": n}}: {{str: int}}): int = n\nfn main() {{}}\n",
    "E0400",
    "the clauses of `f` don't cover every case: `f(_)` is not handled",
  )
  fix(d, (1, 36, 1, 36), "\nfn f(_: {{str: int}}): int = ??")
  let d = one(
    "fn f(v: Value): int {{\n  match v {{\n    Map({{\"a\": Int(n)}}) => n\n    Null => 0\n  }}\n}}\nfn main() {{}}\n",
    "E0400",
    "this `match` doesn't cover every case: `Bool(_)`, `Int(_)`, `Float(_)` and more are not handled",
  )
  has_note(d, "catch-all")
  clean("fn f({{\"a\": n}}: {{str: int}}): int = n\nfn f(_: {{str: int}}): int = 0\nfn main() {{}}\n")
}

fn string_prefixes() uses env, fs, ffi, time {
  let d = one(
    "fn f(s: str): int {{\n  match s {{\n    \"GET \" + p => 1\n    \"GET \" + q => 2\n    _ => 3\n  }}\n}}\nfn main() {{}}\n",
    "E0401",
    "this arm is unreachable",
  )
  has_note(d, "the arm `\"GET \" + p` at line 3")
  let d = one(
    "fn f(\"GET \" + p): int = 1\nfn main() {{}}\n",
    "E0400",
    "the clauses of `f` don't cover every case: `f(_)` is not handled",
  )
  fix(d, (1, 26, 1, 26), "\nfn f(_): int = ??")
}

// ---- reachability and guards ----

fn unreachable_clause_names_the_covering_one() uses env, fs, ffi, time {
  let d = one(
    "fn fib(0): int = 0\nfn fib(1): int = 1\nfn fib(n: int): int = fib(n - 1) + fib(n - 2)\nfn fib(5): int = 5\nfn main() {{}}\n",
    "E0401",
    "this clause of `fib` is unreachable",
  )
  at(d, 4, 8)
  has_note(d, "the clause `fn fib(n: int)` at line 3 already matches every call this one matches")
  fix(d, (3, 46, 4, 19), "")
}

fn unreachable_by_several_arms_together() uses env, fs, ffi, time {
  let d = one(
    "fn f(b: bool): int {{\n  match b {{\n    true => 1\n    false => 0\n    _ => 2\n  }}\n}}\nfn main() {{}}\n",
    "E0401",
    "this arm is unreachable",
  )
  at(d, 5, 5)
  has_note(d, "the arms before it together match every value this one matches")
  fix(d, (4, 15, 5, 11), "")
}

fn guards_dont_count_toward_exhaustiveness() uses env, fs, ffi, time {
  let d = one(
    "fn grade(n: int): str when n >= 90 = \"A\"\nfn grade(n: int): str when n < 90 = \"B\"\nfn main() {{}}\n",
    "E0400",
    "the clauses of `grade` don't cover every case: `grade(_)` is not handled",
  )
  has_note(d, "clauses with a `when` guard don't count")
  fix(d, (2, 40, 2, 40), "\nfn grade(n: int): str = ??")
  clean("fn grade(n: int): str when n >= 90 = \"A\"\nfn grade(_: int): str = \"B\"\nfn main() {{}}\n")
}

fn guarded_arm_after_catch_all_is_unreachable() uses env, fs, ffi, time {
  let d = one(
    "fn f(n: int): int {{\n  match n {{\n    _ => 0\n    k when k > 1 => 1\n  }}\n}}\nfn main() {{}}\n",
    "E0401",
    "this arm is unreachable",
  )
  has_note(d, "the arm `_` at line 3")
}

fn guarded_arm_doesnt_make_later_arm_unreachable() uses env, fs, ffi, time {
  clean("fn f(n: int): int {{\n  match n {{\n    k when k > 1 => 1\n    _ => 0\n  }}\n}}\nfn main() {{}}\n")
}

// ---- let, for, closures ----

fn let_else_that_always_matches() uses env, fs, ffi, time {
  let d = one(
    "enum One {{ Only(v: int) }}\nfn f(t: One): int {{\n  let Only(a) = t else {{ return 0 }}\n  a\n}}\nfn main() {{}}\n",
    "E0402",
    "the `else` of this `let` is never taken: the pattern matches every `One`",
  )
  fix(d, (3, 18, 3, 36), "")
  clean("fn f(xs: [int]): int {{\n  let [h, ..t] = xs else {{ return 0 }}\n  h\n}}\nfn main() {{}}\n")
}

fn refutable_let_without_else() uses env, fs, ffi, time {
  let d = one(
    "fn f(t: (int, bool)): int {{\n  let (a, true) = t\n  a\n}}\nfn main() {{}}\n",
    "E0403",
    "this `let` pattern might not match: `(_, false)` is not handled",
  )
  at(d, 2, 7)
  let d = one(
    "{SHAPE}fn f(xs: [Shape]): float {{\n  var t = 0.0\n  for Circle(r) in xs {{ t += r }}\n  t\n}}\nfn main() {{}}\n",
    "E0403",
    "the pattern of this `for` might not match: `Rect(_, _)` is not handled",
  )
  at(d, 4, 7)
}

// ---- effects ----

fn missing_effect_adds_uses() uses env, fs, ffi, time {
  let d = one(
    "fn load(p: str): str! {{\n  let s = fs.read(p)?\n  s\n}}\nfn main() {{}}\n",
    "E0410",
    "`load` uses the effect `fs` but doesn't declare it",
  )
  at(d, 2, 11)
  has_note(d, "call chain: `load` → `fs.read` (uses fs)")
  fix(d, (1, 22, 1, 22), " uses fs")
}

fn missing_effect_appends_to_list() uses env, fs, ffi, time {
  let d = one(
    "fn f(): int uses fs {{\n  let s = fs.read(\"x\") else \"\"\n  s.len() + time.now()\n}}\nfn main() {{}}\n",
    "E0410",
    "`f` uses the effect `time` but doesn't declare it",
  )
  fix(d, (1, 20, 1, 20), ", time")
}

fn missing_effect_without_return_type() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{\n  time.sleep(1)\n}}\n",
    "E0410",
    "`main` uses the effect `time` but doesn't declare it",
  )
  fix(d, (1, 10, 1, 10), " uses time")
  let d = one(
    "fn main() {{\n  time.sleep(rand.int(1, 2))\n}}\n",
    "E0410",
    "`main` uses the effects `time`, `rand` but doesn't declare them",
  )
  fix(d, (1, 10, 1, 10), " uses time, rand")
}

fn missing_effect_through_a_closure() uses env, fs, ffi, time {
  let d = one(
    "fn all(ps: [str]): [str] = ps.map(p => fs.read(p) else \"\")\nfn main() {{}}\n",
    "E0410",
    "`all` uses the effect `fs` but doesn't declare it",
  )
  has_note(d, "the closure at 1:35 is part of `all`, so its effects are `all`'s")
  fix(d, (1, 25, 1, 25), " uses fs")
}

fn missing_effect_through_a_function_value() uses env, fs, ffi, time {
  let d = one(
    "fn load(p: str): str uses fs = fs.read(p) else \"\"\nfn all(ps: [str]): [str] = ps.map(load)\nfn main() {{}}\n",
    "E0410",
    "`all` uses the effect `fs` but doesn't declare it",
  )
  at(d, 2, 35)
  has_note(d, "call chain: `all` → `load` (uses fs)")
}

fn missing_effect_through_a_shape_vtable() uses env, fs, ffi, time {
  let d = one(
    "shape Log {{ fn log(self, s: str) uses fs }}\nfn report(l: any Log) {{ l.log(\"hi\") }}\nfn main() {{}}\n",
    "E0410",
    "`report` uses the effect `fs` but doesn't declare it",
  )
  has_note(d, "call chain: `report` → `Log.log (through `any Log`)` (uses fs)")
  fix(d, (2, 22, 2, 22), " uses fs")
}

fn conversion_to_any_shape_checks_method_effects() uses env, fs, ffi, time {
  let d = one(
    "shape Log {{ fn log(self, s: str) }}\nstruct F {{ p: str }}\nfn log(f: F, s: str) uses fs {{ fs.write(f.p, s) else () }}\nfn report(l: any Log) {{ l.log(\"hi\") }}\nfn main() {{ report(F {{ p: \"a\" }}) }}\n",
    "E0415",
    "converting `F` to `any Log` would let `Log.log` use `fs`, which the shape doesn't declare",
  )
  at(d, 5, 20)
  has_note(d, "`log` for `F` (at 3:4) uses `fs`")
  fix(d, (1, 33, 1, 33), " uses fs")
}

fn missing_effect_through_a_generic_instance() uses env, fs, ffi, time {
  let src = "shape Area {{ fn area(self): float }}\nstruct Sq {{ s: float }}\nfn area(q: Sq): float uses fs {{\n  let _ = fs.read(\"x\") else \"\"\n  q.s * q.s\n}}\nfn total(xs: [Area]): float = xs.map(x => x.area()).sum()\nfn main() {{\n  print(total([Sq {{ s: 1.0 }}]))\n}}\n"
  let d = one(src, "E0410", "`main` uses the effect `fs` but doesn't declare it")
  at(d, 9, 9)
  has_note(d, "call chain: `main` → `total<Sq>` → `area` (uses fs)")
  fix(d, (8, 10, 8, 10), " uses fs")
  clean(src.replace("fn main() {{", "fn main() uses fs {{"))
}

fn unused_effect_is_a_warning() uses env, fs, ffi, time {
  let dir = scratch()
  let path = paths.join(dir, "t.auk")
  t.write(path, "fn f(): int uses fs, net = 1\nfn main() uses fs, net {{ print(f()) }}\n")
  let (ds, ok) = check_path(path)
  t.check(ok, "warnings must not fail the check")
  t.check(ds.len() == 1, "{ds}")
  let d = ds[0]
  assert (d.code, d.severity) == ("E0411", "warning")
  assert d.message == "`f` declares the effects `fs`, `net` but doesn't use them"
  fix(d, (1, 12, 1, 25), "")
  let out = auk(["check", path])
  assert out.success()
  let err = out.stderr
  t.check(
    err.contains("t.auk:1:18: warning[E0411]: `f` declares the effects `fs`, `net` but doesn't use them"),
    err,
  )
  // removing one of several keeps the rest
  t.write(
    path,
    "fn f(): int uses fs, net = (fs.read(\"a\") else \"\").len()\nfn main() uses fs, net {{ print(f()) }}\n",
  )
  let (ds, ok) = check_path(path)
  assert ok
  t.check(ds.len() == 1, "{ds}")
  assert ds[0].message == "`f` declares the effect `net` but doesn't use it"
  fix(ds[0], (1, 12, 1, 25), " uses fs")
}

fn impure_imprint_and_constants() uses env, fs, ffi, time {
  let d = one(
    "imprint T = fs.read(\"x\") else \"\"\nfn main() {{}}\n",
    "E0412",
    "`imprint T` is computed at compile time and must be pure, but its initializer uses the effect `fs`",
  )
  at(d, 1, 13)
  has_note(d, "call chain: `T` → `fs.read` (uses fs)")
  let _ = one(
    "let K = time.now()\nfn main() {{}}\n",
    "E0412",
    "the module constant `K` must be pure, but its initializer uses the effect `time`",
  )
  clean("imprint SQ = [1, 2, 3].map(x => x * x)\nfn main() {{ print(SQ) }}\n")
}

fn tests_print_and_peek_are_free() uses env, fs, ffi, time {
  clean("fn f(x: int): int = peek x * 2\ntest \"io\" {{\n  let s = fs.read(\"x\") else \"\"\n  print(s)\n  assert time.now() > 0\n}}\nfn main() {{ print(f(1)) }}\n")
}

fn main_gets_no_implicit_permission() uses env, fs, ffi, time {
  let d = one(
    "fn main(): ()! {{\n  print(fs.read(\"a\")?)\n}}\n",
    "E0410",
    "`main` uses the effect `fs` but doesn't declare it",
  )
  fix(d, (1, 15, 1, 15), " uses fs")
}

fn unknown_effect_name() uses env, fs, ffi, time {
  let d = one("fn f(): int uses fss = 1\nfn main() {{}}\n", "E0414", "unknown effect `fss`")
  fix(d, (1, 18, 1, 21), "fs")
}

// ---- the package ceiling ----

fn project(toml_effects: str, main: str): str uses fs {
  let dir = scratch()
  t.write(
    paths.join(dir, "raft.toml"),
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = {toml_effects}\n",
  )
  t.write(paths.join(dir, "src/main.auk"), main)
  dir
}

fn package_ceiling() uses env, fs, ffi, time {
  let dir = project(
    "[\"net\"]",
    "fn load(p: str): str! uses fs, net {{\n  var c = net.tcp(\"a\", 1)?\n  c.close()\n  fs.read(p)\n}}\nfn main(): ()! uses net {{\n  var c = net.tcp(\"b\", 2)?\n  c.close()\n}}\n",
  )
  let (ds, ok) = check_path(paths.join(dir, "src/main.auk"))
  assert !ok
  t.check(ds.len() == 1, "{ds}")
  let d = ds[0]
  assert (d.code, d.message) ==
    ("E0413", "`load` uses `fs`, but the package `app` allows only `net`")
  at(d, 1, 28)
  has_note(d, "help: add \"fs\" to `effects` under [package] in")
  has_note(d, "raft.toml")
  let dir = project("[]", "fn main() uses time {{ time.sleep(1) }}\n")
  let (ds, _) = check_path(paths.join(dir, "src/main.auk"))
  t.check(ds.len() == 1, "{ds}")
  assert ds[0].message == "`main` uses `time`, but the package `app` allows no effects"
  // a standalone file has no ceiling
  clean("fn main() uses time {{ time.sleep(1) }}\n")
}

fn dependency_checked_against_its_own_manifest() uses env, fs, ffi, time {
  let dir = project("[\"fs\"]", "fn main() uses fs {{ print(dep.load()) }}\n")
  t.write(
    paths.join(dir, "raft.toml"),
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = [\"fs\"]\n\n[deps]\ndep = \"^0.1\"\n",
  )
  let q = paths.join(dir, ".raft/dep")
  t.write(
    paths.join(q, "raft.toml"),
    "[package]\nname = \"dep\"\nversion = \"0.1.0\"\neffects = []\n",
  )
  t.write(paths.join(q, "src/lib.auk"), "pub fn load(): str uses fs = fs.read(\"x\") else \"\"\n")
  let (ds, ok) = check_path(paths.join(dir, "src/main.auk"))
  assert !ok
  t.check(ds.len() == 1, "{ds}")
  assert (ds[0].code, ds[0].message) ==
    ("E0413", "`load` uses `fs`, but the package `dep` allows no effects")
  t.check(
    ds[0].file is some(_) && (ds[0].file else "").ends_with(".raft/dep/src/lib.auk"),
    "{ds[0].file}",
  )
}

fn missing_and_unused_effects_get_one_combined_fix() uses env, fs, ffi, time {
  let src =
    "fn f(): str! uses net, fs, time {{\n  fs.read(\"x{{rand.int(1, 2)}}\")\n}}\nfn main() {{}}\n"
  let ds = check(src)
  t.check(ds.len() == 2, "{ds}")
  let by = (code: str) => match ds.find(d => d.code == code) {
    some(d) => d
    none => t.bail("no {code}: {ds}")
  }
  let (e, w) = (by("E0410"), by("E0411"))
  assert (e.code, e.message) == ("E0410", "`f` uses the effect `rand` but doesn't declare it")
  assert (w.code, w.message) ==
    ("E0411", "`f` declares the effects `net`, `time` but doesn't use them")
  // one fix, on the error, rewriting the whole list (the user's order, then the new effect)
  t.check(e.fixes.len() == 1, "{e}")
  fix(e, (1, 13, 1, 32), " uses fs, rand")
  t.check(w.fixes.len() == 0, "the warning must not carry a conflicting fix: {w}")
  let fixed = apply_fix(src, e.fixes[0])
  assert fixed ==
    "fn f(): str! uses fs, rand {{\n  fs.read(\"x{{rand.int(1, 2)}}\")\n}}\nfn main() {{}}\n"
  clean(fixed)
  // each alone still gets its own fix
  let d = one(
    "fn f(): str! uses fs {{\n  fs.read(\"x{{rand.int(1, 2)}}\")\n}}\nfn main() {{}}\n",
    "E0410",
    "`f` uses the effect `rand` but doesn't declare it",
  )
  fix(d, (1, 21, 1, 21), ", rand")
}

// ---- regressions: cascades and pointless `?` / `else` ----

fn closure_arity_mismatch_reports_only_e0204() uses env, fs, ffi, time {
  let _ = one(
    "fn f(xs: [int]): [int] = xs.map((a, b) => a)\nfn main() {{ print(f([1])) }}\n",
    "E0204",
    "this closure takes 2 parameter(s), but 1 are expected here",
  )
}

fn pointless_try_under_fallible_return() uses env, fs, ffi, time {
  // the `int!` return type must not make `?` on a plain `int` acceptable
  let d = one(
    "fn size(s: str): int! = s.len()?\nfn main() {{ print(size(\"a\")!) }}\n",
    "E0250",
    "`?` needs a `T!`, `T?` or a list of them, but `s.len()` is `int`",
  )
  fix(d, (1, 32, 1, 33), "")
}

fn try_on_shadowing_fallible_fn_is_fine() uses env, fs, ffi, time {
  // `s.len()` finds this module's `len` (an `int!`) before core's, so the `?` is needed
  clean("fn len(s: str): int! = s.len()?\nfn main() {{ print(len(\"a\") else 0) }}\n")
}

fn irrefutable_struct_let_else_is_e0255() uses env, fs, ffi, time {
  let d = one(
    "struct Point {{ x: int, y: int }}\nfn f(p: Point): int {{\n  let Point {{ x, .. }} = p else {{ return 0 }}\n  x\n}}\nfn main() {{ print(f(Point {{ x: 1, y: 2 }})) }}\n",
    "E0255",
    "this `let` always succeeds: `p` is a plain `Point` and the pattern always matches",
  )
  has_note(d, "remove the `else` part")
}
