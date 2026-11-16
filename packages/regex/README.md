# regex

A backtracking regular-expression engine for Duck. `regex(p)` compiles a pattern into an AST once; matching runs on an explicit backtracking stack, so long inputs don't grow the call stack. Positions are char indexes, so non-ASCII text works the same as ASCII.

**Effects:** none (`effects = []`)

## Usage
```
let email = regex(r"(\w+)@(\w+)\.com")?
email.find("mail ann@duck.com")          // some("ann@duck.com")
email.captures("ann@duck.com")           // some([some("ann@duck.com"), some("ann"), some("duck")])
email.replace("ann@duck.com", "$2/$1")   // "duck/ann"
(regex(r"\d+")?).find_all("a1b22")       // ["1", "22"]
(regex(r"\s*,\s*")?).split("a , b,c")    // ["a", "b", "c"]
regex("a(b")                             // err(Unclosed(1, '(')); .message() explains it
```
Write patterns as raw strings (`r"..."`) so `\` and `{n}` reach the regex unchanged.

## Syntax
| | |
|---|---|
| literals, `.` | `.` matches any char except `\n` |
| `[a-z]` `[^...]` | classes; `]` first is literal, `-` first or last is literal; escapes allowed inside |
| `\d \w \s \D \W \S` | ASCII digit, word (`[A-Za-z0-9_]`), space (` \t\n\r`) and their negations |
| `\. \\ \( \* ...` `\n \t \r` | escaped metacharacters (also `\-` `\/`) and control chars |
| `^ $` | start / end of the input |
| `( )` `(?: )` | capturing / non-capturing group |
| `\|` | alternation, leftmost alternative wins |
| `* + ? {n} {n,} {n,m}` | greedy quantifiers |
| `*? +? ?? {n,m}?` | lazy quantifiers |

## API
- `regex(p: str): Regex!RegexErr`: compile a pattern
- `find(r, s): str?`: the leftmost match
- `find_all(r, s): [str]`: all non-overlapping matches (empty matches included)
- `is_match(r, s): bool`
- `captures(r, s): [str?]?`: group 0 is the whole match; an unmatched group is `none`
- `replace(r, s, with: str): str`: replace every match; `$0`..`$99` insert a group, `$$` a dollar
- `split(r, s): [str]`: split around matches
- `escape(s): str`: quote metacharacters so `regex(escape(s))` matches `s` literally
- `source(r): str`, `group_count(r): int`
- `enum RegexErr { Unexpected(at, c), Unclosed(at, open), NothingToRepeat(at), BadRepeat(at), BadRange(at), BadEscape(at, c), TrailingBackslash(at), BadGroup(at) }`
- `pos(e: RegexErr): int`: char index in the pattern; `message(e): str`: one-line description
