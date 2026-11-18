//! The `duck` command: the Duck compiler (lexer → parser → resolve → check → patterns/effects →
//! MIR → LLVM, JIT or object file + the embedded runtime), its formatter, REPL, language
//! server and docs.

mod ast;
mod build;
mod mir;
mod rt_symbols {
    include!(concat!(env!("OUT_DIR"), "/rt_symbols.rs"));
}
mod check;
mod dap;
mod dbg_eval;
mod debug;
mod diag;
mod effects;
mod explain;
mod fmt;
mod hatch;
mod holes;
mod json;
mod lexer;
mod live;
mod lsp;
mod mcp;
mod parser;
mod patterns;
mod repl;
mod resolve;
mod token;
// Parts of the typed program are only read by tests and `duck typed`.
#[allow(dead_code)]
mod typed;
#[allow(dead_code)]
mod types;
mod units;

use std::path::Path;
use std::process::exit;
use std::{env, fs};

/// The compact language reference handed to AI coders (`duck spec`).
const SPEC: &str = include_str!("../docs/spec.md");

const USAGE: &str = "\
usage: duck <command> [args]

commands:
  run [-O] [--trace=json|<file>] <file> [args...]
                           compile and run the program (-O: optimize fully, slower to
                           start; --trace: log calls, returns, errors, peeks and panics
                           as JSON lines; json = stderr)
  run --debug <file> [args...]
                           build with debugger hooks; a front end attaches through
                           DUCK_DEBUG=<unix socket> (see docs/compiler.md, Debugger)
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
  fmt [--check] <path>...  format .duck files in place (`-` = stdin to stdout)
  holes <file> [--json]    brief every `??` hole: expected type, scope, contracts, tests
  hatch <file> [--hole N] [--tries 3] [--dry-run]
                           fill holes with an AI model, checked and tested (DUCK_HATCH_CMD)
  explain [E0xxx]          explain an error code (with no code: list every code)
  pond [--quiet]           the interactive REPL (--quiet: no banner or prompts)
  lsp                      run the language server (LSP over stdio)
  mcp                      run the MCP server for AI agents (tools over stdio)
  ir [--llvm] <file>       print the program's MIR (--llvm: its LLVM IR)
  spec                     print the compact language reference

packages are managed by `quack` (see docs/quack.md).

environment:
  DUCK_LEAK_CHECK=1        `run`/`test` programs fail if runtime objects leak
  DUCK_LINKER              the linker `build` uses (default: cc)
  DUCK_HATCH_CMD           the model command `hatch` runs, prompt on stdin (default: claude -p)";

fn usage() -> ! {
    eprintln!("{USAGE}");
    exit(2)
}

fn main() {
    // started by a `gui.open` in a program run by this command, to own its windows
    if env::var_os("DUCK_GUI_HOST").is_some() {
        std::process::exit(duck_rt::gui_host::host_main());
    }
    let args: Vec<String> = env::args().skip(1).collect();
    let Some((cmd, rest)) = args.split_first() else { usage() };
    let code = match cmd.as_str() {
        "spec" => {
            print!("{SPEC}");
            0
        }
        "explain" => explain::run(rest),
        "pond" => repl::run(rest),
        "lsp" => lsp::run(),
        "mcp" => mcp::run(),
        "fmt" => fmt::run(rest),
        "holes" => holes::run(rest),
        "hatch" => hatch::run(rest),
        "debug" => debug::run(rest),
        "dap" => dap::run(),
        "run" | "build" | "ir" | "test" => build::cli(cmd, rest),
        "__jit" => build::jit_cli(rest),
        "check" => match rest {
            [file] => check_file(file, false),
            [file, flag] if flag == "--json" => check_file(file, true),
            _ => usage(),
        },
        // hidden debug commands, used by the tests
        "parse" => parse_file(rest),
        "typed" => typed_file(rest),
        "help" | "-h" | "--help" => {
            println!("{USAGE}");
            0
        }
        _ => usage(),
    };
    exit(code)
}

/// `duck check`: load the module tree (project, dependencies, core) and type-check it. Returns
/// the exit code. Warnings (E0411) are reported but don't fail the check.
fn check_file(path: &str, json: bool) -> i32 {
    let src = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: cannot read {path}: {e}");
            return 1;
        }
    };
    let diags = match resolve::load_in_package(Path::new(path), src) {
        Ok(prog) => check::check_all(prog).1,
        Err(ds) => ds,
    };
    if json {
        println!("{}", diag::json_report_files(path, &diags));
    } else {
        for d in &diags {
            let src = resolve::source_of(&d.file).unwrap_or_default();
            eprint!("{}", d.diag.render(&d.file, &src));
        }
    }
    if diags.iter().all(|d| d.diag.is_warning()) { 0 } else { 1 }
}

/// `duck parse [--ast | --json] <file>`: a hidden debug command that parses one file and prints
/// `ok`, an S-expression dump of the AST, or the diagnostics. Returns the exit code.
fn parse_file(args: &[String]) -> i32 {
    let (mode, path) = match args {
        [path] => ("", path),
        [mode, path] if mode == "--ast" || mode == "--json" => (mode.as_str(), path),
        _ => usage(),
    };
    let src = match fs::read_to_string(path) {
        Ok(src) => src,
        Err(e) => {
            eprintln!("error: cannot read {path}: {e}");
            return 1;
        }
    };
    match parser::parse(&src) {
        Ok(m) if mode == "--ast" => print!("{}", m.dump()),
        Ok(_) if mode == "--json" => println!("{}", diag::json_report(path, &[])),
        Ok(_) => println!("ok"),
        Err(diags) => {
            if mode == "--json" {
                println!("{}", diag::json_report(path, &diags));
            } else {
                diags.iter().for_each(|d| eprint!("{}", d.render(path, &src)));
            }
            return 1;
        }
    }
    0
}

/// `duck typed <file>`: a hidden debug command that type-checks and prints a summary of the typed
/// program (signatures, generic instances) plus any invariant violations.
fn typed_file(args: &[String]) -> i32 {
    let [path] = args else { usage() };
    match resolve::load(Path::new(path)).and_then(check::check) {
        Ok(tp) => {
            print!("{}", tp.dump());
            let bad = tp.validate();
            for b in &bad {
                println!("INVARIANT: {b}");
            }
            i32::from(!bad.is_empty())
        }
        Err(ds) => {
            for d in &ds {
                let src = resolve::source_of(&d.file).unwrap_or_default();
                eprint!("{}", d.diag.render(&d.file, &src));
            }
            1
        }
    }
}
