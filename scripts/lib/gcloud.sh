#!/usr/bin/env bash

set -euo pipefail

gcloud_json() {
  # Usage: gcloud_json <args...>
  # Writes JSON to stdout. Caller handles errors.
  gcloud "$@" --format=json
}

gcloud_value() {
  # Usage: gcloud_value <args...>
  # Writes value to stdout. Caller handles errors.
  gcloud "$@" --format="value()"
}

gcloud_try_json() {
  # Usage: gcloud_try_json <max_attempts> <args...>
  local max_attempts="$1"; shift
  run_with_retries "$max_attempts" gcloud_json "$@"
}

