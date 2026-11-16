# text

Everyday string tools that core doesn't have:
- case conversion between identifier styles
- Levenshtein distance and "did you mean" suggestions
- terminal display width, with padding and truncation that respect it
- POSIX shell-word splitting and quoting
- word wrapping, indent and dedent
- a Myers line diff with unified (`diff -u`) output

Each output from `unified` was checked by applying it with `patch(1)`.

**Effects:** none.

```duck
fn main(args: [str]): int! {
  print(text.snake("XMLHttpRequest"))          // xml_http_request
  print(text.camel("user_id"))                 // userId
  print(text.title("the-quick_brown fox"))     // The Quick Brown Fox

  let cmds = ["status", "stash", "commit", "push"]
  match text.closest("stauts", cmds) {
    some(c) => print("unknown command; did you mean `{c}`?")
    none => print("unknown command")
  }

  let argv = text.shell_words("grep -n 'hello world' \"my file.txt\"")?
  print(argv)                                  // ["grep", "-n", "hello world", "my file.txt"]
  print(text.join(["rm", "it's here"]))        // rm 'it'"'"'s here'

  print(text.width("日本語"))                    // 6 columns
  print(text.pad_right("日本", 6) + "|")         // "日本  |"
  print(text.truncate("a very long title", 10))  // a very lo…
  for line in text.wrap("the quick brown fox jumps over the lazy dog", 16) { print(line) }

  let patch = text.unified("a\nb\nc\n", "a\nB\nc\n")
  print("--- a/notes.txt\n+++ b/notes.txt\n" + patch)   // @@ -1,3 +1,3 @@ ...
  0
}
```

## API
Case (ASCII letters only change case; other chars are kept):
- `words(s): [str]`: how the case functions split their input. Every char that isn't a letter or digit separates words. A word also ends before an upper-case letter that follows a lower-case letter, a digit or a non-ASCII letter (`fooBar`, `v2Api`). Inside an acronym, the last capital starts a new word when lower case follows it (`XMLHttp` → `XML`, `Http`). Digits stay with the word they follow (`utf8Decode` → `utf8`, `Decode`).
- `snake`, `kebab`, `camel`, `pascal`, `title`, `constant` (`SCREAMING_SNAKE`), and `capitalize(word)`

Similarity:
- `distance(a, b): int`: Levenshtein distance over chars. It is case-sensitive and takes O(len(a)·len(b)) time.
- `similarity(a, b): float`: `1 - distance / max(len)`, from 0.0 to 1.0.
- `suggest(s, options, n): [str]` and `closest(s, options): str?`: options within distance `max(len(s), 3) / 3` of `s`, ignoring ASCII case, best first. Ties keep the input order. This is the cutoff compilers use for "did you mean".

Display width:
- `char_width(c): int` (0, 1 or 2), `width(s): int`: terminal columns.
- `pad_right(s, w)`, `pad_left(s, w)`: pad with spaces to `w` columns. `"{s:<10}"` counts chars, which misaligns CJK and emoji.
- `truncate(s, w)` cuts `s` to at most `w` columns, ending with `…` when it cuts. `truncate(s, w, ellipsis)` uses your own ending. A wide char is never split.

Shell words (POSIX `sh` quoting, no expansion):
- `shell_words(s): [str]!ShellErr`: whitespace separates words. `'…'` is literal. Inside `"…"`, a backslash escapes only `` $ ` " \ `` and newline. Outside quotes, `\x` gives `x`, and a backslash before a newline joins the lines. A `#` at the start of a word starts a comment. `$VAR`, globs, `~` and `| ; &` stay as ordinary text.
- `quote(s): str`: returns `s` unchanged if it's safe, otherwise single-quoted. `shell_words(quote(s)) == [s]` holds for every string. `join(words): str` is the inverse of `shell_words`.
- `enum ShellErr { UnclosedQuote(at: int), TrailingBackslash(at: int) }`, `message(e)`

Layout:
- `wrap(s, w): [str]` breaks text greedily at spaces by display width. Existing line breaks and blank lines are kept. Runs of spaces collapse, and leading indentation is dropped. A word wider than `w` is split. `fill(s, w): str` is `wrap(...).join("\n")`.
- `indent(s, prefix)` prefixes the non-blank lines. `dedent(s)` removes the leading spaces and tabs that all non-blank lines share, and empties whitespace-only lines.

Diff:
- `enum Edit { Keep(line), Del(line), Ins(line) }`. `diff(old: [str], new: [str]): [Edit]` returns a shortest edit script, using Myers' O(ND) algorithm after trimming the common prefix and suffix, with deletions before insertions in each change.
- `unified(old: str, new: str): str` returns `diff -u` hunks with 3 lines of context, or `""` when the texts are equal. `unified(old, new, context)` sets the context. Only the hunks are returned, so prepend `--- a/x\n+++ b/x\n` yourself. A missing final newline shows up as `\ No newline at end of file`, as git prints it.

## Limits
- **Width is an approximation per code point, not per grapheme.** It counts 0 for controls, combining marks, zero-width joiners and spaces, variation selectors and emoji skin-tone modifiers. It counts 2 for East Asian Wide and Fullwidth chars (CJK, Hangul, kana, fullwidth forms) and emoji with default emoji presentation. Everything else counts 1. What it gets wrong:
  - ZWJ sequences (`👨‍👩‍👧` counts 6, a terminal draws 2) and flags made of regional indicators (2 chars, so 2 columns, which may differ by terminal).
  - Text-default symbols turned into emoji with U+FE0F (`❤️` counts 1).
  - East Asian Ambiguous chars (`±`, `Ω`, box drawing) count 1, which is right outside CJK locales.
  - The tables roughly follow Unicode 15, so newer emoji count 1.
- **No grapheme segmentation or Unicode normalization.** `distance` and `truncate` work on code points. `"é"` written as `e` plus a combining accent counts as 2 chars for `distance`, and `truncate` can cut between the `e` and its accent.
- **Case mapping is ASCII-only**, like core's `upper`/`lower`. `snake("Ärger")` keeps the `Ä`.
- `diff` uses memory proportional to D² (D = the number of differing lines), so it suits source files and config, not huge, mostly different inputs.
