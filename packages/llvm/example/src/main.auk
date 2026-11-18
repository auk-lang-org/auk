// The llvm package end to end: build `add(i64, i64) -> i64` and a C `main` that prints
// `add(40, 2)` with printf, verify the module and print its IR, run `add` in ORC LLJIT, then
// write an object file and bitcode, link the object with `cc` into an executable and run it.
//
//   cd packages/llvm/example && raft install && auk run src/main.auk

fn build(c: llvm.Context): llvm.Module uses ffi {
  let m = llvm.ir.module_create_with_name_in_context("add", c)
  let i64 = llvm.ir.int64_type_in_context(c)
  let i32 = llvm.ir.int32_type_in_context(c)
  let ptr = llvm.ir.pointer_type_in_context(c, 0)
  let b = llvm.builder.create_builder_in_context(c)
  // i64 add(i64 a, i64 b) { return a + b; }
  let add_ty = llvm.ir.function_type(i64, [i64, i64], 0)
  let add = llvm.ir.add_function(m, "add", add_ty)
  llvm.builder.position_builder_at_end(
    b,
    llvm.values.append_basic_block_in_context(c, add, "entry"),
  )
  let sum = llvm.builder.build_add(
    b,
    llvm.values.get_param(add, 0),
    llvm.values.get_param(add, 1),
    "sum",
  )
  let _ = llvm.builder.build_ret(b, sum)
  // int main(void) { printf("add(40, 2) = %lld\n", add(40, 2)); return 0; }
  let printf_ty = llvm.ir.function_type(i32, [ptr], 1)
  let printf = llvm.ir.add_function(m, "printf", printf_ty)
  let main = llvm.ir.add_function(m, "main", llvm.ir.function_type(i32, [], 0))
  llvm.builder.position_builder_at_end(
    b,
    llvm.values.append_basic_block_in_context(c, main, "entry"),
  )
  let fmt = llvm.values.add_global(
    m,
    llvm.ir.array_type2(llvm.ir.int8_type_in_context(c), 19),
    "fmt",
  )
  llvm.values.set_initializer(
    fmt,
    llvm.values.const_string_in_context2(c, "add(40, 2) = %lld\n", 0),
  )
  llvm.values.set_linkage(fmt, llvm.PRIVATE_LINKAGE)
  llvm.values.set_global_constant(fmt, 1)
  let k = (n: int) => llvm.values.const_int(i64, n, 1)
  let r = llvm.builder.build_call2(b, add_ty, add, [k(40), k(2)], "r")
  let _ = llvm.builder.build_call2(b, printf_ty, printf, [fmt, r], "")
  let _ = llvm.builder.build_ret(b, llvm.values.const_int(i32, 0, 0))
  llvm.builder.dispose_builder(b)
  m
}

fn main() uses ffi, fs, proc {
  let c = llvm.ir.context_create()
  let m = build(c)
  llvm.kit.verify(m) else e => {
    print("invalid module: {e}")
    return
  }
  print(llvm.ir.print_module_to_string(m))

  let tm = llvm.kit.host_machine(llvm.kit.Level.Default) else e => {
    print("no target machine: {e}")
    return
  }
  llvm.kit.set_target(m, tm)
  let obj = llvm.kit.emit(tm, m, false) else e => {
    print("emit: {e}")
    return
  }

  // in memory: ORC LLJIT, then a call through the looked-up address
  let jt = llvm.kit.jit() else e => {
    print("jit: {e}")
    return
  }
  llvm.kit.add_object(jt, obj) else e => print("jit: {e}")
  match llvm.kit.lookup(jt, "add") {
    ok(f) => print("JIT: add(40, 2) = {llvm.kit.call_ii_i(f, 40, 2)}")
    err(e) => print("lookup: {e}")
  }
  llvm.kit.close(jt) else e => print("jit: {e}")

  // on disk: an object file and bitcode, linked by cc into an executable
  fs.mkdir("out") else {}
  fs.write_bytes("out/add.o", obj) else e => print("write: {e}")
  fs.write_bytes("out/add.bc", llvm.kit.bitcode(m)) else e => print("write: {e}")
  match proc.run("cc", ["out/add.o", "-o", "out/add"]) {
    err(e) => print("cc: {e}")
    ok(_) => {}
  }
  let ran = proc.run("out/add", []) else e => "{e}"
  print("built: {ran.trim()}")

  llvm.target.dispose_target_machine(tm)
  llvm.ir.dispose_module(m)
  llvm.ir.context_dispose(c)
}
