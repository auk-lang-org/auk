//! The window process: now in C (`runtime/c/gui_host.c`, which explains it).

unsafe extern "C" {
    safe fn auk__gui_host_main() -> i32;
}

/// Run the window process. Returns an exit code only if it can't start.
pub fn host_main() -> i32 {
    auk__gui_host_main()
}
