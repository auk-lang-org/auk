#!/usr/bin/env bash
# Diff `auk check <file> --json` (every diagnostic: the type checker, patterns.rs and effects.rs,
# warnings included) of the Rust compiler and its Auk port over the corpus: the report, stderr
# and the exit code (see docs/self-host-plan.md, Phase 3).
source "$(dirname "$0")/pilot_common.sh"
diff_cmd check check --json
