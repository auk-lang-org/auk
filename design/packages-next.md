# Next packages

Packages most Auk programs will want after the P0/P1 set in `design/package-list.md`. Each one
follows the existing conventions: pure Auk where possible, `parse`/`decode`/`encode`/`message`
naming, a typed error enum, a README with the full API, and `test` blocks that pass under
`AUK_LEAK_CHECK=1`.

Status: ⬜ not started · 🟨 in progress · ✅ done (0.1.0) · ⛔ blocked

## Tier 1: highest value

| # | package | what | deps / effects | status |
|---|---|---|---|---|
| 1 | `term` | ANSI colors and styles, `strip`, tables, progress bars, `NO_COLOR`/tty detection | `text`; `env` | ✅ |
| 2 | `sqlite` | embedded SQL via `ffi` over the SQLite C library | `fs`, `ffi` | ⛔ blocked: user packages can't declare `extern fn` (E0036) |
| 3 | `template` | HTML/text templates with automatic escaping, loops, conditionals, partials | none | ✅ |
| 4 | `markdown` | CommonMark → HTML and → a block/inline tree | none | ✅ |
| 5 | `image` | PNG decode/encode (via `compress`), QOI, BMP; into `pixels.Frame` | `compress` | ⬜ |

## Tier 2: web and networking

| # | package | what | deps / effects | status |
|---|---|---|---|---|
| 6 | `websocket` | RFC 6455 framing, client and `http.server` upgrade | `http`, `hash`, `encoding` | ⬜ |
| 7 | `jwt` | HS256 sign/verify, claims (`exp`, `nbf`, `iat`), RS/ES once `crypto` exists | `hash`, `encoding`, `json` | ⬜ |
| 8 | `crypto` | AEAD, Ed25519, argon2/bcrypt: bindings over the runtime's TLS library | runtime | ⬜ |
| 9 | `mime` | extension ↔ content type, `multipart/form-data` parse/build | none | ⬜ |

## Tier 3: data and tooling

| # | package | what | deps / effects | status |
|---|---|---|---|---|
| 10 | `stats` | mean, median, quantiles, stddev, histograms, linear regression | none | ⬜ |
| 11 | `vec` | Vec2/3/4, Mat3/4, quaternions (check `graphics` for overlap first) | none | ⬜ |
| 12 | `binary` | big/little-endian int and float read/write over `[int]` | none | ⬜ |
| 13 | `msgpack` / `cbor` | compact binary `Value` encodings, same shape as `json` | `binary` | ⬜ |
| 14 | `prop` | property-based testing with shrinking, deterministic seed | none | ⬜ |
| 15 | `snap` | snapshot assertions with readable diffs | `text`; `fs` | ⬜ |
| 16 | `semver` | versions, requirements, matching (share with `raft`) | none | ⬜ |

## Not now

Postgres and Redis clients: large protocol work, and `sqlite` covers "I need a database" for the
programs Auk targets.

## Log

Notes on what shipped and how it differs from the plan above go here, one entry per package.

### `term` 0.1.0

- Shipped as planned. Detection is `enabled()` / `enabled(fd)`, not `auto()`, with `println` /
  `eprintln` that strip escapes when color is off. `FORCE_COLOR=0` counts as off.
- Needed two new core functions in `env`: `is_terminal(fd): bool` (isatty) and
  `columns(): int?` (TIOCGWINSZ on stdout, stderr or stdin, then `$COLUMNS`).
- Tables take styled and multi-line cells and come in five border styles (`Rounded`, `Sharp`,
  `Ascii`, `Plain`, `Markdown`).
- Not yet: truncating styled text, downgrading true color to 256 or 16 colors, raw mode or key input.
- Tested by `tests/packages_next.rs`, which runs the package's tests under the leak checker and
  checks `NO_COLOR`/`FORCE_COLOR` end to end.

### `sqlite`: blocked

`ffi` exists only as an effect name. `extern fn` is allowed only in the core prelude (E0036), so a
package can't bind `libsqlite3`. There are two ways forward: (a) a user-level FFI (an
`extern fn` in packages that declare `effects = ["ffi"]`, plus a `[link]` section in raft.toml
that passes `-l` flags to the linker), or (b) a core `sqlite` module in the runtime that links the system
`libsqlite3`. (a) is the general fix and unblocks `crypto` too.

### `template` 0.1.0

- Jinja syntax, because AI-written code already knows it. Supports `if`/`elif`/`else`, `for` (with
  `loop` and `else`), `set`, `include` (partials passed to `render`), `raw`, comments, 31
  filters and `-` whitespace control.
- Differences from Jinja: undefined names are errors (`| default(x)` catches them), a
  block tag or comment alone on its line removes the line (Mustache's "standalone" rule; no
  `trim_blocks` setting needed), and int `/` truncates.
- `render<T: Data>` takes structs directly; there's no separate `Value` entry point, because
  `to_value` of a `Value` is the value itself.
- Rendering 10k rows through an include takes about 0.4 s in a debug build.
- Not yet: `extends`/`block` inheritance, macros, custom filters, indenting included partials.

### `markdown` 0.1.0

- CommonMark plus the GFM tables, strikethrough, task lists and bare URL autolinks. Gives
  `parse` (a tree), `to_html`, `html` and `text` (plain text).
- **644/652 CommonMark 0.31.2 spec examples pass.** The check used markdown-it-py and the spec's
  `spec.json`, run outside the repo (the spec is CC-BY-SA, so it isn't vendored). 2 of the misses are
  the intended GFM autolinks. The other 6 are Unicode case folding of labels, tabs inside
  container markers, and a reference definition followed by a blank line inside a list item.
- Safe by default: raw HTML is escaped and `javascript:`/`vbscript:`/`file:`/non-image `data:`
  URLs are dropped. `Opts { unsafe_html: true }` turns both off for trusted input.
- Design: container blocks re-parse their stripped lines recursively, rather than using the
  spec's incremental open-block algorithm. Lazy continuation lines keep their indentation so they
  can't start a block. Emphasis uses the spec's delimiter-run algorithm, including the rule of 3.
- Not yet: footnotes, heading anchors, the full HTML entity table (Latin-1 and common names only).
