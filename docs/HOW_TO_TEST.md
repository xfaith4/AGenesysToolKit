# How to Test OAuth Implementation

This document provides quick-start instructions for testing the OAuth Authorization Code + PKCE implementation.

## Quick Test (5 minutes)

This test verifies the OAuth flow works end-to-end with a real Genesys Cloud account.

### Prerequisites

1. ✅ Windows machine with PowerShell 5.1 or 7+
2. ✅ Genesys Cloud account with admin access
3. ✅ Internet connection
4. ✅ Port 8400 available on localhost

### Step 1: Create OAuth Client (One-time setup)

1. Log into your Genesys Cloud organization
2. Navigate to: **Admin** → **Integrations** → **OAuth**
3. Click **Add Client**
4. Configure:
   - **App Name**: `Genesys Cloud Tool Test`
   - **Grant Type**: Select **Code Authorization** (with PKCE)
   - **Authorized redirect URIs**: 
     ```
     http://localhost:8400/oauth/callback
     ```
   - **Scope**: Select these scopes:
     - ☑ conversations
     - ☑ analytics
     - ☑ notifications
     - ☑ users
5. Click **Save**
6. **Copy the Client ID** - you'll need it in the next step

### Step 2: Configure Application

1. Open `App/GenesysCloudTool.ps1` in a text editor
2. Find the `Set-GcAuthConfig` section (around line 94)
3. Replace `YOUR_CLIENT_ID_HERE` with your actual Client ID from Step 1
4. Verify the region matches your organization (e.g., `mypurecloud.com`, `mypurecloud.ie`)
5. Save the file

Example configuration:
```powershell
Set-GcAuthConfig `
  -Region 'mypurecloud.com' `
  -ClientId 'a1b2c3d4-e5f6-7890-abcd-ef1234567890' `
  -RedirectUri 'http://localhost:8400/oauth/callback' `
  -Scopes @('conversations', 'analytics', 'notifications', 'users')
```

### Step 3: Test Login Flow

1. Open PowerShell
2. Navigate to the repository root:
   ```powershell
   cd C:\path\to\AGenesysToolKit
   ```
3. Launch the application:
   ```powershell
   .\App\GenesysCloudTool.ps1
   ```
4. Click the **Login…** button in the top-right corner
5. Your browser will open to the Genesys Cloud login page
6. Log in with your Genesys Cloud credentials (if not already logged in)
7. Click **Authorize** to grant the application access
8. The browser will show "Authentication Successful" - you can close it
9. Return to the application

**✅ Success Indicators:**
- Button changes to "Logout"
- Top bar shows: `Auth: Logged in as <Your Name>`
- Top bar shows: `Token: Token OK`
- Status bar shows: "Authentication successful!"
- "Test Token" button is enabled

### Step 4: Test Token

1. Click the **Test Token** button
2. Wait for the test to complete (2-3 seconds)

**✅ Success Indicators:**
- Status bar shows: "Token test: OK. User: <Your Name> | Org: <Org Name>"
- No error dialogs appear

### Step 5: Test Logout

1. Click the **Logout** button
2. Observe the UI changes

**✅ Success Indicators:**
- Button changes back to "Login…"
- Top bar shows: `Auth: Not logged in`
- Top bar shows: `Token: No token`
- Status bar shows: "Logged out successfully."
- "Test Token" button is disabled

### Step 6: Test Re-login

1. Click **Login…** again
2. Browser opens (may skip login if still logged in to Genesys Cloud)
3. Authorize again
4. Verify you're logged back in

**✅ Success Indicators:**
- Same as Step 3
- Button shows "Logout"
- Token is valid

## Testing Real API Calls

Once logged in, you can test that the token works for real API calls:

### Test Export Packet

1. Ensure you're logged in (button shows "Logout")
2. Navigate to: **Conversations** → **Conversation Timeline**
3. Enter a valid Conversation ID from your organization
   - Format: UUID or `c-NNNNNN`
   - Must be a conversation you have access to
4. Click **Build Timeline**
5. Click **Export Packet**
6. Wait for the export job to complete

**✅ Success Indicators:**
- Job appears in Jobs backstage with status "Running" → "Completed"
- Snackbar notification: "Export complete"
- Artifact appears in `artifacts/` directory
- ZIP file contains:
  - `conversation.json`
  - `timeline.json`
  - `transcript.txt`
  - `summary.md`

## Troubleshooting

### "Configuration Required" Error

**Problem**: Warning dialog appears when clicking Login.

**Solution**: 
- Verify you updated `ClientId` in `Set-GcAuthConfig`
- Ensure you replaced `YOUR_CLIENT_ID_HERE` with your actual Client ID
- Restart the application after editing the script

### Browser Doesn't Open

**Problem**: Clicking Login doesn't open browser.

**Solution**:
- Check PowerShell console for errors
- Verify Windows default browser is set
- Try manually opening the authorization URL (shown in Jobs backstage logs)

### "Authentication failed"

**Common Causes**:

1. **Port 8400 in use**
   - Check: `netstat -an | findstr :8400`
   - Solution: Close application using port 8400, or use different port

2. **Redirect URI mismatch**
   - Verify OAuth client has exact URI: `http://localhost:8400/oauth/callback`
   - Check for typos (http vs https, port number, path)

3. **Client ID incorrect**
   - Double-check Client ID in OAuth client matches configuration
   - Ensure no extra spaces or characters

4. **Wrong region**
   - Verify region in config matches your Genesys Cloud organization
   - Common regions: `mypurecloud.com`, `mypurecloud.ie`, `mypurecloud.de`

### "Token test failed"

**Problem**: Token test shows error after successful login.

**Solution**:
- Click Logout then Login again to get fresh token
- Verify scopes include `users` scope
- Check region is correct
- Check Jobs backstage for detailed error message

### Export Packet Fails

**Problem**: Export packet job fails with error.

**Solution**:
- Verify you're logged in (click Test Token)
- Ensure Conversation ID is valid and accessible
- Check required scopes: `conversations`, `analytics`
- Try a different Conversation ID

## Viewing Logs

For detailed troubleshooting:

1. Click **Jobs** button in top bar
2. Select the failed job from the list
3. Review the logs in the right panel
4. Look for specific error messages (401, 404, timeout, etc.)

## Advanced Testing

For comprehensive testing including timeout, cancellation, and edge cases, see:
- [docs/OAUTH_TESTING.md](OAUTH_TESTING.md) - Full test suite with 12+ test scenarios

## Automated Tests

Run automated unit tests:

```powershell
# Smoke tests (verify modules load)
.\tests\smoke.ps1

# Auth module unit tests
.\tests\test-auth.ps1
```

## Success Checklist

- [x] Application launches without errors
- [x] Login button opens browser
- [x] OAuth flow completes successfully
- [x] Button changes to "Logout"
- [x] Token test passes
- [x] Logout clears token
- [x] Re-login works
- [x] Export packet works with real conversation ID

## Getting Help

If tests fail:

1. Review error messages in Jobs backstage
2. Check [docs/CONFIGURATION.md](CONFIGURATION.md) for setup details
3. See [docs/OAUTH_TESTING.md](OAUTH_TESTING.md) for comprehensive test scenarios
4. Open GitHub issue with:
   - Exact error message
   - Steps to reproduce
   - PowerShell version: `$PSVersionTable.PSVersion`
   - Screenshot of error (if applicable)

## Next Steps

Once OAuth is working:

1. ✅ Test other features (Subscriptions, Timeline, etc.)
2. ✅ Configure additional scopes if needed
3. ✅ Review [docs/ROADMAP.md](ROADMAP.md) for upcoming features
4. ✅ Explore the codebase and contribute improvements

## Notes

- **Security**: Tokens are stored in memory only, never written to disk
- **PKCE**: Implementation follows RFC 7636 (OAuth 2.0 PKCE)
- **Compatibility**: Works with PowerShell 5.1 and 7+
- **No External Dependencies**: Uses only built-in .NET classes
- **Port**: Default is 8400, but can be changed in configuration

## Minimum Test (30 seconds)

If you just want to verify the code runs:

1. Launch application: `.\App\GenesysCloudTool.ps1`
2. Click Login (expect "Configuration Required" warning)
3. Close application

This verifies:
- ✅ Application loads
- ✅ UI renders
- ✅ Button handlers work
- ✅ Configuration validation works

For full OAuth testing, you need a configured OAuth client (Steps 1-6 above).
