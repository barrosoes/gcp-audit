## ADDED Requirements

### Requirement: Organization scope input
The system MUST accept an Organization identifier (`ORG_ID`) as the root scope for the audit run.

#### Scenario: ORG_ID provided
- **WHEN** the operator starts an audit run with `ORG_ID` set
- **THEN** the system uses `ORG_ID` as the discovery root for folders and projects

### Requirement: Recursive folder discovery
The system MUST discover folders under the Organization recursively, producing a complete folder tree (including nested folders) visible to the executing identity.

#### Scenario: Nested folders exist
- **WHEN** the Organization contains nested folder hierarchies
- **THEN** the system discovers folders at all depths and records their parent/child relationships

### Requirement: Project discovery under organization and folders
The system MUST discover all projects belonging to the Organization, including projects attached under any discovered folder.

#### Scenario: Projects spread across folders
- **WHEN** projects exist under multiple folders and at the organization root
- **THEN** the system enumerates all projects and associates each project with its parent (org or folder)

### Requirement: Discovery output manifest
The system MUST write a machine-readable discovery manifest that lists:
- the Organization
- the full set of discovered folders (with parent links)
- the full set of discovered projects (with parent links)

#### Scenario: Discovery completes successfully
- **WHEN** discovery finishes without fatal errors
- **THEN** the system writes a manifest file that can be consumed by subsequent collectors

### Requirement: Discovery filtering (optional)
The system MUST support optional filters to limit discovery scope (e.g., include/exclude folder IDs, include/exclude project IDs) without changing default behavior.

#### Scenario: Folder allowlist filter provided
- **WHEN** the operator provides a folder allowlist filter
- **THEN** the system limits traversal and project enumeration to the allowed subtree(s)
