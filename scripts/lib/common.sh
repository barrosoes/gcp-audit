#!/usr/bin/env bash

set -euo pipefail

timestamp_rfc3339() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_level_to_num() {
  case "${1:-INFO}" in
    DEBUG) echo 10 ;;
    INFO) echo 20 ;;
    WARN) echo 30 ;;
    ERROR) echo 40 ;;
    *) echo 20 ;;
  esac
}

log_should_print() {
  local msg_level="${1:-INFO}"
  local cur_level="${LOG_LEVEL:-INFO}"
  [[ "$(log_level_to_num "$msg_level")" -ge "$(log_level_to_num "$cur_level")" ]]
}

log_line() {
  local level="$1"; shift
  local msg="$*"
  local line
  line="$(timestamp_rfc3339) [$level] $msg"
  if log_should_print "$level"; then
    echo "$line" 1>&2
  fi
  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$line" >>"$LOG_FILE"
  fi
}

log_debug() { log_line DEBUG "$@"; }
log_info()  { log_line INFO  "$@"; }
log_warn()  { log_line WARN  "$@"; }
log_error() { log_line ERROR "$@"; }

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Missing required command: $cmd"
    return 1
  fi
}

ensure_dir() {
  local dir="$1"
  mkdir -p "$dir"
}

csv_to_lines() {
  # Converts comma-separated list into one-per-line, stripping spaces.
  local s="${1:-}"
  if [[ -z "$s" ]]; then
    return 0
  fi
  echo "$s" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
}

list_contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

is_allowed_by_filters() {
  # Usage: is_allowed_by_filters "<id>" "<include_csv>" "<exclude_csv>"
  local id="$1"
  local include_csv="${2:-}"
  local exclude_csv="${3:-}"

  local includes=()
  local excludes=()

  while IFS= read -r line; do includes+=("$line"); done < <(csv_to_lines "$include_csv" || true)
  while IFS= read -r line; do excludes+=("$line"); done < <(csv_to_lines "$exclude_csv" || true)

  if ((${#includes[@]} > 0)); then
    if ! list_contains "$id" "${includes[@]}"; then
      return 1
    fi
  fi

  if ((${#excludes[@]} > 0)); then
    if list_contains "$id" "${excludes[@]}"; then
      return 1
    fi
  fi

  return 0
}

sleep_backoff_seconds() {
  local attempt="$1"
  local base="${2:-1}"
  local max="${3:-30}"
  local s=$(( base * (2 ** (attempt - 1)) ))
  if (( s > max )); then s="$max"; fi
  echo "$s"
}

run_with_retries() {
  # Usage: run_with_retries <max_attempts> <cmd...>
  local max_attempts="$1"; shift
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    local ec=$?
    if (( attempt >= max_attempts )); then
      return "$ec"
    fi
    local sleep_s
    sleep_s="$(sleep_backoff_seconds "$attempt" 1 20)"
    log_warn "Command failed (attempt $attempt/$max_attempts, exit=$ec). Retrying in ${sleep_s}s: $*"
    sleep "$sleep_s"
    attempt=$((attempt + 1))
  done
}

write_json_pretty() {
  # Pretty-print JSON to file if python3 exists; otherwise write raw.
  # Usage: write_json_pretty <output_path> <raw_json_string>
  local out="$1"
  local raw="$2"
  ensure_dir "$(dirname "$out")"
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' "$raw" "$out"
import json, sys
raw = sys.argv[1]
out = sys.argv[2]
obj = json.loads(raw) if raw.strip() else None
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY
  else
    printf '%s\n' "$raw" >"$out"
  fi
}

append_error_jsonl() {
  # Usage: append_error_jsonl <errors_jsonl_path> <scope_type> <scope_id> <capability> <message>
  local path="$1"
  local scope_type="$2"
  local scope_id="$3"
  local capability="$4"
  local message="$5"

  ensure_dir "$(dirname "$path")"
  local ts
  ts="$(timestamp_rfc3339)"
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' "$ts" "$scope_type" "$scope_id" "$capability" "$message" >>"$path"
import json, sys
ts, scope_type, scope_id, capability, message = sys.argv[1:]
print(json.dumps({
  "timestamp": ts,
  "scopeType": scope_type,
  "scopeId": scope_id,
  "capability": capability,
  "message": message,
}, ensure_ascii=False))
PY
  else
    printf '{"timestamp":"%s","scopeType":"%s","scopeId":"%s","capability":"%s","message":"%s"}\n' \
      "$ts" "$scope_type" "$scope_id" "$capability" "$(echo "$message" | tr -d '\n' | sed 's/"/\\"/g')" >>"$path"
  fi
}

