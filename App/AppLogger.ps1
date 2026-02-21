# AppLogger.ps1
# ─────────────────────────────────────────────────────────────────────────────
# Always-on application logging, trace logging, and console diagnostics.
#
# Provides three logging channels:
#   1. App log   — structured, redacted, always written to artifacts/toolkit-*.log
#   2. Trace log — verbose HTTP/event tracing, opt-in via GC_TOOLKIT_TRACE=1
#   3. Console diagnostics — noisy token-workflow output to the host console
#
# Dot-sourced by GenesysCloudTool.ps1 at startup.
# After dot-sourcing, call Initialize-GcAppLogger once the artifacts directory
# is available:
#
#   . (Join-Path $scriptRoot 'AppLogger.ps1')
#   ...
#   $script:ArtifactsDir = Join-Path $PSScriptRoot 'artifacts'
#   New-Item -ItemType Directory -Path $script:ArtifactsDir -Force | Out-Null
#   Initialize-GcAppLogger -ArtifactsDir $script:ArtifactsDir
# ─────────────────────────────────────────────────────────────────────────────

### BEGIN: AppLoggerState
$script:GcAppLogEnvVar   = 'GC_TOOLKIT_APP_LOG'
$script:GcTraceEnvVar    = 'GC_TOOLKIT_TRACE'
$script:GcTraceLogEnvVar = 'GC_TOOLKIT_TRACE_LOG'
$script:GcAppLogPath     = $null
$script:GcTraceLogPath   = $null

# Console diagnostics are configured at dot-source time via env vars.
# Override at startup: set GC_TOOLKIT_DIAGNOSTICS=0 to suppress console output,
# GC_TOOLKIT_REVEAL_SECRETS=1 to print full token values (use with caution).
$script:GcConsoleDiagnosticsEnabled        = $true
$script:GcConsoleDiagnosticsRevealSecrets  = $false
try {
  if ($env:GC_TOOLKIT_DIAGNOSTICS -and ($env:GC_TOOLKIT_DIAGNOSTICS -match '^(0|false|no|off)$')) {
    $script:GcConsoleDiagnosticsEnabled = $false
  }
  if ($env:GC_TOOLKIT_REVEAL_SECRETS -and ($env:GC_TOOLKIT_REVEAL_SECRETS -match '^(1|true|yes|on)$')) {
    $script:GcConsoleDiagnosticsRevealSecrets = $true
  }
} catch {
  Write-Verbose "[AppLogger] Failed to read diagnostics env vars: $_"
}
### END: AppLoggerState

### BEGIN: InitializeGcAppLogger
function Initialize-GcAppLogger {
  <#
  .SYNOPSIS
    Sets up log file paths and registers them as process-scoped environment variables.
    Must be called once after the artifacts directory is created.

  .PARAMETER ArtifactsDir
    Absolute path to the artifacts output directory (App/artifacts/).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ArtifactsDir
  )

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $script:GcAppLogPath   = Join-Path $ArtifactsDir ("toolkit-{0}.log" -f $stamp)
  $script:GcTraceLogPath = Join-Path $ArtifactsDir ("trace-{0}.log"   -f $stamp)

  try {
    [Environment]::SetEnvironmentVariable($script:GcAppLogEnvVar,   $script:GcAppLogPath,   'Process')
  } catch {
    Write-Verbose "[AppLogger] Failed to register GC_TOOLKIT_APP_LOG env var: $_"
  }
  try {
    [Environment]::SetEnvironmentVariable($script:GcTraceLogEnvVar, $script:GcTraceLogPath, 'Process')
  } catch {
    Write-Verbose "[AppLogger] Failed to register GC_TOOLKIT_TRACE_LOG env var: $_"
  }
}
### END: InitializeGcAppLogger

### BEGIN: AppLogHelpers
function ConvertTo-GcAppLogSafeString {
  [CmdletBinding()]
  param(
    [AllowNull()] $Value,
    [int] $KeepStart = 8,
    [int] $KeepEnd = 4
  )

  if ($null -eq $Value) { return $null }
  $s = [string]$Value
  if ([string]::IsNullOrWhiteSpace($s)) { return '<empty>' }
  if ($s.Length -le ($KeepStart + $KeepEnd + 3)) { return ("<{0} chars>" -f $s.Length) }
  return ("{0}…{1} (<{2} chars>)" -f $s.Substring(0, $KeepStart), $s.Substring($s.Length - $KeepEnd), $s.Length)
}

function ConvertTo-GcAppLogSafeData {
  [CmdletBinding()]
  param(
    [AllowNull()] $Data,
    [int] $Depth = 0
  )

  if ($null -eq $Data) { return $null }
  if ($Depth -gt 6) { return '[MaxDepth]' }

  if ($Data -is [hashtable]) {
    $out = @{}
    foreach ($k in $Data.Keys) {
      $key = [string]$k
      $v = $Data[$k]
      if ($key -match '(?i)secret|token|authorization|code_verifier|verifier|authcode|code|access_token|refresh_token') {
        $out[$key] = ConvertTo-GcAppLogSafeString -Value $v
      } else {
        $out[$key] = ConvertTo-GcAppLogSafeData -Data $v -Depth ($Depth + 1)
      }
    }
    return $out
  }

  if ($Data -is [System.Collections.IEnumerable] -and -not ($Data -is [string])) {
    $arr = @()
    foreach ($item in $Data) {
      $arr += (ConvertTo-GcAppLogSafeData -Data $item -Depth ($Depth + 1))
    }
    return $arr
  }

  return $Data
}

function Write-GcAppLog {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Message,
    [ValidateSet('TRACE','DEBUG','INFO','WARN','ERROR','DIAG','JOB','UI','HTTP','AUTH')]
    [string] $Level = 'INFO',
    [string] $Category,
    [hashtable] $Data
  )

  $ts = (Get-Date).ToString('o')
  $cat = if ($Category) { $Category } else { 'app' }
  $line = "[{0}] [{1}] [{2}] {3}" -f $ts, $Level.ToUpperInvariant(), $cat, $Message

  if ($Data) {
    try {
      $safe = ConvertTo-GcAppLogSafeData -Data $Data
      $json = ($safe | ConvertTo-Json -Depth 12 -Compress)
      $line += " | data=$json"
    } catch {
      $line += " | data=<unserializable>"
    }
  }

  try {
    $path = $null
    try { $path = [Environment]::GetEnvironmentVariable($script:GcAppLogEnvVar) } catch {
      Write-Verbose "[AppLogger] Could not read GC_TOOLKIT_APP_LOG env var: $_"
      $path = $null
    }
    if ($path) { Add-Content -LiteralPath $path -Value $line -Encoding utf8 }
  } catch {
    # Intentional: log writes must never crash the app.
    Write-Verbose "[AppLogger] Log write failed: $_"
  }
}
### END: AppLogHelpers

### BEGIN: TraceHelpers
function Test-GcTraceEnabled {
  try {
    $v = [Environment]::GetEnvironmentVariable($script:GcTraceEnvVar)
    return ($v -and ($v -match '^(1|true|yes|on)$'))
  } catch {
    return $false
  }
}

function Write-GcTrace {
  param(
    [Parameter(Mandatory)][string]$Message,
    [string]$Level = 'INFO'
  )

  if (-not (Test-GcTraceEnabled)) { return }

  $ts = (Get-Date).ToString('HH:mm:ss.fff')
  $line = "[{0}] [{1}] {2}" -f $ts, $Level.ToUpperInvariant(), $Message

  try {
    $path = [Environment]::GetEnvironmentVariable($script:GcTraceLogEnvVar)
    if ($path) { Add-Content -LiteralPath $path -Value $line -Encoding utf8 }
  } catch {
    # Intentional: trace write failure must not surface to the user.
    Write-Verbose "[AppLogger] Trace write failed: $_"
  }
}
### END: TraceHelpers

### BEGIN: ConsoleDiagnostics
function Format-GcDiagSecret {
  param(
    [AllowNull()][AllowEmptyString()][string]$Value,
    [int]$Head = 10,
    [int]$Tail = 6
  )

  if ($script:GcConsoleDiagnosticsRevealSecrets) { return $Value }
  if ([string]::IsNullOrWhiteSpace($Value)) { return '<empty>' }

  $len = $Value.Length
  if ($len -le ($Head + $Tail + 3)) { return ("<{0} chars>" -f $len) }
  return ("{0}...{1} (<{2} chars>)" -f $Value.Substring(0, $Head), $Value.Substring($len - $Tail), $len)
}

function Write-GcDiag {
  param(
    [Parameter(Mandatory)][string]$Message
  )
  $ts = (Get-Date).ToString('HH:mm:ss.fff')
  $line = ("[{0}] [DIAG] {1}" -f $ts, $Message)
  if ($script:GcConsoleDiagnosticsEnabled) {
    Write-Host $line
  }
  try { Write-GcAppLog -Level 'DIAG' -Category 'diag' -Message $Message } catch {
    Write-Verbose "[AppLogger] Write-GcDiag app log write failed: $_"
  }
  Write-GcTrace -Level 'DIAG' -Message $Message
}
### END: ConsoleDiagnostics
