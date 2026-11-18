/// tests/check.rs: the checker through `auk check`: the whole corpus checks clean (and its typed
/// program satisfies codegen's invariants), and small programs get the exact diagnostic codes,
/// messages and fix-its.
///
/// Differences from Rust: the `check --json` report is read with json.auk (Rust has a minimal
/// reader of its own; `str`/`num` keep its leniency: a bool reads as "true"/"false", anything
/// else missing as "" or 0); a scratch directory is a fresh `fs.temp_dir()` (Rust's
/// `auk-check-<pid>-<n>` under the temp dir).

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("corpus_checks_clean", corpus_checks_clean),
  t.test("corpus_typed_invariants", corpus_typed_invariants),
  t.test("shapes_monomorphize_per_type", shapes_monomorphize_per_type),
  t.test("feature_programs_check_clean", feature_programs_check_clean),
  t.test("mismatch_wrong_return_type", mismatch_wrong_return_type),
  t.test("mismatch_missing_return_type", mismatch_missing_return_type),
  t.test("mismatch_argument", mismatch_argument),
  t.test("mismatch_int_literal_for_float", mismatch_int_literal_for_float),
  t.test("mismatch_mixed_numbers_suggests_conversion", mismatch_mixed_numbers_suggests_conversion),
  t.test("missing_question_mark", missing_question_mark),
  t.test(
    "missing_question_mark_without_fallible_return",
    missing_question_mark_without_fallible_return,
  ),
  t.test(
    "try_in_plain_function_suggests_fallible_return",
    try_in_plain_function_suggests_fallible_return,
  ),
  t.test("try_on_optional_in_result_function", try_on_optional_in_result_function),
  t.test("try_cannot_convert_between_error_enums", try_cannot_convert_between_error_enums),
  t.test("try_on_plain_value", try_on_plain_value),
  t.test("optional_chaining_on_result", optional_chaining_on_result),
  t.test("optional_chaining_on_plain_value", optional_chaining_on_plain_value),
  t.test("field_of_optional_suggests_chaining", field_of_optional_suggests_chaining),
  t.test(
    "tuple_element_of_optional_suggests_chaining",
    tuple_element_of_optional_suggests_chaining,
  ),
  t.test("unwrap_plain_value", unwrap_plain_value),
  t.test("else_on_plain_value", else_on_plain_value),
  t.test("else_binder_on_optional", else_binder_on_optional),
  t.test("refutable_let_else_must_diverge", refutable_let_else_must_diverge),
  t.test("fail_outside_fallible_function", fail_outside_fallible_function),
  t.test("fail_with_wrong_value", fail_with_wrong_value),
  t.test("fail_with_message_in_typed_error_function", fail_with_message_in_typed_error_function),
  t.test("if_without_else_as_value", if_without_else_as_value),
  t.test("integer_literal_out_of_range_in_pattern", integer_literal_out_of_range_in_pattern),
  t.test("cannot_infer_empty_list", cannot_infer_empty_list),
  t.test("guards_cannot_fail", guards_cannot_fail),
  t.test("ignored_error", ignored_error),
  t.test("branch_mismatch_does_not_blame_return_type", branch_mismatch_does_not_blame_return_type),
  t.test("no_cascade_after_bad_receiver", no_cascade_after_bad_receiver),
  t.test("unknown_name_suggests_similar", unknown_name_suggests_similar),
  t.test("unknown_function", unknown_function),
  t.test("unknown_field_suggests_similar", unknown_field_suggests_similar),
  t.test("unknown_method", unknown_method),
  t.test("method_exists_for_other_types", method_exists_for_other_types),
  t.test("unknown_type_suggests_str", unknown_type_suggests_str),
  t.test("unknown_struct_field_in_literal", unknown_struct_field_in_literal),
  t.test("missing_struct_fields", missing_struct_fields),
  t.test("shape_used_as_value_type", shape_used_as_value_type),
  t.test("ambiguous_overload", ambiguous_overload),
  t.test("no_overload_for_first_argument", no_overload_for_first_argument),
  t.test("wrong_argument_count", wrong_argument_count),
  t.test("overloads_split_by_first_parameter_type", overloads_split_by_first_parameter_type),
  t.test("duplicate_function", duplicate_function),
  t.test("clause_parameter_types_disagree", clause_parameter_types_disagree),
  t.test("parameter_type_unknown", parameter_type_unknown),
  t.test("user_operator_missing", user_operator_missing),
  t.test("shape_fit_failure_names_missing_function", shape_fit_failure_names_missing_function),
  t.test("ord_not_automatic_for_structs", ord_not_automatic_for_structs),
  t.test("user_cmp_makes_a_type_ord", user_cmp_makes_a_type_ord),
  t.test("closures_are_not_show", closures_are_not_show),
  t.test("type_parameter_needs_bound", type_parameter_needs_bound),
  t.test("missing_ampersand", missing_ampersand),
  t.test("ampersand_on_plain_parameter", ampersand_on_plain_parameter),
  t.test("assign_to_let", assign_to_let),
  t.test("ref_to_let", ref_to_let),
  t.test("mutating_method_on_let", mutating_method_on_let),
  t.test("assign_to_plain_parameter", assign_to_plain_parameter),
  t.test("closure_cannot_assign_capture", closure_cannot_assign_capture),
  t.test("strings_are_immutable", strings_are_immutable),
  t.test("unawaited_async_call", unawaited_async_call),
  t.test("async_result_used_without_await", async_result_used_without_await),
  t.test("async_returned_where_value_expected", async_returned_where_value_expected),
  t.test("await_non_task", await_non_task),
  t.test("format_precision_on_int", format_precision_on_int),
  t.test("format_zero_pad_on_str", format_zero_pad_on_str),
  t.test("format_malformed", format_malformed),
  t.test("format_specs_that_fit", format_specs_that_fit),
  t.test("pattern_type_mismatch", pattern_type_mismatch),
  t.test("is_pattern_cannot_bind", is_pattern_cannot_bind),
  t.test("variant_pattern_field_count", variant_pattern_field_count),
  t.test("duplicate_binding", duplicate_binding),
  t.test("struct_pattern_needs_rest", struct_pattern_needs_rest),
  t.test("bare_variant_name_matches_variant", bare_variant_name_matches_variant),
  t.test("break_outside_loop", break_outside_loop),
  t.test("break_value_in_while", break_value_in_while),
  t.test("loop_over_string_suggests_chars", loop_over_string_suggests_chars),
  t.test("index_non_indexable", index_non_indexable),
  t.test("project_modules_and_paths", project_modules_and_paths),
  t.test("private_function_of_other_module", private_function_of_other_module),
  t.test("private_field_type_hides_field", private_field_type_hides_field),
  t.test("missing_dependency", missing_dependency),
  t.test("module_colliding_with_dependency", module_colliding_with_dependency),
  t.test("dependency_paths_and_name_rule", dependency_paths_and_name_rule),
  t.test("extern_needs_the_ffi_effect", extern_needs_the_ffi_effect),
  t.test("main_signature", main_signature),
  t.test("text_output_renders_fixes", text_output_renders_fixes),
  t.test("map_pattern_starts_a_match_arm", map_pattern_starts_a_match_arm),
]

fn auk(args: [str]): cmd.Out uses env, ffi, time = t.run_auk(args)

/// Install the dependencies of the example project and of the packages that have any (the
/// runner's setup did; Rust's `setup` runs once per test binary).
fn setup() {}

fn auk_files(dir: str): [str] uses fs = t.auk_files(dir)

/// Every example program, and every package checked from its root module.
fn corpus_roots(): [str] uses fs {
  let files = auk_files("examples")
  let pkgs = t
    .must(fs.list("packages"), "list packages")
    .sort()
    .map(n => "packages/{n}/src/lib.auk")
    .filter(p => fs.exists(p) && !fs.is_dir(p))
  files + pkgs
}

fn corpus_checks_clean() uses env, fs, ffi, time {
  setup()
  let files = corpus_roots()
  t.check(files.len() >= 15, "corpus too small: {files}")
  var failed: [str] = []
  for p in files {
    let out = auk(["check", p, "--json"])
    if !out.success() || !out.stdout.contains("\"ok\":true,\"diagnostics\":[]") {
      let text = auk(["check", p]).stderr
      failed.push("{p}:\n{text}")
    }
  }
  t.check(failed.len() == 0, "{failed.len()} corpus file(s) failed to check:\n{failed.join("\n")}")
}

/// The typed program of every corpus root has no inference variables or error types left, and
/// every generic instance is concrete (`auk typed` runs `TypedProgram::validate`).
fn corpus_typed_invariants() uses env, fs, ffi, time {
  t.skip_if_lacks("typed", "the typed program and its invariants")
  setup()
  for p in corpus_roots() {
    let out = auk(["typed", p])
    let text = out.stdout
    t.check(out.success() && !text.contains("INVARIANT"), "{p}:\n{text}{out.stderr}")
    t.check(text.contains(" instances, "), "{p}: {text}")
  }
}

fn shapes_monomorphize_per_type() uses env, fs, ffi, time {
  t.skip_if_lacks("typed", "the generic instances")
  setup()
  let out = auk(["typed", "examples/inventory.auk"])
  let text = out.stdout
  // (core's own generics instantiate too; `sort` is a runtime extern, so `filter` stands for them)
  for want in [
    "examples.top<Item>",
    "examples.report<Item>",
    "examples.report<Order>",
    "core.filter<int>",
  ] {
    t.check(text.contains(want), "missing instance {want}:\n{text}")
  }
  t.check(text.contains("fn examples.top<Ord>([Ord], int): [Ord]"), text)
}

// ---- small programs ----

/// A fresh directory for one test program (no raft.toml, so core only).
fn scratch(): str uses fs = t.must(fs.temp_dir(), "temp dir")

/// One diagnostic from `check --json`.
struct D {
  code: str,
  line: int,
  col: int,
  message: str,
  notes: [str],
  /// (line, col, end_line, end_col, text)
  fixes: [(int, int, int, int, str)],
}

/// Check `src` as a standalone file; the diagnostics in order.
fn check(src: str): [D] uses env, fs, ffi, time {
  let dir = scratch()
  let path = paths.join(dir, "t.auk")
  t.write(path, src)
  let ds = check_path(path)
  t.rm_rf(dir)
  ds
}

fn check_path(path: str): [D] uses env, ffi, time {
  let out = auk(["check", path, "--json"])
  let v = match json.parse(out.stdout) {
    ok(v) => v
    err(Bad(e)) => t.bail("{e}: {out.stdout}")
  }
  let ds = v.get("diagnostics").as_arr()
  // warnings (severity "warning") don't fail the check
  let errors = ds.filter(d => jstr(d.get("severity")) != "warning").len()
  t.check(out.success() == (errors == 0), "exit status vs diagnostics: {out.stdout}")
  ds.map(d => D {
    code: jstr(d.get("code")),
    line: jnum(d.get("line")),
    col: jnum(d.get("col")),
    message: jstr(d.get("message")),
    notes: d.get("notes").as_arr().map(n => jstr(n)),
    fixes: d
      .get("fixes")
      .as_arr()
      .map(
        f => (
          jnum(f.get("line")),
          jnum(f.get("col")),
          jnum(f.get("end_line")),
          jnum(f.get("end_col")),
          jstr(f.get("text")),
        ),
      ),
  })
}

/// Rust's reader: a string, a bool as text, anything else "".
fn jstr(j: json.Json): str = match j {
  Str(s) => s
  Bool(b) => "{b}"
  _ => ""
}

/// Rust's reader: a number as u32 (`as` saturates), anything else 0.
fn jnum(j: json.Json): int = match j {
  Num(n) => if n <= 0.0 { 0 } else { int(n) }
  _ => 0
}

/// The single diagnostic of `src`, which must have this code and message.
fn one(src: str, code: str, message: str): D uses env, fs, ffi, time {
  let ds = check(src)
  t.check(ds.len() == 1, "expected exactly one diagnostic for:\n{src}\ngot: {ds}")
  let d = ds[0]
  t.check((d.code, d.message) == (code, message), "{d}")
  d
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

// ---- positive programs: every feature the checker covers ----

fn feature_programs_check_clean() uses env, fs, ffi, time {
  for (name, src) in [
    ("features", FEATURES),
    ("spec examples", SPEC_EXAMPLES),
    ("generics", GENERICS),
  ] {
    let ds = check(src)
    t.check(ds.len() == 0, "{name}: {ds}")
  }
}

let FEATURES = "\nshape Area {{ fn area(self): float }}\nstruct Circle {{ r: float }}\nstruct Sq {{ s: float }}\nfn area(c: Circle): float = 3.14 * c.r * c.r\nfn area(s: Sq): float = s.s * s.s\nfn total(xs: [Area]): float = xs.map(x => x.area()).sum()\nfn draw(xs: [any Area]): float {{\n  var t = 0.0\n  for x in xs {{ t += x.area() }}\n  t\n}}\nfn biggest(a: Ord, b: Ord): Ord = if a > b {{ a }} else {{ b }}\nfn pair<A: Show, B: Show>(a: A, b: B): str = a.show() + b.show()\nstruct V {{ x: int, y: int }}\nfn add(a: V, b: V): V = V {{ x: a.x + b.x, y: a.y + b.y }}\nenum Tree {{ Leaf, Node(l: Tree, v: int, r: Tree) }}\nfn sum(Leaf): int = 0\nfn sum(Node(l, v, r)): int = sum(l) + v + sum(r)\nfn push2(xs: var [int], v: int) {{ xs.push(v) }}\nasync fn get(n: int): int! {{ n }}\nfn opt(n: int): int? = if n > 0 {{ n }} else {{ none }}\nfn twice(f: (int) => int, x: int): int = f(f(x))\nlet LIMIT = 10\nimprint TABLE = [1, 2, 3].map(x => x * x)\nfn fail_with(n: int): int! {{\n  if n > 0 {{ fail(\"bad {{n}}\") }}\n  n\n}}\ntest \"features\" {{\n  assert total([Circle {{ r: 1.0 }}, Circle {{ r: 2.0 }}]) > 0.0\n  assert draw([Circle {{ r: 1.0 }}, Sq {{ s: 2.0 }}]) > 0.0\n  assert biggest(3, 4) == 4 && biggest(\"a\", \"b\") == \"b\"\n  assert pair(1, \"x\") == \"1x\"\n  assert V {{ x: 1, y: 2 }} + V {{ x: 3, y: 4 }} == V {{ x: 4, y: 6 }}\n  assert sum(Node(Leaf, 3, Node(Leaf, 4, Leaf))) == 7\n  var xs = [1]\n  push2(&xs, 2)\n  xs.push2(3)\n  let (a, b) = await (get(1), get(2))\n  assert a? + b? == 3\n  let all = await [1, 2, 3].map(n => get(n))\n  assert all.len() == 3\n  let t = get(5)\n  assert (await t)? == 5\n  assert opt(3)?.show() is some(_)\n  assert (opt(-1) else 0) == 0\n  assert twice(x => x + 1, LIMIT) == 12\n  assert TABLE[2] == 9\n  assert peek xs.len() * 2 == 6\n  let s: Set<int> = set([1, 2, 2])\n  assert s.len() == 2\n  for k, v in {{\"a\": 1}} {{ assert k.len() == v }}\n  assert {{\"a\": 1}}.entries()[0] == (\"a\", 1)\n  assert xs.enum().map((i, x) => i + x)[0] == 1\n  assert xs.max()! == 3\n  let z = xs.find(x => x > 1) else return\n  assert z == 2\n  let e: int! = fail_with(1)\n  let msg = match e {{ ok(n) => \"{{n}}\", err(er) => \"{{er}}\" }}\n  assert msg.len() > 0 && e is err(_)\n  assert int('a') == 97 && char(97)! == 'a'\n  assert \"{{3.14159:.2}} {{42:>5}} {{\"x\":<3}}|\" == \"3.14    42 x  |\"\n  assert [3, 1, 2].sort() == [1, 2, 3] && [[1], [2]] == [[1], [2]] && (1, \"a\") < (2, \"b\")\n  assert str(['a', 'b']) == \"ab\"\n  match e {{ ok(_) => {{}}, err(_) => {{}} }}\n}}\n"

let GENERICS = "\nstruct Box<T> {{ v: T }}\nenum Tree<T> {{ Leaf, Node(l: Tree<T>, v: T, r: Tree<T>) }}\nfn insert<T: Ord>(t: Tree<T>, x: T): Tree<T> = match t {{\n  Leaf => Node(Leaf, x, Leaf)\n  Node(l, v, r) when x < v => Node(insert(l, x), v, r)\n  Node(l, v, r) => Node(l, v, insert(r, x))\n}}\nfn items<T>(Leaf: Tree<T>): [T] = []\nfn items<T>(Node(l, v, r): Tree<T>): [T] = items(l) + [v] + items(r)\nshape Same {{ fn same(self, o: Self): bool }}\nstruct Id {{ n: int }}\nfn same(a: Id, b: Id): bool = a.n == b.n\nfn all_same(xs: [Same]): bool = xs.all(x => x.same(xs[0]))\nstruct Money {{ cents: int }}\nfn show(m: Money): str = \"${{m.cents / 100}}\"\nfn unbox<T>(b: Box<T>): T = b.v\ntest \"generics\" {{\n  assert unbox(Box {{ v: 3 }}) == 3\n  let bs: Box<str> = Box {{ v: \"x\" }}\n  assert bs.v == \"x\"\n  var t: Tree<int> = Leaf\n  for x in [3, 1, 2] {{ t = insert(t, x) }}\n  assert items(t) == [1, 2, 3]\n  assert all_same([Id {{ n: 1 }}, Id {{ n: 1 }}])\n  let m = Money {{ cents: 250 }}\n  assert \"{{m}}\" == \"$2\" && [m].join(\",\") == \"$2\"\n  let f = unbox\n  assert f(Box {{ v: 1 }}) == 1\n}}\n"

let SPEC_EXAMPLES = "\nstruct Config {{ name: str }}\nstruct User {{ id: int, name: str }}\nenum ParseErr {{ BadToken(at: int), Eof }}\nstruct Ast {{ n: int }}\nstruct Point {{ x: float, y: float }}\nenum Shape {{ Circle(r: float), Rect(w: float, h: float) }}\nfn area(s: Shape): float = match s {{\n  Circle(r) => 3.14 * r * r\n  Rect(w, h) when w == h => w * w\n  Rect(w, h) => w * h\n}}\nfn fib(0): int = 0\nfn fib(1): int = 1\nfn fib(n: int): int = fib(n - 1) + fib(n - 2)\nfn len([], acc: int): int = acc\nfn len([_, ..t]: [int], acc: int): int = len(t, acc + 1)\nfn grade(n: int): str when n >= 90 = \"A\"\nfn grade(_: int): str = \"B\"\nfn parse_cfg(text: str): Config! = Config {{ name: text }}\nfn load(path: str): Config! uses fs {{\n  let text = fs.read(path)?\n  parse_cfg(text)?\n}}\nfn default(): Config = Config {{ name: \"x\" }}\nfn parse(s: str): Ast!ParseErr {{\n  if s == \"\" {{ fail(Eof) }}\n  Ast {{ n: s.len() }}\n}}\nfn find(xs: [User], id: int): User? = xs.find(u => u.id == id)\nfn first_or_zero(xs: [int]): int {{\n  let [h, ..t] = xs else {{ return 0 }}\n  h + t.len()\n}}\nfn nums(strs: [str]): [int]! = strs.map(s => int.parse(s))?\nfn isqrt(n: int): int\n  requires n >= 0\n  ensures result * result <= n\n{{ ?? }}\nfn deposit(a: var Point, d: float)\n  ensures a.x == old(a.x) + d\n{{\n  a.x += d\n}}\nasync fn get(url: str): str! uses net {{\n  var c = net.tcp(url, 80)?\n  c.close()\n  url\n}}\nasync fn both(u1: str, u2: str): [str!]! uses net {{\n  let page = await get(u1)?\n  let (a, b) = await (get(u1), get(u2))\n  let all = await [u1, u2].map(u => get(u))\n  [a, b] + all + [page]\n}}\ntest \"isqrt\" {{ assert isqrt(17) == 4 }}\nfn main(args: [str]): int! uses fs {{\n  var n: int = 0\n  n += 1\n  let p = Point {{ x: 1.0, y: 2.0 }}\n  let q = Point {{ x: 3.0, ..p }}\n  let (x, y) = (1.0, 2.0)\n  let r = Point {{ x, y }}\n  let c = load(\"a.toml\") else e => default()\n  let k = int.parse(\"12\") else 0\n  let name = find([User {{ id: 1, name: \"ann\" }}], 1)?.name else \"nobody\"\n  let v = loop {{ if k > 0 {{ break 42 }} }}\n  for i, (a, b) in [(1, 2)] {{ print(i + a + b) }}\n  print(\"{{c.name}} {{k}} {{name}} {{v}} {{area(Circle(2.0)) + q.x + r.y}} {{fib(10)}} {{len([1, 2], 0)}} {{grade(95)}} {{core.str(1)}}\")\n  print(parse(\"x\") is err(Eof))\n  0\n}}\n"

// ---- types ----

fn mismatch_wrong_return_type() uses env, fs, ffi, time {
  let d = one("fn f(a: int): str = a\n", "E0200", "expected `str`, found `int`")
  has_note(d, "convert with `str(x)`")
  fix(d, (1, 15, 1, 18), "int")
}

fn mismatch_missing_return_type() uses env, fs, ffi, time {
  let d = one(
    "fn f(n: int) = n * 2\n",
    "E0200",
    "this function has no return type, so it returns `()`, but its body is an `int`",
  )
  fix(d, (1, 13, 1, 13), ": int")
}

fn mismatch_argument() uses env, fs, ffi, time {
  let d = one(
    "fn twice(n: int): int = n * 2\nfn main() {{ print(twice(\"two\")) }}\n",
    "E0200",
    "expected `int`, found `str`",
  )
  assert (d.line, d.col) == (2, 25)
}

fn mismatch_int_literal_for_float() uses env, fs, ffi, time {
  let d = one("fn f(x: float): float = x * 2\n", "E0260", "can't apply `*` to `float` and `int`")
  fix(d, (1, 29, 1, 30), "2.0")
}

fn mismatch_mixed_numbers_suggests_conversion() uses env, fs, ffi, time {
  let d = one(
    "fn f(n: int, x: float): float = x + n\n",
    "E0260",
    "can't apply `+` to `float` and `int`",
  )
  fix(d, (1, 37, 1, 37), "float(")
  fix(d, (1, 38, 1, 38), ")")
}

fn missing_question_mark() uses env, fs, ffi, time {
  let d = one(
    "fn g(): int! = 1\nfn f(): int! {{\n  let x: int = g()\n  x\n}}\n",
    "E0201",
    "expected `int`, found `int!`: the value may be an error",
  )
  has_note(d, "add `?`")
  fix(d, (3, 19, 3, 19), "?")
}

fn missing_question_mark_without_fallible_return() uses env, fs, ffi, time {
  let d = one(
    "fn g(): int! = 1\nfn f(): int = g()\n",
    "E0201",
    "expected `int`, found `int!`: the value may be an error",
  )
  has_note(d, "handle it with `else`")
  t.check(d.fixes.len() == 0 || d.fixes.all(f => f.4 != "?"), "{d}")
}

fn try_in_plain_function_suggests_fallible_return() uses env, fs, ffi, time {
  let d = one(
    "fn f(): int {{\n  let n = int.parse(\"1\")?\n  n\n}}\n",
    "E0243",
    "`?` passes an error up, but this function returns `int`",
  )
  fix(d, (1, 9, 1, 12), "int!")
}

fn try_on_optional_in_result_function() uses env, fs, ffi, time {
  let d = one(
    "fn f(xs: [int]): int! {{\n  let x = xs.first()?\n  x\n}}\n",
    "E0249",
    "`?` on an optional `int?` in a function that returns `int!`",
  )
  has_note(d, "else fail(")
}

fn try_cannot_convert_between_error_enums() uses env, fs, ffi, time {
  let _ = one(
    "enum E {{ A }}\nenum F {{ B }}\nfn g(): int!E = 1\nfn f(): int!F {{\n  let x = g()?\n  x\n}}\n",
    "E0247",
    "`?` can't pass an `E` error up: this function returns `int!F`",
  )
}

fn try_on_plain_value() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{ print(1?) }}\n",
    "E0250",
    "`?` needs a `T!`, `T?` or a list of them, but `1` is `int`",
  )
  fix(d, (1, 20, 1, 21), "")
}

fn optional_chaining_on_result() uses env, fs, ffi, time {
  let d = one(
    "fn g(): int! = 1\nfn main(): ()! {{ print(g()?.show()) }}\n",
    "E0252",
    "`?.` works on `T?` only, but `g()` is `int!`",
  )
  fix(d, (2, 24, 2, 29), "(g()?).")
}

fn optional_chaining_on_plain_value() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{ print(5?.show()) }}\n",
    "E0253",
    "`?.` needs an optional `T?`, but `5` is `int`",
  )
  fix(d, (1, 20, 1, 22), ".")
}

fn field_of_optional_suggests_chaining() uses env, fs, ffi, time {
  let d = one(
    "struct P {{ x: int }}\nfn f(p: P?): int = p.x\n",
    "E0222",
    "`p` may be missing (`P?`), so it has no field `x`",
  )
  fix(d, (2, 21, 2, 22), "?.")
}

fn tuple_element_of_optional_suggests_chaining() uses env, fs, ffi, time {
  let d = one(
    "fn f(p: (int, str)?): str = p.1\n",
    "E0223",
    "`p` may be missing (`(int, str)?`), so it has no element 1",
  )
  fix(d, (1, 30, 1, 31), "?.")
  let _ = one(
    "fn f(p: (int, str)?): int? = p?.2\n",
    "E0223",
    "the tuple `(int, str)` has no element 2",
  )
  let _ = one(
    "fn f(p: int?): int? = p?.0\n",
    "E0223",
    "`?.0` needs an optional tuple, found `int?`",
  )
}

fn unwrap_plain_value() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{ print(1!) }}\n",
    "E0251",
    "`!` unwraps a `T?` or `T!`, but this is `int`",
  )
  fix(d, (1, 20, 1, 21), "")
}

fn else_on_plain_value() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{\n  let x = 1 else 2\n}}\n",
    "E0255",
    "this `let` always succeeds: `1` is a plain `int` and the pattern always matches",
  )
  fix(d, (2, 12, 2, 19), "")
}

fn else_binder_on_optional() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{\n  let x = [1].first() else e => 0\n}}\n",
    "E0254",
    "`else e =>` binds an error, but the value is optional (`T?`), so there is none",
  )
  fix(d, (2, 28, 2, 33), "")
}

fn refutable_let_else_must_diverge() uses env, fs, ffi, time {
  let _ = one(
    "fn f(xs: [int]): int {{\n  let [h, ..t] = xs else 0\n  h\n}}\n",
    "E0240",
    "the `else` of a refutable `let` must leave the block (return, break, continue or fail), but this is an `int`",
  )
}

fn fail_outside_fallible_function() uses env, fs, ffi, time {
  let d = one(
    "fn f(): int {{\n  fail(\"x\")\n}}\n",
    "E0242",
    "`fail` can only be used in a function that returns `T!` or `T!E` (or in a test)",
  )
  fix(d, (1, 9, 1, 12), "int!")
}

fn fail_with_wrong_value() uses env, fs, ffi, time {
  let _ = one(
    "fn f(): int! {{\n  fail(3)\n}}\n",
    "E0241",
    "`fail` needs a `str` message, an `Err` or an error enum value, found `int`",
  )
}

fn fail_with_message_in_typed_error_function() uses env, fs, ffi, time {
  let _ = one(
    "enum E {{ A }}\nfn f(): int!E {{\n  fail(\"x\")\n}}\n",
    "E0241",
    "this function's errors are `E`, so it can't fail with a message",
  )
}

fn if_without_else_as_value() uses env, fs, ffi, time {
  let _ = one(
    "fn f(c: bool): int = if c {{ 1 }}\n",
    "E0205",
    "an `if` without `else` has no value, but an `int` is expected here",
  )
}

fn integer_literal_out_of_range_in_pattern() uses env, fs, ffi, time {
  let _ = one(
    "fn f(99999999999999999999): int = 0\n",
    "E0005",
    "integer literal does not fit in 64 bits",
  )
}

fn cannot_infer_empty_list() uses env, fs, ffi, time {
  let d = one("fn main() {{ let xs = [] }}\n", "E0360", "can't infer the type of this expression")
  assert (d.line, d.col) == (1, 22)
}

fn guards_cannot_fail() uses env, fs, ffi, time {
  let _ = one(
    "fn f(s: str): int when int.parse(s)? > 0 = 1\nfn f(_: str): int = 0\n",
    "E0246",
    "`?` is not allowed in a guard",
  )
}

fn ignored_error() uses env, fs, ffi, time {
  let d = one(
    "fn save(): ()! = ()\nfn main(): ()! {{\n  save()\n  print(1)\n}}\n",
    "E0334",
    "the result of `save()` is a `()!`, and its error is ignored",
  )
  fix(d, (3, 9, 3, 9), "?")
  assert check("fn save(): ()! = ()\nfn main() {{\n  let _ = save()\n}}\n").len() == 0
}

fn branch_mismatch_does_not_blame_return_type() uses env, fs, ffi, time {
  let d = one(
    "fn f(c: bool): bool = if c {{ true }} else {{ 1 }}\n",
    "E0200",
    "expected `bool`, found `int`",
  )
  t.check(d.fixes.len() == 0, "{d}")
}

fn no_cascade_after_bad_receiver() uses env, fs, ffi, time {
  let ds = check("struct S {{ xs: [int] }}\nfn f(s: S): bool = s?.xs.all(x => x > 0)\n")
  t.check(ds.len() == 1, "{ds}")
  assert ds[0].code == "E0253"
}

// ---- names, fields, methods ----

fn unknown_name_suggests_similar() uses env, fs, ffi, time {
  let d = one("fn main() {{\n  let count = 1\n  print(cout)\n}}\n", "E0102", "unknown name `cout`")
  has_note(d, "did you mean `count`?")
  fix(d, (3, 9, 3, 13), "count")
}

fn unknown_function() uses env, fs, ffi, time {
  let _ = one("fn main() {{ frobnicate(1) }}\n", "E0102", "unknown function `frobnicate`")
}

fn unknown_field_suggests_similar() uses env, fs, ffi, time {
  let d = one(
    "struct P {{ name: str }}\nfn f(p: P): str = p.nmae\n",
    "E0221",
    "the struct `P` has no field `nmae`",
  )
  has_note(d, "its fields are: name")
  fix(d, (2, 21, 2, 25), "name")
}

fn unknown_method() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{ [1, 2].frob() }}\n",
    "E0103",
    "no function `frob` takes a `[int]` first (1 argument(s))",
  )
  assert (d.line, d.col) == (1, 20)
}

fn method_exists_for_other_types() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{ print(5.trim()) }}\n",
    "E0103",
    "no function `trim` takes an `int` first (1 argument(s))",
  )
  has_note(d, "trim(str): str")
}

fn unknown_type_suggests_str() uses env, fs, ffi, time {
  let d = one("fn f(s: string) {{}}\n", "E0104", "unknown type `string`")
  fix(d, (1, 9, 1, 15), "str")
}

fn unknown_struct_field_in_literal() uses env, fs, ffi, time {
  let d = one(
    "struct P {{ x: int }}\nfn main() {{ print(P {{ x: 1, z: 2 }}) }}\n",
    "E0225",
    "the struct `P` has no field `z`",
  )
  fix(d, (2, 29, 2, 30), "x")
}

fn missing_struct_fields() uses env, fs, ffi, time {
  let _ = one(
    "struct P {{ x: int, y: int }}\nfn main() {{ print(P {{ x: 1 }}) }}\n",
    "E0224",
    "the struct literal is missing field(s) `y` of `P`",
  )
}

fn shape_used_as_value_type() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{\n  let v: Show = 1\n}}\n",
    "E0105",
    "the shape `Show` can't be used as a type here",
  )
  fix(d, (2, 10, 2, 14), "any Show")
}

// ---- overloading ----

fn ambiguous_overload() uses env, fs, ffi, time {
  let d = one(
    "fn f<T>(x: [T]): int = 1\nfn f(x: [int]): int = 2\nfn main() {{ print(f([1])) }}\n",
    "E0301",
    "the call to `f` is ambiguous: 2 overloads take a `[int]` first",
  )
  has_note(d, "f([T]): int; f([int]): int")
}

fn no_overload_for_first_argument() uses env, fs, ffi, time {
  let d = one(
    "fn show2(n: int): str = \"\"\nfn show2(s: str): str = s\nfn main() {{ print(show2(1.5)) }}\n",
    "E0202",
    "no `show2` takes a first argument of type `float`",
  )
  has_note(d, "show2(int): str; show2(str): str")
}

fn wrong_argument_count() uses env, fs, ffi, time {
  let d = one(
    "fn f(a: int, b: int) {{}}\nfn main() {{ f(1) }}\n",
    "E0300",
    "`f` takes 2 argument(s), but 1 were given",
  )
  has_note(d, "f(int, int)")
}

fn overloads_split_by_first_parameter_type() uses env, fs, ffi, time {
  assert check("struct A {{ a: int }}\nstruct B {{ b: int }}\nfn show(x: A): str = \"a\"\nfn show(x: B): str = \"b\"\nfn main() {{ print(show(A {{ a: 1 }}) + B {{ b: 2 }}.show()) }}\n").len() ==
    0
}

fn duplicate_function() uses env, fs, ffi, time {
  let d = one(
    "fn f(x: int) = ()\nfn g() = ()\nfn f(y: int) = ()\n",
    "E0111",
    "`f` is defined twice with a first parameter of type `int` taking 1 parameter(s)",
  )
  has_note(d, "must be contiguous")
}

fn clause_parameter_types_disagree() uses env, fs, ffi, time {
  let d = one(
    "fn f(0, s: str): int = 0\nfn f(n: int, s: int): int = 1\n",
    "E0108",
    "this clause of `f` declares parameter 2 as `int`, but an earlier clause says `str`",
  )
  fix(d, (2, 17, 2, 20), "str")
}

fn parameter_type_unknown() uses env, fs, ffi, time {
  let _ = one("fn f(x) = ()\n", "E0109", "can't tell the type of parameter 1 of `f`")
}

fn user_operator_missing() uses env, fs, ffi, time {
  let d = one(
    "struct V {{ x: int }}\nfn main() {{ print(V {{ x: 1 }} + V {{ x: 2 }}) }}\n",
    "E0261",
    "`+` isn't defined for `V`",
  )
  has_note(d, "define `fn add(a: V, b: V): V`")
}

// ---- shapes ----

fn shape_fit_failure_names_missing_function() uses env, fs, ffi, time {
  let d = one(
    "shape Area {{ fn area(self): float }}\nstruct Tri {{ a: float }}\nfn total(xs: [Area]): float = 0.0\nfn main() {{ print(total([Tri {{ a: 1.0 }}])) }}\n",
    "E0350",
    "`Tri` doesn't fit the shape `Area`, which `total` needs (it takes `Area` values)",
  )
  has_note(d, "fn area(x: Tri): float")
}

fn ord_not_automatic_for_structs() uses env, fs, ffi, time {
  let d = one(
    "struct P {{ x: int }}\nfn main() {{ print([P {{ x: 1 }}].sort()) }}\n",
    "E0350",
    "`P` doesn't fit the shape `Ord`, which `sort` needs for its type parameter `T`",
  )
  has_note(d, "define `fn cmp(a: P, b: P): int`")
}

fn user_cmp_makes_a_type_ord() uses env, fs, ffi, time {
  assert check("struct P {{ x: int }}\nfn cmp(a: P, b: P): int = a.x - b.x\nfn main() {{ print([P {{ x: 1 }}].sort().len()) }}\n").len() ==
    0
}

fn closures_are_not_show() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{ print(x => x + 1) }}\n",
    "E0350",
    "`(int) => int` doesn't fit the shape `Show`, which `print` needs for its type parameter `T`",
  )
  has_note(d, "closures don't fit")
}

fn type_parameter_needs_bound() uses env, fs, ffi, time {
  let d = one(
    "fn f<T>(x: T): str = \"{{x}}\"\n",
    "E0350",
    "`T` doesn't fit the shape `Show`, to interpolate it into a string",
  )
  has_note(d, "<T: Show>")
}

// ---- var parameters and mutability ----

fn missing_ampersand() uses env, fs, ffi, time {
  let d = one(
    "fn f(xs: var [int]) {{ xs.push(1) }}\nfn main() {{\n  var a = [1]\n  f(a)\n}}\n",
    "E0310",
    "parameter `xs` of `f` is `var`, so the argument needs `&`",
  )
  fix(d, (4, 5, 4, 5), "&")
}

fn ampersand_on_plain_parameter() uses env, fs, ffi, time {
  let d = one(
    "fn f(xs: [int]) {{}}\nfn main() {{\n  var a = [1]\n  f(&a)\n}}\n",
    "E0311",
    "parameter 1 of `f` is not a `var` parameter, so its argument takes no `&`",
  )
  fix(d, (4, 5, 4, 6), "")
}

fn assign_to_let() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{\n  let n = 1\n  n += 1\n}}\n",
    "E0320",
    "can't assign to `n`: it isn't mutable",
  )
  fix(d, (2, 3, 2, 6), "var")
}

fn ref_to_let() uses env, fs, ffi, time {
  let d = one(
    "fn f(xs: var [int]) {{}}\nfn main() {{\n  let a = [1]\n  f(&a)\n}}\n",
    "E0320",
    "can't pass `&a`: `a` isn't mutable",
  )
  fix(d, (3, 3, 3, 6), "var")
}

fn mutating_method_on_let() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{\n  let xs = [1]\n  xs.push(2)\n}}\n",
    "E0320",
    "`push` changes its first argument, but `xs` isn't mutable",
  )
  fix(d, (2, 3, 2, 6), "var")
}

fn assign_to_plain_parameter() uses env, fs, ffi, time {
  let d = one("fn f(n: int) {{\n  n = 3\n}}\n", "E0320", "can't assign to `n`: it isn't mutable")
  fix(d, (1, 9, 1, 9), "var ")
}

fn closure_cannot_assign_capture() uses env, fs, ffi, time {
  let _ = one(
    "fn main() {{\n  var n = 0\n  let f = () => {{ n = 1 }}\n}}\n",
    "E0323",
    "a closure can't change `n`, a variable it captures",
  )
}

fn strings_are_immutable() uses env, fs, ffi, time {
  let _ = one(
    "fn main() {{\n  var s = \"ab\"\n  s[0] = 'c'\n}}\n",
    "E0322",
    "strings are immutable: `s[i]` can't be assigned",
  )
}

// ---- async ----

fn unawaited_async_call() uses env, fs, ffi, time {
  let d = one(
    "async fn get(): int = 1\nfn main() {{\n  get()\n  print(1)\n}}\n",
    "E0332",
    "this `async fn` call is never awaited",
  )
  fix(d, (3, 3, 3, 3), "await ")
}

fn async_result_used_without_await() uses env, fs, ffi, time {
  let d = one(
    "async fn get(): int = 1\nfn main() {{ print(get() + 1) }}\n",
    "E0333",
    "`get()` is an un-awaited `async fn` call, so `+` can't use its value",
  )
  fix(d, (2, 19, 2, 19), "await ")
}

fn async_returned_where_value_expected() uses env, fs, ffi, time {
  let d = one(
    "async fn get(): int = 1\nfn f(): int = get()\n",
    "E0333",
    "expected `int`, found an un-awaited `async fn` call",
  )
  fix(d, (2, 15, 2, 15), "await ")
}

fn await_non_task() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{ let x = await 1 }}\n",
    "E0331",
    "`await` needs an `async fn` call, a task, a tuple of tasks or a list of tasks, but `1` is `int`",
  )
  fix(d, (1, 21, 1, 27), "")
}

// ---- interpolation ----

fn format_precision_on_int() uses env, fs, ffi, time {
  let _ = one(
    "fn main(n: int) {{}}\n",
    "E0370",
    "`main` has an unsupported signature: (int) returning `()`",
  )
  let d = one(
    "fn f(n: int): str = \"{{n:.2}}\"\n",
    "E0280",
    "the format spec `.2` has a precision, which applies to `float` and `str`, not `int`",
  )
  assert (d.line, d.col) == (1, 23)
}

fn format_zero_pad_on_str() uses env, fs, ffi, time {
  let _ = one(
    "fn f(s: str): str = \"{{s:05}}\"\n",
    "E0281",
    "the format spec `05` pads with zeros, which applies to numbers, not `str`",
  )
}

fn format_malformed() uses env, fs, ffi, time {
  let _ = one(
    "fn f(n: int): str = \"{{n:e}}\"\n",
    "E0282",
    "malformed format spec `e`: unexpected `e`",
  )
}

fn format_specs_that_fit() uses env, fs, ffi, time {
  assert check("fn f(x: float, n: int, s: str): str = \"{{x:.2}} {{n:>5}} {{n:05}} {{s:<10}} {{s:.3}} {{s:-^9}} {{x:08.3}}\"\n").len() ==
    0
}

// ---- patterns ----

fn pattern_type_mismatch() uses env, fs, ffi, time {
  let _ = one(
    "fn f(x: int): int = match x {{\n  \"a\" => 1\n  _ => 2\n}}\n",
    "E0262",
    "this pattern matches a `str`, but the value is an `int`",
  )
}

fn is_pattern_cannot_bind() uses env, fs, ffi, time {
  let d = one(
    "fn f(x: int?): bool = x is some(y)\n",
    "E0263",
    "an `is` pattern can't bind names, but `y` would bind one",
  )
  fix(d, (1, 33, 1, 34), "_")
}

fn variant_pattern_field_count() uses env, fs, ffi, time {
  let _ = one(
    "enum E {{ A(x: int, y: int) }}\nfn f(e: E): int = match e {{\n  A(x) => x\n}}\n",
    "E0264",
    "the variant `A` has 2 field(s), but the pattern has 1",
  )
}

fn duplicate_binding() uses env, fs, ffi, time {
  let _ = one(
    "fn f(p: (int, int)): int = match p {{\n  (a, a) => a\n}}\n",
    "E0265",
    "`a` is bound twice in this pattern",
  )
}

fn struct_pattern_needs_rest() uses env, fs, ffi, time {
  let d = one(
    "struct P {{ x: int, y: int }}\nfn f(p: P): int = match p {{\n  P {{ x }} => x\n}}\n",
    "E0266",
    "this pattern doesn't mention the field(s) `y` of `P`",
  )
  fix(d, (3, 9, 3, 9), ", ..")
}

fn bare_variant_name_matches_variant() uses env, fs, ffi, time {
  // `Eof` is a variant in scope, so it matches it (not a binding); `other` binds
  assert check("enum T {{ Eof, Word(s: str) }}\nfn f(t: T): str = match t {{\n  Eof => \"end\"\n  other => \"word\"\n}}\n").len() ==
    0
}

// ---- control flow ----

fn break_outside_loop() uses env, fs, ffi, time {
  let _ = one("fn main() {{ break }}\n", "E0244", "`break` outside a loop")
}

fn break_value_in_while() uses env, fs, ffi, time {
  let _ = one(
    "fn main() {{\n  while true {{ break 1 }}\n}}\n",
    "E0245",
    "only `loop` can `break` with a value",
  )
}

fn loop_over_string_suggests_chars() uses env, fs, ffi, time {
  let d = one(
    "fn main() {{\n  for c in \"abc\" {{ print(c) }}\n}}\n",
    "E0207",
    "can't loop over a `str`",
  )
  fix(d, (2, 17, 2, 17), ".chars()")
}

fn index_non_indexable() uses env, fs, ffi, time {
  let _ = one("fn main() {{ print(5[0]) }}\n", "E0270", "can't index an `int`")
}

// ---- modules, privacy, packages ----

/// A project with `raft.toml` and the given `src/` files; returns its directory.
fn project(files: [(str, str)], deps: [str]): str uses fs {
  let dir = scratch()
  var toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n"
  if deps.len() > 0 {
    toml = toml + "\n[deps]\n"
    for d in deps { toml = toml + "{d} = \"^0.1\"\n" }
  }
  t.write(paths.join(dir, "raft.toml"), toml)
  for (name, src) in files { t.write(paths.join(dir, "src/{name}"), src) }
  dir
}

let GEO = "pub struct Circle {{ r: float }}\npub enum Kind {{ Big, Small }}\npub fn area(c: Circle): float = 3.14 * c.r * c.r * float(app.helper())\nfn secret(): int = 2\n"

fn project_modules_and_paths() uses env, fs, ffi, time {
  let main = "pub fn helper(): int = 1\nfn main() {{\n  let c = geo.Circle {{ r: 1.0 }}\n  print(geo.area(c) + c.area())\n  print(geo.shapes.sides(geo.shapes.Tri))\n  let k: geo.Kind = geo.Big\n  print(k == geo.Kind.Small)\n  match k {{ Big => print(\"big\"), _ => {{}} }}\n}}\n"
  let shapes =
    "pub enum Poly {{ Tri, Quad }}\npub fn sides(Tri): int = 3\npub fn sides(Quad): int = 4\n"
  let dir = project([("main.auk", main), ("geo.auk", GEO), ("geo/shapes.auk", shapes)], [])
  let ds = check_path(paths.join(dir, "src/main.auk"))
  t.check(ds.len() == 0, "{ds}")
}

fn private_function_of_other_module() uses env, fs, ffi, time {
  let main = "pub fn helper(): int = 1\nfn main() {{ print(geo.secret()) }}\n"
  let dir = project([("main.auk", main), ("geo.auk", GEO)], [])
  let ds = check_path(paths.join(dir, "src/main.auk"))
  t.check(ds.len() == 1, "{ds}")
  assert (ds[0].code, ds[0].message) == ("E0120", "`secret` is private to module `app.geo`")
}

fn private_field_type_hides_field() uses env, fs, ffi, time {
  let lib = "struct Hidden {{ x: int }}\npub struct Pt {{ x: int, h: Hidden }}\npub fn make(): Pt = Pt {{ x: 1, h: Hidden {{ x: 2 }} }}\n"
  let main = "fn main() {{\n  let p = lib.make()\n  print(p.x)\n  print(p.h)\n}}\n"
  let dir = project([("main.auk", main), ("lib2.auk", lib.replace("lib", "lib2"))], [])
  let main2 = main.replace("lib.", "lib2.")
  t.write(paths.join(dir, "src/main.auk"), main2)
  let ds = check_path(paths.join(dir, "src/main.auk"))
  t.check(ds.len() == 1, "{ds}")
  assert (ds[0].code, ds[0].message) ==
    ("E0121", "the field `h` of `Pt` is private to module `app.lib2`")
  has_note(ds[0], "its type is private to that module")
}

fn missing_dependency() uses env, fs, ffi, time {
  let dir = project([("main.auk", "fn main() {{}}\n")], ["json"])
  let ds = check_path(paths.join(dir, "src/main.auk"))
  t.check(ds.len() == 1, "{ds}")
  assert (ds[0].code, ds[0].message) == ("E0100", "dependency `json` of `app` is not installed")
  has_note(ds[0], "raft install")
}

fn module_colliding_with_dependency() uses env, fs, ffi, time {
  let dir = project([("main.auk", "fn main() {{}}\n"), ("json.auk", "pub fn x() = ()\n")], ["json"])
  let q = paths.join(dir, ".raft/json/src")
  t.write(paths.join(q, "lib.auk"), "pub fn parse(s: str): int = 1\n")
  t.write(
    paths.join(dir, ".raft/json/raft.toml"),
    "[package]\nname = \"json\"\nversion = \"0.1.0\"\n",
  )
  let ds = check_path(paths.join(dir, "src/main.auk"))
  t.check(ds.len() == 1, "{ds}")
  assert (ds[0].code, ds[0].message) ==
    ("E0101", "module `app.json` has the same name as the dependency `json`")
}

fn dependency_paths_and_name_rule() uses env, fs, ffi, time {
  setup()
  // `regex(p)` means `regex.regex(p)`; dependency variants match unqualified by type
  let dir = project(
    [
      (
        "main.auk",
        "fn main(): ()! {{\n  let r = regex(\"a+\")?\n  print(r.find(\"baa\") else \"\")\n  match regex(\"(\") {{\n    err(Unclosed(at, _)) => print(at)\n    _ => print(0)\n  }}\n  let v = json.parse(\"[1]\")?\n  print(json.str(v))\n}}\n",
      ),
    ],
    ["regex", "json"],
  )
  let out = t.raft().arg("install").cwd(dir).output()
  t.check(out.success(), out.stderr)
  let ds = check_path(paths.join(dir, "src/main.auk"))
  t.check(ds.len() == 0, "{ds}")
}

fn extern_needs_the_ffi_effect() uses env, fs, ffi, time {
  // a standalone file has no raft.toml to declare `ffi` in (projects: tests/ffi.rs)
  let _ = one(
    "extern fn f(): int = \"int f(void)\"\n",
    "E0036",
    "`extern` declarations need the `ffi` effect in the package's raft.toml",
  )
}

fn main_signature() uses env, fs, ffi, time {
  let _ = one(
    "fn main(x: int) {{}}\n",
    "E0370",
    "`main` has an unsupported signature: (int) returning `()`",
  )
}

fn text_output_renders_fixes() uses env, fs, ffi, time {
  let dir = scratch()
  let path = paths.join(dir, "t.auk")
  t.write(path, "fn f(xs: var [int]) {{}}\nfn main() {{\n  var a = [1]\n  f(a)\n}}\n")
  let out = auk(["check", path])
  let err = out.stderr
  assert !out.success()
  t.check(
    err.contains("error[E0310]: parameter `xs` of `f` is `var`, so the argument needs `&`"),
    err,
  )
  t.check(err.contains("= fix: insert `&` at 4:5"), err)
}

fn map_pattern_starts_a_match_arm() uses env, fs, ffi, time {
  // on a map, on the first arm and on a later one (the lexer joins a line starting with `{`)
  let src = "fn f(v: {{str: int}}): int {{\n  match v {{\n    {{\"b\": n}} => n\n    {{\"a\": n}} => n + 1\n    _ => 0\n  }}\n}}\nfn g(v: {{str: int}}): int = match v {{ {{\"a\": n}} => n, _ => 0 }}\nfn h(v: Value): int {{\n  match v {{\n    Value.Null => 0\n    {{\"a\": Value.Int(n)}} => n\n    _ => 1\n  }}\n}}\nfn main() {{}}\n"
  let ds = check(src)
  t.check(ds.len() == 0, "{ds}")
  // the bound value really is type-checked: `n` is an `int`
  let d = one(
    "fn f(v: {{str: int}}): str {{\n  match v {{\n    _ when false => \"\"\n    {{\"a\": n}} => n\n    _ => \"\"\n  }}\n}}\nfn main() {{}}\n",
    "E0200",
    "expected `str`, found `int`",
  )
  assert (d.line, d.col) == (4, 17)
}
