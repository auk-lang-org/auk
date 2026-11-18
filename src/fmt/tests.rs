//! Unit tests for `auk fmt`. Every case also checks that the output parses to the same AST
//! (`format_checked`) and that formatting it again changes nothing.

use super::*;

/// Format `src`, checking meaning preservation and idempotence.
fn fmt(src: &str) -> String {
    let out = format_checked(src).unwrap_or_else(|e| panic!("{e:?}\n--- input ---\n{src}"));
    let again = format_checked(&out).unwrap_or_else(|e| panic!("{e:?}\n--- output ---\n{out}"));
    assert_eq!(again, out, "not idempotent\n--- first ---\n{out}\n--- second ---\n{again}");
    out
}

/// Assert that `src` formats to `want` (both given without the final newline).
#[track_caller]
fn check(src: &str, want: &str) {
    let got = fmt(src);
    assert_eq!(got.trim_end(), want, "\n--- got ---\n{got}--- want ---\n{want}\n");
}

/// `src` is already canonical.
#[track_caller]
fn same(src: &str) {
    check(src, src);
}

// ---- spacing ----

#[test]
fn spacing_and_operators() {
    check("fn f(a:int,b:int):int=a+b*c", "fn f(a: int, b: int): int = a + b * c");
    check("fn f( ) {  g( 1 ,2 )  }", "fn f() { g(1, 2) }");
    check("fn f() {\n  x+=1\n  y=-z\n  w = !a&&b||c\n}", "fn f() {\n  x += 1\n  y = -z\n  w = !a && b || c\n}");
    check("fn f() = 0..n+1", "fn f() = 0..n + 1");
    check("fn f() = xs[a..=b]", "fn f() = xs[a..=b]");
    check("let P = Point{x:1.0,y:2.0}", "let P = Point { x: 1.0, y: 2.0 }");
    check("let M = { \"a\" : 1 }", "let M = {\"a\": 1}");
    check("fn f(m: {str:[int]}, t: (int,str)): int?=none", "fn f(m: {str: [int]}, t: (int, str)): int? = none");
}

#[test]
fn literals_are_verbatim() {
    same("let N = 1_000 + 0xff + 1e-9");
    same("let S = r\"a\\d{2}\" + \"tab\\t {x:>5} {{}}\" + '\\n'.to_str()");
    same("fn f() {\n  let s = \"\"\"\n    keep   this\n      indent\n    \"\"\"\n  s\n}");
}

#[test]
fn trailing_commas_only_when_multi_line() {
    check("fn f() = g(a, b,)", "fn f() = g(a, b)");
    check("fn f() = [1, 2, 3,]", "fn f() = [1, 2, 3]");
    check(
        "fn f() = Thing {\n  alpha: 1,\n  beta: 2\n}",
        "fn f() = Thing {\n  alpha: 1,\n  beta: 2,\n}",
    );
    check("enum E {\n  A,\n  B\n}", "enum E {\n  A,\n  B,\n}");
}

// ---- line breaking ----

#[test]
fn long_argument_lists_break_one_per_line() {
    check(
        "fn f() {\n  let out = encode(request.method, target.path, authority(url), request.headers, request.body_text_utf8)\n}",
        "fn f() {\n  let out = encode(\n    request.method,\n    target.path,\n    authority(url),\n    request.headers,\n    request.body_text_utf8,\n  )\n}",
    );
    // short lists written over several lines are joined
    check("fn f() = g(\n  a,\n  b,\n)", "fn f() = g(a, b)");
}

#[test]
fn long_signatures_break_parameters() {
    check(
        "fn configure(name: str, verbose: bool, retries: int, timeout_ms: int, endpoint: str): Configuration { ?? }",
        "fn configure(\n  name: str,\n  verbose: bool,\n  retries: int,\n  timeout_ms: int,\n  endpoint: str,\n): Configuration { ?? }",
    );
}

#[test]
fn long_struct_literals() {
    check(
        "fn f() {\n  let r = Req { method: \"POST\", url: \"https://a.com/form\", headers: {\"X-Id\": \"7\"}, body: \"hello there\" }\n}",
        "fn f() {\n  let r = Req {\n    method: \"POST\",\n    url: \"https://a.com/form\",\n    headers: {\"X-Id\": \"7\"},\n    body: \"hello there\",\n  }\n}",
    );
    // a struct literal the user expanded stays expanded; a short one stays on one line
    same("fn f() = P {\n  x: 1,\n  y: 2,\n}");
    same("fn f() = P { x: 1, ..base }");
    // the last argument is hugged
    check(
        "fn f() {\n  await request(Req { method: \"POST\", url, headers: {\"Content-Type\": \"text/plain; charset=utf-8\"}, body })\n}",
        "fn f() {\n  await request(Req {\n    method: \"POST\",\n    url,\n    headers: {\"Content-Type\": \"text/plain; charset=utf-8\"},\n    body,\n  })\n}",
    );
}

#[test]
fn binary_operators_break_after_the_operator() {
    check(
        "fn f() {\n  assert parse_url(\"https://Example.COM/a/b?x=1&y=2#top\")? == Url { tls: true, host: \"example.com\", port: 443 }\n}",
        "fn f() {\n  assert parse_url(\"https://Example.COM/a/b?x=1&y=2#top\")? ==\n    Url { tls: true, host: \"example.com\", port: 443 }\n}",
    );
    check(
        "fn f() {\n  let gone = (see_other && name == \"content-type\") || (!same_origin && name == \"proxy-authorization\")\n}",
        "fn f() {\n  let gone =\n    (see_other && name == \"content-type\") || (!same_origin && name == \"proxy-authorization\")\n}",
    );
    // an expanded last operand stays on the operator's line
    same("fn f() {\n  assert xs == [\n    1,\n    2,\n  ]\n}");
}

#[test]
fn eq_bodies_stay_on_one_line_when_they_fit() {
    check("fn f(x: int): int =\n  x + 1", "fn f(x: int): int = x + 1");
    check(
        "pub fn switch(s: Spec, long: str, short: char?, help: str): Spec = s.add_opt(Opt { long, short, meta: \"\", help, kind: Flag })",
        "pub fn switch(s: Spec, long: str, short: char?, help: str): Spec =\n  s.add_opt(Opt { long, short, meta: \"\", help, kind: Flag })",
    );
    check(
        "fn f(n: int): str when n > 0 = \"a fairly long string that will not fit on the first line at all, really\"",
        "fn f(n: int): str when n > 0 =\n  \"a fairly long string that will not fit on the first line at all, really\"",
    );
}

#[test]
fn blocks() {
    same("fn f() { g() }");
    same("fn f() {\n  g()\n}");
    check("fn f() {\n}", "fn f() {}");
    // a one-line block that no longer fits breaks
    check(
        "fn f() { if ready { print(\"the quick brown fox jumps over the lazy dog, again and again and again and again\") } }",
        "fn f() {\n  if ready {\n    print(\"the quick brown fox jumps over the lazy dog, again and again and again and again\")\n  }\n}",
    );
    same("fn f() = if a { 1 } else if b { 2 } else { 3 }");
    same("fn f() {\n  let v = loop { if done() { break 42 } }\n}");
    same("fn f(x: int?) = match x { some(v) => v, none => 0 }");
    same("fn f(x: int?) {\n  match x {\n    some(v) when v > 0 => v\n    _ => 0\n  }\n}");
}

#[test]
fn blank_lines_in_blocks() {
    check(
        "fn f() {\n\n  a()\n\n\n\n  b()\n  c()\n\n}",
        "fn f() {\n  a()\n\n  b()\n  c()\n}",
    );
}

// ---- chains and pipes ----

#[test]
fn chains() {
    // short chains stay on one line
    same("fn f() = xs.filter(x => x > 0).map(x => x * 2).sum()");
    // optional chaining into a tuple element
    check("fn f() = xs.first() ?. 1 ?.len() else 0", "fn f() = xs.first()?.1?.len() else 0");
    same("fn f() = p?.0?.1");
    // three or more calls that don't fit break before each `.`
    check(
        "fn demo(): Spec = app(\"cp\", \"copy files\").switch(\"verbose\", 'v', \"say more\").switch(\"force\", 'f', \"overwrite\").arg(\"src\", \"file\")",
        "fn demo(): Spec = app(\"cp\", \"copy files\")\n  .switch(\"verbose\", 'v', \"say more\")\n  .switch(\"force\", 'f', \"overwrite\")\n  .arg(\"src\", \"file\")",
    );
    // a field prefix stays with the root
    check(
        "fn f(s: State) = s.items.filter(i => i.quantity > minimum_quantity).map(i => i.unit_price * i.quantity_in_stock).sum()",
        "fn f(s: State) = s.items\n  .filter(i => i.quantity > minimum_quantity)\n  .map(i => i.unit_price * i.quantity_in_stock)\n  .sum()",
    );
    // a chain the user broke stays broken
    same("fn f() = text\n  .lines()\n  .len()");
    // ...unless breaking after `=` is enough
    check(
        "fn total(s: State) = s.items.filter(i => i.quantity > minimum).map(i => i.unit_price * i.quantity).sum()",
        "fn total(s: State) =\n  s.items.filter(i => i.quantity > minimum).map(i => i.unit_price * i.quantity).sum()",
    );
    // two calls: the arguments break, not the chain
    check(
        "fn f() {\n  assert wide.help().contains(\"\\n      --a-very-long-option VALUE\\n                          wide\\n\", x)\n}",
        "fn f() {\n  assert wide.help().contains(\n    \"\\n      --a-very-long-option VALUE\\n                          wide\\n\",\n    x,\n  )\n}",
    );
}

#[test]
fn pipes() {
    same("fn f() = rows |> filter(r => r != \"\") |> map(g)?");
    check(
        "fn f() {\n  let xs = all_the_rows |> filter(r => r.trim() != \"\") |> map(r => float.parse(r.split(\",\")[column]))?\n}",
        "fn f() {\n  let xs = all_the_rows\n    |> filter(r => r.trim() != \"\")\n    |> map(r => float.parse(r.split(\",\")[column]))?\n}",
    );
    same("fn f() {\n  let xs = rows\n    |> filter(r => r != \"\")\n    |> map(g)?\n}");
    same("fn f() = (a |> g()).len()");
}

#[test]
fn hugged_closures() {
    same("fn f() {\n  xs.each(x => {\n    print(x)\n    log(x)\n  })\n}");
    same("fn f() {\n  let ys = xs.map(x => match x {\n    0 => 1\n    _ => x\n  })\n}");
}

// ---- items and clause groups ----

#[test]
fn clause_groups_stay_together() {
    check(
        "fn fib(0): int = 0\n\nfn fib(1): int = 1\n\n\nfn fib(n: int): int = fib(n - 1) + fib(n - 2)\nfn main() {\n  print(fib(10))\n}",
        "fn fib(0): int = 0\nfn fib(1): int = 1\nfn fib(n: int): int = fib(n - 1) + fib(n - 2)\n\nfn main() {\n  print(fib(10))\n}",
    );
    // a header line and its clauses
    same("/// The length.\npub fn len(xs: [int]): int\nfn len([]): int = 0\nfn len([_, ..t]): int = 1 + len(t)");
}

#[test]
fn blank_lines_between_items() {
    // multi-line items get a blank line around them
    check(
        "struct A { x: int }\nfn f() {\n  g()\n}\nfn h() {\n  g()\n}",
        "struct A { x: int }\n\nfn f() {\n  g()\n}\n\nfn h() {\n  g()\n}",
    );
    // one-line items written together stay together; runs of blank lines collapse
    same("enum Tok { Num(v: float), Op(c: char) }\nenum Expr { Lit(v: float), Neg(e: Expr) }");
    check("fn a() = 1\n\n\n\nfn b() = 2", "fn a() = 1\n\nfn b() = 2");
}

#[test]
fn contracts_and_holes() {
    same("fn isqrt(n: int): int\n  requires n >= 0\n  ensures result * result <= n\n{ ?? }");
    check(
        "fn f(a: var Account, amt: int)\n  requires amt > 0\n{\n  a.balance += amt\n}",
        "fn f(a: var Account, amt: int)\n  requires amt > 0\n{\n  a.balance += amt\n}",
    );
}

#[test]
fn other_items() {
    same("shape Area { fn area(self): float }");
    same("shape Pair {\n  fn left(self): int\n  fn right(self): int\n}");
    same("pub enum Shape { Circle(r: float), Rect(w: float, h: float), Wrap(int) }");
    same("pub async fn get<A: Show + Eq, B>(a: A, b: B): str! uses net, fs = \"\"");
    same("imprint TABLE = build()");
    same("test \"adds\" { assert 1 + 1 == 2 }");
    same("fn f(g: ((int) => int)?, h: (int, str) => bool, xs: [any Show]): {str: int}!E = ??");
}

// ---- parentheses ----

#[test]
fn parentheses_follow_precedence() {
    // needed ones stay, redundant ones go (except around operands, where they help reading)
    check("fn f() = ((a))", "fn f() = a");
    check("fn f() = g((a + b))", "fn f() = g(a + b)");
    same("fn f() = (a + b) * c");
    same("fn f() = a - (b - c)");
    same("fn f() = (a && b) || c");
    same("fn f() = (a < b) == c");
    same("fn f() = -(a + b)");
    same("fn f() = (2 ** 3) ** 4");
    same("fn f() = (x?).len()");
    same("fn f() = (await get(u)).body");
    same("fn f() = await get(u)?");
    same("fn f() = (x else y) + 1");
    same("fn f() {\n  if p == (Point { x: 1 }) { go() }\n  for (Point { x, y }) in ps { go() }\n  peek (-x)\n}");
    check("fn f() {\n  if (a > b) { go() }\n}", "fn f() {\n  if a > b { go() }\n}");
}

#[test]
fn bitwise_operators() {
    check(
        "fn f() {\n  x&=a|b^c&~d<<2>>1\n  x>>=1\n  y<<=2\n  z|=3\n  w^=4\n}",
        "fn f() {\n  x &= a | b ^ c & ~d << 2 >> 1\n  x >>= 1\n  y <<= 2\n  z |= 3\n  w ^= 4\n}",
    );
    same("fn f() = (a | b) & c");
    same("fn f() = (a + 1) << 2");
    same("fn f() = (x & 1) == 0");
    same("fn f() = -(~a)");
    same("fn f() = ~(a & b)");
    same("fn f() = 0..a << 1");
    same("fn f() = g(&xs, a & b)");
    // a comparison's bitwise operand keeps its parentheses, even when it starts with its own
    check("fn f() {\n  assert ((a >> n) & m) == 0\n  assert 0 != ((b) | c)\n}", "fn f() {\n  assert ((a >> n) & m) == 0\n  assert 0 != (b | c)\n}");
    check("fn f() = 1 == (((a) ^ b))", "fn f() = 1 == (a ^ b)");
}

// ---- comments ----

#[test]
fn comments_are_kept_in_place() {
    same("// a section\n\n/// Docs for f.\nfn f() {\n  // leading\n  g()  // trailing\n\n  // before h\n  h()\n  // dangling at the end\n}");
    // trailing comments on consecutive lines are aligned
    check(
        "enum E {\n  A(x: int), // first\n  LongerName(y: str, z: str),   // second\n}",
        "enum E {\n  A(x: int),                   // first\n  LongerName(y: str, z: str),  // second\n}",
    );
    // a comment after an opening brace stays on that line
    same("fn f() {  // why\n  g()\n}");
    // comments inside lists force them to break; inline block comments stay inline
    same("fn f() = g(\n  a,  // the first\n  b,\n)");
    same("fn f() = g(a, /* why */ b)");
    // comments inside struct definitions and match arms
    same("struct S {\n  /// The x.\n  x: int,  // pixels\n  y: int,\n}");
    same("fn f(x: int) {\n  match x {\n    0 => a()  // zero\n    // the rest\n    _ => b()\n  }\n}");
    // the end of the file
    same("fn f() = 1\n\n// the end");
}

#[test]
fn comments_are_never_lost() {
    // a comment in a spot the layout has no place for moves to the end of the line
    let out = fmt("fn f() {\n  let y = a + // why\n    b\n}");
    assert_eq!(out, "fn f() {\n  let y = a + b  // why\n}\n");
    let src = "/* a */ fn f(/* b */) /* c */ { /* d */ g(/* e */) /* f */ } /* g */\n// h\n";
    let out = fmt(src);
    for c in ["/* a */", "/* b */", "/* c */", "/* d */", "/* e */", "/* f */", "/* g */", "// h"] {
        assert!(out.contains(c), "lost {c} in:\n{out}");
    }
}

#[test]
fn doc_comments_stay_attached() {
    let src = "/// Module docs.\n\n/// Item docs\n/// over two lines.\npub struct P {\n  /// Field docs.\n  x: int,\n}\n";
    let a = parse(src).unwrap();
    let b = parse(&fmt(src)).unwrap();
    assert_eq!(a.doc, b.doc);
    let (Item::Struct(sa), Item::Struct(sb)) = (&a.items[0], &b.items[0]) else { panic!() };
    assert_eq!(sa.doc, sb.doc);
    assert_eq!(sa.fields[0].doc, sb.fields[0].doc);
}

// ---- errors and the corpus ----

#[test]
fn parse_errors_are_reported() {
    assert!(matches!(format_checked("fn f( {"), Err(Error::Parse(_))));
    assert!(matches!(format_checked("fn f() { a; b }"), Err(Error::Parse(_))));
}

#[test]
fn ast_shape_ignores_spans_and_ids() {
    let a = parse("fn f(a: int) = a + 1").unwrap();
    let b = parse("fn f(\n  a: int,\n) =\n    a+1").unwrap();
    assert_ne!(format!("{a:?}"), format!("{b:?}"));
    assert_eq!(ast_shape(&a), ast_shape(&b));
    assert_ne!(ast_shape(&a), ast_shape(&parse("fn f(a: int) = a + 2").unwrap()));
}

/// Every corpus file formats to the same AST (docs included) and is a fixed point.
#[test]
fn corpus_round_trips() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files = Vec::new();
    collect(&root.join("examples"), &mut files).unwrap();
    collect(&root.join("packages"), &mut files).unwrap();
    assert!(files.len() >= 17);
    for f in files {
        let src = fs::read_to_string(&f).unwrap();
        let out = format_checked(&src).unwrap_or_else(|e| panic!("{}: {e:?}", f.display()));
        assert_eq!(format(&out).unwrap(), out, "{} is not a fixed point", f.display());
    }
}
