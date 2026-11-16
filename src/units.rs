//! Units of measure: `3.0<m/s^2>`, `float<kg*m/s^2>`.
//!
//! A unit is a product of named base units with non-zero integer exponents, kept in canonical
//! form (sorted by name), so `m/s/s`, `m*s^-2` and `m/s^2` are the same value. Units are pure
//! names (no conversion factors) and are checked only: codegen erases them (`Ty::erase_units`).

use std::fmt;

/// A canonical unit: base names sorted, exponents non-zero. Empty means dimensionless.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
pub struct Units(pub Vec<(String, i32)>);

impl Units {
    pub fn is_none(&self) -> bool {
        self.0.is_empty()
    }

    /// Multiply (`k = 1`) or divide (`k = -1`) by `o`.
    pub fn combine(&self, o: &Units, k: i32) -> Units {
        let mut v = self.0.clone();
        for (n, e) in &o.0 {
            match v.iter_mut().find(|(m, _)| m == n) {
                Some(x) => x.1 += k * e,
                None => v.push((n.clone(), k * e)),
            }
        }
        Units::canon(v)
    }

    /// Raise to an integer power.
    pub fn pow(&self, k: i32) -> Units {
        Units::canon(self.0.iter().map(|(n, e)| (n.clone(), e * k)).collect())
    }

    /// The `k`-th root, when every exponent is divisible by `k`.
    pub fn root(&self, k: i32) -> Option<Units> {
        self.0.iter().all(|(_, e)| e % k == 0).then(|| Units(self.0.iter().map(|(n, e)| (n.clone(), e / k)).collect()))
    }

    fn canon(mut v: Vec<(String, i32)>) -> Units {
        v.retain(|(_, e)| *e != 0);
        v.sort();
        Units(v)
    }

    /// When `self` and `o` have the same base names and differ only in exponents, a phrase
    /// saying so (`m^2` vs `m`), for diagnostics.
    pub fn exponent_hint(&self, o: &Units) -> Option<String> {
        let names = |u: &Units| u.0.iter().map(|(n, _)| n.clone()).collect::<Vec<_>>();
        (names(self) == names(o) && self != o).then(|| "they differ only in an exponent".to_string())
    }
}

/// `kg*m/s^2`: positive exponents first (joined with `*`), then each negative one as `/u^n`;
/// `1/s` when nothing is positive; `1` when dimensionless.
impl fmt::Display for Units {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let pos: Vec<String> = self.0.iter().filter(|(_, e)| *e > 0).map(|(n, e)| power(n, *e)).collect();
        let neg: Vec<String> = self.0.iter().filter(|(_, e)| *e < 0).map(|(n, e)| power(n, -e)).collect();
        if pos.is_empty() {
            f.write_str("1")?;
        } else {
            f.write_str(&pos.join("*"))?;
        }
        for n in neg {
            write!(f, "/{n}")?;
        }
        Ok(())
    }
}

fn power(n: &str, e: i32) -> String {
    if e == 1 { n.to_string() } else { format!("{n}^{e}") }
}

/// Parse the text between `<` and `>`: names or `1`, joined by `*` and `/` (left to right),
/// each optionally raised to an integer power `^n` (`n` may be negative).
pub fn parse(src: &str) -> Result<Units, String> {
    let mut toks: Vec<String> = Vec::new();
    let cs: Vec<char> = src.chars().collect();
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i];
        if c == ' ' {
            i += 1;
        } else if c.is_alphanumeric() || c == '_' {
            let s: String = cs[i..].iter().take_while(|c| c.is_alphanumeric() || **c == '_').collect();
            i += s.chars().count();
            toks.push(s);
        } else {
            toks.push(c.to_string());
            i += 1;
        }
    }
    if toks.is_empty() {
        return Err("the unit is empty".into());
    }
    let mut v: Vec<(String, i32)> = Vec::new();
    let mut sign = 1;
    let mut k = 0;
    loop {
        let Some(t) = toks.get(k) else { return Err("the unit ends after an operator".into()) };
        k += 1;
        let name = if t == "1" {
            None
        } else if t.starts_with(|c: char| c.is_alphabetic() || c == '_') {
            Some(t.clone())
        } else {
            return Err(format!("expected a unit name or `1`, found `{t}`"));
        };
        let mut e = 1;
        if toks.get(k).is_some_and(|t| t == "^") {
            k += 1;
            let neg = toks.get(k).is_some_and(|t| t == "-");
            if neg {
                k += 1;
            }
            let n: i32 = toks.get(k).and_then(|t| t.parse().ok()).ok_or("`^` needs an integer exponent, like `s^2` or `s^-1`")?;
            k += 1;
            e = if neg { -n } else { n };
        }
        if let Some(n) = name {
            v.push((n, sign * e));
        }
        match toks.get(k).map(String::as_str) {
            None => break,
            Some("*") => sign = 1,
            Some("/") => sign = -1,
            Some(t) => return Err(format!("unexpected `{t}` in a unit (units use names, `*`, `/` and `^n`)")),
        }
        k += 1;
    }
    Ok(Units::default().combine(&Units(v), 1))
}

/// Remove every unit of measure from a checked program, so codegen only sees plain `int` and
/// `float` (units cost nothing at run time). `check::check` calls it; the language server
/// keeps the units for hovers.
pub fn erase(tp: &mut crate::typed::TypedProgram) {
    use crate::typed::{Callee, ErrConv, FailKind, NameRef, Target};
    use crate::types::TypeDefKind;
    fn e(t: &mut crate::types::Ty) {
        if t.has_units() {
            *t = t.erase_units();
        }
    }
    fn all(ts: &mut [crate::types::Ty]) {
        ts.iter_mut().for_each(e);
    }
    fn callee(c: &mut Callee) {
        match c {
            Callee::Fn { type_args, .. } => all(type_args),
            Callee::Variant(v) => all(&mut v.args),
            Callee::Shape { self_ty, .. } => e(self_ty),
            _ => {}
        }
    }
    fn target(t: &mut Target) {
        if let Target::Intrinsic { ty, .. } | Target::Derived { ty, .. } = t {
            e(ty);
        }
    }
    for d in &mut tp.defs.types {
        match &mut d.kind {
            TypeDefKind::Struct { fields } => fields.iter_mut().for_each(|f| e(&mut f.ty)),
            TypeDefKind::Enum { variants } => variants.iter_mut().for_each(|v| v.fields.iter_mut().for_each(|(_, t)| e(t))),
            TypeDefKind::Opaque { .. } => {}
        }
    }
    for s in &mut tp.defs.shapes {
        for m in &mut s.methods {
            all(&mut m.params);
            e(&mut m.ret);
        }
    }
    for f in &mut tp.fns {
        f.params.iter_mut().for_each(|p| e(&mut p.ty));
        e(&mut f.ret);
    }
    tp.consts.iter_mut().for_each(|c| e(&mut c.ty));
    for t in &mut tp.tables {
        t.types.values_mut().for_each(e);
        t.locals.iter_mut().for_each(|l| e(&mut l.ty));
        t.variants.values_mut().for_each(|v| all(&mut v.args));
        t.calls.values_mut().for_each(|c| callee(&mut c.callee));
        t.shows.values_mut().for_each(callee);
        for n in t.names.values_mut() {
            match n {
                NameRef::Fn { type_args, .. } => all(type_args),
                NameRef::Variant(v) => all(&mut v.args),
                _ => {}
            }
        }
        t.struct_lits.values_mut().for_each(|s| all(&mut s.args));
        for c in t.closures.values_mut() {
            all(&mut c.params);
            e(&mut c.ret);
        }
        for f in t.fails.values_mut() {
            if let FailKind::TypedToErr(x) = f {
                e(x);
            }
        }
        for tr in t.tries.values_mut() {
            if let ErrConv::ToErr { from } = &mut tr.conv {
                e(from);
            }
        }
        t.err_payload_pats.values_mut().for_each(e);
    }
    for i in &mut tp.instances {
        all(&mut i.type_args);
        i.resolved.values_mut().for_each(target);
        i.shows.values_mut().for_each(target);
    }
    tp.types_used = std::mem::take(&mut tp.types_used).into_iter().map(|t| t.erase_units()).collect();
    tp.shape_impls = std::mem::take(&mut tp.shape_impls)
        .into_iter()
        .map(|((b, t), mut v)| {
            target(&mut v);
            ((b, t.erase_units()), v)
        })
        .collect();
    tp.from_value_impls = std::mem::take(&mut tp.from_value_impls)
        .into_iter()
        .map(|(t, mut v)| {
            target(&mut v);
            (t.erase_units(), v)
        })
        .collect();
    for v in &mut tp.vtables {
        e(&mut v.ty);
        v.methods.iter_mut().for_each(target);
    }
    if let Some(m) = &mut tp.main {
        e(&mut m.ret);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn show(s: &str) -> String {
        parse(s).map(|u| u.to_string()).unwrap_or_else(|e| format!("error: {e}"))
    }

    #[test]
    fn canonical() {
        assert_eq!(show("m/s/s"), "m/s^2");
        assert_eq!(show("m*s^-2"), "m/s^2");
        assert_eq!(show("m*kg/s^2"), "kg*m/s^2");
        assert_eq!(show("1/s"), "1/s");
        assert_eq!(show("m/m"), "1");
        assert_eq!(show(" m / s "), "m/s");
        assert!(parse("m/m").unwrap().is_none());
    }

    #[test]
    fn malformed() {
        assert!(show("").starts_with("error"));
        assert!(show("m*").starts_with("error"));
        assert!(show("m^x").starts_with("error"));
        assert!(show("2").starts_with("error"));
        assert!(show("m-s").starts_with("error"));
    }
}
