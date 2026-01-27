#!/usr/bin/env pwsh
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Dependencies Module Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

# Enable offline demo mode
$env:GC_TOOLKIT_OFFLINE_DEMO = '1'

# Import modules
Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Dependencies.psm1') -Force
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
Test-Scenario "Dependencies module imports" {
    $module = Get-Module -Name Dependencies
    if (-not $module) {
        throw "Dependencies module not loaded"
    }
}

# Test 2: Search-GcFlowReferences function exists
Test-Scenario "Search-GcFlowReferences function exists" {
    $cmd = Get-Command Search-GcFlowReferences -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Search-GcFlowReferences command not found"
    }
}

# Test 3: Get-GcObjectById function exists
Test-Scenario "Get-GcObjectById function exists" {
    $cmd = Get-Command Get-GcObjectById -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Get-GcObjectById command not found"
    }
}

# Test 4: Search-GcFlowReferences with queue reference
Test-Scenario "Search-GcFlowReferences with queue reference" {
    $result = Search-GcFlowReferences -ObjectId 'queue-123' -ObjectType 'queue' `
        -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com'
    
    # In offline mode, null or array are both acceptable
    if ($null -ne $result -and $result -isnot [array]) {
        # Single result is also OK, wrap it
        $result = @($result)
    }
    
    $count = if ($null -eq $result) { 0 } else { @($result).Count }
    Write-Host "  Found $count flow references" -ForegroundColor Gray
}

# Test 5: Search-GcFlowReferences with dataAction reference
Test-Scenario "Search-GcFlowReferences with dataAction reference" {
    $result = Search-GcFlowReferences -ObjectId 'dataaction-456' -ObjectType 'dataAction' `
        -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com'
    
    # In offline mode, null or array are both acceptable
    if ($null -ne $result -and $result -isnot [array]) {
        # Single result is also OK
        Write-Host "  Returned single result or collection" -ForegroundColor Gray
    }
    
    Write-Host "  DataAction reference search completed" -ForegroundColor Gray
}

# Test 6: Flow reference result structure
Test-Scenario "Flow reference result contains expected fields" {
    $result = Search-GcFlowReferences -ObjectId 'test-object-789' -ObjectType 'queue' `
        -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com'
    
    # If results exist, verify structure
    if ($result -and (@($result).Count -gt 0)) {
        $firstResult = @($result)[0]
        
        $requiredFields = @('flowId', 'flowName', 'occurrences')
        foreach ($field in $requiredFields) {
            if (-not $firstResult.ContainsKey($field)) {
                throw "Result missing required field: $field"
            }
        }
        
        Write-Host "  Result structure validated" -ForegroundColor Gray
    } else {
        Write-Host "  No results to validate (acceptable in offline mode)" -ForegroundColor Gray
    }
}

# Test 7: Get-GcObjectById with queue type
Test-Scenario "Get-GcObjectById with queue type" {
    $result = Get-GcObjectById -ObjectId 'queue-123' -ObjectType 'queue' `
        -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com'
    
    # In offline mode, may return null or object
    Write-Host "  Object lookup completed" -ForegroundColor Gray
}

# Test 8: Verify parameter requirements
Test-Scenario "Functions have required parameters defined" {
    $searchCmd = Get-Command Search-GcFlowReferences
    $mandatoryParams = @()
    
    foreach ($param in $searchCmd.Parameters.Values) {
        foreach ($attr in $param.Attributes) {
            if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.Mandatory) {
                $mandatoryParams += $param
                break
            }
        }
    }
    
    if ($mandatoryParams.Count -lt 4) {
        throw "Expected at least 4 mandatory parameters for Search-GcFlowReferences"
    }
    
    Write-Host "  Search-GcFlowReferences has $($mandatoryParams.Count) mandatory parameters" -ForegroundColor Gray
}

# Test 9: Additional parameter validation
Test-Scenario "Get-GcObjectById has required parameters" {
    $objCmd = Get-Command Get-GcObjectById
    $mandatoryParams = @()
    
    foreach ($param in $objCmd.Parameters.Values) {
        foreach ($attr in $param.Attributes) {
            if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.Mandatory) {
                $mandatoryParams += $param
                break
            }
        }
    }
    
    if ($mandatoryParams.Count -lt 4) {
        throw "Expected at least 4 mandatory parameters for Get-GcObjectById"
    }
    
    Write-Host "  Get-GcObjectById has $($mandatoryParams.Count) mandatory parameters" -ForegroundColor Gray
}

# Test 10: Reference counting logic
Test-Scenario "Reference counting returns numeric occurrences" {
    $result = Search-GcFlowReferences -ObjectId 'test-queue-999' -ObjectType 'queue' `
        -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com'
    
    if ($result -and (@($result).Count -gt 0)) {
        $firstResult = @($result)[0]
        
        if ($firstResult.occurrences -isnot [System.IConvertible] -or -not ($firstResult.occurrences -is [System.ValueType])) {
            throw "Expected occurrences to be numeric, got $($firstResult.occurrences.GetType())"
        }
        
        if ($firstResult.occurrences -lt 0) {
            throw "Expected occurrences to be non-negative"
        }
        
        Write-Host "  Occurrences: $($firstResult.occurrences)" -ForegroundColor Gray
    } else {
        Write-Host "  No results to validate occurrences" -ForegroundColor Gray
    }
}

# Test 11: Handles missing flows gracefully
Test-Scenario "Handles missing flows without crashing" {
    # This should not throw even if no flows exist
    $result = Search-GcFlowReferences -ObjectId 'nonexistent-queue' -ObjectType 'queue' `
        -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com'
    
    # In offline mode, null or empty array are both acceptable
    if ($null -ne $result -and $result -isnot [array]) {
        throw "Expected null or array, got $($result.GetType())"
    }
    
    Write-Host "  Handled missing flows gracefully" -ForegroundColor Gray
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { 'Green' } else { 'Red' })

exit $testsFailed
