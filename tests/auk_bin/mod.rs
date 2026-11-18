//! The binary an end-to-end test drives: `$AUK_BIN` when set (another build of the same
//! commands, such as the self-hosted port: `auk build compiler/src/main.auk -o target/auk-port`,
//! then `AUK_BIN=$PWD/target/auk-port cargo test --release --test lsp --test mcp --test explain`),
//! otherwise this build's `auk`.
//!
//! A binary from `$AUK_BIN` may lack commands. `$AUK_BIN_LACKS` lists them (comma-separated);
//! unset, it is what the port's driver doesn't have yet: `run`, `test`, `debug`, `build`, `ir`
//! (it can't run the imprint helper) and `parse`. Tests that need one skip it (`lacks`) with a
//! note on stderr.

#![allow(dead_code)]

/// The commands the port's driver doesn't have yet.
const PORT_LACKS: &str = "run,test,debug,build,ir,parse";

/// The `auk` binary to run.
pub fn auk_bin() -> String {
    std::env::var("AUK_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_auk").to_string())
}

/// Whether the binary lacks `cmd`; if so, say which test skips what.
pub fn lacks(cmd: &str, what: &str) -> bool {
    if std::env::var_os("AUK_BIN").is_none() {
        return false;
    }
    let list = std::env::var("AUK_BIN_LACKS").unwrap_or_else(|_| PORT_LACKS.to_string());
    let lacking = list.split(',').any(|c| c.trim() == cmd);
    if lacking {
        eprintln!("skipped for {}: {what} (needs `{cmd}`, which it lacks)", auk_bin());
    }
    lacking
}
