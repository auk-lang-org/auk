Roman numerals, two functions.

`to_roman(n)` converts 1 <= n <= 3999 to a standard (canonical) Roman numeral using I V X L C D M and the subtractive forms IV IX XL XC CD CM. Example: 1994 -> "MCMXCIV".

`from_roman(s)` parses a Roman numeral and returns its value, or missing (none / None) if `s` is not the canonical numeral of a number in 1..3999: empty strings, lowercase letters, other characters and non-canonical forms such as "IIII", "IC", "VX" or "MMMM" are all rejected.
