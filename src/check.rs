//! Types, inference, overloading and shapes: AST + module tree -> `TypedProgram`.
//!
//! Phases:
//! 1. **collect** (this file): register every struct, enum, opaque type and shape per module,
//!    resolve their field types, split each parsed clause group by first-parameter type into
//!    functions (overloads), compute each function's signature (annotations, or types implied by
//!    clause patterns), and register constants and tests.
//! 2. **bodies** (check/expr.rs, check/pat.rs): bidirectional inference. `infer(e, hint)` gives an
//!    expression's own type, using the hint for inference only; `check(e, want)` also converts
//!    it (auto-wrap into `T?`/`T!`, conversion to `any S`). Inference variables live in the body's
//!    `Infer` and are resolved when the body is done.
//! 3. **shapes and monomorphization** (check/shapes.rs): deferred shape-bound checks
//!    (structural fit, with derived instances for the built-in shapes), then the instance
//!    worklist that produces `TypedProgram::instances`.
//!
//! Name lookup in a module (spec "Modules, packages"): locals, then the module's items, then
//! core's public items (local names shadow core: `core.x` reaches the hidden one; a local named
//! like a core module makes `env.get(k)` a method call, see `expr_path`). A dot call
//! `x.f(a)` looks for `f` by `x`'s type: in the current module, then in the module that defines
//! `x`'s type, then in core. A bare name in a pattern is the variant of that name when one is in
//! scope (an enum of the current module or core), or when the matched type is an enum with such
//! a variant (so a dependency's error variants can be matched unqualified); otherwise it binds.

mod expr;
mod pat;
pub(crate) mod shapes;

use std::collections::{BTreeSet, HashMap, HashSet};

use super::ast::{self, FnBody, FnClause, Item, NodeId, PatKind, TypeKind};
use super::diag::{Diag, FileDiag, Span};
use super::resolve::{ModId, Program};
use super::typed::*;
use super::types::*;

/// Type-check a loaded program, then check patterns (exhaustiveness, reachability) and effects.
/// Warnings are dropped when there is no error; `check_all` returns them too. Units of measure
/// are erased from the result (it is what codegen gets).
pub fn check(prog: Program) -> Result<TypedProgram, Vec<FileDiag>> {
    match check_all(prog) {
        (Some(mut tp), _) => {
            super::units::erase(&mut tp);
            Ok(tp)
        }
        (None, diags) => Err(diags),
    }
}

/// Like `check`, also returning warnings: the typed program if there are no errors, and every
/// diagnostic (errors and warnings) in file and position order.
pub fn check_all(prog: Program) -> (Option<TypedProgram>, Vec<FileDiag>) {
    let (tp, diags) = check_partial(prog);
    let ok = diags.iter().all(|d| d.diag.is_warning());
    (tp.filter(|_| ok), diags)
}

/// Like `check_all`, but on errors still returns the program as far as it type-checked, for
/// tools (LSP hover) that want types in broken code: the side tables of every body (a node
/// whose type couldn't be inferred has `Ty::Error`), with no instances and no `main`. It is
/// `None` only when the declarations themselves don't check (no body was checked). A program
/// returned alongside an error is partial and must never reach codegen.
pub fn check_partial(prog: Program) -> (Option<TypedProgram>, Vec<FileDiag>) {
    let (tp, errs) = check_types(prog);
    let tp = match tp {
        Some(tp) if errs.is_empty() => tp,
        tp => return (tp, errs),
    };
    let mut diags = super::patterns::check(&tp);
    diags.extend(super::effects::check(&tp));
    diags.sort_by(|a, b| (a.file.as_str(), a.diag.span.line, a.diag.span.col).cmp(&(b.file.as_str(), b.diag.span.line, b.diag.span.col)));
    diags.dedup();
    (Some(tp), diags)
}

/// Types, inference, overloading and shapes only: the typed program (partial when there are
/// errors; `None` when the declarations failed) and the errors. (`auk dump check|typed`, the
/// oracles of the self-hosted checker, stop here too.)
pub(crate) fn check_types(prog: Program) -> (Option<TypedProgram>, Vec<FileDiag>) {
    let mut c = Checker::new(prog);
    c.collect();
    if !c.errs.is_empty() {
        return (None, sorted(c.errs));
    }
    c.check_bodies();
    if c.errs.is_empty() {
        c.find_main();
    }
    if !c.errs.is_empty() {
        let errs = sorted(std::mem::take(&mut c.errs));
        return (Some(c.finish()), errs);
    }
    c.monomorphize();
    let errs = std::mem::take(&mut c.errs);
    (Some(c.finish()), errs)
}

/// Errors in file and position order, without duplicates.
fn sorted(mut errs: Vec<FileDiag>) -> Vec<FileDiag> {
    errs.sort_by(|a, b| (a.file.as_str(), a.diag.span.line, a.diag.span.col).cmp(&(b.file.as_str(), b.diag.span.line, b.diag.span.col)));
    errs.dedup();
    errs
}

/// What the dotted prefix of an expression path means (`Checker::expr_path`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum ExprPath {
    Module(ModId),
    /// Not a module: the first segment is a value (a local, or not a module name at all).
    Value,
    /// A local named like a module that locals don't shadow (E0116 was reported).
    Ambiguous,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum TypeItem {
    Def(DefId),
    Shape(ShapeId),
}

/// The items declared in one module, by name.
#[derive(Debug, Default)]
pub(crate) struct ItemTable {
    pub types: HashMap<String, TypeItem>,
    pub fns: HashMap<String, Vec<FnId>>,
    pub consts: HashMap<String, ConstId>,
    pub variants: HashMap<String, Vec<(DefId, usize)>>,
}

/// Well-known core definitions.
#[derive(Debug, Default)]
pub(crate) struct Builtins {
    pub err: DefId,
    pub value: DefId,
    pub show: ShapeId,
    pub ord: ShapeId,
    pub eq: ShapeId,
    pub data: ShapeId,
}

/// Type parameter names in scope while resolving a type.
#[derive(Debug, Default, Clone)]
pub(crate) struct GenScope {
    pub names: HashMap<String, ParamId>,
    pub self_param: Option<ParamId>,
    /// Create an implicit type parameter for a shape name used as a type (function signatures).
    pub implicit: bool,
    /// Implicit parameters created so far, by shape name.
    pub implicit_params: Vec<ParamId>,
    /// Splitting clause groups: a shape name stands for itself (`Any`), only as a grouping key.
    pub key_mode: bool,
}

#[derive(Debug, Clone, PartialEq)]
enum ConstState {
    Todo,
    Busy,
    Done,
}

/// A deferred check, done when the body's types are known.
#[derive(Debug, Clone)]
pub(crate) enum Deferred {
    /// `ty` must fit `shape` (a generic bound, or an operator/interpolation need).
    Fits { ty: Ty, shape: ShapeId, span: Span, why: String },
}

/// One function, closure or other body frame (for `return`, `?`, captures and loops).
#[derive(Debug, Clone)]
pub(crate) struct Frame {
    /// What `return` / `?` / `fail` target; `None` where they are not allowed (constants).
    pub ret: Option<Ty>,
    /// The span of the return type annotation, for fix-its.
    pub ret_span: Option<Span>,
    pub scope_base: usize,
    pub captures: Vec<LocalId>,
    pub loops: Vec<LoopCx>,
    pub is_closure: bool,
    /// A `catch` body: captures by reference (it runs before the enclosing frame returns), so
    /// it may change the variables it captures.
    pub by_ref: bool,
    pub what: &'static str,
    /// Where to insert `: T` when the function has no return type (just after its `)`).
    pub ret_insert: Option<Span>,
}

#[derive(Debug, Clone)]
pub(crate) struct LoopCx {
    /// `loop` (break may carry a value) vs `while`/`for`.
    pub is_loop: bool,
    pub break_ty: Ty,
    pub saw_break: bool,
}

/// The state of the body being checked.
pub(crate) struct BodyCx {
    pub module: ModId,
    pub body: BodyRef,
    pub inf: Infer,
    pub t: Tables,
    pub scopes: Vec<HashMap<String, LocalId>>,
    pub frames: Vec<Frame>,
    pub generics: GenScope,
    pub deferred: Vec<Deferred>,
    pub callees: BTreeSet<FnId>,
    /// Inside `ensures`: the `result` local.
    pub result_local: Option<LocalId>,
    pub in_ensures: bool,
    pub olds: Vec<NodeId>,
    /// The next call is the operand of `await`: an async call runs directly.
    pub direct_await: bool,
    /// > 0 while inferring expressions whose context already failed (no follow-up errors).
    pub quiet: u32,
    pub local_start: usize,
}

pub(crate) struct Checker {
    pub prog: Program,
    pub defs: Defs,
    pub fns: Vec<FnInfo>,
    pub consts: Vec<ConstInfo>,
    pub tests: Vec<TestInfo>,
    pub items: Vec<ItemTable>,
    pub tables: Vec<Tables>,
    pub errs: Vec<FileDiag>,
    pub b: Builtins,
    const_state: Vec<ConstState>,
    /// The body stack (a constant may be checked lazily while another body is in progress).
    pub cxs: Vec<BodyCx>,
    /// The names `let` statements are binding while their values are checked (innermost last), so
    /// a closure that calls its own `let` name gets a clear E0102.
    pub binding: Vec<String>,
    /// While checking the second and later alternatives of an or-pattern: the locals the first
    /// one bound, by name (each alternative binds the same ones).
    pub or_binds: Option<HashMap<String, LocalId>>,
    /// Per body: the nodes whose targets monomorphization resolves.
    pub body_nodes: HashMap<BodyRef, BodyNodes>,
    pub main: Option<MainInfo>,
    pub instances: Vec<Instance>,
    pub types_used: BTreeSet<Ty>,
    pub shape_impls: std::collections::BTreeMap<(Builtin, Ty), Target>,
    /// User `from_value` functions used by `from_value` of a type (directly, or for a field or
    /// element of a derived one); a type not listed is derived.
    pub from_value_impls: std::collections::BTreeMap<Ty, Target>,
    /// The types whose `from_value` was resolved (`from_value_impls`).
    pub from_value_seen: HashSet<Ty>,
    pub vtables: Vec<Vtable>,
    /// How to make a local mutable, for the E0320 fix-it: the `let` keyword to replace with
    /// `var`, or (for a parameter) where to insert `var `.
    pub let_fixes: HashMap<(ModId, LocalId), Span>,
    pub param_fixes: HashMap<(ModId, LocalId), Span>,
}

/// The call, show and `any`-conversion nodes of one body (with the module they live in).
#[derive(Debug, Default, Clone)]
pub(crate) struct BodyNodes {
    pub module: ModId,
    pub calls: Vec<NodeId>,
    /// `Name` nodes naming a function used as a value (`NameRef::Fn`).
    pub fn_refs: Vec<NodeId>,
    pub shows: Vec<NodeId>,
    pub anys: Vec<NodeId>,
}

/// "a `int`" -> "an `int`": the article before a quoted type or name that starts with a vowel.
fn articles(msg: &str) -> String {
    let mut out = String::with_capacity(msg.len());
    let mut rest = msg;
    while let Some(i) = rest.find("a `") {
        let at_word = i == 0 || !rest[..i].ends_with(|c: char| c.is_alphanumeric() || c == '_');
        let next = rest[i + 3..].chars().next();
        out.push_str(&rest[..i]);
        if at_word && next.is_some_and(|c| "aeiouAEIOU".contains(c)) {
            out.push_str("an `");
        } else {
            out.push_str("a `");
        }
        rest = &rest[i + 3..];
    }
    out.push_str(rest);
    out
}

/// Edit distance counting an adjacent transposition as one edit, for "did you mean" notes.
pub(crate) fn edit_distance(a: &str, b: &str) -> usize {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let mut d = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, x) in d[0].iter_mut().enumerate() {
        *x = j;
    }
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            d[i][j] = (d[i - 1][j] + 1).min(d[i][j - 1] + 1).min(d[i - 1][j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                d[i][j] = d[i][j].min(d[i - 2][j - 2] + 1);
            }
        }
    }
    d[a.len()][b.len()]
}

/// The closest candidate to `name`, if it is close enough to be a likely typo. Ties go to the
/// first name in byte order, so the answer doesn't depend on the order of `cands` (often a
/// `HashMap`'s keys, whose order changes from run to run).
pub(crate) fn similar<'a>(name: &str, cands: impl IntoIterator<Item = &'a String>) -> Option<String> {
    let mut best: Option<(usize, &String)> = None;
    for c in cands {
        let d = edit_distance(name, c);
        if d <= (name.len().max(2) / 3).max(1) && c != name && best.is_none_or(|(bd, bc)| (d, c) < (bd, bc)) {
            best = Some((d, c));
        }
    }
    best.map(|(_, c)| c.clone())
}

impl Checker {
    fn new(prog: Program) -> Checker {
        let n = prog.mods.len();
        Checker {
            prog,
            defs: Defs::default(),
            fns: Vec::new(),
            consts: Vec::new(),
            tests: Vec::new(),
            items: (0..n).map(|_| ItemTable::default()).collect(),
            tables: (0..n).map(|_| Tables::default()).collect(),
            errs: Vec::new(),
            b: Builtins::default(),
            const_state: Vec::new(),
            cxs: Vec::new(),
            binding: Vec::new(),
            or_binds: None,
            body_nodes: HashMap::new(),
            main: None,
            instances: Vec::new(),
            types_used: BTreeSet::new(),
            shape_impls: Default::default(),
            from_value_impls: Default::default(),
            from_value_seen: Default::default(),
            vtables: Vec::new(),
            let_fixes: HashMap::new(),
            param_fixes: HashMap::new(),
        }
    }

    // ---- diagnostics ----

    pub fn err_in(&mut self, m: ModId, mut d: Diag) {
        // A type shown as `{error}` comes from an earlier error; a diagnostic about it is a
        // cascade (e.g. an ambiguous overload for an argument that didn't type-check), so it is
        // dropped. Only once an error is on record, so broken code never checks clean.
        if !self.errs.is_empty() && (d.message.contains("{error}") || d.notes.iter().any(|n| n.contains("{error}"))) {
            return;
        }
        let file = self.prog.mods[m].file.clone();
        d.message = articles(&d.message);
        d.notes = d.notes.iter().map(|n| articles(n)).collect();
        self.errs.push(FileDiag { file, diag: d });
    }

    /// Report in the current body's module.
    pub fn err(&mut self, d: Diag) {
        let m = self.cur_module();
        self.err_in(m, d);
    }

    pub fn cur_module(&self) -> ModId {
        self.cxs.last().map(|c| c.module).unwrap_or(self.prog.root)
    }

    /// Render a type for messages, resolving inference variables of the current body.
    pub fn show(&self, t: &Ty) -> String {
        let t = match self.cxs.last() {
            Some(cx) => cx.inf.resolve(t),
            None => t.clone(),
        };
        self.defs.show(&t)
    }

    // ---- collect ----

    fn collect(&mut self) {
        let nmods = self.prog.mods.len();
        // types and shapes
        for m in 0..nmods {
            for i in 0..self.prog.mods[m].ast.items.len() {
                self.declare_type(m, i);
            }
        }
        self.find_builtins();
        for m in 0..nmods {
            for i in 0..self.prog.mods[m].ast.items.len() {
                self.define_type(m, i);
            }
        }
        self.field_visibility();
        // functions, constants, tests
        for m in 0..nmods {
            for i in 0..self.prog.mods[m].ast.items.len() {
                let item = self.prog.mods[m].ast.items[i].clone();
                match &item {
                    Item::Fn(g) => self.declare_fns(m, i, g),
                    Item::Let(c) | Item::Imprint(c) => {
                        let ty = c.ty.as_ref().map(|t| self.resolve_type(m, t, &mut GenScope::default()));
                        let id = self.consts.len();
                        if let Some(&prev) = self.items[m].consts.get(&c.name.name) {
                            let at = self.consts[prev].span;
                            self.err_in(
                                m,
                                Diag::new("E0107", c.name.span, format!("`{}` is defined twice in this module", c.name.name))
                                    .note(format!("the first definition is at {at}")),
                            );
                        }
                        self.items[m].consts.insert(c.name.name.clone(), id);
                        self.consts.push(ConstInfo {
                            name: c.name.name.clone(),
                            module: m,
                            public: c.public,
                            imprint: matches!(item, Item::Imprint(_)),
                            ty: ty.unwrap_or(Ty::Error),
                            item: i,
                            span: c.name.span,
                        });
                        self.const_state.push(ConstState::Todo);
                    }
                    Item::Test(t) => self.tests.push(TestInfo { name: t.name.clone(), module: m, item: i, span: t.span }),
                    _ => {}
                }
            }
            self.check_duplicate_fns(m);
        }
    }

    fn declare_type(&mut self, m: ModId, i: usize) {
        let item = &self.prog.mods[m].ast.items[i];
        let (name, span, public, doc, generics, node, kind) = match item {
            Item::Struct(d) => (d.name.clone(), d.span, d.public, d.doc.clone(), d.generics.clone(), d.id, 0),
            Item::Enum(d) => (d.name.clone(), d.span, d.public, d.doc.clone(), d.generics.clone(), d.id, 1),
            Item::ExternType(d) => (d.name.clone(), d.span, d.public, d.doc.clone(), Vec::new(), d.id, 2),
            Item::Shape(d) => (d.name.clone(), d.span, d.public, d.doc.clone(), d.generics.clone(), d.id, 3),
            _ => return,
        };
        if self.items[m].types.contains_key(&name.name) {
            self.err_in(m, Diag::new("E0107", name.span, format!("the type `{}` is defined twice in this module", name.name)));
            return;
        }
        if matches!(name.name.as_str(), "int" | "float" | "bool" | "char" | "str") {
            self.err_in(m, Diag::new("E0107", name.span, format!("`{}` is a built-in type and can't be redefined", name.name)));
            return;
        }
        if kind == 3 {
            let self_param = self.defs.params.len();
            self.defs.params.push(TypeParam { name: "Self".into(), bounds: Vec::new(), implicit: false });
            let id = self.defs.shapes.len();
            let builtin = if self.prog.is_core(m) {
                match name.name.as_str() {
                    "Show" => Some(Builtin::Show),
                    "Ord" => Some(Builtin::Ord),
                    "Eq" => Some(Builtin::Eq),
                    "Data" => Some(Builtin::Data),
                    _ => None,
                }
            } else {
                None
            };
            if !generics.is_empty() {
                self.err_in(
                    m,
                    Diag::new("E0113", generics[0].name.span, "shapes can't have type parameters")
                        .note("inside a shape, `Self` names the type that fits it"),
                );
            }
            self.defs.params[self_param].bounds.push(id);
            self.defs.shapes.push(ShapeDef { name: name.name.clone(), module: m, public, self_param, methods: Vec::new(), builtin, span });
            self.items[m].types.insert(name.name, TypeItem::Shape(id));
            return;
        }
        let params: Vec<ParamId> = generics
            .iter()
            .map(|g| {
                self.defs.params.push(TypeParam { name: g.name.name.clone(), bounds: Vec::new(), implicit: false });
                self.defs.params.len() - 1
            })
            .collect();
        if let Item::ExternType(d) = item
            && !self.prog.is_core(m)
        {
            let d = d.clone();
            self.ffi_type(m, &d);
        }
        let item = &self.prog.mods[m].ast.items[i];
        let kind = match item {
            Item::ExternType(d) => TypeDefKind::Opaque { c_type: d.c_type.clone() },
            Item::Struct(_) => TypeDefKind::Struct { fields: Vec::new() },
            _ => TypeDefKind::Enum { variants: Vec::new() },
        };
        let id = self.defs.types.len();
        self.defs.types.push(TypeDef { name: name.name.clone(), module: m, public, doc, params, kind, span, node });
        self.items[m].types.insert(name.name, TypeItem::Def(id));
    }

    // ---- user-level FFI (docs/ffi-plan.md) ----

    /// E0036 unless `m`'s package declares the `ffi` effect in its raft.toml.
    fn ffi_allowed(&mut self, m: ModId, at: Span) -> bool {
        let pkg = &self.prog.pkgs[self.prog.mods[m].pkg];
        if pkg.dir.is_some() && pkg.effects.iter().any(|e| e == "ffi") {
            return true;
        }
        let mut d = Diag::new("E0036", at, "`extern` declarations need the `ffi` effect in the package's raft.toml");
        d = match &pkg.dir {
            Some(dir) => d.note(format!("help: add \"ffi\" to `effects` under [package] in {}", dir.join("raft.toml").display())),
            None => d.note("C functions can only be bound inside a project: create a raft.toml with `effects = [\"ffi\"]` under [package]"),
        };
        self.err_in(m, d.note("calling C is unchecked (a crash can't be caught), so a package says so in its manifest; callers then need `uses ffi`"));
        false
    }

    /// The span of the string literal that ends an item spanning `end` (its C prototype or C
    /// type).
    fn ffi_str_span(&self, m: ModId, end: Span) -> Span {
        let src = &self.prog.mods[m].src;
        let Some(line) = src.lines().nth(end.end_line as usize - 1) else { return end };
        let cs: Vec<char> = line.chars().collect();
        let stop = (end.end_col as usize).saturating_sub(1).min(cs.len());
        let Some(close) = cs[..stop].iter().rposition(|&c| c == '"') else { return end };
        let Some(open) = cs[..close].iter().rposition(|&c| c == '"') else { return end };
        Span { line: end.end_line, col: open as u32 + 1, end_line: end.end_line, end_col: close as u32 + 2 }
    }

    /// Check a user `extern type` (an opaque C pointer type).
    fn ffi_type(&mut self, m: ModId, d: &ast::ExternTypeDef) {
        if !self.ffi_allowed(m, d.span) {
            return;
        }
        let at = self.ffi_str_span(m, d.span);
        let why = match crate::ffi::parse_type(&d.c_type) {
            Ok(_) if d.c_type.trim_start().starts_with("Auk") => Some("`Auk...` types belong to the runtime".to_string()),
            Ok(crate::ffi::CTy::Ptr { .. } | crate::ffi::CTy::Named(_)) => None,
            Ok(t) => Some(format!("`{}` is not a pointer: an `extern type` is an opaque C pointer type (`T *`, or a typedef of one)", t.show())),
            Err(e) => Some(e),
        };
        if let Some(why) = why {
            self.err_in(
                m,
                Diag::new("E0040", at, format!("`{}` can't be an `extern type`", d.c_type))
                    .note(why)
                    .note("write the C pointer type, e.g. `extern type Db = \"sqlite3 *\"` or `extern type Module = \"LLVMModuleRef\"`"),
            );
        }
    }

    /// Check an `extern fn f(): T = "#embed path"`: no parameters, the file (relative to the
    /// source file) is readable, and `T` is a form of its contents: `[int]`, `str` (valid
    /// UTF-8), `ffi.Ptr` or `int` (the length). The path in the result is the resolved one.
    fn ffi_embed(&mut self, m: ModId, c: &FnClause, mut sig: crate::ffi::CSig, params: &[ParamInfo], ret: &Ty, at: Span) -> Option<(crate::ffi::CSig, Vec<crate::ffi::Conv>)> {
        let name = &c.name.name;
        let e40 = |span: Span, msg: String| Diag::new("E0040", span, msg);
        let rel = sig.embed.clone().unwrap_or_default();
        let path = std::path::Path::new(&self.prog.mods[m].file).parent().unwrap_or(std::path::Path::new("")).join(&rel);
        let mut errs = Vec::new();
        if !params.is_empty() {
            errs.push(e40(at, format!("`{name}` embeds a file, so it takes no parameters")));
        }
        let bytes = match std::fs::read(&path) {
            Ok(b) => Some(b),
            Err(e) => {
                errs.push(e40(at, format!("`{name}`: cannot read the file to embed, `{}`: {e}", path.display())).note("the path is relative to this source file"));
                None
            }
        };
        let is_ptr = matches!(ret, Ty::Named(d, _) if self.defs.types[*d].name == "Ptr" && self.prog.is_core(self.defs.types[*d].module));
        let fits = match ret {
            Ty::Int => true,
            Ty::List(e) => **e == Ty::Int,
            Ty::Str => {
                if let Some(b) = &bytes
                    && let Err(e) = std::str::from_utf8(b)
                {
                    errs.push(e40(at, format!("`{name}` embeds `{rel}` as a `str`, but it isn't UTF-8 (at byte {})", e.valid_up_to())).note("embed binary files as `[int]` or `ffi.Ptr`"));
                }
                true
            }
            _ => is_ptr || ret.has_error(),
        };
        if !fits {
            let span = c.ret.as_ref().map(|t| t.span).unwrap_or(c.name.span);
            errs.push(
                e40(span, format!("`{name}` returns `{}`, which isn't a form of an embedded file", self.defs.show(ret)))
                    .note("an embedded file is `[int]` (its bytes), `str` (UTF-8 text), `ffi.Ptr` (the address of its bytes, read-only) or `int` (its length)"),
            );
        }
        if !errs.is_empty() {
            for d in errs {
                self.err_in(m, d);
            }
            return None;
        }
        sig.embed = Some(path.to_string_lossy().into_owned());
        Some((sig, vec![crate::ffi::Conv::Unit]))
    }

    /// Check a user `extern fn`: the package allows it, the prototype parses, and every Auk
    /// parameter and the result fit their C types (E0040).
    #[allow(clippy::too_many_arguments)]
    fn ffi_fn(&mut self, m: ModId, c: &FnClause, proto: &str, params: &[ParamInfo], ret: &Ty, is_async: bool, generics: &[ParamId]) -> Option<(crate::ffi::CSig, Vec<crate::ffi::Conv>)> {
        use crate::ffi::{CTy, conv, parse_proto};
        if !self.ffi_allowed(m, c.name.span) {
            return None;
        }
        let at = self.ffi_str_span(m, c.span);
        let name = &c.name.name;
        let e40 = |span: Span, msg: String| Diag::new("E0040", span, msg);
        if is_async || !generics.is_empty() {
            let what = if is_async { "`async`" } else { "generic" };
            self.err_in(m, e40(c.name.span, format!("the C function `{name}` can't be {what}")).note("a C function has one fixed signature and returns when it's done"));
            return None;
        }
        let sig = match parse_proto(proto) {
            Ok(s) => s,
            Err(e) => {
                self.err_in(
                    m,
                    e40(at, format!("`{name}`: can't read the C prototype")).note(e).note("write the C declaration, e.g. `extern fn abs(n: int): int = \"int abs(int)\"`"),
                );
                return None;
            }
        };
        if sig.embed.is_some() {
            return self.ffi_embed(m, c, sig, params, ret, at);
        }
        if sig.params.len() != params.len() {
            self.err_in(
                m,
                if sig.cast {
                    e40(at, format!("`{name}` has {} parameter(s), but a cast takes 1", params.len())).note("a cast `(T)` converts its one argument, an `ffi.Ptr` or an `extern type`, to `T`")
                } else if sig.indirect {
                    e40(at, format!("`{name}` has {} parameter(s), but a call through a function pointer with this prototype takes {}", params.len(), sig.params.len()))
                        .note("the first parameter is the function's address (`ffi.Ptr`), then one per C parameter")
                } else {
                    e40(at, format!("`{name}` has {} parameter(s), but the C prototype of `{}` has {}", params.len(), sig.name, sig.params.len()))
                        .note("each Auk parameter matches the C parameter in the same position")
                },
            );
            return None;
        }
        let mut convs = Vec::new();
        let mut errs = Vec::new();
        {
            let defs = &self.defs;
            let prog = &self.prog;
            let ptr_of = |t: &Ty| -> Option<Option<CTy>> {
                let Ty::Named(d, _) = t else { return None };
                let TypeDefKind::Opaque { c_type } = &defs.types[*d].kind else { return None };
                if c_type.starts_with("Auk") {
                    return None;
                }
                if prog.is_core(defs.types[*d].module) { Some(None) } else { crate::ffi::parse_type(c_type).ok().map(Some) }
            };
            for (k, (p, ct)) in params.iter().zip(&sig.params).enumerate() {
                if p.ty.has_error() {
                    return None;
                }
                let cv = if sig.cast {
                    match &p.ty {
                        _ if p.var => Err("a cast's argument can't be `var`".to_string()),
                        Ty::Opt(x) if ptr_of(x).is_some() => Ok(crate::ffi::Conv::OptPtr),
                        t if ptr_of(t).is_some() => Ok(crate::ffi::Conv::Ptr),
                        _ => Err("a cast `(T)` converts an opaque pointer: an `ffi.Ptr` or an `extern type` (or its `T?`)".to_string()),
                    }
                } else {
                    conv(&p.ty, p.var, ct, false, sig.free.is_some(), &ptr_of)
                };
                match cv {
                    Ok(cv) => convs.push(cv),
                    Err(why) => {
                        let span = c.params.get(k).map(|x| x.ty.as_ref().map(|t| t.span).unwrap_or(x.span)).unwrap_or(at);
                        let var = if p.var { "var " } else { "" };
                        errs.push(
                            e40(span, format!("parameter {} of `{name}` is `{var}{}`, which doesn't fit the C type `{}`", k + 1, defs.show(&p.ty), ct.show()))
                                .note(why),
                        );
                    }
                }
            }
            if ret.has_error() {
                return None;
            }
            match conv(ret, false, &sig.ret, true, sig.free.is_some(), &ptr_of) {
                Ok(cv) => convs.push(cv),
                Err(why) => {
                    let span = c.ret.as_ref().map(|t| t.span).unwrap_or(c.name.span);
                    errs.push(e40(span, format!("`{name}` returns `{}`, which doesn't fit the C result type `{}`", defs.show(ret), sig.ret.show())).note(why));
                }
            }
        }
        let owned = convs.iter().any(|cv| {
            use crate::ffi::Conv::*;
            matches!(cv, Str { owned: true } | OptStr { owned: true }) || matches!(cv, Out(x) if matches!(**x, OptStr { owned: true }))
        });
        if sig.free.is_some() && !owned && errs.is_empty() {
            errs.push(
                e40(at, format!("`+free` in `{name}`'s prototype, but it hands over no `char *` string"))
                    .note("`+free(fn)` names the function that frees a returned `char *` (or a `char **` out-parameter) once it's copied"),
            );
        }
        let ok = errs.is_empty();
        for d in errs {
            self.err_in(m, d);
        }
        ok.then_some((sig, convs))
    }

    fn find_builtins(&mut self) {
        let core = self.prog.core_root;
        let ty = |c: &Checker, n: &str| c.items[core].types.get(n).copied();
        if let Some(TypeItem::Def(d)) = ty(self, "Err") {
            self.b.err = d;
        }
        if let Some(TypeItem::Def(d)) = ty(self, "Value") {
            self.b.value = d;
        }
        for (n, slot) in [("Show", 0), ("Ord", 1), ("Eq", 2), ("Data", 3)] {
            if let Some(TypeItem::Shape(s)) = ty(self, n) {
                match slot {
                    0 => self.b.show = s,
                    1 => self.b.ord = s,
                    2 => self.b.eq = s,
                    _ => self.b.data = s,
                }
            }
        }
    }

    /// The generic scope of a type definition.
    fn def_scope(&self, d: DefId) -> GenScope {
        let mut g = GenScope::default();
        for &p in &self.defs.types[d].params {
            g.names.insert(self.defs.params[p].name.clone(), p);
        }
        g
    }

    fn define_type(&mut self, m: ModId, i: usize) {
        let item = self.prog.mods[m].ast.items[i].clone();
        match &item {
            Item::Struct(sd) => {
                let Some(TypeItem::Def(d)) = self.items[m].types.get(&sd.name.name).copied() else { return };
                if self.defs.types[d].node != sd.id {
                    return;
                }
                let mut g = self.def_scope(d);
                self.resolve_bounds(m, &sd.generics, &self.defs.types[d].params.clone(), &mut g);
                let mut fields: Vec<FieldDef> = Vec::new();
                for f in &sd.fields {
                    if fields.iter().any(|x| x.name == f.name.name) {
                        self.err_in(m, Diag::new("E0107", f.name.span, format!("the field `{}` is declared twice", f.name.name)));
                        continue;
                    }
                    let ty = self.resolve_type(m, &f.ty, &mut g);
                    fields.push(FieldDef { name: f.name.name.clone(), ty, public: false, span: f.span });
                }
                self.defs.types[d].kind = TypeDefKind::Struct { fields };
            }
            Item::Enum(ed) => {
                let Some(TypeItem::Def(d)) = self.items[m].types.get(&ed.name.name).copied() else { return };
                if self.defs.types[d].node != ed.id {
                    return;
                }
                let mut g = self.def_scope(d);
                self.resolve_bounds(m, &ed.generics, &self.defs.types[d].params.clone(), &mut g);
                let mut variants: Vec<VariantDef> = Vec::new();
                for v in &ed.variants {
                    if variants.iter().any(|x| x.name == v.name.name) {
                        self.err_in(m, Diag::new("E0107", v.name.span, format!("the variant `{}` is declared twice", v.name.name)));
                        continue;
                    }
                    let fields = v.fields.iter().map(|f| (f.name.as_ref().map(|n| n.name.clone()), self.resolve_type(m, &f.ty, &mut g))).collect();
                    let idx = variants.len();
                    variants.push(VariantDef { name: v.name.name.clone(), fields, span: v.span, node: v.id });
                    self.items[m].variants.entry(v.name.name.clone()).or_default().push((d, idx));
                }
                self.defs.types[d].kind = TypeDefKind::Enum { variants };
            }
            Item::Shape(sd) => {
                let Some(TypeItem::Shape(s)) = self.items[m].types.get(&sd.name.name).copied() else { return };
                let self_param = self.defs.shapes[s].self_param;
                let mut methods = Vec::new();
                for f in &sd.methods {
                    let mut g = GenScope { self_param: Some(self_param), ..GenScope::default() };
                    let mut params = Vec::new();
                    for (k, p) in f.params.iter().enumerate() {
                        let t = match (&p.ty, &p.pat.kind) {
                            (Some(t), _) => self.resolve_type(m, t, &mut g),
                            (None, PatKind::Bind(n)) if n == "self" && k == 0 => Ty::Param(self_param),
                            _ => {
                                self.err_in(
                                    m,
                                    Diag::new("E0109", p.span, "a shape method parameter needs a type")
                                        .note("write `fn name(self, other: T): R`; `self` is the fitting type"),
                                );
                                Ty::Error
                            }
                        };
                        params.push(t);
                    }
                    if !matches!(params.first(), Some(Ty::Param(p)) if *p == self_param) {
                        self.err_in(
                            m,
                            Diag::new("E0113", f.name.span, format!("shape method `{}` must take `self` first", f.name.name))
                                .note("e.g. `fn area(self): float`"),
                        );
                    }
                    let ret = f.ret.as_ref().map(|t| self.resolve_type(m, t, &mut g)).unwrap_or_else(Ty::unit);
                    methods.push(ShapeMethod { name: f.name.name.clone(), params, ret });
                }
                self.defs.shapes[s].methods = methods;
            }
            _ => {}
        }
    }

    fn resolve_bounds(&mut self, m: ModId, gs: &[ast::Generic], params: &[ParamId], scope: &mut GenScope) {
        for (g, &p) in gs.iter().zip(params) {
            for b in &g.bounds {
                if let Some(s) = self.resolve_shape(m, b) {
                    self.defs.params[p].bounds.push(s);
                }
            }
            scope.names.insert(g.name.name.clone(), p);
        }
    }

    /// A pub struct's fields are public unless their type mentions a private type of the
    /// struct's module.
    fn field_visibility(&mut self) {
        for d in 0..self.defs.types.len() {
            let (public, module) = (self.defs.types[d].public, self.defs.types[d].module);
            let TypeDefKind::Struct { fields } = &self.defs.types[d].kind else { continue };
            let vis: Vec<bool> = fields
                .iter()
                .map(|f| {
                    let mut private = false;
                    f.ty.walk(&mut |t| {
                        if let Ty::Named(x, _) = t {
                            private |= self.defs.types[*x].module == module && !self.defs.types[*x].public;
                        }
                    });
                    public && !private
                })
                .collect();
            if let TypeDefKind::Struct { fields } = &mut self.defs.types[d].kind {
                for (f, v) in fields.iter_mut().zip(vis) {
                    f.public = v;
                }
            }
        }
    }

    /// Resolve a type expression that must name a shape (a bound, `any S`).
    pub fn resolve_shape(&mut self, m: ModId, t: &ast::Type) -> Option<ShapeId> {
        if let TypeKind::Named { path, args } = &t.kind
            && args.is_empty()
            && let Some(TypeItem::Shape(s)) = self.lookup_type_path(m, path)
        {
            return Some(s);
        }
        self.err_in(
            m,
            Diag::new("E0105", t.span, format!("expected a shape, found `{}`", ast::type_dump(t)))
                .note("bounds and `any` take a shape such as `Show`, `Ord`, `Eq`, `Data` or one declared with `shape`"),
        );
        None
    }

    /// The type (or shape) a path names in module `m`.
    pub fn lookup_type_path(&mut self, m: ModId, path: &[ast::Ident]) -> Option<TypeItem> {
        if path.len() == 1 {
            let n = &path[0].name;
            if let Some(&t) = self.items[m].types.get(n) {
                return Some(t);
            }
            let core = self.prog.core_root;
            if let Some(&t) = self.items[core].types.get(n)
                && self.type_item_public(t)
            {
                return Some(t);
            }
            return None;
        }
        let target = self.module_of_path(m, &path[..path.len() - 1])?;
        let last = &path[path.len() - 1];
        let t = *self.items[target].types.get(&last.name)?;
        if target != m && !self.type_item_public(t) {
            self.err_in(
                m,
                Diag::new("E0120", last.span, format!("the type `{}` is private to module `{}`", last.name, self.prog.name(target)))
                    .note("mark it `pub` to use it from other modules"),
            );
        }
        Some(t)
    }

    fn type_item_public(&self, t: TypeItem) -> bool {
        match t {
            TypeItem::Def(d) => self.defs.types[d].public,
            TypeItem::Shape(s) => self.defs.shapes[s].public,
        }
    }

    /// The module a path of module names denotes (`http.uri`), if every segment is a module.
    pub fn module_of_path(&self, m: ModId, path: &[ast::Ident]) -> Option<ModId> {
        let mut cur = self.prog.first_segment(m, &path.first()?.name)?;
        for seg in &path[1..] {
            cur = self.prog.child(cur, &seg.name)?;
        }
        Some(cur)
    }

    /// What the dotted prefix `path` of an expression (`env` in `env.get(k)`) means. A path's
    /// first segment names a module unless a local of that name is in scope (spec "Modules,
    /// packages": local names shadow core ones):
    /// - a local named like a core module (`env`, `fs`, `time`, ...) wins, so `env.get(k)` is a
    ///   method call on the local; `core.env.get(k)` still reaches the module;
    /// - a local named like a module of this package, the package itself, a dependency or `core`
    ///   is an error (E0116) at the use: `m.` is always a path for those, and silently picking
    ///   either meaning would surprise half of the readers.
    pub fn expr_path(&mut self, m: ModId, path: &[ast::Ident]) -> ExprPath {
        let Some(target) = self.module_of_path(m, path) else { return ExprPath::Value };
        let first = &path[0];
        if !self.local_in_scope(&first.name) {
            return ExprPath::Module(target);
        }
        let n = first.name.as_str();
        let head = self.prog.first_segment(m, n).expect("a module path has a first segment");
        if self.prog.is_core(head) && n != "core" {
            return ExprPath::Value;
        }
        let pkg = &self.prog.pkgs[self.prog.mods[m].pkg];
        let what = if n == "core" {
            "the core library root".to_string()
        } else if pkg.root == head {
            format!("this package `{n}`")
        } else if pkg.deps.contains_key(n) && self.prog.child(pkg.root, n).is_none() {
            format!("the dependency `{n}`")
        } else {
            format!("the module `{}`", self.prog.name(head))
        };
        self.err(
            Diag::new("E0116", first.span, format!("`{n}` is both a local and {what}, so `{n}.` is ambiguous"))
                .note(format!("`{n}.` is always a path when `{n}` names a module or dependency; rename the local to use it as a value"))
                .note("only core module names (`env`, `fs`, `time`, ...) are shadowed by locals"),
        );
        ExprPath::Ambiguous
    }

    /// Resolve a type annotation.
    pub fn resolve_type(&mut self, m: ModId, t: &ast::Type, g: &mut GenScope) -> Ty {
        match &t.kind {
            TypeKind::List(x) => Ty::list(self.resolve_type(m, x, g)),
            TypeKind::Map(k, v) => Ty::map(self.resolve_type(m, k, g), self.resolve_type(m, v, g)),
            TypeKind::Tuple(ts) => Ty::Tuple(ts.iter().map(|x| self.resolve_type(m, x, g)).collect()),
            TypeKind::Optional(x) => Ty::opt(self.resolve_type(m, x, g)),
            TypeKind::Fallible { ok, err } => {
                let ok = self.resolve_type(m, ok, g);
                let e = match err {
                    None => Ty::Named(self.b.err, Vec::new()),
                    Some(e) => {
                        let et = self.resolve_type(m, e, g);
                        let fine = match &et {
                            Ty::Named(d, _) => self.defs.is_enum(*d) || *d == self.b.err,
                            Ty::Error => true,
                            _ => false,
                        };
                        if !fine {
                            self.err_in(
                                m,
                                Diag::new("E0112", e.span, format!("the error type in `T!E` must be an enum, found `{}`", self.defs.show(&et)))
                                    .note("write `T!` for a plain `Err`, or declare `enum MyErr { ... }`"),
                            );
                            return Ty::Error;
                        }
                        et
                    }
                };
                Ty::res(ok, e)
            }
            TypeKind::Any(s) => match self.resolve_shape(m, s) {
                Some(s) => Ty::Any(s),
                None => Ty::Error,
            },
            TypeKind::Fn { params, ret } => Ty::func(params.iter().map(|x| self.resolve_type(m, x, g)).collect(), self.resolve_type(m, ret, g)),
            // the parser allows `var T` only as a function type's parameter
            TypeKind::Var(x) => Ty::Mut(Box::new(self.resolve_type(m, x, g))),
            TypeKind::Measured { base, units } => match self.resolve_type(m, base, g) {
                b @ (Ty::Int | Ty::Float) => Ty::measured(b, units.clone()),
                Ty::Error => Ty::Error,
                b => {
                    let bs = self.defs.show(&b);
                    self.err_in(m, Diag::new("E0037", t.span, format!("only `int` and `float` take a unit of measure, not `{bs}`")));
                    Ty::Error
                }
            },
            TypeKind::Named { path, args } => {
                if path.len() == 1 {
                    let n = path[0].name.as_str();
                    if let Some(&p) = g.names.get(n) {
                        return self.no_args(m, t, args, Ty::Param(p));
                    }
                    if n == "Self" {
                        if let Some(p) = g.self_param {
                            return self.no_args(m, t, args, Ty::Param(p));
                        }
                        self.err_in(m, Diag::new("E0104", t.span, "`Self` is only valid inside a shape"));
                        return Ty::Error;
                    }
                    if !self.items[m].types.contains_key(n) {
                        let prim = match n {
                            "int" => Some(Ty::Int),
                            "float" => Some(Ty::Float),
                            "bool" => Some(Ty::Bool),
                            "char" => Some(Ty::Char),
                            "str" => Some(Ty::Str),
                            // only core can name it (`proc.exit(code): never`)
                            "never" if self.prog.is_core(m) => Some(Ty::Never),
                            _ => None,
                        };
                        if let Some(p) = prim {
                            return self.no_args(m, t, args, p);
                        }
                        if n == "Task" {
                            if args.len() != 1 {
                                self.err_in(m, Diag::new("E0106", t.span, format!("`Task` takes 1 type argument, found {}", args.len())));
                                return Ty::Error;
                            }
                            return Ty::Task(Box::new(self.resolve_type(m, &args[0], g)));
                        }
                    }
                }
                let Some(item) = self.lookup_type_path(m, path) else {
                    let name = path.iter().map(|i| i.name.clone()).collect::<Vec<_>>().join(".");
                    let mut d = Diag::new("E0104", t.span, format!("unknown type `{name}`"));
                    let mut cands: Vec<String> = self.items[m].types.keys().cloned().collect();
                    cands.extend(["int", "float", "bool", "char", "str", "Value", "Err"].map(String::from));
                    if let Some(s) = similar(&name, &cands) {
                        d = d.note(format!("did you mean `{s}`?")).fix(t.span, s);
                    } else if name == "string" || name == "String" {
                        d = d.note("the string type is `str`").fix(t.span, "str");
                    } else if name == "i64" || name == "f64" {
                        d = d.note("Auk's numeric types are `int` and `float`");
                    }
                    self.err_in(m, d);
                    return Ty::Error;
                };
                match item {
                    TypeItem::Def(d) => {
                        let want = self.defs.types[d].params.len();
                        if args.len() != want {
                            self.err_in(
                                m,
                                Diag::new(
                                    "E0106",
                                    t.span,
                                    format!("`{}` takes {want} type argument(s), found {}", self.defs.types[d].name, args.len()),
                                ),
                            );
                            return Ty::Error;
                        }
                        Ty::Named(d, args.iter().map(|a| self.resolve_type(m, a, g)).collect())
                    }
                    TypeItem::Shape(s) => {
                        if g.key_mode {
                            return Ty::Any(s);
                        }
                        if g.implicit {
                            let name = self.defs.shapes[s].name.clone();
                            if let Some(&p) = g.names.get(&name) {
                                return Ty::Param(p);
                            }
                            self.defs.params.push(TypeParam { name: name.clone(), bounds: vec![s], implicit: true });
                            let p = self.defs.params.len() - 1;
                            g.names.insert(name, p);
                            g.implicit_params.push(p);
                            return Ty::Param(p);
                        }
                        let name = self.defs.shapes[s].name.clone();
                        self.err_in(
                            m,
                            Diag::new("E0105", t.span, format!("the shape `{name}` can't be used as a type here"))
                                .note(format!("a shape is a type only in a function signature (`fn f(x: {name})`); elsewhere write `any {name}` for a value of any fitting type"))
                                .fix(t.span, format!("any {name}")),
                        );
                        Ty::Error
                    }
                }
            }
        }
    }

    fn no_args(&mut self, m: ModId, t: &ast::Type, args: &[ast::Type], ty: Ty) -> Ty {
        if !args.is_empty() {
            self.err_in(m, Diag::new("E0106", t.span, format!("`{}` takes no type arguments", self.defs.show(&ty))));
        }
        ty
    }

    // ---- functions: splitting clause groups and signatures ----

    /// The type a parameter pattern implies by its form alone (for clause groups without an
    /// annotation at that position): `0` is int, `Circle(r)` is `Shape`, `[]` is a list, ...
    /// `None` when the pattern says nothing (a binding or `_`).
    fn pattern_type(&mut self, m: ModId, p: &ast::Pat, inf: &mut Infer) -> Option<Ty> {
        Some(match &p.kind {
            PatKind::Wild => return None,
            PatKind::Bind(n) => {
                let vs = self.variants_in_scope(m, n);
                if vs.len() == 1 {
                    let (d, _) = vs[0];
                    self.fresh_def(d, inf)
                } else {
                    return None;
                }
            }
            PatKind::Lit { lit, .. } => match lit {
                ast::Lit::Int(_) => Ty::Int,
                ast::Lit::Float(_) => Ty::Float,
                ast::Lit::Bool(_) => Ty::Bool,
                ast::Lit::Char(_) => Ty::Char,
                ast::Lit::Str(_) => Ty::Str,
            },
            PatKind::Tuple(ps) => Ty::Tuple(ps.iter().map(|p| self.pattern_type(m, p, inf).unwrap_or_else(|| inf.fresh())).collect()),
            PatKind::List { head, rest, tail } => {
                let e = inf.fresh();
                for p in head.iter().chain(tail) {
                    if let Some(t) = self.pattern_type(m, p, inf) {
                        inf.unify(&e, &t);
                    }
                }
                if let Some(r) = rest.as_ref().and_then(|r| r.pat.as_ref())
                    && let Some(t) = self.pattern_type(m, r, inf)
                {
                    inf.unify(&Ty::list(e.clone()), &t);
                }
                Ty::list(e)
            }
            PatKind::Variant { path, .. } => {
                let (d, _) = self.variant_path(m, path)?;
                self.fresh_def(d, inf)
            }
            PatKind::Struct { path, .. } => match self.lookup_type_path(m, path) {
                Some(TypeItem::Def(d)) => self.fresh_def(d, inf),
                _ => return None,
            },
            PatKind::Map(_) => return None,
            PatKind::StrPrefix { .. } => Ty::Str,
            PatKind::Some(p) => Ty::opt(self.pattern_type(m, p, inf).unwrap_or_else(|| inf.fresh())),
            PatKind::None => Ty::opt(inf.fresh()),
            PatKind::Ok(_) | PatKind::Err(_) => Ty::res(inf.fresh(), inf.fresh()),
            PatKind::Or(ps) => return self.pattern_type(m, &ps[0], inf),
        })
    }

    pub fn fresh_def(&self, d: DefId, inf: &mut Infer) -> Ty {
        Ty::Named(d, self.defs.types[d].params.iter().map(|_| inf.fresh()).collect())
    }

    /// Variants named `name` visible unqualified in module `m`: the module's own enums, else
    /// core's public enums (`Value`).
    pub fn variants_in_scope(&self, m: ModId, name: &str) -> Vec<(DefId, usize)> {
        if let Some(v) = self.items[m].variants.get(name)
            && !v.is_empty()
        {
            return v.clone();
        }
        let core = self.prog.core_root;
        self.items[core]
            .variants
            .get(name)
            .map(|v| v.iter().copied().filter(|(d, _)| self.defs.types[*d].public || m == core).collect())
            .unwrap_or_default()
    }

    /// A qualified variant path: `Shape.Circle`, `json.Eof`, `json.JsonErr.Eof`, or a bare
    /// `Circle` in scope.
    pub fn variant_path(&mut self, m: ModId, path: &[ast::Ident]) -> Option<(DefId, usize)> {
        let last = &path[path.len() - 1].name;
        if path.len() == 1 {
            let vs = self.variants_in_scope(m, last);
            return if vs.len() == 1 { Some(vs[0]) } else { None };
        }
        let prefix = &path[..path.len() - 1];
        if let Some(TypeItem::Def(d)) = self.lookup_type_path(m, prefix) {
            return self.defs.variants(d).iter().position(|v| &v.name == last).map(|i| (d, i));
        }
        let target = self.module_of_path(m, prefix)?;
        let vs: Vec<(DefId, usize)> = self.items[target]
            .variants
            .get(last)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|(d, _)| self.defs.types[*d].public || target == m)
            .collect();
        if vs.len() == 1 { Some(vs[0]) } else { None }
    }

    /// The grouping key of a clause: its first parameter's type (annotation or pattern). A
    /// clause's own type parameters are matched by name across the group (`canon`), so
    /// `items<T>(Leaf: Tree<T>)` and `items<T>(Node(..): Tree<T>)` are one function while
    /// `f<T>(x: [T])` and `f(x: [int])` are two overloads.
    fn clause_key(&mut self, m: ModId, c: &FnClause, inf: &mut Infer, canon: &mut HashMap<String, ParamId>) -> Option<Ty> {
        let p = c.params.first()?;
        if let Some(t) = &p.ty {
            let mut g = GenScope { key_mode: true, ..GenScope::default() };
            for gp in &c.generics {
                let id = *canon.entry(gp.name.name.clone()).or_insert_with(|| {
                    self.defs.params.push(TypeParam { name: gp.name.name.clone(), bounds: Vec::new(), implicit: false });
                    self.defs.params.len() - 1
                });
                g.names.insert(gp.name.name.clone(), id);
            }
            let n = self.errs.len();
            let ty = self.resolve_type(m, t, &mut g);
            self.errs.truncate(n); // reported again when the signature is resolved
            return Some(ty);
        }
        self.pattern_type(m, &p.pat, inf)
    }

    fn declare_fns(&mut self, m: ModId, item: usize, g: &ast::FnGroup) {
        // split the clause group by first-parameter type
        let mut inf = Infer::default();
        let mut canon = HashMap::new();
        let header_key = g.header.as_ref().and_then(|h| self.clause_key(m, h, &mut inf, &mut canon));
        let mut splits: Vec<(Option<Ty>, Vec<usize>)> = Vec::new();
        for (ci, c) in g.clauses.iter().enumerate() {
            let k = self.clause_key(m, c, &mut inf, &mut canon);
            match (splits.last_mut(), k) {
                (Some(_), None) => splits.last_mut().unwrap().1.push(ci),
                (Some((cur, cs)), Some(k)) => match cur {
                    None => {
                        *cur = Some(k);
                        cs.push(ci);
                    }
                    Some(t) if inf.try_unify(t, &k) => cs.push(ci),
                    Some(_) => splits.push((Some(k), vec![ci])),
                },
                (None, k) => splits.push((k, vec![ci])),
            }
        }
        let header_split = match &header_key {
            Some(hk) => splits.iter().position(|(k, _)| k.as_ref().is_none_or(|k| inf.can_unify(k, hk))).unwrap_or(0),
            None => 0,
        };
        for (si, (_, clauses)) in splits.into_iter().enumerate() {
            let header = g.header.is_some() && si == header_split;
            self.declare_fn(m, item, g, clauses, header);
        }
    }

    fn declare_fn(&mut self, m: ModId, item: usize, g: &ast::FnGroup, clauses: Vec<usize>, header: bool) {
        let hdr = if header { g.header.as_deref() } else { None };
        let cls: Vec<&FnClause> = clauses.iter().map(|&i| &g.clauses[i]).collect();
        let first = hdr.unwrap_or(cls[0]);
        let all: Vec<&FnClause> = hdr.into_iter().chain(cls.iter().copied()).collect();
        // generics: explicit ones, plus implicit shape parameters
        let gen_src = all.iter().find(|c| !c.generics.is_empty()).copied();
        let mut gs = GenScope { implicit: true, ..GenScope::default() };
        let mut generics = Vec::new();
        if let Some(src) = gen_src {
            for gp in &src.generics {
                self.defs.params.push(TypeParam { name: gp.name.name.clone(), bounds: Vec::new(), implicit: false });
                let p = self.defs.params.len() - 1;
                gs.names.insert(gp.name.name.clone(), p);
                generics.push(p);
            }
            for (gp, &p) in src.generics.iter().zip(&generics) {
                for b in &gp.bounds {
                    if let Some(s) = self.resolve_shape(m, b) {
                        self.defs.params[p].bounds.push(s);
                    }
                }
            }
        }
        // parameters
        let mut params = Vec::new();
        let mut inf = Infer::default();
        for i in 0..g.arity {
            let ann = all.iter().find_map(|c| c.params[i].ty.as_ref());
            let ty = match ann {
                Some(t) => {
                    let ty = self.resolve_type(m, t, &mut gs);
                    for c in &all {
                        if let Some(t2) = &c.params[i].ty
                            && !std::ptr::eq(t2, t)
                        {
                            let n = self.errs.len();
                            let ty2 = self.resolve_type(m, t2, &mut gs);
                            self.errs.truncate(n);
                            if ty2 != ty && !ty2.has_error() && !ty.has_error() {
                                self.err_in(
                                    m,
                                    Diag::new(
                                        "E0108",
                                        t2.span,
                                        format!(
                                            "this clause of `{}` declares parameter {} as `{}`, but an earlier clause says `{}`",
                                            g.name,
                                            i + 1,
                                            self.defs.show(&ty2),
                                            self.defs.show(&ty)
                                        ),
                                    )
                                    .note("all clauses of a function take the same parameter types")
                                    .fix(t2.span, self.defs.show(&ty)),
                                );
                            }
                        }
                    }
                    ty
                }
                None => {
                    let v = inf.fresh();
                    for c in &all {
                        if let Some(t) = self.pattern_type(m, &c.params[i].pat, &mut inf) {
                            inf.unify(&v, &t);
                        }
                    }
                    let t = inf.resolve(&v);
                    if t.has_vars() {
                        let span = cls[0].params[i].span;
                        self.err_in(
                            m,
                            Diag::new("E0109", span, format!("can't tell the type of parameter {} of `{}`", i + 1, g.name))
                                .note("annotate it in one clause (`x: T`) or in a header line; a clause pattern like `0`, `[]` or `Circle(r)` only implies a type when it fixes it completely"),
                        );
                        Ty::Error
                    } else {
                        t
                    }
                }
            };
            let var = all.iter().any(|c| c.params[i].var);
            let names: Vec<Option<&String>> = cls.iter().map(|c| if let PatKind::Bind(n) = &c.params[i].pat.kind { Some(n) } else { None }).collect();
            let name = match names.first() {
                Some(Some(n)) if names.iter().all(|x| *x == Some(*n)) && self.variants_in_scope(m, n).is_empty() => Some((*n).clone()),
                _ => None,
            };
            params.push(ParamInfo { name, ty, var });
        }
        // return type
        let ret_ann = all.iter().find_map(|c| c.ret.as_ref());
        let ret = match ret_ann {
            Some(t) => {
                let r = self.resolve_type(m, t, &mut gs);
                for c in &all {
                    if let Some(t2) = &c.ret
                        && !std::ptr::eq(t2, t)
                    {
                        let n = self.errs.len();
                        let r2 = self.resolve_type(m, t2, &mut gs);
                        self.errs.truncate(n);
                        if r2 != r && !r2.has_error() && !r.has_error() {
                            self.err_in(
                                m,
                                Diag::new(
                                    "E0110",
                                    t2.span,
                                    format!(
                                        "this clause of `{}` returns `{}`, but an earlier clause returns `{}`",
                                        g.name,
                                        self.defs.show(&r2),
                                        self.defs.show(&r)
                                    ),
                                )
                                .note("all clauses of a function have the same return type")
                                .fix(t2.span, self.defs.show(&r)),
                            );
                        }
                    }
                }
                r
            }
            None => Ty::unit(),
        };
        generics.extend(gs.implicit_params.iter().copied());
        let is_async = all.iter().any(|c| c.is_async);
        let public = all.iter().any(|c| c.public);
        let mut uses: Vec<String> = first.uses.iter().map(|u| u.name.clone()).collect();
        let doc = all.iter().find_map(|c| c.doc.clone());
        let ext = cls.iter().find_map(|c| if let Some(FnBody::Extern(s)) = &c.body { Some(s.clone()) } else { None });
        let kind = match ext {
            Some(proto) if !self.prog.is_core(m) => {
                // a user C function: implicitly `uses ffi`
                if !uses.iter().any(|u| u == "ffi") {
                    uses.push("ffi".into());
                }
                let c = cls.iter().find(|c| matches!(c.body, Some(FnBody::Extern(_)))).copied().unwrap_or(first);
                match self.ffi_fn(m, c, &proto, &params, &ret, is_async, &generics) {
                    Some((sig, convs)) => FnKind::Ffi { sig: Box::new(sig), convs, item },
                    None => FnKind::Extern { symbol: String::new(), loc: false, item },
                }
            }
            Some(sym) if sym.starts_with('@') => match Intrinsic::from_symbol(&sym) {
                Some(which) => FnKind::Intrinsic { which, item },
                None => {
                    // Internal: only prelude externs name runtime symbols (user ones are C
                    // prototypes), so this fires only for a broken prelude declaration.
                    self.err_in(m, Diag::new("E0114", first.name.span, format!("unknown compiler intrinsic `{sym}`")));
                    FnKind::Extern { symbol: sym, loc: false, item }
                }
            },
            Some(sym) => {
                let (symbol, loc) = match sym.strip_suffix(" +loc") {
                    Some(s) => (s.to_string(), true),
                    None => (sym, false),
                };
                FnKind::Extern { symbol, loc, item }
            }
            None => FnKind::Auk { item, clauses, header },
        };
        let id = self.fns.len();
        self.fns.push(FnInfo {
            name: g.name.clone(),
            module: m,
            public,
            is_async,
            doc,
            generics,
            params,
            ret,
            uses,
            kind,
            span: first.name.span,
            callees: BTreeSet::new(),
            olds: Vec::new(),
            result_local: None,
        });
        self.items[m].fns.entry(g.name.clone()).or_default().push(id);
    }

    /// Two functions with the same name, arity and (non-generic) first-parameter type in one
    /// module: the clauses were split apart.
    fn check_duplicate_fns(&mut self, m: ModId) {
        let mut dups = Vec::new();
        for ids in self.items[m].fns.values() {
            for (i, &a) in ids.iter().enumerate() {
                for &b in &ids[i + 1..] {
                    let (fa, fb) = (&self.fns[a], &self.fns[b]);
                    if fa.params.len() != fb.params.len() {
                        continue;
                    }
                    let same = match (fa.params.first(), fb.params.first()) {
                        (Some(x), Some(y)) => x.ty == y.ty && !x.ty.has_params() && !x.ty.has_error(),
                        (None, None) => true,
                        _ => false,
                    };
                    if same {
                        dups.push((a, b));
                    }
                }
            }
        }
        for (a, b) in dups {
            let (fa, fb) = (&self.fns[a], &self.fns[b]);
            let first = fa.params.first().map(|p| format!(" with a first parameter of type `{}`", self.defs.show(&p.ty))).unwrap_or_default();
            let d = Diag::new("E0111", fb.span, format!("`{}` is defined twice{first} taking {} parameter(s)", fb.name, fb.params.len()))
                .note(format!("the other definition is at {}; the clauses of one function must be contiguous (and differ in the first parameter's type to overload)", fa.span));
            self.err_in(m, d);
        }
    }

    // ---- function lookup ----

    /// Functions named `name` visible from module `m` in `target` (all if the same module, else
    /// public ones).
    pub fn fns_in(&self, m: ModId, target: ModId, name: &str) -> Vec<FnId> {
        let core_internal = self.prog.is_core(m) && self.prog.is_core(target);
        self.items[target]
            .fns
            .get(name)
            .map(|v| v.iter().copied().filter(|&f| target == m || core_internal || self.fns[f].public).collect())
            .unwrap_or_default()
    }

    // ---- bodies ----

    fn check_bodies(&mut self) {
        for c in 0..self.consts.len() {
            self.ensure_const(c);
        }
        for f in 0..self.fns.len() {
            if matches!(self.fns[f].kind, FnKind::Auk { .. }) {
                self.check_fn(f);
            }
        }
        for t in 0..self.tests.len() {
            self.check_test(t);
        }
    }

    pub fn new_cx(&self, module: ModId, body: BodyRef, generics: GenScope) -> BodyCx {
        BodyCx {
            module,
            body,
            inf: Infer::default(),
            t: Tables::default(),
            scopes: vec![HashMap::new()],
            frames: Vec::new(),
            generics,
            deferred: Vec::new(),
            callees: BTreeSet::new(),
            result_local: None,
            in_ensures: false,
            olds: Vec::new(),
            direct_await: false,
            quiet: 0,
            local_start: self.tables[module].locals.len(),
        }
    }

    /// Check a constant if it hasn't been yet (constants are checked on first use, so their
    /// inferred types are available to the bodies that use them).
    pub fn ensure_const(&mut self, c: ConstId) {
        match self.const_state[c] {
            ConstState::Done => return,
            ConstState::Busy => {
                let (m, span, name) = (self.consts[c].module, self.consts[c].span, self.consts[c].name.clone());
                self.err_in(
                    m,
                    Diag::new("E0115", span, format!("the constant `{name}` depends on itself")).note("give it a type annotation or break the cycle"),
                );
                self.consts[c].ty = Ty::Error;
                self.const_state[c] = ConstState::Done;
                return;
            }
            ConstState::Todo => {}
        }
        self.const_state[c] = ConstState::Busy;
        let m = self.consts[c].module;
        let item = self.consts[c].item;
        let (Item::Let(cd) | Item::Imprint(cd)) = self.prog.mods[m].ast.items[item].clone() else { unreachable!() };
        let cx = self.new_cx(m, BodyRef::Const(c), GenScope::default());
        self.cxs.push(cx);
        self.push_frame(Frame {
            ret: None,
            ret_span: None,
            scope_base: 0,
            captures: Vec::new(),
            loops: Vec::new(),
            is_closure: false,
            by_ref: false,
            ret_insert: None,
            what: "constant",
        });
        if cd.ty.is_some() {
            let want = self.consts[c].ty.clone();
            self.check(&cd.value, &want);
        } else {
            self.infer(&cd.value, None);
        }
        self.finish_body();
        let resolved = self.tables[m].types.get(&cd.value.id).cloned();
        if cd.ty.is_none() {
            self.consts[c].ty = resolved.unwrap_or(Ty::Error);
        }
        self.const_state[c] = ConstState::Done;
        // an imprint is computed at compile time and embedded as data: its type must fit `Data`
        let ty = self.consts[c].ty.clone();
        if self.consts[c].imprint && !ty.has_error() && !ty.has_vars() {
            let data = self.b.data;
            if let Err(note) = self.fit(&ty, data, m) {
                let (name, span) = (self.consts[c].name.clone(), self.consts[c].span);
                let ts = self.defs.show(&ty);
                self.err_in(
                    m,
                    Diag::new("E0350", span, format!("`{ts}` doesn't fit the shape `Data`, which `imprint {name}` needs: its value is computed at compile time and embedded as data"))
                        .note(note)
                        .note("compute it at startup with `let` instead, or store data (lists, maps, structs, enums) and build the value from it"),
                );
            }
        }
    }

    fn check_fn(&mut self, f: FnId) {
        let info = self.fns[f].clone();
        let FnKind::Auk { item, clauses, header } = &info.kind else { return };
        let m = info.module;
        let Item::Fn(group) = self.prog.mods[m].ast.items[*item].clone() else { unreachable!() };
        let mut gs = GenScope::default();
        for &p in &info.generics {
            gs.names.insert(self.defs.params[p].name.clone(), p);
        }
        let cx = self.new_cx(m, BodyRef::Fn(f), gs);
        self.cxs.push(cx);
        let hdr = if *header { group.header.as_deref() } else { None };
        // contracts on the header line, in the header's own scope
        if let Some(h) = hdr {
            self.push_scope();
            self.push_frame(Frame {
                ret: Some(info.ret.clone()),
                ret_span: h.ret.as_ref().map(|t| t.span),
                scope_base: 0,
                captures: Vec::new(),
                loops: Vec::new(),
                is_closure: false,
                by_ref: false,
                ret_insert: None,
                what: "function",
            });
            self.bind_params(h, &info, true);
            self.contracts(h, &info);
            self.pop_frame();
            self.pop_scope();
        }
        for &ci in clauses {
            let c = &group.clauses[ci];
            self.push_scope();
            let ret_insert = if c.ret.is_none() { self.params_close(m, c) } else { None };
            self.push_frame(Frame {
                ret: Some(info.ret.clone()),
                ret_span: c.ret.as_ref().map(|t| t.span),
                scope_base: 0,
                captures: Vec::new(),
                loops: Vec::new(),
                is_closure: false,
                by_ref: false,
                ret_insert,
                what: "function",
            });
            self.bind_params(c, &info, false);
            if let Some(g) = &c.guard {
                self.guard(g);
            }
            self.contracts(c, &info);
            match &c.body {
                Some(FnBody::Expr(e)) => {
                    self.check_tail(e, &info.ret);
                }
                Some(FnBody::Block(b)) => {
                    let e = ast::Expr { id: b.id, span: b.span, kind: ast::ExprKind::Block(b.clone()) };
                    self.check_tail(&e, &info.ret);
                }
                _ => {}
            }
            self.pop_frame();
            self.pop_scope();
        }
        let olds = std::mem::take(&mut self.cxs.last_mut().unwrap().olds);
        let result_local = self.cxs.last().unwrap().result_local;
        let callees = std::mem::take(&mut self.cxs.last_mut().unwrap().callees);
        self.finish_body();
        self.fns[f].olds = olds;
        self.fns[f].result_local = result_local;
        self.fns[f].callees = callees;
    }

    /// The empty span just after the `)` that closes a clause's parameter list.
    fn params_close(&self, m: ModId, c: &FnClause) -> Option<Span> {
        let src = &self.prog.mods[m].src;
        let line = src.lines().nth(c.name.span.line as usize - 1)?;
        let chars: Vec<char> = line.chars().collect();
        let mut i = c.name.span.end_col as usize - 1;
        let mut depth = 0i32;
        while i < chars.len() {
            match chars[i] {
                '(' | '[' | '{' | '<' => depth += 1,
                ')' | ']' | '}' | '>' => {
                    depth -= 1;
                    if depth == 0 && chars[i] == ')' {
                        let col = i as u32 + 2;
                        return Some(Span { line: c.name.span.line, col, end_line: c.name.span.line, end_col: col });
                    }
                }
                _ => {}
            }
            i += 1;
        }
        None
    }

    /// Bind a clause's parameter patterns to the function's parameter types.
    fn bind_params(&mut self, c: &FnClause, info: &FnInfo, header: bool) {
        let mut seen = HashMap::new();
        for (p, pi) in c.params.iter().zip(&info.params) {
            self.cx().t.types.insert(p.id, pi.ty.clone());
            if header {
                // a header binds plain names only (for its contracts)
                if let PatKind::Bind(n) = &p.pat.kind {
                    let l = self.new_local(n, pi.ty.clone(), pi.var, p.pat.span);
                    self.cx().t.binds.insert(p.pat.id, l);
                    self.cx().t.types.insert(p.pat.id, pi.ty.clone());
                    self.scope_insert(n, l);
                }
                continue;
            }
            let before = self.tables[self.cur_module()].locals.len();
            self.pattern(&p.pat, &pi.ty, pi.var, &mut seen);
            // assigning to an immutable parameter suggests `x: var T`
            if let (false, Some(t)) = (pi.var, &p.ty) {
                let m = self.cur_module();
                let after = self.tables[m].locals.len();
                let at = Span { end_line: t.span.line, end_col: t.span.col, ..t.span };
                for l in before..after {
                    self.param_fixes.insert((m, l), at);
                }
            }
        }
    }

    fn contracts(&mut self, c: &FnClause, info: &FnInfo) {
        for r in &c.requires {
            self.check(r, &Ty::Bool);
        }
        if c.ensures.is_empty() {
            return;
        }
        self.push_scope();
        let rt = match &info.ret {
            Ty::Res(t, _) => (**t).clone(),
            t => t.clone(),
        };
        let l = match self.cx().result_local {
            Some(l) => l,
            None => {
                let l = self.new_local("result", rt, false, c.name.span);
                self.cx().result_local = Some(l);
                l
            }
        };
        self.scope_insert("result", l);
        self.cx().in_ensures = true;
        for e in &c.ensures {
            self.check(e, &Ty::Bool);
        }
        self.cx().in_ensures = false;
        self.pop_scope();
    }

    fn check_test(&mut self, t: TestId) {
        let m = self.tests[t].module;
        let Item::Test(td) = self.prog.mods[m].ast.items[self.tests[t].item].clone() else { unreachable!() };
        let cx = self.new_cx(m, BodyRef::Test(t), GenScope::default());
        self.cxs.push(cx);
        let ret = Ty::res(Ty::unit(), Ty::Named(self.b.err, Vec::new()));
        self.push_frame(Frame {
            ret: Some(ret),
            ret_span: None,
            scope_base: 0,
            captures: Vec::new(),
            loops: Vec::new(),
            is_closure: false,
            by_ref: false,
            ret_insert: None,
            what: "test",
        });
        let e = ast::Expr { id: td.body.id, span: td.body.span, kind: ast::ExprKind::Block(td.body.clone()) };
        self.stmt(&e, true);
        self.pop_frame();
        self.finish_body();
    }

    // ---- scopes and locals ----

    pub fn cx(&mut self) -> &mut BodyCx {
        self.cxs.last_mut().expect("no body in progress")
    }

    pub fn push_scope(&mut self) {
        self.cx().scopes.push(HashMap::new());
    }

    pub fn pop_scope(&mut self) {
        self.cx().scopes.pop();
    }

    /// A `when` guard: a `bool` that can't fail or leave the function (spec: guards are pure
    /// and can't fail), so it is checked in a frame without a return type.
    pub fn guard(&mut self, g: &ast::Expr) {
        self.push_frame(Frame {
            ret: None,
            ret_span: None,
            scope_base: 0,
            captures: Vec::new(),
            loops: Vec::new(),
            is_closure: false,
            by_ref: false,
            ret_insert: None,
            what: "guard",
        });
        self.check(g, &Ty::Bool);
        self.pop_frame();
    }

    pub fn push_frame(&mut self, mut f: Frame) {
        f.scope_base = self.cx().scopes.len();
        self.cx().frames.push(f);
    }

    pub fn pop_frame(&mut self) -> Frame {
        self.cx().frames.pop().expect("frame")
    }

    pub fn new_local(&mut self, name: &str, ty: Ty, mutable: bool, span: Span) -> LocalId {
        let m = self.cur_module();
        self.tables[m].locals.push(LocalInfo { name: name.to_string(), ty, mutable, span });
        self.tables[m].locals.len() - 1
    }

    pub fn scope_insert(&mut self, name: &str, l: LocalId) {
        self.cx().scopes.last_mut().unwrap().insert(name.to_string(), l);
    }

    /// Is a local named `name` in scope? (Unlike `lookup_local`, records no capture.)
    pub fn local_in_scope(&self, name: &str) -> bool {
        self.cxs.last().is_some_and(|cx| cx.scopes.iter().any(|s| s.contains_key(name)))
    }

    /// Find a local by name, recording captures for every closure frame it crosses.
    pub fn lookup_local(&mut self, name: &str) -> Option<LocalId> {
        let cx = self.cxs.last_mut()?;
        let idx = cx.scopes.iter().rposition(|s| s.contains_key(name))?;
        let l = cx.scopes[idx][name];
        for f in cx.frames.iter_mut().rev() {
            if f.scope_base <= idx {
                break;
            }
            if f.is_closure && !f.captures.contains(&l) {
                f.captures.push(l);
            }
        }
        Some(l)
    }

    /// Is local `l` captured by the innermost closure frame (declared outside it)?
    pub fn is_captured(&self, l: LocalId) -> bool {
        let Some(cx) = self.cxs.last() else { return false };
        cx.frames.iter().rev().take_while(|f| f.is_closure).any(|f| !f.by_ref && f.captures.contains(&l))
    }

    pub fn local_ty(&self, l: LocalId) -> Ty {
        self.tables[self.cur_module()].locals[l].ty.clone()
    }

    /// Resolve every inference variable of the finished body and merge its tables into the
    /// module's. Unresolved variables are reported once (E0360).
    fn finish_body(&mut self) {
        // deferred shape checks
        let deferred = std::mem::take(&mut self.cx().deferred);
        for d in deferred {
            let Deferred::Fits { ty, shape, span, why } = d;
            let t = self.cx().inf.resolve(&ty);
            if t.has_vars() || t.has_error() {
                continue;
            }
            self.require_fit(&t, shape, span, &why);
        }
        let cx = self.cxs.pop().unwrap();
        let m = cx.module;
        let inf = &cx.inf;
        let z = |t: &Ty| inf.resolve(t);
        let mut unresolved: Vec<NodeId> = Vec::new();
        let mut t = cx.t;
        for (n, ty) in t.types.iter_mut() {
            *ty = z(ty);
            if ty.has_vars() {
                *ty = ty.map_ty(&mut |x| if let Ty::Var(_) = x { Ty::Error } else { x });
                unresolved.push(*n);
            }
        }
        let fix_ty = |ty: &Ty| -> Ty { z(ty).map_ty(&mut |x| if let Ty::Var(_) = x { Ty::Error } else { x }) };
        for c in t.calls.values_mut() {
            match &mut c.callee {
                Callee::Fn { type_args, .. } => type_args.iter_mut().for_each(|a| *a = fix_ty(a)),
                Callee::Variant(v) => v.args.iter_mut().for_each(|a| *a = fix_ty(a)),
                Callee::Shape { self_ty, .. } => *self_ty = fix_ty(self_ty),
                _ => {}
            }
        }
        for s in t.shows.values_mut() {
            if let Callee::Shape { self_ty, .. } = s {
                *self_ty = fix_ty(self_ty);
            }
        }
        for v in t.variants.values_mut() {
            v.args.iter_mut().for_each(|a| *a = fix_ty(a));
        }
        for n in t.names.values_mut() {
            match n {
                NameRef::Fn { type_args, .. } => type_args.iter_mut().for_each(|a| *a = fix_ty(a)),
                NameRef::Variant(v) => v.args.iter_mut().for_each(|a| *a = fix_ty(a)),
                _ => {}
            }
        }
        for s in t.struct_lits.values_mut() {
            s.args.iter_mut().for_each(|a| *a = fix_ty(a));
        }
        for c in t.closures.values_mut() {
            c.params.iter_mut().for_each(|a| *a = fix_ty(a));
            c.ret = fix_ty(&c.ret);
        }
        for f in t.fails.values_mut() {
            if let FailKind::TypedToErr(x) = f {
                *x = fix_ty(x);
            }
        }
        for tr in t.tries.values_mut() {
            if let ErrConv::ToErr { from } = &mut tr.conv {
                *from = fix_ty(from);
            }
        }
        for x in t.err_payload_pats.values_mut() {
            *x = fix_ty(x);
        }
        let start = cx.local_start;
        for l in &mut self.tables[m].locals[start..] {
            l.ty = fix_ty(&l.ty);
        }
        if !unresolved.is_empty() && self.errs.is_empty() {
            // report at the first (in source order) expression whose type is unknown
            let span = self.first_span(m, &unresolved).unwrap_or_default();
            self.err_in(
                m,
                Diag::new("E0360", span, "can't infer the type of this expression").note("add a type annotation, e.g. `let xs: [int] = []`"),
            );
        }
        let tm = &mut self.tables[m];
        tm.types.extend(t.types);
        tm.coercions.extend(t.coercions);
        tm.names.extend(t.names);
        tm.binds.extend(t.binds);
        tm.variants.extend(t.variants);
        tm.calls.extend(t.calls);
        tm.fields.extend(t.fields);
        tm.struct_lits.extend(t.struct_lits);
        tm.struct_pats.extend(t.struct_pats);
        tm.closures.extend(t.closures);
        tm.tries.extend(t.tries);
        tm.fails.extend(t.fails);
        tm.elses.extend(t.elses);
        tm.opt_chains.extend(t.opt_chains);
        tm.awaits.extend(t.awaits);
        tm.fors.extend(t.fors);
        tm.formats.extend(t.formats);
        tm.shows.extend(t.shows);
        tm.value_map_pats.extend(t.value_map_pats);
        tm.err_payload_pats.extend(t.err_payload_pats);
        tm.units.extend(t.units);
    }

    /// The earliest span (in source order) among expression or pattern nodes of module `m`
    /// (searched in the AST; only used for rare diagnostics).
    fn first_span(&self, m: ModId, nodes: &[NodeId]) -> Option<Span> {
        let mut best: Option<Span> = None;
        let mut consider = |id: NodeId, span: Span| {
            if nodes.contains(&id) && best.is_none_or(|b| (span.line, span.col) < (b.line, b.col)) {
                best = Some(span);
            }
        };
        for item in &self.prog.mods[m].ast.items {
            visit_item_exprs(item, &mut |e| consider(e.id, e.span));
        }
        best
    }

    // ---- main ----

    fn find_main(&mut self) {
        let root = self.prog.root;
        let Some(ids) = self.items[root].fns.get("main").cloned() else { return };
        let f = ids[0];
        let info = self.fns[f].clone();
        let err = Ty::Named(self.b.err, Vec::new());
        let ok_args = info.params.is_empty() || (info.params.len() == 1 && info.params[0].ty == Ty::list(Ty::Str) && !info.params[0].var);
        let ok_ret = [Ty::unit(), Ty::Int, Ty::res(Ty::unit(), err.clone()), Ty::res(Ty::Int, err)].contains(&info.ret);
        if ids.len() > 1 || !ok_args || !ok_ret || !info.generics.is_empty() {
            self.err_in(
                root,
                Diag::new(
                    "E0370",
                    info.span,
                    format!(
                        "`main` has an unsupported signature: ({}) returning `{}`",
                        info.params.iter().map(|p| self.defs.show(&p.ty)).collect::<Vec<_>>().join(", "),
                        self.defs.show(&info.ret)
                    ),
                )
                .note("write `fn main()` or `fn main(args: [str])`, returning nothing, `int`, `()!` or `int!` (an `int` is the exit code)"),
            );
            return;
        }
        self.main = Some(MainInfo { func: f, takes_args: !info.params.is_empty(), ret: info.ret });
    }

    fn finish(self) -> TypedProgram {
        TypedProgram {
            program: self.prog,
            defs: self.defs,
            fns: self.fns,
            consts: self.consts,
            tests: self.tests,
            tables: self.tables,
            instances: self.instances,
            types_used: self.types_used,
            shape_impls: self.shape_impls,
            from_value_impls: self.from_value_impls,
            vtables: self.vtables,
            main: self.main,
        }
    }
}

/// Visit every expression of an item (pre-order), including nested blocks, closures and
/// interpolations.
pub(crate) fn visit_item_exprs(item: &Item, f: &mut impl FnMut(&ast::Expr)) {
    let clause = |c: &FnClause, f: &mut dyn FnMut(&ast::Expr)| {
        for e in c.requires.iter().chain(&c.ensures).chain(&c.guard) {
            visit_expr(e, f);
        }
        match &c.body {
            Some(FnBody::Expr(e)) => visit_expr(e, f),
            Some(FnBody::Block(b)) => b.stmts.iter().for_each(|s| visit_expr(s, f)),
            _ => {}
        }
    };
    match item {
        Item::Fn(g) => {
            for c in g.header.iter().map(|h| &**h).chain(&g.clauses) {
                clause(c, f);
            }
        }
        Item::Test(t) => t.body.stmts.iter().for_each(|s| visit_expr(s, f)),
        Item::Let(c) | Item::Imprint(c) => visit_expr(&c.value, f),
        _ => {}
    }
}

pub(crate) fn visit_expr(e: &ast::Expr, f: &mut dyn FnMut(&ast::Expr)) {
    use ast::ExprKind as K;
    f(e);
    let block = |b: &ast::Block, f: &mut dyn FnMut(&ast::Expr)| b.stmts.iter().for_each(|s| visit_expr(s, f));
    match &e.kind {
        K::Lit(_) | K::Name(_) | K::Hole | K::Continue => {}
        K::Measured { expr, .. } => visit_expr(expr, f),
        K::Interp(ps) => {
            for p in ps {
                if let ast::InterpPart::Expr { expr, .. } = p {
                    visit_expr(expr, f);
                }
            }
        }
        K::Field { expr, .. } | K::TupleField { expr, .. } | K::Unary { expr, .. } | K::Is { expr, .. } => visit_expr(expr, f),
        K::Try(x) | K::Unwrap(x) | K::Await(x) | K::AwaitAny(x) | K::Catch(x) | K::Ref(x) | K::Assert(x) | K::Peek(x) => visit_expr(x, f),
        K::Call { callee, args } => {
            visit_expr(callee, f);
            args.iter().for_each(|a| visit_expr(a, f));
        }
        K::MethodCall { recv, args, .. } => {
            visit_expr(recv, f);
            args.iter().for_each(|a| visit_expr(a, f));
        }
        K::Pipe { lhs, callee, args } => {
            visit_expr(lhs, f);
            visit_expr(callee, f);
            args.iter().for_each(|a| visit_expr(a, f));
        }
        K::Index { expr, index } => {
            visit_expr(expr, f);
            visit_expr(index, f);
        }
        K::Slice { expr, lo, hi, .. } => {
            visit_expr(expr, f);
            visit_expr(lo, f);
            visit_expr(hi, f);
        }
        K::Binary { lhs, rhs, .. } => {
            visit_expr(lhs, f);
            visit_expr(rhs, f);
        }
        K::Range { lo, hi, .. } => {
            visit_expr(lo, f);
            visit_expr(hi, f);
        }
        K::OptChain { expr, args, .. } => {
            visit_expr(expr, f);
            args.iter().flatten().for_each(|a| visit_expr(a, f));
        }
        K::Else { expr, arm } => {
            visit_expr(expr, f);
            visit_expr(&arm.body, f);
        }
        K::Closure { body, .. } => visit_expr(body, f),
        K::If { cond, then, els } => {
            visit_expr(cond, f);
            block(then, f);
            if let Some(x) = els {
                visit_expr(x, f);
            }
        }
        K::Match { scrut, arms } => {
            visit_expr(scrut, f);
            for a in arms {
                if let Some(g) = &a.guard {
                    visit_expr(g, f);
                }
                visit_expr(&a.body, f);
            }
        }
        K::Loop(b) | K::Block(b) => block(b, f),
        K::While { cond, body } => {
            visit_expr(cond, f);
            block(body, f);
        }
        K::For { iter, body, .. } => {
            visit_expr(iter, f);
            block(body, f);
        }
        K::Let { value, els, .. } => {
            visit_expr(value, f);
            if let Some(a) = els {
                visit_expr(&a.body, f);
            }
        }
        K::Assign { target, value, .. } => {
            visit_expr(target, f);
            visit_expr(value, f);
        }
        K::Return(x) | K::Break(x) => {
            if let Some(x) = x {
                visit_expr(x, f);
            }
        }
        K::Struct { fields, base, .. } => {
            fields.iter().filter_map(|fi| fi.value.as_ref()).for_each(|v| visit_expr(v, f));
            if let Some(b) = base {
                visit_expr(b, f);
            }
        }
        K::List(xs) | K::Tuple(xs) => xs.iter().for_each(|x| visit_expr(x, f)),
        K::Map(es) => {
            for (k, v) in es {
                visit_expr(k, f);
                visit_expr(v, f);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::expr::parse_format;
    use super::*;

    #[test]
    fn format_specs() {
        let f = parse_format("-^20.3").unwrap();
        assert_eq!((f.fill, f.align, f.zero, f.width, f.precision), (Some('-'), Some('^'), false, Some(20), Some(3)));
        let f = parse_format("08.2").unwrap();
        assert_eq!((f.fill, f.align, f.zero, f.width, f.precision), (None, None, true, Some(8), Some(2)));
        let f = parse_format(">5").unwrap();
        assert_eq!((f.align, f.width), (Some('>'), Some(5)));
        assert_eq!(parse_format("08x").unwrap().radix, Some('x'));
        assert!(parse_format("e").is_err());
        assert!(parse_format("xb").is_err());
        assert!(parse_format("5.").is_err());
        assert!(parse_format("").is_err());
    }

    #[test]
    fn typo_distance() {
        assert_eq!(edit_distance("cout", "count"), 1);
        assert_eq!(edit_distance("nmae", "name"), 1);
        assert_eq!(similar("lenght", &["length".to_string(), "len".to_string()]), Some("length".into()));
        assert_eq!(similar("zzz", &["length".to_string()]), None);
        // a tie is broken by name, not by the candidates' order
        let (f, g) = ("f".to_string(), "g".to_string());
        assert_eq!(similar("x", [&f, &g]), Some("f".into()));
        assert_eq!(similar("x", [&g, &f]), Some("f".into()));
    }

    #[test]
    fn articles_before_vowels() {
        assert_eq!(articles("found a `int` and a `str`, a `Item`"), "found an `int` and a `str`, an `Item`");
        assert_eq!(articles("data `x`"), "data `x`");
    }
}
