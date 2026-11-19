/// The window process on Linux: there are no windows here yet (gui.open fails before starting
/// one), so a host started anyway says so and exits (was the non-`__APPLE__` path of
/// runtime/c/gui_host.c). The macOS host is gui_host.macos.auk.

extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
extern fn unsetenv(name: raw.Ptr<u8>): i32 = "int unsetenv(const char *)"
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn fputs(s: raw.Ptr<u8>, f: raw.Ptr<()>): i32 = "int fputs(const char *, FILE *)"

/// Run the window process. Returns an exit code only if it can't start.
pub export fn auk__gui_host_main(): i32 uses raw, ffi {
  let v = getenv("AUK_GUI_HOST")
  let n: usize = if v.is_null() { 0 } else { strlen(v) }
  let spec: raw.Ptr<u8> = raw.cast(auk__xmalloc(n + 1))
  if n > 0 {
    raw.copy(spec, v, n)
  }
  spec.at(n) = 0
  let _ = unsetenv("AUK_GUI_HOST")
  let _ = fputs("gui: windows are only supported on macOS so far\n", cfacts.stderr())
  raw.free(spec)
  1
}
