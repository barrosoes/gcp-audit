#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$ROOT_DIR/tests/tmp"
TEST_OUT="$ROOT_DIR/tests/out"

export PATH="$ROOT_DIR/tests/bin:$PATH"
export GCLOUD_MOCK_TMP_DIR="$TEST_TMP"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" 1>&2; exit 1; }

assert_file_exists() {
  local p="$1"
  [[ -f "$p" ]] || fail "Expected file to exist: $p"
}

assert_file_not_exists() {
  local p="$1"
  [[ ! -f "$p" ]] || fail "Expected file to NOT exist: $p"
}

assert_eq() {
  local a="$1"
  local b="$2"
  [[ "$a" == "$b" ]] || fail "Expected '$a' == '$b'"
}

count_calls() {
  local log="$1"
  if [[ ! -f "$log" ]]; then
    echo 0
    return 0
  fi
  wc -l <"$log" | tr -d ' '
}

reset_tmp() {
  rm -rf "$TEST_TMP" "$TEST_OUT"
  mkdir -p "$TEST_TMP" "$TEST_OUT"
}

run_audit() {
  local extra_args=("$@")
  "$ROOT_DIR/scripts/gcp-org-audit.sh" --org-id 123 --out-dir "$TEST_OUT" --run-id test-run "${extra_args[@]}"
}

test_dry_run_no_gcloud_calls() {
  reset_tmp

  # If gcloud is invoked, fail fast.
  cat >"$ROOT_DIR/tests/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${GCLOUD_MOCK_TMP_DIR:-$ROOT_DIR/tests/tmp}"
mkdir -p "$TMP_DIR"
echo "gcloud $*" >>"$TMP_DIR/gcloud_calls.log"
exit 99
EOF
  chmod +x "$ROOT_DIR/tests/bin/gcloud"

  if run_audit --dry-run >/dev/null 2>&1; then
    :
  else
    fail "dry-run should succeed even without calling gcloud"
  fi

  local calls
  calls="$(count_calls "$TEST_TMP/gcloud_calls.log")"
  assert_eq "$calls" "0"
  pass "dry-run makes zero gcloud calls"
}

restore_full_mock() {
  # Recreate the full mock (in case previous test overwrote it)
  cp "$ROOT_DIR/tests/bin/gcloud.full" "$ROOT_DIR/tests/bin/gcloud"
  chmod +x "$ROOT_DIR/tests/bin/gcloud"
}

test_idempotency_without_force() {
  reset_tmp

  restore_full_mock

  run_audit >/dev/null
  local first_calls
  first_calls="$(count_calls "$TEST_TMP/gcloud_calls.log")"
  [[ "$first_calls" -gt 0 ]] || fail "expected gcloud calls in first run"

  # Second run should do fewer calls due to skip-existing (no --force)
  run_audit >/dev/null
  local second_calls
  second_calls="$(count_calls "$TEST_TMP/gcloud_calls.log")"

  # calls log is cumulative; compute delta by capturing size before second run
  # We'll do a more robust delta approach:
  reset_tmp
  restore_full_mock
  run_audit >/dev/null
  first_calls="$(count_calls "$TEST_TMP/gcloud_calls.log")"
  local before_second="$first_calls"
  run_audit >/dev/null
  local total_after_second
  total_after_second="$(count_calls "$TEST_TMP/gcloud_calls.log")"
  local delta_second=$(( total_after_second - before_second ))

  [[ "$delta_second" -lt "$first_calls" ]] || fail "expected fewer gcloud calls on second run (delta=$delta_second first=$first_calls)"
  pass "idempotency: second run makes fewer gcloud calls (without --force)"
}

test_enabled_apis_aggregations_exist() {
  reset_tmp
  restore_full_mock

  run_audit >/dev/null

  local run_root="$TEST_OUT/test-run/org/123"
  assert_file_exists "$run_root/org/123/enabled-apis/enabled_apis_aggregated.json"
  assert_file_exists "$run_root/org/123/enabled-apis/enabled_apis_by_project.json"

  # Validate both files are valid JSON and contain expected keys.
  python3 - <<'PY' "$run_root/org/123/enabled-apis/enabled_apis_aggregated.json" "$run_root/org/123/enabled-apis/enabled_apis_by_project.json"
import json, sys
p1, p2 = sys.argv[1], sys.argv[2]
a = json.load(open(p1,'r',encoding='utf-8'))
b = json.load(open(p2,'r',encoding='utf-8'))
assert isinstance(a, list) and a and "api" in a[0] and "projects" in a[0]
assert isinstance(b, list) and b and "projectId" in b[0] and "apis" in b[0]
PY

  pass "enabled APIs aggregations (by api + by project) are generated"
}

main() {
  # Save the full mock as a backup for tests that overwrite it.
  cp "$ROOT_DIR/tests/bin/gcloud" "$ROOT_DIR/tests/bin/gcloud.full"

  test_dry_run_no_gcloud_calls
  test_idempotency_without_force
  test_enabled_apis_aggregations_exist

  restore_full_mock
  echo "All tests passed."
}

main "$@"

