/// Summary statistics for one numeric column of a CSV file.

struct Stats { n: int, mean: float, min: float, max: float, stdev: float }

fn stats(xs: [float]): Stats
  requires xs.len() > 0
{
  let n = float(xs.len())
  let mean = xs.sum() / n
  let var_ = xs.map(x => (x - mean) ** 2.0).sum() / n
  Stats { n: xs.len(), mean, min: xs.min()!, max: xs.max()!, stdev: var_.sqrt() }
}

fn main(args: [str]): int! uses fs {
  let [_, path, col] = args else fail("usage: csv_stats <file> <column>")
  let [header, ..rows] = fs.lines(path)? else fail("empty file")
  let i = header.split(",").find_index(h => h == col) else fail("no column {col}")
  let xs = rows
    |> filter(r => r.trim() != "")
    |> map(r => float.parse(r.split(",")[i]))?
  if xs.len() == 0 { fail("no data rows") }
  let s = stats(xs)
  print("n={s.n} mean={s.mean:.2} min={s.min} max={s.max} sd={s.stdev:.3}")
  0
}
