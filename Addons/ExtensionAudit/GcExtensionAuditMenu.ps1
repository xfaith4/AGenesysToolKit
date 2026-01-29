### BEGIN FILE: GcExtensionAuditMenu.ps1
#requires -Version 5.1
Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

# Adjust these paths as you like
$modulePath = Join-Path $PSScriptRoot 'GcExtensionAudit.psm1'
Import-Module $modulePath -Force

# ---- Config ----
$defaultApiBaseUri = 'https://api.usw2.pure.cloud'
$logPath = Join-Path $PSScriptRoot ("logs\GcExtensionAudit_{0}.log" -f (Get-Date).ToString('yyyyMMdd_HHmmss'))
Set-GcLogPath -Path $logPath

function Read-NonEmpty([string]$Prompt) {
  do {
    $v = Read-Host $Prompt
  } while ([string]::IsNullOrWhiteSpace($v))
  return $v
}

function New-ContextInteractive {
  $apiBaseUri = Read-Host "API Base URI [$defaultApiBaseUri]"
  if ([string]::IsNullOrWhiteSpace($apiBaseUri)) { $apiBaseUri = $defaultApiBaseUri }

  # Token handling: let you paste, or read from env var
  $token = Read-Host "Access Token (paste) OR press Enter to use `$env:GC_ACCESS_TOKEN"
  if ([string]::IsNullOrWhiteSpace($token)) { $token = $env:GC_ACCESS_TOKEN }
  if ([string]::IsNullOrWhiteSpace($token)) { throw "No access token provided. Paste one or set `$env:GC_ACCESS_TOKEN." }

  $includeInactive = Read-Host "Include inactive users? (y/N)"
  $inc = ($includeInactive -match '^(y|yes)$')

  Write-Log -Level INFO -Message "Building context (this is the main cost)" -Data @{ ApiBaseUri = $apiBaseUri; IncludeInactive = $inc }

  New-GcExtensionAuditContext -ApiBaseUri $apiBaseUri -AccessToken $token -IncludeInactive:$inc
}

function Show-Menu {
  Write-Host ""
  Write-Host "Genesys Cloud Extension Audit Menu"
  Write-Host "  1) Provide Dry Run Report"
  Write-Host "  2) Find Duplicate Extension assignments (same extension on multiple users)"
  Write-Host "  3) Find Discrepancies (profile extension exists, but extension list assigned to someone else / non-user)"
  Write-Host "  4) Find Missing Assignments (profile extension NOT present in extension list)  <-- primary target"
  Write-Host "  5) Patch Missing Assignments (reassert extension on user; version+1)"
  Write-Host "  q) Quit"
  Write-Host ""
}

$ctx = $null
$lastReport = $null

while ($true) {
  Show-Menu
  $choice = Read-Host "Select"

  if ($choice -eq 'q') { break }

  if (-not $ctx) {
    $ctx = New-ContextInteractive
    Write-Log -Level INFO -Message "Context ready" -Data @{
      UsersTotal = $ctx.Users.Count
      UsersWithProfileExt = $ctx.UsersWithProfileExtension.Count
      DistinctProfileExt = $ctx.ProfileExtensionNumbers.Count
      ExtensionsLoaded = $ctx.Extensions.Count
      ExtensionMode = $ctx.ExtensionMode
    }
  }

  switch ($choice) {
    '1' {
      $rep = New-ExtensionDryRunReport -Context $ctx
      $lastReport = $rep

      Write-Host ""
      Write-Host "Dry Run Summary:"
      $rep.Summary | Format-List

      $outFolder = Join-Path $PSScriptRoot 'out'
      $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
      Export-ReportCsv -Rows $rep.Rows -Path (Join-Path $outFolder "DryRunReport_$ts.csv")

      Write-Log -Level INFO -Message "Dry run report complete" -Data @{ OutFolder = $outFolder }
    }

    '2' {
      $dups = Find-DuplicateUserExtensionAssignments -Context $ctx
      Write-Host ""
      Write-Host "Duplicate assignments rows: $($dups.Count)"
      $dups | Sort-Object ProfileExtension, UserName | Select-Object -First 30 | Format-Table -AutoSize

      $outFolder = Join-Path $PSScriptRoot 'out'
      $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
      Export-ReportCsv -Rows $dups -Path (Join-Path $outFolder "DuplicateUserAssignments_$ts.csv")
    }

    '3' {
      $disc = Find-ExtensionDiscrepancies -Context $ctx
      Write-Host ""
      Write-Host "Discrepancies rows: $($disc.Count)"
      $disc | Sort-Object ProfileExtension, UserName | Select-Object -First 30 | Format-Table -AutoSize

      $outFolder = Join-Path $PSScriptRoot 'out'
      $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
      Export-ReportCsv -Rows $disc -Path (Join-Path $outFolder "Discrepancies_$ts.csv")
    }

    '4' {
      $missing = Find-MissingExtensionAssignments -Context $ctx
      Write-Host ""
      Write-Host "Missing assignment rows: $($missing.Count)"
      $missing | Sort-Object ProfileExtension, UserName | Select-Object -First 30 | Format-Table -AutoSize

      $outFolder = Join-Path $PSScriptRoot 'out'
      $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
      Export-ReportCsv -Rows $missing -Path (Join-Path $outFolder "MissingAssignments_$ts.csv")
    }

    '5' {
      $whatIf = Read-Host "Run in WhatIf mode first? (Y/n)"
      $doWhatIf = -not ($whatIf -match '^(n|no)$')

      if ($doWhatIf) {
        Write-Log -Level INFO -Message "Starting patch in WhatIf mode" -Data $null
        $result = Patch-MissingExtensionAssignments -Context $ctx -WhatIf
      } else {
        $confirm = Read-Host "Type PATCH to proceed with real changes"
        if ($confirm -ne 'PATCH') {
          Write-Host "Cancelled."
          continue
        }
        Write-Log -Level WARN -Message "Starting REAL patch" -Data $null
        $result = Patch-MissingExtensionAssignments -Context $ctx
      }

      Write-Host ""
      Write-Host "Patch Summary:"
      $result.Summary | Format-List

      $outFolder = Join-Path $PSScriptRoot 'out'
      $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
      Export-ReportCsv -Rows $result.Updated -Path (Join-Path $outFolder "PatchUpdated_$ts.csv")
      Export-ReportCsv -Rows $result.Skipped -Path (Join-Path $outFolder "PatchSkipped_$ts.csv")
      Export-ReportCsv -Rows $result.Failed  -Path (Join-Path $outFolder "PatchFailed_$ts.csv")

      Write-Host ""
      Write-Host "Suggested next step: re-run option 4 to confirm missing assignments decreased."
    }

    default {
      Write-Host "Unknown option."
    }
  }

  $stats = Get-GcApiStats
  Write-Log -Level INFO -Message "API stats snapshot" -Data @{
    TotalCalls = $stats.TotalCalls
    ByMethod   = $stats.ByMethod
  }
}

Write-Log -Level INFO -Message "Exiting menu" -Data @{ LogPath = $logPath }
Write-Host "Log written to: $logPath"
### END FILE: GcExtensionAuditMenu.ps1
<#
Removal: DID and extension PUT endpoints
https://community.genesys.com/discussion/removal-did-and-extension-put-endpoints
#>
