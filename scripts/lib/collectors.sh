#!/usr/bin/env bash

set -euo pipefail

_json_sort_list_by_key() {
  # Usage: _json_sort_list_by_key <key>
  local key="$1"
  python3 -c 'import json,sys
key=sys.argv[1]
data=json.load(sys.stdin) or []
def k(x):
  return str(x.get(key,"")) if isinstance(x, dict) else ""
data_sorted=sorted(data, key=k)
json.dump(data_sorted, sys.stdout, indent=2, sort_keys=True, ensure_ascii=False)
sys.stdout.write("\n")
' "$key"
}

_write_json_file_from_cmd() {
  # Usage: _write_json_file_from_cmd <out_path> <scope_type> <scope_id> <capability> <cmd...>
  local out="$1"; shift
  local scope_type="$1"; shift
  local scope_id="$1"; shift
  local capability="$1"; shift
  local errors_jsonl="$1"; shift

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would write $out from: $*"
    return 0
  fi

  if [[ -f "$out" && "${FORCE:-0}" != "1" ]]; then
    log_debug "Skip existing: $out"
    return 0
  fi

  local raw
  if raw="$("$@" 2>/dev/null)"; then
    write_json_pretty "$out" "$raw"
    return 0
  fi

  local ec=$?
  append_error_jsonl "$errors_jsonl" "$scope_type" "$scope_id" "$capability" "Command failed (exit=$ec): $*"
  return 0
}

collect_iam_org() {
  local org_id="$1"
  local out_dir="$2"
  local errors_jsonl="$3"
  ensure_dir "$out_dir"
  _write_json_file_from_cmd "$out_dir/iam_policy.json" "org" "$org_id" "iam-audit" "$errors_jsonl" \
    gcloud organizations get-iam-policy "$org_id" --format=json
}

collect_iam_folder() {
  local folder_id="$1"
  local out_dir="$2"
  local errors_jsonl="$3"
  ensure_dir "$out_dir"
  _write_json_file_from_cmd "$out_dir/iam_policy.json" "folder" "$folder_id" "iam-audit" "$errors_jsonl" \
    gcloud resource-manager folders get-iam-policy "$folder_id" --format=json
}

collect_iam_project() {
  local project_id="$1"
  local out_dir="$2"
  local errors_jsonl="$3"
  ensure_dir "$out_dir"
  _write_json_file_from_cmd "$out_dir/iam_policy.json" "project" "$project_id" "iam-audit" "$errors_jsonl" \
    gcloud projects get-iam-policy "$project_id" --format=json
}

normalize_iam_view() {
  # Reads raw IAM policies from run output and writes a normalized JSON array.
  # Usage: normalize_iam_view <run_root>
  local run_root="$1"
  local out="$run_root/iam/normalized_iam.json"
  ensure_dir "$(dirname "$out")"

  python3 - <<'PY' "$run_root" "$out"
import glob, json, os, sys
run_root, out_path = sys.argv[1], sys.argv[2]

records = []
def add(scope_type, scope_id, policy_path):
    try:
        with open(policy_path, "r", encoding="utf-8") as f:
            policy = json.load(f) or {}
    except Exception:
        return
    for b in policy.get("bindings", []) or []:
        role = b.get("role")
        for m in b.get("members", []) or []:
            records.append({
                "scopeType": scope_type,
                "scopeId": scope_id,
                "role": role,
                "member": m,
                "sourceFile": os.path.relpath(policy_path, run_root),
            })

org_paths = glob.glob(os.path.join(run_root, "org", "*", "iam", "iam_policy.json"))
for p in org_paths:
    parts = p.split(os.sep)
    org_id = parts[parts.index("org")+1]
    add("org", org_id, p)

for p in glob.glob(os.path.join(run_root, "folders", "*", "iam", "iam_policy.json")):
    folder_id = os.path.basename(os.path.dirname(os.path.dirname(p)))
    add("folder", folder_id, p)

for p in glob.glob(os.path.join(run_root, "projects", "*", "iam", "iam_policy.json")):
    project_id = os.path.basename(os.path.dirname(os.path.dirname(p)))
    add("project", project_id, p)

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(records, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY
}

collect_enabled_apis_project() {
  local project_id="$1"
  local out_dir="$2"
  local errors_jsonl="$3"
  ensure_dir "$out_dir"

  local out_file="$out_dir/enabled_services.json"
  if [[ -f "$out_file" && "${FORCE:-0}" != "1" ]]; then
    log_debug "Skip existing: $out_file"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would list enabled services for project $project_id"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  if gcloud services list --enabled --project "$project_id" --format=json >"$tmp" 2>/dev/null; then
    cat "$tmp" | _json_sort_list_by_key "serviceName" >"$out_file"
    rm -f "$tmp"
    return 0
  fi
  local ec=$?
  rm -f "$tmp"
  append_error_jsonl "$errors_jsonl" "project" "$project_id" "enabled-apis-audit" "Failed to list enabled services (exit=$ec)"
  return 0
}

aggregate_enabled_apis_org() {
  # Usage: aggregate_enabled_apis_org <run_root> <org_out_dir>
  local run_root="$1"
  local out_dir="$2"
  ensure_dir "$out_dir"

  local out_by_api="$out_dir/enabled_apis_aggregated.json"
  local out_by_project="$out_dir/enabled_apis_by_project.json"

  if [[ -f "$out_by_api" && -f "$out_by_project" && "${FORCE:-0}" != "1" ]]; then
    log_debug "Skip existing: $out_by_api and $out_by_project"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would aggregate enabled apis (by API and by project)"
    return 0
  fi

  python3 - <<'PY' "$run_root" "$out_by_api" "$out_by_project"
import glob, json, os, sys
run_root, out_by_api, out_by_project = sys.argv[1], sys.argv[2], sys.argv[3]
by_api = {}
by_project = {}
for p in glob.glob(os.path.join(run_root, "projects", "*", "enabled-apis", "enabled_services.json")):
    project_id = os.path.basename(os.path.dirname(os.path.dirname(p)))
    try:
        data = json.load(open(p, "r", encoding="utf-8")) or []
    except Exception:
        continue
    svcs = []
    for svc in data:
        name = svc.get("serviceName") or svc.get("name") or ""
        if not name:
            continue
        by_api.setdefault(name, []).append(project_id)
        svcs.append(name)
    by_project[project_id] = sorted(set(svcs))

out_api = [{"api": k, "projects": sorted(set(v))} for k,v in sorted(by_api.items())]
with open(out_by_api, "w", encoding="utf-8") as f:
    json.dump(out_api, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")

out_proj = [{"projectId": k, "apis": v} for k,v in sorted(by_project.items())]
with open(out_by_project, "w", encoding="utf-8") as f:
    json.dump(out_proj, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY
}

collect_asset_inventory_project() {
  # Uses CAI search-all-resources for project scope.
  # Usage: collect_asset_inventory_project <project_id> <out_dir> <errors_jsonl> <resource_types_csv>
  local project_id="$1"
  local out_dir="$2"
  local errors_jsonl="$3"
  local resource_types_csv="${4:-}"
  ensure_dir "$out_dir"

  local out_file="$out_dir/resources.json"
  if [[ -f "$out_file" && "${FORCE:-0}" != "1" ]]; then
    log_debug "Skip existing: $out_file"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would collect CAI inventory for project $project_id"
    return 0
  fi

  local args=(asset search-all-resources "--scope=projects/${project_id}" "--format=json")
  if [[ -n "$resource_types_csv" ]]; then
    args+=("--asset-types=$resource_types_csv")
  fi

  local tmp
  tmp="$(mktemp)"
  if run_with_retries 3 gcloud "${args[@]}" >"$tmp" 2>/dev/null; then
    cat "$tmp" | _json_sort_list_by_key "name" >"$out_file"
    rm -f "$tmp"
    return 0
  fi
  local ec=$?
  rm -f "$tmp"
  append_error_jsonl "$errors_jsonl" "project" "$project_id" "asset-inventory-export" "CAI search-all-resources failed (exit=$ec)"
  return 0
}

aggregate_asset_inventory_org() {
  # Usage: aggregate_asset_inventory_org <run_root> <out_path>
  local run_root="$1"
  local out_path="$2"
  ensure_dir "$(dirname "$out_path")"

  if [[ -f "$out_path" && "${FORCE:-0}" != "1" ]]; then
    log_debug "Skip existing: $out_path"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would aggregate asset inventory (org)"
    return 0
  fi

  python3 - <<'PY' "$run_root" "$out_path"
import glob, json, os, sys
run_root, out_path = sys.argv[1], sys.argv[2]
out = []
for p in glob.glob(os.path.join(run_root, "projects", "*", "asset-inventory", "resources.json")):
    project_id = os.path.basename(os.path.dirname(os.path.dirname(p)))
    try:
        data = json.load(open(p, "r", encoding="utf-8")) or []
    except Exception:
        continue
    out.append({"projectId": project_id, "resources": data})
out = sorted(out, key=lambda x: x.get("projectId",""))
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY
}

collect_billing_project() {
  # Usage: collect_billing_project <project_id> <out_dir> <errors_jsonl>
  local project_id="$1"
  local out_dir="$2"
  local errors_jsonl="$3"
  ensure_dir "$out_dir"

  local out_file="$out_dir/billing.json"
  if [[ -f "$out_file" && "${FORCE:-0}" != "1" ]]; then
    log_debug "Skip existing: $out_file"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would describe billing for project $project_id"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"

  if gcloud billing projects describe "$project_id" --format=json >"$tmp" 2>/dev/null; then
    cat "$tmp" | python3 -m json.tool >"$out_file" 2>/dev/null || cat "$tmp" >"$out_file"
    rm -f "$tmp"
    return 0
  fi

  if gcloud beta billing projects describe "$project_id" --format=json >"$tmp" 2>/dev/null; then
    cat "$tmp" | python3 -m json.tool >"$out_file" 2>/dev/null || cat "$tmp" >"$out_file"
    rm -f "$tmp"
    return 0
  fi

  local ec=$?
  rm -f "$tmp"
  append_error_jsonl "$errors_jsonl" "project" "$project_id" "billing-audit" "Billing describe failed (exit=$ec)"
  return 0
}

aggregate_billing_org() {
  # Usage: aggregate_billing_org <run_root> <out_path>
  local run_root="$1"
  local out_path="$2"
  ensure_dir "$(dirname "$out_path")"

  if [[ -f "$out_path" && "${FORCE:-0}" != "1" ]]; then
    log_debug "Skip existing: $out_path"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would aggregate billing (org)"
    return 0
  fi

  python3 - <<'PY' "$run_root" "$out_path"
import glob, json, os, sys
run_root, out_path = sys.argv[1], sys.argv[2]
by_acct = {}
disabled = []
for p in glob.glob(os.path.join(run_root, "projects", "*", "billing", "billing.json")):
    project_id = os.path.basename(os.path.dirname(os.path.dirname(p)))
    try:
        data = json.load(open(p, "r", encoding="utf-8")) or {}
    except Exception:
        continue
    enabled = data.get("billingEnabled")
    acct = data.get("billingAccountName") or ""
    if not enabled:
        disabled.append(project_id)
    if acct:
        by_acct.setdefault(acct, []).append(project_id)
out = {
  "byBillingAccount": {k: sorted(v) for k,v in sorted(by_acct.items())},
  "billingDisabledProjects": sorted(disabled),
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY
}

collect_org_policy_constraints_org() {
  # Usage: collect_org_policy_constraints_org <org_id> <out_dir> <errors_jsonl>
  local org_id="$1"
  local out_dir="$2"
  local errors_jsonl="$3"
  ensure_dir "$out_dir"

  local out_file="$out_dir/constraints.json"
  local out_catalog="$out_dir/constraints_catalog.json"

  if [[ -f "$out_file" && -f "$out_catalog" && "${FORCE:-0}" != "1" ]]; then
    log_debug "Skip existing: $out_file and $out_catalog"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would list org policy constraints/policies for org $org_id"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  if gcloud org-policies list --organization="$org_id" --format=json >"$tmp" 2>/dev/null; then
    cat "$tmp" | _json_sort_list_by_key "constraint" >"$out_file"
    rm -f "$tmp"
  else
    local ec=$?
    rm -f "$tmp"
    append_error_jsonl "$errors_jsonl" "org" "$org_id" "org-policy-audit" "Org policies list failed (exit=$ec)"
  fi
  rm -f "$tmp"

  # Best-effort: attempt to list constraint catalog/definitions (gcloud support varies).
  if [[ -f "$out_catalog" && "${FORCE:-0}" != "1" ]]; then
    return 0
  fi
  tmp="$(mktemp)"
  if gcloud org-policies list-constraints --organization="$org_id" --format=json >"$tmp" 2>/dev/null; then
    cat "$tmp" | _json_sort_list_by_key "name" >"$out_catalog"
  elif gcloud org-policies list-constraints --format=json >"$tmp" 2>/dev/null; then
    cat "$tmp" | _json_sort_list_by_key "name" >"$out_catalog"
  else
    append_error_jsonl "$errors_jsonl" "org" "$org_id" "org-policy-audit" "Org policy constraint catalog not available via gcloud (list-constraints unsupported or denied)"
  fi
  rm -f "$tmp"
}

collect_org_policies_scope_effective() {
  # Best-effort: list policies set at scope; if --effective is available, describe effective policy.
  # Usage: collect_org_policies_scope_effective <scope_type> <scope_id> <constraints_json> <out_dir> <errors_jsonl>
  local scope_type="$1" # org|folder|project
  local scope_id="$2"
  local constraints_json="$3"
  local out_dir="$4"
  local errors_jsonl="$5"

  ensure_dir "$out_dir"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would collect org policies for $scope_type $scope_id"
    return 0
  fi

  local list_args=(org-policies list "--format=json")
  case "$scope_type" in
    org) list_args+=("--organization=$scope_id") ;;
    folder) list_args+=("--folder=$scope_id") ;;
    project) list_args+=("--project=$scope_id") ;;
    *) return 0 ;;
  esac

  local tmp
  tmp="$(mktemp)"
  local policies_set="$out_dir/policies_set.json"
  if [[ -f "$policies_set" && "${FORCE:-0}" != "1" ]]; then
    log_debug "Skip existing: $policies_set"
  elif gcloud "${list_args[@]}" >"$tmp" 2>/dev/null; then
    cat "$tmp" | _json_sort_list_by_key "constraint" >"$policies_set"
  else
    local ec=$?
    append_error_jsonl "$errors_jsonl" "$scope_type" "$scope_id" "org-policy-audit" "Org policies list failed for scope (exit=$ec)"
  fi
  rm -f "$tmp"

  if [[ ! -f "$constraints_json" ]]; then
    return 0
  fi

  local effective_supported=0
  if gcloud org-policies describe --help 2>/dev/null | grep -q -- '--effective'; then
    effective_supported=1
  fi

  local constraints_ids="$out_dir/constraints_ids.txt"
  if [[ ! -f "$constraints_ids" || "${FORCE:-0}" == "1" ]]; then
    python3 - <<'PY' "$constraints_json" >"$constraints_ids"
import json, sys
data = json.load(open(sys.argv[1], "r", encoding="utf-8")) or []
for item in data:
    c = item.get("constraint")
    if c: print(c)
PY
  fi

  local constraint
  while IFS= read -r constraint; do
    [[ -z "$constraint" ]] && continue
    local out_file="$out_dir/describe/$(echo "$constraint" | tr '/' '_' ).json"
    ensure_dir "$(dirname "$out_file")"
    if [[ -f "$out_file" && "${FORCE:-0}" != "1" ]]; then
      continue
    fi
    local describe_args=(org-policies describe "$constraint" "--format=json")
    case "$scope_type" in
      org) describe_args+=("--organization=$scope_id") ;;
      folder) describe_args+=("--folder=$scope_id") ;;
      project) describe_args+=("--project=$scope_id") ;;
    esac
    if (( effective_supported == 1 )); then
      describe_args+=("--effective")
    fi
    local raw
    if raw="$(run_with_retries 2 gcloud "${describe_args[@]}" 2>/dev/null || true)"; then
      if [[ -n "$raw" ]]; then
        write_json_pretty "$out_file" "$raw"
      fi
    fi
  done <"$constraints_ids"

  # Build inheritance/override summary (best-effort) with parent references.
  if [[ -n "${RUN_ROOT:-}" && -n "${ORG_ID:-}" ]]; then
    python3 - <<'PY' "$scope_type" "$scope_id" "$out_dir" "$RUN_ROOT" "$ORG_ID" >/dev/null 2>&1 || true
import glob, json, os, sys
scope_type, scope_id, out_dir, run_root, org_id = sys.argv[1:]
describe_dir = os.path.join(out_dir, "describe")
files = sorted(glob.glob(os.path.join(describe_dir, "*.json")))

def sanitize(constraint: str) -> str:
    return constraint.replace("/", "_")

def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def parent_for_folder(fid: str):
    tree = os.path.join(run_root, "discovery", "folder_tree.json")
    data = read_json(tree) or []
    for it in data:
        if str(it.get("folderId")) == str(fid):
            pf = it.get("parentFolderId")
            if pf:
                return ("folder", str(pf))
            return ("org", str(org_id))
    return ("org", str(org_id))

def parent_for_project(pid: str):
    pj = os.path.join(run_root, "discovery", "projects.json")
    data = read_json(pj) or []
    for it in data:
        if it.get("projectId") == pid:
            pt = it.get("parentType") or "organization"
            if pt == "folder" and it.get("parentId"):
                return ("folder", str(it.get("parentId")))
            return ("org", str(org_id))
    return ("org", str(org_id))

def parent_scope(st: str, sid: str):
    if st == "org":
        return None
    if st == "folder":
        return parent_for_folder(sid)
    if st == "project":
        return parent_for_project(sid)
    return None

parent = parent_scope(scope_type, scope_id)

summary = []
for fp in files:
    data = read_json(fp) or {}
    constraint = data.get("constraint") or os.path.splitext(os.path.basename(fp))[0]
    inherit = data.get("inheritFromParent")
    entry = {
        "constraint": constraint,
        "scopeType": scope_type,
        "scopeId": scope_id,
        "inheritFromParent": inherit,
        "effectivePolicyFile": os.path.relpath(fp, run_root),
    }
    if parent and inherit is False:
        ptype, pid = parent
        parent_base = {
            "org": os.path.join(run_root, "org", org_id, "org-policies", "describe"),
            "folder": os.path.join(run_root, "folders", pid, "org-policies", "describe"),
        }.get(ptype)
        if parent_base:
            pfp = os.path.join(parent_base, sanitize(constraint) + ".json")
            if os.path.exists(pfp):
                entry["parentEffectivePolicyFile"] = os.path.relpath(pfp, run_root)
    summary.append(entry)

out_path = os.path.join(out_dir, "inheritance_summary.json")
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY
  fi
}

