## Context

O objetivo é entregar um script único (bash) executável no Cloud Shell via `gcloud` que realize auditoria de segurança na Organization inteira do GCP. O script deve:

- Descobrir, de forma automática e recursiva, a árvore de **folders** e **projetos** a partir do `ORG_ID`.
- Coletar dados de auditoria por categorias (capabilities do proposal), privilegiando **Cloud Asset Inventory** para inventário abrangente quando aplicável.
- Persistir os resultados em uma estrutura de pastas previsível e amigável para consumo por humanos e ferramentas.

Restrições e premissas:

- Execução em Cloud Shell (ambiente Linux padrão, `gcloud` disponível).
- Acesso é read-only na maior parte dos casos, mas pode exigir que APIs estejam habilitadas para consulta (ex.: Cloud Asset Inventory).
- Organizações grandes podem gerar volume alto de chamadas e dados; precisamos de controles de paginação, rate-limit e tolerância a falhas.

## Goals / Non-Goals

**Goals:**

- Implementar pipeline de auditoria por Organization com descoberta recursiva (org → folders → projetos).
- Coletar e exportar dados para as capabilities definidas no `proposal.md`:
  - `org-scope-discovery`, `asset-inventory-export`, `iam-audit`, `enabled-apis-audit`, `org-policy-audit`, `billing-audit`, `report-structure`.
- Manter execução idempotente, com outputs determinísticos e organização por diretórios.
- Tornar o script “operável” (logs, códigos de saída, modo dry-run opcional, retries).

**Non-Goals:**

- Não construir um sistema/serviço contínuo (apenas execução via script).
- Não fazer remediação automática (somente coleta/relato).
- Não implementar dashboards/BI; apenas gerar dados e sumarizações simples.
- Não garantir cobertura perfeita de “todos os recursos” via APIs específicas; inventário deve priorizar CAI e complementar quando necessário.

## Decisions

### 1) Estrutura geral: pipeline por fases (discover → collect → export → summarize)

- **Decisão**: Implementar um orquestrador simples em bash que executa fases em sequência e chama coletores por capability.
- **Racional**: Mantém clareza operacional, permite reexecução parcial e facilita paralelismo controlado.
- **Alternativas**:
  - Um script monolítico sem fases: mais difícil de manter e testar.
  - Implementar em Python/Go: melhor engenharia, mas foge do requisito (bash/Cloud Shell).

### 2) Descoberta de escopo usando Cloud Resource Manager (folders/projetos)

- **Decisão**: Descobrir folders e projetos via `gcloud resource-manager folders list` e `gcloud projects list` filtrando por parent/org/folder, com paginação e recursão.
- **Racional**: Abordagem padrão, com suporte nativo em `gcloud` e sem depender de inventário prévio.
- **Alternativas**:
  - Descobrir via CAI (search-all-resources) para encontrar projetos: possível, mas menos direto e pode depender mais de permissões/limites.

### 3) Inventário base via Cloud Asset Inventory (CAI)

- **Decisão**: Usar CAI como fonte primária para inventário amplo de recursos (ex.: `gcloud asset search-all-resources` / `gcloud asset list` / export quando aplicável), com escopo por projeto e, quando suportado, por org/folder.
- **Racional**: CAI padroniza coleta multi-serviço e reduz a necessidade de enumerar APIs individuais para inventário.
- **Alternativas**:
  - Consultar API por serviço (Compute, GKE, etc.): mais granular, mas explode complexidade e manutenção.

### 4) Coletores por capability (interfaces simples e outputs padronizados)

- **Decisão**: Cada capability vira uma função/“módulo” bash com assinatura estável, por exemplo:
  - `collect_iam_org`, `collect_iam_folder`, `collect_iam_project`
  - `collect_enabled_apis_project`
  - `collect_org_policies_*`
  - `collect_billing_*`
  - `collect_asset_inventory_*`
- **Racional**: Permite evolução incremental e facilita mapear diretamente para specs.
- **Alternativas**:
  - Um único coletor genérico: tende a ficar complexo e com muitos condicionais.

### 5) Formato de dados e estrutura de diretórios

- **Decisão**: Persistir outputs primários em JSON (saída de `gcloud ... --format=json`), com opcionais CSV/TSV para alguns relatórios e um `summary.json` por escopo (org/folder/projeto).
- **Estrutura proposta**:
  - `out/<timestamp|run-id>/org/<ORG_ID>/...`
  - `.../folders/<FOLDER_ID>/...`
  - `.../projects/<PROJECT_ID>/...`
  - dentro de cada escopo: `iam/`, `asset-inventory/`, `org-policies/`, `billing/`, `enabled-apis/`, `logs/`
- **Racional**: JSON é fácil de validar/parsear e mantém fidelidade ao dado original.
- **Alternativas**:
  - Somente texto humano: dificulta automação posterior.
  - Somente CSV: perde estrutura e fidelidade.

### 6) Performance e confiabilidade: paginação, retries e paralelismo controlado

- **Decisão**: Implementar:
  - paginação/iteração robusta (`--page-size`, loops por tokens quando necessário)
  - retries com backoff para erros transitórios
  - paralelismo opcional por projeto com limite (ex.: `xargs -P <N>`), desabilitado por padrão
- **Racional**: Evita falhas em orgs grandes e respeita quotas.
- **Alternativas**:
  - Paralelismo irrestrito: risco de rate-limit e throttling, além de outputs inconsistentes.

### 7) Segurança e permissões: modelo “least privilege” documentado

- **Decisão**: Tratar permissões como requisito explícito de execução, com verificação inicial (`preflight`) e mensagem clara do que falta.
- **Racional**: Execuções em ambientes corporativos frequentemente falham por IAM; diagnóstico rápido reduz custo.
- **Alternativas**:
  - Assumir Owner/Admin: inviável e inseguro.

## Risks / Trade-offs

- **[Quotas/rate-limit em orgs grandes]** → Mitigação: paralelismo controlado, retries/backoff, execução por lotes e checkpoints.
- **[Permissões insuficientes para CAI/IAM/Org Policy/Billing]** → Mitigação: preflight de permissões + documentação de roles mínimas por capability.
- **[Cobertura incompleta de recursos via CAI para alguns serviços/atributos]** → Mitigação: specs podem definir “fonte primária” (CAI) + coletores complementares quando necessário.
- **[Tempo de execução elevado]** → Mitigação: flags para limitar escopo (folders/projetos), execução incremental e desabilitar capabilities não necessárias.
- **[Outputs grandes e custosos para armazenar/transferir]** → Mitigação: compressão opcional, granularidade por escopo e retenção configurável.
