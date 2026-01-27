### BEGIN FILE: Core/Diagnostics.psm1

Set-StrictMode -Version Latest

<#
.SYNOPSIS
  Diagnostic logging module for AGenesysToolKit.

.DESCRIPTION
  Provides diagnostic logging capabilities to help troubleshoot issues.
  Logs are written to a file in the temp directory by default.
#>

$script:DiagnosticLogPath = $null

function Enable-GcDiagnostics {
  <#
  .SYNOPSIS
    Enables diagnostic logging to a file.
  
  .DESCRIPTION
    Creates a diagnostic log file in the specified directory (or temp directory by default).
    Once enabled, all calls to Write-GcDiagnostic will append to this log file.
  
  .PARAMETER LogDirectory
    Directory where the diagnostic log file will be created.
    If not specified, uses the system temp directory.
  
  .OUTPUTS
    Path to the created log file.
  
  .EXAMPLE
    Enable-GcDiagnostics
    # Enables diagnostics with default temp directory
  
  .EXAMPLE
    Enable-GcDiagnostics -LogDirectory "C:\Logs\AGenesysToolKit"
    # Enables diagnostics with custom directory
  #>
  [CmdletBinding()]
  param(
    [string]$LogDirectory
  )
  
  if (-not $LogDirectory) {
    # Try $env:TEMP, fallback to /tmp or current directory
    if ($env:TEMP) {
      $LogDirectory = Join-Path $env:TEMP 'AGenesysToolKit'
    } elseif ($env:TMPDIR) {
      $LogDirectory = Join-Path $env:TMPDIR 'AGenesysToolKit'
    } elseif (Test-Path '/tmp') {
      $LogDirectory = '/tmp/AGenesysToolKit'
    } else {
      $LogDirectory = Join-Path (Get-Location) 'temp/AGenesysToolKit'
    }
  }
  
  try {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:DiagnosticLogPath = Join-Path $LogDirectory "diagnostic-$timestamp.log"
    
    # Create the log file
    "Diagnostics enabled: $script:DiagnosticLogPath" | Set-Content -Path $script:DiagnosticLogPath -Encoding UTF8
    
    return $script:DiagnosticLogPath
  } catch {
    Write-Warning "Failed to enable diagnostics: $_"
    return $null
  }
}

function Write-GcDiagnostic {
  <#
  .SYNOPSIS
    Writes a diagnostic message to the log file.
  
  .DESCRIPTION
    Appends a timestamped diagnostic message to the log file if diagnostics are enabled.
    If diagnostics are not enabled, this function does nothing.
  
  .PARAMETER Message
    The diagnostic message to write.
  
  .PARAMETER Level
    The log level (INFO, WARN, ERROR, DEBUG). Defaults to INFO.
  
  .EXAMPLE
    Write-GcDiagnostic "Starting report generation"
  
  .EXAMPLE
    Write-GcDiagnostic "Failed to connect to API" -Level ERROR
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Message,
    
    [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
    [string]$Level = 'INFO'
  )
  
  if (-not $script:DiagnosticLogPath) { 
    return 
  }
  
  try {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $entry = "[$timestamp] [$Level] $Message"
    
    Add-Content -Path $script:DiagnosticLogPath -Value $entry -Encoding UTF8
  } catch {
    # Silently fail if we can't write to the log
    Write-Verbose "Failed to write diagnostic: $_"
  }
}

function Get-GcDiagnosticLogPath {
  <#
  .SYNOPSIS
    Returns the current diagnostic log file path.
  
  .DESCRIPTION
    Returns the path to the current diagnostic log file if diagnostics are enabled.
    Returns $null if diagnostics are not enabled.
  
  .OUTPUTS
    String path to the log file, or $null.
  
  .EXAMPLE
    $logPath = Get-GcDiagnosticLogPath
    if ($logPath) { Start-Process $logPath }
  #>
  [CmdletBinding()]
  param()
  
  return $script:DiagnosticLogPath
}

# Export functions
Export-ModuleMember -Function @(
  'Enable-GcDiagnostics',
  'Write-GcDiagnostic',
  'Get-GcDiagnosticLogPath'
)

### END FILE: Core/Diagnostics.psm1
