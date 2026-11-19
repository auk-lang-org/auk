#!/bin/sh
# Installs the latest Auk release (auk and raft) for this machine from GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/auk-lang-org/auk/main/install.sh | sh
#
# macOS arm64, Linux arm64 and Linux x86-64. The binaries need LLVM 23 (its shared library):
# `brew install llvm@23` on macOS; on Debian/Ubuntu `libllvm23` (apt.llvm.org), and a system
# linker (`lld-23` or binutils) for `auk build`.
#
# Environment:
#   AUK_VERSION   a release to install instead of the latest, e.g. 1.0.0
#   AUK_INSTALL   where bin/ goes (default ~/.auk: auk and raft land in ~/.auk/bin)
set -eu

repo=auk-lang-org/auk
prefix=${AUK_INSTALL:-$HOME/.auk}

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# fetch <url> <file>
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
  final_url() { curl -fsSLI -o /dev/null -w '%{url_effective}' "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
  final_url() { wget -q -S --spider "$1" 2>&1 | sed -n 's/^ *[Ll]ocation: *//p' | tail -n 1 | tr -d '\r'; }
else
  die "needs curl or wget"
fi

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  *) die "no release for $(uname -s): build from source (./build.sh --install)" ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) arch=arm64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) die "no release for $(uname -m): build from source (./build.sh --install)" ;;
esac
if [ "$os-$arch" = macos-x86_64 ]; then
  die "no release for Intel Macs yet: build from source (./build.sh --install)"
fi
platform=$os-$arch

# The version: AUK_VERSION, else the tag the latest release redirects to (…/tag/v1.0.0).
version=${AUK_VERSION:-}
if [ -z "$version" ]; then
  tag=$(final_url "https://github.com/$repo/releases/latest") || die "can't reach github.com"
  version=${tag##*/}
fi
version=${version#v}
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "couldn't find the latest release (got \`$version\`); set AUK_VERSION" ;;
esac

name=auk-$version-$platform
base=https://github.com/$repo/releases/download/v$version
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Downloading Auk $version ($platform)"
fetch "$base/$name.tar.gz" "$tmp/$name.tar.gz" || die "no $name.tar.gz in release v$version"

# Check it against the release's SHA256SUMS (when it has one and there's a tool to check with).
if fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" 2>/dev/null; then
  want=$(awk -v f="$name.tar.gz" '$2 == f { print $1 }' "$tmp/SHA256SUMS")
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$tmp/$name.tar.gz" | awk '{ print $1 }')
  elif command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 "$tmp/$name.tar.gz" | awk '{ print $1 }')
  else
    got=$want
  fi
  [ -n "$want" ] && [ "$got" = "$want" ] || die "checksum mismatch for $name.tar.gz"
fi

tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
mkdir -p "$prefix/bin"
for b in auk raft; do
  # Through a temporary name, so a running auk is never overwritten in place.
  cp "$tmp/$name/bin/$b" "$prefix/bin/.$b.new"
  chmod 755 "$prefix/bin/.$b.new"
  mv -f "$prefix/bin/.$b.new" "$prefix/bin/$b"
done
say "Installed auk and raft $version in $prefix/bin"

# LLVM 23, which auk links against.
if [ "$os" = macos ]; then
  if [ ! -e /opt/homebrew/opt/llvm/lib/libLLVM.23.1.dylib ]; then
    say ""
    say "auk needs LLVM 23 from Homebrew: brew install llvm@23"
  fi
elif ! "$prefix/bin/auk" --version >/dev/null 2>&1; then
  say ""
  say "auk can't start; it needs LLVM 23's shared library (libLLVM.so.23.1):"
  say "  Debian/Ubuntu: see https://apt.llvm.org, then apt install libllvm23 lld-23"
fi

case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *)
    say ""
    say "Add it to your PATH (e.g. in ~/.zshrc or ~/.bashrc):"
    say "  export PATH=\"$prefix/bin:\$PATH\""
    ;;
esac
