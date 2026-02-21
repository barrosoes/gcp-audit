# gcp-audit

Auditoria “enterprise-ish” para Google Cloud Platform (GCP) em **nível de Organization**, executável no **Cloud Shell**, com coleta de:

- Descoberta recursiva de folders e projetos
- Inventário de recursos via **Cloud Asset Inventory**
- IAM (org/folder/project) + visão normalizada (principal → roles → scopes)
- APIs habilitadas por projeto
- Org Policies (set + effective/best-effort) com herança vs override (best-effort)
- Billing por projeto + sumário por Billing Account
- Outputs organizados por escopo e capability

## Requisitos

- Execução no **Cloud Shell** (ou Linux com `gcloud` instalado e autenticado)
- `gcloud`
- `python3` (usado para normalização e JSON “pretty”/ordenado)

## APIs necessárias (e validação)

O script faz uma checagem **best-effort** em um projeto amostra da Organization e grava o resultado em:

- `out/<run-id>/org/<ORG_ID>/preflight/required_apis.json`

APIs normalmente envolvidas:

- `cloudresourcemanager.googleapis.com`
- `cloudasset.googleapis.com`
- `serviceusage.googleapis.com`
- `orgpolicy.googleapis.com`
- `cloudbilling.googleapis.com`

Obs.: a necessidade/visibilidade pode variar por ambiente/permissões; falhas são registradas em `errors.jsonl` sem abortar toda a execução, sempre que possível.

## Permissões / IAM (least privilege – recomendado)

Os mínimos exatos variam por política da empresa e pelos recursos presentes, mas um baseline comum inclui:

- **Discovery (org/folder/project)**:
  - `roles/resourcemanager.organizationViewer`
  - `roles/resourcemanager.folderViewer`
  - `roles/resourcemanager.projectViewer`
- **IAM policies** (ler IAM):
  - `roles/resourcemanager.organizationIamViewer`
  - `roles/resourcemanager.folderIamViewer`
  - `roles/resourcemanager.projectIamViewer`
  - alternativa “mais ampla”: `roles/iam.securityReviewer`
- **Cloud Asset Inventory**:
  - `roles/cloudasset.viewer`
- **Enabled APIs (Service Usage)**:
  - `roles/serviceusage.serviceUsageViewer`
- **Org Policies**:
  - `roles/orgpolicy.policyViewer`
- **Billing**:
  - `roles/billing.viewer` (no Billing Account) + acesso para ler vínculo de billing por projeto

Se algo estiver faltando, o script registra erros por escopo em `errors.jsonl` (em vez de parar toda a auditoria).

## Como executar (Cloud Shell)

Executar auditoria completa por Organization:

```bash
./scripts/gcp-org-audit.sh --org-id 123456789012
```

Execução com paralelismo por projeto:

```bash
./scripts/gcp-org-audit.sh --org-id 123456789012 --parallelism 4
```

Restringir a lista de projetos:

```bash
./scripts/gcp-org-audit.sh --org-id 123456789012 --include-projects proj-a,proj-b
```

Dry-run (não chama `gcloud`):

```bash
./scripts/gcp-org-audit.sh --org-id 123456789012 --dry-run
```

## Layout de outputs

O run root fica em:

- `out/<run-id>/org/<ORG_ID>/`

Arquivos e pastas principais:

- `metadata.json`: inputs/flags, timestamps e info do `gcloud`
- `logs/run.log`: log com timestamps
- `discovery/`:
  - `folders.json`, `folder_tree.json`
  - `projects.json`
  - `manifest.json`
  - `folder_ids.txt`, `project_ids.txt`
- `org/<ORG_ID>/` (nível org):
  - `iam/iam_policy.json`
  - `org-policies/constraints.json`, `org-policies/policies_set.json`, `org-policies/describe/*.json`
  - `org-policies/constraints_catalog.json` (best-effort, quando `gcloud org-policies list-constraints` está disponível)
  - `enabled-apis/enabled_apis_aggregated.json`
  - `enabled-apis/enabled_apis_by_project.json`
  - `asset-inventory/asset_inventory_aggregated.json`
  - `billing/billing_summary.json`
  - `errors.jsonl`
- `folders/<FOLDER_ID>/`:
  - `iam/iam_policy.json`
  - `org-policies/*` + `inheritance_summary.json` (best-effort)
  - `errors.jsonl`
- `projects/<PROJECT_ID>/`:
  - `enabled-apis/enabled_services.json`
  - `asset-inventory/resources.json`
  - `iam/iam_policy.json`
  - `billing/billing.json`
  - `org-policies/*` + `inheritance_summary.json` (best-effort)
  - `errors.jsonl`
- `iam/normalized_iam.json`: visão normalizada (principal → roles → scopes)

## Observações de performance

- Em Organizations grandes, o volume de dados e chamadas a APIs pode ser alto.
- Use `--parallelism` com cuidado para evitar rate-limit.
- Use filtros (`--include-*` / `--exclude-*`) para recortar escopo quando necessário.

## Testes automatizados (pure bash, sem GCP real)

Foi adicionada uma suíte de testes **“pure bash”** que roda o script usando um **`gcloud` mockado** (fixtures em JSON). Isso permite validar:

- `--dry-run` realmente **não chama** `gcloud`
- idempotência: segunda execução (mesmo `RUN_ID`/`OUT_DIR`) faz **menos chamadas** por causa de “skip existing” (sem `--force`)
- geração dos agregados de APIs habilitadas (por API e por projeto)

### Como executar

```bash
chmod +x tests/run.sh tests/bin/gcloud
./tests/run.sh
```

### Estrutura dos testes

- `tests/run.sh`: runner + asserts
- `tests/bin/gcloud`: mock de `gcloud` que grava chamadas em `tests/tmp/gcloud_calls.log`
- `tests/fixtures/*.json`: respostas “canned” usadas pelo mock
- `tests/out/`: outputs do script gerados durante os testes
