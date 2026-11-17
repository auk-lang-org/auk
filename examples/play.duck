/// Play songs: decode with the `audio` package, apply optional ffmpeg-style filters, and hand
/// the result to the system player (`afplay` on macOS, `paplay` or `aplay` on Linux).
///
///   play song.flac other.wav                      # a playlist, in order
///   play -af "atempo=1.25,volume=-3dB" song.flac  # filters first (any `-af` chain)
///   play -ss 1:30 song.flac                       # start 90 s in
///
/// Reads WAV, AIFF/AIFC, AU and FLAC; MP3/AAC/Ogg files are skipped with a message.

fn player(): (str, [str])! uses proc {
  for (cmd, args) in [("afplay", []), ("paplay", []), ("aplay", ["-q"])] {
    match proc.run("sh", ["-c", "command -v {cmd}"]) {
      ok(_) => return (cmd, args)
      err(_) => {}
    }
  }
  fail("no audio player found (need afplay, paplay or aplay)")
}

fn mmss(s: float): str = "{int(s) / 60}:{int(s) % 60:02}"

fn main(args: [str]): int! uses fs, proc {
  var graph = ""
  var start = 0.0
  var files: [str] = []
  var i = 1
  while i < args.len() {
    match args[i] {
      "-af" => {
        graph = args.get(i + 1) else fail("-af needs a filter chain")
        i += 1
      }
      "-ss" => {
        let v = args.get(i + 1) else fail("-ss needs a time")
        start = audio.graph.duration(v) else fail("not a time: {v}")
        i += 1
      }
      f => files.push(f)
    }
    i += 1
  }
  if files.len() == 0 { fail("usage: play [-af filters] [-ss start] <file>...") }
  let (cmd, pargs) = player()?
  let tmp = fs.temp_dir()? + "/play.wav"
  for f in files {
    let bytes = fs.read_bytes(f) else e => {
      eprint("skip {f}: {e}")
      continue
    }
    var a = audio.decode(bytes) else e => {
      eprint("skip {f}: {audio.message(e)}")
      continue
    }
    if start > 0.0 { a = a.trim(start, -1.0) }
    if graph != "" {
      a = a.apply(graph) else e => fail(audio.message(e))
    }
    let title = a.tags.get("title") else f
    let by = match a.tags.get("artist") {
      some(v) => " - {v}"
      none => ""
    }
    print("▶ {title}{by}  [{a.rate} Hz, {a.nch()} ch, {mmss(a.duration())}]")
    // 24-bit keeps the quality of hi-res sources and of float processing
    fs.write_bytes(tmp, audio.encode(a, audio.Wav, audio.S24) else e => fail(audio.message(e)))?
    proc.run(cmd, pargs + [tmp])?
  }
  fs.remove(tmp) else {}
  0
}
