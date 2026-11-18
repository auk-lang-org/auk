/// The LLVM back end's drivers (src/mir/llvm/mod.rs and src/mir/backend.rs): MIR → LLVM IR
/// (`codegen`) → machine code in memory (ORC, `orcjit`) or an object file (`object`, linked by
/// `native` into an executable), with the optimization levels and their pass pipelines.

/// How much to optimize.
pub enum Level {
  /// Nothing (fastest to compile): tests, imprints, debugger evaluations.
  O0,
  /// A few cheap passes (`auk run`).
  Light,
  O2,
  O3,
}

/// The pass pipeline. Every level first drops functions nothing uses (`globaldce`): code
/// generation is most of the time spent compiling in memory.
fn passes(l: Level): str = match l {
  O0 => "globaldce"
  Light => "globaldce,function(sroa,early-cse,instcombine<no-verify-fixpoint>,simplifycfg)"
  O2 => "default<O2>"
  O3 => "default<O3>"
}

/// The code generator's level. `Light` uses the fast instruction selector too: on IR the
/// light passes cleaned up it makes about the same code as SelectionDAG at half the cost.
fn codegen_level(l: Level): int = match l {
  O0 | Light => llvm.CODE_GEN_LEVEL_NONE
  O2 => llvm.CODE_GEN_LEVEL_DEFAULT
  O3 => llvm.CODE_GEN_LEVEL_AGGRESSIVE
}

/// A target machine for this computer.
fn target_machine(level: Level): llvm.TargetMachine! uses env, ffi {
  llvm.kit.init_native()
  let triple = llvm.target.get_default_target_triple()
  var t: llvm.Target? = none
  var why: str? = none
  if llvm.target.get_target_from_triple(triple, &t, &why) != 0 {
    return fail(why else "unknown target {triple}")
  }
  let cpu = llvm.target.get_host_cpu_name()
  let features = llvm.target.get_host_cpu_features()
  // AUK_LLVM_CODEGEN=0..3 overrides the code generator's level (tuning)
  let cg = match (env.get("AUK_LLVM_CODEGEN") else "") {
    "0" => Level.O0
    "1" => Level.Light
    "2" => Level.O2
    "3" => Level.O3
    _ => level
  }
  let tm = llvm.target.create_target_machine(
    t!,
    triple,
    cpu,
    features,
    codegen_level(cg),
    llvm.RELOC_PIC,
    llvm.CODE_MODEL_DEFAULT,
  ) else {
    return fail("cannot create an LLVM target machine for this computer")
  }
  if codegen_level(cg) == llvm.CODE_GEN_LEVEL_NONE {
    // GlobalISel (AArch64's default at O0) has a pass that is quadratic in a block's size
    // (`Localizer`): 12 s for a program with a big package. FastISel compiles it in a blink.
    llvm.target.set_target_machine_global_isel(tm, 0)
    llvm.target.set_target_machine_fast_isel(tm, 1)
  }
  tm
}

/// A translated, verified and optimized module (in a new context), with the runtime symbols its
/// code calls (for the JIT).
pub struct Built {
  cx: llvm.Context,
  m: llvm.Module,
  tm: llvm.TargetMachine,
  rt_syms: [str],
}

/// Translate, verify and optimize `prog`. `link_runtime`: link the runtime's inlinable functions
/// into the module first (`rtlink`; `auk build` only: it costs compile time). `raw`: without the
/// pass pipeline.
fn build(
  prog: mir.Program,
  info: mir.types.TyInfo,
  ex: codegen.Exports,
  live: (int, {int: int})?,
  level: Level,
  link_runtime: bool,
  raw: bool,
): Built! uses fs, env, ffi {
  let tm = target_machine(level)?
  let t0 = micros()
  let cx = llvm.ir.context_create()
  let triple = llvm.target.get_target_machine_triple(tm)
  var g = codegen.new(cx, "auk", prog, info, live, mir.layout.arch_of(triple))
  g.inline_rt = level != Level.O0
  codegen.program(&g, ex)?
  let m = g.m
  var rt_syms = g.rt_funcs.keys() + g.rt_data.keys()
  codegen.dispose(g)
  let t_gen = micros() - t0
  llvm.ir.set_target(m, triple)
  let dl = llvm.target.create_target_data_layout(tm)
  llvm.target.set_module_data_layout(m, dl)
  llvm.target.dispose_target_data(dl)
  // AUK_NO_RT_INLINE=1: without the runtime's bitcode (to compare)
  if link_runtime && env.get("AUK_NO_RT_INLINE") == none && !rtlink.link(cx, m) {
    eprint("note: the runtime's bitcode can't be used with this LLVM; runtime calls won't be inlined")
  }
  if env.get("AUK_VERIFY") != none {
    var msg: str? = none
    if llvm.ir.verify_module(m, llvm.RETURN_STATUS_ACTION, &msg) != 0 {
      let why = msg else ""
      let ir = llvm.ir.print_module_to_string(m)
      llvm.ir.dispose_module(m)
      llvm.ir.context_dispose(cx)
      llvm.target.dispose_target_machine(tm)
      return fail("invalid LLVM IR: {why}{ir}")
    }
  }
  // AUK_LLVM_PASSES overrides the pass pipeline (tuning; empty: none)
  let custom = env.get("AUK_LLVM_PASSES")
  let pipeline = if raw {
    ""
  } else {
    match custom {
      some(p) => p
      none => passes(level)
    }
  }
  if pipeline != "" {
    match llvm.kit.run_passes(m, pipeline, tm) {
      ok(_) => {}
      err(e) => return fail("optimizing: {e}")
    }
  }
  // AUK_TIME_BACKEND=1: the time code generation (MIR → LLVM IR) and the rest (the runtime's
  // bitcode, the passes) took, to stderr (comparing back ends)
  if env.get("AUK_TIME_BACKEND") != none {
    eprint("backend: codegen {t_gen} us, link+passes {micros() - t0 - t_gen} us")
  }
  Built { cx, m, tm, rt_syms }
}

fn exports(entry: str): codegen.Exports = codegen.Exports { entry, names: [], all: false }

/// Generate machine code for a built module: an object file's bytes (consumes the module).
fn emit(b: Built): [int]! uses ffi {
  let r = llvm.kit.emit(b.tm, b.m, false)
  llvm.ir.dispose_module(b.m)
  llvm.ir.context_dispose(b.cx)
  llvm.target.dispose_target_machine(b.tm)
  r
}

/// Compile a program in memory (`auk run`'s `Light`, `-O`'s `O2`, tests' `O0`).
pub fn jit(
  prog: mir.Program,
  info: mir.types.TyInfo,
  level: Level,
): orcjit.Code! uses fs, env, proc, ffi {
  orcjit.open_libs(prog.links, prog.c_syms)?
  let b = build(prog, info, exports("dk_entry"), none, level, false, false)?
  let syms = b.rt_syms
  orcjit.load(emit(b)?, syms)
}

/// Compile a program to an object file whose `main` is the entry point; `opt`: optimize (O2,
/// with the runtime's inlinable functions).
pub fn object(prog: mir.Program, info: mir.types.TyInfo, opt: bool): [int]! uses fs, env, ffi {
  let level = if opt { Level.O2 } else { Level.O0 }
  emit(build(prog, info, exports("main"), none, level, opt, false)?)
}

/// The program's LLVM IR at `level` (`o0`, `light`, `o2`, `o3`, or `build`: O2 with the
/// runtime's bitcode; a `-raw` suffix stops before the pass pipeline), as `auk ir --llvm=LEVEL`
/// prints it.
pub fn ir_text(prog: mir.Program, info: mir.types.TyInfo, level: str): str! uses fs, env, ffi {
  let raw = level.ends_with("-raw")
  let name = level.strip_suffix("-raw") else level
  let (l, rt) = match name {
    "o0" => (Level.O0, false)
    "light" => (Level.Light, false)
    "o2" => (Level.O2, false)
    "o3" => (Level.O3, false)
    "build" => (Level.O2, true)
    _ =>
      return fail("unknown LLVM level `{level}` (o0, light, o2, o3, build, with an optional -raw)")
  }
  let b = build(prog, info, exports("main"), none, l, rt, raw)?
  let s = llvm.ir.print_module_to_string(b.m)
  llvm.ir.dispose_module(b.m)
  llvm.ir.context_dispose(b.cx)
  llvm.target.dispose_target_machine(b.tm)
  s
}

extern fn c_clock_gettime(clock: int, ts: ffi.Ptr): int = "int clock_gettime(int, void *)"

/// A monotonic clock in microseconds (`time.now()` has milliseconds).
pub fn micros(): int uses ffi {
  let ts = ffi.alloc(16)
  // CLOCK_MONOTONIC
  let _ = c_clock_gettime(if paths.os() == "macos" { 6 } else { 1 }, ts)
  let us = ffi.read_i64(ts, 0) * 1000000 + ffi.read_i64(ts, 8) / 1000
  ffi.free(ts)
  us
}
