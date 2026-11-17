/// Measurement (module `audio.analyze`): per-channel statistics (ffmpeg's astats and
/// volumedetect), EBU R128 / ITU-R BS.1770-4 loudness (integrated, range, momentary and
/// short-term maxima), true peak, the FFT and spectra, and silence detection.

/// Statistics of one channel. Levels in dBFS are -inf (shown as -1000) for silence.
pub struct Stats {
  peak: float,  // the largest |sample|
  peak_db: float,
  rms: float,
  rms_db: float,
  dc: float,  // the mean
  min: float,
  max: float,
  crest: float,  // peak / rms
  clipped: int,  // samples at or beyond full scale
  zero_crossings: int,
}

pub fn stats(xs: [float]): Stats {
  var peak = 0.0
  var sum = 0.0
  var sq = 0.0
  var lo = 0.0
  var hi = 0.0
  var clipped = 0
  var zc = 0
  for i in 0..xs.len() {
    let x = xs[i]
    let ax = abs(x)
    if ax > peak { peak = ax }
    if x < lo { lo = x }
    if x > hi { hi = x }
    if ax >= 1.0 { clipped += 1 }
    sum += x
    sq += x * x
    if i > 0 && ((xs[i - 1] < 0.0 && x >= 0.0) || (xs[i - 1] >= 0.0 && x < 0.0)) { zc += 1 }
  }
  let n = if xs.len() == 0 { 1.0 } else { float(xs.len()) }
  let rms = sqrt(sq / n)
  Stats {
    peak,
    peak_db: audio.fx.db(peak),
    rms,
    rms_db: audio.fx.db(rms),
    dc: sum / n,
    min: lo,
    max: hi,
    crest: if rms > 0.0 { peak / rms } else { 0.0 },
    clipped,
    zero_crossings: zc,
  }
}

// ---- loudness (BS.1770-4, as libebur128) ----

/// Loudness in LUFS and loudness range in LU. Integrated is -70 or lower for (near) silence.
pub struct Loudness {
  integrated: float,
  range: float,
  momentary_max: float,   // the loudest 400 ms block
  short_term_max: float,  // the loudest 3 s window
  true_peak_db: float,    // dBTP, 4x oversampled
}

// The two K-weighting stages (a high shelf, then a high pass) for this sample rate.
fn kweight(xs: [float], rate: int): [float] {
  let r = float(rate)
  var f0 = 1681.974450955533
  let g = 3.999843853973347
  var q = 0.7071752369554196
  var k = tan(float.pi * f0 / r)
  let vh = 10.0 ** (g / 20.0)
  let vb = vh ** 0.4996667741545416
  let a0 = 1.0 + k / q + k * k
  let shelf = audio.fx.Biquad {
    b0: (vh + vb * k / q + k * k) / a0,
    b1: 2.0 * (k * k - vh) / a0,
    b2: (vh - vb * k / q + k * k) / a0,
    a1: 2.0 * (k * k - 1.0) / a0,
    a2: (1.0 - k / q + k * k) / a0,
  }
  f0 = 38.13547087602444
  q = 0.5003270373238773
  k = tan(float.pi * f0 / r)
  let d = 1.0 + k / q + k * k
  let hp = audio.fx.Biquad {
    b0: 1.0,
    b1: -2.0,
    b2: 1.0,
    a1: 2.0 * (k * k - 1.0) / d,
    a2: (1.0 - k / q + k * k) / d,
  }
  audio.fx.biquad(audio.fx.biquad(xs, shelf), hp)
}

// Channel weights: 1 for front channels, 1.41 for surrounds, 0 for LFE (5.1 order L R C LFE Ls Rs).
fn weight(c: int, nch: int): float {
  if nch >= 6 && c == 3 { return 0.0 }
  if nch >= 5 && c >= 4 { return 1.41 }
  1.0
}

fn lufs(power: float): float = if power <= 0.0 { -1000.0 } else { -0.691 + 10.0 * log10(power) }

// The weighted mean-square power of each window of `len` samples, every `step` samples.
fn blocks(ks: [[float]], len: int, step: int): [float] {
  let nch = ks.len()
  let n = ks[0].len()
  // running sums of squares per channel
  var cums: [[float]] = []
  for c in 0..nch {
    var cum = [0.0]
    var s = 0.0
    for x in ks[c] {
      s += x * x
      cum.push(s)
    }
    cums.push(cum)
  }
  var out: [float] = []
  var start = 0
  while start + len <= n {
    var p = 0.0
    for c in 0..nch { p += weight(c, nch) * (cums[c][start + len] - cums[c][start]) / float(len) }
    out.push(p)
    start += step
  }
  out
}

fn gated_mean(ps: [float], gate: float): float {
  let kept = ps.filter(p => lufs(p) > gate)
  if kept.len() == 0 { 0.0 } else { kept.sum() / float(kept.len()) }
}

pub fn loudness(chans: [[float]], rate: int): Loudness {
  let ks = chans.map(ch => kweight(ch, rate))
  let ms = blocks(ks, int(0.4 * float(rate)), int(0.1 * float(rate)))
  let st = blocks(ks, 3 * rate, rate / 10)
  // integrated: absolute gate at -70 LUFS, then a relative gate 10 LU below
  let abs_ps = ms.filter(p => lufs(p) > -70.0)
  let rel = lufs(if abs_ps.len() == 0 { 0.0 } else { abs_ps.sum() / float(abs_ps.len()) }) - 10.0
  let integrated = lufs(gated_mean(abs_ps, rel))
  // range: short-term loudness, gated at -70 and 20 LU below, 10th to 95th percentile
  let st_abs = st.filter(p => lufs(p) > -70.0)
  let st_rel = lufs(if st_abs.len() == 0 { 0.0 } else { st_abs.sum() / float(st_abs.len()) }) - 20.0
  let lv = st_abs.filter(p => lufs(p) > st_rel).map(p => lufs(p)).sort()
  let range = if lv.len() < 2 {
    0.0
  } else {
    lv[int(round(float(lv.len() - 1) * 0.95))] - lv[int(round(float(lv.len() - 1) * 0.10))]
  }
  Loudness {
    integrated: if integrated < -70.0 { -70.0 } else { integrated },
    range,
    momentary_max: lufs(ms.max() else 0.0),
    short_term_max: lufs(st.max() else 0.0),
    true_peak_db: audio.fx.db(true_peak(chans, rate)),
  }
}

/// The largest |sample| after 4x oversampling (BS.1770 true peak; the interpolator has 12 taps
/// per phase, like the standard's 48-tap reference filter).
pub fn true_peak(chans: [[float]], rate: int): float {
  var peak = 0.0
  for ch in chans {
    for x in audio.resample.resample_with(ch, rate, rate * 4, 6) {
      if abs(x) > peak { peak = abs(x) }
    }
    // the oversampled peak can't be below the sample peak
    for x in ch { if abs(x) > peak { peak = abs(x) } }
  }
  peak
}

// ---- FFT ----

/// An in-place radix-2 FFT of (re, im); the length must be a power of two. `inverse` scales
/// by 1/n.
pub fn fft(re: var [float], im: var [float], inverse: bool) {
  let n = re.len()
  // bit reversal
  var j = 0
  for i in 1..n {
    var bit = n >> 1
    while (j & bit) != 0 {
      j = j ^ bit
      bit = bit >> 1
    }
    j = j | bit
    if i < j {
      let tr = re[i]
      re[i] = re[j]
      re[j] = tr
      let ti = im[i]
      im[i] = im[j]
      im[j] = ti
    }
  }
  var len = 2
  let sign = if inverse { 1.0 } else { -1.0 }
  while len <= n {
    let ang = sign * 2.0 * float.pi / float(len)
    let wr = cos(ang)
    let wi = sin(ang)
    var i = 0
    while i < n {
      var cr = 1.0
      var ci = 0.0
      for k in 0..len / 2 {
        let a = i + k
        let b = a + len / 2
        let xr = re[b] * cr - im[b] * ci
        let xi = re[b] * ci + im[b] * cr
        re[b] = re[a] - xr
        im[b] = im[a] - xi
        re[a] = re[a] + xr
        im[a] = im[a] + xi
        let t = cr * wr - ci * wi
        ci = cr * wi + ci * wr
        cr = t
      }
      i += len
    }
    len = len << 1
  }
  if inverse {
    for k in 0..n {
      re[k] = re[k] / float(n)
      im[k] = im[k] / float(n)
    }
  }
}

pub fn pow2(n: int): int {
  var p = 1
  while p < n { p = p << 1 }
  p
}

/// The average magnitude spectrum of `xs` in dBFS: `size / 2 + 1` bins from 0 Hz to Nyquist, from
/// Hann-windowed frames of `size` (a power of two) with 50% overlap. A full-scale sine reads
/// about 0 dB at its bin.
pub fn spectrum(xs: [float], size: int): [float] {
  let n = pow2(size)
  let win = (0..n).map(i => 0.5 - 0.5 * cos(2.0 * float.pi * float(i) / float(n)))
  let wsum = win.sum()
  var acc = audio.pcm.zeros(n / 2 + 1)
  var frames = 0
  var start = 0
  loop {
    var re: [float] = []
    var im: [float] = []
    for i in 0..n {
      re.push((xs.get(start + i) else 0.0) * win[i])
      im.push(0.0)
    }
    fft(&re, &im, false)
    for k in 0..n / 2 + 1 {
      acc[k] = acc[k] + sqrt(re[k] * re[k] + im[k] * im[k])
    }
    frames += 1
    start += n / 2
    if start + n > xs.len() { break }
  }
  // a sine of amplitude A puts A * wsum / 2 in its bin
  acc.map(m => audio.fx.db(2.0 * m / float(frames) / wsum))
}

/// The frequency (Hz) of the strongest spectral peak, refined by parabolic interpolation.
pub fn dominant(xs: [float], rate: int): float {
  let n = pow2(if xs.len() < 8192 { xs.len() } else { 8192 })
  if n < 4 { return 0.0 }
  let s = spectrum(xs, n)
  var k = 1
  for i in 1..s.len() - 1 { if s[i] > s[k] { k = i } }
  let (a, b, c) = (s[k - 1], s[k], s[(k + 1) % s.len()])
  let den = a - 2.0 * b + c
  let off = if k + 1 < s.len() && den != 0.0 { 0.5 * (a - c) / den } else { 0.0 }
  (float(k) + off) * float(rate) / float(n)
}

// ---- silence ----

/// Spans (start, end) in seconds where every channel stays below `threshold_db` for at least
/// `min_secs` (ffmpeg's silencedetect).
pub fn silences(
  chans: [[float]],
  rate: int,
  threshold_db: float,
  min_secs: float,
): [(float, float)] {
  let lim = audio.fx.undb(threshold_db)
  let n = chans[0].len()
  let need = audio.fx.samples(min_secs, rate)
  var out: [(float, float)] = []
  var start = -1
  for i in 0..n + 1 {
    let quiet = i < n && chans.all(ch => abs(ch[i]) < lim)
    if quiet {
      if start < 0 { start = i }
    } else if start >= 0 {
      if i - start >= need && i - start > 0 {
        out.push((float(start) / float(rate), float(i) / float(rate)))
      }
      start = -1
    }
  }
  out
}

/// The first and one-past-last frame where some channel reaches `threshold_db`, or none if
/// the audio is silent throughout.
pub fn sound_bounds(chans: [[float]], threshold_db: float): (int, int)? {
  let lim = audio.fx.undb(threshold_db)
  let n = chans[0].len()
  let loud = (i: int) => chans.any(ch => abs(ch[i]) >= lim)
  var a = 0
  while a < n && !loud(a) { a += 1 }
  if a == n { return none }
  var b = n
  while b > a && !loud(b - 1) { b -= 1 }
  some((a, b))
}
