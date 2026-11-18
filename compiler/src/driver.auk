/// The back end's commands (Phase 4), on a MIR program the Rust compiler wrote
/// (`auk dump mir [--release] [-g] [--trace..] [--debug] <file>`):
///
/// - `compiler mir <dump>`: the MIR as C-like text, as `auk ir <file>` prints it.
///
/// Every command takes `--time` (the time of the work, reading the dump excluded, to stderr)
/// and `--repeat N`.

pub fn main(args: [str]): int! uses fs, time, ffi {
  let what = args[1]
  let rest = args.skip(2)
  let time_it = rest.contains("--time")
  var repeat = 1
  var files: [str] = []
  for i, a in rest {
    if a == "--repeat" {
      repeat = int.parse(rest.get(i + 1) else "1") else 1
    } else if !a.starts_with("--") && (i == 0 || rest[i - 1] != "--repeat") {
      files.push(a)
    }
  }
  if files.len() != 1 {
    eprint("usage: compiler {what} [--time] [--repeat N] <mir dump>")
    return 2
  }
  let text = fs.read(files[0])?
  let t0 = time.now()
  var out = ""
  for _ in 0..repeat {
    let (prog, info) = mir.reader.read(text)?
    if what == "mir" { out = mir.printer.print_program(prog, info) }
  }
  if time_it { eprint("time: {(time.now() - t0) * 1000 / repeat} us") }
  if out != "" { print_raw(out) }
  0
}

/// Write `s` to stdout as is (`print` adds a newline).
fn print_raw(s: str) uses ffi {
  let n = c_write(1, s, s.byte_len())
  if n < 0 { eprint("error: writing the output failed") }
}

extern fn c_write(fd: int, s: str, n: int): int = "long write(int, const char *, size_t)"
