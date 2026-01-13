#!/usr/bin/env pwsh
# Test script for Reporting module

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Reporting Module Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get repository root
$repoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repository root: $repoRoot"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host ""

# Import module
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'
$reportingModule = Join-Path -Path $coreRoot -ChildPath 'Reporting.psm1'

if (-not (Test-Path $reportingModule)) {
  Write-Host "  [FAIL] Reporting module not found: $reportingModule" -ForegroundColor Red
  exit 1
}

Import-Module $reportingModule -Force

$testsPassed = 0
$testsFailed = 0

# Create temp directory for tests
$tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-reporting-$(Get-Date -Format 'yyyyMMddHHmmss')")
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Write-Host "Test directory: $tempDir"
Write-Host ""

# Test 1: New-GcReportRunId
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 1: New-GcReportRunId" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $runId1 = New-GcReportRunId
  $runId2 = New-GcReportRunId
  
  Write-Host "  Generated RunId 1: $runId1"
  Write-Host "  Generated RunId 2: $runId2"
  
  # Check format: yyyyMMdd-HHmmss_<guid>
  if ($runId1 -match '^\d{8}-\d{6}_[a-f0-9]{8}$') {
    Write-Host "  [PASS] RunId format is correct" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] RunId format is incorrect: $runId1" -ForegroundColor Red
    $testsFailed++
  }
  
  # Check uniqueness
  if ($runId1 -ne $runId2) {
    Write-Host "  [PASS] RunIds are unique" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] RunIds are not unique" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 2: New-GcArtifactBundle
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 2: New-GcArtifactBundle" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $bundle = New-GcArtifactBundle `
    -ReportName "Test Report" `
    -OutputDirectory $tempDir `
    -Metadata @{
      Region = 'usw2.pure.cloud'
      OrgId = 'test-org-123'
    }
  
  Write-Host "  Bundle Path: $($bundle.BundlePath)"
  Write-Host "  RunId: $($bundle.RunId)"
  
  # Check bundle directory exists
  if (Test-Path $bundle.BundlePath) {
    Write-Host "  [PASS] Bundle directory created" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Bundle directory not created" -ForegroundColor Red
    $testsFailed++
  }
  
  # Check metadata.json exists
  if (Test-Path $bundle.MetadataPath) {
    Write-Host "  [PASS] metadata.json created" -ForegroundColor Green
    $testsPassed++
    
    # Read and validate metadata
    $metadata = Get-Content -Path $bundle.MetadataPath -Raw | ConvertFrom-Json
    
    if ($metadata.ReportName -eq "Test Report") {
      Write-Host "  [PASS] Metadata ReportName is correct" -ForegroundColor Green
      $testsPassed++
    } else {
      Write-Host "  [FAIL] Metadata ReportName is incorrect: $($metadata.ReportName)" -ForegroundColor Red
      $testsFailed++
    }
    
    if ($metadata.Region -eq 'usw2.pure.cloud') {
      Write-Host "  [PASS] Metadata custom field (Region) preserved" -ForegroundColor Green
      $testsPassed++
    } else {
      Write-Host "  [FAIL] Metadata custom field not preserved" -ForegroundColor Red
      $testsFailed++
    }
  } else {
    Write-Host "  [FAIL] metadata.json not created" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 3: Write-GcReportHtml
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 3: Write-GcReportHtml" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $htmlPath = [System.IO.Path]::Combine($tempDir, 'test-report.html')
  
  Write-GcReportHtml `
    -Path $htmlPath `
    -Title "Test Report Card" `
    -Summary @{
      ConversationId = 'c-12345'
      RowCount = 42
      Region = 'usw2.pure.cloud'
    } `
    -Warnings @('Test warning 1', 'Test warning 2') `
    -Rows @(
      [PSCustomObject]@{ Id = 1; Name = 'Alice'; Count = 10 }
      [PSCustomObject]@{ Id = 2; Name = 'Bob'; Count = 20 }
      [PSCustomObject]@{ Id = 3; Name = 'Charlie'; Count = 30 }
    )
  
  # Check HTML file exists
  if (Test-Path $htmlPath) {
    Write-Host "  [PASS] HTML report created" -ForegroundColor Green
    $testsPassed++
    
    # Read HTML and validate content
    $htmlContent = Get-Content -Path $htmlPath -Raw
    
    if ($htmlContent -match 'Test Report Card') {
      Write-Host "  [PASS] HTML contains title" -ForegroundColor Green
      $testsPassed++
    } else {
      Write-Host "  [FAIL] HTML missing title" -ForegroundColor Red
      $testsFailed++
    }
    
    if ($htmlContent -match 'ConversationId') {
      Write-Host "  [PASS] HTML contains summary table" -ForegroundColor Green
      $testsPassed++
    } else {
      Write-Host "  [FAIL] HTML missing summary table" -ForegroundColor Red
      $testsFailed++
    }
    
    if ($htmlContent -match 'Test warning 1') {
      Write-Host "  [PASS] HTML contains warnings" -ForegroundColor Green
      $testsPassed++
    } else {
      Write-Host "  [FAIL] HTML missing warnings" -ForegroundColor Red
      $testsFailed++
    }
    
    if ($htmlContent -match 'Alice' -and $htmlContent -match 'Bob') {
      Write-Host "  [PASS] HTML contains data preview" -ForegroundColor Green
      $testsPassed++
    } else {
      Write-Host "  [FAIL] HTML missing data preview" -ForegroundColor Red
      $testsFailed++
    }
  } else {
    Write-Host "  [FAIL] HTML report not created" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 4: Write-GcDataArtifacts (JSON and CSV)
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 4: Write-GcDataArtifacts" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $testData = @(
    [PSCustomObject]@{ Id = 1; Name = 'Alice'; Score = 95 }
    [PSCustomObject]@{ Id = 2; Name = 'Bob'; Score = 87 }
    [PSCustomObject]@{ Id = 3; Name = 'Charlie'; Score = 92 }
  )
  
  $jsonPath = [System.IO.Path]::Combine($tempDir, 'test-data.json')
  $csvPath = [System.IO.Path]::Combine($tempDir, 'test-data.csv')
  $xlsxPath = [System.IO.Path]::Combine($tempDir, 'test-data.xlsx')
  
  $result = Write-GcDataArtifacts `
    -Rows $testData `
    -JsonPath $jsonPath `
    -CsvPath $csvPath `
    -XlsxPath $xlsxPath `
    -CreateXlsx $true
  
  Write-Host "  JSON Created: $($result.JsonCreated)"
  Write-Host "  CSV Created: $($result.CsvCreated)"
  Write-Host "  XLSX Created: $($result.XlsxCreated)"
  if ($result.XlsxSkippedReason) {
    Write-Host "  XLSX Skipped Reason: $($result.XlsxSkippedReason)"
  }
  
  # Check JSON
  if ($result.JsonCreated -and (Test-Path $jsonPath)) {
    Write-Host "  [PASS] JSON file created" -ForegroundColor Green
    $testsPassed++
    
    # Validate JSON content
    $jsonData = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
    if ($jsonData.Count -eq 3 -and $jsonData[0].Name -eq 'Alice') {
      Write-Host "  [PASS] JSON content is correct" -ForegroundColor Green
      $testsPassed++
    } else {
      Write-Host "  [FAIL] JSON content is incorrect" -ForegroundColor Red
      $testsFailed++
    }
  } else {
    Write-Host "  [FAIL] JSON file not created" -ForegroundColor Red
    $testsFailed++
  }
  
  # Check CSV
  if ($result.CsvCreated -and (Test-Path $csvPath)) {
    Write-Host "  [PASS] CSV file created" -ForegroundColor Green
    $testsPassed++
    
    # Validate CSV content
    $csvData = Import-Csv -Path $csvPath
    if ($csvData.Count -eq 3 -and $csvData[0].Name -eq 'Alice') {
      Write-Host "  [PASS] CSV content is correct" -ForegroundColor Green
      $testsPassed++
    } else {
      Write-Host "  [FAIL] CSV content is incorrect" -ForegroundColor Red
      $testsFailed++
    }
  } else {
    Write-Host "  [FAIL] CSV file not created" -ForegroundColor Red
    $testsFailed++
  }
  
  # Check XLSX (optional - may not be available)
  if ($result.XlsxCreated) {
    Write-Host "  [INFO] XLSX file created (ImportExcel available)" -ForegroundColor Yellow
  } else {
    Write-Host "  [INFO] XLSX skipped: $($result.XlsxSkippedReason)" -ForegroundColor Yellow
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 5: Update-GcArtifactIndex and Get-GcArtifactIndex
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 5: Artifact Index" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $indexPath = [System.IO.Path]::Combine($tempDir, 'index.json')
  
  # Add first entry
  Update-GcArtifactIndex -IndexPath $indexPath -Entry @{
    ReportName = 'Test Report 1'
    RunId = 'run-001'
    Timestamp = (Get-Date -Format o)
    Status = 'OK'
    RowCount = 10
  }
  
  # Add second entry
  Update-GcArtifactIndex -IndexPath $indexPath -Entry @{
    ReportName = 'Test Report 2'
    RunId = 'run-002'
    Timestamp = (Get-Date -Format o)
    Status = 'Warnings'
    RowCount = 5
  }
  
  # Check index file exists
  if (Test-Path $indexPath) {
    Write-Host "  [PASS] Index file created" -ForegroundColor Green
    $testsPassed++
    
    # Read index
    $index = Get-GcArtifactIndex -IndexPath $indexPath
    
    if ($index.Count -eq 2) {
      Write-Host "  [PASS] Index contains 2 entries" -ForegroundColor Green
      $testsPassed++
    } else {
      Write-Host "  [FAIL] Index contains $($index.Count) entries (expected 2)" -ForegroundColor Red
      $testsFailed++
    }
    
    if ($index[0].ReportName -eq 'Test Report 1' -and $index[1].ReportName -eq 'Test Report 2') {
      Write-Host "  [PASS] Index entries are correct" -ForegroundColor Green
      $testsPassed++
    } else {
      Write-Host "  [FAIL] Index entries are incorrect" -ForegroundColor Red
      $testsFailed++
    }
  } else {
    Write-Host "  [FAIL] Index file not created" -ForegroundColor Red
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

# Cleanup
try {
  Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Test directory cleaned up." -ForegroundColor Gray
} catch {
  Write-Host "Warning: Could not clean up test directory: $_" -ForegroundColor Yellow
}

if ($testsFailed -gt 0) {
  exit 1
}

exit 0
