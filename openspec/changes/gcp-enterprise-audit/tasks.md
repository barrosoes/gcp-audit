## 1. Repository & script scaffolding

- [x] 1.1 Create `scripts/` (or `bin/`) layout for the single bash audit script and supporting libs
- [x] 1.2 Add executable entrypoint (e.g., `gcp-org-audit.sh`) with strict mode (`set -euo pipefail`) and consistent logging
- [x] 1.3 Implement CLI flags and env parsing: `ORG_ID` (required), optional filters (folder/project include/exclude), `RUN_ID`, `OUT_DIR`, `DRY_RUN`, `PARALLELISM`
- [x] 1.4 Add `--help` usage text and example invocations for Cloud Shell

## 2. Preflight checks (auth, APIs, permissions)

- [x] 2.1 Validate `gcloud` presence/version and active account; fail fast with actionable errors
- [x] 2.2 Validate required APIs availability (Cloud Resource Manager, Cloud Asset Inventory, Service Usage, Org Policy, Cloud Billing) and document required enablement
- [x] 2.3 Implement permission preflight per capability (best-effort): log missing permissions per scope (org/folder/project) without aborting the whole run
- [x] 2.4 Implement run metadata output (inputs, filters, timestamps, gcloud version) at run root

## 3. Output structure (report-structure)

- [x] 3.1 Create run root directory layout: `out/<run-id>/org/<ORG_ID>/...` with `logs/` and `metadata.json`
- [x] 3.2 Implement deterministic file naming and stable ordering for JSON outputs (diff-friendly)
- [x] 3.3 Implement per-scope error record format and location (e.g., `errors.jsonl` per scope)

## 4. Scope discovery (org-scope-discovery)

- [x] 4.1 Implement recursive folder discovery starting at `ORG_ID` (store parent links and depth)
- [x] 4.2 Implement project discovery for org root and for each discovered folder (associate parent scope)
- [x] 4.3 Write discovery manifest JSON including org, folders, projects, and discovered relationships
- [x] 4.4 Implement discovery filters (folder/project allow/deny lists) without changing default behavior

## 5. Asset inventory (asset-inventory-export)

- [x] 5.1 Implement CAI inventory collection per project (primary mechanism) with pagination handling
- [x] 5.2 Add optional resource type filtering for CAI inventory queries
- [x] 5.3 Write per-project inventory outputs to `asset-inventory/` and an org-level aggregated inventory dataset
- [x] 5.4 Implement retries with backoff for transient CAI failures and record partial failures per project

## 6. IAM audit (iam-audit)

- [x] 6.1 Collect Organization IAM policy and write raw JSON output
- [x] 6.2 Collect Folder IAM policies for all discovered folders and write raw JSON outputs
- [x] 6.3 Collect Project IAM policies for all discovered projects and write raw JSON outputs
- [x] 6.4 Generate normalized IAM view (principal → roles → scopes) for easier analysis
- [x] 6.5 Ensure permission errors are recorded per scope and do not abort the full run

## 7. Enabled APIs audit (enabled-apis-audit)

- [x] 7.1 Enumerate enabled services/APIs per project and write JSON outputs under `enabled-apis/`
- [x] 7.2 Produce aggregated org-level enabled-apis dataset grouped by API and by project
- [x] 7.3 Ensure stable ordering for diffability between runs
- [x] 7.4 Record clear errors when Service Usage queries fail (missing perms/APIs) and continue other capabilities

## 8. Org Policy audit (org-policy-audit)

- [x] 8.1 Enumerate Org Policy constraints at organization scope and write JSON outputs
- [x] 8.2 Collect effective policy values at org, folder, and project scopes (where applicable)
- [x] 8.3 Indicate inheritance vs override in outputs (reference parent scope value when overridden)
- [x] 8.4 Partition org-policy outputs by scope in deterministic locations

## 9. Billing audit (billing-audit)

- [x] 9.1 Retrieve billing linkage per project (billing enabled status + billing account ID) and write JSON outputs
- [x] 9.2 Produce org-level billing summary grouped by billing account and list billing-disabled projects
- [x] 9.3 Record permission/API prerequisite failures per project and continue the run

## 10. Reliability, performance, and operability

- [x] 10.1 Add pagination helpers and robust JSON writing utilities (consistent formatting)
- [x] 10.2 Add retry/backoff helper and apply it to network/API calls across collectors
- [x] 10.3 Add optional parallelism for per-project collectors with a safe default limit
- [x] 10.4 Add log levels and ensure logs are written to `logs/` with timestamps
- [x] 10.5 Add incremental/idempotent behavior (skip existing outputs unless `--force` is set)

## 11. Documentation and examples

- [x] 11.1 Document required IAM roles/permissions per capability and recommended least-privilege setup
- [x] 11.2 Add README section describing outputs layout and how to interpret key datasets
- [x] 11.3 Provide Cloud Shell run examples (basic run, filtered run, parallel run) and expected runtime considerations
