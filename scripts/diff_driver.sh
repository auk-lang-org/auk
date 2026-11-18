#!/usr/bin/env bash
# The self-hosted driver (docs/self-host-plan.md, Phase 4): the Auk compiler's `auk` commands
# against the Rust `auk`'s on what golden.sh doesn't cover: usage errors, `explain`, `spec`,
# missing files and programs that don't build, `test` filters and flat directories, `build -o`
# (the executables' output), imprint failures, and the leak checker (`AUK_LEAK_CHECK=1`; the
# port runs programs in its own process, where its own objects are live). Each case compares
# stdout, stderr and the exit code.
# Usage: scripts/diff_driver.sh [<port binary>]   (default: build target/pilot/compiler)
source "$(dirname "$0")/pilot_common.sh"
if [ -n "${1:-}" ]; then
  PORT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  cargo build --release -q
else
  build_both
fi
out="$ROOT/target/pilot/driver"
rm -rf "$out"
mkdir -p "$out/empty" "$out/flat"
cp tests/fixtures/bitwise.auk tests/fixtures/sha256.auk examples/hello.auk "$out/flat/"
printf 'test "broken" {\n  assert 1 == "x"\n}\n' > "$out/flat/broken.auk"
n=0 bad=0
# case NAME ENV CMD...: run `auk CMD...` and `compiler CMD...` with the environment ENV
# (`-` for none); `@` in an argument stands for this run's scratch directory
case_() {
  local name="$1" envs="$2" side bin
  shift 2
  n=$((n + 1))
  for side in rust auk; do
    bin="$AUK"
    [ "$side" = auk ] && bin="$PORT"
    local dir="$out/$name.$side.d" args=() a
    mkdir -p "$dir"
    for a in "$@"; do args+=("${a//@/$dir}"); done
    # shellcheck disable=SC2086  # ENV is words
    run_cmd "$out/$name.$side" env ${envs/#-/} "$bin" ${args[@]+"${args[@]}"}
    sed -i.bak -e "s|$dir|<dir>|g" "$out/$name.$side" && rm -f "$out/$name.$side.bak"
    if [ -f "$dir/exe" ]; then
      run_cmd "$out/$name.$side.exe" "$dir/exe"
      cat "$out/$name.$side.exe" >> "$out/$name.$side"
    fi
  done
  if ! cmp -s "$out/$name.rust" "$out/$name.auk"; then
    bad=$((bad + 1))
    echo "DIFF $name: $* (diff $out/$name.rust $out/$name.auk)"
  fi
}
case_ none -
case_ help - help
case_ unknown - nonsense
case_ check_usage - check
case_ check_extra - check a b c
case_ check_json_first - check --json examples/hello.auk
case_ check_missing - check no_such.auk
case_ run_usage - run
case_ build_usage - build
case_ build_bad_o - build examples/hello.auk -x out
case_ ir_usage - ir
case_ test_usage - test a b c
case_ holes_usage - holes
case_ fmt_usage - fmt
case_ explain_list - explain
case_ explain_code - explain 400
case_ explain_near - explain E0206
case_ explain_word - explain semicolon
case_ explain_usage - explain E0001 E0002
case_ spec - spec
case_ trace_empty - run --trace= examples/hello.auk
case_ trace_limit - run --trace-limit 0 examples/hello.auk
case_ trace_core - run --trace-core examples/hello.auk
case_ ir_llvm_dump - ir --llvm --dump examples/hello.auk
case_ run_missing - run no_such.auk
case_ run_type_error - run tests/errors/mixed_numbers.auk
case_ run_no_main - run tests/fixtures/bitwise.auk
case_ run_args - run examples/csv_stats.auk tests/fixtures/stats.csv price
case_ run_flag_args - run examples/wc.auk --trace-core
case_ run_traced - run --trace=json examples/fib.auk
case_ run_trace_file - run --trace=@/t.jsonl examples/hello.auk
case_ run_O - run -O examples/fib.auk
case_ build_missing - build no_such.auk
case_ build_type_error - build tests/errors/semicolon.auk
case_ build_exe - build examples/fib.auk -o @/exe
case_ build_exe_g - build -g examples/hello.auk -o @/exe
case_ test_missing - test no_such.auk
case_ test_not_project - test "$out/empty"
case_ test_no_tests - test examples/hello.auk
case_ test_filter - test tests/fixtures/collections.auk map
case_ test_filter_none - test tests/fixtures/collections.auk zzz_nothing
case_ test_flat - test "$out/flat"
case_ test_flat_filter - test "$out/flat" sha
case_ test_trace - test --trace=json tests/fixtures/bitwise.auk
case_ test_trace_dir - test --trace=@/tr tests/fixtures/bitwise.auk
case_ imprint_ok - run tests/checker/check2_052.auk
case_ imprint_panic - run tests/checker/run_029.auk
case_ imprint_panic_build - build tests/checker/run_028.auk -o @/exe
case_ leak_run AUK_LEAK_CHECK=1 run examples/tour.auk
case_ leak_run_stdin AUK_LEAK_CHECK=1 run examples/wc.auk tests/fixtures/words.txt
case_ leak_test AUK_LEAK_CHECK=1 test examples/bank.auk
case_ leak_pkg AUK_LEAK_CHECK=1 test packages/json
case_ leak_flat AUK_LEAK_CHECK=1 test "$out/flat"
echo "driver: $n cases, $bad differ"
[ "$bad" -eq 0 ]
