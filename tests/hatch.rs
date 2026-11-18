//! `auk hatch` against a fake model: `AUK_HATCH_CMD` is a shell script that logs each prompt
//! (`prompt.0`, `prompt.1`, ...) and answers with canned code chosen by grepping the prompt.
//! No real model is called.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const MEDIAN: &str = "let s = xs.sort()\nlet n = s.len()\nif n % 2 == 1 { s[n / 2] } else { (s[n / 2 - 1] + s[n / 2]) / 2.0 }";

const DEDUP: &str = "var out: [int] = []\nfor x in xs {\n  if !out.contains(x) { out.push(x) }\n}\nout";

const SECONDS: &str = "\
if s.len() == 0 { fail(Empty) }
var total = 0
var n = 0
var have = false
for c in s.chars() {
  if c.is_digit() {
    n = n * 10 + (int(c) - int('0'))
    have = true
  } else {
    if !have { fail(NoNumber) }
    let mult = match c {
      'h' => 3_600
      'm' => 60
      's' => 1
      _ => fail(BadUnit(c))
    }
    total += n * mult
    n = 0
    have = false
  }
}
if have { fail(NoNumber) }
total";

/// A temp dir with a copy of examples/hatch.auk (plus `extra` appended).
fn setup(name: &str, extra: &str) -> (PathBuf, PathBuf) {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("hatch").join(name);
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    let src = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/hatch.auk")).unwrap();
    let f = d.join("hatch.auk");
    fs::write(&f, src + extra).unwrap();
    (d, f)
}

/// Write the fake model: `rules` are (shell condition on "$p", answer) pairs tried in order; the
/// answer is printed inside a ```auk fence. No rule matching = exit 1.
fn fake(dir: &Path, rules: &[(&str, &str)]) -> String {
    let mut s = String::from("#!/bin/sh\np=$(cat)\nn=$(ls \"$D\" | grep -c '^prompt\\.')\nprintf '%s' \"$p\" > \"$D/prompt.$n\"\nhas() { printf '%s' \"$p\" | grep -qF -- \"$1\"; }\n");
    for (i, (cond, answer)) in rules.iter().enumerate() {
        s += &format!("{} {cond}; then\ncat <<'ANSWER'\nHere you go:\n```auk\n{answer}\n```\nANSWER\nexit 0\n", if i == 0 { "if" } else { "elif" });
    }
    s += "fi\necho 'no canned answer' >&2\nexit 1\n";
    let script = dir.join("model.sh");
    fs::write(&script, s).unwrap();
    format!("D='{}' sh '{}'", dir.display(), script.display())
}

fn hatch(dir: &Path, cmd: &str, args: &[&str]) -> (Output, String) {
    let o = Command::new(env!("CARGO_BIN_EXE_auk"))
        .arg("hatch")
        .args(args)
        .current_dir(dir)
        .env("AUK_HATCH_CMD", cmd)
        .env_remove("AUK_LEAK_CHECK")
        .output()
        .unwrap();
    let text = format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
    (o, text)
}

fn prompts(dir: &Path) -> Vec<String> {
    (0..).map(|i| dir.join(format!("prompt.{i}"))).take_while(|p| p.exists()).map(|p| fs::read_to_string(p).unwrap()).collect()
}

fn auk(dir: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_auk")).args(args).current_dir(dir).env_remove("AUK_LEAK_CHECK").output().unwrap()
}

#[test]
fn median_on_the_first_try() {
    let (d, f) = setup("first", "");
    let cmd = fake(&d, &[("has 'in fn median'", MEDIAN)]);
    let (o, out) = hatch(&d, &cmd, &["hatch.auk", "--hole", "1"]);
    assert!(o.status.success(), "{out}");
    assert!(out.contains("hole 1 (fn median, hatch.auk:6): filled after 1 try"), "{out}");
    let src = fs::read_to_string(&f).unwrap();
    assert!(src.contains("  requires xs.len() > 0\n{\n  let s = xs.sort()\n"), "{src}");
    assert_eq!(src.matches("??").count(), 3, "the other holes stay (and the header comment's `??`):\n{src}");
    // the prompt: spec, the file, the brief and the instructions
    let ps = prompts(&d);
    assert_eq!(ps.len(), 1);
    let p = &ps[0];
    for want in [
        "# The Auk language reference",
        "## Contracts, holes, tests, debugging",
        "fn dedup(xs: [int]): [int]",
        "hole 1 at hatch.auk:6:3 in fn median",
        "expected type: float",
        "requires xs.len() > 0",
        "    xs: [float]",
        "assert median([4.0, 1.0, 3.0, 2.0]) == 2.5",
        "Reply with ONLY the code",
    ] {
        assert!(p.contains(want), "the prompt lacks {want:?}:\n{p}");
    }
    let t = auk(&d, &["test", "hatch.auk", "median"]);
    assert!(t.status.success(), "{}", String::from_utf8_lossy(&t.stdout));
}

#[test]
fn type_errors_are_sent_back() {
    let (d, f) = setup("type_error", "");
    // the corrected answer is only given when the prompt carries the checker's error code
    let cmd = fake(&d, &[("has '\"code\":\"E0200\"'", MEDIAN), ("has 'in fn median'", "xs.len()")]);
    let (o, out) = hatch(&d, &cmd, &["hatch.auk", "--hole", "1"]);
    assert!(o.status.success(), "{out}");
    assert!(out.contains("filled after 2 tries"), "{out}");
    let ps = prompts(&d);
    assert_eq!(ps.len(), 2);
    assert!(!ps[0].contains("Your previous answer"));
    assert!(ps[1].contains("## Your previous answer\n```auk\nxs.len()\n```\nIt did not type-check"), "{}", ps[1]);
    assert!(ps[1].contains("expected `float`, found `int`"), "{}", ps[1]);
    assert!(fs::read_to_string(&f).unwrap().contains("let s = xs.sort()"));
}

#[test]
fn test_failures_are_sent_back() {
    let (d, f) = setup("test_failure", "");
    // `xs[0]` type-checks but fails the median test
    let cmd = fake(&d, &[("has 'FAIL median'", MEDIAN), ("has 'in fn median'", "xs[0]")]);
    let (o, out) = hatch(&d, &cmd, &["hatch.auk", "--hole", "1"]);
    assert!(o.status.success(), "{out}");
    assert!(out.contains("filled after 2 tries"), "{out}");
    let ps = prompts(&d);
    assert_eq!(ps.len(), 2);
    assert!(ps[1].contains("type-checks, but these tests failed"), "{}", ps[1]);
    assert!(ps[1].contains("assertion failed: median([3.0, 1.0, 2.0]) == 2.0"), "{}", ps[1]);
    // the failing test's execution trace: what the candidate actually returned
    assert!(ps[1].contains("execution trace"), "{}", ps[1]);
    assert!(ps[1].contains(r#"{"ev":"call","fn":"hatch.median","loc":"hatch.auk:23:10","args":["[3.0, 1.0, 2.0]"],"depth":0}"#), "{}", ps[1]);
    assert!(ps[1].contains(r#"{"ev":"ret","fn":"hatch.median","value":"3.0","depth":0}"#), "{}", ps[1]);
    assert!(ps[1].contains(r#"{"ev":"panic","msg":"assertion failed: median([3.0, 1.0, 2.0]) == 2.0"#), "{}", ps[1]);
    assert!(!ps[0].contains(r#"{"ev":"#), "the first prompt has no trace");
    assert!(fs::read_to_string(&f).unwrap().contains("let s = xs.sort()"));
}

#[test]
fn contracts_are_checked() {
    let (d, _) = setup("contract", "");
    // returns the list twice: violates `ensures result.len() <= xs.len()` (the tests also fail)
    let cmd = fake(&d, &[("has 'ensures failed'", DEDUP), ("has 'in fn dedup'", "xs + xs")]);
    let (o, out) = hatch(&d, &cmd, &["hatch.auk", "--hole", "2"]);
    assert!(o.status.success(), "{out}");
    assert!(out.contains("hole 2 (fn dedup, hatch.auk:11): filled after 2 tries"), "{out}");
    assert!(prompts(&d)[1].contains("ensures failed: result.len() <= xs.len()"));
}

#[test]
fn gives_up_after_tries() {
    let (d, f) = setup("give_up", "");
    let before = fs::read_to_string(&f).unwrap();
    let cmd = fake(&d, &[("has 'in fn median'", "xs[0]")]);
    let (o, out) = hatch(&d, &cmd, &["hatch.auk", "--hole", "1", "--tries", "2"]);
    assert_eq!(o.status.code(), Some(1), "{out}");
    assert!(out.contains("hole 1 (fn median, hatch.auk:6): failed after 2 tries\n  last error:\n    FAIL median"), "{out}");
    assert_eq!(prompts(&d).len(), 2);
    assert_eq!(fs::read_to_string(&f).unwrap(), before, "a failed hatch leaves the file alone");
}

#[test]
fn a_failing_model_command() {
    let (d, f) = setup("bad_cmd", "");
    let before = fs::read_to_string(&f).unwrap();
    let (o, out) = hatch(&d, "echo broken >&2; exit 3", &["hatch.auk", "--hole", "1", "--tries", "1"]);
    assert_eq!(o.status.code(), Some(1), "{out}");
    assert!(out.contains("failed after 1 try") && out.contains("broken"), "{out}");
    assert_eq!(fs::read_to_string(&f).unwrap(), before);
}

#[test]
fn dry_run_prints_a_diff() {
    let (d, f) = setup("dry", "");
    let before = fs::read_to_string(&f).unwrap();
    let cmd = fake(&d, &[("has 'in fn median'", MEDIAN)]);
    let (o, out) = hatch(&d, &cmd, &["hatch.auk", "--hole", "1", "--dry-run"]);
    assert!(o.status.success(), "{out}");
    assert_eq!(fs::read_to_string(&f).unwrap(), before);
    assert!(out.contains("--- a/hatch.auk\n+++ b/hatch.auk\n@@ -3,"), "{out}");
    assert!(out.contains("   requires xs.len() > 0\n-{ ?? }\n+{\n+  let s = xs.sort()\n"), "{out}");
    assert!(out.contains("(dry run: no files were changed)"), "{out}");
}

#[test]
fn full_hatch_then_test_and_build() {
    let (d, f) = setup("full", "\nfn main() {\n  print(median([2.0, 1.0]))\n}\n");
    let cmd = fake(&d, &[("has 'in fn median'", MEDIAN), ("has 'in fn dedup'", DEDUP), ("has 'in fn seconds'", SECONDS)]);
    let (o, out) = hatch(&d, &cmd, &["hatch.auk"]);
    assert!(o.status.success(), "{out}");
    for n in ["hole 1 (fn median", "hole 2 (fn dedup", "hole 3 (fn seconds"] {
        assert!(out.contains(n), "{out}");
    }
    assert_eq!(out.matches("filled after 1 try").count(), 3, "{out}");
    assert_eq!(prompts(&d).len(), 3);
    let src = fs::read_to_string(&f).unwrap();
    assert!(!src.lines().skip(1).any(|l| l.contains("??")), "{src}");
    // formatted, tests pass, and a release build accepts it
    assert!(auk(&d, &["fmt", "--check", "hatch.auk"]).status.success());
    let t = auk(&d, &["test", "hatch.auk"]);
    let tout = String::from_utf8_lossy(&t.stdout);
    assert!(t.status.success() && tout.contains("3 passed, 0 failed"), "{tout}");
    let b = auk(&d, &["build", "hatch.auk", "-o", "hatched"]);
    assert!(b.status.success(), "{}", String::from_utf8_lossy(&b.stderr));
    let r = Command::new(d.join("hatched")).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&r.stdout), "1.5\n");
    let h = auk(&d, &["holes", "hatch.auk"]);
    assert!(String::from_utf8_lossy(&h.stdout).starts_with("no holes"));
}

#[test]
fn a_failed_hole_is_skipped() {
    let (d, f) = setup("skip", "");
    // median can't be filled; dedup still is, and keeps its own number
    let cmd = fake(&d, &[("has 'in fn median'", "xs[0]"), ("has 'in fn dedup'", DEDUP), ("has 'in fn seconds'", SECONDS)]);
    let (o, out) = hatch(&d, &cmd, &["hatch.auk", "--tries", "1"]);
    assert_eq!(o.status.code(), Some(1), "{out}");
    assert!(out.contains("hole 1 (fn median, hatch.auk:6): failed after 1 try"), "{out}");
    assert!(out.contains("hole 2 (fn dedup") && out.contains("hole 3 (fn seconds"), "{out}");
    assert_eq!(out.matches("filled after 1 try").count(), 2, "{out}");
    let src = fs::read_to_string(&f).unwrap();
    assert!(src.contains("  requires xs.len() > 0\n{ ?? }") && src.contains("var out: [int] = []"), "{src}");
}

#[test]
fn usage_errors() {
    let (d, _) = setup("usage", "");
    let (o, out) = hatch(&d, "true", &["hatch.auk", "--hole", "9"]);
    assert_eq!(o.status.code(), Some(2));
    assert!(out.contains("there is no hole 9"), "{out}");
    let (o, _) = hatch(&d, "true", &[]);
    assert_eq!(o.status.code(), Some(2));
    let help = String::from_utf8_lossy(&auk(&d, &["help"]).stdout).into_owned();
    assert!(help.contains("hatch <file> [--hole N] [--tries 3] [--dry-run]") && help.contains("AUK_HATCH_CMD"), "{help}");
    assert!(help.contains("holes <file> [--json]"), "{help}");
}
