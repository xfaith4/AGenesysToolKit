# Conversations Modules - Implementation Roadmap

This document outlines the implementation plan for the Conversations workspace modules that are currently placeholders.

## Overview

The Conversations workspace provides deep analysis of conversation data, including lookup, timeline reconstruction, media/quality analysis, and comprehensive incident packet generation.

## Module Status

| Module | Status | Priority |
|--------|--------|----------|
| Conversation Lookup | ✅ Fully Implemented | N/A |
| Conversation Timeline | ✅ Fully Implemented | N/A |
| Media & Quality | 🔴 Not Implemented | Medium |
| Abandon & Experience | 🔴 Not Implemented | Medium |
| Analytics Jobs | ✅ Fully Implemented | N/A |
| Incident Packet | ✅ Fully Implemented | N/A |

## Implementation Plan

### 1. Conversation Lookup Module ✅ Fully Implemented

**Priority**: High - Essential for finding and analyzing conversations

**Status**: Complete - view implemented with search, export, and navigation features

**Purpose**: Search conversations by various criteria (date range, participants, queue, wrap-up code, etc.)

**View Requirements**:
```powershell
function New-ConversationLookupView {
  # UI Components:
  # - Date range picker (last 1h, 6h, 24h, 7d, custom)
  # - Filter by: Queue, User/Agent, ANI, DNIS, Direction (inbound/outbound)
  # - Media type filter: voice, chat, email, message
  # - Results grid: Conversation ID, Start Time, Duration, Participants, Queue, Disposition
  # - Actions: Search, Export JSON/CSV, Open Timeline (link to Timeline module)
  # - Pagination controls (500 results default, show "Load More")
}
```

**API Endpoints**:
- `POST /api/v2/analytics/conversations/details/query` - Search conversations
- `GET /api/v2/conversations/{conversationId}` - Get conversation details

**Core Module Functions**:
```powershell
# In Core/ConversationsExtended.psm1
function Search-GcConversations {
  # Already implemented ✅
}

function Get-GcConversationById {
  # Already implemented ✅
}
```

**Query Body Example**:
```json
{
  "interval": "2024-01-15T00:00:00Z/2024-01-15T23:59:59Z",
  "order": "desc",
  "orderBy": "conversationStart",
  "paging": {
    "pageSize": 100,
    "pageNumber": 1
  },
  "segmentFilters": [
    {
      "type": "and",
      "predicates": [
        { "dimension": "queueId", "value": "queue-id" }
      ]
    }
  ]
}
```

**Implementation Steps**:
1. Create `New-ConversationLookupView` function with search form layout
2. Build dynamic query body from filter selections
3. Wire "Search" button to `Search-GcConversations` via `Start-AppJob`
4. Display results in DataGrid with sortable columns
5. Add "Open Timeline" button that calls `New-ConversationTimelineView` with selected conversation ID
6. Implement export handlers (JSON/CSV)
7. Add pagination support for large result sets

**Estimated Effort**: 6-8 hours

---

### 2. Conversation Timeline Module ✅ Fully Implemented

**Status**: Complete and functional

**Current Implementation**:
- `New-ConversationTimelineView` function exists in main app
- `Core/Timeline.psm1` module provides timeline reconstruction
- Features:
  - Fetch conversation details via Analytics API
  - Normalize events into unified timeline
  - Display sortable timeline events (Time/Category/Label)
  - JSON details pane for selected event
  - Export to JSON and Markdown
  - Integration with subscription events

**No further action required** ✅

---

### 3. Media & Quality Module 🔴 Not Implemented

**Priority**: Medium - Useful for quality assurance and compliance

**Purpose**: View recordings, screen recordings, transcripts, and quality evaluations

**View Requirements**:
```powershell
function New-MediaQualityView {
  # UI Components:
  # - Tabs: Recordings, Transcripts, Quality Evaluations
  # - Recording filters: Date range, Queue, Media type
  # - Display: Recording ID, Conversation ID, Duration, Created Date, Media Type
  # - Actions: Load, Download Recording, View Transcript, Export
  # - Quality Evaluations: Evaluation Form, Evaluator, Score, Status
}
```

**API Endpoints**:
- `GET /api/v2/recording/recordings` - List recordings
- `GET /api/v2/conversations/{conversationId}/recordings` - Get conversation recordings
- `GET /api/v2/recording/recordings/{recordingId}` - Get recording details
- `GET /api/v2/recording/recordings/{recordingId}/media` - Download recording
- `POST /api/v2/quality/conversations/{conversationId}/evaluations/query` - Query evaluations
- `GET /api/v2/quality/evaluations/{evaluationId}` - Get evaluation details

**Core Module Functions Needed**:
```powershell
# In Core/ConversationsExtended.psm1
function Get-GcRecordings {
  # Already implemented ✅
}

function Get-GcRecordingMedia {
  param($RecordingId, $AccessToken, $InstanceName)
  # Download recording media file
  # Returns: Media URL or file content
}

function Get-GcQualityEvaluations {
  # Already implemented ✅
}

function Get-GcConversationTranscript {
  param($ConversationId, $AccessToken, $InstanceName)
  # Fetch transcript from conversation
  # Parse and format transcript text
}
```

**Data Model**:
```json
{
  "recording": {
    "id": "recording-id",
    "conversationId": "conversation-id",
    "name": "Recording Name",
    "duration": 320000,
    "mediaUri": "https://...",
    "mediaType": "audio/mpeg",
    "dateCreated": "2024-01-15T10:30:00Z"
  },
  "evaluation": {
    "id": "evaluation-id",
    "conversationId": "conversation-id",
    "evaluationForm": { "name": "Call Quality Form" },
    "evaluator": { "name": "John Manager" },
    "agent": { "name": "Jane Agent" },
    "score": 85,
    "status": "FINISHED"
  }
}
```

**Implementation Steps**:
1. Add `Get-GcRecordingMedia` and `Get-GcConversationTranscript` to `Core/ConversationsExtended.psm1`
2. Create `New-MediaQualityView` with tabbed layout
3. Implement "Recordings" tab with load/export functionality
4. Add "Download Recording" button handler
5. Implement "Transcripts" tab with text display
6. Implement "Quality Evaluations" tab with evaluation details
7. Add export functionality for all tabs

**Estimated Effort**: 8-10 hours

---

### 4. Abandon & Experience Module 🔴 Not Implemented

**Priority**: Medium - Insights into customer experience and abandonment patterns

**Purpose**: Analyze conversation metrics related to abandonment, wait times, and customer experience

**View Requirements**:
```powershell
function New-AbandonExperienceView {
  # UI Components:
  # - Date range picker
  # - Metrics dashboard: Abandonment rate, Average wait time, Average handle time
  # - Charts: Abandonment trends, Wait time distribution (requires charting library)
  # - Results grid: Conversation ID, Queue, Wait Time, Outcome (abandoned/handled)
  # - Actions: Query, Export metrics to JSON/CSV
}
```

**API Endpoints**:
- `POST /api/v2/analytics/conversations/aggregates/query` - Aggregated conversation metrics
- `POST /api/v2/analytics/conversations/details/query` - Detailed conversation data

**Query Example (Aggregates)**:
```json
{
  "interval": "2024-01-15T00:00:00Z/2024-01-15T23:59:59Z",
  "groupBy": ["queueId"],
  "metrics": ["nOffered", "nHandled", "nAbandon", "tWait", "tHandle"],
  "filter": {
    "type": "and",
    "predicates": [
      { "dimension": "mediaType", "value": "voice" }
    ]
  }
}
```

**Core Module Functions Needed**:
```powershell
# In Core/ConversationsExtended.psm1 or new Core/Analytics.psm1
function Get-GcAbandonmentMetrics {
  param($StartTime, $EndTime, $AccessToken, $InstanceName)
  # Query abandonment metrics using aggregates API
  # Calculate: Abandonment rate, Average wait time, Average handle time
}

function Search-GcAbandonedConversations {
  param($StartTime, $EndTime, $AccessToken, $InstanceName)
  # Query conversations with abandoned outcome
  # Return detailed list of abandoned conversations
}
```

**Data Model**:
```json
{
  "metrics": {
    "abandonmentRate": 0.15,
    "totalOffered": 1000,
    "totalAbandoned": 150,
    "avgWaitTime": 45,
    "avgHandleTime": 320
  },
  "conversations": [
    {
      "conversationId": "conv-id",
      "queueName": "Customer Service",
      "waitTime": 120,
      "outcome": "abandoned",
      "timestamp": "2024-01-15T10:30:00Z"
    }
  ]
}
```

**Implementation Steps**:
1. Create `Core/Analytics.psm1` module for analytics aggregates
2. Add `Get-GcAbandonmentMetrics` and `Search-GcAbandonedConversations` functions
3. Create `New-AbandonExperienceView` with metrics dashboard layout
4. Implement metrics calculation and display
5. Add results grid with abandoned conversations
6. Implement export functionality

**Estimated Effort**: 6-8 hours

**Note**: Charting functionality (trends, distribution) is optional and requires additional UI library (e.g., LiveCharts, OxyPlot).

---

### 5. Analytics Jobs Module ✅ Fully Implemented

**Priority**: High - Essential for long-running analytics queries

**Status**: Complete - view implemented with job submission, monitoring, and export

**Implemented Features**:
- Job submission form with date range selection
- Job polling and status tracking (queued/running/completed/failed)
- View job results in dialog
- Export job results to JSON
- Background execution via Start-AppJob
- Integration with Core/Jobs.psm1 functions

---

### 6. Incident Packet Module ✅ Fully Implemented

**Priority**: High - Critical for incident investigation and support

**Status**: Complete - standalone view implemented with packet generation and history tracking

**Implemented Features**:
- Standalone `New-IncidentPacketView` module
- Conversation ID input with validation
- ZIP archive creation option
- Packet history grid showing recent exports
- File count and size tracking
- Integration with Core/ArtifactGenerator.psm1
- Background execution via Start-AppJob

**Core Implementation**:
- `Core/ArtifactGenerator.psm1` module exists with `Export-GcConversationPacket` function
- Integrated into Conversation Timeline view with "Export Packet" button
- Generates comprehensive incident packets:
  - `conversation.json` - Raw API response
  - `timeline.json` - Normalized timeline events
  - `events.ndjson` - Subscription events
  - `transcript.txt` - Conversation transcript
  - `agent_assist.json` - Agent Assist data
  - `summary.md` - Human-readable summary
  - ZIP archive

---

## Testing Strategy

### Unit Tests

Create `tests/test-conversations.ps1`:

```powershell
# Test Core/ConversationsExtended.psm1 functions
Describe "Conversations Module Tests" {
  Context "Search-GcConversations" {
    It "Should build correct query body" {
      # Test query construction
      # Test pagination
    }
  }
  
  Context "Get-GcRecordings" {
    It "Should retrieve recordings" {
      # Mock API response
      # Test filtering
    }
  }
  
  Context "Get-GcQualityEvaluations" {
    It "Should retrieve evaluations" {
      # Test API call
    }
  }
}
```

### Integration Tests

Manual testing checklist:

- [x] Search conversations by date range and queue
- [x] Export conversation search results to JSON/CSV
- [x] Open timeline from search results
- [ ] Load recordings and verify grid population
- [ ] Download recording media file
- [ ] View conversation transcript
- [ ] Load quality evaluations
- [ ] Query abandonment metrics
- [x] Submit analytics job and monitor progress
- [x] View and export analytics job results
- [ ] Generate incident packet for conversation
- [ ] Verify packet contents (all files present)

---

## API Permissions Required

Ensure OAuth client has the following scopes:

- `conversations` - Read conversation data
- `analytics` - Query analytics and submit jobs
- `recording` - Read and download recordings
- `quality` - Read quality evaluations

---

## Future Enhancements

### Phase 2 Enhancements

1. **Advanced Search**
   - Save search filters as presets
   - Search by custom attributes
   - Regex pattern matching

2. **Real-Time Monitoring**
   - Live conversation feed
   - Active conversation dashboard
   - Alerts for specific conversation patterns

3. **Bulk Operations**
   - Bulk export conversations
   - Batch incident packet generation
   - Scheduled analytics jobs

4. **Enhanced Media & Quality**
   - In-app audio player for recordings
   - Transcript search and highlight
   - Quality evaluation editor (if permissions allow)

5. **Analytics Dashboard**
   - Interactive charts and graphs
   - Customizable metrics dashboards
   - Comparative analysis (day-over-day, week-over-week)

---

## Dependencies

### Core Modules
- `Core/ConversationsExtended.psm1` - ✅ Created
- `Core/Timeline.psm1` - ✅ Exists
- `Core/ArtifactGenerator.psm1` - ✅ Exists
- `Core/Jobs.psm1` - ✅ Exists
- `Core/HttpRequests.psm1` - ✅ Exists
- `Core/JobRunner.psm1` - ✅ Exists
- `Core/Analytics.psm1` - 🔴 Needs creation (for aggregates)

### UI Components
- WPF DataGrid for list views
- DatePicker for date range selection
- ComboBox for filters
- Button handlers for actions
- TabControl for multi-section views

---

## References

- [Genesys Cloud Conversations API](https://developer.genesys.cloud/commdigital/digital/conversations-apis)
- [Analytics API - Conversation Details](https://developer.genesys.cloud/analyticsdatamanagement/analytics/detail/conversation-detail-job)
- [Recording API](https://developer.genesys.cloud/recordingandquality/recording/)
- [Quality API](https://developer.genesys.cloud/recordingandquality/quality/)

---

## Summary

**Current State**:
- ✅ Conversation Timeline fully implemented and functional
- ✅ Conversation Lookup fully implemented with search and export
- ✅ Analytics Jobs fully implemented with submission and monitoring
- ✅ Incident Packet fully implemented with standalone view
- ✅ Core module functions exist for lookup, media, quality
- ✅ Core/Jobs.psm1 module complete
- 🔴 View functions not yet created for: Media & Quality, Abandon & Experience

**Completed in v0.5.0**:
1. ✅ `New-ConversationLookupView` - Search with date range, filters, export, navigation
2. ✅ `New-AnalyticsJobsView` - Job submission, monitoring, export results
3. ✅ `New-IncidentPacketView` - Standalone packet generation with history

**Remaining Work**:
1. Implement `New-MediaQualityView` (8-10 hours)
2. Implement `New-AbandonExperienceView` (6-8 hours)
3. Add view mappings to switch statement in main app (if needed)
4. Test end-to-end functionality
5. Create unit tests

**Total Remaining Effort**: 14-18 hours

---

**Status**: Roadmap 67% complete (4 of 6 modules implemented).
