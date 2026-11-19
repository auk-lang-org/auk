// The hand-written half of the layout probe (run.sh appends the generated tables): abi's and
// cfacts' functions and by-value structs, exported for probe.c to call and compare with C.

// cfacts: the C macros as raw functions
export fn auk_wifexited(s: i32): bool = cfacts.wifexited(s)
export fn auk_wexitstatus(s: i32): i32 = cfacts.wexitstatus(s)
export fn auk_wifsignaled(s: i32): bool = cfacts.wifsignaled(s)
export fn auk_wtermsig(s: i32): i32 = cfacts.wtermsig(s)
export fn auk_s_isdir(m: u32): bool = cfacts.s_isdir(m)
export fn auk_s_isreg(m: u32): bool = cfacts.s_isreg(m)
export fn auk_cmsg_len(n: usize): usize = cfacts.cmsg_len(n)
export fn auk_cmsg_space(n: usize): usize = cfacts.cmsg_space(n)
export fn auk_cmsg_data(c: raw.Ptr<cfacts.Cmsghdr>): raw.Ptr<u8> uses raw = cfacts.cmsg_data(c)
export fn auk_cmsg_firsthdr(m: raw.Ptr<cfacts.Msghdr>): raw.Ptr<cfacts.Cmsghdr> uses raw = cfacts.cmsg_firsthdr(m)
export fn auk_uc_pc(uc: raw.Ptr<()>): raw.Ptr<u64> uses raw = cfacts.uc_pc(uc)
export fn auk_uc_sp(uc: raw.Ptr<()>): raw.Ptr<u64> uses raw = cfacts.uc_sp(uc)
export fn auk_si_addr(si: raw.Ptr<()>): raw.Ptr<()> uses raw = cfacts.si_addr(si)
export fn auk_errno_ptr(): raw.Ptr<i32> uses ffi = cfacts.errno_ptr()
export fn auk_errno(): i32 uses raw, ffi = cfacts.errno()
export fn auk_set_errno(e: i32) uses raw, ffi { cfacts.set_errno(e) }
export fn auk_stdout(): raw.Ptr<()> uses raw = cfacts.stdout()
export fn auk_stderr(): raw.Ptr<()> uses raw = cfacts.stderr()

// a stat through the Auk layout: the mode and size C's stat(2) filled in
extern fn stat(path: raw.Ptr<u8>, st: raw.Ptr<cfacts.Stat>): i32 = "int stat(const char *, void *)"
export fn auk_stat_size(path: raw.Ptr<u8>): i64 uses raw, ffi {
  let st: raw.Ptr<cfacts.Stat> = raw.cast(raw.alloc(raw.size_of<cfacts.Stat>()))
  if stat(path, st) != 0 { return -1 }
  let n = if cfacts.s_isreg(u32(st.st_mode)) { i64(st.st_size) } else { -2 }
  raw.free(st)
  n
}

// abi: helpers, function pointers in a table, structs by value
export fn auk_is_handle(kind: u32): bool = abi.is_handle(kind)
export fn auk_map_key(m: raw.Ptr<abi.Map>, i: i64): raw.Ptr<u8> uses raw = abi.map_key(m, i)
export fn auk_map_val(m: raw.Ptr<abi.Map>, i: i64): raw.Ptr<u8> uses raw = abi.map_val(m, i)

export fn auk_ops_hash(ops: raw.Ptr<abi.ElemOps>, p: raw.Ptr<()>): u64 uses raw {
  let h = ops.hash
  h(p)
}

export fn auk_value_i(v: abi.Value): i64 = if v.tag == abi.V_INT { v.u.i } else { -1 }
export fn auk_mk_value_f(f: float): abi.Value = abi.Value { tag: abi.V_FLOAT, u: abi.ValueU { f: f } }
export fn auk_mk_res_int(n: i64): abi.ResInt = abi.ResInt { ok: n >= 0, val: n }
export fn auk_opt_float(o: abi.OptFloat): float = if o.some { o.val } else { -1.0 }
export fn auk_mk_opt_char(c: u32): abi.OptChar = abi.OptChar { some: true, val: c }
export fn auk_closure_env(c: abi.Closure): raw.Ptr<abi.Obj> = c.env
export fn auk_probe_str_len(s: raw.Ptr<abi.Str>): i64 uses raw = s.len_chars
export fn auk_probe_str_byte(s: raw.Ptr<abi.Str>, i: i64): u8 uses raw = s.data.at(i)
export fn auk_task_hint(t: raw.Ptr<abi.Task>): usize uses raw = t.hint
export fn auk_chan_closed(c: raw.Ptr<abi.Chan>): bool uses raw = c.closed

/// pthread_mutex_lock/unlock on a mutex initialized from cfacts.PTHREAD_MUTEX_INITIALIZER.
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"
export fn auk_mutex_roundtrip(): i32 uses raw, ffi {
  let m: raw.Ptr<cfacts.PthreadMutex> = raw.cast(raw.alloc(raw.size_of<cfacts.PthreadMutex>()))
  m.store(cfacts.PTHREAD_MUTEX_INITIALIZER)
  if pthread_mutex_lock(m) != 0 { return 1 }
  if pthread_mutex_unlock(m) != 0 { return 2 }
  raw.free(m)
  0
}

