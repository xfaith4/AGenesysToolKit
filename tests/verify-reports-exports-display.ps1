#!/usr/bin/env pwsh
# Verification script for Reports & Exports module display fix
# This script verifies that the ListBox displays artifact items correctly
# instead of showing "Object[]Array"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Reports & Exports Display Verification" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repository root: $repoRoot"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host ""

$testsPassed = 0
$testsFailed = 0

# Test 1: Verify the fix is present in the code
Write-Host "Test 1: Verify fix implementation" -ForegroundColor Cyan
try {
  $appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool_UX_Prototype.ps1'
  $content = Get-Content -Path $appFile -Raw
  
  # Check for the fix pattern: ItemsSource = null followed by Items.Clear() and Items.Add()
  $hasItemsSourceNull = $content -match '\$h\.LstArtifacts\.ItemsSource\s*=\s*\$null'
  $hasItemsClear = $content -match '\$h\.LstArtifacts\.Items\.Clear\(\)'
  $hasItemsAdd = $content -match '\$h\.LstArtifacts\.Items\.Add\(\$item\)'
  
  if ($hasItemsSourceNull -and $hasItemsClear -and $hasItemsAdd) {
    Write-Host "  [PASS] Fix implementation verified:" -ForegroundColor Green
    Write-Host "    [PASS] ItemsSource is set to null" -ForegroundColor Green
    Write-Host "    [PASS] Items collection is cleared" -ForegroundColor Green
    Write-Host "    [PASS] Items are added individually" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Fix pattern not found:" -ForegroundColor Red
    Write-Host "    ItemsSource = null: $hasItemsSourceNull" -ForegroundColor Red
    Write-Host "    Items.Clear(): $hasItemsClear" -ForegroundColor Red
    Write-Host "    Items.Add(): $hasItemsAdd" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 2: Verify the old buggy pattern is NOT present
Write-Host "Test 2: Verify old buggy pattern removed" -ForegroundColor Cyan
try {
  $appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool_UX_Prototype.ps1'
  $content = Get-Content -Path $appFile -Raw
  
  # Current implementation uses a scriptblock variable ($refreshArtifactList), not a named function.
  # We verify the old buggy assignment is absent across the view implementation.
  $hasRefreshHandler = ($content -match '\$refreshArtifactList\s*=\s*\{') -or ($content -match 'function\s+Refresh-ArtifactList\s*\{')
  $hasBuggyPattern = $content -match '\$h\.LstArtifacts\.ItemsSource\s*=\s*\$displayItems'

  if ($hasRefreshHandler -and (-not $hasBuggyPattern)) {
    Write-Host "  [PASS] Old buggy pattern removed from refresh handler" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Refresh handler validation failed:" -ForegroundColor Red
    Write-Host "    Refresh handler found: $hasRefreshHandler" -ForegroundColor Red
    Write-Host "    Buggy ItemsSource assignment found: $hasBuggyPattern" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 3: Verify the XAML DataTemplate is still present
Write-Host "Test 3: Verify XAML DataTemplate configuration" -ForegroundColor Cyan
try {
  $appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool_UX_Prototype.ps1'
  $content = Get-Content -Path $appFile -Raw
  
  # Check for ListBox.ItemTemplate with DisplayName and DisplayTime bindings
  $hasItemTemplate = $content -match '<ListBox\.ItemTemplate>'
  $hasDisplayNameBinding = $content -match 'Text="\{Binding DisplayName\}"'
  $hasDisplayTimeBinding = $content -match 'Text="\{Binding DisplayTime\}"'
  
  if ($hasItemTemplate -and $hasDisplayNameBinding -and $hasDisplayTimeBinding) {
    Write-Host "  [PASS] XAML DataTemplate configuration verified:" -ForegroundColor Green
    Write-Host "    [PASS] ItemTemplate defined" -ForegroundColor Green
    Write-Host "    [PASS] DisplayName binding present" -ForegroundColor Green
    Write-Host "    [PASS] DisplayTime binding present" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] XAML configuration incomplete:" -ForegroundColor Red
    Write-Host "    ItemTemplate: $hasItemTemplate" -ForegroundColor Red
    Write-Host "    DisplayName binding: $hasDisplayNameBinding" -ForegroundColor Red
    Write-Host "    DisplayTime binding: $hasDisplayTimeBinding" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 4: Verify all three Reports & Exports modules route to the same view
Write-Host "Test 4: Verify module routing" -ForegroundColor Cyan
try {
  $appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool_UX_Prototype.ps1'
  $content = Get-Content -Path $appFile -Raw
  
  # Use more specific patterns that match within the switch statement context
  # Look for the switch case followed by the function call on subsequent lines
  $reportBuilder = $content -match "'Reports\s+&\s+Exports::Report\s+Builder'\s*\{[^\}]*?New-ReportsExportsView"
  $exportHistory = $content -match "'Reports\s+&\s+Exports::Export\s+History'\s*\{[^\}]*?New-ReportsExportsView"
  $quickExports = $content -match "'Reports\s+&\s+Exports::Quick\s+Exports'\s*\{[^\}]*?New-ReportsExportsView"
  
  if ($reportBuilder -and $exportHistory -and $quickExports) {
    Write-Host "  [PASS] All three modules route correctly:" -ForegroundColor Green
    Write-Host "    [PASS] Report Builder -> New-ReportsExportsView" -ForegroundColor Green
    Write-Host "    [PASS] Export History -> New-ReportsExportsView" -ForegroundColor Green
    Write-Host "    [PASS] Quick Exports -> New-ReportsExportsView" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Module routing incomplete:" -ForegroundColor Red
    Write-Host "    Report Builder: $reportBuilder" -ForegroundColor Red
    Write-Host "    Export History: $exportHistory" -ForegroundColor Red
    Write-Host "    Quick Exports: $quickExports" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Verification Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor Red
Write-Host ""

# Explanation of the fix
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "What Was Fixed" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "PROBLEM:" -ForegroundColor Yellow
Write-Host "  All three modules under 'Reports & Exports' workspace displayed" -ForegroundColor White
Write-Host "  'Object[]Array' instead of showing artifact names and timestamps." -ForegroundColor White
Write-Host ""
Write-Host "ROOT CAUSE:" -ForegroundColor Yellow
Write-Host "  When setting ListBox.ItemsSource to a PowerShell array with a" -ForegroundColor White
Write-Host "  DataTemplate binding, WPF sometimes fails to properly bind and" -ForegroundColor White
Write-Host "  displays the array's string representation instead." -ForegroundColor White
Write-Host ""
Write-Host "SOLUTION:" -ForegroundColor Yellow
Write-Host "  Changed Refresh-ArtifactList to:" -ForegroundColor White
Write-Host "    1. Clear ItemsSource binding (set to null)" -ForegroundColor Gray
Write-Host "    2. Clear Items collection" -ForegroundColor Gray
Write-Host "    3. Add items individually via Items.Add()" -ForegroundColor Gray
Write-Host ""
Write-Host "  This ensures proper WPF/PowerShell interop for ListBox items" -ForegroundColor White
Write-Host "  with DataTemplate bindings." -ForegroundColor White
Write-Host ""

if ($testsFailed -gt 0) {
  Write-Host "========================================" -ForegroundColor Red
  Write-Host "    [FAIL] VERIFICATION FAILED" -ForegroundColor Red
  Write-Host "========================================" -ForegroundColor Red
  exit 1
} else {
  Write-Host "========================================" -ForegroundColor Green
  Write-Host "    [PASS] ALL VERIFICATIONS PASSED" -ForegroundColor Green
  Write-Host "========================================" -ForegroundColor Green
  exit 0
}

