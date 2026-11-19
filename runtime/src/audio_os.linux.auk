/// audio_out's Linux half: PulseAudio's simple API (libpulse-simple.so.0, also served by
/// PipeWire), loaded with dlopen on first use (was the non-`__APPLE__` half of
/// runtime/c/audio_out.c). The macOS half is audio_os.macos.auk.

// the rest of the runtime (C, for now)
extern fn auk__task_cancelled(): bool = "bool auk__task_cancelled(void)"
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
// libc
extern fn dlopen(path: raw.Ptr<u8>, mode: i32): raw.Ptr<()> = "void *dlopen(const char *, int)"
extern fn dlsym(handle: raw.Ptr<()>, name: raw.Ptr<u8>): raw.Ptr<()> = "void *dlsym(void *, const char *)"
extern fn pthread_once(once: raw.Ptr<cfacts.PthreadOnce>, f: raw.Fn<() => ()>): i32 = "int pthread_once(pthread_once_t *, void (*)(void))"

/// C: pa_sample_spec
raw struct PaSpec {
  format: i32,
  rate: u32,
  channels: u8,
}

/// The pa_simple functions (a pa_simple * is a raw.Ptr<()>).
raw struct PaApi {
  new_: raw.Fn<(raw.Ptr<u8>, raw.Ptr<u8>, i32, raw.Ptr<u8>, raw.Ptr<u8>, raw.Ptr<PaSpec>, raw.Ptr<()>, raw.Ptr<()>, raw.Ptr<i32>) => raw.Ptr<()>>,
  write: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>, usize, raw.Ptr<i32>) => i32>,
  drain: raw.Fn<(raw.Ptr<()>, raw.Ptr<i32>) => i32>,
  flush: raw.Fn<(raw.Ptr<()>, raw.Ptr<i32>) => i32>,
  free_: raw.Fn<(raw.Ptr<()>) => ()>,
  strerror_: raw.Fn<(i32) => raw.Ptr<u8>>,
}

raw let PA_PLAYBACK: i32 = 1
/// PA_SAMPLE_FLOAT32LE: every Linux target (arm64, x86-64) is little-endian (the C chose
/// PA_SAMPLE_FLOAT32BE, 6, by `__BYTE_ORDER__`).
raw let PA_FLOAT32: i32 = 5

raw var pa: PaApi = PaApi {}
raw var pa_ok: bool = false
raw var pa_once: cfacts.PthreadOnce = cfacts.PTHREAD_ONCE_INIT

fn pa_load() uses raw, ffi {
  let lib = dlopen("libpulse-simple.so.0", cfacts.RTLD_LAZY)
  let base = dlopen("libpulse.so.0", cfacts.RTLD_LAZY)
  if lib.is_null() || base.is_null() {
    return
  }
  let a = raw.addr_of(&pa)
  a.new_ = raw.cast(dlsym(lib, "pa_simple_new"))
  a.write = raw.cast(dlsym(lib, "pa_simple_write"))
  a.drain = raw.cast(dlsym(lib, "pa_simple_drain"))
  a.flush = raw.cast(dlsym(lib, "pa_simple_flush"))
  a.free_ = raw.cast(dlsym(lib, "pa_simple_free"))
  a.strerror_ = raw.cast(dlsym(base, "pa_strerror"))
  pa_ok = !a.new_.is_null() && !a.write.is_null() && !a.drain.is_null() && !a.flush.is_null() &&
    !a.free_.is_null() && !a.strerror_.is_null()
}

/// Play n samples xs (nch channels) at rate Hz: true once heard, or false with the reason in fb
/// (an audio_out.AudioFail).
pub fn play(xs: raw.Ptr<float>, n: i64, nch: i64, rate: i64, fb: raw.Ptr<u8>): bool uses raw, ffi {
  let _ = pthread_once(raw.addr_of(&pa_once), raw.fn_of(pa_load))
  let cap = raw.size_of<audio_out.AudioFail>()
  if !pa_ok {
    str_fmt.auk__cstr_copy(fb, cap, "could not load libpulse-simple.so.0 (PulseAudio or PipeWire)")
    return false
  }
  let strerror_ = pa.strerror_
  var spec = PaSpec { format: PA_FLOAT32, rate: u32(rate), channels: u8(nch) }
  var e: i32 = 0
  let new_ = pa.new_
  let s = new_(raw.null(), "auk", PA_PLAYBACK, raw.null(), "audio_out", raw.addr_of(&spec), raw.null(), raw.null(), raw.addr_of(&e))
  if s.is_null() {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "no output device (")
    str.auk__sb_put_cstr(mp, strerror_(e))
    str.auk__sb_put_cstr(mp, ")")
    str_fmt.auk__sb_take_into(mp, fb, cap)
    return false
  }
  let write = pa.write
  let flush = pa.flush
  let free_ = pa.free_
  // small chunks, so a cancelled task stops within a chunk
  let per = (if rate / 50 > 1 { rate / 50 } else { i64(1) }) * nch
  let buf: raw.Ptr<f32> = raw.cast(auk__xmalloc(usize(per) * 4))
  var off: i64 = 0
  while off < n {
    if auk__task_cancelled() {
      let _ = flush(s, raw.addr_of(&e))
      free_(s)
      raw.free(buf)
      return true
    }
    let len = if n - off < per { n - off } else { per }
    var i: i64 = 0
    while i < len {
      buf.at(i) = audio_out.to_f32(xs.at(off + i))
      i += 1
    }
    if write(s, raw.cast(buf), usize(len) * 4, raw.addr_of(&e)) < 0 {
      free_(s)
      raw.free(buf)
      str_fmt.auk__cstr_copy(fb, cap, strerror_(e))
      return false
    }
    off += per
  }
  raw.free(buf)
  let drain = pa.drain
  let r = drain(s, raw.addr_of(&e))
  free_(s)
  if r < 0 {
    str_fmt.auk__cstr_copy(fb, cap, strerror_(e))
    return false
  }
  true
}
