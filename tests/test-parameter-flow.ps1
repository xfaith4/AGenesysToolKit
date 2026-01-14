#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Tests parameter flow through the module hierarchy to verify proper token passing.

.DESCRIPTION
  This test verifies that all modules properly accept and pass AccessToken and InstanceName
  parameters through the call chain. It checks function signatures and ensures all
  functions that make API calls have the necessary authentication parameters.

.NOTES
  This is a static analysis test that doesn't require a live Genesys Cloud connection.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Parameter Flow Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Repository root: $repoRoot" -ForegroundColor Gray
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host ""

$testsPassed = 0
$testsFailed = 0
$warnings = @()

function Test-FunctionParameters {
  param(
    [string]$ModuleName,
    [string]$FunctionName,
    [string[]]$RequiredParameters
  )
  
  try {
    $fn = Get-Command -Name $FunctionName -ErrorAction Stop
    
    foreach ($param in $RequiredParameters) {
      if (-not ($fn.Parameters.ContainsKey($param))) {
        throw "Function $FunctionName is missing required parameter: $param"
      }
    }
    
    return $true
  } catch {
    Write-Host "  [FAIL] $FunctionName - $($_.Exception.Message)" -ForegroundColor Red
    return $false
  }
}

# Test 1: Jobs.psm1 - All functions should have AccessToken and InstanceName
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 1: Jobs.psm1 Parameter Flow" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Jobs.psm1') -Force

$jobFunctions = @(
  'Wait-GcAsyncJob'
  'Start-GcAnalyticsConversationDetailsJob'
  'Get-GcAnalyticsConversationDetailsJobAvailability'
  'Get-GcAnalyticsConversationDetailsJobStatus'
  'Stop-GcAnalyticsConversationDetailsJob'
  'Get-GcAnalyticsConversationDetailsJobResults'
  'Invoke-GcAnalyticsConversationDetailsQuery'
  'Start-GcAnalyticsUserDetailsJob'
  'Get-GcAnalyticsUserDetailsJobAvailability'
  'Get-GcAnalyticsUserDetailsJobStatus'
  'Stop-GcAnalyticsUserDetailsJob'
  'Get-GcAnalyticsUserDetailsJobResults'
  'Invoke-GcAnalyticsUserDetailsQuery'
  'Start-GcUsageAggregatesQueryJob'
  'Get-GcUsageAggregatesQueryJob'
  'Start-GcClientUsageAggregatesQueryJob'
  'Get-GcClientUsageAggregatesQueryJob'
  'Start-GcAgentChecklistInferenceJob'
  'Get-GcAgentChecklistInferenceJobStatus'
)

foreach ($fnName in $jobFunctions) {
  if (Test-FunctionParameters -ModuleName 'Jobs' -FunctionName $fnName -RequiredParameters @('AccessToken', 'InstanceName')) {
    Write-Host "  [PASS] $fnName has AccessToken and InstanceName parameters" -ForegroundColor Green
    $testsPassed++
  } else {
    $testsFailed++
  }
}

# Test 2: Verify other modules that make API calls have proper parameters
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 2: Other Modules Parameter Flow" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Import-Module (Join-Path -Path $coreRoot -ChildPath 'Analytics.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'RoutingPeople.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ConfigExport.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Dependencies.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ConversationsExtended.psm1') -Force

$otherModuleFunctions = @(
  @{ Module = 'Analytics'; Function = 'Get-GcAbandonmentMetrics'; Params = @('AccessToken', 'InstanceName') }
  @{ Module = 'Analytics'; Function = 'Search-GcAbandonedConversations'; Params = @('AccessToken', 'InstanceName') }
  @{ Module = 'RoutingPeople'; Function = 'Get-GcQueues'; Params = @('AccessToken', 'InstanceName') }
  @{ Module = 'RoutingPeople'; Function = 'Get-GcUsers'; Params = @('AccessToken', 'InstanceName') }
  @{ Module = 'ConfigExport'; Function = 'Export-GcFlowsConfig'; Params = @('AccessToken', 'InstanceName') }
  @{ Module = 'Dependencies'; Function = 'Search-GcFlowReferences'; Params = @('AccessToken', 'InstanceName') }
  @{ Module = 'ConversationsExtended'; Function = 'Search-GcConversations'; Params = @('AccessToken', 'InstanceName') }
  @{ Module = 'ConversationsExtended'; Function = 'Get-GcConversationById'; Params = @('AccessToken', 'InstanceName') }
)

foreach ($testCase in $otherModuleFunctions) {
  if (Test-FunctionParameters -ModuleName $testCase.Module -FunctionName $testCase.Function -RequiredParameters $testCase.Params) {
    Write-Host "  [PASS] $($testCase.Module)::$($testCase.Function) has required parameters" -ForegroundColor Green
    $testsPassed++
  } else {
    $testsFailed++
  }
}

# Test 3: Verify Timeline module functions (uses direct Invoke-RestMethod - acceptable pattern)
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 3: Timeline Module (Direct API Calls)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Import-Module (Join-Path -Path $coreRoot -ChildPath 'Timeline.psm1') -Force

$timelineFunctions = @(
  @{ Function = 'Get-GcConversationDetails'; Params = @('AccessToken', 'Region') }
  @{ Function = 'Get-GcConversationAnalytics'; Params = @('AccessToken', 'Region') }
)

foreach ($testCase in $timelineFunctions) {
  if (Test-FunctionParameters -ModuleName 'Timeline' -FunctionName $testCase.Function -RequiredParameters $testCase.Params) {
    Write-Host "  [PASS] Timeline::$($testCase.Function) has required parameters" -ForegroundColor Green
    $testsPassed++
  } else {
    $testsFailed++
  }
}

# Test 4: Verify HttpRequests.psm1 has proper wrapper functions
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 4: HttpRequests Module Wrappers" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$httpFunctions = @('Invoke-GcRequest', 'Invoke-GcPagedRequest', 'Invoke-AppGcRequest', 'Set-GcAppState')
foreach ($fnName in $httpFunctions) {
  $fn = Get-Command -Name $fnName -ErrorAction SilentlyContinue
  if ($fn) {
    Write-Host "  [PASS] $fnName exists" -ForegroundColor Green
    $testsPassed++
  } else {
    Write-Host "  [FAIL] $fnName not found" -ForegroundColor Red
    $testsFailed++
  }
}

# Test 5: Verify ArtifactGenerator properly passes parameters
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 5: ArtifactGenerator Module" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Import-Module (Join-Path -Path $coreRoot -ChildPath 'ArtifactGenerator.psm1') -Force

$artifactFunctions = @(
  @{ Function = 'Export-GcConversationPacket'; Params = @('AccessToken', 'Region') }
)

foreach ($testCase in $artifactFunctions) {
  if (Test-FunctionParameters -ModuleName 'ArtifactGenerator' -FunctionName $testCase.Function -RequiredParameters $testCase.Params) {
    Write-Host "  [PASS] ArtifactGenerator::$($testCase.Function) has required parameters" -ForegroundColor Green
    $testsPassed++
  } else {
    $testsFailed++
  }
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Parameter Flow Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

if ($testsFailed -eq 0) {
  Write-Host "================================" -ForegroundColor Green
  Write-Host "    ✓ ALL TESTS PASSED" -ForegroundColor Green
  Write-Host "================================" -ForegroundColor Green
  exit 0
} else {
  Write-Host "================================" -ForegroundColor Red
  Write-Host "    ✗ TESTS FAILED" -ForegroundColor Red
  Write-Host "================================" -ForegroundColor Red
  exit 1
}
