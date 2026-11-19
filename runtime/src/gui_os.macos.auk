/// gui's per-OS parts (was gui.c's `#if`s): windows exist on macOS, and the socket structures'
/// field widths are the platform's (cfacts: `msg_controllen`, `cmsg_len` are u32 here, u64 on
/// Linux; `sun_family` a u8 here). The Linux variant is gui_os.linux.auk.

extern fn ns_get_executable_path(buf: raw.Ptr<u8>, size: raw.Ptr<u32>): i32 = "int _NSGetExecutablePath(char *, uint32_t *)"
extern fn posix_spawn_file_actions_addinherit_np(acts: raw.Ptr<cfacts.PosixSpawnFileActions>, fd: i32): i32 =
  "int posix_spawn_file_actions_addinherit_np(void *, int)"

/// Whether gui.open can open windows here.
pub raw let SUPPORTED: bool = true

/// msg's one iovec, and its control buffer (null, 0 for none).
pub fn msg_set(msg: raw.Ptr<cfacts.Msghdr>, iov: raw.Ptr<cfacts.Iovec>, control: raw.Ptr<()>, len: usize) uses raw {
  msg.msg_iov = iov
  msg.msg_iovlen = 1
  msg.msg_control = control
  msg.msg_controllen = u32(len)
}

pub fn msg_controllen(msg: raw.Ptr<cfacts.Msghdr>): usize uses raw = usize(msg.msg_controllen)

pub fn cmsg_set(c: raw.Ptr<cfacts.Cmsghdr>, level: i32, kind: i32, len: usize) uses raw {
  c.cmsg_level = level
  c.cmsg_type = kind
  c.cmsg_len = u32(len)
}

pub fn sun_set_family(addr: raw.Ptr<cfacts.SockaddrUn>) uses raw {
  addr.sun_family = u8(cfacts.AF_UNIX)
}

/// This program's executable into buf (size bytes): false if it doesn't fit.
pub fn exe_path(buf: raw.Ptr<u8>, size: u32): bool uses raw, ffi {
  var n = size
  ns_get_executable_path(buf, raw.addr_of(&n)) == 0
}

/// Let the child inherit fds 0, 1, 2 (the spawn attributes close every other one).
pub fn inherit_std(acts: raw.Ptr<cfacts.PosixSpawnFileActions>) uses ffi {
  var fd: i32 = 0
  while fd < 3 {
    let _ = posix_spawn_file_actions_addinherit_np(acts, fd)
    fd += 1
  }
}
