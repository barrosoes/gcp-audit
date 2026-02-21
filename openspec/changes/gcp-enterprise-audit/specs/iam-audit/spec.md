## ADDED Requirements

### Requirement: IAM policy collection for organization
The system MUST collect the IAM policy for the Organization scope and persist it as JSON.

#### Scenario: Organization IAM policy collected
- **WHEN** the audit run starts IAM collection
- **THEN** the system retrieves the Organization IAM policy and writes it to the org IAM output path

### Requirement: IAM policy collection for folders
The system MUST collect IAM policies for every discovered folder and persist each as JSON.

#### Scenario: Folder IAM policies collected
- **WHEN** the system has discovered folders under the Organization
- **THEN** it retrieves and stores IAM policies for each folder

### Requirement: IAM policy collection for projects
The system MUST collect IAM policies for every discovered project and persist each as JSON.

#### Scenario: Project IAM policies collected
- **WHEN** the system has discovered projects under the Organization
- **THEN** it retrieves and stores IAM policies for each project

### Requirement: IAM output normalization
The system MUST preserve the raw IAM policy bindings and MUST additionally produce a normalized view that can be used to answer: “who has which roles at which scope?”.

#### Scenario: Normalized IAM view generated
- **WHEN** raw IAM policies are collected for org/folders/projects
- **THEN** the system produces a normalized dataset mapping principals to roles and scopes

### Requirement: Permission error handling
The system MUST record permission errors per scope without terminating the entire run, unless the error prevents discovery of any IAM data at all.

#### Scenario: Missing permission for one folder
- **WHEN** IAM policy retrieval fails for a specific folder due to access denied
- **THEN** the system records the error in logs/outputs and continues with remaining scopes
