### BEGIN: Batch Fix + User Version-Bump Helpers
<#
$ApiBaseUri  = 'https://api.usw2.pure.cloud'
$AccessToken = $script:AccessToken  # or however you store it

# Dry run first:
$result = Repair-GcExtensionOwnersFromUserProfiles `
  -ApiBaseUri $ApiBaseUri `
  -AccessToken $AccessToken `
  -IncludeInactive `
  -ExportFolder "G:\Temp\GcExtFix" `
  -WhatIf

$result.Summary
$result.Updated | Select-Object -First 10
$result.ManualReview_UserDuplicates | Sort-Object ProfileExtension, UserName | Select-Object -First 20

#>
function Update-GcUserWithVersionBump {
  <#
  .SYNOPSIS
  Patch a user while bumping version by +1.

  .NOTES
  Genesys Cloud PATCH /api/v2/users/<userId> requires "version" and recommends including all addresses
  to avoid overwriting. :contentReference[oaicite:1]{index=1}
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string] $UserId,
    [Parameter(Mandatory)] [hashtable] $PatchBody
  )

  # Get current user to obtain version + current addresses (avoid accidental overwrite)
  $u = Invoke-GcApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery "/api/v2/users/$($UserId)"
  if ($null -eq $u -or $null -eq $u.id) { throw "Failed to GET user $($UserId)." }

  $currentVersion = [int]$u.version
  $PatchBody['version'] = ($currentVersion + 1)

  # If caller is patching addresses, include all existing addresses unless they already provided them
  if ($PatchBody.ContainsKey('addresses') -and -not $PatchBody['addresses']) {
    $PatchBody['addresses'] = @($u.addresses)
  }

  $path = "/api/v2/users/$($UserId)"
  if ($PSCmdlet.ShouldProcess("User $($UserId)", "PATCH with version $($PatchBody.version)")) {
    return (Invoke-GcApi -Method PATCH -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery $path -Body $PatchBody)
  }
}

function Set-UserProfileExtension {
  <#
  .SYNOPSIS
  (Optional utility) Ensure the user profile extension matches the given extension number.
  Uses PATCH /api/v2/users/<userId> with version+1 and preserves addresses. :contentReference[oaicite:2]{index=2}

  .NOTE
  This is NOT required for the batch owner-fix workflow (since we treat the user profile as source-of-truth),
  but it’s here because you asked to bump version when user objects are updated.
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,
    [Parameter(Mandatory)] [string] $UserId,
    [Parameter(Mandatory)] [string] $ExtensionNumber
  )

  $u = Invoke-GcApi -Method GET -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -PathAndQuery "/api/v2/users/$($UserId)"
  $addresses = @($u.addresses)

  # Try to find WORK PHONE to set extension; fallback to first PHONE address
  $idx = -1
  for ($i = 0; $i -lt $addresses.Count; $i++) {
    if ($addresses[$i].mediaType -eq 'PHONE' -and $addresses[$i].type -eq 'WORK') { $idx = $i; break }
  }
  if ($idx -lt 0) {
    for ($i = 0; $i -lt $addresses.Count; $i++) {
      if ($addresses[$i].mediaType -eq 'PHONE') { $idx = $i; break }
    }
  }
  if ($idx -lt 0) {
    throw "User $($UserId) has no PHONE address entry to set an extension on."
  }

  $addresses[$idx].extension = [string]$ExtensionNumber

  $patch = @{
    addresses = $addresses
  }

  Update-GcUserWithVersionBump -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -UserId $UserId -PatchBody $patch -WhatIf:$WhatIfPreference
}

function Repair-GcExtensionOwnersFromUserProfiles {
  <#
  .SYNOPSIS
  Batch-fix: for each user whose profile extension points to an extension record owned by someone else (or non-USER),
  update the extension record owner to that user.

  Safety:
  - Skips duplicate user assignments (same extension on multiple users)
  - Skips duplicate extension records (same number has multiple records)
  - Skips missing extension records
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string] $ApiBaseUri,
    [Parameter(Mandatory)] [string] $AccessToken,

    [Parameter()] [switch] $IncludeInactive,

    # Only fix these mismatch types
    [Parameter()] [ValidateSet('OwnerMismatch','OwnerTypeNotUser')] [string[]] $FixIssue = @('OwnerMismatch','OwnerTypeNotUser'),

    # Throttle controls
    [Parameter()] [int] $SleepMsBetweenUpdates = 150,
    [Parameter()] [int] $MaxUpdates = 0,

    # Optional exports
    [Parameter()] [string] $ExportFolder
  )

  $report = Find-GcUserExtensionAnomalies -ApiBaseUri $ApiBaseUri -AccessToken $AccessToken -IncludeInactive:$IncludeInactive

  # Build quick lookup sets for manual-review conditions
  $dupUserExtSet = @{}
  foreach ($d in @($report.DuplicateUserAssignments)) { $dupUserExtSet[[string]$d.ProfileExtension] = $true }

  $dupExtNumSet = @{}
  foreach ($d in @($report.DuplicateExtensionRecords)) { $dupExtNumSet[[string]$d.ExtensionNumber] = $true }

  $updated = New-Object System.Collections.Generic.List[object]
  $skipped = New-Object System.Collections.Generic.List[object]
  $failed  = New-Object System.Collections.Generic.List[object]

  $updatesDone = 0

  foreach ($m in @($report.Mismatches)) {
    $extNum = [string]$m.ProfileExtension

    # Skip anything that needs manual review
    if ($dupUserExtSet.ContainsKey($extNum)) {
      $skipped.Add([pscustomobject]@{ Reason='DuplicateUserAssignment'; Issue=$m.Issue; Extension=$extNum; UserId=$m.UserId; UserName=$m.UserName })
      continue
    }
    if ($dupExtNumSet.ContainsKey($extNum)) {
      $skipped.Add([pscustomobject]@{ Reason='DuplicateExtensionRecords'; Issue=$m.Issue; Extension=$extNum; UserId=$m.UserId; UserName=$m.UserName })
      continue
    }

    if ($m.Issue -eq 'NoExtensionRecord') {
      $skipped.Add([pscustomobject]@{ Reason='NoExtensionRecord'; Issue=$m.Issue; Extension=$extNum; UserId=$m.UserId; UserName=$m.UserName })
      continue
    }

    if ($FixIssue -notcontains $m.Issue) {
      $skipped.Add([pscustomobject]@{ Reason='NotInFixScope'; Issue=$m.Issue; Extension=$extNum; UserId=$m.UserId; UserName=$m.UserName })
      continue
    }

    if ($MaxUpdates -gt 0 -and $updatesDone -ge $MaxUpdates) {
      $skipped.Add([pscustomobject]@{ Reason='MaxUpdatesReached'; Issue=$m.Issue; Extension=$extNum; UserId=$m.UserId; UserName=$m.UserName })
      continue
    }

    try {
      # This updates the extension record owner to the userId that has the extension on their profile
      $result = Set-GcExtensionOwnerFromUserProfile `
        -ApiBaseUri $ApiBaseUri `
        -AccessToken $AccessToken `
        -UserId $m.UserId `
        -ExtensionNumber $extNum `
        -WhatIf:$WhatIfPreference

      $updated.Add([pscustomobject]@{
        Issue            = $m.Issue
        ExtensionNumber  = $extNum
        UserId           = $m.UserId
        UserName         = $m.UserName
        PreviousOwnerId  = $m.ExtensionOwnerId
        PreviousOwnerType= $m.ExtensionOwnerType
        ExtensionId      = $m.ExtensionId
        Status           = $result.Status
      })

      $updatesDone++
      if ($SleepMsBetweenUpdates -gt 0) { Start-Sleep -Milliseconds $SleepMsBetweenUpdates }
    }
    catch {
      $failed.Add([pscustomobject]@{
        Issue           = $m.Issue
        ExtensionNumber = $extNum
        UserId          = $m.UserId
        UserName        = $m.UserName
        ExtensionId     = $m.ExtensionId
        Error           = $_.Exception.Message
      })
    }
  }

  $out = [pscustomobject]@{
    Summary = [pscustomobject]@{
      UsersWithExtensions        = @($report.UsersWithExtensions).Count
      MismatchesFound            = @($report.Mismatches).Count
      DuplicateUserAssignments   = @($report.DuplicateUserAssignments).Count
      DuplicateExtensionRecords  = @($report.DuplicateExtensionRecords).Count
      UpdatedCount               = $updated.Count
      SkippedCount               = $skipped.Count
      FailedCount                = $failed.Count
      WhatIf                     = [bool]$WhatIfPreference
    }
    Updated  = $updated
    Skipped  = $skipped
    Failed   = $failed
    ManualReview_UserDuplicates = $report.DuplicateUserAssignments
    ManualReview_ExtDuplicates  = $report.DuplicateExtensionRecords
    Report    = $report
  }

  if (-not [string]::IsNullOrWhiteSpace($ExportFolder)) {
    if (-not (Test-Path -LiteralPath $ExportFolder)) {
      New-Item -ItemType Directory -Path $ExportFolder -Force | Out-Null
    }

    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $updated  | Export-Csv -NoTypeInformation -Path (Join-Path $ExportFolder "extension_owner_fix_updated_$($ts).csv")
    $skipped  | Export-Csv -NoTypeInformation -Path (Join-Path $ExportFolder "extension_owner_fix_skipped_$($ts).csv")
    $failed   | Export-Csv -NoTypeInformation -Path (Join-Path $ExportFolder "extension_owner_fix_failed_$($ts).csv")
    @($report.DuplicateUserAssignments) | Export-Csv -NoTypeInformation -Path (Join-Path $ExportFolder "extension_owner_fix_manualreview_userdups_$($ts).csv")
    @($report.DuplicateExtensionRecords) | Export-Csv -NoTypeInformation -Path (Join-Path $ExportFolder "extension_owner_fix_manualreview_extdups_$($ts).csv")
  }

  return $out
}

### END: Batch Fix + User Version-Bump Helpers
