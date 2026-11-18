#!/usr/bin/env bash
# Diff `auk holes <file>` and `auk holes <file> --json` (the brief of every `??` hole, the
# diagnostics on stderr, the exit code), Rust compiler against its Auk port, over the corpus.
source "$(dirname "$0")/pilot_common.sh"
diff_cmd holes holes && diff_cmd holes_json holes --json
