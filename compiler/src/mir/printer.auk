/// `auk ir`: a MIR program printed as C-like text (src/mir/print.rs), one function after another
/// (with the type definitions and globals it uses): every variable is declared at the top of
/// its function, `Loop` is `for (;;)` with its latch after a continue label, runtime calls name
/// the runtime's C symbols. (It reads as C against the runtime's ABI; nothing compiles it.)
///
/// Rust writes into `String`s; here each piece is a `[str]` joined once.

/// Escape bytes as the contents of a C string literal (octal escapes keep it unambiguous).
pub fn c_str(s: [int]): str {
  var out: [str] = ["\""]
  for b in s {
    if b == 34 {
      out.push("\\\"")
    } else if b == 92 {
      out.push("\\\\")
    } else if b == 63 {
      out.push("\\?")
    } else if b >= 32 && b <= 126 {
      out.push(str([char(b)!]))
    } else {
      out.push("\\{b / 64}{b / 8 % 8}{b % 8}")
    }
  }
  out.push("\"")
  out.join("")
}

struct Printer {
  p: mir.Program,
  info: mir.types.TyInfo,
  types: [str],
  names: {mir.MTy: str},
  n: int,
  /// Continue labels of the open loops.
  conts: [int],
}

/// The C source of a program.
pub fn print_program(p: mir.Program, info: mir.types.TyInfo): str {
  var pr = Printer { p, info, types: [], names: {}, n: 0, conts: [] }
  var protos: [str] = []
  var funcs: [str] = []
  for f in p.funcs {
    let sig = sig_of(&pr, f)
    protos.push("{sig};\n")
    funcs.push("{sig} {{\n")
    body(&pr, f, &funcs)
    funcs.push("}}\n\n")
  }
  var globals: [str] = []
  for g in p.globals {
    let t = ct(&pr, g.ty)
    let q = if g.constant { "const " } else { "" }
    match g.init {
      some(init) => {
        let i = init_of(&pr, init)
        globals.push("static {q}{t} {g.name} = {i};\n")
      }
      none => globals.push("static {q}{t} {g.name};\n")
    }
  }
  var out: [str] = ["/* auk ir: the program's MIR, printed as C-like text */\n\n"]
  out.push("/* ---- types ---- */\n")
  out.push(pr.types.join(""))
  out.push("\n/* ---- prototypes ---- */\n")
  out.push(protos.join(""))
  out.push("\n/* ---- globals ---- */\n")
  out.push(globals.join(""))
  out.push("\n/* ---- functions ---- */\n")
  out.push(funcs.join(""))
  match p.entry {
    some(e) => out.push("int main(int argc, char **argv) {{\n    return {p.funcs[e].name}(argc, argv);\n}}\n")
    none => {}
  }
  out.join("")
}

fn fresh(pr: var Printer): int {
  pr.n += 1
  pr.n
}

// ---- types ----

/// The C spelling of a type, defining it first if needed.
fn ct(pr: var Printer, t: mir.MTy): str = match t {
  Void => "void"
  Bool => "bool"
  I8 => "int8_t"
  U8 => "uint8_t"
  I16 => "int16_t"
  U16 => "uint16_t"
  F32 => "float"
  I32 => "int32_t"
  U32 => "uint32_t"
  I64 => "int64_t"
  U64 => "uint64_t"
  CStr => "const char *"
  Code => "void *"
  Ptr(x) => match x {
    Rt(ElemOps) => "const AukElemOps *"
    x => {
      let c = ct(&pr, x)
      if c.ends_with("*") { "{c}*" } else { "{c} *" }
    }
  }
  Rt(r) => match r {
    StrBuf => "AukStrBuf"
    Obj => "AukObj"
    ElemOps => "AukElemOps"
    Task => "AukTask"
  }
  Agg(a) => {
    match pr.names.get(t) {
      some(n) => return n
      none => {}
    }
    let def = pr.p.aggs[a]
    let name = "{def.name}_{a}"
    pr.names[t] = name
    var body: [str] = []
    for i, f in def.fields {
      let c = ct(&pr, f)
      body.push("    {c} f{i};\n")
    }
    if def.fields.len() == 0 { body.push("    int dummy;\n") }
    pr.types.push("typedef struct {name} {{\n{body.join("")}}} {name};\n")
    name
  }
  D(d) => dt(&pr, d)
}

fn dt(pr: var Printer, t: types.Ty): str {
  let info = pr.info
  match t {
    Int => return "int64_t"
    Float => return "double"
    Bool => return "bool"
    Char => return "uint32_t"
    Str => return "AukStr *"
    Never => return "AukUnit"
    Tuple(ts) when ts.len() == 0 => return "AukUnit"
    List(_) => return "AukArr *"
    Map(_, _) => return "AukMap *"
    Fn(_, _) => return "AukClosure"
    Task(_) => return "AukTask *"
    Fixed(k) => return match k {
      I8 => "int8_t"
      I16 => "int16_t"
      I32 => "int32_t"
      I64 | Isize => "int64_t"
      U8 => "uint8_t"
      U16 => "uint16_t"
      U32 => "uint32_t"
      U64 | Usize => "uint64_t"
      F32 => "float"
    }
    Ptr(_) | CFn(_, _) => return "void *"
    _ => {}
  }
  if mir.types.is_value(info, t) { return "AukValue" }
  match mir.types.opaque_c(info, t) {
    some(c) => return c
    none => {}
  }
  match t {
    Opt(inner) => match inner {
      Int => "AukOpt_int"
      Float => "AukOpt_float"
      Bool => "AukOpt_bool"
      Char => "AukOpt_char"
      Str => "AukOpt_str"
      List(_) => "AukOpt_arr"
      x when mir.types.is_value(info, x) => "AukOpt_value"
      _ => define(&pr, t)
    }
    Res(inner, _) => match inner {
      Tuple(ts) when ts.len() == 0 => "AukRes_unit"
      Int => "AukRes_int"
      Float => "AukRes_float"
      Str => "AukRes_str"
      List(_) => "AukRes_arr"
      x when mir.types.is_value(info, x) => "AukRes_value"
      x when mir.types.opaque_c(info, x) == some("AukConn *") => "AukRes_conn"
      x when mir.types.opaque_c(info, x) == some("AukListener *") => "AukRes_listener"
      _ => define(&pr, types.Ty.Res(inner, types.unit()))
    }
    _ => define(&pr, t)
  }
}

fn c_ident(s: str): str =
  str(s.chars().map(c => if c.is_alpha() && int(c) < 128 || c.is_digit() { c } else { '_' }))

fn define(pr: var Printer, t: types.Ty): str {
  let key = mir.MTy.D(t)
  match pr.names.get(key) {
    some(n) => return n
    none => {}
  }
  let k = fresh(&pr)
  let info = pr.info
  var body: [str] = []
  let show = mir.types.show_ty(info, t).replace("*/", "* /")
  let name = match t {
    Tuple(ts) => {
      let name = "DkTup{k}"
      for i, x in ts {
        let c = dt(&pr, x)
        body.push("    {c} f{i};\n")
      }
      pr.types.push("/* {show} */\ntypedef struct {name} {{\n{body.join("")}}} {name};\n")
      name
    }
    Opt(inner) => {
      let c = dt(&pr, inner)
      let name = "DkOpt{k}"
      pr.types.push("/* {show} */\nAUK_DEF_OPT({name}, {c});\n")
      name
    }
    Res(inner, _) => {
      let c = dt(&pr, inner)
      let name = "DkRes{k}"
      pr.types.push("/* {show} */\nAUK_DEF_RES({name}, {c});\n")
      name
    }
    Named(d, _) => {
      let def = info.defs.types[d]
      let dname = c_ident(def.name)
      match def.kind {
        Struct(_) => {
          let name = "DkS{k}_{dname}"
          for i, (ft, boxed) in mir.types.struct_layout(info, t) {
            let c = if boxed { "AukObj *" } else { dt(&pr, ft) }
            body.push("    {c} f{i};\n")
          }
          if body.len() == 0 { body.push("    AukUnit dummy;\n") }
          let kw = if types.is_union(info.defs, d) { "union" } else { "struct" }
          pr.types.push("/* {show} */\ntypedef {kw} {name} {{\n{body.join("")}}} {name};\n")
          name
        }
        Enum(_) => {
          let name = "DkE{k}_{dname}"
          var un: [str] = []
          for vi, fs in mir.types.enum_layout(info, t) {
            if fs.len() == 0 { continue }
            var st: [str] = []
            for fi, (ft, boxed) in fs {
              let c = if boxed { "AukObj *" } else { dt(&pr, ft) }
              st.push(" {c} f{fi};")
            }
            un.push("        struct {{{st.join("")} }} v{vi};\n")
          }
          if un.len() == 0 {
            pr.types.push("/* {show} */\ntypedef struct {name} {{\n    int32_t tag;\n}} {name};\n")
          } else {
            pr.types.push("/* {show} */\ntypedef struct {name} {{\n    int32_t tag;\n    union {{\n{un.join("")}    }} u;\n}} {name};\n")
          }
          name
        }
        Opaque(c_type) => c_type
      }
    }
    Any(_) => {
      let name = "DkAny{k}"
      pr.types.push("typedef struct {name} {{\n    AukObj *f0;\n    const void *f1;\n}} {name};\n")
      name
    }
    Array(x, n) => {
      let name = "DkArr{k}"
      let c = dt(&pr, x)
      let len = if n < 0 { "" } else { "{n}" }
      pr.types.push("/* {show} */\ntypedef struct {name} {{\n    {c} a[{len}];\n}} {name};\n")
      name
    }
    _ => mir.bug("c: can't define {mir.types.show_ty(info, t)}")
  }
  pr.names[key] = name
  name
}

let ELEM_OPS = ["size", "retain", "release", "eq", "cmp", "hash", "show", "copy"]
let VALUE_MEMBERS = ["", "b", "i", "f", "s", "list", "map"]

/// The C member path of `sel` in a value of type `t`.
fn member(pr: Printer, t: mir.MTy, sel: mir.Sel): str = match (t, sel) {
  (Agg(_), F(i)) => "f{i}"
  (Rt(ElemOps), F(i)) => ELEM_OPS[i]
  (D(d), sel) => match (d, sel) {
    (Opt(_), F(0)) => "some"
    (Opt(_), F(1)) | (Res(_, _), F(1)) => "val"
    (Res(_, _), F(0)) => "ok"
    (Res(_, _), F(2)) => "err"
    (Fn(_, _), F(0)) => "fn"
    (Fn(_, _), F(1)) => "env"
    (_, Tag) => "tag"
    (d, V(vi, _)) when mir.types.is_value(pr.info, d) => "u.{VALUE_MEMBERS[vi]}"
    (_, V(vi, fi)) => "u.v{vi}.f{fi}"
    (_, F(i)) => "f{i}"
  }
  _ => mir.bug("c: no member {sel} of {t}")
}

// ---- functions ----

fn sig_of(pr: var Printer, f: mir.Func): str {
  let r = ct(&pr, f.ret)
  var ps: [str] = []
  for v in f.params {
    let t = ct(&pr, f.vars[v])
    ps.push("{t} v{v}")
  }
  let pl = if ps.len() == 0 { "void" } else { ps.join(", ") }
  "static {r} {f.name}({pl})"
}

fn body(pr: var Printer, f: mir.Func, out: var [str]) {
  var is_param: [bool] = f.vars.map(_ => false)
  for v in f.params { is_param[v] = true }
  for v, t in f.vars {
    if is_param[v] { continue }
    let c = ct(&pr, t)
    out.push("    {c} v{v};\n")
  }
  for v in 0..f.vars.len() {
    if !is_param[v] { out.push("    (void)v{v};\n") }
  }
  for v in f.params { out.push("    (void)v{v};\n") }
  stmts(&pr, f.body, 1, &out)
}

fn stmts(pr: var Printer, ss: [mir.Stmt], ind: int, out: var [str]) {
  for s in ss { stmt(&pr, s, ind, &out) }
}

fn stmt(pr: var Printer, s: mir.Stmt, ind: int, out: var [str]) {
  let pad = "    ".repeat(ind)
  match s {
    Let(v, e) => {
      let x = ex(&pr, e)
      out.push("{pad}v{v} = {x};\n")
    }
    Set(p, e) => {
      let a = ex(&pr, p)
      let x = ex(&pr, e)
      out.push("{pad}{a} = {x};\n")
    }
    Do(e) => {
      let x = ex(&pr, e)
      out.push("{pad}{x};\n")
    }
    If(c, a, b) => {
      let x = ex(&pr, c)
      out.push("{pad}if ({x}) {{\n")
      stmts(&pr, a, ind + 1, &out)
      if b.len() == 0 {
        out.push("{pad}}}\n")
      } else {
        out.push("{pad}}} else {{\n")
        stmts(&pr, b, ind + 1, &out)
        out.push("{pad}}}\n")
      }
    }
    Loop(body, latch) => {
      let l = fresh(&pr)
      pr.conts.push(l)
      out.push("{pad}for (;;) {{\n")
      stmts(&pr, body, ind + 1, &out)
      pr.conts.pop()
      out.push("{pad}dk_c{l}:;\n")
      stmts(&pr, latch, ind + 1, &out)
      out.push("{pad}}}\n")
    }
    Break => out.push("{pad}break;\n")
    Continue => {
      let l = pr.conts.last() else mir.bug("continue outside a loop")
      out.push("{pad}goto dk_c{l};\n")
    }
    Label(0) => out.push("dk_tail:;\n")
    Goto(0) => out.push("{pad}goto dk_tail;\n")
    Label(l) => out.push("dk_l{l}:;\n")
    Goto(l) => out.push("{pad}goto dk_l{l};\n")
    Ret(none) => out.push("{pad}return;\n")
    Ret(some(e)) => {
      let x = ex(&pr, e)
      out.push("{pad}return {x};\n")
    }
    Unreachable => out.push("{pad}__builtin_unreachable();\n")
    Loc(i) => match pr.p.locs.get(i) {
      some((f, l, c)) => out.push("{pad}// {f}:{l}:{c}\n")
      none => {}
    }
  }
}

// ---- expressions ----

fn is_int(t: mir.MTy): bool = match t {
  I8 | U8 | I16 | U16 | I32 | U32 | I64 | U64 => true
  D(Int) | D(Char) => true
  _ => false
}

/// `n` as an unsigned 64-bit number (Rust's `n as u64`).
fn u64_text(n: int): str {
  if n >= 0 { return "{n}" }
  // n + 2^64 = (n >>> 1) * 2 + (n & 1), the halves computed without overflow
  let half = (n >> 1) & 9223372036854775807
  let q = half / 5
  let r = half % 5 * 2 + (n & 1)
  "{q}{r}"
}

/// Rust's `{:?}` of an `f64`: the shortest round-trip digits, in plain notation from 1e-4 up to
/// 1e16 (with `.0` when integral), otherwise `1.5e300` / `1e-7`.
pub fn rust_float(x: float): str {
  let s = "{x}"
  if s == "NaN" || s.contains("inf") { return s }
  let neg = s.starts_with("-")
  let body = if neg { s.strip_prefix("-") else s } else { s }
  // digits and decimal exponent: value = 0.d1d2... * 10^e  (as d1.d2... * 10^(e-1))
  var mant = body
  var exp = 0
  match body.find("e") {
    some(i) => {
      let cs = body.chars()
      mant = str(cs.take(i))
      exp = int.parse(str(cs.skip(i + 1))) else 0
    }
    none => {}
  }
  let parts = mant.split(".")
  let ip = parts[0]
  let fp = if parts.len() > 1 { parts[1] } else { "" }
  var digits = ip + fp
  var point = ip.len() + exp
  // strip leading zeros
  while digits.len() > 1 && digits.starts_with("0") {
    digits = digits.strip_prefix("0") else digits
    point -= 1
  }
  while digits.len() > 1 && digits.ends_with("0") { digits = digits.strip_suffix("0") else digits }
  let sign = if neg { "-" } else { "" }
  if digits == "0" { return "{sign}0.0" }
  // the value is 0.digits * 10^point
  let sci = point - 1
  if sci < -4 || sci >= 16 {
    let cs = digits.chars()
    let m = if cs.len() == 1 { digits } else { "{cs[0]}.{str(cs.skip(1))}" }
    return "{sign}{m}e{sci}"
  }
  if point <= 0 { return "{sign}0.{"0".repeat(-point)}{digits}" }
  let cs = digits.chars()
  if point >= cs.len() { return "{sign}{digits}{"0".repeat(point - cs.len())}.0" }
  "{sign}{str(cs.take(point))}.{str(cs.skip(point))}"
}

fn ex(pr: var Printer, e: mir.Ex): str = match e.k {
  Var(v) => "v{v}"
  Global(g) => pr.p.globals[g].name
  Int(n) => match e.ty {
    Bool | D(Bool) => if n != 0 { "true" } else { "false" }
    I64 | D(Int) => if n == -9223372036854775807 - 1 { "INT64_MIN" } else { "INT64_C({n})" }
    U64 => "UINT64_C({u64_text(n)})"
    U32 | D(Char) => "UINT32_C({n & 4294967295})"
    D(Fixed(_)) => {
      let c = ct(&pr, e.ty)
      "(({c}){n})"
    }
    t when (t is mir.MTy.D(_)) && !is_int(t) && t != mir.MTy.D(types.Ty.Float) => "0"
    t => {
      let c = ct(&pr, t)
      "(({c}){n})"
    }
  }
  Float(x) => {
    let s = "{x}"
    if s == "NaN" {
      "(__builtin_nan(\"\"))"
    } else if s == "inf" {
      "(__builtin_inf())"
    } else if s == "-inf" {
      "(-__builtin_inf())"
    } else {
      var t = rust_float(x)
      if !t.contains(".") && !t.contains("e") { t = t + ".0" }
      "({t})"
    }
  }
  CStr(s) => c_str(s)
  Undef => "/* undefined */"
  Zero => {
    let c = ct(&pr, e.ty)
    let agg = match e.ty {
      Agg(_) | Rt(_) => true
      D(t) => !mir.types.is_scalar(pr.info, t)
      _ => false
    }
    if c.ends_with("*") { "NULL" } else if agg { "(({c}){{0}})" } else { "(({c})0)" }
  }
  FnAddr(f) => match f {
    Fn(f) => "((void *){pr.p.funcs[f].name})"
    Rt(s) => "((void *){s})"
  }
  GlobalAddr(g) => "((void *)&{pr.p.globals[g].name})"
  RtGlobalAddr(s) => "(&{s})"
  Field(b, s) => {
    let m = member(pr, b.ty, s)
    let x = ex(&pr, b)
    "({x}).{m}"
  }
  Deref(p) => {
    let pt = ct(&pr, mir.MTy.Ptr(e.ty))
    let x = ex(&pr, p)
    "(*({pt})({x}))"
  }
  Addr(p) => {
    let x = ex(&pr, p)
    "(&{x})"
  }
  Un(op, a) => {
    let x = ex(&pr, a)
    match op {
      Not => "(!({x}))"
      Neg => "(-({x}))"
      BitNot => "(~({x}))"
    }
  }
  Bin(op, a, b) => {
    let int = is_int(a.ty)
    let x = ex(&pr, a)
    let y = ex(&pr, b)
    let sym = match op {
      Add => "+"
      Sub => "-"
      Mul => "*"
      Div => "/"
      BitAnd => "&"
      BitOr => "|"
      BitXor => "^"
      Eq => "=="
      Ne => "!="
      Lt => "<"
      Le => "<="
      Gt => ">"
      Ge => ">="
      Rem => "%"
      Shl => "<<"
      Shr => ">>"
    }
    if int && (op == mir.BOp.Add || op == mir.BOp.Sub || op == mir.BOp.Mul) {
      // wrapping integer arithmetic
      let t = ct(&pr, e.ty)
      "(({t})((uint64_t)({x}) {sym} (uint64_t)({y})))"
    } else {
      "(({x}) {sym} ({y}))"
    }
  }
  And(xs) => {
    var parts: [str] = []
    for x in xs { parts.push("({ex(&pr, x)})") }
    "({parts.join(" && ")})"
  }
  Cast(x) => {
    let from = ct(&pr, x.ty)
    let to = ct(&pr, e.ty)
    let s = ex(&pr, x)
    if from == to { s } else { "(({to})({s}))" }
  }
  Call(c, args) => {
    var a: [str] = []
    for x in args { a.push(ex(&pr, x)) }
    let al = a.join(", ")
    match c {
      Fn(f) => "{pr.p.funcs[f].name}({al})"
      Rt(s) => "{s}({al})"
      Indirect(code, ps) => {
        let r = ct(&pr, e.ty)
        var pl: [str] = []
        for t in ps { pl.push(ct(&pr, t)) }
        let cx = ex(&pr, code)
        "(({r} (*)({pl.join(", ")}))({cx}))({al})"
      }
      CPtr(code) => {
        let r = ct(&pr, e.ty)
        var pl: [str] = []
        for x in args { pl.push(ct(&pr, x.ty)) }
        let cx = ex(&pr, code)
        "(({r} (*)({pl.join(", ")}))({cx}))({al})"
      }
    }
  }
  Agg(ms) => {
    let c = ct(&pr, e.ty)
    if ms.len() == 0 { return "(({c}){{0}})" }
    var parts: [str] = []
    for (s, v) in ms {
      let m = member(pr, e.ty, s)
      parts.push(".{m} = {ex(&pr, v)}")
    }
    "(({c}){{{parts.join(", ")}}})"
  }
  Cond(c, a, b) => {
    let x = ex(&pr, c)
    let y = ex(&pr, a)
    let z = ex(&pr, b)
    "(({x}) ? ({y}) : ({z}))"
  }
  Elem(arr, i) => {
    let t = ct(&pr, e.ty)
    let a = ex(&pr, arr)
    let x = ex(&pr, i)
    "((({t} *)({a})->data)[{x}])"
  }
  RtField(p, f) => {
    let x = ex(&pr, p)
    let m = match f {
      ArrLen => "len"
      ArrData => "data"
      ErrMsg => "msg"
    }
    "(({x})->{m})"
  }
  SizeOf(t) => "sizeof({ct(&pr, t)})"
}

/// A constant initializer (for a global).
fn init_of(pr: var Printer, e: mir.Ex): str = match e.k {
  Agg(ms) => {
    var parts: [str] = []
    for (s, v) in ms {
      let m = member(pr, e.ty, s)
      parts.push(".{m} = {ex(&pr, v)}")
    }
    if parts.len() == 0 { "{{0}}" } else { "{{{parts.join(", ")}}}" }
  }
  _ => ex(&pr, e)
}
