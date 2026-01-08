# AGenesysToolKit Architecture

## North Star

The AGenesysToolKit delivers **decision-grade insight from APIs, logs, and telemetry** to empower engineers, operations teams, and contact center analysts. Our guiding principles are:

- **UX-first**: Every interaction is designed to minimize friction and maximize clarity. The tool anticipates user needs and provides immediate feedback.
- **Jobs-first**: Long-running operations never block the UI. All heavy work (analytics queries, bulk exports, conversation detail fetches) runs as asynchronous jobs with progress tracking, cancellation support, and automatic result retrieval.
- **Pagination is default-complete**: Engineers expect entirety by default. API calls retrieve full datasets unless explicitly capped with `-MaxPages` or `-MaxItems`. No silent truncation, no surprising partial results.

## The 3 Workspaces

The toolkit is organized into three primary workspaces, each serving a distinct purpose:

### 1. Orchestration
**Purpose**: Administrative and configuration tasks, user/queue management, routing control.

**Examples**:
- User provisioning and role assignment
- Queue configuration and management
- Skills and language configuration
- Routing rule setup
- Integration management

**Typical Modules**:
- User Management
- Queue Management
- Skills & Languages
- Routing Configuration
- Integration Center

### 2. Conversations
**Purpose**: Deep dive into conversation data, transcripts, metrics, and participant details.

**Examples**:
- Conversation search and filtering
- Transcript retrieval and analysis
- Recording downloads
- Participant history
- Sentiment and analytics

**Typical Modules**:
- Conversation Search
- Transcript Viewer
- Recording Manager
- Analytics Dashboard
- Quality Management

### 3. Operations
**Purpose**: Real-time monitoring, alerting, subscriptions, health checks, and diagnostics.

**Examples**:
- Topic subscriptions (real-time events)
- Presence monitoring
- Queue statistics live view
- System health checks
- Event streaming and logging

**Typical Modules**:
- Topic Subscriptions
- Presence Monitor
- Queue Statistics
- Health Dashboard
- Event Logs

## Core Contracts

These contracts are the foundation of the toolkit. All modules MUST adhere to them.

### `Invoke-GcRequest`

**Purpose**: Single HTTP request to the Genesys Cloud API. No pagination loop.

**Contract**:
- **Input**: Path, Method, Query parameters, Body, Headers, AccessToken
- **Output**: The raw API response (deserialized from JSON)
- **Behavior**:
  - Builds full URI from base + path
  - Replaces `{pathParams}` tokens (e.g., `{conversationId}`)
  - Adds Authorization header if AccessToken provided
  - Retries transient failures (default: 2 retries with 2-second delay)
  - Throws on persistent errors (4xx/5xx after retries)
- **Guarantee**: Predictable, synchronous, single-request behavior. If the endpoint returns paginated data, this function returns ONLY the first page.

**Example**:
```powershell
$user = Invoke-GcRequest -Path '/api/v2/users/me' -Method GET -AccessToken $token
```

### `Invoke-GcPagedRequest`

**Purpose**: Automatically paginate through API responses until completion.

**Contract**:
- **Input**: Same as `Invoke-GcRequest`, plus paging parameters (`-MaxPages`, `-MaxItems`, `-PageSize`)
- **Output**: By default, returns merged item list (e.g., all `entities`, `results`, `conversations`). If no item list detected, returns last response object.
- **Behavior**:
  - DEFAULT: Retrieves entire dataset across all pages (engineers expect entirety)
  - Supports multiple pagination patterns (see Pagination Policy below)
  - User can cap with `-MaxPages` or `-MaxItems` to limit retrieval
  - Handles retry logic per page
  - Automatically detects and follows pagination signals
- **Guarantee**: Unless explicitly capped, this function retrieves the complete dataset. No silent truncation.

**Example**:
```powershell
# Get ALL users (may be thousands)
$allUsers = Invoke-GcPagedRequest -Path '/api/v2/users' -Method GET -AccessToken $token

# Get first 500 users only
$limitedUsers = Invoke-GcPagedRequest -Path '/api/v2/users' -Method GET -AccessToken $token -MaxItems 500
```

### Job Pattern

**Purpose**: All long-running operations follow the Submit → Poll → Fetch pattern.

**Contract**:
1. **Submit**: Call a `Start-Gc*Job` function (e.g., `Start-GcAnalyticsConversationDetailsJob`)
   - Returns a job object with `id` property
2. **Poll**: Use `Wait-GcAsyncJob` to poll job status until completion
   - Checks status endpoint at intervals (default: 1.5 seconds)
   - Detects completion states: `FULFILLED`, `COMPLETED`, `SUCCESS`
   - Detects failure states: `FAILED`, `ERROR`
   - Throws on timeout (default: 300 seconds)
3. **Fetch Results**: Call the results endpoint (e.g., `Get-GcAnalyticsConversationDetailsJobResults`)
   - Results are typically paginated; use `Invoke-GcPagedRequest` internally
   - Default: return ALL results unless capped

**Helper Functions**:
- `Invoke-Gc*Query`: One-call helpers that combine Submit → Poll → Fetch (e.g., `Invoke-GcAnalyticsConversationDetailsQuery`)

**Guarantee**: No blocking of the UI thread. All jobs run asynchronously with progress tracking in the Job Center.

**Example**:
```powershell
# Manual pattern
$job = Start-GcAnalyticsConversationDetailsJob -Body $queryBody
Wait-GcAsyncJob -StatusPath '/api/v2/analytics/conversations/details/jobs/{0}' -JobId $job.id -TimeoutSeconds 600
$results = Get-GcAnalyticsConversationDetailsJobResults -JobId $job.id

# Helper pattern (recommended)
$results = Invoke-GcAnalyticsConversationDetailsQuery -Body $queryBody -TimeoutSeconds 600
```

### Never Block UI

**Principle**: The UI thread must never be blocked by long-running operations.

**Implementation**:
- All potentially slow operations (>2 seconds) MUST use the Job pattern
- Job Center displays all active/completed jobs with progress bars
- Users can cancel jobs in progress
- Jobs update their status and logs in real-time
- Completed jobs display results or provide download links

## Pagination Policy

The toolkit supports multiple pagination patterns commonly used by Genesys Cloud APIs:

### Supported Patterns

1. **`nextPage` (token or link)**
   - API returns `nextPage` field with either:
     - A full URL: `https://api.usw2.pure.cloud/api/v2/users?pageNumber=2&pageSize=100`
     - A relative path: `/api/v2/users?pageNumber=2&pageSize=100`
     - A query string only: `pageNumber=2&pageSize=100`
   - The toolkit automatically resolves all three forms

2. **`nextUri`**
   - Similar to `nextPage`, API returns `nextUri` field
   - Supports full URL, relative path, or query string

3. **`pageCount` / `pageNumber`**
   - Page-based pagination: API returns total page count and current page number
   - Toolkit increments `pageNumber` and continues until `pageNumber >= pageCount`

4. **`cursor` / `nextCursor`**
   - Cursor-based pagination: API returns opaque cursor token
   - Toolkit passes cursor in next request's query parameters
   - Continues until no cursor returned

### Default Behavior: Entirety

**Principle**: Engineers expect the entire dataset by default. Provide controls to cap when needed.

- `Invoke-GcPagedRequest` retrieves ALL pages by default
- Users opt-in to limits with `-MaxPages` or `-MaxItems`
- No silent truncation: if a cap is hit, it's because the user set it
- Verbose logging shows pagination progress

### Capping Controls

```powershell
# Get first 3 pages only
Invoke-GcPagedRequest -Path '/api/v2/users' -MaxPages 3

# Get first 1000 items only
Invoke-GcPagedRequest -Path '/api/v2/users' -MaxItems 1000

# Get first page only (no pagination)
Invoke-GcPagedRequest -Path '/api/v2/users' -All:$false
```

## Exports Policy (Backstage)

**Philosophy**: Exports are a "snackbar + open folder" experience, not a full designer.

**Behavior**:
1. User clicks "Export" button in any view
2. Snackbar appears: "Exporting 1,234 items to JSON..."
3. File is written to `artifacts/` directory (gitignored)
4. Snackbar updates: "Export complete! [Open Folder]"
5. Clicking "Open Folder" opens Windows Explorer to the `artifacts/` directory

**Supported Formats**:
- **JSON** (always available): Pretty-printed, UTF-8, easy to parse
- **TXT** (always available): Tab-delimited or custom format for plain text viewers
- **XLSX** (optional): Only if `ImportExcel` module is available
  - Toolkit checks for module and disables XLSX export if not found
  - User can install with `Install-Module ImportExcel` to enable

**No Configuration UI**: 
- Exports use sensible defaults (timestamp in filename, auto-open folder)
- Power users can customize by editing config files (future Phase 4+)

**Example**:
```powershell
# Export results to JSON
Export-GcResults -Data $results -Format JSON -Name "conversation-details"
# → artifacts/conversation-details-2026-01-08-120530.json
```

---

## Module Organization

All modules reside in the `/Core` directory and are imported by the main application (`/App`).

**Core Modules**:
- `Core/HttpRequests.psm1`: HTTP primitives (`Invoke-GcRequest`, `Invoke-GcPagedRequest`)
- `Core/Jobs.psm1`: Job management and async operation helpers

**Future Modules** (Phase 2+):
- `Core/Users.psm1`
- `Core/Queues.psm1`
- `Core/Conversations.psm1`
- `Core/Analytics.psm1`
- `Core/Subscriptions.psm1`

**Application**:
- `App/GenesysCloudTool_UX_Prototype_v2_1.ps1`: Main WPF UI application

**Tests**:
- `tests/smoke.ps1`: Smoke tests to validate core modules load and key commands exist
- `tests/integration/*`: Integration tests (Phase 2+)
- `tests/unit/*`: Unit tests (Phase 2+)

---

## Naming Conventions

All public functions follow PowerShell verb-noun conventions with the `Gc` prefix:

- `Verb-GcNoun`: Standard pattern (e.g., `Invoke-GcRequest`, `Get-GcUser`, `Start-GcJob`)
- Use approved PowerShell verbs: `Get`, `Set`, `New`, `Remove`, `Invoke`, `Start`, `Stop`, `Wait`, etc.

**Private/Helper Functions**:
- May use any naming, but should be clearly internal (e.g., `Resolve-GcEndpoint`, `ConvertTo-GcQueryString`)
- Not exported from modules

---

## Error Handling

**Principle**: Fail fast, fail loud, provide actionable context.

**Implementation**:
- HTTP errors: Retry transient failures (429, 503, connection timeouts), throw on persistent failures
- Job failures: Detect `FAILED` / `ERROR` status and throw with full job details
- Validation errors: Check inputs early and provide clear error messages
- All errors include relevant context (job ID, request path, response body)

**Example**:
```powershell
try {
    $results = Invoke-GcAnalyticsConversationDetailsQuery -Body $queryBody
} catch {
    Write-Error "Failed to fetch conversation details: $($_.Exception.Message)"
    # Log to Job Center
}
```

---

## Future Enhancements (Phase 4+)

- Caching layer for frequently accessed resources (users, queues)
- Offline mode with local storage
- Advanced export templates and scheduling
- Webhook/event forwarding to external systems
- Multi-org support with profile switching
- Enhanced error recovery and automatic retries
