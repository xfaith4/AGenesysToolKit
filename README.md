# AGenesysToolKit

A professional toolkit for Genesys Cloud platform operations, analytics, and administration.

## Overview

AGenesysToolKit provides decision-grade insights from Genesys Cloud APIs, logs, and telemetry. Built with UX-first principles, it empowers engineers, operations teams, and contact center analysts with:

- **Jobs-first architecture**: Long-running operations never block the UI
- **Complete pagination by default**: Engineers get full datasets unless explicitly capped
- **Centralized HTTP primitives**: Consistent error handling, retry logic, and rate limiting
- **Three core workspaces**: Orchestration, Conversations, and Operations

## Quick Start

### Prerequisites

- PowerShell 5.1 or PowerShell 7+
- Windows (for WPF UI components)
- Genesys Cloud credentials (OAuth token or client credentials)

### Running Smoke Tests

Verify the installation and core module loading:

```powershell
# From repository root
./tests/smoke.ps1
```

### Launching the UI Prototype

```powershell
# From repository root
./App/GenesysCloudTool_UX_Prototype_v2_1.ps1
```

## Project Structure

```
/Core              # Reusable PowerShell modules
  HttpRequests.psm1   # HTTP primitives (Invoke-GcRequest, Invoke-GcPagedRequest)
  Jobs.psm1           # Job pattern functions (Wait-GcAsyncJob, analytics jobs)

/App               # Application entry points
  GenesysCloudTool_UX_Prototype_v2_1.ps1   # WPF UI application

/docs              # Documentation
  ARCHITECTURE.md    # Core contracts, pagination policy, workspaces
  ROADMAP.md         # Phased development plan
  STYLE.md           # Coding conventions and best practices

/tests             # Test scripts
  smoke.ps1          # Smoke tests for module loading and command existence

/artifacts         # Runtime output (gitignored)
```

## Core Contracts

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

## Development Status

**Current Phase: Phase 0 - Foundation Complete ✅**

- [x] Repository structure established
- [x] Core HTTP primitives implemented
- [x] Job pattern implemented
- [x] Documentation complete
- [x] Smoke tests passing
- [x] WPF UI prototype functional

**Next Phase: Phase 1 - Core HTTP & Pagination Primitives**

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
