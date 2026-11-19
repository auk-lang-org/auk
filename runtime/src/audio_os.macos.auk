/// audio_out's macOS half: AudioToolbox's AudioQueue, loaded with dlopen on first use (was the
/// `__APPLE__` half of runtime/c/audio_out.c). The Linux half is audio_os.linux.auk.

// the rest of the runtime (C, for now)
extern fn auk__task_cancelled(): bool = "bool auk__task_cancelled(void)"
// libc
extern fn dlopen(path: raw.Ptr<u8>, mode: i32): raw.Ptr<()> = "void *dlopen(const char *, int)"
extern fn dlsym(handle: raw.Ptr<()>, name: raw.Ptr<u8>): raw.Ptr<()> = "void *dlsym(void *, const char *)"
extern fn pthread_once(once: raw.Ptr<cfacts.PthreadOnce>, f: raw.Fn<() => ()>): i32 = "int pthread_once(pthread_once_t *, void (*)(void))"
extern fn nanosleep(req: raw.Ptr<cfacts.Timespec>, rem: raw.Ptr<cfacts.Timespec>): i32 = "int nanosleep(const void *, void *)"

/// Samples are handed to AudioQueue in buffers of this many frames.
raw let CHUNK: i64 = 4096

/// C: AudioStreamBasicDescription
raw struct Asbd {
  sample_rate: float,
  format_id: u32,
  format_flags: u32,
  bytes_per_packet: u32,
  frames_per_packet: u32,
  bytes_per_frame: u32,
  channels_per_frame: u32,
  bits_per_channel: u32,
  reserved: u32,
}

raw assert raw.size_of<Asbd>() == 40

/// C: AudioQueueBuffer
raw struct AqBuffer {
  capacity: u32,
  data: raw.Ptr<()>,
  size: u32,
  user: raw.Ptr<()>,
  desc_capacity: u32,
  descs: raw.Ptr<()>,
  desc_count: u32,
}

/// C: AudioQueueOutputCallback
raw type AqCallback = raw.Fn<(raw.Ptr<()>, raw.Ptr<()>, raw.Ptr<AqBuffer>) => ()>

/// The AudioQueue functions (an AudioQueueRef is a raw.Ptr<()>).
raw struct AqApi {
  new_output: raw.Fn<(raw.Ptr<Asbd>, AqCallback, raw.Ptr<()>, raw.Ptr<()>, raw.Ptr<()>, u32, raw.Ptr<raw.Ptr<()>>) => i32>,
  allocate: raw.Fn<(raw.Ptr<()>, u32, raw.Ptr<raw.Ptr<AqBuffer>>) => i32>,
  enqueue: raw.Fn<(raw.Ptr<()>, raw.Ptr<AqBuffer>, u32, raw.Ptr<()>) => i32>,
  start: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => i32>,
  stop: raw.Fn<(raw.Ptr<()>, u8) => i32>,
  dispose: raw.Fn<(raw.Ptr<()>, u8) => i32>,
  get_property: raw.Fn<(raw.Ptr<()>, u32, raw.Ptr<()>, raw.Ptr<u32>) => i32>,
}

raw let LPCM: u32 = 0x6c70636d // 'lpcm'
raw let FLOAT_PACKED: u32 = 9 // kAudioFormatFlagIsFloat | IsPacked
raw let IS_RUNNING: u32 = 0x6171726e // 'aqrn'

/// Every buffer is enqueued up front, so nothing needs refilling when one finishes.
fn aq_done(user: raw.Ptr<()>, q: raw.Ptr<()>, b: raw.Ptr<AqBuffer>) {}

raw var aq: AqApi = AqApi {}
raw var aq_ok: bool = false
raw var aq_once: cfacts.PthreadOnce = cfacts.PTHREAD_ONCE_INIT

fn aq_load() uses raw, ffi {
  let lib = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", cfacts.RTLD_LAZY)
  if lib.is_null() {
    return
  }
  let a = raw.addr_of(&aq)
  a.new_output = raw.cast(dlsym(lib, "AudioQueueNewOutput"))
  a.allocate = raw.cast(dlsym(lib, "AudioQueueAllocateBuffer"))
  a.enqueue = raw.cast(dlsym(lib, "AudioQueueEnqueueBuffer"))
  a.start = raw.cast(dlsym(lib, "AudioQueueStart"))
  a.stop = raw.cast(dlsym(lib, "AudioQueueStop"))
  a.dispose = raw.cast(dlsym(lib, "AudioQueueDispose"))
  a.get_property = raw.cast(dlsym(lib, "AudioQueueGetProperty"))
  aq_ok = !a.new_output.is_null() && !a.allocate.is_null() && !a.enqueue.is_null() && !a.start.is_null() &&
    !a.stop.is_null() && !a.dispose.is_null() && !a.get_property.is_null()
}

fn sleep_ms(ms: i64) uses raw, ffi {
  var ts = cfacts.Timespec { tv_sec: 0, tv_nsec: ms * 1000000 }
  let _ = nanosleep(raw.addr_of(&ts), raw.null())
}

fn aq_fail(fb: raw.Ptr<u8>, q: raw.Ptr<()>, what: raw.Ptr<u8>, st: i32): bool uses raw, ffi {
  let dispose = aq.dispose
  let _ = dispose(q, 1)
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  str.auk__sb_put_cstr(mp, what)
  str.auk__sb_put_cstr(mp, " error ")
  str_fmt.auk_sb_int(mp, i64(st))
  str_fmt.auk__sb_take_into(mp, fb, raw.size_of<audio_out.AudioFail>())
  false
}

/// Play n samples xs (nch channels) at rate Hz: true once heard, or false with the reason in fb
/// (an audio_out.AudioFail).
pub fn play(xs: raw.Ptr<float>, n: i64, nch: i64, rate: i64, fb: raw.Ptr<u8>): bool uses raw, ffi {
  let _ = pthread_once(raw.addr_of(&aq_once), raw.fn_of(aq_load))
  if !aq_ok {
    str_fmt.auk__cstr_copy(fb, raw.size_of<audio_out.AudioFail>(), "could not load AudioToolbox")
    return false
  }
  var fmt = Asbd {
    sample_rate: float(rate), format_id: LPCM, format_flags: FLOAT_PACKED,
    bytes_per_packet: u32(4 * nch), frames_per_packet: 1, bytes_per_frame: u32(4 * nch),
    channels_per_frame: u32(nch), bits_per_channel: 32, reserved: 0,
  }
  var q: raw.Ptr<()> = raw.null()
  let new_output = aq.new_output
  var st = new_output(raw.addr_of(&fmt), raw.fn_of(aq_done), raw.null(), raw.null(), raw.null(), 0, raw.addr_of(&q))
  if st != 0 || q.is_null() {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "no output device (AudioQueueNewOutput error ")
    str_fmt.auk_sb_int(mp, i64(st))
    str.auk__sb_put_cstr(mp, ")")
    str_fmt.auk__sb_take_into(mp, fb, raw.size_of<audio_out.AudioFail>())
    return false
  }
  let allocate = aq.allocate
  let enqueue = aq.enqueue
  let per = CHUNK * nch
  var off: i64 = 0
  while off < n {
    let len = if n - off < per { n - off } else { per }
    let bytes = u32(len * 4)
    var b: raw.Ptr<AqBuffer> = raw.null()
    st = allocate(q, bytes, raw.addr_of(&b))
    if st != 0 || b.is_null() {
      return aq_fail(fb, q, "AudioQueueAllocateBuffer", st)
    }
    let d: raw.Ptr<f32> = raw.cast(b.data)
    var i: i64 = 0
    while i < len {
      d.at(i) = audio_out.to_f32(xs.at(off + i))
      i += 1
    }
    b.size = bytes
    st = enqueue(q, b, 0, raw.null())
    if st != 0 {
      return aq_fail(fb, q, "AudioQueueEnqueueBuffer", st)
    }
    off += per
  }
  let start = aq.start
  st = start(q, raw.null())
  if st != 0 {
    return aq_fail(fb, q, "AudioQueueStart", st)
  }
  // Stop once the queued buffers have played; the queue reports it stopped running then.
  let stop = aq.stop
  let _ = stop(q, 0)
  let frames = n / nch
  let dur_ms = i64(u64(frames) * 1000 / u64(rate))
  let get_property = aq.get_property
  var waited: i64 = 0
  loop {
    if auk__task_cancelled() {
      break
    }
    if waited >= dur_ms {
      var running: u32 = 0
      var size: u32 = 4
      st = get_property(q, IS_RUNNING, raw.cast(raw.addr_of(&running)), raw.addr_of(&size))
      // a stuck queue shouldn't hang the program: give it two seconds past the end
      if st != 0 || running == 0 || waited >= dur_ms + 2000 {
        break
      }
    }
    sleep_ms(10)
    waited += 10
  }
  let dispose = aq.dispose
  let _ = dispose(q, 1)
  true
}
