/// The process environment (`uses env`): what the program's invoker gave it, i.e. its
/// environment variables, arguments and standard input.

pub extern fn get(key: str): str? uses env = "auk_env_get"
/// The program's arguments, the program name first.
pub extern fn args(): [str] uses env = "auk_env_args"
/// The next line of stdin without its line break (`\n` or `\r\n`), or none at end of input.
/// Invalid UTF-8 becomes U+FFFD.
pub extern fn read_line(): str? uses env = "auk_env_read_line"
/// The rest of stdin; an Err on a read error or invalid UTF-8.
pub extern fn read_all(): str! uses env = "auk_env_read_all"
/// The rest of stdin split into lines (as `s.lines()`; invalid UTF-8 becomes U+FFFD).
pub extern fn lines(): [str] uses env = "auk_env_lines"
/// Whether `fd` (0 stdin, 1 stdout, 2 stderr) is a terminal; false for any other number.
pub extern fn is_terminal(fd: int): bool uses env = "auk_env_is_terminal"
/// The terminal's width in columns (from stdout, stderr or stdin, else `$COLUMNS`), or none.
pub extern fn columns(): int? uses env = "auk_env_columns"
