#!/usr/bin/env pwsh
# Test script for ArtifactGenerator module

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ArtifactGenerator Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get repository root
$repoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repository root: $repoRoot"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host ""

# Import module
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'
$artifactModule = Join-Path -Path $coreRoot -ChildPath 'ArtifactGenerator.psm1'
Import-Module $artifactModule -Force

# Test 1: Windows-safe filename generation
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 1: Windows-safe filename generation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$testConvId = "c-12345:test/bad\chars"
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeConvId = $testConvId -replace '[<>:"/\\|?*]', '_'

Write-Host "Original ConversationId: $testConvId"
Write-Host "Safe ConversationId: $safeConvId"

if ($safeConvId -match '[<>:"/\\|?*]') {
  Write-Host "  [FAIL] Safe filename still contains invalid characters" -ForegroundColor Red
  exit 1
} else {
  Write-Host "  [PASS] Filename is Windows-safe" -ForegroundColor Green
}
Write-Host ""

# Test 2: Create mock packet
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 2: Create mock packet" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$tempDir = if ($IsWindows -or $env:TEMP) {
  if ($env:TEMP) {
    Join-Path -Path $env:TEMP -ChildPath "test-artifacts-$(Get-Date -Format 'yyyyMMddHHmmss')"
  } else {
    Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test-artifacts-$(Get-Date -Format 'yyyyMMddHHmmss')"
  }
} else {
  Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test-artifacts-$(Get-Date -Format 'yyyyMMddHHmmss')"
}
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Write-Host "Test directory: $tempDir"

# Create mock conversation data
$mockConversation = @{
  conversationId = 'c-test-12345'
  startTime = '2024-01-15T10:30:00Z'
  endTime = '2024-01-15T10:45:00Z'
  participants = @(
    @{ id = 'p1'; name = 'Agent' },
    @{ id = 'p2'; name = 'Customer' }
  )
}

# Create mock timeline
$mockTimeline = @(
  [PSCustomObject]@{
    Time = [datetime]::Parse('2024-01-15T10:30:00Z')
    Category = 'Segment'
    Label = 'Call started'
    Details = @{ event = 'start' }
    CorrelationKeys = @{ conversationId = 'c-test-12345' }
  },
  [PSCustomObject]@{
    Time = [datetime]::Parse('2024-01-15T10:45:00Z')
    Category = 'Segment'
    Label = 'Call ended'
    Details = @{ event = 'end' }
    CorrelationKeys = @{ conversationId = 'c-test-12345' }
  }
)

# Create mock subscription events
$mockSubEvents = @(
  [PSCustomObject]@{
    ts = [datetime]::Parse('2024-01-15T10:31:00Z')
    severity = 'info'
    topic = 'audiohook.transcription.final'
    conversationId = 'c-test-12345'
    text = 'Hello, how can I help you?'
  },
  [PSCustomObject]@{
    ts = [datetime]::Parse('2024-01-15T10:31:30Z')
    severity = 'info'
    topic = 'audiohook.transcription.final'
    conversationId = 'c-test-12345'
    text = 'I need help with my account.'
  },
  [PSCustomObject]@{
    ts = [datetime]::Parse('2024-01-15T10:32:00Z')
    severity = 'error'
    topic = 'audiohook.error'
    conversationId = 'c-test-12345'
    text = 'Transcription timeout'
  }
)

# Create packet
Write-Host "Creating incident packet..."
try {
  $packet = New-GcIncidentPacket `
    -ConversationId 'c-test-12345' `
    -OutputDirectory $tempDir `
    -ConversationData $mockConversation `
    -Timeline $mockTimeline `
    -SubscriptionEvents $mockSubEvents `
    -CreateZip
  
  Write-Host "  Packet created: $($packet.PacketName)" -ForegroundColor Green
  Write-Host "  Directory: $($packet.PacketDirectory)" -ForegroundColor Green
  
  # Verify folder structure
  if (Test-Path $packet.PacketDirectory) {
    Write-Host "  [PASS] Packet directory exists" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] Packet directory not found" -ForegroundColor Red
    exit 1
  }
  
  # Verify files
  $expectedFiles = @('conversation.json', 'timeline.json', 'events.ndjson', 'transcript.txt', 'summary.md')
  $missingFiles = @()
  
  foreach ($file in $expectedFiles) {
    $filePath = Join-Path -Path $packet.PacketDirectory -ChildPath $file
    if (Test-Path $filePath) {
      Write-Host "  [PASS] $file exists" -ForegroundColor Green
    } else {
      Write-Host "  [FAIL] $file missing" -ForegroundColor Red
      $missingFiles += $file
    }
  }
  
  if ($missingFiles.Count -gt 0) {
    Write-Host "  Missing files: $($missingFiles -join ', ')" -ForegroundColor Red
    exit 1
  }
  
  # Verify ZIP if created
  if ($packet.ZipPath) {
    if (Test-Path $packet.ZipPath) {
      Write-Host "  [PASS] ZIP archive created: $(Split-Path -Leaf $packet.ZipPath)" -ForegroundColor Green
      
      # Check ZIP filename format: IncidentPacket_<conversationId>_<timestamp>.zip
      $zipName = Split-Path -Leaf $packet.ZipPath
      if ($zipName -match '^IncidentPacket_.*_\d{8}-\d{6}\.zip$') {
        Write-Host "  [PASS] ZIP filename format correct" -ForegroundColor Green
      } else {
        Write-Host "  [FAIL] ZIP filename format incorrect: $zipName" -ForegroundColor Red
        exit 1
      }
    } else {
      Write-Host "  [FAIL] ZIP archive not found" -ForegroundColor Red
      exit 1
    }
  } else {
    Write-Host "  [INFO] ZIP creation skipped (compression not available)" -ForegroundColor Yellow
  }
  
  # Verify summary.md content
  $summaryPath = Join-Path -Path $packet.PacketDirectory -ChildPath 'summary.md'
  $summaryContent = Get-Content -Path $summaryPath -Raw
  
  Write-Host ""
  Write-Host "Summary.md validation:" -ForegroundColor Cyan
  
  $checks = @(
    @{ Name = 'Contains conversation ID'; Pattern = 'c-test-12345' },
    @{ Name = 'Contains time range'; Pattern = 'Started:|Time Range' },
    @{ Name = 'Contains error analysis'; Pattern = 'Errors' },
    @{ Name = 'Contains quality notes'; Pattern = 'Quality Notes|Transcription Events' },
    @{ Name = 'Contains files list'; Pattern = 'Files Included' }
  )
  
  foreach ($check in $checks) {
    if ($summaryContent -match $check.Pattern) {
      Write-Host "  [PASS] $($check.Name)" -ForegroundColor Green
    } else {
      Write-Host "  [FAIL] $($check.Name)" -ForegroundColor Red
      exit 1
    }
  }
  
  # Verify transcript.txt content
  $transcriptPath = Join-Path -Path $packet.PacketDirectory -ChildPath 'transcript.txt'
  $transcriptContent = Get-Content -Path $transcriptPath -Raw
  
  Write-Host ""
  Write-Host "Transcript.txt validation:" -ForegroundColor Cyan
  
  if ($transcriptContent -match 'Hello, how can I help you') {
    Write-Host "  [PASS] Contains transcription text" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] Missing transcription text" -ForegroundColor Red
    exit 1
  }
  
  if ($transcriptContent -match 'I need help with my account') {
    Write-Host "  [PASS] Contains multiple transcript entries" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] Missing transcript entries" -ForegroundColor Red
    exit 1
  }
  
  # Verify events.ndjson
  $eventsPath = Join-Path -Path $packet.PacketDirectory -ChildPath 'events.ndjson'
  $eventsLines = Get-Content -Path $eventsPath
  
  Write-Host ""
  Write-Host "Events.ndjson validation:" -ForegroundColor Cyan
  Write-Host "  Event count: $($eventsLines.Count)"
  
  if ($eventsLines.Count -eq 3) {
    Write-Host "  [PASS] All subscription events written" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] Expected 3 events, found $($eventsLines.Count)" -ForegroundColor Red
    exit 1
  }
  
  # Verify each line is valid JSON
  $validJson = $true
  foreach ($line in $eventsLines) {
    try {
      $null = $line | ConvertFrom-Json
    } catch {
      $validJson = $false
      break
    }
  }
  
  if ($validJson) {
    Write-Host "  [PASS] All lines are valid JSON" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] Invalid JSON found" -ForegroundColor Red
    exit 1
  }
  
} catch {
  Write-Host "  [FAIL] Error creating packet: $_" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace -ForegroundColor Red
  exit 1
}

Write-Host ""

# Cleanup
Write-Host "Cleaning up test directory..." -ForegroundColor Cyan
Remove-Item -Path $tempDir -Recurse -Force

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "All tests passed!" -ForegroundColor Green
Write-Host ""
Write-Host "================================" -ForegroundColor Green
Write-Host "    [PASS] ARTIFACT GENERATOR PASS" -ForegroundColor Green
Write-Host "================================" -ForegroundColor Green

