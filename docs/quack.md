# quack: Duck's package manager

`quack` fetches, pins and audits Duck packages. Its one unusual feature is that **packages declare their effects**, and `quack` refuses to install a package that needs an effect your project hasn't allowed. Because of that, a project's `quack.toml` tells you the most that any dependency can do.

## Core vs packages
- **Core** (always available, no install): collections, strings, math, `Set<T>`, `Value`, and the effect primitives `fs`, `net`, `env`, `proc`, `time`, `rand`, `audio_out`, `gui`. Core is kept to what the language itself needs:
  - Console: `print(x)` and `eprint(x)` (stdout and stderr; no effect needed). Stdin is part of `env`, alongside arguments and environment variables (all three are input the invoker hands the program, so no separate effect): `env.read_line(): str?` (none at end of input), `env.read_all(): str!`, `env.lines(): [str]`. `proc.exit(code: int): never uses proc` ends the program (stdout/stderr flushed).
  - Files (`uses fs`): `read`, `write`, `append`, `lines`, `read_bytes(p): [int]!`, `write_bytes(p, bs: [int]): ()!` (bytes as ints 0–255; an Err if one is out of range), `exists(p): bool`, `is_dir(p): bool`, `list(dir): [str]!` (sorted names), `mkdir(p): ()!` (with parents), `remove(p): ()!` (file or empty dir), `rename(a, b): ()!`, `temp_dir(): str!` (a new private dir).
  - Random (`uses rand`): `rand.int(lo, hi)`, `rand.float()`, `rand.shuffle(xs): [T]` and `rand.choice(xs): T?` come from a fast generator that `rand.seed(n)` makes repeatable for tests (not cryptographic); `rand.bytes(n): [int]` comes from the OS's cryptographic generator and ignores the seed.
  - `net.tcp(host: str, port: int): net.Conn! uses net` and `net.tls(host, port): net.Conn! uses net`. `net.Conn` has `write(c: var Conn, data: [int]): ()!` (bytes as ints 0–255), `read(c: var Conn, max: int): [int]!` (empty = closed), and `close(c: var Conn)`. Converting between text and bytes: `s.bytes(): [int]`, `str.from_utf8(bs: [int]): str!`.
  - TLS uses the platform's stack (Network.framework on macOS; OpenSSL 3/1.1 loaded with `dlopen` on Linux, so a build never needs it; without it `net.tls` returns Err "tls unavailable in this build"). It always verifies the certificate chain against the system trust store and the certificate's name against `host`; there is no way to turn that off. A bad certificate is an Err `net.tls <host>:<port>: certificate verification failed: <reason>`.
  - Servers: `net.listen(host: str, port: int): net.Listener! uses net` (`""` = every interface; port 0 picks a free port), `accept(l: Listener): net.Conn! uses net` (blocks only the calling task, so an `async fn` can serve while others run), `port(l): int`, `close(l: var Listener)`. See `examples/echo.duck`. Server-side TLS is not available yet.
  - Collection extras: `xs.chunks(n)` and `xs.windows(n)` (`[[T]]`, `n > 0`), `flat_map(f)`, `group_by(key): {K: [T]}` (groups in first-seen key order) and `unique()` (keeps the first of each; O(n) with a hash set, so `T: Eq`).
  - `enum Value { Null, Bool(b: bool), Int(i: int), Float(f: float), Str(s: str), List(xs: [Value]), Map(m: {str: Value}) }`, the neutral data tree. The compiler derives `to_value(x): Value` and `from_value(v: Value): T!` for every struct (as a `Map` keyed by field name) and enum (as `Map` `{"tag": Str(variant), ...fields}`; a field-less variant is just `Str(variant)`). Format packages (`json`, `csv`) convert text to and from `Value`.
- **Packages** (installed with quack): everything else. The official set lives in `packages/`:

| package | provides | effects |
|---|---|---|
| `json` | `parse` (text → core `Value`), `str`, `pretty`, `decode`/`encode` for any `Data` | none |
| `csv` | RFC 4180 reader/writer, header-keyed rows | none |
| `regex` | backtracking regex: `find`, `find_all`, `captures`, `replace` | none |
| `cli` | argument parsing: flags, options, positionals, usage text | none |
| `http` | HTTP/1.1 client: `get`, `post`, `request`, `Resp` | `net` |
| `encoding` | base64 (standard/URL-safe), hex, percent-encoding; strict decoding with `EncErr` | none |
| `hash` | SHA-256 (one-shot and streaming), HMAC-SHA-256, CRC-32, FNV-1a, constant-time `equal` | none |
| `datetime` | `Date`/`Time`/`DateTime`, calendar math, RFC 3339 parse/format, fixed UTC offsets | none |
| `url` | RFC 3986 `parse`/`show`/`resolve`, query strings (depends on `encoding`) | none |
| `toml` | TOML 1.0 `parse` (text → core `Value`), `str`, `decode`/`encode` for any `Data` | none |
| `log` | leveled logfmt / JSON-lines logging to stderr through a `Logger` value (depends on `json`) | none |
| `xml` | XML 1.0 `parse` into an `Element` tree, queries (`child`, `all`, `descendants`, `text`), `str`/`pretty` writers | none |
| `audio` | decode/encode WAV, AIFF/AIFC, AU, FLAC; `probe`; resample, remix, filters, dynamics, time stretch, EBU R128 loudness, spectra; ffmpeg-style `apply("highpass=f=80,loudnorm")` | none |

## Project layout
```
my_app/
  quack.toml          manifest (hand-edited or via `quack add`)
  quack.lock          exact versions + checksums (generated; commit it)
  src/main.duck       entry point for apps
  src/lib.duck        root module for libraries
  src/geo/shapes.duck module `geo.shapes`
  .quack/             installed packages (generated; don't commit)
```
A package's root module is `src/lib.duck`; its items are reached as `<pkg>.<item>` (e.g. `json.parse`). Other files are submodules: `src/value.duck` in package `json` is `json.value`. There are no imports; a path's first segment names a dependency, a core module, or a top-level module of your own project. A local module with the same name as a dependency is a compile error.

## quack.toml
```toml
[package]
name = "weather"
version = "0.1.0"
effects = ["net", "fs"]        # the most this package (and its deps) may use

[deps]
http = "^0.1"                  # from the registry
json = "^0.1"
geo  = { path = "../geo" }     # a local package
```
- `name`: lowercase `a-z0-9_`, and it must not collide with a core module.
- `version`: semver `MAJOR.MINOR.PATCH`.
- `effects`: a subset of `fs net time rand env proc ffi` (defaults to `[]`). The compiler rejects any `uses` in this package that isn't listed. **quack checks every dependency edge**: each package's effects must be a subset of the effects of the package that depends on it, so a dependency can never exceed what its parent allows, and the root's list bounds the whole tree.
- Version requirements: `"^1.2"` (>=1.2.0, <2.0.0; for 0.x, `^0.3` means >=0.3.0, <0.4.0; `^0.0.3` means exactly 0.0.3), `"~1.2.3"` (>=1.2.3, <1.3.0), `"=1.2.3"` (needs all three numbers), `"*"`. A bare `"1.2"` means `^1.2`. Pre-release and build suffixes aren't supported in v1.
- The `[package]` table supports strings, string arrays and inline tables only.
- Package names can't be core module names: `fs net time rand env proc ffi str int float bool math core`.

## quack.lock
Generated, one `[[package]]` per resolved dependency, sorted by name:
```toml
[[package]]
name = "http"
version = "0.1.0"
source = "registry"
effects = ["net"]
checksum = "sha256:9f2c…"
```
The checksum is SHA-256 over the installed files (`quack.toml`, `README.md` if present, `src/**`), in sorted relative-path order using `/` separators. Each file contributes its path, a NUL byte, its length as 8 big-endian bytes, then its contents. `quack install` verifies both the registry copy and `.quack/<name>/` against the lock and fails loudly on a mismatch. Path dependencies are recorded as `source = "path:../geo"` (relative to the project) and aren't verified, since they're edited freely.

## Registry
v1's registry is a directory of packages, each one `<registry>/<name>/` with a `quack.toml`. It defaults to the `packages/` folder of the Duck installation; override it with `QUACK_REGISTRY=/path`. Each name has one published version in v1. (A hosted index with many versions per package comes later; the manifest and lock formats don't change.)

## Commands
| command | does |
|---|---|
| `quack new <name> [--lib]` | create `<name>/` with `quack.toml` and `src/main.duck` (or `src/lib.duck`) |
| `quack add <pkg> [--path <dir>]` | add a dependency (latest version, as `^MAJOR.MINOR`), then install |
| `quack remove <pkg>` | drop a dependency, then re-install |
| `quack install` | resolve, check effects, copy into `.quack/<name>/`, write `quack.lock` |
| `quack list` | show the dependency tree with versions and effects |

Behavior:
- Every command finds the project by searching upward from the current directory.
- **All-or-nothing:** resolution, version matching, the effects check and checksums all happen before anything is written. On any error nothing is installed, and `add`/`remove` restore the previous `quack.toml`.
- `quack add` edits `[deps]` in place, keeping comments and formatting.
- `quack new` also writes a `.gitignore` containing `/.quack/`, and refuses to overwrite an existing directory.
- Errors print `error: …` (naming the dependency chain, e.g. `(weather -> http -> json)`) and an optional `  help: …` line, then exit 1. Running with no arguments or an unknown command prints usage and exits 2.
- `install` prints `+` for new or changed packages and `-` for removed ones, direct dependencies first, and prints nothing when nothing changed.

Example (real output, against `packages/`):
```
$ quack add http
error: http 0.1.0 needs effect `net`, but weather's quack.toml only allows []
  help: add "net" to [package] effects in quack.toml
$ quack add http          # after setting effects = ["net"]
  + http 0.1.0   uses net
  + json 0.1.0   (via http)
$ quack add csv
  + csv 0.1.0
$ quack list
weather 0.1.0   uses net
├── http 0.1.0   uses net
│   └── json 0.1.0
└── csv 0.1.0
```

## Why this design (fewest tokens + accuracy)
- **No import lines**: dependencies are named once, in the manifest.
- **Effects at the package boundary**: a reviewer or an AI agent can audit what a dependency is able to do without reading its code, and a `json` update can never start making network calls.
- **One version per package in a build** (v1): no diamond-dependency surprises, and error messages stay simple.
