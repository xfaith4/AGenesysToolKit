# Testing Guide - AGenesysToolKit

This guide provides comprehensive testing procedures for AGenesysToolKit, from quick smoke tests to full integration testing.

## Table of Contents

- [Quick Start Testing](#quick-start-testing)
- [Test Suites](#test-suites)
- [Manual Testing](#manual-testing)
- [OAuth Testing](#oauth-testing)
- [JobRunner Testing](#jobrunner-testing)
- [Integration Testing](#integration-testing)
- [Troubleshooting Tests](#troubleshooting-tests)

## Quick Start Testing

### Running All Tests (2 minutes)

```powershell
# From repository root
cd /path/to/AGenesysToolKit

# Run smoke tests (module loading)
./tests/smoke.ps1

# Run JobRunner tests (background jobs)
./tests/test-jobrunner.ps1

# Run parameter flow tests (authentication)
./tests/test-parameter-flow.ps1
```

**Expected Results:**
- Smoke tests: 10/10 passing
- JobRunner tests: 12/12 passing
- Parameter flow tests: 34/34 passing

### Quick Validation

If you just want to verify the toolkit is functional:

```powershell
# Single command to run all core tests
Get-ChildItem ./tests/smoke.ps1, ./tests/test-jobrunner.ps1, ./tests/test-parameter-flow.ps1 | ForEach-Object { 
    Write-Host "`n=== Running $($_.Name) ===" -ForegroundColor Cyan
    & $_.FullName 
}
```

## Test Suites

### OfflineDemo Workflow Tests (`test-offlinedemo-workflow.ps1`)

**Purpose**: Validate all OfflineDemo-supported API flows (SampleData router) headlessly, and ensure trace logs are written locally for debugging.

**Duration**: ~5–10 seconds

**What it tests:**
- Offline sample-data routing for key endpoints (users/me, audits, queues, flows, actions, recordings, quality)
- Analytics conversation details async job flow (submit → wait → results)
- Timeline reconstruction using offline conversation + analytics data
- Trace log file creation for a test run

**Running:**
```powershell
./tests/test-offlinedemo-workflow.ps1
```

**Artifacts:**
- Trace log written under `./artifacts/offlinedemo-test-*.log` (gitignored)

### 1. Smoke Tests (`smoke.ps1`)

**Purpose**: Verify all core modules load correctly and key functions exist.

**Duration**: ~10 seconds

**What it tests:**
- Module loading (HttpRequests, Jobs, Auth, JobRunner, Subscriptions, Timeline, ArtifactGenerator)
- Command existence (Invoke-GcRequest, Invoke-GcPagedRequest, Wait-GcAsyncJob)

**Running:**
```powershell
./tests/smoke.ps1
```

**Interpreting Results:**
```
Tests Passed: 10
Tests Failed: 0
✓ SMOKE PASS
```

If any test fails, check that:
- All module files exist in `/Core`
- No syntax errors in module files
- PowerShell version is 5.1 or 7+

### 2. JobRunner Tests (`test-jobrunner.ps1`)

**Purpose**: Validate background job execution system.

**Duration**: ~30 seconds

**What it tests:**
- Job context creation
- Job lifecycle (Queued → Running → Completed)
- Job cancellation
- Log streaming
- Error handling in jobs
- Multiple concurrent jobs
- Job timing and duration tracking

**Running:**
```powershell
./tests/test-jobrunner.ps1
```

**Interpreting Results:**
```
Tests Passed: 12
Tests Failed: 0
✓ ALL TESTS PASSED
```

**Common Issues:**
- **Jobs stuck in Running state**: Runspace may not have closed properly. Restart PowerShell session.
- **Timing issues**: Some tests wait for job completion. Slow systems may need longer timeouts.

### 3. Parameter Flow Tests (`test-parameter-flow.ps1`)

**Purpose**: Verify authentication parameters are correctly defined and passed through the call chain.

**Duration**: ~15 seconds

**What it tests:**
- All Jobs.psm1 functions have AccessToken/InstanceName parameters
- HTTP primitives accept authentication parameters
- Module function signatures are correct
- Timeline module authentication pattern
- ArtifactGenerator parameter flow

**Running:**
```powershell
./tests/test-parameter-flow.ps1
```

**Interpreting Results:**
```
Tests Passed: 34
Tests Failed: 0
✓ ALL PARAMETER FLOW TESTS PASSED
```

### 4. Additional Test Scripts

These tests are available for specific scenarios:

- **`test-auth.ps1`**: OAuth authentication flow
- **`test-timeline.ps1`**: Conversation timeline reconstruction
- **`test-artifact-generator.ps1`**: Incident packet generation
- **`test-reporting.ps1`**: Report generation and templates
- **`test-mvp-modules.ps1`**: Module functionality tests
- **`test-reports-exports-ui.ps1`**: UI export functionality

## Manual Testing

### OfflineDemo Manual Plan

- `docs/OFFLINEDEMO_TEST_PLAN.md`

### Testing the Application UI

1. **Launch Application**
   ```powershell
   ./App/GenesysCloudTool_UX_Prototype_v2_1.ps1
   ```

2. **Verify Main Window**
   - Window opens without errors
   - All workspace tabs are visible (Conversations, Routing & People, Orchestration, Operations, Reporting, Admin)
   - Status bar shows "Not authenticated"

3. **Test Navigation**
   - Click each workspace tab
   - Verify sections load without errors
   - Check that all buttons are visible

### Manual Test Checklist

#### Authentication Flow
- [ ] Click "Login..." button
- [ ] Browser opens with OAuth consent page
- [ ] After consent, callback URL is captured
- [ ] Token is acquired successfully
- [ ] Status bar updates to show authenticated user
- [ ] "Logout" button becomes available

#### Conversations Workspace
- [ ] **Conversation Lookup**: Search for conversations by ID or date range
- [ ] **Analytics Jobs**: Submit query and monitor job progress
- [ ] **Incident Packet**: Generate comprehensive export for a conversation
- [ ] **Abandon & Experience**: View abandonment metrics
- [ ] **Media & Quality**: Access recordings and transcripts

#### Routing & People Workspace
- [ ] **Users & Presence**: List users and view presence status
- [ ] **Routing Snapshot**: View real-time queue metrics with auto-refresh

#### Orchestration Workspace
- [ ] **Config Export**: Export flows, queues, or full configuration
- [ ] **Dependency Map**: Search for flow references to objects

#### Operations Workspace
- [ ] **Topic Subscriptions**: Start/stop WebSocket subscriptions
- [ ] **Conversation Timeline**: Open timeline for a conversation ID

#### Reporting Workspace
- [ ] **Report Templates**: Generate reports with various templates
- [ ] **Artifacts Backstage**: View and open exported artifacts

#### Admin & Settings
- [ ] **Job Center**: View active and completed jobs
- [ ] **Settings**: View/update configuration

## OAuth Testing

### Quick OAuth Test (5 minutes)

See [docs/HOW_TO_TEST.md](docs/HOW_TO_TEST.md) for step-by-step OAuth testing.

**Quick verification:**

```powershell
# Import Auth module
Import-Module ./Core/Auth.psm1 -Force

# Configure OAuth
Set-GcAuthConfig -ClientId 'your-client-id' -Region 'mypurecloud.com'

# Test authentication (opens browser)
$token = Get-GcTokenAsync -TimeoutSeconds 300

# Verify token works
$userInfo = Test-GcToken -AccessToken $token
Write-Host "Authenticated as: $($userInfo.name)"

# Cleanup
Clear-GcTokenState
```

### Comprehensive OAuth Testing

See [docs/OAUTH_TESTING.md](docs/OAUTH_TESTING.md) for 12+ detailed OAuth test scenarios.

## JobRunner Testing

### Quick JobRunner Test

```powershell
# Run automated tests
./tests/test-jobrunner.ps1
```

### Manual JobRunner Testing

See [docs/HOW_TO_TEST_JOBRUNNER.md](docs/HOW_TO_TEST_JOBRUNNER.md) for detailed scenarios including:

1. **Simple Job Success**: Submit and complete a basic job
2. **Job with Logs**: Job that produces log output
3. **Job Cancellation**: Cancel a running job
4. **Job Failure**: Job that throws an error
5. **Multiple Concurrent Jobs**: Run several jobs simultaneously
6. **Job with Result**: Job that returns data
7. **Long-Running Job**: Job that takes extended time

**Quick manual test in UI:**

1. Launch application
2. Navigate to Admin → Job Center
3. Go to Operations → Topic Subscriptions
4. Click "Start Subscription" (creates a job)
5. Watch Job Center update in real-time
6. Click "Stop" to cancel
7. Verify job shows as "Canceled" in Job Center

## Integration Testing

### Prerequisites for Integration Tests

- Valid Genesys Cloud OAuth credentials
- Network access to Genesys Cloud APIs
- Appropriate permissions in your Genesys Cloud organization

### Setting Up Integration Tests

1. **Configure OAuth Client**
   ```powershell
   # Edit App/GenesysCloudTool_UX_Prototype_v2_1.ps1
   # Update Set-GcAuthConfig with your Client ID
   ```

2. **Run Application**
   ```powershell
   ./App/GenesysCloudTool_UX_Prototype_v2_1.ps1
   ```

3. **Authenticate**
   - Click "Login..." button
   - Complete OAuth flow
   - Verify authentication succeeds

### Integration Test Scenarios

#### Test 1: User Listing
```powershell
# Navigate to: Routing & People → Users & Presence
# Click "List Users"
# Expected: Grid populates with users from your org
# Verify: Names, emails, departments display correctly
```

#### Test 2: Analytics Query
```powershell
# Navigate to: Conversations → Analytics Jobs
# Enter date range (last 7 days)
# Click "Query"
# Expected: Job submitted, tracked in Job Center, completes with results
# Verify: Results grid shows conversations
```

#### Test 3: Queue Metrics
```powershell
# Navigate to: Routing & People → Routing Snapshot
# Click "Refresh"
# Expected: Real-time queue metrics load
# Verify: Health status (red/yellow/green) displays, metrics are current
```

#### Test 4: Timeline Reconstruction
```powershell
# Navigate to: Operations → Topic Subscriptions
# Enter a valid conversation ID
# Click "Open Timeline"
# Expected: Timeline window opens, events load and display
# Verify: Timeline shows chronological events with details
```

#### Test 5: Export Packet
```powershell
# Navigate to: Conversations → Incident Packet
# Enter a valid conversation ID
# Click "Export Packet"
# Expected: Job runs, packet created in artifacts/
# Verify: ZIP file contains conversation.json, timeline.json, summary.md, etc.
```

## Troubleshooting Tests

### Common Test Failures

#### "Module not found"
**Problem**: Module file missing or path incorrect

**Solution**:
```powershell
# Verify module exists
Get-ChildItem ./Core/*.psm1

# Check current directory
Get-Location

# Ensure you're in repository root
cd /path/to/AGenesysToolKit
```

#### "Command not found"
**Problem**: Function not exported from module

**Solution**:
```powershell
# Check module exports
Import-Module ./Core/HttpRequests.psm1 -Force
Get-Command -Module HttpRequests

# Verify Export-ModuleMember is present in module file
Get-Content ./Core/HttpRequests.psm1 | Select-String "Export-ModuleMember"
```

#### "Job never completes"
**Problem**: Runspace not closing or infinite loop

**Solution**:
```powershell
# Restart PowerShell session
exit

# Re-run test
pwsh
./tests/test-jobrunner.ps1
```

#### "OAuth timeout"
**Problem**: Browser didn't complete OAuth flow within timeout

**Solution**:
```powershell
# Increase timeout
$token = Get-GcTokenAsync -TimeoutSeconds 600  # 10 minutes

# Or manually complete OAuth faster in browser
```

#### "Access denied" or "401 Unauthorized"
**Problem**: Invalid token or expired credentials

**Solution**:
```powershell
# Clear token state
Clear-GcTokenState

# Re-authenticate
$token = Get-GcTokenAsync

# Verify token
Test-GcToken -AccessToken $token
```

### Debugging Failed Tests

#### Enable Verbose Logging
```powershell
# Run test with verbose output
$VerbosePreference = 'Continue'
./tests/smoke.ps1
```

#### Check Module Loading
```powershell
# Try loading module manually
try {
    Import-Module ./Core/HttpRequests.psm1 -Force -Verbose
} catch {
    Write-Host "Error: $($_.Exception.Message)"
    Write-Host "Stack: $($_.ScriptStackTrace)"
}
```

#### Inspect Job State
```powershell
# If JobRunner test fails, check job state
Import-Module ./Core/JobRunner.psm1 -Force
$jobs = Get-GcJobs
$jobs | Format-Table Name, Status, StartTime, Duration
```

## Test Coverage Summary

| Test Suite | Coverage | Duration | Purpose |
|------------|----------|----------|---------|
| Smoke | Core module loading | 10s | Basic functionality check |
| JobRunner | Background job system | 30s | Job execution validation |
| Parameter Flow | Authentication params | 15s | Auth parameter verification |
| OAuth | Authentication flow | 2-5min | OAuth integration |
| Integration | End-to-end features | 10-30min | Full feature validation |

## Continuous Testing

### Before Committing Code

Run this quick test sequence:

```powershell
# Quick validation (1 minute)
./tests/smoke.ps1 && ./tests/test-jobrunner.ps1

# Full validation (2 minutes)
Get-ChildItem ./tests/test-*.ps1 | Where-Object { $_.Name -match '^test-(smoke|jobrunner|parameter-flow)' } | ForEach-Object { & $_.FullName }
```

### Before Releasing

1. Run all automated tests
2. Perform manual UI testing
3. Test OAuth flow end-to-end
4. Verify at least one integration scenario
5. Check that exports work (JSON, TXT)
6. Review Job Center functionality

## Getting Help

- **Test failures**: Open an issue with the `test-failure` label
- **Integration issues**: Check [docs/CONFIGURATION.md](docs/CONFIGURATION.md)
- **OAuth problems**: See [docs/OAUTH_TESTING.md](docs/OAUTH_TESTING.md)
- **General questions**: Open an issue with the `question` label

---

**Last Updated**: 2026-01-14  
**Tested PowerShell Versions**: 5.1, 7.4  
**Tested Operating Systems**: Windows 10, Windows 11, Windows Server 2019
