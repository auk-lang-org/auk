#!/usr/bin/env bash
# Diff the module trees and path resolutions (`auk dump resolve`) of the Rust compiler and its
# Auk port over the corpus (see docs/self-host-plan.md, Phase 3).
source "$(dirname "$0")/pilot_common.sh"
diff_mode resolve
