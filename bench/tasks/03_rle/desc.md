Run-length encoding, two functions.

`rle_encode(s)` replaces each run of a repeated character with the character followed by the run length; a run of length 1 is written as just the character. Example: "aaabccdddd" -> "a3bc2d4". The input contains no digit characters.

`rle_decode(s)` is the inverse: each character may be followed by a decimal count (one or more digits); no count means 1. Errors: if the string starts with a digit, fail with `LeadingDigit`; if any count is zero (e.g. "a0", "a00"), fail with `ZeroCount`. The empty string decodes to the empty string.
