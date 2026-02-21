## ADDED Requirements

### Requirement: Enabled APIs enumeration per project
The system MUST enumerate enabled services/APIs for each discovered project and persist results as JSON.

#### Scenario: Enabled services listed for a project
- **WHEN** the system audits a project
- **THEN** it lists all enabled services/APIs for that project and writes the output to the project enabled-apis path

### Requirement: Stable output and diffability
The system MUST produce outputs in a stable order to allow easy diffing between runs.

#### Scenario: Same project audited twice
- **WHEN** the same project is audited in two separate runs with no changes
- **THEN** the enabled-apis output is byte-for-byte identical (or differs only by run metadata outside the dataset)

### Requirement: Aggregated organization view
The system MUST produce an aggregated view listing enabled APIs across all discovered projects, grouped by API and by project.

#### Scenario: Organization has multiple projects
- **WHEN** the audit run includes multiple projects
- **THEN** the system produces an org-level aggregated enabled-apis dataset

### Requirement: Failure handling for disabled Service Usage API
The system MUST record a clear error when it cannot enumerate enabled APIs because prerequisite APIs or permissions are missing, and MUST continue with other capabilities where possible.

#### Scenario: Service Usage permissions missing
- **WHEN** listing enabled services fails due to access denied
- **THEN** the system records the failure for that project and continues auditing other projects/capabilities
