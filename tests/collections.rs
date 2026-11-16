//! The core collection extras written in Duck (src/prelude/core.duck): `chunks`, `windows`,
//! `flat_map`, `group_by` and `unique`, tested by tests/fixtures/collections.duck under the
//! leak checker, plus the `requires n > 0` panics.

use std::path::PathBuf;
use std::process::{Command, Output};
use std::{env, fs};

fn duck_cmd() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_duck"));
    c.env_remove("DUCK_CFLAGS").env("DUCK_LEAK_CHECK", "1");
    c
}

fn text(o: &Output) -> (String, String) {
    (String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned())
}

#[test]
fn collection_extras_pass_their_tests() {
    let o = duck_cmd().args(["test", "tests/fixtures/collections.duck"]).output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{out}\n{err}");
    assert_eq!(out, "ok chunks\nok windows\nok flat_map\nok group_by\nok unique\n5 passed, 0 failed\n", "{err}");
}

#[test]
fn chunks_and_windows_need_a_positive_size() {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("collections");
    fs::create_dir_all(&d).unwrap();
    for f in ["chunks", "windows"] {
        let p = d.join(format!("{f}.duck"));
        fs::write(&p, format!("fn main() {{\n  print([1, 2].{f}(0))\n}}\n")).unwrap();
        let o = duck_cmd().arg("run").arg(&p).output().unwrap();
        let (_, err) = text(&o);
        assert_eq!(o.status.code(), Some(101), "{err}");
        assert!(err.starts_with("panic: requires failed: n > 0\n"), "{err}");
    }
}
