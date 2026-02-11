### BEGIN: tests/test-timeline.ps1
# Test script for Timeline functionality
# This tests the Timeline module and related functions

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "AGenesysToolKit Timeline Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

Write-Host "Repository root: $repoRoot" -ForegroundColor Gray
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host ""

$testsPassed = 0
$testsFailed = 0

function Test-TimelineFunction {
  param(
    [string]$TestName,
    [scriptblock]$TestBlock
  )
  
  Write-Host "========================================" -ForegroundColor Cyan
  Write-Host "Test: $TestName" -ForegroundColor Cyan
  Write-Host "========================================" -ForegroundColor Cyan
  
  try {
    & $TestBlock
    Write-Host "  [PASS] $TestName" -ForegroundColor Green
    $script:testsPassed++
  } catch {
    Write-Host "  [FAIL] $TestName" -ForegroundColor Red
    Write-Host "  Error: $_" -ForegroundColor Red
    $script:testsFailed++
  }
  Write-Host ""
}

# Test 1: Import Timeline module
Test-TimelineFunction "Import Timeline module" {
  Import-Module (Join-Path -Path $coreRoot -ChildPath 'Timeline.psm1') -Force
  
  # Verify module is loaded
  $module = Get-Module -Name Timeline
  if (-not $module) {
    throw "Timeline module not loaded"
  }
}

# Test 2: New-GcTimelineEvent with Segment category
Test-TimelineFunction "New-GcTimelineEvent with Segment category" {
  $evt = New-GcTimelineEvent `
    -Time (Get-Date) `
    -Category 'Segment' `
    -Label 'Test Segment Event' `
    -Details @{ test = 'value' } `
    -CorrelationKeys @{ conversationId = 'c-123456' }
  
  if ($evt.Category -ne 'Segment') {
    throw "Expected Category 'Segment', got '$($evt.Category)'"
  }
  
  if ($evt.Label -ne 'Test Segment Event') {
    throw "Expected Label 'Test Segment Event', got '$($evt.Label)'"
  }
}

# Test 3: New-GcTimelineEvent with Live Events category
Test-TimelineFunction "New-GcTimelineEvent with Live Events category" {
  $evt = New-GcTimelineEvent `
    -Time (Get-Date) `
    -Category 'Live Events' `
    -Label 'Subscription Event' `
    -Details @{ topic = 'audiohook.transcription.final'; text = 'Test text' } `
    -CorrelationKeys @{ conversationId = 'c-123456'; eventType = 'audiohook.transcription.final' }
  
  if ($evt.Category -ne 'Live Events') {
    throw "Expected Category 'Live Events', got '$($evt.Category)'"
  }
}

# Test 4: ConvertTo-GcTimeline with mock conversation data
Test-TimelineFunction "ConvertTo-GcTimeline with mock data" {
  $mockConversation = [PSCustomObject]@{
    id = 'c-123456'
    startTime = (Get-Date).AddMinutes(-10).ToString('o')
    participants = @(
      [PSCustomObject]@{
        id = 'p-1'
        name = 'Test User'
        startTime = (Get-Date).AddMinutes(-10).ToString('o')
        endTime = (Get-Date).AddMinutes(-2).ToString('o')
        sessions = @()
      }
    )
  }
  
  $timeline = ConvertTo-GcTimeline -ConversationData $mockConversation
  
  if (-not $timeline) {
    throw "Expected timeline events, got null"
  }
  
  if ($timeline.Count -lt 1) {
    throw "Expected at least 1 event, got $($timeline.Count)"
  }
  
  Write-Host "  Generated $($timeline.Count) timeline events" -ForegroundColor Gray
}

# Test 5: ConvertTo-GcTimeline with subscription events
Test-TimelineFunction "ConvertTo-GcTimeline with subscription events" {
  $mockConversation = [PSCustomObject]@{
    id = 'c-123456'
    startTime = (Get-Date).AddMinutes(-10).ToString('o')
    participants = @()
  }
  
  $subEvents = @(
    [PSCustomObject]@{
      ts = (Get-Date).AddMinutes(-5)
      conversationId = 'c-123456'
      type = 'audiohook.transcription.final'
      text = 'Test transcription'
    }
  )
  
  $timeline = ConvertTo-GcTimeline -ConversationData $mockConversation -SubscriptionEvents $subEvents
  
  if (-not $timeline) {
    throw "Expected timeline events, got null"
  }
  
  # Check if subscription event was integrated
  $transcriptionEvent = $timeline | Where-Object { $_.Category -eq 'Transcription' }
  if (-not $transcriptionEvent) {
    throw "Expected Transcription event in timeline"
  }
  
  Write-Host "  Timeline includes $($timeline.Count) events (including subscription events)" -ForegroundColor Gray
}

# Test 6: Timeline events are sorted by time
Test-TimelineFunction "Timeline events are sorted by time" {
  $now = Get-Date
  $evt1 = New-GcTimelineEvent -Time $now.AddMinutes(-10) -Category 'System' -Label 'Event 1'
  $evt2 = New-GcTimelineEvent -Time $now.AddMinutes(-5) -Category 'Segment' -Label 'Event 2'
  $evt3 = New-GcTimelineEvent -Time $now.AddMinutes(-8) -Category 'Error' -Label 'Event 3'
  
  $timeline = @($evt1, $evt2, $evt3) | Sort-Object -Property Time
  
  if ($timeline[0].Label -ne 'Event 1') {
    throw "Expected first event to be 'Event 1', got '$($timeline[0].Label)'"
  }
  
  if ($timeline[1].Label -ne 'Event 3') {
    throw "Expected second event to be 'Event 3', got '$($timeline[1].Label)'"
  }
  
  if ($timeline[2].Label -ne 'Event 2') {
    throw "Expected third event to be 'Event 2', got '$($timeline[2].Label)'"
  }
}

# Test 7: All valid categories are accepted
Test-TimelineFunction "All valid timeline categories" {
  $categories = @('Segment', 'MediaStats', 'Error', 'AgentAssist', 'Transcription', 'System', 'Quality', 'Live Events')
  
  foreach ($cat in $categories) {
    $evt = New-GcTimelineEvent -Time (Get-Date) -Category $cat -Label "Test $cat"
    if ($evt.Category -ne $cat) {
      throw "Failed to create event with category '$cat'"
    }
  }
  
  Write-Host "  All $($categories.Count) categories validated" -ForegroundColor Gray
}

# Test 8: CorrelationKeys are preserved
Test-TimelineFunction "CorrelationKeys are preserved" {
  $corrKeys = @{
    conversationId = 'c-123456'
    participantId = 'p-789'
    sessionId = 's-abc'
  }
  
  $evt = New-GcTimelineEvent `
    -Time (Get-Date) `
    -Category 'Segment' `
    -Label 'Test Event' `
    -CorrelationKeys $corrKeys
  
  if ($evt.CorrelationKeys.conversationId -ne 'c-123456') {
    throw "CorrelationKeys not preserved correctly"
  }
  
  if ($evt.CorrelationKeys.participantId -ne 'p-789') {
    throw "CorrelationKeys not preserved correctly"
  }
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Timeline Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host ""

if ($testsFailed -eq 0) {
  Write-Host "================================" -ForegroundColor Green
  Write-Host "    [PASS] TIMELINE TEST PASS" -ForegroundColor Green
  Write-Host "================================" -ForegroundColor Green
  exit 0
} else {
  Write-Host "================================" -ForegroundColor Red
  Write-Host "    [FAIL] TIMELINE TEST FAIL" -ForegroundColor Red
  Write-Host "================================" -ForegroundColor Red
  exit 1
}

### END: tests/test-timeline.ps1

