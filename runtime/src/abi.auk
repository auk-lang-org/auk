// The runtime's ABI in the `raw` dialect: every type of runtime/c/auk_rt.h (and the task and
// channel objects of task.c and chan.c) as a `raw struct`/`raw union`, its constants as
// `raw let`s (docs/lowlevel.md, sections 2 and 8). auk_rt.h stays the contract while C and Auk
// are linked together: every size and offset is a `raw assert`, and runtime/test/abi/run.sh
// compares each with the C compiler's sizeof/offsetof (with the real auk_rt.h).
//
// Names drop the `Auk` prefix (`AukStr` is `abi.Str`, `AUK_K_STR` is `abi.K_STR`); fields keep
// C's names except `fn` (a keyword), which is `func`. One field per line, and each type's C
// name in a `/// C:` line: run.sh reads both.
//
// The dialect has no type aliases, so auk_rt.h's function-pointer typedefs are written out
// where they are used:
//   AukRetainFn   raw.Fn<(raw.Ptr<()>) => ()>
//   AukEqFn       raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => bool>
//   AukCmpFn      raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => i32>
//   AukHashFn     raw.Fn<(raw.Ptr<()>) => u64>
//   AukShowFn     raw.Fn<(raw.Ptr<()>) => raw.Ptr<Str>>
//   AukCopyFn     raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>        (src, dst)
//   AukObjCopyFn  raw.Fn<(raw.Ptr<Obj>) => raw.Ptr<Obj>>
//   AukDropFn     raw.Fn<(raw.Ptr<Obj>) => ()>
//   AukThunk      raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>        (env, out)
//   AukTestFn     raw.Fn<() => raw.Ptr<Err>>
//   AukMainFn     raw.Fn<(raw.Ptr<Arr>) => ResInt>
//   AukDbgEvalHook raw.Fn<(u32, u32, raw.Ptr<u8>, raw.Ptr<DbgCompiled>, raw.Ptr<raw.Ptr<u8>>) => bool>
// `const T *` is `raw.Ptr<T>`, C's `int` is `i32`, `size_t` is `usize`; `_Atomic` fields are
// plain (use raw.atomic_* on their addresses). Opaque C types (AukHeap) are `raw.Ptr<()>`.

// ---- object kinds (AukHeader.kind) ----

pub raw let K_STR: u32 = 1
pub raw let K_ARR: u32 = 2
pub raw let K_MAP: u32 = 3
pub raw let K_ERR: u32 = 4
pub raw let K_OBJ: u32 = 5
pub raw let K_TASK: u32 = 6
pub raw let K_CONN: u32 = 7
pub raw let K_LISTENER: u32 = 8
pub raw let K_CHAN: u32 = 9
pub raw let K_FRAME: u32 = 10

/// AukHeader.flags: the object has a heap Link prefix (heap.c).
pub raw let TRACKED: u32 = 1

/// Is an object of this kind a handle (never tracked, shared by reference count)?
pub fn is_handle(kind: u32): bool = kind >= K_TASK && kind <= K_FRAME

// ---- AukValue tags ----

pub raw let V_NULL: u32 = 0
pub raw let V_BOOL: u32 = 1
pub raw let V_INT: u32 = 2
pub raw let V_FLOAT: u32 = 3
pub raw let V_STR: u32 = 4
pub raw let V_LIST: u32 = 5
pub raw let V_MAP: u32 = 6

// ---- other constants ----

/// AukStrBuf.small's size.
pub raw let SB_SMALL: i64 = 40
/// The stack of the thread a program's `main` and each test run on.
pub raw let MAIN_STACK: usize = 268435456
/// The stack of each task.
pub raw let TASK_STACK: usize = 33554432

// gui.c's wire protocol (AukWireMsg.op)
pub raw let WIRE_OPEN: u8 = 1
pub raw let WIRE_CLOSE: u8 = 2
pub raw let WIRE_PRESENT: u8 = 3
pub raw let WIRE_BYE: u8 = 4
pub raw let WIRE_REPLY: u8 = 100
pub raw let WIRE_EVENT: u8 = 101
pub raw let WIRE_METRICS: u8 = 102
pub raw let WIRE_PRESENTED: u8 = 103

// ffi.c: how a list's elements are laid out in a C array
pub raw let FFI_RAW: i64 = 0
pub raw let FFI_I8: i64 = 1
pub raw let FFI_U8: i64 = 2
pub raw let FFI_I16: i64 = 3
pub raw let FFI_U16: i64 = 4
pub raw let FFI_I32: i64 = 5
pub raw let FFI_U32: i64 = 6
pub raw let FFI_F32: i64 = 7

// ---- the header and element ops ----

/// C: AukHeader
/// Every heap object begins with this (16 bytes). rc < 0 marks an immortal object; rc is
/// atomic.
pub raw struct Header {
  rc: i64,
  kind: u32,
  flags: u32,
}

raw assert raw.size_of<Header>() == 16 && raw.align_of<Header>() == 8
raw assert raw.offset_of<Header>(.rc) == 0
raw assert raw.offset_of<Header>(.kind) == 8
raw assert raw.offset_of<Header>(.flags) == 12

/// C: AukElemOps
/// How a container handles its elements (null functions for plain data).
pub raw struct ElemOps {
  size: usize,
  retain: raw.Fn<(raw.Ptr<()>) => ()>,
  release: raw.Fn<(raw.Ptr<()>) => ()>,
  eq: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => bool>,
  cmp: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => i32>,
  hash: raw.Fn<(raw.Ptr<()>) => u64>,
  show: raw.Fn<(raw.Ptr<()>) => raw.Ptr<Str>>,
  copy: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>,
}

raw assert raw.size_of<ElemOps>() == 64 && raw.align_of<ElemOps>() == 8
raw assert raw.offset_of<ElemOps>(.size) == 0
raw assert raw.offset_of<ElemOps>(.retain) == 8
raw assert raw.offset_of<ElemOps>(.release) == 16
raw assert raw.offset_of<ElemOps>(.eq) == 24
raw assert raw.offset_of<ElemOps>(.cmp) == 32
raw assert raw.offset_of<ElemOps>(.hash) == 40
raw assert raw.offset_of<ElemOps>(.show) == 48
raw assert raw.offset_of<ElemOps>(.copy) == 56

// ---- heap objects ----

/// C: AukStr
/// Immutable UTF-8 string; data is NUL-terminated (data[len_bytes] == 0).
pub raw struct Str {
  h: Header,
  len_bytes: i64,
  len_chars: i64,
  is_ascii: bool,
  data: [u8; ..],
}

raw assert raw.size_of<Str>() == 40 && raw.align_of<Str>() == 8
raw assert raw.offset_of<Str>(.h) == 0
raw assert raw.offset_of<Str>(.len_bytes) == 16
raw assert raw.offset_of<Str>(.len_chars) == 24
raw assert raw.offset_of<Str>(.is_ascii) == 32
raw assert raw.offset_of<Str>(.data) == 33

/// C: AukArr
/// An array. A slice view has base != null.
pub raw struct Arr {
  h: Header,
  ops: raw.Ptr<ElemOps>,
  len: i64,
  cap: i64,
  data: raw.Ptr<u8>,
  base: raw.Ptr<Arr>,
}

raw assert raw.size_of<Arr>() == 56 && raw.align_of<Arr>() == 8
raw assert raw.offset_of<Arr>(.h) == 0
raw assert raw.offset_of<Arr>(.ops) == 16
raw assert raw.offset_of<Arr>(.len) == 24
raw assert raw.offset_of<Arr>(.cap) == 32
raw assert raw.offset_of<Arr>(.data) == 40
raw assert raw.offset_of<Arr>(.base) == 48

/// C: AukMap
/// Insertion-ordered hash map: an index table over an entries array.
pub raw struct Map {
  h: Header,
  kops: raw.Ptr<ElemOps>,
  vops: raw.Ptr<ElemOps>,
  len: i64,
  n: i64,
  cap: i64,
  entries: raw.Ptr<u8>,
  voff: i64,
  stride: i64,
  hashes: raw.Ptr<u64>,
  dead: raw.Ptr<bool>,
  index: raw.Ptr<u64>,
  icap: i64,
}

raw assert raw.size_of<Map>() == 112 && raw.align_of<Map>() == 8
raw assert raw.offset_of<Map>(.h) == 0
raw assert raw.offset_of<Map>(.kops) == 16
raw assert raw.offset_of<Map>(.vops) == 24
raw assert raw.offset_of<Map>(.len) == 32
raw assert raw.offset_of<Map>(.n) == 40
raw assert raw.offset_of<Map>(.cap) == 48
raw assert raw.offset_of<Map>(.entries) == 56
raw assert raw.offset_of<Map>(.voff) == 64
raw assert raw.offset_of<Map>(.stride) == 72
raw assert raw.offset_of<Map>(.hashes) == 80
raw assert raw.offset_of<Map>(.dead) == 88
raw assert raw.offset_of<Map>(.index) == 96
raw assert raw.offset_of<Map>(.icap) == 104

/// Map entry i's key (auk__map_key).
pub fn map_key(m: raw.Ptr<Map>, i: i64): raw.Ptr<u8> uses raw = m.entries.offset(i * m.stride)

/// Map entry i's value (auk__map_val).
pub fn map_val(m: raw.Ptr<Map>, i: i64): raw.Ptr<u8> uses raw =
  m.entries.offset(i * m.stride + m.voff)

/// C: AukErrPayload
pub raw struct ErrPayload {
  type_id: u32,
  data: raw.Ptr<()>,
  ops: raw.Ptr<ElemOps>,
}

raw assert raw.size_of<ErrPayload>() == 24 && raw.align_of<ErrPayload>() == 8
raw assert raw.offset_of<ErrPayload>(.type_id) == 0
raw assert raw.offset_of<ErrPayload>(.data) == 8
raw assert raw.offset_of<ErrPayload>(.ops) == 16

/// C: AukErr
pub raw struct Err {
  h: Header,
  msg: raw.Ptr<Str>,
  code: i64,
  cause: raw.Ptr<Err>,
  payload: ErrPayload,
}

raw assert raw.size_of<Err>() == 64 && raw.align_of<Err>() == 8
raw assert raw.offset_of<Err>(.h) == 0
raw assert raw.offset_of<Err>(.msg) == 16
raw assert raw.offset_of<Err>(.code) == 24
raw assert raw.offset_of<Err>(.cause) == 32
raw assert raw.offset_of<Err>(.payload) == 40

/// C: AukObj
/// Generic heap object with a destructor (closure envs, boxes).
pub raw struct Obj {
  h: Header,
  drop: raw.Fn<(raw.Ptr<Obj>) => ()>,
  copy: raw.Fn<(raw.Ptr<Obj>) => raw.Ptr<Obj>>,
}

raw assert raw.size_of<Obj>() == 32 && raw.align_of<Obj>() == 8
raw assert raw.offset_of<Obj>(.h) == 0
raw assert raw.offset_of<Obj>(.drop) == 16
raw assert raw.offset_of<Obj>(.copy) == 24

/// C: AukClosure; func=fn
pub raw struct Closure {
  func: raw.Ptr<()>,
  env: raw.Ptr<Obj>,
}

raw assert raw.size_of<Closure>() == 16 && raw.align_of<Closure>() == 8
raw assert raw.offset_of<Closure>(.func) == 0
raw assert raw.offset_of<Closure>(.env) == 8

/// C: AukConn
/// A TCP connection (tls: the TLS session over fd, null for plain TCP).
pub raw struct Conn {
  h: Header,
  fd: i32,
  tls: raw.Ptr<()>,
}

raw assert raw.size_of<Conn>() == 32 && raw.align_of<Conn>() == 8
raw assert raw.offset_of<Conn>(.h) == 0
raw assert raw.offset_of<Conn>(.fd) == 16
raw assert raw.offset_of<Conn>(.tls) == 24

/// C: AukListener
pub raw struct Listener {
  h: Header,
  fd: i32,
  port: i64,
}

raw assert raw.size_of<Listener>() == 32 && raw.align_of<Listener>() == 8
raw assert raw.offset_of<Listener>(.h) == 0
raw assert raw.offset_of<Listener>(.fd) == 16
raw assert raw.offset_of<Listener>(.port) == 24

/// C: AukFrame
/// A pixels.Frame: w×hgt colors 0xTTRRGGBB inline after the header.
pub raw struct Frame {
  h: Header,
  w: i64,
  hgt: i64,
  data: [u32; ..],
}

raw assert raw.size_of<Frame>() == 32 && raw.align_of<Frame>() == 8
raw assert raw.offset_of<Frame>(.h) == 0
raw assert raw.offset_of<Frame>(.w) == 16
raw assert raw.offset_of<Frame>(.hgt) == 24
raw assert raw.offset_of<Frame>(.data) == 32

// ---- the core `Value` enum ----

/// C: __typeof__(((AukValue *)0)->u)
pub raw union ValueU {
  b: bool,
  i: i64,
  f: float,
  s: raw.Ptr<Str>,
  list: raw.Ptr<Arr>,
  map: raw.Ptr<Map>,
}

raw assert raw.size_of<ValueU>() == 8 && raw.align_of<ValueU>() == 8

/// C: AukValue
pub raw struct Value {
  tag: u32,
  u: ValueU,
}

raw assert raw.size_of<Value>() == 16 && raw.align_of<Value>() == 8
raw assert raw.offset_of<Value>(.tag) == 0
raw assert raw.offset_of<Value>(.u) == 8

// ---- optionals (`T?`) and results (`T!`) ----

/// C: AukOpt_int
pub raw struct OptInt {
  some: bool,
  val: i64,
}

raw assert raw.size_of<OptInt>() == 16 && raw.offset_of<OptInt>(.val) == 8

/// C: AukOpt_float
pub raw struct OptFloat {
  some: bool,
  val: float,
}

raw assert raw.size_of<OptFloat>() == 16 && raw.offset_of<OptFloat>(.val) == 8

/// C: AukOpt_bool
pub raw struct OptBool {
  some: bool,
  val: bool,
}

raw assert raw.size_of<OptBool>() == 2 && raw.offset_of<OptBool>(.val) == 1

/// C: AukOpt_char
pub raw struct OptChar {
  some: bool,
  val: u32,
}

raw assert raw.size_of<OptChar>() == 8 && raw.offset_of<OptChar>(.val) == 4

/// C: AukOpt_str
pub raw struct OptStr {
  some: bool,
  val: raw.Ptr<Str>,
}

raw assert raw.size_of<OptStr>() == 16 && raw.offset_of<OptStr>(.val) == 8

/// C: AukOpt_arr
pub raw struct OptArr {
  some: bool,
  val: raw.Ptr<Arr>,
}

raw assert raw.size_of<OptArr>() == 16 && raw.offset_of<OptArr>(.val) == 8

/// C: AukOpt_value
pub raw struct OptValue {
  some: bool,
  val: Value,
}

raw assert raw.size_of<OptValue>() == 24 && raw.offset_of<OptValue>(.val) == 8

/// C: AukRes_unit
pub raw struct ResUnit {
  ok: bool,
  val: u8,
  err: raw.Ptr<Err>,
}

raw assert raw.size_of<ResUnit>() == 16 &&
  raw.offset_of<ResUnit>(.val) == 1 &&
  raw.offset_of<ResUnit>(.err) == 8

/// C: AukRes_int
pub raw struct ResInt {
  ok: bool,
  val: i64,
  err: raw.Ptr<Err>,
}

raw assert raw.size_of<ResInt>() == 24 &&
  raw.offset_of<ResInt>(.val) == 8 &&
  raw.offset_of<ResInt>(.err) == 16

/// C: AukRes_float
pub raw struct ResFloat {
  ok: bool,
  val: float,
  err: raw.Ptr<Err>,
}

raw assert raw.size_of<ResFloat>() == 24 &&
  raw.offset_of<ResFloat>(.val) == 8 &&
  raw.offset_of<ResFloat>(.err) == 16

/// C: AukRes_str
pub raw struct ResStr {
  ok: bool,
  val: raw.Ptr<Str>,
  err: raw.Ptr<Err>,
}

raw assert raw.size_of<ResStr>() == 24 &&
  raw.offset_of<ResStr>(.val) == 8 &&
  raw.offset_of<ResStr>(.err) == 16

/// C: AukRes_arr
pub raw struct ResArr {
  ok: bool,
  val: raw.Ptr<Arr>,
  err: raw.Ptr<Err>,
}

raw assert raw.size_of<ResArr>() == 24 &&
  raw.offset_of<ResArr>(.val) == 8 &&
  raw.offset_of<ResArr>(.err) == 16

/// C: AukRes_conn
pub raw struct ResConn {
  ok: bool,
  val: raw.Ptr<Conn>,
  err: raw.Ptr<Err>,
}

raw assert raw.size_of<ResConn>() == 24 &&
  raw.offset_of<ResConn>(.val) == 8 &&
  raw.offset_of<ResConn>(.err) == 16

/// C: AukRes_listener
pub raw struct ResListener {
  ok: bool,
  val: raw.Ptr<Listener>,
  err: raw.Ptr<Err>,
}

raw assert raw.size_of<ResListener>() == 24 &&
  raw.offset_of<ResListener>(.val) == 8 &&
  raw.offset_of<ResListener>(.err) == 16

/// C: AukRes_value
pub raw struct ResValue {
  ok: bool,
  val: Value,
  err: raw.Ptr<Err>,
}

raw assert raw.size_of<ResValue>() == 32 &&
  raw.offset_of<ResValue>(.val) == 8 &&
  raw.offset_of<ResValue>(.err) == 24

// ---- helpers' structs ----

/// C: AukStrBuf
/// Growable string builder; zero-initialized by its owner. Up to SB_SMALL bytes stay in
/// `small` (buf null, cap 0). No pointer into itself, so it may be moved.
pub raw struct StrBuf {
  buf: raw.Ptr<u8>,
  len: i64,
  cap: i64,
  small: [u8; 40],
}

raw assert raw.size_of<StrBuf>() == 64 && raw.align_of<StrBuf>() == 8
raw assert raw.offset_of<StrBuf>(.buf) == 0
raw assert raw.offset_of<StrBuf>(.len) == 8
raw assert raw.offset_of<StrBuf>(.cap) == 16
raw assert raw.offset_of<StrBuf>(.small) == 24
raw assert raw.size_of<StrBuf>() - raw.offset_of<StrBuf>(.small) == usize(SB_SMALL)

/// C: AukTmp
/// A scratch element buffer: on the stack when it fits, else malloc'd.
pub raw struct Tmp {
  stack: [u8; 256],
  heap: raw.Ptr<u8>,
}

raw assert raw.size_of<Tmp>() == 264 && raw.align_of<Tmp>() == 8
raw assert raw.offset_of<Tmp>(.stack) == 0
raw assert raw.offset_of<Tmp>(.heap) == 256

/// C: AukPanic
/// A recovered panic: its message and where it happened (malloc'd C strings).
pub raw struct Panic {
  msg: raw.Ptr<u8>,
  loc: raw.Ptr<u8>,
}

raw assert raw.size_of<Panic>() == 16 && raw.align_of<Panic>() == 8
raw assert raw.offset_of<Panic>(.msg) == 0
raw assert raw.offset_of<Panic>(.loc) == 8

/// C: AukStrCase
/// A literal arm of a `match` on `str`.
pub raw struct StrCase {
  s: raw.Ptr<u8>,
  len: i64,
}

raw assert raw.size_of<StrCase>() == 16 && raw.align_of<StrCase>() == 8
raw assert raw.offset_of<StrCase>(.s) == 0
raw assert raw.offset_of<StrCase>(.len) == 8

// ---- dbg.c ----

/// C: AukDbgFrame
/// A frame record, as generated code lays it out.
pub raw struct DbgFrame {
  func: i64,
  parent: raw.Ptr<DbgFrame>,
  site: i64,
  slots: [raw.Ptr<()>; ..],
}

raw assert raw.size_of<DbgFrame>() == 24 && raw.align_of<DbgFrame>() == 8
raw assert raw.offset_of<DbgFrame>(.func) == 0
raw assert raw.offset_of<DbgFrame>(.parent) == 8
raw assert raw.offset_of<DbgFrame>(.site) == 16
raw assert raw.offset_of<DbgFrame>(.slots) == 24

/// C: AukDbgCompiled
/// An expression compiled for the debugger: run(addresses of the locals in slots order).
pub raw struct DbgCompiled {
  run: raw.Fn<(raw.Ptr<raw.Ptr<()>>) => raw.Ptr<Str>>,
  slots: raw.Ptr<u32>,
  nslots: i64,
  ty: raw.Ptr<u8>,
}

raw assert raw.size_of<DbgCompiled>() == 32 && raw.align_of<DbgCompiled>() == 8
raw assert raw.offset_of<DbgCompiled>(.run) == 0
raw assert raw.offset_of<DbgCompiled>(.slots) == 8
raw assert raw.offset_of<DbgCompiled>(.nslots) == 16
raw assert raw.offset_of<DbgCompiled>(.ty) == 24

// ---- gui.c's wire messages ----

/// C: AukWireBuf
pub raw struct WireBuf {
  sb: StrBuf,
}

raw assert raw.size_of<WireBuf>() == 64 && raw.offset_of<WireBuf>(.sb) == 0

/// C: AukWireReader
pub raw struct WireReader {
  b: raw.Ptr<u8>,
  n: i64,
  i: i64,
}

raw assert raw.size_of<WireReader>() == 24 && raw.align_of<WireReader>() == 8
raw assert raw.offset_of<WireReader>(.b) == 0
raw assert raw.offset_of<WireReader>(.n) == 8
raw assert raw.offset_of<WireReader>(.i) == 16

/// C: AukWireMsg
pub raw struct WireMsg {
  op: u8,
  body: raw.Ptr<u8>,
  n: i64,
  fd: i32,
  r: WireReader,
}

raw assert raw.size_of<WireMsg>() == 56 && raw.align_of<WireMsg>() == 8
raw assert raw.offset_of<WireMsg>(.op) == 0
raw assert raw.offset_of<WireMsg>(.body) == 8
raw assert raw.offset_of<WireMsg>(.n) == 16
raw assert raw.offset_of<WireMsg>(.fd) == 24
raw assert raw.offset_of<WireMsg>(.r) == 32

// ---- the handles of task.c and chan.c (not in auk_rt.h: their layouts hold pthread types,
// the platform's, so their offsets past the first pthread field are per target) ----

/// C: struct AukTask; func=fn
pub raw struct Task {
  h: Header,
  th: cfacts.PthreadT,
  mu: cfacts.PthreadMutex,
  func: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>,
  args: raw.Ptr<()>,
  result: raw.Ptr<()>,
  result_size: usize,
  ops: raw.Ptr<ElemOps>,
  joined: bool,
  panic: raw.Ptr<Panic>,
  observed: bool,
  cancel: bool,
  done: bool,
  kids: raw.Ptr<raw.Ptr<Task>>,
  nkids: i64,
  capkids: i64,
  heap: raw.Ptr<()>,
  args_drop: raw.Fn<(raw.Ptr<()>) => ()>,
  hint: usize,
}

raw assert raw.align_of<Task>() == 8
raw assert raw.offset_of<Task>(.h) == 0
raw assert raw.offset_of<Task>(.th) == 16
raw assert raw.offset_of<Task>(.mu) == 16 + raw.size_of<cfacts.PthreadT>()

raw assert raw.offset_of<Task>(.func) ==
  raw.offset_of<Task>(.mu) + raw.size_of<cfacts.PthreadMutex>()

raw assert raw.offset_of<Task>(.args) == raw.offset_of<Task>(.func) + 8
raw assert raw.offset_of<Task>(.result) == raw.offset_of<Task>(.func) + 16
raw assert raw.offset_of<Task>(.result_size) == raw.offset_of<Task>(.func) + 24
raw assert raw.offset_of<Task>(.ops) == raw.offset_of<Task>(.func) + 32
raw assert raw.offset_of<Task>(.joined) == raw.offset_of<Task>(.func) + 40
raw assert raw.offset_of<Task>(.panic) == raw.offset_of<Task>(.func) + 48
raw assert raw.offset_of<Task>(.observed) == raw.offset_of<Task>(.func) + 56
raw assert raw.offset_of<Task>(.cancel) == raw.offset_of<Task>(.func) + 57
raw assert raw.offset_of<Task>(.done) == raw.offset_of<Task>(.func) + 58
raw assert raw.offset_of<Task>(.kids) == raw.offset_of<Task>(.func) + 64
raw assert raw.offset_of<Task>(.nkids) == raw.offset_of<Task>(.func) + 72
raw assert raw.offset_of<Task>(.capkids) == raw.offset_of<Task>(.func) + 80
raw assert raw.offset_of<Task>(.heap) == raw.offset_of<Task>(.func) + 88
raw assert raw.offset_of<Task>(.args_drop) == raw.offset_of<Task>(.func) + 96
raw assert raw.offset_of<Task>(.hint) == raw.offset_of<Task>(.func) + 104
raw assert raw.size_of<Task>() == raw.offset_of<Task>(.func) + 112

/// C: struct AukChan
/// An unbounded FIFO shared by every copy of a channel.
pub raw struct Chan {
  h: Header,
  lock: cfacts.PthreadMutex,
  cv: cfacts.PthreadCond,
  ops: raw.Ptr<ElemOps>,
  items: raw.Ptr<u8>,
  size: usize,
  cap: i64,
  head: i64,
  count: i64,
  closed: bool,
}

raw assert raw.align_of<Chan>() == 8
raw assert raw.offset_of<Chan>(.h) == 0
raw assert raw.offset_of<Chan>(.lock) == 16
raw assert raw.offset_of<Chan>(.cv) == 16 + raw.size_of<cfacts.PthreadMutex>()
raw assert raw.offset_of<Chan>(.ops) == raw.offset_of<Chan>(.cv) + raw.size_of<cfacts.PthreadCond>()
raw assert raw.offset_of<Chan>(.items) == raw.offset_of<Chan>(.ops) + 8
raw assert raw.offset_of<Chan>(.size) == raw.offset_of<Chan>(.ops) + 16
raw assert raw.offset_of<Chan>(.cap) == raw.offset_of<Chan>(.ops) + 24
raw assert raw.offset_of<Chan>(.head) == raw.offset_of<Chan>(.ops) + 32
raw assert raw.offset_of<Chan>(.count) == raw.offset_of<Chan>(.ops) + 40
raw assert raw.offset_of<Chan>(.closed) == raw.offset_of<Chan>(.ops) + 48
raw assert raw.size_of<Chan>() == raw.offset_of<Chan>(.ops) + 56
