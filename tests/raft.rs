use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

/// A fresh scratch directory, removed on drop.
struct Tmp(PathBuf);

impl Tmp {
    fn new() -> Tmp {
        static N: AtomicUsize = AtomicUsize::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("raft-test-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Tmp(dir)
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Run raft in `dir` against the fixture registry: (success, stdout, stderr).
fn raft(dir: &Path, args: &[&str]) -> (bool, String, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_raft"))
        .args(args)
        .current_dir(dir)
        .env("RAFT_REGISTRY", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/registry"))
        .output()
        .unwrap();
    let s = |b: Vec<u8>| String::from_utf8(b).unwrap();
    (out.status.success(), s(out.stdout), s(out.stderr))
}

/// Run raft and require success; returns stdout.
fn ok(dir: &Path, args: &[&str]) -> String {
    let (success, out, err) = raft(dir, args);
    assert!(success, "raft {args:?} failed:\n{err}");
    out
}

/// Run raft and require failure; returns stderr.
fn fails(dir: &Path, args: &[&str]) -> String {
    let (success, out, err) = raft(dir, args);
    assert!(!success, "raft {args:?} should have failed:\n{out}");
    err
}

/// A new app project `app` inside a scratch directory; returns (scratch, project dir).
fn app() -> (Tmp, PathBuf) {
    let tmp = Tmp::new();
    ok(&tmp.0, &["new", "app"]);
    let dir = tmp.0.join("app");
    (tmp, dir)
}

fn read(path: impl AsRef<Path>) -> String {
    fs::read_to_string(path).unwrap()
}

/// Allow the given effects in the project's `[package]` table.
fn allow(dir: &Path, effects: &str) {
    let toml = read(dir.join("raft.toml")).replace("effects = []", &format!("effects = {effects}"));
    fs::write(dir.join("raft.toml"), toml).unwrap();
}

#[test]
fn new_app_and_lib() {
    let tmp = Tmp::new();
    assert_eq!(ok(&tmp.0, &["new", "app"]), "created app/ (app)\n");
    assert_eq!(
        read(tmp.0.join("app/raft.toml")),
        "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = []\n\n[deps]\n"
    );
    assert!(read(tmp.0.join("app/src/main.auk")).contains("fn main()"));
    assert_eq!(ok(&tmp.0, &["new", "geo", "--lib"]), "created geo/ (library)\n");
    assert!(read(tmp.0.join("geo/src/lib.auk")).contains("pub fn"));
    assert!(!tmp.0.join("geo/src/main.auk").exists());

    // Never overwrite an existing directory.
    fs::write(tmp.0.join("app/src/main.auk"), "mine").unwrap();
    let err = fails(&tmp.0, &["new", "app"]);
    assert_eq!(err, "error: `app` already exists\n  help: choose another name or remove it first\n");
    assert_eq!(read(tmp.0.join("app/src/main.auk")), "mine");

    assert!(fails(&tmp.0, &["new", "Bad-Name"]).starts_with("error: invalid package name `Bad-Name`\n"));
    assert!(
        fails(&tmp.0, &["new", "net"]).starts_with("error: package name `net` collides with the core module `net`\n")
    );
}

#[test]
fn add_transitive_and_lock() {
    let (_tmp, dir) = app();
    // A comment that `add` must keep.
    let toml = read(dir.join("raft.toml")).replace("[deps]\n", "[deps]  # registry deps\n");
    fs::write(dir.join("raft.toml"), &toml).unwrap();

    assert_eq!(ok(&dir, &["add", "a"]), "  + a 1.2.0\n  + b 1.0.3   (via a)\n");
    assert_eq!(read(dir.join("raft.toml")), format!("{toml}a = \"^1.2\"\n"));

    let lock = read(dir.join("raft.lock"));
    let names: Vec<_> = lock.lines().filter(|l| l.starts_with("name = ")).collect();
    assert_eq!(names, ["name = \"a\"", "name = \"b\""]);
    assert!(lock.contains(
        "[[package]]\nname = \"b\"\nversion = \"1.0.3\"\nsource = \"registry\"\neffects = []\nchecksum = \"sha256:"
    ));

    // Installed: raft.toml, README.md and src/**.
    assert!(dir.join(".raft/a/README.md").is_file());
    assert!(dir.join(".raft/a/src/lib.auk").is_file());
    assert!(dir.join(".raft/b/src/util/more.auk").is_file());

    // Adding an existing dependency again is a no-op.
    assert_eq!(ok(&dir, &["add", "a"]), "");
    assert_eq!(read(dir.join("raft.lock")), lock);
}

#[test]
fn remove_dep() {
    let (_tmp, dir) = app();
    let before = read(dir.join("raft.toml"));
    ok(&dir, &["add", "a"]);
    assert_eq!(ok(&dir, &["remove", "a"]), "  - a 1.2.0\n  - b 1.0.3\n");
    assert_eq!(read(dir.join("raft.toml")), before);
    assert!(!dir.join(".raft/a").exists() && !dir.join(".raft/b").exists());
    assert!(!read(dir.join("raft.lock")).contains("[[package]]"));

    let err = fails(&dir, &["remove", "a"]);
    assert_eq!(
        err,
        "error: `a` is not a dependency of app\n  help: dependencies are listed under [deps] in raft.toml\n"
    );
}

#[test]
fn install_existing_manifest_and_list() {
    let (_tmp, dir) = app();
    allow(&dir, "[\"net\"]");
    let toml = read(dir.join("raft.toml")) + "a = \"^1.0\"\nfetch = \"~0.3.0\"\n";
    fs::write(dir.join("raft.toml"), toml).unwrap();
    // A stale package left over in .raft/ is removed.
    fs::create_dir_all(dir.join(".raft/stale/src")).unwrap();

    assert_eq!(ok(&dir, &["install"]), "  + a 1.2.0\n  + fetch 0.3.1   uses net\n  + b 1.0.3       (via a)\n");
    assert!(!dir.join(".raft/stale").exists());
    assert_eq!(ok(&dir, &["install"]), "");

    let tree = "\
app 0.1.0   uses net
├── a 1.2.0
│   └── b 1.0.3
└── fetch 0.3.1   uses net
    └── b 1.0.3
";
    assert_eq!(ok(&dir, &["list"]), tree);
    // Works from a subdirectory too.
    assert_eq!(ok(&dir.join("src"), &["list"]), tree);

    fs::remove_dir_all(dir.join(".raft")).unwrap();
    assert_eq!(fails(&dir, &["list"]), "error: a is not installed\n  help: run `raft install`\n");
}

#[test]
fn path_dependency() {
    let (tmp, dir) = app();
    ok(&tmp.0, &["new", "geo", "--lib"]);
    // geo itself depends on the registry package b.
    let geo = read(tmp.0.join("geo/raft.toml")) + "b = \"^1.0\"\n";
    fs::write(tmp.0.join("geo/raft.toml"), geo).unwrap();

    assert_eq!(ok(&dir, &["add", "geo", "--path", "../geo"]), "  + geo 0.1.0\n  + b 1.0.3   (via geo)\n");
    assert!(read(dir.join("raft.toml")).ends_with("[deps]\ngeo = { path = \"../geo\" }\n"));
    assert!(read(dir.join("raft.lock")).contains("name = \"geo\"\nversion = \"0.1.0\"\nsource = \"path:../geo\""));
    assert!(dir.join(".raft/geo/src/lib.auk").is_file());

    // Local edits to a path package are picked up by the next install.
    fs::write(tmp.0.join("geo/src/lib.auk"), "pub fn x(): int { 1 }\n").unwrap();
    ok(&dir, &["install"]);
    assert_eq!(read(dir.join(".raft/geo/src/lib.auk")), "pub fn x(): int { 1 }\n");

    let err = fails(&dir, &["add", "geo2", "--path", "../geo"]);
    assert!(err.starts_with("error: ") && err.contains("names itself `geo`, not `geo2` (app -> geo2)"), "{err}");
    let err = fails(&dir, &["add", "nowhere", "--path", "../nowhere"]);
    assert_eq!(err, "error: no raft.toml in ../nowhere (app -> nowhere)\n");
}

#[test]
fn effects_violation() {
    let (_tmp, dir) = app();
    allow(&dir, "[\"fs\"]");
    let before = read(dir.join("raft.toml"));
    let err = fails(&dir, &["add", "fetch"]);
    assert_eq!(
        err,
        "error: fetch 0.3.1 needs effect `net`, but app's raft.toml only allows [\"fs\"]\n  help: add \"net\" to [package] effects in raft.toml\n"
    );
    // Nothing changed.
    assert_eq!(read(dir.join("raft.toml")), before);
    assert!(!dir.join(".raft").exists() && !dir.join("raft.lock").exists());

    // Transitive: bad declares no effects but depends on fetch.
    let toml = read(dir.join("raft.toml")).replace("[\"fs\"]", "[\"net\"]");
    fs::write(dir.join("raft.toml"), toml).unwrap();
    let err = fails(&dir, &["add", "bad"]);
    assert_eq!(
        err,
        "error: fetch 0.3.1 (app -> bad -> fetch) needs effect `net`, but bad's raft.toml only allows []\n  help: bad must list \"net\" in its effects to depend on fetch\n"
    );
}

#[test]
fn checksum_mismatch() {
    let (_tmp, dir) = app();
    ok(&dir, &["add", "a"]);
    fs::write(dir.join(".raft/b/src/lib.auk"), "pub fn evil() {}\n").unwrap();
    let err = fails(&dir, &["install"]);
    assert!(err.starts_with("error: checksum mismatch for b 1.0.3 in .raft/b: expected sha256:"), "{err}");
    assert!(err.ends_with(
        "\n  help: the installed files were modified; delete .raft/b and run `raft install` to restore them\n"
    ));

    fs::remove_dir_all(dir.join(".raft/b")).unwrap();
    assert_eq!(ok(&dir, &["install"]), "");
    assert_ne!(read(dir.join(".raft/b/src/lib.auk")), "pub fn evil() {}\n");

    // A lock entry that disagrees with the registry copy is also fatal.
    let lock = read(dir.join("raft.lock"));
    let at = lock.find("name = \"b\"").unwrap();
    let sum = at + lock[at..].find("sha256:").unwrap() + 7;
    let tampered = format!("{}{}", &lock[..sum], "0".repeat(64)) + &lock[sum + 64..];
    fs::write(dir.join("raft.lock"), tampered).unwrap();
    let err = fails(&dir, &["install"]);
    assert!(err.starts_with("error: checksum mismatch for b 1.0.3 in the registry"), "{err}");
}

#[test]
fn unknown_package() {
    let (_tmp, dir) = app();
    let registry = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/registry");
    let err = fails(&dir, &["add", "nope"]);
    assert_eq!(
        err,
        format!(
            "error: package `nope` not found in the registry (app -> nope)\n  help: the registry is {registry}; set RAFT_REGISTRY to use another\n"
        )
    );
    assert!(!read(dir.join("raft.toml")).contains("nope"));
    // Transitive: lost depends on ghost, which doesn't exist.
    let err = fails(&dir, &["add", "lost"]);
    assert!(err.starts_with("error: package `ghost` not found in the registry (app -> lost -> ghost)\n"), "{err}");
}

#[test]
fn version_mismatch() {
    let (_tmp, dir) = app();
    let toml = read(dir.join("raft.toml")) + "c = \"^1.0\"\n";
    fs::write(dir.join("raft.toml"), toml).unwrap();
    let err = fails(&dir, &["install"]);
    assert_eq!(
        err,
        "error: c ^1.0 does not match the registry version 2.0.0 (app -> c)\n  help: use c = \"^2.0\" in raft.toml\n"
    );

    // `raft add` rewrites the requirement to the registry's version.
    assert_eq!(ok(&dir, &["add", "c"]), "  + c 2.0.0\n");
    assert!(read(dir.join("raft.toml")).ends_with("[deps]\nc = \"^2.0\"\n"));

    // Transitive: old wants c ^1.0.
    let err = fails(&dir, &["add", "old"]);
    assert_eq!(
        err,
        "error: c ^1.0 does not match the registry version 2.0.0 (app -> old -> c)\n  help: old needs c ^1.0, but the registry only has 2.0.0\n"
    );
}

#[test]
fn outside_a_project() {
    let tmp = Tmp::new();
    let err = fails(&tmp.0, &["install"]);
    assert_eq!(
        err,
        "error: no raft.toml in this directory or any parent\n  help: create a project with `raft new <name>`\n"
    );
}
