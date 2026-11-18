/// The back end's commands (Phase 4), on a MIR program the Rust compiler wrote
/// (`auk dump mir [--release] [-g] [--trace..] [--debug] <file>`):
///
/// - `compiler mir <dump>`: the MIR as C-like text, as `auk ir <file>` prints it.
/// - `compiler llvm [--level L] <dump>`: the LLVM IR, as `auk ir --llvm=L <file>` prints it
///   (`o0` by default; `light`, `o2`, `o3`, `build`, with an optional `-raw`).
/// - `compiler build <dump> -o <out>`: an executable, as `auk build` makes it (the dump of
///   `auk dump mir --release [-g]`).
/// - `compiler run [--level L] [--argv0 A] <dump> [args...]`: compile in memory (ORC) and run
///   it in this process, as `auk run` does (`light` by default; `argv[0]` is `A`, else the dump).
///
/// Options before the dump: `--time` (the time of the work, reading the dump excluded, to
/// stderr) and `--repeat N` (do it N times; not `run`).

pub fn main(args: [str]): int! uses fs, env, proc, time, ffi {
  let what = args[1]
  var time_it = false
  var repeat = 1
  var level = if what == "run" { "light" } else { "o0" }
  var argv0: str? = none
  var i = 2
  while i < args.len() && args[i].starts_with("--") {
    let a = args[i]
    if a == "--time" {
      time_it = true
    } else if a == "--repeat" && i + 1 < args.len() {
      repeat = int.parse(args[i + 1]) else 1
      i += 1
    } else if a == "--level" && i + 1 < args.len() {
      level = args[i + 1]
      i += 1
    } else if a == "--argv0" && i + 1 < args.len() {
      argv0 = args[i + 1]
      i += 1
    } else {
      return usage(what)
    }
    i += 1
  }
  if i >= args.len() { return usage(what) }
  let file = args[i]
  let rest = args.skip(i + 1)
  let text = fs.read(file)?
  let t0 = time.now()
  if what == "run" {
    let (prog, info) = mir.reader.read(text)?
    let code = match backend.jit(prog, info, level_of(level)?) {
      ok(c) => c
      err(e) => {
        print_to(2, "{e}")
        return 1
      }
    }
    let entry = orcjit.lookup(code, "dk_entry")?
    if time_it { eprint("time: {(time.now() - t0) * 1000} us") }
    let status = orcjit.run(entry, [argv0 else file] + rest)
    orcjit.close(code)
    return status
  }
  if what == "build" {
    if rest.len() != 2 || rest[0] != "-o" { return usage(what) }
    let (prog, info) = mir.reader.read(text)?
    match native.build(prog, info, rest[1]) {
      ok(_) => {}
      err(e) => {
        // the message is a whole `error: ...` report, as `auk build` prints it
        print_to(2, "{e}")
        return 1
      }
    }
    if time_it { eprint("time: {(time.now() - t0) * 1000} us") }
    return 0
  }
  if rest.len() != 0 { return usage(what) }
  var out = ""
  var t_read = 0
  var t_work = 0
  for _ in 0..repeat {
    let t1 = backend.micros()
    let (prog, info) = mir.reader.read(text)?
    let t2 = backend.micros()
    out = if what == "mir" {
      mir.printer.print_program(prog, info)
    } else {
      backend.ir_text(prog, info, level)?
    }
    t_read += t2 - t1
    t_work += backend.micros() - t2
  }
  if time_it {
    eprint("time: read {t_read / repeat} us, {what} {t_work / repeat} us (per repetition)")
  }
  print_raw(out)
  0
}

fn level_of(l: str): backend.Level! = match l {
  "o0" => backend.Level.O0
  "light" => backend.Level.Light
  "o2" => backend.Level.O2
  "o3" => backend.Level.O3
  _ => fail("unknown level `{l}` (o0, light, o2, o3)")
}

fn usage(what: str): int {
  eprint("usage: compiler mir|llvm|build|run [--time] [--repeat N] [--level L] [--argv0 A] <mir dump> [-o out | args...]")
  2
}

/// Write `s` to stdout as is (`print` adds a newline).
fn print_raw(s: str) uses ffi {
  print_to(1, s)
}

extern fn c_write(fd: int, s: str, n: int): int = "long write(int, const char *, size_t)"

/// Write `s` as is to file descriptor `fd`.
fn print_to(fd: int, s: str) uses ffi {
  if c_write(fd, s, s.byte_len()) < 0 { eprint("error: writing the output failed") }
}
