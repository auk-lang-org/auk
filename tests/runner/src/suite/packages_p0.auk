/// tests/packages_p0.rs: the P0 packages (`encoding`, `hash`, `datetime`, `url`, `toml`, `log`):
/// `auk test` passes for each, with the leak checker on, and raft installs each one into a fresh
/// project.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("p0_package_tests_pass_without_leaks", p0_package_tests_pass_without_leaks),
  t.test("raft_adds_each_p0_package", raft_adds_each_p0_package),
]

let PKGS = ["encoding", "hash", "datetime", "url", "toml", "log"]

fn raft(dir: str, args: [str]): cmd.Out uses env, ffi, time {
  t.raft().args(args).cwd(dir).setenv("RAFT_REGISTRY", t.abs("packages")).output()
}

/// Install the dependencies of the packages that have any (`.raft/` is not committed).
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

fn p0_package_tests_pass_without_leaks() uses env, fs, ffi, time {
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
    let last = out.lines().last() else ""
    let passed = t.must(int.parse(last.split(" ")[0]), "the count")
    t.check(passed >= 6, "{p}: only {passed} tests ran")
  }
}

fn raft_adds_each_p0_package() uses env, fs, ffi, time {
  let dir = t.scratch("p0/app")
  t.write(
    paths.join(dir, "raft.toml"),
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = []\n",
  )
  for p in PKGS {
    let out = raft(dir, ["add", p])
    t.check(out.success(), "raft add {p}: {out.stderr}")
  }
  let list = raft(dir, ["list"]).stdout
  for p in PKGS { t.check(list.contains("{p} 0.1.0"), list) }
  t.check(!list.contains("uses"), "P0 packages use no effects:\n{list}")
  t.write(paths.join(dir, "src/main.auk"), r"""
      fn main(): int! {
        let u = url.parse("https://a.com/x?q=a+b")?
        print(u.param("q") else "")
        print(hash.sha256_hex("abc").len())
        print(encoding.base64("hi".bytes()))
        print("{datetime.from_unix_ms(0)}")
        let v = toml.parse("a = 1")?
        print(v == Map({"a": Int(1)}))
        log.new(log.Info).info("done")
        0
      }
      """)
  let o = t.auk().args(["run", "src/main.auk"]).cwd(dir).output()
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  assert o.stdout == "a b\n64\naGk=\n1970-01-01T00:00:00Z\ntrue\n"
  t.check(o.stderr.contains("level=info msg=done"), o.stderr)
}
