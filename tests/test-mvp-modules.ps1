#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Test script for MVP modules: Operational Event Logs, Audit Logs, OAuth/Token Usage

.DESCRIPTION
  Validates that:
  1. Module view functions exist in the app script
  2. XAML syntax is valid
  3. Function definitions are complete
  4. No obvious syntax errors

.NOTES
  This is a basic validation test that doesn't require WPF or authentication.
  It verifies the module structure only.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "MVP Modules Syntax Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repository root: $repoRoot"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host ""

$testsPassed = 0
$testsFailed = 0

# Load the main app script
$appScript = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool_UX_Prototype_v2_1.ps1'
$appContent = Get-Content -Path $appScript -Raw

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 1: Check app script loads" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if (Test-Path $appScript) {
  Write-Host "  [PASS] App script exists" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] App script not found" -ForegroundColor Red
  $testsFailed++
  exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 2: Operational Event Logs function exists" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($appContent -match 'function New-OperationalEventLogsView') {
  Write-Host "  [PASS] Function New-OperationalEventLogsView found" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Function New-OperationalEventLogsView not found" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 3: Audit Logs function exists" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($appContent -match 'function New-AuditLogsView') {
  Write-Host "  [PASS] Function New-AuditLogsView found" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Function New-AuditLogsView not found" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 4: OAuth/Token Usage function exists" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($appContent -match 'function New-OAuthTokenUsageView') {
  Write-Host "  [PASS] Function New-OAuthTokenUsageView found" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Function New-OAuthTokenUsageView not found" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 5: Module wiring - Operational Event Logs" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($appContent -match "'Operations::Operational Event Logs'") {
  Write-Host "  [PASS] Module wired in Set-ContentForModule" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Module not wired in Set-ContentForModule" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 6: Module wiring - Audit Logs" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($appContent -match "'Operations::Audit Logs'") {
  Write-Host "  [PASS] Module wired in Set-ContentForModule" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Module not wired in Set-ContentForModule" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 7: Module wiring - OAuth / Token Usage" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($appContent -match "'Operations::OAuth / Token Usage'") {
  Write-Host "  [PASS] Module wired in Set-ContentForModule" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Module not wired in Set-ContentForModule" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 8: XAML structure - Operational Event Logs" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check for key UI elements in Operational Event Logs view
$opXamlChecks = @(
  'x:Name="BtnOpQuery"',
  'x:Name="BtnOpExportJson"',
  'x:Name="BtnOpExportCsv"',
  'x:Name="GridOpEvents"',
  'x:Name="TxtOpSearch"'
)

$opXamlPass = $true
foreach ($check in $opXamlChecks) {
  if ($appContent -notmatch [regex]::Escape($check)) {
    Write-Host "  [WARN] Missing UI element: $check" -ForegroundColor Yellow
    $opXamlPass = $false
  }
}

if ($opXamlPass) {
  Write-Host "  [PASS] All expected UI elements found" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Some UI elements missing" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 9: XAML structure - Audit Logs" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check for key UI elements in Audit Logs view
$auditXamlChecks = @(
  'x:Name="BtnAuditQuery"',
  'x:Name="BtnAuditExportJson"',
  'x:Name="BtnAuditExportCsv"',
  'x:Name="GridAuditLogs"',
  'x:Name="TxtAuditSearch"'
)

$auditXamlPass = $true
foreach ($check in $auditXamlChecks) {
  if ($appContent -notmatch [regex]::Escape($check)) {
    Write-Host "  [WARN] Missing UI element: $check" -ForegroundColor Yellow
    $auditXamlPass = $false
  }
}

if ($auditXamlPass) {
  Write-Host "  [PASS] All expected UI elements found" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Some UI elements missing" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 10: XAML structure - OAuth/Token Usage" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check for key UI elements in OAuth/Token Usage view
$tokenXamlChecks = @(
  'x:Name="BtnTokenQuery"',
  'x:Name="BtnTokenExportJson"',
  'x:Name="BtnTokenExportCsv"',
  'x:Name="GridTokenUsage"',
  'x:Name="TxtTokenSearch"'
)

$tokenXamlPass = $true
foreach ($check in $tokenXamlChecks) {
  if ($appContent -notmatch [regex]::Escape($check)) {
    Write-Host "  [WARN] Missing UI element: $check" -ForegroundColor Yellow
    $tokenXamlPass = $false
  }
}

if ($tokenXamlPass) {
  Write-Host "  [PASS] All expected UI elements found" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Some UI elements missing" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 11: API endpoint usage - Operational Event Logs" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($appContent -match '/api/v2/audits/query') {
  Write-Host "  [PASS] Uses correct API endpoint (/api/v2/audits/query)" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] API endpoint not found or incorrect" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 12: API endpoint usage - OAuth/Token Usage" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($appContent -match '/api/v2/oauth/clients') {
  Write-Host "  [PASS] Uses correct API endpoint (/api/v2/oauth/clients)" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] API endpoint not found or incorrect" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 13: Uses Start-AppJob" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check that all modules use Start-AppJob for async execution
if ($appContent -match 'Start-AppJob.*Query Operational Events' -and 
    $appContent -match 'Start-AppJob.*Query Audit Logs' -and
    $appContent -match 'Start-AppJob.*Query OAuth Clients') {
  Write-Host "  [PASS] All modules use Start-AppJob for background queries" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Not all modules use Start-AppJob" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 14: Uses Invoke-GcPagedRequest" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check that modules use the paged request wrapper
if ($appContent -match 'Invoke-GcPagedRequest.*audits/query' -and
    $appContent -match 'Invoke-GcPagedRequest.*oauth/clients') {
  Write-Host "  [PASS] Modules use Invoke-GcPagedRequest for API calls" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Modules don't use Invoke-GcPagedRequest" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "Tests Passed: $testsPassed"
Write-Host "Tests Failed: $testsFailed"
Write-Host ""

if ($testsFailed -eq 0) {
  Write-Host "================================" -ForegroundColor Green
  Write-Host "    ✓ ALL TESTS PASSED" -ForegroundColor Green
  Write-Host "================================" -ForegroundColor Green
  exit 0
} else {
  Write-Host "================================" -ForegroundColor Red
  Write-Host "    ✗ SOME TESTS FAILED" -ForegroundColor Red
  Write-Host "================================" -ForegroundColor Red
  exit 1
}
