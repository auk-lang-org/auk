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
pub export fn auk__heap_alloc(size: usize, kind: u32): raw.Ptr<abi.Header> uses raw, ffi {
  let handle = abi.is_handle(kind)
  let hp: raw.Ptr<Heap> = if handle { raw.null() } else { cur_heap }
  if hp.is_null() {
    let h: raw.Ptr<abi.Header> = raw.cast(rc.auk__xcalloc(1, size))
    h.kind = kind
    if handle {
      auk__note_handle(raw.cast(h), 1)
    }
    return h
  }
  let l: raw.Ptr<Link> = raw.cast(rc.auk__xcalloc(1, raw.size_of<Link>() + size))
  let h = header_of(l)
  h.kind = kind
  h.flags = abi.TRACKED
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
  if (h.flags & abi.TRACKED) == 0 {
    raw.free(h)
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
  raw.free(l)
}

/// The bytes usable from h (the header included) in its allocation, which may be more than
/// were asked for.
pub export fn auk__heap_usable(h: raw.Ptr<abi.Header>): usize uses raw, ffi {
  let tracked = (h.flags & abi.TRACKED) != 0
  let base: raw.Ptr<()> = if tracked { raw.cast(link_of(h)) } else { raw.cast(h) }
  let n = heap_os.usable_size(base)
  if tracked { n - raw.size_of<Link>() } else { n }
}

/// Grow (or shrink) h's allocation to size bytes from the header on; returns its new address.
/// The object must be unique: nothing else may hold the old address. Bytes past the old size
/// are not zeroed.
pub export fn auk__heap_resize(h: raw.Ptr<abi.Header>, size: usize): raw.Ptr<abi.Header> uses raw, ffi {
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
    raw.free(l)
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
      rc.auk_release(raw.from_int(int(held.keys.at(i))))
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
