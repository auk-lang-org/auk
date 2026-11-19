# Package catalog

The official packages live in `packages/` in the repository, which is also the default
registry. Add one with `raft add <name>`. Each has a `README.md` with its full API.

The "effects" column is the most a package can do. A package with none is pure computation:
it cannot touch files, the network, the clock or anything else.

## Data formats

| package | provides | effects |
|---|---|---|
| `json` | parse and write JSON; `decode`/`encode` for your own types | none |
| `toml` | TOML 1.0, the same API as `json` | none |
| `yaml` | YAML, the same API as `json` | none |
| `csv` | RFC 4180 reader and writer; rows as lists or header-keyed maps; `decode` into structs | none |
| `xml` | XML 1.0 into an element tree, with queries and writers | none |
| `markdown` | Markdown (CommonMark plus GitHub tables, strikethrough, task lists) to HTML, a tree or text | none |
| `template` | Jinja-style text and HTML templates, auto-escaped | none |

`json`, `toml`, `yaml` and `csv` all convert through core's `Value`, so the same struct works
with each:

```auk
struct Server { host: str, port: int }

fn main(): ()! {
  let s: Server = json.decode("{{\"host\": \"example.com\", \"port\": 8080}}")?
  print(s.port)                    // 8080
  print(json.encode(s))            // {"host":"example.com","port":8080}
}
```

## Text and numbers

| package | provides | effects |
|---|---|---|
| `regex` | regular expressions: `find`, `find_all`, `captures`, `replace` | none |
| `text` | case conversion, edit distance and suggestions, display width, shell words, wrapping, line diff | none |
| `encoding` | base64, hex and percent-encoding | none |
| `hash` | SHA-256, HMAC-SHA-256, CRC-32, FNV-1a, constant-time compare | none |
| `compress` | DEFLATE, gzip, zlib and zip archives | none |
| `num` | exact decimal arithmetic for money, plus `gcd`, `lcm`, `pow_mod` | none |
| `datetime` | dates, times and instants; RFC 3339; calendar math; fixed UTC offsets | none |
| `uuid` | UUID v4 and v7, parsing and formatting | `rand` |
| `url` | parse, format and resolve URLs; query strings | none |

## Programs and services

| package | provides | effects |
|---|---|---|
| `cli` | command-line parsing: switches, options, positionals, generated help | none |
| `log` | leveled, structured logging as logfmt or JSON lines | none |
| `term` | terminal colors and styles, tables, progress bars, spinners | `env` |
| `glob` | glob patterns, and walking directories for matches | `fs` |
| `http` | an HTTP/1.1 client (with TLS and redirects) and a server with pattern-matched routes | `net` |
| `sup` | supervisors: restart tasks that fail, in the Erlang/OTP style | `time` |
| `splash` | live server-rendered pages in the style of Phoenix LiveView | `net` |

A complete HTTP server, with routes written as clauses:

```auk
fn route("GET", "/", _: http.server.Req): http.Resp = http.server.text(200, "hello from auk\n")
fn route("GET", "/hello/" + name, r: http.server.Req): http.Resp {
  let greeting = r.param("greeting") else "hi"
  http.server.text(200, "{greeting}, {name}!\n")
}
fn route(_: str, _: str, _: http.server.Req): http.Resp = http.server.not_found()

fn main(): ()! uses net {
  var s = http.server.listen("127.0.0.1", 8080)?
  eprint("listening on http://127.0.0.1:{s.port()}")
  await http.server.serve(s, http.server.router(route))?
}
```

## Media

| package | provides | effects |
|---|---|---|
| `audio` | decode and encode WAV, AIFF, AU and FLAC; resampling, filters, loudness, spectra | none |
| `graphics` | drawing into frames: a canvas that tracks changed regions, TrueType text | `fs`, `gui` |

## Toolchain

| package | provides | effects |
|---|---|---|
| `llvm` | bindings to LLVM 23's C API; what the Auk compiler's back end is built on | `ffi` |

## Choosing between core and a package

Core is deliberately small: collections, strings, math, `Value`, and the primitives behind
each effect (`fs`, `net`, `time`, `rand`, `env`, `proc`). Everything with a format, a protocol
or a policy in it is a package. See the [core library reference](core.md).
