#!/usr/bin/env bash
#
# mayhem/test.sh — RUN ReadStat's own functional test binaries (already built by mayhem/build.sh's
# `make check_PROGRAMS` in the NORMAL-flags tree). Each of the four is a real assertion-based
# functional test (reads fixtures under resources/, checks parsed values/behavior) — a PATCH that
# neuters the library to a no-op fails these, not just "didn't crash". One CTRF "test" per binary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

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

TEST_BUILD_DIR="$(cat /mayhem/.mayhem-test-build-dir 2>/dev/null || echo "${TEST_BUILD_DIR:-${HOME:-/tmp}/mayhem-test-build}")"
cd "$TEST_BUILD_DIR" || { echo "missing $TEST_BUILD_DIR — run mayhem/build.sh first" >&2; exit 2; }

TEST_BINS="test_readstat test_dta_days test_sav_date test_double_decimals"
passed=0 failed=0
for t in $TEST_BINS; do
  [ -x "./$t" ] || { echo "missing ./$t in $TEST_BUILD_DIR — run mayhem/build.sh first" >&2; exit 2; }
  echo "== running $t =="
  out="$(./"$t" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  case "$t" in
    test_readstat|test_dta_days)
      # Silent-on-success by design (only prints on a parse/assertion error) — exit code is their
      # only signal.
      ok=$rc
      ;;
    *)
      # test_sav_date / test_double_decimals are verbose on success (an "... OK" line per
      # assertion) — require that real assertion output, not just a clean exit, so a
      # neutered/no-op binary (exits 0 before running any code, hence no output at all) is caught
      # rather than counted as a pass.
      if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "OK"; then ok=0; else ok=1; fi
      ;;
  esac
  if [ "$ok" -eq 0 ]; then
    echo "-- $t: PASS"
    passed=$((passed + 1))
  else
    echo "-- $t: FAIL (exit $rc)"
    failed=$((failed + 1))
  fi
done

emit_ctrf "readstat-check_PROGRAMS" "$passed" "$failed"
