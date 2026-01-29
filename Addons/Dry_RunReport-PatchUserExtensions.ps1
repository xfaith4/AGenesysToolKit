### BEGIN: Build Dry-Run Before/After Report

function Get-GcUserById {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string] $UserId
  )
  Invoke-GcApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery "/api/v2/users/$($UserId)"
}

function Get-UserPhoneSummary {
  [CmdletBinding()]
  param([Parameter(Mandatory)] $User)

  if (-not $User.addresses) { return $null }

  $phones = @($User.addresses | Where-Object { $_ -and $_.mediaType -eq 'PHONE' })

  # Keep it compact for CSV readability
  ($phones | ForEach-Object {
    $t = if ($_.type) { $_.type } else { '' }
    $addr = if ($_.address) { $_.address } else { '' }
    $ext  = if ($_.extension) { $_.extension } else { '' }
    "$t:$addr (ext:$ext)"
  }) -join " | "
}

function New-GcExtensionOwnerDryRunReport {
  <#
  .SYNOPSIS
  Produces a change-plan report showing what would be patched (extension owners), including before/after.

  .NOTES
  - This does NOT modify anything.
  - It also includes skip rows for manual review conditions (duplicates, missing ext record).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [switch] $IncludeInactive,

    # Which issues you intend to auto-fix
    [Parameter()] [ValidateSet('OwnerMismatch','OwnerTypeNotUser')] [string[]] $FixIssue = @('OwnerMismatch','OwnerTypeNotUser'),

    # Resolve owner/user names (extra API calls). Turn off if you want speed.
    [Parameter()] [switch] $ResolveOwnerNames
  )

  $report = Find-GcUserExtensionAnomalies -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -IncludeInactive:$IncludeInactive

  # Build manual-review lookup sets
  $dupUserExtSet = @{}
  foreach ($d in @($report.DuplicateUserAssignments)) { $dupUserExtSet[[string]$d.ProfileExtension] = $true }

  $dupExtNumSet = @{}
  foreach ($d in @($report.DuplicateExtensionRecords)) { $dupExtNumSet[[string]$d.ExtensionNumber] = $true }

  # Build extension lookup by number
  $extByNum = @{}
  foreach ($e in @($report.Extensions)) {
    $n = [string]$e.number
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    if (-not $extByNum.ContainsKey($n)) { $extByNum[$n] = @() }
    $extByNum[$n] += $e
  }

  # Optional cache for resolving user info
  $userCache = @{}
  function Resolve-UserDisplay([string]$id) {
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    if ($userCache.ContainsKey($id)) { return $userCache[$id] }
    try {
      $u = Get-GcUserById -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -UserId $id
      $val = if ($u) { "$($u.name) <$($u.email)>" } else { $id }
      $userCache[$id] = $val
      return $val
    } catch {
      $userCache[$id] = $id
      return $id
    }
  }

  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($m in @($report.Mismatches)) {
    $extNum = [string]$m.ProfileExtension

    $action = 'Skip'
    $reason = $null

    if ($dupUserExtSet.ContainsKey($extNum)) {
      $reason = 'DuplicateUserAssignment'
    } elseif ($dupExtNumSet.ContainsKey($extNum)) {
      $reason = 'DuplicateExtensionRecords'
    } elseif ($m.Issue -eq 'NoExtensionRecord') {
      $reason = 'NoExtensionRecord'
    } elseif ($FixIssue -notcontains $m.Issue) {
      $reason = 'NotInFixScope'
    } else {
      $action = 'UpdateExtensionOwner'
    }

    # Pull user summary from the already-fetched list (avoid per-user GET where possible)
    $userRow = @($report.UsersWithExtensions | Where-Object { $_.UserId -eq $m.UserId } | Select-Object -First 1)

    # If we want phone summary, we need the actual user object (addresses). That's extra calls.
    $phoneSummary = $null
    if ($ResolveOwnerNames) {
      $uObj = Get-GcUserById -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -UserId $m.UserId
      $phoneSummary = Get-UserPhoneSummary -User $uObj
    }

    $beforeOwnerDisplay = $m.ExtensionOwnerId
    $afterOwnerDisplay  = $m.UserId

    if ($ResolveOwnerNames) {
      $beforeOwnerDisplay = Resolve-UserDisplay $m.ExtensionOwnerId
      $afterOwnerDisplay  = Resolve-UserDisplay $m.UserId
    }

    # Extension record details (if it exists and is unique)
    $extId = $m.ExtensionId
    if (-not $extId -and $extByNum.ContainsKey($extNum) -and @($extByNum[$extNum]).Count -eq 1) {
      $extId = [string]$extByNum[$extNum][0].id
    }

    $rows.Add([pscustomobject]@{
      Action               = $action
      SkipReason           = $reason

      Issue                = $m.Issue

      UserName             = $m.UserName
      UserEmail            = $m.UserEmail
      UserState            = $m.UserState
      UserId               = $m.UserId

      ProfileExtension     = $extNum
      UserPhones           = $phoneSummary  # optional, can be null

      ExtensionId          = $extId

      Before_OwnerType     = $m.ExtensionOwnerType
      Before_OwnerId       = $m.ExtensionOwnerId
      Before_OwnerDisplay  = $beforeOwnerDisplay

      After_OwnerType      = 'USER'
      After_OwnerId        = $m.UserId
      After_OwnerDisplay   = $afterOwnerDisplay
    })
  }

  # Add explicit manual-review sections as rows too (nice for one CSV)
  foreach ($d in @($report.DuplicateUserAssignments)) {
    $rows.Add([pscustomobject]@{
      Action               = 'ManualReview'
      SkipReason           = 'DuplicateUserAssignment'
      Issue                = 'DuplicateUserAssignment'
      UserName             = $d.UserName
      UserEmail            = $d.UserEmail
      UserState            = $d.UserState
      UserId               = $d.UserId
      ProfileExtension     = $d.ProfileExtension
      UserPhones           = $null
      ExtensionId          = $null
      Before_OwnerType     = $null
      Before_OwnerId       = $null
      Before_OwnerDisplay  = $null
      After_OwnerType      = $null
      After_OwnerId        = $null
      After_OwnerDisplay   = $null
    })
  }

  foreach ($d in @($report.DuplicateExtensionRecords)) {
    $rows.Add([pscustomobject]@{
      Action               = 'ManualReview'
      SkipReason           = 'DuplicateExtensionRecords'
      Issue                = 'DuplicateExtensionRecords'
      UserName             = $null
      UserEmail            = $null
      UserState            = $null
      UserId               = $null
      ProfileExtension     = $d.ExtensionNumber
      UserPhones           = $null
      ExtensionId          = $d.ExtensionId
      Before_OwnerType     = $d.OwnerType
      Before_OwnerId       = $d.OwnerId
      Before_OwnerDisplay  = $d.OwnerId
      After_OwnerType      = $null
      After_OwnerId        = $null
      After_OwnerDisplay   = $null
    })
  }

  # Summary object + rows
  [pscustomobject]@{
    Summary = [pscustomobject]@{
      TotalRows = $rows.Count
      WillPatch = (@($rows) | Where-Object { $_.Action -eq 'UpdateExtensionOwner' }).Count
      ManualReview = (@($rows) | Where-Object { $_.Action -eq 'ManualReview' }).Count
      Skipped = (@($rows) | Where-Object { $_.Action -eq 'Skip' }).Count
      ResolveOwnerNames = [bool]$ResolveOwnerNames
    }
    Rows = $rows
  }
}

### END: Build Dry-Run Before/After Report
