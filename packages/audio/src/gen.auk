/// Signal generators (module `audio.gen`): periodic waves, sweeps and colored noise. Pure:
/// noise comes from a seeded xorshift generator, so the same seed gives the same samples.

pub enum Wave { Sine, Square, Sawtooth, Triangle }

pub fn wave_named(s: str): Wave? = match s {
  "sine" => some(Sine)
  "square" => some(Square)
  "sawtooth" => some(Sawtooth)
  "saw" => some(Sawtooth)
  "triangle" => some(Triangle)
  _ => none
}

// One period's value at phase `p` (0..1).
fn at(w: Wave, p: float): float = match w {
  Sine => sin(2.0 * float.pi * p)
  Square => if p < 0.5 { 1.0 } else { -1.0 }
  Sawtooth => 2.0 * p - 1.0
  Triangle => if p < 0.25 { 4.0 * p } else if p < 0.75 { 2.0 - 4.0 * p } else { 4.0 * p - 4.0 }
}

/// `n` samples of a wave at `freq` Hz and amplitude `amp`, starting at phase 0.
pub fn wave(w: Wave, freq: float, amp: float, n: int, rate: int): [float] {
  var out: [float] = []
  let step = freq / float(rate)
  for i in 0..n {
    let p = float(i) * step
    out.push(amp * at(w, p - floor(p)))
  }
  out
}

/// A sine sweep from `f0` to `f1` Hz over `n` samples; `log` sweeps exponentially.
pub fn chirp(f0: float, f1: float, amp: float, n: int, rate: int, log: bool): [float] {
  let dur = float(n) / float(rate)
  var out: [float] = []
  for i in 0..n {
    let t = float(i) / float(rate)
    let phase = if log && f0 > 0.0 && f1 > 0.0 && f0 != f1 {
      let k = (f1 / f0) ** (1.0 / dur)
      2.0 * float.pi * f0 * (k ** t - 1.0) / ln(k)
    } else {
      2.0 * float.pi * (f0 * t + (f1 - f0) * t * t / (2.0 * dur))
    }
    out.push(amp * sin(phase))
  }
  out
}

pub enum Color { White, Pink, Brown }

pub fn color_named(s: str): Color? = match s {
  "white" => some(White)
  "pink" => some(Pink)
  "brown" => some(Brown)
  "brownian" => some(Brown)
  _ => none
}

// xorshift64*: a uniform float in -1..1 and the next state.
fn next(s: int): (float, int) {
  var x = s
  x = x ^ (x >> 12)
  x = x ^ (x << 25)
  x = x ^ (x >> 27)
  let r = (x *% 0x2545f4914f6cdd1d) >> 11
  let u = float(r & 0xfffffffffffff) / 4503599627370496.0
  (2.0 * u - 1.0, x)
}

/// `n` samples of noise with peak amplitude about `amp`.
pub fn noise(c: Color, amp: float, n: int, seed: int): [float] {
  var s = if seed == 0 { 0x1e3779b97f4a7c15 } else { seed }
  var out: [float] = []
  // Paul Kellet's pink filter state, and the brown integrator
  var b0 = 0.0
  var b1 = 0.0
  var b2 = 0.0
  var b3 = 0.0
  var b4 = 0.0
  var b5 = 0.0
  var b6 = 0.0
  var brown = 0.0
  for _ in 0..n {
    let (w, ns) = next(s)
    s = ns
    let v = match c {
      White => w
      Pink => {
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        let p = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
        b6 = w * 0.115926
        p * 0.11
      }
      Brown => {
        brown = (brown + 0.02 * w) / 1.02
        brown * 3.5
      }
    }
    out.push(amp * v)
  }
  out
}
