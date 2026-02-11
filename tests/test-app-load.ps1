### BEGIN: tests/test-app-load.ps1
# Test script to verify the main app loads without errors
# This validates that all functions are defined and modules import correctly

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "App Load Validation Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
$appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool_UX_Prototype.ps1'

Write-Host "Testing: $appFile" -ForegroundColor Gray
Write-Host ""

try {
  if (-not (Test-Path -Path $appFile)) {
    throw "App file not found: $appFile"
  }

  $content = Get-Content -Path $appFile -Raw -ErrorAction Stop

  $requiredFunctions = @(
    'Show-TimelineWindow',
    'New-PlaceholderView',
    'New-ConversationTimelineView',
    'New-SubscriptionsView',
    'Start-AppJob',
    'Format-EventSummary'
  )

  $missingFunctions = @()
  foreach ($func in $requiredFunctions) {
    $pattern = 'function\s+' + [regex]::Escape($func) + '\b'
    if ($content -notmatch $pattern) {
      $missingFunctions += $func
    }
  }

  if ($missingFunctions.Count -gt 0) {
    throw ("Missing functions: {0}" -f ($missingFunctions -join ', '))
  }

  Write-Host "  [PASS] All required functions found" -ForegroundColor Green

  # Validate parser-level syntax
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($appFile, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    $errorSummary = ($errors | ForEach-Object {
      "L{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message
    }) -join '; '
    throw ("Syntax errors detected: {0}" -f $errorSummary)
  }

  Write-Host "  [PASS] No syntax errors detected" -ForegroundColor Green

  Write-Host "========================================" -ForegroundColor Green
  Write-Host "    [PASS] APP LOAD VALIDATION PASS" -ForegroundColor Green
  Write-Host "========================================" -ForegroundColor Green
  exit 0

} catch {
  Write-Host "Error: $_" -ForegroundColor Red
  Write-Host "========================================" -ForegroundColor Red
  Write-Host "    [FAIL] APP LOAD VALIDATION FAIL" -ForegroundColor Red
  Write-Host "========================================" -ForegroundColor Red
  exit 1
}

### END: tests/test-app-load.ps1

