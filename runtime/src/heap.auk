/// Per-task heaps: what makes a crashed task leave nothing behind. (Was runtime/c/heap.c,
/// ported line by line; `struct AukHeap` is `Heap`, opaque to the rest of the runtime.)
///
/// Every task thread allocates into a heap of its own. A tracked object has a hidden prefix just
/// before its header (Link: the heap's doubly linked list, and the heap itself), and its header's
/// flags say so; objects allocated with no current heap (the main thread, constants, handles)
/// have no prefix and are not tracked.
///
/// Nothing crosses a task boundary by reference: spawn arguments are deep-copied into the new
/// task's heap, `await` deep-copies the result into the awaiter's, and channels copy messages.
/// Only handles (tasks, connections, listeners, channels, frames) are shared, and they are never
/// tracked. So when a task's heap goes (its task crashed, was cancelled or was freed), no object
/// outside the heap can point into it, and sweep frees everything still in it, whatever its
/// reference count says.
///
/// Handles live outside every heap, so a heap also keeps a ledger of the references its task
/// took on handles (creating one counts, as do retains, minus releases). References held only by
/// the frames of a crashed task are on the ledger and nowhere else: the sweep gives them back,
/// closing the connections the task still had open.

// the rest of the runtime (C, or another module's `export fn`, which such an `extern fn` resolves to)
// pthreads
extern fn auk__str_cursor_reset() = "void auk__str_cursor_reset(void)"
extern fn pthread_mutex_init(m: raw.Ptr<cfacts.PthreadMutex>, attr: raw.Ptr<()>): i32 =
  "int pthread_mutex_init(void *, const void *)"
extern fn pthread_mutex_destroy(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_destroy(void *)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"

/// The prefix of a tracked object (32 bytes, so the header stays 16-byte aligned).
raw struct Link {
  prev: raw.Ptr<Link>,
  next: raw.Ptr<Link>,
  heap: raw.Ptr<Heap>,
  pad: usize,
}

raw assert raw.size_of<Link>() == 32

/// The handle ledger: handle address -> references held (open addressing, linear probing;
/// key 0 is an empty slot, a removed entry keeps its key with count 0 until the next grow).
raw struct Ledger {
  keys: raw.Ptr<usize>,
  counts: raw.Ptr<i64>,
  cap: i64,
  used: i64,
}

/// C: struct AukHeap
raw struct Heap {
  lock: cfacts.PthreadMutex,
  /// the list's sentinel
  head: Link,
  handles_lock: cfacts.PthreadMutex,
  handles: Ledger,
  /// being swept: freeing an object leaves its memory on the list for the sweep to free last
  /// (lock held to read or write)
  sweeping: bool,
}

/// A reference count no release can bring to zero while a heap is swept.
raw let DYING: i64 = 9223372036854775807 / 4

raw thread var cur_heap: raw.Ptr<Heap> = raw.null()

// ---- the small-block pool --------------------------------------------------------------------
//
// Object memory of up to POOL_MAX bytes (the Link prefix included) comes from size classes of
// 16 bytes instead of malloc: class c holds blocks of c * 16 bytes. Each thread keeps a free
// list per class and carves new blocks from CHUNK-byte chunks of its own (malloc'd, never given
// back). Freeing pushes a block on the freeing thread's list, whichever thread allocated it, so
// blocks can move between threads; a task's thread hands its lists to a global spill (under a
// lock) when it ends (auk__heap_thread_end), and a thread whose list is empty takes the spill's
// before carving. An object's class is in its header's flags (bits 8 to 15; 0: malloc'd).

raw let POOL_MAX: usize = 512
raw let NCLASS: i64 = 33
raw let CHUNK: usize = 65536
raw let CLASS_SHIFT: u32 = 8

/// A free block: the first word links the class's list.
raw struct FreeBlock {
  next: raw.Ptr<FreeBlock>,
}

/// One thread's pool.
raw struct Pool {
  free: [raw.Ptr<FreeBlock>; 33],
  /// the rest of the current chunk
  bump: raw.Ptr<u8>,
  end: raw.Ptr<u8>,
}

raw thread var pool: Pool = Pool {}

/// The free blocks of threads that have ended, by class (under spill_lock); spill_n counts the
/// classes with any, read without the lock to skip it when there are none.
raw var spill: [raw.Ptr<FreeBlock>; 33] = []
raw var spill_n: i64 = 0
raw var spill_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER

/// The class of an object of total bytes (0 when too big for the pool).
fn class_for(total: usize): i64 = if total <= POOL_MAX { i64((total + 15) >> 4) } else { 0 }

/// The class recorded in h's flags.
fn class_of(h: raw.Ptr<abi.Header>): i64 uses raw = i64((h.flags >> CLASS_SHIFT) & 255)

/// A zeroed block of class c.
fn pool_alloc(c: i64): raw.Ptr<u8> uses raw, ffi {
  let q = pool_take(c)
  raw.fill(q, 0, usize(c) * 16)
  q
}

/// A block of class c (its bytes as they are).
fn pool_take(c: i64): raw.Ptr<u8> uses raw, ffi {
  let p = raw.addr_of(&pool)
  let lists: raw.Ptr<raw.Ptr<FreeBlock>> = raw.cast(raw.field_addr(p, .free))
  let b = lists.at(c)
  if raw.likely(!b.is_null()) {
    lists.at(c) = b.next
    return raw.cast(b)
  }
  pool_refill(p, c, usize(c) * 16)
}

/// pool_alloc's slow path: the spill's blocks of class c, else a block carved from the chunk.
fn pool_refill(p: raw.Ptr<Pool>, c: i64, n: usize): raw.Ptr<u8> uses raw, ffi {
  let lists: raw.Ptr<raw.Ptr<FreeBlock>> = raw.cast(raw.field_addr(p, .free))
  if raw.atomic_load(raw.addr_of(&spill_n), raw.Order.Relaxed) > 0 {
    let sp: raw.Ptr<raw.Ptr<FreeBlock>> = raw.cast(raw.addr_of(&spill))
    let _ = pthread_mutex_lock(raw.addr_of(&spill_lock))
    let b = sp.at(c)
    if !b.is_null() {
      sp.at(c) = raw.null()
      let _ = raw.atomic_sub(raw.addr_of(&spill_n), 1, raw.Order.Relaxed)
    }
    let _ = pthread_mutex_unlock(raw.addr_of(&spill_lock))
    if !b.is_null() {
      lists.at(c) = b.next
      return raw.cast(b)
    }
  }
  if p.bump.is_null() || p.end.int() - p.bump.int() < i64(n) {
    let chunk: raw.Ptr<u8> = raw.cast(rc.auk__xmalloc(CHUNK))
    p.bump = chunk
    p.end = chunk.offset(i64(CHUNK))
  }
  let q = p.bump
  p.bump = q.offset(i64(n))
  q
}

/// Give a block of class c back (to this thread's list).
fn pool_free(q: raw.Ptr<()>, c: i64) uses raw {
  let lists: raw.Ptr<raw.Ptr<FreeBlock>> = raw.cast(raw.field_addr(raw.addr_of(&pool), .free))
  let b: raw.Ptr<FreeBlock> = raw.cast(q)
  b.next = lists.at(c)
  lists.at(c) = b
}

/// Free the memory of an object's block: base is where it starts (its Link when tracked).
fn block_free(base: raw.Ptr<()>, c: i64) uses raw {
  if c == 0 {
    raw.free(base)
  } else {
    pool_free(base, c)
  }
}

/// Memory for an object of total bytes (zeroed when zero); sets *class to its class.
fn block_alloc(total: usize, class: raw.Ptr<i64>, zero: bool): raw.Ptr<()> uses raw, ffi {
  let c = class_for(total)
  class.store(c)
  if c == 0 {
    return if zero { rc.auk__xcalloc(1, total) } else { rc.auk__xmalloc(total) }
  }
  raw.cast(if zero { pool_alloc(c) } else { pool_take(c) })
}

// ---- buffers: memory whose size its owner keeps (a list's elements, a map's tables) ----------
//
// A buffer of n bytes comes from the pool when n <= POOL_MAX, else from malloc; the owner
// passes the same n back to resize or free it (class_for(n) says which). The bytes of a new
// buffer are unspecified unless zeroed.

/// A buffer of n bytes.
pub export fn auk__buf_alloc(n: usize): raw.Ptr<u8> uses raw, ffi {
  let c = class_for(n)
  if c == 0 {
    return raw.cast(rc.auk__xmalloc(n))
  }
  pool_take(c)
}

/// A zeroed buffer of n bytes.
pub export fn auk__buf_zalloc(n: usize): raw.Ptr<u8> uses raw, ffi {
  let c = class_for(n)
  if c == 0 {
    return raw.cast(rc.auk__xcalloc(1, n))
  }
  let q = pool_take(c)
  raw.fill(q, 0, n)
  q
}

/// Free the buffer p of n bytes (null is nothing).
pub export fn auk__buf_free(p: raw.Ptr<u8>, n: usize) uses raw {
  if p.is_null() {
    return
  }
  block_free(raw.cast(p), class_for(n))
}

/// The buffer p of old bytes (null when old is 0), now n bytes: the first min(old, n) kept.
pub export fn auk__buf_resize(p: raw.Ptr<u8>, old: usize, n: usize): raw.Ptr<u8> uses raw, ffi {
  let oc = if p.is_null() { i64(0) } else { class_for(old) }
  let nc = class_for(n)
  if oc == nc && !p.is_null() {
    if oc != 0 {
      return p
    }
    return raw.cast(rc.auk__xrealloc(raw.cast(p), n))
  }
  if oc == 0 && nc == 0 {
    return raw.cast(rc.auk__xrealloc(raw.cast(p), n))
  }
  let q = auk__buf_alloc(n)
  if !p.is_null() {
    raw.copy(q, p, if old < n { old } else { n })
    auk__buf_free(p, old)
  }
  q
}

/// The capacity, at least cap, of a buffer of elements of size bytes that fills its pool
/// block (cap itself when it isn't pooled), so `cap * size` stays in the same class.
pub fn buf_fit(cap: i64, size: usize): i64 {
  if size == 0 || cap <= 0 {
    return cap
  }
  let c = class_for(usize(cap) * size)
  if c == 0 {
    return cap
  }
  i64(usize(c) * 16 / size)
}

/// A thread that allocated or freed objects is ending: its free blocks go to the spill, for
/// other threads to use. (The rest of its chunk is lost: at most CHUNK bytes.)
pub export fn auk__heap_thread_end() uses raw, ffi {
  let p = raw.addr_of(&pool)
  let lists: raw.Ptr<raw.Ptr<FreeBlock>> = raw.cast(raw.field_addr(p, .free))
  let sp: raw.Ptr<raw.Ptr<FreeBlock>> = raw.cast(raw.addr_of(&spill))
  let _ = pthread_mutex_lock(raw.addr_of(&spill_lock))
  var c: i64 = 1
  while c < NCLASS {
    let b = lists.at(c)
    if !b.is_null() {
      var last = b
      while !last.next.is_null() {
        last = last.next
      }
      if sp.at(c).is_null() {
        let _ = raw.atomic_add(raw.addr_of(&spill_n), 1, raw.Order.Relaxed)
      }
      last.next = sp.at(c)
      sp.at(c) = b
      lists.at(c) = raw.null()
    }
    c += 1
  }
  let _ = pthread_mutex_unlock(raw.addr_of(&spill_lock))
  p.bump = raw.null()
  p.end = raw.null()
}

/// The header of the object whose Link is l.
fn header_of(l: raw.Ptr<Link>): raw.Ptr<abi.Header> uses raw = raw.cast(raw.cast<u8>(l).offset(raw.size_of<Link>()))

/// The Link of the tracked object h.
fn link_of(h: raw.Ptr<abi.Header>): raw.Ptr<Link> uses raw = raw.cast(raw.cast<u8>(h).offset(-i64(raw.size_of<Link>())))

fn ledger_slot(key: usize, cap: i64): u64 uses ffi = rc.auk_hash_int(i64(key)) & u64(cap - 1)

fn ledger_grow(l: raw.Ptr<Ledger>) uses raw, ffi {
  let keys = l.keys
  let counts = l.counts
  let cap = l.cap
  l.cap = if cap == 0 { 16 } else { cap * 2 }
  l.keys = raw.cast(rc.auk__xcalloc(usize(l.cap), raw.size_of<usize>()))
  l.counts = raw.cast(rc.auk__xcalloc(usize(l.cap), raw.size_of<i64>()))
  l.used = 0
  var i: i64 = 0
  while i < cap {
    if keys.at(i) != 0 && counts.at(i) != 0 {
      ledger_entry(l, keys.at(i)).store(counts.at(i))
    }
    i += 1
  }
  raw.free(keys)
  raw.free(counts)
}

/// The count for key, adding the key (count 0) when it is missing.
fn ledger_entry(l: raw.Ptr<Ledger>, key: usize): raw.Ptr<i64> uses raw, ffi {
  if (l.used + 1) * 4 > l.cap * 3 {
    ledger_grow(l)
  }
  let mask = u64(l.cap - 1)
  var i = ledger_slot(key, l.cap)
  while l.keys.at(i) != 0 {
    if l.keys.at(i) == key {
      return l.counts.offset(i)
    }
    i = (i + 1) & mask
  }
  l.keys.at(i) = key
  l.counts.at(i) = 0
  l.used += 1
  l.counts.offset(i)
}

pub export fn auk__note_handle(p: raw.Ptr<()>, delta: i64) uses raw, ffi {
  let h = cur_heap
  if h.is_null() {
    return
  }
  let _ = pthread_mutex_lock(raw.field_addr(h, .handles_lock))
  let n = ledger_entry(raw.field_addr(h, .handles), usize(p.int()))
  n.store(n.load() + delta)
  let _ = pthread_mutex_unlock(raw.field_addr(h, .handles_lock))
}

export fn auk__heap_new(): raw.Ptr<Heap> uses raw, ffi {
  let h: raw.Ptr<Heap> = raw.cast(rc.auk__xcalloc(1, raw.size_of<Heap>()))
  let _ = pthread_mutex_init(raw.field_addr(h, .lock), raw.null())
  let _ = pthread_mutex_init(raw.field_addr(h, .handles_lock), raw.null())
  let s = raw.field_addr(h, .head)
  s.prev = s
  s.next = s
  h
}

export fn auk__heap_current(): raw.Ptr<Heap> = cur_heap

pub export fn auk__heap_switch(h: raw.Ptr<Heap>): raw.Ptr<Heap> {
  let old = cur_heap
  cur_heap = h
  old
}

/// For generated code: switch heaps (a constant's initializer runs untracked, since its value
/// outlives the task that happened to compute it first).
export fn auk_heap_switch(h: raw.Ptr<()>): raw.Ptr<()> uses raw = raw.cast(auk__heap_switch(raw.cast(h)))

/// For generated code: a fresh heap for a task about to be spawned.
export fn auk_heap_new(): raw.Ptr<()> uses raw, ffi = raw.cast(auk__heap_new())

/// Allocate size zeroed bytes for an object of kind in the current heap (untracked when there
/// is none, or for a handle kind). Returns the header's address.
pub export fn auk__heap_alloc(size: usize, kind: u32): raw.Ptr<abi.Header> uses raw, ffi = alloc_in(size, kind, true)

/// auk__heap_alloc without zeroing: only the header (but its rc) and the Link are set; the
/// caller writes every other byte it reads.
pub export fn auk__heap_alloc_nz(size: usize, kind: u32): raw.Ptr<abi.Header> uses raw, ffi = alloc_in(size, kind, false)

fn alloc_in(size: usize, kind: u32, zero: bool): raw.Ptr<abi.Header> uses raw, ffi {
  let handle = abi.is_handle(kind)
  let hp: raw.Ptr<Heap> = if handle { raw.null() } else { cur_heap }
  var c: i64 = 0
  if hp.is_null() {
    let h: raw.Ptr<abi.Header> = raw.cast(block_alloc(size, raw.addr_of(&c), zero || handle))
    h.kind = kind
    h.flags = u32(c) << CLASS_SHIFT
    if handle {
      auk__note_handle(raw.cast(h), 1)
    }
    return h
  }
  let l: raw.Ptr<Link> = raw.cast(block_alloc(raw.size_of<Link>() + size, raw.addr_of(&c), zero))
  let h = header_of(l)
  h.kind = kind
  h.flags = abi.TRACKED | (u32(c) << CLASS_SHIFT)
  l.heap = hp
  let _ = pthread_mutex_lock(raw.field_addr(hp, .lock))
  let s = raw.field_addr(hp, .head)
  l.prev = s
  l.next = s.next
  let first = s.next
  first.prev = l
  s.next = l
  let _ = pthread_mutex_unlock(raw.field_addr(hp, .lock))
  h
}

/// Free an object's memory (taking it off its heap's list).
pub export fn auk__heap_free(h: raw.Ptr<abi.Header>) uses raw, ffi {
  let c = class_of(h)
  if (h.flags & abi.TRACKED) == 0 {
    block_free(raw.cast(h), c)
    return
  }
  let l = link_of(h)
  let hp = l.heap
  let _ = pthread_mutex_lock(raw.field_addr(hp, .lock))
  if hp.sweeping {
    // the sweep frees it at the end: an object swept later may still release this one
    let _ = pthread_mutex_unlock(raw.field_addr(hp, .lock))
    return
  }
  let prev = l.prev
  let next = l.next
  prev.next = next
  next.prev = prev
  let _ = pthread_mutex_unlock(raw.field_addr(hp, .lock))
  block_free(raw.cast(l), c)
}

/// The bytes usable from h (the header included) in its allocation, which may be more than
/// were asked for.
pub export fn auk__heap_usable(h: raw.Ptr<abi.Header>): usize uses raw, ffi {
  let tracked = (h.flags & abi.TRACKED) != 0
  let c = class_of(h)
  let base: raw.Ptr<()> = if tracked { raw.cast(link_of(h)) } else { raw.cast(h) }
  let n = if c == 0 { heap_os.usable_size(base) } else { usize(c) * 16 }
  if tracked { n - raw.size_of<Link>() } else { n }
}

/// Grow (or shrink) h's allocation to size bytes from the header on; returns its new address.
/// The object must be unique: nothing else may hold the old address. Bytes past the old size
/// are not zeroed.
pub export fn auk__heap_resize(h: raw.Ptr<abi.Header>, size: usize): raw.Ptr<abi.Header> uses raw, ffi {
  let c = class_of(h)
  if c != 0 {
    return pool_resize(h, size, c)
  }
  if (h.flags & abi.TRACKED) == 0 {
    // raw.realloc aborts on failure, as the C did
    return raw.cast(raw.realloc(h, size))
  }
  let l = link_of(h)
  let hp = l.heap
  let _ = pthread_mutex_lock(raw.field_addr(hp, .lock))
  let n: raw.Ptr<Link> = raw.cast(raw.realloc(l, raw.size_of<Link>() + size))
  let prev = n.prev
  let next = n.next
  prev.next = n
  next.prev = n
  let _ = pthread_mutex_unlock(raw.field_addr(hp, .lock))
  header_of(n)
}

/// auk__heap_resize of a pooled object: moved to a block of a bigger class (or a malloc'd one
/// past POOL_MAX), unless its block already holds size bytes (and its Link).
fn pool_resize(h: raw.Ptr<abi.Header>, size: usize, c: i64): raw.Ptr<abi.Header> uses raw, ffi {
  let tracked = (h.flags & abi.TRACKED) != 0
  let extra = if tracked { raw.size_of<Link>() } else { usize(0) }
  let have = usize(c) * 16
  if extra + size <= have {
    return h
  }
  let nc = class_for(extra + size)
  let mem: raw.Ptr<u8> = if nc == 0 { raw.cast(rc.auk__xmalloc(extra + size)) } else { pool_take(nc) }
  let flags = (h.flags & ~(u32(255) << CLASS_SHIFT)) | (u32(nc) << CLASS_SHIFT)
  if !tracked {
    let n: raw.Ptr<abi.Header> = raw.cast(mem)
    raw.copy(n, h, have)
    n.flags = flags
    pool_free(raw.cast(h), c)
    return n
  }
  let l = link_of(h)
  let hp = l.heap
  let _ = pthread_mutex_lock(raw.field_addr(hp, .lock))
  let n: raw.Ptr<Link> = raw.cast(mem)
  raw.copy(n, l, have)
  let nh = header_of(n)
  nh.flags = flags
  let prev = n.prev
  let next = n.next
  prev.next = n
  next.prev = n
  let _ = pthread_mutex_unlock(raw.field_addr(hp, .lock))
  pool_free(raw.cast(l), c)
  nh
}

/// Free every object still in heap, then the heap. No object outside it may point into it.
/// Each object is freed by its kind's ordinary free routine, so what it holds outside the heap
/// (handles) is released properly; objects inside the heap first get a reference count no
/// release can bring to zero, so each is freed exactly once, here. Their memory is freed only
/// after all of them have been: the objects are freed in list order, and freeing one releases
/// what it holds, which may be another swept object, freed before it or not.
pub export fn auk__heap_sweep(hp: raw.Ptr<Heap>) uses raw, ffi {
  if hp.is_null() {
    return
  }
  // strings in the heap are going without auk__str_free: forget str.auk's index cursor
  auk__str_cursor_reset()
  var n: i64 = 0
  var cap: i64 = 0
  var objs: raw.Ptr<raw.Ptr<abi.Header>> = raw.null()
  let _ = pthread_mutex_lock(raw.field_addr(hp, .lock))
  hp.sweeping = true
  let s = raw.field_addr(hp, .head)
  var l = s.next
  while l != s {
    let h = header_of(l)
    let next = l.next
    if raw.atomic_load(raw.field_addr(h, .rc), raw.Order.SeqCst) < 0 {
      // immortal: it must stay; just take it off the list
      let prev = l.prev
      prev.next = next
      next.prev = prev
      h.flags = h.flags & ~abi.TRACKED
    } else {
      raw.atomic_store(raw.field_addr(h, .rc), DYING, raw.Order.SeqCst)
      if n == cap {
        cap = if cap == 0 { 64 } else { cap * 2 }
        objs = raw.cast(rc.auk__xrealloc(raw.cast(objs), usize(cap) * raw.size_of<raw.Ptr<abi.Header>>()))
      }
      objs.at(n) = h
      n += 1
    }
    l = next
  }
  let _ = pthread_mutex_unlock(raw.field_addr(hp, .lock))
  // free them as this heap's task would (their handle releases come off its ledger)
  let old = auk__heap_switch(hp)
  var i: i64 = 0
  while i < n {
    rc.auk__free_now(raw.cast(objs.at(i)))
    i += 1
  }
  raw.free(objs)
  // now the memory: what was swept, and anything freed while sweeping (allocated by a drop)
  let _ = pthread_mutex_lock(raw.field_addr(hp, .lock))
  l = s.next
  while l != s {
    let next = l.next
    block_free(raw.cast(l), class_of(header_of(l)))
    l = next
  }
  s.next = s
  s.prev = s
  let _ = pthread_mutex_unlock(raw.field_addr(hp, .lock))
  let _ = auk__heap_switch(raw.null())
  let _ = pthread_mutex_lock(raw.field_addr(hp, .handles_lock))
  let held = hp.handles
  hp.handles = Ledger {}
  let _ = pthread_mutex_unlock(raw.field_addr(hp, .handles_lock))
  i = 0
  while i < held.cap {
    var k: i64 = 0
    while k < held.counts.at(i) {
      rc.release(raw.from_int(int(held.keys.at(i))))
      k += 1
    }
    i += 1
  }
  raw.free(held.keys)
  raw.free(held.counts)
  let _ = auk__heap_switch(if old == hp { raw.null() } else { old })
  let _ = pthread_mutex_destroy(raw.field_addr(hp, .lock))
  let _ = pthread_mutex_destroy(raw.field_addr(hp, .handles_lock))
  raw.free(hp)
}
