# glob

Glob patterns for file paths: `*`, `?`, `[...]`, `**` and `{a,b}`. Matching is a pure function of two strings. `walk` and `find` list directories to return the paths that match.

**Effects:** `fs`, and only `walk` and `find` need it. `matches`, `compile`, `escape` and `is_pattern` are pure.

```duck
fn main(): int! uses fs {
  assert glob.matches("src/**/*.duck", "src/net/tcp.duck")
  assert glob.matches(r"*.{md,toml}", "quack.toml")      // r"…": `{` in a normal string interpolates
  assert !glob.matches("*", ".env")                      // wildcards skip hidden files

  for path in glob.walk("src", "**/*.duck")? { print(path) }    // lib.duck, net/tcp.duck, ...
  let docs = glob.find("docs/*.md")?                            // ["docs/guide.md", ...]

  let g = glob.compile(r"**/*.{png,jpg}")                       // compile once, match many
  let images = docs.filter(p => glob.matches(g, p))
  print(glob.escape("report[1].txt"))                           // report\[1\].txt
  0
}
```

## Pattern syntax
| pattern | matches |
|---|---|
| `?` | any one char except `/` |
| `*` | any run of chars (possibly empty) except `/` |
| `[abc]` `[a-z0-9_]` | one char from the set. A `]` first in the set is literal, as is a `-` first or last |
| `[!a-c]` `[^a-c]` | one char not in the set (never `/`) |
| `**` | as a whole segment: zero or more segments. `src/**/*.duck` matches `src/a.duck` and `src/x/y/a.duck`, and `a/**` matches `a` itself. Inside a longer segment (`a**b`) it is just `*` |
| `{a,b,c}` | any of the alternatives. They may nest, may be empty (`file{,.bak}`) and may contain `/` and wildcards |
| `\x` | `x` literally |

- **Hidden files:** a segment that starts with `.` matches only a pattern segment that starts with a literal `.`. So `*` and `**` skip `.git`, `.env` and the like, while `.*`, `.git/**` and `**/.cache/*` still reach them.
- **Paths:** segments are split on `/`. Empty segments, a leading `./` and a trailing `/` are ignored. A pattern that starts with `/` matches only absolute paths, and the other way round. Matching is case-sensitive and compares chars (code points).
- **Never an error:** an unclosed `[`, or a `{` without a top-level `,` and a closing `}`, matches literally, as in bash. So every string is a valid pattern.

## API
- `matches(pattern: str, path: str): bool`
- `compile(pattern: str): Glob` and `matches(g: Glob, path: str): bool`: expand and tokenize the pattern once, then match it against many paths.
- `walk(dir: str, pattern: str): [str]! uses fs`: returns every file and directory under `dir` whose path relative to `dir` matches. Results are relative to `dir`, joined with `/`, in walk order (each directory's entries sorted by name, with a directory's contents right after it; call `.sort()` if you want plain lexicographic order). `walk` opens only directories that could still match, so `src/*.duck` never reads `docs/`, and `**` never descends into hidden directories. It follows symlinks, down to at most `MAX_DEPTH` (64) levels, because `fs` can't detect symlink cycles. It fails if `dir` can't be listed.
- `find(pattern: str): [str]! uses fs`: a pattern that carries its own base directory. `find("src/**/*.duck")` walks `src` and returns `src/...` paths, while `find("/etc/*.conf")` returns absolute paths. A pattern without glob syntax returns `[pattern]` if that path exists, otherwise `[]`.
- `escape(s: str): str`: backslash-escapes `* ? [ ] { } , \`, so the result matches only `s`.
- `is_pattern(s: str): bool`: tells whether `s` contains any of `* ? [ { \`.

## Notes
- In Duck source, `{` inside a normal string starts interpolation. Write brace patterns as raw strings (`r"*.{md,toml}"`) or double the braces (`"*.{{md,toml}}"`). Patterns read at run time (from arguments or config files) need nothing special.
- `walk` and `find` return directories too when they match (`walk(d, "*")` lists both files and directories). Filter with `fs.is_dir` if you only want files.
- Brace expansion multiplies: `{a,b}{c,d}{e,f}` makes 8 patterns. Keep alternatives reasonable.
- `*` and `?` match `/` in neither `matches` nor `walk`. If you want a pattern without `/` to match a file name at any depth, as in `.gitignore`, write `**/name`.
