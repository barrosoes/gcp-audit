## ADDED Requirements

### Requirement: Run output root directory
The system MUST write all outputs under a single run root directory identified by a run identifier (timestamp or explicit run-id).

#### Scenario: Audit run starts
- **WHEN** an audit run begins
- **THEN** the system creates a run root output directory and writes all subsequent outputs beneath it

### Requirement: Output partitioning by scope and capability
The system MUST partition outputs by scope (org/folder/project) and by capability (e.g., iam, asset-inventory, org-policies, billing, enabled-apis).

#### Scenario: Multiple capabilities executed
- **WHEN** the audit run executes multiple capabilities for a project
- **THEN** outputs are written into capability-specific subdirectories under that project scope directory

### Requirement: Deterministic filenames and metadata
The system MUST use deterministic filenames for datasets and MUST write run metadata (inputs, filters, start/end time, tool versions) in a separate metadata file.

#### Scenario: Outputs written for a project
- **WHEN** outputs are produced for a given project and capability
- **THEN** dataset filenames follow a consistent naming convention and a metadata file is present at the run root

### Requirement: Logging
The system MUST write execution logs to the run output directory and MUST include per-scope error records when a collector fails.

#### Scenario: Collector fails for one project
- **WHEN** a capability collector fails for a specific project
- **THEN** the system writes an error record under that project scope and continues where possible
