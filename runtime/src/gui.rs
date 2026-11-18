//! Windows: now in C (`runtime/c/gui.c`, which explains the window process).

unsafe extern "C" {
    safe fn auk_gui_shutdown();
}

/// Close this program's windows: it is ending normally (`auk run --live` calls this when the
/// program returns, so its windows don't wait to be taken over by the next run).
pub fn shutdown() {
    auk_gui_shutdown()
}
