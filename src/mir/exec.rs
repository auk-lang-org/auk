//! Running JIT-compiled programs, whichever back end compiled them: calling the entry point
//! in this process or in a forked child with redirected streams, and waiting for children.

use std::collections::HashMap;

/// A program compiled in memory; keep it alive while its code runs. Dropping it frees the code
/// (through the back end's owner object) unless it was leaked.
pub struct Jit {
    entry: *const u8,
    code: Option<Box<dyn std::any::Any>>,
}

/// A program compiled for `duck run --live`: every call to a function in the live slots goes
/// through the live table, so a later compile can replace bodies.
pub struct LiveJit {
    pub jit: Jit,
    /// (slot, code address) of each function in the slots, to store into the table.
    pub entries: Vec<(usize, *const u8)>,
    /// The program's `dk_init` (literals, imprints, constants), to run before a reloaded module's
    /// code is used.
    pub init: *const u8,
    /// Each function's code address, by name (to tell which code a running task started in).
    pub addrs: HashMap<String, *const u8>,
}

impl Jit {
    /// `entry`: `int f(int argc, char **argv)`; `code` owns the memory it lives in.
    pub fn new(entry: *const u8, code: Box<dyn std::any::Any>) -> Jit {
        Jit { entry, code: Some(code) }
    }

    /// Leave the compiled code in memory for good (a live reload: old frames may still run it).
    pub fn leak(mut self) {
        std::mem::forget(self.code.take());
    }

    /// Call the entry point with these arguments (`argv[0]` first); returns its exit code.
    pub fn run(&self, args: &[String]) -> i32 {
        let cs: Vec<std::ffi::CString> = args.iter().map(|a| std::ffi::CString::new(a.as_bytes()).unwrap_or_default()).collect();
        let mut argv: Vec<*const std::ffi::c_char> = cs.iter().map(|c| c.as_ptr()).collect();
        argv.push(std::ptr::null());
        let f: extern "C" fn(i32, *const *const std::ffi::c_char) -> i32 = unsafe { std::mem::transmute(self.entry) };
        f(cs.len() as i32, argv.as_ptr())
    }

    /// Run the entry point in a forked child process with its streams redirected; returns its
    /// exit code (None: killed by a signal).
    pub fn run_forked(&self, args: &[String], r: Redirect) -> Result<Option<i32>, String> {
        let pid = self.spawn(args, r, false)?;
        wait_child(pid, None).map(|w| w.unwrap_or(None))
    }

    /// Start the entry point in a forked child process (`own_group`: in a new process group);
    /// returns its pid.
    pub fn spawn(&self, args: &[String], r: Redirect, own_group: bool) -> Result<i32, String> {
        use std::os::fd::IntoRawFd;
        let open = |p: Option<&std::path::Path>| -> Result<Option<i32>, String> {
            match p {
                Some(p) => std::fs::File::create(p).map(|f| Some(f.into_raw_fd())).map_err(|e| format!("error: cannot create {}: {e}\n", p.display())),
                None => Ok(None),
            }
        };
        let (out, err, both) = (open(r.stdout)?, open(r.stderr)?, open(r.merged)?);
        let null = if r.stdin_null { std::fs::File::open("/dev/null").ok().map(|f| f.into_raw_fd()) } else { None };
        unsafe {
            libc::fflush(std::ptr::null_mut());
            let pid = libc::fork();
            if pid < 0 {
                return Err("error: fork failed\n".into());
            }
            if pid == 0 {
                if own_group {
                    libc::setpgid(0, 0);
                }
                if let Some(fd) = null {
                    libc::dup2(fd, 0);
                }
                if let Some(fd) = out.or(both) {
                    libc::dup2(fd, 1);
                }
                if let Some(fd) = err.or(both) {
                    libc::dup2(fd, 2);
                }
                let code = self.run(args);
                libc::fflush(std::ptr::null_mut());
                libc::_exit(code);
            }
            if own_group {
                libc::setpgid(pid, pid);
            }
            for fd in [out, err, both, null].into_iter().flatten() {
                libc::close(fd);
            }
            Ok(pid)
        }
    }
}

/// Wait for a child process: Ok(Some(exit code, or None if killed by a signal)), or Ok(None)
/// when `limit` passed first (the child is then killed with its process group).
pub fn wait_child(pid: i32, limit: Option<std::time::Duration>) -> Result<Option<Option<i32>>, String> {
    let start = std::time::Instant::now();
    loop {
        let mut status = 0;
        let flags = if limit.is_some() { libc::WNOHANG } else { 0 };
        let r = unsafe { libc::waitpid(pid, &mut status, flags) };
        if r == pid {
            return Ok(Some(if libc::WIFEXITED(status) { Some(libc::WEXITSTATUS(status)) } else { None }));
        }
        if r < 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err("error: waitpid failed\n".into());
        }
        if limit.is_some_and(|l| start.elapsed() > l) {
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
                libc::kill(pid, libc::SIGKILL);
                libc::waitpid(pid, &mut status, 0);
            }
            return Ok(None);
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}


/// Where a forked program's standard streams go.
#[derive(Default)]
pub struct Redirect<'p> {
    pub stdout: Option<&'p std::path::Path>,
    pub stderr: Option<&'p std::path::Path>,
    /// stdout and stderr both to this file, in order.
    pub merged: Option<&'p std::path::Path>,
    pub stdin_null: bool,
}

