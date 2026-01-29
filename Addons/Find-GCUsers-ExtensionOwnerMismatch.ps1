### BEGIN FILE: GenesysCloud-ExtensionAudit.ps1
#requires -Version 5.1
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Find users whose profile extension does not match the owner of the same extension in the Telephony Extensions list,
and optionally fix by updating the extension owner.

Endpoints used:
- GET  /api/v2/users (users list; extension commonly stored in addresses[].extension) :contentReference[oaicite:4]{index=4}
- GET  /api/v2/telephony/providers/edges/extensions (extensions list; number/owner/ownerType) :contentReference[oaicite:5]{index=5}
- GET  /api/v2/telephony/providers/edges/extensions/{extensionId} (get extension by ID) :contentReference[oaicite:6]{index=6}
- PUT  /api/v2/telephony/providers/edges/extensions/{extensionId} (update extension by ID) :contentReference[oaicite:7]{index=7}
#>

function Invoke-GcApi {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidateSet('GET','POST','PUT','PATCH','DELETE')] [string] $Method,
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string] $PathAndQuery,
    [Parameter()] $Body
  )

  $uri = "$($ApiBaseUri)$($PathAndQuery)"
  $headers = @{
    Authorization = "Bearer $($AccessToken)"
    Accept        = "application/json"
  }

  $irmParams = @{
    Method      = $Method
    Uri         = $uri
    Headers     = $headers
    ErrorAction = 'Stop'
  }

  if ($null -ne $Body) {
    $headers['Content-Type'] = 'application/json'
    $irmParams['Body'] = ($Body | ConvertTo-Json -Depth 20)
  }

  Invoke-RestMethod @irmParams
}

function Get-GcUsersAll {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [int] $PageSize = 500,
    [Parameter()] [switch] $IncludeInactive
  )

  $all = New-Object System.Collections.Generic.List[object]
  $states = @('active')
  if ($IncludeInactive) { $states += 'inactive' }

  foreach ($state in $states) {
    $pageNumber = 1
    while ($true) {
      $q = "/api/v2/users?pageSize=$($PageSize)&pageNumber=$($pageNumber)&state=$($state)"
      $resp = Invoke-GcApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery $q

      if ($resp -and $resp.entities) {
        foreach ($u in $resp.entities) { $all.Add($u) }
      }

      if (-not $resp -or $pageNumber -ge [int]$resp.pageCount) { break }
      $pageNumber++
    }
  }

  $all
}

function Get-GcExtensionsAll {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [int] $PageSize = 100
  )

  $all = New-Object System.Collections.Generic.List[object]
  $pageNumber = 1

  while ($true) {
    $q = "/api/v2/telephony/providers/edges/extensions?pageSize=$($PageSize)&pageNumber=$($pageNumber)"
    $resp = Invoke-GcApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery $q

    if ($resp -and $resp.entities) {
      foreach ($e in $resp.entities) { $all.Add($e) }
    }

    if (-not $resp -or $pageNumber -ge [int]$resp.pageCount) { break }
    $pageNumber++
  }

  $all
}

function Get-UserProfileExtension {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $User
  )

  # Prefer PHONE/WORK with a non-empty extension
  $candidates = @()

  if ($User.PSObject.Properties.Name -contains 'addresses' -and $User.addresses) {
    $candidates = @($User.addresses | Where-Object {
      $_ -and $_.mediaType -eq 'PHONE' -and -not [string]::IsNullOrWhiteSpace($_.extension)
    })
  }

  if (-not $candidates -or $candidates.Count -eq 0) { return $null }

  $work = $candidates | Where-Object { $_.type -eq 'WORK' }
  if ($work -and $work.Count -ge 1) { return [string]$work[0].extension }

  $primary = $candidates | Where-Object { $_.type -eq 'PRIMARY' }
  if ($primary -and $primary.Count -ge 1) { return [string]$primary[0].extension }

  return [string]$candidates[0].extension
}

function Find-GcUserExtensionAnomalies {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter()] [switch] $IncludeInactive
  )

  $users = Get-GcUsersAll -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -IncludeInactive:$IncludeInactive
  $exts  = Get-GcExtensionsAll -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken

  # Build maps
  $extsByNumber = @{}
  foreach ($e in $exts) {
    $num = [string]$e.number
    if ([string]::IsNullOrWhiteSpace($num)) { continue }
    if (-not $extsByNumber.ContainsKey($num)) { $extsByNumber[$num] = @() }
    $extsByNumber[$num] += $e
  }

  # Extract user extensions + duplicate detection (users sharing same extension)
  $userRows = @()
  foreach ($u in $users) {
    $profileExt = Get-UserProfileExtension -User $u
    if ([string]::IsNullOrWhiteSpace($profileExt)) { continue }

    $userRows += [pscustomobject]@{
      UserId           = $u.id
      UserName         = $u.name
      UserEmail        = $u.email
      UserState        = $u.state
      ProfileExtension = [string]$profileExt
    }
  }

  $dupUserAssignments = @()
  $groups = $userRows | Group-Object -Property ProfileExtension
  foreach ($g in $groups) {
    if ($g.Count -gt 1) {
      foreach ($item in $g.Group) {
        $dupUserAssignments += [pscustomobject]@{
          ProfileExtension = $g.Name
          UserId           = $item.UserId
          UserName         = $item.UserName
          UserEmail        = $item.UserEmail
          UserState        = $item.UserState
          Note             = "Duplicate: same profile extension assigned to multiple users"
        }
      }
    }
  }

  $dupExtRecords = @()
  foreach ($kvp in $extsByNumber.GetEnumerator()) {
    if ($kvp.Value.Count -gt 1) {
      foreach ($e in $kvp.Value) {
        $dupExtRecords += [pscustomobject]@{
          ExtensionNumber = $kvp.Key
          ExtensionId     = $e.id
          OwnerId         = $e.owner.id
          OwnerType       = $e.ownerType
          Note            = "Duplicate: multiple extension records share the same number"
        }
      }
    }
  }

  $dupSet = @{}
  foreach ($d in $dupUserAssignments) { $dupSet[$d.ProfileExtension] = $true }

  # Mismatches / missing
  $mismatches = @()

  foreach ($row in $userRows) {
    $num = $row.ProfileExtension

    # If user-side duplicates exist, do not auto-evaluate into mismatch list; manual review instead.
    if ($dupSet.ContainsKey($num)) { continue }

    if (-not $extsByNumber.ContainsKey($num)) {
      $mismatches += [pscustomobject]@{
        Issue            = 'NoExtensionRecord'
        ProfileExtension = $num
        UserId           = $row.UserId
        UserName         = $row.UserName
        UserEmail        = $row.UserEmail
        UserState        = $row.UserState
        ExtensionId      = $null
        ExtensionOwnerId = $null
        ExtensionOwnerType = $null
      }
      continue
    }

    $matches = @($extsByNumber[$num])
    if ($matches.Count -ne 1) {
      # Multiple extension records for same number => manual review
      continue
    }

    $ext = $matches[0]
    $ownerId = $null
    $ownerType = $null

    if ($ext.PSObject.Properties.Name -contains 'ownerType') { $ownerType = [string]$ext.ownerType }
    if ($ext.PSObject.Properties.Name -contains 'owner' -and $ext.owner) { $ownerId = [string]$ext.owner.id }

    if ($ownerType -ne 'USER') {
      $mismatches += [pscustomobject]@{
        Issue              = 'OwnerTypeNotUser'
        ProfileExtension   = $num
        UserId             = $row.UserId
        UserName           = $row.UserName
        UserEmail          = $row.UserEmail
        UserState          = $row.UserState
        ExtensionId        = $ext.id
        ExtensionOwnerId   = $ownerId
        ExtensionOwnerType = $ownerType
      }
      continue
    }

    if ([string]::IsNullOrWhiteSpace($ownerId) -or $ownerId -ne $row.UserId) {
      $mismatches += [pscustomobject]@{
        Issue              = 'OwnerMismatch'
        ProfileExtension   = $num
        UserId             = $row.UserId
        UserName           = $row.UserName
        UserEmail          = $row.UserEmail
        UserState          = $row.UserState
        ExtensionId        = $ext.id
        ExtensionOwnerId   = $ownerId
        ExtensionOwnerType = $ownerType
      }
    }
  }

  [pscustomobject]@{
    Mismatches             = $mismatches
    DuplicateUserAssignments = $dupUserAssignments
    DuplicateExtensionRecords = $dupExtRecords
    UsersWithExtensions    = $userRows
    Extensions             = $exts
  }
}

function Set-GcExtensionOwnerFromUserProfile {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string] $UserId,
    [Parameter(Mandatory)] [string] $ExtensionNumber
  )

  # Find extension record(s) by number
  $exts = Get-GcExtensionsAll -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken
  $matches = @($exts | Where-Object { [string]$_.number -eq [string]$ExtensionNumber })

  if ($matches.Count -eq 0) {
    throw "No extension record found for number '$($ExtensionNumber)'."
  }
  if ($matches.Count -gt 1) {
    throw "Multiple extension records found for number '$($ExtensionNumber)'. Manual review required."
  }

  $extId = [string]$matches[0].id

  # Pull the full extension object (safer for PUT)
  $getPath = "/api/v2/telephony/providers/edges/extensions/$($extId)"
  $extObj = Invoke-GcApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery $getPath

  # Update owner/ownerType (fields documented on Extension resource) :contentReference[oaicite:8]{index=8}
  $extObj.ownerType = 'USER'
  $extObj.owner     = @{ id = $UserId }

  $putPath = "/api/v2/telephony/providers/edges/extensions/$($extId)"

  if ($PSCmdlet.ShouldProcess("Extension $($ExtensionNumber) [$($extId)]", "Set owner to user $($UserId)")) {
    Invoke-GcApi -Method PUT -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery $putPath -Body $extObj | Out-Null
  }

  [pscustomobject]@{
    ExtensionNumber = $ExtensionNumber
    ExtensionId     = $extId
    NewOwnerUserId  = $UserId
    Status          = 'Updated'
  }
}

<#
USAGE EXAMPLE:

$ApiBaseUri  = 'https://api.usw2.pure.cloud'   # adjust for your region
$AccessToken = $script:AccessToken            # or paste a bearer token

$report = Find-GcUserExtensionAnomalies -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -IncludeInactive

# Review:
$report.Mismatches | Format-Table -Auto
$report.DuplicateUserAssignments | Sort-Object ProfileExtension, UserName | Format-Table -Auto
$report.DuplicateExtensionRecords | Sort-Object ExtensionNumber, ExtensionId | Format-Table -Auto

# Fix ONE mismatch (safe):
$m = $report.Mismatches | Where-Object { $_.Issue -eq 'OwnerMismatch' } | Select-Object -First 1
Set-GcExtensionOwnerFromUserProfile -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -UserId $m.UserId -ExtensionNumber $m.ProfileExtension -WhatIf

# Then remove -WhatIf to actually update.
#>
### END FILE: GenesysCloud-ExtensionAudit.ps1
