#!/usr/bin/env pwsh
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ConversationsExtended Module Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

# Enable offline demo mode
$env:GC_TOOLKIT_OFFLINE_DEMO = '1'

# Import modules
Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ConversationsExtended.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'SampleData.psm1') -Force

$testsPassed = 0
$testsFailed = 0

function Test-Scenario {
    param(
        [string]$Name,
        [scriptblock]$TestBlock
    )
    
    Write-Host "Test: $Name" -ForegroundColor Cyan
    try {
        & $TestBlock
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:testsPassed++
    } catch {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "  Error: $_" -ForegroundColor Red
        $script:testsFailed++
    }
    Write-Host ""
}

# Test 1: Module imports successfully
Test-Scenario "ConversationsExtended module imports" {
    $module = Get-Module -Name ConversationsExtended
    if (-not $module) {
        throw "ConversationsExtended module not loaded"
    }
}

# Test 2: Search-GcConversations function exists
Test-Scenario "Search-GcConversations function exists" {
    $cmd = Get-Command Search-GcConversations -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Search-GcConversations command not found"
    }
}

# Test 3: Get-GcConversationById function exists
Test-Scenario "Get-GcConversationById function exists" {
    $cmd = Get-Command Get-GcConversationById -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Get-GcConversationById command not found"
    }
}

# Test 4: Get-GcRecordings function exists
Test-Scenario "Get-GcRecordings function exists" {
    $cmd = Get-Command Get-GcRecordings -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Get-GcRecordings command not found"
    }
}

# Test 5: Get-GcQualityEvaluations function exists
Test-Scenario "Get-GcQualityEvaluations function exists" {
    $cmd = Get-Command Get-GcQualityEvaluations -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Get-GcQualityEvaluations command not found"
    }
}

# Test 6: Search-GcConversations with query body
Test-Scenario "Search-GcConversations with offline data" {
    $searchBody = @{
        interval = "2024-01-01T00:00:00.000Z/2024-01-02T00:00:00.000Z"
        order = "asc"
        orderBy = "conversationStart"
    }
    
    $result = Search-GcConversations -Body $searchBody -AccessToken 'dummy-token' `
        -InstanceName 'mypurecloud.com' -MaxItems 100
    
    if ($null -eq $result) {
        throw "Expected result, got null"
    }
}

# Test 7: Get-GcConversationById with specific ID
Test-Scenario "Get-GcConversationById with offline data" {
    $result = Get-GcConversationById -ConversationId 'test-conversation-123' `
        -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com'
    
    # In offline mode, should return something or null (both acceptable)
    Write-Host "  Conversation lookup completed" -ForegroundColor Gray
}

# Test 8: Get-GcRecordings with pagination
Test-Scenario "Get-GcRecordings with offline data" {
    $result = Get-GcRecordings -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com' -MaxItems 50
    
    if ($null -eq $result) {
        throw "Expected result, got null"
    }
}

# Test 9: Get-GcQualityEvaluations with pagination
Test-Scenario "Get-GcQualityEvaluations with offline data" {
    $result = Get-GcQualityEvaluations -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com' -MaxItems 50
    
    if ($null -eq $result) {
        throw "Expected result, got null"
    }
}

# Test 10: Verify parameter requirements
Test-Scenario "Functions have required parameters defined" {
    $searchCmd = Get-Command Search-GcConversations
    $mandatoryParams = @()
    
    foreach ($param in $searchCmd.Parameters.Values) {
        foreach ($attr in $param.Attributes) {
            if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.Mandatory) {
                $mandatoryParams += $param
                break
            }
        }
    }
    
    if ($mandatoryParams.Count -lt 3) {
        throw "Expected at least 3 mandatory parameters for Search-GcConversations"
    }
    
    Write-Host "  Search-GcConversations has $($mandatoryParams.Count) mandatory parameters" -ForegroundColor Gray
}

# Test 11: Verify parameter requirements  
Test-Scenario "Functions have required parameters defined" {
    $convCmd = Get-Command Get-GcConversationById
    $mandatoryParams = @()
    
    foreach ($param in $convCmd.Parameters.Values) {
        foreach ($attr in $param.Attributes) {
            if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.Mandatory) {
                $mandatoryParams += $param
                break
            }
        }
    }
    
    if ($mandatoryParams.Count -lt 3) {
        throw "Expected at least 3 mandatory parameters for Get-GcConversationById"
    }
    
    Write-Host "  Get-GcConversationById has $($mandatoryParams.Count) mandatory parameters" -ForegroundColor Gray
}

# Test 12: Pagination handling with MaxItems
Test-Scenario "MaxItems parameter is accepted in Search" {
    $searchBody = @{
        interval = "2024-01-01T00:00:00.000Z/2024-01-02T00:00:00.000Z"
    }
    
    $result = Search-GcConversations -Body $searchBody -AccessToken 'dummy-token' `
        -InstanceName 'mypurecloud.com' -MaxItems 25
    
    # No error means parameter was accepted
    Write-Host "  MaxItems parameter accepted" -ForegroundColor Gray
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { 'Green' } else { 'Red' })

exit $testsFailed
