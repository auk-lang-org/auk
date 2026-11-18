//! The LLVM back end: MIR → LLVM IR (`codegen.rs`) → machine code in memory (ORC, `jit.rs`) or an
//! object file (`object`, linked by `build.rs` into an executable).

mod codegen;
mod debug;
mod jit;
mod rtlink;

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::sync::Once;

use llvm_sys::analysis::{LLVMVerifierFailureAction, LLVMVerifyModule};
use llvm_sys::core::*;
use llvm_sys::prelude::{LLVMContextRef, LLVMModuleRef};
use llvm_sys::target::*;
use llvm_sys::target_machine::*;
use llvm_sys::transforms::pass_builder::*;

use super::Program;
use super::exec::{Jit, LiveJit};
use super::types::TyInfo;
use codegen::{Exports, Gen};

/// How much to optimize.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Level {
    /// Nothing (fastest to compile): tests, imprints, debugger evaluations.
    O0,
    /// A few cheap passes (`auk run`).
    Light,
    O2,
    O3,
}

impl Level {
    /// The pass pipeline. Every level first drops functions nothing uses (`globaldce`): code
    /// generation is most of the time spent compiling in memory.
    fn passes(self) -> Option<&'static str> {
        match self {
            Level::O0 => Some("globaldce"),
            Level::Light => Some("globaldce,function(sroa,early-cse,instcombine<no-verify-fixpoint>,simplifycfg)"),
            Level::O2 => Some("default<O2>"),
            Level::O3 => Some("default<O3>"),
        }
    }
    /// The code generator's level. `Light` uses the fast instruction selector too: on IR the
    /// light passes cleaned up it makes about the same code as SelectionDAG at half the cost.
    fn codegen(self) -> LLVMCodeGenOptLevel {
        match self {
            Level::O0 | Level::Light => LLVMCodeGenOptLevel::LLVMCodeGenLevelNone,
            Level::O2 => LLVMCodeGenOptLevel::LLVMCodeGenLevelDefault,
            Level::O3 => LLVMCodeGenOptLevel::LLVMCodeGenLevelAggressive,
        }
    }
}

fn init() {
    static INIT: Once = Once::new();
    INIT.call_once(|| unsafe {
        LLVM_InitializeNativeTarget();
        LLVM_InitializeNativeAsmPrinter();
        LLVM_InitializeNativeAsmParser();
    });
}

/// Take an LLVM-allocated message.
fn message(m: *mut libc::c_char) -> String {
    if m.is_null() {
        return String::new();
    }
    unsafe {
        let s = CStr::from_ptr(m).to_string_lossy().into_owned();
        LLVMDisposeMessage(m);
        s
    }
}

/// A target machine for this computer.
fn target_machine(level: Level) -> Result<LLVMTargetMachineRef, String> {
    init();
    unsafe {
        let triple = LLVMGetDefaultTargetTriple();
        let mut target = std::ptr::null_mut();
        let mut err = std::ptr::null_mut();
        if LLVMGetTargetFromTriple(triple, &mut target, &mut err) != 0 {
            LLVMDisposeMessage(triple);
            return Err(message(err));
        }
        let cpu = LLVMGetHostCPUName();
        let features = LLVMGetHostCPUFeatures();
        // AUK_LLVM_CODEGEN=0..3 overrides the code generator's level (tuning)
        let cg = match std::env::var("AUK_LLVM_CODEGEN").ok().as_deref() {
            Some("0") => Level::O0,
            Some("1") => Level::Light,
            Some("2") => Level::O2,
            Some("3") => Level::O3,
            _ => level,
        };
        let tm = LLVMCreateTargetMachine(target, triple, cpu, features, cg.codegen(), LLVMRelocMode::LLVMRelocPIC, LLVMCodeModel::LLVMCodeModelDefault);
        LLVMDisposeMessage(triple);
        LLVMDisposeMessage(cpu);
        LLVMDisposeMessage(features);
        if tm.is_null() {
            return Err("cannot create an LLVM target machine for this computer".into());
        }
        if cg.codegen() == LLVMCodeGenOptLevel::LLVMCodeGenLevelNone {
            // GlobalISel (AArch64's default at O0) has a pass that is quadratic in a block's size
            // (`Localizer`): 12 s for a program with a big package. FastISel compiles it in a blink.
            LLVMSetTargetMachineGlobalISel(tm, 0);
            LLVMSetTargetMachineFastISel(tm, 1);
        }
        Ok(tm)
    }
}

/// A translated, verified and optimized module (in a new context).
struct Built {
    cx: LLVMContextRef,
    m: LLVMModuleRef,
    tm: LLVMTargetMachineRef,
}

/// Translate, verify and optimize `prog`. `link_runtime`: link the runtime's inlinable functions
/// into the module first (`rtlink.rs`; `auk build` only: it costs compile time).
fn build(prog: &Program, info: &TyInfo, ex: &Exports, live: Option<(usize, HashMap<u32, usize>)>, level: Level, link_runtime: bool) -> Result<Built, String> {
    build_at(prog, info, ex, live, level, link_runtime, false)
}

/// `build`; `raw`: without the pass pipeline.
fn build_at(prog: &Program, info: &TyInfo, ex: &Exports, live: Option<(usize, HashMap<u32, usize>)>, level: Level, link_runtime: bool, raw: bool) -> Result<Built, String> {
    let tm = target_machine(level)?;
    unsafe {
        let cx = LLVMContextCreate();
        let m = {
            let mut g = Gen::new(cx, "auk", prog, info, live);
            g.inline_rt = level != Level::O0;
            g.program(ex)?;
            g.m
        };
        let triple = LLVMGetTargetMachineTriple(tm);
        LLVMSetTarget(m, triple);
        LLVMDisposeMessage(triple);
        let dl = LLVMCreateTargetDataLayout(tm);
        LLVMSetModuleDataLayout(m, dl);
        llvm_sys::target::LLVMDisposeTargetData(dl);
        // AUK_NO_RT_INLINE=1: without the runtime's bitcode (to compare)
        if link_runtime && std::env::var_os("AUK_NO_RT_INLINE").is_none() && !rtlink::link(cx, m) {
            eprintln!("note: the runtime's bitcode can't be used with this LLVM; runtime calls won't be inlined");
        }
        if cfg!(debug_assertions) || std::env::var_os("AUK_VERIFY").is_some() {
            let mut msg = std::ptr::null_mut();
            if LLVMVerifyModule(m, LLVMVerifierFailureAction::LLVMReturnStatusAction, &mut msg) != 0 {
                let why = message(msg);
                let ir = if std::env::var_os("AUK_VERIFY").is_some() { message(LLVMPrintModuleToString(m)) } else { String::new() };
                LLVMDisposeModule(m);
                LLVMContextDispose(cx);
                LLVMDisposeTargetMachine(tm);
                return Err(format!("invalid LLVM IR: {why}{ir}"));
            }
        }
        // AUK_LLVM_PASSES overrides the pass pipeline (tuning; empty: none)
        let custom = std::env::var("AUK_LLVM_PASSES").ok();
        let passes = match &custom {
            _ if raw => None,
            Some(p) if p.is_empty() => None,
            Some(p) => Some(p.as_str()),
            None => level.passes(),
        };
        if let Some(p) = passes {
            let opts = LLVMCreatePassBuilderOptions();
            let p = CString::new(p).unwrap();
            let r = jit::check(LLVMRunPasses(m, p.as_ptr(), tm, opts));
            LLVMDisposePassBuilderOptions(opts);
            r.map_err(|e| format!("optimizing: {e}"))?;
        }
        Ok(Built { cx, m, tm })
    }
}

fn exports(entry: &str) -> Exports {
    Exports { entry: entry.into(), names: Vec::new(), all: false }
}

/// Compile a program in memory.
pub fn jit(prog: &Program, info: &TyInfo, level: Level) -> Result<Jit, String> {
    jit::open_libs(&prog.links, &prog.c_syms)?;
    let b = build(prog, info, &exports("dk_entry"), None, level, false)?;
    let code = jit::Code::load(&emit(b)?)?;
    let entry = code.lookup("dk_entry")?;
    Ok(Jit::new(entry, Box::new(code)))
}

/// The debugger's evaluation module, compiled in memory for good: (entry, `dk_init`).
pub fn jit_eval(prog: &Program, info: &TyInfo) -> Result<(*const u8, *const u8), String> {
    let ex = Exports { entry: "dk_entry".into(), names: vec!["dk_init".into()], all: false };
    jit::open_libs(&prog.links, &prog.c_syms)?;
    let b = build(prog, info, &ex, None, Level::O0, false)?;
    let code = jit::Code::load(&emit(b)?)?;
    let entry = code.lookup("dk_entry")?;
    let init = code.lookup("dk_init")?;
    std::mem::forget(code);
    Ok((entry, init))
}

/// A program for `auk run --live`: calls to the functions in `slots` go through the live table
/// at `table` (8-byte code pointers).
pub fn jit_live(prog: &Program, info: &TyInfo, table: usize, slots: &HashMap<u32, usize>) -> Result<LiveJit, String> {
    let ex = Exports { entry: "dk_entry".into(), names: Vec::new(), all: true };
    jit::open_libs(&prog.links, &prog.c_syms)?;
    let b = build(prog, info, &ex, Some((table, slots.clone())), Level::O0, false)?;
    let code = jit::Code::load(&emit(b)?)?;
    let entry = code.lookup("dk_entry")?;
    let mut addrs = HashMap::new();
    for (i, f) in prog.funcs.iter().enumerate() {
        if Some(i as u32) == prog.entry {
            addrs.insert(f.name.clone(), entry);
        } else {
            addrs.insert(f.name.clone(), code.lookup(&f.name)?);
        }
    }
    let entries = slots.iter().filter_map(|(&f, &slot)| addrs.get(&prog.funcs[f as usize].name).map(|&a| (slot, a))).collect();
    let init = *addrs.get("dk_init").ok_or("no dk_init")?;
    Ok(LiveJit { jit: Jit::new(entry, Box::new(code)), entries, init, addrs })
}

/// Compile a program to an object file whose `main` is the entry point.
pub fn object(prog: &Program, info: &TyInfo, opt: bool) -> Result<Vec<u8>, String> {
    emit(build(prog, info, &exports("main"), None, if opt { Level::O2 } else { Level::O0 }, opt)?)
}

/// Generate machine code for a built module: an object file's bytes (consumes the module).
fn emit(b: Built) -> Result<Vec<u8>, String> {
    unsafe {
        let mut err = std::ptr::null_mut();
        let mut buf = std::ptr::null_mut();
        let r = LLVMTargetMachineEmitToMemoryBuffer(b.tm, b.m, LLVMCodeGenFileType::LLVMObjectFile, &mut err, &mut buf);
        LLVMDisposeModule(b.m);
        LLVMContextDispose(b.cx);
        LLVMDisposeTargetMachine(b.tm);
        if r != 0 {
            return Err(message(err));
        }
        let bytes = std::slice::from_raw_parts(LLVMGetBufferStart(buf).cast::<u8>(), LLVMGetBufferSize(buf)).to_vec();
        LLVMDisposeMemoryBuffer(buf);
        Ok(bytes)
    }
}

/// The program's LLVM IR at `level` (`link_runtime`: with the runtime's bitcode, as `auk build`;
/// `raw`: before the pass pipeline), as text.
pub fn ir_text_at(prog: &Program, info: &TyInfo, level: Level, link_runtime: bool, raw: bool) -> Result<String, String> {
    let b = build_at(prog, info, &exports("main"), None, level, link_runtime, raw)?;
    unsafe {
        let s = message(LLVMPrintModuleToString(b.m));
        LLVMDisposeModule(b.m);
        LLVMContextDispose(b.cx);
        LLVMDisposeTargetMachine(b.tm);
        Ok(s)
    }
}

