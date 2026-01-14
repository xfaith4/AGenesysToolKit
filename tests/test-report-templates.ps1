#!/usr/bin/env pwsh
# Test script for ReportTemplates module

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Report Templates Module Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get repository root
$repoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repository root: $repoRoot"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host ""

# Import modules
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'
$reportingModule = Join-Path -Path $coreRoot -ChildPath 'Reporting.psm1'
$templatesModule = Join-Path -Path $coreRoot -ChildPath 'ReportTemplates.psm1'

if (-not (Test-Path $templatesModule)) {
  Write-Host "  [FAIL] ReportTemplates module not found: $templatesModule" -ForegroundColor Red
  exit 1
}

Import-Module $reportingModule -Force
Import-Module $templatesModule -Force

$testsPassed = 0
$testsFailed = 0

# Test 1: Get-GcReportTemplates
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 1: Get-GcReportTemplates" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $templates = Get-GcReportTemplates
  
  Write-Host "  Found $($templates.Count) templates"
  
  if ($templates.Count -eq 4) {
    Write-Host "  [PASS] Expected number of templates (4)" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Expected 4 templates, got $($templates.Count)" -ForegroundColor Red
    $testsFailed++
  }
  
  # Check template names
  $expectedNames = @('Conversation Inspect Packet', 'Errors & Failures Snapshot', 'Subscription Session Summary', 'Executive Daily Summary')
  $actualNames = $templates.Name
  
  $allNamesMatch = $true
  foreach ($name in $expectedNames) {
    if ($name -notin $actualNames) {
      Write-Host "  [FAIL] Missing template: $name" -ForegroundColor Red
      $allNamesMatch = $false
    }
  }
  
  if ($allNamesMatch) {
    Write-Host "  [PASS] All expected templates present" -ForegroundColor Green
    $testsPassed++
  } else {
    $testsFailed++
  }
  
  # Check template structure
  $template = $templates[0]
  if ($template.Name -and $template.Description -and $template.Parameters -and $template.InvokeScript) {
    Write-Host "  [PASS] Template has required properties" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Template missing required properties" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 2: Invoke-ErrorsFailuresSnapshotReport (mock data)
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 2: Errors & Failures Snapshot (mock)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  # Create mock job with errors
  $mockJobs = @(
    [PSCustomObject]@{
      Name = 'Test Job 1'
      Type = 'Export'
      Status = 'Failed'
      Errors = @('Connection timeout', 'Retry limit exceeded')
      Ended = (Get-Date).AddMinutes(-10)
    },
    [PSCustomObject]@{
      Name = 'Test Job 2'
      Type = 'Query'
      Status = 'Completed'
      Errors = @()
      Ended = (Get-Date).AddMinutes(-5)
    }
  )
  
  # Create mock subscription errors
  $mockSubErrors = @(
    [PSCustomObject]@{
      ts = (Get-Date).AddMinutes(-8)
      severity = 'error'
      topic = 'v2.conversations.{id}.transcription.error'
      conversationId = 'c-12345'
      text = 'Transcription service unavailable'
    }
  )
  
  $result = Invoke-ErrorsFailuresSnapshotReport `
    -Jobs $mockJobs `
    -SubscriptionErrors $mockSubErrors `
    -Since (Get-Date).AddHours(-1)
  
  Write-Host "  Rows returned: $($result.Rows.Count)"
  Write-Host "  Warnings: $($result.Warnings.Count)"
  
  if ($result.Rows.Count -eq 2) {
    Write-Host "  [PASS] Correct number of error rows (1 failed job + 1 sub error)" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Expected 2 error rows, got $($result.Rows.Count)" -ForegroundColor Red
    $testsFailed++
  }
  
  if ($result.Summary.Status -eq 'OK') {
    Write-Host "  [PASS] Report status is OK" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Report status is not OK: $($result.Summary.Status)" -ForegroundColor Red
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Exception: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 3: Invoke-SubscriptionSessionSummaryReport (mock data)
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 3: Subscription Session Summary (mock)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
  $sessionStart = (Get-Date).AddMinutes(-15)
  $topics = @('v2.conversations.{id}.transcription', 'v2.conversations.{id}.agentassist')
  
  $mockEvents = @(
    [PSCustomObject]@{
      ts = (Get-Date).AddMinutes(-14)
      topic = 'v2.conversations.{id}.transcription'
      text = 'Transcription event 1'
    },
    [PSCustomObject]@{
      ts = (Get-Date).AddMinutes(-13)
      topic = 'v2.conversations.{id}.transcription'
      text = 'Transcription event 2'
    },
    [PSCustomObject]@{
      ts = (Get-Date).AddMinutes(-12)
      topic = 'v2.conversations.{id}.agentassist'
      text = 'Agent assist suggestion'
    }
  )
  
  $result = Invoke-SubscriptionSessionSummaryReport `
    -SessionStart $sessionStart `
    -Topics $topics `
    -Events $mockEvents `
    -Disconnects 0
  
  Write-Host "  Rows returned: $($result.Rows.Count)"
  Write-Host "  Topic groups: $($result.Rows.Count)"
  
  if ($result.Rows.Count -eq 2) {
    Write-Host "  [PASS] Correct number of topic groups (2)" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Expected 2 topic groups, got $($result.Rows.Count)" -ForegroundColor Red
    $testsFailed++
  }
  
  if ($result.Summary.TotalEvents -eq 3) {
    Write-Host "  [PASS] Correct total event count (3)" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Expected 3 total events, got $($result.Summary.TotalEvents)" -ForegroundColor Red
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
  exit 1
}

exit 0
