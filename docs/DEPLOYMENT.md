# Deployment Guide - AGenesysToolKit

This guide provides step-by-step instructions for deploying AGenesysToolKit to production environments for use by Genesys Cloud operations teams.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Deployment Options](#deployment-options)
- [Production Setup](#production-setup)
- [Configuration Management](#configuration-management)
- [User Onboarding](#user-onboarding)
- [Monitoring and Maintenance](#monitoring-and-maintenance)
- [Troubleshooting](#troubleshooting)
- [Scaling Considerations](#scaling-considerations)

## Overview

### Deployment Architecture

AGenesysToolKit is a Windows desktop application that:
- Runs locally on engineer workstations
- Connects to Genesys Cloud APIs via HTTPS
- Stores no data persistently (except exported artifacts)
- Uses OAuth for authentication
- Requires no server infrastructure

### Typical Deployment

```
┌─────────────────────────┐
│   Engineer Workstation  │
│   ┌─────────────────┐   │
│   │ AGenesysToolKit │   │
│   │   (WPF App)     │   │
│   └────────┬────────┘   │
│            │ OAuth      │
└────────────┼────────────┘
             │ HTTPS
             ▼
    ┌────────────────┐
    │ Genesys Cloud  │
    │      APIs      │
    └────────────────┘
```

## Prerequisites

### System Requirements

**Per Workstation**:
- **OS**: Windows 10 (1809+) or Windows 11 or Windows Server 2019+
- **PowerShell**: Version 5.1 or PowerShell 7+ (7.4+ recommended)
- **Memory**: 4GB RAM minimum, 8GB recommended
- **Disk**: 500MB free space for application and artifacts
- **Network**: Outbound HTTPS (443) to Genesys Cloud APIs
- **.NET**: .NET Framework 4.7.2+ (for WPF) - usually pre-installed on Windows 10/11

### Network Requirements

**Outbound Connections**:
- `https://api.{region}.pure.cloud` (e.g., `api.usw2.pure.cloud`) - Port 443
- `https://login.{region}.pure.cloud` - Port 443 (OAuth)
- `wss://api.{region}.pure.cloud` - Port 443 (WebSocket subscriptions)

**Firewall Rules**:
```
Allow outbound HTTPS (443) to:
  - *.mypurecloud.com
  - *.pure.cloud
  - *.mypurecloud.com.au
  - *.mypurecloud.ie
  - *.mypurecloud.de
  - *.mypurecloud.jp
  (depending on your Genesys Cloud region)
```

### Genesys Cloud Requirements

**OAuth Client Configuration**:
1. Admin access to create OAuth clients
2. Organization-level OAuth client (recommended) or user-level
3. Grant type: Authorization Code with PKCE
4. Redirect URI: `http://localhost:8085/oauth/callback`

**Required Permissions** (minimum):
- `authorization:readonly`
- `users:readonly`
- `analytics:readonly`
- `conversations:readonly`

**Optional Permissions** (for full feature set):
- `routing:readonly`
- `architect:readonly`
- `quality:readonly`
- `recordings:readonly`
- `telephony:readonly`

See [CONFIGURATION.md](docs/CONFIGURATION.md) for detailed OAuth setup.

## Deployment Options

### Option 1: Individual Workstation Deployment

**Best for**: Small teams (1-10 users), testing, pilot programs

**Process**:
1. Clone repository to each workstation
2. Configure OAuth client
3. Train users
4. Provide support documentation

**Pros**:
- Simple and fast
- Easy to update
- No central infrastructure

**Cons**:
- Manual updates required
- Configuration per workstation
- Version consistency challenges

### Option 2: Shared Network Location

**Best for**: Medium teams (10-50 users), centralized management

**Process**:
1. Deploy to network share (e.g., `\\fileserver\Tools\AGenesysToolKit`)
2. Configure OAuth client (shared config)
3. Users run from network location
4. Updates deployed centrally

**Pros**:
- Single version across team
- Centralized updates
- Shared configuration

**Cons**:
- Network dependency
- Potential performance impact
- Concurrent access considerations

### Option 3: Packaged Distribution

**Best for**: Large teams (50+ users), enterprise deployment

**Process**:
1. Package application (ZIP, MSI, or deployment tool)
2. Distribute via software distribution system (SCCM, Intune, etc.)
3. Centralize configuration via Group Policy or config management
4. Automate updates

**Pros**:
- Enterprise-grade deployment
- Automated updates
- Policy-based configuration
- Audit and compliance tracking

**Cons**:
- Requires packaging/deployment infrastructure
- More complex setup
- Longer initial deployment time

## Production Setup

### Step 1: Create OAuth Client

1. **Log in to Genesys Cloud Admin**
   - Navigate to Admin → Integrations → OAuth
   - Click "Add Client"

2. **Configure OAuth Client**
   ```
   Name: AGenesysToolKit Production
   Grant Type: Authorization Code with PKCE
   Redirect URI: http://localhost:8085/oauth/callback
   Token Duration: 43200 seconds (12 hours)
   ```

3. **Assign Permissions**
   - Grant required scopes (see Prerequisites)
   - Consider using a role-based approach
   - Document permissions granted

4. **Save Client ID**
   - Copy the Client ID
   - Store securely (NOT in version control)
   - Share with deployment team only

### Step 2: Prepare Application Files

```powershell
# Clone or extract application
git clone https://github.com/xfaith4/AGenesysToolKit.git
# OR
# Extract AGenesysToolKit-v0.6.0.zip

cd AGenesysToolKit

# Verify integrity
./tests/smoke.ps1

# Expected: 10/10 tests pass
```

### Step 3: Configure Application

**Option A: Embedded Configuration** (for packaged deployment)

Edit `App/GenesysCloudTool_UX_Prototype.ps1`:

```powershell
# Find the Set-GcAuthConfig section
Set-GcAuthConfig `
  -ClientId 'your-production-client-id' `
  -Region 'mypurecloud.com' `
  -RedirectUri 'http://localhost:8085/oauth/callback'
```

**Option B: External Configuration** (for flexible deployment)

Create `config/production.json`:

```json
{
  "oauth": {
    "clientId": "your-production-client-id",
    "region": "mypurecloud.com",
    "redirectUri": "http://localhost:8085/oauth/callback"
  },
  "application": {
    "logLevel": "Information",
    "artifactsDirectory": "./artifacts",
    "autoRefreshInterval": 30000
  }
}
```

**Security Note**: Do NOT commit configuration with Client ID to version control if Client ID is considered sensitive.

### Step 4: Create Deployment Package

**For Network Share**:
```powershell
# Copy files to network location
$source = "C:\AGenesysToolKit"
$destination = "\\fileserver\Tools\AGenesysToolKit"

Copy-Item -Path $source -Destination $destination -Recurse -Force

# Set permissions (read-only for users, read-write for admins)
$acl = Get-Acl $destination
# Configure ACL as needed
Set-Acl -Path $destination -AclObject $acl
```

**For Packaged Distribution**:
```powershell
# Create ZIP package
$version = "0.6.0"
$packageName = "AGenesysToolKit-v$version.zip"

Compress-Archive -Path ./AGenesysToolKit/* -DestinationPath $packageName
```

### Step 5: User Access Configuration

**Create Launch Script** (`Launch-AGenesysToolKit.ps1`):

```powershell
<#
.SYNOPSIS
    Launches AGenesysToolKit with production configuration.

.DESCRIPTION
    This script ensures PowerShell execution policy is set appropriately
    and launches the AGenesysToolKit application.
#>

# Set execution policy for current user if needed
$currentPolicy = Get-ExecutionPolicy -Scope CurrentUser
if ($currentPolicy -eq 'Restricted' -or $currentPolicy -eq 'Undefined') {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
}

# Verify prerequisites
$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -lt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -lt 1)) {
    Write-Error "PowerShell 5.1 or later is required. Current version: $psVersion"
    Read-Host "Press Enter to exit"
    exit 1
}

# Launch application
$appPath = Join-Path $PSScriptRoot "App\GenesysCloudTool_UX_Prototype.ps1"

if (-not (Test-Path $appPath)) {
    Write-Error "Application not found at: $appPath"
    Read-Host "Press Enter to exit"
    exit 1
}

# Run application
& $appPath
```

### Step 6: Create Desktop Shortcuts

**PowerShell script to create shortcuts** (`Create-Shortcut.ps1`):

```powershell
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:USERPROFILE\Desktop\AGenesysToolKit.lnk")
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -File `"\\fileserver\Tools\AGenesysToolKit\Launch-AGenesysToolKit.ps1`""
$Shortcut.WorkingDirectory = "\\fileserver\Tools\AGenesysToolKit"
$Shortcut.IconLocation = "powershell.exe"
$Shortcut.Description = "AGenesysToolKit - Genesys Cloud Operations Toolkit"
$Shortcut.Save()

Write-Host "Shortcut created on desktop" -ForegroundColor Green
```

## Configuration Management

### Centralized Configuration (Enterprise)

**Using Group Policy**:

1. Create GPO: "AGenesysToolKit Configuration"
2. Configure registry keys or environment variables:
   ```
   HKEY_CURRENT_USER\Software\AGenesysToolKit
     - ClientId (String)
     - Region (String)
   ```
3. Deploy to appropriate OUs

**Using Config File**:

1. Deploy base configuration to `%PROGRAMDATA%\AGenesysToolKit\config.json`
2. Application reads config on startup
3. User-specific settings in `%APPDATA%\AGenesysToolKit\user-config.json`

### Environment-Specific Configurations

**Development**:
```json
{
  "oauth": { "clientId": "dev-client-id" },
  "logging": { "level": "Verbose" }
}
```

**Staging**:
```json
{
  "oauth": { "clientId": "staging-client-id" },
  "logging": { "level": "Information" }
}
```

**Production**:
```json
{
  "oauth": { "clientId": "prod-client-id" },
  "logging": { "level": "Warning" }
}
```

## User Onboarding

### Training Materials

Provide users with:

1. **Quick Start Guide** (README.md)
2. **Configuration Guide** (docs/CONFIGURATION.md)
3. **Testing Guide** (TESTING.md)
4. **Troubleshooting Guide** (TROUBLESHOOTING.md - create as needed)

### First-Time User Setup

1. **Launch Application**
   - Double-click desktop shortcut or run Launch script

2. **Authenticate**
   - Click "Login..." button
   - Browser opens with OAuth consent
   - Grant permissions
   - Return to application

3. **Verify Functionality**
   - Navigate to Routing & People → Users & Presence
   - Click "List Users"
   - Verify users display

4. **Test Export**
   - Click "Export" button
   - Verify file created in artifacts/

### Support Resources

- **Documentation**: Full documentation in `docs/` directory
- **FAQ**: Create internal FAQ based on common questions
- **Support Channel**: Slack channel, email, or ticketing system
- **Expert Users**: Identify power users for peer support

## Monitoring and Maintenance

### Application Health

**No Server-Side Monitoring**: Application runs client-side, so monitoring is per-workstation.

**User Feedback Mechanisms**:
- Error reporting (manual)
- Usage surveys
- Support ticket trends

### Updates and Patches

**Version Control**:
- Track version in README.md
- Document changes in CHANGELOG.md (create as needed)
- Tag releases in Git

**Update Process**:
1. Test new version in development
2. Deploy to staging/pilot group
3. Gather feedback
4. Deploy to production
5. Communicate changes to users

**Rollback Plan**:
- Keep previous version available
- Document rollback procedure
- Test rollback process

### Artifact Management

**Exported Files**:
- Users responsible for managing `artifacts/` directory
- Recommend periodic cleanup
- Set retention policies (e.g., 30 days)

```powershell
# Example cleanup script (run manually or scheduled)
$artifactsPath = "C:\AGenesysToolKit\artifacts"
$retentionDays = 30

Get-ChildItem -Path $artifactsPath -Recurse | 
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$retentionDays) } |
  Remove-Item -Force -Recurse
```

## Troubleshooting

### Common Issues

#### "Execution Policy Restricted"

**Symptom**: PowerShell won't run scripts

**Solution**:
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

#### "Module not found"

**Symptom**: Application fails to load modules

**Solution**:
- Verify all files copied correctly
- Check working directory is application root
- Re-extract/copy files from source

#### "OAuth timeout"

**Symptom**: OAuth flow doesn't complete within timeout

**Solution**:
- Increase timeout in `Get-GcTokenAsync` call
- Check network connectivity to Genesys Cloud
- Verify firewall allows OAuth redirect callback

#### "Access Denied / 401"

**Symptom**: API calls fail with authentication errors

**Solution**:
- Verify OAuth client has required permissions
- Check token hasn't expired
- Re-authenticate (logout and login again)

### Logging and Diagnostics

**Enable Verbose Logging**:
```powershell
$VerbosePreference = 'Continue'
./App/GenesysCloudTool_UX_Prototype.ps1
```

**Check Job Logs**:
- Open Admin → Job Center
- View logs for failed jobs
- Export logs if needed for support

## Scaling Considerations

### Performance

**Single User**:
- Application performs well with typical workloads
- Background job system prevents UI blocking

**Concurrent Users** (on network share):
- Application is read-only on disk
- Each user runs independent instance
- No file locking issues

**Large Datasets**:
- Pagination handles large API responses
- Job pattern ensures non-blocking operations
- Consider `MaxItems` limits for very large queries

### Geographic Distribution

**Multi-Region Deployments**:
- Deploy separate OAuth clients per region
- Configure region-specific settings
- Use region-appropriate API endpoints

**Regional Considerations**:
```
US West 2 (Oregon): mypurecloud.com
US East 1 (Virginia): use.mypurecloud.com
EU (Ireland): mypurecloud.ie
EU (Frankfurt): mypurecloud.de
Asia Pacific (Sydney): mypurecloud.com.au
Asia Pacific (Tokyo): mypurecloud.jp
```

### Capacity Planning

**Per User**:
- Disk: ~500MB (application + artifacts)
- Memory: ~200-500MB during use
- Network: ~1-5 Mbps (depending on usage)

**For 100 Users**:
- Network share: ~50GB (application + user artifacts)
- Network bandwidth: ~100-500 Mbps peak
- No server-side infrastructure required

## Success Metrics

### Key Performance Indicators (KPIs)

**Adoption**:
- Active users per week
- Features used per user
- Time to first successful use

**Efficiency**:
- Time saved vs. manual processes
- Number of exports generated
- Incident investigation time reduction

**Quality**:
- Error rate (failed jobs, API errors)
- Support tickets related to toolkit
- User satisfaction scores

### Measuring Success

**Week 1-4** (Pilot):
- 10-20 users
- Gather feedback
- Iterate on configuration

**Month 2-3** (Rollout):
- 50-100 users
- Monitor adoption
- Address common issues

**Month 4+** (Maturity):
- Full team adoption
- Established support processes
- Continuous improvement

## Checklist for Production Deployment

- [ ] OAuth client created with appropriate permissions
- [ ] Application files deployed (workstation, network share, or packaged)
- [ ] Configuration completed (OAuth Client ID, region)
- [ ] Launch scripts and shortcuts created
- [ ] User documentation distributed
- [ ] Training sessions scheduled/completed
- [ ] Support channels established
- [ ] Smoke tests pass in production environment
- [ ] Pilot users selected and onboarded
- [ ] Rollback plan documented
- [ ] Monitoring/feedback mechanism in place

## Support and Escalation

### Level 1: Self-Service
- User documentation (README, guides)
- FAQ and troubleshooting docs
- Peer support (power users)

### Level 2: Internal Support
- IT help desk or support team
- Configuration assistance
- Basic troubleshooting

### Level 3: Development Team
- Complex issues
- Bug fixes
- Feature requests
- Security concerns

---

**Last Updated**: 2026-01-14  
**Version**: 0.6.0  
**Deployment Tested**: Windows 10, Windows 11, Windows Server 2019
