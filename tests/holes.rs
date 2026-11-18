//! `auk holes`: the brief for every `??` hole (expected type, scope, contracts, tests), as text
//! and as JSON, for a single file and for a project with a hole in a submodule.

#[path = "../src/json.rs"]
#[allow(dead_code)]
mod json;

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

use json::Json;

mod auk_bin;

fn auk(args: &[&str]) -> Output {
    Command::new(auk_bin::auk_bin()).args(args).current_dir(env!("CARGO_MANIFEST_DIR")).output().unwrap()
}

fn holes_json(file: &str) -> Json {
    let o = auk(&["holes", file, "--json"]);
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success(), "auk holes failed:\n{out}\n{}", String::from_utf8_lossy(&o.stderr));
    json::parse(&out).unwrap_or_else(|e| panic!("bad JSON ({e}): {out}"))
}

fn strs(j: &Json) -> Vec<&str> {
    j.as_arr().iter().map(|x| x.as_str().unwrap()).collect()
}

fn scope(h: &Json) -> Vec<(String, String)> {
    h.get("scope").as_arr().iter().map(|v| (v.get("name").as_str().unwrap().to_string(), v.get("type").as_str().unwrap().to_string())).collect()
}

fn scratch(name: &str) -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("holes").join(name);
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn hatch_example_has_three_holes() {
    let j = holes_json("examples/hatch.auk");
    assert_eq!(j.get("ok"), &Json::Bool(true));
    let hs = j.get("holes").as_arr();
    assert_eq!(hs.len(), 3, "{j}");
    let expected: Vec<&str> = hs.iter().map(|h| h.get("expected").as_str().unwrap()).collect();
    assert_eq!(expected, ["float", "[int]", "int!DurErr"]);
    let names: Vec<&str> = hs.iter().map(|h| h.at(&["function", "name"]).as_str().unwrap()).collect();
    assert_eq!(names, ["median", "dedup", "seconds"]);
    for (i, h) in hs.iter().enumerate() {
        assert_eq!(h.get("index").as_i64(), Some(i as i64 + 1));
        assert_eq!(h.get("file").as_str(), Some("examples/hatch.auk"));
        assert_eq!(h.get("body"), &Json::Bool(true), "each hole is a whole `{{ ?? }}` body");
        assert_eq!(h.get("end_col").as_i64(), Some(h.get("col").as_i64().unwrap() + 2));
    }

    let median = &hs[0];
    assert_eq!((median.get("line").as_i64(), median.get("col").as_i64()), (Some(6), Some(3)));
    assert_eq!(median.get("context").as_str(), Some("fn median"));
    assert_eq!(median.at(&["function", "signature"]).as_str(), Some("fn median(xs: [float]): float"));
    assert_eq!(median.at(&["function", "doc"]).as_str(), Some("Median of a non-empty list."));
    assert_eq!(strs(median.at(&["function", "requires"])), ["xs.len() > 0"]);
    assert!(median.at(&["function", "ensures"]).as_arr().is_empty());
    assert_eq!(scope(median), [("xs".to_string(), "[float]".to_string())]);
    let tests = median.get("tests").as_arr();
    assert_eq!(tests.len(), 1);
    assert_eq!(tests[0].get("name").as_str(), Some("median"));
    assert_eq!(
        tests[0].get("source").as_str(),
        Some("test \"median\" {\n  assert median([3.0, 1.0, 2.0]) == 2.0\n  assert median([4.0, 1.0, 3.0, 2.0]) == 2.5\n}")
    );
    let others: Vec<&str> = median.get("module_fns").as_arr().iter().map(|f| f.get("signature").as_str().unwrap()).collect();
    assert_eq!(others, ["fn dedup(xs: [int]): [int]", "fn seconds(s: str): int!DurErr"]);
    assert_eq!(median.get("module_types").as_arr()[0].get("source").as_str(), Some("enum DurErr { Empty, BadUnit(c: char), NoNumber }"));

    let dedup = &hs[1];
    assert_eq!(strs(dedup.at(&["function", "ensures"])), ["result.len() <= xs.len()"]);
    assert_eq!(scope(dedup), [("xs".to_string(), "[int]".to_string())]);
    assert!(dedup.get("tests").as_arr()[0].get("source").as_str().unwrap().contains("assert dedup([3, 1, 3, 2, 1]) == [3, 1, 2]"));

    let seconds = &hs[2];
    assert!(seconds.at(&["function", "doc"]).is_null(), "the doc above `enum DurErr` is not seconds'");
    assert_eq!(strs(seconds.at(&["function", "ensures"])), ["result >= 0"]);
    assert_eq!(scope(seconds), [("s".to_string(), "str".to_string())]);
    let src = seconds.get("tests").as_arr()[0].get("source").as_str().unwrap();
    assert!(src.starts_with("test \"seconds\" {") && src.contains("assert seconds(\"5x\") is err(BadUnit('x'))"), "{src}");
}

#[test]
fn text_brief() {
    let o = auk(&["holes", "examples/hatch.auk"]);
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success());
    for want in [
        "hole 1 at examples/hatch.auk:6:3 in fn median\n  expected type: float\n",
        "    /// Median of a non-empty list.\n    fn median(xs: [float]): float\n      requires xs.len() > 0\n",
        "  in scope:\n    xs: [float]\n",
        "  tests that call it:\n    test \"median\" {\n      assert median([3.0, 1.0, 2.0]) == 2.0\n",
        "hole 3 at examples/hatch.auk:18:3 in fn seconds\n  expected type: int!DurErr\n",
        "      ensures result >= 0\n",
    ] {
        assert!(out.contains(want), "missing {want:?} in:\n{out}");
    }
}

#[test]
fn no_holes() {
    let o = auk(&["holes", "examples/fib.auk", "--json"]);
    let j = json::parse(&String::from_utf8_lossy(&o.stdout)).unwrap();
    assert!(o.status.success());
    assert!(j.get("holes").as_arr().is_empty());
}

#[test]
fn project_hole_in_a_submodule() {
    let d = scratch("proj");
    fs::create_dir_all(d.join("src")).unwrap();
    fs::write(d.join("raft.toml"), "[package]\nname = \"proj\"\nversion = \"0.1.0\"\n").unwrap();
    fs::write(
        d.join("src/main.auk"),
        "fn main() {\n  print(geo.scale([1, 2], 3))\n}\n\ntest \"scale\" {\n  assert geo.scale([1], 2) == [4]\n}\n\ntest \"other\" {\n  assert 1 + 1 == 2\n}\n",
    )
    .unwrap();
    fs::write(
        d.join("src/geo.auk"),
        "/// Multiply by twice `f`.\npub fn scale(xs: [int], f: int): [int] {\n  let k = f * 2\n  for i in 0..3 {\n    let gone = i\n  }\n  xs.map(x => {\n    let y = x * k\n    ??\n  })\n}\n\nfn helper(s: str): int = s.len()\n",
    )
    .unwrap();
    let main = d.join("src/main.auk").display().to_string();
    let j = holes_json(&main);
    let hs = j.get("holes").as_arr();
    assert_eq!(hs.len(), 1, "{j}");
    let h = &hs[0];
    assert!(h.get("file").as_str().unwrap().ends_with("src/geo.auk"), "{h}");
    assert_eq!((h.get("line").as_i64(), h.get("col").as_i64()), (Some(9), Some(5)));
    assert_eq!(h.get("expected").as_str(), Some("int"));
    assert_eq!(h.get("body"), &Json::Bool(false));
    assert_eq!(h.at(&["function", "signature"]).as_str(), Some("pub fn scale(xs: [int], f: int): [int]"));
    assert_eq!(h.at(&["function", "doc"]).as_str(), Some("Multiply by twice `f`."));
    let names: Vec<String> = scope(h).into_iter().map(|(n, t)| format!("{n}: {t}")).collect();
    assert_eq!(names, ["xs: [int]", "f: int", "k: int", "x: int", "y: int"], "`i` and `gone` are out of scope");
    let tests: Vec<&str> = h.get("tests").as_arr().iter().map(|t| t.get("name").as_str().unwrap()).collect();
    assert_eq!(tests, ["scale"], "only the test that calls `geo.scale`");
    let others: Vec<&str> = h.get("module_fns").as_arr().iter().map(|f| f.get("signature").as_str().unwrap()).collect();
    assert_eq!(others, ["fn helper(s: str): int"]);
}

#[test]
fn type_errors_fail_but_still_brief() {
    let d = scratch("broken");
    let f = d.join("b.auk");
    fs::write(&f, "fn f(n: int): int {\n  let s: str = 1\n  ??\n}\n").unwrap();
    let o = auk(&["holes", f.to_str().unwrap(), "--json"]);
    assert_eq!(o.status.code(), Some(1));
    let j = json::parse(&String::from_utf8_lossy(&o.stdout)).unwrap();
    assert_eq!(j.get("ok"), &Json::Bool(false));
    assert_eq!(j.get("holes").as_arr().len(), 1);
    assert!(String::from_utf8_lossy(&o.stderr).contains("E0200"));
}
