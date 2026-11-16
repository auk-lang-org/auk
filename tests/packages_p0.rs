//! The P0 packages (`encoding`, `hash`, `datetime`, `url`, `toml`, `log`): `duck test` passes for
//! each, with the leak checker on, and quack installs each one into a fresh project.

use std::path::Path;
use std::process::Command;
use std::sync::Once;
use std::{env, fs};

const PKGS: [&str; 6] = ["encoding", "hash", "datetime", "url", "toml", "log"];

fn quack(dir: &Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_quack"))
        .args(args)
        .current_dir(dir)
        .env("QUACK_REGISTRY", Path::new(env!("CARGO_MANIFEST_DIR")).join("packages"))
        .output()
        .unwrap()
}

/// Install the dependencies of the packages that have any (`.quack/` is not committed).
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
fn p0_package_tests_pass_without_leaks() {
    setup();
    for p in PKGS {
        let o = Command::new(env!("CARGO_BIN_EXE_duck"))
            .args(["test", &format!("packages/{p}/src/lib.duck")])
            .env_remove("DUCK_CFLAGS")
            .env("DUCK_LEAK_CHECK", "1")
            .output()
            .unwrap();
        let out = String::from_utf8_lossy(&o.stdout);
        assert!(o.status.success() && out.ends_with(" passed, 0 failed\n"), "{p}:\n{out}\n{}", String::from_utf8_lossy(&o.stderr));
        assert!(!out.contains("FAIL") && !out.contains("leak:"), "{p}:\n{out}");
        let passed: usize = out.lines().last().unwrap().split(' ').next().unwrap().parse().unwrap();
        assert!(passed >= 6, "{p}: only {passed} tests ran");
    }
}

#[test]
fn quack_adds_each_p0_package() {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("p0").join("app");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("quack.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = []\n").unwrap();
    for p in PKGS {
        let out = quack(&dir, &["add", p]);
        assert!(out.status.success(), "quack add {p}: {}", String::from_utf8_lossy(&out.stderr));
    }
    let list = String::from_utf8_lossy(&quack(&dir, &["list"]).stdout).into_owned();
    for p in PKGS {
        assert!(list.contains(&format!("{p} 0.1.0")), "{list}");
    }
    assert!(!list.contains("uses"), "P0 packages use no effects:\n{list}");
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::write(
        dir.join("src/main.duck"),
        r#"fn main(): int! {
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
"#,
    )
    .unwrap();
    let o = Command::new(env!("CARGO_BIN_EXE_duck")).args(["run", "src/main.duck"]).current_dir(&dir).env_remove("DUCK_CFLAGS").output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success(), "{out}\n{}", String::from_utf8_lossy(&o.stderr));
    assert_eq!(out, "a b\n64\naGk=\n1970-01-01T00:00:00Z\ntrue\n");
    assert!(String::from_utf8_lossy(&o.stderr).contains("level=info msg=done"));
}
