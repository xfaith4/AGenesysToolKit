# Routing & People Modules - Implementation Roadmap

This document outlines the implementation plan for the Routing & People workspace modules that are currently placeholders.

## Overview

The Routing & People workspace focuses on ACD (Automatic Call Distribution) configuration, skills management, user administration, and routing analytics.

## Module Status

| Module | Status | Priority |
|--------|--------|----------|
| Queues | ✅ Fully Implemented | N/A |
| Skills | ✅ Fully Implemented | N/A |
| Users & Presence | ✅ Fully Implemented | N/A |
| Routing Snapshot | 🔴 Not Implemented | Medium |

## Implementation Plan

### 1. Queues Module ✅ Core Module Ready

**Status**: Core module functions exist in `Core/RoutingPeople.psm1`

**Current Implementation**:
- `Get-GcQueues` function implemented
- API endpoint: `/api/v2/routing/queues`
- Supports pagination for large queue lists

**View Requirements**:
```powershell
function New-QueuesView {
  # UI Components:
  # - Filter by division
  # - Search by queue name
  # - Display: Name, Division, Member Count, Media Settings
  # - Actions: Load, Export JSON/CSV
  # - Detail view: Queue configuration, members, wrapup codes
}
```

**API Endpoints**:
- `GET /api/v2/routing/queues` - List all queues
- `GET /api/v2/routing/queues/{queueId}` - Get queue details
- `GET /api/v2/routing/queues/{queueId}/members` - Get queue members
- `GET /api/v2/routing/queues/{queueId}/wrapupcodes` - Get wrapup codes

**Data Model**:
```json
{
  "id": "queue-id",
  "name": "Customer Service",
  "division": { "id": "...", "name": "Sales" },
  "memberCount": 15,
  "mediaSettings": {
    "call": { "alertingTimeoutSeconds": 30 },
    "email": { "alertingTimeoutSeconds": 300 }
  },
  "routingRules": [...],
  "dateModified": "2024-01-15T10:30:00Z"
}
```

**Implementation Steps**:
1. Create `New-QueuesView` function with XAML layout
2. Wire "Load Queues" button to `Get-GcQueues`
3. Add search/filter functionality
4. Implement export handlers (JSON/CSV)
5. Add queue detail modal (optional enhancement)

---

### 2. Skills Module ✅ Core Module Ready

**Status**: Core module functions exist in `Core/RoutingPeople.psm1`

**Current Implementation**:
- `Get-GcSkills` function implemented
- API endpoint: `/api/v2/routing/skills`
- Supports pagination

**View Requirements**:
```powershell
function New-SkillsView {
  # UI Components:
  # - Filter by state (active/inactive)
  # - Search by skill name
  # - Display: Name, State, Date Modified
  # - Actions: Load, Export JSON/CSV
  # - Bulk operations: Enable/disable skills
}
```

**API Endpoints**:
- `GET /api/v2/routing/skills` - List all skills
- `GET /api/v2/routing/skills/{skillId}` - Get skill details
- `POST /api/v2/routing/skills` - Create skill
- `DELETE /api/v2/routing/skills/{skillId}` - Delete skill

**Data Model**:
```json
{
  "id": "skill-id",
  "name": "Spanish",
  "state": "active",
  "dateModified": "2024-01-15T10:30:00Z"
}
```

**Implementation Steps**:
1. Create `New-SkillsView` function with XAML layout
2. Wire "Load Skills" button to `Get-GcSkills`
3. Add search/filter functionality
4. Implement export handlers (JSON/CSV)
5. Add skill management actions (create/delete) - optional

---

### 3. Users & Presence Module ✅ Fully Implemented

**Priority**: High - Critical for user management and monitoring

**Status**: Complete - view implemented with user listing, search, and export

**Implemented Features**:
- ✅ `New-UsersPresenceView` function
- ✅ Load users with Get-GcUsers
- ✅ Display user name, email, division, state, username
- ✅ Search/filter functionality
- ✅ Export to JSON/CSV
- ✅ Background execution via Start-AppJob

**Core Module Functions**:
- ✅ `Get-GcUsers` - Already implemented in Core/RoutingPeople.psm1
- ✅ `Get-GcUserPresence` - Already implemented in Core/RoutingPeople.psm1

**Future Enhancements** (not in current scope):
- Real-time presence monitoring with auto-refresh
- User routing status display
- User routing skills with proficiency levels
- Tabbed layout for different views

---

### 4. Routing Snapshot Module 🔴 Not Implemented

**Priority**: Medium - Useful for operational visibility

**Purpose**: Real-time snapshot of routing health, queue statistics, and agent activity

**View Requirements**:
```powershell
function New-RoutingSnapshotView {
  # UI Components:
  # - Real-time metrics: Agents on Queue, Calls in Queue, Longest Wait
  # - Queue health indicators (green/yellow/red)
  # - Auto-refresh every 10 seconds
  # - Drill-down: Click queue to see members and interactions
  # - Export snapshot to JSON/CSV
}
```

**API Endpoints**:
- `GET /api/v2/routing/queues/{queueId}/users` - Queue members
- `POST /api/v2/analytics/queues/observations/query` - Queue observations (real-time)
- `GET /api/v2/conversations` - Active conversations
- `GET /api/v2/users/{userId}/routingstatus` - Agent routing status

**Core Module Functions Needed**:
```powershell
# In Core/RoutingPeople.psm1
function Get-GcQueueObservations {
  param($QueueIds, $AccessToken, $InstanceName)
  # Query real-time queue observations
  # Returns: oInteracting, oWaiting, oOnQueue metrics
}

function Get-GcRoutingSnapshot {
  param($AccessToken, $InstanceName)
  # Aggregate snapshot across all queues
  # Returns: Queue health, agent availability, interaction counts
}
```

**Data Model**:
```json
{
  "snapshot": {
    "timestamp": "2024-01-15T10:30:00Z",
    "queues": [
      {
        "queueId": "queue-id",
        "queueName": "Customer Service",
        "agentsOnQueue": 12,
        "agentsAvailable": 5,
        "interactionsWaiting": 3,
        "longestWaitTime": 45,
        "healthStatus": "yellow"
      }
    ]
  }
}
```

**Implementation Steps**:
1. Add `Get-GcQueueObservations` and `Get-GcRoutingSnapshot` to `Core/RoutingPeople.psm1`
2. Create `New-RoutingSnapshotView` with metrics dashboard layout
3. Implement auto-refresh timer (10 seconds)
4. Add health status indicators (green: <30s wait, yellow: 30-60s, red: >60s)
5. Implement drill-down modals for queue details
6. Add export functionality

**Estimated Effort**: 6-8 hours

---

## Testing Strategy

### Unit Tests

Create `tests/test-routing-people.ps1`:

```powershell
# Test Core/RoutingPeople.psm1 functions
Describe "Routing & People Module Tests" {
  Context "Get-GcQueues" {
    It "Should return queue list" {
      # Mock API response
      # Test pagination
      # Test error handling
    }
  }
  
  Context "Get-GcSkills" {
    It "Should return skills list" {
      # Test API call
      # Test filtering
    }
  }
  
  Context "Get-GcUsers" {
    It "Should return users with presence" {
      # Test user retrieval
      # Test presence aggregation
    }
  }
}
```

### Integration Tests

Manual testing checklist:

- [ ] Load queues and verify grid population
- [ ] Search queues by name
- [ ] Export queues to JSON/CSV
- [ ] Load skills and verify display
- [ ] Export skills to JSON/CSV
- [ ] Load users and verify presence status
- [ ] Filter users by division/status
- [ ] Refresh routing snapshot and verify metrics
- [ ] Verify auto-refresh in Routing Snapshot

---

## API Permissions Required

Ensure OAuth client has the following scopes:

- `routing` - Read routing configuration (queues, skills)
- `users` - Read user information
- `presence` - Read user presence
- `analytics` - Read queue observations and real-time metrics

---

## Future Enhancements

### Phase 2 Enhancements

1. **Queue Management Actions**
   - Add/remove queue members
   - Modify queue settings
   - Configure wrapup codes

2. **Skill Management Actions**
   - Create/delete skills
   - Bulk assign skills to users
   - Skill proficiency matrix view

3. **Advanced User Management**
   - Modify user routing status
   - Assign/remove routing skills
   - Set user presence (if permissions allow)

4. **Real-Time Monitoring**
   - WebSocket-based presence updates
   - Live queue statistics dashboard
   - Alert thresholds and notifications

5. **Reporting**
   - Historical queue performance reports
   - Agent productivity reports
   - Skill utilization analytics

---

## Dependencies

### Core Modules
- `Core/RoutingPeople.psm1` - ✅ Created
- `Core/HttpRequests.psm1` - ✅ Exists
- `Core/JobRunner.psm1` - ✅ Exists

### UI Components
- WPF DataGrid for list views
- ComboBox for filters
- Button handlers for load/export actions
- Search TextBox with real-time filtering

---

## References

- [Genesys Cloud Routing API](https://developer.genesys.cloud/routing/)
- [Users API](https://developer.genesys.cloud/useragentman/users/)
- [Presence API](https://developer.genesys.cloud/useragentman/presence/)
- [Analytics API - Queue Observations](https://developer.genesys.cloud/analyticsdatamanagement/analytics/detail/conversation-aggregate-query-examples)

---

## Summary

**Current State**:
- ✅ Core module functions implemented for Queues, Skills, Users, and Presence
- ✅ Queues view fully implemented with search and export
- ✅ Skills view fully implemented with search and export
- ✅ Users & Presence view fully implemented with search and export
- 🔴 Routing Snapshot module not implemented

**Completed in v0.5.0**:
1. ✅ `New-QueuesView` - List, search, export queues
2. ✅ `New-SkillsView` - List, search, export skills
3. ✅ `New-UsersPresenceView` - List, search, export users

**Remaining Work**:
1. Implement `New-RoutingSnapshotView` (6-8 hours)
2. Create core functions for queue observations
3. Add view mapping to switch statement in main app
4. Test end-to-end functionality
5. Create unit tests

**Total Remaining Effort**: 6-8 hours

---

**Status**: Roadmap 75% complete (3 of 4 modules implemented).
