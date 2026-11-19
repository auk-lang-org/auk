/// gui's per-OS parts on Linux (gui_os.macos.auk explains): no windows yet, so gui.open fails
/// cleanly; the wire protocol is still here (u64 `msg_controllen`/`cmsg_len`, u16
/// `sun_family`).

/// Whether gui.open can open windows here.
pub raw let SUPPORTED: bool = false

/// msg's one iovec, and its control buffer (null, 0 for none).
pub fn msg_set(msg: raw.Ptr<cfacts.Msghdr>, iov: raw.Ptr<cfacts.Iovec>, control: raw.Ptr<()>, len: usize) uses raw {
  msg.msg_iov = iov
  msg.msg_iovlen = 1
  msg.msg_control = control
  msg.msg_controllen = u64(len)
}

pub fn msg_controllen(msg: raw.Ptr<cfacts.Msghdr>): usize uses raw = usize(msg.msg_controllen)

pub fn cmsg_set(c: raw.Ptr<cfacts.Cmsghdr>, level: i32, kind: i32, len: usize) uses raw {
  c.cmsg_level = level
  c.cmsg_type = kind
  c.cmsg_len = u64(len)
}

pub fn sun_set_family(addr: raw.Ptr<cfacts.SockaddrUn>) uses raw {
  addr.sun_family = u16(cfacts.AF_UNIX)
}

/// (never called: SUPPORTED is false)
pub fn exe_path(buf: raw.Ptr<u8>, size: u32): bool uses raw, ffi = false

/// (never called: SUPPORTED is false)
pub fn inherit_std(acts: raw.Ptr<cfacts.PosixSpawnFileActions>) uses ffi {}
