Split one CSV line into fields.

- Fields are separated by commas. An empty line is one empty field; a trailing comma adds a final empty field.
- A field that STARTS with a double quote is quoted: it runs to the matching closing quote, commas inside it are literal, and two double quotes in a row (`""`) inside it stand for one `"`. The quotes themselves are not part of the value.
- After a closing quote the next character must be a comma or the end of the line; otherwise fail with `JunkAfterQuote(at)`, where `at` is the 0-based character index of the offending character in the line.
- A quoted field with no closing quote fails with `Unterminated`.
- In a field that does not start with a quote, quote characters are ordinary characters. Fields are not trimmed.
