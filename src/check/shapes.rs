//! Shapes (structural fit, derived instances of the built-in shapes) and monomorphization.

use std::collections::HashMap;

use super::*;

impl Checker {
    /// Report unless `ty` fits `shape` (seen from the current module).
    pub fn require_fit(&mut self, ty: &Ty, shape: ShapeId, span: Span, why: &str) {
        let m = self.cur_module();
        if let Err(note) = self.fit(ty, shape, m) {
            let (ts, ss) = (self.defs.show(ty), self.defs.shapes[shape].name.clone());
            self.err(Diag::new("E0350", span, format!("`{ts}` doesn't fit the shape `{ss}`, {why}")).note(note));
        }
    }

    /// Does `ty` fit `shape`? `Err` carries a note saying what is missing.
    pub fn fit(&mut self, ty: &Ty, shape: ShapeId, m: ModId) -> Result<(), String> {
        self.fit_rec(ty, shape, m, &mut Vec::new())
    }

    fn fit_rec(&mut self, ty: &Ty, shape: ShapeId, m: ModId, visiting: &mut Vec<(Ty, ShapeId)>) -> Result<(), String> {
        // a unit of measure doesn't change what a number fits
        let ty = &ty.erase_units();
        if visiting.iter().any(|(t, s)| t == ty && *s == shape) {
            return Ok(());
        }
        let sname = self.defs.shapes[shape].name.clone();
        match ty {
            Ty::Error | Ty::Never => return Ok(()),
            Ty::Param(p) => {
                let b = &self.defs.params[*p].bounds;
                if b.contains(&shape) || (shape == self.b.eq && b.contains(&self.b.ord)) {
                    return Ok(());
                }
                let pn = self.defs.params[*p].name.clone();
                return Err(format!("the type parameter `{pn}` isn't declared to fit `{sname}`; add the bound: `<{pn}: {sname}>`"));
            }
            Ty::Any(s) => {
                if *s == shape {
                    return Ok(());
                }
                return Err(format!("an `any {}` value only fits `{}`", self.defs.shapes[*s].name, self.defs.shapes[*s].name));
            }
            _ => {}
        }
        if self.find_impl(shape, ty, m).is_some() {
            return Ok(());
        }
        let Some(builtin) = self.defs.shapes[shape].builtin else {
            return Err(self.missing_note(shape, ty));
        };
        visiting.push((ty.clone(), shape));
        let r = self.derive_ok(builtin, ty, shape, m, visiting);
        visiting.pop();
        r
    }

    fn missing_note(&self, shape: ShapeId, ty: &Ty) -> String {
        let s = &self.defs.shapes[shape];
        let ts = self.defs.show(ty);
        let sub: HashMap<ParamId, Ty> = [(s.self_param, ty.clone())].into_iter().collect();
        let sigs: Vec<String> = s
            .methods
            .iter()
            .map(|me| {
                let ps: Vec<String> = me
                    .params
                    .iter()
                    .enumerate()
                    .map(|(i, p)| if i == 0 { format!("x: {ts}") } else { format!("p{i}: {}", self.defs.show(&p.subst(&sub))) })
                    .collect();
                format!("fn {}({}): {}", me.name, ps.join(", "), self.defs.show(&me.ret.subst(&sub)))
            })
            .collect();
        format!("`{}` fits a type that has {}; no such function exists for `{ts}`", s.name, sigs.join(" and "))
    }

    /// Whether the compiler can derive built-in shape `b` for `ty` (its components must fit).
    fn derive_ok(&mut self, b: Builtin, ty: &Ty, shape: ShapeId, m: ModId, v: &mut Vec<(Ty, ShapeId)>) -> Result<(), String> {
        let ts = self.defs.show(ty);
        let comps = |me: &mut Checker, tys: Vec<Ty>, v: &mut Vec<(Ty, ShapeId)>| -> Result<(), String> {
            for t in tys {
                me.fit_rec(&t, shape, m, v)?;
            }
            Ok(())
        };
        match (b, ty) {
            (_, Ty::Int | Ty::Float | Ty::Bool | Ty::Char | Ty::Str) => Ok(()),
            (Builtin::Ord, Ty::List(t)) => comps(self, vec![(**t).clone()], v),
            (Builtin::Ord, Ty::Tuple(ts)) => comps(self, ts.clone(), v),
            (Builtin::Ord, _) => Err(format!(
                "`Ord` is automatic only for numbers, chars, strings, bools, and lists and tuples of them; define `fn cmp(a: {ts}, b: {ts}): int` (negative, 0 or positive)"
            )),
            (Builtin::Data, Ty::Tuple(_)) => Err("tuples don't convert to `Value`; use a struct".into()),
            (Builtin::Data, Ty::Map(k, val)) => {
                if **k != Ty::Str {
                    return Err(format!("only maps with `str` keys convert to `Value`, not `{ts}`"));
                }
                comps(self, vec![(**val).clone()], v)
            }
            (Builtin::Data, Ty::Res(..)) => Err("`T!` values don't convert to `Value`".into()),
            (_, Ty::Tuple(ts)) => comps(self, ts.clone(), v),
            (_, Ty::List(t) | Ty::Opt(t)) => comps(self, vec![(**t).clone()], v),
            (_, Ty::Map(k, val)) => comps(self, vec![(**k).clone(), (**val).clone()], v),
            (_, Ty::Res(t, e)) => comps(self, vec![(**t).clone(), (**e).clone()], v),
            (_, Ty::Named(d, args)) => {
                let d = *d;
                if d == self.b.value {
                    return Ok(());
                }
                let s = self.defs.subst_of(d, args);
                let fields: Vec<Ty> = match &self.defs.types[d].kind {
                    TypeDefKind::Struct { fields } => fields.iter().map(|f| f.ty.subst(&s)).collect(),
                    TypeDefKind::Enum { variants } => variants.iter().flat_map(|vr| vr.fields.iter().map(|(_, t)| t.subst(&s))).collect(),
                    // C pointers compare and print by address
                    TypeDefKind::Opaque { c_type } if !c_type.starts_with("Auk") && (shape == self.b.show || shape == self.b.eq) => return Ok(()),
                    TypeDefKind::Opaque { .. } => {
                        return Err(format!("`{ts}` is a runtime type without a `{}` instance", self.defs.shapes[shape].name));
                    }
                };
                for f in fields {
                    if let Err(e) = self.fit_rec(&f, shape, m, v) {
                        let fs = self.defs.show(&f);
                        return Err(format!("`{ts}` has a field of type `{fs}`: {e}"));
                    }
                }
                Ok(())
            }
            (_, Ty::Fn(..)) => Err("closures don't fit the built-in shapes".into()),
            (_, Ty::Task(_)) => Err("tasks don't fit the built-in shapes; `await` them first".into()),
            _ => Err(format!("`{ts}` doesn't fit `{}`", self.defs.shapes[shape].name)),
        }
    }

    /// User (or core) functions implementing every method of `shape` for `ty`: for each
    /// method, the function and its type arguments. Searched in `m`, then `ty`'s module, then
    /// core. A function whose first parameter is a bare type parameter doesn't count (that would
    /// be a generic over the shape itself).
    pub fn find_impl(&mut self, shape: ShapeId, ty: &Ty, m: ModId) -> Option<Vec<(FnId, Vec<Ty>)>> {
        let sh = self.defs.shapes[shape].clone();
        let mut tiers = vec![m];
        if let Ty::Named(d, _) = ty {
            let home = self.defs.types[*d].module;
            if !tiers.contains(&home) {
                tiers.push(home);
            }
        }
        let core = self.prog.core_root;
        if !tiers.contains(&core) {
            tiers.push(core);
        }
        let sub: HashMap<ParamId, Ty> = [(sh.self_param, ty.clone())].into_iter().collect();
        let mut out = Vec::new();
        'methods: for meth in &sh.methods {
            for &tier in &tiers {
                let cands: Vec<FnId> =
                    if tier == core { self.items[core].fns.get(&meth.name).cloned().unwrap_or_default() } else { self.fns_in(m, tier, &meth.name) };
                for f in cands {
                    let info = &self.fns[f];
                    if info.params.len() != meth.params.len() || matches!(info.params[0].ty, Ty::Param(_)) {
                        continue;
                    }
                    let mut inf = Infer::default();
                    let s: HashMap<ParamId, Ty> = info.generics.iter().map(|&g| (g, inf.fresh())).collect();
                    let mut ok = inf.unify(&info.params[0].ty.subst(&s), ty);
                    for (k, mp) in meth.params.iter().enumerate().skip(1) {
                        ok = ok && inf.unify(&info.params[k].ty.subst(&s), &mp.subst(&sub));
                    }
                    ok = ok && inf.unify(&info.ret.subst(&s), &meth.ret.subst(&sub));
                    if ok {
                        let targs = info.generics.iter().map(|g| inf.resolve(&s[g])).collect();
                        out.push((f, targs));
                        continue 'methods;
                    }
                }
            }
            return None;
        }
        Some(out)
    }

    // ---- monomorphization ----

    pub fn monomorphize(&mut self) {
        let mut index: HashMap<(BodyRef, Vec<Ty>), InstId> = HashMap::new();
        let mut work: Vec<InstId> = Vec::new();
        for f in 0..self.fns.len() {
            if matches!(self.fns[f].kind, FnKind::Auk { .. }) && self.fns[f].generics.is_empty() {
                self.instance_of(BodyRef::Fn(f), Vec::new(), &mut index, &mut work);
            }
        }
        for t in 0..self.tests.len() {
            self.instance_of(BodyRef::Test(t), Vec::new(), &mut index, &mut work);
        }
        for c in 0..self.consts.len() {
            self.instance_of(BodyRef::Const(c), Vec::new(), &mut index, &mut work);
        }
        let mut ops_done = 0;
        loop {
            while let Some(i) = work.pop() {
                self.process_instance(i, &mut index, &mut work);
            }
            // element ops: Show/Eq/Ord of every list and map element type that has them
            let used: Vec<Ty> = self.types_used.iter().cloned().collect();
            if used.len() == ops_done {
                break;
            }
            ops_done = used.len();
            for t in used {
                let elems: Vec<Ty> = match &t {
                    Ty::List(e) => vec![(**e).clone()],
                    Ty::Map(k, v) => vec![(**k).clone(), (**v).clone()],
                    _ => Vec::new(),
                };
                for e in elems {
                    for (b, s) in [(Builtin::Show, self.b.show), (Builtin::Eq, self.b.eq), (Builtin::Ord, self.b.ord)] {
                        let root = self.prog.root;
                        if !self.shape_impls.contains_key(&(b, e.clone()))
                            && let Some(from) = self.fit_from(&e, s, root)
                        {
                            self.impl_target(s, 0, &e, from, &mut index, &mut work);
                        }
                    }
                }
            }
            if work.is_empty() {
                break;
            }
        }
    }

    fn process_instance(&mut self, i: InstId, index: &mut HashMap<(BodyRef, Vec<Ty>), InstId>, work: &mut Vec<InstId>) {
        let body = self.instances[i].body;
        let subst = self.instances[i].subst(&self.fns);
        let nodes = self.body_nodes.get(&body).cloned().unwrap_or_default();
        let m = nodes.module;
        let mut resolved = HashMap::new();
        for n in &nodes.calls {
            let Some(call) = self.tables[m].calls.get(n).cloned() else { continue };
            let t = self.resolve_target(&call.callee, &subst, m, index, work);
            resolved.insert(*n, t);
        }
        for n in &nodes.fn_refs {
            if let Some(NameRef::Fn { func, type_args }) = self.tables[m].names.get(n).cloned() {
                let args: Vec<Ty> = type_args.iter().map(|t| t.subst(&subst)).collect();
                let t = self.fn_target(func, args, m, index, work);
                resolved.insert(*n, t);
            }
        }
        let mut shows = HashMap::new();
        for n in &nodes.shows {
            let Some(callee) = self.tables[m].shows.get(n).cloned() else { continue };
            let t = self.resolve_target(&callee, &subst, m, index, work);
            shows.insert(*n, t);
        }
        let mut vts = HashMap::new();
        for n in &nodes.anys {
            let Some(ty) = self.tables[m].types.get(n).cloned() else { continue };
            let ty = ty.subst(&subst);
            let Some(cs) = self.tables[m].coercions.get(n).cloned() else { continue };
            for c in cs {
                if let Coercion::ToAny(s) = c {
                    let vt = self.vtable(s, &ty, m, index, work);
                    vts.insert(*n, vt);
                }
            }
        }
        self.instances[i].resolved = resolved;
        self.instances[i].shows = shows;
        self.instances[i].vtables = vts;
        // concrete types used by this instance
        let mut tys = Vec::new();
        self.body_types(body, &mut tys);
        for t in tys {
            let t = t.subst(&subst);
            self.use_type(&t);
        }
    }

    fn instance_of(&mut self, body: BodyRef, args: Vec<Ty>, index: &mut HashMap<(BodyRef, Vec<Ty>), InstId>, work: &mut Vec<InstId>) -> InstId {
        // units are erased: `sum` of `[float<m>]` and of `[float]` is one instance
        let args: Vec<Ty> = args.iter().map(Ty::erase_units).collect();
        if let Some(&i) = index.get(&(body, args.clone())) {
            return i;
        }
        let i = self.instances.len();
        self.instances.push(Instance { body, type_args: args.clone(), resolved: HashMap::new(), shows: HashMap::new(), vtables: HashMap::new() });
        index.insert((body, args), i);
        work.push(i);
        i
    }

    fn resolve_target(
        &mut self,
        callee: &Callee,
        subst: &HashMap<ParamId, Ty>,
        m: ModId,
        index: &mut HashMap<(BodyRef, Vec<Ty>), InstId>,
        work: &mut Vec<InstId>,
    ) -> Target {
        match callee {
            Callee::Fn { func, type_args } => {
                let args: Vec<Ty> = type_args.iter().map(|t| t.subst(subst)).collect();
                self.fn_target(*func, args, m, index, work)
            }
            Callee::Variant(v) => Target::Variant { def: v.def, index: v.index },
            Callee::Closure => Target::Closure,
            Callee::Vtable { shape, method } => Target::Vtable { shape: *shape, method: *method },
            Callee::Shape { shape, method, self_ty } => {
                let t = self_ty.subst(subst);
                self.impl_target(*shape, *method, &t, m, index, work)
            }
        }
    }

    fn fn_target(&mut self, f: FnId, args: Vec<Ty>, m: ModId, index: &mut HashMap<(BodyRef, Vec<Ty>), InstId>, work: &mut Vec<InstId>) -> Target {
        let args: Vec<Ty> = args.iter().map(Ty::erase_units).collect();
        match self.fns[f].kind.clone() {
            FnKind::Auk { .. } => Target::Instance(self.instance_of(BodyRef::Fn(f), args, index, work)),
            FnKind::Extern { symbol, loc, .. } => Target::Extern { symbol, loc },
            FnKind::Ffi { .. } => Target::Ffi(f),
            FnKind::Intrinsic { which, .. } => {
                let ty = args.first().cloned().unwrap_or_else(Ty::unit);
                let shape = match which {
                    Intrinsic::Show => Some(self.b.show),
                    Intrinsic::Eq => Some(self.b.eq),
                    Intrinsic::Cmp => Some(self.b.ord),
                    Intrinsic::ToValue => Some(self.b.data),
                    _ => None,
                };
                match shape {
                    Some(s) if !matches!(ty, Ty::Param(_)) => {
                        let t = self.impl_target(s, 0, &ty, m, index, work);
                        if let Target::Derived { .. } = t { Target::Intrinsic { which, ty } } else { t }
                    }
                    _ if which == Intrinsic::FromValue && !ty.has_params() => {
                        // `core.from_value(v): D` uses a user `fn from_value(v: Value): D!` like
                        // `core.to_value(d)` uses a user `to_value(d: D)` (#523)
                        let ty = ty.erase_units();
                        self.resolve_from_value(&ty, &[m], index, work);
                        match self.from_value_impls.get(&ty) {
                            Some(t) => t.clone(),
                            None => Target::Intrinsic { which, ty },
                        }
                    }
                    _ => Target::Intrinsic { which, ty },
                }
            }
        }
    }

    /// How method `method` of `shape` is implemented for the concrete `ty`.
    fn impl_target(
        &mut self,
        shape: ShapeId,
        method: usize,
        ty: &Ty,
        m: ModId,
        index: &mut HashMap<(BodyRef, Vec<Ty>), InstId>,
        work: &mut Vec<InstId>,
    ) -> Target {
        let ty = &ty.erase_units();
        let builtin = self.defs.shapes[shape].builtin;
        if let Some(b) = builtin
            && let Some(t) = self.shape_impls.get(&(b, ty.clone()))
        {
            return t.clone();
        }
        // A user function in `m`'s view, else one in the type's own module even if private
        // there (`fn cmp(a: Item, b: Item)` next to `struct Item`): generic code instantiated
        // elsewhere (core's `sort`) can't name it, but it still implements the shape.
        let found = self.find_impl(shape, ty, m).map(|f| (f, m)).or_else(|| {
            let home = self.home_module(ty).filter(|&h| h != m)?;
            self.find_impl(shape, ty, home).map(|f| (f, home))
        });
        let t = match found {
            Some((fns, from)) => {
                let (f, args) = fns[method].clone();
                self.fn_target(f, args, from, index, work)
            }
            None => match builtin {
                Some(b) => {
                    self.shape_impls.insert((b, ty.clone()), Target::Derived { shape: b, ty: ty.clone() });
                    self.derived_components(b, ty, m, index, work);
                    Target::Derived { shape: b, ty: ty.clone() }
                }
                None => Target::Derived { shape: Builtin::Show, ty: ty.clone() },
            },
        };
        if let Some(b) = builtin {
            self.shape_impls.insert((b, ty.clone()), t.clone());
        }
        t
    }

    /// Record how `from_value` makes a `ty`: a user `fn from_value(v: Value): T!` (in
    /// `from_value_impls`), else derived, structurally, with each field and element type
    /// resolved the same way. The derived `from_value` is the inverse of the derived
    /// `to_value`, which calls a user `to_value` for components, so a custom form nested in a
    /// struct, list, map or optional must be read back by the matching user `from_value` (#523).
    /// The user function is looked for in `mods` (the requesting module, then the modules of the
    /// enclosing types) and in `ty`'s own module, private functions included there.
    fn resolve_from_value(&mut self, ty: &Ty, mods: &[ModId], index: &mut HashMap<(BodyRef, Vec<Ty>), InstId>, work: &mut Vec<InstId>) {
        if matches!(ty, Ty::Int | Ty::Float | Ty::Bool | Ty::Char | Ty::Str) || ty.has_params() || !self.from_value_seen.insert(ty.clone()) {
            return;
        }
        let mut tiers = mods.to_vec();
        if let Some(h) = self.home_module(ty)
            && !tiers.contains(&h)
        {
            tiers.push(h);
        }
        if let Some((f, args, from)) = self.find_from_value(ty, &tiers) {
            let t = self.fn_target(f, args, from, index, work);
            self.from_value_impls.insert(ty.clone(), t);
            return;
        }
        for c in self.components(ty) {
            self.resolve_from_value(&c.erase_units(), &tiers, index, work);
        }
    }

    /// A non-core `fn from_value(v: Value): T!` that makes `ty` (generic ones included, except
    /// one returning a bare type parameter, which would just be a wrapper of core's), from the
    /// first of `tiers` that has one.
    fn find_from_value(&self, ty: &Ty, tiers: &[ModId]) -> Option<(FnId, Vec<Ty>, ModId)> {
        let value = Ty::Named(self.b.value, Vec::new());
        for &tier in tiers {
            if self.prog.is_core(tier) {
                continue;
            }
            for f in self.fns_in(tier, tier, "from_value") {
                let info = &self.fns[f];
                if info.params.len() != 1 || info.params[0].ty != value {
                    continue;
                }
                let Ty::Res(ok, er) = &info.ret else { continue };
                if matches!(**ok, Ty::Param(_)) || !self.defs.is_err(er) {
                    continue;
                }
                let mut inf = Infer::default();
                let s: HashMap<ParamId, Ty> = info.generics.iter().map(|&g| (g, inf.fresh())).collect();
                if inf.unify(&ok.subst(&s), ty) {
                    let targs = info.generics.iter().map(|g| inf.resolve(&s[g])).collect();
                    return Some((f, targs, tier));
                }
            }
        }
        None
    }

    /// The component types of a derived instance: element, field and variant field types.
    fn components(&self, ty: &Ty) -> Vec<Ty> {
        match ty {
            Ty::List(t) | Ty::Opt(t) => vec![(**t).clone()],
            Ty::Map(k, v) => vec![(**k).clone(), (**v).clone()],
            Ty::Res(t, e) => vec![(**t).clone(), (**e).clone()],
            Ty::Tuple(ts) => ts.clone(),
            Ty::Named(d, args) => {
                let s = self.defs.subst_of(*d, args);
                match &self.defs.types[*d].kind {
                    TypeDefKind::Struct { fields } => fields.iter().map(|f| f.ty.subst(&s)).collect(),
                    TypeDefKind::Enum { variants } => variants.iter().flat_map(|v| v.fields.iter().map(|(_, t)| t.subst(&s))).collect(),
                    _ => Vec::new(),
                }
            }
            _ => Vec::new(),
        }
    }

    /// Make sure the components of a derived instance have their own instances recorded.
    fn derived_components(&mut self, b: Builtin, ty: &Ty, m: ModId, index: &mut HashMap<(BodyRef, Vec<Ty>), InstId>, work: &mut Vec<InstId>) {
        let shape = match b {
            Builtin::Show => self.b.show,
            Builtin::Eq => self.b.eq,
            Builtin::Ord => self.b.ord,
            Builtin::Data => self.b.data,
        };
        for c in self.components(ty) {
            let c = c.erase_units();
            if matches!(c, Ty::Int | Ty::Float | Ty::Bool | Ty::Char | Ty::Str) || c.has_params() {
                continue;
            }
            if !self.shape_impls.contains_key(&(b, c.clone()))
                && let Some(from) = self.fit_from(&c, shape, m)
            {
                self.impl_target(shape, 0, &c, from, index, work);
            }
        }
    }

    /// The module of a struct or enum type's definition.
    fn home_module(&self, ty: &Ty) -> Option<ModId> {
        match ty {
            Ty::Named(d, _) => Some(self.defs.types[*d].module),
            _ => None,
        }
    }

    /// Does `ty` fit `shape` seen from `m`, or else from its own module (where its private
    /// shape functions are visible)? The module to resolve the implementation from.
    fn fit_from(&mut self, ty: &Ty, shape: ShapeId, m: ModId) -> Option<ModId> {
        if self.fit(ty, shape, m).is_ok() {
            return Some(m);
        }
        let home = self.home_module(ty).filter(|&h| h != m)?;
        self.fit(ty, shape, home).is_ok().then_some(home)
    }

    fn vtable(&mut self, shape: ShapeId, ty: &Ty, m: ModId, index: &mut HashMap<(BodyRef, Vec<Ty>), InstId>, work: &mut Vec<InstId>) -> VtableId {
        let ty = &ty.erase_units();
        if let Some(i) = self.vtables.iter().position(|v| v.shape == shape && &v.ty == ty) {
            return i;
        }
        let n = self.defs.shapes[shape].methods.len();
        let methods = (0..n).map(|k| self.impl_target(shape, k, ty, m, index, work)).collect();
        self.vtables.push(Vtable { shape, ty: ty.clone(), methods });
        self.vtables.len() - 1
    }

    /// Record a concrete type and its components in `types_used`.
    fn use_type(&mut self, t: &Ty) {
        if t.has_units() {
            return self.use_type(&t.erase_units());
        }
        if t.has_params() || t.has_error() || t.has_vars() || self.types_used.contains(t) {
            return;
        }
        if matches!(t, Ty::Never) {
            return;
        }
        self.types_used.insert(t.clone());
        for c in t.children() {
            let c = c.clone();
            self.use_type(&c);
        }
        if let Ty::Named(d, args) = t {
            let s = self.defs.subst_of(*d, args);
            let inner: Vec<Ty> = match &self.defs.types[*d].kind {
                TypeDefKind::Struct { fields } => fields.iter().map(|f| f.ty.subst(&s)).collect(),
                TypeDefKind::Enum { variants } => variants.iter().flat_map(|v| v.fields.iter().map(|(_, t)| t.subst(&s))).collect(),
                _ => Vec::new(),
            };
            for c in inner {
                self.use_type(&c);
            }
        }
    }

    /// Every type recorded for the expressions, patterns and parameters of a body.
    fn body_types(&self, body: BodyRef, out: &mut Vec<Ty>) {
        let (m, item, clauses): (ModId, usize, Option<Vec<usize>>) = match body {
            BodyRef::Fn(f) => match &self.fns[f].kind {
                FnKind::Auk { item, clauses, .. } => (self.fns[f].module, *item, Some(clauses.clone())),
                _ => return,
            },
            BodyRef::Test(t) => (self.tests[t].module, self.tests[t].item, None),
            BodyRef::Const(c) => (self.consts[c].module, self.consts[c].item, None),
        };
        let tables = &self.tables[m];
        let item = &self.prog.mods[m].ast.items[item];
        if let BodyRef::Fn(f) = body {
            for p in &self.fns[f].params {
                out.push(p.ty.clone());
            }
            out.push(self.fns[f].ret.clone());
        }
        let mut push = |id: NodeId| {
            if let Some(t) = tables.types.get(&id) {
                out.push(t.clone());
            }
        };
        match (item, clauses) {
            (Item::Fn(g), Some(cs)) => {
                for ci in cs {
                    let c = &g.clauses[ci];
                    for p in &c.params {
                        visit_pat(&p.pat, &mut |q| push(q.id));
                    }
                    let one = Item::Fn(ast::FnGroup { name: g.name.clone(), arity: g.arity, header: None, clauses: vec![c.clone()] });
                    visit_item_exprs(&one, &mut |e| {
                        push(e.id);
                        visit_expr_pats(e, &mut |q| push(q.id));
                    });
                }
            }
            (item, _) => visit_item_exprs(item, &mut |e| {
                push(e.id);
                visit_expr_pats(e, &mut |q| push(q.id));
            }),
        }
    }
}

/// The patterns directly inside an expression (let, match arms, for, closure params, is).
fn visit_expr_pats(e: &ast::Expr, f: &mut impl FnMut(&ast::Pat)) {
    use ast::ExprKind as K;
    match &e.kind {
        K::Let { pat, .. } | K::Is { pat, .. } => visit_pat(pat, f),
        K::Match { arms, .. } => arms.iter().for_each(|a| visit_pat(&a.pat, f)),
        K::For { index, pat, .. } => {
            if let Some(i) = index {
                visit_pat(i, f);
            }
            visit_pat(pat, f);
        }
        K::Closure { params, .. } => params.iter().for_each(|p| visit_pat(&p.pat, f)),
        _ => {}
    }
}

pub(crate) fn visit_pat(p: &ast::Pat, f: &mut impl FnMut(&ast::Pat)) {
    f(p);
    match &p.kind {
        PatKind::Tuple(ps) => ps.iter().for_each(|q| visit_pat(q, f)),
        PatKind::List { head, rest, tail } => {
            head.iter().chain(tail).for_each(|q| visit_pat(q, f));
            if let Some(r) = rest
                && let Some(q) = &r.pat
            {
                visit_pat(q, f);
            }
        }
        PatKind::Variant { args: Some(a), .. } => a.iter().for_each(|q| visit_pat(q, f)),
        PatKind::Struct { fields, .. } => fields.iter().filter_map(|x| x.pat.as_ref()).for_each(|q| visit_pat(q, f)),
        PatKind::Map(es) => es.iter().for_each(|(_, q)| visit_pat(q, f)),
        PatKind::StrPrefix { rest, .. } => visit_pat(rest, f),
        PatKind::Some(q) | PatKind::Ok(q) | PatKind::Err(q) => visit_pat(q, f),
        _ => {}
    }
}
