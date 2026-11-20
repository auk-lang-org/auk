# raft: the package manager

`raft` creates projects and fetches, pins and audits their dependencies. Its unusual feature
is that **packages declare their effects**, and raft refuses to install one that needs an
effect your project hasn't allowed.

## Commands

| command | does |
|---|---|
| `raft new <name> [--lib]` | create `<name>/` with `raft.toml`, `.gitignore` and `src/main.auk` (or `src/lib.auk`) |
| `raft add <pkg>` | add the latest version of a package, then install |
| `raft add <pkg>@<version>` | add one version of a package (`http@0.1.1`), or the newest that fits a requirement (`http@^0.1`), then install |
| `raft add <pkg> --path <dir>` | add a local package by path |
| `raft add <pkg> --url <url>` | add a package bundle served at an `http://` or `https://` URL |
| `raft remove <pkg>` | drop a dependency, then install |
| `raft install` | resolve, check effects, copy packages into `.raft/`, write `raft.lock` |
| `raft list` | show the dependency tree with versions and effects |
| `raft pack [<dir>]` | write the package as one file, `<dir>/<name>.raft` (default: the project), for serving from a URL |
| `raft publish [--token <token>]` | publish this version of the package to the registry |

Every command finds the project by searching upward from the current directory.

Installing is all-or-nothing. Versions, effects and checksums are all checked before anything
is written; on any error nothing changes, and `add` and `remove` put `raft.toml` back as it
was.

## `raft.toml`

```toml
[package]
name = "weather"
version = "0.1.0"
effects = ["net", "fs"]        # the most this package and its dependencies may do

[deps]
http = "^0.1"                  # from the registry
json = "^0.1"
geo  = { path = "../geo" }     # a local package
maps = { url = "https://example.com/pkgs/maps.raft" }   # a bundle at a URL

[link]
libs = ["sqlite3"]             # C libraries, for packages that use ffi
```

- **`name`**: lowercase letters, digits and `_`. It cannot be the name of a core module
  (`fs net time rand env proc ffi str int float bool math core`).
- **`version`**: `MAJOR.MINOR.PATCH`.
- **`effects`**: any of `fs net time rand env proc gui audio_out ffi`. The default is none.
- **`[link]`**: see [Calling C](../language/c-interop.md#setup).

### Version requirements

| written | accepts |
|---|---|
| `"^1.2"` or `"1.2"` | 1.2.0 up to, not including, 2.0.0 |
| `"^0.3"` | 0.3.0 up to, not including, 0.4.0 |
| `"^0.0.3"` | exactly 0.0.3 |
| `"~1.2.3"` | 1.2.3 up to, not including, 1.3.0 |
| `"=1.2.3"` | exactly that |
| `"*"` | anything |

A build contains one version of each package.

## Effects are checked on every edge

Each package's `effects` must be a subset of the effects of the package that depends on it.
A dependency can therefore never do more than its parent allows, and your project's own list
bounds the whole tree.

```console
$ raft add http
error: http 0.1.1 needs effect `net`, but weather's raft.toml only allows []
  help: add "net" to [package] effects in raft.toml
```

Allowing an effect is a decision you make once, in one visible place, and it shows up in code
review as a one-line diff. `raft list` then answers "what can my dependencies do?" at a
glance:

```console
$ raft list
weather 0.1.0   uses net
├── http 0.1.1   uses net
│   ├── json 0.1.0
│   └── url 0.1.0
│       └── encoding 0.1.0
└── csv 0.1.0
```

The compiler enforces the same list inside each package, so a package cannot use an effect it
didn't declare. See [Effects](../language/effects.md).

## `raft.lock`

`raft install` writes the exact version, source, effects and checksum of every resolved
package:

```toml
[[package]]
name = "http"
version = "0.1.1"
source = "registry"
effects = ["net"]
checksum = "sha256:9f2c…"
```

Commit it. The checksum is a SHA-256 over the package's files, and `raft install` verifies
both the registry's (or URL's) copy and the installed copy in `.raft/` against it, failing
loudly on a mismatch, so a URL that starts serving different files is caught. A URL
dependency is recorded as `source = "url:<url>"`. Path dependencies are recorded but not
verified, since you edit them freely.

A package that would be downloaded is taken from `.raft/` instead when the lock pins it and
the installed copy still has the locked checksum, so a locked, installed project installs
offline.

Don't commit `.raft/`; `raft new` writes a `.gitignore` for it. After a fresh clone, run
`raft install`.

## The registry

By default raft installs packages from [rpm](https://rpm.auk-lang.org), the Auk package
registry. rpm keeps every published version; raft picks the newest one that fits the
requirement in `raft.toml`, or the one `raft.lock` pins. `RAFT_REGISTRY` names another
registry:

- `RAFT_REGISTRY=https://rpm.example.com`: another rpm server.
- `RAFT_REGISTRY=/path/to/pkgs`: a directory, one folder per package.
- `RAFT_REGISTRY=https://example.com/pkgs`: any static web server holding one
  `<name>.raft` bundle per package (`https://example.com/pkgs/json.raft`).

A directory or static server has one version per package.

### Choosing a version

`raft add http` takes the newest version and writes `http = "^0.1"`: any later `0.1.x` fits.
To get one version exactly, name it; to choose the range yourself, give a requirement:

```console
$ raft add http@0.1.1        # writes http = "=0.1.1"
$ raft add http@~0.1.1       # writes http = "~0.1.1": the newest 0.1.x from 0.1.1 up
```

`raft.lock` keeps the version it has for as long as the requirement in `raft.toml` takes it,
so installs don't change under you. To move to a newer version, name it: `raft add http@0.1.2`.

To use a package of your own, depend on it by path (`raft add geo --path ../geo`) or by URL
(`raft add geo --url https://example.com/geo.raft`).

## Serving packages from a URL

`raft pack` writes a package as one file, `<name>.raft`, holding `raft.toml`, `README.md` and
`src/`. Put it on any web server (a static host, a release page, an object store):

```console
$ cd geo && raft pack ../site/pkgs
packed geo 0.2.0 -> ../site/pkgs/geo.raft
  sha256:4be1…
```

The printed hash is the SHA-256 of the file, and it is exactly the checksum `raft.lock` will
record for the package. raft follows redirects, verifies TLS certificates (there is no way to
turn that off), and only unpacks the files a bundle may hold, so a bundle cannot write outside
`.raft/<name>/`.

## Writing a package

```console
$ raft new geo --lib
created geo/ (library)
```

- `src/lib.auk` is the root module. Its `pub` items are the package's API, reached as
  `geo.<item>`; other files are submodules (`src/shapes.auk` is `geo.shapes`).
- Declare the smallest `effects` list you can. A package with none can be added to any
  project. If only one function needs the clock, consider taking the time as an argument
  instead, as `datetime` and `uuid.v7` do.
- Return typed errors (`T!YourErr`) so callers can react to them.
- Put `test` blocks next to the code and a `README.md` at the top with a short example.

### Publishing

Sign in at [rpm.auk-lang.org](https://rpm.auk-lang.org), make a token on your account page,
and run `raft publish` in the package:

```console
$ RPM_TOKEN=rpm_… raft publish
published geo 0.1.0 -> https://rpm.auk-lang.org/packages/geo/0.1.0
  sha256:9a91ccc4…
```

It sends `raft.toml`, `README.md` and everything under `src/`. A published version is
permanent: it can be yanked on the site, never changed, so to publish a change, raise
`version` in `raft.toml` first. The first to publish a name owns it. Every dependency must
already be in the registry, and path dependencies can't be published. `--token <token>` works
in place of `RPM_TOKEN`, and `RAFT_REGISTRY` publishes to another rpm server.

The [package catalog](../reference/packages.md) lists the official packages.
