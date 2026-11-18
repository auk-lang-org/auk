//! The machine back end the rest of the compiler calls: compile a MIR program in memory (`jit`,
//! `jit_eval`, `jit_live`), to an object file (`object`), or to back-end IR text (`ir_text`).
//! `DUCK_BACKEND` (`llvm`, the default, | `cranelift`) picks the back end while both exist.

use std::collections::HashMap;

use super::Program;
use super::{clif, llvm};
pub use super::exec::{Jit, LiveJit, Redirect, wait_child};
use super::types::TyInfo;

/// Is the LLVM back end selected (anything but `DUCK_BACKEND=cranelift`)?
fn use_llvm() -> bool {
    std::env::var("DUCK_BACKEND").map_or(true, |b| b != "cranelift")
}

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
    if use_llvm() {
        let level = match opt {
            Opt::None => llvm::Level::O0,
            Opt::Light => llvm::Level::Light,
            Opt::Full => llvm::Level::O2,
        };
        llvm::jit(prog, info, level)
    } else {
        clif::jit(prog, info, opt == Opt::Full)
    }
}

/// The debugger's evaluation module, compiled in memory for good: (entry, `dk_init`).
pub fn jit_eval(prog: &Program, info: &TyInfo) -> Result<(*const u8, *const u8), String> {
    if use_llvm() { llvm::jit_eval(prog, info) } else { clif::jit_eval(prog, info) }
}

/// A program for `duck run --live` (calls to `slots` go through the live table at `table`).
pub fn jit_live(prog: &Program, info: &TyInfo, table: usize, slots: &HashMap<u32, usize>) -> Result<LiveJit, String> {
    if use_llvm() { llvm::jit_live(prog, info, table, slots) } else { clif::jit_live(prog, info, table, slots) }
}

/// An object file whose `main` is the entry point.
pub fn object(prog: &Program, info: &TyInfo, opt: bool) -> Result<Vec<u8>, String> {
    if use_llvm() { llvm::object(prog, info, opt) } else { clif::object(prog, info, opt) }
}

/// Cranelift IR of every function, as text (`duck ir --clif`).
pub fn clif_ir(prog: &Program, info: &TyInfo) -> Result<String, String> {
    clif::ir_text(prog, info)
}

/// The program's LLVM IR, as text (`duck ir --llvm`).
pub fn llvm_ir(prog: &Program, info: &TyInfo) -> Result<String, String> {
    llvm::ir_text(prog, info)
}
