#!/usr/bin/env bash
# Diff `auk check <file>` (the rendered diagnostics on stderr: source excerpt, carets, notes,
# fix-its, help) and its exit code, Rust compiler against its Auk port, over the corpus.
source "$(dirname "$0")/pilot_common.sh"
diff_cmd check_text check
