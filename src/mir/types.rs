//! How Auk types are represented: which values hold references, which struct and variant
//! fields are boxed, and the members (`Sel`) of each aggregate. Shared by the MIR generator and
//! the back ends.
//!
//! Representations (the C names are the runtime's types, runtime/c/auk_rt.h):
//! - `int float bool char` → i64, f64, bool (1 byte), u32; `()` and `never` → a byte.
//! - `str`, `[T]`, `{K: V}`, `Task<T>` and opaque runtime types → pointers to runtime objects.
//! - tuple → members `F(i)`; struct → `F(i)` per field (a boxed field is a `AukObj *` cell
//!   holding the value); enum (and core `Value`) → `Tag` (i32) plus a union of variants, field
//!   `fi` of variant `vi` is `V(vi, fi)` (boxed like struct fields; never boxed in `Value`).
//! - `T?` → `F(0)` some (bool), `F(1)` val; `T!` / `T!E` → `F(0)` ok (bool), `F(1)` val,
//!   `F(2)` err (`AukErr *`; a typed `E` travels as the error's payload).
//! - closure → `F(0)` code pointer, `F(1)` environment (`AukObj *` or NULL).
//! - `any S` → `F(0)` the boxed value (`AukObj *`), `F(1)` its vtable.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

use super::{AggDef, MTy, Sel};
use crate::typed::TypedProgram;
use crate::types::{DefId, ShapeId, Ty, TypeDefKind};

/// Type facts about a typed program.
pub struct TyInfo<'a> {
    pub tp: &'a TypedProgram,
    pub value_def: Option<DefId>,
    err_def: DefId,
    rc: RefCell<HashMap<Ty, bool>>,
}

impl<'a> TyInfo<'a> {
    pub fn new(tp: &'a TypedProgram) -> TyInfo<'a> {
        let value_def = tp
            .defs
            .types
            .iter()
            .position(|d| d.name == "Value" && tp.program.is_core(d.module) && matches!(d.kind, TypeDefKind::Enum { .. }));
        let err_def = tp.defs.types.iter().position(|d| d.name == "Err" && matches!(d.kind, TypeDefKind::Opaque { .. })).unwrap_or(0);
        TyInfo { tp, value_def, err_def, rc: RefCell::new(HashMap::new()) }
    }

    pub fn is_value(&self, t: &Ty) -> bool {
        matches!(t, Ty::Named(d, _) if Some(*d) == self.value_def)
    }

    pub fn is_err_ty(&self, t: &Ty) -> bool {
        self.tp.defs.is_err(t)
    }

    pub fn err_ty(&self) -> Ty {
        Ty::Named(self.err_def, Vec::new())
    }

    pub fn is_opaque(&self, t: &Ty) -> bool {
        matches!(t, Ty::Named(d, _) if matches!(self.tp.defs.types[*d].kind, TypeDefKind::Opaque { .. }))
    }

    /// Is it a C pointer type (`ffi.Ptr`, or a user `extern type`)? A plain address: no
    /// reference count.
    pub fn is_foreign(&self, t: &Ty) -> bool {
        self.opaque_c(t).is_some_and(|c| !c.starts_with("Auk"))
    }

    /// Is it an opaque type the runtime changes in place, copying it first when shared (a
    /// `pixels.Frame`)? An extern's `var` parameter of such a type gets the variable's address,
    /// as lists and maps do, so the runtime can swap in the copy. Other opaque types are handles
    /// (`net.Conn`): a `var` one is passed by value.
    pub fn is_cow_opaque(&self, t: &Ty) -> bool {
        self.opaque_c(t) == Some("AukFrame *")
    }

    /// The opaque type's runtime C spelling (`AukErr *`, `AukConn *`).
    pub fn opaque_c(&self, t: &Ty) -> Option<&str> {
        match t {
            Ty::Named(d, _) => match &self.tp.defs.types[*d].kind {
                TypeDefKind::Opaque { c_type } => Some(c_type),
                _ => None,
            },
            _ => None,
        }
    }

    pub fn show_ty(&self, t: &Ty) -> String {
        self.tp.defs.show(t)
    }

    /// Is the value a pointer to a runtime object (`str`, lists, maps, tasks, opaque types)?
    pub fn is_ptr(&self, t: &Ty) -> bool {
        matches!(t, Ty::Str | Ty::List(_) | Ty::Map(..) | Ty::Task(_)) || self.is_opaque(t)
    }

    /// Is the value a scalar (one machine word or less, no members)?
    pub fn is_scalar(&self, t: &Ty) -> bool {
        matches!(t, Ty::Int | Ty::Float | Ty::Bool | Ty::Char | Ty::Never) || t.is_unit() || self.is_ptr(t)
    }

    /// Does a value of this type hold references?
    pub fn needs_rc(&self, t: &Ty) -> bool {
        if let Some(&b) = self.rc.borrow().get(t) {
            return b;
        }
        let b = match t {
            Ty::Int | Ty::Float | Ty::Bool | Ty::Char | Ty::Never => false,
            Ty::Str | Ty::List(_) | Ty::Map(..) | Ty::Task(_) | Ty::Fn(..) | Ty::Any(_) => true,
            Ty::Tuple(ts) => {
                self.rc.borrow_mut().insert(t.clone(), false);
                ts.iter().any(|x| self.needs_rc(x))
            }
            Ty::Opt(x) => self.needs_rc(x),
            Ty::Res(..) => true,
            Ty::Named(d, _) => {
                if Some(*d) == self.value_def {
                    true
                } else {
                    match &self.tp.defs.types[*d].kind {
                        TypeDefKind::Opaque { c_type } => c_type.starts_with("Auk"),
                        TypeDefKind::Struct { .. } => {
                            let layout = self.struct_layout(t);
                            self.rc.borrow_mut().insert(t.clone(), false);
                            layout.iter().any(|(ft, boxed)| *boxed || self.needs_rc(ft))
                        }
                        TypeDefKind::Enum { .. } => {
                            let layout = self.enum_layout(t);
                            self.rc.borrow_mut().insert(t.clone(), false);
                            layout.iter().flatten().any(|(ft, boxed)| *boxed || self.needs_rc(ft))
                        }
                    }
                }
            }
            _ => false,
        };
        self.rc.borrow_mut().insert(t.clone(), b);
        b
    }

    /// Per struct field: its type (substituted) and whether it is boxed (a field whose type
    /// contains the struct itself by value, like `boss: User?`).
    pub fn struct_layout(&self, t: &Ty) -> Vec<(Ty, bool)> {
        let Ty::Named(d, args) = t else { return Vec::new() };
        let s = self.tp.defs.subst_of(*d, args);
        self.tp
            .defs
            .fields(*d)
            .iter()
            .map(|f| {
                let ft = f.ty.subst(&s);
                let boxed = self.reaches(&ft, t, &mut HashSet::new());
                (ft, boxed)
            })
            .collect()
    }

    /// Per variant, the field types (substituted) and whether each is boxed.
    pub fn enum_layout(&self, t: &Ty) -> Vec<Vec<(Ty, bool)>> {
        let Ty::Named(d, args) = t else { return Vec::new() };
        let s = self.tp.defs.subst_of(*d, args);
        let value = Some(*d) == self.value_def;
        self.tp
            .defs
            .variants(*d)
            .iter()
            .map(|v| {
                v.fields
                    .iter()
                    .map(|(_, ft)| {
                        let ft = ft.subst(&s);
                        let boxed = !value && self.reaches(&ft, t, &mut HashSet::new());
                        (ft, boxed)
                    })
                    .collect()
            })
            .collect()
    }

    /// Does `t` contain `target` by value (through tuples, optionals, results, structs, enums)?
    fn reaches(&self, t: &Ty, target: &Ty, seen: &mut HashSet<Ty>) -> bool {
        if t == target {
            return true;
        }
        if !seen.insert(t.clone()) {
            return false;
        }
        match t {
            Ty::Tuple(ts) => ts.iter().any(|x| self.reaches(x, target, seen)),
            Ty::Opt(x) => self.reaches(x, target, seen),
            Ty::Res(x, _) => self.reaches(x, target, seen),
            Ty::Named(d, args) if Some(*d) != self.value_def => {
                let s = self.tp.defs.subst_of(*d, args);
                match &self.tp.defs.types[*d].kind {
                    TypeDefKind::Struct { fields } => fields.iter().any(|f| self.reaches(&f.ty.subst(&s), target, seen)),
                    TypeDefKind::Enum { variants } => variants.iter().any(|v| v.fields.iter().any(|(_, ft)| self.reaches(&ft.subst(&s), target, seen))),
                    _ => false,
                }
            }
            _ => false,
        }
    }

    pub fn is_struct(&self, t: &Ty) -> bool {
        matches!(t, Ty::Named(d, _) if self.tp.defs.is_struct(*d))
    }

    /// A shape method's parameter or return type, with `Self` (unsupported for `any`) as `()`.
    pub fn method_ty(&self, t: &Ty, s: ShapeId) -> Ty {
        let sp = self.tp.defs.shapes[s].self_param;
        t.map_ty(&mut |x| if x == Ty::Param(sp) { Ty::unit() } else { x })
    }

    /// The type of member `sel` of a value of type `t`.
    pub fn member_ty(&self, t: &MTy, sel: Sel, aggs: &[AggDef]) -> MTy {
        match (t, sel) {
            (MTy::Agg(a), Sel::F(i)) => aggs[*a as usize].fields[i as usize].clone(),
            (MTy::D(t), sel) => self.d_member_ty(t, sel),
            _ => panic!("mir: no member {sel:?} of {t:?}"),
        }
    }

    fn d_member_ty(&self, t: &Ty, sel: Sel) -> MTy {
        let boxed = |b: bool, ft: Ty| if b { MTy::obj_ptr() } else { MTy::D(ft) };
        match (t, sel) {
            (Ty::Tuple(ts), Sel::F(i)) => MTy::D(ts[i as usize].clone()),
            (Ty::Opt(_), Sel::F(0)) | (Ty::Res(..), Sel::F(0)) => MTy::Bool,
            (Ty::Opt(x), Sel::F(1)) | (Ty::Res(x, _), Sel::F(1)) => MTy::D((**x).clone()),
            (Ty::Res(..), Sel::F(2)) => MTy::D(self.err_ty()),
            (Ty::Fn(..), Sel::F(0)) => MTy::Code,
            (Ty::Fn(..), Sel::F(1)) | (Ty::Any(_), Sel::F(0)) => MTy::obj_ptr(),
            (Ty::Any(_), Sel::F(1)) => MTy::void_ptr(),
            (Ty::Named(..), Sel::F(i)) if self.is_struct(t) => {
                let (ft, b) = self.struct_layout(t).swap_remove(i as usize);
                boxed(b, ft)
            }
            (Ty::Named(..), Sel::Tag) => MTy::I32,
            (Ty::Named(..), Sel::V(vi, fi)) => {
                let (ft, b) = self.enum_layout(t).swap_remove(vi as usize).swap_remove(fi as usize);
                boxed(b, ft)
            }
            _ => panic!("mir: no member {sel:?} of {}", self.show_ty(t)),
        }
    }
}
