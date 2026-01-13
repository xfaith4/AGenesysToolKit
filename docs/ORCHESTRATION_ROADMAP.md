# Orchestration Modules - Implementation Roadmap

This document outlines the implementation plan for the remaining Orchestration workspace modules that are currently placeholders.

## Overview

The Orchestration workspace handles administrative configuration tasks, including flows, data actions, dependency mapping, and configuration export.

## Module Status

| Module | Status | Priority |
|--------|--------|----------|
| Flows | ✅ Fully Implemented | N/A |
| Data Actions | ✅ Fully Implemented | N/A |
| Dependency / Impact Map | 🔴 Not Implemented | Medium |
| Config Export | 🔴 Not Implemented | Medium |

## Implemented Modules

### 1. Flows Module ✅ Fully Implemented

**Status**: Complete and functional

**Current Implementation**:
- `New-FlowsView` function exists in main app (lines 2573-2839)
- API integration: `/api/v2/flows`
- Features:
  - Load all flows with pagination
  - Filter by flow type (Inbound Call, Chat, Email, Bot, etc.)
  - Filter by status (Published, Draft, Checked Out)
  - Search flows by name
  - Export to JSON/CSV
  - Display: Name, Type, Status, Version, Modified Date, Modified By

**No further action required** ✅

---

### 2. Data Actions Module ✅ Fully Implemented

**Status**: Complete and functional

**Current Implementation**:
- `New-DataActionsView` function exists in main app (lines 2840-3099)
- API integration: `/api/v2/integrations/actions`
- Features:
  - Load all data actions with pagination
  - Filter by category (Custom, Platform, Integration)
  - Filter by status (Active, Inactive)
  - Search actions by name
  - Export to JSON/CSV
  - Display: Name, Category, Status, Integration, Modified Date, Modified By

**No further action required** ✅

---

## Implementation Plan for Remaining Modules

### 3. Dependency / Impact Map Module 🔴 Not Implemented

**Priority**: Medium - Useful for impact analysis before making configuration changes

**Purpose**: Visualize dependencies between configuration objects (flows, queues, data actions, integrations) to understand impact of changes

**View Requirements**:
```powershell
function New-DependencyImpactMapView {
  # UI Components:
  # - Object type selector: Flow, Queue, Data Action, Integration, Schedule
  # - Object search/select dropdown
  # - Dependency visualization: Tree view or graph (textual representation)
  # - Impact summary: "X flows depend on this queue", "Used by Y integrations"
  # - Export dependency map to JSON/text
  # - Reverse lookup: "What uses this object?"
}
```

**API Endpoints**:
- `GET /api/v2/flows/{flowId}` - Get flow configuration (includes references to queues, data actions)
- `GET /api/v2/routing/queues` - List queues (analyze which flows reference them)
- `GET /api/v2/integrations/actions/{actionId}` - Get data action details
- `GET /api/v2/integrations` - List integrations

**Core Module Functions Needed**:
```powershell
# Create new Core/Dependencies.psm1 module
function Get-GcFlowDependencies {
  param($FlowId, $AccessToken, $InstanceName)
  # Parse flow configuration
  # Extract references to: queues, skills, data actions, schedules, prompts
  # Return dependency tree
}

function Get-GcQueueUsage {
  param($QueueId, $AccessToken, $InstanceName)
  # Find all flows that reference this queue
  # Check DID numbers assigned to queue
  # Return list of dependent objects
}

function Get-GcDataActionUsage {
  param($ActionId, $AccessToken, $InstanceName)
  # Find all flows that use this data action
  # Check scheduled jobs that use it
  # Return list of dependent objects
}

function Build-GcDependencyMap {
  param($ObjectType, $ObjectId, $AccessToken, $InstanceName)
  # Build complete dependency tree for any object
  # Recursive traversal of dependencies
  # Return hierarchical structure
}
```

**Data Model**:
```json
{
  "object": {
    "id": "flow-id",
    "name": "Customer Service Flow",
    "type": "flow"
  },
  "dependencies": [
    {
      "id": "queue-id",
      "name": "Customer Service Queue",
      "type": "queue",
      "relationship": "transfers_to"
    },
    {
      "id": "data-action-id",
      "name": "Lookup Customer",
      "type": "dataAction",
      "relationship": "invokes"
    }
  ],
  "dependents": [
    {
      "id": "did-number-id",
      "name": "+1-555-0100",
      "type": "didNumber",
      "relationship": "routes_to"
    }
  ]
}
```

**Implementation Steps**:
1. Create `Core/Dependencies.psm1` module
2. Implement `Get-GcFlowDependencies` to parse flow JSON
3. Implement `Get-GcQueueUsage` to find queue references
4. Implement `Build-GcDependencyMap` for hierarchical dependency tree
5. Create `New-DependencyImpactMapView` with object selector
6. Display dependency tree in TreeView or hierarchical list
7. Add export functionality (JSON/text)
8. Implement reverse lookup ("What uses this?")

**Challenges**:
- Flow configuration JSON is complex and nested
- Requires parsing XML/YAML flow definitions
- Performance: Scanning all flows to find dependencies can be slow
- API does not provide direct dependency queries

**Alternative Approach** (Simpler):
- Instead of full dependency analysis, provide "Usage Search"
- Search flows by queue ID, data action ID, etc.
- Text-based search through flow configurations
- Display results as list rather than graph

**Estimated Effort**: 10-12 hours (full implementation) or 4-6 hours (simplified search)

---

### 4. Config Export Module 🔴 Not Implemented

**Priority**: Medium - Useful for backup, documentation, and migration

**Purpose**: Export Genesys Cloud configuration to JSON/YAML for backup, version control, or migration purposes

**View Requirements**:
```powershell
function New-ConfigExportView {
  # UI Components:
  # - Configuration type selector: Flows, Queues, Skills, Data Actions, Integrations, Users
  # - Select all / Select specific checkbox
  # - Export format: JSON, YAML (if supported)
  # - Include related objects checkbox (e.g., export flow with referenced queues)
  # - Progress bar for export
  # - Actions: Export Selected, Export All, Schedule Export (future)
}
```

**API Endpoints**:
- All relevant configuration APIs (flows, queues, skills, users, etc.)
- No dedicated "export" API - must query each resource type individually

**Core Module Functions Needed**:
```powershell
# Create new Core/ConfigExport.psm1 module
function Export-GcFlowsConfig {
  param($FlowIds, $AccessToken, $InstanceName, $OutputPath)
  # Export flows to JSON file
  # Optionally include dependencies
}

function Export-GcQueuesConfig {
  param($QueueIds, $AccessToken, $InstanceName, $OutputPath)
  # Export queues to JSON file
}

function Export-GcSkillsConfig {
  param($SkillIds, $AccessToken, $InstanceName, $OutputPath)
  # Export skills to JSON file
}

function Export-GcDataActionsConfig {
  param($ActionIds, $AccessToken, $InstanceName, $OutputPath)
  # Export data actions to JSON file
}

function Export-GcCompleteConfig {
  param($AccessToken, $InstanceName, $OutputDirectory)
  # Export all configuration types to organized directory structure
  # artifacts/
  #   config_export_20240115/
  #     flows/
  #       flow1.json
  #       flow2.json
  #     queues/
  #       queue1.json
  #     skills/
  #       skill1.json
  # Creates ZIP archive
}
```

**Data Model**:
Export structure:
```
config_export_20240115_103045/
├── flows/
│   ├── flow_customer_service.json
│   ├── flow_sales.json
│   └── manifest.json (list of exported flows)
├── queues/
│   ├── queue_customer_service.json
│   └── manifest.json
├── skills/
│   ├── skill_spanish.json
│   └── manifest.json
├── data_actions/
│   ├── action_lookup_customer.json
│   └── manifest.json
├── users/ (optional)
│   └── manifest.json
├── metadata.json (export timestamp, scope, user)
└── config_export_20240115_103045.zip
```

**Implementation Steps**:
1. Create `Core/ConfigExport.psm1` module
2. Implement individual export functions (flows, queues, skills, data actions)
3. Implement `Export-GcCompleteConfig` for bulk export
4. Create `New-ConfigExportView` with checkboxes for each config type
5. Implement "Export Selected" button handler
6. Add progress tracking during export
7. Generate ZIP archive of exported files
8. Add "Open Folder" button to view exported files

**Use Cases**:
- **Backup**: Periodic export of configuration for disaster recovery
- **Version Control**: Track configuration changes in Git
- **Migration**: Export from one org and import to another (import not in scope)
- **Documentation**: Generate JSON files for documentation purposes
- **Audit**: Review configuration changes over time

**Estimated Effort**: 6-8 hours

---

## Testing Strategy

### Unit Tests

Create `tests/test-orchestration.ps1`:

```powershell
# Test Orchestration modules
Describe "Orchestration Module Tests" {
  Context "Dependency Analysis" {
    It "Should parse flow dependencies" {
      # Test flow JSON parsing
      # Test queue reference extraction
    }
  }
  
  Context "Config Export" {
    It "Should export flows to JSON" {
      # Test export function
      # Verify file creation
    }
    
    It "Should create ZIP archive" {
      # Test ZIP creation
      # Verify archive contents
    }
  }
}
```

### Integration Tests

Manual testing checklist:

**Flows & Data Actions** (Already Implemented):
- [x] Load flows and verify grid population
- [x] Search flows by name
- [x] Export flows to JSON/CSV
- [x] Load data actions and verify display
- [x] Export data actions to JSON/CSV

**Dependency / Impact Map**:
- [ ] Select a flow and view dependencies
- [ ] View queues used by flows
- [ ] View data actions used by flows
- [ ] Perform reverse lookup (what uses this queue?)
- [ ] Export dependency map to JSON

**Config Export**:
- [ ] Export all flows to JSON
- [ ] Export specific queues to JSON
- [ ] Export complete configuration (all types)
- [ ] Verify ZIP archive creation
- [ ] Verify directory structure and file contents
- [ ] Test "Open Folder" button

---

## API Permissions Required

Ensure OAuth client has the following scopes:

- `architect` - Read flow configurations
- `routing` - Read queue and skill configurations
- `integrations` - Read data actions and integrations
- `users` - Read user configuration (optional)

---

## Future Enhancements

### Phase 2 Enhancements

1. **Advanced Dependency Visualization**
   - Graphical dependency tree (requires UI charting library)
   - Interactive drill-down
   - Circular dependency detection

2. **Config Import**
   - Import flows/queues/skills from JSON files
   - Conflict resolution (if object already exists)
   - Bulk import from ZIP archive

3. **Config Diff**
   - Compare two exported configurations
   - Highlight differences between orgs
   - Generate migration plan

4. **Scheduled Exports**
   - Automated daily/weekly configuration exports
   - Email notification on completion
   - Integration with version control (Git commit)

5. **Config Validation**
   - Validate exported configuration for errors
   - Check for missing dependencies
   - Compliance checks (naming conventions, etc.)

---

## Dependencies

### Core Modules
- `Core/Dependencies.psm1` - 🔴 Needs creation
- `Core/ConfigExport.psm1` - 🔴 Needs creation
- `Core/HttpRequests.psm1` - ✅ Exists
- `Core/JobRunner.psm1` - ✅ Exists

### UI Components
- WPF TreeView for dependency visualization
- CheckBox for configuration type selection
- ProgressBar for export progress
- Button handlers for export actions

---

## References

- [Genesys Cloud Architect API](https://developer.genesys.cloud/devapps/architect/)
- [Routing API](https://developer.genesys.cloud/routing/)
- [Integrations API](https://developer.genesys.cloud/integrations/)

---

## Summary

**Current State**:
- ✅ Flows module fully implemented and functional
- ✅ Data Actions module fully implemented and functional
- 🔴 Dependency / Impact Map not implemented
- 🔴 Config Export not implemented

**Next Steps**:
1. Implement `New-ConfigExportView` (6-8 hours) - **RECOMMENDED PRIORITY**
2. Create `Core/ConfigExport.psm1` module
3. Implement `New-DependencyImpactMapView` (simplified search version: 4-6 hours)
4. Create `Core/Dependencies.psm1` module (simplified)
5. Add view mappings to switch statement in main app
6. Test end-to-end functionality

**Total Estimated Effort**: 10-14 hours (simplified) or 16-20 hours (full implementation)

---

**Recommendation**: 
- **Config Export** is higher value and easier to implement - prioritize this
- **Dependency Analysis** can be simplified to text-based search initially
- Both are "nice to have" rather than critical functionality

---

**Status**: Roadmap complete. Ready for implementation.
