/// Sound output (`uses audio_out`): play interleaved float samples on the default output device
/// (was runtime/c/audio_out.c, ported line by line).
///
/// The system audio library is loaded with dlopen on first use, so programs that never play
/// sound don't load it: AudioToolbox's AudioQueue on macOS, PulseAudio's simple API
/// (libpulse-simple.so.0, also served by PipeWire) elsewhere; that half is `audio_os`
/// (`audio_os.macos.auk`, `audio_os.linux.auk`). Playback blocks the calling task until the sound
/// has finished, waking every few milliseconds so a cancelled task stops at once.

// the rest of the runtime (C, for now)
extern fn auk__check_cancel(loc: raw.Ptr<u8>) = "void auk__check_cancel(const char *)"

/// x clamped to -1..1 as a float (NaN stays NaN).
pub fn to_f32(x: float): f32 {
  if x < -1.0 {
    return f32(-1.0)
  }
  if x > 1.0 {
    return f32(1.0)
  }
  f32(x)
}

/// The reason playback failed (a C string in b).
pub raw struct AudioFail {
  b: [u8; 256],
}

fn audio_err(m: raw.Ptr<abi.StrBuf>): abi.ResUnit uses raw, ffi =
  abi.ResUnit { err: str.auk__err_sb(m) }

/// Play samples (interleaved, channels per frame, nominally -1.0..1.0) at rate Hz and return
/// once they have been heard. An Err if the arguments are invalid or no output device can be
/// opened.
export fn auk_audio_out_play(samples: raw.Ptr<abi.Arr>, channels: i64, rate: i64, loc: raw.Ptr<u8>): abi.ResUnit uses raw, ffi {
  let n = arr.auk_arr_len(samples)
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  str.auk__sb_put_cstr(mp, "audio_out.play: ")
  if channels < 1 || channels > 32 {
    str_fmt.auk_sb_int(mp, channels)
    str.auk__sb_put_cstr(mp, " channels (expected 1 to 32)")
    return audio_err(mp)
  }
  if rate < 1 || rate > 768000 {
    str.auk__sb_put_cstr(mp, "sample rate ")
    str_fmt.auk_sb_int(mp, rate)
    str.auk__sb_put_cstr(mp, " (expected 1 to 768000)")
    return audio_err(mp)
  }
  if n % channels != 0 {
    str_fmt.auk_sb_int(mp, n)
    str.auk__sb_put_cstr(mp, " samples is not a whole number of ")
    str_fmt.auk_sb_int(mp, channels)
    str.auk__sb_put_cstr(mp, "-channel frames")
    return audio_err(mp)
  }
  if n == 0 {
    str.auk_sb_free(mp)
    return abi.ResUnit { ok: true }
  }
  var f = AudioFail {}
  let fb: raw.Ptr<u8> = raw.cast(raw.addr_of(&f))
  if audio_os.play(raw.cast(samples.data), n, channels, rate, fb) {
    str.auk_sb_free(mp)
    auk__check_cancel(loc)
    return abi.ResUnit { ok: true }
  }
  str.auk__sb_put_cstr(mp, fb)
  audio_err(mp)
}
