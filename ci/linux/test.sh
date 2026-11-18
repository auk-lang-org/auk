#!/bin/sh
# Builds and tests the Auk compiler on Linux in Docker (Debian trixie, LLVM 23; see Dockerfile).
#
#   ci/linux/test.sh                    # cargo build --release && cargo test --release
#   ci/linux/test.sh --test run         # arguments go to `cargo test --release`
#   ci/linux/test.sh shell              # a shell in the container, the repo at /src
#
# The repo is mounted at /src. The target directory and cargo's registry live in Docker volumes
# (auk-linux-target, auk-linux-cargo), so reruns only rebuild what changed and the host's
# target/ (macOS objects) is left alone. `docker volume rm auk-linux-target` starts clean.
# AUK_LINUX_IMAGE names the image (default auk-linux); AUK_LINUX_PLATFORM picks its platform
# (default: the host's, e.g. linux/amd64 to test x86-64 under emulation).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
image=${AUK_LINUX_IMAGE:-auk-linux}
platform=${AUK_LINUX_PLATFORM:+--platform=$AUK_LINUX_PLATFORM}

docker build ${platform:-} -q -t "$image" "$here" >/dev/null

tty=
[ -t 0 ] && [ -t 1 ] && tty=-t
run() {
    docker run --rm -i $tty ${platform:-} \
        -v "$root:/src" \
        -v auk-linux-target:/target \
        -v auk-linux-cargo:/usr/local/cargo/registry \
        -e CARGO_TARGET_DIR=/target \
        -e CARGO_TERM_COLOR=${CARGO_TERM_COLOR:-auto} \
        -w /src "$image" "$@"
}

if [ "${1:-}" = shell ]; then
    run bash
else
    run sh -c 'cargo build --release && cargo test --release "$@"' sh "$@"
fi
