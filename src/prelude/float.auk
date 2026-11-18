/// `float.parse`.

/// Decimal and exponent forms, plus `inf` and `nan`.
pub extern fn parse(s: str): float! = "auk_float_parse"

/// The float with these IEEE 754 double-precision bits: `float.from_bits(x.bits()) == x`.
pub extern fn from_bits(n: int): float = "auk_ffrom_bits"
/// The single-precision float in the low 32 bits of `n` (as in f32 audio or binary formats).
pub extern fn from_bits32(n: int): float = "auk_ffrom_bits32"

pub let pi = 3.141592653589793
pub let e = 2.718281828459045
