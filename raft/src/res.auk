/// raft's error type (src/bin/raft.rs's `Error`, `Res` and `err`): a user-facing failure, printed
/// as `error: msg` plus an optional `  help: ...` line.
///
/// `T!E` needs an enum `E`, so a `Res<T>` is `T!res.Fail`, whose one variant carries the `Error`.

pub struct Error {
  msg: str,
  help: str?,
}

pub enum Fail {
  Bad(e: Error),
}

pub fn err(msg: str): Error = Error { msg, help: none }

pub fn help(e: Error, help: str): Error = Error { help: some(help), ..e }
