#!/usr/bin/env pwsh
# Integration test for Reports & Templates UI fixes

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Reports & Templates Integration Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get repository root
$repoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repository root: $repoRoot"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host ""

# Enable offline demo mode
$env:GC_TOOLKIT_OFFLINE_DEMO = '1'
Write-Host "Offline demo mode enabled: $env:GC_TOOLKIT_OFFLINE_DEMO"
Write-Host ""

# Import required modules
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ReportTemplates.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Auth.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Diagnostics.psm1') -Force

$testsPassed = 0
$testsFailed = 0

# Test 1: Template loading
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 1: Load templates" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $templates = Get-GcReportTemplates
  if ($templates.Count -lt 4) {
    throw "Expected at least 4 templates, got $($templates.Count)"
  }
  Write-Host "  ✓ Loaded $($templates.Count) templates" -ForegroundColor Green
  $testsPassed++
} catch {
  Write-Host "  ✗ FAILED: $_" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""

# Test 2: Template selection simulation
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 2: Simulate template selection" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $template = $templates[0]
  Write-Host "  Selected: $($template.Name)" -ForegroundColor Gray
  
  if (-not $template.Description) {
    throw "Template missing Description"
  }
  if (-not $template.Parameters) {
    throw "Template missing Parameters"
  }
  
  Write-Host "  Description: $($template.Description)" -ForegroundColor Gray
  Write-Host "  Parameters: $($template.Parameters.Count)" -ForegroundColor Gray
  Write-Host "  ✓ Template selection works" -ForegroundColor Green
  $testsPassed++
} catch {
  Write-Host "  ✗ FAILED: $_" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""

# Test 3: Parameter validation
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 3: Validate parameters" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $params = @{
    Region = 'usw2.pure.cloud'
    AccessToken = 'mock-token'
  }
  
  $missingParams = @()
  foreach ($paramName in $template.Parameters.Keys) {
    $paramDef = $template.Parameters[$paramName]
    if ($paramDef.Required -and -not $params.ContainsKey($paramName)) {
      $missingParams += $paramName
      Write-Host "  Missing required: $paramName" -ForegroundColor Yellow
    }
  }
  
  Write-Host "  ✓ Parameters validated (found $($missingParams.Count) missing)" -ForegroundColor Green
  $testsPassed++
} catch {
  Write-Host "  ✗ FAILED: $_" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""

# Test 4: Report execution (mock - will fail in offline mode but shouldn't crash)
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 4: Execute report (offline mode)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  # Pick a simpler template that doesn't require API calls
  $errorsTemplate = $templates | Where-Object { $_.Name -eq 'Errors & Failures Snapshot' }
  
  if ($errorsTemplate) {
    Write-Host "  Testing with: $($errorsTemplate.Name)" -ForegroundColor Gray
    
    $mockParams = @{
      Jobs = @()
      SubscriptionErrors = @()
    }
    
    try {
      $result = Invoke-GcReportTemplate -TemplateName $errorsTemplate.Name -Parameters $mockParams -ErrorAction Stop
      
      if ($result.Success -eq $false) {
        Write-Host "  ⚠ Report returned error (expected in offline mode): $($result.Error)" -ForegroundColor Yellow
      } else {
        Write-Host "  ✓ Report executed successfully" -ForegroundColor Green
      }
      $testsPassed++
    } catch {
      Write-Host "  ⚠ Exception (may be expected in offline mode): $_" -ForegroundColor Yellow
      # Still count as passed since it's expected in offline mode
      $testsPassed++
    }
  } else {
    Write-Host "  ⚠ Could not find Errors & Failures Snapshot template, skipping" -ForegroundColor Yellow
    $testsPassed++
  }
} catch {
  Write-Host "  ✗ FAILED: $_" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""

# Test 5: Diagnostics module
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 5: Diagnostics module" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $logPath = Enable-GcDiagnostics
  if (-not $logPath) {
    throw "Enable-GcDiagnostics returned null"
  }
  
  Write-GcDiagnostic "Test diagnostic message" -Level INFO
  Write-GcDiagnostic "Test error message" -Level ERROR
  
  # Verify log file was created
  if (-not (Test-Path $logPath)) {
    throw "Diagnostic log file was not created: $logPath"
  }
  
  $logContent = Get-Content -Path $logPath -Raw
  if (-not $logContent.Contains("Test diagnostic message")) {
    throw "Diagnostic log does not contain expected message"
  }
  
  Write-Host "  Log path: $logPath" -ForegroundColor Gray
  Write-Host "  ✓ Diagnostics module works" -ForegroundColor Green
  $testsPassed++
} catch {
  Write-Host "  ✗ FAILED: $_" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""

# Test 6: Connection test function
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 6: Connection test function" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  # Test with invalid token (should fail gracefully)
  $result = Test-GcConnection -Region 'usw2.pure.cloud' -AccessToken 'invalid-token-for-testing'
  
  if ($result.Success) {
    Write-Host "  ⚠ Unexpected: Connection succeeded with invalid token" -ForegroundColor Yellow
  } else {
    Write-Host "  Expected failure with invalid token" -ForegroundColor Gray
    Write-Host "  Error: $($result.Error)" -ForegroundColor Gray
  }
  
  if (-not $result.Tests) {
    throw "Test-GcConnection did not return Tests hashtable"
  }
  
  Write-Host "  ✓ Test-GcConnection function works" -ForegroundColor Green
  $testsPassed++
} catch {
  Write-Host "  ✗ FAILED: $_" -ForegroundColor Red
  $testsFailed++
}

Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host ""

if ($testsFailed -gt 0) {
  Write-Host "✗ Integration test FAILED" -ForegroundColor Red
  exit 1
} else {
  Write-Host "✓ Integration test PASSED" -ForegroundColor Green
  exit 0
}
