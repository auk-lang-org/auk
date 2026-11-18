/// Runtime functions inlined into `auk build` programs (src/mir/llvm/rtlink.rs): the runtime's
/// own LLVM bitcode (built by build.rs from the same source as `libauk_rt.a`) is linked into the
/// program's module before it is optimized, so LLVM can inline small runtime functions (string
/// and map helpers, element ops) into generated code. Nothing from it is emitted: a function
/// LLVM may inline becomes `available_externally`, so every call it doesn't inline still goes to
/// `libauk_rt.a`, and the runtime's state stays in one place.
///
/// The runtime keeps state in private globals (task heaps, the tracer, the debugger) and
/// thread-locals. A copy of a function that touched them would have its own copy of that state,
/// so only *safe* functions are offered: neither they nor the internal functions they reach
/// (directly, or through constant tables like vtables) use a private mutable global or a
/// thread-local. Unsafe exported functions become plain declarations, exported constants
/// `available_externally`, exported mutable globals declarations.
///
/// The bitcode is embedded in the compiler (`#embed`): build.rs copies it to `target/auk-rt/`.
/// If this LLVM can't read it the program is built without it (`link` returns false). Rust keys
/// its maps by pointer; here by the value's address (`addr_of`).

extern fn runtime_bc(): ffi.Ptr = "#embed ../../target/auk-rt/auk_rt.bc"
extern fn runtime_bc_len(): int = "#embed ../../target/auk-rt/auk_rt.bc"

extern fn c_buffer(
  data: ffi.Ptr,
  n: int,
  name: str,
): llvm.MemoryBuffer = "LLVMMemoryBufferRef LLVMCreateMemoryBufferWithMemoryRangeCopy(void *, size_t, const char *)"

extern fn value_ptr(v: llvm.Value): ffi.Ptr = "(void *)"

// LLVMGetOperand may give NULL (a missing operand)
extern fn c_get_operand(
  v: llvm.Value,
  i: int,
): llvm.Value? = "LLVMValueRef LLVMGetOperand(LLVMValueRef, unsigned)"

fn addr_of(v: llvm.Value): int uses ffi = ffi.addr(value_ptr(v))

fn is_local(l: int): bool = l == llvm.INTERNAL_LINKAGE || l == llvm.PRIVATE_LINKAGE

/// What a function's body depends on.
struct Uses {
  /// It touches a private mutable global or a thread-local itself.
  state: bool,
  /// Internal functions it references (calls, or function pointers in constant tables).
  internal: {int: bool},
}

fn no_uses(): Uses = Uses { state: false, internal: {} }

struct Scan {
  /// Function index by value.
  index: {int: int},
  /// What each constant global's initializer references (memo): (touches state, internal fns).
  tables: {int: (bool, {int: bool})},
}

/// Record what value `v` (an operand) references into `u`.
fn value(sc: var Scan, v: llvm.Value?, u: var Uses, depth: int) uses ffi {
  let v = v else return
  if depth > 64 { return }
  if llvm.values.is_a_function(v) != none {
    if is_local(llvm.values.get_linkage(v)) && llvm.values.is_declaration(v) == 0 {
      match sc.index.get(addr_of(v)) {
        some(i) => u.internal[i] = true
        none => {}
      }
    }
  } else if llvm.values.is_a_global_variable(v) != none {
    if llvm.values.is_thread_local(v) != 0 ||
      is_local(llvm.values.get_linkage(v)) && llvm.values.is_global_constant(v) == 0 {
      u.state = true
    } else if llvm.values.is_global_constant(v) != 0 && llvm.values.is_declaration(v) == 0 {
      let key = addr_of(v)
      let (state, fns) = match sc.tables.get(key) {
        some(t) => t
        none => {
          sc.tables[key] = (false, {})  // cycles
          var t = no_uses()
          value(&sc, llvm.values.get_initializer(v), &t, depth + 1)
          sc.tables[key] = (t.state, t.internal)
          (t.state, t.internal)
        }
      }
      if state { u.state = true }
      for f in fns.keys() { u.internal[f] = true }
    }
  } else if llvm.values.is_a_global_alias(v) != none {
    value(&sc, llvm.values.alias_get_aliasee(v), &u, depth + 1)
  } else if llvm.values.is_a_constant(v) != none {
    for k in 0..max(llvm.values.get_num_operands(v), 0) {
      value(&sc, c_get_operand(v, k), &u, depth + 1)
    }
  }
}

fn functions(m: llvm.Module): [llvm.Value] uses ffi {
  var out: [llvm.Value] = []
  var f = llvm.ir.get_first_function(m)
  loop {
    let x = f else break
    out.push(x)
    f = llvm.ir.get_next_function(x)
  }
  out
}

fn globals(m: llvm.Module): [llvm.Value] uses ffi {
  var out: [llvm.Value] = []
  var g = llvm.values.get_first_global(m)
  loop {
    let x = g else break
    out.push(x)
    g = llvm.values.get_next_global(x)
  }
  out
}

fn name(v: llvm.Value): str uses ffi {
  var n = 0
  llvm.values.get_value_name2(v, &n)
}

/// Link the runtime's inlinable functions into module `m` (in context `cx`; its target triple and
/// data layout already set). Returns false if the runtime bitcode can't be used here.
pub fn link(cx: llvm.Context, m: llvm.Module): bool uses ffi {
  let buf = c_buffer(runtime_bc(), runtime_bc_len(), "auk_rt")
  var parsed: llvm.Module? = none
  if llvm.bitcode.parse_bitcode_in_context2(cx, buf, &parsed) != 0 || parsed == none {
    llvm.bitcode.dispose_memory_buffer(buf)
    return false
  }
  llvm.bitcode.dispose_memory_buffer(buf)
  let rm = parsed!
  llvm.ir.set_target(rm, llvm.ir.get_target(m))
  llvm.ir.set_data_layout(rm, llvm.ir.get_data_layout_str(m))

  // what every defined function uses
  let fns = functions(rm)
  var index: {int: int} = {}
  for i, f in fns { index[addr_of(f)] = i }
  var sc = Scan { index, tables: {} }
  var used: [Uses] = []
  for f in fns {
    var u = no_uses()
    if llvm.values.is_declaration(f) == 0 {
      var b = llvm.values.get_first_basic_block(f)
      loop {
        let bb = b else break
        var i = llvm.values.get_first_instruction(bb)
        loop {
          let ins = i else break
          for k in 0..max(llvm.values.get_num_operands(ins), 0) {
            value(&sc, c_get_operand(ins, k), &u, 0)
          }
          i = llvm.values.get_next_instruction(ins)
        }
        b = llvm.values.get_next_basic_block(bb)
      }
      // a personality function is a reference too
      if llvm.values.has_personality_fn(f) != 0 {
        value(&sc, llvm.values.get_personality_fn(f), &u, 0)
      }
    }
    used.push(u)
  }
  // unsafe: touches state itself, or reaches an unsafe internal function
  var bad = used.map(u => u.state)
  loop {
    var changed = false
    for i in 0..fns.len() {
      if !bad[i] && used[i].internal.keys().any(j => bad[j]) {
        bad[i] = true
        changed = true
      }
    }
    if !changed { break }
  }

  // exported functions: inlinable copies, or declarations
  for i, f in fns {
    if llvm.values.is_declaration(f) != 0 || llvm.values.get_linkage(f) != llvm.EXTERNAL_LINKAGE {
      continue
    }
    if !bad[i] {
      llvm.values.set_linkage(f, llvm.AVAILABLE_EXTERNALLY_LINKAGE)
      continue
    }
    // drop the body: a fresh declaration takes over the name and every use
    let n = name(f)
    llvm.values.set_value_name2(f, "{n}.dk_unsafe")
    let decl = llvm.ir.add_function(rm, n, llvm.values.global_get_value_type(f))
    llvm.values.replace_all_uses_with(f, decl)
    llvm.values.delete_function(f)
  }
  // exported globals: the runtime's own (one copy, in libauk_rt.a)
  for g in globals(rm) {
    if llvm.values.is_declaration(g) != 0 || is_local(llvm.values.get_linkage(g)) { continue }
    if llvm.values.is_global_constant(g) != 0 && llvm.values.is_thread_local(g) == 0 {
      llvm.values.set_linkage(g, llvm.AVAILABLE_EXTERNALLY_LINKAGE)
    } else {
      llvm.values.set_initializer(g, none)
      llvm.values.set_linkage(g, llvm.EXTERNAL_LINKAGE)
    }
  }
  // exported aliases (identical functions folded, e.g. `auk_str_len` = `auk_arr_len`):
  // a declaration takes over the name; the alias goes private and unused (dropped later)
  var a = llvm.values.get_first_global_alias(rm)
  loop {
    let al = a else break
    let next = llvm.values.get_next_global_alias(al)
    if !is_local(llvm.values.get_linkage(al)) {
      let n = name(al)
      llvm.values.set_value_name2(al, "{n}.dk_alias")
      let ty = llvm.values.global_get_value_type(al)
      let decl = if llvm.ir.get_type_kind(ty) == llvm.FUNCTION_TYPE_KIND {
        llvm.ir.add_function(rm, n, ty)
      } else {
        llvm.values.add_global(rm, ty, n)
      }
      llvm.values.replace_all_uses_with(al, decl)
      llvm.values.set_linkage(al, llvm.PRIVATE_LINKAGE)
    }
    a = next
  }
  // LLVMLinkModules2 consumes rm; true means it failed
  llvm.bitcode.link_modules2(m, rm) == 0
}
