/// The Auk compiler written in Auk: the `auk` command (src/main.rs) with the commands the port
/// has — `run`, `build`, `test`, `check`, `ir`, `fmt`, `holes`, `explain`, `spec`, `lsp`, `mcp`,
/// and the hidden `__jit` and `dump tokens|ast|resolve|check|typed` — with the Rust CLI's flags,
/// output and exit codes. The prelude (`embedded`), the language reference (`mcp.spec_main`) and
/// the error pages (`error_pages`) are compiled in, so the binary needs no checkout.
///
/// The port's own oracles and timing commands:
/// - `compiler tokens|ast|resolve|check|typed [--quiet] [--time] [--repeat N] [--core] [--all]
///   <file>...` prints what `auk dump tokens|ast|resolve|check|typed` prints (`check` with
///   several files, or with a timing option, prints `auk dump check`'s report of the type
///   checker alone; `typed --core`: core modules' tables too). `--quiet` does the work without
///   printing (`check --quiet` runs the type checker alone, with `--all` all of `auk check`),
///   `--repeat N` does the whole job N times, and `--time` prints the time per repetition (file
///   reading excluded) to stderr.
/// - `compiler ir [--imprint-eval] [--time] [--quiet] [--repeat N] ...`: see `drive.ir_opts`.
/// - `compiler mir|llvm|build-mir|run-mir <mir dump>`: the back end on the Rust compiler's MIR
///   (`driver`).

let USAGE_TEXT = """
usage: auk <command> [args]

commands:
  run [-O] [--trace=json|<file>] <file> [args...]
                           compile and run the program (-O: optimize fully, slower to
                           start; --trace: log calls, returns, errors, peeks and panics
                           as JSON lines; json = stderr)
  run --debug <file> [args...]
                           build with debugger hooks; a front end attaches through
                           AUK_DEBUG=<unix socket> (see docs/compiler.md, Debugger)
  debug [--break <file:line|fn>]... [--print a,b] [--json] <file> [args...]
                           debug the program: an interactive prompt on a terminal;
                           otherwise (or --json/--batch) run to each breakpoint and
                           panic and report the locals and stack there
  dap                      the Debug Adapter Protocol on stdin/stdout (editors' debuggers)
  run --live <file> [args...]
                           run, swapping in new code on every save (state survives;
                           a changed struct/enum layout restarts the tasks using it)
  build [-g] <file> [-o out]
                           compile to a native executable (release; refuses `??` holes;
                           -g: DWARF line tables for lldb/gdb, on macOS in <out>.dSYM)
  check <file> [--json]    type-check only (no codegen); --json for machine-readable output
  test [--trace=json|<dir>] [file|dir] [filter]
                           build and run the `test` blocks of a file or project
                           (--trace=json: each FAIL shows its trace's last events;
                           --trace=<dir>: one <test>.jsonl trace per test)
  --trace-limit N          (run/test) stop a trace after N events (default 10000)
  --trace-core             (run/test) trace core library functions too
  fmt [--check] <path>...  format .auk files in place (`-` = stdin to stdout)
  holes <file> [--json]    brief every `??` hole: expected type, scope, contracts, tests
  hatch <file> [--hole N] [--tries 3] [--dry-run]
                           fill holes with an AI model, checked and tested (AUK_HATCH_CMD)
  explain [E0xxx]          explain an error code (with no code: list every code)
  dive [--quiet]           the interactive REPL (--quiet: no banner or prompts)
  lsp                      run the language server (LSP over stdio)
  mcp                      run the MCP server for AI agents (tools over stdio)
  ir [--llvm] <file>       print the program's MIR (--llvm: its LLVM IR)
  spec                     print the compact language reference

packages are managed by `raft` (see docs/raft.md).

environment:
  AUK_LEAK_CHECK=1        `run`/`test` programs fail if runtime objects leak
  AUK_LINKER              the linker `build` uses (default: cc)
  AUK_HATCH_CMD           the model command `hatch` runs, prompt on stdin (default: claude -p)
"""

fn usage(): str = USAGE_TEXT.strip_suffix("\n") else USAGE_TEXT

/// The commands of the Rust `auk` that the port doesn't have yet (Phase 5).
let NOT_PORTED = ["debug", "dap"]

/// The port's dump modes (`compiler <mode>`, or `auk dump <mode>`).
let MODES = ["tokens", "ast", "resolve", "check", "typed"]

fn main(args: [str]): int! uses fs, env, time, ffi, proc {
  if args.len() < 2 {
    eprint(usage())
    return 2
  }
  let cmd = args[1]
  let rest = args.skip(2)
  let cx = resolve.Sources { prelude: embedded.prelude(), overrides: {}, os: paths.os() }
  match cmd {
    "spec" => return mcp.spec_main()
    "explain" => return explain.run(rest)
    "lsp" => return lsp.run(cx)
    "mcp" => return mcp.run(args[0])
    "fmt" => return fmt.run(rest)
    "hatch" => return hatch.run(args[0], cx, rest)
    "dive" => return dive.run(cx, rest)
    "holes" => {
      if rest.len() == 1 { return holes.run(cx, rest[0], false) }
      if rest.len() == 2 && rest[1] == "--json" { return holes.run(cx, rest[0], true) }
      if rest.len() == 2 && rest[0] == "--json" { return holes.run(cx, rest[1], true) }
      eprint("usage: auk holes <file> [--json]")
      return 2
    }
    "check" => {
      if rest.len() == 1 { return cli.check_file(cx, rest[0], false) }
      if rest.len() == 2 && rest[1] == "--json" { return cli.check_file(cx, rest[0], true) }
      // the port's timing and multi-file forms
      if rest.any(a => a == "--quiet" || a == "--time" || a == "--repeat") {
        return dev(cx, cmd, rest)
      }
      eprint(usage())
      return 2
    }
    "run" | "build" | "ir" | "test" => return drive.cli(cx, cmd, rest)
    "__jit" => return drive.jit_cli(cx, rest)
    "dump" => {
      let mode = rest.get(0) else ""
      if !MODES.contains(mode) {
        eprint("usage: auk dump tokens|ast|resolve|check|typed <file>")
        return 2
      }
      return dev(cx, mode, rest.skip(1))
    }
    "mir" | "llvm" | "build-mir" | "run-mir" => return driver.main(args)
    "help" | "-h" | "--help" => {
      print(usage())
      return 0
    }
    _ => {}
  }
  if MODES.contains(cmd) && rest.len() > 0 { return dev(cx, cmd, rest) }
  if NOT_PORTED.contains(cmd) {
    eprint("error: `auk {cmd}` is not in the self-hosted compiler yet (use the Rust `auk`)")
    return 2
  }
  eprint(usage())
  2
}

/// The port's dump modes: `what` (tokens, ast, resolve, check, typed) of each file.
fn dev(cx: resolve.Sources, what: str, rest: [str]): int! uses fs, time, ffi {
  let quiet = rest.contains("--quiet")
  let time_it = rest.contains("--time")
  let core = rest.contains("--core")
  var repeat = 1
  var files: [str] = []
  for i, a in rest {
    if a == "--repeat" {
      repeat = int.parse(rest.get(i + 1) else "1") else 1
    } else if !a.starts_with("--") && (i == 0 || rest[i - 1] != "--repeat") {
      files.push(a)
    }
  }
  var srcs: [str] = []
  for f in files { srcs.push(fs.read(f)?) }
  let cwd = paths.cwd()
  let t0 = time.now()
  var out: [str] = []
  for _ in 0..repeat {
    for i, f in files {
      let src = srcs[i]
      if files.len() > 1 && !quiet { out.push("== {f}") }
      if what == "check" || what == "typed" {
        let r = resolve.load_in_package(cx, f, src)
        if quiet {
          match r {
            ok(p) => if rest.contains("--all") { let _ = check.check_all(p) } else { let _ = check.check_types(p) }
            err(_) => {}
          }
        } else if what == "check" {
          out.push(dump.checked(f, r))
        } else {
          dump.typed_program(&out, cwd, r, core)
        }
      } else if what == "resolve" {
        let r = resolve.load_in_package(cx, f, src)
        if !quiet { dump.resolved(&out, cwd, r) }
      } else if what == "tokens" {
        match lexer.lex(src) {
          ok(lx) => if !quiet { dump.tokens(&out, lx.module_doc, lx.toks) }
          err(Bad(d)) => if !quiet { dump.diag_dump(&out, d) }
        }
      } else {
        let parts = f.split("/")
        let prelude = parts.len() >= 2 && parts[parts.len() - 2] == "prelude"
        match parser.parse(src, prelude) {
          ok(m) => if !quiet { dump.module(&out, m) }
          err(Many(ds)) => if !quiet {
            for d in ds { dump.diag_dump(&out, d) }
          }
        }
      }
    }
  }
  if out.len() > 0 { print(out.join("\n")) }
  if time_it { eprint("time: {(time.now() - t0) * 1000 / repeat} us") }
  0
}
