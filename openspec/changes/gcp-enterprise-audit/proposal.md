## Why

Hoje a auditoria de segurança no GCP tende a ser fragmentada por projeto e pouco repetível; este change cria uma auditoria padronizada, executável no Cloud Shell, que cobre a Organization inteira para apoiar segurança/compliance com consistência e baixo esforço operacional.

## What Changes

- Adicionar um **script único em bash** para execução no Cloud Shell via `gcloud`.
- Executar a auditoria a partir de uma **Organization** e fazer **descoberta recursiva** de folders e projetos.
- Gerar **inventário de recursos** usando **Cloud Asset Inventory** quando apropriado para cobertura ampla e consistente.
- Coletar e exportar informações de:
  - IAM (níveis org/folder/project)
  - APIs habilitadas por projeto
  - Org Policies (por org/folder/project conforme aplicável)
  - Billing (vínculos e informações relevantes para auditoria)
- Persistir resultados em uma **estrutura organizada em pastas**, adequada para consulta e integração com relatórios.

## Capabilities

### New Capabilities
- `org-scope-discovery`: Descoberta automática e recursiva de folders e projetos a partir da Organization.
- `asset-inventory-export`: Inventário de recursos via Cloud Asset Inventory (export/consulta) com outputs estruturados.
- `iam-audit`: Coleta e exportação de IAM em org, folders e projetos (bindings/policies) para revisão de acesso.
- `enabled-apis-audit`: Enumeração de serviços/APIs habilitadas por projeto para baseline e detecção de drift.
- `org-policy-audit`: Coleta de políticas/constraints (org/folder/project) para avaliar postura de segurança.
- `billing-audit`: Coleta de informações de billing e vínculos (ex.: billing account associada a projetos) para governança.
- `report-structure`: Padronização de diretórios/arquivos de saída (ex.: por org/folder/projeto/categoria) para consumo posterior.

### Modified Capabilities

<!-- None -->

## Impact

- Dependência de execução no **Cloud Shell** com `gcloud` e permissões suficientes para leitura em nível de Organization.
- Pode exigir APIs/serviços habilitados (ex.: Cloud Asset Inventory, Cloud Resource Manager) e acesso IAM apropriado para listar e ler políticas.
- Auditoria pode gerar grande volume de dados e chamadas a APIs; é necessário considerar tempo de execução e limites de quota em orgs grandes.
