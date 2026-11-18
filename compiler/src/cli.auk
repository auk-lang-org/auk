/// The `auk check` command (src/main.rs `check_file`).

/// `auk check [--json] <file>`: load the module tree (project, dependencies, core) and check it;
/// the JSON report on stdout, or the rendered diagnostics on stderr. Returns the exit code:
/// warnings (E0411) don't fail the check.
pub fn check_file(cx: resolve.Sources, path: str, json: bool): int uses fs, ffi {
  let src = match fs.read(path) {
    ok(s) => s
    err(e) => {
      eprint("error: cannot read {path}: {paths.io_error(e.show())}")
      return 1
    }
  }
  let diags = match resolve.load_in_package(cx, path, src) {
    ok(prog) => check.check_all(prog).1
    err(Many(ds)) => ds
  }
  if json {
    print(diag.json_report_files(path, diags))
  } else {
    print_diags(cx, diags)
  }
  if diags.all(d => d.diag.is_warning()) { 0 } else { 1 }
}

/// Render diagnostics to stderr, each against its file's text (Rust's `eprint!` of each
/// `render`; `eprint` adds the last newline).
pub fn print_diags(cx: resolve.Sources, diags: [diag.FileDiag]) uses fs {
  var out: [str] = []
  for d in diags {
    let src = resolve.source_of(cx, d.file) else ""
    out.push(d.diag.render(d.file, src))
  }
  let all = out.join("")
  if all != "" { eprint(all.strip_suffix("\n") else all) }
}

/// `auk parse [--ast | --json] <file>` (src/main.rs `parse_file`): a hidden debug command that
/// parses one file and prints `ok`, an S-expression dump of the AST, or the diagnostics. Returns
/// the exit code (`none`: bad arguments, the caller prints the usage).
pub fn parse_file(args: [str]): int? uses fs, ffi {
  let (mode, path) = if args.len() == 1 {
    ("", args[0])
  } else if args.len() == 2 && (args[0] == "--ast" || args[0] == "--json") {
    (args[0], args[1])
  } else {
    return none
  }
  let src = match fs.read(path) {
    ok(s) => s
    err(e) => {
      eprint("error: cannot read {path}: {paths.io_error(e.show())}")
      return 1
    }
  }
  match parser.parse(src, false) {
    ok(m) => {
      if mode == "--ast" {
        posix.print_raw(ast_dump.module(m))
      } else if mode == "--json" {
        print(diag.json_report(path, []))
      } else {
        print("ok")
      }
      0
    }
    err(Many(diags)) => {
      if mode == "--json" {
        print(diag.json_report(path, diags))
      } else {
        posix.eprint_raw(diags.map(d => d.render(path, src)).join(""))
      }
      1
    }
  }
}

/// `auk typed <file>` (src/main.rs `typed_file`): a hidden debug command that type-checks
/// (`check::check`: `check_all`, units erased) and prints a summary of the typed program
/// (signatures, generic instances) plus any invariant violations. Returns the exit code.
pub fn typed_file(cx: resolve.Sources, path: str): int uses fs, ffi {
  let diags = match resolve.load(cx, path) {
    ok(prog) => match check.check_all(prog) {
      (some(t), _) => {
        var tp = t
        units.erase(&tp)
        posix.print_raw(typed.dump(tp))
        let bad = typed.validate(tp)
        for b in bad { print("INVARIANT: {b}") }
        return if bad.len() == 0 { 0 } else { 1 }
      }
      (none, ds) => ds
    }
    err(Many(ds)) => ds
  }
  print_diags(cx, diags)
  1
}
