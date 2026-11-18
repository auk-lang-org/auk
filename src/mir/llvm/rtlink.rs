//! Runtime functions inlined into `auk build` programs: the runtime's own LLVM bitcode (built
//! by build.rs from the same source as `libauk_rt.a`) is linked into the program's module
//! before it is optimized, so LLVM can inline small runtime functions (string and map helpers,
//! element ops) into generated code. Nothing from it is emitted: a function LLVM may inline
//! becomes `available_externally`, so every call it doesn't inline still goes to
//! `libauk_rt.a`, and the runtime's state stays in one place.
//!
//! The runtime keeps state in private globals (task heaps, the tracer, the debugger) and
//! thread-locals. A copy of a function that touched them would have its own copy of that state,
//! so only *safe* functions are offered: neither they nor the internal functions they reach
//! (directly, or through constant tables like vtables) use a private mutable global or a
//! thread-local. Unsafe exported functions become plain declarations, exported constants
//! `available_externally`, exported mutable globals declarations.
//!
//! The bitcode comes from rustc's LLVM; if this LLVM can't read it the program is built
//! without it (`link` returns false).

use std::collections::{HashMap, HashSet};
use std::ffi::CStr;

use llvm_sys::bit_reader::LLVMParseBitcodeInContext2;
use llvm_sys::core::*;
use llvm_sys::linker::LLVMLinkModules2;
use llvm_sys::prelude::*;
use llvm_sys::LLVMLinkage;

static RUNTIME_BC: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/auk_rt.bc"));

fn is_local(l: LLVMLinkage) -> bool {
    matches!(l, LLVMLinkage::LLVMInternalLinkage | LLVMLinkage::LLVMPrivateLinkage)
}

/// What a function's body depends on.
#[derive(Default)]
struct Uses {
    /// It touches a private mutable global or a thread-local itself.
    state: bool,
    /// Internal functions it references (calls, or function pointers in constant tables).
    internal: HashSet<usize>,
}

struct Scan {
    /// Function index by value.
    index: HashMap<usize, usize>,
    /// What each constant global's initializer references (memo): (touches state, internal fns).
    tables: HashMap<usize, (bool, HashSet<usize>)>,
}

impl Scan {
    /// Record what value `v` (an operand) references into `u`.
    unsafe fn value(&mut self, v: LLVMValueRef, u: &mut Uses, depth: u32) {
        unsafe {
            if v.is_null() || depth > 64 {
                return;
            }
            if !LLVMIsAFunction(v).is_null() {
                if is_local(LLVMGetLinkage(v)) && LLVMIsDeclaration(v) == 0 {
                    if let Some(&i) = self.index.get(&(v as usize)) {
                        u.internal.insert(i);
                    }
                }
            } else if !LLVMIsAGlobalVariable(v).is_null() {
                if LLVMIsThreadLocal(v) != 0 || (is_local(LLVMGetLinkage(v)) && LLVMIsGlobalConstant(v) == 0) {
                    u.state = true;
                } else if LLVMIsGlobalConstant(v) != 0 && LLVMIsDeclaration(v) == 0 {
                    let key = v as usize;
                    let (state, fns) = match self.tables.get(&key) {
                        Some(t) => t.clone(),
                        None => {
                            self.tables.insert(key, (false, HashSet::new())); // cycles
                            let mut t = Uses::default();
                            self.value(LLVMGetInitializer(v), &mut t, depth + 1);
                            self.tables.insert(key, (t.state, t.internal.clone()));
                            (t.state, t.internal)
                        }
                    };
                    u.state |= state;
                    u.internal.extend(fns);
                }
            } else if !LLVMIsAGlobalAlias(v).is_null() {
                self.value(LLVMAliasGetAliasee(v), u, depth + 1);
            } else if !LLVMIsAConstant(v).is_null() {
                for k in 0..LLVMGetNumOperands(v).max(0) {
                    self.value(LLVMGetOperand(v, k as u32), u, depth + 1);
                }
            }
        }
    }
}

fn functions(m: LLVMModuleRef) -> Vec<LLVMValueRef> {
    let mut out = Vec::new();
    unsafe {
        let mut f = LLVMGetFirstFunction(m);
        while !f.is_null() {
            out.push(f);
            f = LLVMGetNextFunction(f);
        }
    }
    out
}

fn globals(m: LLVMModuleRef) -> Vec<LLVMValueRef> {
    let mut out = Vec::new();
    unsafe {
        let mut g = LLVMGetFirstGlobal(m);
        while !g.is_null() {
            out.push(g);
            g = LLVMGetNextGlobal(g);
        }
    }
    out
}

fn name(v: LLVMValueRef) -> String {
    unsafe {
        let mut n = 0;
        let p = LLVMGetValueName2(v, &mut n);
        String::from_utf8_lossy(std::slice::from_raw_parts(p.cast::<u8>(), n)).into_owned()
    }
}

/// Link the runtime's inlinable functions into module `m` (in context `cx`; its target triple and
/// data layout already set). Returns false if the runtime bitcode can't be used here.
pub fn link(cx: LLVMContextRef, m: LLVMModuleRef) -> bool {
    unsafe {
        let buf = LLVMCreateMemoryBufferWithMemoryRangeCopy(RUNTIME_BC.as_ptr().cast(), RUNTIME_BC.len(), c"auk_rt".as_ptr());
        let mut rm = std::ptr::null_mut();
        if LLVMParseBitcodeInContext2(cx, buf, &mut rm) != 0 || rm.is_null() {
            LLVMDisposeMemoryBuffer(buf);
            return false;
        }
        LLVMDisposeMemoryBuffer(buf);
        LLVMSetTarget(rm, LLVMGetTarget(m));
        LLVMSetDataLayout(rm, LLVMGetDataLayoutStr(m));

        // what every defined function uses
        let fns = functions(rm);
        let mut scan = Scan { index: fns.iter().enumerate().map(|(i, f)| (*f as usize, i)).collect(), tables: HashMap::new() };
        let mut uses: Vec<Uses> = Vec::with_capacity(fns.len());
        for &f in &fns {
            let mut u = Uses::default();
            if LLVMIsDeclaration(f) == 0 {
                let mut b = LLVMGetFirstBasicBlock(f);
                while !b.is_null() {
                    let mut i = LLVMGetFirstInstruction(b);
                    while !i.is_null() {
                        for k in 0..LLVMGetNumOperands(i).max(0) {
                            scan.value(LLVMGetOperand(i, k as u32), &mut u, 0);
                        }
                        i = LLVMGetNextInstruction(i);
                    }
                    b = LLVMGetNextBasicBlock(b);
                }
                // a personality function is a reference too
                if LLVMHasPersonalityFn(f) != 0 {
                    scan.value(LLVMGetPersonalityFn(f), &mut u, 0);
                }
            }
            uses.push(u);
        }
        // unsafe: touches state itself, or reaches an unsafe internal function
        let mut unsafe_ = uses.iter().map(|u| u.state).collect::<Vec<bool>>();
        loop {
            let mut changed = false;
            for i in 0..fns.len() {
                if !unsafe_[i] && uses[i].internal.iter().any(|&j| unsafe_[j]) {
                    unsafe_[i] = true;
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }

        // exported functions: inlinable copies, or declarations
        for (i, &f) in fns.iter().enumerate() {
            if LLVMIsDeclaration(f) != 0 || LLVMGetLinkage(f) != LLVMLinkage::LLVMExternalLinkage {
                continue;
            }
            if !unsafe_[i] {
                LLVMSetLinkage(f, LLVMLinkage::LLVMAvailableExternallyLinkage);
                continue;
            }
            // drop the body: a fresh declaration takes over the name and every use
            let n = name(f);
            let dead = format!("{n}.dk_unsafe");
            LLVMSetValueName2(f, dead.as_ptr().cast(), dead.len());
            let decl = LLVMAddFunction(rm, CStr::from_bytes_with_nul(format!("{n}\0").as_bytes()).unwrap().as_ptr(), LLVMGlobalGetValueType(f));
            LLVMReplaceAllUsesWith(f, decl);
            LLVMDeleteFunction(f);
        }
        // exported globals: the runtime's own (one copy, in libauk_rt.a)
        for g in globals(rm) {
            if LLVMIsDeclaration(g) != 0 || is_local(LLVMGetLinkage(g)) {
                continue;
            }
            if LLVMIsGlobalConstant(g) != 0 && LLVMIsThreadLocal(g) == 0 {
                LLVMSetLinkage(g, LLVMLinkage::LLVMAvailableExternallyLinkage);
            } else {
                LLVMSetInitializer(g, std::ptr::null_mut());
                LLVMSetLinkage(g, LLVMLinkage::LLVMExternalLinkage);
            }
        }
        // exported aliases (identical functions folded, e.g. `auk_str_len` = `auk_arr_len`):
        // a declaration takes over the name; the alias goes private and unused (dropped later)
        let mut a = LLVMGetFirstGlobalAlias(rm);
        while !a.is_null() {
            let next = LLVMGetNextGlobalAlias(a);
            if !is_local(LLVMGetLinkage(a)) {
                let n = name(a);
                let dead = format!("{n}.dk_alias");
                LLVMSetValueName2(a, dead.as_ptr().cast(), dead.len());
                let ty = LLVMGlobalGetValueType(a);
                let cn = CStr::from_bytes_with_nul(format!("{n}\0").as_bytes()).unwrap().as_ptr();
                let decl = if LLVMGetTypeKind(ty) == llvm_sys::LLVMTypeKind::LLVMFunctionTypeKind { LLVMAddFunction(rm, cn, ty) } else { LLVMAddGlobal(rm, ty, cn) };
                LLVMReplaceAllUsesWith(a, decl);
                LLVMSetLinkage(a, LLVMLinkage::LLVMPrivateLinkage);
            }
            a = next;
        }
        // LLVMLinkModules2 consumes rm; true means it failed
        LLVMLinkModules2(m, rm) == 0
    }
}
