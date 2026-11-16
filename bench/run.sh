#!/bin/sh
# Re-run the Duck accuracy benchmark. Usage: bench/run.sh [run-name] [extra run.py args...]
#   BENCH_MODEL=claude-opus-5-5   the model for every call (claude -p --model)
#   BENCH_TOK_PY=<python>         a Python with tiktoken, for token counts
#   REBUILD=1                     rebuild the compiler and refresh bench/bin/duck + bench/spec.md first
set -e
here=$(cd "$(dirname "$0")" && pwd)
name=${1:-$(date +%Y%m%d-%H%M%S)}
[ $# -gt 0 ] && shift
if [ "${REBUILD:-0}" = 1 ]; then
  (cd "$here/.." && cargo build --release)
  cp "$here/../target/release/duck" "$here/bin/duck"
  "$here/bin/duck" spec > "$here/spec.md"
fi
python3 -I "$here/harness/verify.py"
python3 -I "$here/harness/run.py" --out "$here/runs/$name" "$@"
tok=${BENCH_TOK_PY:-/private/tmp/claude-501/-Users-nate-duck/7b475531-7181-4918-82ef-a7c47fa46b67/scratchpad/venv/bin/python}
"$tok" -I "$here/harness/report.py" "$here/runs/$name"
