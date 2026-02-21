## ADDED Requirements

### Requirement: Billing account linkage per project
The system MUST determine the billing account linkage for each discovered project and persist results as JSON.

#### Scenario: Project has a billing account
- **WHEN** the system audits billing for a project with billing enabled
- **THEN** it records the billing account ID and billing enabled status for that project

### Requirement: Organization-level billing summary
The system MUST produce an organization-level billing summary that lists projects grouped by billing account and highlights projects with billing disabled.

#### Scenario: Mixed billing states across projects
- **WHEN** some projects have billing disabled and others are linked to different billing accounts
- **THEN** the org-level summary groups by billing account and includes a list of billing-disabled projects

### Requirement: Permission and API prerequisite handling
The system MUST record clear errors when billing information cannot be retrieved due to missing permissions or APIs and MUST continue with other scopes where possible.

#### Scenario: Billing permissions missing for a project
- **WHEN** billing linkage retrieval fails due to access denied
- **THEN** the system records the error for that project and continues auditing remaining projects
