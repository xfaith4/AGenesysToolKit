# Timeline Feature Documentation

## Overview

The Timeline feature provides a comprehensive view of conversation events retrieved from the Genesys Cloud Analytics API. It displays events in a sortable grid with detailed JSON views and supports correlation of live subscription events.

## Features

### Timeline Window

- **Sortable DataGrid**: Click column headers to sort by Time, Category, or Label
- **Detail Pane**: Select any event to view its full JSON representation including:
  - Time (ISO 8601 format)
  - Category
  - Label
  - Correlation Keys (conversationId, participantId, sessionId, etc.)
  - Full details object

### Event Categories

The timeline supports the following event categories:

- **Segment**: Participant sessions, queue entries, agent connections
- **MediaStats**: Media quality metrics, MOS scores, jitter, packet loss
- **Error**: Disconnect codes, errors, failures
- **AgentAssist**: Agent assist suggestions and knowledge articles
- **Transcription**: Speech-to-text transcription events
- **System**: Conversation lifecycle events (start, end)
- **Quality**: Quality monitoring and evaluation events
- **Live Events**: Real-time subscription events (if available)

### Live Event Correlation

When subscription events are buffered (from Topic Subscriptions monitoring), the timeline automatically correlates and includes events that match the conversation ID. These appear in the "Live Events" category.

## Usage

### From Topic Subscriptions

1. Navigate to **Operations → Topic Subscriptions**
2. Optionally enter a conversation ID in the textbox, or start streaming and select an event
3. Click **"Open Timeline"** button
4. Wait for the background job to complete (status shown in status bar)
5. Timeline window opens with retrieved events

### From Conversation Timeline Module

1. Navigate to **Conversations → Conversation Timeline**
2. Enter a conversation ID in the textbox
3. Click **"Build Timeline"** button
4. Wait for the background job to complete
5. Timeline window opens with retrieved events

## Background Job Flow

The timeline retrieval follows a non-blocking job pattern to ensure the UI remains responsive:

1. **Validation**: Check for conversation ID and authentication
2. **Job Submission**: Submit analytics conversation details job to Genesys Cloud API
3. **Polling**: Poll job status until completion (max 2 minutes)
4. **Results Fetch**: Retrieve conversation details from completed job
5. **Normalization**: Convert raw analytics data to timeline events using `ConvertTo-GcTimeline`
6. **Correlation**: Filter and merge subscription events with matching conversation ID
7. **Display**: Open timeline window with sorted events

## Technical Details

### API Endpoints Used

- `POST /api/v2/analytics/conversations/details/jobs` - Submit analytics job
- `GET /api/v2/analytics/conversations/details/jobs/{jobId}` - Poll job status
- `GET /api/v2/analytics/conversations/details/jobs/{jobId}/results` - Fetch results

### Timeline Event Structure

Each timeline event contains:

```json
{
  "Time": "2024-01-15T13:20:01.123Z",
  "Category": "Segment",
  "Label": "Participant Joined: Customer",
  "Details": {
    "participantId": "p-12345",
    "purpose": "customer",
    "sessions": [...]
  },
  "CorrelationKeys": {
    "conversationId": "c-abcdef123456",
    "participantId": "p-12345"
  }
}
```

### Module Functions

#### `Show-TimelineWindow`

Opens a new WPF window displaying timeline events.

**Parameters:**
- `ConversationId` (string, required): Conversation ID to display
- `TimelineEvents` (object[], required): Array of timeline event objects
- `SubscriptionEvents` (object[], optional): Array of subscription events for reference

#### `New-GcTimelineEvent`

Creates a timeline event object (from Core/Timeline.psm1).

**Parameters:**
- `Time` (datetime, required): Event timestamp
- `Category` (string, required): Event category (Segment, MediaStats, Error, etc.)
- `Label` (string, required): Human-readable label
- `Details` (object, optional): Detailed information object
- `CorrelationKeys` (hashtable, optional): Correlation identifiers

#### `ConvertTo-GcTimeline`

Converts raw conversation data to unified timeline events (from Core/Timeline.psm1).

**Parameters:**
- `ConversationData` (object, required): Raw conversation data from API
- `AnalyticsData` (object, optional): Analytics data for enrichment
- `SubscriptionEvents` (object[], optional): Subscription events to correlate

## Error Handling

### No Authentication
If the user is not logged in, a message box prompts authentication before proceeding.

### No Conversation ID
If no conversation ID is provided or can be inferred, a warning message is displayed.

### Job Failure
If the analytics job fails or times out:
- Error is logged to job logs (visible in Backstage → Jobs)
- Error message box is displayed
- Status bar shows failure message

### No Data Found
If the conversation ID is not found in the analytics system:
- Error is logged with message "No conversation data found for ID: {id}"
- Error message box is displayed

## Performance Considerations

- **Non-Blocking**: All API calls and data processing occur in background runspace
- **UI Responsiveness**: Main UI thread never blocks during retrieval
- **Timeout**: Jobs timeout after 2 minutes (120 seconds)
- **Correlation Efficiency**: Subscription events are filtered in-memory before correlation

## Testing

Run timeline tests to verify functionality:

```powershell
# From repository root
./tests/test-timeline.ps1
```

Expected output: **8 tests passed**

Tests cover:
- Timeline module loading
- Event creation with all categories
- Timeline conversion with mock data
- Subscription event correlation
- Timeline sorting
- CorrelationKeys preservation

## Future Enhancements

Potential improvements for the timeline feature:

- [ ] Export timeline to CSV/Excel
- [ ] Filter timeline by category or time range
- [ ] Search/highlight events by text
- [ ] Visual timeline graph view
- [ ] Auto-refresh for active conversations
- [ ] Export timeline as shareable report

## Troubleshooting

### Timeline window doesn't open

**Cause**: Job failed or returned no data

**Solution**: 
1. Check job logs in Backstage → Jobs
2. Verify conversation ID exists and is recent (within data retention)
3. Verify OAuth token has analytics scope

### Missing subscription events

**Cause**: Events not buffered or conversation ID mismatch

**Solution**:
1. Ensure subscription streaming was active during conversation
2. Verify conversation ID matches exactly
3. Check EventBuffer count in AppState

### Empty timeline

**Cause**: Conversation has no segments or participants yet

**Solution**:
1. Wait for conversation to complete or progress further
2. Check if conversation is very recent (analytics lag ~30 seconds)
3. Try a different, completed conversation ID

## See Also

- [Core/Timeline.psm1](../Core/Timeline.psm1) - Timeline module implementation
- [Core/Jobs.psm1](../Core/Jobs.psm1) - Analytics job pattern functions
- [HOW_TO_TEST_JOBRUNNER.md](HOW_TO_TEST_JOBRUNNER.md) - Job runner testing guide
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture overview
