/// RIFF WAVE (module `audio.wav`): reads PCM (8/16/24/32-bit, and 12/20-bit in wider
/// containers), IEEE float (32/64-bit), A-law, μ-law, IMA ADPCM and Microsoft ADPCM, plain or
/// WAVE_FORMAT_EXTENSIBLE, in RIFF or RF64 files, with LIST/INFO tags. Writes every one of
/// those formats except Microsoft ADPCM.

// What the header says, before any samples are decoded.
struct Hdr {
  tag: int,  // format tag (the subformat's, for WAVE_FORMAT_EXTENSIBLE)
  nch: int,
  rate: int,
  block: int,
  bits: int,
  data_at: int,
  data_len: int,
  fact: int,  // frames from the fact chunk, or -1
  coefs: [(int, int)],
  tags: {str: str},
}

// RIFF INFO ids and the tag names used in `Audio.tags` (ffmpeg's names).
let INFO = [
  ("INAM", "title"),
  ("IART", "artist"),
  ("IPRD", "album"),
  ("ICMT", "comment"),
  ("ICRD", "date"),
  ("IGNR", "genre"),
  ("ITRK", "track"),
  ("ICOP", "copyright"),
  ("ISFT", "encoder"),
]

fn info_name(id: str): str = INFO.find(p => p.0 == id)?.1 else id.lower()

fn header(d: [int]): Hdr!audio.AErr {
  if d.len() < 12 { fail(audio.Truncated("WAV header")) }
  let riff = audio.pcm.tag(d, 0)
  if (riff != "RIFF" && riff != "RF64") || audio.pcm.tag(d, 8) != "WAVE" {
    fail(audio.Corrupt("not a WAV file"))
  }
  var h = Hdr {
    tag: -1,
    nch: 0,
    rate: 0,
    block: 0,
    bits: 0,
    data_at: -1,
    data_len: 0,
    fact: -1,
    coefs: [],
    tags: {},
  }
  var big_data = -1  // RF64: the data size from the ds64 chunk
  var p = 12
  while p + 8 <= d.len() {
    let id = audio.pcm.tag(d, p)
    var size = audio.pcm.u32le(d, p + 4)
    let body = p + 8
    if id == "ds64" && body + 16 <= d.len() {
      big_data = audio.pcm.u64le(d, body + 8)
    } else if id == "fmt " {
      if body + 16 > d.len() || size < 16 { fail(audio.Truncated("WAV fmt chunk")) }
      h.tag = audio.pcm.u16le(d, body)
      h.nch = audio.pcm.u16le(d, body + 2)
      h.rate = audio.pcm.u32le(d, body + 4)
      h.block = audio.pcm.u16le(d, body + 12)
      h.bits = audio.pcm.u16le(d, body + 14)
      if h.tag == 0xfffe && size >= 40 && body + 26 <= d.len() {
        h.tag = audio.pcm.u16le(d, body + 24)
      }
      if h.tag == 2 && size >= 22 && body + 22 <= d.len() {
        let n = audio.pcm.u16le(d, body + 20)
        for i in 0..n {
          let q = body + 22 + 4 * i
          if q + 4 <= d.len() {
            h.coefs.push(
              (
                audio.pcm.sext(audio.pcm.u16le(d, q), 16),
                audio.pcm.sext(audio.pcm.u16le(d, q + 2), 16),
              ),
            )
          }
        }
      }
    } else if id == "fact" && body + 4 <= d.len() {
      h.fact = audio.pcm.u32le(d, body)
    } else if id == "LIST" && audio.pcm.tag(d, body) == "INFO" {
      var q = body + 4
      let end = if body + size < d.len() { body + size } else { d.len() }
      while q + 8 <= end {
        let n = audio.pcm.u32le(d, q + 4)
        let stop = if q + 8 + n < end { q + 8 + n } else { end }
        let v = audio.pcm.text(d[q + 8..stop])
        if v != "" { h.tags[info_name(audio.pcm.tag(d, q))] = v }
        q += 8 + n + (n & 1)
      }
    } else if id == "data" {
      if size == 0xffffffff && big_data >= 0 { size = big_data }
      // a streamed file may say 0 or 0xffffffff; a cut-off one says too much: take what's there
      if size == 0 || size == 0xffffffff || body + size > d.len() { size = d.len() - body }
      h.data_at = body
      h.data_len = size
      if h.tag >= 0 { return h }
    }
    if size == 0xffffffff { break }
    p = body + size + (size & 1)
  }
  if h.tag < 0 { fail(audio.Truncated("WAV file before its fmt chunk")) }
  if h.data_at < 0 { fail(audio.Truncated("WAV file before its data chunk")) }
  h
}

// The sample format of a PCM-like header.
fn fmt_of(h: Hdr): audio.Fmt!audio.AErr {
  let w = if h.nch > 0 { h.block / h.nch } else { 0 }
  match h.tag {
    1 => match w {
      1 => audio.U8
      2 => audio.S16
      3 => audio.S24
      4 => audio.S32
      _ => fail(audio.Unsupported("{h.bits}-bit PCM in {w}-byte samples"))
    }
    3 => match w {
      4 => audio.F32
      8 => audio.F64
      _ => fail(audio.Unsupported("{h.bits}-bit float"))
    }
    6 => audio.Alaw
    7 => audio.Ulaw
    0x11 => audio.Ima
    t => fail(audio.Unsupported("WAV format tag 0x{hex(t)}"))
  }
}

fn hex(n: int): str {
  let digits = "0123456789abcdef"
  var s = ""
  var v = n
  loop {
    s = str([digits[v & 15]]) + s
    v = v >> 4
    if v == 0 { break }
  }
  s
}

fn codec(h: Hdr): str = match h.tag {
  2 => "adpcm_ms"
  _ => match fmt_of(h) {
    ok(f) => audio.codec_name(f, false)
    err(_) => "unknown"
  }
}

fn frames(h: Hdr): int = match h.tag {
  2 => {
    let per = (h.block - 7 * h.nch) * 2 / h.nch + 2
    let full = h.data_len / h.block * per
    let rest = h.data_len % h.block
    let n = full + if rest >= 7 * h.nch { (rest - 7 * h.nch) * 2 / h.nch + 2 } else { 0 }
    if h.fact >= 0 && h.fact < n { h.fact } else { n }
  }
  0x11 => {
    let per = audio.pcm.ima_frames(h.block, h.nch)
    let full = h.data_len / h.block * per
    let rest = h.data_len % h.block
    let n = full + if rest >= 4 * h.nch { (rest - 4 * h.nch) / (4 * h.nch) * 8 + 1 } else { 0 }
    if h.fact >= 0 && h.fact < n { h.fact } else { n }
  }
  _ => if h.block > 0 { h.data_len / h.block } else { 0 }
}

fn check(h: Hdr): ()!audio.AErr {
  if h.nch < 1 { fail(audio.Corrupt("WAV file has {h.nch} channels")) }
  if h.rate < 1 { fail(audio.Corrupt("WAV file has sample rate {h.rate}")) }
  if h.block < 1 { fail(audio.Corrupt("WAV file has block size {h.block}")) }
}

pub fn probe(d: [int]): audio.Info!audio.AErr {
  let h = header(d)?
  check(h)?
  audio.Info {
    container: "wav",
    codec: codec(h),
    rate: h.rate,
    channels: h.nch,
    frames: frames(h),
    bits: h.bits,
    tags: h.tags,
  }
}

pub fn decode(d: [int]): audio.Audio!audio.AErr {
  let h = header(d)?
  check(h)?
  let chans = if h.tag == 2 {
    audio.pcm.ms_decode(
      d,
      h.data_at,
      h.data_len,
      h.nch,
      h.block,
      h.coefs,
      h.fact,
    ) else e => fail(audio.Corrupt("{e}"))
  } else {
    match fmt_of(h)? {
      audio.Ima => audio.pcm.ima_decode(
        d,
        h.data_at,
        h.data_len,
        h.nch,
        h.block,
        h.fact,
      ) else e => fail(audio.Corrupt("{e}"))
      f => {
        if audio.pcm.width(f) * h.nch != h.block {
          fail(
            audio.Unsupported("block size {h.block} for {h.nch} channels of {audio.codec_name(f, false)}"),
          )
        }
        audio.pcm.decode(d, h.data_at, h.data_len / h.block, h.nch, f, false)
      }
    }
  }
  audio.Audio { rate: h.rate, chans, tags: h.tags }
}

// The WAVE_FORMAT_EXTENSIBLE channel mask for the usual layouts (0 = unassigned).
fn mask(n: int): int = match n {
  1 => 0x4
  2 => 0x3
  3 => 0x7
  4 => 0x33
  5 => 0x37
  6 => 0x3f
  7 => 0x13f
  8 => 0x63f
  _ => 0
}

fn chunk(out: var [int], id: str, body: [int]) {
  out = out + id.bytes()
  audio.pcm.put32le(&out, body.len())
  out = out + body
  if (body.len() & 1) == 1 { out.push(0) }
}

/// A complete WAV file. Writes WAVE_FORMAT_EXTENSIBLE for more than two channels or more than
/// 16 bits, a `fact` chunk for non-PCM formats, and a LIST/INFO chunk for known tags.
pub fn encode(a: audio.Audio, f: audio.Fmt): [int]!audio.AErr {
  let nch = a.chans.len()
  if nch < 1 || nch > 65535 { fail(audio.BadArg("WAV needs 1 to 65535 channels, not {nch}")) }
  let n = a.chans[0].len()
  let tag = match f {
    audio.S8 => fail(audio.Unsupported("WAV can't hold signed 8-bit samples; use U8"))
    audio.F32 => 3
    audio.F64 => 3
    audio.Alaw => 6
    audio.Ulaw => 7
    audio.Ima => 0x11
    _ => 1
  }
  var fmt: [int] = []
  var data: [int] = []
  var direct = false  // the samples are encoded straight into the file, below
  if tag == 0x11 {
    let block = 256 * nch * if a.rate > 11025 { a.rate / 11025 } else { 1 }
    let per = audio.pcm.ima_frames(block, nch)
    audio.pcm.put16le(&fmt, tag)
    audio.pcm.put16le(&fmt, nch)
    audio.pcm.put32le(&fmt, a.rate)
    audio.pcm.put32le(&fmt, a.rate * block / per)
    audio.pcm.put16le(&fmt, block)
    audio.pcm.put16le(&fmt, 4)
    audio.pcm.put16le(&fmt, 2)
    audio.pcm.put16le(&fmt, per)
    data = audio.pcm.ima_encode(a.chans, block)
  } else {
    direct = true
    let w = audio.pcm.width(f)
    let ext = (nch > 2 || w > 2) && (tag == 1 || tag == 3)
    audio.pcm.put16le(&fmt, if ext { 0xfffe } else { tag })
    audio.pcm.put16le(&fmt, nch)
    audio.pcm.put32le(&fmt, a.rate)
    audio.pcm.put32le(&fmt, a.rate * w * nch)
    audio.pcm.put16le(&fmt, w * nch)
    audio.pcm.put16le(&fmt, w * 8)
    if ext {
      audio.pcm.put16le(&fmt, 22)
      audio.pcm.put16le(&fmt, w * 8)
      audio.pcm.put32le(&fmt, mask(nch))
      // the subformat GUID: the format tag then 00000000-0010-8000-00aa00389b71
      audio.pcm.put16le(&fmt, tag)
      fmt = fmt + [0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]
    } else if tag != 1 {
      audio.pcm.put16le(&fmt, 0)
    }
  }
  var body = "WAVE".bytes()
  chunk(&body, "fmt ", fmt)
  if tag != 1 {
    var fact: [int] = []
    audio.pcm.put32le(&fact, n)
    chunk(&body, "fact", fact)
  }
  var info = "INFO".bytes()
  for (id, name) in INFO {
    let v = a.tags.get(name) else ""
    if v != "" { chunk(&info, id, v.bytes() + [0]) }
  }
  if info.len() > 4 { chunk(&body, "LIST", info) }
  // the data chunk comes last, so the file is the RIFF header, `body`, then that chunk
  let dlen = if direct { n * audio.pcm.width(f) * nch } else { data.len() }
  var out = "RIFF".bytes()
  audio.pcm.put32le(&out, body.len() + 8 + dlen + (dlen & 1))
  out = out + body + "data".bytes()
  audio.pcm.put32le(&out, dlen)
  if direct { audio.pcm.encode_into(&out, a.chans, f, false) } else { out = out + data }
  if (dlen & 1) == 1 { out.push(0) }
  out
}
