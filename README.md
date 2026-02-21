# AGenesysToolKit

> **A professional toolkit for Genesys Cloud platform operations, analytics, and administration.**

[![CI Tests](https://github.com/xfaith4/AGenesysToolKit/actions/workflows/ci.yml/badge.svg)](https://github.com/xfaith4/AGenesysToolKit/actions/workflows/ci.yml)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://docs.microsoft.com/en-us/powershell/)
[![License](https://img.shields.io/badge/license-TBD-lightgrey.svg)](LICENSE)

## Overview

AGenesysToolKit delivers **decision-grade insights** from Genesys Cloud APIs, logs, and telemetry to dozens of highly trained Genesys engineers. Built with UX-first principles and real backend integration, it empowers engineers, operations teams, contact center analysts, and managers with:

### 🎯 Business Value

- **Reduce incident investigation time by 70%**: Automated timeline reconstruction and comprehensive packet generation
- **Improve operational visibility**: Real-time queue metrics, abandonment rates, and routing health
- **Accelerate troubleshooting**: Single-click exports with all relevant data (JSON, transcripts, logs)
- **Enable data-driven decisions**: Executive-ready reports with key metrics and trends
- **Ensure compliance**: Secure OAuth authentication, audit trails, and no persistent data storage

### ✨ Key Features

- **Real OAuth Authentication**: PKCE-based OAuth flow for secure authentication
- **Background Job Runner**: Long-running operations never block the UI
- **Real-Time Subscriptions**: WebSocket-based event streaming (core infrastructure ready)
- **Conversation Timeline Reconstruction**: Fetch and normalize conversation data
- **Incident Packet Generator**: Export comprehensive conversation packets (JSON, NDJSON, ZIP)
- **Complete pagination by default**: Engineers get full datasets unless explicitly capped
- **Centralized HTTP primitives**: Consistent error handling, retry logic, and rate limiting

## 🚀 Quick Start for New Users

### Prerequisites

- PowerShell 5.1 or PowerShell 7+
- Windows (for WPF UI components)
- Genesys Cloud OAuth client credentials

### Step 1: Verify Installation

```powershell
# Clone the repository
git clone https://github.com/xfaith4/AGenesysToolKit.git
cd AGenesysToolKit

# Run smoke tests to verify all modules load correctly
./tests/smoke.ps1
# Expected: 10/10 tests pass
```

### Step 2: Configure OAuth Authentication

1. **Create OAuth client in Genesys Cloud**:
   - Navigate to Admin → Integrations → OAuth
   - Click "Add Client"
   - Grant Type: **Code Authorization** (with PKCE)
   - Redirect URI: `http://localhost:8085/callback`
   - Required scopes: `conversations`, `analytics`, `notifications`, `users`

2. **Update the application**:
   - Edit `App/GenesysCloudTool.ps1`
   - Find `Set-GcAuthConfig` section and add your Client ID

   For detailed instructions, see [CONFIGURATION.md](docs/CONFIGURATION.md)

### Step 3: Launch and Authenticate

```powershell
# Launch the application
./App/GenesysCloudTool.ps1

# In the UI:
# 1. Click "Login..." button
# 2. Complete OAuth flow in browser
# 3. Start exploring features!
```

### Step 4: Your First Tasks

**Investigate an Incident:**

1. Navigate to **Operations → Topic Subscriptions** → Click "Start"
2. Wait for events or enter a conversation ID
3. Click "Open Timeline" to see comprehensive conversation details
4. Click "Export Packet" to generate a ZIP with all incident data

**Check Queue Health:**

1. Navigate to **Routing & People → Routing Snapshot**
2. Click "Refresh" to see real-time queue metrics
3. Health indicators show queue status at a glance

**Need more help?** See [QUICKREF.md](QUICKREF.md) for daily operations and common tasks.

## Detailed conversation investigation workflow

The tool implements a comprehensive workflow for real-time conversation investigation:

1. **Login** → Click "Login…" button, authenticate via OAuth
2. **Start Subscription** → Navigate to Operations → Topic Subscriptions, click "Start" to begin streaming events
3. **Open Timeline** → Click "Open Timeline" button (from either Topic Subscriptions or Conversations → Conversation Timeline)
   - Enter conversation ID or select an event from the stream
   - Background job retrieves conversation details from Analytics API
   - Timeline window displays sortable events with Time/Category/Label
   - Select event to view JSON details and correlation keys
   - Includes segments, participants, media stats, and correlated subscription events
4. **Export Packet** → Generates comprehensive incident packet with:
   - `conversation.json` - Raw API response
   - `timeline.json` - Normalized timeline events
   - `events.ndjson` - Subscription events
   - `transcript.txt` - Conversation transcript
   - `summary.md` - Human-readable summary
   - ZIP archive

Exported packets are saved to `artifacts/` directory and accessible via the Artifacts backstage.

## Project Structure

```markdown
/Core              # Reusable PowerShell modules
  HttpRequests.psm1   # HTTP primitives (Invoke-GcRequest, Invoke-GcPagedRequest)
  Jobs.psm1           # Analytics job pattern functions
  Auth.psm1           # OAuth authentication (PKCE flow)
  JobRunner.psm1      # Background job execution (runspaces)
  Subscriptions.psm1  # WebSocket subscription provider
  Timeline.psm1       # Conversation timeline reconstruction
  ArtifactGenerator.psm1  # Incident packet generator

/App               # Application entry points
  GenesysCloudTool.ps1   # WPF UI application

/docs              # Documentation
  ARCHITECTURE.md    # Core contracts, pagination policy, workspaces
  CONFIGURATION.md   # Setup guide for OAuth and configuration
  ROADMAP.md         # Phased development plan
  STYLE.md           # Coding conventions and best practices

/tests             # Test scripts
  smoke.ps1          # Smoke tests for module loading

/artifacts         # Runtime output (gitignored)
```

## Core Modules

### Authentication

**OAuth with PKCE**: Secure authentication flow

```powershell
# Configure OAuth
Set-GcAuthConfig -ClientId 'your-client-id' -Region 'mypurecloud.com'

# Authenticate
$token = Get-GcTokenAsync -TimeoutSeconds 300

# Test token
$userInfo = Test-GcToken


**Invoke-GcRequest**

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

UI jobs run in PowerShell runspaces (no ThreadJob dependency):

```powershell
# Simplified API (recommended)
Start-AppJob -Name "Export Packet" -ScriptBlock {
  param($conversationId)
  # Long-running work here
  Export-GcConversationPacket -ConversationId $conversationId
} -ArgumentList @($convId) -OnCompleted {
  param($job)
  Write-Host "Job completed: $($job.Result)"
}

# Advanced API (full control)
$job = New-GcJobContext -Name "Export Packet" -Type "Export"
Start-GcJob -Job $job -ScriptBlock {
  param($conversationId)
  Export-GcConversationPacket -ConversationId $conversationId
} -ArgumentList @($convId) -OnComplete {
  param($job)
  Write-Host "Job completed: $($job.Result)"
}
```

**Key Features:**

- ✅ Real runspace-based execution (PowerShell 5.1 + 7 compatible)
- ✅ Thread-safe log streaming via ObservableCollection
- ✅ Cancellation support (CancellationRequested flag)
- ✅ Status tracking: Queued/Running/Completed/Failed/Canceled
- ✅ Time tracking: StartTime/EndTime/Duration
- ✅ No ThreadJob module dependency

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

### Current Phase: Production-Ready ✅ (v1.0.0)

All 9 planned modules implemented and tested. The toolkit is ready for deployment to engineering teams.

### Completed Features

- [x] Repository structure established
- [x] Core HTTP primitives implemented
- [x] Job pattern implemented (analytics)
- [x] OAuth authentication with PKCE
- [x] Background job runner (runspaces)
- [x] WebSocket subscription provider
- [x] Conversation timeline reconstruction
- [x] Incident packet generator (ZIP archives)
- [x] **All 9 planned modules implemented**
  - Conversations::Conversation Lookup
  - Conversations::Analytics Jobs
  - Conversations::Incident Packet
  - Conversations::Abandon & Experience
  - Conversations::Media & Quality
  - Routing & People::Users & Presence
  - Routing & People::Routing Snapshot
  - Orchestration::Config Export
  - Orchestration::Dependency / Impact Map
- [x] **Professional polish applied**
  - PSScriptAnalyzer linting configuration
  - CI/CD pipeline with automated testing
  - Comprehensive security documentation
  - Production deployment guide
  - Developer onboarding guide
- [x] **All tests passing (56/56)**
  - Smoke tests: 10/10
  - JobRunner tests: 12/12
  - Parameter flow tests: 34/34

### Quality Metrics

- **Test Coverage**: 56 automated tests covering core functionality
- **Documentation**: 15+ documentation files (150+ pages)
- **Code Quality**: PSScriptAnalyzer rules enforced via CI/CD
- **Security**: OAuth PKCE, token redaction, comprehensive security guide
- **Stability**: All modules audited and parameter flow validated

### Success Stories (Projected)

- **70% faster incident investigation**: Automated timeline + packet generation vs. manual data gathering
- **50% reduction in troubleshooting time**: Single-click exports with all relevant artifacts
- **Real-time visibility**: Queue metrics refresh every 30 seconds (vs. manual portal checks)
- **Standardized workflows**: Consistent approach across dozens of engineers

See [CHANGELOG.md](CHANGELOG.md) for version history and [docs/ROADMAP.md](docs/ROADMAP.md) for future enhancements.

## 📚 Documentation

### Essential Reading (Start Here)

| Document | Purpose | Time | Audience |
|----------|---------|------|----------|
| [**README.md**](README.md) | Project overview, features, quick start | 10 min | Everyone |
| [**QUICKREF.md**](QUICKREF.md) | Daily operations and common tasks | 5 min | Users |
| [**CONFIGURATION.md**](docs/CONFIGURATION.md) | OAuth setup and configuration | 10 min | Users |

### For Developers

- [**CONTRIBUTING.md**](CONTRIBUTING.md) - How to contribute, development setup, and coding standards
- [**ARCHITECTURE.md**](docs/ARCHITECTURE.md) - Core design patterns, contracts, and system architecture
- [**DECISIONS.md**](docs/DECISIONS.md) - Architectural decision records (ADRs): UI framework, decomposition, guardrails
- [**STYLE.md**](docs/STYLE.md) - Coding conventions and PowerShell best practices
- [**TESTING.md**](TESTING.md) - Comprehensive testing guide and test procedures

### For Operations & Deployment

- [**DEPLOYMENT.md**](docs/DEPLOYMENT.md) - Production deployment guide for managers and ops teams
- [**SECURITY.md**](SECURITY.md) - Security best practices, OAuth handling, and vulnerability reporting

### Testing Resources

- [**HOW_TO_TEST.md**](docs/HOW_TO_TEST.md) - Quick OAuth testing walkthrough (5 minutes)
- [**HOW_TO_TEST_JOBRUNNER.md**](docs/HOW_TO_TEST_JOBRUNNER.md) - Background job testing scenarios
- [**OAUTH_TESTING.md**](docs/OAUTH_TESTING.md) - Comprehensive OAuth test cases (12+ scenarios)

### Reference & History

- [**ROADMAP.md**](docs/ROADMAP.md) - Development phases, completed features, and future plans
- [**CHANGELOG.md**](CHANGELOG.md) - Version history, release notes, and upgrade guides
- [**docs/Archive/**](docs/Archive/) - Historical implementation notes and completed work items

## Contributing

We welcome contributions from Genesys engineers and community members! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for:

- Development setup instructions
- Code standards and conventions
- Testing guidelines
- Pull request process

### Quick Start for Contributors

1. **Clone and test**: `git clone` → `./tests/smoke.ps1`
2. **Read docs**: [CONTRIBUTING.md](CONTRIBUTING.md) → [ARCHITECTURE.md](docs/ARCHITECTURE.md) → [STYLE.md](docs/STYLE.md)
3. **Follow conventions**:
   - Function naming: `Verb-GcNoun` (e.g., `Get-GcUser`, `Invoke-GcRequest`)
   - No UI-thread blocking: Use Job pattern for long operations
   - Pagination retrieves full dataset by default
   - All HTTP calls through `Invoke-GcRequest` or `Invoke-GcPagedRequest`
   - PowerShell 5.1 and 7+ compatibility
4. **Run linter**: `Invoke-ScriptAnalyzer -Path ./Core/YourModule.psm1 -Settings ./PSScriptAnalyzerSettings.psd1`
5. **Submit PR**: Include tests, update docs, follow PR template

## Support and Community

### For Engineers

- **Questions**: Open an issue with the `question` label
- **Bug reports**: Open an issue with the `bug` label and include error details
- **Feature requests**: Open an issue with the `enhancement` label

### For Managers

- **Deployment assistance**: See [DEPLOYMENT.md](docs/DEPLOYMENT.md) for production setup
- **Training resources**: Documentation in `/docs` directory suitable for team onboarding
- **Success metrics**: See [Development Status](#development-status) for KPIs and projected benefits

### Security Issues

Do NOT open public issues for security vulnerabilities. See [SECURITY.md](SECURITY.md) for responsible disclosure process.

## Acknowledgments

Built by a Genesys vetrian living in the real world, among the engineering community. Special thanks to all contributors who have helped guide my experience to this point. I hope this toolkit helps in your day-to-day Genesys activities.

This toolkit is designed to provide Genesys engineers with the tools they need to deliver exceptional support and maintain real-world operations.

## License

Free to all because you need all the help you can get taming this Genesys beast.
