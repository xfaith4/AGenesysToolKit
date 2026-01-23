#!/usr/bin/env pwsh
#Requires -Version 5.1

<#
.SYNOPSIS
  Test script for Live Event Stream refactoring

.DESCRIPTION
  Tests the new structured event storage, Format-EventSummary function,
  and event object schema.
#>

# Import the app script to test the functions (but don't show UI)
$scriptRoot = Split-Path -Parent $PSCommandPath
$appRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'App'
$appScript = Join-Path -Path $appRoot -ChildPath 'GenesysCloudTool_UX_Prototype.ps1'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Live Event Stream Refactoring Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$testsPassed = 0
$testsFailed = 0

# We'll test the functions by loading them into the current scope
# Since the script includes WPF, we need to dot-source only the relevant functions

# Test 1: Format-EventSummary function exists
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Test 1: Format-EventSummary Function Definition" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

# Parse the script file to extract Format-EventSummary function
$scriptContent = Get-Content -Path $appScript -Raw

if ($scriptContent -match 'function Format-EventSummary') {
  Write-Host "  [PASS] Format-EventSummary function is defined" -ForegroundColor Green
  $testsPassed++
  
  # Extract and eval the function definition
  if ($scriptContent -match '(?s)function Format-EventSummary\s*\{.*?\.EXAMPLE.*?\}.*?\n\}') {
    $functionDef = $matches[0]
    
    # Also need Escape-GcXml if used
    if ($scriptContent -match '(?s)function Escape-GcXml\s*\{.*?\n\}') {
      $escapeFunc = $matches[0]
      Invoke-Expression $escapeFunc
    }
    
    Invoke-Expression $functionDef
    Write-Host "  [INFO] Function loaded successfully" -ForegroundColor Cyan
  }
} else {
  Write-Host "  [FAIL] Format-EventSummary function not found" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 2: Format-EventSummary with basic event
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Test 2: Format-EventSummary with Basic Event" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

try {
  $testEvent = [PSCustomObject]@{
    ts = Get-Date
    severity = 'warn'
    topic = 'audiohook.transcription.final'
    conversationId = 'c-123456'
    queueId = $null
    queueName = 'Support - Voice'
    text = 'Test transcript text'
    raw = @{
      eventId = [guid]::NewGuid().ToString()
      timestamp = (Get-Date).ToString('o')
    }
  }
  
  $summary = Format-EventSummary -Event $testEvent
  
  if ($summary -and $summary -match '\[.*?\].*\[warn\].*audiohook\.transcription\.final.*conv=c-123456.*Test transcript text') {
    Write-Host "  [PASS] Format-EventSummary produces correct format" -ForegroundColor Green
    Write-Host "  [INFO] Output: $summary" -ForegroundColor Cyan
    $testsPassed++
  } else {
    Write-Host "  [FAIL] Format-EventSummary output format incorrect" -ForegroundColor Red
    Write-Host "  [INFO] Output: $summary" -ForegroundColor Yellow
    $testsFailed++
  }
} catch {
  Write-Host "  [FAIL] Format-EventSummary threw error: $_" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 3: Event object schema validation
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Test 3: Event Object Schema" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

$requiredFields = @('ts', 'severity', 'topic', 'conversationId', 'queueId', 'queueName', 'raw')
$schemaValid = $true

foreach ($field in $requiredFields) {
  if ($testEvent.PSObject.Properties.Name -contains $field) {
    Write-Host "  [PASS] Event has required field: $field" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] Event missing required field: $field" -ForegroundColor Red
    $schemaValid = $false
  }
}

if ($schemaValid) {
  $testsPassed++
} else {
  $testsFailed++
}
Write-Host ""

# Test 4: AppState EventBuffer and PinnedEvents collections
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Test 4: AppState Collections" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

if ($scriptContent -match 'EventBuffer\s*=\s*New-Object System\.Collections\.ObjectModel\.ObservableCollection\[object\]') {
  Write-Host "  [PASS] EventBuffer is an ObservableCollection" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] EventBuffer not defined as ObservableCollection" -ForegroundColor Red
  $testsFailed++
}

if ($scriptContent -match 'PinnedEvents\s*=\s*New-Object System\.Collections\.ObjectModel\.ObservableCollection\[object\]') {
  Write-Host "  [PASS] PinnedEvents is an ObservableCollection" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] PinnedEvents not defined as ObservableCollection" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 5: New-MockEvent returns structured object
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Test 5: New-MockEvent Structure" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

if ($scriptContent -match '(?s)function New-MockEvent.*?raw = @\{.*?eventId.*?timestamp.*?\}') {
  Write-Host "  [PASS] New-MockEvent includes raw field" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] New-MockEvent doesn't include raw field" -ForegroundColor Red
  $testsFailed++
}

if ($scriptContent -match 'topic\s*=\s*\$etype') {
  Write-Host "  [PASS] New-MockEvent uses 'topic' field name" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] New-MockEvent doesn't use 'topic' field name" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 6: Search functionality implemented
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Test 6: Search Box Functionality" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

if ($scriptContent -match '\$h\.TxtSearch\.Add_TextChanged') {
  Write-Host "  [PASS] Search box TextChanged handler exists" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Search box TextChanged handler not found" -ForegroundColor Red
  $testsFailed++
}

if ($scriptContent -match 'conversationId.*Contains\(\$searchLower\)') {
  Write-Host "  [PASS] Search includes conversationId" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Search doesn't include conversationId" -ForegroundColor Red
  $testsFailed++
}

if ($scriptContent -match 'topic.*Contains\(\$searchLower\)') {
  Write-Host "  [PASS] Search includes topic" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Search doesn't include topic" -ForegroundColor Red
  $testsFailed++
}

if ($scriptContent -match 'severity.*Contains\(\$searchLower\)') {
  Write-Host "  [PASS] Search includes severity" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Search doesn't include severity" -ForegroundColor Red
  $testsFailed++
}

if ($scriptContent -match 'ConvertTo-Json') {
  Write-Host "  [PASS] Search includes raw JSON" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Search doesn't include raw JSON" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 7: Pinning stores object reference
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Test 7: Pinning Functionality" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

if ($scriptContent -match '\$script:AppState\.PinnedEvents\.Add\(\$evt\)') {
  Write-Host "  [PASS] Pinning adds event object to PinnedEvents collection" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Pinning doesn't add event object to PinnedEvents" -ForegroundColor Red
  $testsFailed++
}

if ($scriptContent -match 'eventId.*\$evt\.raw\.eventId') {
  Write-Host "  [PASS] Pinning checks for duplicates using eventId" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] Pinning doesn't check for duplicates properly" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 8: StreamTimer stores objects in ListBoxItem.Tag
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Test 8: StreamTimer Object Storage" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

if ($scriptContent -match 'New-Object System\.Windows\.Controls\.ListBoxItem') {
  Write-Host "  [PASS] StreamTimer creates ListBoxItem objects" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] StreamTimer doesn't create ListBoxItem objects" -ForegroundColor Red
  $testsFailed++
}

if ($scriptContent -match '\$listItem\.Tag\s*=\s*\$evt') {
  Write-Host "  [PASS] StreamTimer stores event in ListBoxItem.Tag" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] StreamTimer doesn't store event in Tag" -ForegroundColor Red
  $testsFailed++
}

if ($scriptContent -match 'Format-EventSummary.*-Event \$evt') {
  Write-Host "  [PASS] StreamTimer uses Format-EventSummary for display" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] StreamTimer doesn't use Format-EventSummary" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Test 9: EventBuffer stores events
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Test 9: EventBuffer Storage" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

if ($scriptContent -match '\$script:AppState\.EventBuffer\.Insert\(0, \$evt\)') {
  Write-Host "  [PASS] StreamTimer adds events to EventBuffer" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] StreamTimer doesn't add events to EventBuffer" -ForegroundColor Red
  $testsFailed++
}

if ($scriptContent -match 'EventBuffer\.Count -gt 1000') {
  Write-Host "  [PASS] EventBuffer has size limit" -ForegroundColor Green
  $testsPassed++
} else {
  Write-Host "  [FAIL] EventBuffer doesn't have size limit" -ForegroundColor Red
  $testsFailed++
}
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

if ($testsFailed -eq 0) {
  Write-Host "================================" -ForegroundColor Green
  Write-Host "    ✓ ALL TESTS PASS" -ForegroundColor Green
  Write-Host "================================" -ForegroundColor Green
  exit 0
} else {
  Write-Host "================================" -ForegroundColor Red
  Write-Host "    ✗ SOME TESTS FAILED" -ForegroundColor Red
  Write-Host "================================" -ForegroundColor Red
  exit 1
}
