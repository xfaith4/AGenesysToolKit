# Conversations Modules - Implementation Roadmap

This document outlines the implementation plan for the Conversations workspace modules that are currently placeholders.

## Overview

The Conversations workspace provides deep analysis of conversation data, including lookup, timeline reconstruction, media/quality analysis, and comprehensive incident packet generation.

## Module Status

| Module | Status | Priority |
|--------|--------|----------|
| Conversation Lookup | 🔴 Not Implemented | High |
| Conversation Timeline | ✅ Fully Implemented | N/A |
| Media & Quality | 🔴 Not Implemented | Medium |
| Abandon & Experience | 🔴 Not Implemented | Medium |
| Analytics Jobs | 🔴 Not Implemented | High |
| Incident Packet | 🟡 Partially Implemented | High |

## Implementation Plan

### 1. Conversation Lookup Module 🔴 Not Implemented

**Priority**: High - Essential for finding and analyzing conversations

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

### 5. Analytics Jobs Module 🔴 Not Implemented

**Priority**: High - Essential for long-running analytics queries

**Purpose**: Manage and monitor analytics jobs (conversation details, user details, aggregates)

**View Requirements**:
```powershell
function New-AnalyticsJobsView {
  # UI Components:
  # - Job submission form: Job type, Date range, Filters
  # - Active jobs grid: Job ID, Type, Status, Progress, Submitted Time
  # - Completed jobs grid: Job ID, Type, Status, Result count, Completed Time
  # - Actions: Submit Job, View Results, Cancel Job, Export Results
  # - Auto-refresh every 5 seconds
}
```

**API Endpoints**:
- `POST /api/v2/analytics/conversations/details/jobs` - Submit conversation details job
- `GET /api/v2/analytics/conversations/details/jobs/{jobId}` - Get job status
- `GET /api/v2/analytics/conversations/details/jobs/{jobId}/results` - Get job results
- `DELETE /api/v2/analytics/conversations/details/jobs/{jobId}` - Cancel job

**Core Module Functions**:
```powershell
# In Core/Jobs.psm1 (already exists)
function Start-GcAnalyticsConversationDetailsJob {
  # Already implemented ✅
}

function Get-GcAnalyticsConversationDetailsJobStatus {
  # Already implemented ✅
}

function Get-GcAnalyticsConversationDetailsJobResults {
  # Already implemented ✅
}

function Stop-GcAnalyticsConversationDetailsJob {
  # Already implemented ✅
}

function Invoke-GcAnalyticsConversationDetailsQuery {
  # Already implemented ✅ (one-call helper)
}
```

**Implementation Steps**:
1. Create `New-AnalyticsJobsView` with job submission form
2. Implement "Submit Job" button handler using `Start-GcAnalyticsConversationDetailsJob`
3. Add timer for auto-refresh (poll job status every 5 seconds)
4. Display active jobs with status indicators (queued/running/completed/failed)
5. Implement "View Results" button that fetches and displays job results
6. Add "Cancel Job" button handler using `Stop-GcAnalyticsConversationDetailsJob`
7. Implement export functionality for completed job results

**Estimated Effort**: 4-6 hours

**Note**: Core functions already exist, only view implementation needed!

---

### 6. Incident Packet Module 🟡 Partially Implemented

**Priority**: High - Critical for incident investigation and support

**Current Implementation**:
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

**View Requirements** (Standalone Module):
```powershell
function New-IncidentPacketView {
  # UI Components:
  # - Input: Conversation ID or search for conversation
  # - Packet configuration: Include recordings, Include quality evaluations, Include agent assist
  # - Generate button
  # - Recent packets grid: Conversation ID, Generated Time, Size, Actions
  # - Actions: Generate Packet, Open Folder, Delete Packet
}
```

**Implementation Steps**:
1. Create `New-IncidentPacketView` standalone view
2. Add conversation ID input with validation
3. Implement "Generate Packet" button using `Export-GcConversationPacket`
4. Add optional components checkboxes (recordings, evaluations, etc.)
5. Display recent packets from `artifacts/` directory
6. Add "Open Folder" and "Delete Packet" actions

**Estimated Effort**: 3-4 hours

**Note**: Core functionality already exists! Only standalone view needed.

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

- [ ] Search conversations by date range and queue
- [ ] Export conversation search results to JSON/CSV
- [ ] Open timeline from search results
- [ ] Load recordings and verify grid population
- [ ] Download recording media file
- [ ] View conversation transcript
- [ ] Load quality evaluations
- [ ] Query abandonment metrics
- [ ] Submit analytics job and monitor progress
- [ ] View and export analytics job results
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
- ✅ Core module functions exist for lookup, media, quality
- ✅ Incident Packet core functionality complete
- ✅ Analytics Jobs core functions exist in `Core/Jobs.psm1`
- 🔴 View functions not yet created for: Lookup, Media & Quality, Abandon & Experience, Analytics Jobs
- 🟡 Incident Packet needs standalone view

**Next Steps**:
1. Implement `New-ConversationLookupView` (6-8 hours) - **HIGH PRIORITY**
2. Implement `New-AnalyticsJobsView` (4-6 hours) - **HIGH PRIORITY**
3. Implement `New-IncidentPacketView` (3-4 hours) - **HIGH PRIORITY**
4. Implement `New-MediaQualityView` (8-10 hours)
5. Implement `New-AbandonExperienceView` (6-8 hours)
6. Add view mappings to switch statement in main app
7. Test end-to-end functionality
8. Create unit tests

**Total Estimated Effort**: 27-36 hours

---

**Status**: Roadmap complete. Ready for implementation.
