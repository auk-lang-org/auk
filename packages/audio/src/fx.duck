/// Filters and effects on one channel at a time (module `audio.fx`): RBJ-cookbook biquads,
/// echo, dynamics (compressor, limiter, gate), fades and WSOLA time stretching. `audio` applies
/// them to every channel; the functions here take a channel's samples and the sample rate.

/// Normalized biquad coefficients: y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2.
pub struct Biquad { b0: float, b1: float, b2: float, a1: float, a2: float }

pub enum Kind { Lowpass, Highpass, Bandpass, Notch, Allpass, Peak, LowShelf, HighShelf }

/// The RBJ Audio EQ Cookbook filter of `kind` at `freq` Hz with quality `q` and (for peak and
/// shelf filters) `gain_db`.
pub fn design(kind: Kind, freq: float, q: float, gain_db: float, rate: int): Biquad {
  let w0 = 2.0 * float.pi * freq / float(rate)
  let cw = cos(w0)
  let alpha = sin(w0) / (2.0 * q)
  let a = 10.0 ** (gain_db / 40.0)
  let (b0, b1, b2, a0, a1, a2) = match kind {
    Lowpass => ((1.0 - cw) / 2.0, 1.0 - cw, (1.0 - cw) / 2.0, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)
    Highpass =>
      ((1.0 + cw) / 2.0, -(1.0 + cw), (1.0 + cw) / 2.0, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)
    Bandpass => (alpha, 0.0, -alpha, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)
    Notch => (1.0, -2.0 * cw, 1.0, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)
    Allpass => (1.0 - alpha, -2.0 * cw, 1.0 + alpha, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)
    Peak =>
      (1.0 + alpha * a, -2.0 * cw, 1.0 - alpha * a, 1.0 + alpha / a, -2.0 * cw, 1.0 - alpha / a)
    LowShelf => {
      let s = 2.0 * sqrt(a) * alpha
      (
        a * ((a + 1.0) - (a - 1.0) * cw + s),
        2.0 * a * ((a - 1.0) - (a + 1.0) * cw),
        a * ((a + 1.0) - (a - 1.0) * cw - s),
        (a + 1.0) + (a - 1.0) * cw + s,
        -2.0 * ((a - 1.0) + (a + 1.0) * cw),
        (a + 1.0) + (a - 1.0) * cw - s,
      )
    }
    HighShelf => {
      let s = 2.0 * sqrt(a) * alpha
      (
        a * ((a + 1.0) + (a - 1.0) * cw + s),
        -2.0 * a * ((a - 1.0) + (a + 1.0) * cw),
        a * ((a + 1.0) + (a - 1.0) * cw - s),
        (a + 1.0) - (a - 1.0) * cw + s,
        2.0 * ((a - 1.0) - (a + 1.0) * cw),
        (a + 1.0) - (a - 1.0) * cw - s,
      )
    }
  }
  Biquad { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 }
}

/// Runs the filter over `xs` (transposed direct form II, starting from silence).
pub fn biquad(xs: [float], f: Biquad): [float] {
  var out = xs
  var z1 = 0.0
  var z2 = 0.0
  for i in 0..xs.len() {
    let x = xs[i]
    let y = f.b0 * x + z1
    z1 = f.b1 * x - f.a1 * y + z2
    z2 = f.b2 * x - f.a2 * y
    out[i] = y
  }
  out
}

/// The filter's gain in dB at `freq` Hz.
pub fn response_db(f: Biquad, freq: float, rate: int): float {
  let w = 2.0 * float.pi * freq / float(rate)
  // |B(e^jw)| / |A(e^jw)|
  let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2.0 * w), sin(2.0 * w))
  let br = f.b0 + f.b1 * c1 + f.b2 * c2
  let bi = -(f.b1 * s1 + f.b2 * s2)
  let ar = 1.0 + f.a1 * c1 + f.a2 * c2
  let ai = -(f.a1 * s1 + f.a2 * s2)
  10.0 * log10((br * br + bi * bi) / (ar * ar + ai * ai))
}

// ---- delays ----

/// `secs` of silence before `xs`.
pub fn delay(xs: [float], secs: float, rate: int): [float] =
  audio.pcm.zeros(samples(secs, rate)) + xs

pub fn samples(secs: float, rate: int): int = if secs <= 0.0 {
  0
} else {
  int(round(secs * float(rate)))
}

/// ffmpeg's aecho: out = (x * in_gain + sum(x delayed by delays[i] * decays[i])) * out_gain,
/// lengthened so the last echo finishes.
pub fn echo(
  xs: [float],
  rate: int,
  in_gain: float,
  out_gain: float,
  delays: [float],
  decays: [float],
): [float] {
  let ds = delays.map(d => samples(d, rate))
  let tail = ds.max() else 0
  var out: [float] = []
  for i in 0..xs.len() + tail {
    var y = (xs.get(i) else 0.0) * in_gain
    for k in 0..ds.len() {
      let j = i - ds[k]
      if j >= 0 && j < xs.len() { y += xs[j] * decays[k] }
    }
    out.push(y * out_gain)
  }
  out
}

// ---- dynamics ----

pub fn db(x: float): float = if x <= 0.0 { -1000.0 } else { 20.0 * log10(x) }
pub fn undb(d: float): float = 10.0 ** (d / 20.0)

// The envelope step of ffmpeg's dynamics filters: 4 / (time * rate), at most 1.
fn step(secs: float, rate: int): float {
  let s = if secs <= 0.0 { 1.0 } else { 4.0 / (secs * float(rate)) }
  if s > 1.0 { 1.0 } else { s }
}

// A one-pole smoothing coefficient for a time constant in seconds.
fn coef(secs: float, rate: int): float = if secs <= 0.0 {
  0.0
} else {
  exp(-1.0 / (secs * float(rate)))
}

/// The gain (in dB, <= 0) a compressor applies to a level of `x` dB.
pub fn curve(x: float, threshold: float, ratio: float, knee: float): float {
  let over = x - threshold
  if knee > 0.0 && 2.0 * abs(over) <= knee {
    let t = over + knee / 2.0
    (1.0 / ratio - 1.0) * t * t / (2.0 * knee)
  } else if over > 0.0 {
    over * (1.0 / ratio - 1.0)
  } else {
    0.0
  }
}

/// The gain each sample gets from a feed-forward compressor driven by `detect` (one value per
/// sample: the loudest channel's absolute level, say), as ffmpeg's acompressor: an envelope
/// follows the level (or its square, for `rms`), rising with `attack` and falling with
/// `release` (seconds), and the gain comes from the envelope. Levels are in dB.
pub fn compress_gains(
  detect: [float],
  rate: int,
  threshold: float,
  ratio: float,
  knee: float,
  attack: float,
  release: float,
  makeup: float,
  rms: bool,
): [float] {
  let ca = step(attack, rate)
  let cr = step(release, rate)
  var env = 0.0
  var out: [float] = []
  for x in detect {
    let v = if rms { x * x } else { x }
    env += (v - env) * if v > env { ca } else { cr }
    let level = if rms { sqrt(env) } else { env }
    out.push(undb(curve(db(level), threshold, ratio, knee) + makeup))
  }
  out
}

/// The gain each sample gets from a lookahead brickwall limiter: no sample of `detect` times
/// its gain goes over `limit`. The gain falls over `attack` seconds before a peak and recovers
/// over `release` seconds after it.
pub fn limit_gains(
  detect: [float],
  rate: int,
  limit: float,
  attack: float,
  release: float,
): [float] {
  let n = detect.len()
  let la = if samples(attack, rate) < 1 { 1 } else { samples(attack, rate) }
  let need = detect.map(x => if x > limit { limit / x } else { 1.0 })
  // the least gain needed anywhere in the next `la` samples (a sliding-window minimum)
  var held = audio.pcm.zeros(n)
  var dq: [int] = []
  var head = 0
  var j = 0
  for i in 0..n {
    while j < n && j <= i + la {
      while dq.len() > head && need[dq[dq.len() - 1]] >= need[j] { dq.pop() }
      dq.push(j)
      j += 1
    }
    while dq[head] < i { head += 1 }
    held[i] = need[dq[head]]
  }
  // recover slowly after a peak, never above what's held
  let cr = coef(release, rate)
  var r = 1.0
  for i in 0..n {
    r = cr * r + (1.0 - cr) * held[i]
    if r > held[i] { r = held[i] }
    held[i] = r
  }
  // a moving average over the lookahead ramps the gain down smoothly before each peak, and
  // stays at or below every sample's need (the window ending at a peak holds only values <= it)
  var out: [float] = []
  var sum = 0.0
  for i in 0..n {
    sum += held[i]
    if i > la { sum -= held[i - la - 1] }
    // before the window fills, pad with the first held value
    let pad = if i < la { float(la - i) * held[0] } else { 0.0 }
    out.push((sum + pad) / float(la + 1))
  }
  out
}

// Cubic Hermite interpolation between (x0, p0) and (x1, p1) with slopes m0 and m1.
fn hermite(x: float, x0: float, x1: float, p0: float, p1: float, m0: float, m1: float): float {
  let w = x1 - x0
  let t = (x - x0) / w
  let (a, b) = (m0 * w, m1 * w)
  let c2 = -3.0 * p0 - 2.0 * a + 3.0 * p1 - b
  let c3 = 2.0 * p0 + a - 2.0 * p1 + b
  c3 * t * t * t + c2 * t * t + a * t + p0
}

/// The gain a noise gate applies, as ffmpeg's agate (downward mode): an envelope of the level
/// (or of its square, for `rms`) with ffmpeg's attack and release; below the threshold the gain
/// falls along `ratio` in the envelope's log domain, through a Hermite knee spanning `threshold`
/// times or divided by sqrt(`knee`), never below `range`. Threshold, knee and range are linear.
pub fn gate_gains(
  detect: [float],
  rate: int,
  threshold: float,
  ratio: float,
  knee: float,
  range: float,
  attack: float,
  release: float,
  rms: bool,
): [float] {
  let ca = step(attack, rate)
  let cr = step(release, rate)
  let lt = if rms { threshold * threshold } else { threshold }
  let thres = ln(lt)
  let lin_stop = lt * sqrt(knee)
  let kstart = ln(lt / sqrt(knee))
  let kstop = ln(lin_stop)
  var env = 0.0
  var out: [float] = []
  for x in detect {
    let v = if rms { x * x } else { x }
    env += (v - env) * if v > env { ca } else { cr }
    var g = 1.0
    if env > 0.0 && env < lin_stop {
      let slope = ln(env)
      var gain = (slope - thres) * ratio + thres
      if knee > 1.0 && slope > kstart {
        gain = hermite(slope, kstart, kstop, (kstart - thres) * ratio + thres, kstop, ratio, 1.0)
      }
      g = exp(gain - slope)
      if g < range { g = range }
    }
    out.push(g)
  }
  out
}

// ---- fades ----

pub enum Curve { Linear, QuarterSine, HalfSine, Log, Exp, Square, Cube }

/// The gain at `t` (0..1) through a fade-in.
pub fn shape(c: Curve, t0: float): float {
  let t = if t0 < 0.0 { 0.0 } else if t0 > 1.0 { 1.0 } else { t0 }
  match c {
    Linear => t
    QuarterSine => sin(t * float.pi / 2.0)
    HalfSine => (1.0 - cos(t * float.pi)) / 2.0
    Log => if t <= 0.0 { 0.0 } else { max0(1.0 + log10(t) / 3.0) }
    Exp => if t <= 0.0 { 0.0 } else { 10.0 ** (3.0 * (t - 1.0)) }
    Square => t * t
    Cube => t * t * t
  }
}

fn max0(x: float): float = if x < 0.0 { 0.0 } else { x }

pub fn curve_named(s: str): Curve? = match s {
  "tri" => some(Linear)
  "linear" => some(Linear)
  "qsin" => some(QuarterSine)
  "hsin" => some(HalfSine)
  "log" => some(Log)
  "exp" => some(Exp)
  "squ" => some(Square)
  "cub" => some(Cube)
  _ => none
}

/// Fades `xs` in (or out) over `len` samples starting at sample `start`: before a fade-in is
/// silence, after a fade-out too.
pub fn fade(xs: [float], fade_in: bool, start: int, len: int, c: Curve): [float] {
  var out = xs
  for i in 0..xs.len() {
    let t = if len <= 0 {
      if i >= start { 1.0 } else { 0.0 }
    } else {
      float(i - start) / float(len)
    }
    let g = if fade_in { shape(c, t) } else { shape(c, 1.0 - t) }
    if g != 1.0 { out[i] = xs[i] * g }
  }
  out
}

// ---- time stretching (WSOLA) ----

/// Positions in the input where each output frame of a WSOLA stretch starts: frames of `win`
/// samples, written every `win / 2`, read every `win / 2 * tempo` and nudged by up to `search`
/// samples to line up with the previous frame. `guide` is a mono mix used to line frames up.
pub fn wsola_plan(guide: [float], tempo: float, win: int, search: int): [int] {
  let hop = win / 2
  let n = guide.len()
  var starts: [int] = [0]
  var k = 1
  loop {
    let nominal = int(round(float(k) * float(hop) * tempo))
    if nominal >= n { break }
    // the natural continuation of the previous frame
    let target = starts[k - 1] + hop
    var best = nominal
    if target + hop <= n {
      // coarse search every 4 samples, then refine around the best
      best = align(guide, target, hop, nominal - search, nominal + search, 4, 8, nominal)
      best = align(guide, target, hop, best - 3, best + 3, 1, 2, best)
    }
    starts.push(best)
    k += 1
  }
  starts
}

// The start in lo..=hi (every `step`) whose `hop` samples best match those at `target`, by
// normalized cross-correlation over every `stride`-th sample.
fn align(
  g: [float],
  target: int,
  hop: int,
  lo: int,
  hi: int,
  step: int,
  stride: int,
  dflt: int,
): int {
  let n = g.len()
  var best = dflt
  var best_score = -1.0e300
  var p = lo
  while p <= hi {
    if p >= 0 && p + hop <= n {
      var s = 0.0
      var e = 0.0
      var i = 0
      while i < hop {
        let x = g[p + i]
        s += x * g[target + i]
        e += x * x
        i += stride
      }
      let score = if e > 0.0 { s / sqrt(e) } else { 0.0 }
      if score > best_score {
        best_score = score
        best = p
      }
    }
    p += step
  }
  best
}

/// Overlap-adds Hann-windowed frames of `xs` from `starts`, one every `win / 2` samples.
pub fn wsola_apply(xs: [float], starts: [int], win: int, len: int): [float] {
  let hop = win / 2
  var out = audio.pcm.zeros(starts.len() * hop + win)
  var norm = audio.pcm.zeros(starts.len() * hop + win)
  let w = (0..win).map(i => 0.5 - 0.5 * cos(2.0 * float.pi * float(i) / float(win)))
  for k in 0..starts.len() {
    let p = starts[k]
    let o = k * hop
    for i in 0..win {
      let x = xs.get(p + i) else 0.0
      out[o + i] = out[o + i] + x * w[i]
      norm[o + i] = norm[o + i] + w[i]
    }
  }
  var res: [float] = []
  for i in 0..len {
    let nv = norm.get(i) else 0.0
    res.push(if nv > 1.0e-6 { out[i] / nv } else { 0.0 })
  }
  res
}
