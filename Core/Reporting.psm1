### BEGIN FILE: Core/Reporting.psm1

Set-StrictMode -Version Latest

<#
.SYNOPSIS
  Core reporting and export functionality for AGenesysToolKit.

.DESCRIPTION
  Provides functions for creating shareable artifact bundles with:
  - HTML report cards (human-friendly)
  - JSON + CSV data (machine-friendly)
  - Optional XLSX (if ImportExcel available)
  - Metadata tracking (timestamp, region, filters, versions, warnings)
  - Export history via index.json
#>

# Module state
$script:ReportingConfig = @{
  IndexFileName = 'index.json'
  DefaultOutputDirectory = $null
}

function New-GcReportRunId {
  <#
  .SYNOPSIS
    Generates a unique correlation ID for a report run.
  
  .DESCRIPTION
    Creates a timestamped correlation ID in the format: yyyyMMdd-HHmmss_<guid>
    Used for organizing artifacts and tracking report executions.
  
  .OUTPUTS
    String - Correlation ID in format: 20240115-143022_abc123def
  
  .EXAMPLE
    $runId = New-GcReportRunId
    # Returns: "20240115-143022_a1b2c3d4"
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()
  
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $guid = [Guid]::NewGuid().ToString('N').Substring(0, 8)
  return "${timestamp}_${guid}"
}

function New-GcArtifactBundle {
  <#
  .SYNOPSIS
    Creates an artifact bundle folder structure with metadata skeleton.
  
  .DESCRIPTION
    Creates a structured directory for report artifacts:
    - OutputDirectory/ReportName/RunId/
      - metadata.json
      - report.html (placeholder)
      - data.json
      - data.csv
      - data.xlsx (optional)
  
  .PARAMETER ReportName
    Name of the report (sanitized for filesystem)
  
  .PARAMETER OutputDirectory
    Base output directory (defaults to App/artifacts)
  
  .PARAMETER RunId
    Optional correlation ID (auto-generated if not provided)
  
  .PARAMETER Metadata
    Initial metadata hashtable
  
  .OUTPUTS
    PSCustomObject with:
      - BundlePath: full path to bundle directory
      - RunId: correlation ID
      - MetadataPath: path to metadata.json
      - ReportHtmlPath: path to report.html
      - DataJsonPath: path to data.json
      - DataCsvPath: path to data.csv
      - DataXlsxPath: path to data.xlsx
  
  .EXAMPLE
    $bundle = New-GcArtifactBundle -ReportName "Conversation Inspect" -Metadata @{ Region = 'usw2.pure.cloud' }
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ReportName,
    
    [string]$OutputDirectory,
    
    [string]$RunId,
    
    [hashtable]$Metadata = @{}
  )
  
  # Default output directory
  if (-not $OutputDirectory) {
    if ($script:ReportingConfig.DefaultOutputDirectory) {
      $OutputDirectory = $script:ReportingConfig.DefaultOutputDirectory
    } else {
      $repoRoot = Split-Path -Parent $PSScriptRoot
      $OutputDirectory = [System.IO.Path]::Combine($repoRoot, 'App', 'artifacts')
    }
  }
  
  # Generate RunId if not provided
  if (-not $RunId) {
    $RunId = New-GcReportRunId
  }
  
  # Sanitize report name for filesystem
  $safeReportName = $ReportName -replace '[<>:"/\\|?*]', '_'
  
  # Create bundle directory: OutputDirectory/ReportName/RunId/
  $bundlePath = [System.IO.Path]::Combine($OutputDirectory, $safeReportName, $RunId)
  
  try {
    New-Item -ItemType Directory -Path $bundlePath -Force | Out-Null
  } catch {
    throw "Failed to create bundle directory at $($bundlePath): $_"
  }
  
  # Define artifact paths
  $metadataPath = [System.IO.Path]::Combine($bundlePath, 'metadata.json')
  $reportHtmlPath = [System.IO.Path]::Combine($bundlePath, 'report.html')
  $dataJsonPath = [System.IO.Path]::Combine($bundlePath, 'data.json')
  $dataCsvPath = [System.IO.Path]::Combine($bundlePath, 'data.csv')
  $dataXlsxPath = [System.IO.Path]::Combine($bundlePath, 'data.xlsx')
  
  # Initialize metadata with defaults
  $metadataContent = [ordered]@{
    ReportName = $ReportName
    RunId = $RunId
    Timestamp = (Get-Date -Format o)
    BundlePath = $bundlePath
    Status = 'Created'
    Warnings = @()
  }
  
  # Merge provided metadata
  foreach ($key in $Metadata.Keys) {
    $metadataContent[$key] = $Metadata[$key]
  }
  
  # Write metadata skeleton
  try {
    $metadataContent | ConvertTo-Json -Depth 10 | Set-Content -Path $metadataPath -Encoding UTF8
  } catch {
    throw "Failed to write metadata.json: $_"
  }
  
  # Return bundle info
  return [PSCustomObject]@{
    BundlePath = $bundlePath
    RunId = $RunId
    MetadataPath = $metadataPath
    ReportHtmlPath = $reportHtmlPath
    DataJsonPath = $dataJsonPath
    DataCsvPath = $dataCsvPath
    DataXlsxPath = $dataXlsxPath
  }
}

function Write-GcReportHtml {
  <#
  .SYNOPSIS
    Writes a self-contained HTML report card.
  
  .DESCRIPTION
    Generates a professional HTML report with embedded CSS.
    Includes summary table, row counts, warnings, and optional data preview.
  
  .PARAMETER Path
    Output path for report.html
  
  .PARAMETER Title
    Report title
  
  .PARAMETER Summary
    Hashtable of summary key-value pairs
  
  .PARAMETER Rows
    Array of data rows (optional preview)
  
  .PARAMETER Warnings
    Array of warning messages
  
  .PARAMETER PreviewRowCount
    Number of rows to include in preview (default: 10)
  
  .EXAMPLE
    Write-GcReportHtml -Path "C:\artifacts\report.html" -Title "Conversation Inspect" -Summary @{ ConversationId = "c-123"; RowCount = 42 }
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    
    [Parameter(Mandatory)]
    [string]$Title,
    
    [hashtable]$Summary = @{},
    
    [object[]]$Rows = @(),
    
    [string[]]$Warnings = @(),
    
    [int]$PreviewRowCount = 10
  )
  
  # Build summary table HTML
  $summaryHtml = ""
  if ($Summary.Count -gt 0) {
    $summaryHtml = "<h2>Summary</h2><table class='summary-table'><thead><tr><th>Property</th><th>Value</th></tr></thead><tbody>"
    foreach ($key in $Summary.Keys) {
      $value = $Summary[$key]
      # Handle null/empty values
      if ($null -eq $value) { $value = "(null)" }
      elseif ($value -is [array]) { $value = "[$($value.Count) items]" }
      elseif ($value -is [hashtable]) { $value = "{$($value.Count) properties}" }
      
      $summaryHtml += "<tr><td>$([System.Security.SecurityElement]::Escape($key))</td><td>$([System.Security.SecurityElement]::Escape($value.ToString()))</td></tr>"
    }
    $summaryHtml += "</tbody></table>"
  }
  
  # Build warnings section
  $warningsHtml = ""
  if ($Warnings.Count -gt 0) {
    $warningsHtml = "<div class='warnings'><h2>⚠️ Warnings</h2><ul>"
    foreach ($warning in $Warnings) {
      $warningsHtml += "<li>$([System.Security.SecurityElement]::Escape($warning))</li>"
    }
    $warningsHtml += "</ul></div>"
  }
  
  # Build data preview
  $previewHtml = ""
  if ($Rows.Count -gt 0) {
    $previewRows = $Rows | Select-Object -First $PreviewRowCount
    $previewHtml = "<h2>Data Preview (First $PreviewRowCount of $($Rows.Count))</h2>"
    
    # Get column names from first row
    $firstRow = $previewRows[0]
    $columns = @()
    if ($firstRow -is [hashtable]) {
      $columns = @($firstRow.Keys)
    } elseif ($firstRow -is [PSCustomObject]) {
      $columns = @($firstRow.PSObject.Properties | ForEach-Object { $_.Name })
    }
    
    if ($columns.Count -gt 0) {
      $previewHtml += "<table class='data-table'><thead><tr>"
      foreach ($col in $columns) {
        $previewHtml += "<th>$([System.Security.SecurityElement]::Escape($col))</th>"
      }
      $previewHtml += "</tr></thead><tbody>"
      
      foreach ($row in $previewRows) {
        $previewHtml += "<tr>"
        foreach ($col in $columns) {
          $cellValue = ""
          if ($row -is [hashtable]) {
            $cellValue = $row[$col]
          } elseif ($row -is [PSCustomObject]) {
            $cellValue = $row.$col
          }
          
          if ($null -eq $cellValue) { $cellValue = "" }
          elseif ($cellValue -is [array]) { $cellValue = "[$($cellValue.Count) items]" }
          elseif ($cellValue -is [hashtable]) { $cellValue = "{...}" }
          
          # Truncate long values
          $cellValueStr = $cellValue.ToString()
          if ($cellValueStr.Length -gt 100) {
            $cellValueStr = $cellValueStr.Substring(0, 100) + "..."
          }
          
          $previewHtml += "<td>$([System.Security.SecurityElement]::Escape($cellValueStr))</td>"
        }
        $previewHtml += "</tr>"
      }
      
      $previewHtml += "</tbody></table>"
    }
  }
  
  # Build complete HTML
  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$([System.Security.SecurityElement]::Escape($Title))</title>
  <style>
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
      line-height: 1.6;
      color: #1f2937;
      background-color: #f9fafb;
      margin: 0;
      padding: 20px;
    }
    .container {
      max-width: 1200px;
      margin: 0 auto;
      background: white;
      border-radius: 12px;
      box-shadow: 0 2px 8px rgba(0,0,0,0.1);
      padding: 40px;
    }
    h1 {
      color: #111827;
      font-size: 28px;
      font-weight: 600;
      margin-top: 0;
      margin-bottom: 8px;
    }
    h2 {
      color: #374151;
      font-size: 20px;
      font-weight: 600;
      margin-top: 32px;
      margin-bottom: 16px;
      border-bottom: 2px solid #e5e7eb;
      padding-bottom: 8px;
    }
    .subtitle {
      color: #6b7280;
      font-size: 14px;
      margin-bottom: 32px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      margin-bottom: 24px;
    }
    .summary-table th,
    .summary-table td {
      text-align: left;
      padding: 12px;
      border-bottom: 1px solid #e5e7eb;
    }
    .summary-table th {
      background-color: #f3f4f6;
      font-weight: 600;
      width: 30%;
    }
    .data-table {
      font-size: 13px;
      overflow-x: auto;
      display: block;
    }
    .data-table th,
    .data-table td {
      padding: 10px;
      border: 1px solid #e5e7eb;
      white-space: nowrap;
      max-width: 300px;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .data-table th {
      background-color: #f3f4f6;
      font-weight: 600;
      position: sticky;
      top: 0;
    }
    .data-table tbody tr:hover {
      background-color: #f9fafb;
    }
    .warnings {
      background-color: #fef3c7;
      border-left: 4px solid #f59e0b;
      padding: 16px;
      margin: 24px 0;
      border-radius: 4px;
    }
    .warnings h2 {
      color: #92400e;
      margin-top: 0;
      border: none;
      padding: 0;
    }
    .warnings ul {
      margin: 8px 0 0 0;
      padding-left: 24px;
    }
    .warnings li {
      color: #78350f;
      margin-bottom: 4px;
    }
    .footer {
      margin-top: 40px;
      padding-top: 24px;
      border-top: 1px solid #e5e7eb;
      color: #6b7280;
      font-size: 13px;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>$([System.Security.SecurityElement]::Escape($Title))</h1>
    <div class="subtitle">Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC</div>
    
    $warningsHtml
    
    $summaryHtml
    
    $previewHtml
    
    <div class="footer">
      <p><strong>AGenesysToolKit</strong> — Report Card</p>
      <p>Full data available in data.json, data.csv, and data.xlsx (if applicable).</p>
    </div>
  </div>
</body>
</html>
"@
  
  try {
    $html | Set-Content -Path $Path -Encoding UTF8
  } catch {
    throw "Failed to write HTML report: $_"
  }
}

function Write-GcDataArtifacts {
  <#
  .SYNOPSIS
    Writes data artifacts: JSON, CSV, and optional XLSX.
  
  .DESCRIPTION
    Exports data in multiple formats:
    - JSON: Full fidelity with nested objects
    - CSV: Flattened view for spreadsheet consumption
    - XLSX: Excel format if ImportExcel module is available
  
  .PARAMETER Rows
    Array of data rows
  
  .PARAMETER JsonPath
    Output path for data.json
  
  .PARAMETER CsvPath
    Output path for data.csv
  
  .PARAMETER XlsxPath
    Output path for data.xlsx (optional)
  
  .PARAMETER CreateXlsx
    Attempt to create XLSX if ImportExcel is available (default: $true)
  
  .OUTPUTS
    Hashtable with:
      - JsonCreated: boolean
      - CsvCreated: boolean
      - XlsxCreated: boolean
      - XlsxSkippedReason: string (if XLSX not created)
  
  .EXAMPLE
    Write-GcDataArtifacts -Rows $data -JsonPath "C:\artifacts\data.json" -CsvPath "C:\artifacts\data.csv" -XlsxPath "C:\artifacts\data.xlsx"
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Rows,
    
    [Parameter(Mandatory)]
    [string]$JsonPath,
    
    [Parameter(Mandatory)]
    [string]$CsvPath,
    
    [string]$XlsxPath,
    
    [bool]$CreateXlsx = $true
  )
  
  $result = @{
    JsonCreated = $false
    CsvCreated = $false
    XlsxCreated = $false
    XlsxSkippedReason = $null
  }
  
  # Write JSON
  try {
    $Rows | ConvertTo-Json -Depth 20 | Set-Content -Path $JsonPath -Encoding UTF8
    $result.JsonCreated = $true
  } catch {
    throw "Failed to write JSON data: $_"
  }
  
  # Write CSV
  try {
    if ($Rows.Count -gt 0) {
      $Rows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
      $result.CsvCreated = $true
    } else {
      # Create empty CSV with message
      "# No data rows" | Set-Content -Path $CsvPath -Encoding UTF8
      $result.CsvCreated = $true
    }
  } catch {
    throw "Failed to write CSV data: $_"
  }
  
  # Attempt XLSX if requested
  if ($CreateXlsx -and $XlsxPath) {
    try {
      # Check if ImportExcel module is available
      $importExcelAvailable = $null -ne (Get-Module -ListAvailable -Name ImportExcel -ErrorAction SilentlyContinue)
      
      if ($importExcelAvailable) {
        # Import module
        Import-Module ImportExcel -ErrorAction Stop
        
        # Export to XLSX
        if ($Rows.Count -gt 0) {
          $Rows | Export-Excel -Path $XlsxPath -AutoSize -FreezeTopRow -BoldTopRow
          $result.XlsxCreated = $true
        } else {
          # Create empty workbook with message
          @([PSCustomObject]@{ Message = "No data rows" }) | Export-Excel -Path $XlsxPath
          $result.XlsxCreated = $true
        }
      } else {
        $result.XlsxSkippedReason = "ImportExcel module not available"
      }
    } catch {
      $result.XlsxSkippedReason = "Error creating XLSX: $_"
    }
  } elseif (-not $CreateXlsx) {
    $result.XlsxSkippedReason = "XLSX creation not requested"
  } else {
    $result.XlsxSkippedReason = "XLSX path not provided"
  }
  
  return $result
}

function Update-GcArtifactIndex {
  <#
  .SYNOPSIS
    Updates the artifact index file with a new export entry.
  
  .DESCRIPTION
    Maintains a JSON index of all exports at App/artifacts/index.json.
    Appends new entry to the index array.
  
  .PARAMETER IndexPath
    Path to index.json (defaults to App/artifacts/index.json)
  
  .PARAMETER Entry
    Hashtable with export metadata:
      - ReportName
      - RunId
      - Timestamp
      - BundlePath
      - RowCount
      - Status (OK / Warnings / Failed)
      - Warnings (array)
  
  .EXAMPLE
    Update-GcArtifactIndex -Entry @{ ReportName = "Test"; RunId = "123"; Status = "OK" }
  #>
  [CmdletBinding()]
  param(
    [string]$IndexPath,
    
    [Parameter(Mandatory)]
    [hashtable]$Entry
  )
  
  # Default index path
  if (-not $IndexPath) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $artifactsDir = [System.IO.Path]::Combine($repoRoot, 'App', 'artifacts')
    $IndexPath = [System.IO.Path]::Combine($artifactsDir, 'index.json')
  }
  
  # Ensure artifacts directory exists
  $artifactsDir = Split-Path -Parent $IndexPath
  if (-not (Test-Path $artifactsDir)) {
    New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
  }
  
  # Load existing index
  $index = @()
  if (Test-Path $IndexPath) {
    try {
      $indexContent = Get-Content -Path $IndexPath -Raw -Encoding UTF8
      if ($indexContent) {
        $index = @($indexContent | ConvertFrom-Json)
      }
    } catch {
      Write-Warning "Failed to read existing index, creating new one: $_"
    }
  }
  
  # Add new entry
  $index += [PSCustomObject]$Entry
  
  # Write updated index
  try {
    $index | ConvertTo-Json -Depth 10 | Set-Content -Path $IndexPath -Encoding UTF8
  } catch {
    throw "Failed to update artifact index: $_"
  }
}

function Get-GcArtifactIndex {
  <#
  .SYNOPSIS
    Retrieves the artifact index.
  
  .DESCRIPTION
    Reads and returns the contents of App/artifacts/index.json.
  
  .PARAMETER IndexPath
    Path to index.json (defaults to App/artifacts/index.json)
  
  .OUTPUTS
    Array of export entries
  
  .EXAMPLE
    $exports = Get-GcArtifactIndex
  #>
  [CmdletBinding()]
  param(
    [string]$IndexPath
  )
  
  # Default index path
  if (-not $IndexPath) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $artifactsDir = [System.IO.Path]::Combine($repoRoot, 'App', 'artifacts')
    $IndexPath = [System.IO.Path]::Combine($artifactsDir, 'index.json')
  }
  
  if (-not (Test-Path $IndexPath)) {
    return @()
  }
  
  try {
    $indexContent = Get-Content -Path $IndexPath -Raw -Encoding UTF8
    if ($indexContent) {
      return @($indexContent | ConvertFrom-Json)
    } else {
      return @()
    }
  } catch {
    Write-Warning "Failed to read artifact index: $_"
    return @()
  }
}

function Open-GcArtifact {
  <#
  .SYNOPSIS
    Opens an artifact folder or file using the system default application.
  
  .DESCRIPTION
    Cross-platform helper to open folders or files in the system file browser or default application.
  
  .PARAMETER Path
    Path to folder or file to open
  
  .EXAMPLE
    Open-GcArtifact -Path "C:\artifacts\report-123\"
    Open-GcArtifact -Path "C:\artifacts\report-123\report.html"
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )
  
  if (-not (Test-Path $Path)) {
    throw "Path does not exist: $Path"
  }
  
  try {
    if ($IsWindows -or $env:OS -match 'Windows') {
      # Windows: Use explorer
      if (Test-Path $Path -PathType Container) {
        Start-Process 'explorer.exe' -ArgumentList $Path
      } else {
        Start-Process $Path
      }
    } elseif ($IsMacOS) {
      # macOS: Use open command
      Start-Process 'open' -ArgumentList $Path
    } else {
      # Linux: Use xdg-open
      Start-Process 'xdg-open' -ArgumentList $Path
    }
  } catch {
    throw "Failed to open artifact: $_"
  }
}

function Set-GcReportingConfig {
  <#
  .SYNOPSIS
    Configures default settings for reporting module.
  
  .PARAMETER DefaultOutputDirectory
    Default directory for artifacts
  
  .EXAMPLE
    Set-GcReportingConfig -DefaultOutputDirectory "C:\MyArtifacts"
  #>
  [CmdletBinding()]
  param(
    [string]$DefaultOutputDirectory
  )
  
  if ($DefaultOutputDirectory) {
    $script:ReportingConfig.DefaultOutputDirectory = $DefaultOutputDirectory
  }
}

# Export functions
Export-ModuleMember -Function @(
  'New-GcReportRunId',
  'New-GcArtifactBundle',
  'Write-GcReportHtml',
  'Write-GcDataArtifacts',
  'Update-GcArtifactIndex',
  'Get-GcArtifactIndex',
  'Open-GcArtifact',
  'Set-GcReportingConfig'
)

### END FILE: Core/Reporting.psm1
