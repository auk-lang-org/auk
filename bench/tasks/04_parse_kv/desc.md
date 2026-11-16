Parse a config string of `key=value` pairs separated by `;`.

- Split the input on `;` into segments, numbered from 0. Segments that are empty or only whitespace are skipped (but still count for numbering).
- Each other segment is split at its FIRST `=` into key and value; whitespace around the key and around the value is trimmed.
- Values are base-10 integers, possibly negative (e.g. `-12`).
- A later duplicate key overwrites the earlier value but keeps the key's original position. Keys are in order of first appearance.

Errors (report the first problem from left to right):
- a non-blank segment with no `=` -> `MissingEq(at)`, where `at` is the segment number;
- an empty key -> `EmptyKey(at)`;
- a value that is not an integer -> `BadValue(key)`.
