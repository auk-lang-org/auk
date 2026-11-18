//! User-level FFI (docs/ffi-plan.md): a package that declares the `ffi` effect may write
//! `extern fn f(..): T = "<C prototype>"` and `extern type T = "<C pointer type>"`.
//!
//! This module parses C prototypes and C types, and matches each Auk parameter and result type
//! against its C type (E0040 when they don't fit). The match is a `Conv`, which tells lowering
//! (`mir/lower/ffi.rs`) how to marshal the value across the call.

use crate::types::Ty;

/// A C type, as far as the FFI understands one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CTy {
    Void,
    Bool,
    /// An integer of `bytes` bytes. `chr`: spelled with `char` (a `char *` may be a string).
    Int { bytes: u8, signed: bool, chr: bool },
    F32,
    F64,
    /// A pointer; `konst`: the pointee is `const`.
    Ptr { to: Box<CTy>, konst: bool },
    /// A type name the FFI doesn't know (a typedef, or `struct X`): only usable by value when an
    /// `extern type` declares it as an opaque pointer, or behind a `*`.
    Named(String),
}

impl CTy {
    pub fn is_ptr(&self) -> bool {
        matches!(self, CTy::Ptr { .. })
    }

    /// `char *` / `const char *` (any signedness).
    pub fn is_char_ptr(&self) -> bool {
        matches!(self, CTy::Ptr { to, .. } if matches!(**to, CTy::Int { bytes: 1, chr: true, .. }))
    }

    /// The same type, ignoring `const` (and `struct`/`signed` spellings).
    pub fn same(&self, o: &CTy) -> bool {
        match (self, o) {
            (CTy::Ptr { to: a, .. }, CTy::Ptr { to: b, .. }) => a.same(b),
            (CTy::Int { bytes: a, signed: s, .. }, CTy::Int { bytes: b, signed: t, .. }) => a == b && s == t,
            _ => self == o,
        }
    }

    /// The C spelling, for messages.
    pub fn show(&self) -> String {
        match self {
            CTy::Void => "void".into(),
            CTy::Bool => "bool".into(),
            CTy::Int { bytes, signed, chr } => match (bytes, signed, chr) {
                // plain `char` is this target's signedness (unsigned on Linux arm64)
                (1, s, true) if *s == char_signed() => "char".into(),
                (1, true, true) => "signed char".into(),
                (1, false, true) => "unsigned char".into(),
                (1, true, _) => "int8_t".into(),
                (1, false, _) => "uint8_t".into(),
                (2, true, _) => "short".into(),
                (2, false, _) => "unsigned short".into(),
                (4, true, _) => "int".into(),
                (4, false, _) => "unsigned".into(),
                (_, true, _) => "int64_t".into(),
                (_, false, _) => "uint64_t".into(),
            },
            CTy::F32 => "float".into(),
            CTy::F64 => "double".into(),
            CTy::Ptr { to, konst } => {
                let inner = to.show();
                let c = if *konst { "const " } else { "" };
                if inner.ends_with('*') { format!("{c}{inner}*") } else { format!("{c}{inner} *") }
            }
            CTy::Named(n) => n.clone(),
        }
    }
}

/// A parsed C prototype.
#[derive(Debug, Clone, PartialEq)]
pub struct CSig {
    /// The C function's symbol.
    pub name: String,
    pub ret: CTy,
    pub params: Vec<CTy>,
    /// `+free(fn)`: the function that frees the `char *` strings this function hands over
    /// (its result, or a `char **` out-parameter); they are copied to Auk strings first.
    pub free: Option<String>,
    /// A call through a function pointer (`"int64_t (*)(int64_t, int64_t)"`): `params[0]` is the
    /// function's address (`void *`, an Auk `ffi.Ptr`), the rest are the C function's parameters.
    pub indirect: bool,
}

// ---- parsing ------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Word(String),
    Star,
    LParen,
    RParen,
    Comma,
    LBrack,
    RBrack,
    Dots,
    Num,
}

fn lex(s: &str) -> Result<Vec<Tok>, String> {
    let cs: Vec<char> = s.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i];
        if c.is_whitespace() {
            i += 1;
            continue;
        }
        if c.is_ascii_alphabetic() || c == '_' {
            let st = i;
            while i < cs.len() && (cs[i].is_ascii_alphanumeric() || cs[i] == '_') {
                i += 1;
            }
            out.push(Tok::Word(cs[st..i].iter().collect()));
            continue;
        }
        if c.is_ascii_digit() {
            while i < cs.len() && cs[i].is_ascii_alphanumeric() {
                i += 1;
            }
            out.push(Tok::Num);
            continue;
        }
        if s[cs[..i].iter().map(|c| c.len_utf8()).sum::<usize>()..].starts_with("...") {
            out.push(Tok::Dots);
            i += 3;
            continue;
        }
        out.push(match c {
            '*' => Tok::Star,
            '(' => Tok::LParen,
            ')' => Tok::RParen,
            ',' => Tok::Comma,
            '[' => Tok::LBrack,
            ']' => Tok::RBrack,
            _ => return Err(format!("unexpected `{c}` in the C prototype")),
        });
        i += 1;
    }
    Ok(out)
}

const QUALIFIERS: &[&str] = &["const", "volatile", "restrict", "__restrict", "__restrict__", "_Nonnull", "_Nullable", "__nonnull", "extern", "static", "inline"];

/// A fixed-width or system integer typedef: (bytes, signed).
fn int_typedef(w: &str) -> Option<(u8, bool)> {
    Some(match w {
        "int8_t" => (1, true),
        "uint8_t" => (1, false),
        "int16_t" => (2, true),
        "uint16_t" => (2, false),
        "int32_t" => (4, true),
        "uint32_t" => (4, false),
        "int64_t" | "ssize_t" | "ptrdiff_t" | "intptr_t" | "off_t" | "intmax_t" => (8, true),
        "uint64_t" | "size_t" | "uintptr_t" | "uintmax_t" => (8, false),
        _ => return None,
    })
}

/// Is plain `char` signed on this target?
fn char_signed() -> bool {
    !(cfg!(target_os = "linux") && (cfg!(target_arch = "aarch64") || cfg!(target_arch = "arm")))
}

struct P {
    toks: Vec<Tok>,
    pos: usize,
}

impl P {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos)
    }

    fn word(&self) -> Option<&str> {
        match self.peek() {
            Some(Tok::Word(w)) => Some(w),
            _ => None,
        }
    }

    /// Declaration specifiers, pointers and an optional declarator name: (type, name).
    fn decl(&mut self, what: &str, top: bool) -> Result<(CTy, Option<String>), String> {
        let mut konst = false;
        let mut words: Vec<String> = Vec::new();
        let mut named: Option<String> = None;
        let mut name = None;
        while let Some(w) = self.word().map(str::to_string) {
            if w == "const" {
                konst = true;
                self.pos += 1;
                continue;
            }
            if QUALIFIERS.contains(&w.as_str()) {
                self.pos += 1;
                continue;
            }
            if matches!(w.as_str(), "struct" | "union" | "enum") {
                self.pos += 1;
                let Some(tag) = self.word().map(str::to_string) else { return Err(format!("`{w}` needs a name in {what}")) };
                self.pos += 1;
                if w == "enum" {
                    words.push("int".into());
                } else {
                    named = Some(tag);
                }
                continue;
            }
            let is_kw = matches!(w.as_str(), "void" | "bool" | "_Bool" | "char" | "short" | "int" | "long" | "signed" | "unsigned" | "float" | "double");
            let have_base = !words.is_empty() || named.is_some();
            if is_kw {
                words.push(w);
                self.pos += 1;
            } else if !have_base {
                named = Some(w);
                self.pos += 1;
            } else {
                break;
            }
        }
        let mut ty = match named {
            Some(n) if words.is_empty() => match int_typedef(&n) {
                Some((bytes, signed)) => CTy::Int { bytes, signed, chr: false },
                None => CTy::Named(n),
            },
            Some(n) => return Err(format!("`{n}` can't be combined with `{}` in {what}", words.join(" "))),
            None if words.is_empty() => return Err(format!("expected a C type in {what}")),
            None => base_type(&words).ok_or_else(|| format!("`{}` is not a C type the FFI supports", words.join(" ")))?,
        };
        while self.peek() == Some(&Tok::Star) {
            self.pos += 1;
            ty = CTy::Ptr { to: Box::new(ty), konst };
            konst = false;
            while let Some(w) = self.word() {
                if w == "const" {
                    konst = true;
                } else if !QUALIFIERS.contains(&w) {
                    break;
                }
                self.pos += 1;
            }
        }
        if let Some(w) = self.word() {
            name = Some(w.to_string());
            self.pos += 1;
        }
        if !top && self.peek() == Some(&Tok::LParen) {
            return Err("function pointers (callbacks from C into Auk) aren't supported".into());
        }
        while self.peek() == Some(&Tok::LBrack) {
            self.pos += 1;
            while matches!(self.peek(), Some(Tok::Num | Tok::Word(_))) {
                self.pos += 1;
            }
            if self.peek() != Some(&Tok::RBrack) {
                return Err(format!("expected `]` in {what}"));
            }
            self.pos += 1;
            ty = CTy::Ptr { to: Box::new(ty), konst };
        }
        Ok((ty, name))
    }
}

fn base_type(words: &[String]) -> Option<CTy> {
    let has = |w: &str| words.iter().any(|x| x == w);
    let count = |w: &str| words.iter().filter(|x| *x == w).count();
    let unsigned = has("unsigned");
    let int = |bytes: u8| CTy::Int { bytes, signed: !unsigned, chr: false };
    let rest: Vec<&str> = words.iter().map(String::as_str).filter(|w| !matches!(*w, "signed" | "unsigned" | "int")).collect();
    Some(match rest.as_slice() {
        ["void"] if words.len() == 1 => CTy::Void,
        ["bool"] | ["_Bool"] if words.len() == 1 => CTy::Bool,
        ["float"] if words.len() == 1 => CTy::F32,
        ["double"] if words.len() == 1 => CTy::F64,
        ["char"] if !has("int") => {
            let signed = if unsigned {
                false
            } else if has("signed") {
                true
            } else {
                char_signed()
            };
            CTy::Int { bytes: 1, signed, chr: true }
        }
        ["short"] => int(2),
        [] => int(4),
        ["long"] => int(8),
        ["long", "long"] if count("long") == 2 => int(8),
        _ => return None,
    })
}

/// Parse an `extern type`'s C spelling: a pointer type (`sqlite3 *`) or a typedef name for one
/// (`LLVMModuleRef`).
pub fn parse_type(s: &str) -> Result<CTy, String> {
    let mut p = P { toks: lex(s)?, pos: 0 };
    let (t, name) = p.decl("the C type", false)?;
    if name.is_some() || p.pos < p.toks.len() {
        return Err(format!("`{s}` is not a single C type"));
    }
    Ok(t)
}

/// Parse `"<C prototype>"`, with an optional ` +free(fn)` suffix.
pub fn parse_proto(src: &str) -> Result<CSig, String> {
    let (proto, free) = match src.find("+free") {
        Some(i) => {
            let rest = src[i + "+free".len()..].trim();
            let inner = rest.strip_prefix('(').and_then(|r| r.strip_suffix(')')).map(str::trim);
            match inner {
                Some(f) if !f.is_empty() && f.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') => (&src[..i], Some(f.to_string())),
                _ => return Err("expected `+free(function)` after the prototype".into()),
            }
        }
        None => (src, None),
    };
    let toks = lex(proto.trim().trim_end_matches(';'))?;
    let mut p = P { toks, pos: 0 };
    let (ret, name) = p.decl("the result type", true)?;
    // `T (*)(params)`: a call through the function pointer passed first
    let indirect = name.is_none() && p.toks.get(p.pos..p.pos + 3) == Some(&[Tok::LParen, Tok::Star, Tok::RParen][..]);
    if indirect {
        p.pos += 3;
    }
    let name = if indirect { Some("(*)".to_string()) } else { name };
    let Some(name) = name else {
        return Err("expected a C prototype like \"int abs(int)\" (the result type, the C function's name, its parameter types)".into());
    };
    if p.peek() != Some(&Tok::LParen) {
        return Err(format!("expected `(` after `{name}`"));
    }
    p.pos += 1;
    let mut params = Vec::new();
    if indirect {
        params.push(CTy::Ptr { to: Box::new(CTy::Void), konst: false });
    }
    if p.peek() == Some(&Tok::RParen) || (p.word() == Some("void") && p.toks.get(p.pos + 1) == Some(&Tok::RParen)) {
        if p.peek() != Some(&Tok::RParen) {
            p.pos += 1;
        }
    } else {
        loop {
            if p.peek() == Some(&Tok::Dots) {
                return Err("variadic C functions (`...`) aren't supported".into());
            }
            let (t, _) = p.decl(&format!("parameter {}", params.len() + 1), false)?;
            if t == CTy::Void {
                return Err("a parameter can't be `void`".into());
            }
            params.push(t);
            match p.peek() {
                Some(Tok::Comma) => p.pos += 1,
                Some(Tok::RParen) => break,
                _ => return Err(format!("expected `,` or `)` after parameter {}", params.len())),
            }
        }
    }
    if p.peek() != Some(&Tok::RParen) {
        return Err("expected `)` to end the parameter list".into());
    }
    p.pos += 1;
    if p.pos < p.toks.len() {
        return Err("unexpected text after the prototype".into());
    }
    Ok(CSig { name, ret, params, free, indirect })
}

// ---- matching Auk types to C types ----------------------------------------------------------

/// How a list's elements are laid out in the C array (the runtime's `AUK_FFI_*` kinds).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Elem {
    /// The same bytes as the Auk element (`int64_t`, `double`, `bool`, pointers).
    Raw = 0,
    I8 = 1,
    U8 = 2,
    I16 = 3,
    U16 = 4,
    I32 = 5,
    U32 = 6,
    F32 = 7,
}

/// How one value crosses the call.
#[derive(Debug, Clone, PartialEq)]
pub enum Conv {
    /// `int` ↔ a C integer.
    Int { bytes: u8, signed: bool },
    Bool,
    /// `float` ↔ `double` (`f32`: `float`).
    Float { f32: bool },
    /// `str` ↔ `const char *` (a result: copied; `owned`: freed after with `+free`).
    Str { owned: bool },
    /// `str?` ↔ `const char *`, `none` ↔ NULL.
    OptStr { owned: bool },
    /// An opaque pointer (`ffi.Ptr` or an `extern type`).
    Ptr,
    /// `T?` of an opaque pointer, `none` ↔ NULL.
    OptPtr,
    /// `()` ↔ `void` (results).
    Unit,
    /// `[T]` ↔ `T *`: a temporary C array of the elements (`var`: copied back after the call).
    List { elem: Elem, back: bool },
    /// `var T` ↔ `T *`: the address of a temporary holding the C value, written back after.
    Out(Box<Conv>),
}

/// What an Auk type is to the FFI, when it's an opaque pointer: `None` for `ffi.Ptr` (any
/// pointer), or the `extern type`'s C type.
pub type PtrOf<'a> = &'a dyn Fn(&Ty) -> Option<Option<CTy>>;

fn int_elem(bytes: u8, signed: bool) -> Elem {
    match (bytes, signed) {
        (1, true) => Elem::I8,
        (1, false) => Elem::U8,
        (2, true) => Elem::I16,
        (2, false) => Elem::U16,
        (4, true) => Elem::I32,
        (4, false) => Elem::U32,
        _ => Elem::Raw,
    }
}

/// Does C type `c` fit the opaque pointer type described by `p`?
fn ptr_fits(p: &Option<CTy>, c: &CTy) -> bool {
    match p {
        None => c.is_ptr(),
        Some(want) => want.same(c),
    }
}

/// The help for a C type that no Auk type fits.
fn hint(c: &CTy) -> String {
    match c {
        CTy::Named(n) => format!(
            "`{n}` is a C type name the FFI doesn't know: write its underlying type (an integer typedef as `int`, `unsigned`, ...; a pointer as `T *`), or declare an opaque pointer type `extern type {} = \"{n}\"`",
            n.trim_end_matches("Ref")
        ),
        CTy::Int { .. } => "C integers are `int` in Auk".into(),
        CTy::Bool => "C `bool` is `bool` in Auk".into(),
        CTy::F32 | CTy::F64 => "C `float` and `double` are `float` in Auk".into(),
        CTy::Void => "`void` is `()` in Auk (no result type)".into(),
        CTy::Ptr { konst, .. } if c.is_char_ptr() => {
            if *konst {
                "`const char *` is `str` (or `str?`); other pointers are `ffi.Ptr` or an `extern type`".into()
            } else {
                "a `char *` parameter may be written by C: pass a byte buffer (`[int]`) or an `ffi.Ptr`; `str` goes as `const char *`".into()
            }
        }
        CTy::Ptr { .. } => "pointers are `ffi.Ptr` (or an `extern type`); `T *` for a list `[T]`; a `var` parameter for an out-parameter".into(),
    }
}

/// Match Auk type `t` (a `var` parameter when `var`) with C type `c`. `ret`: it's the result.
/// `free`: the prototype has `+free(fn)`. Err: why it doesn't fit (a note for E0040).
pub fn conv(t: &Ty, var: bool, c: &CTy, ret: bool, free: bool, ptr_of: PtrOf) -> Result<Conv, String> {
    if var {
        let CTy::Ptr { to, .. } = c else {
            return Err(format!("a `var` parameter is an out-parameter: its C type is a pointer (`{} *`)", c.show()));
        };
        if let Ty::List(_) = t {
            return match conv(t, false, c, false, free, ptr_of)? {
                Conv::List { elem, .. } => Ok(Conv::List { elem, back: true }),
                _ => unreachable!(),
            };
        }
        if *t == Ty::Str {
            return Err("an out-parameter string is `var str?` (C may leave it NULL)".into());
        }
        let inner = match t {
            Ty::Opt(x) if **x == Ty::Str => {
                if !to.is_char_ptr() {
                    return Err(format!("`str?` goes with `char *`, not `{}`", to.show()));
                }
                Conv::OptStr { owned: free && !matches!(&**to, CTy::Ptr { konst: true, .. }) }
            }
            _ => conv(t, false, to, true, free, ptr_of)?,
        };
        return Ok(Conv::Out(Box::new(inner)));
    }
    let bad = || Err(hint(c));
    match t {
        Ty::Int => match c {
            CTy::Int { bytes, signed, .. } => Ok(Conv::Int { bytes: *bytes, signed: *signed }),
            _ => bad(),
        },
        Ty::Bool => match c {
            CTy::Bool => Ok(Conv::Bool),
            _ => bad(),
        },
        Ty::Float => match c {
            CTy::F32 => Ok(Conv::Float { f32: true }),
            CTy::F64 => Ok(Conv::Float { f32: false }),
            _ => bad(),
        },
        Ty::Str | Ty::Opt(_) if matches!(t, Ty::Str) || matches!(t, Ty::Opt(x) if **x == Ty::Str) => {
            let opt = *t != Ty::Str;
            let CTy::Ptr { konst, .. } = c else { return bad() };
            if !c.is_char_ptr() {
                return bad();
            }
            if !ret && !konst {
                return Err("a `str` parameter is `const char *` (C must not write to it); for a buffer C fills, pass `[int]` or an `ffi.Ptr`".into());
            }
            let owned = ret && free && !konst;
            Ok(if opt { Conv::OptStr { owned } } else { Conv::Str { owned } })
        }
        Ty::Opt(x) => match ptr_of(x) {
            Some(p) if ptr_fits(&p, c) => Ok(Conv::OptPtr),
            Some(_) => bad(),
            None => Err(format!("an optional (`T?`) crosses to C only as a pointer (`none` is NULL) or a `str?`; `{}` isn't one", c.show())),
        },
        Ty::List(e) => {
            if ret {
                return Err("a C function can't return a list: return an `ffi.Ptr` and read it with `ffi.bytes` / `read_*`".into());
            }
            let CTy::Ptr { to, .. } = c else { return Err(format!("a list `[T]` goes to C as a pointer to its first element, not `{}`", c.show())) };
            let elem = match (&**e, &**to) {
                (Ty::Int, CTy::Int { bytes, signed, .. }) => int_elem(*bytes, *signed),
                (Ty::Int, CTy::Void) => Elem::U8,
                (Ty::Float, CTy::F64) => Elem::Raw,
                (Ty::Float, CTy::F32) => Elem::F32,
                (Ty::Bool, CTy::Bool) => Elem::Raw,
                (e, to) => match ptr_of(e) {
                    Some(p) if ptr_fits(&p, to) => Elem::Raw,
                    _ => return Err(format!("a list `[T]` goes to C as `T *`; `{}` doesn't fit this element type ({})", to.show(), hint(to))),
                },
            };
            Ok(Conv::List { elem, back: false })
        }
        t if t.is_unit() => match c {
            CTy::Void if ret => Ok(Conv::Unit),
            _ => bad(),
        },
        _ => match ptr_of(t) {
            Some(p) if ptr_fits(&p, c) => Ok(Conv::Ptr),
            Some(Some(want)) => Err(format!("this type is the C type `{}`, not `{}`", want.show(), c.show())),
            Some(None) => Err(format!("`ffi.Ptr` is any C pointer (`T *`); `{}` isn't a pointer{}", c.show(), if let CTy::Named(_) = c { format!(" the FFI knows ({})", hint(c)) } else { String::new() })),
            None => Err("only `int`, `float`, `bool`, `str`, `str?`, lists of these, `ffi.Ptr`, `extern type`s, their optionals and `()` cross to C".into()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn i(bytes: u8, signed: bool) -> CTy {
        CTy::Int { bytes, signed, chr: false }
    }

    #[test]
    fn prototypes() {
        let s = parse_proto("int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs)").unwrap();
        assert_eq!(s.name, "sqlite3_open_v2");
        assert_eq!(s.ret, i(4, true));
        assert!(s.params[0].is_char_ptr());
        assert_eq!(s.params[1], CTy::Ptr { to: Box::new(CTy::Ptr { to: Box::new(CTy::Named("sqlite3".into())), konst: false }), konst: false });
        let s = parse_proto("const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);").unwrap();
        assert!(s.ret.is_char_ptr());
        assert_eq!(parse_proto("void f(void)").unwrap().params, vec![]);
        assert_eq!(parse_proto("unsigned long long f(unsigned, short int, size_t n, double)").unwrap().params, vec![i(4, false), i(2, true), i(8, false), CTy::F64]);
        let s = parse_proto("char *LLVMPrintModuleToString(LLVMModuleRef M) +free(LLVMDisposeMessage)").unwrap();
        assert_eq!(s.free.as_deref(), Some("LLVMDisposeMessage"));
        assert_eq!(s.params, vec![CTy::Named("LLVMModuleRef".into())]);
        assert_eq!(parse_proto("void f(int xs[], struct S *const *p)").unwrap().params[0], CTy::Ptr { to: Box::new(i(4, true)), konst: false });
        assert!(parse_proto("int printf(const char *, ...)").unwrap_err().contains("variadic"));
        assert!(parse_proto("void qsort(void *, size_t, size_t, int (*)(const void *, const void *))").unwrap_err().contains("callbacks"));
        assert!(parse_proto("abs").is_err());
        assert!(parse_proto("long double f(void)").is_err());
        assert_eq!(parse_type("LLVMModuleRef").unwrap(), CTy::Named("LLVMModuleRef".into()));
        let s = parse_proto("int64_t (*)(int64_t a, int64_t)").unwrap();
        assert!(s.indirect);
        assert_eq!(s.params, vec![CTy::Ptr { to: Box::new(CTy::Void), konst: false }, i(8, true), i(8, true)]);
        assert_eq!(parse_proto("void (*)(void)").unwrap().params.len(), 1);
        assert!(!parse_proto("int abs(int)").unwrap().indirect);
        assert!(parse_type("struct sqlite3 *").unwrap().same(&parse_type("sqlite3*").unwrap()));
    }
}
