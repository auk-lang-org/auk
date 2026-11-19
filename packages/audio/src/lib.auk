/// Audio in pure Auk, at the level of ffmpeg's audio side: decode and encode WAV, AIFF/AIFC,
/// AU and FLAC (with PCM, float, G.711 and ADPCM codecs), probe files, resample, remix
/// channels, filter (biquads, EQ, echo, dynamics, fades, time stretch), measure (stats, EBU R128
/// loudness, true peak, spectra, silence) and generate signals. Filter graphs use ffmpeg's `-af`
/// syntax: `a.apply("highpass=f=80,loudnorm=I=-16")`.
///
/// Pure: no effects. Bytes are `[int]` (0–255) as in `fs.read_bytes`. Samples are planar floats,
/// nominally -1.0..1.0; integer formats clip outside that when encoded.

/// Decoded audio: `chans[c][i]` is frame `i` of channel `c`; every channel has the same length.
/// `tags` holds metadata with lowercase keys (`title`, `artist`, `album`, `comment`, ...).
pub struct Audio { rate: int, chans: [[float]], tags: {str: str} }

/// Why decoding, encoding or a filter graph failed.
pub enum AErr {
  Truncated(what: str),    // the input ended early
  Unsupported(what: str),  // a valid file in a format or codec this library doesn't handle
  Corrupt(why: str),       // malformed data
  BadArg(why: str),        // an invalid argument or filter graph
}

/// A one-line description, e.g. `unsupported: MP3`.
pub fn message(e: AErr): str
fn message(Truncated(what)): str = "truncated: {what}"
fn message(Unsupported(what)): str = "unsupported: {what}"
fn message(Corrupt(why)): str = "corrupt: {why}"
fn message(BadArg(why)): str = "bad argument: {why}"

/// Sample formats. `Ima` is 4-bit IMA ADPCM (WAV only).
pub enum Fmt { U8, S8, S16, S24, S32, F32, F64, Alaw, Ulaw, Ima }

/// File formats this library writes.
pub enum Container { Wav, Aiff, Au, Flac }

/// What `probe` finds without decoding the samples.
pub struct Info {
  container: str,  // "wav", "aiff", "aifc", "au" or "flac"
  codec: str,      // ffmpeg's codec name: "pcm_s16le", "pcm_f32be", "adpcm_ima_wav", "flac", ...
  rate: int,
  channels: int,
  frames: int,  // per channel (0 when a FLAC stream doesn't say)
  bits: int,    // bits per sample
  tags: {str: str},
}

pub fn duration(i: Info): float = if i.rate > 0 { float(i.frames) / float(i.rate) } else { 0.0 }

/// ffmpeg's name for a sample format's codec: `codec_name(S16, false) == "pcm_s16le"`.
pub fn codec_name(f: Fmt, big: bool): str {
  let e = if big { "be" } else { "le" }
  match f {
    U8 => "pcm_u8"
    S8 => "pcm_s8"
    S16 => "pcm_s16{e}"
    S24 => "pcm_s24{e}"
    S32 => "pcm_s32{e}"
    F32 => "pcm_f32{e}"
    F64 => "pcm_f64{e}"
    Alaw => "pcm_alaw"
    Ulaw => "pcm_mulaw"
    Ima => "adpcm_ima_wav"
  }
}

/// A sample format by ffmpeg's `-sample_fmt` or codec name: `u8 s16 s24 s32 flt dbl`, `f32`,
/// `pcm_s24le`, `alaw`, `mulaw`/`ulaw`, `ima`/`adpcm_ima_wav`.
pub fn fmt_named(s: str): Fmt? {
  let t = s.lower()
  let base = if t.starts_with("pcm_") { t[4..t.len()] } else { t }
  let core = if base.ends_with("le") || base.ends_with("be") {
    base[0..base.len() - 2]
  } else {
    base
  }
  match core {
    "u8" => some(U8)
    "s8" => some(S8)
    "s16" => some(S16)
    "s16p" => some(S16)
    "s24" => some(S24)
    "s32" => some(S32)
    "s32p" => some(S32)
    "flt" => some(F32)
    "fltp" => some(F32)
    "f32" => some(F32)
    "dbl" => some(F64)
    "dblp" => some(F64)
    "f64" => some(F64)
    "alaw" => some(Alaw)
    "mulaw" => some(Ulaw)
    "ulaw" => some(Ulaw)
    "ima" => some(Ima)
    "adpcm_ima_wav" => some(Ima)
    _ => none
  }
}

/// The container for a file name's extension: `.wav`, `.aif`/`.aiff`/`.aifc`, `.au`/`.snd`,
/// `.flac`.
pub fn container_for(path: str): Container? {
  let p = path.lower()
  if p.ends_with(".wav") || p.ends_with(".wave") {
    some(Wav)
  } else if p.ends_with(".aif") || p.ends_with(".aiff") || p.ends_with(".aifc") {
    some(Aiff)
  } else if p.ends_with(".au") || p.ends_with(".snd") {
    some(Au)
  } else if p.ends_with(".flac") {
    some(Flac)
  } else {
    none
  }
}

// ---- reading and writing ----

// What the first bytes say the file is.
fn sniff(d: [int]): str {
  let t = audio.pcm.tag(d, 0)
  if (t == "RIFF" || t == "RF64") && audio.pcm.tag(d, 8) == "WAVE" { return "wav" }
  if t == "FORM" && (audio.pcm.tag(d, 8) == "AIFF" || audio.pcm.tag(d, 8) == "AIFC") {
    return "aiff"
  }
  if t == ".snd" { return "au" }
  let skip = audio.flac.id3_offset(d)
  if audio.pcm.tag(d, skip) == "fLaC" { return "flac" }
  if t == "OggS" { return "Ogg" }
  if t.starts_with("ID3") || (d.len() >= 2 && d[0] == 0xff && (d[1] & 0xe0) == 0xe0) {
    return "MP3"
  }
  if d.len() >= 8 && audio.pcm.tag(d, 4) == "ftyp" { return "MP4/M4A" }
  if d.len() >= 4 && d[0] == 0x1a && d[1] == 0x45 && d[2] == 0xdf && d[3] == 0xa3 {
    return "Matroska/WebM"
  }
  ""
}

/// Header information: format, codec, rate, channels, length and tags.
pub fn probe(d: [int]): Info!AErr = match sniff(d) {
  "wav" => audio.wav.probe(d)
  "aiff" => audio.aiff.probe(d)
  "au" => audio.aiff.au_probe(d)
  "flac" => audio.flac.probe(d)
  "" => fail(Unsupported("unknown file format"))
  other => fail(Unsupported(other))
}

/// Decodes a WAV, AIFF/AIFC, AU or FLAC file, recognized by its contents.
pub fn decode(d: [int]): Audio!AErr = match sniff(d) {
  "wav" => audio.wav.decode(d)
  "aiff" => audio.aiff.decode(d)
  "au" => audio.aiff.au_decode(d)
  "flac" => audio.flac.decode(d)
  "" => fail(Unsupported("unknown file format"))
  other => fail(Unsupported(other))
}

/// Encodes as a complete file. FLAC takes U8/S8 (stored as 8-bit), S16 or S24; WAV anything but
/// S8; AIFF the signed and float formats and G.711; AU the same.
pub fn encode(a: Audio, c: Container, f: Fmt): [int]!AErr {
  valid(a)?
  match c {
    Wav => audio.wav.encode(a, f)
    Aiff => audio.aiff.encode(a, f)
    Au => audio.aiff.au_encode(a, f)
    Flac => match f {
      U8 => audio.flac.encode(a, 8)
      S8 => audio.flac.encode(a, 8)
      S16 => audio.flac.encode(a, 16)
      S24 => audio.flac.encode(a, 24)
      _ => fail(Unsupported("FLAC with {codec_name(f, false)} samples; use S16 or S24"))
    }
  }
}

fn valid(a: Audio): ()!AErr {
  if a.chans.len() == 0 { fail(BadArg("audio has no channels")) }
  if a.rate < 1 { fail(BadArg("sample rate {a.rate}")) }
  let n = a.chans[0].len()
  if a.chans.any(ch => ch.len() != n) { fail(BadArg("channels have different lengths")) }
}

// ---- making audio ----

/// Audio from planar samples, with no tags.
pub fn new(rate: int, chans: [[float]]): Audio = Audio { rate, chans, tags: {} }

/// `secs` of silence.
pub fn silence(secs: float, rate: int, nch: int): Audio
  requires nch >= 1
{
  let n = audio.fx.samples(secs, rate)
  new(rate, (0..nch).map(_ => audio.pcm.zeros(n)))
}

/// A mono sine wave.
pub fn sine(freq: float, secs: float, rate: int): Audio =
  tone(audio.gen.Sine, freq, secs, rate, 1.0)

/// A mono periodic wave at amplitude `amp`.
pub fn tone(w: audio.gen.Wave, freq: float, secs: float, rate: int, amp: float): Audio =
  new(rate, [audio.gen.wave(w, freq, amp, audio.fx.samples(secs, rate), rate)])

/// A mono sine sweep from `f0` to `f1` Hz (exponential when `log`).
pub fn chirp(f0: float, f1: float, secs: float, rate: int, log: bool): Audio =
  new(rate, [audio.gen.chirp(f0, f1, 1.0, audio.fx.samples(secs, rate), rate, log)])

/// Mono noise; the same seed gives the same samples.
pub fn noise(c: audio.gen.Color, secs: float, rate: int, amp: float, seed: int): Audio =
  new(rate, [audio.gen.noise(c, amp, audio.fx.samples(secs, rate), seed)])

/// A source in ffmpeg's lavfi syntax: `sine=frequency=440:duration=2`,
/// `anoisesrc=color=pink:d=5:a=0.3:seed=7`, `anullsrc=r=48000:cl=stereo:d=1`, plus
/// `square`, `sawtooth`, `triangle` (like `sine`) and `chirp=f0=20:f1=20000:d=5`.
pub fn source(spec: str): Audio!AErr = audio.graph.source(spec)

// ---- basic facts ----

pub fn frames(a: Audio): int = if a.chans.len() == 0 { 0 } else { a.chans[0].len() }
pub fn nch(a: Audio): int = a.chans.len()
pub fn duration(a: Audio): float = float(a.frames()) / float(a.rate)

// Applies `f` to each channel.
fn each(a: Audio, f: ([float]) => [float]): Audio = Audio { chans: a.chans.map(f), ..a }

// ---- levels ----

pub fn db_to_gain(db: float): float = audio.fx.undb(db)
pub fn gain_to_db(g: float): float = audio.fx.db(g)

/// Every sample times `g`.
pub fn gain(a: Audio, g: float): Audio = a.each(ch => ch.map(x => x * g))

/// Louder or quieter by `db` decibels.
pub fn gain_db(a: Audio, db: float): Audio = a.gain(audio.fx.undb(db))

/// Scaled so the peak sample is at `peak_db` dBFS (silence stays silent).
pub fn normalize(a: Audio, peak_db: float): Audio {
  let p = a.chans.map(ch => audio.analyze.stats(ch).peak).max() else 0.0
  if p <= 0.0 { a } else { a.gain(audio.fx.undb(peak_db) / p) }
}

/// Scaled to `lufs` integrated loudness (EBU R128), then limited so the true peak stays under
/// `tp_db` dBTP: ffmpeg's `loudnorm` in linear mode.
pub fn loudnorm(a: Audio, lufs: float, tp_db: float): Audio {
  let l = a.loudness()
  if l.integrated <= -70.0 { return a }
  let g = a.gain_db(lufs - l.integrated)
  // the limiter works on samples; leave room for inter-sample peaks
  let tp = audio.analyze.true_peak(g.chans, g.rate)
  if audio.fx.db(tp) <= tp_db { g } else { g.limit(tp_db - 0.3, 0.005, 0.05) }
}

/// Clamps every sample to -1.0..1.0.
pub fn clip(a: Audio): Audio =
  a.each(ch => ch.map(x => if x > 1.0 { 1.0 } else if x < -1.0 { -1.0 } else { x }))

/// Adds `d` to every sample.
pub fn dc_shift(a: Audio, d: float): Audio = a.each(ch => ch.map(x => x + d))

// ---- time ----

fn at(a: Audio, secs: float): int {
  let i = audio.fx.samples(secs, a.rate)
  if i > a.frames() { a.frames() } else { i }
}

/// The part from `start` to `end` seconds (`end` < 0: to the end).
pub fn trim(a: Audio, start: float, end: float): Audio {
  let s = a.at(start)
  let e = if end < 0.0 { a.frames() } else { a.at(end) }
  if e <= s { a.each(_ => []) } else { a.each(ch => ch[s..e]) }
}

/// `secs` of silence added at the end.
pub fn pad(a: Audio, secs: float): Audio {
  let z = audio.pcm.zeros(audio.fx.samples(secs, a.rate))
  a.each(ch => ch + z)
}

/// `secs` of silence added at the start.
pub fn delay(a: Audio, secs: float): Audio = a.each(ch => audio.fx.delay(ch, secs, a.rate))

/// Each channel delayed by its own amount (ffmpeg's adelay); missing entries are 0.
pub fn delay_each(a: Audio, secs: [float]): Audio {
  let ds = (0..a.nch()).map(c => audio.fx.samples(secs.get(c) else 0.0, a.rate))
  let longest = ds.max() else 0
  Audio {
    chans: (0..a.nch()).map(
      c => audio.pcm.zeros(ds[c]) + a.chans[c] + audio.pcm.zeros(longest - ds[c]),
    ),
    ..a,
  }
}

pub fn reverse(a: Audio): Audio = a.each(ch => ch.reverse())

/// Fades in over the first `secs`.
pub fn fade_in(a: Audio, secs: float): Audio = a.fade(true, 0.0, secs, audio.fx.Linear)

/// Fades out over the last `secs`.
pub fn fade_out(a: Audio, secs: float): Audio =
  a.fade(false, a.duration() - secs, secs, audio.fx.Linear)

/// A fade (in or out) starting at `start` seconds and lasting `secs`, with curve `c`
/// (ffmpeg's afade).
pub fn fade(a: Audio, fade_in: bool, start: float, secs: float, c: audio.fx.Curve): Audio {
  let s = audio.fx.samples(start, a.rate)
  let n = audio.fx.samples(secs, a.rate)
  a.each(ch => audio.fx.fade(ch, fade_in, s, n, c))
}

/// Joins clips end to end. They must share a rate and channel count.
pub fn concat(xs: [Audio]): Audio!AErr {
  let [first, ..rest] = xs else fail(BadArg("concat of nothing"))
  var chans = first.chans
  for x in rest {
    if x.rate != first.rate || x.nch() != first.nch() {
      fail(
        BadArg("concat needs the same rate and channels: {first.rate} Hz x{first.nch()} vs {x.rate} Hz x{x.nch()}"),
      )
    }
    for c in 0..chans.len() {
      for v in x.chans[c] { chans[c].push(v) }
    }
  }
  Audio { chans, ..first }
}

/// `b` added onto `a` starting at `at` seconds; the result is as long as both need. They must
/// share a rate and channel count.
pub fn overlay(a: Audio, b: Audio, at: float): Audio!AErr {
  if a.rate != b.rate || a.nch() != b.nch() {
    fail(
      BadArg("overlay needs the same rate and channels: {a.rate} Hz x{a.nch()} vs {b.rate} Hz x{b.nch()}"),
    )
  }
  let off = audio.fx.samples(at, a.rate)
  let n = if off + b.frames() > a.frames() { off + b.frames() } else { a.frames() }
  var chans = a.chans.map(ch => ch + audio.pcm.zeros(n - ch.len()))
  for c in 0..chans.len() {
    for i in 0..b.frames() { chans[c][off + i] = chans[c][off + i] + b.chans[c][i] }
  }
  Audio { chans, ..a }
}

/// The sum of several clips, each scaled by 1/n so it can't clip more than the loudest input
/// (ffmpeg's amix); converts rates and channel counts to the first clip's.
pub fn mix(xs: [Audio]): Audio!AErr {
  let [first, ..] = xs else fail(BadArg("mix of nothing"))
  var out = first.gain(1.0 / float(xs.len()))
  for x in xs.skip(1) {
    let y = x.resample(first.rate).remix(first.nch()).gain(1.0 / float(xs.len()))
    out = out.overlay(y, 0.0)?
  }
  out
}

/// Plays faster (`factor` > 1) or slower without changing pitch (ffmpeg's atempo), by WSOLA
/// with 40 ms frames.
pub fn tempo(a: Audio, factor: float): Audio
  requires factor > 0.0
{
  if factor == 1.0 || a.frames() == 0 { return a }
  // 40 ms frames (an even number of samples), aligned within +-12 ms
  let win = 2 * (audio.fx.samples(0.02, a.rate) + 1)
  let guide = a.mono().chans[0]
  let starts = audio.fx.wsola_plan(guide, factor, win, audio.fx.samples(0.012, a.rate))
  let len = int(round(float(a.frames()) / factor))
  a.each(ch => audio.fx.wsola_apply(ch, starts, win, len))
}

/// Shifts the pitch by `semitones` keeping the duration: resample, then stretch back.
pub fn pitch(a: Audio, semitones: float): Audio {
  if semitones == 0.0 { return a }
  let ratio = 2.0 ** (semitones / 12.0)
  // play `ratio` times faster (higher), then stretch back to the original length
  let fast = Audio { rate: int(round(float(a.rate) * ratio)), ..a }.resample(a.rate)
  fast.tempo(1.0 / ratio)
}

/// The same samples labelled with a new rate: faster and higher, or slower and lower
/// (ffmpeg's asetrate).
pub fn set_rate(a: Audio, rate: int): Audio
  requires rate > 0
{ Audio { rate, ..a } }

/// Converts to `rate` Hz (band-limited sinc interpolation).
pub fn resample(a: Audio, rate: int): Audio
  requires rate > 0
{
  if rate == a.rate { return a }
  Audio { rate, chans: a.chans.map(ch => audio.resample.resample(ch, a.rate, rate)), ..a }
}

// ---- channels ----

/// The mean of all channels, as one.
pub fn mono(a: Audio): Audio {
  if a.nch() == 1 { return a }
  a.pan([(0..a.nch()).map(_ => 1.0 / float(a.nch()))])
}

/// Mixes channels by a matrix: output channel `o` is the sum of `m[o][i] * input i` (ffmpeg's
/// pan filter).
pub fn pan(a: Audio, m: [[float]]): Audio {
  let n = a.frames()
  let chans = m.map(row => {
    var out = audio.pcm.zeros(n)
    for i in 0..row.len() {
      let g = row[i]
      if g != 0.0 && i < a.nch() {
        let ch = a.chans[i]
        for k in 0..n { out[k] = out[k] + g * ch[k] }
      }
    }
    out
  })
  Audio { chans, ..a }
}

/// Converts to `n` channels: mono is copied to the front left and right, stereo to mono is the
/// mean (ffmpeg uses 0.707 per channel, which can clip), 5.1 and quad fold down to stereo with
/// -3 dB centre and surrounds (normalized so no output can clip); otherwise channels are dropped
/// or silent ones added.
pub fn remix(a: Audio, n: int): Audio
  requires n >= 1
{
  let k = a.nch()
  if n == k { return a }
  let h = 0.7071067811865476
  if k == 1 { return a.pan((0..n).map(o => if o < 2 || n == 1 { [1.0] } else { [0.0] })) }
  if n == 1 && k == 2 { return a.mono() }
  if n == 2 && (k == 6 || k == 5) {
    // L R C LFE Ls Rs (or L R C Ls Rs)
    let s = if k == 6 { 4 } else { 3 }
    var l = audio.pcm.zeros(k)
    var r = audio.pcm.zeros(k)
    l[0] = 1.0
    l[2] = h
    l[s] = h
    r[1] = 1.0
    r[2] = h
    r[s + 1] = h
    let norm = 1.0 / (1.0 + 2.0 * h)
    return a.pan([l.map(g => g * norm), r.map(g => g * norm)])
  }
  if n == 2 && k == 4 {
    let norm = 1.0 / (1.0 + h)
    return a.pan([[norm, 0.0, h * norm, 0.0], [0.0, norm, 0.0, h * norm]])
  }
  if n == 1 { return a.remix(2).mono() }
  a.pan((0..n).map(o => (0..k).map(i => if i == o { 1.0 } else { 0.0 })))
}

/// Channel `c` alone, as mono.
pub fn channel(a: Audio, c: int): Audio
  requires c >= 0 && c < a.nch()
{ Audio { chans: [a.chans[c]], ..a } }

/// Widens (`m` > 1) or narrows (`m` < 1) a stereo image around its mid (ffmpeg's extrastereo).
pub fn widen(a: Audio, m: float): Audio {
  if a.nch() != 2 { return a }
  let n = a.frames()
  var l = a.chans[0]
  var r = a.chans[1]
  for i in 0..n {
    let mid = (a.chans[0][i] + a.chans[1][i]) / 2.0
    l[i] = mid + m * (a.chans[0][i] - mid)
    r[i] = mid + m * (a.chans[1][i] - mid)
  }
  Audio { chans: [l, r], ..a }
}

// ---- filters ----

/// Any RBJ biquad on every channel.
pub fn biquad(a: Audio, kind: audio.fx.Kind, freq: float, q: float, gain_db: float): Audio {
  let f = audio.fx.design(kind, freq, q, gain_db, a.rate)
  a.each(ch => audio.fx.biquad(ch, f))
}

/// Two-pole low-pass at `freq` Hz (Butterworth, Q 0.707).
pub fn lowpass(a: Audio, freq: float): Audio =
  a.biquad(audio.fx.Lowpass, freq, 0.7071067811865476, 0.0)

/// Two-pole high-pass at `freq` Hz (Butterworth, Q 0.707).
pub fn highpass(a: Audio, freq: float): Audio =
  a.biquad(audio.fx.Highpass, freq, 0.7071067811865476, 0.0)

/// Band-pass around `freq` Hz (constant 0 dB peak gain).
pub fn bandpass(a: Audio, freq: float, q: float): Audio = a.biquad(audio.fx.Bandpass, freq, q, 0.0)

/// Removes a narrow band around `freq` Hz (mains hum: `notch(50.0, 10.0)`).
pub fn notch(a: Audio, freq: float, q: float): Audio = a.biquad(audio.fx.Notch, freq, q, 0.0)

/// A peaking EQ band: `gain_db` at `freq` Hz, width set by `q`.
pub fn eq(a: Audio, freq: float, q: float, gain_db: float): Audio =
  a.biquad(audio.fx.Peak, freq, q, gain_db)

/// Boosts or cuts below `freq` Hz (ffmpeg's bass/lowshelf).
pub fn bass(a: Audio, gain_db: float, freq: float): Audio =
  a.biquad(audio.fx.LowShelf, freq, 0.7071067811865476, gain_db)

/// Boosts or cuts above `freq` Hz (ffmpeg's treble/highshelf).
pub fn treble(a: Audio, gain_db: float, freq: float): Audio =
  a.biquad(audio.fx.HighShelf, freq, 0.7071067811865476, gain_db)

/// ffmpeg's aecho: delays in seconds, each with its decay; `in_gain` and `out_gain` scale the
/// dry signal and the sum. The result is longer by the longest delay.
pub fn echo(a: Audio, in_gain: float, out_gain: float, delays: [float], decays: [float]): Audio
  requires delays.len() == decays.len()
{ a.each(ch => audio.fx.echo(ch, a.rate, in_gain, out_gain, delays, decays)) }

/// Amplitude modulation at `freq` Hz; `depth` 0..1 (ffmpeg's tremolo).
pub fn tremolo(a: Audio, freq: float, depth: float): Audio {
  let n = a.frames()
  let g = (0..n).map(
    i => 1.0 - depth / 2.0 + depth / 2.0 * cos(2.0 * float.pi * freq * float(i) / float(a.rate)),
  )
  a.each(ch => (0..ch.len()).map(i => ch[i] * g[i]))
}

// ---- dynamics ----

// The mean |sample| over channels at each frame, as ffmpeg's link=average (channels share one
// gain, so the stereo image holds).
fn detector_avg(a: Audio): [float] {
  let n = a.frames()
  var d = audio.pcm.zeros(n)
  for ch in a.chans {
    for i in 0..n { d[i] = d[i] + abs(ch[i]) / float(a.nch()) }
  }
  d
}

// The loudest channel's |sample| at each frame.
fn detector(a: Audio): [float] {
  let n = a.frames()
  var d = audio.pcm.zeros(n)
  for ch in a.chans {
    for i in 0..n { if abs(ch[i]) > d[i] { d[i] = abs(ch[i]) } }
  }
  d
}

fn apply_gains(a: Audio, g: [float]): Audio = a.each(ch => (0..ch.len()).map(i => ch[i] * g[i]))

/// Settings for `compress`: levels in dB, times in seconds.
pub struct Comp {
  threshold: float,  // where reduction starts
  ratio: float,      // 4.0 = 4 dB over the threshold comes out as 1 dB over
  knee: float,       // soft knee width
  attack: float,
  release: float,
  makeup: float,  // gain added after
  rms: bool,      // detect RMS level (true) or peaks
}

/// ffmpeg's acompressor defaults: threshold -18 dB, ratio 2, knee 9 dB, attack 20 ms,
/// release 250 ms, no makeup, RMS detection.
pub let COMP = Comp {
  threshold: -18.0,
  ratio: 2.0,
  knee: 9.0,
  attack: 0.02,
  release: 0.25,
  makeup: 0.0,
  rms: true,
}

/// A feed-forward compressor, with one gain for all channels.
pub fn compress(a: Audio, c: Comp): Audio
  requires c.ratio >= 1.0
{
  a.apply_gains(
    audio.fx.compress_gains(
      a.detector_avg(),
      a.rate,
      c.threshold,
      c.ratio,
      c.knee,
      c.attack,
      c.release,
      c.makeup,
      c.rms,
    ),
  )
}

/// A lookahead brickwall limiter: no sample exceeds `ceiling_db` dBFS. The gain ramps down over
/// `attack` seconds before a peak and recovers over `release` after.
pub fn limit(a: Audio, ceiling_db: float, attack: float, release: float): Audio = a.apply_gains(
  audio.fx.limit_gains(a.detector(), a.rate, audio.fx.undb(ceiling_db), attack, release),
)

/// A noise gate (ffmpeg's agate with its defaults: RMS detection, a 9 dB soft knee): below
/// `threshold_db` the level is pushed down by `ratio`, by at most `range_db` dB.
pub fn gate(
  a: Audio,
  threshold_db: float,
  ratio: float,
  range_db: float,
  attack: float,
  release: float,
): Audio
  requires ratio >= 1.0
{
  let g = audio.fx.gate_gains(
    a.detector_avg(),
    a.rate,
    audio.fx.undb(threshold_db),
    ratio,
    2.828427125,
    audio.fx.undb(-abs(range_db)),
    attack,
    release,
    true,
  )
  a.apply_gains(g)
}

// ---- measuring ----

/// Per-channel statistics (ffmpeg's astats and volumedetect).
pub fn stats(a: Audio): [audio.analyze.Stats] = a.chans.map(ch => audio.analyze.stats(ch))

/// The largest |sample| over all channels.
pub fn peak(a: Audio): float = a.chans.map(ch => audio.analyze.stats(ch).peak).max() else 0.0

/// EBU R128 loudness (integrated, range, maxima, true peak), as ffmpeg's ebur128 filter.
pub fn loudness(a: Audio): audio.analyze.Loudness = audio.analyze.loudness(a.chans, a.rate)

/// The magnitude spectrum of the mono mix, in dBFS, `size / 2 + 1` bins up to Nyquist.
pub fn spectrum(a: Audio, size: int): [float] = audio.analyze.spectrum(a.mono().chans[0], size)

/// The strongest frequency (Hz) in the mono mix.
pub fn dominant(a: Audio): float = audio.analyze.dominant(a.mono().chans[0], a.rate)

/// Silent spans, (start, end) in seconds: every channel below `threshold_db` for at least
/// `min_secs` (ffmpeg's silencedetect).
pub fn silences(a: Audio, threshold_db: float, min_secs: float): [(float, float)] =
  audio.analyze.silences(a.chans, a.rate, threshold_db, min_secs)

/// Leading and trailing silence (below `threshold_db` on every channel) removed.
pub fn trim_silence(a: Audio, threshold_db: float): Audio = match audio.analyze.sound_bounds(
  a.chans,
  threshold_db,
) {
  some((s, e)) => a.each(ch => ch[s..e])
  none => a.each(_ => [])
}

// ---- filter graphs ----

/// Runs a filter chain written as ffmpeg's `-af`: `volume=-3dB,highpass=f=80,aresample=48000`.
/// See the README for the filters and options supported.
pub fn apply(a: Audio, graph: str): Audio!AErr = audio.graph.apply(a, graph)

// ---- tests ----

fn unhex(h: str): [int] = h.chars().chunks(2).map(p => hexdigit(p[0]) * 16 + hexdigit(p[1]))

fn hexdigit(c: char): int = if c.is_digit() { int(c) - 48 } else { int(c) - 87 }

fn tohex(bs: [int]): str = bs.map(b => {
  let d = "0123456789abcdef"
  str([d[b >> 4], d[b & 15]])
}).join("")

// A stereo test signal: a sine and a sawtooth, 1000 frames at 8 kHz.
fn sig(): Audio = new(8000, [
  audio.gen.wave(audio.gen.Sine, 440.0, 0.5, 1000, 8000),
  audio.gen.wave(audio.gen.Sawtooth, 300.0, 0.4, 1000, 8000),
])

fn max_err(a: Audio, b: Audio): float {
  var m = 0.0
  for c in 0..a.nch() {
    for i in 0..a.frames() {
      m = if abs(a.chans[c][i] - b.chans[c][i]) > m {
        abs(a.chans[c][i] - b.chans[c][i])
      } else {
        m
      }
    }
  }
  m
}

// The signal as it reads back from `bits`-bit integers.
fn quantized(a: Audio, bits: int): Audio =
  a.each(ch => ch.map(x => float(audio.pcm.quant(x, bits)) / float(1 << (bits - 1))))

test "WAV round trips every format" {
  let a = sig()
  for (f, codec, tol) in [
    (U8, "pcm_u8", 0.004),
    (S16, "pcm_s16le", 0.00002),
    (S24, "pcm_s24le", 0.0000001),
    (S32, "pcm_s32le", 0.000000001),
    (F32, "pcm_f32le", 0.0000001),
    (F64, "pcm_f64le", 0.0),
    (Alaw, "pcm_alaw", 0.02),
    (Ulaw, "pcm_mulaw", 0.02),
    (Ima, "adpcm_ima_wav", 1.0),
  ] {
    let bs = encode(a, Wav, f)?
    let i = probe(bs)?
    assert (i.container, i.codec, i.rate, i.channels, i.frames) == ("wav", codec, 8000, 2, 1000)
    let b = decode(bs)?
    assert b.frames() == 1000
    assert max_err(a, b) <= tol
  }
  // ADPCM tracks a sine closely (it can't follow the sawtooth's jumps)
  let s = sine(440.0, 0.2, 8000).gain(0.5)
  assert max_err(s.trim(0.01, -1.0), (decode(encode(s, Wav, Ima)?)?).trim(0.01, -1.0)) < 0.03
}

test "AIFF and AU round trips" {
  let a = Audio { tags: {"title": "Raft", "artist": "Auk"}, ..sig() }
  for (c, f, name) in [
    (Aiff, S16, "pcm_s16be"),
    (Aiff, S8, "pcm_s8"),
    (Aiff, S24, "pcm_s24be"),
    (Aiff, F32, "pcm_f32be"),
    (Aiff, Ulaw, "pcm_mulaw"),
    (Au, S16, "pcm_s16be"),
    (Au, F64, "pcm_f64be"),
    (Au, Alaw, "pcm_alaw"),
  ] {
    let bs = encode(a, c, f)?
    assert (probe(bs)?).codec == name
    let b = decode(bs)?
    assert b.frames() == 1000 && b.rate == 8000
    assert max_err(a, b) < 0.02
  }
  assert (decode(encode(a, Aiff, S16)?)?).tags == {"title": "Raft", "artist": "Auk"}
  assert (decode(encode(a, Wav, S16)?)?).tags == {"title": "Raft", "artist": "Auk"}
  assert (probe(encode(a, Aiff, F64)?)?).container == "aifc"
}

test "FLAC round trips are lossless" {
  let a = sig()
  for bits in [8, 16, 24] {
    let q = quantized(a, bits)
    let fmt = if bits == 8 { S8 } else if bits == 16 { S16 } else { S24 }
    let b = decode(encode(q, Flac, fmt)?)?
    assert max_err(q, b) == 0.0
    assert (probe(encode(q, Flac, fmt)?)?).bits == bits
  }
  // edge cases: lengths around the block size, 1 to 8 channels, silence, noise, full scale
  let q = quantized(a, 16)
  for n in [0, 1, 15, 4095, 4097] {
    let x = new(8000, [(0..n).map(i => q.chans[0][i % 1000])])
    let y = decode(encode(x, Flac, S16)?)?
    assert y.frames() == n && max_err(x, y) == 0.0
  }
  for nch in [1, 3, 6, 8] {
    let x = new(48000, (0..nch).map(c => q.chans[c % 2].map(v => v * float(c + 1) / 8.0)))
    let x16 = quantized(x, 16)
    assert max_err(x16, decode(encode(x16, Flac, S16)?)?) == 0.0
  }
  let silent = silence(0.1, 8000, 2)
  assert max_err(silent, decode(encode(silent, Flac, S16)?)?) == 0.0
  assert (encode(silent, Flac, S16)?).len() < 200
  let hiss = quantized(noise(audio.gen.White, 0.5, 8000, 1.0, 7), 16)
  assert max_err(hiss, decode(encode(hiss, Flac, S16)?)?) == 0.0
  let loud = tone(audio.gen.Square, 100.0, 0.2, 8000, 1.5)
  let lq = quantized(loud, 16)
  assert max_err(lq, decode(encode(loud, Flac, S16)?)?) == 0.0
  // 8-bit samples in 16 bits: wasted bits
  let coarse = quantized(a, 8)
  assert (encode(coarse, Flac, S16)?).len() < (encode(q, Flac, S16)?).len() / 2 + 100
}

test "FLAC from libFLAC" {
  // `flac --blocksize=32` of 48 stereo frames: a sine and a ramp, at 8 kHz
  let f = unhex(
    "664c6143000000220020002000003700004201f402f00000003089597962fd24657f210a268c4fcc9cdb840000" +
      "28200000007265666572656e6365206c6962464c414320312e352e3020323032353032313100000000fff8641800" +
      "1f1c180000093c11a5187a0193179f9e9f9c141120c1feb2d2fefee2ce877e1ec466c7021101a16053f063f1e43" +
      "0c3c3c3c3ea000f3e3d04000f0f0689fff86418010f7918fa8ef1b4ea22e48301945cdedfdd5752e9c7dc94d424" +
      "00d00bb0984c26130984c29b0ac2016ed856158561584043a3",
  )
  let a = decode(f)?
  assert (a.rate, a.nch(), a.frames()) == (8000, 2, 48)
  let left = a.chans[0].map(x => int(round(x * 32768.0)))
  let right = a.chans[1].map(x => int(round(x * 32768.0)))
  assert left.take(6) == [0, 2364, 4517, 6266, 7456, 7979]
  assert left == (0..48).map(i => int(8000.0 * sin(float(i) * 0.3)))
  assert right == (0..48).map(i => (i * 97) % 2000 - 1000)
  assert (probe(f)?).tags == {}
  // a flipped bit fails a CRC
  var bad = f
  bad[150] = bad[150] ^ 4
  assert decode(bad) is err(Corrupt(_))
  assert decode(f.take(180)) is err(Truncated(_))
}

test "MD5 and G.711" {
  assert tohex(audio.flac.md5([])) == "d41d8cd98f00b204e9800998ecf8427e"
  assert tohex(audio.flac.md5("abc".bytes())) == "900150983cd24fb0d6963f7d28e17f72"
  let long =
    "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."
  assert tohex(audio.flac.md5(long.bytes())) == "f168d89e05b664041ee6745f050caa4b"
  assert (audio.pcm.alaw(0), audio.pcm.ulaw(0), audio.pcm.alaw(32767), audio.pcm.ulaw(32767)) ==
    (0xd5, 0xff, 0xaa, 0x80)
  assert (audio.pcm.alaw(-32768), audio.pcm.ulaw(-32768)) == (0x2a, 0x00)
}

test "unknown and broken input" {
  assert decode([]) is err(Unsupported(_))
  assert decode("ID3\u{3}".bytes() + [0, 0, 0, 0, 0, 0]) is err(Unsupported("MP3"))
  assert decode("OggS".bytes() + [0, 0, 0, 0]) is err(Unsupported("Ogg"))
  let w = encode(sig(), Wav, S16)?
  assert decode(w.take(10)) is err(Unsupported(_))
  assert decode(w.take(20)) is err(Truncated(_))
  assert decode(w.take(40)) is err(Truncated(_))  // no data chunk
  assert decode(
    [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0] + "WAVEdata".bytes() + [0, 0, 0, 0],
  ) is err(Truncated(_))
  // a cut-off data chunk reads what's there
  assert (decode(w.take(w.len() - 400))?).frames() == 900
  assert encode(sig(), Flac, F32) is err(Unsupported(_))
  assert encode(new(8000, []), Wav, S16) is err(BadArg(_))
  assert message(Unsupported("MP3")) == "unsupported: MP3"
}

test "damaged AIFF rates and AU channel counts are errors" {
  let a = encode(sig(), Aiff, S16)?
  let comm = (0..a.len() - 4).find(i => audio.pcm.tag(a, i) == "COMM")!
  // the 80-bit rate: NaN, infinite, beyond any int, and an int past 32 bits
  for ext in [
    [0x7f, 0xff, 0xc0, 0, 0, 0, 0, 0, 0, 0],
    [0xff, 0xff, 0, 0, 0, 0, 0, 0, 0, 0],
    [0x40, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0],
    [0x40, 0x27, 0x80, 0, 0, 0, 0, 0, 0, 0],
  ] {
    var d = a
    for i, b in ext { d[comm + 16 + i] = b }
    assert decode(d) is err(Corrupt(_))
    assert probe(d) is err(Corrupt(_))
  }
  var nan = a
  nan[comm + 16] = 0x7f
  nan[comm + 17] = 0xff
  assert decode(nan) is err(Corrupt("AIFF sample rate NaN"))
  // 98 bytes claiming about a billion channels
  var au = ".snd".bytes()
  for v in [24, 74, 3, 8000, 1000000000] { audio.pcm.put32be(&au, v) }
  au = au + (0..74).map(i => i)
  assert decode(au) is err(Corrupt(_))
  assert probe(au) is err(Corrupt(_))
  // up to 65535 channels (what WAV and AIFF can hold) still read
  au[22] = 0xff
  au[23] = 0xff
  au[20] = 0
  au[21] = 0
  assert (probe(au)?).channels == 65535
  assert (decode(au)?).nch() == 65535
  au[21] = 1
  assert probe(au) is err(Corrupt(_))
}

test "names" {
  assert fmt_named("s16") == some(S16) &&
    fmt_named("pcm_s24le") == some(S24) &&
    fmt_named("flt") == some(F32)
  assert fmt_named("mulaw") == some(Ulaw) && fmt_named("opus") == none
  assert container_for("a/b.FLAC") == some(Flac) &&
    container_for("x.aif") == some(Aiff) &&
    container_for("x.mp3") == none
  assert codec_name(F64, true) == "pcm_f64be"
}

test "resampling keeps a sine clean" {
  for (from, to) in [(44100, 48000), (48000, 44100), (8000, 22050)] {
    let a = sine(1000.0, 0.2, from).resample(to)
    let ideal = sine(1000.0, 0.2, to)
    assert a.frames() == ideal.frames()
    let mid = a.trim(0.05, 0.15)
    let ref = ideal.trim(0.05, 0.15)
    assert max_err(mid, ref) < 0.0001
  }
}

test "filters" {
  let lp = audio.fx.design(audio.fx.Lowpass, 1000.0, 0.7071067811865476, 0.0, 48000)
  assert abs(audio.fx.response_db(lp, 1000.0, 48000) + 3.01) < 0.01
  assert audio.fx.response_db(lp, 10000.0, 48000) < -38.0
  let pk = audio.fx.design(audio.fx.Peak, 2000.0, 1.0, 6.0, 48000)
  assert abs(audio.fx.response_db(pk, 2000.0, 48000) - 6.0) < 0.001
  // a 5 kHz tone through a 500 Hz low-pass loses about 40 dB
  let t = sine(5000.0, 0.5, 48000)
  let drop = gain_to_db(t.lowpass(500.0).trim(0.1, -1.0).peak() / t.peak())
  assert drop < -38.0 && drop > -42.0
  // hum removal
  let hum = sine(50.0, 1.0, 8000)
  assert hum.notch(50.0, 5.0).trim(0.5, -1.0).peak() < 0.01
}

test "levels and loudness" {
  // EBU Tech 3341: a stereo 1 kHz sine at -23 dBFS reads -23 LUFS
  let s = sine(1000.0, 3.0, 48000).remix(2).gain_db(-23.0)
  let l = s.loudness()
  assert abs(l.integrated + 23.0) < 0.1
  assert abs(l.true_peak_db + 23.0) < 0.1
  assert abs(s.loudnorm(-16.0, -1.0).loudness().integrated + 16.0) < 0.1
  assert abs(gain_to_db(s.normalize(-1.0).peak()) + 1.0) < 0.0001
  let st = sine(100.0, 1.0, 8000).gain(0.5).stats()[0]
  assert abs(st.rms - 0.35355) < 0.001 && abs(st.crest - 1.4142) < 0.001 && st.clipped == 0
  assert silence(0.1, 8000, 1).loudness().integrated == -70.0
}

test "dynamics" {
  let a = sine(200.0, 1.0, 8000).gain(3.0)
  let lim = a.limit(-1.0, 0.005, 0.05)
  assert lim.peak() <= db_to_gain(-1.0) + 0.000001
  assert lim.peak() > db_to_gain(-1.5)
  // 2:1 above -18 dB with no knee: a 0 dB tone comes out near -9 dB
  let c = sine(200.0, 1.0, 8000).compress(Comp { knee: 0.0, rms: false, ..COMP })
  assert abs(gain_to_db(c.trim(0.5, -1.0).peak()) + 9.0) < 1.0
  // a quiet tone is gated down, a loud one passes
  let quiet = sine(200.0, 1.0, 8000).gain_db(-50.0)
  assert quiet.gate(-30.0, 4.0, 40.0, 0.01, 0.1).trim(0.5, -1.0).peak() < quiet.peak() / 10.0
  let loud = sine(200.0, 1.0, 8000).gain_db(-10.0)
  assert abs(loud.gate(-30.0, 4.0, 40.0, 0.01, 0.1).trim(0.5, -1.0).peak() - loud.peak()) < 0.01
}

test "editing" {
  let a = sig()
  assert a.trim(0.025, 0.1).frames() == 600
  assert a.trim(0.1, 0.05).frames() == 0
  assert a.pad(0.5).frames() == 5000 && a.delay(0.5).chans[0][4000] == a.chans[0][0]
  assert a.reverse().chans[1][0] == a.chans[1][999]
  let f = a.fade_in(0.05)
  assert f.chans[0][0] == 0.0 && f.chans[0][500] == a.chans[0][500]
  assert (concat([a, a, a])?).frames() == 3000
  assert concat([a, sine(1.0, 1.0, 8000)]) is err(BadArg(_))
  let o = a.overlay(a, 0.1)?
  assert o.frames() == 1800 && o.chans[0][900] == a.chans[0][900] + a.chans[0][100]
  assert (mix([a, a])?).chans[0][7] == a.chans[0][7]
  let e = a.echo(1.0, 1.0, [0.01], [0.5])
  assert e.frames() == 1080 && e.chans[0][100] == a.chans[0][100] + 0.5 * a.chans[0][20]
  assert abs(a.delay_each([0.0, 0.01]).chans[1][80] - a.chans[1][0]) == 0.0
}

test "channels" {
  let m = sine(100.0, 0.1, 8000)
  let st = m.remix(2)
  assert st.nch() == 2 && st.chans[1] == m.chans[0]
  assert st.mono().chans[0] == m.chans[0]
  let six = new(8000, (0..6).map(_ => m.chans[0]))
  let down = six.remix(2)
  assert down.nch() == 2 && down.peak() <= 1.000000001 && down.peak() > 0.99
  assert m.remix(6).chans[2] == audio.pcm.zeros(800)
  assert sig().channel(1).chans[0] == sig().chans[1]
  assert max_err(sig().widen(1.0), sig()) < 0.000000000001
}

test "time and pitch" {
  let a = concat([sine(500.0, 0.5, 8000), sine(1000.0, 0.5, 8000)])?
  let fast = a.tempo(2.0)
  assert fast.frames() == 4000
  assert abs(fast.trim(0.05, 0.2).dominant() - 500.0) < 5.0
  assert abs(fast.trim(0.3, 0.45).dominant() - 1000.0) < 5.0
  let up = sine(440.0, 1.0, 8000).pitch(12.0)
  assert up.frames() == 8000 && abs(up.trim(0.2, 0.8).dominant() - 880.0) < 5.0
  assert sine(440.0, 1.0, 8000).set_rate(16000).duration() == 0.5
}

test "analysis" {
  assert abs(sine(1234.0, 0.5, 44100).dominant() - 1234.0) < 1.0
  let sp = sine(1000.0, 1.0, 8000).spectrum(1024)
  assert sp.len() == 513 && abs(sp[128]) < 0.1 && sp[300] < -100.0
  var re = [1.0, 2.0, 3.0, 4.0, 0.0, -1.0, 0.5, 2.0]
  var im = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
  let orig = re
  audio.analyze.fft(&re, &im, false)
  assert abs(re[0] - 11.5) < 0.0000001
  audio.analyze.fft(&re, &im, true)
  assert (0..8).all(i => abs(re[i] - orig[i]) < 0.0000001)
  let gap = concat([sine(300.0, 0.5, 8000), silence(1.0, 8000, 1), sine(300.0, 0.5, 8000)])?
  let sil = gap.silences(-60.0, 0.5)
  assert sil.len() == 1 && abs(sil[0].0 - 0.5) < 0.01 && abs(sil[0].1 - 1.5) < 0.01
  assert silence(0.2, 8000, 1).delay(0.0).silences(-60.0, 0.1).len() == 1
  let padded = concat([silence(0.25, 8000, 1), sine(300.0, 0.5, 8000), silence(0.25, 8000, 1)])?
  assert abs(padded.trim_silence(-60.0).duration() - 0.5) < 0.001
}

test "filter graphs" {
  let a = sig()
  assert (a.apply("volume=0.5")?).chans[0][3] == a.chans[0][3] * 0.5
  assert abs((a.apply("volume=-6.0206dB")?).peak() - a.peak() / 2.0) < 0.0001
  let b = a.apply("highpass=f=100, lowpass=f=3000:p=1 ,aresample=16000,atrim=start=0.01:duration=0.05,afade=t=out:d=0.01")?
  assert b.rate == 16000 && b.frames() == 800
  assert (a.apply("pan=mono|c0=0.5*c0+0.5*c1")?).chans[0][9] ==
    (a.chans[0][9] + a.chans[1][9]) * 0.5
  assert (a.apply("pan=stereo|c0=c1|c1=-c0")?).chans[1][9] == -a.chans[0][9]
  assert (a.apply("aformat=sample_rates=4000:channel_layouts=mono")?).rate == 4000
  assert (a.apply("aecho=0.8:0.9:10|20:0.3|0.2")?).frames() == 1160
  assert (a.apply("adelay=10|20")?).frames() == 1160
  assert (a.apply("atempo=2")?).frames() == 500
  assert (a.apply("anull,areverse,areverse")?).chans == a.chans
  assert a.apply("bogus=1") is err(BadArg(_))
  assert a.apply("volume=loud") is err(BadArg(_))
  assert a.apply("lowpass=f=9000") is err(BadArg(_))
  assert audio.graph.duration("1:02.5") == some(62.5) && audio.graph.duration("250ms") == some(0.25)
}

test "sources" {
  let s = source("sine=frequency=1000:duration=0.5:sample_rate=8000")?
  assert s.frames() == 4000 && abs(s.peak() - 0.125) < 0.001 && abs(s.dominant() - 1000.0) < 2.0
  let n = source("anoisesrc=color=pink:d=0.2:a=0.5:seed=3:r=8000")?
  assert n.frames() == 1600 &&
    n.peak() <= 1.0 &&
    n == source("anoisesrc=color=pink:d=0.2:a=0.5:seed=3:r=8000")?
  assert (source("anullsrc=r=48000:cl=5.1:d=0.1")?).nch() == 6
  assert (source("square=f=100:d=0.1:r=8000")?).peak() == 0.5
  assert (source("chirp=f0=100:f1=1000:d=1:r=8000")?).frames() == 8000
  assert source("wobble") is err(BadArg(_))
}
