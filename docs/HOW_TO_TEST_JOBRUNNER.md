# How to Test JobRunner Implementation

This document provides step-by-step instructions for testing the runspace-based JobRunner implementation that replaces JobSim.

## Overview

The JobRunner implementation provides:
- **Real background execution** using PowerShell runspaces (no ThreadJob dependency)
- **Thread-safe log streaming** via ObservableCollection
- **Cancellation support** with CancellationRequested flag
- **Status tracking**: Queued → Running → Completed/Failed/Canceled
- **Time tracking**: StartTime, EndTime, Duration
- **PowerShell 5.1 and 7+ compatibility**

## Automated Tests

### 1. Run Smoke Tests

Verify all core modules load correctly:

```powershell
# From repository root
./tests/smoke.ps1
```

**Expected Output:**
```
✓ SMOKE PASS
Tests Passed: 10
Tests Failed: 0
```

### 2. Run JobRunner Tests

Test the JobRunner module directly (12 tests):

```powershell
# From repository root
./tests/test-jobrunner.ps1
```

**Expected Output:**
```
✓ ALL TESTS PASS
Tests Passed: 12
Tests Failed: 0
```

**Tests covered:**
- Job context creation
- Log entry management
- Script block execution
- Parameter passing
- Complex return types
- Status transitions
- Completion callbacks
- Running jobs collection
- Log timeline capture
- PowerShell version compatibility
- Runspace isolation
- Error handling

## Manual UI Testing

### Prerequisites

1. **Windows** with PowerShell 5.1 or 7+
2. **Genesys Cloud OAuth Client** (for real API calls)
   - See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for setup

### Test Scenarios

#### Scenario 1: Subscription Connection (Simple Job)

**Purpose:** Verify jobs execute and update UI responsively

**Steps:**
1. Launch the application:
   ```powershell
   ./App/GenesysCloudTool_UX_Prototype_v2_1.ps1
   ```

2. Navigate to **Operations → Topic Subscriptions**

3. Click **Start Subscription**
   - **Expected:** Job appears in Jobs badge count (e.g., "Jobs (1)")
   - **Expected:** Button becomes "Starting..." briefly
   - **Expected:** After ~1.2 seconds, job completes
   - **Expected:** UI updates: "Subscription started" status message
   - **Expected:** Start button disabled, Stop button enabled

4. Click **Jobs** button in top bar
   - **Expected:** Backstage opens showing job list
   - **Expected:** Job shows "Completed" status with timestamps
   - **Expected:** Job logs show "Queued", "Started", "Completed" entries with timestamps

5. Click **Stop Subscription**
   - **Expected:** New job executes (~0.7 seconds)
   - **Expected:** UI updates: "Subscription stopped" status message
   - **Expected:** Start button enabled, Stop button disabled

**Verification:**
- ✅ UI remains responsive during job execution
- ✅ Jobs badge count increments/decrements correctly
- ✅ Job status transitions: Queued → Running → Completed
- ✅ Logs capture execution timeline
- ✅ No errors in PowerShell console

---

#### Scenario 2: Export Packet (Mock - No Auth)

**Purpose:** Verify background jobs with file I/O

**Steps:**
1. Navigate to **Operations → Topic Subscriptions**

2. Click **Export Packet** (without logging in)
   - **Expected:** Warning dialog: "Please log in first..."
   - **Expected:** Click OK to proceed with mock export

3. Job executes (~1.4 seconds)
   - **Expected:** Job appears in Jobs badge
   - **Expected:** Job completes successfully
   - **Expected:** Snackbar notification: "Export complete (mock)"
   - **Expected:** Artifact added to Artifacts badge count

4. Click **Artifacts** button
   - **Expected:** Backstage shows artifact with mock packet file path
   - **Expected:** Click "Open Selected" to view file
   - **Expected:** File contains mock packet data

**Verification:**
- ✅ Background job creates file without blocking UI
- ✅ Artifacts collection updates correctly
- ✅ Snackbar notification appears
- ✅ File I/O completes successfully

---

#### Scenario 3: Test Token (Real API Call)

**Purpose:** Verify real API calls execute in background

**Prerequisites:**
- Valid OAuth token (either via Login or manually set in script)

**Steps:**
1. **Option A - OAuth Login:**
   - Click **Login** button
   - Complete OAuth flow in browser
   - Job runs: "OAuth Login"
   - **Expected:** Success message, token stored

2. **Option B - Manual Token (for quick testing):**
   ```powershell
   # Before launching app, edit the script and set:
   $script:AppState.AccessToken = "YOUR_VALID_TOKEN_HERE"
   ```

3. Click **Test Token** button
   - **Expected:** Job "Test Token" starts
   - **Expected:** Job makes GET /api/v2/users/me API call
   - **Expected:** Job completes with success message showing username/org

4. Check job logs
   - **Expected:** No errors
   - **Expected:** API response data captured

**Verification:**
- ✅ Real API call executes in background
- ✅ Token validation works correctly
- ✅ User info displayed in status bar
- ✅ No UI blocking during API call

---

#### Scenario 4: Export Packet (Real - With Auth)

**Purpose:** Verify complex background job with multiple API calls

**Prerequisites:**
- Valid OAuth token (logged in)

**Steps:**
1. Navigate to **Conversations → Conversation Timeline**

2. Enter a valid Conversation ID (or use mock ID)

3. Click **Export Packet**
   - **Expected:** Job "Export Incident Packet — {id}" starts
   - **Expected:** Job runs for several seconds (API calls + file generation)
   - **Expected:** Job completes successfully
   - **Expected:** Snackbar notification with ZIP file path
   - **Expected:** Artifact added with ZIP file

4. Check Artifacts backstage
   - **Expected:** ZIP file contains:
     - conversation.json
     - timeline.json
     - events.ndjson
     - transcript.txt
     - summary.md

5. Verify job logs show:
   - "Started (Export)"
   - API call progress (if ArtifactGenerator logs to job)
   - "Completed"

**Verification:**
- ✅ Multi-step background job completes
- ✅ Files created successfully
- ✅ ZIP archive generated
- ✅ No errors during execution
- ✅ UI responsive throughout

---

#### Scenario 5: Job Cancellation

**Purpose:** Verify cancellation support (future enhancement)

**Note:** Cancellation is implemented but not wired to UI buttons yet. To test:

```powershell
# In PowerShell console after starting a long job:
$job = $script:AppState.Jobs[0]  # Get first job
Stop-GcJob -Job $job

# Expected: Job status changes to "Canceled"
# Expected: Job logs show "Cancellation requested..."
```

**Verification:**
- ✅ Stop-GcJob sets CancellationRequested flag
- ✅ Job monitoring loop detects cancellation
- ✅ Job status updated to "Canceled"
- ✅ Cleanup runs (runspace closed)

---

## PowerShell Version Compatibility

Test on both PowerShell versions:

### PowerShell 5.1 (Windows)
```powershell
powershell.exe -File ./tests/test-jobrunner.ps1
powershell.exe -File ./tests/smoke.ps1
```

### PowerShell 7+
```powershell
pwsh -File ./tests/test-jobrunner.ps1
pwsh -File ./tests/smoke.ps1
```

**Verification:**
- ✅ All tests pass on both versions
- ✅ No ThreadJob module dependency
- ✅ Runspace creation works correctly

---

## Performance Testing

### Verify No UI Blocking

1. Start a job (e.g., Test Token)
2. While job is running, try:
   - Clicking other buttons
   - Navigating between workspaces
   - Resizing window
   - Scrolling lists

**Expected:** All UI interactions remain responsive

### Verify Multiple Concurrent Jobs

1. Quickly click:
   - Start Subscription
   - Test Token
   - Export Packet

**Expected:**
- All jobs queue and execute
- Jobs badge shows correct count
- All complete successfully
- No race conditions or errors

---

## Troubleshooting

### Issue: Jobs badge count doesn't update

**Cause:** Jobs collection binding issue

**Fix:** Verify `$script:AppState.Jobs` is ObservableCollection

### Issue: Job stuck in "Running" status

**Cause:** Exception in script block

**Check:**
- Job logs for error messages
- Job.Errors collection
- PowerShell console for uncaught exceptions

### Issue: "Unable to find type [Windows.Threading.Dispatcher]" in tests

**Cause:** Running tests in non-GUI PowerShell session (expected)

**Expected:** Tests pass with non-WPF fallback path (synchronous execution)

### Issue: Real API calls fail

**Cause:** Invalid or expired token

**Fix:**
1. Verify token is valid: `Test-GcToken`
2. Re-authenticate: Click Login button
3. Check OAuth client configuration

---

## Success Criteria

✅ **All automated tests pass** (smoke + jobrunner)

✅ **UI remains responsive** during all job executions

✅ **Jobs badge count** updates correctly

✅ **Job status transitions** work correctly: Queued → Running → Completed/Failed

✅ **Job logs** capture execution timeline with timestamps

✅ **Background jobs** execute without blocking UI thread

✅ **Real API calls** work in Test Token scenario

✅ **File I/O** works in Export Packet scenarios

✅ **No errors** in PowerShell console during normal operation

✅ **PowerShell 5.1 and 7+** both work correctly

---

## Next Steps

After verifying all test scenarios pass:

1. **Review job logs** for any unexpected warnings
2. **Monitor memory usage** during extended sessions
3. **Test cancellation** when UI cancel buttons are wired
4. **Test error handling** with invalid API calls
5. **Stress test** with 10+ concurrent jobs

---

## References

- **JobRunner Implementation:** [Core/JobRunner.psm1](../Core/JobRunner.psm1)
- **Start-AppJob Usage:** [App/GenesysCloudTool_UX_Prototype_v2_1.ps1](../App/GenesysCloudTool_UX_Prototype_v2_1.ps1)
- **OAuth Setup:** [docs/CONFIGURATION.md](CONFIGURATION.md)
- **Architecture:** [docs/ARCHITECTURE.md](ARCHITECTURE.md)
