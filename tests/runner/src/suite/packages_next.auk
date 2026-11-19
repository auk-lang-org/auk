/// tests/packages_next.rs: the packages from `design/packages-next.md`: `auk test` passes for each
/// with the leak checker on, and raft installs each one into a fresh project.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("next_package_tests_pass_without_leaks", next_package_tests_pass_without_leaks),
  t.test(
    "term_colors_follow_no_color_and_force_color",
    term_colors_follow_no_color_and_force_color,
  ),
  t.test("template_renders_a_struct_from_an_app", template_renders_a_struct_from_an_app),
  t.test("markdown_renders_safely_from_an_app", markdown_renders_safely_from_an_app),
]

let PKGS = ["term", "template", "markdown"]

fn raft(dir: str, args: [str]): cmd.Out uses env, ffi, time {
  t.raft().args(args).cwd(dir).setenv("RAFT_REGISTRY", t.abs("packages")).output()
}

/// `raft install` in the packages with dependencies (a stale lock regenerated).
fn setup() uses env, fs, ffi, time {
  for p in PKGS {
    let dir = t.abs("packages/{p}")
    if !t.read(paths.join(dir, "raft.toml")).contains("[deps]") { continue }
    if !raft(dir, ["install"]).success() {
      let _ = fs.remove(paths.join(dir, "raft.lock"))
      t.rm_rf(paths.join(dir, ".raft"))
      let out = raft(dir, ["install"])
      t.check(out.success(), "raft install in {p}: {out.stderr}")
    }
  }
}

fn next_package_tests_pass_without_leaks() uses env, fs, ffi, time {
  setup()
  for p in PKGS {
    let o = t
      .auk()
      .args(["test", "packages/{p}/src/lib.auk"])
      .setenv("AUK_LEAK_CHECK", "1")
      .output()
    let out = o.stdout
    t.check(o.success() && out.ends_with(" passed, 0 failed\n"), "{p}:\n{out}\n{o.stderr}")
    t.check(!out.contains("FAIL") && !out.contains("leak:"), "{p}:\n{out}")
  }
}

fn app(name: str, effects: str, main: str): str uses env, fs, ffi {
  let dir = t.scratch("next/{name}")
  t.write(
    paths.join(dir, "raft.toml"),
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = [{effects}]\n",
  )
  t.write(paths.join(dir, "src/main.auk"), main)
  dir
}

fn term_colors_follow_no_color_and_force_color() uses env, fs, ffi, time {
  let dir = app(
    "term",
    "\"env\"",
    "fn main(): int uses env {{\n  term.println(term.red(\"hi\"))\n  print(term.width(term.bold(\"日本\")))\n  0\n}}\n",
  )
  let out = raft(dir, ["add", "term"])
  t.check(out.success(), "raft add term: {out.stderr}")
  let run = (vars: [(str, str)]) => {
    var c = t
      .auk()
      .args(["run", "src/main.auk"])
      .cwd(dir)
      .unsetenv("NO_COLOR")
      .unsetenv("FORCE_COLOR")
    for (k, v) in vars { c = c.setenv(k, v) }
    let o = c.output()
    t.check(o.success(), o.stderr)
    o.stdout
  }
  // stdout is a pipe here, so color is off unless forced
  t.eq(run([]), "hi\n4\n", "")
  t.eq(run([("FORCE_COLOR", "1")]), "\u{1b}[31mhi\u{1b}[0m\n4\n", "")
  t.eq(run([("FORCE_COLOR", "1"), ("NO_COLOR", "1")]), "hi\n4\n", "")
  t.eq(run([("FORCE_COLOR", "0")]), "hi\n4\n", "")
}

fn template_renders_a_struct_from_an_app() uses env, fs, ffi, time {
  let dir = app("template", "", r"""
      struct Item { name: str, n: int }
      fn main(): int! {
        let t = template.html(r"{% for it in items %}<b>{{ it.name }}</b>={{ it.n }};{% end %}")?
        print(template.render(t, {"items": [Item { name: "a&b", n: 1 }, Item { name: "c", n: 2 }]})?)
        match template.render_text(r"{{ missing }}", {"x": 1}) {
          err(e) => print(template.message(e))
          ok(_) => print("rendered")
        }
        0
      }
      """)
  let out = raft(dir, ["add", "template"])
  t.check(out.success(), "raft add template: {out.stderr}")
  let o = t.auk().args(["run", "src/main.auk"]).cwd(dir).output()
  t.check(o.success(), o.stderr)
  t.eq(
    o.stdout,
    "<b>a&amp;b</b>=1;<b>c</b>=2;\n1:1: `missing` is undefined (use `| default(...)` if it may be missing)\n",
    "",
  )
}

fn markdown_renders_safely_from_an_app() uses env, fs, ffi, time {
  let dir = app(
    "markdown",
    "",
    "fn main() {{\n  print(markdown.html(\"# Hi\\n\\n*a* <script>x</script> [b](javascript:x)\"))\n  print(markdown.text(\"**t** &amp; u\"))\n}}\n",
  )
  let out = raft(dir, ["add", "markdown"])
  t.check(out.success(), "raft add markdown: {out.stderr}")
  let o = t.auk().args(["run", "src/main.auk"]).cwd(dir).output()
  t.check(o.success(), o.stderr)
  t.eq(
    o.stdout,
    "<h1>Hi</h1>\n<p><em>a</em> &lt;script&gt;x&lt;/script&gt; <a href=\"\">b</a></p>\n\nt & u\n",
    "",
  )
}
