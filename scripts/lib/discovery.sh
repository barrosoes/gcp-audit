#!/usr/bin/env bash

set -euo pipefail

_py_ids_from_gcloud_list() {
  # Reads JSON array from stdin and prints IDs one per line.
  # For folders: expects `name` like "folders/123" or `folderId`.
  # For projects: expects `projectId`.
  python3 -c 'import json,sys,re
data=json.load(sys.stdin)
for item in (data or []):
  if not isinstance(item, dict):
    continue
  pid=item.get("projectId")
  if pid:
    print(pid); continue
  name=item.get("name") or ""
  m=re.match(r"folders/(\\d+)$", name)
  if m:
    print(m.group(1)); continue
  fid=item.get("folderId")
  if fid:
    print(fid)
'
}

discover_folders_recursive() {
  # Writes combined folder list JSON to $1 and folder IDs to stdout.
  # Usage: discover_folders_recursive <out_json> <org_id>
  local out_json="$1"
  local org_id="$2"

  require_cmd gcloud
  require_cmd python3

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  local seen_file="$tmp_dir/seen.txt"
  : >"$seen_file"

  local -a queue=()
  queue+=("organization:${org_id}")

  local combined="$tmp_dir/combined.jsonl"
  : >"$combined"

  local qi=0
  while (( qi < ${#queue[@]} )); do
    local parent="${queue[$qi]}"
    qi=$((qi + 1))

    local ptype="${parent%%:*}"
    local pid="${parent#*:}"

    local raw
    if [[ "$ptype" == "organization" ]]; then
      raw="$(gcloud resource-manager folders list --organization="$pid" --format=json 2>/dev/null || true)"
    else
      raw="$(gcloud resource-manager folders list --folder="$pid" --format=json 2>/dev/null || true)"
    fi

    if [[ -z "$raw" || "$raw" == "[]" ]]; then
      continue
    fi

    printf '%s\n' "$raw" | python3 -c 'import json,sys
data=json.load(sys.stdin)
for item in (data or []):
  print(json.dumps(item, ensure_ascii=False))
' >>"$combined"

    while IFS= read -r fid; do
      [[ -z "$fid" ]] && continue
      if ! grep -qxF "$fid" "$seen_file"; then
        echo "$fid" >>"$seen_file"
        queue+=("folder:${fid}")
      fi
    done < <(printf '%s\n' "$raw" | _py_ids_from_gcloud_list || true)
  done

  python3 - <<'PY' "$combined" "$out_json"
import json, sys
combined_path, out_path = sys.argv[1], sys.argv[2]
items = []
with open(combined_path, "r", encoding="utf-8") as f:
    for line in f:
        line=line.strip()
        if not line: 
            continue
        items.append(json.loads(line))
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(items, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY

  sort -u "$seen_file"
}

discover_projects_for_parent() {
  # Writes project list JSON to $1 and project IDs to stdout.
  # Usage: discover_projects_for_parent <out_json> <parent_type> <parent_id>
  local out_json="$1"
  local parent_type="$2" # organization|folder
  local parent_id="$3"

  require_cmd gcloud
  require_cmd python3

  local filter
  if [[ "$parent_type" == "organization" ]]; then
    filter="parent.type=organization parent.id=${parent_id}"
  else
    filter="parent.type=folder parent.id=${parent_id}"
  fi

  local raw
  raw="$(gcloud projects list --filter="$filter" --format=json 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then raw="[]"; fi
  write_json_pretty "$out_json" "$raw"
  printf '%s\n' "$raw" | _py_ids_from_gcloud_list || true
}

