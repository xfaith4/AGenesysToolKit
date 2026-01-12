# AGenesysToolKit

A professional toolkit for Genesys Cloud platform operations, analytics, and administration.

## Overview

AGenesysToolKit provides decision-grade insights from Genesys Cloud APIs, logs, and telemetry. Built with UX-first principles and real backend integration, it empowers engineers, operations teams, and contact center analysts with:

- **Real OAuth Authentication**: PKCE-based OAuth flow for secure authentication
- **Background Job Runner**: Long-running operations never block the UI
- **Real-Time Subscriptions**: WebSocket-based event streaming (core infrastructure ready)
- **Conversation Timeline Reconstruction**: Fetch and normalize conversation data
- **Incident Packet Generator**: Export comprehensive conversation packets (JSON, NDJSON, ZIP)
- **Complete pagination by default**: Engineers get full datasets unless explicitly capped
- **Centralized HTTP primitives**: Consistent error handling, retry logic, and rate limiting

## Quick Start

### Prerequisites

- PowerShell 5.1 or PowerShell 7+
- Windows (for WPF UI components)
- Genesys Cloud OAuth client credentials

### Configuration

Before running the application, you need to configure OAuth credentials. See [CONFIGURATION.md](docs/CONFIGURATION.md) for detailed setup instructions.

Quick summary:
1. Create an OAuth client in Genesys Cloud (Admin → Integrations → OAuth)
2. Edit `App/GenesysCloudTool_UX_Prototype_v2_1.ps1` and update the `Set-GcAuthConfig` section with your Client ID
3. Launch the application

### Running Smoke Tests

Verify the installation and core module loading:

```powershell
# From repository root
./tests/smoke.ps1
```

### Launching the Application

```powershell
# From repository root
./App/GenesysCloudTool_UX_Prototype_v2_1.ps1
```

## Money Path Flow: End-to-End

The tool implements the complete "money path" for incident investigation:

1. **Login** → Click "Login…" button, authenticate via OAuth
2. **Navigate** to Conversations → Conversation Timeline
3. **Enter Conversation ID**
4. **Export Packet** → Generates comprehensive incident packet with:
   - `conversation.json` - Raw API response
   - `timeline.json` - Normalized timeline events
   - `events.ndjson` - Subscription events
   - `transcript.txt` - Conversation transcript
   - `summary.md` - Human-readable summary
   - ZIP archive

Exported packets are saved to `artifacts/` directory and accessible via the Artifacts backstage.

## Project Structure

```
/Core              # Reusable PowerShell modules
  HttpRequests.psm1   # HTTP primitives (Invoke-GcRequest, Invoke-GcPagedRequest)
  Jobs.psm1           # Analytics job pattern functions
  Auth.psm1           # OAuth authentication (PKCE flow)
  JobRunner.psm1      # Background job execution (runspaces)
  Subscriptions.psm1  # WebSocket subscription provider
  Timeline.psm1       # Conversation timeline reconstruction
  ArtifactGenerator.psm1  # Incident packet generator

/App               # Application entry points
  GenesysCloudTool_UX_Prototype_v2_1.ps1   # WPF UI application

/docs              # Documentation
  ARCHITECTURE.md    # Core contracts, pagination policy, workspaces
  CONFIGURATION.md   # Setup guide for OAuth and configuration
  ROADMAP.md         # Phased development plan
  STYLE.md           # Coding conventions and best practices

/tests             # Test scripts
  smoke.ps1          # Smoke tests for module loading

/artifacts         # Runtime output (gitignored)
```

## Core Contracts

### Authentication

**OAuth with PKCE**: Secure authentication flow

```powershell
# Configure OAuth
Set-GcAuthConfig -ClientId 'your-client-id' -Region 'mypurecloud.com'

# Authenticate
$token = Get-GcTokenAsync -TimeoutSeconds 300

# Test token
$userInfo = Test-GcToken
```

### `Invoke-GcRequest`

Single HTTP request to Genesys Cloud API (no pagination).

```powershell
$user = Invoke-GcRequest -Path '/api/v2/users/me' -Method GET -AccessToken $token
```

### `Invoke-GcPagedRequest`

Automatically paginate through API responses until completion (default behavior).

```powershell
# Get ALL users (may be thousands)
$allUsers = Invoke-GcPagedRequest -Path '/api/v2/users' -Method GET -AccessToken $token

# Get first 500 users only
$limitedUsers = Invoke-GcPagedRequest -Path '/api/v2/users' -Method GET -AccessToken $token -MaxItems 500
```

### Job Pattern

Long-running operations follow Submit → Poll → Fetch pattern:

```powershell
# Helper pattern (recommended)
$results = Invoke-GcAnalyticsConversationDetailsQuery -Body $queryBody -TimeoutSeconds 600

# Manual pattern
$job = Start-GcAnalyticsConversationDetailsJob -Body $queryBody
Wait-GcAsyncJob -StatusPath '/api/v2/analytics/conversations/details/jobs/{0}' -JobId $job.id
$results = Get-GcAnalyticsConversationDetailsJobResults -JobId $job.id
```

### Background Job Runner

UI jobs run in PowerShell runspaces (off UI thread):

```powershell
# Create job context
$job = New-GcJobContext -Name "Export Packet" -Type "Export"

# Start background job
Start-GcJob -Job $job -ScriptBlock {
  param($conversationId)
  # Long-running work here
  Export-GcConversationPacket -ConversationId $conversationId
} -ArgumentList @($convId) -OnComplete {
  param($job)
  Write-Host "Job completed: $($job.Result)"
}
```

### Conversation Timeline

Fetch and normalize conversation data:

```powershell
# Get conversation details
$conversation = Get-GcConversationDetails -ConversationId $convId -Region $region -AccessToken $token

# Build unified timeline
$timeline = ConvertTo-GcTimeline -ConversationData $conversation

# Export timeline
Export-GcTimelineToJson -Timeline $timeline -Path "timeline.json"
```

### Incident Packet Generation

Generate comprehensive incident packets:

```powershell
# Export conversation packet with all artifacts
$packet = Export-GcConversationPacket `
  -ConversationId $convId `
  -Region $region `
  -AccessToken $token `
  -OutputDirectory "./artifacts" `
  -SubscriptionEvents $events `
  -CreateZip

# Packet includes:
# - conversation.json (raw API response)
# - timeline.json (normalized events)
# - events.ndjson (subscription events)
# - transcript.txt (conversation transcript)
# - agent_assist.json (Agent Assist data)
# - summary.md (human-readable summary)
# - ZIP archive
```

## Development Status

**Current Phase: Money Path Implementation Complete ✅**

- [x] Repository structure established
- [x] Core HTTP primitives implemented
- [x] Job pattern implemented (analytics)
- [x] **OAuth authentication with PKCE**
- [x] **Background job runner (runspaces)**
- [x] **WebSocket subscription provider**
- [x] **Conversation timeline reconstruction**
- [x] **Incident packet generator (ZIP archives)**
- [x] **Real Export Packet flow (end-to-end)**
- [x] Documentation complete
- [x] Smoke tests passing (10/10)
- [x] WPF UI integrated with real backend

**Next Phase: Subscription Engine Integration**

- [ ] Wire real-time WebSocket subscriptions into UI
- [ ] Replace mock event streaming with live events
- [ ] Implement structured event storage and filtering

See [docs/ROADMAP.md](docs/ROADMAP.md) for detailed phased development plan.

## Documentation

- [**ARCHITECTURE.md**](docs/ARCHITECTURE.md) - Core contracts, pagination policy, and workspace definitions
- [**ROADMAP.md**](docs/ROADMAP.md) - Phased development plan and version history
- [**STYLE.md**](docs/STYLE.md) - Coding conventions, naming patterns, and best practices

## Contributing

Contributions are welcome! Please follow the conventions outlined in [docs/STYLE.md](docs/STYLE.md).

### Key Conventions

- Function naming: `Verb-GcNoun` (e.g., `Get-GcUser`, `Invoke-GcRequest`)
- No UI-thread blocking: Use Job pattern for long operations
- Pagination retrieves full dataset by default
- All HTTP calls through `Invoke-GcRequest` or `Invoke-GcPagedRequest`
- PowerShell 5.1 and 7+ compatibility

## License

[To be determined]

## Support

For questions, issues, or feature requests, please open an issue on GitHub.
