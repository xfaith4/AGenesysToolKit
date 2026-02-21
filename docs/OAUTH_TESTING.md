# OAuth Flow Testing Guide

This guide provides step-by-step instructions for testing the OAuth Authorization Code + PKCE implementation for Genesys Cloud authentication.

## Prerequisites

1. **Genesys Cloud Account** with access to an organization
2. **PowerShell 5.1 or 7+** on Windows
3. **OAuth Client** configured in Genesys Cloud (see [CONFIGURATION.md](CONFIGURATION.md))
4. **Port 8400 available** on localhost

## Testing Checklist

### 1. Initial Setup Test

**Objective**: Verify the application launches and shows proper initial state.

**Steps**:
1. Open PowerShell
2. Navigate to repository root: `cd path\to\AGenesysToolKit`
3. Launch application: `.\App\GenesysCloudTool.ps1`
4. Verify the window opens successfully

**Expected Results**:
- ✅ Window opens with title "Genesys Cloud Tool — UX Prototype v2.1"
- ✅ Top bar shows: `Region: mypurecloud.com | Org: Production | Auth: Not logged in | Token: No token`
- ✅ "Login…" button is visible and enabled
- ✅ "Test Token" button is visible but may be disabled

### 2. Configuration Warning Test

**Objective**: Verify proper error handling when OAuth client is not configured.

**Steps**:
1. Ensure `Set-GcAuthConfig` in the script has `ClientId 'YOUR_CLIENT_ID_HERE'` (default)
2. Click the "Login…" button

**Expected Results**:
- ✅ Warning dialog appears with message: "Please configure your OAuth Client ID in the script."
- ✅ Dialog shows instructions: `Set-GcAuthConfig -ClientId 'your-client-id' -Region 'your-region'`
- ✅ No browser window opens
- ✅ Button remains as "Login…"

### 3. OAuth Login Flow Test (Full Flow)

**Objective**: Test the complete OAuth authorization code + PKCE flow.

**Preparation**:
1. Configure your OAuth Client ID in `App\GenesysCloudTool.ps1`:
   ```powershell
   Set-GcAuthConfig `
     -Region 'mypurecloud.com' `
     -ClientId 'YOUR_ACTUAL_CLIENT_ID' `
     -RedirectUri 'http://localhost:8400/oauth/callback' `
     -Scopes @('conversations', 'analytics', 'notifications', 'users')
   ```
2. Ensure OAuth client in Genesys Cloud has redirect URI: `http://localhost:8400/oauth/callback`
3. Restart the application if you edited the script

**Steps**:
1. Click the "Login…" button
2. Observe the button text change
3. Wait for browser to open
4. Log in to Genesys Cloud (if not already logged in)
5. Authorize the application
6. Observe the browser callback page
7. Return to the application

**Expected Results**:
- ✅ Button text changes to "Authenticating..."
- ✅ Button becomes disabled during authentication
- ✅ Status bar shows: "Starting OAuth flow..."
- ✅ Jobs backstage shows a job: "OAuth Login" with status "Running"
- ✅ System default browser opens to Genesys Cloud login page
- ✅ URL contains:
  - `https://login.mypurecloud.com/oauth/authorize`
  - `response_type=code`
  - `client_id=<your-client-id>`
  - `redirect_uri=http://localhost:8400/oauth/callback`
  - `code_challenge=<base64-string>`
  - `code_challenge_method=S256`
  - `state=<random-string>`
- ✅ After authorization, browser shows: "Authentication Successful" with message "You can close this window."
- ✅ Application updates:
  - Button text changes to "Logout"
  - Button becomes enabled
  - Status bar shows: "Authentication successful!"
  - Top bar shows: `Auth: Logged in as <Your Name>`
  - Top bar shows: `Token: Token OK`
  - "Test Token" button becomes enabled
- ✅ Job completes successfully in Jobs backstage

### 4. Token Test

**Objective**: Verify the token is valid by calling the Genesys Cloud API.

**Steps**:
1. After successful login, click the "Test Token" button
2. Wait for the request to complete

**Expected Results**:
- ✅ Button text changes to "Testing..."
- ✅ Button becomes disabled temporarily
- ✅ Status bar shows: "Testing token..."
- ✅ After completion:
  - Button returns to "Test Token"
  - Button becomes enabled
  - Status bar shows: "Token test: OK. User: <Your Name> | Org: <Org Name>"
  - Top bar updates with organization name

### 5. Logout Test

**Objective**: Verify logout clears token and resets UI state.

**Steps**:
1. Ensure you are logged in (button shows "Logout")
2. Click the "Logout" button
3. Observe the UI changes

**Expected Results**:
- ✅ Status bar shows: "Logged out successfully."
- ✅ Button text changes to "Login…"
- ✅ Button remains enabled
- ✅ Top bar shows: `Auth: Not logged in`
- ✅ Top bar shows: `Token: No token`
- ✅ "Test Token" button becomes disabled
- ✅ Token is cleared from memory (can verify by clicking "Test Token" - it should show "No token available")

### 6. Re-login Test

**Objective**: Verify you can log in again after logout.

**Steps**:
1. After logout, click the "Login…" button
2. Complete the OAuth flow again

**Expected Results**:
- ✅ OAuth flow works identically to the first login
- ✅ Browser may skip login if session still active
- ✅ Application returns to logged-in state
- ✅ Button shows "Logout"

### 7. Timeout Test

**Objective**: Verify proper handling when OAuth flow times out.

**Steps**:
1. Click "Login…"
2. When browser opens, **do not** complete the login
3. Wait for 5+ minutes (default timeout is 300 seconds)

**Expected Results**:
- ✅ After timeout, job fails
- ✅ Status bar shows: "Authentication failed. Check job logs for details."
- ✅ Button returns to "Login…"
- ✅ Button becomes enabled
- ✅ Jobs backstage shows error in logs
- ✅ HTTP listener stops cleanly

### 8. Cancel Test

**Objective**: Verify proper handling when user cancels OAuth flow.

**Steps**:
1. Click "Login…"
2. When browser opens, close the browser tab/window without authorizing
3. Wait a few seconds

**Expected Results**:
- ✅ Application handles gracefully
- ✅ Eventually times out or shows error
- ✅ Button returns to "Login…"
- ✅ HTTP listener stops cleanly

### 9. Port In Use Test

**Objective**: Verify error handling when port 8400 is already in use.

**Preparation**:
1. Before launching the app, start a process on port 8400:
   ```powershell
   # In separate PowerShell window
   $listener = New-Object System.Net.HttpListener
   $listener.Prefixes.Add("http://localhost:8400/")
   $listener.Start()
   Write-Host "Listener started on port 8400. Press Ctrl+C to stop."
   while ($listener.IsListening) { Start-Sleep -Seconds 1 }
   ```

**Steps**:
1. Launch the application
2. Click "Login…"
3. Observe error handling

**Expected Results**:
- ✅ Error is logged in Jobs backstage
- ✅ Application shows authentication failed
- ✅ Button returns to "Login…"
- ✅ User-friendly error message (if implemented)

**Cleanup**:
- Press Ctrl+C in the PowerShell window that started the listener

### 10. Network Error Test

**Objective**: Verify error handling when network is unavailable.

**Steps**:
1. Disconnect from network or use invalid region
2. Attempt to log in

**Expected Results**:
- ✅ Error is handled gracefully
- ✅ Jobs backstage shows connection error
- ✅ Button returns to "Login…"

### 11. Export Packet with Token Test

**Objective**: Verify authenticated API calls work for real operations.

**Steps**:
1. Log in successfully
2. Navigate to: Conversations → Conversation Timeline
3. Enter a valid conversation ID (or leave blank for mock)
4. Click "Export Packet"

**Expected Results**:
- ✅ Real export job runs (if valid conversation ID provided)
- ✅ Uses authenticated token for API calls
- ✅ Packet is generated and saved to `artifacts/` directory
- ✅ Snackbar notification appears with "Export complete"
- ✅ Artifact appears in Artifacts backstage

### 12. Token Expiry Test

**Objective**: Verify handling of expired tokens.

**Steps**:
1. Log in successfully
2. Wait for token to expire (typically 24 hours, not practical for testing)
3. Alternatively, manually clear `$script:AppState.AccessToken` in PowerShell console
4. Try to use "Test Token" or "Export Packet"

**Expected Results**:
- ✅ API calls fail with 401 Unauthorized
- ✅ Error messages indicate token is invalid
- ✅ User is prompted to log in again

## Manual Verification

### PKCE Implementation Details

To verify PKCE is correctly implemented, inspect the OAuth authorization URL in the browser:

1. Click "Login…"
2. Copy the URL from the browser address bar
3. Decode the URL parameters

**Required Parameters**:
- `code_challenge`: Base64URL-encoded SHA256 hash of the verifier
- `code_challenge_method`: Must be "S256"
- `state`: Random state parameter for CSRF protection

### HTTP Listener Behavior

To verify the HTTP listener is working correctly:

1. During OAuth flow, navigate to: `http://localhost:8400/oauth/callback?code=test123&state=abc`
2. Observe the response page

**Expected**:
- ✅ Page loads (even with invalid code)
- ✅ Listener responds with HTML
- ✅ Listener stops after first request

### Token Exchange

The token exchange happens automatically. To verify:

1. Check Jobs backstage logs during login
2. Look for successful OAuth flow completion

**Expected Log Entries**:
- "OAuth Login" job starts
- "Queued." message
- Job progress updates
- Job completes with "Completed." status

## Troubleshooting

### Browser doesn't open

**Possible causes**:
- No default browser configured
- Browser blocked by security software
- URL too long (unlikely with standard config)

**Solutions**:
- Manually copy the authorization URL from console output
- Check Windows default browser settings
- Temporarily disable security software

### "Authentication failed" message

**Common causes**:
1. **Port in use**: Close other applications using port 8400
2. **Invalid Client ID**: Verify Client ID in Genesys Cloud matches configuration
3. **Redirect URI mismatch**: Ensure OAuth client has exact redirect URI: `http://localhost:8400/oauth/callback`
4. **Timeout**: Complete authorization within 5 minutes
5. **Network issues**: Check internet connection

**Debug steps**:
1. Open Jobs backstage
2. Select "OAuth Login" job
3. Review logs for detailed error messages
4. Check for HTTP errors (401, 404, 500, etc.)

### "Token test failed" after successful login

**Possible causes**:
- Token expired (unlikely immediately after login)
- Invalid scopes (missing required scopes)
- Network issues
- Wrong region configured

**Solutions**:
- Click "Logout" then "Login…" to get fresh token
- Verify scopes in OAuth client include: `conversations`, `analytics`, `notifications`, `users`
- Verify region matches your Genesys Cloud organization

### Export Packet fails

**Requirements**:
- Valid access token (log in first)
- Valid conversation ID
- Conversation must be accessible to your user
- Required scopes: `conversations`, `analytics`

**Debug steps**:
1. Verify token is valid: Click "Test Token"
2. Check conversation ID is correct format (UUID or "c-NNNNNN")
3. Review Jobs backstage for specific error

## Security Verification

### PKCE Flow Validation

Verify PKCE is correctly implemented by checking:

1. **Code Verifier**: 
   - Random, cryptographically secure
   - 43-128 characters
   - Base64URL encoded

2. **Code Challenge**:
   - SHA256 hash of code verifier
   - Base64URL encoded
   - Sent in authorization request

3. **Code Exchange**:
   - Code verifier sent in token exchange
   - Server validates challenge matches verifier

### State Parameter

Verify CSRF protection:
- Random state generated for each flow
- State sent in authorization request
- State validated in callback
- Warning logged if state mismatch detected

### Token Storage

Verify secure token handling:
- Token stored in memory only
- Not written to disk
- Cleared on logout
- Not exposed in logs

## Success Criteria

All tests pass with expected results:
- ✅ OAuth flow completes successfully
- ✅ PKCE challenge and verifier are generated correctly
- ✅ Browser opens to correct authorization URL
- ✅ Local HTTP listener captures callback
- ✅ Authorization code exchanged for token
- ✅ Token stored in AppState
- ✅ UI updates show logged-in state
- ✅ Logout clears token and resets UI
- ✅ Re-login works after logout
- ✅ Token can be used for API calls
- ✅ HTTP listener stops cleanly after callback or timeout
- ✅ Error handling is graceful and user-friendly

## Automation Considerations

While this guide focuses on manual testing, consider these for future automation:

1. **Mock OAuth Server**: Create a local mock server to simulate Genesys Cloud OAuth endpoints
2. **Automated Browser**: Use Selenium or similar to automate browser interactions
3. **Unit Tests**: Test PKCE generation, URL building, token exchange logic independently
4. **Integration Tests**: Test full flow with mock server

## Reporting Issues

If you encounter issues during testing:

1. Document the exact steps to reproduce
2. Capture error messages from:
   - Status bar
   - Jobs backstage logs
   - PowerShell console output
3. Note your environment:
   - PowerShell version (`$PSVersionTable.PSVersion`)
   - Windows version
   - Genesys Cloud region
4. Check port 8400 availability: `netstat -an | findstr :8400`
5. Open a GitHub issue with all details

## Additional Resources

- [OAuth 2.0 RFC 6749](https://datatracker.ietf.org/doc/html/rfc6749)
- [PKCE RFC 7636](https://datatracker.ietf.org/doc/html/rfc7636)
- [Genesys Cloud OAuth Documentation](https://developer.genesys.cloud/authorization/platform-auth/)
