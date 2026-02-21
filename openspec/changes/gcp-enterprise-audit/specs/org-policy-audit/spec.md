## ADDED Requirements

### Requirement: Org Policy constraints enumeration
The system MUST enumerate Organization Policy constraints that apply to the Organization and persist results as JSON.

#### Scenario: Organization constraints collected
- **WHEN** the org-policy audit runs for the Organization
- **THEN** the system outputs the set of constraints and their definitions/identifiers for the Organization

### Requirement: Policy values collection per scope
The system MUST collect effective policy values for Organization Policy constraints at organization, folder, and project scopes where applicable.

#### Scenario: Effective policy collected for a project
- **WHEN** a project is audited for org policies
- **THEN** the system records the effective policy value(s) for relevant constraints at that project scope

### Requirement: Inheritance and overrides visibility
The system MUST make it possible to identify when a policy is inherited versus overridden at a lower scope.

#### Scenario: Folder overrides org policy
- **WHEN** a folder sets a policy value that differs from the Organization
- **THEN** the outputs indicate the override and reference the parent scope value

### Requirement: Output structure by scope
The system MUST write org policy outputs under the run output directory separated by scope (org/folder/project) and include identifiers for the scope being audited.

#### Scenario: Folder org policy output written
- **WHEN** a folder policy collection completes
- **THEN** the output path includes the folder ID and contains only that folder’s policy dataset
