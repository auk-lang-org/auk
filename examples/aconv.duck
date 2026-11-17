/// An ffmpeg-style audio converter on the `audio` package.
///
///   aconv -i in.flac                                  # probe: format, codec, rate, length, tags
///   aconv -i in.wav -af "highpass=f=80,loudnorm=I=-16" -ar 48000 -ac 1 out.flac
///   aconv -i in.aiff -ss 1.5 -t 10 -sample_fmt s24 -metadata title=Intro out.wav
///   aconv -f lavfi -i "sine=f=440:d=2" beep.wav       # generate
///   aconv -i in.wav -stats                            # levels and EBU R128 loudness
///
/// The output format comes from the extension (.wav .aif .aiff .aifc .au .flac); the sample
/// format defaults to the input's (16 or 24 bits for FLAC).

struct Opts {
  input: str,
  lavfi: bool,
  output: str,
  graph: str,
  rate: int,
  chans: int,
  fmt: str,
  start: float,
  dur: float,
  tags: {str: str},
  stats: bool,
}

fn usage(): str = "usage: aconv [-f lavfi] -i <input> [-ss S] [-t S] [-af graph] [-ar Hz] [-ac N] [-sample_fmt F] [-metadata k=v] [-stats] [output]"

fn secs(v: str): float! = audio.graph.duration(v) else fail("not a duration: {v}")

fn parse(args: [str]): Opts! {
  var o = Opts {
    input: "",
    lavfi: false,
    output: "",
    graph: "",
    rate: 0,
    chans: 0,
    fmt: "",
    start: 0.0,
    dur: -1.0,
    tags: {},
    stats: false,
  }
  var i = 1
  while i < args.len() {
    let a = args[i]
    // every option but -stats takes a value
    let v = if a.starts_with("-") && a != "-stats" {
      args.get(i + 1) else fail("{a} needs a value\n{usage()}")
    } else {
      ""
    }
    match a {
      "-i" => o.input = v
      "-f" => o.lavfi = v == "lavfi"
      "-af" => o.graph = if o.graph == "" { v } else { o.graph + "," + v }
      "-ar" => o.rate = int.parse(v)?
      "-ac" => o.chans = int.parse(v)?
      "-sample_fmt" => o.fmt = v
      "-c:a" => o.fmt = v
      "-acodec" => o.fmt = v
      "-ss" => o.start = secs(v)?
      "-t" => o.dur = secs(v)?
      "-metadata" => {
        let eq = v.find("=") else fail("-metadata takes key=value")
        o.tags[v[0..eq].lower()] = v[eq + 1..v.len()]
      }
      "-stats" => o.stats = true
      "-y" => {}
      _ => {
        if a.starts_with("-") { fail("unknown option {a}\n{usage()}") }
        o.output = a
      }
    }
    i += if a.starts_with("-") && a != "-stats" && a != "-y" { 2 } else { 1 }
  }
  if o.input == "" { fail(usage()) }
  o
}

fn hms(s: float): str {
  let m = int(s) / 60
  "{m / 60:02}:{m % 60:02}:{s - float(m * 60):06.3}"
}

fn show(i: audio.Info, path: str) {
  print("Input: {path}")
  print("  Duration: {hms(i.duration())}, {i.frames} frames")
  print("  Stream: Audio: {i.codec} ({i.container}), {i.rate} Hz, {i.channels} channels, {i.bits} bits")
  if i.tags.len() > 0 {
    print("  Metadata:")
    for k, v in i.tags { print("    {k:<16}: {v}") }
  }
}

fn report(a: audio.Audio) {
  for c, s in a.stats() {
    print("channel {c}: peak {s.peak_db:.2} dBFS, RMS {s.rms_db:.2} dBFS, DC {s.dc:.6}, crest {s.crest:.2}, clipped {s.clipped}")
  }
  let l = a.loudness()
  print("loudness: I {l.integrated:.1} LUFS, LRA {l.range:.1} LU, true peak {l.true_peak_db:.1} dBTP")
  for (s, e) in a.silences(-60.0, 1.0) { print("silence: {s:.3}s to {e:.3}s") }
}

// The input's sample format, as close as the output container allows.
fn default_fmt(i: audio.Info, c: audio.Container): audio.Fmt {
  let f = audio.fmt_named(i.codec) else if i.bits > 16 { audio.S24 } else { audio.S16 }
  match (c, f) {
    (audio.Flac, audio.S16) => audio.S16
    (audio.Flac, audio.U8) => audio.U8
    (audio.Flac, audio.S8) => audio.S8
    (audio.Flac, _) => if i.bits > 16 { audio.S24 } else { audio.S16 }
    (audio.Wav, audio.S8) => audio.U8
    (audio.Aiff, audio.U8) => audio.S8
    (audio.Au, audio.U8) => audio.S8
    _ => f
  }
}

fn main(args: [str]): int! uses fs {
  let o = parse(args)?
  let fail_on = (e: audio.AErr) => audio.message(e)
  var info = audio.Info {
    container: "lavfi",
    codec: "pcm_s16le",
    rate: 0,
    channels: 0,
    frames: 0,
    bits: 16,
    tags: {},
  }
  var a = if o.lavfi {
    audio.source(o.input) else e => fail(fail_on(e))
  } else {
    let bytes = fs.read_bytes(o.input)?
    info = audio.probe(bytes) else e => fail("{o.input}: {fail_on(e)}")
    audio.decode(bytes) else e => fail("{o.input}: {fail_on(e)}")
  }
  if o.output == "" && !o.stats {
    show(info, o.input)
    return 0
  }
  if o.start > 0.0 || o.dur >= 0.0 {
    a = a.trim(o.start, if o.dur >= 0.0 { o.start + o.dur } else { -1.0 })
  }
  if o.graph != "" { a = a.apply(o.graph) else e => fail(fail_on(e)) }
  if o.chans > 0 { a = a.remix(o.chans) }
  if o.rate > 0 { a = a.resample(o.rate) }
  for k, v in o.tags { a.tags[k] = v }
  if o.stats { report(a) }
  if o.output != "" {
    let c = audio.container_for(
      o.output,
    ) else fail("unknown output format: {o.output} (use .wav .aiff .aifc .au .flac)")
    let f = if o.fmt == "" {
      default_fmt(info, c)
    } else {
      audio.fmt_named(o.fmt) else fail("unknown sample format: {o.fmt}")
    }
    let out = audio.encode(a, c, f) else e => fail(fail_on(e))
    fs.write_bytes(o.output, out)?
    let codec = if c == audio.Flac {
      "flac"
    } else {
      audio.codec_name(f, c == audio.Aiff || c == audio.Au)
    }
    print("{o.output}: {codec}, {a.rate} Hz, {a.nch()} ch, {hms(a.duration())}, {out.len()} bytes")
  }
  0
}
