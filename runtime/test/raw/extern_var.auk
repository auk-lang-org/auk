// `extern var`: C data defined elsewhere (libc's `environ`; on macOS also the block runtime's
// `_NSConcreteGlobalBlock`, by address).

extern var environ: raw.Ptr<raw.Ptr<u8>> = "environ"

fn run(): int uses raw {
  if environ.is_null() || environ.load().is_null() { return 1 }
  let first = environ.load()
  if first.at(0) == 0 { return 2 }
  0
}

fn main(): int uses raw = run()
