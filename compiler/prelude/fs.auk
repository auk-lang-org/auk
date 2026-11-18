/// The file system (`uses fs`).

pub extern fn read(path: str): str! uses fs = "auk_fs_read"
pub extern fn write(path: str, text: str): ()! uses fs = "auk_fs_write"
pub extern fn lines(path: str): [str]! uses fs = "auk_fs_lines"
/// Add `text` to the end of the file, creating it if needed.
pub extern fn append(path: str, text: str): ()! uses fs = "auk_fs_append"
/// The file's bytes, as ints 0..255.
pub extern fn read_bytes(path: str): [int]! uses fs = "auk_fs_read_bytes"
/// Write bytes (ints 0..255); an Err, before the file is touched, if one is out of range.
pub extern fn write_bytes(path: str, bytes: [int]): ()! uses fs = "auk_fs_write_bytes"
/// Does a file or directory exist at `path`?
pub extern fn exists(path: str): bool uses fs = "auk_fs_exists"
pub extern fn is_dir(path: str): bool uses fs = "auk_fs_is_dir"
/// The names of the entries of `dir` (not paths), sorted.
pub extern fn list(dir: str): [str]! uses fs = "auk_fs_list"
/// Create a directory and any missing parents (fine if it already exists).
pub extern fn mkdir(path: str): ()! uses fs = "auk_fs_mkdir"
/// Remove a file or an empty directory.
pub extern fn remove(path: str): ()! uses fs = "auk_fs_remove"
pub extern fn rename(from: str, to: str): ()! uses fs = "auk_fs_rename"
/// Create a new, empty, private directory under the system temp dir and return its path.
/// The program removes it when done.
pub extern fn temp_dir(): str! uses fs = "auk_fs_temp_dir"
