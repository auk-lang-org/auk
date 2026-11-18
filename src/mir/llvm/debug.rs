//! DWARF debug info for native builds (`duck build -g`) through LLVM's DIBuilder: a line table
//! that maps machine code back to Duck source lines, and a subprogram per Duck function (named by
//! its Duck name, `prog.fact`), so lldb, gdb and editor front ends like CodeLLDB can set
//! `file:line` breakpoints, step by source line and show where they are.
//!
//! Lowering marks every statement with `Stmt::Loc` (an index into `Program::locs`); the code
//! generator sets the builder's location from it. There is no DWARF language code for Duck, so
//! the unit says C. Variables are not described: the instrumented debugger (`duck run --debug`,
//! `duck debug`, `duck dap`) is the one that shows Duck values. On Mach-O the linker leaves DWARF
//! in the object file, so `duck build` runs `dsymutil` to gather it into `<out>.dSYM`.

use std::collections::HashMap;
use std::path::Path;

use llvm_sys::core::*;
use llvm_sys::debuginfo::*;
use llvm_sys::prelude::*;
use llvm_sys::LLVMModuleFlagBehavior;

use super::super::{Program, Stmt};

pub struct Debug {
    cx: LLVMContextRef,
    dib: LLVMDIBuilderRef,
    cwd: String,
    files: HashMap<String, LLVMMetadataRef>,
    fn_ty: LLVMMetadataRef,
    /// The compile unit's file (generated functions are placed there, at line 0).
    main: LLVMMetadataRef,
}

fn abs(f: &str) -> String {
    std::fs::canonicalize(f).map(|p| p.display().to_string()).unwrap_or_else(|_| f.to_string())
}

/// The first source location in a body (where the function is said to be).
fn first_loc(ss: &[Stmt]) -> Option<u32> {
    for s in ss {
        match s {
            Stmt::Loc(i) => return Some(*i),
            Stmt::If(_, a, b) | Stmt::Loop(a, b) => {
                if let Some(i) = first_loc(a).or_else(|| first_loc(b)) {
                    return Some(i);
                }
            }
            _ => {}
        }
    }
    None
}

impl Debug {
    /// Debug info for module `m`, if the program carries source locations (`-g`).
    pub fn new(cx: LLVMContextRef, m: LLVMModuleRef, prog: &Program) -> Option<Debug> {
        if prog.locs.is_empty() {
            return None;
        }
        unsafe {
            let i32t = LLVMInt32TypeInContext(cx);
            let flag = |k: &str, v: u32| {
                let md = LLVMValueAsMetadata(LLVMConstInt(i32t, v as u64, 0));
                LLVMAddModuleFlag(m, LLVMModuleFlagBehavior::LLVMModuleFlagBehaviorWarning, k.as_ptr().cast(), k.len(), md);
            };
            flag("Debug Info Version", LLVMDebugMetadataVersion());
            flag("Dwarf Version", 4);
            let dib = LLVMCreateDIBuilder(m);
            let cwd = std::env::current_dir().map(|d| d.display().to_string()).unwrap_or_else(|_| "/".into());
            let mut d = Debug { cx, dib, cwd, files: HashMap::new(), fn_ty: std::ptr::null_mut(), main: std::ptr::null_mut() };
            // the compile unit is named after the program's first source file
            let main = prog.locs.iter().map(|l| &l.0).find(|f| Path::new(f).is_file()).cloned().unwrap_or_else(|| prog.locs[0].0.clone());
            let file = d.file(&main);
            d.main = file;
            let producer = format!("duck {}", env!("CARGO_PKG_VERSION"));
            LLVMDIBuilderCreateCompileUnit(
                dib,
                LLVMDWARFSourceLanguage::LLVMDWARFSourceLanguageC99,
                file,
                producer.as_ptr().cast(),
                producer.len(),
                1,
                c"".as_ptr(),
                0,
                0,
                c"".as_ptr(),
                0,
                LLVMDWARFEmissionKind::LLVMDWARFEmissionKindFull,
                0,
                0,
                0,
                c"".as_ptr(),
                0,
                c"".as_ptr(),
                0,
            );
            d.fn_ty = LLVMDIBuilderCreateSubroutineType(dib, file, std::ptr::null_mut(), 0, LLVMDIFlagZero);
            Some(d)
        }
    }

    fn file(&mut self, f: &str) -> LLVMMetadataRef {
        if let Some(&m) = self.files.get(f) {
            return m;
        }
        let p = abs(f);
        let path = Path::new(&p);
        let dir = path.parent().map(|d| d.display().to_string()).filter(|d| !d.is_empty()).unwrap_or_else(|| self.cwd.clone());
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or(p.clone());
        let m = unsafe { LLVMDIBuilderCreateFile(self.dib, name.as_ptr().cast(), name.len(), dir.as_ptr().cast(), dir.len()) };
        self.files.insert(f.to_string(), m);
        m
    }

    /// Attach a subprogram to function `fv` (MIR function `fi`); returns it and the location of
    /// the function's first line (for its prologue). Every function gets one, so Duck code that
    /// LLVM inlines into it keeps its lines: a Duck body is named by its Duck name (`prog.fact`)
    /// at its first statement, a generated function (shims, element ops, ...) by its symbol,
    /// marked artificial, at line 0.
    pub fn subprogram(&mut self, fv: LLVMValueRef, prog: &Program, fi: usize) -> (LLVMMetadataRef, LLVMMetadataRef) {
        let f = &prog.funcs[fi];
        let duck = prog.names.get(&(fi as u32)).and_then(|n| first_loc(&f.body).map(|l| (n, l)));
        let (name, fm, line, col, flags) = match duck {
            Some((n, l)) => {
                let (file, line, col) = &prog.locs[l as usize];
                (n.as_str(), self.file(file), *line, *col, LLVMDIFlagZero)
            }
            None => (f.name.as_str(), self.main, 0, 0, LLVMDIFlagArtificial),
        };
        unsafe {
            let sp = LLVMDIBuilderCreateFunction(self.dib, fm, name.as_ptr().cast(), name.len(), c"".as_ptr(), 0, fm, line, self.fn_ty, 0, 1, line, flags, 1);
            LLVMSetSubprogram(fv, sp);
            let at = LLVMDIBuilderCreateDebugLocation(self.cx, line, col, sp, std::ptr::null_mut());
            (sp, at)
        }
    }

    /// The location `Program::locs[i]` in subprogram `sp`. A location in another file than the
    /// function's (code inlined by lowering) still names its own line.
    pub fn loc(&self, prog: &Program, i: u32, sp: LLVMMetadataRef) -> LLVMMetadataRef {
        let (_, line, col) = &prog.locs[i as usize];
        unsafe { LLVMDIBuilderCreateDebugLocation(self.cx, *line, *col, sp, std::ptr::null_mut()) }
    }

    /// Finish the debug info (before the module is verified or emitted).
    pub fn finish(self) {
        unsafe {
            LLVMDIBuilderFinalize(self.dib);
            LLVMDisposeDIBuilder(self.dib);
        }
    }
}
