//! ORC LLJIT: one JIT instance per compiled program, with the runtime linked into this process
//! as absolute symbols. ORC only links: the program arrives as an object file compiled by our own
//! target machine (the same code generation as `auk build`), so nothing compiles lazily and no
//! LLVM thread exists when `run`/`test` fork.

use std::ffi::{CStr, CString};

use llvm_sys::error::*;
use llvm_sys::orc2::lljit::*;
use llvm_sys::orc2::*;
use llvm_sys::core::LLVMCreateMemoryBufferWithMemoryRangeCopy;

/// An LLVM error's message (consuming the error); Ok for no error.
pub fn check(e: LLVMErrorRef) -> Result<(), String> {
    if e.is_null() {
        return Ok(());
    }
    unsafe {
        let m = LLVMGetErrorMessage(e);
        let s = CStr::from_ptr(m).to_string_lossy().into_owned();
        LLVMDisposeErrorMessage(m);
        Err(s)
    }
}

/// A program's code in memory; dropping it frees the code.
pub struct Code(LLVMOrcLLJITRef);

impl Drop for Code {
    fn drop(&mut self) {
        unsafe {
            let _ = check(LLVMOrcDisposeLLJIT(self.0));
        }
    }
}

impl Code {
    /// Link object file `obj` (with the runtime) into memory.
    pub fn load(obj: &[u8]) -> Result<Code, String> {
        unsafe {
            let mut j = std::ptr::null_mut();
            check(LLVMOrcCreateLLJIT(&mut j, LLVMOrcCreateLLJITBuilder()))?;
            let code = Code(j);
            let jd = LLVMOrcLLJITGetMainJITDylib(j);
            // the runtime linked into this process
            let flags = || LLVMJITSymbolFlags {
                GenericFlags: LLVMJITSymbolGenericFlags::LLVMJITSymbolGenericFlagsExported as u8 | LLVMJITSymbolGenericFlags::LLVMJITSymbolGenericFlagsCallable as u8,
                TargetFlags: 0,
            };
            let mut pairs: Vec<LLVMOrcCSymbolMapPair> = crate::rt_symbols::rt_symbols()
                .into_iter()
                .map(|(name, addr)| {
                    let n = CString::new(name).unwrap();
                    LLVMOrcCSymbolMapPair { Name: LLVMOrcLLJITMangleAndIntern(j, n.as_ptr()), Sym: LLVMJITEvaluatedSymbol { Address: addr as u64, Flags: flags() } }
                })
                .collect();
            let mu = LLVMOrcAbsoluteSymbols(pairs.as_mut_ptr(), pairs.len());
            check(LLVMOrcJITDylibDefine(jd, mu))?;
            // libc and friends (memcpy, memset, ... that LLVM may call)
            let mut g = std::ptr::null_mut();
            check(LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(&mut g, LLVMOrcLLJITGetGlobalPrefix(j), None, std::ptr::null_mut()))?;
            LLVMOrcJITDylibAddGenerator(jd, g);
            let buf = LLVMCreateMemoryBufferWithMemoryRangeCopy(obj.as_ptr().cast(), obj.len(), c"auk".as_ptr());
            check(LLVMOrcLLJITAddObjectFile(j, jd, buf))?;
            Ok(code)
        }
    }

    /// The address of an exported function (compiling the module the first time).
    pub fn lookup(&self, name: &str) -> Result<*const u8, String> {
        let mut a = 0;
        let n = CString::new(name).unwrap();
        check(unsafe { LLVMOrcLLJITLookup(self.0, &mut a, n.as_ptr()) }).map_err(|e| format!("looking up {name}: {e}"))?;
        Ok(a as usize as *const u8)
    }
}
