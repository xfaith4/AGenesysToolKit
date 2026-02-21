#!/usr/bin/env pwsh
# Test script to validate Reports & Exports UI implementation

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Reports & Exports UI Validation Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repository root: $repoRoot"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host ""

$testsPassed = 0
$testsFailed = 0

# Test 1: Check if New-ReportsExportsView function exists
Write-Host "Test 1: New-ReportsExportsView function exists" -ForegroundColor Cyan
try {
  $appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool.ps1'
  $content = Get-Content -Path $appFile -Raw
  
  if ($content -match 'function New-ReportsExportsView') {
    Write-Host "  [PASS] Function definition found" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Function definition NOT found" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 2: Check navigation routing
Write-Host "Test 2: Navigation routes to New-ReportsExportsView" -ForegroundColor Cyan
try {
  $appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool.ps1'
  $content = Get-Content -Path $appFile -Raw
  
  # Count occurrences of New-ReportsExportsView
  # Should have: 1 function definition + 3 navigation calls = 4 total
  $matches = [regex]::Matches($content, 'New-ReportsExportsView')
  
  if ($matches.Count -eq 4) {
    Write-Host "  [PASS] Function defined once and called 3 times in navigation" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Expected 4 occurrences, found $($matches.Count)" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 3: Check XAML structure
Write-Host "Test 3: XAML contains required UI elements" -ForegroundColor Cyan
try {
  $appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool.ps1'
  $content = Get-Content -Path $appFile -Raw
  
  $requiredElements = @(
    'x:Name="TxtTemplateSearch"',
    'x:Name="LstTemplates"',
    'x:Name="PnlParameters"',
    'x:Name="BtnRunReport"',
    'x:Name="WebPreview"',
    'x:Name="BtnExportHtml"',
    'x:Name="LstArtifacts"',
    'x:Name="MnuArtifactOpen"'
  )
  
  $missingElements = @()
  foreach ($element in $requiredElements) {
    if ($content -notmatch [regex]::Escape($element)) {
      $missingElements += $element
    }
  }
  
  if ($missingElements.Count -eq 0) {
    Write-Host "  [PASS] All required XAML elements present" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Missing elements: $($missingElements -join ', ')" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 4: Check event handlers
Write-Host "Test 4: Event handlers implemented" -ForegroundColor Cyan
try {
  $appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool.ps1'
  $content = Get-Content -Path $appFile -Raw
  
  $requiredHandlers = @(
    'BtnRunReport.*Add_Click',
    'BtnExportHtml.*Add_Click',
    'BtnSavePreset.*Add_Click',
    'BtnLoadPreset.*Add_Click',
    'MnuArtifactOpen.*Add_Click',
    'MnuArtifactDelete.*Add_Click'
  )
  
  $missingHandlers = @()
  foreach ($handler in $requiredHandlers) {
    if ($content -notmatch $handler) {
      $missingHandlers += $handler
    }
  }
  
  if ($missingHandlers.Count -eq 0) {
    Write-Host "  [PASS] All required event handlers implemented" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Missing handlers: $($missingHandlers -join ', ')" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 5: Check helper functions
Write-Host "Test 5: Helper functions implemented" -ForegroundColor Cyan
try {
  $appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool.ps1'
  $content = Get-Content -Path $appFile -Raw
  
  $requiredFunctions = @(
    'Refresh-TemplateList',
    'Build-ParameterPanel',
    'Get-ParameterValues'
  )
  
  $missingFunctions = @()
  foreach ($func in $requiredFunctions) {
    # Check for both 'function name' and 'function script:name' patterns
    if ($content -notmatch "function\s+(?:script:)?$func") {
      $missingFunctions += $func
    }
  }
  
  if ($missingFunctions.Count -eq 0) {
    Write-Host "  [PASS] All helper functions implemented" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Missing functions: $($missingFunctions -join ', ')" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 6: Check integration with Core modules
Write-Host "Test 6: Integration with Core modules" -ForegroundColor Cyan
try {
  $appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool.ps1'
  $content = Get-Content -Path $appFile -Raw
  
  $requiredCalls = @(
    'Get-GcReportTemplates',
    'Get-GcArtifactIndex',
    'Invoke-GcReportTemplate',
    'Start-AppJob'
  )
  
  $missingCalls = @()
  foreach ($call in $requiredCalls) {
    if ($content -notmatch [regex]::Escape($call)) {
      $missingCalls += $call
    }
  }
  
  if ($missingCalls.Count -eq 0) {
    Write-Host "  [PASS] All Core module integrations present" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Missing calls: $($missingCalls -join ', ')" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor Red
Write-Host ""

if ($testsFailed -gt 0) {
  Write-Host "========================================" -ForegroundColor Red
  Write-Host "    [FAIL] VALIDATION FAILED" -ForegroundColor Red
  Write-Host "========================================" -ForegroundColor Red
  exit 1
} else {
  Write-Host "========================================" -ForegroundColor Green
  Write-Host "    [PASS] ALL TESTS PASSED" -ForegroundColor Green
  Write-Host "========================================" -ForegroundColor Green
  exit 0
}

