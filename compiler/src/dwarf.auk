/// DWARF debug info for native builds (`auk build -g`) through LLVM's DIBuilder
/// (src/mir/llvm/debug.rs): a line table that maps machine code back to Auk source lines, and a
/// subprogram per Auk function (named by its Auk name, `prog.fact`), so lldb, gdb and editor
/// front ends like CodeLLDB can set `file:line` breakpoints, step by source line and show where
/// they are.
///
/// Lowering marks every statement with `Stmt.Loc` (an index into `Program.locs`); the code
/// generator sets the builder's location from it. There is no DWARF language code for Auk, so
/// the unit says C. Variables are not described: the instrumented debugger (`auk run --debug`,
/// `auk debug`, `auk dap`) is the one that shows Auk values. On Mach-O the linker leaves DWARF
/// in the object file, so `auk build` runs `dsymutil` to gather it into `<out>.dSYM`.
///
/// Rust's `Option<Debug>` is a `Debug` with `on` (handles are `?`s when it is off).

/// The version the producer string names (the Rust compiler's Cargo.toml `version`, kept).
let VERSION = "0.1.0"

pub struct Debug {
  on: bool,
  cx: llvm.Context,
  dib: llvm.DIBuilder?,
  cwd: str,
  files: {str: llvm.Metadata},
  fn_ty: llvm.Metadata?,
  /// The compile unit's file (generated functions are placed there, at line 0).
  main: llvm.Metadata?,
}

fn abs(f: str): str uses ffi = paths.canonicalize(f) else f

/// The first source location in a body (where the function is said to be).
fn first_loc(ss: [mir.Stmt]): int? {
  for s in ss {
    match s {
      Loc(i) => return i
      If(_, a, b) | Loop(a, b) => {
        match first_loc(a) {
          some(i) => return i
          none => {}
        }
        match first_loc(b) {
          some(i) => return i
          none => {}
        }
      }
      _ => {}
    }
  }
  none
}

/// Debug info for module `m`, on if the program carries source locations (`-g`).
pub fn new(cx: llvm.Context, m: llvm.Module, prog: mir.Program): Debug uses fs, ffi {
  var d = Debug { on: false, cx, dib: none, cwd: "", files: {}, fn_ty: none, main: none }
  if prog.locs.len() == 0 { return d }
  let i32t = llvm.ir.int32_type_in_context(cx)
  let flag = (k: str, v: int) => {
    let md = llvm.values.value_as_metadata(llvm.values.const_int(i32t, v, 0))
    llvm.ir.add_module_flag(m, llvm.MODULE_FLAG_BEHAVIOR_WARNING, k, md)
  }
  flag("Debug Info Version", llvm.debug.debug_metadata_version())
  flag("Dwarf Version", 4)
  let dib = llvm.debug.create_di_builder(m)
  d.on = true
  d.dib = dib
  d.cwd = paths.cwd()
  // the compile unit is named after the program's first source file
  var main = prog.locs[0].0
  for l in prog.locs {
    if paths.is_file(l.0) {
      main = l.0
      break
    }
  }
  let file = file_of(&d, main)
  d.main = file
  let producer = "auk {VERSION}"
  llvm.debug.di_builder_create_compile_unit(
    dib,
    llvm.DWARF_SOURCE_LANGUAGE_C99,
    file,
    producer,
    1,
    "",
    0,
    "",
    llvm.DWARF_EMISSION_FULL,
    0,
    0,
    0,
    "",
    "",
  )
  d.fn_ty = llvm.debug.di_builder_create_subroutine_type(dib, file, [], llvm.DI_FLAG_ZERO)
  d
}

fn file_of(d: var Debug, f: str): llvm.Metadata uses ffi {
  match d.files.get(f) {
    some(m) => return m
    none => {}
  }
  let p = abs(f)
  let dir = match paths.parent(p) {
    some(x) => if x == "" { d.cwd } else { x }
    none => d.cwd
  }
  let name = paths.file_name(p)
  let m = llvm.debug.di_builder_create_file(d.dib!, if name == "" { p } else { name }, dir)
  d.files[f] = m
  m
}

/// Attach a subprogram to function `fv` (MIR function `fi`); returns it and the location of
/// the function's first line (for its prologue). Every function gets one, so Auk code that
/// LLVM inlines into it keeps its lines: an Auk body is named by its Auk name (`prog.fact`)
/// at its first statement, a generated function (shims, element ops, ...) by its symbol,
/// marked artificial, at line 0.
pub fn subprogram(
  d: var Debug,
  fv: llvm.Value,
  prog: mir.Program,
  fi: int,
): (llvm.Metadata, llvm.Metadata) uses ffi {
  let f = prog.funcs[fi]
  var name = f.name
  var fm = d.main!
  var line = 0
  var col = 0
  var flags = llvm.DI_FLAG_ARTIFICIAL
  match prog.names.get(fi) {
    some(n) => match first_loc(f.body) {
      some(l) => {
        let (file, ln, c) = prog.locs[l]
        name = n
        fm = file_of(&d, file)
        line = ln
        col = c
        flags = llvm.DI_FLAG_ZERO
      }
      none => {}
    }
    none => {}
  }
  let sp = llvm.debug.di_builder_create_function(
    d.dib!,
    fm,
    name,
    "",
    fm,
    line,
    d.fn_ty,
    0,
    1,
    line,
    flags,
    1,
  )
  llvm.debug.set_subprogram(fv, sp)
  let at = llvm.debug.di_builder_create_debug_location(d.cx, line, col, sp, none)
  (sp, at)
}

/// The location `Program.locs[i]` in subprogram `sp`. A location in another file than the
/// function's (code inlined by lowering) still names its own line.
pub fn loc(d: Debug, prog: mir.Program, i: int, sp: llvm.Metadata): llvm.Metadata uses ffi {
  let (_, line, col) = prog.locs[i]
  llvm.debug.di_builder_create_debug_location(d.cx, line, col, sp, none)
}

/// Finish the debug info (before the module is verified or emitted).
pub fn finish(d: Debug) uses ffi {
  if !d.on { return }
  llvm.debug.di_builder_finalize(d.dib!)
  llvm.debug.dispose_di_builder(d.dib!)
}
