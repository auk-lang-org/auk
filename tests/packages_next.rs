//! The packages from `docs/packages-next.md`: `duck test` passes for each with the leak checker
//! on, and quack installs each one into a fresh project.

use std::path::Path;
use std::process::Command;
use std::sync::Once;
use std::{env, fs};

const PKGS: [&str; 3] = ["term", "template", "markdown"];

fn quack(dir: &Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_quack"))
        .args(args)
        .current_dir(dir)
        .env("QUACK_REGISTRY", Path::new(env!("CARGO_MANIFEST_DIR")).join("packages"))
        .output()
        .unwrap()
}

fn setup() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        for p in PKGS {
            let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("packages").join(p);
            if !fs::read_to_string(dir.join("quack.toml")).unwrap().contains("[deps]") {
                continue;
            }
            if !quack(&dir, &["install"]).status.success() {
                let _ = fs::remove_file(dir.join("quack.lock"));
                let _ = fs::remove_dir_all(dir.join(".quack"));
                let out = quack(&dir, &["install"]);
                assert!(out.status.success(), "quack install in {p}: {}", String::from_utf8_lossy(&out.stderr));
            }
        }
    });
}

#[test]
fn next_package_tests_pass_without_leaks() {
    setup();
    for p in PKGS {
        let o = Command::new(env!("CARGO_BIN_EXE_duck"))
            .args(["test", &format!("packages/{p}/src/lib.duck")])
            .env("DUCK_LEAK_CHECK", "1")
            .output()
            .unwrap();
        let out = String::from_utf8_lossy(&o.stdout);
        assert!(o.status.success() && out.ends_with(" passed, 0 failed\n"), "{p}:\n{out}\n{}", String::from_utf8_lossy(&o.stderr));
        assert!(!out.contains("FAIL") && !out.contains("leak:"), "{p}:\n{out}");
    }
}

fn app(name: &str, effects: &str, main: &str) -> std::path::PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("next").join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::write(dir.join("quack.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = [{effects}]\n")).unwrap();
    fs::write(dir.join("src/main.duck"), main).unwrap();
    dir
}

#[test]
fn term_colors_follow_no_color_and_force_color() {
    let dir = app(
        "term",
        "\"env\"",
        "fn main(): int uses env {\n  term.println(term.red(\"hi\"))\n  print(term.width(term.bold(\"日本\")))\n  0\n}\n",
    );
    let out = quack(&dir, &["add", "term"]);
    assert!(out.status.success(), "quack add term: {}", String::from_utf8_lossy(&out.stderr));
    let run = |vars: &[(&str, &str)]| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_duck"));
        c.args(["run", "src/main.duck"]).current_dir(&dir).env_remove("NO_COLOR").env_remove("FORCE_COLOR");
        for (k, v) in vars {
            c.env(k, v);
        }
        let o = c.output().unwrap();
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
        String::from_utf8(o.stdout).unwrap()
    };
    // stdout is a pipe here, so color is off unless forced
    assert_eq!(run(&[]), "hi\n4\n");
    assert_eq!(run(&[("FORCE_COLOR", "1")]), "\x1b[31mhi\x1b[0m\n4\n");
    assert_eq!(run(&[("FORCE_COLOR", "1"), ("NO_COLOR", "1")]), "hi\n4\n");
    assert_eq!(run(&[("FORCE_COLOR", "0")]), "hi\n4\n");
}

#[test]
fn template_renders_a_struct_from_an_app() {
    let dir = app(
        "template",
        "",
        r#"struct Item { name: str, n: int }
fn main(): int! {
  let t = template.html(r"{% for it in items %}<b>{{ it.name }}</b>={{ it.n }};{% end %}")?
  print(template.render(t, {"items": [Item { name: "a&b", n: 1 }, Item { name: "c", n: 2 }]})?)
  match template.render_text(r"{{ missing }}", {"x": 1}) {
    err(e) => print(template.message(e))
    ok(_) => print("rendered")
  }
  0
}
"#,
    );
    let out = quack(&dir, &["add", "template"]);
    assert!(out.status.success(), "quack add template: {}", String::from_utf8_lossy(&out.stderr));
    let o = Command::new(env!("CARGO_BIN_EXE_duck")).args(["run", "src/main.duck"]).current_dir(&dir).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    assert_eq!(
        String::from_utf8_lossy(&o.stdout),
        "<b>a&amp;b</b>=1;<b>c</b>=2;\n1:1: `missing` is undefined (use `| default(...)` if it may be missing)\n"
    );
}

#[test]
fn markdown_renders_safely_from_an_app() {
    let dir = app(
        "markdown",
        "",
        "fn main() {\n  print(markdown.html(\"# Hi\\n\\n*a* <script>x</script> [b](javascript:x)\"))\n  print(markdown.text(\"**t** &amp; u\"))\n}\n",
    );
    let out = quack(&dir, &["add", "markdown"]);
    assert!(out.status.success(), "quack add markdown: {}", String::from_utf8_lossy(&out.stderr));
    let o = Command::new(env!("CARGO_BIN_EXE_duck")).args(["run", "src/main.duck"]).current_dir(&dir).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    assert_eq!(
        String::from_utf8_lossy(&o.stdout),
        "<h1>Hi</h1>\n<p><em>a</em> &lt;script&gt;x&lt;/script&gt; <a href=\"\">b</a></p>\n\nt & u\n"
    );
}
