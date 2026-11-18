/// The core prelude (`compiler/prelude/*.auk`) compiled into the binary, as Rust's `include_str!`
/// does, so the compiler needs no checkout: one `#embed` per file.

extern fn prelude_core(): str = "#embed ../prelude/core.auk"
extern fn prelude_fs(): str = "#embed ../prelude/fs.auk"
extern fn prelude_net(): str = "#embed ../prelude/net.auk"
extern fn prelude_time(): str = "#embed ../prelude/time.auk"
extern fn prelude_rand(): str = "#embed ../prelude/rand.auk"
extern fn prelude_env(): str = "#embed ../prelude/env.auk"
extern fn prelude_proc(): str = "#embed ../prelude/proc.auk"
extern fn prelude_audio_out(): str = "#embed ../prelude/audio_out.auk"
extern fn prelude_gui(): str = "#embed ../prelude/gui.auk"
extern fn prelude_pixels(): str = "#embed ../prelude/pixels.auk"
extern fn prelude_str(): str = "#embed ../prelude/str.auk"
extern fn prelude_int(): str = "#embed ../prelude/int.auk"
extern fn prelude_float(): str = "#embed ../prelude/float.auk"
extern fn prelude_ffi(): str = "#embed ../prelude/ffi.auk"

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
