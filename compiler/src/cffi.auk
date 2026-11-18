/// User-level FFI (src/ffi.rs): parse C prototypes and C types, and match each Auk parameter and
/// result type against its C type (E0040 when they don't fit). The match is a `Conv`, which
/// tells lowering how to marshal the value across the call. (Named `cffi` because a module of
/// this package called `ffi` would hide core's `ffi` module.)

/// A C type, as far as the FFI understands one.
pub enum CTy {
  Void,
  Bool,
  /// An integer of `bytes` bytes. `chr`: spelled with `char` (a `char *` may be a string).
  Int(bytes: int, signed: bool, chr: bool),
  F32,
  F64,
  /// A pointer; `konst`: the pointee is `const`.
  Ptr(to: CTy, konst: bool),
  /// A type name the FFI doesn't know (a typedef, or `struct X`).
  Named(name: str),
}

/// A parsed C prototype.
pub struct CSig {
  /// The C function's symbol.
  name: str,
  ret: CTy,
  params: [CTy],
  /// `+free(fn)`: the function that frees the `char *` strings this function hands over.
  free: str?,
  /// A call through a function pointer: `params[0]` is the function's address.
  indirect: bool,
}

/// How a list's elements are laid out in the C array (the runtime's `AUK_FFI_*` kinds).
pub enum Elem { Raw, I8, U8, I16, U16, I32, U32, F32 }

/// How one value crosses the call.
pub enum Conv {
  Int(bytes: int, signed: bool),
  Bool,
  Float(f32: bool),
  Str(owned: bool),
  OptStr(owned: bool),
  Ptr,
  OptPtr,
  Unit,
  List(elem: Elem, back: bool),
  Out(c: Conv),
}

/// Why a prototype, C type or Auk type doesn't work (Rust's `Err(String)`; `T!E` needs an
/// enum).
pub enum CErr { Bad(why: str) }

/// What an Auk type is to the FFI (Rust's `Option<Option<CTy>>` from `PtrOf`): not an opaque
/// pointer (`None`), `ffi.Ptr`, any pointer (`Some(None)`), or an `extern type` with its C type
/// (`Some(Some(t))`).
pub enum PtrKind { NotPtr, AnyPtr, CType(t: CTy) }

pub fn is_ptr(c: CTy): bool = c is CTy.Ptr(_, _)

/// `char *` / `const char *` (any signedness).
pub fn is_char_ptr(c: CTy): bool = match c {
  Ptr(Int(1, _, true), _) => true
  _ => false
}

/// The same type, ignoring `const` (and `struct`/`signed` spellings).
pub fn same(a: CTy, o: CTy): bool = match (a, o) {
  (Ptr(x, _), Ptr(y, _)) => same(x, y)
  (Int(x, s, _), Int(y, t, _)) => x == y && s == t
  _ => a == o
}

/// The C spelling, for messages.
pub fn show(c: CTy): str = match c {
  Void => "void"
  Bool => "bool"
  Int(bytes, signed, chr) => {
    // plain `char` is this target's signedness (unsigned on Linux arm64)
    if bytes == 1 && chr && signed == char_signed() { return "char" }
    if bytes == 1 && chr { return if signed { "signed char" } else { "unsigned char" } }
    match (bytes, signed) {
      (1, true) => "int8_t"
      (1, false) => "uint8_t"
      (2, true) => "short"
      (2, false) => "unsigned short"
      (4, true) => "int"
      (4, false) => "unsigned"
      (_, true) => "int64_t"
      _ => "uint64_t"
    }
  }
  F32 => "float"
  F64 => "double"
  Ptr(to, konst) => {
    let inner = show(to)
    let k = if konst { "const " } else { "" }
    if inner.ends_with("*") { "{k}{inner}*" } else { "{k}{inner} *" }
  }
  Named(n) => n
}

// ---- parsing ----

enum Tok {
  Word(w: str),
  Star,
  LParen,
  RParen,
  Comma,
  LBrack,
  RBrack,
  Dots,
  Num,
}

fn is_ascii_alpha(c: char): bool = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

fn is_ascii_alnum(c: char): bool = is_ascii_alpha(c) || (c >= '0' && c <= '9')

fn lex(s: str): [Tok]!CErr {
  let cs = s.chars()
  var out: [Tok] = []
  var i = 0
  while i < cs.len() {
    let c = cs[i]
    if lexer.is_whitespace(c) {
      i += 1
      continue
    }
    if is_ascii_alpha(c) || c == '_' {
      let st = i
      while i < cs.len() && (is_ascii_alnum(cs[i]) || cs[i] == '_') { i += 1 }
      out.push(Tok.Word(str(cs[st..i])))
      continue
    }
    if c >= '0' && c <= '9' {
      while i < cs.len() && is_ascii_alnum(cs[i]) { i += 1 }
      out.push(Tok.Num)
      continue
    }
    if i + 3 <= cs.len() && c == '.' && cs[i + 1] == '.' && cs[i + 2] == '.' {
      out.push(Tok.Dots)
      i += 3
      continue
    }
    out.push(match c {
      '*' => Tok.Star
      '(' => Tok.LParen
      ')' => Tok.RParen
      ',' => Tok.Comma
      '[' => Tok.LBrack
      ']' => Tok.RBrack
      _ => fail(Bad("unexpected `{c}` in the C prototype"))
    })
    i += 1
  }
  out
}

let QUALIFIERS = ["const", "volatile", "restrict", "__restrict", "__restrict__", "_Nonnull", "_Nullable", "__nonnull", "extern", "static", "inline"]

/// A fixed-width or system integer typedef: (bytes, signed).
fn int_typedef(w: str): (int, bool)? = match w {
  "int8_t" => (1, true)
  "uint8_t" => (1, false)
  "int16_t" => (2, true)
  "uint16_t" => (2, false)
  "int32_t" => (4, true)
  "uint32_t" => (4, false)
  "int64_t" | "ssize_t" | "ptrdiff_t" | "intptr_t" | "off_t" | "intmax_t" => (8, true)
  "uint64_t" | "size_t" | "uintptr_t" | "uintmax_t" => (8, false)
  _ => none
}

/// Is plain `char` signed on this target? Rust: everywhere but Linux on arm/aarch64. The port
/// can't ask for the architecture without the `ffi` effect, so it assumes a signed `char`
/// (macOS, Linux x86_64).
fn char_signed(): bool = true

struct P { toks: [Tok], pos: int }

fn peek(p: P): Tok? = p.toks.get(p.pos)

fn word(p: P): str? = match p.toks.get(p.pos) {
  some(Word(w)) => w
  _ => none
}

/// Declaration specifiers, pointers and an optional declarator name: (type, name).
fn decl(p: var P, what: str, top: bool): (CTy, str?)!CErr {
  var konst = false
  var words: [str] = []
  var named: str? = none
  var name: str? = none
  loop {
    let w = p.word() else break
    if w == "const" {
      konst = true
      p.pos += 1
      continue
    }
    if QUALIFIERS.contains(w) {
      p.pos += 1
      continue
    }
    if w == "struct" || w == "union" || w == "enum" {
      p.pos += 1
      let tag = p.word() else return fail(Bad("`{w}` needs a name in {what}"))
      p.pos += 1
      if w == "enum" { words.push("int") } else { named = tag }
      continue
    }
    let is_kw = ["void", "bool", "_Bool", "char", "short", "int", "long", "signed", "unsigned", "float", "double"].contains(w)
    let have_base = words.len() > 0 || named != none
    if is_kw {
      words.push(w)
      p.pos += 1
    } else if !have_base {
      named = w
      p.pos += 1
    } else {
      break
    }
  }
  var ty = match named {
    some(n) => {
      if words.len() > 0 { return fail(Bad("`{n}` can't be combined with `{words.join(" ")}` in {what}")) }
      match int_typedef(n) {
        some((bytes, signed)) => CTy.Int(bytes, signed, false)
        none => CTy.Named(n)
      }
    }
    none => {
      if words.len() == 0 { return fail(Bad("expected a C type in {what}")) }
      base_type(words) else return fail(Bad("`{words.join(" ")}` is not a C type the FFI supports"))
    }
  }
  while p.peek() == some(Tok.Star) {
    p.pos += 1
    ty = CTy.Ptr(ty, konst)
    konst = false
    loop {
      let w = p.word() else break
      if w == "const" {
        konst = true
      } else if !QUALIFIERS.contains(w) {
        break
      }
      p.pos += 1
    }
  }
  match p.word() {
    some(w) => {
      name = w
      p.pos += 1
    }
    none => {}
  }
  if !top && p.peek() == some(Tok.LParen) {
    return fail(Bad("function pointers (callbacks from C into Auk) aren't supported"))
  }
  while p.peek() == some(Tok.LBrack) {
    p.pos += 1
    loop {
      match p.peek() {
        some(Num) | some(Word(_)) => p.pos += 1
        _ => break
      }
    }
    if p.peek() != some(Tok.RBrack) { return fail(Bad("expected `]` in {what}")) }
    p.pos += 1
    ty = CTy.Ptr(ty, konst)
  }
  (ty, name)
}

fn base_type(words: [str]): CTy? {
  let unsigned = words.contains("unsigned")
  let rest = words.filter(w => w != "signed" && w != "unsigned" && w != "int")
  let longs = words.filter(w => w == "long").len()
  let one = words.len() == 1
  let r0 = if rest.len() > 0 { rest[0] } else { "" }
  if rest.len() == 1 && r0 == "void" && one { return CTy.Void }
  if rest.len() == 1 && (r0 == "bool" || r0 == "_Bool") && one { return CTy.Bool }
  if rest.len() == 1 && r0 == "float" && one { return CTy.F32 }
  if rest.len() == 1 && r0 == "double" && one { return CTy.F64 }
  if rest.len() == 1 && r0 == "char" && !words.contains("int") {
    let signed = if unsigned { false } else if words.contains("signed") { true } else { char_signed() }
    return CTy.Int(1, signed, true)
  }
  if rest.len() == 1 && r0 == "short" { return CTy.Int(2, !unsigned, false) }
  if rest.len() == 0 { return CTy.Int(4, !unsigned, false) }
  if rest.len() == 1 && r0 == "long" { return CTy.Int(8, !unsigned, false) }
  if rest.len() == 2 && r0 == "long" && rest[1] == "long" && longs == 2 { return CTy.Int(8, !unsigned, false) }
  none
}

/// Parse an `extern type`'s C spelling: a pointer type (`sqlite3 *`) or a typedef name for one
/// (`LLVMModuleRef`).
pub fn parse_type(s: str): CTy!CErr {
  var p = P { toks: lex(s)?, pos: 0 }
  let (t, name) = decl(&p, "the C type", false)?
  if name != none || p.pos < p.toks.len() { return fail(Bad("`{s}` is not a single C type")) }
  t
}

fn is_ident(f: str): bool {
  for c in f.chars() {
    if !(is_ascii_alnum(c) || c == '_') { return false }
  }
  true
}

/// Parse `"<C prototype>"`, with an optional ` +free(fn)` suffix.
pub fn parse_proto(src: str): CSig!CErr {
  var proto = src
  var free: str? = none
  match src.find("+free") {
    some(i) => {
      let rest = src[i + 5..src.len()].trim()
      let inner = match rest.strip_prefix("(") {
        some(r) => match r.strip_suffix(")") {
          some(x) => some(x.trim())
          none => none
        }
        none => none
      }
      match inner {
        some(f) when f.len() > 0 && is_ident(f) => {
          proto = src[0..i]
          free = f
        }
        _ => return fail(Bad("expected `+free(function)` after the prototype"))
      }
    }
    none => {}
  }
  var body = proto.trim()
  while body.ends_with(";") { body = body[0..body.len() - 1] }
  let toks = lex(body)?
  var p = P { toks, pos: 0 }
  let (ret, name0) = decl(&p, "the result type", true)?
  // `T (*)(params)`: a call through the function pointer passed first
  let indirect = name0 == none && p.pos + 3 <= p.toks.len() && p.toks[p.pos] == Tok.LParen &&
    p.toks[p.pos + 1] == Tok.Star && p.toks[p.pos + 2] == Tok.RParen
  if indirect { p.pos += 3 }
  let name1 = if indirect { some("(*)") } else { name0 }
  let name = name1 else {
    return fail(Bad("expected a C prototype like \"int abs(int)\" (the result type, the C function's name, its parameter types)"))
  }
  if p.peek() != some(Tok.LParen) { return fail(Bad("expected `(` after `{name}`")) }
  p.pos += 1
  var params: [CTy] = []
  if indirect { params.push(CTy.Ptr(CTy.Void, false)) }
  if p.peek() == some(Tok.RParen) || (p.word() == some("void") && p.toks.get(p.pos + 1) == some(Tok.RParen)) {
    if p.peek() != some(Tok.RParen) { p.pos += 1 }
  } else {
    loop {
      if p.peek() == some(Tok.Dots) { return fail(Bad("variadic C functions (`...`) aren't supported")) }
      let (t, _) = decl(&p, "parameter {params.len() + 1}", false)?
      if t == CTy.Void { return fail(Bad("a parameter can't be `void`")) }
      params.push(t)
      match p.peek() {
        some(Comma) => p.pos += 1
        some(RParen) => break
        _ => return fail(Bad("expected `,` or `)` after parameter {params.len()}"))
      }
    }
  }
  if p.peek() != some(Tok.RParen) { return fail(Bad("expected `)` to end the parameter list")) }
  p.pos += 1
  if p.pos < p.toks.len() { return fail(Bad("unexpected text after the prototype")) }
  CSig { name, ret, params, free, indirect }
}

// ---- matching Auk types to C types ----

fn int_elem(bytes: int, signed: bool): Elem = match (bytes, signed) {
  (1, true) => Elem.I8
  (1, false) => Elem.U8
  (2, true) => Elem.I16
  (2, false) => Elem.U16
  (4, true) => Elem.I32
  (4, false) => Elem.U32
  _ => Elem.Raw
}

/// Does C type `c` fit the opaque pointer type described by `p` (`AnyPtr` or `CType`)?
fn ptr_fits(p: PtrKind, c: CTy): bool = match p {
  CType(want) => same(want, c)
  _ => is_ptr(c)
}

/// The help for a C type that no Auk type fits.
fn hint(c: CTy): str = match c {
  Named(n) => {
    var base = n
    while base.ends_with("Ref") { base = base[0..base.len() - 3] }
    "`{n}` is a C type name the FFI doesn't know: write its underlying type (an integer typedef as `int`, `unsigned`, ...; a pointer as `T *`), or declare an opaque pointer type `extern type {base} = \"{n}\"`"
  }
  Int(_, _, _) => "C integers are `int` in Auk"
  Bool => "C `bool` is `bool` in Auk"
  F32 | F64 => "C `float` and `double` are `float` in Auk"
  Void => "`void` is `()` in Auk (no result type)"
  Ptr(_, konst) => if is_char_ptr(c) {
    if konst {
      "`const char *` is `str` (or `str?`); other pointers are `ffi.Ptr` or an `extern type`"
    } else {
      "a `char *` parameter may be written by C: pass a byte buffer (`[int]`) or an `ffi.Ptr`; `str` goes as `const char *`"
    }
  } else {
    "pointers are `ffi.Ptr` (or an `extern type`); `T *` for a list `[T]`; a `var` parameter for an out-parameter"
  }
}

/// Match Auk type `t` (a `var` parameter when `var_`) with C type `c`. `ret`: it's the result.
/// `free`: the prototype has `+free(fn)`. `ptr_of`: what an Auk type is as an opaque pointer.
/// Fails with why it doesn't fit (a note for E0040).
pub fn conv(t: types.Ty, var_: bool, c: CTy, ret: bool, free: bool, ptr_of: (types.Ty) => PtrKind): Conv!CErr {
  if var_ {
    let to = match c {
      Ptr(to, _) => to
      _ => return fail(Bad("a `var` parameter is an out-parameter: its C type is a pointer (`{show(c)} *`)"))
    }
    if t is types.Ty.List(_) {
      return match conv(t, false, c, false, free, ptr_of)? {
        List(elem, _) => Conv.List(elem, true)
        x => x
      }
    }
    if t == types.Ty.Str { return fail(Bad("an out-parameter string is `var str?` (C may leave it NULL)")) }
    let inner = match t {
      Opt(Str) => {
        if !is_char_ptr(to) { return fail(Bad("`str?` goes with `char *`, not `{show(to)}`")) }
        Conv.OptStr(free && !(to is CTy.Ptr(_, true)))
      }
      _ => conv(t, false, to, true, free, ptr_of)?
    }
    return Conv.Out(inner)
  }
  let bad = hint(c)
  match t {
    Int => match c {
      Int(bytes, signed, _) => Conv.Int(bytes, signed)
      _ => fail(Bad(bad))
    }
    Bool => match c {
      Bool => Conv.Bool
      _ => fail(Bad(bad))
    }
    Float => match c {
      F32 => Conv.Float(true)
      F64 => Conv.Float(false)
      _ => fail(Bad(bad))
    }
    Str | Opt(Str) => {
      let opt = t != types.Ty.Str
      let konst = match c {
        Ptr(_, k) => k
        _ => return fail(Bad(bad))
      }
      if !is_char_ptr(c) { return fail(Bad(bad)) }
      if !ret && !konst {
        return fail(Bad("a `str` parameter is `const char *` (C must not write to it); for a buffer C fills, pass `[int]` or an `ffi.Ptr`"))
      }
      let owned = ret && free && !konst
      if opt { Conv.OptStr(owned) } else { Conv.Str(owned) }
    }
    Opt(x) => match ptr_of(x) {
      NotPtr => fail(Bad("an optional (`T?`) crosses to C only as a pointer (`none` is NULL) or a `str?`; `{show(c)}` isn't one"))
      p => if ptr_fits(p, c) { Conv.OptPtr } else { fail(Bad(bad)) }
    }
    List(e) => {
      if ret {
        return fail(Bad("a C function can't return a list: return an `ffi.Ptr` and read it with `ffi.bytes` / `read_*`"))
      }
      let to = match c {
        Ptr(to, _) => to
        _ => return fail(Bad("a list `[T]` goes to C as a pointer to its first element, not `{show(c)}`"))
      }
      let elem = match (e, to) {
        (Int, Int(bytes, signed, _)) => int_elem(bytes, signed)
        (Int, Void) => Elem.U8
        (Float, F64) => Elem.Raw
        (Float, F32) => Elem.F32
        (Bool, Bool) => Elem.Raw
        _ => {
          let p = ptr_of(e)
          if p != PtrKind.NotPtr && ptr_fits(p, to) {
            Elem.Raw
          } else {
            return fail(Bad("a list `[T]` goes to C as `T *`; `{show(to)}` doesn't fit this element type ({hint(to)})"))
          }
        }
      }
      Conv.List(elem, false)
    }
    t2 when t2.is_unit() => match c {
      Void => if ret { Conv.Unit } else { fail(Bad(bad)) }
      _ => fail(Bad(bad))
    }
    _ => {
      let p = ptr_of(t)
      if p != PtrKind.NotPtr && ptr_fits(p, c) { return Conv.Ptr }
      match p {
        CType(want) => fail(Bad("this type is the C type `{show(want)}`, not `{show(c)}`"))
        AnyPtr => {
          let known = if c is CTy.Named(_) { " the FFI knows ({hint(c)})" } else { "" }
          fail(Bad("`ffi.Ptr` is any C pointer (`T *`); `{show(c)}` isn't a pointer{known}"))
        }
        NotPtr => fail(Bad("only `int`, `float`, `bool`, `str`, `str?`, lists of these, `ffi.Ptr`, `extern type`s, their optionals and `()` cross to C"))
      }
    }
  }
}

fn i(bytes: int, signed: bool): CTy = CTy.Int(bytes, signed, false)

fn proto_err(s: str): str = match parse_proto(s) {
  ok(_) => ""
  err(Bad(why)) => why
}

test "prototypes" {
  let s = parse_proto("int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs)")!
  assert s.name == "sqlite3_open_v2"
  assert s.ret == i(4, true)
  assert is_char_ptr(s.params[0])
  assert s.params[1] == CTy.Ptr(CTy.Ptr(CTy.Named("sqlite3"), false), false)
  let s2 = parse_proto("const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);")!
  assert is_char_ptr(s2.ret)
  assert parse_proto("void f(void)")!.params.len() == 0
  assert parse_proto("unsigned long long f(unsigned, short int, size_t n, double)")!.params == [i(4, false), i(2, true), i(8, false), CTy.F64]
  let s3 = parse_proto("char *LLVMPrintModuleToString(LLVMModuleRef M) +free(LLVMDisposeMessage)")!
  assert s3.free == some("LLVMDisposeMessage")
  assert s3.params == [CTy.Named("LLVMModuleRef")]
  assert parse_proto("void f(int xs[], struct S *const *p)")!.params[0] == CTy.Ptr(i(4, true), false)
  assert proto_err("int printf(const char *, ...)").contains("variadic")
  assert proto_err("void qsort(void *, size_t, size_t, int (*)(const void *, const void *))").contains("callbacks")
  assert proto_err("abs") != ""
  assert proto_err("long double f(void)") != ""
  assert parse_type("LLVMModuleRef")! == CTy.Named("LLVMModuleRef")
  let s4 = parse_proto("int64_t (*)(int64_t a, int64_t)")!
  assert s4.indirect
  assert s4.params == [CTy.Ptr(CTy.Void, false), i(8, true), i(8, true)]
  assert parse_proto("void (*)(void)")!.params.len() == 1
  assert !parse_proto("int abs(int)")!.indirect
  assert same(parse_type("struct sqlite3 *")!, parse_type("sqlite3*")!)
}
