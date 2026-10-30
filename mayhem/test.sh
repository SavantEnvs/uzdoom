#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS cppdap's own googletest suite (built by mayhem/build.sh) and reports CTRF.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

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

BIN="$SRC/build-tests/cppdap-unittests"
if [ ! -x "$BIN" ]; then
  echo "missing $BIN — mayhem/build.sh did not produce the test runner" >&2
  emit_ctrf "googletest" 0 1 0
  exit 1
fi

OUT="$(mktemp)"
"$BIN" >"$OUT" 2>&1
rc=$?
tail -n 15 "$OUT"

total="$(sed -nE 's/^\[==========\] ([0-9]+) tests? from .* ran\..*/\1/p' "$OUT" | tail -1)"
passed="$(sed -nE 's/^\[  PASSED  \] ([0-9]+) tests?\..*/\1/p' "$OUT" | tail -1)"
skipped="$(sed -nE 's/^\[  SKIPPED \] ([0-9]+) tests?.*/\1/p' "$OUT" | tail -1)"
failed="$(sed -nE 's/^\[  FAILED  \] ([0-9]+) tests?, listed below.*/\1/p' "$OUT" | tail -1)"
rm -f "$OUT"

# No gtest summary at all (the runner was neutered or crashed) is a failure, never a pass.
if [ -z "$total" ] || [ "${total:-0}" -eq 0 ]; then
  emit_ctrf "googletest" 0 1 0
  exit 1
fi
passed="${passed:-0}"; skipped="${skipped:-0}"; failed="${failed:-0}"
[ "$rc" -eq 0 ] || [ "$failed" -gt 0 ] || failed=1
emit_ctrf "googletest" "$passed" "$failed" "$skipped"
