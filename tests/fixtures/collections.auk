/// Core collection extras: chunks, windows, flat_map, group_by, unique (tests/collections.rs).

struct P { name: str, team: str }

test "chunks" {
  assert [1, 2, 3, 4, 5].chunks(2) == [[1, 2], [3, 4], [5]]
  assert [1, 2, 3, 4].chunks(2) == [[1, 2], [3, 4]]
  assert [1, 2].chunks(5) == [[1, 2]]
  let e: [int] = []
  assert e.chunks(3).len() == 0
}

test "windows" {
  assert [1, 2, 3, 4].windows(2) == [[1, 2], [2, 3], [3, 4]]
  assert [1, 2, 3].windows(3) == [[1, 2, 3]]
  assert [1, 2].windows(3).len() == 0
  assert "abcd".chars().windows(2).map(w => str(w)) == ["ab", "bc", "cd"]
}

test "flat_map" {
  assert [1, 2, 3].flat_map(n => (0..n).map(_ => n)) == [1, 2, 2, 3, 3, 3]
  assert ["a b", "", "c"].flat_map(s => s.split()) == ["a", "b", "c"]
}

test "group_by" {
  let g = [1, 2, 3, 4, 5, 6, 7].group_by(n => n % 3)
  assert g.keys() == [1, 2, 0]
  assert g[1] == [1, 4, 7]
  assert g[0] == [3, 6]
  let ps = [
    P { name: "a", team: "red" },
    P { name: "b", team: "blue" },
    P { name: "c", team: "red" },
  ]
  let t = ps.group_by(p => p.team)
  assert t.keys() == ["red", "blue"]
  assert t["red"].map(p => p.name) == ["a", "c"]
}

test "unique" {
  assert [3, 1, 3, 2, 1].unique() == [3, 1, 2]
  assert ["b", "a", "b"].unique() == ["b", "a"]
  assert [(1, "x"), (1, "x"), (2, "x")].unique() == [(1, "x"), (2, "x")]
  assert [P { name: "a", team: "r" }, P { name: "a", team: "r" }].unique().len() == 1
}
