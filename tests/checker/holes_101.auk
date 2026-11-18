/// The AI workflow: a human writes signatures, contracts and tests; `auk hatch` fills the ?? holes.

/// Median of a non-empty list.
fn median(xs: [float]): float
  requires xs.len() > 0
{
  let s = xs.sort()
  let n = s.len()
  if n % 2 == 1 { s[n / 2] } else { (s[n / 2 - 1] + s[n / 2]) / 2.0 }
}

/// Remove duplicates, keeping the first occurrence of each value.
fn dedup(xs: [int]): [int]
  ensures result.len() <= xs.len()
{
  var out: [int] = []
  for x in xs {
    if !out.contains(x) { out.push(x) }
  }
  out
}

/// Parse "3h20m5s" style durations into seconds.
enum DurErr { Empty, BadUnit(c: char), NoNumber }

fn seconds(s: str): int!DurErr
  ensures result >= 0
{
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
  total
}

test "median" {
  assert median([3.0, 1.0, 2.0]) == 2.0
  assert median([4.0, 1.0, 3.0, 2.0]) == 2.5
}

test "dedup" {
  assert dedup([3, 1, 3, 2, 1]) == [3, 1, 2]
  assert dedup([]) == []
}

test "seconds" {
  assert seconds("1h")? == 3_600
  assert seconds("3h20m5s")? == 12_005
  assert seconds("") is err(Empty)
  assert seconds("5x") is err(BadUnit('x'))
}

fn main() {
  print(median([2.0, 1.0]))
}
