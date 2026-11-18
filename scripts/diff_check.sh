#!/usr/bin/env bash
# Diff the type checker's diagnostics (`auk dump check`: the `auk check --json` report of
# check.rs, before patterns.rs and effects.rs) of the Rust compiler and its Auk port over the
# corpus (see docs/self-host-plan.md, Phase 3).
source "$(dirname "$0")/pilot_common.sh"
diff_mode check
