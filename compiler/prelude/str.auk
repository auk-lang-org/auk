/// `str.from_utf8`: text from bytes.

/// Decode UTF-8 bytes (ints 0..255); an Err on invalid UTF-8.
pub extern fn from_utf8(bytes: [int]): str! = "auk_str_from_utf8"
