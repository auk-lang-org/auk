/// How Auk types are represented (src/mir/types.rs, the parts the back end and the MIR printer
/// use): which values are pointers, which struct and variant fields are boxed, and the members
/// (`Sel`) of each aggregate.
///
/// Representations (the C names are the runtime's types, runtime/c/auk_rt.h):
/// - `int float bool char` → i64, f64, bool (1 byte), u32; `()` and `never` → a byte.
/// - `str`, `[T]`, `{K: V}`, `Task<T>` and opaque runtime types → pointers to runtime objects.
/// - tuple → members `F(i)`; struct → `F(i)` per field (a boxed field is a `AukObj *` cell
///   holding the value); enum (and core `Value`) → `Tag` (i32) plus a union of variants, field
///   `fi` of variant `vi` is `V(vi, fi)` (boxed like struct fields; never boxed in `Value`).
/// - `T?` → `F(0)` some (bool), `F(1)` val; `T!` / `T!E` → `F(0)` ok (bool), `F(1)` val,
///   `F(2)` err (`AukErr *`; a typed `E` travels as the error's payload).
/// - closure → `F(0)` code pointer, `F(1)` environment (`AukObj *` or NULL).
/// - `any S` → `F(0)` the boxed value (`AukObj *`), `F(1)` its vtable.
///
/// Rust's `TyInfo` wraps the typed program; here it holds the type definitions the MIR dump
/// carries (`mir.reader`), with `value_def` and `err_def` as the Rust compiler computed them.

pub struct TyInfo { defs: types.Defs, value_def: int?, err_def: int }

pub fn is_value(info: TyInfo, t: types.Ty): bool = match t {
  Named(d, _) => some(d) == info.value_def
  _ => false
}

pub fn is_err_ty(info: TyInfo, t: types.Ty): bool = types.is_err(info.defs, t)

pub fn err_ty(info: TyInfo): types.Ty = types.Ty.Named(info.err_def, [])

pub fn is_opaque(info: TyInfo, t: types.Ty): bool = match t {
  Named(d, _) => info.defs.types[d].kind is types.TypeDefKind.Opaque(_)
  _ => false
}

/// The opaque type's runtime C spelling (`AukErr *`, `AukConn *`).
pub fn opaque_c(info: TyInfo, t: types.Ty): str? = match t {
  Named(d, _) => match info.defs.types[d].kind {
    Opaque(c) => c
    _ => none
  }
  _ => none
}

pub fn show_ty(info: TyInfo, t: types.Ty): str = types.show(info.defs, t)

/// Is the value a pointer to a runtime object (`str`, lists, maps, tasks, opaque types)?
pub fn is_ptr(info: TyInfo, t: types.Ty): bool = match t {
  Str | List(_) | Map(_, _) | Task(_) => true
  _ => is_opaque(info, t)
}

/// Is the value a scalar (one machine word or less, no members)?
pub fn is_scalar(info: TyInfo, t: types.Ty): bool = match t {
  Int | Float | Bool | Char | Never => true
  _ => types.is_unit(t) || is_ptr(info, t)
}

/// Per struct field: its type (substituted) and whether it is boxed (a field whose type
/// contains the struct itself by value, like `boss: User?`).
pub fn struct_layout(info: TyInfo, t: types.Ty): [(types.Ty, bool)] {
  let (d, args) = match t {
    Named(d, args) => (d, args)
    _ => return []
  }
  let s = types.subst_of(info.defs, d, args)
  types.fields(info.defs, d).map(f => {
    let ft = types.subst(f.ty, s)
    var seen: {types.Ty: bool} = {}
    let boxed = reaches(info, ft, t, &seen)
    (ft, boxed)
  })
}

/// Per variant, the field types (substituted) and whether each is boxed.
pub fn enum_layout(info: TyInfo, t: types.Ty): [[(types.Ty, bool)]] {
  let (d, args) = match t {
    Named(d, args) => (d, args)
    _ => return []
  }
  let s = types.subst_of(info.defs, d, args)
  let value = some(d) == info.value_def
  types.variants(info.defs, d).map(v => v.fields.map(f => {
    let ft = types.subst(f.1, s)
    var seen: {types.Ty: bool} = {}
    let boxed = !value && reaches(info, ft, t, &seen)
    (ft, boxed)
  }))
}

/// Does `t` contain `target` by value (through tuples, optionals, results, structs, enums)?
fn reaches(info: TyInfo, t: types.Ty, target: types.Ty, seen: var {types.Ty: bool}): bool {
  if t == target { return true }
  if seen.contains(t) { return false }
  seen[t] = true
  match t {
    Tuple(ts) => {
      for x in ts {
        if reaches(info, x, target, &seen) { return true }
      }
      false
    }
    Opt(x) => reaches(info, x, target, &seen)
    Res(x, _) => reaches(info, x, target, &seen)
    Named(d, args) => {
      if some(d) == info.value_def { return false }
      let s = types.subst_of(info.defs, d, args)
      match info.defs.types[d].kind {
        Struct(fields) => {
          for f in fields {
            if reaches(info, types.subst(f.ty, s), target, &seen) { return true }
          }
          false
        }
        Enum(variants) => {
          for v in variants {
            for f in v.fields {
              if reaches(info, types.subst(f.1, s), target, &seen) { return true }
            }
          }
          false
        }
        _ => false
      }
    }
    _ => false
  }
}

pub fn is_struct(info: TyInfo, t: types.Ty): bool = match t {
  Named(d, _) => types.is_struct(info.defs, d)
  _ => false
}

/// The type of member `sel` of a value of type `t`.
pub fn member_ty(info: TyInfo, t: mir.MTy, sel: mir.Sel, aggs: [mir.AggDef]): mir.MTy = match (
  t,
  sel,
) {
  (Agg(a), F(i)) => aggs[a].fields[i]
  (D(d), sel) => d_member_ty(info, d, sel)
  _ => mir.bug("mir: no member {sel} of {t}")
}

fn boxed_ty(b: bool, ft: types.Ty): mir.MTy = if b { mir.obj_ptr() } else { mir.MTy.D(ft) }

fn d_member_ty(info: TyInfo, t: types.Ty, sel: mir.Sel): mir.MTy = match (t, sel) {
  (Tuple(ts), F(i)) => mir.MTy.D(ts[i])
  (Opt(_), F(0)) | (Res(_, _), F(0)) => mir.MTy.Bool
  (Opt(x), F(1)) | (Res(x, _), F(1)) => mir.MTy.D(x)
  (Res(_, _), F(2)) => mir.MTy.D(err_ty(info))
  (Fn(_, _), F(0)) => mir.MTy.Code
  (Fn(_, _), F(1)) | (Any(_), F(0)) => mir.obj_ptr()
  (Any(_), F(1)) => mir.void_ptr()
  (Named(_, _), F(i)) when is_struct(info, t) => {
    let (ft, b) = struct_layout(info, t)[i]
    boxed_ty(b, ft)
  }
  (Named(_, _), Tag) => mir.MTy.I32
  (Named(_, _), V(vi, fi)) => {
    let (ft, b) = enum_layout(info, t)[vi][fi]
    boxed_ty(b, ft)
  }
  _ => mir.bug("mir: no member {sel} of {show_ty(info, t)}")
}
