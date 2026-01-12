# Export Packet Implementation Summary

## Overview

The "Export Packet" feature has been fully implemented as a real artifact generator that creates comprehensive incident packets for conversations. The implementation follows all requirements from the problem statement.

## Requirements Met

### ✅ 1. Determine conversationId
- **From textbox**: Both views (Conversation Timeline and Topic Subscriptions) check the conversation ID textbox first
- **From selected event**: Topic Subscriptions view can infer conversationId from selected event (though textbox takes priority)
- Implementation matches "Prompt 6" pattern (line 1661-1691 in main app)

### ✅ 2. Create packet folder
- Folder structure: `./artifacts/<timestamp>_<conversationId>/`
- Example: `./artifacts/20260112-140054_c-test-12345/`
- Timestamp format: `yyyyMMdd-HHmmss`

### ✅ 3. Write required files

#### conversation.json
- Raw conversation details from Analytics API
- Full conversation data with participants, segments, metrics
- JSON format with 20-level depth

#### timeline.json
- Normalized timeline list
- Includes segments, media stats, and correlated subscription events
- Structured timeline events with Time, Category, Label, Details, and CorrelationKeys

#### events.ndjson
- Buffered structured events filtered for the specific conversation
- NDJSON format (one JSON object per line)
- Includes all subscription events (transcription, agent assist, errors)

#### transcript.txt
- Best-effort extraction of transcript content
- Filters events by transcription topic patterns
- Sorted by timestamp
- Speaker detection from topic names (Customer/Agent/Participant)
- Formatted with timestamps: `[HH:mm:ss.fff] Speaker:`

#### summary.md
- Auto-generated brief with:
  - **Time range**: Start/end times and duration calculation
  - **Key errors**: Top 10 errors with timestamps
  - **Participants count**: From conversation data
  - **Quality notes**: Transcription event counts (partial vs final)
  - **Severity analysis**: Event counts by severity level
  - **Files included**: List of all files in the packet

### ✅ 4. ZIP archive
- Filename: `IncidentPacket_<conversationId>_<timestamp>.zip`
- Example: `IncidentPacket_c-test-12345_20260112-140054.zip`
- Created using `System.IO.Compression.ZipFile.CreateFromDirectory`

### ✅ 5. Register in Artifacts backstage
- Artifacts automatically added via `Add-ArtifactAndNotify` function
- Shows snackbar notification with "Open" and "Folder" actions
- Registered in `$script:AppState.Artifacts` collection
- Visible in Backstage → Artifacts tab

## Constraints Met

### ✅ Built-in compression with graceful fallback
- Uses `System.IO.Compression.FileSystem` assembly
- Checks availability before attempting ZIP creation
- If compression unavailable, continues without ZIP (packet folder still created)
- Warning logged if ZIP creation fails

### ✅ Windows-safe filenames
- Sanitizes conversationId by replacing invalid characters: `[<>:"/\\|?*]` → `_`
- Example: `c-12345:test/bad\chars` → `c-12345_test_bad_chars`
- Ensures folder and ZIP file names are Windows-compatible

## Implementation Details

### Core/ArtifactGenerator.psm1

**Functions:**
1. `New-GcIncidentPacket` - Creates packet folder and all artifact files
2. `Export-GcConversationPacket` - High-level export function that:
   - Queries Analytics API for conversation data (POST /api/v2/analytics/conversations/details/jobs)
   - Polls for job completion (same pattern as timeline job)
   - Retrieves results (GET /api/v2/analytics/conversations/details/jobs/{id}/results)
   - Filters subscription events by conversationId
   - Builds timeline using `ConvertTo-GcTimeline`
   - Creates packet using `New-GcIncidentPacket`

**Key Features:**
- Conversation ID filtering: All subscription event processing filters by conversationId
- Array safety: All Where-Object operations wrapped in `@()` to ensure array types
- DateTime handling: Supports both DateTime objects and string timestamps
- Error resilience: Try/catch blocks with detailed error messages
- Progress logging: Write-Output statements for job progress tracking

### App/GenesysCloudTool_UX_Prototype_v2_1.ps1

**Integration Points:**

1. **Conversation Timeline view** (line 1194-1272)
   - "Export Packet" button
   - Uses conversationId from textbox
   - Falls back to mock export if not authenticated

2. **Topic Subscriptions view** (line 1734-1815)
   - "Export Packet" button
   - Uses conversationId from textbox or generates random ID
   - Falls back to mock export if not authenticated

**Job Execution:**
- Uses `Start-AppJob` for background execution
- Imports `ArtifactGenerator.psm1` in runspace context
- Passes all required parameters: conversationId, region, accessToken, artifactsDir, eventBuffer
- `OnCompleted` callback registers artifact and shows notification

## Testing

### tests/test-artifact-generator.ps1

**Test Coverage:**
1. Windows-safe filename generation
2. Mock packet creation with conversation data, timeline, and subscription events
3. Folder structure verification
4. Required files presence check
5. ZIP archive creation and naming validation
6. Summary.md content validation (conversation ID, time range, errors, quality notes, files list)
7. Transcript.txt content validation
8. Events.ndjson format validation (NDJSON with valid JSON per line)

**Results:**
- All tests passing
- Validates folder naming: `<timestamp>_<conversationId>`
- Validates ZIP naming: `IncidentPacket_<conversationId>_<timestamp>.zip`
- Verifies all required files are created
- Confirms proper event filtering by conversationId

### tests/smoke.ps1
- All 10 smoke tests passing
- Module loads correctly
- No regressions

## Usage Examples

### From UI (Authenticated)
1. Navigate to Operations → Topic Subscriptions
2. Enter or select a conversation ID
3. Click "Export Packet"
4. Background job retrieves conversation data from Analytics API
5. Packet created in `./artifacts/` directory
6. Snackbar notification appears with "Open" and "Folder" actions
7. Artifact registered in Backstage → Artifacts tab

### From UI (Mock Mode - No Authentication)
1. Same steps as above
2. Mock packet created instead of real data
3. Mock file created: `incident-packet-mock-<conversationId>-<timestamp>.txt`

### Programmatic Usage
```powershell
# Export conversation packet
$packet = Export-GcConversationPacket `
  -ConversationId 'c-12345' `
  -Region 'mypurecloud.com' `
  -AccessToken $token `
  -OutputDirectory './artifacts' `
  -SubscriptionEvents $events `
  -CreateZip

# Result object contains:
# - PacketName: folder name
# - PacketDirectory: full path to folder
# - Files: hashtable of file paths
# - ZipPath: full path to ZIP (if created)
# - ConversationId: conversation ID
# - Timestamp: generation timestamp
# - Created: DateTime of creation
```

## Files Changed

1. **Core/ArtifactGenerator.psm1** (566 lines changed)
   - Complete implementation of packet generation
   - Analytics API integration
   - Event filtering and processing

2. **App/GenesysCloudTool_UX_Prototype_v2_1.ps1** (10 lines added)
   - Module import statements in scriptblocks

3. **tests/test-artifact-generator.ps1** (new file, 268 lines)
   - Comprehensive test suite

## Deliverables Status

- ✅ Working export + artifacts list update
- ✅ Real Analytics API integration
- ✅ Comprehensive file generation (5 required files + optional agent_assist.json)
- ✅ ZIP archive support with graceful fallback
- ✅ Windows-safe filename handling
- ✅ Conversation ID determination from textbox or selected event
- ✅ Automatic artifact registration in backstage
- ✅ Test coverage

## Next Steps (Optional Enhancements)

1. Add export progress indicator in UI
2. Support bulk export (multiple conversations)
3. Add export history view
4. Support custom date ranges for Analytics queries
5. Add export templates (minimal, standard, verbose)
6. Support export to cloud storage (S3, Azure Blob)
