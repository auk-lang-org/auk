/// Reads a MIR program written by `auk dump mir` (src/mir/dump.rs, which describes the format):
/// whitespace-separated tokens in prefix form, strings as `'` and their bytes with `\hh`
/// escapes, floats as their IEEE bits (a signed decimal). Gives the program and the type definitions its layouts
/// need (`mir.types.TyInfo`).

struct Reader { toks: [str], i: int }

/// The program and type facts in `text` (a dump), or what is wrong with it.
pub fn read(text: str): (mir.Program, mir.types.TyInfo)! {
  var r = Reader { toks: split(text), i: 0 }
  expect(&r, "auk-mir")?
  expect(&r, "1")?
  expect(&r, "types")?
  var defs = types.new_defs()
  let nt = num(&r)?
  for _ in 0..nt {
    expect(&r, "T")?
    let name = string(&r)?
    var params: [int] = []
    let np = num(&r)?
    for _ in 0..np { params.push(num(&r)?) }
    let kind = match tok(&r)? {
      "S" => {
        var fields: [types.FieldDef] = []
        let n = num(&r)?
        for _ in 0..n {
          let fname = string(&r)?
          let t = ty(&r)?
          fields.push(types.FieldDef { name: fname, ty: t, public: true, span: diag.NONE })
        }
        types.TypeDefKind.Struct(fields)
      }
      "E" => {
        var vs: [types.VariantDef] = []
        let n = num(&r)?
        for _ in 0..n {
          let vname = string(&r)?
          var fs: [(str?, types.Ty)] = []
          let nf = num(&r)?
          for _ in 0..nf {
            let fname: str? = if peek(r) == "-" {
              r.i += 1
              none
            } else {
              string(&r)?
            }
            let t = ty(&r)?
            fs.push((fname, t))
          }
          vs.push(types.VariantDef { name: vname, fields: fs, span: diag.NONE, node: 0 })
        }
        types.TypeDefKind.Enum(vs)
      }
      "O" => types.TypeDefKind.Opaque(string(&r)?)
      k => return bad(r, "a type definition kind, found `{k}`")
    }
    defs.types.push(types.TypeDef {
      name,
      module: 0,
      public: true,
      doc: none,
      params,
      kind,
      span: diag.NONE,
      node: 0,
    })
  }
  expect(&r, "shapes")?
  let ns = num(&r)?
  for _ in 0..ns {
    let name = string(&r)?
    let sp = num(&r)?
    defs.shapes.push(types.ShapeDef {
      name,
      module: 0,
      public: true,
      self_param: sp,
      methods: [],
      builtin: none,
      span: diag.NONE,
    })
  }
  expect(&r, "params")?
  let npar = num(&r)?
  for _ in 0..npar {
    let name = string(&r)?
    defs.params.push(types.TypeParam { name, bounds: [], implicit: false })
  }
  expect(&r, "value")?
  let value_def = opt_num(&r)?
  expect(&r, "err")?
  let err_def = num(&r)?
  let info = mir.types.TyInfo { defs, value_def, err_def }
  expect(&r, "aggs")?
  var aggs: [mir.AggDef] = []
  let na = num(&r)?
  for _ in 0..na {
    let name = string(&r)?
    let fields = mtys(&r)?
    aggs.push(mir.AggDef { name, fields })
  }
  expect(&r, "globals")?
  var globals: [mir.Global] = []
  let ng = num(&r)?
  for _ in 0..ng {
    let name = string(&r)?
    let t = mty(&r)?
    let constant = num(&r)? == 1
    let init: mir.Ex? = if peek(r) == "-" {
      r.i += 1
      none
    } else {
      ex(&r)?
    }
    globals.push(mir.Global { name, ty: t, init, constant, kind: 0 })
  }
  expect(&r, "funcs")?
  var funcs: [mir.Func] = []
  let nf = num(&r)?
  for _ in 0..nf {
    expect(&r, "F")?
    let name = string(&r)?
    let abi = match tok(&r)? {
      "A" => mir.Abi.Auk
      "C" => mir.Abi.C
      a => return bad(r, "an ABI, found `{a}`")
    }
    let ret = mty(&r)?
    var params: [int] = []
    let np = num(&r)?
    for _ in 0..np { params.push(num(&r)?) }
    let vars = mtys(&r)?
    let body = stmts(&r)?
    funcs.push(mir.Func { name, params, ret, vars, body, abi })
  }
  expect(&r, "entry")?
  let entry = opt_num(&r)?
  expect(&r, "locs")?
  var locs: [(str, int, int)] = []
  let nl = num(&r)?
  for _ in 0..nl {
    let f = string(&r)?
    let line = num(&r)?
    let col = num(&r)?
    locs.push((f, line, col))
  }
  expect(&r, "names")?
  var names: {int: str} = {}
  let nn = num(&r)?
  for _ in 0..nn {
    let f = num(&r)?
    names[f] = string(&r)?
  }
  expect(&r, "links")?
  let links = strings(&r)?
  expect(&r, "csyms")?
  let c_syms = strings(&r)?
  if r.i != r.toks.len() { return bad(r, "the end of the dump") }
  let prog = mir.Program { funcs, aggs, globals, entry, locs, names, links, c_syms, exports: {} }
  (prog, info)
}

fn bad<T>(r: Reader, what: str): T! = fail("mir dump: expected {what} at token {r.i}")

fn peek(r: Reader): str = r.toks.get(r.i) else ""

fn tok(r: var Reader): str! {
  if r.i >= r.toks.len() { return bad(r, "more") }
  r.i += 1
  r.toks[r.i - 1]
}

fn expect(r: var Reader, t: str): ()! {
  let x = tok(&r)?
  if x != t { return bad(r, "`{t}`, found `{x}`") }
}

fn num(r: var Reader): int! {
  let t = tok(&r)?
  int.parse(t) else bad(r, "a number, found `{t}`")?
}

fn opt_num(r: var Reader): int?! {
  if peek(r) == "-" {
    r.i += 1
    return none
  }
  num(&r)?
}

fn hex_digit(c: int): int = if c <= 57 { c - 48 } else if c <= 70 { c - 55 } else { c - 87 }

/// A `'` token's bytes.
fn byte_string(r: var Reader): [int]! {
  let t = tok(&r)?
  if !t.starts_with("'") { return bad(r, "a string, found `{t}`") }
  let bs = t.bytes()
  var out: [int] = []
  var i = 1
  while i < bs.len() {
    if bs[i] == 92 {
      out.push(hex_digit(bs[i + 1]) * 16 + hex_digit(bs[i + 2]))
      i += 3
    } else {
      out.push(bs[i])
      i += 1
    }
  }
  out
}

fn string(r: var Reader): str! {
  let t = peek(r)
  if t.starts_with("'") && !t.contains("\\") {
    r.i += 1
    return t.strip_prefix("'") else t
  }
  let bs = byte_string(&r)?
  str.from_utf8(bs)
}

fn strings(r: var Reader): [str]! {
  let n = num(&r)?
  var out: [str] = []
  for _ in 0..n { out.push(string(&r)?) }
  out
}

fn ty(r: var Reader): types.Ty! {
  let t = tok(&r)?
  match t {
    "int" => types.Ty.Int
    "float" => types.Ty.Float
    "bool" => types.Ty.Bool
    "char" => types.Ty.Char
    "str" => types.Ty.Str
    "never" => types.Ty.Never
    "L" => types.Ty.List(ty(&r)?)
    "M" => {
      let k = ty(&r)?
      types.Ty.Map(k, ty(&r)?)
    }
    "T" => types.Ty.Tuple(tys(&r)?)
    "O" => types.Ty.Opt(ty(&r)?)
    "R" => {
      let x = ty(&r)?
      types.Ty.Res(x, ty(&r)?)
    }
    "N" => {
      let d = num(&r)?
      types.Ty.Named(d, tys(&r)?)
    }
    "P" => types.Ty.Param(num(&r)?)
    "A" => types.Ty.Any(num(&r)?)
    "F" => {
      let ps = tys(&r)?
      types.Ty.Fn(ps, ty(&r)?)
    }
    "K" => types.Ty.Task(ty(&r)?)
    "U" => types.Ty.Mut(ty(&r)?)
    "Me" => {
      let x = ty(&r)?
      var u: [(str, int)] = []
      let n = num(&r)?
      for _ in 0..n {
        let name = string(&r)?
        u.push((name, num(&r)?))
      }
      types.Ty.Measured(x, u)
    }
    _ => bad(r, "a type, found `{t}`")
  }
}

fn tys(r: var Reader): [types.Ty]! {
  let n = num(&r)?
  var out: [types.Ty] = []
  for _ in 0..n { out.push(ty(&r)?) }
  out
}

fn mty(r: var Reader): mir.MTy! {
  let t = tok(&r)?
  match t {
    "void" => mir.MTy.Void
    "bool" => mir.MTy.Bool
    "i8" => mir.MTy.I8
    "u8" => mir.MTy.U8
    "i16" => mir.MTy.I16
    "u16" => mir.MTy.U16
    "i32" => mir.MTy.I32
    "u32" => mir.MTy.U32
    "i64" => mir.MTy.I64
    "u64" => mir.MTy.U64
    "f32" => mir.MTy.F32
    "cstr" => mir.MTy.CStr
    "code" => mir.MTy.Code
    "*" => mir.MTy.Ptr(mty(&r)?)
    "D" => mir.MTy.D(ty(&r)?)
    "G" => mir.MTy.Agg(num(&r)?)
    "rt:strbuf" => mir.MTy.Rt(mir.Rt.StrBuf)
    "rt:obj" => mir.MTy.Rt(mir.Rt.Obj)
    "rt:elemops" => mir.MTy.Rt(mir.Rt.ElemOps)
    "rt:task" => mir.MTy.Rt(mir.Rt.Task)
    _ => bad(r, "a machine type, found `{t}`")
  }
}

fn mtys(r: var Reader): [mir.MTy]! {
  let n = num(&r)?
  var out: [mir.MTy] = []
  for _ in 0..n { out.push(mty(&r)?) }
  out
}

fn sel(r: var Reader): mir.Sel! {
  let t = tok(&r)?
  match t {
    "f" => mir.Sel.F(num(&r)?)
    "tag" => mir.Sel.Tag
    "v" => {
      let vi = num(&r)?
      mir.Sel.V(vi, num(&r)?)
    }
    _ => bad(r, "a member, found `{t}`")
  }
}

fn bop(r: var Reader): mir.BOp! {
  let t = tok(&r)?
  match t {
    "add" => mir.BOp.Add
    "sub" => mir.BOp.Sub
    "mul" => mir.BOp.Mul
    "div" => mir.BOp.Div
    "band" => mir.BOp.BitAnd
    "bor" => mir.BOp.BitOr
    "bxor" => mir.BOp.BitXor
    "eq" => mir.BOp.Eq
    "ne" => mir.BOp.Ne
    "lt" => mir.BOp.Lt
    "le" => mir.BOp.Le
    "gt" => mir.BOp.Gt
    "ge" => mir.BOp.Ge
    _ => bad(r, "a binary operator, found `{t}`")
  }
}

fn exs(r: var Reader): [mir.Ex]! {
  let n = num(&r)?
  var out: [mir.Ex] = []
  for _ in 0..n { out.push(ex(&r)?) }
  out
}

fn ex(r: var Reader): mir.Ex! {
  let t = tok(&r)?
  let k = match t {
    "var" => mir.K.Var(num(&r)?)
    "glob" => mir.K.Global(num(&r)?)
    "int" => mir.K.Int(num(&r)?)
    "flt" => mir.K.Float(float.from_bits(num(&r)?))
    "cs" => mir.K.CStr(byte_string(&r)?)
    "zero" => mir.K.Zero
    "fn" => mir.K.FnAddr(mir.FRef.Fn(num(&r)?))
    "fnrt" => mir.K.FnAddr(mir.FRef.Rt(string(&r)?))
    "gaddr" => mir.K.GlobalAddr(num(&r)?)
    "rtg" => mir.K.RtGlobalAddr(string(&r)?)
    "fld" => {
      let b = ex(&r)?
      mir.K.Field(b, sel(&r)?)
    }
    "deref" => mir.K.Deref(ex(&r)?)
    "addr" => mir.K.Addr(ex(&r)?)
    "un" => {
      let op = match tok(&r)? {
        "not" => mir.UOp.Not
        "neg" => mir.UOp.Neg
        "bnot" => mir.UOp.BitNot
        o => return bad(r, "a unary operator, found `{o}`")
      }
      mir.K.Un(op, ex(&r)?)
    }
    "bin" => {
      let op = bop(&r)?
      let a = ex(&r)?
      mir.K.Bin(op, a, ex(&r)?)
    }
    "and" => mir.K.And(exs(&r)?)
    "cast" => mir.K.Cast(ex(&r)?)
    "call" => {
      let c = match tok(&r)? {
        "fn" => mir.Callee.Fn(num(&r)?)
        "rt" => mir.Callee.Rt(string(&r)?)
        "ind" => {
          let code = ex(&r)?
          mir.Callee.Indirect(code, mtys(&r)?)
        }
        "cptr" => mir.Callee.CPtr(ex(&r)?)
        c => return bad(r, "a callee, found `{c}`")
      }
      mir.K.Call(c, exs(&r)?)
    }
    "agg" => {
      let n = num(&r)?
      var ms: [(mir.Sel, mir.Ex)] = []
      for _ in 0..n {
        let s = sel(&r)?
        ms.push((s, ex(&r)?))
      }
      mir.K.Agg(ms)
    }
    "cond" => {
      let c = ex(&r)?
      let a = ex(&r)?
      mir.K.Cond(c, a, ex(&r)?)
    }
    "elem" => {
      let a = ex(&r)?
      mir.K.Elem(a, ex(&r)?)
    }
    "rtf" => {
      let p = ex(&r)?
      let f = match tok(&r)? {
        "len" => mir.RtF.ArrLen
        "data" => mir.RtF.ArrData
        "msg" => mir.RtF.ErrMsg
        f => return bad(r, "a runtime field, found `{f}`")
      }
      mir.K.RtField(p, f)
    }
    "sizeof" => mir.K.SizeOf(mty(&r)?)
    _ => return bad(r, "an expression, found `{t}`")
  }
  mir.Ex { k, ty: mty(&r)? }
}

fn stmts(r: var Reader): [mir.Stmt]! {
  let n = num(&r)?
  var out: [mir.Stmt] = []
  for _ in 0..n { out.push(stmt(&r)?) }
  out
}

fn stmt(r: var Reader): mir.Stmt! {
  let t = tok(&r)?
  match t {
    "let" => {
      let v = num(&r)?
      mir.Stmt.Let(v, ex(&r)?)
    }
    "set" => {
      let p = ex(&r)?
      mir.Stmt.Set(p, ex(&r)?)
    }
    "do" => mir.Stmt.Do(ex(&r)?)
    "if" => {
      let c = ex(&r)?
      let a = stmts(&r)?
      mir.Stmt.If(c, a, stmts(&r)?)
    }
    "loop" => {
      let a = stmts(&r)?
      mir.Stmt.Loop(a, stmts(&r)?)
    }
    "break" => mir.Stmt.Break
    "cont" => mir.Stmt.Continue
    "label" => mir.Stmt.Label(num(&r)?)
    "goto" => mir.Stmt.Goto(num(&r)?)
    "ret0" => mir.Stmt.Ret(none)
    "ret1" => mir.Stmt.Ret(some(ex(&r)?))
    "unr" => mir.Stmt.Unreachable
    "loc" => mir.Stmt.Loc(num(&r)?)
    _ => bad(r, "a statement, found `{t}`")
  }
}
