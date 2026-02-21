### BEGIN: Core.HttpRequests.psm1

Set-StrictMode -Version Latest

# Module-level AppState reference (set by calling application)
$script:AppState = $null
$script:OfflineDemoEnvVar = 'GC_TOOLKIT_OFFLINE_DEMO'
$script:TraceEnvVar = 'GC_TOOLKIT_TRACE'
$script:TraceLogEnvVar = 'GC_TOOLKIT_TRACE_LOG'
$script:TraceBodyEnvVar = 'GC_TOOLKIT_TRACE_BODY'

function Test-GcOfflineDemoEnabled {
  try {
    $v = [Environment]::GetEnvironmentVariable($script:OfflineDemoEnvVar)
    if ($v -and ($v -match '^(1|true|yes|on)$')) {
      return $true
    }
  } catch {
    # Intentional: GetEnvironmentVariable guard for pathological process environments.
    Write-Verbose "[HttpRequests] GetEnvironmentVariable($script:OfflineDemoEnvVar) failed: $_"
  }
  return $false
}

function Test-GcToolkitTraceEnabled {
  try {
    $v = [Environment]::GetEnvironmentVariable($script:TraceEnvVar)
    return ($v -and ($v -match '^(1|true|yes|on)$'))
  } catch {
    # Intentional: GetEnvironmentVariable guard for pathological process environments.
    Write-Verbose "[HttpRequests] GetEnvironmentVariable($script:TraceEnvVar) failed: $_"
  }
  return $false
}

function Test-GcToolkitTraceBodyEnabled {
  # For safety: only log request bodies when explicitly enabled, or in OfflineDemo.
  try {
    if (Test-GcOfflineDemoEnabled) { return $true }
    $v = [Environment]::GetEnvironmentVariable($script:TraceBodyEnvVar)
    return ($v -and ($v -match '^(1|true|yes|on)$'))
  } catch { Write-Verbose "Ignored error: $_" }
  return $false
}

function Get-GcToolkitTraceLogPath {
  try {
    $p = [Environment]::GetEnvironmentVariable($script:TraceLogEnvVar)
    if (-not [string]::IsNullOrWhiteSpace($p)) { return $p }
  } catch { Write-Verbose "Ignored error: $_" }
  return $null
}

function ConvertTo-GcTraceSnippet {
  [CmdletBinding()]
  param(
    [AllowNull()] [object] $Value,
    [int] $MaxChars = 1200
  )

  if ($null -eq $Value) { return '<null>' }

  $text = $null
  if ($Value -is [string]) {
    $text = $Value
  } else {
    try { $text = ($Value | ConvertTo-Json -Compress -Depth 15) } catch { $text = ($Value | Out-String) }
  }

  if ($null -eq $text) { return '<null>' }
  $text = [string]$text
  $text = $text -replace "[\r\n]+", " "
  if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + '…' }
  return $text
}

function Write-GcToolkitTrace {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Message,
    [ValidateSet('INFO','WARN','ERROR','DEBUG')][string] $Level = 'INFO'
  )

  if (-not (Test-GcToolkitTraceEnabled)) { return }

  $ts = (Get-Date).ToString('HH:mm:ss.fff')
  $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message

  try {
    $path = Get-GcToolkitTraceLogPath
    if ($path) { Add-Content -LiteralPath $path -Value $line -Encoding utf8 }
  } catch {
    # Intentional: trace log write failure must not bubble out of a tracing helper.
    # Write-Verbose is used as fallback (never throws in practice).
    Write-Verbose "[HttpRequests] Trace file write failed: $_"
  }

  # Always also emit to Verbose so developers can opt-in to console output.
  try { Write-Verbose $line } catch {
    # Intentional: Write-Verbose guard for restricted runspace environments.
    $null = $_
  }
}

function Get-GcToolkitAppLogPath {
  [CmdletBinding()]
  param()
  try {
    $p = [Environment]::GetEnvironmentVariable('GC_TOOLKIT_APP_LOG')
    if (-not [string]::IsNullOrWhiteSpace($p)) { return $p }
  } catch { Write-Verbose "Ignored error: $_" }
  return $null
}

function ConvertTo-GcToolkitAppLogSafeString {
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

function ConvertTo-GcToolkitAppLogSafeData {
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
        $out[$key] = ConvertTo-GcToolkitAppLogSafeString -Value $v
      } else {
        $out[$key] = ConvertTo-GcToolkitAppLogSafeData -Data $v -Depth ($Depth + 1)
      }
    }
    return $out
  }

  if ($Data -is [System.Collections.IEnumerable] -and -not ($Data -is [string])) {
    $arr = @()
    foreach ($item in $Data) {
      $arr += (ConvertTo-GcToolkitAppLogSafeData -Data $item -Depth ($Depth + 1))
    }
    return $arr
  }

  return $Data
}

function Write-GcToolkitAppLog {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet('TRACE','DEBUG','INFO','WARN','ERROR','HTTP')]
    [string]$Level = 'INFO',
    [string]$Category = 'http',
    [hashtable]$Data
  )

  $path = Get-GcToolkitAppLogPath
  if (-not $path) { return }

  $ts = (Get-Date).ToString('o')
  $line = "[{0}] [{1}] [{2}] {3}" -f $ts, $Level.ToUpperInvariant(), $Category, $Message
  if ($Data) {
    try {
      $safe = ConvertTo-GcToolkitAppLogSafeData -Data $Data
      $json = ($safe | ConvertTo-Json -Depth 12 -Compress)
      $line += " | data=$json"
    } catch {
      $line += " | data=<unserializable>"
    }
  }
  try {
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
  } catch {
    # Intentional: app log write failure must not bubble out of a logging helper.
    Write-Verbose "[HttpRequests] App log write failed (path: $path): $_"
  }
}

function Set-GcAppState {
  <#
  .SYNOPSIS
    Sets the AppState reference for Invoke-AppGcRequest to use.
  
  .DESCRIPTION
    This function allows the calling application to provide its AppState
    to the HttpRequests module, enabling Invoke-AppGcRequest to automatically
    inject AccessToken and Region without requiring them as parameters.
  
  .PARAMETER State
    Reference to the application's $script:AppState hashtable
  
  .EXAMPLE
    Set-GcAppState -State ([ref]$script:AppState)
  
  .NOTES
    Added for Step 1: Token plumbing implementation.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ref]$State
  )
  
  $script:AppState = $State.Value
}

function Normalize-GcInstanceName {
  <#
  .SYNOPSIS
    Normalizes user-provided region/host input into a Genesys Cloud instance name.

  .DESCRIPTION
    Accepts values like:
      - usw2.pure.cloud
      - api.usw2.pure.cloud
      - apps.usw2.pure.cloud
      - https://api.usw2.pure.cloud
      - https://apps.usw2.pure.cloud/some/path

    Returns the instance name (ex: usw2.pure.cloud) suitable for building:
      https://api.<instanceName>/
  #>
  [CmdletBinding()]
  param(
    [AllowNull()][AllowEmptyString()]
    [string] $RegionText
  )

  if ([string]::IsNullOrWhiteSpace($RegionText)) { return $null }

  $text = $RegionText.Trim()

  # Strip common wrapping quotes when copying from JSON/CLI output.
  if (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'"))) {
    if ($text.Length -ge 2) { $text = $text.Substring(1, $text.Length - 2) }
  }

  $gcHost = $text

  # If a full URL was provided, extract Host; otherwise, strip any path fragment.
  if ($gcHost -match '^[a-zA-Z][a-zA-Z0-9+\.-]*://') {
    try {
      $uri = [Uri]$gcHost
      if ($uri.Host) { $gcHost = $uri.Host }
    } catch { Write-Verbose "Ignored error: $_" }
  } else {
    $gcHost = ($gcHost -split '/')[0]
  }

  # Strip :port if present.
  if ($gcHost -match '^(?<h>[^:]+):\d+$') {
    $gcHost = $matches['h']
  }

  # Remove invisible/whitespace characters that commonly sneak in during copy/paste.
  $gcHost = $gcHost -replace "[\u200B-\u200D\uFEFF]", ""
  $gcHost = $gcHost -replace "\s+", ""

  $gcHost = $gcHost.Trim().Trim('.').ToLowerInvariant()

  # Allow users to paste api./apps./login. URLs and normalize back to region.
  if ($gcHost -match '^(api|apps|login|signin|sso|auth)\.(?<rest>.+)$') {
    $gcHost = $matches['rest']
  }

  return $gcHost
}

function Normalize-GcAccessToken {
  <#
  .SYNOPSIS
    Normalizes user-provided access token input (manual paste).

  .DESCRIPTION
    Handles common paste formats:
      - Raw token
      - "Bearer <token>"
      - "Authorization: Bearer <token>"
      - JSON token response containing access_token
    Removes whitespace/line breaks and zero-width characters.
  #>
  [CmdletBinding()]
  param(
    [AllowNull()][AllowEmptyString()]
    [string] $TokenText
  )

  if ([string]::IsNullOrWhiteSpace($TokenText)) { return $null }

  $raw = $TokenText.Trim()

  # If user pasted a JSON token response, extract access_token.
  if ($raw -match '(?i)\baccess_token\b' -and ($raw.TrimStart().StartsWith('{') -or $raw.TrimStart().StartsWith('['))) {
    try {
      $obj = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($obj -and $obj.access_token) {
        $raw = [string]$obj.access_token
      }
    } catch { Write-Verbose "Ignored error: $_" }
  }

  # Handle common header formats.
  $raw = ($raw -replace '(?i)^\s*authorization\s*:\s*bearer\s+', '')
  $raw = ($raw -replace '(?i)^\s*bearer\s*:\s*', '')
  $raw = ($raw -replace '(?i)^\s*bearer\s+', '')

  $raw = $raw.Trim()

  # Strip wrapping quotes.
  if (($raw.StartsWith('"') -and $raw.EndsWith('"')) -or ($raw.StartsWith("'") -and $raw.EndsWith("'"))) {
    if ($raw.Length -ge 2) { $raw = $raw.Substring(1, $raw.Length - 2) }
  }

  # Remove whitespace/line breaks and zero-width chars introduced by copy/paste.
  $raw = $raw -replace "[\u200B-\u200D\uFEFF]", ""
  $raw = $raw -replace "\s+", ""

  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  return $raw
}

function Resolve-GcEndpoint {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Path,
    [hashtable] $PathParams
  )

  $resolved = $Path.TrimStart('/')

  # Replace {token} path params (ex: {conversationId})
  if ($PathParams) {
    foreach ($k in $PathParams.Keys) {
      $token = '{' + $k + '}'
      if ($resolved -like "*$token*") {
        $resolved = $resolved.Replace($token, [string]$PathParams[$k])
      }
    }
  }

  return $resolved
}

function ConvertTo-GcQueryString {
  [CmdletBinding()]
  param(
    [hashtable] $Query
  )

  if (-not $Query -or $Query.Count -eq 0) { return "" }

  $pairs = foreach ($kv in $Query.GetEnumerator()) {
    if ($null -eq $kv.Value) { continue }

    # Allow arrays: key=a&key=b
    if ($kv.Value -is [System.Collections.IEnumerable] -and -not ($kv.Value -is [string])) {
      foreach ($v in $kv.Value) {
        "{0}={1}" -f [Uri]::EscapeDataString([string]$kv.Key), [Uri]::EscapeDataString([string]$v)
      }
    } else {
      "{0}={1}" -f [Uri]::EscapeDataString([string]$kv.Key), [Uri]::EscapeDataString([string]$kv.Value)
    }
  }

  return ($pairs -join "&")
}

function Join-GcUri {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $BaseUri,
    [Parameter(Mandatory)] [string] $RelativePath,
    [string] $QueryString
  )

  $base = $BaseUri.TrimEnd('/')
  $rel  = $RelativePath.TrimStart('/')

  if ([string]::IsNullOrWhiteSpace($QueryString)) {
    return "$base/$rel"
  }

  return "$base/$rel`?$QueryString"
}

function Invoke-GcWithRetry {
  <#
  .SYNOPSIS
    Private retry helper used by Invoke-GcRequest and Invoke-GcPagedRequest.

  .DESCRIPTION
    Wraps a scriptblock in a retry loop with:
      - Exponential backoff with jitter (base * 2^attempt + 0–1 s jitter)
      - Retry-After header honoured when present on 429/503 responses
      - Trace logging on every retry and final failure
      - Configurable max delay ceiling

  .PARAMETER ScriptBlock
    The operation to retry. Must throw on failure.

  .PARAMETER RetryCount
    Maximum number of retries (0 = no retries; default: 2).

  .PARAMETER BaseDelaySeconds
    Delay for the first retry. Doubles on each subsequent attempt (default: 2).

  .PARAMETER MaxDelaySeconds
    Ceiling on computed exponential delay before jitter (default: 30).

  .PARAMETER OperationLabel
    Human-readable label for trace messages (e.g. "GET /api/v2/users").
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][scriptblock] $ScriptBlock,
    [int]    $RetryCount        = 2,
    [int]    $BaseDelaySeconds  = 2,
    [int]    $MaxDelaySeconds   = 30,
    [string] $OperationLabel    = 'HTTP'
  )

  $attempt = 0
  while ($true) {
    try {
      return & $ScriptBlock
    } catch {
      $attempt++

      if ($attempt -gt $RetryCount) {
        Write-GcToolkitTrace -Level ERROR -Message ("[RETRY] $OperationLabel — max retries ($RetryCount) exceeded: $($_.Exception.Message)")
        throw
      }

      # Respect Retry-After header (seconds) when the server provides it.
      $retryAfterSec = $null
      try {
        $resp = $_.Exception.Response
        if ($resp) {
          $raRaw = $null
          # PS 5.1 HttpWebResponse
          if ($resp -is [System.Net.HttpWebResponse]) {
            $raRaw = $resp.Headers['Retry-After']
          }
          # PS 7+ HttpResponseMessage
          if ($resp -is [System.Net.Http.HttpResponseMessage]) {
            $retryHeader = $resp.Headers.RetryAfter
            if ($retryHeader -and $retryHeader.Delta) {
              $retryAfterSec = [int]$retryHeader.Delta.TotalSeconds
            } elseif ($retryHeader -and $retryHeader.Date) {
              $retryAfterSec = [int]([DateTime]::UtcNow - $retryHeader.Date.UtcDateTime).TotalSeconds * -1
            }
          }
          if ($raRaw -and $null -eq $retryAfterSec) {
            $parsed = 0
            if ([int]::TryParse($raRaw, [ref]$parsed)) { $retryAfterSec = $parsed }
          }
        }
      } catch {
        # Intentional: Retry-After extraction is best-effort; failure does not block retry.
        Write-Verbose "[HttpRequests] Retry-After header extraction failed: $_"
      }

      if ($null -ne $retryAfterSec -and $retryAfterSec -gt 0) {
        $delaySec = $retryAfterSec
        Write-GcToolkitTrace -Level WARN -Message ("[RETRY] $OperationLabel — attempt $attempt/$RetryCount honouring Retry-After: ${delaySec}s — $($_.Exception.Message)")
      } else {
        # Exponential backoff: base * 2^(attempt-1), capped, plus up to 1 s of jitter.
        $exponential = [Math]::Min($BaseDelaySeconds * [Math]::Pow(2, $attempt - 1), $MaxDelaySeconds)
        $jitterSec   = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
        $delaySec    = $exponential + $jitterSec
        Write-GcToolkitTrace -Level WARN -Message ("[RETRY] $OperationLabel — attempt $attempt/$RetryCount sleeping ${delaySec}s — $($_.Exception.Message)")
      }

      Start-Sleep -Seconds $delaySec
    }
  }
}

function Invoke-GcRequest {
  <#
  .SYNOPSIS
    Single Genesys Cloud API request (no pagination loop).

  .DESCRIPTION
    - Builds https://api.<InstanceName>/ + path
    - Replaces {pathParams}
    - Adds query string
    - Adds Authorization header if AccessToken provided
    - Retries transient failures (optional)

  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Path,

    [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
    [string] $Method = 'GET',

    # Either supply InstanceName (ex: "usw2.pure.cloud") or BaseUri directly.
    [string] $InstanceName = "usw2.pure.cloud",
    [string] $BaseUri,

    [hashtable] $Headers,
    [string] $AccessToken,

    [hashtable] $Query,
    [hashtable] $PathParams,

    [object] $Body,

    [int] $RetryCount = 2,
    [int] $RetryDelaySeconds = 2
  )

  if (-not $BaseUri) {
    $BaseUri = "https://api.$($InstanceName)/"
  }

  $resolvedPath = Resolve-GcEndpoint -Path $Path -PathParams $PathParams
  $qs  = ConvertTo-GcQueryString -Query $Query
  $uri = Join-GcUri -BaseUri $BaseUri -RelativePath $resolvedPath -QueryString $qs
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  # Offline demo: serve responses from local sample data (no network).
  if (Test-GcOfflineDemoEnabled) {
    Write-GcToolkitTrace -Level INFO -Message ("OFFLINE {0} {1}" -f $Method, $uri)
    Write-GcToolkitAppLog -Level 'HTTP' -Category 'http' -Message 'OFFLINE request' -Data @{
      Method      = $Method
      Uri         = $uri
      InstanceName = $InstanceName
    }
    if (Test-GcToolkitTraceBodyEnabled -and $Method -in @('POST','PUT','PATCH') -and $null -ne $Body) {
      Write-GcToolkitTrace -Level DEBUG -Message ("OFFLINE body: {0}" -f (ConvertTo-GcTraceSnippet -Value $Body))
    }

    $sampleModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'SampleData.psm1'
    if (-not (Get-Module -Name SampleData)) {
      if (Test-Path $sampleModulePath) {
        Import-Module $sampleModulePath -Force -ErrorAction Stop
      } else {
        throw "Offline demo enabled but sample data module not found: $sampleModulePath"
      }
    }

    $bodyObj = $Body
    if ($Body -is [string]) {
      try { $bodyObj = ($Body | ConvertFrom-Json -ErrorAction Stop) } catch { $bodyObj = $Body }
    }

    return Invoke-GcSampleRequest -Path ("/{0}" -f $resolvedPath.TrimStart('/')) -Method $Method -Query $Query -PathParams $PathParams -Body $bodyObj
  }

  # Headers
  $h = @{}
  if ($Headers) { foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] } }

  if ($AccessToken) {
    $h['Authorization'] = "Bearer $($AccessToken)"
  }

  if (-not $h.ContainsKey('Content-Type')) {
    $h['Content-Type'] = "application/json; charset=utf-8"
  }

  Write-Verbose ("GC {0} {1}" -f $Method, $uri)
  Write-GcToolkitTrace -Level INFO -Message ("HTTP {0} {1}" -f $Method, $uri)
  Write-GcToolkitAppLog -Level 'HTTP' -Category 'http' -Message 'Request' -Data @{
    Method       = $Method
    Uri          = $uri
    InstanceName = $InstanceName
    Path         = $resolvedPath
    QueryKeys    = if ($Query) { @($Query.Keys) } else { @() }
    HasBody      = [bool]($Method -in @('POST','PUT','PATCH') -and $null -ne $Body)
    TokenLength  = if ($AccessToken) { $AccessToken.Length } else { 0 }
  }

  $irmParams = @{
    Uri     = $uri
    Method  = $Method
    Headers = $h
  }

  if ($Method -in @('POST','PUT','PATCH') -and $null -ne $Body) {
    # If already a string assume caller knows; otherwise JSON it.
    if ($Body -is [string]) {
      $irmParams['Body'] = $Body
    } else {
      $irmParams['Body'] = ($Body | ConvertTo-Json -Depth 25)
    }
  }

  if (Test-GcToolkitTraceBodyEnabled -and $Method -in @('POST','PUT','PATCH') -and $irmParams.ContainsKey('Body')) {
    Write-GcToolkitTrace -Level DEBUG -Message ("HTTP body: {0}" -f (ConvertTo-GcTraceSnippet -Value $irmParams['Body']))
  }

  $attempt = 0
  while ($true) {
    try {
      $result = Invoke-RestMethod @irmParams
      Write-GcToolkitTrace -Level INFO -Message ("HTTP OK {0} {1}" -f $Method, $uri)
      try {
        $sw.Stop()
        Write-GcToolkitAppLog -Level 'HTTP' -Category 'http' -Message 'Response OK' -Data @{
          Method     = $Method
          Uri        = $uri
          ElapsedMs  = $sw.ElapsedMilliseconds
        }
      } catch {
        # Intentional: telemetry write must not mask a successful API response.
        Write-Verbose "[HttpRequests] Success telemetry write failed: $_"
      }
      return $result
    } catch {
      $attempt++

      if ($attempt -gt $RetryCount) {
        Write-GcToolkitTrace -Level ERROR -Message ("HTTP FAIL {0} {1} :: {2}" -f $Method, $uri, $_.Exception.Message)
        try {
          $sw.Stop()
          $statusCode = $null
          try {
            if ($_.Exception.Response -is [System.Net.HttpWebResponse]) { $statusCode = [int]$_.Exception.Response.StatusCode }
            if ($_.Exception.Response -is [System.Net.Http.HttpResponseMessage]) { $statusCode = [int]$_.Exception.Response.StatusCode }
          } catch {
            # Intentional: status code extraction is best-effort across PS 5.1/7+ response types.
            Write-Verbose "[HttpRequests] Status code extraction failed: $_"
          }
          Write-GcToolkitAppLog -Level 'ERROR' -Category 'http' -Message 'Request failed' -Data @{
            Method     = $Method
            Uri        = $uri
            StatusCode = $statusCode
            Error      = $_.Exception.Message
            ElapsedMs  = $sw.ElapsedMilliseconds
          }
        } catch {
          # Intentional: failure telemetry must not mask the original exception being re-thrown.
          Write-Verbose "[HttpRequests] Failure telemetry write failed: $_"
        }
        throw
      }

      # Respect Retry-After when present (same logic as Invoke-GcWithRetry).
      $retryDelaySec = $null
      try {
        $resp = $_.Exception.Response
        if ($resp -is [System.Net.HttpWebResponse]) {
          $raRaw = $resp.Headers['Retry-After']
          $parsed = 0
          if ($raRaw -and [int]::TryParse($raRaw, [ref]$parsed)) { $retryDelaySec = $parsed }
        }
      } catch {
        # Intentional: Retry-After extraction is best-effort.
        Write-Verbose "[HttpRequests] Retry-After extraction failed: $_"
      }
      if ($null -eq $retryDelaySec) {
        $exponential   = [Math]::Min($RetryDelaySeconds * [Math]::Pow(2, $attempt - 1), 30)
        $jitterSec     = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
        $retryDelaySec = $exponential + $jitterSec
      }

      Write-GcToolkitTrace -Level WARN -Message ("HTTP RETRY {0}/{1} {2} sleeping {3}s :: {4}" -f $attempt, $RetryCount, $uri, $retryDelaySec, $_.Exception.Message)
      Write-Verbose ("Retry {0}/{1} after error: {2}" -f $attempt, $RetryCount, $_.Exception.Message)
      try {
        Write-GcToolkitAppLog -Level 'WARN' -Category 'http' -Message 'Retry' -Data @{
          Attempt       = $attempt
          RetryCount    = $RetryCount
          Uri           = $uri
          DelaySec      = $retryDelaySec
          Error         = $_.Exception.Message
        }
      } catch {
        # Intentional: retry telemetry must not mask the retry logic itself.
        Write-Verbose "[HttpRequests] Retry telemetry write failed: $_"
      }
      Start-Sleep -Seconds $retryDelaySec
    }
  }
}

function Get-GcItemsFromResponse {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Response,
    [string[]] $ItemProperties = @('entities','results','conversations','items','data')
  )

  # If API returns an array directly
  if ($Response -is [System.Collections.IEnumerable] -and -not ($Response -is [string]) -and -not ($Response.PSObject.Properties.Name -contains 'PSComputerName')) {
    if ($Response -isnot [hashtable] -and $Response -isnot [pscustomobject]) {
      return ,$Response
    }
  }

  $all = New-Object 'System.Collections.Generic.List[object]'

  foreach ($p in $ItemProperties) {
    if ($Response.PSObject.Properties.Name -contains $p) {
      $val = $Response.$p
      if ($val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
        foreach ($x in $val) { [void]$all.Add($x) }
      }
    }
  }

  return $all
}

function Resolve-GcNextLinkToUri {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $NextValue,
    [Parameter(Mandatory)] [string] $BaseUri,
    [Parameter(Mandatory)] [string] $ResolvedPath
  )

  $n = $NextValue.Trim()

  # Full URL
  if ($n -match '^https?://') { return $n }

  # Relative path
  if ($n.StartsWith('/')) {
    $base = $BaseUri.TrimEnd('/')
    return "$base/$($n.TrimStart('/'))"
  }

  # Querystring-ish (your pattern: ^[^/?]+= )
  if ($n -match '^[^/?]+=' ) {
    $base = $BaseUri.TrimEnd('/')
    $rel  = $ResolvedPath.TrimStart('/')
    return "$base/$rel`?$n"
  }

  # Fallback: treat as already-formed URI-ish
  return $n
}

function Invoke-GcPagedRequest {
  <#
  .SYNOPSIS
    Calls a Genesys Cloud endpoint and auto-paginates until completion (default behavior).

  .DESCRIPTION
    Supports:
      - nextPage (querystring or relative path or full URL)
      - nextUri  (querystring or relative path or full URL)
      - pageCount/pageNumber (page-based pagination)
      - cursor-style pagination (cursor/nextCursor fields)

    Returns:
      - By default: the merged item list (entities/results/conversations/etc)
      - If no item list detected: returns the last response object
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Path,

    [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
    [string] $Method = 'GET',

    [string] $InstanceName = "usw2.pure.cloud",
    [string] $BaseUri,

    [hashtable] $Headers,
    [string] $AccessToken,

    [hashtable] $Query,
    [hashtable] $PathParams,
    [object] $Body,

    # Default: engineers get the whole dataset
    [switch] $All = $true,

    [int] $PageSize = 100,
    [int] $MaxPages = 0,     # 0 = unlimited
    [int] $MaxItems = 0,     # 0 = unlimited

    [string[]] $ItemProperties = @('entities','results','conversations','items','data'),

    [int] $RetryCount = 2,
    [int] $RetryDelaySeconds = 2
  )

  if (-not $BaseUri) {
    $BaseUri = "https://api.$($InstanceName)/"
  }

  $resolvedPath = Resolve-GcEndpoint -Path $Path -PathParams $PathParams

  $q = @{}
  if ($Query) { foreach ($k in $Query.Keys) { $q[$k] = $Query[$k] } }

  # Respect caller if they explicitly set pageSize, otherwise default it.
  if (-not $q.ContainsKey('pageSize') -and $PageSize -gt 0) {
    $q['pageSize'] = $PageSize
  }
  if (-not $q.ContainsKey('pageNumber')) {
    $q['pageNumber'] = 1
  }

  $items = New-Object 'System.Collections.Generic.List[object]'
  $pagesFetched = 0
  $lastResponse = $null

  # Initial request
  $lastResponse = Invoke-GcRequest -Path $resolvedPath -Method $Method -InstanceName $InstanceName -BaseUri $BaseUri `
    -Headers $Headers -AccessToken $AccessToken -Query $q -Body $Body -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds

  $chunk = Get-GcItemsFromResponse -Response $lastResponse -ItemProperties $ItemProperties
  foreach ($x in $chunk) { [void]$items.Add($x) }
  $pagesFetched++

  if (-not $All) {
    if ($items.Count -gt 0) { return $items }
    return $lastResponse
  }

  # Pull pagination signals (mirrors your screenshot logic)
  $nextPage   = $null
  $nextUri    = $null
  $pageCount  = $null
  $pageNumber = $null
  $cursor     = $null
  $nextCursor = $null

  try { $nextPage = $lastResponse.nextPage } catch { Write-Verbose "Ignored error: $_" }
  try { $nextUri = $lastResponse.nextUri } catch { Write-Verbose "Ignored error: $_" }
  try { $pageCount = $lastResponse.pageCount } catch { Write-Verbose "Ignored error: $_" }
  try { $pageNumber = $lastResponse.pageNumber } catch { Write-Verbose "Ignored error: $_" }
  try { $cursor = $lastResponse.cursor } catch { Write-Verbose "Ignored error: $_" }
  try { $nextCursor = $lastResponse.nextCursor } catch { Write-Verbose "Ignored error: $_" }

    if ($MaxPages -gt 0 -and $pagesFetched -ge $MaxPages) { break }
    if ($MaxItems -gt 0 -and $items.Count -ge $MaxItems) { break }

    $nextCallUri = $null

    if ($nextPage) {
      $nextCallUri = Resolve-GcNextLinkToUri -NextValue ([string]$nextPage) -BaseUri $BaseUri -ResolvedPath $resolvedPath
    }
    elseif ($nextUri) {
      $nextCallUri = Resolve-GcNextLinkToUri -NextValue ([string]$nextUri) -BaseUri $BaseUri -ResolvedPath $resolvedPath
    }
    elseif ($nextCursor) {
      # Cursor-style (common pattern): add as query param for next request
      $q['cursor'] = [string]$nextCursor
      $q.Remove('pageNumber') | Out-Null
    }
    elseif ($cursor -and (-not $q.ContainsKey('cursor'))) {
      # Some endpoints return cursor (not nextCursor) and expect you to feed it back
      $q['cursor'] = [string]$cursor
      $q.Remove('pageNumber') | Out-Null
    }
    elseif ($pageCount -and $pageNumber -and ($pageCount -gt 1) -and ($pageNumber -lt $pageCount)) {
      $pageNumber++
      $q['pageNumber'] = $pageNumber
      # fall-through to normal request using updated query
    }
    else {
      break
    }

    # Fetch next page
    if ($nextCallUri) {
      # Reuse the same headers/token/body, just hit the resolved next URI.
      # Build params once outside the retry lambda so the closure captures them cleanly.
      Write-Verbose ("GC {0} {1}" -f $Method, $nextCallUri)
      Write-GcToolkitTrace -Level INFO -Message ("HTTP {0} {1} [next-page]" -f $Method, $nextCallUri)

      $nextPageHeaders = @{}
      if ($Headers) { foreach ($k in $Headers.Keys) { $nextPageHeaders[$k] = $Headers[$k] } }
      if ($AccessToken) { $nextPageHeaders['Authorization'] = "Bearer $($AccessToken)" }
      if (-not $nextPageHeaders.ContainsKey('Content-Type')) { $nextPageHeaders['Content-Type'] = "application/json; charset=utf-8" }

      $nextPageIrmParams = @{
        Uri     = $nextCallUri
        Method  = $Method
        Headers = $nextPageHeaders
      }
      if ($Method -in @('POST','PUT','PATCH') -and $null -ne $Body) {
        $nextPageIrmParams['Body'] = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 25) }
      }

      # Use the shared retry helper: exponential backoff + Retry-After support + trace logging.
      $lastResponse = Invoke-GcWithRetry `
        -RetryCount       $RetryCount `
        -BaseDelaySeconds $RetryDelaySeconds `
        -OperationLabel   ("$Method $nextCallUri [page $($pagesFetched + 1)]") `
        -ScriptBlock      { Invoke-RestMethod @nextPageIrmParams }
    }
    else {
      $lastResponse = Invoke-GcRequest -Path $resolvedPath -Method $Method -InstanceName $InstanceName -BaseUri $BaseUri `
        -Headers $Headers -AccessToken $AccessToken -Query $q -Body $Body -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds
    }

    $chunk = Get-GcItemsFromResponse -Response $lastResponse -ItemProperties $ItemProperties
    foreach ($x in $chunk) { [void]$items.Add($x) }
    $pagesFetched++

    # refresh pagination signals (matches your pattern)
    $nextPage   = $null
    $nextUri    = $null
    $pageCount  = $null
    $pageNumber = $null
    $cursor     = $null
    $nextCursor = $null

    try { $nextPage = $lastResponse.nextPage } catch { Write-Verbose "Ignored error: $_" }
    try { $nextUri = $lastResponse.nextUri } catch { Write-Verbose "Ignored error: $_" }
    try { $pageCount = $lastResponse.pageCount } catch { Write-Verbose "Ignored error: $_" }
    try { $pageNumber = $lastResponse.pageNumber } catch { Write-Verbose "Ignored error: $_" }
    try { $cursor = $lastResponse.cursor } catch { Write-Verbose "Ignored error: $_" }
    try { $nextCursor = $lastResponse.nextCursor } catch { Write-Verbose "Ignored error: $_" }
  }

  if ($items.Count -gt 0) { return $items }
  return $lastResponse
}

function Invoke-AppGcRequest {
  <#
  .SYNOPSIS
    Application-level wrapper for Invoke-GcRequest that automatically injects
    AccessToken and InstanceName from AppState.

  .DESCRIPTION
    This function wraps Invoke-GcRequest and automatically provides:
    - AccessToken from $script:AppState.AccessToken
    - InstanceName derived from $script:AppState.Region
    
    Simplifies API calls in the UI by removing the need to pass these
    parameters explicitly on every request.
    
    NOTE: Requires $script:AppState to be set by the calling application.

  .PARAMETER Path
    API path (e.g., '/api/v2/users/me')

  .PARAMETER Method
    HTTP method (default: GET)

  .PARAMETER Headers
    Additional headers (optional)

  .PARAMETER Query
    Query parameters (optional)

  .PARAMETER PathParams
    Path parameter substitutions (optional)

  .PARAMETER Body
    Request body (optional)

  .PARAMETER RetryCount
    Number of retries on transient failures (default: 2)

  .PARAMETER RetryDelaySeconds
    Delay between retries (default: 2)

  .EXAMPLE
    # Simple GET request using app state for auth
    $user = Invoke-AppGcRequest -Path '/api/v2/users/me'

  .EXAMPLE
    # POST with body
    $result = Invoke-AppGcRequest -Path '/api/v2/conversations/calls' -Method POST -Body $callBody

  .NOTES
    Added for Step 1: Token plumbing + Test Token implementation.
    Automatically injects AccessToken and InstanceName from AppState.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Path,

    [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
    [string] $Method = 'GET',

    [hashtable] $Headers,
    [hashtable] $Query,
    [hashtable] $PathParams,
    [object] $Body,

    [int] $RetryCount = 2,
    [int] $RetryDelaySeconds = 2
  )

  # Validate AppState is available and properly set
  if (-not $script:AppState) {
    throw "AppState not found. Invoke-AppGcRequest requires AppState to be initialized via Set-GcAppState."
  }

  # Validate required AppState properties
  if (-not $script:AppState.Region) {
    throw "AppState.Region is not set. Please configure the region before making API calls."
  }

  if (-not $script:AppState.AccessToken) {
    throw "AppState.AccessToken is not set. Please authenticate first (Login or Test Token)."
  }

  # Derive InstanceName from Region
  # Region format: 'mypurecloud.com', 'mypurecloud.ie', 'usw2.pure.cloud', etc.
  # API endpoint format: 'https://api.{region}/'
  $instanceName = $script:AppState.Region

  # Call the core HTTP function with injected auth
  $requestParams = @{
    Path         = $Path
    Method       = $Method
    InstanceName = $instanceName
    AccessToken  = $script:AppState.AccessToken
    RetryCount   = $RetryCount
    RetryDelaySeconds = $RetryDelaySeconds
  }

  if ($Headers) { $requestParams['Headers'] = $Headers }
  if ($Query) { $requestParams['Query'] = $Query }
  if ($PathParams) { $requestParams['PathParams'] = $PathParams }
  if ($Body) { $requestParams['Body'] = $Body }

  try {
    return Invoke-GcRequest @requestParams
  } catch {
    # Enhanced error messages for common issues
    $errorMessage = $_.Exception.Message
    
    # Check for DNS/connectivity errors (region misconfiguration)
    if ($errorMessage -match 'Unable to connect|could not be resolved|Name or service not known') {
      throw "Failed to connect to region '$instanceName'. Please verify the region is correct. Original error: $errorMessage"
    }
    
    # Check for auth errors
    if ($errorMessage -match '401|Unauthorized') {
      throw "Authentication failed. Token may be invalid or expired. Original error: $errorMessage"
    }
    
    # Check for endpoint not found (may indicate wrong API version or region)
    if ($errorMessage -match '404|Not Found') {
      throw "API endpoint not found. This may indicate an incorrect region or API path. Original error: $errorMessage"
    }
    
    # Re-throw with context
    throw "API request failed: $errorMessage"
  }
}

Export-ModuleMember -Function Invoke-GcRequest, Invoke-GcPagedRequest, Invoke-AppGcRequest, Set-GcAppState, Normalize-GcInstanceName, Normalize-GcAccessToken

### END: Core.HttpRequests.psm1
