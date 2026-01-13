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
| Config Export | ✅ Fully Implemented | N/A |

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

### 4. Config Export Module ✅ Fully Implemented

**Priority**: Medium - Useful for backup, documentation, and migration

**Status**: Complete - Core module and view implemented with full export capabilities

**Implemented Features**:
- ✅ `Core/ConfigExport.psm1` module created
- ✅ `Export-GcFlowsConfig` - Export flows to JSON
- ✅ `Export-GcQueuesConfig` - Export queues to JSON
- ✅ `Export-GcSkillsConfig` - Export skills to JSON
- ✅ `Export-GcDataActionsConfig` - Export data actions to JSON
- ✅ `Export-GcCompleteConfig` - Bulk export with organized directory structure
- ✅ `New-ConfigExportView` - UI with checkboxes for each config type
- ✅ Export history tracking
- ✅ ZIP archive creation
- ✅ Background execution via Start-AppJob

**Export Structure**:
```
config_export_20240115_103045/
├── flows/
│   ├── flow_{id}.json
│   └── manifest.json
├── queues/
│   ├── queue_{id}.json
│   └── manifest.json
├── skills/
│   ├── skill_{id}.json
│   └── manifest.json
├── data_actions/
│   ├── action_{id}.json
│   └── manifest.json
├── metadata.json
└── config_export_20240115_103045.zip
```

**Use Cases**:
- **Backup**: Periodic export of configuration for disaster recovery
- **Version Control**: Track configuration changes in Git
- **Migration**: Export from one org (import not in scope)
- **Documentation**: Generate JSON files for documentation purposes
- **Audit**: Review configuration changes over time

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
- ✅ Config Export module fully implemented and functional
- 🔴 Dependency / Impact Map not implemented

**Completed in v0.5.0**:
1. ✅ `New-ConfigExportView` - Export configuration with history tracking
2. ✅ `Core/ConfigExport.psm1` - Export functions for all config types

**Remaining Work**:
1. Implement `New-DependencyImpactMapView` (simplified search version: 4-6 hours)
2. Create `Core/Dependencies.psm1` module (simplified)
3. Add view mapping to switch statement in main app
4. Test end-to-end functionality

**Total Remaining Effort**: 4-6 hours (simplified)

---

**Recommendation**: 
- **Config Export** ✅ Completed
- **Dependency Analysis** can be simplified to text-based search initially
- Dependency analysis is "nice to have" rather than critical functionality

---

**Status**: Roadmap 75% complete (3 of 4 modules implemented).
