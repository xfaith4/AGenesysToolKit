# AGenesysToolKit Style Guide

This document outlines coding conventions and best practices for the AGenesysToolKit project.

---

## Core Principles

1. **UX-first**: Every function, every error message, every log line should serve the user's need for clarity and efficiency.
2. **Fail fast, fail loud**: Errors should be detected early and reported with actionable context.
3. **Predictable defaults**: Engineers expect sensible defaults (pagination retrieves all, jobs have reasonable timeouts, etc.).
4. **No surprises**: Functions should behave consistently and document their guarantees clearly.

---

## PowerShell Conventions

### Function Naming: `Verb-GcNoun`

All public functions MUST follow PowerShell's approved verb-noun pattern with the `Gc` prefix to indicate Genesys Cloud:

- **Approved verbs**: `Get`, `Set`, `New`, `Remove`, `Invoke`, `Start`, `Stop`, `Wait`, `Export`, `Import`, `Test`, `Clear`, etc.
- **Examples**: `Invoke-GcRequest`, `Get-GcUser`, `Start-GcAnalyticsConversationDetailsJob`, `Wait-GcAsyncJob`, `Export-GcResults`

**DO**:
```powershell
function Get-GcUser { ... }
function Start-GcJob { ... }
function Invoke-GcPagedRequest { ... }
```

**DON'T**:
```powershell
function Gc-GetUser { ... }           # Verb comes first
function GetGenesysUser { ... }       # Use approved verb
function Fetch-GcUser { ... }         # 'Fetch' is not an approved verb; use 'Get'
```

### No UI-Thread Blocking

Long-running operations (>2 seconds) MUST use the Job pattern:

- Submit job via `Start-Gc*Job`
- Poll status via `Wait-GcAsyncJob`
- Fetch results via `Get-Gc*JobResults`

**DO**:
```powershell
function Invoke-GcAnalyticsConversationDetailsQuery {
    $job = Start-GcAnalyticsConversationDetailsJob -Body $Body
    Wait-GcAsyncJob -StatusPath '/api/v2/analytics/conversations/details/jobs/{0}' -JobId $job.id
    Get-GcAnalyticsConversationDetailsJobResults -JobId $job.id
}
```

**DON'T**:
```powershell
# Never block the UI thread with synchronous long-running calls
$results = Invoke-RestMethod -Uri $uri -Method POST -Body $Body
Start-Sleep -Seconds 60  # Waiting for job to complete synchronously
```

### Pagination Defaults to Full Retrieval

`Invoke-GcPagedRequest` MUST retrieve the entire dataset by default. Users opt-in to limits with `-MaxPages` or `-MaxItems`.

**DO**:
```powershell
# Get ALL users (thousands if necessary)
$allUsers = Invoke-GcPagedRequest -Path '/api/v2/users' -Method GET

# User explicitly caps retrieval
$first500 = Invoke-GcPagedRequest -Path '/api/v2/users' -Method GET -MaxItems 500
```

**DON'T**:
```powershell
# NEVER silently truncate without user's explicit cap
if ($pageCount -gt 10) { break }  # Bad: arbitrary limit without user input
```

### Avoid PowerShell Colon-After-Variable Bug

PowerShell has a parsing quirk where `$var:` is interpreted as a drive reference. Use `$($var)` when a colon follows:

**DO**:
```powershell
$uri = "https://api.usw2.pure.cloud/api/v2/users"
Write-Host "Fetching from: $($uri)"
$header = "Authorization: Bearer $($token)"
```

**DON'T**:
```powershell
$header = "Authorization: Bearer $token"  # Works fine
$header = "Authorization: Bearer $token:"  # Breaks due to colon parsing bug
```

### Prefer Structured Objects, Then Export

Build structured PowerShell objects (`[PSCustomObject]`), then export to desired format. Don't build CSV or JSON strings by hand.

**DO**:
```powershell
$results = foreach ($item in $data) {
    [PSCustomObject]@{
        Id   = $item.id
        Name = $item.name
        Date = $item.timestamp
    }
}

# Export to desired format
$results | Export-Csv -Path $outPath -NoTypeInformation
$results | ConvertTo-Json -Depth 10 | Out-File $outPath
```

**DON'T**:
```powershell
# Never build CSV by hand
$csv = "Id,Name,Date`n"
foreach ($item in $data) {
    $csv += "$($item.id),$($item.name),$($item.timestamp)`n"
}
```

### Centralize HTTP in Core Primitives

All HTTP calls MUST go through `Invoke-GcRequest` or `Invoke-GcPagedRequest`. No ad-hoc `Invoke-RestMethod` calls elsewhere.

**DO**:
```powershell
function Get-GcUser {
    param([string]$UserId)
    Invoke-GcRequest -Path "/api/v2/users/$UserId" -Method GET
}

function Get-AllGcQueues {
    Invoke-GcPagedRequest -Path "/api/v2/routing/queues" -Method GET
}
```

**DON'T**:
```powershell
# Never bypass the core HTTP primitives
$user = Invoke-RestMethod -Uri "https://api.usw2.pure.cloud/api/v2/users/$UserId" -Headers $headers
```

**Why**: Centralization ensures consistent error handling, retry logic, logging, and rate limiting.

---

## Code Structure

### Module Organization

- **`/Core`**: Reusable PowerShell modules (`.psm1` files)
  - `Core/HttpRequests.psm1`: HTTP primitives
  - `Core/Jobs.psm1`: Job pattern functions
  - Future: `Core/Users.psm1`, `Core/Queues.psm1`, etc.
- **`/App`**: Application code (WPF UI, entry points)
- **`/docs`**: Documentation (architecture, roadmap, style guide)
- **`/tests`**: Test scripts (smoke, unit, integration)
- **`/artifacts`**: Runtime output (gitignored)

### Exporting Functions

Only export public functions from modules:

```powershell
# At end of module file
Export-ModuleMember -Function Invoke-GcRequest, Invoke-GcPagedRequest
```

Private/helper functions should NOT be exported.

### Error Handling

- **Fail fast**: Validate inputs early
- **Fail loud**: Throw exceptions with clear messages and context
- **Include context**: Add relevant details (job ID, request path, response body)

**DO**:
```powershell
if (-not $JobId) {
    throw "JobId parameter is required for Get-GcJobStatus."
}

try {
    $response = Invoke-GcRequest -Path $path -Method GET
} catch {
    throw "Failed to fetch job status for JobId=$JobId. Error: $($_.Exception.Message)"
}
```

**DON'T**:
```powershell
# Vague error messages
if (-not $JobId) { throw "Missing parameter" }

# Silent failures
try {
    $response = Invoke-GcRequest -Path $path -Method GET
} catch {
    return $null  # Don't hide errors
}
```

---

## Testing

### Smoke Tests

Smoke tests verify that modules load and core commands exist:

```powershell
# tests/smoke.ps1
Import-Module ./Core/HttpRequests.psm1 -Force
$cmd = Get-Command Invoke-GcRequest -ErrorAction SilentlyContinue
if (-not $cmd) { throw "Invoke-GcRequest not found" }
Write-Host "SMOKE PASS"
```

### Unit Tests

(Phase 2+) Use Pester for unit tests:

```powershell
Describe "Invoke-GcRequest" {
    It "Builds correct URI" {
        # Mock Invoke-RestMethod
        Mock Invoke-RestMethod { return @{} }
        
        Invoke-GcRequest -Path '/api/v2/users/me' -Method GET
        
        # Assert Invoke-RestMethod was called with correct URI
        Assert-MockCalled Invoke-RestMethod -ParameterFilter {
            $Uri -like '*api.usw2.pure.cloud/api/v2/users/me'
        }
    }
}
```

### Integration Tests

(Phase 2+) Test against live API (requires credentials):

```powershell
Describe "Invoke-GcPagedRequest (Live)" -Tag Integration {
    BeforeAll {
        $token = Get-Content ./test-token.txt
    }
    
    It "Retrieves all users" {
        $users = Invoke-GcPagedRequest -Path '/api/v2/users' -Method GET -AccessToken $token
        $users.Count | Should -BeGreaterThan 0
    }
}
```

---

## Documentation

### Function Comments

Use PowerShell's comment-based help:

```powershell
function Invoke-GcRequest {
    <#
    .SYNOPSIS
        Single Genesys Cloud API request (no pagination loop).
    
    .DESCRIPTION
        Builds full URI, adds Authorization header, handles retries.
    
    .PARAMETER Path
        API path (e.g., '/api/v2/users/me')
    
    .PARAMETER Method
        HTTP method (GET, POST, PUT, PATCH, DELETE)
    
    .PARAMETER AccessToken
        Bearer token for Authorization header
    
    .EXAMPLE
        Invoke-GcRequest -Path '/api/v2/users/me' -Method GET -AccessToken $token
    
    .EXAMPLE
        Invoke-GcRequest -Path '/api/v2/conversations/{id}' -PathParams @{id='abc-123'} -Method GET
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'GET',
        [string] $AccessToken
    )
    
    # Implementation...
}
```

### Inline Comments

Use inline comments sparingly. Prefer self-documenting code:

**DO**:
```powershell
# Resolve path parameters (e.g., {conversationId})
$resolvedPath = Resolve-GcEndpoint -Path $Path -PathParams $PathParams
```

**DON'T**:
```powershell
# This is the path
$path = $Path  # Set the path variable
```

---

## Git & Versioning

### Commit Messages

Use clear, imperative commit messages:

- **DO**: `Add pagination support for user endpoints`
- **DO**: `Fix retry logic in Invoke-GcRequest`
- **DO**: `Update ARCHITECTURE.md with pagination policy`
- **DON'T**: `Fixed stuff`, `WIP`, `asdfasdf`

### Branching

- `main`: Production-ready code
- `develop`: Integration branch for features
- `feature/*`: Feature branches (e.g., `feature/job-center-ui`)
- `bugfix/*`: Bug fix branches (e.g., `bugfix/pagination-cursor-handling`)

### Pull Requests

- Include clear description of changes
- Link to related issues
- Update documentation if applicable
- Ensure smoke tests pass

---

## Security

### No Secrets in Code

Never commit secrets to the repository:

- **DON'T**: `$token = "abc123..."`
- **DO**: `$token = Get-Content ./token.txt` (and gitignore `*.token`)

### Input Validation

Validate all user inputs:

```powershell
function Get-GcUser {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $UserId
    )
    
    # Additional validation
    if ($UserId -notmatch '^[a-f0-9-]{36}$') {
        throw "UserId must be a valid GUID."
    }
    
    Invoke-GcRequest -Path "/api/v2/users/$UserId" -Method GET
}
```

### Error Messages

Don't leak sensitive data in error messages:

**DO**:
```powershell
throw "Failed to authenticate. Please check your credentials."
```

**DON'T**:
```powershell
throw "Failed to authenticate with token: $($token)"
```

---

## Performance

### Avoid N+1 Queries

Batch requests when possible:

**DO**:
```powershell
# Single request for all users
$users = Invoke-GcPagedRequest -Path '/api/v2/users' -Method GET
```

**DON'T**:
```powershell
# Multiple requests for each user ID
foreach ($id in $userIds) {
    $user = Invoke-GcRequest -Path "/api/v2/users/$id" -Method GET
}
```

### Use Pagination Efficiently

Set `PageSize` appropriately (default: 100, max: varies by endpoint):

```powershell
# Efficient: fetch 500 items per page if API supports it
Invoke-GcPagedRequest -Path '/api/v2/conversations' -PageSize 500
```

---

## Summary Checklist

Before submitting code, verify:

- [ ] Function names follow `Verb-GcNoun` pattern
- [ ] No UI-thread blocking (use Job pattern for long operations)
- [ ] Pagination retrieves full dataset by default
- [ ] All HTTP calls go through `Invoke-GcRequest` / `Invoke-GcPagedRequest`
- [ ] Error messages are clear and actionable
- [ ] No secrets committed
- [ ] Comment-based help added for public functions
- [ ] Smoke tests pass
- [ ] Code is self-documenting with minimal inline comments
