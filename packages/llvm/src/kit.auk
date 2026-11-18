/// Hand-written helpers over the generated bindings (the parts of `src/mir/llvm/mod.rs` and
/// `jit.rs` every user needs): target setup, LLVM errors as Auk errors, object and bitcode
/// emission as bytes, and ORC LLJIT with absolute symbols and calls into JIT code.

/// How hard the code generator works (`LLVMCodeGenOptLevel`).
pub enum Level { None, Less, Default, Aggressive }

fn level_code(l: Level): int = match l {
  None => llvm.CODE_GEN_LEVEL_NONE
  Less => llvm.CODE_GEN_LEVEL_LESS
  Default => llvm.CODE_GEN_LEVEL_DEFAULT
  Aggressive => llvm.CODE_GEN_LEVEL_AGGRESSIVE
}

/// Register the AArch64 and x86 targets, their assemblers and printers (what the
/// `LLVM_InitializeNative*` inline functions do). Calling it again is harmless.
pub fn init_native() uses ffi {
  llvm.target.initialize_aarch64_target_info()
  llvm.target.initialize_aarch64_target()
  llvm.target.initialize_aarch64_target_mc()
  llvm.target.initialize_aarch64_asm_printer()
  llvm.target.initialize_aarch64_asm_parser()
  llvm.target.initialize_x86_target_info()
  llvm.target.initialize_x86_target()
  llvm.target.initialize_x86_target_mc()
  llvm.target.initialize_x86_asm_printer()
  llvm.target.initialize_x86_asm_parser()
}

/// `none` (success) as `ok`, an LLVM error as `fail` with its message (the error is consumed).
pub fn check(e: llvm.Error?): ()! uses ffi {
  match e {
    some(x) => fail(llvm.orc.get_error_message(x))
    none => {}
  }
}

/// A target machine for this computer (position-independent code), as `auk build` makes it.
/// `Level.None` also picks FastISel over GlobalISel, which is quadratic on big blocks.
pub fn host_machine(level: Level): llvm.TargetMachine! uses ffi {
  init_native()
  let triple = llvm.target.get_default_target_triple()
  var t: llvm.Target? = none
  var why: str? = none
  if llvm.target.get_target_from_triple(triple, &t, &why) != 0 {
    fail(why else "unknown target {triple}")
  }
  let tm = llvm.target.create_target_machine(
    t!,
    triple,
    llvm.target.get_host_cpu_name(),
    llvm.target.get_host_cpu_features(),
    level_code(level),
    llvm.RELOC_PIC,
    llvm.CODE_MODEL_DEFAULT,
  ) else {
    fail("cannot create an LLVM target machine for {triple}")
  }
  if level == None {
    llvm.target.set_target_machine_global_isel(tm, 0)
    llvm.target.set_target_machine_fast_isel(tm, 1)
  }
  tm
}

/// Give module `m` the target machine's triple and data layout.
pub fn set_target(m: llvm.Module, tm: llvm.TargetMachine) uses ffi {
  llvm.ir.set_target(m, llvm.target.get_target_machine_triple(tm))
  let dl = llvm.target.create_target_data_layout(tm)
  llvm.target.set_module_data_layout(m, dl)
  llvm.target.dispose_target_data(dl)
}

/// Verify `m`: `fail` with LLVM's message when it's invalid.
pub fn verify(m: llvm.Module): ()! uses ffi {
  var msg: str? = none
  if llvm.ir.verify_module(m, llvm.RETURN_STATUS_ACTION, &msg) != 0 {
    fail(msg else "invalid module")
  }
}

/// Run a pass pipeline (`"default<O2>"`, `"globaldce,function(sroa)"`, ...) over `m`.
pub fn run_passes(m: llvm.Module, passes: str, tm: llvm.TargetMachine?): ()! uses ffi {
  let opts = llvm.passes.create_pass_builder_options()
  let r = llvm.passes.run_passes(m, passes, tm, opts)
  llvm.passes.dispose_pass_builder_options(opts)
  check(r)?
}

/// The bytes of a memory buffer, copied; the buffer is disposed of.
pub fn take_bytes(b: llvm.MemoryBuffer): [int] uses ffi {
  let out = ffi.bytes(llvm.bitcode.get_buffer_start(b), llvm.bitcode.get_buffer_size(b))
  llvm.bitcode.dispose_memory_buffer(b)
  out
}

/// Machine code for `m`: an object file (`asm`: assembly text instead), as bytes.
pub fn emit(tm: llvm.TargetMachine, m: llvm.Module, asm: bool): [int]! uses ffi {
  var why: str? = none
  var buf: llvm.MemoryBuffer? = none
  let kind = if asm { llvm.ASSEMBLY_FILE } else { llvm.OBJECT_FILE }
  if llvm.target.target_machine_emit_to_memory_buffer(tm, m, kind, &why, &buf) != 0 {
    fail(why else "emitting machine code failed")
  }
  take_bytes(buf!)
}

/// `m` as bitcode.
pub fn bitcode(m: llvm.Module): [int] uses ffi =
  take_bytes(llvm.bitcode.write_bitcode_to_memory_buffer(m))

/// Read bitcode into a new module of context `c`.
pub fn parse_bitcode(c: llvm.Context, bc: [int]): llvm.Module! uses ffi {
  let buf = llvm.bitcode.create_memory_buffer_with_memory_range_copy(bc, "bitcode")
  var m: llvm.Module? = none
  let bad = llvm.bitcode.parse_bitcode_in_context2(c, buf, &m)
  llvm.bitcode.dispose_memory_buffer(buf)
  if bad != 0 { fail("invalid bitcode") }
  m!
}

// ---- ORC LLJIT ----

/// A JIT for one object file: dispose of it with `close`.
pub struct Jit { j: llvm.OrcLLJIT, dylib: llvm.OrcJITDylib }

/// A new LLJIT whose main dylib also finds this process's symbols (libc, loaded libraries).
pub fn jit(): Jit! uses ffi {
  init_native()
  var j: llvm.OrcLLJIT? = none
  check(llvm.orc.orc_create_lljit(&j, llvm.orc.orc_create_lljit_builder()))?
  let jit = j!
  let jd = llvm.orc.orc_lljit_get_main_jit_dylib(jit)
  var g: llvm.OrcDefinitionGenerator? = none
  let prefix = llvm.orc.orc_lljit_get_global_prefix(jit)
  check(
    llvm.orc.orc_create_dynamic_library_search_generator_for_process(
      &g,
      prefix,
      ffi.null,
      ffi.null,
    ),
  )?
  llvm.orc.orc_jit_dylib_add_generator(jd, g!)
  Jit { j: jit, dylib: jd }
}

// An interned name as a plain pointer, to store in C memory.
extern fn entry_ptr(e: llvm.OrcSymbolStringPoolEntry): ffi.Ptr = "(void *)"

/// Define symbols at fixed addresses in the JIT's main dylib (how `auk run` hands the runtime
/// to JIT code). `LLVMOrcCSymbolMapPair` is laid out by hand: the interned name (8 bytes), the
/// address (8), the generic and target flags (1 + 1, padded to 8).
pub fn define(jt: Jit, syms: [(str, ffi.Ptr)]): ()! uses ffi {
  if syms.len() == 0 { return }
  let size = 24
  let pairs = ffi.alloc(size * syms.len())
  let flags = llvm.JIT_SYMBOL_GENERIC_FLAGS_EXPORTED + llvm.JIT_SYMBOL_GENERIC_FLAGS_CALLABLE
  for i in 0..syms.len() {
    let (name, at) = syms[i]
    ffi.write_ptr(pairs, i * size, entry_ptr(llvm.orc.orc_lljit_mangle_and_intern(jt.j, name)))
    ffi.write_ptr(pairs, i * size + 8, at)
    ffi.write_u8(pairs, i * size + 16, flags)
  }
  let mu = llvm.orc.orc_absolute_symbols(pairs, syms.len())
  ffi.free(pairs)
  check(llvm.orc.orc_jit_dylib_define(jt.dylib, mu!))?
}

/// Link object file `obj` into the JIT.
pub fn add_object(jt: Jit, obj: [int]): ()! uses ffi {
  let buf = llvm.bitcode.create_memory_buffer_with_memory_range_copy(obj, "auk")
  check(llvm.orc.orc_lljit_add_object_file(jt.j, jt.dylib, buf))?
}

/// The address of `name` (linking the code the first time).
pub fn lookup(jt: Jit, name: str): ffi.Ptr! uses ffi {
  var a = 0
  check(llvm.orc.orc_lljit_lookup(jt.j, &a, name))?
  ffi.ptr(a)
}

/// Free the JIT and its code.
pub fn close(jt: Jit): ()! uses ffi = check(llvm.orc.orc_dispose_lljit(jt.j))

/// Call JIT code `f: (i64, i64) -> i64`; other signatures are one `extern fn` each, the same way:
/// `extern fn call(f: ffi.Ptr, x: float): float = "double (*)(double)"`.
pub extern fn call_ii_i(f: ffi.Ptr, a: int, b: int): int = "int64_t (*)(int64_t, int64_t)"
/// Call JIT code `f: (i64) -> i64`.
pub extern fn call_i_i(f: ffi.Ptr, a: int): int = "int64_t (*)(int64_t)"
