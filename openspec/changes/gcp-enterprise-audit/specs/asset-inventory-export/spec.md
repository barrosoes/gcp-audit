## ADDED Requirements

### Requirement: Asset inventory collection via Cloud Asset Inventory
The system MUST collect a resource inventory using Cloud Asset Inventory (CAI) as the primary mechanism for broad multi-service coverage.

#### Scenario: Inventory run for a project
- **WHEN** the system runs inventory for a discovered project
- **THEN** it queries CAI for resources in that project scope and records the results

### Requirement: Inventory scope selection
The system MUST support collecting inventory at the project scope and MUST be able to aggregate results across all discovered projects for an organization-wide view.

#### Scenario: Organization-wide inventory requested
- **WHEN** an audit run targets an Organization with multiple projects
- **THEN** the system collects per-project inventory and produces an aggregated organization-level inventory output

### Requirement: Inventory output format
The system MUST persist inventory outputs as JSON using stable, deterministic filenames per scope (org/folder/project) and capability.

#### Scenario: Inventory output written
- **WHEN** the inventory collector completes for a scope
- **THEN** the system writes JSON output under the run output directory in a predictable location

### Requirement: Resource type selection (optional)
The system MUST allow selecting a subset of resource types for inventory collection, while defaulting to a comprehensive set when not specified.

#### Scenario: Resource type filter provided
- **WHEN** the operator provides a list of resource type filters
- **THEN** the system restricts CAI queries to the requested types

### Requirement: Pagination and rate-limit resilience
The system MUST handle pagination for CAI results and MUST retry transient failures with backoff.

#### Scenario: CAI returns multiple pages
- **WHEN** CAI returns inventory results across multiple pages
- **THEN** the system retrieves all pages and outputs a complete dataset for the scope
