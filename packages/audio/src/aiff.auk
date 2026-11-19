/// AIFF and AIFF-C (module `audio.aiff`): big-endian PCM (8 to 32 bits), little-endian `sowt`,
/// 32/64-bit float, A-law and μ-law, with NAME/AUTH/(c)/ANNO text chunks. Also Sun/NeXT `.au`.

struct Hdr {
  nch: int,
  frames: int,
  bits: int,
  rate: int,
  comp: str,
  data_at: int,
  data_len: int,
  tags: {str: str},
}

let TEXT = [("NAME", "title"), ("AUTH", "artist"), ("(c) ", "copyright"), ("ANNO", "comment")]

/// An 80-bit IEEE extended float (the AIFF sample rate).
fn ext80(d: [int], i: int): float {
  let e = (d[i] & 0x7f) << 8 | d[i + 1]
  let hi = audio.pcm.u32be(d, i + 2)
  let lo = audio.pcm.u32be(d, i + 6)
  if e == 0 && hi == 0 && lo == 0 { return 0.0 }
  let v = float(hi) * 2.0 ** float(e - 16383 - 31) + float(lo) * 2.0 ** float(e - 16383 - 63)
  if (d[i] & 0x80) != 0 { -v } else { v }
}

// The highest sample rate read from a file: WAV and AU store the rate in 32 bits.
let MAX_RATE = 0xffffffff

fn put_ext80(out: var [int], rate: int) {
  var e = 0
  while (rate >> (e + 1)) > 0 { e += 1 }
  audio.pcm.put16be(&out, 16383 + e)
  audio.pcm.put32be(&out, rate << (31 - e))
  audio.pcm.put32be(&out, 0)
}

fn header(d: [int]): Hdr!audio.AErr {
  if d.len() < 12 { fail(audio.Truncated("AIFF header")) }
  let form = audio.pcm.tag(d, 8)
  if audio.pcm.tag(d, 0) != "FORM" || (form != "AIFF" && form != "AIFC") {
    fail(audio.Corrupt("not an AIFF file"))
  }
  var h = Hdr {
    nch: 0,
    frames: 0,
    bits: 0,
    rate: 0,
    comp: "NONE",
    data_at: -1,
    data_len: 0,
    tags: {},
  }
  var comm = false
  var p = 12
  while p + 8 <= d.len() {
    let id = audio.pcm.tag(d, p)
    var size = audio.pcm.u32be(d, p + 4)
    let body = p + 8
    if body + size > d.len() { size = d.len() - body }
    if id == "COMM" {
      if size < 18 { fail(audio.Truncated("AIFF COMM chunk")) }
      h.nch = audio.pcm.u16be(d, body)
      h.frames = audio.pcm.u32be(d, body + 2)
      h.bits = audio.pcm.u16be(d, body + 6)
      // a damaged rate can be NaN, infinite or too big for an int
      let rate = ext80(d, body + 8)
      if !(rate > -1.0e18 && rate < 1.0e18) { fail(audio.Corrupt("AIFF sample rate {rate}")) }
      h.rate = int(round(rate))
      if form == "AIFC" && size >= 22 { h.comp = audio.pcm.tag(d, body + 18) }
      comm = true
    } else if id == "SSND" && size >= 8 {
      let off = audio.pcm.u32be(d, body)
      h.data_at = body + 8 + off
      h.data_len = size - 8 - off
    } else {
      match TEXT.find(t => t.0 == id) {
        some((_, name)) => {
          let v = audio.pcm.text(d[body..body + size])
          if v != "" { h.tags[name] = v }
        }
        none => {}
      }
    }
    p = body + size + (size & 1)
  }
  if !comm { fail(audio.Corrupt("AIFF file has no COMM chunk")) }
  if h.nch < 1 || h.rate < 1 || h.rate > MAX_RATE {
    fail(audio.Corrupt("AIFF file has {h.nch} channels at {h.rate} Hz"))
  }
  if h.data_at < 0 {
    if h.frames > 0 { fail(audio.Corrupt("AIFF file has no SSND chunk")) }
    h.data_at = d.len()
  }
  h
}

// The sample format and whether it is big-endian.
fn fmt_of(h: Hdr): (audio.Fmt, bool)!audio.AErr {
  let w = (h.bits + 7) / 8
  match h.comp.lower() {
    "none" => (pcm_fmt(w)?, true)
    "twos" => (pcm_fmt(w)?, true)
    "sowt" => (pcm_fmt(w)?, false)
    "raw " => (audio.U8, true)
    "fl32" => (audio.F32, true)
    "fl64" => (audio.F64, true)
    "alaw" => (audio.Alaw, true)
    "ulaw" => (audio.Ulaw, true)
    c => fail(audio.Unsupported("AIFF-C compression '{h.comp}'"))
  }
}

fn pcm_fmt(w: int): audio.Fmt!audio.AErr = match w {
  1 => audio.S8
  2 => audio.S16
  3 => audio.S24
  4 => audio.S32
  _ => fail(audio.Unsupported("{w * 8}-bit AIFF samples"))
}

pub fn probe(d: [int]): audio.Info!audio.AErr {
  let h = header(d)?
  let (f, big) = fmt_of(h)?
  let container = if audio.pcm.tag(d, 8) == "AIFC" { "aifc" } else { "aiff" }
  audio.Info {
    container,
    codec: audio.codec_name(f, big),
    rate: h.rate,
    channels: h.nch,
    frames: h.frames,
    bits: h.bits,
    tags: h.tags,
  }
}

pub fn decode(d: [int]): audio.Audio!audio.AErr {
  let h = header(d)?
  let (f, big) = fmt_of(h)?
  let w = audio.pcm.width(f)
  let room = h.data_len / (w * h.nch)
  let n = if h.frames < room { h.frames } else { room }
  if n < h.frames { fail(audio.Truncated("AIFF sound data")) }
  audio.Audio {
    rate: h.rate,
    chans: audio.pcm.decode(d, h.data_at, n, h.nch, f, big),
    tags: h.tags,
  }
}

fn chunk(out: var [int], id: str, body: [int]) {
  out = out + id.bytes()
  audio.pcm.put32be(&out, body.len())
  out = out + body
  if (body.len() & 1) == 1 { out.push(0) }
}

/// AIFF for integer PCM (S8, S16, S24, S32); AIFF-C for F32, F64, A-law and μ-law.
pub fn encode(a: audio.Audio, f: audio.Fmt): [int]!audio.AErr {
  let nch = a.chans.len()
  if nch < 1 { fail(audio.BadArg("AIFF needs at least one channel")) }
  let (comp, name) = match f {
    audio.S8 => ("NONE", "")
    audio.S16 => ("NONE", "")
    audio.S24 => ("NONE", "")
    audio.S32 => ("NONE", "")
    audio.F32 => ("fl32", "32-bit floating point")
    audio.F64 => ("fl64", "64-bit floating point")
    audio.Alaw => ("alaw", "ALaw 2:1")
    audio.Ulaw => ("ulaw", "\u{b5}Law 2:1")
    _ => fail(audio.Unsupported("AIFF can't hold {audio.codec_name(f, true)}; use S8"))
  }
  let aifc = comp != "NONE"
  var comm: [int] = []
  audio.pcm.put16be(&comm, nch)
  audio.pcm.put32be(&comm, a.chans[0].len())
  audio.pcm.put16be(&comm, audio.pcm.bits(f))
  put_ext80(&comm, a.rate)
  if aifc {
    comm = comm + comp.bytes()
    // a Pascal string, padded to an even length
    let nb = name.bytes()
    comm.push(nb.len())
    comm = comm + nb
    if (nb.len() & 1) == 0 { comm.push(0) }
  }
  var body = if aifc { "AIFC" } else { "AIFF" }.bytes()
  if aifc { chunk(&body, "FVER", [0xa2, 0x80, 0x51, 0x40]) }
  chunk(&body, "COMM", comm)
  for (id, name) in TEXT {
    let v = a.tags.get(name) else ""
    if v != "" { chunk(&body, id, v.bytes()) }
  }
  // the SSND chunk comes last, so the file is the FORM header, `body`, then that chunk
  let dlen = 8 + a.chans[0].len() * audio.pcm.width(f) * nch
  var out = "FORM".bytes()
  audio.pcm.put32be(&out, body.len() + 8 + dlen + (dlen & 1))
  out = out + body + "SSND".bytes()
  audio.pcm.put32be(&out, dlen)
  out = out + [0, 0, 0, 0, 0, 0, 0, 0]
  audio.pcm.encode_into(&out, a.chans, f, true)
  if (dlen & 1) == 1 { out.push(0) }
  out
}

// ---- Sun/NeXT .au ----

fn au_fmt(enc: int): audio.Fmt!audio.AErr = match enc {
  1 => audio.Ulaw
  2 => audio.S8
  3 => audio.S16
  4 => audio.S24
  5 => audio.S32
  6 => audio.F32
  7 => audio.F64
  27 => audio.Alaw
  e => fail(audio.Unsupported("AU encoding {e}"))
}

// The most channels an AU file may have: what WAV and AIFF can hold (their channel counts are
// 16-bit). The header's count is 32-bit, and each channel becomes a list when decoding.
let MAX_AU_CHANNELS = 65535

fn au_header(d: [int]): (int, int, audio.Fmt, int, int, str)!audio.AErr {
  if d.len() < 24 { fail(audio.Truncated("AU header")) }
  if audio.pcm.tag(d, 0) != ".snd" { fail(audio.Corrupt("not an AU file")) }
  let at = audio.pcm.u32be(d, 4)
  var size = audio.pcm.u32be(d, 8)
  let f = au_fmt(audio.pcm.u32be(d, 12))?
  let rate = audio.pcm.u32be(d, 16)
  let nch = audio.pcm.u32be(d, 20)
  if at < 24 || at > d.len() { fail(audio.Corrupt("AU data offset {at}")) }
  if nch < 1 || rate < 1 || nch > MAX_AU_CHANNELS {
    fail(audio.Corrupt("AU file has {nch} channels at {rate} Hz"))
  }
  if size == 0xffffffff || at + size > d.len() { size = d.len() - at }
  let note = audio.pcm.text(d[24..at])
  (at, size, f, rate, nch, note)
}

pub fn au_probe(d: [int]): audio.Info!audio.AErr {
  let (_, size, f, rate, nch, note) = au_header(d)?
  let tags: {str: str} = if note == "" { {} } else { {"comment": note} }
  audio.Info {
    container: "au",
    codec: audio.codec_name(f, true),
    rate,
    channels: nch,
    frames: size / (audio.pcm.width(f) * nch),
    bits: audio.pcm.bits(f),
    tags,
  }
}

pub fn au_decode(d: [int]): audio.Audio!audio.AErr {
  let (at, size, f, rate, nch, note) = au_header(d)?
  let tags: {str: str} = if note == "" { {} } else { {"comment": note} }
  audio.Audio {
    rate,
    chans: audio.pcm.decode(d, at, size / (audio.pcm.width(f) * nch), nch, f, true),
    tags,
  }
}

pub fn au_encode(a: audio.Audio, f: audio.Fmt): [int]!audio.AErr {
  let enc = match f {
    audio.Ulaw => 1
    audio.S8 => 2
    audio.S16 => 3
    audio.S24 => 4
    audio.S32 => 5
    audio.F32 => 6
    audio.F64 => 7
    audio.Alaw => 27
    _ => fail(audio.Unsupported("AU can't hold {audio.codec_name(f, true)}"))
  }
  let note = (a.tags.get("comment") else "").bytes()
  // the annotation is NUL-terminated and padded to a multiple of 8 bytes
  var pad = note + [0]
  while pad.len() % 8 != 0 || pad.len() < 8 { pad.push(0) }
  let nch = a.chans.len()
  let dlen = if nch == 0 { 0 } else { a.chans[0].len() * audio.pcm.width(f) * nch }
  var out = ".snd".bytes()
  audio.pcm.put32be(&out, 24 + pad.len())
  audio.pcm.put32be(&out, dlen)
  audio.pcm.put32be(&out, enc)
  audio.pcm.put32be(&out, a.rate)
  audio.pcm.put32be(&out, nch)
  out = out + pad
  audio.pcm.encode_into(&out, a.chans, f, true)
  out
}
