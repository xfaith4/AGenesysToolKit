# ExtensionAudit.psm1
# ─────────────────────────────────────────────────────────────────────────────
# Genesys Cloud extension and user misconfiguration auditing.
#
# Ported from the standalone GenesysAudits project and adapted for integration
# with the AGenesysToolKit unified shell.
#
# Key functions:
#   New-GcExtensionAuditContext   — loads all users + extensions (paged API)
#   Find-*                        — 7 targeted finding functions
#   New-ExtensionDryRunReport     — composite report without live mutations
#   Patch-MissingExtensionAssignments — live user PATCH (SupportsShouldProcess)
#   Export-GcAuditWorkbook        — XLSX export (requires ImportExcel module)
#   Export-ReportCsv              — CSV export (no external dependencies)
# ─────────────────────────────────────────────────────────────────────────────
#requires -Version 5.1
Set-StrictMode -Version Latest

#region Logging + Stats

$script:LogPath    = $null
$script:LogToHost  = $false   # Suppressed in toolkit integration; route via Write-GcAppLog instead.
$script:GcSensitiveLogKeyPattern = '(?i)^(authorization|access[_-]?token|refresh[_-]?token|token|password|client[_-]?secret)$'
$script:GcApiStats = [ordered]@{
  TotalCalls = 0
  ByMethod   = @{}
  ByPath     = @{}
  LastError  = $null
  RateLimit  = $null
}

function New-GcExtensionAuditLogPath {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter()] [ValidateNotNullOrEmpty()] [string] $Prefix = 'GcExtensionAudit'
  )

  $base = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:USERPROFILE }
  if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
  if ([string]::IsNullOrWhiteSpace($base)) { $base = $PSScriptRoot }

  $logDir = Join-Path $base 'AGenesysToolKit\Logs\ExtensionAudit'
  if (-not (Test-Path -LiteralPath $logDir)) {
    if ($PSCmdlet.ShouldProcess($logDir, 'Create log directory')) {
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
  }

  $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
  return (Join-Path $logDir ("{0}_{1}.log" -f $Prefix, $ts))
}

function Set-GcLogPath {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter()] [switch] $Append
  )
  try {
    if (-not $PSCmdlet.ShouldProcess($Path, "Initialize logging")) {
      $script:LogPath = $null
      return
    }

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }

    if (-not $Append -and (Test-Path -LiteralPath $Path)) {
      Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }

    $script:LogPath = $Path
    Write-GcAuditLog -Level INFO -Message "Logging initialized" -Data ([ordered]@{ LogPath = $Path; Append = [bool]$Append })
  }
  catch {
    $script:LogPath = $null
    throw "Failed to initialize logging at path '$Path': $($_.Exception.Message)"
  }
}

function Protect-GcLogData {
  [CmdletBinding()]
  param(
    [Parameter()] $Data
  )

  function ProtectValue([object]$Value) {
    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
      $out = [ordered]@{}
      foreach ($k in @($Value.Keys)) {
        $key = [string]$k
        if ($key -match $script:GcSensitiveLogKeyPattern) {
          $out[$key] = '***REDACTED***'
        }
        else {
          $out[$key] = ProtectValue $Value[$k]
        }
      }
      return $out
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
      $list = New-Object System.Collections.Generic.List[object]
      foreach ($item in $Value) { $list.Add((ProtectValue $item)) }
      return @($list)
    }

    if ($Value -is [psobject] -and -not ($Value -is [string])) {
      $props = $Value.PSObject.Properties
      if ($props -and $props.Count -gt 0) {
        $out = [ordered]@{}
        foreach ($p in $props) {
          $name = [string]$p.Name
          if ($name -match $script:GcSensitiveLogKeyPattern) {
            $out[$name] = '***REDACTED***'
          }
          else {
            $out[$name] = ProtectValue $p.Value
          }
        }
        return $out
      }
    }

    return $Value
  }

  return (ProtectValue $Data)
}

function Write-GcAuditLog {
  # Renamed from Write-Log to avoid collision with other modules in shared runspace.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')] [string] $Level,
    [Parameter(Mandatory)] [string] $Message,
    [Parameter()] $Data
  )

  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
  $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message

  if ($null -ne $Data) {
    try {
      $safeData = Protect-GcLogData -Data $Data
      $json = ($safeData | ConvertTo-Json -Depth 20 -Compress)
      $line = "$line | $json"
    }
    catch {
      $line = "$line | (Data serialization failed: $($_.Exception.Message))"
    }
  }

  if ($script:LogToHost) {
    switch ($Level) {
      'ERROR' { Write-Host $line -ForegroundColor Red }
      'WARN'  { Write-Host $line -ForegroundColor Yellow }
      'INFO'  { Write-Host $line -ForegroundColor Gray }
      'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
    try {
      Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8 -ErrorAction Stop
    }
    catch {
      # Avoid recursive logging failures; fall back to host only.
      $script:LogPath = $null
      Write-Verbose "[ExtensionAudit] File logging disabled: $($_.Exception.Message)"
    }
  }
}

function Get-GcApiStats {
  [CmdletBinding()]
  param()
  [pscustomobject]@{
    TotalCalls = $script:GcApiStats.TotalCalls
    ByMethod   = $script:GcApiStats.ByMethod
    ByPath     = $script:GcApiStats.ByPath
    LastError  = $script:GcApiStats.LastError
    RateLimit  = $script:GcApiStats.RateLimit
  }
}

#endregion Logging + Stats

#region Core API

function Get-GcHeaderValue {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Headers,
    [Parameter(Mandatory)] [string] $Name
  )

  try {
    $keys = $null
    if ($Headers -is [System.Net.WebHeaderCollection]) {
      $keys = @($Headers.AllKeys)
    }
    else {
      $keys = @($Headers.Keys)
    }

    foreach ($k in $keys) {
      if ([string]$k -ieq $Name) {
        $v = $Headers[$k]
        if ($v -is [string[]]) { return ($v -join ',') }
        return [string]$v
      }
    }
  }
  catch {
    return $null
  }

  return $null
}

function Get-GcRateLimitSnapshot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Headers
  )

  $limitRaw = Get-GcHeaderValue -Headers $Headers -Name 'X-RateLimit-Limit'
  $remRaw   = Get-GcHeaderValue -Headers $Headers -Name 'X-RateLimit-Remaining'
  $resetRaw = Get-GcHeaderValue -Headers $Headers -Name 'X-RateLimit-Reset'

  if ([string]::IsNullOrWhiteSpace($limitRaw) -and [string]::IsNullOrWhiteSpace($remRaw) -and [string]::IsNullOrWhiteSpace($resetRaw)) {
    return $null
  }

  $limit     = $null
  $remaining = $null
  $resetUtc  = $null

  try { if (-not [string]::IsNullOrWhiteSpace($limitRaw)) { $limit     = [int]([double]$limitRaw) } } catch { $limit = $null }
  try { if (-not [string]::IsNullOrWhiteSpace($remRaw))   { $remaining = [int]([double]$remRaw)   } } catch { $remaining = $null }

  try {
    if (-not [string]::IsNullOrWhiteSpace($resetRaw)) {
      $resetNum = [double]$resetRaw
      $now = [DateTimeOffset]::UtcNow
      if ($resetNum -gt 1000000000000) {
        $resetUtc = [DateTimeOffset]::FromUnixTimeMilliseconds([int64][Math]::Floor($resetNum)).UtcDateTime
      }
      elseif ($resetNum -gt 1000000000) {
        $resetUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64][Math]::Floor($resetNum)).UtcDateTime
      }
      else {
        $resetUtc = $now.AddSeconds([Math]::Max(0, $resetNum)).UtcDateTime
      }
    }
  }
  catch {
    $resetUtc = $null
  }

  [pscustomobject]@{
    Limit         = $limit
    Remaining     = $remaining
    ResetUtc      = $resetUtc
    CapturedAtUtc = [DateTime]::UtcNow
  }
}

function Invoke-GcAuditRateLimitThrottle {
  [CmdletBinding()]
  param(
    [Parameter()] $Snapshot,
    [Parameter()] [ValidateRange(0, 5000)]   [int] $MinRemaining    = 2,
    [Parameter()] [ValidateRange(0, 600000)] [int] $ResetBufferMs   = 250,
    [Parameter()] [ValidateRange(0, 600000)] [int] $MaxSleepMs      = 60000
  )

  if ($null -eq $Snapshot -or $null -eq $Snapshot.Remaining) { return }
  if ($Snapshot.Remaining -gt $MinRemaining) { return }

  $sleepMs = 500

  if ($Snapshot.ResetUtc) {
    $delta = ($Snapshot.ResetUtc - [DateTime]::UtcNow)
    if ($delta.TotalMilliseconds -gt 0) {
      $sleepMs = [int][Math]::Ceiling($delta.TotalMilliseconds + $ResetBufferMs)
    }
  }

  $sleepMs = [Math]::Min([Math]::Max(0, $sleepMs), $MaxSleepMs)
  if ($sleepMs -le 0) { return }

  Write-GcAuditLog -Level WARN -Message "Rate limit low; throttling" -Data @{
    Remaining = $Snapshot.Remaining
    Limit     = $Snapshot.Limit
    ResetUtc  = $Snapshot.ResetUtc
    SleepMs   = $sleepMs
  }

  Start-Sleep -Milliseconds $sleepMs
}

function ConvertFrom-GcAuditJson {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Json
  )

  if ([string]::IsNullOrWhiteSpace($Json)) { return $null }

  $cmd = Get-Command ConvertFrom-Json -ErrorAction Stop
  if ($cmd.Parameters.ContainsKey('Depth')) {
    return ($Json | ConvertFrom-Json -Depth 20)
  }

  return ($Json | ConvertFrom-Json)
}

function Invoke-GcAuditApi {
  # Self-contained API caller with exponential backoff and rate-limit awareness.
  # Uses its own implementation to avoid depending on toolkit's HttpRequests.psm1,
  # which allows this module to run in isolated runspaces.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')] [string] $Method,
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string] $PathAndQuery,
    [Parameter()] $Body,
    [Parameter()] [ValidateRange(0, 50)]     [int] $MaxRetries             = 5,
    [Parameter()] [ValidateRange(0, 60000)]  [int] $InitialBackoffMs       = 500,
    [Parameter()] [ValidateRange(0, 5000)]   [int] $ThrottleMinRemaining   = 2,
    [Parameter()] [ValidateRange(0, 600000)] [int] $ThrottleResetBufferMs  = 250,
    [Parameter()] [ValidateRange(0, 600000)] [int] $ThrottleMaxSleepMs     = 60000,
    [Parameter()] [ValidateRange(1, 600)]    [int] $TimeoutSec             = 120
  )

  # Ensure TLS 1.2 for Windows PowerShell 5.1.
  try {
    if (([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
  }
  catch { $null = $_ }

  if ($ApiBaseUri.EndsWith('/')) { $ApiBaseUri = $ApiBaseUri.TrimEnd('/') }
  if (-not $PathAndQuery.StartsWith('/')) { $PathAndQuery = "/$PathAndQuery" }

  $uri = "$ApiBaseUri$PathAndQuery"

  $script:GcApiStats.TotalCalls++
  if (-not $script:GcApiStats.ByMethod.ContainsKey($Method)) { $script:GcApiStats.ByMethod[$Method] = 0 }
  $script:GcApiStats.ByMethod[$Method]++

  $pathKey = $PathAndQuery.Split('?')[0]
  if (-not $script:GcApiStats.ByPath.ContainsKey($pathKey)) { $script:GcApiStats.ByPath[$pathKey] = 0 }
  $script:GcApiStats.ByPath[$pathKey]++

  $headers = @{
    'Authorization' = "Bearer $AccessToken"
    'Accept'        = 'application/json'
  }

  $attempt = 0
  $backoff  = [Math]::Max(100, $InitialBackoffMs)

  do {
    $attempt++
    try {
      $iwrSplat = @{
        Method          = $Method
        Uri             = $uri
        Headers         = $headers
        ErrorAction     = 'Stop'
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
      }

      if ($null -ne $Body) {
        $headers['Content-Type'] = 'application/json'
        $iwrSplat['ContentType'] = 'application/json'
        $iwrSplat['Body']        = ($Body | ConvertTo-Json -Depth 20)
      }

      Write-GcAuditLog -Level DEBUG -Message "API $Method $PathAndQuery (attempt $attempt)" -Data $null

      $resp = Invoke-WebRequest @iwrSplat
      if ($resp -and $resp.Headers) {
        $snapshot = Get-GcRateLimitSnapshot -Headers $resp.Headers
        if ($snapshot) {
          $script:GcApiStats.RateLimit = $snapshot
          Invoke-GcAuditRateLimitThrottle -Snapshot $snapshot -MinRemaining $ThrottleMinRemaining -ResetBufferMs $ThrottleResetBufferMs -MaxSleepMs $ThrottleMaxSleepMs
        }
      }

      if ($null -eq $resp -or [string]::IsNullOrWhiteSpace([string]$resp.Content)) { return $null }
      return (ConvertFrom-GcAuditJson -Json $resp.Content)
    }
    catch {
      $ex    = $_.Exception
      $msg   = $ex.Message
      $script:GcApiStats.LastError = $msg

      $statusCode    = $null
      $retryAfterSec = $null
      try {
        if ($ex.Response -and $ex.Response.StatusCode) { $statusCode = [int]$ex.Response.StatusCode }
        if ($ex.Response -and $ex.Response.Headers -and $ex.Response.Headers['Retry-After']) {
          $retryAfterSec = [int]$ex.Response.Headers['Retry-After']
        }
        if ($ex.Response -and $ex.Response.Headers) {
          $snapshot = Get-GcRateLimitSnapshot -Headers $ex.Response.Headers
          if ($snapshot) { $script:GcApiStats.RateLimit = $snapshot }
        }
      }
      catch { $null = $_ }

      $isRetryable = $false
      if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -le 599)) { $isRetryable = $true }

      Write-GcAuditLog -Level WARN -Message "API failure $Method $PathAndQuery" -Data @{
        Attempt   = $attempt
        Status    = $statusCode
        Message   = $msg
        Retryable = $isRetryable
      }

      if (-not $isRetryable -or $attempt -ge $MaxRetries) {
        Write-GcAuditLog -Level ERROR -Message "API giving up $Method $PathAndQuery" -Data @{
          Attempt = $attempt
          Status  = $statusCode
          Message = $msg
        }
        throw
      }

      $sleepMs = $backoff
      if ($retryAfterSec -and $retryAfterSec -gt 0) {
        $sleepMs = [Math]::Max($sleepMs, $retryAfterSec * 1000)
      }
      Start-Sleep -Milliseconds $sleepMs
      $backoff = [Math]::Min(8000, [int]($backoff * 1.8))
    }
  } while ($true)
}

#endregion Core API

#region Data Collection (Users + Extensions)

function Get-GcAuditUsersAll {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [switch] $IncludeInactive,
    [Parameter()] [ValidateRange(1, 500)] [int] $PageSize = 500
  )

  Write-GcAuditLog -Level INFO -Message "Fetching users (paged)" -Data @{ IncludeInactive = [bool]$IncludeInactive; PageSize = $PageSize }

  $page  = 1
  $users = New-Object System.Collections.Generic.List[object]

  do {
    $state = if ($IncludeInactive) { '&state=any' } else { '&state=active' }
    $pq    = "/api/v2/users?pageSize=$PageSize&pageNumber=$page&expand=locations,station,lasttokenissued$state"
    $resp  = Invoke-GcAuditApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery $pq

    foreach ($u in @($resp.entities)) { $users.Add($u) }

    Write-GcAuditLog -Level INFO -Message "Users page fetched" -Data @{
      PageNumber = $page
      PageCount  = $resp.pageCount
      Entities   = @($resp.entities).Count
      TotalSoFar = $users.Count
    }

    $page++
  } while ($page -le [int]$resp.pageCount)

  return @($users)
}

function Get-GcAuditUserProfileExtension {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $User
  )

  if (-not $User.addresses) { return $null }

  $phones = @($User.addresses | Where-Object { $_ -and $_.mediaType -eq 'PHONE' })
  if ($phones.Count -eq 0) { return $null }

  $work = @($phones | Where-Object { $_.type -eq 'WORK' -and $_.extension })
  if ($work.Count -gt 0) { return [string]$work[0].extension }

  $any = @($phones | Where-Object { $_.extension })
  if ($any.Count -gt 0) { return [string]$any[0].extension }

  return $null
}

function Get-GcAuditExtensionsPage {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [ValidateRange(1, 100)] [int] $PageSize   = 100,
    [Parameter()] [int]                         $PageNumber = 1
  )

  $q = "/api/v2/telephony/providers/edges/extensions?pageSize=$PageSize&pageNumber=$PageNumber"
  Invoke-GcAuditApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery $q
}

function Get-GcAuditExtensionsAll {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [ValidateRange(1, 100)] [int] $PageSize = 100
  )

  Write-GcAuditLog -Level INFO -Message "Fetching extensions (full crawl)" -Data @{ PageSize = $PageSize }

  $page = 1
  $exts = New-Object System.Collections.Generic.List[object]

  do {
    $resp = Get-GcAuditExtensionsPage -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PageSize $PageSize -PageNumber $page
    foreach ($e in @($resp.entities)) { $exts.Add($e) }

    Write-GcAuditLog -Level INFO -Message "Extensions page fetched" -Data @{
      PageNumber = $page
      PageCount  = $resp.pageCount
      Entities   = @($resp.entities).Count
      TotalSoFar = $exts.Count
    }

    $page++
  } while ($page -le [int]$resp.pageCount)

  return @($exts)
}

#endregion Data Collection

#region Context Builder

function New-GcExtensionAuditContext {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [switch]          $IncludeInactive,
    [Parameter()] [ValidateRange(1, 500)] [int] $UsersPageSize         = 500,
    [Parameter()] [ValidateRange(1, 100)] [int] $ExtensionsPageSize    = 100,
    [Parameter()] [int]                         $MaxFullExtensionPages = 25
  )

  Write-GcAuditLog -Level INFO -Message "Building audit context" -Data @{
    IncludeInactive       = [bool]$IncludeInactive
    UsersPageSize         = $UsersPageSize
    ExtensionsPageSize    = $ExtensionsPageSize
    MaxFullExtensionPages = $MaxFullExtensionPages
  }

  # Users
  $users = @(Get-GcAuditUsersAll -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -IncludeInactive:$IncludeInactive -PageSize $UsersPageSize)

  $userById        = @{}
  $userDisplayById = @{}
  foreach ($u in $users) {
    if ($null -eq $u -or [string]::IsNullOrWhiteSpace([string]$u.id)) { continue }
    $userById[[string]$u.id] = $u
    $userDisplayById[[string]$u.id] = [pscustomobject]@{
      UserId    = [string]$u.id
      UserName  = [string]$u.name
      UserEmail = [string]$u.email
      UserState = [string]$u.state
    }
  }

  # Profile extensions from user address entries
  $usersWithProfileExt = New-Object System.Collections.Generic.List[object]
  $profileExtSet       = New-Object 'System.Collections.Generic.HashSet[string]'
  $processedCount      = 0

  foreach ($u in $users) {
    $processedCount++

    $ext = Get-GcAuditUserProfileExtension -User $u
    if (-not [string]::IsNullOrWhiteSpace([string]$ext)) {
      $usersWithProfileExt.Add([pscustomobject]@{
          UserId           = [string]$u.id
          UserName         = [string]$u.name
          UserEmail        = [string]$u.email
          UserState        = [string]$u.state
          ProfileExtension = [string]$ext
        }) | Out-Null
      [void]$profileExtSet.Add([string]$ext)
    }

    if (($processedCount % 500) -eq 0) {
      Write-GcAuditLog -Level INFO -Message "Profile extraction progress" -Data @{
        ProcessedUsers            = $processedCount
        TotalUsers                = $users.Count
        UsersWithProfileExtension = $usersWithProfileExt.Count
      }
    }
  }

  Write-GcAuditLog -Level INFO -Message "User profile extensions collected" -Data @{
    UsersTotal                = $users.Count
    UsersWithProfileExtension = $usersWithProfileExt.Count
    DistinctProfileExtensions = $profileExtSet.Count
  }

  # Extensions from telephony API
  Write-GcAuditLog -Level INFO -Message "Loading extensions (paged)" -Data @{
    ExtensionsPageSize    = $ExtensionsPageSize
    MaxFullExtensionPages = $MaxFullExtensionPages
  }

  $extensions  = New-Object System.Collections.Generic.List[object]
  $extByNumber = @{}

  $first     = Get-GcAuditExtensionsPage -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PageSize $ExtensionsPageSize -PageNumber 1
  $pageCount = [int]($first.pageCount)

  $pagesToFetch = $pageCount
  if ($MaxFullExtensionPages -gt 0 -and $pageCount -gt $MaxFullExtensionPages) {
    $pagesToFetch = [int]$MaxFullExtensionPages
  }

  $extMode  = if ($pagesToFetch -ge $pageCount) { 'FULL' } else { 'PARTIAL' }
  $extCache = [pscustomobject]@{
    PageCount    = $pageCount
    PagesFetched = $pagesToFetch
    PagesSkipped = [Math]::Max(0, ($pageCount - $pagesToFetch))
    IsComplete   = ($pagesToFetch -ge $pageCount)
    MaxPagesLimit = $MaxFullExtensionPages
  }

  function _AddExtensionsToIndex {
    param([Parameter(Mandatory)] $Entities)

    foreach ($e in @($Entities)) {
      if ($null -eq $e) { continue }
      $extensions.Add($e) | Out-Null

      $num = [string]$e.number
      if ([string]::IsNullOrWhiteSpace($num)) { continue }

      if (-not $extByNumber.ContainsKey($num)) {
        $extByNumber[$num] = New-Object System.Collections.Generic.List[object]
      }
      $extByNumber[$num].Add($e) | Out-Null
    }
  }

  _AddExtensionsToIndex -Entities $first.entities

  Write-GcAuditLog -Level INFO -Message "Extensions page fetched" -Data @{
    PageNumber = 1
    PageCount  = $pageCount
    Entities   = @($first.entities).Count
    TotalSoFar = $extensions.Count
    Mode       = $extMode
  }

  for ($page = 2; $page -le $pagesToFetch; $page++) {
    $resp = Get-GcAuditExtensionsPage -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PageSize $ExtensionsPageSize -PageNumber $page
    _AddExtensionsToIndex -Entities $resp.entities

    Write-GcAuditLog -Level INFO -Message "Extensions page fetched" -Data @{
      PageNumber = $page
      PageCount  = [int]$resp.pageCount
      Entities   = @($resp.entities).Count
      TotalSoFar = $extensions.Count
      Mode       = $extMode
    }
  }

  # Normalize index values to arrays
  foreach ($k in @($extByNumber.Keys)) {
    $extByNumber[$k] = @($extByNumber[$k])
  }

  if ($extMode -eq 'PARTIAL') {
    Write-GcAuditLog -Level WARN -Message "Extensions crawl limited; results are partial" -Data @{
      PageCount    = $pageCount
      PagesFetched = $pagesToFetch
      MaxLimit     = $MaxFullExtensionPages
    }
  }

  return [pscustomobject]@{
    ApiBaseUri                = $ApiBaseUri
    Users                     = @($users)
    UserById                  = $userById
    UserDisplayById           = $userDisplayById
    UsersWithProfileExtension = @($usersWithProfileExt)
    ProfileExtensionNumbers   = @($profileExtSet.ToArray() | Sort-Object)

    Extensions                = @($extensions)
    ExtensionMode             = $extMode
    ExtensionCache            = $extCache
    ExtensionsByNumber        = $extByNumber
  }
}

#endregion Context Builder

#region Findings

function Find-DuplicateUserExtensionAssignments {
  [CmdletBinding()]
  param([Parameter(Mandatory)] $Context)

  $dups  = New-Object System.Collections.Generic.List[object]
  $byExt = @{}

  foreach ($x in @($Context.UsersWithProfileExtension)) {
    $n = [string]$x.ProfileExtension
    if (-not $byExt.ContainsKey($n)) { $byExt[$n] = New-Object System.Collections.Generic.List[object] }
    $byExt[$n].Add($x) | Out-Null
  }

  foreach ($k in $byExt.Keys) {
    $list = @($byExt[$k])
    if ($list.Count -le 1) { continue }
    foreach ($x in $list) {
      $dups.Add([pscustomobject]@{
          ProfileExtension = [string]$x.ProfileExtension
          UserId           = [string]$x.UserId
          UserName         = [string]$x.UserName
          UserEmail        = [string]$x.UserEmail
          UserState        = [string]$x.UserState
        }) | Out-Null
    }
  }

  Write-GcAuditLog -Level INFO -Message "Duplicate user extension assignments found" -Data @{ Count = $dups.Count }
  return @($dups)
}

function Find-DuplicateExtensionRecords {
  [CmdletBinding()]
  param([Parameter(Mandatory)] $Context)

  $dups = New-Object System.Collections.Generic.List[object]

  foreach ($k in @($Context.ExtensionsByNumber.Keys)) {
    $list = @($Context.ExtensionsByNumber[$k])
    if ($list.Count -le 1) { continue }

    foreach ($e in $list) {
      $dups.Add([pscustomobject]@{
          ExtensionNumber = [string]$e.number
          ExtensionId     = [string]$e.id
          OwnerType       = [string]$e.owner.type
          OwnerId         = [string]$e.owner.id
          ExtensionPoolId = [string]$e.extensionPool.id
        }) | Out-Null
    }
  }

  Write-GcAuditLog -Level INFO -Message "Duplicate extension records found" -Data @{ Count = $dups.Count }
  return @($dups)
}

function Find-ExtensionDiscrepancies {
  [CmdletBinding()]
  param([Parameter(Mandatory)] $Context)

  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($x in @($Context.UsersWithProfileExtension)) {
    $n = [string]$x.ProfileExtension
    if ([string]::IsNullOrWhiteSpace($n)) { continue }

    $hasExtRecord = ($Context.ExtensionsByNumber.ContainsKey($n) -and @($Context.ExtensionsByNumber[$n]).Count -gt 0)
    if (-not $hasExtRecord) { continue }

    foreach ($e in @($Context.ExtensionsByNumber[$n])) {
      $ownerType = [string]$e.owner.type
      $ownerId   = [string]$e.owner.id

      if (-not [string]::IsNullOrWhiteSpace($ownerId) -and $ownerId -ne [string]$x.UserId) {
        $rows.Add([pscustomobject]@{
            Issue              = 'Extension owner does not match user profile extension'
            ProfileExtension   = [string]$x.ProfileExtension
            UserId             = [string]$x.UserId
            UserName           = [string]$x.UserName
            UserEmail          = [string]$x.UserEmail
            ExtensionId        = [string]$e.id
            ExtensionOwnerType = $ownerType
            ExtensionOwnerId   = $ownerId
          }) | Out-Null
      }
    }
  }

  Write-GcAuditLog -Level INFO -Message "Extension discrepancies found" -Data @{ Count = $rows.Count }
  return @($rows)
}

function Find-MissingExtensionAssignments {
  [CmdletBinding()]
  param([Parameter(Mandatory)] $Context)

  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($x in @($Context.UsersWithProfileExtension)) {
    $n = [string]$x.ProfileExtension
    if ([string]::IsNullOrWhiteSpace($n)) { continue }

    $hasExtRecord = ($Context.ExtensionsByNumber.ContainsKey($n) -and @($Context.ExtensionsByNumber[$n]).Count -gt 0)
    if ($hasExtRecord) { continue }

    $rows.Add([pscustomobject]@{
        Issue            = 'User has profile extension but no matching extension record'
        ProfileExtension = [string]$x.ProfileExtension
        UserId           = [string]$x.UserId
        UserName         = [string]$x.UserName
        UserEmail        = [string]$x.UserEmail
        UserState        = [string]$x.UserState
      }) | Out-Null
  }

  Write-GcAuditLog -Level INFO -Message "Missing extension assignments found" -Data @{ Count = $rows.Count }
  return @($rows)
}

#region User Condition Checks (users list; no additional API calls)

function Get-GcAuditPropertyValue {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Object,
    [Parameter(Mandatory)] [string[]] $Names
  )

  if ($null -eq $Object) { return $null }
  $props = $Object.PSObject.Properties
  if (-not $props) { return $null }

  foreach ($name in $Names) {
    foreach ($p in $props) {
      if ($p.Name -ieq $name) { return $p.Value }
    }
  }

  return $null
}

function ConvertTo-GcAuditDateTime {
  [CmdletBinding()]
  param(
    [Parameter()] $Value
  )

  if ($null -eq $Value) { return $null }

  if ($Value -is [DateTime])       { return $Value }
  if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }

  if ($Value -is [System.Text.Json.JsonElement]) {
    switch ($Value.ValueKind) {
      'String' { return (ConvertTo-GcAuditDateTime -Value $Value.GetString()) }
      'Number' { return (ConvertTo-GcAuditDateTime -Value $Value.GetDouble()) }
      default  { return $null }
    }
  }

  if ($Value -is [string]) {
    $dt = $null
    if ([DateTime]::TryParse($Value, [ref]$dt)) { return $dt }

    $num = $null
    if ([double]::TryParse($Value, [ref]$num)) { return (ConvertTo-GcAuditDateTime -Value $num) }
    return $null
  }

  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
    $epoch = [double]$Value
    if ($epoch -gt 1000000000000) {
      return [DateTimeOffset]::FromUnixTimeMilliseconds([int64][Math]::Floor($epoch)).UtcDateTime
    }
    if ($epoch -gt 1000000000) {
      return [DateTimeOffset]::FromUnixTimeSeconds([int64][Math]::Floor($epoch)).UtcDateTime
    }
    return $null
  }

  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($name in @('date','timestamp','time','value','lastTokenIssued','lasttokenissued','issuedAt','issuedOn')) {
      foreach ($k in $Value.Keys) {
        if ([string]$k -ieq $name) { return (ConvertTo-GcAuditDateTime -Value $Value[$k]) }
      }
    }
    return $null
  }

  if ($Value -is [psobject]) {
    $candidate = Get-GcAuditPropertyValue -Object $Value -Names @('date','timestamp','time','value','lastTokenIssued','lasttokenissued','issuedAt','issuedOn')
    if ($null -ne $candidate) { return (ConvertTo-GcAuditDateTime -Value $candidate) }
  }

  return $null
}

function Get-GcAuditUserTokenLastIssuedUtc {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $User
  )

  $raw = Get-GcAuditPropertyValue -Object $User -Names @(
    'tokenlastissued', 'tokenLastIssued', 'lasttokenissued', 'lastTokenIssued',
    'dateLastLogin', 'dateLastLoginUtc', 'lastLogin', 'lastlogin'
  )

  if ($null -eq $raw) { return $null }

  $dt = ConvertTo-GcAuditDateTime -Value $raw
  if ($null -eq $dt) { return $null }

  try { return $dt.ToUniversalTime() } catch { return $dt }
}

function Find-UsersWithStaleTokens {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Context,
    [Parameter()] [ValidateRange(1, 3650)] [int] $OlderThanDays = 90
  )

  $rows = New-Object System.Collections.Generic.List[object]
  $now  = [DateTime]::UtcNow

  foreach ($u in @($Context.Users)) {
    $last = Get-GcAuditUserTokenLastIssuedUtc -User $u
    if ($null -eq $last) { continue }

    $days = [int]([Math]::Floor(($now - $last).TotalDays))
    if ($days -lt $OlderThanDays) { continue }

    $rows.Add([pscustomobject]@{
        Issue                = "Token last issued is older than $OlderThanDays days"
        UserId               = [string]$u.id
        UserName             = [string]$u.name
        UserEmail            = [string]$u.email
        UserState            = [string]$u.state
        TokenLastIssuedUtc   = $last
        DaysSinceTokenIssued = $days
      }) | Out-Null
  }

  Write-GcAuditLog -Level INFO -Message "Users with stale tokens found" -Data @{ Count = $rows.Count; OlderThanDays = $OlderThanDays }
  return @($rows)
}

function Find-UsersMissingDefaultStation {
  [CmdletBinding()]
  param([Parameter(Mandatory)] $Context)

  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($u in @($Context.Users)) {
    $station = $u.station
    if ($null -ne $station -and -not [string]::IsNullOrWhiteSpace([string]$station.id)) { continue }

    $rows.Add([pscustomobject]@{
        Issue       = 'User has no default station'
        UserId      = [string]$u.id
        UserName    = [string]$u.name
        UserEmail   = [string]$u.email
        UserState   = [string]$u.state
        StationId   = $null
        StationName = $null
      }) | Out-Null
  }

  Write-GcAuditLog -Level INFO -Message "Users missing default station found" -Data @{ Count = $rows.Count }
  return @($rows)
}

function Find-UsersMissingLocation {
  [CmdletBinding()]
  param([Parameter(Mandatory)] $Context)

  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($u in @($Context.Users)) {
    $locs = @($u.locations)
    if ($locs.Count -gt 0) { continue }

    $rows.Add([pscustomobject]@{
        Issue         = 'User has no locations assigned'
        UserId        = [string]$u.id
        UserName      = [string]$u.name
        UserEmail     = [string]$u.email
        UserState     = [string]$u.state
        LocationCount = 0
      }) | Out-Null
  }

  Write-GcAuditLog -Level INFO -Message "Users missing location found" -Data @{ Count = $rows.Count }
  return @($rows)
}

#endregion User Condition Checks

#endregion Findings

#region Dry Run Report

function New-ExtensionDryRunReport {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Context,
    [Parameter()] [ValidateRange(1, 3650)] [int] $TokenStaleThresholdDays = 90
  )

  $dupsUsers       = Find-DuplicateUserExtensionAssignments -Context $Context
  $dupsExts        = Find-DuplicateExtensionRecords -Context $Context
  $disc            = Find-ExtensionDiscrepancies -Context $Context
  $missing         = Find-MissingExtensionAssignments -Context $Context
  $staleTokens     = Find-UsersWithStaleTokens -Context $Context -OlderThanDays $TokenStaleThresholdDays
  $missingStations = Find-UsersMissingDefaultStation -Context $Context
  $missingLocations = Find-UsersMissingLocation -Context $Context

  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($m in $missing) {
    $rows.Add([pscustomobject][ordered]@{
        Action                      = 'PatchUserResyncExtension'
        Category                    = 'MissingAssignment'
        UserId                      = $m.UserId
        ProfileExtension            = $m.ProfileExtension
        Before_ExtensionRecordFound = $false
        Before_ExtOwner             = $null
        After_Expected              = "User PATCH reasserts extension $($m.ProfileExtension) (sync attempt)"
        Notes                       = 'Primary target'
      })
  }

  foreach ($d in $disc) {
    $beforeOwner = $d.ExtensionOwnerId
    if (-not [string]::IsNullOrWhiteSpace([string]$d.ExtensionOwnerId) -and $Context.UserDisplayById.ContainsKey([string]$d.ExtensionOwnerId)) {
      $ownerDisplay = $Context.UserDisplayById[[string]$d.ExtensionOwnerId]
      $beforeOwner  = "$($ownerDisplay.UserName) ($($ownerDisplay.UserEmail))"
    }
    $rows.Add([pscustomobject][ordered]@{
        Action                      = 'ReportOnly'
        Category                    = $d.Issue
        UserId                      = $d.UserId
        ProfileExtension            = $d.ProfileExtension
        Before_ExtensionRecordFound = $true
        Before_ExtOwner             = $beforeOwner
        After_Expected              = 'N/A (extensions endpoints not reliably writable; fix via user assignment process)'
        Notes                       = "ExtensionId=$($d.ExtensionId); OwnerType=$($d.ExtensionOwnerType)"
      })
  }

  foreach ($d in $dupsUsers) {
    $rows.Add([pscustomobject][ordered]@{
        Action                      = 'ManualReview'
        Category                    = 'DuplicateUserAssignment'
        UserId                      = $d.UserId
        ProfileExtension            = $d.ProfileExtension
        Before_ExtensionRecordFound = $null
        Before_ExtOwner             = $null
        After_Expected              = 'Manual decision required'
        Notes                       = 'Same extension present on multiple users'
      })
  }

  foreach ($d in $dupsExts) {
    $beforeOwner = $d.OwnerId
    if (-not [string]::IsNullOrWhiteSpace([string]$d.OwnerId) -and $Context.UserDisplayById.ContainsKey([string]$d.OwnerId)) {
      $ownerDisplay = $Context.UserDisplayById[[string]$d.OwnerId]
      $beforeOwner  = "$($ownerDisplay.UserName) ($($ownerDisplay.UserEmail))"
    }
    $rows.Add([pscustomobject][ordered]@{
        Action                      = 'ManualReview'
        Category                    = 'DuplicateExtensionRecords'
        UserId                      = $null
        ProfileExtension            = $d.ExtensionNumber
        Before_ExtensionRecordFound = $true
        Before_ExtOwner             = $beforeOwner
        After_Expected              = 'Manual decision required'
        Notes                       = "Multiple extension records exist for number; ExtensionId=$($d.ExtensionId)"
      })
  }

  Write-GcAuditLog -Level INFO -Message "Dry run report created" -Data @{
    Rows                  = $rows.Count
    Missing               = $missing.Count
    Discrepancies         = $disc.Count
    DuplicateUserRows     = $dupsUsers.Count
    DuplicateExtRows      = $dupsExts.Count
    StaleTokens           = $staleTokens.Count
    MissingDefaultStation = $missingStations.Count
    MissingLocation       = $missingLocations.Count
  }

  $extensionIssuesTotal = $missing.Count + $disc.Count + $dupsUsers.Count + $dupsExts.Count
  $userIssuesTotal      = $staleTokens.Count + $missingStations.Count + $missingLocations.Count
  $totalIssues          = $extensionIssuesTotal + $userIssuesTotal

  [pscustomobject]@{
    Metadata = [pscustomobject][ordered]@{
      GeneratedAt               = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      ApiBaseUri                = $Context.ApiBaseUri
      ExtensionMode             = $Context.ExtensionMode
      UsersTotal                = @($Context.Users).Count
      UsersWithProfileExtension = @($Context.UsersWithProfileExtension).Count
      DistinctProfileExtensions = @($Context.ProfileExtensionNumbers).Count
      ExtensionsLoaded          = @($Context.Extensions).Count
      TokenStaleThresholdDays   = $TokenStaleThresholdDays
    }
    Summary  = [pscustomobject][ordered]@{
      TotalRows                  = $rows.Count
      MissingAssignments         = $missing.Count
      Discrepancies              = $disc.Count
      DuplicateUserRows          = $dupsUsers.Count
      DuplicateExtensionRows     = $dupsExts.Count
      UsersWithStaleTokens       = $staleTokens.Count
      UsersMissingDefaultStation = $missingStations.Count
      UsersMissingLocation       = $missingLocations.Count
      ExtensionIssuesTotal       = $extensionIssuesTotal
      UserIssuesTotal            = $userIssuesTotal
      TotalIssues                = $totalIssues
    }
    Rows                       = @($rows)
    MissingAssignments         = $missing
    Discrepancies              = $disc
    DuplicateUserAssignments   = $dupsUsers
    DuplicateExtensionRecords  = $dupsExts
    UsersWithStaleTokens       = $staleTokens
    UsersMissingDefaultStation = $missingStations
    UsersMissingLocation       = $missingLocations
    UserIssues                 = @($staleTokens + $missingStations + $missingLocations)
  }
}

#endregion Dry Run Report

#region Patch (Missing Assignments)

function Update-GcAuditUserWithVersionBump {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string]    $ApiBaseUri,
    [Parameter(Mandatory)] [string]    $AccessToken,
    [Parameter(Mandatory)] [string]    $UserId,
    [Parameter(Mandatory)] [hashtable] $PatchBody
  )

  $patch = @{}
  foreach ($k in $PatchBody.Keys) { $patch[$k] = $PatchBody[$k] }

  $u = Invoke-GcAuditApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery "/api/v2/users/$($UserId)"
  if ($null -eq $u -or $null -eq $u.id) { throw "Failed to GET user $($UserId)." }

  $patch['version'] = ([int]$u.version + 1)

  if ($patch.ContainsKey('addresses') -and $null -eq $patch['addresses']) {
    $patch['addresses'] = @($u.addresses)
  }

  $path   = "/api/v2/users/$($UserId)"
  $target = "User $($UserId)"
  $action = "PATCH $path (version=$($patch.version))"

  if ($PSCmdlet.ShouldProcess($target, $action)) {
    $resp = Invoke-GcAuditApi -Method PATCH -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery $path -Body $patch
    return [pscustomobject][ordered]@{ Status = 'Patched'; UserId = $UserId; Version = [int]$patch.version; Response = $resp }
  }

  return [pscustomobject][ordered]@{
    Status   = (if ($WhatIfPreference) { 'WhatIf' } else { 'Declined' })
    UserId   = $UserId
    Version  = [int]$patch.version
    Response = $null
  }
}

function Set-GcAuditUserProfileExtension {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string] $UserId,
    [Parameter(Mandatory)] [string] $ExtensionNumber
  )

  $u         = Invoke-GcAuditApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery "/api/v2/users/$($UserId)"
  $addresses = @($u.addresses)

  $idx = -1
  for ($i = 0; $i -lt $addresses.Count; $i++) {
    if ($addresses[$i].mediaType -eq 'PHONE' -and $addresses[$i].type -eq 'WORK') { $idx = $i; break }
  }
  if ($idx -lt 0) {
    for ($i = 0; $i -lt $addresses.Count; $i++) {
      if ($addresses[$i].mediaType -eq 'PHONE') { $idx = $i; break }
    }
  }
  if ($idx -lt 0) { throw "User $($UserId) has no PHONE address entry to set extension." }

  $before = [string]$addresses[$idx].extension
  $addresses[$idx].extension = [string]$ExtensionNumber

  Write-GcAuditLog -Level INFO -Message "Preparing user extension PATCH" -Data @{
    UserId = $UserId
    Before = $before
    After  = $ExtensionNumber
  }

  $patch = @{ addresses = $addresses }
  return (Update-GcAuditUserWithVersionBump -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -UserId $UserId -PatchBody $patch -WhatIf:$WhatIfPreference)
}

function Patch-MissingExtensionAssignments {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] $Context,
    [Parameter()] [int] $SleepMsBetween = 150,
    [Parameter()] [int] $MaxUpdates     = 0
  )

  # Note: direct PUT to extensions is not reliably functional.
  # Patch user record instead to reassert the extension via user addresses.
  $missing  = Find-MissingExtensionAssignments -Context $Context
  $dupsUsers = Find-DuplicateUserExtensionAssignments -Context $Context
  $dupSet   = @{}
  foreach ($d in $dupsUsers) { $dupSet[[string]$d.ProfileExtension] = $true }

  $updated = New-Object System.Collections.Generic.List[object]
  $skipped = New-Object System.Collections.Generic.List[object]
  $failed  = New-Object System.Collections.Generic.List[object]

  $done = 0
  foreach ($m in $missing) {
    if ($dupSet.ContainsKey([string]$m.ProfileExtension)) {
      $skipped.Add([pscustomobject][ordered]@{ Reason = 'DuplicateUserAssignment'; UserId = $m.UserId; Extension = $m.ProfileExtension })
      continue
    }

    if ($MaxUpdates -gt 0 -and $done -ge $MaxUpdates) {
      $skipped.Add([pscustomobject][ordered]@{ Reason = 'MaxUpdatesReached'; UserId = $m.UserId; Extension = $m.ProfileExtension })
      continue
    }

    try {
      Write-GcAuditLog -Level INFO -Message "Patching missing assignment" -Data @{
        UserId    = $m.UserId
        Extension = $m.ProfileExtension
      }

      $result = Set-GcAuditUserProfileExtension `
        -ApiBaseUri     $Context.ApiBaseUri `
        -AccessToken    $Context.AccessToken `
        -UserId         $m.UserId `
        -ExtensionNumber $m.ProfileExtension `
        -WhatIf:$WhatIfPreference

      if ($result.Status -eq 'Declined') {
        $skipped.Add([pscustomobject][ordered]@{ Reason = 'UserDeclined'; UserId = $m.UserId; Extension = $m.ProfileExtension })
        continue
      }

      $updated.Add([pscustomobject][ordered]@{
          UserId         = $m.UserId
          Extension      = $m.ProfileExtension
          Status         = $result.Status
          PatchedVersion = $result.Version
        })

      $done++
      if ($SleepMsBetween -gt 0) { Start-Sleep -Milliseconds $SleepMsBetween }
    }
    catch {
      $failed.Add([pscustomobject][ordered]@{
          UserId    = $m.UserId
          Extension = $m.ProfileExtension
          Error     = $_.Exception.Message
        })
      Write-GcAuditLog -Level ERROR -Message "Patch failed" -Data @{ UserId = $m.UserId; Extension = $m.ProfileExtension; Error = $_.Exception.Message }
    }
  }

  [pscustomobject]@{
    Summary = [pscustomobject][ordered]@{
      MissingFound = $missing.Count
      Updated      = $updated.Count
      Skipped      = $skipped.Count
      Failed       = $failed.Count
      WhatIf       = [bool]$WhatIfPreference
    }
    Updated = @($updated)
    Skipped = @($skipped)
    Failed  = @($failed)
  }
}

#endregion Patch

#region Exports

function Export-GcAuditWorkbook {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Report,
    [Parameter(Mandatory)] [string] $Path,
    [Parameter()] [switch] $SkipEmptySheets
  )

  # ImportExcel is an optional dependency; fail gracefully if not present.
  if (-not (Get-Module -Name ImportExcel -ListAvailable)) {
    throw "ImportExcel module is required for XLSX export. Install it with: Install-Module ImportExcel -Scope CurrentUser"
  }
  Import-Module ImportExcel -ErrorAction Stop

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  if ([string]::IsNullOrWhiteSpace([IO.Path]::GetExtension($Path))) {
    $Path = "$Path.xlsx"
  }

  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Force
  }

  function New-GcEmptyRow {
    param([string[]] $Columns)
    $row = [ordered]@{}
    foreach ($c in $Columns) { $row[$c] = $null }
    return [pscustomobject]$row
  }

  $sheets = @(
    @{ Name = 'Missing Assignments';       Table = 'MissingAssignments';       Rows = @($Report.MissingAssignments);        Columns = @('Issue','ProfileExtension','UserId','UserName','UserEmail','UserState') }
    @{ Name = 'Discrepancies';             Table = 'Discrepancies';             Rows = @($Report.Discrepancies);             Columns = @('Issue','ProfileExtension','UserId','UserName','UserEmail','ExtensionId','ExtensionOwnerType','ExtensionOwnerId') }
    @{ Name = 'Duplicate User Assignments'; Table = 'DuplicateUserAssignments'; Rows = @($Report.DuplicateUserAssignments);  Columns = @('ProfileExtension','UserId','UserName','UserEmail','UserState') }
    @{ Name = 'Duplicate Ext Records';     Table = 'DuplicateExtensionRecords'; Rows = @($Report.DuplicateExtensionRecords); Columns = @('ExtensionNumber','ExtensionId','OwnerType','OwnerId','ExtensionPoolId') }
    @{ Name = 'Stale Tokens';              Table = 'StaleTokens';               Rows = @($Report.UsersWithStaleTokens);      Columns = @('Issue','UserId','UserName','UserEmail','UserState','TokenLastIssuedUtc','DaysSinceTokenIssued') }
    @{ Name = 'No Default Station';        Table = 'NoDefaultStation';          Rows = @($Report.UsersMissingDefaultStation); Columns = @('Issue','UserId','UserName','UserEmail','UserState','StationId','StationName') }
    @{ Name = 'No Location';               Table = 'NoLocation';                Rows = @($Report.UsersMissingLocation);      Columns = @('Issue','UserId','UserName','UserEmail','UserState','LocationCount') }
  )

  foreach ($sheet in $sheets) {
    $rows = @($sheet.Rows)
    if ($rows.Count -eq 0 -and $SkipEmptySheets) { continue }
    if ($rows.Count -eq 0) { $rows = @(New-GcEmptyRow -Columns $sheet.Columns) }

    $rows   = $rows | Select-Object $sheet.Columns
    $append = (Test-Path -LiteralPath $Path)

    Export-Excel -Path $Path `
      -WorksheetName $sheet.Name `
      -TableName     $sheet.Table `
      -InputObject   $rows `
      -AutoSize `
      -BoldTopRow `
      -FreezeTopRow `
      -Append:$append | Out-Null
  }

  Write-GcAuditLog -Level INFO -Message "Workbook exported" -Data @{ Path = $Path }
  return $Path
}

function Export-GcAuditReportCsv {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [object[]] $Rows,
    [Parameter(Mandatory)] [string]   $Path
  )
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  try {
    $Rows | Export-Csv -NoTypeInformation -Path $Path -Encoding utf8 -Force
    Write-GcAuditLog -Level INFO -Message "CSV exported" -Data ([ordered]@{ Path = $Path; Rows = @($Rows).Count })
  }
  catch {
    Write-GcAuditLog -Level ERROR -Message "CSV export failed" -Data ([ordered]@{ Path = $Path; Error = $_.Exception.Message })
    throw
  }
}

#endregion Exports

Export-ModuleMember -Function @(
  'New-GcExtensionAuditLogPath', 'Set-GcLogPath', 'Write-GcAuditLog', 'Get-GcApiStats',
  'Invoke-GcAuditApi',
  'Get-GcAuditUsersAll', 'Get-GcAuditExtensionsAll',
  'New-GcExtensionAuditContext',
  'Find-DuplicateUserExtensionAssignments', 'Find-DuplicateExtensionRecords',
  'Find-ExtensionDiscrepancies', 'Find-MissingExtensionAssignments',
  'Find-UsersWithStaleTokens', 'Find-UsersMissingDefaultStation', 'Find-UsersMissingLocation',
  'New-ExtensionDryRunReport',
  'Patch-MissingExtensionAssignments',
  'Export-GcAuditWorkbook', 'Export-GcAuditReportCsv'
)
