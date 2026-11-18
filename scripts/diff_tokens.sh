#!/usr/bin/env bash
# Diff the token dumps of the Rust lexer and its Auk port over the corpus (see docs/pilot-report.md).
source "$(dirname "$0")/pilot_common.sh"
diff_mode tokens
