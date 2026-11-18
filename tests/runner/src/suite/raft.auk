/// tests/raft.rs: the package manager end to end against the fixture registry
/// (tests/fixtures/registry): `new`, `add` (transitive, path dependencies), `remove`,
/// `install`, `list`, the lock file, effects, checksums and errors. The raft under test is
/// `$RAFT_BIN`, else target/bin/raft.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("new_app_and_lib", new_app_and_lib),
  t.test("add_transitive_and_lock", add_transitive_and_lock),
  t.test("remove_dep", remove_dep),
  t.test("install_existing_manifest_and_list", install_existing_manifest_and_list),
  t.test("path_dependency", path_dependency),
  t.test("effects_violation", effects_violation),
  t.test("checksum_mismatch", checksum_mismatch),
  t.test("unknown_package", unknown_package),
  t.test("version_mismatch", version_mismatch),
  t.test("outside_a_project", outside_a_project),
]

/// A fresh scratch directory (Rust's `Tmp`; removed at the end of the test).
fn tmp(name: str): str uses fs, ffi = t.temp("raft-test-{name}")

fn registry(): str uses ffi = t.abs("tests/fixtures/registry")

/// Run raft in `dir` against the fixture registry: (success, stdout, stderr).
fn raft(dir: str, args: [str]): (bool, str, str) uses env, ffi, time {
  let o = t.raft().args(args).cwd(dir).setenv("RAFT_REGISTRY", registry()).output()
  (o.success(), o.stdout, o.stderr)
}

/// Run raft and require failure; returns stderr.
fn fails(dir: str, args: [str]): str uses env, ffi, time {
  let (success, out, err) = raft(dir, args)
  t.check(!success, "raft {args} should have failed:\n{out}")
  err
}

/// A new app project `app` inside a scratch directory; returns (scratch, project dir).
fn app(name: str): (str, str) uses env, fs, ffi, time {
  let d = tmp(name)
  let _ = ok(d, ["new", "app"])
  (d, paths.join(d, "app"))
}

/// Run raft and require success; returns stdout.
fn ok(dir: str, args: [str]): str uses env, ffi, time {
  let (success, out, err) = raft(dir, args)
  t.check(success, "raft {args} failed:\n{err}")
  out
}

fn read(p: str): str uses fs = t.read(p)

/// Allow the given effects in the project's `[package]` table.
fn allow(dir: str, effects: str) uses fs {
  let toml = read(paths.join(dir, "raft.toml")).replace("effects = []", "effects = {effects}")
  t.write(paths.join(dir, "raft.toml"), toml)
}

fn new_app_and_lib() uses env, fs, ffi, time {
  let d = tmp("new_app_and_lib")
  assert ok(d, ["new", "app"]) == "created app/ (app)\n"
  assert read(paths.join(d, "app/raft.toml")) ==
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = []\n\n[deps]\n"
  assert read(paths.join(d, "app/src/main.auk")).contains("fn main()")
  assert ok(d, ["new", "geo", "--lib"]) == "created geo/ (library)\n"
  assert read(paths.join(d, "geo/src/lib.auk")).contains("pub fn")
  assert !fs.exists(paths.join(d, "geo/src/main.auk"))

  // Never overwrite an existing directory.
  t.write(paths.join(d, "app/src/main.auk"), "mine")
  let err = fails(d, ["new", "app"])
  assert err == "error: `app` already exists\n  help: choose another name or remove it first\n"
  assert read(paths.join(d, "app/src/main.auk")) == "mine"

  assert fails(d, ["new", "Bad-Name"]).starts_with("error: invalid package name `Bad-Name`\n")
  assert fails(d, [
    "new",
    "net",
  ]).starts_with("error: package name `net` collides with the core module `net`\n")
  t.rm_rf(d)
}

fn add_transitive_and_lock() uses env, fs, ffi, time {
  let (d, dir) = app("add_transitive_and_lock")
  // A comment that `add` must keep.
  let toml = read(paths.join(dir, "raft.toml")).replace("[deps]\n", "[deps]  # registry deps\n")
  t.write(paths.join(dir, "raft.toml"), toml)

  assert ok(dir, ["add", "a"]) == "  + a 1.2.0\n  + b 1.0.3   (via a)\n"
  assert read(paths.join(dir, "raft.toml")) == "{toml}a = \"^1.2\"\n"

  let lock = read(paths.join(dir, "raft.lock"))
  let names = lock.lines().filter(l => l.starts_with("name = "))
  assert names == ["name = \"a\"", "name = \"b\""]
  assert lock.contains("[[package]]\nname = \"b\"\nversion = \"1.0.3\"\nsource = \"registry\"\neffects = []\nchecksum = \"sha256:")

  // Installed: raft.toml, README.md and src/**.
  assert paths.is_file(paths.join(dir, ".raft/a/README.md"))
  assert paths.is_file(paths.join(dir, ".raft/a/src/lib.auk"))
  assert paths.is_file(paths.join(dir, ".raft/b/src/util/more.auk"))

  // Adding an existing dependency again is a no-op.
  assert ok(dir, ["add", "a"]) == ""
  assert read(paths.join(dir, "raft.lock")) == lock
  t.rm_rf(d)
}

fn remove_dep() uses env, fs, ffi, time {
  let (d, dir) = app("remove_dep")
  let before = read(paths.join(dir, "raft.toml"))
  let _ = ok(dir, ["add", "a"])
  assert ok(dir, ["remove", "a"]) == "  - a 1.2.0\n  - b 1.0.3\n"
  assert read(paths.join(dir, "raft.toml")) == before
  assert !fs.exists(paths.join(dir, ".raft/a")) && !fs.exists(paths.join(dir, ".raft/b"))
  assert !read(paths.join(dir, "raft.lock")).contains("[[package]]")

  let err = fails(dir, ["remove", "a"])
  assert err ==
    "error: `a` is not a dependency of app\n  help: dependencies are listed under [deps] in raft.toml\n"
  t.rm_rf(d)
}

fn install_existing_manifest_and_list() uses env, fs, ffi, time {
  let (d, dir) = app("install_existing_manifest_and_list")
  allow(dir, "[\"net\"]")
  let toml = read(paths.join(dir, "raft.toml")) + "a = \"^1.0\"\nfetch = \"~0.3.0\"\n"
  t.write(paths.join(dir, "raft.toml"), toml)
  // A stale package left over in .raft/ is removed.
  t.must(fs.mkdir(paths.join(dir, ".raft/stale/src")), "mkdir")

  assert ok(dir, ["install"]) ==
    "  + a 1.2.0\n  + fetch 0.3.1   uses net\n  + b 1.0.3       (via a)\n"
  assert !fs.exists(paths.join(dir, ".raft/stale"))
  assert ok(dir, ["install"]) == ""

  let tree = "app 0.1.0   uses net\n├── a 1.2.0\n│   └── b 1.0.3\n└── fetch 0.3.1   uses net\n    └── b 1.0.3\n"
  assert ok(dir, ["list"]) == tree
  // Works from a subdirectory too.
  assert ok(paths.join(dir, "src"), ["list"]) == tree

  t.rm_rf(paths.join(dir, ".raft"))
  assert fails(dir, ["list"]) == "error: a is not installed\n  help: run `raft install`\n"
  t.rm_rf(d)
}

fn path_dependency() uses env, fs, ffi, time {
  let (d, dir) = app("path_dependency")
  let _ = ok(d, ["new", "geo", "--lib"])
  // geo itself depends on the registry package b.
  let geo = read(paths.join(d, "geo/raft.toml")) + "b = \"^1.0\"\n"
  t.write(paths.join(d, "geo/raft.toml"), geo)

  assert ok(dir, ["add", "geo", "--path", "../geo"]) == "  + geo 0.1.0\n  + b 1.0.3   (via geo)\n"
  assert read(paths.join(dir, "raft.toml")).ends_with("[deps]\ngeo = {{ path = \"../geo\" }}\n")
  assert read(
    paths.join(dir, "raft.lock"),
  ).contains("name = \"geo\"\nversion = \"0.1.0\"\nsource = \"path:../geo\"")
  assert paths.is_file(paths.join(dir, ".raft/geo/src/lib.auk"))

  // Local edits to a path package are picked up by the next install.
  t.write(paths.join(d, "geo/src/lib.auk"), "pub fn x(): int {{ 1 }}\n")
  let _ = ok(dir, ["install"])
  assert read(paths.join(dir, ".raft/geo/src/lib.auk")) == "pub fn x(): int {{ 1 }}\n"

  let err = fails(dir, ["add", "geo2", "--path", "../geo"])
  t.check(
    err.starts_with("error: ") && err.contains("names itself `geo`, not `geo2` (app -> geo2)"),
    err,
  )
  let err = fails(dir, ["add", "nowhere", "--path", "../nowhere"])
  assert err == "error: no raft.toml in ../nowhere (app -> nowhere)\n"
  t.rm_rf(d)
}

fn effects_violation() uses env, fs, ffi, time {
  let (d, dir) = app("effects_violation")
  allow(dir, "[\"fs\"]")
  let before = read(paths.join(dir, "raft.toml"))
  let err = fails(dir, ["add", "fetch"])
  assert err ==
    "error: fetch 0.3.1 needs effect `net`, but app's raft.toml only allows [\"fs\"]\n  help: add \"net\" to [package] effects in raft.toml\n"
  // Nothing changed.
  assert read(paths.join(dir, "raft.toml")) == before
  assert !fs.exists(paths.join(dir, ".raft")) && !fs.exists(paths.join(dir, "raft.lock"))

  // Transitive: bad declares no effects but depends on fetch.
  let toml = read(paths.join(dir, "raft.toml")).replace("[\"fs\"]", "[\"net\"]")
  t.write(paths.join(dir, "raft.toml"), toml)
  let err = fails(dir, ["add", "bad"])
  assert err ==
    "error: fetch 0.3.1 (app -> bad -> fetch) needs effect `net`, but bad's raft.toml only allows []\n  help: bad must list \"net\" in its effects to depend on fetch\n"
  t.rm_rf(d)
}

fn checksum_mismatch() uses env, fs, ffi, time {
  let (d, dir) = app("checksum_mismatch")
  let _ = ok(dir, ["add", "a"])
  t.write(paths.join(dir, ".raft/b/src/lib.auk"), "pub fn evil() {{}}\n")
  let err = fails(dir, ["install"])
  t.check(err.starts_with("error: checksum mismatch for b 1.0.3 in .raft/b: expected sha256:"), err)
  assert err.ends_with("\n  help: the installed files were modified; delete .raft/b and run `raft install` to restore them\n")

  t.rm_rf(paths.join(dir, ".raft/b"))
  assert ok(dir, ["install"]) == ""
  assert read(paths.join(dir, ".raft/b/src/lib.auk")) != "pub fn evil() {{}}\n"

  // A lock entry that disagrees with the registry copy is also fatal (the lock is ASCII, so
  // char indices are byte offsets).
  let lock = read(paths.join(dir, "raft.lock"))
  let at = lock.find("name = \"b\"")!
  let sum = at + lock[at..lock.len()].find("sha256:")! + 7
  let tampered = lock[0..sum] + "0".repeat(64) + lock[sum + 64..lock.len()]
  t.write(paths.join(dir, "raft.lock"), tampered)
  let err = fails(dir, ["install"])
  t.check(err.starts_with("error: checksum mismatch for b 1.0.3 in the registry"), err)
  t.rm_rf(d)
}

fn unknown_package() uses env, fs, ffi, time {
  let (d, dir) = app("unknown_package")
  let err = fails(dir, ["add", "nope"])
  assert err ==
    "error: package `nope` not found in the registry (app -> nope)\n  help: the registry is {registry()}; set RAFT_REGISTRY to use another\n"
  assert !read(paths.join(dir, "raft.toml")).contains("nope")
  // Transitive: lost depends on ghost, which doesn't exist.
  let err = fails(dir, ["add", "lost"])
  t.check(
    err.starts_with("error: package `ghost` not found in the registry (app -> lost -> ghost)\n"),
    err,
  )
  t.rm_rf(d)
}

fn version_mismatch() uses env, fs, ffi, time {
  let (d, dir) = app("version_mismatch")
  let toml = read(paths.join(dir, "raft.toml")) + "c = \"^1.0\"\n"
  t.write(paths.join(dir, "raft.toml"), toml)
  let err = fails(dir, ["install"])
  assert err ==
    "error: c ^1.0 does not match the registry version 2.0.0 (app -> c)\n  help: use c = \"^2.0\" in raft.toml\n"

  // `raft add` rewrites the requirement to the registry's version.
  assert ok(dir, ["add", "c"]) == "  + c 2.0.0\n"
  assert read(paths.join(dir, "raft.toml")).ends_with("[deps]\nc = \"^2.0\"\n")

  // Transitive: old wants c ^1.0.
  let err = fails(dir, ["add", "old"])
  assert err ==
    "error: c ^1.0 does not match the registry version 2.0.0 (app -> old -> c)\n  help: old needs c ^1.0, but the registry only has 2.0.0\n"
  t.rm_rf(d)
}

fn outside_a_project() uses env, fs, ffi, time {
  let d = tmp("outside_a_project")
  let err = fails(d, ["install"])
  assert err ==
    "error: no raft.toml in this directory or any parent\n  help: create a project with `raft new <name>`\n"
  t.rm_rf(d)
}
