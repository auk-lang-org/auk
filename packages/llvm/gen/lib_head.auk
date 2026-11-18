/// Bindings to LLVM's C API (LLVM 23), for the Auk compiler's back end. Generated from a list
/// (gen/bind.txt) by gen/gen.py: one `extern fn` per C function, named in snake_case without
/// `LLVM` (`LLVMBuildAdd` → `llvm.builder.build_add`), in a module per area:
///
/// - `llvm.ir`: contexts, modules, types, attributes, verification, printing
/// - `llvm.values`: constants, globals, functions, parameters, basic blocks, instructions
/// - `llvm.builder`: the instruction builder
/// - `llvm.debug`: the DIBuilder (DWARF)
/// - `llvm.target`: targets, target machines, data layouts, object files
/// - `llvm.orc`: ORC LLJIT and LLVM errors
/// - `llvm.bitcode`: memory buffers, bitcode, the linker
/// - `llvm.passes`: the new pass manager
/// - `llvm.kit` (by hand): target setup, errors as `str`, buffers as bytes, calling JIT code
///
/// Each `LLVM*Ref` is its own type here (`llvm.Value`, `llvm.Type`, ...), so they don't mix.
/// `LLVMBool` and enums are `int` (enum values are the constants below: `LLVMIntEQ` →
/// `llvm.INT_EQ`). Strings LLVM hands over are copied and disposed of; a `const char *` with a
/// length takes a `str` alone, and an array with a count takes a list alone. Out-parameters are
/// `var`: `var m: llvm.Module? = none; parse_bitcode_in_context2(c, buf, &m)`.
///
/// Everything here `uses ffi`: LLVM can abort the process, which `catch` can't stop.
