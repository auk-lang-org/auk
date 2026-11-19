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
  types.variants(info.defs, d).map(
    v => v.fields.map(f => {
      let ft = types.subst(f.1, s)
      var seen: {types.Ty: bool} = {}
      let boxed = !value && reaches(info, ft, t, &seen)
      (ft, boxed)
    }),
  )
}

/// Can a value of type `t` reach a handle (a task, connection, listener, channel or frame),
/// whose release does more than free memory (a task's waits for it)? Conservative: closures,
/// `any`, errors and every opaque type may.
pub fn may_hold_handle(info: TyInfo, t: types.Ty, seen: var {types.Ty: bool}): bool {
  if seen.contains(t) { return false }
  seen[t] = true
  match t {
    Int | Float | Bool | Char | Str | Never | Fixed(_) | Ptr(_) | CFn(_, _) | Measured(_, _) => false
    List(x) | Opt(x) => may_hold_handle(info, x, &seen)
    Map(k, v) => may_hold_handle(info, k, &seen) || may_hold_handle(info, v, &seen)
    Tuple(ts) => {
      for x in ts {
        if may_hold_handle(info, x, &seen) { return true }
      }
      false
    }
    Named(d, args) => {
      if some(d) == info.value_def { return false }
      let s = types.subst_of(info.defs, d, args)
      match info.defs.types[d].kind {
        Struct(fields) => {
          for f in fields {
            if may_hold_handle(info, types.subst(f.ty, s), &seen) { return true }
          }
          false
        }
        Enum(variants) => {
          for v in variants {
            for f in v.fields {
              if may_hold_handle(info, types.subst(f.1, s), &seen) { return true }
            }
          }
          false
        }
        _ => true
      }
    }
    _ => true
  }
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
  // a fixed array of the runtime's dialect (element `i`, in a constant initializer)
  (Array(x, _), F(_)) => mir.MTy.D(x)
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

// ---- for lowering (the parts of src/mir/types.rs the reader doesn't need) ----

/// `TyInfo::new`: the type facts of a typed program.
pub fn new(tp: typed.TypedProgram): TyInfo {
  var value_def: int? = none
  var err_def: int? = none
  for i, d in tp.defs.types {
    if value_def == none && d.name == "Value" && resolve.is_core(tp.program, d.module) &&
      d.kind is types.TypeDefKind.Enum(_) {
      value_def = some(i)
    }
    if err_def == none && d.name == "Err" && d.kind is types.TypeDefKind.Opaque(_) { err_def = some(i) }
  }
  TyInfo { defs: tp.defs, value_def, err_def: err_def else 0 }
}

/// Is it a C pointer type (`ffi.Ptr`, or a user `extern type`)? A plain address: no
/// reference count.
pub fn is_foreign(info: TyInfo, t: types.Ty): bool = match opaque_c(info, t) {
  some(c) => !c.starts_with("Auk")
  none => false
}

/// Is it an opaque type the runtime changes in place, copying it first when shared (a
/// `pixels.Frame`)? An extern's `var` parameter of such a type gets the variable's address,
/// as lists and maps do, so the runtime can swap in the copy. Other opaque types are handles
/// (`net.Conn`): a `var` one is passed by value.
pub fn is_cow_opaque(info: TyInfo, t: types.Ty): bool = opaque_c(info, t) == some("AukFrame *")

/// Does a value of this type hold references? `rc` is the memo (Rust's `RefCell` in `TyInfo`):
/// a struct or enum is `false` there while its fields are looked at.
pub fn needs_rc(info: TyInfo, rc: var {types.Ty: bool}, t: types.Ty): bool {
  match rc.get(t) {
    some(b) => return b
    none => {}
  }
  let b = match t {
    Int | Float | Bool | Char | Never => false
    Str | List(_) | Map(_, _) | Task(_) | Fn(_, _) | Any(_) => true
    Tuple(ts) => {
      rc[t] = false
      var any = false
      for x in ts {
        if needs_rc(info, &rc, x) {
          any = true
          break
        }
      }
      any
    }
    Opt(x) => needs_rc(info, &rc, x)
    Res(_, _) => true
    Named(d, _) => {
      if some(d) == info.value_def {
        true
      } else {
        match info.defs.types[d].kind {
          Opaque(c) => c.starts_with("Auk")
          Struct(_) => {
            let layout = struct_layout(info, t)
            rc[t] = false
            var any = false
            for (ft, boxed) in layout {
              if boxed || needs_rc(info, &rc, ft) {
                any = true
                break
              }
            }
            any
          }
          Enum(_) => {
            let layout = enum_layout(info, t)
            rc[t] = false
            var any = false
            for fs in layout {
              for (ft, boxed) in fs {
                if !any && (boxed || needs_rc(info, &rc, ft)) { any = true }
              }
              if any { break }
            }
            any
          }
        }
      }
    }
    _ => false
  }
  rc[t] = b
  b
}

/// A shape method's parameter or return type, with `Self` (unsupported for `any`) as `()`.
pub fn method_ty(info: TyInfo, t: types.Ty, s: int): types.Ty {
  let sp = info.defs.shapes[s].self_param
  types.map_ty(t, x => if x == types.Ty.Param(sp) { types.unit() } else { x })
}
