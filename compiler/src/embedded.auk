/// The core prelude (`src/prelude/*.auk`) compiled into the binary, as Rust's `include_str!`
/// does, so the compiler needs no checkout: one `#embed` per file.

extern fn prelude_core(): str = "#embed ../../src/prelude/core.auk"
extern fn prelude_fs(): str = "#embed ../../src/prelude/fs.auk"
extern fn prelude_net(): str = "#embed ../../src/prelude/net.auk"
extern fn prelude_time(): str = "#embed ../../src/prelude/time.auk"
extern fn prelude_rand(): str = "#embed ../../src/prelude/rand.auk"
extern fn prelude_env(): str = "#embed ../../src/prelude/env.auk"
extern fn prelude_proc(): str = "#embed ../../src/prelude/proc.auk"
extern fn prelude_audio_out(): str = "#embed ../../src/prelude/audio_out.auk"
extern fn prelude_gui(): str = "#embed ../../src/prelude/gui.auk"
extern fn prelude_pixels(): str = "#embed ../../src/prelude/pixels.auk"
extern fn prelude_str(): str = "#embed ../../src/prelude/str.auk"
extern fn prelude_int(): str = "#embed ../../src/prelude/int.auk"
extern fn prelude_float(): str = "#embed ../../src/prelude/float.auk"
extern fn prelude_ffi(): str = "#embed ../../src/prelude/ffi.auk"

/// The prelude texts, (module name, source), in `resolve.PRELUDE` order.
pub fn prelude(): [(str, str)] uses ffi = [
  ("core", prelude_core()),
  ("fs", prelude_fs()),
  ("net", prelude_net()),
  ("time", prelude_time()),
  ("rand", prelude_rand()),
  ("env", prelude_env()),
  ("proc", prelude_proc()),
  ("audio_out", prelude_audio_out()),
  ("gui", prelude_gui()),
  ("pixels", prelude_pixels()),
  ("str", prelude_str()),
  ("int", prelude_int()),
  ("float", prelude_float()),
  ("ffi", prelude_ffi()),
]

test "the embedded prelude is resolve.PRELUDE" {
  assert prelude().map(p => p.0) == resolve.PRELUDE
  assert prelude().all(p => p.1.len() > 0)
}
