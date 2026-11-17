//! Evaluating Duck expressions at a debugger stop (`eval`, conditional breakpoints): the
//! compiler side of the debug engine's eval hook (runtime/src/dbg.rs), installed by
//! `duck run --debug` in the program's own process.
//!
//! To check an expression with exactly the names, types and scopes of the stopped statement, it
//! is written into a copy of the program's source right there, as `let __dbg_r = (<expr>)`
//! before the statement (or, for an expression body like `= e` / `x => e`, in a block around
//! it). The copy is checked as a whole program (every module pinned to the source the running
//! program was built from), and only that expression is compiled (`lower::emit_eval`): a function
//! that reads each local it uses through the stopped frame's slot addresses and returns the
//! value shown. It runs in a fresh JIT module, so the functions it calls are fresh copies too
//! (without breakpoints); locals are the frame's own (an assignment changes them).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use super::ast::{ExprKind, PatKind};
use super::mir::progen::{DbgInfo, Gen, Mode};
use super::mir::types::TyInfo;
use super::typed::{NameRef, TypedProgram};
use duck_rt::dbg::Compiled;

/// What evaluation needs of the running program.
struct Cx {
    root: PathBuf,
    /// The source of every non-core module, as the program was built.
    srcs: HashMap<String, String>,
    info: DbgInfo,
}

static CX: Mutex<Option<Cx>> = Mutex::new(None);

/// The name an evaluated expression is bound to.
const RESULT: &str = "__dbg_r";

/// Make expressions evaluable in this process's program (`duck run --debug`).
pub fn install(root: &Path, tp: &TypedProgram, info: DbgInfo) {
    let srcs = tp.program.mods.iter().enumerate().filter(|(m, _)| !tp.program.is_core(*m)).map(|(_, m)| (m.file.clone(), m.src.clone())).collect();
    *CX.lock().unwrap_or_else(|e| e.into_inner()) = Some(Cx { root: root.to_path_buf(), srcs, info });
    duck_rt::dbg::set_eval_hook(hook);
}

fn hook(func: u32, site: u32, expr: &str) -> Result<Compiled, String> {
    let g = CX.lock().unwrap_or_else(|e| e.into_inner());
    let cx = g.as_ref().ok_or("no program to evaluate in")?;
    compile(cx, func as usize, site as usize, expr)
}

/// The char index (1-based line and column) as a byte offset into `src`.
fn offset(src: &str, line: u32, col: u32) -> usize {
    let mut off = 0;
    for (i, l) in src.split_inclusive('\n').enumerate() {
        if i + 1 == line as usize {
            return off + l.char_indices().nth(col.saturating_sub(1) as usize).map_or(l.trim_end_matches('\n').len(), |(b, _)| b);
        }
        off += l.len();
    }
    src.len()
}

fn compile(cx: &Cx, func: usize, site: usize, expr: &str) -> Result<Compiled, String> {
    // an expression; failing that, a statement such as an assignment (`x = 5`: a `var` local
    // of the frame changes), in a block whose value is `()`
    match compile_as(cx, func, site, &format!("({expr})")) {
        Ok(c) => Ok(c),
        Err(e) => compile_as(cx, func, site, &format!("{{\n{expr}\n}}")).map_err(|_| e),
    }
}

fn compile_as(cx: &Cx, func: usize, site: usize, expr: &str) -> Result<Compiled, String> {
    let s = cx.info.sites.get(site).ok_or("no such statement")?;
    let f = cx.info.fns.get(func).ok_or("no such function")?;
    let mut src = cx.srcs.get(&s.file).cloned().ok_or_else(|| format!("can't evaluate in {}", s.file))?;
    // the copy with the expression in it
    let let_ = format!("let {RESULT} = {expr}");
    if s.wrap {
        let end = offset(&src, s.end_line, s.end_col);
        src.insert_str(end, "\n}");
        let start = offset(&src, s.line, s.col);
        src.insert_str(start, &format!("{{ {let_}\n"));
    } else {
        let start = offset(&src, s.line, s.col);
        src.insert_str(start, &format!("{let_}\n{}", " ".repeat(s.col.saturating_sub(1) as usize)));
    }
    let mut srcs = cx.srcs.clone();
    srcs.insert(s.file.clone(), src);
    let tp = super::resolve::with_sources(&srcs, || super::resolve::load(&cx.root).and_then(super::check::check)).map_err(|ds| {
        // the expression's own errors (in the edited file) first
        let mut ds = ds;
        ds.sort_by_key(|d| d.file != s.file);
        ds.first().map_or("it doesn't check".into(), |d| d.diag.message.clone())
    })?;
    let m = tp.program.mods.iter().position(|x| x.file == s.file).ok_or("the module is gone")?;
    // the inserted `let` and its value
    let mut value = None;
    for item in &tp.program.mods[m].ast.items {
        super::check::visit_item_exprs(item, &mut |e| {
            if let ExprKind::Let { pat, value: v, .. } = &e.kind
                && matches!(&pat.kind, PatKind::Bind(n) if n == RESULT)
                && value.is_none()
            {
                value = Some((**v).clone());
            }
        });
    }
    let value = value.ok_or("the expression got lost (compiler bug)")?;
    let inst = tp.instances.iter().position(|x| x.body == f.body && x.type_args == f.type_args).ok_or("this function isn't compiled any more")?;
    // the stopped frame's locals that it uses: by name, the latest binding in scope
    let t = &tp.tables[m];
    let inside = |sp: crate::diag::Span| (sp.line, sp.col) >= (value.span.line, value.span.col) && (sp.line, sp.col) <= (value.span.end_line, value.span.end_col);
    let mut binds = Vec::new();
    let mut slots = Vec::new();
    let mut missing = None;
    super::check::visit_expr(&value, &mut |e| {
        if let ExprKind::Name(_) = &e.kind
            && let Some(NameRef::Local(l)) = t.names.get(&e.id)
            && !inside(t.locals[*l].span)
            && !binds.contains(l)
        {
            let name = &t.locals[*l].name;
            match s.vis.iter().rev().find(|&&v| f.locals.get(v as usize).is_some_and(|x| &x.0 == name)) {
                Some(&slot) => {
                    binds.push(*l);
                    slots.push(slot);
                }
                None => missing = Some(name.clone()),
            }
        }
    });
    if let Some(n) = missing {
        return Err(format!("`{n}` has no value here"));
    }
    let subst = tp.instances[inst].subst(&tp.fns);
    let ty = t.locals.iter().rev().find(|l| l.name == RESULT).map(|l| tp.defs.show(&l.ty.subst(&subst))).unwrap_or_default();
    // compile just the expression (and what it calls)
    let mut g = Gen::new(&tp, Mode::Run);
    g.imprints = super::build::eval_imprints(&tp)?;
    let run = super::mir::lower::emit_eval(&mut g, inst, &value, &binds);
    super::build::drain(&mut g);
    let _ = g.init_and_cleanup();
    g.prog.entry = Some(run);
    let info = TyInfo::new(&tp);
    let (entry, init) = super::mir::clif::jit_eval(&g.prog, &info)?;
    // its string literals and constants
    unsafe { std::mem::transmute::<*const u8, extern "C" fn()>(init)() };
    let run = unsafe { std::mem::transmute::<*const u8, unsafe extern "C" fn(*const *mut std::ffi::c_void) -> *mut duck_rt::DuckStr>(entry) };
    Ok(Compiled { run, slots, ty })
}
