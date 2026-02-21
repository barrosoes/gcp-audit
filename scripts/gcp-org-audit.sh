#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/gcloud.sh
source "$SCRIPT_DIR/lib/gcloud.sh"
# shellcheck source=lib/discovery.sh
source "$SCRIPT_DIR/lib/discovery.sh"
# shellcheck source=lib/collectors.sh
source "$SCRIPT_DIR/lib/collectors.sh"

usage() {
  cat <<'EOF'
gcp-org-audit.sh - Enterprise-ish GCP Organization audit (Cloud Shell)

Required:
  --org-id <ORG_ID>            Organization numeric ID (e.g., 123456789012)

Common options:
  --out-dir <dir>              Output root directory (default: out)
  --run-id <id>                Run identifier (default: UTC timestamp)
  --log-level <lvl>            DEBUG|INFO|WARN|ERROR (default: INFO)
  --dry-run                    Print what would be executed; do not call gcloud
  --force                      Overwrite existing output files
  --parallelism <n>            Per-project parallelism (default: 1)

Discovery filters (comma-separated IDs):
  --include-folders <csv>
  --exclude-folders <csv>
  --include-projects <csv>
  --exclude-projects <csv>

Asset inventory:
  --resource-types <csv>       CAI asset types filter (comma-separated)

Examples:
  ./scripts/gcp-org-audit.sh --org-id 123456789012
  ./scripts/gcp-org-audit.sh --org-id 123456789012 --parallelism 4
  ./scripts/gcp-org-audit.sh --org-id 123456789012 --include-projects p1,p2

EOF
}

die_usage() {
  log_error "$@"
  usage 1>&2
  exit 2
}

default_run_id() {
  date -u +"%Y%m%dT%H%M%SZ"
}

parse_args() {
  ORG_ID="${ORG_ID:-}"
  OUT_DIR="${OUT_DIR:-out}"
  RUN_ID="${RUN_ID:-$(default_run_id)}"
  DRY_RUN="${DRY_RUN:-0}"
  FORCE="${FORCE:-0}"
  PARALLELISM="${PARALLELISM:-1}"
  LOG_LEVEL="${LOG_LEVEL:-INFO}"

  INCLUDE_FOLDERS="${INCLUDE_FOLDERS:-}"
  EXCLUDE_FOLDERS="${EXCLUDE_FOLDERS:-}"
  INCLUDE_PROJECTS="${INCLUDE_PROJECTS:-}"
  EXCLUDE_PROJECTS="${EXCLUDE_PROJECTS:-}"
  RESOURCE_TYPES="${RESOURCE_TYPES:-}"

  MODE="run"
  PROJECT_ID=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --org-id) ORG_ID="${2:-}"; shift 2 ;;
      --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
      --run-id) RUN_ID="${2:-}"; shift 2 ;;
      --log-level) LOG_LEVEL="${2:-}"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --force) FORCE=1; shift ;;
      --parallelism) PARALLELISM="${2:-}"; shift 2 ;;
      --include-folders) INCLUDE_FOLDERS="${2:-}"; shift 2 ;;
      --exclude-folders) EXCLUDE_FOLDERS="${2:-}"; shift 2 ;;
      --include-projects) INCLUDE_PROJECTS="${2:-}"; shift 2 ;;
      --exclude-projects) EXCLUDE_PROJECTS="${2:-}"; shift 2 ;;
      --resource-types) RESOURCE_TYPES="${2:-}"; shift 2 ;;

      # Internal mode for parallel per-project collection
      --mode) MODE="${2:-}"; shift 2 ;;
      --project-id) PROJECT_ID="${2:-}"; shift 2 ;;

      -h|--help) usage; exit 0 ;;
      *) die_usage "Unknown argument: $1" ;;
    esac
  done

  if [[ "$MODE" == "run" && -z "$ORG_ID" ]]; then
    die_usage "--org-id is required"
  fi
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

preflight_gcloud() {
  require_cmd gcloud
  require_cmd python3

  local account
  account="$(gcloud config get-value account 2>/dev/null || true)"
  if [[ -z "$account" || "$account" == "(unset)" ]]; then
    die_usage "No active gcloud account configured. Run: gcloud auth login"
  fi
  log_info "Using gcloud account: $account"

  local version
  version="$(gcloud --version 2>/dev/null | head -n 1 || true)"
  log_info "$version"
}

validate_required_apis_best_effort() {
  # Best-effort check: verify core APIs are enabled on at least one audited project.
  # Usage: validate_required_apis_best_effort <run_root> <sample_project_id>
  local run_root="$1"
  local sample_project_id="${2:-}"
  local out_dir="$run_root/preflight"
  ensure_dir "$out_dir"

  local required=(
    "cloudresourcemanager.googleapis.com"
    "cloudasset.googleapis.com"
    "serviceusage.googleapis.com"
    "orgpolicy.googleapis.com"
    "cloudbilling.googleapis.com"
  )

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would validate required APIs (best-effort)"
    return 0
  fi

  if [[ -z "$sample_project_id" ]]; then
    log_warn "No sample project available for API enablement checks."
    return 0
  fi

  local enabled_json
  enabled_json="$(gcloud services list --enabled --project "$sample_project_id" --format=json 2>/dev/null || true)"
  if [[ -z "$enabled_json" ]]; then
    log_warn "Unable to list enabled services on sample project $sample_project_id (permissions/API may be missing)."
    return 0
  fi

  python3 - <<'PY' "$enabled_json" "$out_dir/required_apis.json" "${required[@]}"
import json, sys
enabled_raw = sys.argv[1]
out_path = sys.argv[2]
required = sys.argv[3:]
enabled = set()
try:
    for item in json.loads(enabled_raw) or []:
        name = item.get("serviceName") or item.get("name")
        if name: enabled.add(name)
except Exception:
    enabled = set()
out = []
for api in required:
    out.append({"api": api, "enabledOnSampleProject": api in enabled})
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\\n")
PY
}

preflight_permissions_best_effort() {
  # Best-effort permission checks for core operations; logs failures but doesn't abort.
  # Usage: preflight_permissions_best_effort <run_root> <org_id> <sample_project_id>
  local run_root="$1"
  local org_id="$2"
  local sample_project_id="${3:-}"
  local err="$run_root/org/$org_id/errors.jsonl"
  ensure_dir "$(dirname "$err")"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would run permission preflight"
    return 0
  fi

  run_with_retries 1 gcloud organizations describe "$org_id" --format=json >/dev/null 2>&1 || \
    append_error_jsonl "$err" "org" "$org_id" "preflight" "Missing permission for organizations describe"

  run_with_retries 1 gcloud resource-manager folders list --organization="$org_id" --format=json >/dev/null 2>&1 || \
    append_error_jsonl "$err" "org" "$org_id" "preflight" "Missing permission to list folders under organization"

  run_with_retries 1 gcloud projects list --filter="parent.type=organization parent.id=${org_id}" --format=json >/dev/null 2>&1 || \
    append_error_jsonl "$err" "org" "$org_id" "preflight" "Missing permission to list projects under organization"

  run_with_retries 1 gcloud asset search-all-resources --scope="organizations/${org_id}" --limit=1 --format=json >/dev/null 2>&1 || \
    append_error_jsonl "$err" "org" "$org_id" "preflight" "Missing permission/API for Cloud Asset Inventory search-all-resources (org scope)"

  if [[ -n "$sample_project_id" ]]; then
    run_with_retries 1 gcloud services list --enabled --project "$sample_project_id" --format=json >/dev/null 2>&1 || \
      append_error_jsonl "$err" "project" "$sample_project_id" "preflight" "Missing permission/API for Service Usage (list enabled services)"

    run_with_retries 1 gcloud projects get-iam-policy "$sample_project_id" --format=json >/dev/null 2>&1 || \
      append_error_jsonl "$err" "project" "$sample_project_id" "preflight" "Missing permission to read project IAM policy"

    (gcloud billing projects describe "$sample_project_id" --format=json >/dev/null 2>&1 || gcloud beta billing projects describe "$sample_project_id" --format=json >/dev/null 2>&1) || \
      append_error_jsonl "$err" "project" "$sample_project_id" "preflight" "Missing permission/API to read billing linkage for project"
  fi
}

write_run_metadata() {
  local out="$1"
  ensure_dir "$(dirname "$out")"
  if [[ -f "$out" && "${FORCE:-0}" != "1" ]]; then
    log_debug "Skip existing: $out"
    return 0
  fi
  python3 - <<'PY' "$out"
import json, os, sys, subprocess, time
out_path = sys.argv[1]
def sh(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ""
meta = {
  "runId": os.environ.get("RUN_ID",""),
  "orgId": os.environ.get("ORG_ID",""),
  "outDir": os.environ.get("OUT_DIR",""),
  "dryRun": os.environ.get("DRY_RUN","0") == "1",
  "force": os.environ.get("FORCE","0") == "1",
  "parallelism": int(os.environ.get("PARALLELISM","1") or "1"),
  "filters": {
    "includeFolders": os.environ.get("INCLUDE_FOLDERS",""),
    "excludeFolders": os.environ.get("EXCLUDE_FOLDERS",""),
    "includeProjects": os.environ.get("INCLUDE_PROJECTS",""),
    "excludeProjects": os.environ.get("EXCLUDE_PROJECTS",""),
    "resourceTypes": os.environ.get("RESOURCE_TYPES",""),
  },
  "timestamps": {
    "startedAt": os.environ.get("STARTED_AT",""),
  },
  "gcloud": {
    "account": sh(["gcloud","config","get-value","account"]),
    "project": sh(["gcloud","config","get-value","project"]),
    "versionLine": (sh(["gcloud","--version"]).splitlines()[:1] or [""])[0],
  }
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\\n")
PY
}

write_discovery_manifest() {
  # Usage: write_discovery_manifest <run_root> <org_id> <folders_json> <projects_json>
  local run_root="$1"
  local org_id="$2"
  local folders_json="$3"
  local projects_json="$4"
  local out="$run_root/discovery/manifest.json"
  ensure_dir "$(dirname "$out")"

  python3 - <<'PY' "$org_id" "$folders_json" "$projects_json" "$out"
import json, sys
org_id, folders_path, projects_path, out_path = sys.argv[1:]
folders = json.load(open(folders_path, "r", encoding="utf-8")) if folders_path else []
projects = json.load(open(projects_path, "r", encoding="utf-8")) if projects_path else []
manifest = {
  "organization": {"orgId": org_id},
  "folders": folders,
  "projects": projects,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\\n")
PY
}

write_folder_tree() {
  # Usage: write_folder_tree <folders_json> <out_path>
  local folders_json="$1"
  local out_path="$2"
  ensure_dir "$(dirname "$out_path")"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    write_json_pretty "$out_path" "[]"
    return 0
  fi
  python3 - <<'PY' "$folders_json" "$out_path"
import json, sys, re
folders_path, out_path = sys.argv[1:]
folders = json.load(open(folders_path, "r", encoding="utf-8")) or []
nodes = {}
for f in folders:
    name = f.get("name","")
    m = re.match(r"folders/(\\d+)$", name)
    if not m:
        continue
    fid = m.group(1)
    parent = f.get("parent") or ""
    pm = re.match(r"folders/(\\d+)$", parent)
    parent_fid = pm.group(1) if pm else None
    nodes[fid] = {"folderId": fid, "parentFolderId": parent_fid}

def depth(fid, seen=None):
    if seen is None: seen=set()
    if fid in seen: return 0
    seen.add(fid)
    p = nodes.get(fid, {}).get("parentFolderId")
    if not p or p not in nodes: return 1
    return 1 + depth(p, seen)

out = []
for fid in sorted(nodes.keys()):
    d = depth(fid) - 1
    out.append({**nodes[fid], "depth": max(d,0)})
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\\n")
PY
}

discover_scope() {
  local run_root="$1"
  local org_id="$2"

  local disc_dir="$run_root/discovery"
  ensure_dir "$disc_dir"

  if [[ -f "$disc_dir/folder_ids.txt" && -f "$disc_dir/project_ids.txt" && "${FORCE:-0}" != "1" ]]; then
    log_info "Discovery outputs already exist; skipping discovery (use --force to regenerate)."
    return 0
  fi

  log_info "Discovering folders (recursive)..."
  local folders_json="$disc_dir/folders.json"
  local folder_ids=()
  if [[ "$DRY_RUN" == "1" ]]; then
    write_json_pretty "$folders_json" "[]"
  else
    mapfile -t folder_ids < <(discover_folders_recursive "$folders_json" "$org_id" || true)
  fi

  # Apply folder filters to IDs list (folder JSON remains as raw discovery result).
  local filtered_folder_ids=()
  local fid
  for fid in "${folder_ids[@]}"; do
    if is_allowed_by_filters "$fid" "$INCLUDE_FOLDERS" "$EXCLUDE_FOLDERS"; then
      filtered_folder_ids+=("$fid")
    fi
  done
  folder_ids=("${filtered_folder_ids[@]}")
  write_folder_tree "$folders_json" "$disc_dir/folder_tree.json"

  log_info "Discovering projects under org root..."
  local projects_dir="$disc_dir/projects"
  ensure_dir "$projects_dir"
  local org_projects_json="$projects_dir/projects_org_root.json"
  local project_ids=()
  if [[ "$DRY_RUN" == "1" ]]; then
    write_json_pretty "$org_projects_json" "[]"
  else
    mapfile -t project_ids < <(discover_projects_for_parent "$org_projects_json" "organization" "$org_id" || true)
  fi

  log_info "Discovering projects under folders..."
  for fid in "${folder_ids[@]}"; do
    local folder_projects_json="$projects_dir/projects_folder_${fid}.json"
    local ids=()
    if [[ "$DRY_RUN" == "1" ]]; then
      write_json_pretty "$folder_projects_json" "[]"
    else
      mapfile -t ids < <(discover_projects_for_parent "$folder_projects_json" "folder" "$fid" || true)
    fi
    project_ids+=("${ids[@]}")
  done

  # Apply project filters, unique, stable sort.
  local filtered_project_ids=()
  local pid
  for pid in "${project_ids[@]}"; do
    if is_allowed_by_filters "$pid" "$INCLUDE_PROJECTS" "$EXCLUDE_PROJECTS"; then
      filtered_project_ids+=("$pid")
    fi
  done
  mapfile -t project_ids < <(printf '%s\n' "${filtered_project_ids[@]}" | sort -u)

  # Create a projects.json summary with best-effort parent association.
  local projects_json="$disc_dir/projects.json"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    write_json_pretty "$projects_json" "[]"
  else
    python3 - <<'PY' "$org_projects_json" "$projects_dir" "$projects_json"
import glob, json, os, sys
org_root_path, projects_dir, out_path = sys.argv[1:]
items = []
def load(path):
    try:
        return json.load(open(path,"r",encoding="utf-8")) or []
    except Exception:
        return []
for it in load(org_root_path):
    pid = it.get("projectId")
    if not pid: 
        continue
    parent = it.get("parent") or {}
    items.append({
      "projectId": pid,
      "parentType": parent.get("type") or "organization",
      "parentId": parent.get("id"),
    })
for p in glob.glob(os.path.join(projects_dir, "projects_folder_*.json")):
    for it in load(p):
        pid = it.get("projectId")
        if not pid:
            continue
        parent = it.get("parent") or {}
        items.append({
          "projectId": pid,
          "parentType": parent.get("type") or "folder",
          "parentId": parent.get("id"),
        })
dedup = {}
for it in items:
    dedup[it["projectId"]] = it
out = [dedup[k] for k in sorted(dedup.keys())]
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\\n")
PY
  fi

  write_discovery_manifest "$run_root" "$org_id" "$folders_json" "$projects_json"

  printf '%s\n' "${folder_ids[@]}" >"$disc_dir/folder_ids.txt"
  printf '%s\n' "${project_ids[@]}" >"$disc_dir/project_ids.txt"

  log_info "Discovery complete: folders=$(wc -l <"$disc_dir/folder_ids.txt" | tr -d ' ') projects=$(wc -l <"$disc_dir/project_ids.txt" | tr -d ' ')"
}

collect_project_all() {
  # Usage: collect_project_all <run_root> <org_id> <project_id>
  local run_root="$1"
  local org_id="$2"
  local project_id="$3"

  local proj_dir="$run_root/projects/$project_id"
  local errors="$proj_dir/errors.jsonl"
  ensure_dir "$proj_dir"

  log_info "Project $project_id: enabled apis"
  collect_enabled_apis_project "$project_id" "$proj_dir/enabled-apis" "$errors"

  log_info "Project $project_id: asset inventory"
  collect_asset_inventory_project "$project_id" "$proj_dir/asset-inventory" "$errors" "${RESOURCE_TYPES:-}"

  log_info "Project $project_id: IAM policy"
  collect_iam_project "$project_id" "$proj_dir/iam" "$errors"

  log_info "Project $project_id: billing"
  collect_billing_project "$project_id" "$proj_dir/billing" "$errors"

  log_info "Project $project_id: org policies"
  local constraints_json="$run_root/org/$org_id/org-policies/constraints.json"
  collect_org_policies_scope_effective "project" "$project_id" "$constraints_json" "$proj_dir/org-policies" "$errors"
}

collect_folder_all() {
  # Usage: collect_folder_all <run_root> <folder_id> <constraints_json>
  local run_root="$1"
  local folder_id="$2"
  local constraints_json="$3"

  local folder_dir="$run_root/folders/$folder_id"
  local errors="$folder_dir/errors.jsonl"
  ensure_dir "$folder_dir"

  log_info "Folder $folder_id: IAM policy"
  collect_iam_folder "$folder_id" "$folder_dir/iam" "$errors"

  log_info "Folder $folder_id: org policies"
  collect_org_policies_scope_effective "folder" "$folder_id" "$constraints_json" "$folder_dir/org-policies" "$errors"
}

collect_org_all() {
  # Usage: collect_org_all <run_root> <org_id>
  local run_root="$1"
  local org_id="$2"

  local org_dir="$run_root/org/$org_id"
  local errors="$org_dir/errors.jsonl"
  ensure_dir "$org_dir"

  log_info "Org $org_id: IAM policy"
  collect_iam_org "$org_id" "$org_dir/iam" "$errors"

  log_info "Org $org_id: org policy constraints"
  collect_org_policy_constraints_org "$org_id" "$org_dir/org-policies" "$errors"

  log_info "Org $org_id: org policy effective (best-effort)"
  collect_org_policies_scope_effective "org" "$org_id" "$org_dir/org-policies/constraints.json" "$org_dir/org-policies" "$errors"
}

aggregate_org_outputs() {
  # Usage: aggregate_org_outputs <run_root> <org_id>
  local run_root="$1"
  local org_id="$2"
  local org_dir="$run_root/org/$org_id"
  ensure_dir "$org_dir"

  log_info "Aggregating enabled apis (org)"
  aggregate_enabled_apis_org "$run_root" "$org_dir/enabled-apis"

  log_info "Aggregating asset inventory (org)"
  aggregate_asset_inventory_org "$run_root" "$org_dir/asset-inventory/asset_inventory_aggregated.json"

  log_info "Aggregating billing (org)"
  aggregate_billing_org "$run_root" "$org_dir/billing/billing_summary.json"

  log_info "Normalizing IAM view (org)"
  normalize_iam_view "$run_root"
}

main_run() {
  export ORG_ID OUT_DIR RUN_ID DRY_RUN FORCE PARALLELISM LOG_LEVEL
  export INCLUDE_FOLDERS EXCLUDE_FOLDERS INCLUDE_PROJECTS EXCLUDE_PROJECTS RESOURCE_TYPES

  STARTED_AT="$(timestamp_rfc3339)"
  export STARTED_AT

  local run_root="$OUT_DIR/$RUN_ID/org/$ORG_ID"
  export RUN_ROOT="$run_root"
  LOG_FILE="$run_root/logs/run.log"
  export LOG_FILE

  ensure_dir "$run_root/logs"
  log_info "Run root: $run_root"

  preflight_gcloud
  write_run_metadata "$run_root/metadata.json"

  discover_scope "$run_root" "$ORG_ID"

  local sample_project_id=""
  if [[ -f "$run_root/discovery/project_ids.txt" ]]; then
    sample_project_id="$(head -n 1 "$run_root/discovery/project_ids.txt" || true)"
  fi
  validate_required_apis_best_effort "$run_root" "$sample_project_id"
  preflight_permissions_best_effort "$run_root" "$ORG_ID" "$sample_project_id"

  collect_org_all "$run_root" "$ORG_ID"

  local constraints_json="$run_root/org/$ORG_ID/org-policies/constraints.json"

  if [[ -f "$run_root/discovery/folder_ids.txt" ]]; then
    while IFS= read -r folder_id; do
      [[ -z "$folder_id" ]] && continue
      collect_folder_all "$run_root" "$folder_id" "$constraints_json"
    done <"$run_root/discovery/folder_ids.txt"
  fi

  if [[ ! -f "$run_root/discovery/project_ids.txt" ]]; then
    die_usage "Discovery did not create project_ids.txt"
  fi

  if [[ "${PARALLELISM:-1}" -gt 1 && "$DRY_RUN" != "1" ]]; then
    log_info "Collecting per-project with parallelism=${PARALLELISM}"
    local force_flag=()
    if [[ "${FORCE:-0}" == "1" ]]; then
      force_flag=(--force)
    fi
    cat "$run_root/discovery/project_ids.txt" | xargs -n 1 -P "$PARALLELISM" -I {} \
      "$SCRIPT_DIR/gcp-org-audit.sh" \
        --mode collect-project \
        --project-id "{}" \
        --org-id "$ORG_ID" \
        --out-dir "$OUT_DIR" \
        --run-id "$RUN_ID" \
        --log-level "$LOG_LEVEL" \
        "${force_flag[@]}" \
        --resource-types "${RESOURCE_TYPES:-}" \
        --include-folders "${INCLUDE_FOLDERS:-}" \
        --exclude-folders "${EXCLUDE_FOLDERS:-}" \
        --include-projects "${INCLUDE_PROJECTS:-}" \
        --exclude-projects "${EXCLUDE_PROJECTS:-}"
  else
    while IFS= read -r project_id; do
      [[ -z "$project_id" ]] && continue
      collect_project_all "$run_root" "$ORG_ID" "$project_id"
    done <"$run_root/discovery/project_ids.txt"
  fi

  aggregate_org_outputs "$run_root" "$ORG_ID"

  log_info "Audit complete."
}

main_collect_project() {
  if [[ -z "$ORG_ID" || -z "$PROJECT_ID" ]]; then
    die_usage "--org-id and --project-id are required in collect-project mode"
  fi
  local run_root="$OUT_DIR/$RUN_ID/org/$ORG_ID"
  LOG_FILE="$run_root/logs/run.log"
  export LOG_FILE FORCE RESOURCE_TYPES
  collect_project_all "$run_root" "$ORG_ID" "$PROJECT_ID"
}

parse_args "$@"

case "$MODE" in
  run) main_run ;;
  collect-project) main_collect_project ;;
  *) die_usage "Unknown mode: $MODE" ;;
esac

