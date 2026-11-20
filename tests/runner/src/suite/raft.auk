/// tests/raft.rs: the package manager end to end against the fixture registry
/// (tests/fixtures/registry): `new`, `add` (transitive, path and URL dependencies), `remove`,
/// `install`, `list`, `pack`, `publish`, the lock file, effects, checksums and errors. Fetching
/// over HTTP uses a local `python3 -m http.server`, and an rpm registry is played by
/// tests/fixtures/rpm_server.py (both skipped without python3). The raft under test is
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
  t.test("url_registry_and_url_dep", url_registry_and_url_dep),
  t.test("rpm_publish_and_versions", rpm_publish_and_versions),
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

/// `raft pack` bundles served over HTTP: `RAFT_REGISTRY=<url>`, `{ url = ... }` deps, lock
/// checksums equal to the bundle's sha256, a changed remote bundle refused, and an offline
/// reinstall from `.raft/`.
fn url_registry_and_url_dep() uses env, fs, ffi, time {
  if !t.have("python3") { t.skip("needs python3 for a local HTTP server") }
  let d = tmp("url_registry_and_url_dep")
  let srv = paths.join(d, "srv")
  let packed = ok(paths.join(registry(), "b"), ["pack", srv])
  let b_sum = packed.split("\n")[1].trim()
  t.check(b_sum.starts_with("sha256:"), packed)
  for p in ["a", "c"] { let _ = ok(paths.join(registry(), p), ["pack", srv]) }

  var server = cmd
    .new("python3")
    .args(["-u", "-m", "http.server", "0", "--bind", "127.0.0.1"])
    .cwd(srv)
    .start()
  let line = sys.read_line(&server, 20000) else ""
  let port = match line.split(" port ") {
    [_, rest] => rest.split(" ")[0]
    _ => {
      sys.kill(&server)
      t.bail("no port from python3 http.server: `{line}`")
    }
  }
  let url = "http://127.0.0.1:{port}"
  let net = (dir: str, args: [str]) => t
    .raft()
    .args(args)
    .cwd(dir)
    .setenv("RAFT_REGISTRY", url)
    .output()

  let _ = ok(d, ["new", "app"])
  let dir = paths.join(d, "app")
  let o = net(dir, ["add", "a"])
  t.check(o.success(), o.stderr)
  assert o.stdout == "  + a 1.2.0\n  + b 1.0.3   (via a)\n"
  t.has(
    read(paths.join(dir, "raft.lock")),
    "name = \"b\"\nversion = \"1.0.3\"\nsource = \"registry\"\neffects = []\nchecksum = \"{b_sum}\"",
  )
  let o = net(dir, ["add", "c", "--url", "{url}/c.raft"])
  t.check(o.success(), o.stderr)
  t.has(read(paths.join(dir, "raft.toml")), "c = {{ url = \"{url}/c.raft\" }}")
  t.has(read(paths.join(dir, "raft.lock")), "source = \"url:{url}/c.raft\"")

  t.has(
    net(dir, ["add", "zz", "--url", "{url}/zz.raft"]).stderr,
    "error: cannot fetch {url}/zz.raft: HTTP 404",
  )
  t.has(
    net(dir, ["add", "d", "--url", "{url}/c.raft"]).stderr,
    "error: {url}/c.raft is package `c`, not `d`",
  )

  // A changed bundle at the locked URL is refused once it has to be fetched.
  let c2 = paths.join(d, "c2")
  t.copy_dir(paths.join(registry(), "c"), c2)
  t.write(paths.join(c2, "src/lib.auk"), "pub fn evil() {{}}\n")
  let _ = ok(c2, ["pack", srv])
  t.check(net(dir, ["install"]).success(), "the installed c matches the lock: nothing to fetch")
  t.rm_rf(paths.join(dir, ".raft/c"))
  t.has(net(dir, ["install"]).stderr, "error: checksum mismatch for c 2.0.0 at {url}/c.raft")
  assert !fs.exists(paths.join(dir, ".raft/c"))

  // Put c back and reinstall; then, with the server gone, the locked project still installs.
  let _ = ok(paths.join(registry(), "c"), ["pack", srv])
  t.check(net(dir, ["install"]).success(), "reinstall")
  sys.kill(&server)
  let _ = cmd.wait(&server, 5000)
  let o = net(dir, ["install"])
  t.check(o.success() && o.stdout == "", o.stderr)
  t.rm_rf(d)
}

/// An rpm registry (tests/fixtures/rpm_server.py): `raft publish`, installing the newest version
/// that fits, `raft add <pkg>@<version>`, the lock keeping its version, and yanked versions.
fn rpm_publish_and_versions() uses env, fs, ffi, time {
  if !t.have("python3") { t.skip("needs python3 for a local registry") }
  let d = tmp("rpm_publish_and_versions")
  var server = cmd.new("python3").args(["-u", t.abs("tests/fixtures/rpm_server.py")]).start()
  let line = sys.read_line(&server, 20000) else ""
  let port = match line.trim().strip_prefix("port ") {
    some(p) => p
    none => {
      sys.kill(&server)
      t.bail("no port from rpm_server.py: `{line}`")
    }
  }
  let url = "http://127.0.0.1:{port}"
  let run = (dir: str, args: [str], token: str) => t
    .raft()
    .args(args)
    .cwd(dir)
    .setenv("RAFT_REGISTRY", url)
    .setenv("RPM_TOKEN", token)
    .output()
  let net = (dir: str, args: [str]) => run(dir, args, "rpm_test")
  let good = (dir: str, args: [str]) => {
    let o = net(dir, args)
    t.check(o.success(), "raft {args} failed:\n{o.stderr}")
    o.stdout
  }

  // publishing: a token is needed, the right one; the checksum is `raft pack`'s
  let b = paths.join(d, "b")
  t.copy_dir(paths.join(registry(), "b"), b)
  let o = run(b, ["publish"], "")
  t.eq(
    o.stderr,
    "error: publishing needs a token\n  help: make one at {url}/account, then set RPM_TOKEN or pass --token <token>\n",
    "no token",
  )
  t.eq(
    run(b, ["publish"], "wrong").stderr,
    "error: cannot publish b 1.0.3 to {url}: publishing needs an API token\n",
    "a wrong token",
  )
  let b_sum = ok(b, ["pack", paths.join(d, "packed")]).split("\n")[1].trim()
  t.eq(good(b, ["publish"]), "published b 1.0.3 -> {url}/packages/b/1.0.3\n  {b_sum}\n", "publish")
  t.has(
    net(b, ["publish"]).stderr,
    "error: cannot publish b 1.0.3 to {url}: b 1.0.3 is already published",
  )
  t.has(run(b, ["publish", "--token", "rpm_test"], "").stderr, "b 1.0.3 is already published")
  // two more versions of b, and a (which needs b ^1.0)
  for v in ["1.0.4", "1.1.0"] {
    t.write(paths.join(b, "raft.toml"), read(paths.join(b, "raft.toml")).replace("1.0.3", v))
    t.has(good(b, ["publish"]), "published b {v}")
    t.write(paths.join(b, "raft.toml"), read(paths.join(b, "raft.toml")).replace(v, "1.0.3"))
  }
  t.has(good(paths.join(registry(), "a"), ["publish"]), "published a 1.2.0")

  // a registry that is a directory, or would get the token unencrypted
  t.has(
    fails(b, ["publish", "--token", "x"]),
    "error: cannot publish to {registry()}: it is a directory, not an rpm server",
  )
  let o = t
    .raft()
    .args(["publish", "--token", "x"])
    .cwd(b)
    .setenv("RAFT_REGISTRY", "http://rpm.example.com")
    .output()
  t.has(
    o.stderr,
    "error: cannot publish to http://rpm.example.com: the token would be sent unencrypted",
  )

  // installing: the newest version that fits, checked against the registry's checksum
  let _ = ok(d, ["new", "app"])
  let dir = paths.join(d, "app")
  let locked = (name: str) => {
    let l = read(paths.join(dir, "raft.lock"))
    l.split("name = \"{name}\"\nversion = \"")[1].split("\"")[0]
  }
  t.eq(good(dir, ["add", "a"]), "  + a 1.2.0\n  + b 1.1.0   (via a)\n", "add a")
  t.eq(
    net(dir, ["add", "nope"]).stderr,
    "error: package `nope` not found in the registry (app -> nope)\n  help: the registry is {url}; set RAFT_REGISTRY to use another\n",
    "a package rpm doesn't have",
  )
  let _ = good(dir, ["remove", "a"])

  // pinning: an exact version, then a requirement (the locked version stays while it fits)
  t.eq(good(dir, ["add", "b@1.0.3"]), "  + b 1.0.3\n", "add b@1.0.3")
  t.has(read(paths.join(dir, "raft.toml")), "b = \"=1.0.3\"")
  t.has(
    read(paths.join(dir, "raft.lock")),
    "name = \"b\"\nversion = \"1.0.3\"\nsource = \"registry\"\neffects = []\nchecksum = \"{b_sum}\"",
  )
  t.eq(good(dir, ["add", "b@~1.0"]), "", "add b@~1.0 keeps the locked 1.0.3")
  t.has(read(paths.join(dir, "raft.toml")), "b = \"~1.0\"")
  t.eq(locked("b"), "1.0.3", "still locked")
  t.eq(good(dir, ["add", "b@1.0.4"]), "  + b 1.0.4\n", "add b@1.0.4")
  t.has(read(paths.join(dir, ".raft/b/raft.toml")), "version = \"1.0.4\"")
  t.eq(good(dir, ["add", "b"]), "  + b 1.1.0\n", "add b takes the newest")
  t.has(read(paths.join(dir, "raft.toml")), "b = \"^1.1\"")
  let before = read(paths.join(dir, "raft.toml"))
  t.eq(
    net(dir, ["add", "b@2.0.0"]).stderr,
    "error: no version of b in the registry matches =2.0.0\n  help: the newest is 1.1.0\n",
    "a version rpm doesn't have",
  )
  t.eq(
    net(dir, ["add", "b@new"]).stderr,
    "error: invalid version `new` for b\n  help: give a version (1.2.3) or a requirement (^1.2, ~1.2.3, *)\n",
    "not a version",
  )
  t.has(
    net(dir, ["add", "b@1.0.3", "--path", "../b"]).stderr,
    "error: `b@1.0.3`: only a registry package takes a version",
  )
  t.eq(read(paths.join(dir, "raft.toml")), before, "raft.toml is as it was")

  // a yanked version: still installed where it is locked, never chosen anew
  let yank = "import sys, urllib.request; urllib.request.urlopen(sys.argv[1] + '/yank', data=b'{{\"name\": \"b\", \"version\": \"1.1.0\"}}')"
  t.check(cmd.new("python3").args(["-c", yank, url]).output().success(), "yank b 1.1.0")
  t.rm_rf(paths.join(dir, ".raft"))
  t.check(net(dir, ["install"]).success(), "the locked b installs")
  t.eq(locked("b"), "1.1.0", "locked")
  t.rm_rf(paths.join(dir, "raft.lock"))
  t.has(net(dir, ["install"]).stderr, "error: b ^1.1 does not match the registry version 1.0.4")

  sys.kill(&server)
  let _ = cmd.wait(&server, 5000)
  t.rm_rf(d)
}
