# Packages raft needs

What a real package ecosystem depends on, measured from the 50 most-downloaded Rust crates, and what that means for Auk's package manager, `raft`.

## 1. Summary

- Half of Rust's top 50 (25 crates) is **Rust-specific plumbing**: proc-macro machinery (`syn`, `quote`), OS bindings (`libc`, `windows-*`), and internals of other crates. Auk needs none of it, because the compiler derives code itself and the C runtime talks to the OS.
- **17 more are covered already**: 12 by language or core features (ordered maps, `T!` errors, derived `Data`, `imprint`, async runtime) and 5 by existing packages (`json`, `regex`, `cli`).
- The **8 real gaps** in the top 50 are base64, hashing (`digest`), logging, case conversion and string similarity, secure random bytes, server sockets and a byte type. Ranks 51–300 add the application libraries: time/dates, URLs, TOML, UUIDs, TLS, compression and HTTP servers.
- **P0 packages (done, 0.1.0):** `encoding` (base64/hex/percent), `hash` (sha256/hmac/crc32/fnv), `datetime`, `url`, `toml`, `log`. See §5 for what shipped.
- **P1:** `uuid`, an HTTP server inside `http`, `compress`, `num` (decimal), `text`, `yaml`, `glob`. `uuid`, `text`, `num`, `glob`, the `http` server, `compress` and `yaml` are done (0.1.0; see §5). **P2:** `crypto`, `term`, `sqlite`, `template`, `xml`, `binary`, `semver`, `prop`, `snap`.
- **The biggest blockers are in core, not packages:** there is no TLS (so `https://` fails), no bitwise integer operators (needed for any hashing or encoding written in Auk), no byte type or binary file I/O, no `net.listen`, no stderr/stdin, and no directory listing.

## 2. Methodology

- **Source:** the crates.io API, fetched **2026-10-30**:
  - `GET /api/v1/crates?sort=downloads&per_page=50` gives the all-time top 50 (the main table).
  - `GET /api/v1/crates?sort=recent-downloads&per_page=50` gives the top 50 by downloads over the last 90 days.
  - Following the API's `next_page` cursor gave all-time ranks 51–300, which I used as evidence for package priorities.
  - `GET /api/v1/crates/<name>` gave counts for 17 crates outside the top 300 (serde_yaml, zip, rusqlite, sqlx, rust_decimal, chrono-tz, proptest, insta, md-5, handlebars, tera, minijinja, similar, dirs, csv, quickcheck, serde_yml).
- **No numbers are estimated.** Every download count below comes from those API responses, and none was unavailable (no "n/a" entries). A rank like "#103" means the crate's all-time rank.
- **Caveat:** downloads count every CI build and every transitive dependency. They measure how deep a crate sits in dependency trees, not how often developers choose it. That is why plumbing crates dominate, and why I looked past rank 50 for application-level evidence.
- **Verdicts** compare each crate's purpose with `docs/spec.md`, `docs/raft.md`, the five `packages/*/README.md` files, and the actual core prelude (`compiler/prelude/*.auk`, `runtime/src/core.rs`):
  - 🟢 **Built into Auk**: a language or core feature makes it unnecessary.
  - 🔵 **Covered** by an existing package.
  - ⚪ **Not applicable**: Rust implementation plumbing.
  - 🔴 **Gap**: Auk needs a new package or new core/runtime support.

## 3. The top 50 (all-time downloads)

Tally: ⚪ 25 · 🟢 12 · 🔵 5 · 🔴 8.

| # | crate | downloads | purpose | verdict | Auk equivalent / notes |
|---|---|---|---|---|---|
| 1 | hashbrown | 2,898,552,276 | Fast hash map (std's HashMap backend) | 🟢 | `{K: V}` maps are built in (insertion-ordered) |
| 2 | syn | 2,843,372,694 | Parses Rust source for proc macros | ⚪ | No proc macros; the compiler derives Show/Eq/Ord/Data itself |
| 3 | getrandom | 2,422,798,105 | OS secure random bytes | 🔴 | Core gap: core `rand` is a seeded PRNG; add `rand.bytes(n)` from the OS CSPRNG |
| 4 | bitflags | 2,141,757,841 | Typed bit-flag sets | 🟢 | Field-less enum + `Set<T>` |
| 5 | ~~**No stderr, stdin or exit code control**~~ *Resolved*, except `proc.exec` | log (#28), env_logger (#245), anstream (#144) | Done: `eprint(x)` (always allowed), `env.read_line(): str?`, `env.read_all(): str!`, `env.lines(): [str]` (stdin belongs to `env` with args and variables, so no new effect), and `proc.exit(code)`. Still open: `proc.exec(cmd, args, input): proc.Out!` with `{ code, stdout, stderr }`. |
| 6 | ~~**Filesystem basics missing**~~ *Resolved*, except `home()` | tempfile (#100), walkdir (#170), glob (#195), same-file (#182), dirs (385,720,328) | Done: `fs.list(dir): [str]!` (sorted), `exists`, `is_dir`, `mkdir` (with parents), `remove`, `rename`, `append`, `temp_dir(): str!` (mkdtemp, mode 0700). `glob` and `snap` can now be thin packages, and `tempfile` needs no package. Still open: `home(): str?` (today `env.get("HOME")`). |
| 7 | ~~**No secure random bytes**~~ *Resolved* | getrandom (#3), rand_core (#5), rand_chacha (#21) | Done: `rand.bytes(n): [int] uses rand` from the OS CSPRNG (`arc4random_buf` on macOS/BSD, `getrandom` or `/dev/urandom` on Linux), `rand.shuffle(xs): [T]`, `rand.choice(xs): T?` (in Auk, on `rand.int`), and `rand.seed(n)` for reproducible tests (seeds `int`/`float`/`shuffle`/`choice`, never `bytes`). |
| 8 | quote | 1,859,989,566 | Builds Rust tokens in proc macros | ⚪ | No proc macros |
| 9 | proc-macro2 | 1,851,396,512 | Proc-macro token API | ⚪ | No proc macros |
| 10 | base64 | 1,844,709,827 | Base64 encode/decode | 🔴 | New package `encoding` (P0) |
| 11 | windows-sys | 1,825,012,581 | Windows API bindings | ⚪ | Runtime/platform layer |
| 12 | indexmap | 1,784,470,343 | Insertion-ordered hash map | 🟢 | Core maps keep insertion order |
| 13 | itertools | 1,741,456,233 | Extra iterator adapters | 🟢 | Core collection methods; a few (`chunks`, `windows`, `flat_map`, `group_by`) are core gaps |
| 14 | thiserror-impl | 1,734,030,911 | Proc macro behind thiserror | ⚪ | No proc macros |
| 15 | thiserror | 1,733,862,349 | Derive `Error` for enums | 🟢 | `T!E` error enums, `fail`, `?`, `"{e}"` |
| 16 | cfg-if | 1,665,004,822 | Conditional compilation macro | ⚪ | Platform branching lives in the C runtime |
| 17 | memchr | 1,643,864,075 | SIMD byte search | ⚪ | Runtime implements `find`/`contains`/`split` |
| 18 | regex-syntax | 1,627,023,753 | Regex parser (regex internals) | 🔵 | `regex` |
| 19 | serde | 1,614,091,754 | Serialization framework | 🟢 | `Data` shape: derived `to_value`/`from_value` via `Value` |
| 20 | unicode-ident | 1,605,744,992 | Unicode identifier tables for parsers | ⚪ | Used by syn; Auk's lexer owns this |
| 21 | rand_chacha | 1,586,184,880 | ChaCha CSPRNG (rand internals) | ⚪ | Algorithm detail; the need is covered by the secure `rand.bytes` gap |
| 22 | itoa | 1,553,187,056 | Fast int-to-string | 🟢 | String interpolation / `str(n)` |
| 23 | serde_derive | 1,530,785,554 | `#[derive(Serialize, Deserialize)]` | 🟢 | Compiler-derived `to_value`/`from_value` |
| 24 | serde_json | 1,518,732,576 | JSON | 🔵 | `json` |
| 25 | heck | 1,481,871,768 | Case conversion (snake/camel/kebab) | 🔴 | New package `text` (P1) |
| 26 | autocfg | 1,480,271,027 | Detects compiler features in build scripts | ⚪ | No build scripts |
| 27 | once_cell | 1,447,466,430 | Lazy/once-initialized values | 🟢 | Top-level `let` and `imprint` |
| 28 | log | 1,446,099,389 | Logging facade | 🔴 | New package `log` (P0); needs core stderr |
| 29 | cc | 1,431,177,156 | Compiles C code from build scripts | ⚪ | Auk already emits C; native code goes through `ffi` |
| 30 | regex-automata | 1,429,342,728 | Regex matching engines (regex internals) | 🔵 | `regex` (backtracking; a linear-time engine is P2) |
| 31 | socket2 | 1,409,676,040 | Low-level socket options | 🔴 | Core gap: no `net.listen` (server sockets) |
| 32 | smallvec | 1,378,250,485 | Inline small vectors | ⚪ | Refcounted copy-on-write values; no stack-vs-heap choice |
| 33 | rustix | 1,322,757,516 | POSIX syscall bindings | ⚪ | Runtime/platform layer |
| 34 | regex | 1,322,019,431 | Regular expressions | 🔵 | `regex` |
| 35 | aho-corasick | 1,311,334,106 | Multi-substring search (regex internals) | ⚪ | Regex/runtime internal |
| 36 | digest | 1,283,130,372 | Traits for hash functions | 🔴 | New package `hash` (P0) |
| 37 | clap | 1,281,112,588 | Command-line argument parser | 🔵 | `cli` |
| 38 | ryu | 1,278,400,261 | Fast float-to-string | 🟢 | Floats print in shortest exact form |
| 39 | block-buffer | 1,255,373,339 | Block buffering for hashes (sha2 internals) | ⚪ | Internal to a `hash` package |
| 40 | linux-raw-sys | 1,248,353,376 | Linux kernel API bindings | ⚪ | Runtime/platform layer |
| 41 | parking_lot_core | 1,247,822,723 | Lock internals | ⚪ | No user-visible locks; values are copy-on-write |
| 42 | windows_x86_64_msvc | 1,243,708,055 | Windows import library | ⚪ | Platform linking |
| 43 | strsim | 1,217,549,017 | String similarity (Levenshtein, etc.) | 🔴 | New package `text` (P1) |
| 44 | parking_lot | 1,216,960,683 | Faster mutexes/rwlocks | ⚪ | No user-visible locks; concurrency is async/await |
| 45 | bytes | 1,206,830,008 | Byte buffers | 🔴 | Core gap: a compact bytes type; today bytes are `[int]` |
| 46 | windows_x86_64_gnu | 1,198,686,143 | Windows import library | ⚪ | Platform linking |
| 47 | mio | 1,195,999,995 | Non-blocking I/O event loop | 🟢 | Built-in async runtime |
| 48 | windows_aarch64_msvc | 1,191,023,317 | Windows import library | ⚪ | Platform linking |
| 49 | windows_i686_msvc | 1,188,926,874 | Windows import library | ⚪ | Platform linking |
| 50 | windows-targets | 1,187,863,218 | Selects Windows import libs | ⚪ | Platform linking |

### Categories

| category | crates in top 50 | count | Auk status |
|---|---|---|---|
| Platform bindings | libc, windows-sys, rustix, linux-raw-sys, windows-targets, windows_* (×4) | 9 | ⚪ C runtime |
| Macros / build | syn, quote, proc-macro2, unicode-ident, cfg-if, autocfg, cc | 7 | ⚪ compiler-owned derivation |
| Text | regex, regex-syntax, regex-automata, aho-corasick, memchr, heck, strsim | 7 | 🔵 regex; 🔴 `text` |
| Data structures | hashbrown, indexmap, itertools, smallvec, bitflags, once_cell, bytes | 7 | 🟢 mostly; 🔴 bytes |
| Serialization / formatting | serde, serde_derive, serde_json, base64, itoa, ryu | 6 | 🟢/🔵; 🔴 base64 |
| Randomness | getrandom, rand, rand_core, rand_chacha | 4 | 🟢 core `rand`; 🔴 secure bytes |
| Concurrency / async / net | mio, socket2, parking_lot, parking_lot_core | 4 | 🟢 async runtime; 🔴 listen |
| Errors | thiserror, thiserror-impl | 2 | 🟢 `T!E` |
| Crypto / hashing | digest, block-buffer | 2 | 🔴 `hash` |
| CLI | clap | 1 | 🔵 cli |
| Logging | log | 1 | 🔴 `log` |

**What dominates:** 16 of 50 crates exist only to make Rust itself work (macros and OS bindings). Once you set those aside, the ecosystem's center of gravity is **data in and out** (serialization, encoding, text and regex), followed by **randomness**, **hashing** and **I/O plumbing**. Auk's design already removes the most-downloaded application layer (serde, thiserror, once_cell, indexmap), so its remaining needs are **formats and encodings** (base64, TOML, URLs, dates) and **bytes-level infrastructure** (hashing, TLS, compression).

### All-time vs. recent (last 90 days)

- **Entered the recent top 50:** `sha2` (recent #37), `crypto-common` (#27), `cpufeatures` (#19); `toml_datetime` (#45) and `winnow` (#38, the TOML parser); `http` (#49), `shlex` (#42), `zerocopy`, `zmij` (a float formatter replacing `ryu`), `serde_core` (a serde split), and `foldhash` (the hasher behind hashbrown).
- **Dropped out:** `clap`, `strsim`, `ryu`, `mio`, `parking_lot(_core)`, and the per-target `windows_*` import libraries.
- **What that means:** hashing (sha2) and TOML config are moving from leaf dependencies into the default stack, and HTTP types are now near-universal. That supports putting `hash`, `toml` and HTTP server work early. CLI parsing staying just outside the recent top 50 is noise, not a trend (`clap` is still #37 all-time).

## 4. What Auk already covers

| Auk feature | replaces (all-time rank) |
|---|---|
| `T!`, `T!E`, `?`, `fail`, `"{e}"` | thiserror (#15), thiserror-impl (#14), anyhow (#65) |
| derived `to_value`/`from_value` (`Data`), Show/Eq/Ord | serde (#19), serde_derive (#23), serde_core, derive_more (#267), strum (#168) |
| top-level `let`, `imprint` | once_cell (#27), lazy_static (#64), phf (#207) |
| insertion-ordered `{K: V}` maps, `Set<T>` | hashbrown (#1), indexmap (#12), fnv (#109), ahash (#121), bitflags (#4) |
| core collection methods | itertools (#13), either (#57) |
| interpolation, shortest float printing | itoa (#22), ryu (#38) |
| async/await + built-in runtime | mio (#47), tokio basics (#63), futures (#115) |
| refcounted copy-on-write values | smallvec (#32), arrayvec (#214), parking_lot (#44) |
| core `rand.int`/`rand.float` | rand (#6) for everyday use |
| package `json` | serde_json (#24) |
| package `regex` | regex (#34), regex-syntax (#18), regex-automata (#30) |
| package `cli` | clap (#37), clap_builder, clap_derive, clap_lex |
| package `csv` | csv (278,915,649 downloads) |
| package `http` (client and `http.server`) | reqwest (#130); `http://` and `https://` (core TLS); hyper/axum basics (#76, #269) |

## 5. Packages raft needs

All signatures follow `docs/spec.md`. Bytes are `[int]` (0–255) as in core `net`, until core gets a bytes type (§6). Every package mirrors the `json` shape where it can (`parse`/`decode`/`encode`/`message`), so an AI that knows one package can predict the others.

### P0: needed by typical AI-written programs now (done: 0.1.0, in `packages/`)

All six packages are in the registry (`raft add encoding`, and so on), declare `effects = []`, and pass their own `auk test` suites (also under `AUK_LEAK_CHECK` and ASan/UBSan; `tests/packages_p0.rs` runs them and installs each one with raft). Each README has the full API. The sketches further down are the original proposals, kept for the evidence; this is what shipped and where it differs.

| package | deps | shipped API (summary) | deviations from the sketch |
|---|---|---|---|
| `encoding` | none | `base64`, `base64url` (unpadded), `encode64(bs, url, pad)`, `from_base64`, `from_base64url`; `hex`, `hex_upper`, `from_hex`, `hex_val`; `percent_encode(s)` / `percent_encode(s, safe)`, `percent_decode`, `percent_decode_bytes`, `is_unreserved`; `EncErr { BadChar(at, c), BadLength(len), BadPadding(at), TrailingBits(at), BadEscape(at), BadUtf8 }`, `message` | adds `from_base64url`, `encode64` and percent-encoding (the sketch had it in `url`); `EncErr` gains `BadPadding`, `TrailingBits`, `BadEscape`, `BadUtf8`. Decoding is strict: padding is optional but must be right when present, and non-canonical trailing bits are rejected. |
| `hash` | none | `sha256`, `sha256_hex(str)` / `sha256_hex([int])`, streaming `Sha256` + `new_sha256()` / `update(var s, bs)` / `finish(s)`; `hmac_sha256`; `crc32`, `crc32_update`; `fnv1a64`; constant-time `equal(a, b)` | `same` is named `equal`; adds `fnv1a64` and `crc32_update`. SHA-512, SHA-1 and MD5 are not in 0.1. |
| `datetime` | none | `Date`, `Time`, `DateTime { ms, offset_min }`, `Weekday`, `Unit { Ms, Sec, Min, Hour, Day, Week, Month, Year }`, `DateErr { Syntax(expected, col), OutOfRange(field, value) }`; `from_unix_ms`, `unix_ms`, `utc(...)`, `make`, `with_offset`, `date`, `time`, `add`, `diff`, `add_days`, `add_months`, `days`/`from_days`, `weekday`, `is_leap`, `days_in_month`, `day_of_year`; `parse` (RFC 3339 / ISO 8601), `parse_date`, `parse_time`, `show` (RFC 3339), `format(d, "%Y-%m-%d …")`, `http_date`; `cmp` (so `<` and `sort` work) | `from_ms` is named `from_unix_ms`. **No IANA database:** `in_zone(d, "Europe/Paris")` is replaced by fixed offsets (`with_offset(d, minutes)`); embedding tz data with `imprint` is left for later. Durations are plain `int` milliseconds, not `int<ms>`, because `time.now()` returns a plain `int` and the unit would force conversions on every caller. |
| `url` | `encoding` | `Url { scheme, user: str?, host: str?, port: int?, path, query: str?, fragment: str? }`; `parse` (any URI reference, strict), `show` (`"{u}"`), `resolve(base, rel)` (RFC 3986 §5.2, all §5.4 examples), `remove_dots`, `is_absolute`, `default_port`, `port_or_default`, `host_port`, `target`; `parse_query`, `build_query`, `params`, `param`, `with_params`, `segments`; `UrlErr { BadChar(at, c), BadEscape(at), BadScheme(at), BadPort(at), BadHost(at), NotAbsolute }`, `message` | `join` is named `resolve`; `form` is `build_query`; `escape` is `encoding.percent_encode`. Query, fragment, user and host are optional, so absent and empty can be told apart, as RFC 3986 resolution requires. No IDNA/punycode or IRIs yet. |
| `toml` | none | `parse(s): Value!TomlErr` (full TOML 1.0; root `Map` in document order), `str(v): str!`, `decode<T: Data>(s): T!`, `encode<T: Data>(x): str!`, `message`; `TomlErr { Unexpected(found, want, line, col), Eof(want, line, col), BadNumber, BadDateTime, BadEscape, ControlChar, DuplicateKey(key, line, col), NotATable(key, line, col), TooDeep }` | `str`/`encode` return `str!` (a non-`Map` root or a `Null` inside an array can't be written); `Unexpected`/`Eof` also say what was expected. Dates and times stay `Str` (validated, RFC 3339 form, no `datetime` dependency). The writer keeps map order (json sorts). Not yet: TOML 1.1 additions, comment-preserving edits. |
| `log` | `json` | `Level`, `Logger { min, json, fields }`, `new(min)`, `json(l)`, `with<T: Data>(l, key, v)`, `debug`/`info`/`warn`/`error` `(l, msg)` and `(l, msg, fields: {str: Value})`, `log(l, lv, msg, fields)`, `line(...)`: `str?` (pure), `enabled`, `level(s): Level!`, `name(lv)` | `with` takes any `Data` value, not just `Value`. Adds per-line fields, `line` and `enabled`. Writes with `eprint`, and lines have no timestamp (no `time` effect). |

**`http` migration onto `url`** (done): `http` now depends on `url` (and so `encoding`), both effect-free. `http.uri.Url { tls, host, port, target }` is kept as http's own view. `http.uri.parse` is `url.parse` plus a thin check: the scheme is http or https, the host is non-empty, there is no userinfo, and the port is 1–65535. The new `http.uri.from_url` does the same for a `url.Url`, and redirects resolve with `url.resolve` (RFC 3986 §5.2), with `Location: ""` still an error. The changes callers can see:
  - **Characters must be encoded.** URLs are strict RFC 3986. Raw non-ASCII, spaces, control characters and `` "<>\^`{|} `` are a `BadUrl` error, and a `%` must be followed by two hex digits. http.uri only rejected whitespace, so callers must now percent-encode these themselves (`encoding.percent_encode`).
  - **Schemes ignore case.** `HTTP://a.com` is accepted.
  - **Dot segments follow the RFC.** `..` handling in redirects now matches RFC 3986 exactly, the same for every reference form.
  - **Parameters renamed.** The URL parameter of `get`/`post`/`post_json` is named `to`, because a local named `url` would now clash with the dependency. Call sites don't change.


**`encoding`**: base64, base64url and hex. *Rust:* base64 (#10, 1,844,709,827), hex (#159), data-encoding (#295). *Effects:* none. *Size:* S.
```
pub enum EncErr { BadChar(at: int, c: char), BadLength(len: int) }
pub fn base64(bs: [int]): str               // encoding.base64("hi".bytes())
pub fn from_base64(s: str): [int]!EncErr
pub fn base64url(bs: [int]): str            // URL-safe alphabet, no padding
pub fn hex(bs: [int]): str
pub fn from_hex(s: str): [int]!EncErr
```
*Why:* base64 is the highest-ranked application crate in the top 50 (#10). It shows up in HTTP Basic auth, data URLs, JWTs and binary-in-JSON.

**`hash`**: SHA-256/512, SHA-1, MD5, HMAC, CRC-32 and constant-time compare. *Rust:* digest (#36), block-buffer (#39), sha2 (#58, recent #37), hmac (#189), sha1 (#226), md-5 (429,146,952), crc32fast (#141), subtle (#139). *Effects:* none. *Size:* M.
```
pub fn sha256(data: [int]): [int]
pub fn sha256_hex(s: str): str               // hash the UTF-8 text, return lowercase hex
pub fn hmac_sha256(key: [int], msg: [int]): [int]
pub fn crc32(data: [int]): int
pub fn same(a: [int], b: [int]): bool        // constant-time compare for MACs
```
Also `sha512`, `sha1` and `md5`, plus incremental `Sha256` state with `update(h: var Sha256, data: [int])` and `finish`. *Why:* the digest family takes 3 of the top 50 plus a fast-rising `sha2`. It's needed for webhook signatures, API request signing, checksums and cache keys. raft's own lock checksum is SHA-256, which gives a ready test oracle. This package is not for password hashing (see `crypto`, P2).

**`datetime`**: dates, times, durations, RFC 3339 and time zones. *Rust:* time (#84, 1,023,432,190), chrono (#103, 928,616,054), iana-time-zone (#150), httpdate (#199), chrono-tz (184,805,506). *Effects:* **none**: the caller passes the clock (`datetime.from_ms(time.now())`), and the IANA tz database is compiled in with `imprint` rather than read from `/usr/share/zoneinfo`. *Size:* L (calendar math plus tz data).
```
pub struct DateTime { ms: int, offset_min: int }   // instant + display offset
pub fn from_ms(ms: int): DateTime                    // UTC
pub fn parse(s: str): DateTime!DateErr               // RFC 3339 / ISO 8601
pub fn format(d: DateTime, pattern: str): str        // "%Y-%m-%d %H:%M"; d.show() gives RFC 3339
pub fn add(d: DateTime, n: int, unit: Unit): DateTime  // enum Unit { Sec, Min, Hour, Day, Month, Year }
pub fn in_zone(d: DateTime, zone: str): DateTime!DateErr  // "Europe/Paris"
```
Plus a calendar-only `Date` type, `weekday`, `diff`, and `http_date` for headers. *Why:* two independent time crates both sit in the top ~100, and JSON APIs, logs and schedulers all carry timestamps. Today core gives only epoch milliseconds.

**`url`**: URL parsing and joining, percent-encoding, query strings and form encoding. *Rust:* idna (#66, 1,093,369,553), percent-encoding (#82), url (#90, 1,007,813,394), form_urlencoded (#104), serde_urlencoded (#211). *Effects:* none. *Size:* M.
```
pub struct Url { scheme: str, host: str, port: int?, path: str, query: str, fragment: str }
pub fn parse(s: str): Url!UrlErr
pub fn join(base: Url, rel: str): Url!UrlErr
pub fn params(u: Url): [(str, str)]          // decoded query pairs, order kept
pub fn escape(s: str): str                   // percent-encode one component
pub fn form(pairs: [(str, str)]): str        // application/x-www-form-urlencoded
```
*Why:* four crates of the URL stack rank #66–#104. `http.uri` already parses URLs but has no query or percent-encoding support, so `http` should be rebuilt on top of `url`. Internationalized domain names (punycode, the `idna` crate) can follow as a P1 addition to the same package.

**`toml`**: config files. *Rust:* toml (#73, 1,070,695,829), toml_edit (#97), toml_datetime (#98; recent #45), winnow (#67; recent #38). *Effects:* none. *Size:* M.
```
pub fn parse(s: str): Value!TomlErr
pub fn decode<T: Data>(s: str): T!           // let c: Config = toml.decode(fs.read("app.toml")?)?
pub fn encode<T: Data>(x: T): str
pub fn str(v: Value): str
pub fn message(e: TomlErr): str              // "3:7: expected '='"
```
TOML datetimes become `Str` in RFC 3339 form, because `Value` has no date variant. *Why:* TOML is the config format rising fastest in the recent list, and Auk's own `raft.toml` is TOML, so the format is both needed and familiar to users.

**`log`**: leveled, structured logging to stderr. *Rust:* log (#28, 1,446,099,389), tracing (#94), tracing-core (#92), tracing-subscriber (#184), env_logger (#245). *Effects:* none, provided core adds `eprint` (always allowed, like `print`; see §6). *Size:* S.
```
pub enum Level { Debug, Info, Warn, Error }
pub fn new(min: Level): Logger               // no global state: pass the Logger
pub fn info(l: Logger, msg: str)             // also debug/warn/error
pub fn with(l: Logger, key: str, v: Value): Logger   // structured fields, like tracing spans
pub fn json(l: Logger): Logger               // emit one JSON object per line
```
`log.level(env.get("LOG") else "info")` parses a level from text. Timestamps are left to the log collector (journald, Docker), so the package needs no `time` effect. *Why:* `log` is the top-ranked application crate in the top 50 that Auk doesn't cover, and the tracing family adds four more crates in the top 250.

### P1: common

**Done (0.1.0, in `packages/`): `uuid`, `text`, `num`, `glob`, the `http` server (`http.server`), `compress`, `yaml`.** Each passes its own `auk test` suite, also under `AUK_LEAK_CHECK=1` and ASan/UBSan, and installs with `raft add`. Each README has the full API. The table summarizes what shipped and how it differs from the sketches below.

| package | effects | shipped API (summary) | deviations from the sketch |
|---|---|---|---|
| `uuid` | `rand` (generators only) | `Uuid { bytes }`, `Variant { Ncs, Rfc, Microsoft, Future }`, `UuidErr { BadLength, BadChar(at, c) }`, `message`; `v4()`, `v7(ms)`, `v7_after(prev, ms)` (strictly increasing, RFC 9562 §6.2 method 2), `v4_from(bytes)` / `v7_from(ms, bytes)` (deterministic), `nil`, `max`, `from_bytes`; `version`, `variant`, `timestamp(u): int?`, `is_nil`, `is_max`, `cmp` (`<`, `sort`); `parse` (canonical, upper case, `{…}`, `urn:uuid:`, 32 bare hex), `show` (`"{u}"`), `simple`, `urn` | adds `v7_after`, the deterministic `*_from` constructors, `timestamp`, `simple`/`urn`, `nil`/`max`. Only v4 and v7 can be generated: v3/v5 need MD5/SHA-1, which aren't in `hash` 0.1, and v1/v6 need a node ID. Other versions parse and report their version. |
| `text` | none | `words`, `snake`, `kebab`, `camel`, `pascal`, `title`, `constant`, `capitalize`; `distance` (Levenshtein), `similarity`, `suggest(s, opts, n)`, `closest`; `char_width`, `width`, `pad_left`/`pad_right`, `truncate(s, w[, ellipsis])`; `shell_words(s): [str]!ShellErr`, `quote`, `join`; `wrap`, `fill`, `indent`, `dedent`; `Edit { Keep, Del, Ins }`, `diff(old, new)` (Myers), `unified(old, new[, context])` | adds `constant`, `title`, `suggest`, `similarity`, shell `quote`/`join`, width-aware padding. Width is per code point (tables for zero-width and East Asian wide/emoji), not per grapheme. Graphemes and Unicode normalization were left out. Case mapping is ASCII-only, like core. |
| `num` | none | `Dec { neg, mag, scale }` (arbitrary-precision base-10^9 limbs), `Round { HalfEven, HalfUp, HalfDown, Down, Up, Floor, Ceiling }`, `NumErr`, `message`; `dec(s)`, `from_int`, `scaled(coef, scale)`, `ZERO`, `show`, `to_int` (`Overflow` error), `to_float`; `add sub mul div mod cmp eq` (so `+ - * / % == <` work), `div(a, b, places, mode)`, `round(d, places[, mode])`, `pow`, `sum`, `neg`, `abs`, `sign`, `is_zero`, `normalize`; `gcd`, `lcm`, `pow_mod`, `mul_mod` | `dec` also takes exponents (`1.5e3`, bounded at ±1000). There is no overflow at all: the coefficient grows, and only `to_int` checks the 64-bit range. `/` computes 18 places (half-even), then trims back to the input scale. Unary `-` can't be overloaded, so `neg(d)` is a function, and core's `sum` covers only `int`/`float`, so the package has its own `sum`. `==` is numeric (`1.5 == 1.50`) but map hashing still sees the scale: use `normalize` for keys. `Big` integers aren't in 0.1. |
| `glob` | `fs` (`walk`/`find` only) | `matches(pattern, path)`, `compile(pattern): Glob` + `matches(g, path)`, `walk(dir, pattern): [str]!`, `find(pattern): [str]!`, `escape`, `is_pattern`, `MAX_DEPTH`; syntax `* ? [..] [!..] ** {a,b} \x` | adds `walk(dir, pattern)` (results relative to `dir`), `compile`, `escape`, `is_pattern`. Wildcards don't match a leading `.` (shell rule), and `**` doesn't enter hidden directories. Malformed `[`/`{` match literally, so patterns never fail. `walk` prunes directories that can't match and caps depth at 64, since `fs` can't detect symlink cycles. |
| `http.server` (in `http`) | `net` | `Req { method, target, path, query, headers, body }`, `Server`, `listen(host, port)`, `port(s)`, `close(s)`; `serve(host, port, handler)` / `serve(s, handler)` (forever), `serve_n(host, port, n, handler)` / `serve_n(s, n, handler)` (for tests); `text`, `html`, `reply<T: Data>`, `redirect`, `not_found`; `header`, `json`, `decode<T>`, `params`, `param`; `router(route)`, so routes are clauses: `fn route("GET", "/users/" + id, r: Req)`; `request(...)` for socket-free tests. In `http.wire`: `decode_request(bs): Got!ReqErr` (`More(need, cont)` / `Done(...)`), `encode_response(status, headers, body, head_req)`, `ReqErr { BadRequest, TooLarge, HeadTooLarge, NotImplemented, BadVersion }` with `status`/`message`, `reason`, `MAX_HEAD`/`MAX_BODY` | handlers are `(Req) => http.Resp`, not `Resp!`. Adds `listen`/`port` (so port 0 works), `serve_n`, `router` (HEAD routes as GET), `html`/`redirect`/`not_found` and request helpers. One connection at a time, one request per connection (`Connection: close`, no keep-alive or pipelining). Bodies: `Content-Length` and chunked (plus `Expect: 100-continue`); strict RFC 3986 targets. Errors map to 400/413/431/501/505, and a bad handler response becomes a 500. No timeouts (needs gap 8) and no server TLS. |
| `compress` | none | `inflate` (stored, fixed and dynamic Huffman), `deflate` (LZ77 hash chains, then fixed-Huffman or stored blocks), `store`; `gzip`/`gunzip` (all header fields, multi-member, CRC-32 and length checked), `zlib`/`unzlib` (Adler-32 checked); `crc32`, `crc32_update`, `adler32`; `Entry { name, data }`, `zip(entries)` (deterministic: fixed 1980 timestamps), `unzip(bs): [Entry]!` (stored/deflated, data descriptors, CRC and size checked); `ZErr { Truncated, BadHeader(at, why), BadData(at, why), BadChecksum(what) }`, `message` | zip has no zip64, encryption or read-side timestamps/modes; `unzip` returns names as written (callers must guard against `..` paths). The encoder doesn't do dynamic Huffman or lazy matching, so output is about 20% larger than `gzip -9` on text, but every tool decodes it. CRC-32 is implemented locally (no `hash` dependency), so the package has no deps. There's no output cap, so callers should bound untrusted input. |
| `yaml` | none | `parse(s): Value!YamlErr` (one document), `parse_all(s): [Value]!`, `str(v): str` (block style; `parse(str(v)) == v`), `decode<T: Data>`, `encode<T: Data>`, `resolve` (core schema), `message`; `YamlErr { Syntax, Eof, Tab, BadEscape, UnknownAlias, DuplicateKey, Unsupported, ManyDocs, TooDeep }`, all with line and column | a YAML 1.2 subset: block and flow collections, the three quoting styles with every escape, `\|`/`>` blocks with chomping and indentation indicators, comments, multiple documents and anchors/aliases. Tags, complex keys and merge keys (`<<`) are rejected with an `Unsupported` error rather than misread. `str` is infallible (YAML can write every `Value`), unlike `toml.str`. |

The original proposal:

| package | purpose | Rust crates (evidence) | effects | size |
|---|---|---|---|---|
| `uuid` | v4/v7 IDs, parse, format | uuid (#101, 933,466,275) | `rand` | S |
| `http` server module | HTTP/1.1 server reusing `http.wire` | hyper (#76), http (#54; recent #49), httparse (#136), tower (#148), axum (#269) | `net` | L |
| `compress` | gzip/deflate/zlib, zip archives | miniz_oxide (#81), crc32fast (#141), flate2 (#142), zip (322,454,188) | none | M |
| `num` | exact `Dec` decimals (money), later `Big` integers | num-traits (#56), num-bigint (#193), rust_decimal (167,011,997) | none | M |
| `text` | case conversion, edit distance, display width, graphemes, shell-word splitting, wrapping, line diff | heck (#25), strsim (#43), shlex (#89; recent #42), unicode-width (#107), unicode-normalization (#217), unicode-segmentation (#220), similar (234,546,854) | none | M |
| `yaml` | YAML ↔ `Value`, same API as `toml` | serde_yaml (453,656,761) | none | M |
| `glob` | glob matching (pure) plus directory walk | walkdir (#170), glob (#195), dirs (385,720,328) | `fs` | S |

Sketches:
```
// uuid
pub fn v4(): Uuid uses rand
pub fn v7(ms: int): Uuid uses rand           // uuid.v7(time.now()): sortable IDs
pub fn parse(s: str): Uuid!
pub fn show(u: Uuid): str                    // "{id}" interpolates it

// http server: routing is Auk pattern matching, so no router macro is needed
pub async fn serve(port: int, handle: (Req) => Resp!): ()! uses net
pub fn text(status: int, body: str): Resp
pub fn reply<T: Data>(status: int, x: T): Resp   // JSON body

// compress
pub fn gzip(bs: [int]): [int]
pub fn gunzip(bs: [int]): [int]!
pub fn unzip(bs: [int]): [Entry]!            // struct Entry { name: str, data: [int] }

// num
pub fn dec(s: str): Dec!                     // num.dec("19.99")?
pub fn add(a: Dec, b: Dec): Dec              // gives a + b; likewise sub, mul, cmp
pub fn round(d: Dec, places: int): Dec

// text
pub fn snake(s: str): str                    // also camel, pascal, kebab
pub fn distance(a: str, b: str): int         // Levenshtein
pub fn closest(s: str, options: [str]): str? // "did you mean" suggestions
pub fn width(s: str): int                    // terminal columns (CJK, emoji)
pub fn shell_words(s: str): [str]!

// glob
pub fn matches(pattern: str, path: str): bool
pub fn find(pattern: str): [str]! uses fs    // "src/**/*.auk"
```
- **`uuid`** declares `rand` because v4 and v7 need entropy. It depends on the secure `rand.bytes` core gap (§6), since a PRNG-based v4 UUID can collide or be guessed.
- **HTTP server**: put it in `http`, not a new package. The server and client share `http.wire` and already share the `net` effect. It's P1 only because it's blocked on `net.listen`; once that exists it is P0, since "build me an API" is a very common task for AI-written programs.
- **`num`**: `float` is wrong for money, and invoices, prices and inventory (see `examples/bank.auk` and `examples/inventory.auk`) are common AI tasks.
- **`compress`** is also what `http` needs to accept `Content-Encoding: gzip`.

### P2: later

| package | purpose | Rust evidence | effects | size |
|---|---|---|---|---|
| `crypto` | AEAD (AES-GCM, ChaCha20-Poly1305), Ed25519/ECDSA, argon2/bcrypt password hashing | ring (#131), zeroize (#138), signature (#290), der (#277) | none if the runtime exposes the primitives (recommended); `ffi` otherwise | L |
| `term` | ANSI colors/styles, `strip`, simple tables | anstyle (#123), anstream (#144), nu-ansi-term (#241), termcolor (#266) | none | S |
| `sqlite` | embedded SQL database | sqlx (176,949,284), rusqlite (139,414,972) | `fs`, `ffi` | L |
| `template` | HTML/text templates with escaping | handlebars (101,875,686), minijinja (42,106,979), tera (42,080,635) | none | M |
| `xml` | XML reader/writer ↔ `Value` | quick-xml (#292) | none | M |
| `binary` | read/write big- and little-endian ints and floats in byte buffers | byteorder (#110), bytes (#45), zerocopy (recent #46) | none | S |
| `semver` | versions, requirements, matching | semver (#59) | none | S |
| `prop` | property-based testing with shrinking (deterministic seed) | proptest (227,414,436), quickcheck (76,763,225) | none | M |
| `snap` | snapshot assertions with readable diffs | insta (120,156,469), similar (234,546,854) | `fs` | S |
| `audio` | *Done (0.1.0).* Decode/encode WAV, AIFF/AIFC, AU and FLAC; resampling, filters, dynamics, EBU R128 loudness, ffmpeg-style `-af` graphs | symphonia, hound, claxon, rubato, dasp, ebur128 | none | L |
| `graphics` | *Started (0.1.0).* Drawing into `pixels` frames. `graphics.font`: parse TrueType fonts, rasterize glyphs, draw and measure text | ab_glyph, fontdue, rusttype, ttf-parser | `fs` (loading only) | M |

- **`crypto`**: write it as thin bindings over the same vetted C library the runtime links for TLS, not as pure Auk. Constant-time code and side-channel safety are hard to get right in a refcounted, bounds-checked language.
- **`semver`** ranks high (#59), but most of its downloads come from Rust build tooling (`rustc_version`, cargo plugins). AI-written apps rarely need it.
- **`audio`** is pure Auk and checked against ffmpeg and libFLAC: every decoder is bit-exact with ffmpeg; the G.711 encoders, biquads, `tremolo`, `acompressor` and `agate` match ffmpeg's output; loudness matches its `ebur128`; FLAC output passes `flac -t` and compresses like `flac -5`/`-8`. Not yet: lossy codecs (MP3, AAC, Vorbis, Opus) and Ogg/MP4/Matroska containers. Needed core math (`sin cos tan asin acos atan atan2 exp ln log10 log2`, `float.pi`, and float bit conversions for binary formats), which is now in core.
- **`graphics`** is pure Auk, made for `gui`. The glyph masks of `graphics.font` agree with Core Text's to within 1.3% of total coverage at 40 px (2.6–6.6% at 24 and 13 px), with glyphs at the same positions. Not yet: hinting, CFF outlines, complex shaping, line wrapping.
- **`sqlite`** sits well below the top 300 in Rust because Rust's database users spread across many drivers. It's still a frequent need in small AI-written apps, so it's worth doing once `ffi` is mature.

**Considered and not proposed:**
- parser combinators (nom #134, winnow #67): Auk's string patterns (`"GET " + rest`), clause groups and tail calls cover hand-written parsers.
- protobuf (prost #204): niche for typical AI-written programs.
- `once_cell`/`lazy_static`: built in.
- `rand_distr`-style distributions: `shuffle`/`choice` belong in core `rand`, and statistics distributions can wait.

## 6. Core/runtime gaps that packages can't solve alone

Ordered by how much they block.

| # | gap | evidence | recommendation |
|---|---|---|---|
| 1 | ~~**TLS**: `net.tls` returns "tls unavailable in this build", so `http.get("https://…")` fails~~ *Resolved* (client side) | rustls (#77), rustls-webpki (#108), webpki-roots (#120), tokio-rustls (#116), ring (#131), hyper-rustls (#160), openssl-probe (#191), rustls-native-certs (#221) | Done in the runtime (`runtime/src/tls.rs`) with rustls, verifying certificates against the bundled Mozilla roots (`webpki-roots`) and the host name. Verification is always on and a bad certificate is a clear Err. Still open: server TLS (`net.listen_tls`), and trusting roots installed only in the system store. |
| 2 | ~~**No bitwise integer operators**~~ *Resolved*: `& \| ^ ~ << >>` are in the language (the P0 `encoding` and `hash` packages use them) | every hash, base64, CRC, UUID, compression and binary-format package needs them (base64 #10, digest #36, sha2 #58, crc32fast #141, byteorder #110) | Done: operators that bind tighter than comparisons (mixing them unparenthesized, as in `x & 1 == 0`, is error E0038); `<<` wraps like `+% -% *%`, and `>>` is arithmetic. |
| 3 | **No byte type**: bytes are `[int]` (8 bytes per byte). *Binary file I/O is resolved: `fs.read_bytes`/`fs.write_bytes` are in core.* | bytes (#45), byteorder (#110), memchr (#17), zerocopy (recent #46) | Still to do: add a compact `bytes` core type that converts to and from `[int]`, so `compress`, `hash` and the `http` client (which today requires UTF-8 bodies) don't copy 8× the data. |
| 4 | ~~**No server sockets**~~ *Resolved* | socket2 (#31), mio (#47), hyper (#76), axum (#269) | Done: `net.listen(host, port): net.Listener! uses net` (port 0 picks a free port; `port(l)` tells which), `accept(l): net.Conn!` (blocks only its task, so an `async fn` server runs alongside other tasks), `close(l)`; see `examples/echo.auk`. This unblocks the HTTP server package. |
| 5 | ~~**No stderr, stdin or exit code control**~~ *Resolved*, except `proc.exec` | log (#28), env_logger (#245), anstream (#144) | Done: `eprint(x)` (always allowed), `env.read_line(): str?`, `env.read_all(): str!`, `env.lines(): [str]` (stdin belongs to `env` with args and variables, so no new effect), and `proc.exit(code)`. Still open: `proc.exec(cmd, args, input): proc.Out!` with `{ code, stdout, stderr }`. |
| 6 | ~~**Filesystem basics missing**~~ *Resolved*, except `home()` | tempfile (#100), walkdir (#170), glob (#195), same-file (#182), dirs (385,720,328) | Done: `fs.list(dir): [str]!` (sorted), `exists`, `is_dir`, `mkdir` (with parents), `remove`, `rename`, `append`, `temp_dir(): str!` (mkdtemp, mode 0700). `glob` and `snap` can now be thin packages, and `tempfile` needs no package. Still open: `home(): str?` (today `env.get("HOME")`). |
| 7 | ~~**No secure random bytes**~~ *Resolved* | getrandom (#3), rand_core (#5), rand_chacha (#21) | Done: `rand.bytes(n): [int] uses rand` from the OS CSPRNG (`arc4random_buf` on macOS/BSD, `getrandom` or `/dev/urandom` on Linux), `rand.shuffle(xs): [T]`, `rand.choice(xs): T?` (in Auk, on `rand.int`), and `rand.seed(n)` for reproducible tests (seeds `int`/`float`/`shuffle`/`choice`, never `bytes`). |
| 8 | **Async coordination**: no channels, timeouts or select | tokio (#63), futures-* (#69–#96), tokio-util (#114), crossbeam-channel (#205), rayon (#225) | Add runtime-backed `chan()` with `send`/`recv`, `timeout(ms, fut)`, and an async `time.sleep`. The scheduler is the runtime's, so a package can't add these. Treat CPU parallelism (rayon) as a later runtime feature. |
| 9 | ~~**Collection extras**~~ *Resolved*, except `sum_by` | itertools (#13) | Done, in Auk in the core prelude: `chunks(n)`, `windows(n)`, `flat_map(f)`, `group_by(key): {K: [T]}` (insertion-ordered) and `unique()` (first occurrence kept; hashes `Eq` values). Still open: `sum_by`. |

## 7. Recommended build order

Bitwise ops (gap 2) have landed; `fs.read_bytes`/`write_bytes` (gap 3) and `eprint` (gap 5) are in core now. TLS (gap 1) and `net.listen` (gap 4) are done, so `http` works over `https://`.

1. **`encoding`** (S): the smallest package, the highest-ranked gap in the data (base64 #10), and the first real exercise of the new bitwise ops. `hash` (hex output) and `uuid` reuse it.
2. **`hash`** (M): the digest family is rising fastest in the recent list. It unblocks webhooks, request signing and checksums, and raft's SHA-256 lock checksums give a ready test oracle.
3. **`datetime`** (L): two time crates in the top ~100, and timestamps appear in almost every data-handling program. It's pure by design (caller-supplied clock, imprinted tz data).
4. **`toml`** (M): a config format that's climbing in recent downloads. It copies the `json` API, so it is quick to write and easy for AIs to use correctly, and Auk already uses TOML for `raft.toml`.
5. **`log`** (S): the top uncovered application crate in the top 50 (#28). It's small once `eprint` exists.

**Status:** all of P0 (steps 1–5 above, plus `url`) has shipped; see §5. `http.uri` now sits on `url`, and the **HTTP server** (`http.server`, on `net.listen`) has shipped. Of P1, `uuid` (on the new `rand.bytes`), `text`, `num`, `glob`, `compress` (with `zip`/`unzip`) and `yaml` have shipped too, so the P1 list is done. Every P0 package declares **no effects**. Among the P1 packages, only `uuid` (`rand`), the server (`net`) and `glob` (`fs`) need any.
