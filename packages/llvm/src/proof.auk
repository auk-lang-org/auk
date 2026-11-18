/// End-to-end tests of the bindings: a module built in Auk, verified, printed, compiled to an
/// object file and to bitcode, read back, linked, optimized, given debug info, and run in ORC
/// LLJIT, with the JIT code called from Auk.

/// `add(a, b) = a + b` on `i64`, in a new module `demo` of context `c`.
pub fn add_module(c: llvm.Context): llvm.Module uses ffi {
  let m = llvm.ir.module_create_with_name_in_context("demo", c)
  let i64 = llvm.ir.int64_type_in_context(c)
  let f = llvm.ir.add_function(m, "add", llvm.ir.function_type(i64, [i64, i64], 0))
  let (a, b) = (llvm.values.get_param(f, 0), llvm.values.get_param(f, 1))
  llvm.values.set_value_name2(a, "a")
  llvm.values.set_value_name2(b, "b")
  let bld = llvm.builder.create_builder_in_context(c)
  llvm.builder.position_builder_at_end(
    bld,
    llvm.values.append_basic_block_in_context(c, f, "entry"),
  )
  let _ = llvm.builder.build_ret(bld, llvm.builder.build_add(bld, a, b, "sum"))
  llvm.builder.dispose_builder(bld)
  m
}

/// The message of an error, `""` for none.
fn error_of(r: ()!): str = match r {
  err(e) => "{e}"
  ok(_) => ""
}

let ADD_IR = r"""
  ; ModuleID = 'demo'
  source_filename = "demo"

  define i64 @add(i64 %a, i64 %b) {
  entry:
    %sum = add i64 %a, %b
    ret i64 %sum
  }
  """

test "build add(i64, i64), verify it and print its IR" {
  let c = llvm.ir.context_create()
  let m = add_module(c)
  llvm.kit.verify(m)?
  assert llvm.ir.print_module_to_string(m) == ADD_IR
  let f = llvm.ir.get_named_function(m, "add")!
  assert llvm.values.count_params(f) == 2
  var ps = [f, f]
  llvm.values.get_params(f, &ps)
  assert llvm.values.print_value_to_string(ps[1]) == "i64 %b"
  var n = 0
  assert llvm.values.get_value_name2(f, &n) == "add" && n == 3
  assert llvm.ir.print_type_to_string(llvm.values.type_of(ps[0])) == "i64"
  llvm.ir.dispose_module(m)
  llvm.ir.context_dispose(c)
}

test "a broken module fails verification with LLVM's message" {
  let c = llvm.ir.context_create()
  let m = llvm.ir.module_create_with_name_in_context("bad", c)
  let i64 = llvm.ir.int64_type_in_context(c)
  let f = llvm.ir.add_function(m, "f", llvm.ir.function_type(i64, [], 0))
  let _ = llvm.values.append_basic_block_in_context(c, f, "entry")  // no terminator
  assert error_of(llvm.kit.verify(m)).contains("does not have terminator")
  llvm.ir.dispose_module(m)
  llvm.ir.context_dispose(c)
}

test "JIT add with ORC LLJIT and call it" {
  let c = llvm.ir.context_create()
  let m = add_module(c)
  let tm = llvm.kit.host_machine(None)?
  llvm.kit.set_target(m, tm)
  let obj = llvm.kit.emit(tm, m, false)?
  let jt = llvm.kit.jit()?
  llvm.kit.add_object(jt, obj)?
  let add = llvm.kit.lookup(jt, "add")?
  assert llvm.kit.call_ii_i(add, 40, 2) == 42
  assert llvm.kit.call_ii_i(add, -7, 3000000000000) == 2999999999993
  let missing = llvm.kit.lookup(jt, "nope") else e => ffi.null
  assert missing.is_null()
  llvm.kit.close(jt)?
  llvm.target.dispose_target_machine(tm)
  llvm.ir.dispose_module(m)
  llvm.ir.context_dispose(c)
}

test "an object file and assembly for the host" {
  let c = llvm.ir.context_create()
  let m = add_module(c)
  let tm = llvm.kit.host_machine(Default)?
  llvm.kit.set_target(m, tm)
  let obj = llvm.kit.emit(tm, m, false)?
  let macho = obj.len() > 4 && obj[0] == 0xcf && obj[1] == 0xfa && obj[2] == 0xed && obj[3] == 0xfe
  let elf = obj.len() > 4 && obj[0] == 0x7f && obj[1] == 0x45 && obj[2] == 0x4c && obj[3] == 0x46
  assert macho || elf
  let asm = str.from_utf8(llvm.kit.emit(tm, m, true)?)?
  assert asm.contains("add")
  assert llvm.ir.get_target(m) == llvm.target.get_target_machine_triple(tm)
  assert llvm.ir.get_data_layout_str(m) != ""
  llvm.target.dispose_target_machine(tm)
  llvm.ir.dispose_module(m)
  llvm.ir.context_dispose(c)
}

test "bitcode out and back in, then linked into another module" {
  let c = llvm.ir.context_create()
  let m = add_module(c)
  let bc = llvm.kit.bitcode(m)
  assert bc.len() > 4 && (bc[0], bc[1], bc[2], bc[3]) == (0x42, 0x43, 0xc0, 0xde)  // "BC" 0xC0DE
  let back = llvm.kit.parse_bitcode(c, bc)?
  llvm.kit.verify(back)?
  assert llvm.ir.print_module_to_string(back).contains("%sum = add i64 %a, %b")
  assert (llvm.kit.parse_bitcode(c, [1, 2, 3]) else e => back) == back
  // main(x) = add(x, 1), with `add` declared here and defined by the linked module
  let user = llvm.ir.module_create_with_name_in_context("user", c)
  let i64 = llvm.ir.int64_type_in_context(c)
  let fty = llvm.ir.function_type(i64, [i64, i64], 0)
  let decl = llvm.ir.add_function(user, "add", fty)
  let f = llvm.ir.add_function(user, "inc", llvm.ir.function_type(i64, [i64], 0))
  let bld = llvm.builder.create_builder_in_context(c)
  llvm.builder.position_builder_at_end(
    bld,
    llvm.values.append_basic_block_in_context(c, f, "entry"),
  )
  let one = llvm.values.const_int(i64, 1, 0)
  let r = llvm.builder.build_call2(bld, fty, decl, [llvm.values.get_param(f, 0), one], "r")
  let _ = llvm.builder.build_ret(bld, r)
  llvm.builder.dispose_builder(bld)
  assert llvm.values.is_declaration(decl) == 1
  assert llvm.bitcode.link_modules2(user, back) == 0  // consumes `back`
  llvm.kit.verify(user)?
  assert llvm.values.is_declaration(llvm.ir.get_named_function(user, "add")!) == 0
  let tm = llvm.kit.host_machine(None)?
  llvm.kit.set_target(user, tm)
  let jt = llvm.kit.jit()?
  llvm.kit.add_object(jt, llvm.kit.emit(tm, user, false)?)?
  assert llvm.kit.call_i_i(llvm.kit.lookup(jt, "inc")?, 41) == 42
  llvm.kit.close(jt)?
  llvm.target.dispose_target_machine(tm)
  llvm.ir.dispose_module(user)
  llvm.ir.dispose_module(m)
  llvm.ir.context_dispose(c)
}

test "absolute symbols: JIT code calls an address defined from Auk" {
  let c = llvm.ir.context_create()
  let tm = llvm.kit.host_machine(None)?
  // the first JIT has `add`
  let m1 = add_module(c)
  llvm.kit.set_target(m1, tm)
  let j1 = llvm.kit.jit()?
  llvm.kit.add_object(j1, llvm.kit.emit(tm, m1, false)?)?
  let add = llvm.kit.lookup(j1, "add")?
  // the second calls `ext_add`, defined as `add`'s address in the first
  let m2 = llvm.ir.module_create_with_name_in_context("caller", c)
  let i64 = llvm.ir.int64_type_in_context(c)
  let fty = llvm.ir.function_type(i64, [i64, i64], 0)
  let ext = llvm.ir.add_function(m2, "ext_add", fty)
  let f = llvm.ir.add_function(m2, "twice", llvm.ir.function_type(i64, [i64], 0))
  let bld = llvm.builder.create_builder_in_context(c)
  llvm.builder.position_builder_at_end(
    bld,
    llvm.values.append_basic_block_in_context(c, f, "entry"),
  )
  let x = llvm.values.get_param(f, 0)
  let _ = llvm.builder.build_ret(bld, llvm.builder.build_call2(bld, fty, ext, [x, x], ""))
  llvm.builder.dispose_builder(bld)
  llvm.kit.set_target(m2, tm)
  let j2 = llvm.kit.jit()?
  llvm.kit.define(j2, [("ext_add", add)])?
  llvm.kit.add_object(j2, llvm.kit.emit(tm, m2, false)?)?
  assert llvm.kit.call_i_i(llvm.kit.lookup(j2, "twice")?, 21) == 42
  llvm.kit.close(j2)?
  llvm.kit.close(j1)?
  llvm.target.dispose_target_machine(tm)
  llvm.ir.dispose_module(m2)
  llvm.ir.dispose_module(m1)
  llvm.ir.context_dispose(c)
}

test "the O2 pipeline folds a redundant body" {
  let c = llvm.ir.context_create()
  let m = llvm.ir.module_create_with_name_in_context("opt", c)
  let i64 = llvm.ir.int64_type_in_context(c)
  let f = llvm.ir.add_function(m, "same", llvm.ir.function_type(i64, [i64], 0))
  let bld = llvm.builder.create_builder_in_context(c)
  llvm.builder.position_builder_at_end(
    bld,
    llvm.values.append_basic_block_in_context(c, f, "entry"),
  )
  let x = llvm.values.get_param(f, 0)
  let zero = llvm.values.const_int(i64, 0, 0)
  let y = llvm.builder.build_add(bld, x, zero, "")
  let z = llvm.builder.build_mul(bld, y, llvm.values.const_int(i64, 1, 0), "")
  let _ = llvm.builder.build_ret(bld, z)
  llvm.builder.dispose_builder(bld)
  let tm = llvm.kit.host_machine(Default)?
  llvm.kit.set_target(m, tm)
  llvm.kit.run_passes(m, "default<O2>", some(tm))?
  assert llvm.ir.print_module_to_string(m).contains("ret i64 %0")
  assert error_of(llvm.kit.run_passes(m, "no-such-pass", none)).contains("unknown")
  llvm.target.dispose_target_machine(tm)
  llvm.ir.dispose_module(m)
  llvm.ir.context_dispose(c)
}

test "debug info: a compile unit, a subprogram and a location (as debug.rs makes them)" {
  let c = llvm.ir.context_create()
  let m = add_module(c)
  let flag = llvm.values.value_as_metadata(
    llvm.values.const_int(llvm.ir.int32_type_in_context(c), llvm.debug.debug_metadata_version(), 0),
  )
  llvm.ir.add_module_flag(m, llvm.MODULE_FLAG_BEHAVIOR_WARNING, "Debug Info Version", flag)
  let d = llvm.debug.create_di_builder(m)
  let file = llvm.debug.di_builder_create_file(d, "demo.auk", "/src")
  let cu = llvm.debug.di_builder_create_compile_unit(
    d,
    llvm.DWARF_SOURCE_LANGUAGE_C99,
    file,
    "auk",
    0,
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
  let sty = llvm.debug.di_builder_create_subroutine_type(d, some(file), [], llvm.DI_FLAG_ZERO)
  let f = llvm.ir.get_named_function(m, "add")!
  let sp = llvm.debug.di_builder_create_function(
    d,
    file,
    "add",
    "add",
    file,
    3,
    sty,
    0,
    1,
    3,
    llvm.DI_FLAG_ZERO,
    0,
  )
  llvm.debug.set_subprogram(f, sp)
  let ret = llvm.values.get_next_instruction(
    llvm.values.get_first_instruction(llvm.values.get_first_basic_block(f)!)!,
  )!
  let bld = llvm.builder.create_builder_in_context(c)
  llvm.builder.position_builder_at_end(bld, llvm.values.get_first_basic_block(f)!)
  llvm.builder.set_current_debug_location2(
    bld,
    some(llvm.debug.di_builder_create_debug_location(c, 4, 7, sp, none)),
  )
  llvm.builder.dispose_builder(bld)
  llvm.debug.di_builder_finalize(d)
  llvm.debug.dispose_di_builder(d)
  let _ = cu
  let _ = ret
  llvm.kit.verify(m)?
  let text = llvm.ir.print_module_to_string(m)
  assert text.contains("!DIFile(filename: \"demo.auk\", directory: \"/src\")")
  assert text.contains("distinct !DISubprogram(name: \"add\"")
  assert text.contains("!DICompileUnit(language: DW_LANG_C99")
  llvm.ir.dispose_module(m)
  llvm.ir.context_dispose(c)
}
