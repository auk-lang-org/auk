/// Sample-rate conversion (module `audio.resample`): band-limited interpolation with a
/// Kaiser-windowed sinc, as in ffmpeg's swresample defaults (16 zero crossings each side, Kaiser
/// beta 9, cutoff 0.97 of the lower Nyquist). Polyphase with exact phases when the rates share a
/// large divisor (44100 <-> 48000 uses 160 phases), otherwise 4096 interpolated phases.

fn gcd(a: int, b: int): int = if b == 0 { a } else { gcd(b, a % b) }

// The modified Bessel function of the first kind, order 0.
fn bessel_i0(x: float): float {
  var sum = 1.0
  var term = 1.0
  var k = 1.0
  while term > 1.0e-12 * sum {
    let h = x / (2.0 * k)
    term *= h * h
    sum += term
    k += 1.0
  }
  sum
}

fn sinc(x: float): float = if abs(x) < 1.0e-12 { 1.0 } else { sin(float.pi * x) / (float.pi * x) }

/// The filter: `phases + 1` rows of `2 * half` taps; row p holds the weights of input samples
/// i - half + 1 .. i + half for an output at input time i + p / phases.
struct Bank { phases: int, half: int, rows: [[float]] }

fn bank(cut: float, phases: int, zeros: int, beta: float): Bank {
  let half = int(ceil(float(zeros) / cut))
  let i0b = bessel_i0(beta)
  var rows: [[float]] = []
  for p in 0..phases + 1 {
    let frac = float(p) / float(phases)
    var row: [float] = []
    var sum = 0.0
    for o in (1 - half)..(half + 1) {
      // distance from the output time to input sample i + o
      let t = float(o) - frac
      let u = t / float(half)
      let w = if abs(u) >= 1.0 { 0.0 } else { bessel_i0(beta * sqrt(1.0 - u * u)) / i0b }
      let v = cut * sinc(cut * t) * w
      row.push(v)
      sum += v
    }
    // unity gain at DC for every phase
    rows.push(if sum != 0.0 { row.map(v => v / sum) } else { row })
  }
  Bank { phases, half, rows }
}

/// `xs` at `from` Hz, resampled to `to` Hz. The output has ceil(len * to / from) samples.
pub fn resample(xs: [float], from: int, to: int): [float] = resample_with(xs, from, to, 16)

/// `resample` with `zeros` zero crossings of the sinc on each side (more is sharper and slower).
pub fn resample_with(xs: [float], from: int, to: int, zeros: int): [float] {
  if from == to || xs.len() == 0 { return xs }
  let g = gcd(from, to)
  let up = to / g
  let down = from / g
  let exact = up <= 4096
  let phases = if exact { up } else { 4096 }
  let cut = 0.97 * if to < from { float(to) / float(from) } else { 1.0 }
  let b = bank(cut, phases, zeros, 9.0)
  let n = xs.len()
  let m = (n * up + down - 1) / down
  let taps = 2 * b.half
  var out: [float] = []
  for k in 0..m {
    // the output's time in input samples is k * down / up
    let ip = k * down / up
    let rem = k * down % up
    var y = 0.0
    let base = ip - b.half + 1
    if exact {
      let row = b.rows[rem]
      if base >= 0 && base + taps <= n {
        for j in 0..taps { y += xs[base + j] * row[j] }
      } else {
        for j in 0..taps {
          let i = base + j
          if i >= 0 && i < n { y += xs[i] * row[j] }
        }
      }
    } else {
      // interpolate between the two nearest phases
      let pos = float(rem) / float(up) * float(phases)
      let r = int(floor(pos))
      let f = pos - float(r)
      let r0 = b.rows[r]
      let r1 = b.rows[r + 1]
      for j in 0..taps {
        let i = base + j
        if i >= 0 && i < n { y += xs[i] * (r0[j] + f * (r1[j] - r0[j])) }
      }
    }
    out.push(y)
  }
  out
}
