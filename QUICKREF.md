# Quick Reference Guide - AGenesysToolKit

Quick reference for common tasks and workflows. For detailed documentation, see [README.md](README.md).

## Table of Contents

- [First-Time Setup](#first-time-setup)
- [Daily Operations](#daily-operations)
- [Common Tasks](#common-tasks)
- [Troubleshooting](#troubleshooting)
- [Keyboard Shortcuts](#keyboard-shortcuts)

## First-Time Setup

### 1. Install and Verify

```powershell
# Clone repository
git clone https://github.com/xfaith4/AGenesysToolKit.git
cd AGenesysToolKit

# Run smoke tests
./tests/smoke.ps1
# Expected: 10/10 tests pass
```

### 2. Configure OAuth

```powershell
# Edit main application file
notepad App/GenesysCloudTool.ps1

# Find and update this section:
Set-GcAuthConfig `
  -ClientId 'YOUR-CLIENT-ID-HERE' `
  -Region 'usw2.pure.cloud' `
  -RedirectUri 'http://localhost:8085/callback'
```

**Need an OAuth client?** See [CONFIGURATION.md](docs/CONFIGURATION.md)

### 3. Launch and Authenticate

```powershell
# Launch application
./App/GenesysCloudTool.ps1

# In UI:
# 1. Click "Login..." button
# 2. Browser opens → Grant permissions
# 3. Return to app → Status shows "Authenticated as: [your name]"
```

## Daily Operations

### Quick Launch

```powershell
# From repository root
./App/GenesysCloudTool.ps1
```

**Tip**: Create a desktop shortcut for one-click launch. See [DEPLOYMENT.md](DEPLOYMENT.md).

### Common Workflows

#### 🔍 Investigate an Incident

1. **Operations → Topic Subscriptions** → Click "Start"
2. Wait for relevant event to appear in stream
3. Click "Open Timeline" (or enter conversation ID manually)
4. Review timeline events (time, category, label, details)
5. Click "Export Packet" to save all artifacts

**Result**: ZIP file in `artifacts/` with everything needed for analysis

#### 📊 Check Queue Health

1. **Routing & People → Routing Snapshot**
2. Click "Refresh" (or enable auto-refresh)
3. Review health indicators:
   - 🟢 Green: < 5 waiting
   - 🟡 Yellow: 5-10 waiting
   - 🔴 Red: > 10 waiting
4. Export snapshot if needed

**Auto-refresh**: Checkbox enables 30-second refresh

#### 📉 Analyze Abandonment

1. **Conversations → Abandon & Experience**
2. Select date range (Last 1h, 6h, 24h, 7 days)
3. Click "Query"
4. Review metrics:
   - Abandonment rate
   - Total offered vs. abandoned
   - Average wait time
5. Scroll to see list of abandoned conversations
6. Export if needed

#### 🎤 Access Recordings

1. **Conversations → Media & Quality**
2. Go to **Recordings** tab
3. Enter conversation ID
4. Click "Load Recordings"
5. Review metadata (duration, timestamps)
6. Export list if needed

**Transcripts**: Use **Transcripts** tab, enter conversation ID

**Evaluations**: Use **Quality Evaluations** tab for quality scores

## Common Tasks

### Export Data

**Any view with "Export" button**:
1. Click "Export"
2. Choose format (JSON is always available, TXT usually available)
3. File saved to `artifacts/` directory
4. Snackbar notification: "Export complete! [Open Folder]"
5. Click "Open Folder" to view file

**Formats**:
- **JSON**: Pretty-printed, easy to parse
- **TXT**: Tab-delimited or formatted text
- **XLSX**: If ImportExcel module installed

### Search Conversations

1. **Conversations → Conversation Lookup**
2. Enter search criteria:
   - Conversation ID
   - Date range
   - Queue
   - Direction (Inbound/Outbound)
3. Click "Search"
4. Results appear in grid
5. Select conversation → Click "View Details"

### List Users

1. **Routing & People → Users & Presence**
2. Click "List Users"
3. Grid populates with all users
4. Columns: Name, Email, Department, State
5. Click "Export" to save list

### Export Configuration

1. **Orchestration → Config Export**
2. Select export type:
   - Flows only
   - Queues only
   - Full config
3. Click "Export"
4. Job runs in background (track in Admin → Job Center)
5. ZIP file created in `artifacts/`

### Search Dependencies

1. **Orchestration → Dependency / Impact Map**
2. Select object type (Queue, Data Action, Schedule, Skill)
3. Enter object ID
4. Click "Search"
5. Results show flows that reference the object
6. Review occurrence count

### Monitor Jobs

1. **Admin → Job Center**
2. View all active and completed jobs
3. Job details:
   - Name, Status, Start time, Duration
   - Logs (click "View Logs")
4. Cancel running jobs if needed
5. Clear completed jobs (click "Clear Completed")

## Troubleshooting

### "Not Authenticated"

**Problem**: Status bar shows "Not authenticated"

**Solution**:
```powershell
# In UI:
1. Click "Login..." button
2. Complete OAuth flow in browser
3. Return to application

# If still fails:
1. Click "Logout" if available
2. Close and restart application
3. Try "Login..." again
```

### "OAuth Timeout"

**Problem**: Browser opened but OAuth didn't complete

**Solution**:
- Complete OAuth flow faster (< 5 minutes default timeout)
- Or increase timeout in code:
  ```powershell
  $token = Get-GcTokenAsync -TimeoutSeconds 600  # 10 minutes
  ```

### "Job Failed"

**Problem**: Job shows "Failed" status in Job Center

**Solution**:
1. Click "View Logs" in Job Center
2. Review error message at bottom of log
3. Common causes:
   - Invalid conversation ID
   - Insufficient permissions
   - Network timeout
4. Fix issue and retry operation

### "Access Denied / 401"

**Problem**: API calls fail with authentication errors

**Solution**:
1. Verify OAuth client has required permissions
2. Click "Logout" → "Login..." to re-authenticate
3. If persists, check OAuth client configuration in Genesys Cloud Admin

### "Module Not Found"

**Problem**: Error loading modules on startup

**Solution**:
```powershell
# Verify all files present
Get-ChildItem ./Core/*.psm1

# Re-run smoke tests
./tests/smoke.ps1

# If tests fail, re-download application
```

### Export Not Working

**Problem**: "Export" button doesn't create file

**Solution**:
1. Check `artifacts/` directory exists
2. Verify disk space available
3. Check Windows Event Viewer for file system errors
4. Try exporting to different format

## Keyboard Shortcuts

### Application-Wide

| Shortcut | Action |
|----------|--------|
| `Ctrl+L` | Open Login dialog |
| `Ctrl+J` | Open Job Center |
| `Ctrl+S` | Open Settings |
| `Ctrl+Q` | Quit application |
| `F5` | Refresh current view |

### Job Center

| Shortcut | Action |
|----------|--------|
| `Ctrl+C` | Cancel selected job |
| `Ctrl+L` | View logs for selected job |
| `Del` | Clear completed jobs |

### Data Grids

| Shortcut | Action |
|----------|--------|
| `Ctrl+F` | Find in grid |
| `Ctrl+A` | Select all rows |
| `Ctrl+C` | Copy selected rows |
| `Ctrl+E` | Export grid data |

**Note**: Some shortcuts may vary based on focus. Check status bar for context-sensitive shortcuts.

## Power User Tips

### Batch Operations

**Export multiple conversations**:
1. Use Conversation Lookup to find conversations
2. Select multiple rows (Ctrl+Click)
3. Right-click → "Export Selected"

### Custom Date Ranges

**For queries that accept date range**:
1. Use date picker for common ranges (1h, 6h, 24h, 7d)
2. Or enter custom ISO 8601 timestamps:
   - Start: `2026-01-01T00:00:00Z`
   - End: `2026-01-14T23:59:59Z`

### Artifact Management

**Organize exports**:
```powershell
# Clean up old artifacts (> 30 days)
$artifactsPath = "./artifacts"
Get-ChildItem -Path $artifactsPath -Recurse | 
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
  Remove-Item -Force -Recurse
```

### Auto-Refresh Everything

**Enable auto-refresh on multiple views**:
1. Open Routing Snapshot → Enable auto-refresh
2. Open Abandon & Experience → Set to 1-hour range
3. Position windows side-by-side
4. Both will refresh automatically

### Advanced Queries

**For Analytics Jobs**:
```json
{
  "interval": "2026-01-01T00:00:00Z/2026-01-14T23:59:59Z",
  "order": "asc",
  "orderBy": "conversationStart",
  "segmentFilters": [
    {
      "type": "and",
      "predicates": [
        {
          "dimension": "queueId",
          "value": "your-queue-id"
        }
      ]
    }
  ]
}
```

## Configuration Files

### User Settings

Location: `%APPDATA%\AGenesysToolKit\user-settings.json` (future)

### Application Config

Location: `App/GenesysCloudTool.ps1` (OAuth config section)

### Artifacts Output

Location: `./artifacts/` (relative to repository root)

**Gitignored**: Safe to store sensitive exports locally

## Quick Links

- **Full Documentation**: [README.md](README.md) - Start here for project overview
- **Configuration Guide**: [docs/CONFIGURATION.md](docs/CONFIGURATION.md) - OAuth setup
- **Testing Guide**: [TESTING.md](TESTING.md) - Running tests
- **Deployment Guide**: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) - Production deployment
- **Developer Guide**: [CONTRIBUTING.md](CONTRIBUTING.md) - Contributing to the project
- **Security Policy**: [SECURITY.md](SECURITY.md) - Security practices and reporting

## Need Help?

- **Documentation**: Check `/docs` directory for detailed guides
- **Issues**: [Open an issue on GitHub](https://github.com/xfaith4/AGenesysToolKit/issues)
- **Questions**: Issue with `question` label
- **Security**: See [SECURITY.md](SECURITY.md) for responsible disclosure

---

**Last Updated**: 2026-01-14  
**Version**: 1.0.0
**For**: AGenesysToolKit Users
