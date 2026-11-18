#!/usr/bin/env bash
# Diff the AST dumps of the Rust parser and its Auk port over the corpus (see docs/pilot-report.md).
source "$(dirname "$0")/pilot_common.sh"
diff_mode ast
