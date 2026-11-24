#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer tests for the LFortran CLI built by mayhem/build.sh.
#
# Each line of mayhem/golden/cases.txt is `name|lfortran options|input file`. The compiler is run on
# the input and its output (stdout + diagnostics) and exit status are diffed against mayhem/golden/<name>.out: C code
# generation, the Fortran formatter, fixed-form + implicit typing, the C preprocessor, the Fortran
# backend, the GFortran .mod reader and --continue-compilation diagnostics. A neutered compiler
# (no output) fails every case.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
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

LF="$SRC/mayhem/build-fuzz/src/bin/lfortran"
if [ ! -x "$LF" ]; then
  echo "missing $LF — run mayhem/build.sh first" >&2
  emit_ctrf lfortran-golden 0 1
  exit 1
fi
out=$(mktemp)
trap 'rm -f "$out"' EXIT
passed=0 failed=0
while IFS='|' read -r name opts input; do
  [ -n "$name" ] || continue
  # shellcheck disable=SC2086
  { "$LF" $opts "$input" 2>&1; echo "exit=$?"; } > "$out"
  if diff -q "$out" "mayhem/golden/$name.out" >/dev/null; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL $name: lfortran $opts $input"
    diff "$out" "mayhem/golden/$name.out" | head -10
  fi
done < mayhem/golden/cases.txt
emit_ctrf lfortran-golden "$passed" "$failed"
