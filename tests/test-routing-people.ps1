#!/usr/bin/env pwsh
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "RoutingPeople Module Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

# Enable offline demo mode
$env:GC_TOOLKIT_OFFLINE_DEMO = '1'

# Import modules
Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'RoutingPeople.psm1') -Force
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
Test-Scenario "RoutingPeople module imports" {
    $module = Get-Module -Name RoutingPeople
    if (-not $module) {
        throw "RoutingPeople module not loaded"
    }
}

# Test 2: Get-GcQueues function exists
Test-Scenario "Get-GcQueues function exists" {
    $cmd = Get-Command Get-GcQueues -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Get-GcQueues command not found"
    }
}

# Test 3: Get-GcSkills function exists
Test-Scenario "Get-GcSkills function exists" {
    $cmd = Get-Command Get-GcSkills -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Get-GcSkills command not found"
    }
}

# Test 4: Get-GcUsers function exists
Test-Scenario "Get-GcUsers function exists" {
    $cmd = Get-Command Get-GcUsers -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Get-GcUsers command not found"
    }
}

# Test 5: Get-GcUserPresence function exists
Test-Scenario "Get-GcUserPresence function exists" {
    $cmd = Get-Command Get-GcUserPresence -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Get-GcUserPresence command not found"
    }
}

# Test 6: Get-GcQueues with pagination
Test-Scenario "Get-GcQueues with offline data" {
    $result = Get-GcQueues -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com' -MaxItems 100
    
    if ($null -eq $result) {
        throw "Expected result, got null"
    }
    
    # In offline mode, should return array (could be empty)
    if ($result -isnot [array] -and $result -isnot [System.Collections.IEnumerable]) {
        # Single object is also acceptable
        Write-Host "  Returned single object or collection" -ForegroundColor Gray
    }
}

# Test 7: Get-GcSkills with pagination
Test-Scenario "Get-GcSkills with offline data" {
    $result = Get-GcSkills -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com' -MaxItems 100
    
    if ($null -eq $result) {
        throw "Expected result, got null"
    }
}

# Test 8: Get-GcUsers with pagination
Test-Scenario "Get-GcUsers with offline data" {
    $result = Get-GcUsers -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com' -MaxItems 100
    
    if ($null -eq $result) {
        throw "Expected result, got null"
    }
}

# Test 9: Get-GcUserPresence with offline data
Test-Scenario "Get-GcUserPresence with offline data" {
    $result = Get-GcUserPresence -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com'
    
    if ($null -eq $result) {
        throw "Expected result, got null"
    }
}

# Test 10: Verify parameter requirements
Test-Scenario "Functions have required parameters defined" {
    $queueCmd = Get-Command Get-GcQueues
    $mandatoryParams = @()
    
    foreach ($param in $queueCmd.Parameters.Values) {
        foreach ($attr in $param.Attributes) {
            if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.Mandatory) {
                $mandatoryParams += $param
                break
            }
        }
    }
    
    if ($mandatoryParams.Count -lt 2) {
        throw "Expected at least 2 mandatory parameters for Get-GcQueues"
    }
    
    Write-Host "  Get-GcQueues has $($mandatoryParams.Count) mandatory parameters" -ForegroundColor Gray
}

# Test 11: MaxItems parameter is respected
Test-Scenario "MaxItems parameter is accepted" {
    # Just verify the parameter is accepted, actual limiting is in Invoke-GcPagedRequest
    $result = Get-GcQueues -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com' -MaxItems 50
    
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
