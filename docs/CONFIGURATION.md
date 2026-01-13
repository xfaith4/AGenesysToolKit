# Configuration Guide

This guide explains how to configure the Genesys Cloud Tool for real operation.

## Prerequisites

1. **Genesys Cloud Account**: You need access to a Genesys Cloud organization
2. **OAuth Client**: You need to create an OAuth client in Genesys Cloud
3. **PowerShell**: PowerShell 5.1 or PowerShell 7+ on Windows

## Step 1: Create OAuth Client in Genesys Cloud

1. Log into your Genesys Cloud organization
2. Navigate to **Admin** → **Integrations** → **OAuth**
3. Click **Add Client**
4. Configure:
   - **App Name**: "Genesys Cloud Tool" (or your preferred name)
   - **Grant Type**: Select **Code Authorization**
   - **Authorized redirect URIs**: Add `http://localhost:8400/oauth/callback`
   - **Scope**: Select the following scopes:
     - `conversations` - For conversation data
     - `analytics` - For analytics queries
     - `notifications` - For real-time subscriptions
     - `users` - For user information
     - `routing` - For queue information (optional)
     - `organization` - For organization info (optional)
5. Click **Save**
6. **Copy the Client ID** - you'll need this in the next step

## Step 2: Configure the Application

Edit the file `App/GenesysCloudTool_UX_Prototype_v2_1.ps1` and update the OAuth configuration section (around line 90-95):

```powershell
# Initialize Auth Configuration (user should customize these)
Set-GcAuthConfig `
  -Region 'usw2.pure.cloud' `
  -ClientId 'YOUR_CLIENT_ID_HERE' `
  -RedirectUri 'http://localhost:8085/oauth/callback' `
  -Scopes @('conversations', 'analytics', 'notifications', 'users')
```

Replace:

- `YOUR_CLIENT_ID_HERE` with your actual OAuth Client ID
- `mypurecloud.com` with your Genesys Cloud region if different (e.g., 'mypurecloud.ie', 'mypurecloud.com.au', 'mypurecloud.jp')

### Example Configuration

```powershell
Set-GcAuthConfig `
  -Region 'usw2.pure.cloud' `
  -ClientId 'a1b2c3d4-e5f6-7890-abcd-ef1234567890' `
  -RedirectUri 'http://localhost:8085/oauth/callback' `
  -Scopes @('conversations', 'analytics', 'notifications', 'users', 'routing')
```

## Step 3: Launch the Application

From PowerShell, navigate to the repository root and run:

```powershell
.\App\GenesysCloudTool_UX_Prototype_v2_1.ps1
```

## Step 4: Authenticate

1. Click the **Login…** button in the top bar
2. Your default browser will open to the Genesys Cloud login page
3. Log in with your Genesys Cloud credentials
4. Authorize the application
5. The browser will show "Authentication Successful" - you can close the window
6. The tool will update to show "Logged in as [Your Name]"
7. Click **Test Token** to verify the token is valid

## Alternative: Manual Token Entry

If you want to use a token obtained from another source (e.g., Developer Tools, Postman, or another tool), you can manually enter it:

1. Click the **Test Token** button (without logging in via OAuth)
2. The "Manual Token Entry" dialog will open
3. Enter your **Region** (e.g., `mypurecloud.com`, `usw2.pure.cloud`, `mypurecloud.ie`)
4. Paste your **Access Token** in the text box
   - The token will be automatically sanitized (line breaks and extra whitespace removed)
   - "Bearer " prefix will be automatically removed if present
   - Multi-line paste is supported (useful when copying from browser developer tools)
5. Click **Set + Test** to validate the token
6. The tool will test the token by calling `/api/v2/users/me`
7. If successful, you'll see "Token test: OK. User: [Your Name]"

**Tips for Manual Token Entry:**

- Copy the token exactly as shown in your source (including any line breaks)
- The dialog will clean up formatting automatically
- Tokens should be at least 20 characters
- If you get a 400 Bad Request error, verify:
  - Region format is correct (no "api." prefix or "https://" scheme)
  - Token doesn't have invalid characters
  - Token was copied completely without truncation

## Using the Tool

### Money Path Flow: Login → Export Packet

Once authenticated, you can:

1. **Navigate** to Conversations → Conversation Timeline
2. **Enter a Conversation ID** in the text box
3. **Click "Build Timeline"** to load conversation data (currently mock)
4. **Click "Export Packet"** to generate a real incident packet with:
   - `conversation.json` - Raw API response
   - `timeline.json` - Normalized timeline events
   - `events.ndjson` - Subscription events (if available)
   - `transcript.txt` - Conversation transcript
   - `summary.md` - Human-readable summary
   - ZIP archive of all files

Exported packets are saved to the `artifacts/` directory.

### Alternative: Export from Subscriptions

1. Navigate to Operations → Topic Subscriptions
2. Enter a Conversation ID (optional)
3. Click "Start" to begin mock streaming
4. Click "Export Packet" to generate an incident packet

## Troubleshooting

### "Configuration Required" Error

If you see this error when clicking Login, ensure you've updated the `Set-GcAuthConfig` call in the script with your actual Client ID.

### Authentication Fails

- Verify your Client ID is correct
- Ensure the redirect URI `http://localhost:8085/oauth/callback` is configured in your OAuth client
- Check that port 8400 is not in use by another application
- Verify you're using the correct region

### Token Test Fails

**Common causes and solutions:**

#### 400 Bad Request

- **Cause**: Token has invalid format or contains line breaks/whitespace
- **Solution**: Use the Manual Token Entry dialog (click "Test Token" button)
  - The dialog will automatically clean up line breaks and extra whitespace
  - Paste the token as-is from your source; formatting will be handled automatically

#### 401 Unauthorized

- **Cause**: Token is invalid or expired (tokens typically expire after 24 hours)
- **Solution**:
  - For OAuth: Click "Login…" again to get a new token
  - For manual tokens: Obtain a fresh token from your source

#### 404 Not Found

- **Cause**: Wrong region configured or API endpoint doesn't exist
- **Solution**: Verify the region is correct:
  - US West: `usw2.pure.cloud`
  - US East: `mypurecloud.com`
  - Europe (Frankfurt): `mypurecloud.de`
  - Europe (Dublin): `mypurecloud.ie`
  - Asia Pacific (Sydney): `mypurecloud.com.au`
  - Asia Pacific (Tokyo): `mypurecloud.jp`

#### Connection Failed

- **Cause**: Cannot reach the API endpoint
- **Solution**:
  - Verify network connectivity
  - Check if region format is correct (no "api." prefix or "https://")
  - Ensure firewall isn't blocking outbound HTTPS connections

### Export Packet Fails

- Ensure you're logged in first
- Verify the Conversation ID exists and is accessible to your user
- Check the Jobs backstage (click "Jobs" button) for error details
- Required scopes: `conversations`, `analytics`

## Advanced Configuration

### Using Different Regions

Supported regions:

- `mypurecloud.com` - Americas (US East)
- `mypurecloud.com.au` - Asia Pacific (Sydney)
- `mypurecloud.ie` - EMEA (Dublin)
- `mypurecloud.de` - EMEA (Frankfurt)
- `mypurecloud.jp` - Asia Pacific (Tokyo)
- `usw2.pure.cloud` - Americas (US West)
- `cac1.pure.cloud` - Canada
- `apne2.pure.cloud` - Asia Pacific (Seoul)

Update both the `Set-GcAuthConfig` region and the `$script:AppState.Region` value.

### Custom Redirect URI

If port 8400 is unavailable, you can use a different port:

1. Update the OAuth client in Genesys Cloud to use the new redirect URI
2. Update `Set-GcAuthConfig -RedirectUri` to match

Example:

```powershell
Set-GcAuthConfig `
  -Region 'mypurecloud.com' `
  -ClientId 'your-client-id' `
  -RedirectUri 'http://localhost:9090/oauth/callback' `
  -Scopes @('conversations', 'analytics', 'notifications', 'users')
```

## Security Notes

- The OAuth flow uses PKCE (Proof Key for Code Exchange) for enhanced security
- Access tokens are stored in memory only (not persisted to disk)
- No credentials are stored in the application
- Each session requires re-authentication

## Getting Help

- Check the Jobs backstage for detailed error logs
- Review the `artifacts/` directory for exported files
- Consult the Genesys Cloud Developer Center for API documentation
