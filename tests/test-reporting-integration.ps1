#!/usr/bin/env pwsh
# Integration test for Reporting & Exports system

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Reporting & Exports Integration Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get repository root
$repoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repository root: $repoRoot"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host ""

# Import modules
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Reporting.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ReportTemplates.psm1') -Force

$testsPassed = 0
$testsFailed = 0

# Create temp output directory
$tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-reporting-integration-$(Get-Date -Format 'yyyyMMddHHmmss')")
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Write-Host "Test output directory: $tempDir"
Write-Host ""

# Test 1: Errors & Failures Snapshot (no auth required)
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 1: Errors & Failures Snapshot Report" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  # Create mock data
  $mockJobs = @(
    [PSCustomObject]@{
      Name = 'Failed Export'
      Type = 'Export'
      Status = 'Failed'
      Errors = @('Connection timeout')
      Ended = (Get-Date).AddMinutes(-5)
    }
  )
  
  $mockErrors = @(
    [PSCustomObject]@{
      ts = (Get-Date).AddMinutes(-3)
      severity = 'error'
      topic = 'v2.conversations.error'
      conversationId = 'c-test-123'
      text = 'Test error event'
    }
  )
  
  # Execute template
  Write-Host "  Executing template..."
  $templates = Get-GcReportTemplates
  $template = $templates | Where-Object { $_.Name -eq 'Errors & Failures Snapshot' }
  
  $reportData = & $template.InvokeScript -Jobs $mockJobs -SubscriptionErrors $mockErrors -Since (Get-Date).AddHours(-1)
  
  Write-Host "  Report data:"
  Write-Host "    Rows: $($reportData.Rows.Count)"
  Write-Host "    Status: $($reportData.Summary.Status)"
  Write-Host "    Warnings: $($reportData.Warnings.Count)"
  
  if ($reportData.Rows.Count -eq 2) {
    Write-Host "  [PASS] Correct number of error rows" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Expected 2 error rows, got $($reportData.Rows.Count)" -ForegroundColor Red
    $testsFailed++
  }
  
  # Create artifact bundle
  Write-Host "  Creating artifact bundle..."
  $runId = New-GcReportRunId
  $bundle = New-GcArtifactBundle `
    -ReportName "Errors & Failures Snapshot" `
    -OutputDirectory $tempDir `
    -RunId $runId `
    -Metadata @{ TestRun = $true }
  
  # Write artifacts
  Write-Host "  Writing artifacts..."
  Write-GcReportHtml `
    -Path $bundle.ReportHtmlPath `
    -Title "Errors & Failures Snapshot" `
    -Summary $reportData.Summary `
    -Rows $reportData.Rows `
    -Warnings $reportData.Warnings
  
  $artifactResults = Write-GcDataArtifacts `
    -Rows $reportData.Rows `
    -JsonPath $bundle.DataJsonPath `
    -CsvPath $bundle.DataCsvPath `
    -XlsxPath $bundle.DataXlsxPath `
    -CreateXlsx $true
  
  # Update artifact index
  Write-Host "  Updating artifact index..."
  $indexPath = [System.IO.Path]::Combine($tempDir, 'index.json')
  Update-GcArtifactIndex -IndexPath $indexPath -Entry @{
    ReportName = "Errors & Failures Snapshot"
    RunId = $runId
    Timestamp = (Get-Date -Format o)
    BundlePath = $bundle.BundlePath
    RowCount = $reportData.Rows.Count
    Status = 'OK'
  }
  
  # Verify artifacts
  $artifactsExist = @{
    Html = Test-Path $bundle.ReportHtmlPath
    Json = Test-Path $bundle.DataJsonPath
    Csv = Test-Path $bundle.DataCsvPath
    Metadata = Test-Path $bundle.MetadataPath
    Index = Test-Path $indexPath
  }
  
  Write-Host "  Artifacts created:"
  foreach ($key in $artifactsExist.Keys) {
    $icon = if ($artifactsExist[$key]) { '[PASS]' } else { '[FAIL]' }
    Write-Host "    $icon $key"
  }
  
  $allArtifactsCreated = @($artifactsExist.Keys | Where-Object { -not $artifactsExist[$_] }).Count -eq 0
  
  if ($allArtifactsCreated) {
    Write-Host "  [PASS] All core artifacts created" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Some artifacts missing" -ForegroundColor Red
    $testsFailed++
  }
  
  # Verify HTML content
  $htmlContent = Get-Content -Path $bundle.ReportHtmlPath -Raw
  $htmlContainsTitle = $htmlContent -match 'Errors.*Failures Snapshot'
  $htmlContainsSummary = $htmlContent -match '(?i)summary'
  
  if ($htmlContainsTitle -and $htmlContainsSummary) {
    Write-Host "  [PASS] HTML report contains expected content" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] HTML report missing expected content" -ForegroundColor Red
    $testsFailed++
  }
  
  Write-Host ""
  Write-Host "  Artifact bundle created at:"
  Write-Host "  $($bundle.BundlePath)"
  Write-Host ""
  
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace
  $testsFailed++
}

# Test 2: Verify artifact index
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 2: Artifact Index Retrieval" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $indexPath = [System.IO.Path]::Combine($tempDir, 'index.json')
  $index = Get-GcArtifactIndex -IndexPath $indexPath
  
  Write-Host "  Index entries: $($index.Count)"
  
  if ($index.Count -eq 1) {
    Write-Host "  [PASS] Index contains 1 entry" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Expected 1 index entry, got $($index.Count)" -ForegroundColor Red
    $testsFailed++
  }
  
  if ($index[0].ReportName -eq "Errors & Failures Snapshot") {
    Write-Host "  [PASS] Index entry has correct report name" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Index entry has incorrect report name: $($index[0].ReportName)" -ForegroundColor Red
    $testsFailed++
  }
  
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Integration Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor Red
Write-Host ""
Write-Host "Test artifacts preserved at: $tempDir" -ForegroundColor Yellow
Write-Host ""

if ($testsFailed -gt 0) {
  exit 1
}

exit 0

