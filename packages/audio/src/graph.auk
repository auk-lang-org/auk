/// ffmpeg filter-graph syntax (module `audio.graph`): `name=opt:opt,name=key=value:key=value`.
/// Options may be positional (in each filter's documented order) or named, by ffmpeg's long or
/// short names. Durations are seconds (`1.5`), milliseconds (`250ms`) or `[hh:]mm:ss[.f]`.
/// Gains take a number or `NdB`.

// One filter: its name and options, positional ones keyed by their index ("0", "1", ...).
struct Step { name: str, opts: {str: str}, raw: str }

fn bad(why: str): audio.AErr = audio.BadArg(why)

fn parse(spec: str): [Step]!audio.AErr {
  var steps: [Step] = []
  for part in spec.split(",") {
    let p = part.trim()
    if p == "" { continue }
    let (name, args) = match p.find("=") {
      some(i) => (p[0..i].trim(), p[i + 1..p.len()])
      none => (p, "")
    }
    var opts: {str: str} = {}
    var pos = 0
    if args != "" {
      for a in args.split(":") {
        match a.find("=") {
          some(i) => opts[a[0..i].trim()] = a[i + 1..a.len()].trim()
          none => {
            opts["{pos}"] = a.trim()
            pos += 1
          }
        }
      }
    }
    steps.push(Step { name, opts, raw: args })
  }
  steps
}

// The option at positional index `i`, or under any of `names`.
fn opt(s: Step, i: int, names: [str]): str? {
  for n in names {
    match s.opts.get(n) {
      some(v) => return some(v)
      none => {}
    }
  }
  s.opts.get("{i}")
}

fn num(s: Step, i: int, names: [str], dflt: float): float!audio.AErr = match opt(s, i, names) {
  some(v) => float.parse(v) else fail(bad("{s.name}: '{v}' isn't a number"))
  none => dflt
}

// A gain: linear, or in dB with a `dB` suffix.
fn gain(s: Step, i: int, names: [str], dflt: float): float!audio.AErr = match opt(s, i, names) {
  some(v) => parse_gain(v) else fail(bad("{s.name}: '{v}' isn't a gain"))
  none => dflt
}

fn parse_gain(v: str): float? {
  let t = v.trim()
  if t.lower().ends_with("db") {
    let d = pf(t[0..t.len() - 2])?
    some(audio.fx.undb(d))
  } else {
    pf(t)
  }
}

// A level in dB: a number of dB with a `dB` suffix, or a linear amplitude.
fn level_db(s: Step, i: int, names: [str], dflt: float): float!audio.AErr = match opt(s, i, names) {
  some(v) => {
    let t = v.trim()
    if t.lower().ends_with("db") {
      float.parse(t[0..t.len() - 2]) else fail(bad("{s.name}: '{v}' isn't a level"))
    } else {
      audio.fx.db(float.parse(t) else fail(bad("{s.name}: '{v}' isn't a level")))
    }
  }
  none => dflt
}

/// Seconds from `1.5`, `250ms`, `2s`, `1:30` or `01:02:03.5`.
pub fn duration(v: str): float? {
  let t = v.trim()
  if t.ends_with("ms") { return some(pf(t[0..t.len() - 2])? / 1000.0) }
  if t.ends_with("us") { return some(pf(t[0..t.len() - 2])? / 1000000.0) }
  if t.ends_with("s") { return pf(t[0..t.len() - 1]) }
  if t.contains(":") {
    var total = 0.0
    for part in t.split(":") {
      total = total * 60.0 + pf(part)?
    }
    return some(total)
  }
  pf(t)
}

fn pf(s: str): float? = match float.parse(s) {
  ok(v) => some(v)
  err(_) => none
}

fn secs(s: Step, i: int, names: [str], dflt: float): float!audio.AErr = match opt(s, i, names) {
  some(v) => duration(v) else fail(bad("{s.name}: '{v}' isn't a duration"))
  none => dflt
}

// Milliseconds (ffmpeg's dynamics filters take ms).
fn ms(s: Step, i: int, names: [str], dflt: float): float!audio.AErr =
  num(s, i, names, dflt)? / 1000.0

fn int_opt(s: Step, i: int, names: [str], dflt: int): int!audio.AErr = match opt(s, i, names) {
  some(v) => int.parse(v) else fail(bad("{s.name}: '{v}' isn't an integer"))
  none => dflt
}

// A list like `1000|500` (aecho, adelay).
fn list(s: Step, i: int, names: [str], dflt: [float]): [float]!audio.AErr = match opt(s, i, names) {
  some(v) => {
    var xs: [float] = []
    for x in v.split("|") {
      xs.push(float.parse(x.trim()) else fail(bad("{s.name}: '{x}' isn't a number")))
    }
    xs
  }
  none => dflt
}

fn layout(v: str): int? = match v {
  "mono" => some(1)
  "stereo" => some(2)
  "2.1" => some(3)
  "quad" => some(4)
  "4.0" => some(4)
  "5.0" => some(5)
  "5.1" => some(6)
  "7.1" => some(8)
  _ => {
    let t = if v.ends_with("c") { v[0..v.len() - 1] } else { v }
    match int.parse(t) {
      ok(n) => some(n)
      err(_) => none
    }
  }
}

// One filter's width option: Q by default; `t=o` (octaves) or `t=h` (Hz) convert to Q.
fn width_q(s: Step, i: int, freq: float, dflt: float): float!audio.AErr {
  let w = num(s, i, ["w", "width"], dflt)?
  match opt(s, -1, ["t", "width_type"]) {
    some("o") => sqrt(2.0 ** w) / (2.0 ** w - 1.0)
    some("h") => freq / w
    some("s") => 0.7071067811865476 / w
    _ => w
  }
}

fn bq_step(
  a: audio.Audio,
  s: Step,
  kind: audio.fx.Kind,
  dflt_f: float,
  dflt_q: float,
  gain_at: int,
): audio.Audio!audio.AErr {
  let f = num(s, 0, ["f", "frequency"], dflt_f)?
  if f <= 0.0 || f >= float(a.rate) / 2.0 {
    fail(bad("{s.name}: frequency {f} must be between 0 and {a.rate / 2} Hz"))
  }
  let q = width_q(s, 1, f, dflt_q)?
  let g = if gain_at >= 0 { num(s, gain_at, ["g", "gain"], 0.0)? } else { 0.0 }
  a.biquad(kind, f, q, g)
}

// A one-pole filter (lowpass/highpass with p=1).
fn one_pole(a: audio.Audio, f: float, low: bool): audio.Audio {
  let k = exp(-2.0 * float.pi * f / float(a.rate))
  let bq = if low {
    audio.fx.Biquad { b0: 1.0 - k, b1: 0.0, b2: 0.0, a1: -k, a2: 0.0 }
  } else {
    audio.fx.Biquad { b0: (1.0 + k) / 2.0, b1: -(1.0 + k) / 2.0, b2: 0.0, a1: -k, a2: 0.0 }
  }
  audio.Audio { chans: a.chans.map(ch => audio.fx.biquad(ch, bq)), ..a }
}

fn pass(a: audio.Audio, s: Step, low: bool): audio.Audio!audio.AErr {
  let poles = int_opt(s, 2, ["p", "poles"], 2)?
  if poles == 1 {
    let f = num(s, 0, ["f", "frequency"], if low { 500.0 } else { 3000.0 })?
    return one_pole(a, f, low)
  }
  if poles != 2 { fail(bad("{s.name}: poles must be 1 or 2")) }
  bq_step(
    a,
    s,
    if low { audio.fx.Lowpass } else { audio.fx.Highpass },
    if low { 500.0 } else { 3000.0 },
    0.7071067811865476,
    -1,
  )
}

// `pan=stereo|c0=0.5*c0+0.5*c1|c1=c1`: the output layout, then each output as a sum of inputs.
fn pan_step(a: audio.Audio, s: Step): audio.Audio!audio.AErr {
  let parts = s.raw.split("|")
  if s.raw == "" { fail(bad("pan needs a layout and channel definitions")) }
  let n = layout(parts[0].trim()) else fail(bad("pan: unknown layout '{parts[0]}'"))
  var m: [[float]] = (0..n).map(_ => audio.pcm.zeros(a.nch()))
  for def in parts.skip(1) {
    let eq = def.find("=") else fail(bad("pan: '{def}' needs ="))
    let out = def[0..eq].trim()
    let o = int.parse(out.replace("c", "")) else fail(bad("pan: bad output channel '{out}'"))
    if o < 0 || o >= n { fail(bad("pan: output channel {o} out of range")) }
    // split the sum into signed terms
    let expr = def[eq + 1..def.len()].replace(" ", "").replace("-", "+-")
    for term in expr.split("+") {
      if term == "" { continue }
      let (g, ch) = match term.find("*") {
        some(i) => (
          float.parse(term[0..i]) else fail(bad("pan: bad gain in '{term}'")),
          term[i + 1..term.len()],
        )
        none => if term.starts_with("-") { (-1.0, term[1..term.len()]) } else { (1.0, term) }
      }
      let neg = ch.starts_with("-")
      let name = if neg { ch[1..ch.len()] } else { ch }
      let i = int.parse(name.replace("c", "")) else fail(bad("pan: bad input channel '{name}'"))
      if i < 0 || i >= a.nch() { fail(bad("pan: input channel {i} out of range")) }
      m[o][i] = m[o][i] + if neg { -g } else { g }
    }
  }
  a.pan(m)
}

fn step(a: audio.Audio, s: Step): audio.Audio!audio.AErr {
  match s.name {
    "volume" => {
      let g = gain(s, 0, ["volume"], 1.0)?
      a.gain(g)
    }
    "lowpass" => pass(a, s, true)
    "highpass" => pass(a, s, false)
    "bandpass" => bq_step(a, s, audio.fx.Bandpass, 3000.0, 0.7071067811865476, -1)
    "bandreject" => bq_step(a, s, audio.fx.Notch, 3000.0, 0.7071067811865476, -1)
    "allpass" => bq_step(a, s, audio.fx.Allpass, 3000.0, 0.7071067811865476, -1)
    "equalizer" => {
      // equalizer=f:w:g (here positional order is f, width, gain)
      bq_step(a, s, audio.fx.Peak, 1000.0, 1.0, 2)
    }
    "bass" => shelf(a, s, audio.fx.LowShelf, 100.0)
    "lowshelf" => shelf(a, s, audio.fx.LowShelf, 100.0)
    "treble" => shelf(a, s, audio.fx.HighShelf, 3000.0)
    "highshelf" => shelf(a, s, audio.fx.HighShelf, 3000.0)
    "aresample" => {
      let r = int_opt(s, 0, ["osr", "out_sample_rate", "sample_rate"], a.rate)?
      if r < 1 { fail(bad("aresample: rate {r}")) }
      a.resample(r)
    }
    "asetrate" => {
      let r = int_opt(s, 0, ["r", "sample_rate"], a.rate)?
      if r < 1 { fail(bad("asetrate: rate {r}")) }
      a.set_rate(r)
    }
    "aformat" => {
      var b = a
      match opt(s, -1, ["sample_rates", "r"]) {
        some(v) => {
          let r = int.parse(v.split("|")[0]) else fail(bad("aformat: bad rate '{v}'"))
          b = b.resample(r)
        }
        none => {}
      }
      match opt(s, -1, ["channel_layouts", "cl"]) {
        some(v) => {
          let n = layout(v.split("|")[0]) else fail(bad("aformat: unknown layout '{v}'"))
          b = b.remix(n)
        }
        none => {}
      }
      b
    }
    "atempo" => {
      let t = num(s, 0, ["tempo"], 1.0)?
      if t < 0.25 || t > 4.0 { fail(bad("atempo: tempo {t} must be 0.25 to 4")) }
      a.tempo(t)
    }
    "pitch" => a.pitch(num(s, 0, ["semitones", "s"], 0.0)?)
    "atrim" => {
      let start = secs(s, 0, ["start", "starti"], 0.0)?
      let dur = secs(s, -1, ["duration", "durationi", "d"], -1.0)?
      let end = secs(s, 1, ["end", "endi"], if dur >= 0.0 { start + dur } else { -1.0 })?
      a.trim(start, end)
    }
    "apad" => {
      let pad = secs(s, -1, ["pad_dur"], 0.0)?
      let whole = secs(s, -1, ["whole_dur"], 0.0)?
      if whole > a.duration() { a.pad(whole - a.duration()) } else { a.pad(pad) }
    }
    "afade" => {
      let kind = opt(s, 0, ["t", "type"]) else "in"
      let start = secs(s, 1, ["st", "start_time"], -1.0)?
      let d = secs(s, 2, ["d", "duration"], 0.0)?
      let dur = if d > 0.0 {
        d
      } else {
        float(int_opt(s, -1, ["ns", "nb_samples"], 44100)?) / float(a.rate)
      }
      let c = opt(s, -1, ["c", "curve"]) else "tri"
      let curve = audio.fx.curve_named(c) else fail(bad("afade: unknown curve '{c}'"))
      match kind {
        "in" => a.fade(true, if start < 0.0 { 0.0 } else { start }, dur, curve)
        "out" => a.fade(false, if start < 0.0 { a.duration() - dur } else { start }, dur, curve)
        k => fail(bad("afade: type must be in or out, not '{k}'"))
      }
    }
    "areverse" => a.reverse()
    "aecho" => {
      let ig = num(s, 0, ["in_gain"], 0.6)?
      let og = num(s, 1, ["out_gain"], 0.3)?
      let ds = list(s, 2, ["delays"], [1000.0])?
      let dc = list(s, 3, ["decays"], [0.5])?
      if ds.len() != dc.len() { fail(bad("aecho: {ds.len()} delays but {dc.len()} decays")) }
      a.echo(ig, og, ds.map(d => d / 1000.0), dc)
    }
    "adelay" => {
      let ds = list(s, 0, ["delays"], [0.0])?
      let all = int_opt(s, -1, ["all"], 0)? == 1
      let per = if all { (0..a.nch()).map(_ => ds[0]) } else { ds }
      a.delay_each(per.map(d => d / 1000.0))
    }
    "acompressor" => {
      let c = audio.Comp {
        threshold: audio.fx.db(gain(s, -1, ["threshold"], 0.125)?),
        ratio: num(s, -1, ["ratio"], 2.0)?,
        knee: audio.fx.db(num(s, -1, ["knee"], 2.82843)?),
        attack: ms(s, -1, ["attack"], 20.0)?,
        release: ms(s, -1, ["release"], 250.0)?,
        makeup: audio.fx.db(gain(s, -1, ["makeup"], 1.0)?),
        rms: (opt(s, -1, ["detection"]) else "rms") == "rms",
      }
      if c.ratio < 1.0 { fail(bad("acompressor: ratio must be at least 1")) }
      a.compress(c)
    }
    "alimiter" => {
      let lim = gain(s, -1, ["limit"], 1.0)?
      let lin = gain(s, -1, ["level_in"], 1.0)?
      let lout = gain(s, -1, ["level_out"], 1.0)?
      a
        .gain(lin)
        .limit(audio.fx.db(lim), ms(s, -1, ["attack"], 5.0)?, ms(s, -1, ["release"], 50.0)?)
        .gain(lout)
    }
    "agate" => {
      let ratio = num(s, -1, ["ratio"], 2.0)?
      if ratio < 1.0 { fail(bad("agate: ratio must be at least 1")) }
      let g = audio.fx.gate_gains(
        detect_avg(a),
        a.rate,
        gain(s, -1, ["threshold"], 0.125)?,
        ratio,
        num(s, -1, ["knee"], 2.828427125)?,
        gain(s, -1, ["range"], 0.06125)?,
        ms(s, -1, ["attack"], 20.0)?,
        ms(s, -1, ["release"], 250.0)?,
        (opt(s, -1, ["detection"]) else "rms") == "rms",
      )
      let mk = gain(s, -1, ["makeup"], 1.0)?
      audio.Audio { chans: a.chans.map(ch => (0..ch.len()).map(i => ch[i] * g[i] * mk)), ..a }
    }
    "loudnorm" => {
      let i = num(s, -1, ["I", "i"], -24.0)?
      let tp = num(s, -1, ["TP", "tp"], -2.0)?
      if i < -70.0 || i > -5.0 { fail(bad("loudnorm: I must be -70 to -5")) }
      a.loudnorm(i, tp)
    }
    "dynaudnorm" => a.normalize(-1.0)
    "anormalize" => a.normalize(level_db(s, 0, ["peak", "p"], -1.0)?)
    "silenceremove" =>
      a.trim_silence(level_db(s, -1, ["start_threshold", "stop_threshold"], -60.0)?)
    "pan" => pan_step(a, s)
    "extrastereo" => a.widen(num(s, 0, ["m"], 2.5)?)
    "tremolo" => {
      let f = num(s, 0, ["f"], 5.0)?
      let d = num(s, 1, ["d"], 0.5)?
      if d < 0.0 || d > 1.0 { fail(bad("tremolo: depth must be 0 to 1")) }
      a.tremolo(f, d)
    }
    "dcshift" => a.dc_shift(num(s, 0, ["shift"], 0.0)?)
    "aclip" => a.clip()
    "anull" => a
    "channelsplit" => fail(bad("channelsplit makes several outputs; use Audio.channel(c)"))
    n => fail(bad("unknown filter '{n}'"))
  }
}

fn shelf(a: audio.Audio, s: Step, kind: audio.fx.Kind, dflt_f: float): audio.Audio!audio.AErr {
  // bass/treble take g first: bass=g=6:f=100
  let g = num(s, 0, ["g", "gain"], 0.0)?
  let f = num(s, 1, ["f", "frequency"], dflt_f)?
  if f <= 0.0 || f >= float(a.rate) / 2.0 {
    fail(bad("{s.name}: frequency {f} must be between 0 and {a.rate / 2} Hz"))
  }
  let q = width_q(s, 2, f, 0.7071067811865476)?
  a.biquad(kind, f, q, g)
}

fn detect_avg(a: audio.Audio): [float] {
  let n = a.frames()
  var d = audio.pcm.zeros(n)
  for ch in a.chans {
    for i in 0..n { d[i] = d[i] + abs(ch[i]) / float(a.nch()) }
  }
  d
}

/// Runs each filter of the chain in order.
pub fn apply(a: audio.Audio, spec: str): audio.Audio!audio.AErr {
  var cur = a
  for s in parse(spec)? {
    cur = step(cur, s)?
  }
  cur
}

/// A lavfi-style source: `sine=f=440:d=2:r=44100`, `anoisesrc`, `anullsrc`, `square`,
/// `sawtooth`, `triangle`, `chirp`.
pub fn source(spec: str): audio.Audio!audio.AErr {
  let steps = parse(spec)?
  let [s] = steps else fail(bad("a source is one generator, not '{spec}'"))
  let rate = int_opt(s, -1, ["r", "sample_rate"], 44100)?
  if rate < 1 { fail(bad("{s.name}: sample rate {rate}")) }
  let d = secs(s, -1, ["d", "duration"], 5.0)?
  match s.name {
    "anullsrc" => {
      let n = layout(
        opt(s, -1, ["cl", "channel_layout"]) else "stereo",
      ) else fail(bad("anullsrc: unknown layout"))
      audio.silence(d, rate, n)
    }
    "anoisesrc" => {
      let c = opt(s, -1, ["c", "color", "colour"]) else "white"
      let color = audio.gen.color_named(c) else fail(bad("anoisesrc: unknown color '{c}'"))
      audio.noise(
        color,
        d,
        rate,
        num(s, -1, ["a", "amplitude"], 1.0)?,
        int_opt(s, -1, ["s", "seed"], 1)?,
      )
    }
    "chirp" => {
      let f0 = num(s, -1, ["f0"], 20.0)?
      let f1 = num(s, -1, ["f1"], 20000.0)?
      audio.chirp(f0, f1, d, rate, (opt(s, -1, ["type"]) else "lin") == "log")
    }
    name => {
      let w = audio.gen.wave_named(name) else fail(bad("unknown source '{name}'"))
      let f = num(s, 0, ["f", "frequency"], 440.0)?
      let amp = num(s, -1, ["a", "amplitude"], if name == "sine" { 0.125 } else { 0.5 })?
      audio.tone(w, f, d, rate, amp)
    }
  }
}
