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
