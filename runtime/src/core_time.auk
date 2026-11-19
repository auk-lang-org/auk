/// The core library's `time` and `rand` (was runtime/c/core.c, ported line by line). rand is
/// xoshiro256**, one generator for the process behind a mutex, seeded from the OS CSPRNG
/// (`core_os.os_random`) on first use unless `rand.seed` came first.

// the rest of the runtime (C, for now)
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn auk__sleep_ms(ms: i64) = "void auk__sleep_ms(int64_t)"
extern fn auk_hash_int(x: i64): u64 = "uint64_t auk_hash_int(int64_t)"
extern fn auk__panic3(loc: raw.Ptr<u8>, a: raw.Ptr<u8>, b: raw.Ptr<u8>, c: raw.Ptr<u8>): never =
  "void auk__panic3(const char *, const char *, const char *, const char *)"
// libc
extern fn clock_gettime(clock: i32, ts: raw.Ptr<cfacts.Timespec>): i32 = "int clock_gettime(int, void *)"
extern fn getpid(): i32 = "int getpid(void)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"

// ---- time ----

export fn auk_time_now(): i64 uses raw, ffi {
  var ts = cfacts.Timespec {}
  clock_gettime(cfacts.CLOCK_REALTIME, raw.addr_of(&ts))
  ts.tv_sec * 1000 + ts.tv_nsec / 1000000
}

export fn auk_time_sleep(ms: i64) uses ffi {
  if ms > 0 {
    auk__sleep_ms(ms)
  }
}

// ---- rand (xoshiro256**, seeded from the OS CSPRNG) ----

raw var rand_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var rand_s: [u64; 4] = [0, 0, 0, 0]
raw var rand_seeded: bool = false

/// 32 bytes (C's `uint8_t b[32]`).
raw struct Seed {
  b: [u64; 4],
}

fn rotl(x: u64, k: u64): u64 = (x << k) | (x >> (64 - k))

fn rand_next(): u64 uses raw, ffi {
  pthread_mutex_lock(raw.addr_of(&rand_lock))
  let s: raw.Ptr<u64> = raw.cast(raw.addr_of(&rand_s))
  if !rand_seeded {
    var b = Seed {}
    if core_os.os_random(raw.cast(raw.addr_of(&b)), 32) {
      raw.copy(s, raw.addr_of(&b), 32)
    } else {
      let t = u64(auk_time_now()) ^ (u64(getpid()) << 32)
      var i: u64 = 0
      while i < 4 {
        s.at(i) = auk_hash_int(i64(t + i))
        i += 1
      }
    }
    if (s.at(0) | s.at(1) | s.at(2) | s.at(3)) == 0 {
      s.at(0) = 1
    }
    rand_seeded = true
  }
  let r = rotl(s.at(1) * 5, 7) * 9
  let t = s.at(1) << 17
  s.at(2) = s.at(2) ^ s.at(0)
  s.at(3) = s.at(3) ^ s.at(1)
  s.at(1) = s.at(1) ^ s.at(2)
  s.at(0) = s.at(0) ^ s.at(3)
  s.at(2) = s.at(2) ^ t
  s.at(3) = rotl(s.at(3), 45)
  pthread_mutex_unlock(raw.addr_of(&rand_lock))
  r
}

export fn auk_rand_int(lo: i64, hi: i64): i64 uses raw, ffi {
  if lo > hi {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "rand.int(")
    str_fmt.auk_sb_int(mp, lo)
    str.auk__sb_put_cstr(mp, ", ")
    str_fmt.auk_sb_int(mp, hi)
    str.auk__sb_put_cstr(mp, "): lo > hi")
    str.auk__panic_sb("rand.int", mp)
  }
  let span = u64(hi) - u64(lo) + 1 // 0 means the full 2^64 range
  if span == 0 {
    return i64(rand_next())
  }
  let max: u64 = 18446744073709551615 // UINT64_MAX
  let limit = max - max % span
  var x = rand_next()
  while x >= limit {
    x = rand_next()
  }
  i64(u64(lo) + x % span)
}

export fn auk_rand_float(): float uses raw, ffi = float(rand_next() >> 11) * (1.0 / 9007199254740992.0) // 0x1.0p-53

export fn auk_rand_seed(seed: i64) uses raw, ffi {
  var x = u64(seed)
  pthread_mutex_lock(raw.addr_of(&rand_lock))
  let s: raw.Ptr<u64> = raw.cast(raw.addr_of(&rand_s))
  var i: i64 = 0
  while i < 4 {
    // splitmix64
    x += 0x9E3779B97F4A7C15
    var z = x
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    s.at(i) = z ^ (z >> 31)
    i += 1
  }
  if (s.at(0) | s.at(1) | s.at(2) | s.at(3)) == 0 {
    s.at(0) = 1
  }
  rand_seeded = true
  let _ = pthread_mutex_unlock(raw.addr_of(&rand_lock))
}

export fn auk_rand_bytes(n: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Arr> uses raw, ffi {
  if n < 0 {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "rand.bytes(")
    str_fmt.auk_sb_int(mp, n)
    str.auk__sb_put_cstr(mp, "): negative count")
    str.auk__panic_sb(loc, mp)
  }
  let buf: raw.Ptr<u8> = raw.cast(auk__xmalloc(usize(n) + 1))
  if !core_os.os_random(buf, usize(n)) {
    auk__panic3(loc, "rand.bytes: no OS random source available", raw.null(), raw.null())
  }
  let a = core_util.auk__bytes_to_arr(buf, n)
  raw.free(buf)
  a
}
