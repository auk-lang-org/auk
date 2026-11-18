//! The machine back end the rest of the compiler calls (LLVM, `llvm/`): compile a MIR program
//! in memory (`jit`, `jit_eval`, `jit_live`), to an object file (`object`), or to LLVM IR text
//! (`llvm_ir`).

use std::collections::HashMap;

use super::Program;
use super::llvm;
pub use super::exec::{Jit, LiveJit, Redirect, wait_child};
use super::types::TyInfo;

/// How much to optimize code compiled in memory.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Opt {
    /// Nothing: compile as fast as possible (tests, imprints, the debugger, the REPL).
    None,
    /// A few cheap passes (`duck run`).
    Light,
    /// The full optimizer (`duck run -O`).
    Full,
}

/// Compile a program in memory.
pub fn jit(prog: &Program, info: &TyInfo, opt: Opt) -> Result<Jit, String> {
    let level = match opt {
        Opt::None => llvm::Level::O0,
        Opt::Light => llvm::Level::Light,
        Opt::Full => llvm::Level::O2,
    };
    llvm::jit(prog, info, level)
}

/// The debugger's evaluation module, compiled in memory for good: (entry, `dk_init`).
pub fn jit_eval(prog: &Program, info: &TyInfo) -> Result<(*const u8, *const u8), String> {
    llvm::jit_eval(prog, info)
}

/// A program for `duck run --live` (calls to `slots` go through the live table at `table`).
pub fn jit_live(prog: &Program, info: &TyInfo, table: usize, slots: &HashMap<u32, usize>) -> Result<LiveJit, String> {
    llvm::jit_live(prog, info, table, slots)
}

/// An object file whose `main` is the entry point; `opt`: optimize (O2, with the runtime's
/// inlinable functions).
pub fn object(prog: &Program, info: &TyInfo, opt: bool) -> Result<Vec<u8>, String> {
    llvm::object(prog, info, opt)
}

/// The program's LLVM IR, as text (`duck ir --llvm`).
pub fn llvm_ir(prog: &Program, info: &TyInfo) -> Result<String, String> {
    llvm::ir_text(prog, info)
}
