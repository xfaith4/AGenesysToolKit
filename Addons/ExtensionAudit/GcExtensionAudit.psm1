### BEGIN FILE: GcExtensionAudit.psm1
#requires -Version 5.1
Set-StrictMode -Version Latest

#region Logging + Stats

$script:LogPath = $null
$script:LogToHost = $true
$script:GcApiStats = [ordered]@{
  TotalCalls = 0
  ByMethod   = @{}
  ByPath     = @{}
  LastError  = $null
}

function Set-GcLogPath {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter()] [switch] $Append
  )
  $script:LogPath = $Path
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if (-not $Append -and (Test-Path -LiteralPath $Path)) {
    Remove-Item -LiteralPath $Path -Force
  }
  Write-Log -Level INFO -Message "Logging initialized" -Data @{ LogPath = $Path; Append = [bool]$Append }
}

function Write-Log {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidateSet('DEBUG','INFO','WARN','ERROR')] [string] $Level,
    [Parameter(Mandatory)] [string] $Message,
    [Parameter()] $Data
  )

  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
  $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message

  if ($null -ne $Data) {
    try {
      $json = ($Data | ConvertTo-Json -Depth 20 -Compress)
      $line = "$line | $json"
    } catch {
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
    Add-Content -LiteralPath $script:LogPath -Value $line
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
  }
}

#endregion Logging + Stats

#region Core API

function Invoke-GcApi {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidateSet('GET','POST','PUT','PATCH','DELETE')] [string] $Method,
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string] $PathAndQuery,
    [Parameter()] $Body,
    [Parameter()] [int] $MaxRetries = 5,
    [Parameter()] [int] $InitialBackoffMs = 500
  )

  if ($ApiBaseUri.EndsWith('/')) { $ApiBaseUri = $ApiBaseUri.TrimEnd('/') }
  if (-not $PathAndQuery.StartsWith('/')) { $PathAndQuery = "/$PathAndQuery" }

  $uri = "$ApiBaseUri$PathAndQuery"

  # Stats
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
  $backoff = [Math]::Max(100, $InitialBackoffMs)

  do {
    $attempt++
    try {
      $irmSplat = @{
        Method      = $Method
        Uri         = $uri
        Headers     = $headers
        ErrorAction = 'Stop'
      }

      if ($null -ne $Body) {
        $headers['Content-Type'] = 'application/json'
        $irmSplat['Body'] = ($Body | ConvertTo-Json -Depth 20)
      }

      Write-Log -Level DEBUG -Message "API $Method $PathAndQuery (attempt $attempt)" -Data $null
      return Invoke-RestMethod @irmSplat
    }
    catch {
      $ex = $_.Exception
      $msg = $ex.Message
      $script:GcApiStats.LastError = $msg

      # Try to extract status
      $statusCode = $null
      $retryAfterSec = $null
      try {
        if ($ex.Response -and $ex.Response.StatusCode) { $statusCode = [int]$ex.Response.StatusCode }
        if ($ex.Response -and $ex.Response.Headers -and $ex.Response.Headers['Retry-After']) {
          $retryAfterSec = [int]$ex.Response.Headers['Retry-After']
        }
      } catch { }

      $isRetryable = $false
      if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -le 599)) { $isRetryable = $true }

      Write-Log -Level WARN -Message "API failure $Method $PathAndQuery" -Data @{
        Attempt = $attempt
        Status  = $statusCode
        Message = $msg
        Retryable = $isRetryable
      }

      if (-not $isRetryable -or $attempt -ge $MaxRetries) {
        Write-Log -Level ERROR -Message "API giving up $Method $PathAndQuery" -Data @{
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

function Get-GcUsersAll {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [switch] $IncludeInactive,
    [Parameter()] [int] $PageSize = 200
  )

  Write-Log -Level INFO -Message "Fetching users (paged)" -Data @{ IncludeInactive = [bool]$IncludeInactive; PageSize = $PageSize }

  $page = 1
  $users = New-Object System.Collections.Generic.List[object]

  do {
    $state = if ($IncludeInactive) { '' } else { '&state=active' }
    $pq = "/api/v2/users?pageSize=$PageSize&pageNumber=$page$state"
    $resp = Invoke-GcApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery $pq

    foreach ($u in @($resp.entities)) { $users.Add($u) }

    Write-Log -Level INFO -Message "Users page fetched" -Data @{
      PageNumber = $page
      PageCount  = $resp.pageCount
      Entities   = @($resp.entities).Count
      TotalSoFar = $users.Count
    }

    $page++
  } while ($page -le [int]$resp.pageCount)

  return @($users)
}

function Get-UserProfileExtension {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $User
  )

  if (-not $User.addresses) { return $null }

  $phones = @($User.addresses | Where-Object { $_ -and $_.mediaType -eq 'PHONE' })
  if ($phones.Count -eq 0) { return $null }

  # Prefer WORK
  $work = @($phones | Where-Object { $_.type -eq 'WORK' -and $_.extension })
  if ($work.Count -gt 0) { return [string]$work[0].extension }

  $any = @($phones | Where-Object { $_.extension })
  if ($any.Count -gt 0) { return [string]$any[0].extension }

  return $null
}

function Get-GcExtensionsPage {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [int] $PageSize = 100,
    [Parameter()] [int] $PageNumber = 1,
    [Parameter()] [string] $NumberFilter
  )

  $q = "/api/v2/telephony/providers/edges/extensions?pageSize=$PageSize&pageNumber=$PageNumber"
  if (-not [string]::IsNullOrWhiteSpace($NumberFilter)) {
    $q = "/api/v2/telephony/providers/edges/extensions?number=$([uri]::EscapeDataString($NumberFilter))"
  }

  Invoke-GcApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery $q
}

function Get-GcExtensionsAll {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [int] $PageSize = 100
  )

  Write-Log -Level INFO -Message "Fetching extensions (full crawl)" -Data @{ PageSize = $PageSize }

  $page = 1
  $exts = New-Object System.Collections.Generic.List[object]

  do {
    $resp = Get-GcExtensionsPage -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PageSize $PageSize -PageNumber $page
    foreach ($e in @($resp.entities)) { $exts.Add($e) }

    Write-Log -Level INFO -Message "Extensions page fetched" -Data @{
      PageNumber = $page
      PageCount  = $resp.pageCount
      Entities   = @($resp.entities).Count
      TotalSoFar = $exts.Count
    }

    $page++
  } while ($page -le [int]$resp.pageCount)

  return @($exts)
}

function Get-GcExtensionsByNumbers {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string[]] $Numbers,
    [Parameter()] [int] $SleepMs = 75
  )

  $distinct = @($Numbers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  Write-Log -Level INFO -Message "Fetching extensions (targeted by number)" -Data @{ DistinctNumbers = $distinct.Count; SleepMs = $SleepMs }

  $cache = @{}
  $out = New-Object System.Collections.Generic.List[object]
  $i = 0

  foreach ($n in $distinct) {
    $i++
    if ($cache.ContainsKey($n)) { continue }

    try {
      $resp = Get-GcExtensionsPage -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -NumberFilter $n
      $ents = @($resp.entities)
      $cache[$n] = $ents

      foreach ($e in $ents) { $out.Add($e) }

      if (($i % 50) -eq 0) {
        Write-Log -Level INFO -Message "Targeted extension lookups progress" -Data @{
          Completed = $i
          Total     = $distinct.Count
          FoundSoFar = $out.Count
        }
      }
    } catch {
      Write-Log -Level WARN -Message "Extension lookup failed for number $($n)" -Data @{ Error = $_.Exception.Message }
      $cache[$n] = @()
    }

    if ($SleepMs -gt 0) { Start-Sleep -Milliseconds $SleepMs }
  }

  return [pscustomobject]@{
    Extensions = @($out)
    Cache     = $cache
  }
}

#endregion Data Collection

#region Context Builder (min API calls)

function New-GcExtensionAuditContext {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [switch] $IncludeInactive,
    [Parameter()] [int] $UsersPageSize = 200,
    [Parameter()] [int] $ExtensionsPageSize = 100,
    [Parameter()] [int] $MaxFullExtensionPages = 25
  )

  Write-Log -Level INFO -Message "Building audit context" -Data @{
    IncludeInactive = [bool]$IncludeInactive
    UsersPageSize = $UsersPageSize
    ExtensionsPageSize = $ExtensionsPageSize
    MaxFullExtensionPages = $MaxFullExtensionPages
  }

  $users = Get-GcUsersAll -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -IncludeInactive:$IncludeInactive -PageSize $UsersPageSize

  # User lookups
  $userById = @{}
  $userDisplayById = @{}
  $usersWithProfileExt = New-Object System.Collections.Generic.List[object]
  $profileExtNumbers = New-Object System.Collections.Generic.List[string]

  foreach ($u in $users) {
    if (-not $u -or [string]::IsNullOrWhiteSpace($u.id)) { continue }
    $userById[$u.id] = $u

    $disp = if (-not [string]::IsNullOrWhiteSpace($u.email)) { "$($u.name) <$($u.email)>" } else { "$($u.name)" }
    $userDisplayById[$u.id] = $disp

    $ext = Get-UserProfileExtension -User $u
    if (-not [string]::IsNullOrWhiteSpace($ext)) {
      $usersWithProfileExt.Add([pscustomobject]@{
        UserId = $u.id
        UserName = $u.name
        UserEmail = $u.email
        UserState = $u.state
        ProfileExtension = [string]$ext
      })
      $profileExtNumbers.Add([string]$ext)
    }
  }

  Write-Log -Level INFO -Message "User profile extensions collected" -Data @{
    UsersTotal = $users.Count
    UsersWithProfileExtension = $usersWithProfileExt.Count
    DistinctProfileExtensions = (@($profileExtNumbers | Select-Object -Unique)).Count
  }

  # Decide extension fetch strategy with 1 page probe
  $probe = Get-GcExtensionsPage -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PageSize $ExtensionsPageSize -PageNumber 1
  $pageCount = [int]$probe.pageCount

  $extensions = @()
  $extMode = $null
  $extCache = $null

  if ($pageCount -le $MaxFullExtensionPages) {
    $extMode = 'FULL'
    $extensions = Get-GcExtensionsAll -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PageSize $ExtensionsPageSize
  } else {
    $extMode = 'TARGETED'
    $targeted = Get-GcExtensionsByNumbers -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -Numbers @($profileExtNumbers) -SleepMs 75
    $extensions = @($targeted.Extensions)
    $extCache = $targeted.Cache
  }

  Write-Log -Level INFO -Message "Extensions loaded" -Data @{
    Mode = $extMode
    ProbePageCount = $pageCount
    ExtensionsLoaded = $extensions.Count
  }

  # Extension lookups by number
  $extByNumber = @{}
  foreach ($e in $extensions) {
    $n = [string]$e.number
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    if (-not $extByNumber.ContainsKey($n)) { $extByNumber[$n] = @() }
    $extByNumber[$n] += $e
  }

  [pscustomobject]@{
    ApiBaseUri = $ApiBaseUri
    AccessToken = $AccessToken
    IncludeInactive = [bool]$IncludeInactive

    Users = $users
    UserById = $userById
    UserDisplayById = $userDisplayById
    UsersWithProfileExtension = @($usersWithProfileExt)
    ProfileExtensionNumbers = @($profileExtNumbers | Select-Object -Unique)

    Extensions = $extensions
    ExtensionMode = $extMode
    ExtensionCache = $extCache
    ExtensionsByNumber = $extByNumber
  }
}

#endregion Context Builder

#region Findings

function Find-DuplicateUserExtensionAssignments {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Context
  )

  $byExt = @{}
  foreach ($r in $Context.UsersWithProfileExtension) {
    $n = [string]$r.ProfileExtension
    if (-not $byExt.ContainsKey($n)) { $byExt[$n] = @() }
    $byExt[$n] += $r
  }

  $dups = New-Object System.Collections.Generic.List[object]
  foreach ($k in $byExt.Keys) {
    if (@($byExt[$k]).Count -gt 1) {
      foreach ($row in $byExt[$k]) {
        $dups.Add([pscustomobject]@{
          ProfileExtension = $k
          UserId = $row.UserId
          UserName = $row.UserName
          UserEmail = $row.UserEmail
          UserState = $row.UserState
        })
      }
    }
  }

  Write-Log -Level INFO -Message "Duplicate user extension assignments" -Data @{ DuplicateRows = $dups.Count; DuplicateExtensions = (@($dups | Select-Object -ExpandProperty ProfileExtension -Unique)).Count }
  return @($dups)
}

function Find-DuplicateExtensionRecords {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Context
  )

  $dups = New-Object System.Collections.Generic.List[object]
  foreach ($k in $Context.ExtensionsByNumber.Keys) {
    $arr = @($Context.ExtensionsByNumber[$k])
    if ($arr.Count -gt 1) {
      foreach ($e in $arr) {
        $dups.Add([pscustomobject]@{
          ExtensionNumber = $k
          ExtensionId = $e.id
          OwnerType = $e.ownerType
          OwnerId = $e.owner.id
          ExtensionPoolId = $e.extensionPool.id
        })
      }
    }
  }

  Write-Log -Level INFO -Message "Duplicate extension records" -Data @{ DuplicateRows = $dups.Count; DuplicateNumbers = (@($dups | Select-Object -ExpandProperty ExtensionNumber -Unique)).Count }
  return @($dups)
}

function Find-ExtensionDiscrepancies {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Context
  )

  $dupUserExtSet = @{}
  foreach ($d in @(Find-DuplicateUserExtensionAssignments -Context $Context)) { $dupUserExtSet[[string]$d.ProfileExtension] = $true }

  $dupExtNumSet = @{}
  foreach ($d in @(Find-DuplicateExtensionRecords -Context $Context)) { $dupExtNumSet[[string]$d.ExtensionNumber] = $true }

  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($u in $Context.UsersWithProfileExtension) {
    $n = [string]$u.ProfileExtension

    $extList = if ($Context.ExtensionsByNumber.ContainsKey($n)) { @($Context.ExtensionsByNumber[$n]) } else { @() }

    if ($dupUserExtSet.ContainsKey($n)) { continue }
    if ($dupExtNumSet.ContainsKey($n)) { continue }

    if ($extList.Count -eq 0) { continue } # missing is handled elsewhere
    if ($extList.Count -gt 1) { continue } # duplicate ext records handled elsewhere

    $e = $extList[0]
    $ownerType = [string]$e.ownerType
    $ownerId   = [string]$e.owner.id

    if ($ownerType -ne 'USER') {
      $rows.Add([pscustomobject]@{
        Issue = 'OwnerTypeNotUser'
        ProfileExtension = $n
        UserId = $u.UserId
        UserName = $u.UserName
        UserEmail = $u.UserEmail
        ExtensionId = $e.id
        ExtensionOwnerType = $ownerType
        ExtensionOwnerId = $ownerId
      })
      continue
    }

    if ($ownerId -and $ownerId -ne $u.UserId) {
      $rows.Add([pscustomobject]@{
        Issue = 'OwnerMismatch'
        ProfileExtension = $n
        UserId = $u.UserId
        UserName = $u.UserName
        UserEmail = $u.UserEmail
        ExtensionId = $e.id
        ExtensionOwnerType = $ownerType
        ExtensionOwnerId = $ownerId
      })
    }
  }

  Write-Log -Level INFO -Message "Extension discrepancies found" -Data @{ Count = $rows.Count }
  return @($rows)
}

function Find-MissingExtensionAssignments {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Context
  )

  $dupUserExtSet = @{}
  foreach ($d in @(Find-DuplicateUserExtensionAssignments -Context $Context)) { $dupUserExtSet[[string]$d.ProfileExtension] = $true }

  $dupExtNumSet = @{}
  foreach ($d in @(Find-DuplicateExtensionRecords -Context $Context)) { $dupExtNumSet[[string]$d.ExtensionNumber] = $true }

  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($u in $Context.UsersWithProfileExtension) {
    $n = [string]$u.ProfileExtension

    if ($dupUserExtSet.ContainsKey($n)) { continue }
    if ($dupExtNumSet.ContainsKey($n)) { continue }

    $hasAny = ($Context.ExtensionsByNumber.ContainsKey($n) -and @($Context.ExtensionsByNumber[$n]).Count -gt 0)
    if (-not $hasAny) {
      $rows.Add([pscustomobject]@{
        Issue = 'NoExtensionRecord'
        ProfileExtension = $n
        UserId = $u.UserId
        UserName = $u.UserName
        UserEmail = $u.UserEmail
        UserState = $u.UserState
      })
    }
  }

  Write-Log -Level INFO -Message "Missing assignments found (profile ext not in extension list)" -Data @{ Count = $rows.Count }
  return @($rows)
}

#endregion Findings

#region Dry Run Report

function New-ExtensionDryRunReport {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Context
  )

  $dupsUsers = Find-DuplicateUserExtensionAssignments -Context $Context
  $dupsExts  = Find-DuplicateExtensionRecords -Context $Context
  $disc      = Find-ExtensionDiscrepancies -Context $Context
  $missing   = Find-MissingExtensionAssignments -Context $Context

  $dupUserSet = @{}
  foreach ($d in $dupsUsers) { $dupUserSet[[string]$d.ProfileExtension] = $true }

  $dupExtSet = @{}
  foreach ($d in $dupsExts) { $dupExtSet[[string]$d.ExtensionNumber] = $true }

  $rows = New-Object System.Collections.Generic.List[object]

  # Missing (patch target)
  foreach ($m in $missing) {
    $rows.Add([pscustomobject]@{
      Action = 'PatchUserResyncExtension'
      Category = 'MissingAssignment'
      UserId = $m.UserId
      User = $Context.UserDisplayById[$m.UserId]
      ProfileExtension = $m.ProfileExtension
      Before_ExtensionRecordFound = $false
      Before_ExtOwner = $null
      After_Expected = "User PATCH reasserts extension $($m.ProfileExtension) (sync attempt)"
      Notes = 'Primary target'
    })
  }

  # Discrepancies (report-only)
  foreach ($d in $disc) {
    $rows.Add([pscustomobject]@{
      Action = 'ReportOnly'
      Category = $d.Issue
      UserId = $d.UserId
      User = $Context.UserDisplayById[$d.UserId]
      ProfileExtension = $d.ProfileExtension
      Before_ExtensionRecordFound = $true
      Before_ExtOwner = if ($d.ExtensionOwnerId) { $Context.UserDisplayById[$d.ExtensionOwnerId] } else { $d.ExtensionOwnerId }
      After_Expected = 'N/A (extensions endpoints not reliably writable; fix via user assignment process)'
      Notes = "ExtensionId=$($d.ExtensionId); OwnerType=$($d.ExtensionOwnerType)"
    })
  }

  # Duplicates summary rows for manual review
  foreach ($d in $dupsUsers) {
    $rows.Add([pscustomobject]@{
      Action = 'ManualReview'
      Category = 'DuplicateUserAssignment'
      UserId = $d.UserId
      User = $Context.UserDisplayById[$d.UserId]
      ProfileExtension = $d.ProfileExtension
      Before_ExtensionRecordFound = $null
      Before_ExtOwner = $null
      After_Expected = 'Manual decision required'
      Notes = 'Same extension present on multiple users'
    })
  }

  foreach ($d in $dupsExts) {
    $rows.Add([pscustomobject]@{
      Action = 'ManualReview'
      Category = 'DuplicateExtensionRecords'
      UserId = $null
      User = $null
      ProfileExtension = $d.ExtensionNumber
      Before_ExtensionRecordFound = $true
      Before_ExtOwner = if ($d.OwnerId) { $Context.UserDisplayById[$d.OwnerId] } else { $d.OwnerId }
      After_Expected = 'Manual decision required'
      Notes = "Multiple extension records exist for number; ExtensionId=$($d.ExtensionId)"
    })
  }

  Write-Log -Level INFO -Message "Dry run report created" -Data @{
    Rows = $rows.Count
    Missing = $missing.Count
    Discrepancies = $disc.Count
    DuplicateUserRows = $dupsUsers.Count
    DuplicateExtRows = $dupsExts.Count
  }

  [pscustomobject]@{
    Summary = [pscustomobject]@{
      TotalRows = $rows.Count
      MissingAssignments = $missing.Count
      Discrepancies = $disc.Count
      DuplicateUserRows = $dupsUsers.Count
      DuplicateExtensionRows = $dupsExts.Count
    }
    Rows = @($rows)
    MissingAssignments = $missing
    Discrepancies = $disc
    DuplicateUserAssignments = $dupsUsers
    DuplicateExtensionRecords = $dupsExts
  }
}

#endregion Dry Run Report

#region Patch (Missing Assignments): PATCH user with version bump

function Update-GcUserWithVersionBump {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string] $UserId,
    [Parameter(Mandatory)] [hashtable] $PatchBody
  )

  $u = Invoke-GcApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery "/api/v2/users/$($UserId)"
  if ($null -eq $u -or $null -eq $u.id) { throw "Failed to GET user $($UserId)." }

  $PatchBody['version'] = ([int]$u.version + 1)

  # If addresses is being supplied, keep it complete to avoid unintentional overwrites
  if ($PatchBody.ContainsKey('addresses') -and $null -eq $PatchBody['addresses']) {
    $PatchBody['addresses'] = @($u.addresses)
  }

  if ($PSCmdlet.ShouldProcess("User $($UserId)", "PATCH /api/v2/users/$($UserId) with version $($PatchBody.version)")) {
    return Invoke-GcApi -Method PATCH -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery "/api/v2/users/$($UserId)" -Body $PatchBody
  }
}

function Set-UserProfileExtension {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string] $UserId,
    [Parameter(Mandatory)] [string] $ExtensionNumber
  )

  $u = Invoke-GcApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery "/api/v2/users/$($UserId)"
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

  Write-Log -Level INFO -Message "Preparing user extension PATCH" -Data @{
    UserId = $UserId
    Before = $before
    After  = $ExtensionNumber
  }

  $patch = @{ addresses = $addresses }

  Update-GcUserWithVersionBump -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -UserId $UserId -PatchBody $patch -WhatIf:$WhatIfPreference
}

function Patch-MissingExtensionAssignments {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] $Context,
    [Parameter()] [int] $SleepMsBetween = 150,
    [Parameter()] [int] $MaxUpdates = 0
  )

  # Important note: direct PUT to extensions is not reliably functional; patch user to reassert extension.
  # See note about extensions PUT endpoints being nonfunctional/removal in legacy dev forum. :contentReference[oaicite:2]{index=2}
  $missing = Find-MissingExtensionAssignments -Context $Context
  $dupsUsers = Find-DuplicateUserExtensionAssignments -Context $Context
  $dupSet = @{}
  foreach ($d in $dupsUsers) { $dupSet[[string]$d.ProfileExtension] = $true }

  $updated = New-Object System.Collections.Generic.List[object]
  $skipped = New-Object System.Collections.Generic.List[object]
  $failed  = New-Object System.Collections.Generic.List[object]

  $done = 0
  foreach ($m in $missing) {
    if ($dupSet.ContainsKey([string]$m.ProfileExtension)) {
      $skipped.Add([pscustomobject]@{ Reason='DuplicateUserAssignment'; UserId=$m.UserId; User=$Context.UserDisplayById[$m.UserId]; Extension=$m.ProfileExtension })
      continue
    }

    if ($MaxUpdates -gt 0 -and $done -ge $MaxUpdates) {
      $skipped.Add([pscustomobject]@{ Reason='MaxUpdatesReached'; UserId=$m.UserId; User=$Context.UserDisplayById[$m.UserId]; Extension=$m.ProfileExtension })
      continue
    }

    try {
      Write-Log -Level INFO -Message "Patching missing assignment (user resync)" -Data @{
        UserId = $m.UserId
        User   = $Context.UserDisplayById[$m.UserId]
        Extension = $m.ProfileExtension
      }

      Set-UserProfileExtension -ApiBaseUri $Context.ApiBaseUri -AccessToken $Context.AccessToken -UserId $m.UserId -ExtensionNumber $m.ProfileExtension -WhatIf:$WhatIfPreference

      $updated.Add([pscustomobject]@{
        UserId = $m.UserId
        User   = $Context.UserDisplayById[$m.UserId]
        Extension = $m.ProfileExtension
        Status = if ($WhatIfPreference) { 'WhatIf' } else { 'Patched' }
      })

      $done++
      if ($SleepMsBetween -gt 0) { Start-Sleep -Milliseconds $SleepMsBetween }
    } catch {
      $failed.Add([pscustomobject]@{
        UserId = $m.UserId
        User   = $Context.UserDisplayById[$m.UserId]
        Extension = $m.ProfileExtension
        Error  = $_.Exception.Message
      })
      Write-Log -Level ERROR -Message "Patch failed" -Data @{ UserId=$m.UserId; Extension=$m.ProfileExtension; Error=$_.Exception.Message }
    }
  }

  [pscustomobject]@{
    Summary = [pscustomobject]@{
      MissingFound = $missing.Count
      Updated = $updated.Count
      Skipped = $skipped.Count
      Failed  = $failed.Count
      WhatIf  = [bool]$WhatIfPreference
    }
    Updated = @($updated)
    Skipped = @($skipped)
    Failed  = @($failed)
  }
}

#endregion Patch

#region Exports

function Export-ReportCsv {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [object[]] $Rows,
    [Parameter(Mandatory)] [string] $Path
  )
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $Rows | Export-Csv -NoTypeInformation -Path $Path
  Write-Log -Level INFO -Message "CSV exported" -Data @{ Path = $Path; Rows = @($Rows).Count }
}

#endregion Exports

Export-ModuleMember -Function @(
  'Set-GcLogPath','Write-Log','Get-GcApiStats',
  'Invoke-GcApi',
  'Get-GcUsersAll','Get-GcExtensionsAll','Get-GcExtensionsByNumbers',
  'New-GcExtensionAuditContext',
  'Find-DuplicateUserExtensionAssignments','Find-DuplicateExtensionRecords',
  'Find-ExtensionDiscrepancies','Find-MissingExtensionAssignments',
  'New-ExtensionDryRunReport',
  'Patch-MissingExtensionAssignments',
  'Export-ReportCsv'
)
### END FILE: GcExtensionAudit.psm1
