#!/bin/sh
# Builds and tests Auk on Linux in Docker (Debian trixie, LLVM 23; see Dockerfile).
#
#   ci/linux/test.sh                    # ./build.sh --check --test, from the linux seed
#   ci/linux/test.sh -- <args>          # other build.sh arguments (e.g. -- --seed /path/auk)
#   ci/linux/test.sh shell              # a shell in the container, the repo at /src
#
# The repo is mounted read-only at /src and cloned to /work in the container (committed files
# only: commit first), so the host's target/ (macOS objects) is left alone. AUK_LINUX_IMAGE names
# the image (default auk-linux); AUK_LINUX_PLATFORM picks its platform (default: the host's,
# e.g. linux/amd64 for x86-64 under emulation; there is no amd64 seed yet).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
image=${AUK_LINUX_IMAGE:-auk-linux}
platform=${AUK_LINUX_PLATFORM:+--platform=$AUK_LINUX_PLATFORM}

docker build ${platform:-} -q -t "$image" "$here" >/dev/null

tty=
[ -t 0 ] && [ -t 1 ] && tty=-t
run() {
    docker run --rm -i $tty ${platform:-} -v "$root:/src:ro" -w /src "$image" "$@"
}

if [ "${1:-}" = shell ]; then
    run bash
else
    [ "${1:-}" = -- ] && shift
    run bash -c 'git -c safe.directory="*" clone -q /src /work && cd /work && ./build.sh --check --test "$@"' sh "$@"
fi
