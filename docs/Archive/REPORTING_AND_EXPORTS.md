# Reporting & Exports User Guide

**AGenesysToolKit** — Professional reporting and export system for Genesys Cloud data

---

## Overview

The Reporting & Exports system provides a cohesive, template-driven approach to creating shareable artifacts from Genesys Cloud data. Every export includes:

- **HTML Report Card** — Human-friendly summary with key metrics and data preview
- **JSON Data** — Full-fidelity machine-readable format
- **CSV Data** — Spreadsheet-compatible flat format
- **XLSX Data** — Excel workbook (if ImportExcel module is available)
- **Metadata** — Timestamp, region, filters, row counts, versions, warnings

---

## Artifact Folder Layout

Artifacts are organized hierarchically under `App/artifacts/`:

```
App/artifacts/
├── index.json                                    # Global export history
├── Conversation Inspect Packet/
│   └── 20260113-143022_abc123/                  # RunId: yyyyMMdd-HHmmss_<guid>
│       ├── metadata.json                         # Export metadata
│       ├── report.html                           # HTML report card
│       ├── data.json                             # Full data (JSON)
│       ├── data.csv                              # Flat data (CSV)
│       └── data.xlsx                             # Excel workbook (optional)
├── Errors & Failures Snapshot/
│   └── 20260113-144530_def456/
│       ├── ...
└── Subscription Session Summary/
    └── 20260113-145612_ghi789/
        ├── ...
```

### File Descriptions

| File | Purpose | Format |
|------|---------|--------|
| `metadata.json` | Export metadata: timestamp, region, filters, counts, status, warnings | JSON |
| `report.html` | Self-contained HTML report card with embedded CSS | HTML |
| `data.json` | Complete data with nested objects (full fidelity) | JSON |
| `data.csv` | Flattened data for spreadsheet consumption | CSV |
| `data.xlsx` | Excel workbook with formatting (requires ImportExcel) | XLSX |
| `index.json` | Global list of all exports (read by Export History UI) | JSON |

---

## Built-in Report Templates

### 1. Conversation Inspect Packet

**Description:** Complete conversation export with timeline, analytics, and subscription events.

**Use Case:** Troubleshooting customer experience issues, call quality analysis, incident investigation.

**Required Parameters:**
- `ConversationId` — Conversation ID to inspect
- `Region` — Genesys Cloud region (e.g., `usw2.pure.cloud`)
- `AccessToken` — OAuth access token

**Optional Parameters:**
- `SubscriptionEvents` — Array of subscription events to include

**Output Rows:** Timeline events with timestamp, category, label, and details.

**Example Usage (PowerShell):**
```powershell
Import-Module ./Core/ReportTemplates.psm1

$bundle = Invoke-GcReportTemplate `
  -TemplateName 'Conversation Inspect Packet' `
  -Parameters @{
    ConversationId = 'c-12345678-abcd-1234-5678-123456789abc'
    Region = 'usw2.pure.cloud'
    AccessToken = $accessToken
    SubscriptionEvents = $eventBuffer
  }

# Open HTML report
Open-GcArtifact -Path $bundle.ReportHtmlPath
```

---

### 2. Errors & Failures Snapshot

**Description:** Cross-cutting error analysis from jobs, subscriptions, and API calls.

**Use Case:** Troubleshooting session summary, export all recent errors for analysis.

**Required Parameters:** *(None — all optional)*

**Optional Parameters:**
- `Jobs` — App job collection (from `$script:AppState.Jobs`)
- `SubscriptionErrors` — Subscription error events
- `Since` — Only include errors since this DateTime

**Output Rows:** Errors with timestamp, source, category, name, and error message.

**Example Usage:**
```powershell
$bundle = Invoke-GcReportTemplate `
  -TemplateName 'Errors & Failures Snapshot' `
  -Parameters @{
    Jobs = $script:AppState.Jobs
    SubscriptionErrors = $errorEvents
    Since = (Get-Date).AddHours(-2)
  }
```

---

### 3. Subscription Session Summary

**Description:** Live subscription session export with message counts and sample payloads.

**Use Case:** Document a live monitoring session, analyze subscription performance.

**Required Parameters:**
- `SessionStart` — Session start DateTime
- `Topics` — Array of subscribed topic strings
- `Events` — Array of collected event objects

**Optional Parameters:**
- `Disconnects` — Number of disconnects during session

**Output Rows:** Topic groups with event counts and sample payloads.

**Example Usage:**
```powershell
$bundle = Invoke-GcReportTemplate `
  -TemplateName 'Subscription Session Summary' `
  -Parameters @{
    SessionStart = $sessionStartTime
    Topics = @('v2.conversations.{id}.transcription', 'v2.conversations.{id}.agentassist')
    Events = $script:AppState.EventBuffer
    Disconnects = 2
  }
```

---

### 4. Executive Daily Summary

**Description:** Professional 1-day executive report with peak concurrent conversations by media type (1-min intervals), total media volumes, and abandon rates. Includes customizable branding for executive presentations.

**Use Case:** Daily operational reports for executives and management, KPI tracking, historical performance analysis.

**Required Parameters:**
- `Region` — Genesys Cloud region (e.g., `usw2.pure.cloud`)
- `AccessToken` — OAuth access token

**Optional Parameters:**
- `TargetDate` — Date to report on (defaults to yesterday if not specified)
- `BrandingTitle` — Custom title for report (default: "Contact Center Operations")
- `BrandingColor` — Custom color for branding in hex format (default: "#0066CC")

**Output Rows:** Detailed metrics including:
- Peak concurrent conversations by media type (Voice, Chat, Email, Message, Callback)
- Time of peak for each media type
- Total volume per media type for the day
- Abandon rate and total abandoned/offered counts

**Summary Metrics:**
- Report Date
- Branding Title and Color
- Generation timestamp
- Total Conversations
- Peak Concurrent by Media Type
- Total Volume by Media Type
- Total Abandoned/Offered
- Abandon Rate (%)

**Example Usage:**
```powershell
Import-Module ./Core/ReportTemplates.psm1

# Generate report for yesterday with default branding
$bundle = Invoke-GcReportTemplate `
  -TemplateName 'Executive Daily Summary' `
  -Parameters @{
    Region = 'usw2.pure.cloud'
    AccessToken = $accessToken
  }

# Generate report for specific date with custom branding
$bundle = Invoke-GcReportTemplate `
  -TemplateName 'Executive Daily Summary' `
  -Parameters @{
    Region = 'usw2.pure.cloud'
    AccessToken = $accessToken
    TargetDate = (Get-Date '2026-01-10')
    BrandingTitle = 'ACME Corporation - Daily Operations'
    BrandingColor = '#FF6B35'
  }

# Open HTML report
Open-GcArtifact -Path $bundle.ReportHtmlPath
```

**Report Features:**
- Defaults to previous day if no date specified
- Tracks peak concurrency at 1-minute intervals
- Automatically categorizes media types
- Calculates abandon rate based on customer/external participants
- Professional HTML output suitable for executive distribution
- Customizable branding for corporate identity

---

## Format Specifications

### metadata.json

```json
{
  "ReportName": "Conversation Inspect Packet",
  "RunId": "20260113-143022_abc123",
  "Timestamp": "2026-01-13T14:30:22.1234567Z",
  "BundlePath": "/path/to/artifacts/Conversation Inspect Packet/20260113-143022_abc123",
  "Status": "OK",
  "Warnings": [],
  "TemplateName": "Conversation Inspect Packet",
  "Parameters": {
    "ConversationId": "c-12345",
    "Region": "usw2.pure.cloud"
  },
  "Region": "usw2.pure.cloud",
  "RowCount": 42,
  "ArtifactsCreated": {
    "Html": true,
    "Json": true,
    "Csv": true,
    "Xlsx": false
  },
  "XlsxSkippedReason": "ImportExcel module not available"
}
```

### index.json

```json
[
  {
    "ReportName": "Conversation Inspect Packet",
    "RunId": "20260113-143022_abc123",
    "Timestamp": "2026-01-13T14:30:22Z",
    "BundlePath": "/path/to/artifacts/...",
    "RowCount": 42,
    "Status": "OK",
    "Warnings": []
  },
  {
    "ReportName": "Errors & Failures Snapshot",
    "RunId": "20260113-144530_def456",
    "Timestamp": "2026-01-13T14:45:30Z",
    "BundlePath": "/path/to/artifacts/...",
    "RowCount": 5,
    "Status": "Warnings",
    "Warnings": ["2 subscription disconnects occurred"]
  }
]
```

---

## How to Add a New Report Template

### Step 1: Define the Template

Add a new template definition to `Get-GcReportTemplates` in `Core/ReportTemplates.psm1`:

```powershell
[PSCustomObject]@{
  Name = 'My Custom Report'
  Description = 'Brief description of what this report exports'
  Parameters = @{
    RequiredParam = @{ Type = 'String'; Required = $true; Description = 'A required parameter' }
    OptionalParam = @{ Type = 'Int'; Required = $false; Description = 'An optional parameter' }
  }
  InvokeScript = ${function:Invoke-MyCustomReport}
}
```

### Step 2: Implement the Invoke Function

Create a function that returns a hashtable with `Rows`, `Summary`, and `Warnings`:

```powershell
function Invoke-MyCustomReport {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RequiredParam,
    
    [int]$OptionalParam = 0
  )
  
  $warnings = @()
  $rows = @()
  $summary = [ordered]@{}
  
  try {
    # Fetch data, process, populate rows and summary
    
    $rows += [PSCustomObject]@{
      Column1 = 'Value1'
      Column2 = 'Value2'
    }
    
    $summary['Status'] = 'OK'
    $summary['RowCount'] = $rows.Count
    
  } catch {
    $warnings += "Error: $_"
    $summary['Status'] = 'Failed'
  }
  
  return @{
    Rows = $rows
    Summary = $summary
    Warnings = $warnings
  }
}
```

### Step 3: Export the Function

Add your new function to the `Export-ModuleMember` call:

```powershell
Export-ModuleMember -Function @(
  'Get-GcReportTemplates',
  'Invoke-ConversationInspectPacketReport',
  'Invoke-ErrorsFailuresSnapshotReport',
  'Invoke-SubscriptionSessionSummaryReport',
  'Invoke-MyCustomReport'  # <- Add here
)
```

### Step 4: Test Your Template

Create a test script:

```powershell
#!/usr/bin/env pwsh

Import-Module ./Core/Reporting.psm1
Import-Module ./Core/ReportTemplates.psm1

$bundle = Invoke-GcReportTemplate `
  -TemplateName 'My Custom Report' `
  -Parameters @{
    RequiredParam = 'test-value'
    OptionalParam = 42
  }

Write-Host "Report created: $($bundle.BundlePath)"
Open-GcArtifact -Path $bundle.ReportHtmlPath
```

---

## PowerShell API Reference

### Core/Reporting.psm1

#### `New-GcReportRunId`

Generates a unique correlation ID for a report run.

```powershell
$runId = New-GcReportRunId
# Returns: "20260113-143022_abc123"
```

#### `New-GcArtifactBundle`

Creates an artifact bundle folder structure with metadata skeleton.

```powershell
$bundle = New-GcArtifactBundle `
  -ReportName "My Report" `
  -Metadata @{ Region = 'usw2.pure.cloud' }
```

#### `Write-GcReportHtml`

Writes a self-contained HTML report card.

```powershell
Write-GcReportHtml `
  -Path "C:\artifacts\report.html" `
  -Title "My Report" `
  -Summary @{ RowCount = 42 } `
  -Warnings @('Warning message') `
  -Rows $dataRows
```

#### `Write-GcDataArtifacts`

Writes data artifacts: JSON, CSV, and optional XLSX.

```powershell
$result = Write-GcDataArtifacts `
  -Rows $dataRows `
  -JsonPath "C:\artifacts\data.json" `
  -CsvPath "C:\artifacts\data.csv" `
  -XlsxPath "C:\artifacts\data.xlsx"
```

#### `Update-GcArtifactIndex`

Updates the artifact index file with a new export entry.

```powershell
Update-GcArtifactIndex -Entry @{
  ReportName = 'Test Report'
  RunId = '20260113-143022_abc123'
  Status = 'OK'
}
```

#### `Get-GcArtifactIndex`

Retrieves the artifact index.

```powershell
$exports = Get-GcArtifactIndex
foreach ($export in $exports) {
  Write-Host "$($export.Timestamp) - $($export.ReportName)"
}
```

#### `Open-GcArtifact`

Opens an artifact folder or file using the system default application.

```powershell
Open-GcArtifact -Path "C:\artifacts\report.html"
```

### Core/ReportTemplates.psm1

#### `Get-GcReportTemplates`

Returns available report templates.

```powershell
$templates = Get-GcReportTemplates
$template = $templates | Where-Object { $_.Name -eq 'Conversation Inspect Packet' }
```

#### `Invoke-GcReportTemplate`

Executes a report template and generates artifact bundle.

```powershell
$bundle = Invoke-GcReportTemplate `
  -TemplateName 'Conversation Inspect Packet' `
  -Parameters @{ ConversationId = 'c-123'; Region = 'usw2.pure.cloud'; AccessToken = $token }
```

---

## Using the Reports & Exports UI

### Accessing the Module

1. Launch the app:
   ```powershell
   pwsh ./App/GenesysCloudTool_UX_Prototype.ps1
   ```

2. Navigate to **Reports & Exports** in the main navigation

3. The Reports & Exports view consists of three main panels:
   - **LEFT**: Template picker with search
   - **MIDDLE**: Dynamic parameter panel and preview
   - **RIGHT**: Export actions and artifact hub

### Generating a Report

**Step 1: Select a Template**
- Browse available templates in the left panel
- Use the search box to filter templates by name or description
- Click on a template to select it
- View template details and description below the list

**Step 2: Configure Parameters**
- The middle panel automatically generates input controls based on the template's parameter schema
- Required parameters are marked with an asterisk (*)
- Common parameters like Region and AccessToken are auto-filled from your session
- Parameter types include:
  - Text fields (string)
  - Number fields (int)
  - Checkboxes (bool)
  - Date pickers (datetime)
  - Multi-line text (array)

**Step 3: Run the Report**
- Click **Run Report** button
- The report executes asynchronously in the background
- Monitor progress in the app's status bar
- Wait for completion (usually 5-30 seconds depending on data size)

**Step 4: Preview and Export**
- Once complete, the HTML preview appears in the middle panel
- Click **Open in Browser** to view the full HTML report in your default browser
- Use export buttons in the right panel:
  - **Export HTML** — Opens the HTML report
  - **Export JSON** — Opens the raw JSON data
  - **Export CSV** — Opens the CSV data file
  - **Export Excel** — Opens the Excel workbook (if ImportExcel is installed)
  - **Copy Artifact Path** — Copies the bundle path to clipboard
  - **Open Containing Folder** — Opens the artifact folder in file explorer

### Managing Presets

**Save a Preset:**
1. Configure parameters for a template
2. Click **Save Preset** button
3. Preset is saved to `App/artifacts/presets/` with timestamp
4. Presets are template-specific

**Load a Preset:**
1. Select a template
2. Click **Load Preset** button
3. The most recent preset for that template is loaded
4. All parameter values are restored

### Artifact Hub

The **Artifact Hub** in the right panel shows the 20 most recent exports:
- Sorted by timestamp (newest first)
- Shows report name, timestamp, and status
- Right-click or context menu provides actions:
  - **Open HTML Report** — Opens the report in browser
  - **Open Folder** — Opens the artifact folder
  - **Copy Path** — Copies path to clipboard
  - **Delete** — Moves artifact to `artifacts/_trash/`
- Double-click an artifact to open its HTML report

---

## How to Demo

### Prerequisites

1. **PowerShell 5.1+ or PowerShell 7+** — The system is compatible with both versions.
2. **OAuth Access Token** — Obtain a token via the app's Login flow or manually.
3. **Optional: ImportExcel Module** — For XLSX generation:
   ```powershell
   Install-Module -Name ImportExcel -Scope CurrentUser
   ```

### Demo Scenario 1: Export a Conversation Inspect Packet

**Goal:** Export a complete conversation analysis with timeline and subscription events.

**Steps:**

1. Launch the app and log in via OAuth

2. Navigate to **Operations → Topic Subscriptions**

3. Start a subscription and let events stream in

4. Note a conversation ID from the event stream (e.g., `c-12345...`)

5. Navigate to **Reports & Exports**

6. Select **Conversation Inspect Packet** template

7. Enter the conversation ID in the parameter field (Region and AccessToken auto-filled)

8. Click **Run Report**

9. Wait for completion (async job runs in background)

10. Preview appears automatically in the middle panel

11. Click export buttons to access HTML, JSON, CSV, or XLSX files

12. Check the Artifact Hub to see the new export listed

**Expected Result:**
- Artifact bundle created under `App/artifacts/Conversation Inspect Packet/<runId>/`
- HTML preview shows conversation summary, timeline events, and warnings
- CSV and JSON files available for further analysis
- Export appears in Artifact Hub immediately

---

### Demo Scenario 2: Export an Errors & Failures Snapshot

**Goal:** Capture all recent errors after a troubleshooting session.

**Steps:**

1. After running several operations, navigate to **Reports & Exports**

2. Select **Errors & Failures Snapshot** template

3. (Optional) Adjust the "Since" parameter to filter errors by time

4. Click **Run Report**

5. Review the HTML preview showing error summary and details

6. Click **Export CSV** to open the data in a spreadsheet application

**Expected Result:**
- Artifact bundle with all recent errors
- CSV file with columns: Timestamp, Source, Category, Name, Error
- HTML preview shows error summary and warnings

---

### Demo Scenario 3: Export Subscription Session Summary

**Goal:** Document a live monitoring session with metrics.

### Demo Scenario 3: Export Subscription Session Summary

**Goal:** Document a live monitoring session with metrics.

**Steps:**

1. Start a subscription session (**Operations → Topic Subscriptions**)

2. Let it run for a few minutes, collecting events

3. Navigate to **Reports & Exports**

4. Select **Subscription Session Summary** template

5. Configure parameters:
   - SessionStart: (enter session start time)
   - Topics: (list of subscribed topics)
   - Events: (event buffer from app state - may need to reference the app's EventBuffer)

6. Click **Run Report**

7. Preview appears showing session duration, event counts by topic, and sample payloads

8. Use export buttons to access the data in your preferred format

**Expected Result:**
- Artifact bundle with session summary
- HTML preview shows session metadata and topic breakdown
- CSV file with topic groups and event counts

**Note:** This template requires access to the app's internal EventBuffer. It's primarily designed for use from within the app after a subscription session, rather than manual parameter entry.

---

## Troubleshooting

### XLSX Files Not Created

**Symptom:** `data.xlsx` is missing, `metadata.json` shows `XlsxSkippedReason: "ImportExcel module not available"`.

**Solution:** Install ImportExcel module:
```powershell
Install-Module -Name ImportExcel -Scope CurrentUser -Force
```

### "No conversation data returned from analytics API"

**Symptom:** Conversation Inspect Packet report completes but shows "No Data" status.

**Cause:** Conversation ID may not exist, or analytics job returned empty results.

**Solution:**
- Verify the conversation ID is correct
- Check that the conversation is recent (analytics may take time to index)
- Ensure you have the correct region selected

### HTML Report Shows "No data rows"

**Symptom:** HTML report opens but data preview is empty.

**Cause:** Report template returned zero rows (e.g., no errors in the timeframe).

**Solution:** This is expected if no data matches the filters. Adjust filters or timeframe.

---

## Advanced Usage

### Exporting from PowerShell (Without UI)

You can generate reports directly from PowerShell scripts:

```powershell
# Import modules
Import-Module ./Core/Reporting.psm1
Import-Module ./Core/ReportTemplates.psm1

# Get access token (example)
$token = "your-access-token-here"

# Run report
$bundle = Invoke-GcReportTemplate `
  -TemplateName 'Conversation Inspect Packet' `
  -Parameters @{
    ConversationId = 'c-12345678-abcd-1234-5678-123456789abc'
    Region = 'usw2.pure.cloud'
    AccessToken = $token
  }

Write-Host "Report created: $($bundle.BundlePath)"

# Open HTML report
Open-GcArtifact -Path $bundle.ReportHtmlPath

# Or open folder
Open-GcArtifact -Path $bundle.BundlePath
```

### Scheduling Automated Reports

Use Windows Task Scheduler or cron to run reports automatically:

```powershell
# scheduled-report.ps1
param([string]$ConversationId)

Import-Module ./Core/Reporting.psm1
Import-Module ./Core/ReportTemplates.psm1

# Fetch token (from secure store)
$token = Get-SecureToken

# Generate report
$bundle = Invoke-GcReportTemplate `
  -TemplateName 'Conversation Inspect Packet' `
  -Parameters @{
    ConversationId = $ConversationId
    Region = 'usw2.pure.cloud'
    AccessToken = $token
  }

# Email report (optional)
Send-EmailWithAttachment `
  -To 'team@example.com' `
  -Subject "Conversation Report: $ConversationId" `
  -Attachments @($bundle.ReportHtmlPath, $bundle.DataCsvPath)
```

---

## Best Practices

1. **Use Clear Report Names** — When creating custom templates, use descriptive names that indicate the data being exported.

2. **Include Warnings** — Always populate the `Warnings` array if data quality issues are detected.

3. **Redact Sensitive Data** — If exporting PII or sensitive payloads, redact or truncate in HTML previews. Keep full data in JSON for forensics.

4. **Test Templates** — Write unit tests for custom report templates to ensure they handle edge cases (empty data, null values, etc.).

5. **Monitor Artifact Size** — If exporting large datasets, consider pagination or filtering to keep artifact bundles manageable.

6. **Archive Old Exports** — Periodically archive or delete old artifact bundles to prevent disk space issues.

7. **Use Presets for Repeated Reports** — Save parameter configurations as presets to quickly regenerate reports with the same settings.

8. **Check the Artifact Hub** — Before re-running a report, check the Artifact Hub to see if a recent export already exists.

---

## Preset Format

Presets are stored in `App/artifacts/presets/` as JSON files with the following structure:

```json
{
  "TemplateName": "Conversation Inspect Packet",
  "SavedAt": "2026-01-14T03:30:22.1234567Z",
  "Parameters": {
    "ConversationId": "c-12345678-abcd-1234-5678-123456789abc",
    "Region": "usw2.pure.cloud",
    "SubscriptionEvents": []
  }
}
```

**Fields:**
- `TemplateName` — The name of the report template
- `SavedAt` — ISO 8601 timestamp when preset was saved
- `Parameters` — Hashtable of parameter names and values

**File Naming:**
Presets are automatically named using the pattern: `<TemplateName>_<Timestamp>.json`

Example: `Conversation_Inspect_Packet_20260114-033022.json`

**Loading Presets:**
The UI currently loads the first preset found for the selected template. Future enhancements may add preset selection UI.

**Manual Preset Creation:**
You can manually create presets by placing JSON files in the presets directory following the format above.

---

## Support & Feedback

For issues, questions, or feature requests, please:

1. Check this documentation first
2. Review the test scripts in `tests/` for usage examples
3. Open an issue on the repository with:
   - PowerShell version (`$PSVersionTable.PSVersion`)
   - Exact error message
   - Steps to reproduce
   - Contents of `metadata.json` (if applicable)

---

## Changelog

### v1.1.0 (2026-01-14)

- Added production-quality Reports & Exports UI module
- Template picker with search and filtering
- Dynamic parameter generation based on template schema
- Preset save/load functionality
- HTML preview with WebBrowser control
- Artifact Hub with recent exports and context menu actions
- Safe delete (moves to `_trash` folder)

### v1.0.0 (2026-01-13)

- Initial release
- 4 built-in report templates
- HTML + JSON + CSV + XLSX export formats
- Artifact index and history tracking
- Cross-platform support (Windows, macOS, Linux)

---

**Happy Reporting!** 🚀
