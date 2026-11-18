# llvm

Bindings to LLVM's C API (LLVM 23), for the Auk compiler's back end: build IR, verify and
print it, optimize it, emit object files and bitcode, link modules, add debug info, and run code
in memory with ORC LLJIT. They are generated from a list, not written by hand.

**Effects:** `ffi`. **Links:** `/opt/homebrew/opt/llvm@23/lib/libLLVM.dylib` (`brew install
llvm@23`; `auk run`/`test` `dlopen` it, `auk build` links it).

```auk
let c = llvm.ir.context_create()
let m = llvm.ir.module_create_with_name_in_context("demo", c)
let i64 = llvm.ir.int64_type_in_context(c)
let f = llvm.ir.add_function(m, "add", llvm.ir.function_type(i64, [i64, i64], 0))
let b = llvm.builder.create_builder_in_context(c)
llvm.builder.position_builder_at_end(b, llvm.values.append_basic_block_in_context(c, f, "entry"))
let sum = llvm.builder.build_add(b, llvm.values.get_param(f, 0), llvm.values.get_param(f, 1), "sum")
let _ = llvm.builder.build_ret(b, sum)
llvm.kit.verify(m)?
print(llvm.ir.print_module_to_string(m))

let tm = llvm.kit.host_machine(llvm.kit.Level.Default)?   // for this computer
llvm.kit.set_target(m, tm)
let jt = llvm.kit.jit()?                      // ORC LLJIT
llvm.kit.add_object(jt, llvm.kit.emit(tm, m, false)?)?
print(llvm.kit.call_ii_i(llvm.kit.lookup(jt, "add")?, 40, 2))   // 42
```

`example/` does the same, then writes `add.o` and `add.bc`, links the object with `cc` into an
executable and runs it (`cd example && raft install && auk run src/main.auk`).

## Names and types

- `LLVMFooBar` is `llvm.<area>.foo_bar` (`LLVMBuildICmp` → `llvm.builder.build_icmp`,
  `LLVMOrcLLJITLookup` → `llvm.orc.orc_lljit_lookup`). Areas: `ir` (context, module, types,
  attributes, verify, print), `values` (constants, globals, functions, blocks, instructions),
  `builder`, `debug` (DIBuilder), `target` (targets, target machines, object files), `orc`
  (LLJIT, errors), `bitcode` (memory buffers, bitcode, linker), `passes`.
- Each `LLVMFooRef` is its own type `llvm.Foo` (`llvm.Value`, `llvm.Type`, `llvm.OrcLLJIT`, ...),
  so a type can't be passed as a value. A result that may be NULL is `T?` (`get_first_function`,
  `is_a_function`, `get_named_function`, every `LLVMErrorRef`); so is a parameter that takes
  NULL (`set_initializer(g, none)`, `set_current_debug_location2(b, none)`).
- `LLVMBool` and enums are `int`. The enum values the compiler uses are constants:
  `LLVMIntSLT` → `llvm.INT_SLT`, `LLVMPrivateLinkage` → `llvm.PRIVATE_LINKAGE`.
- `const char *` is `str`. A string with a length (`const char *Name, size_t NameLen`) takes the
  `str` alone, and an array with a count (`LLVMValueRef *Args, unsigned NumArgs`) takes a list
  alone: `build_call2(b, fty, f, [x, y], "r")`.
- Strings LLVM hands over (`LLVMPrintModuleToString`, `char **ErrorMessage`) are copied and
  disposed of. Out-parameters are `var`: `var m: llvm.Module? = none`,
  `parse_bitcode_in_context2(c, buf, &m)`.
- Callbacks and pointers to C structs are `ffi.Ptr` (pass `ffi.null`, or lay the struct out with
  `ffi.alloc`/`write_*`, as `llvm.kit.define` does for `LLVMOrcCSymbolMapPair`).

## `llvm.kit` (by hand)

`init_native()` (AArch64 and x86), `check(e: llvm.Error?): ()!`, `host_machine(level)`,
`set_target(m, tm)`, `verify(m)`, `run_passes(m, "default<O2>", tm)`, `emit(tm, m, asm)`:
`[int]`, `bitcode(m)`, `parse_bitcode(c, bytes)`, `take_bytes(buffer)`, and ORC: `jit()`,
`define(jit, [(name, address)])` (absolute symbols), `add_object(jit, obj)`,
`lookup(jit, name): ffi.Ptr`, `close(jit)`. JIT code is called through an `extern fn` with a
function-pointer prototype, address first: `call_ii_i(f, a, b)` is
`"int64_t (*)(int64_t, int64_t)"`; declare one per signature you call.

`llvm.codegen` is a piece of the Rust back end (`Gen::bin`, `truth`, `bool8`, `cstr_addr` from
`src/mir/llvm/codegen.rs`) ported to Auk, with a test that JIT-compiles and calls the result.

## Regenerating

```
python3 packages/llvm/gen/gen.py            # writes src/{lib,ir,values,builder,debug,target,orc,bitcode,passes}.auk
python3 packages/llvm/gen/gen.py --check    # LLVM names src/ (the Rust back end) uses but bind.txt lacks
python3 packages/llvm/gen/gen.py --survey   # how much of the whole C API the FFI can express
```

`gen/bind.txt` is the list: every LLVM function, `Ref` type and enum value the Rust back end uses
(`src/mir/llvm/*.rs`, `src/build.rs`), plus a few for the helpers and tests. Signatures come from
`/opt/homebrew/opt/llvm@23/include/llvm-c`. `kit.auk`, `codegen.auk` and `proof.auk` are
hand-written; `gen/lib_head.auk` is the top of `lib.auk`.

Bound: 211 functions (ir 40, values 54, builder 56, debug 10, target 24, orc 16, bitcode 8,
passes 3), 21 types, 57 constants. Of the names `src/` uses, only three structs aren't bound as
such: `LLVMOrcCSymbolMapPair`, `LLVMJITEvaluatedSymbol` and `LLVMJITSymbolFlags` travel by value
inside an array, so `kit.define` lays them out by hand. Across the whole C API, 1062 of 1066
functions bind (`--survey`); the rest take `const char **` (`LLVMParseCommandLineOptions`,
`LLVMRunFunctionAsMain`) or MCJIT's options struct.
