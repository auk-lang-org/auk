/// The clock (`uses time`).

/// Milliseconds since the Unix epoch.
pub extern fn now(): int uses time = "auk_time_now"
pub extern fn sleep(ms: int) uses time = "auk_time_sleep"
