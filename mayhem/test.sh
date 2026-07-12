#!/usr/bin/env bash
#
# mayhem/test.sh — RUN guillotiere's OWN upstream test suite (already compiled by
# mayhem/build.sh via `cargo test --no-run`; this invocation reuses that cache and
# does not rebuild). Runs every cargo test in the workspace (guillotiere + cli +
# ffi, all features: unit tests in src/allocator.rs and the feature-gated
# src/recording.rs) and maps libtest's results to CTRF.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

LOG=/tmp/cargo-test.log
env -u RUSTFLAGS cargo test --workspace --all-features >"$LOG" 2>&1
rc=$?
cat "$LOG"

# Sum every libtest summary line: "test result: ok. N passed; N failed; N ignored; ..."
read -r P F S <<<"$(awk '/^test result:/ {
  for (i=1;i<=NF;i++) {
    if ($(i+1) ~ /^passed/)  p += $i
    if ($(i+1) ~ /^failed/)  f += $i
    if ($(i+1) ~ /^ignored/) s += $i
  }
} END { printf "%d %d %d", p, f, s }' "$LOG")"

# A crashed/failed-to-run suite must fail even if libtest printed no failures.
if [ "$rc" -ne 0 ] && [ "${F:-0}" -eq 0 ]; then F=1; fi
if [ "${P:-0}" -eq 0 ] && [ "${F:-0}" -eq 0 ]; then
  echo "ERROR: no libtest results parsed — suite did not run" >&2
  F=1
fi

emit_ctrf "cargo-test" "${P:-0}" "${F:-0}" "${S:-0}"
