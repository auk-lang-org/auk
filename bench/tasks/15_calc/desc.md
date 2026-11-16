A calculator for integer expressions, written as a tokenizer plus a recursive-descent parser that evaluates as it parses.

Syntax: non-negative integer literals, binary `+ - * /` with the usual precedence (`*` and `/` bind tighter than `+` and `-`) and left associativity, unary minus (it can repeat: `--3` is 3), and parentheses. Spaces are ignored. Grammar:

    expr   := term (("+" | "-") term)*
    term   := factor (("*" | "/") factor)*
    factor := "-" factor | NUMBER | "(" expr ")"

Division truncates toward zero (`-7 / 2` is -3, `7 / -2` is -3).

The functions:
- `tokenize(s)` turns the string into tokens (`Num(n)` for a run of digits, `Op(c)` for one of `+ - * /`, `LParen`, `RParen`), skipping spaces. The first character that is not a digit, space, operator or parenthesis fails with `BadToken(c)`.
- `parse_expr`, `parse_term` and `parse_factor` each parse one grammar rule starting at token index `pos`, advance `pos` past the tokens they used, and return the value. A missing or unexpected token fails with `Syntax`; dividing by zero fails with `DivZero`.
- `calc(s)` tokenizes, parses an `expr` from position 0, and fails with `Syntax` if tokens are left over. Tokenizer errors come first: if the input has an invalid character, the result is `BadToken` even if it also has syntax errors. (No test input has both a syntax error and a division by zero.)
