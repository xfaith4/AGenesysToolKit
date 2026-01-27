#!/usr/bin/env pwsh
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Analytics Module Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

# Enable offline demo mode
$env:GC_TOOLKIT_OFFLINE_DEMO = '1'

# Import modules
Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Analytics.psm1') -Force
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
Test-Scenario "Analytics module imports" {
    $module = Get-Module -Name Analytics
    if (-not $module) {
        throw "Analytics module not loaded"
    }
}

# Test 2: Get-GcAbandonmentMetrics function exists
Test-Scenario "Get-GcAbandonmentMetrics function exists" {
    $cmd = Get-Command Get-GcAbandonmentMetrics -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Get-GcAbandonmentMetrics command not found"
    }
}

# Test 3: Get-GcAbandonmentMetrics with offline mode
Test-Scenario "Get-GcAbandonmentMetrics with offline data" {
    $startTime = (Get-Date).AddHours(-1)
    $endTime = Get-Date
    
    # Call with dummy credentials (offline mode will mock the response)
    $result = Get-GcAbandonmentMetrics -StartTime $startTime -EndTime $endTime `
        -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com'
    
    if (-not $result) {
        throw "Expected result object, got null"
    }
    
    # Verify result structure
    if (-not $result.ContainsKey('abandonmentRate')) {
        throw "Result missing abandonmentRate field"
    }
    
    if (-not $result.ContainsKey('totalOffered')) {
        throw "Result missing totalOffered field"
    }
    
    Write-Host "  Abandonment rate: $($result.abandonmentRate)%" -ForegroundColor Gray
}

# Test 4: Abandonment rate calculation logic (zero offered)
Test-Scenario "Abandonment rate calculation with zero offered" {
    # This tests the zero-division handling in the module
    # When no calls are offered, rate should be 0
    $result = Get-GcAbandonmentMetrics `
        -StartTime (Get-Date).AddHours(-1) `
        -EndTime (Get-Date) `
        -AccessToken 'dummy-token' `
        -InstanceName 'mypurecloud.com'
    
    # The offline mode might return data, but the calculation should handle zeros
    if ($result.totalOffered -eq 0) {
        if ($result.abandonmentRate -ne 0) {
            throw "Expected abandonment rate to be 0 when no calls offered"
        }
    }
}

# Test 5: Result contains expected fields
Test-Scenario "Result contains all expected fields" {
    $result = Get-GcAbandonmentMetrics `
        -StartTime (Get-Date).AddHours(-1) `
        -EndTime (Get-Date) `
        -AccessToken 'dummy-token' `
        -InstanceName 'mypurecloud.com'
    
    $requiredFields = @('abandonmentRate', 'totalOffered', 'totalAbandoned', 'avgWaitTime', 'avgHandleTime', 'byQueue')
    
    foreach ($field in $requiredFields) {
        if (-not $result.ContainsKey($field)) {
            throw "Result missing required field: $field"
        }
    }
}

# Test 6: Verify parameter requirements (mandatory params exist)
Test-Scenario "Function has required parameters defined" {
    $cmd = Get-Command Get-GcAbandonmentMetrics
    $mandatoryParams = @()
    
    foreach ($param in $cmd.Parameters.Values) {
        foreach ($attr in $param.Attributes) {
            if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.Mandatory) {
                $mandatoryParams += $param
                break
            }
        }
    }
    
    if ($mandatoryParams.Count -lt 4) {
        throw "Expected at least 4 mandatory parameters, found $($mandatoryParams.Count)"
    }
    
    Write-Host "  Found $($mandatoryParams.Count) mandatory parameters" -ForegroundColor Gray
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { 'Green' } else { 'Red' })

exit $testsFailed
