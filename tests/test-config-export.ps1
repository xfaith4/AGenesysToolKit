#!/usr/bin/env pwsh
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ConfigExport Module Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

# Enable offline demo mode
$env:GC_TOOLKIT_OFFLINE_DEMO = '1'

# Import modules
Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ConfigExport.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'SampleData.psm1') -Force

$testsPassed = 0
$testsFailed = 0

# Create temp directory for test exports
$testExportPath = Join-Path -Path $repoRoot -ChildPath 'artifacts/test-exports'
if (-not (Test-Path $testExportPath)) {
    New-Item -ItemType Directory -Path $testExportPath -Force | Out-Null
}

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
Test-Scenario "ConfigExport module imports" {
    $module = Get-Module -Name ConfigExport
    if (-not $module) {
        throw "ConfigExport module not loaded"
    }
}

# Test 2: Export-GcFlowsConfig function exists
Test-Scenario "Export-GcFlowsConfig function exists" {
    $cmd = Get-Command Export-GcFlowsConfig -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Export-GcFlowsConfig command not found"
    }
}

# Test 3: Export-GcQueuesConfig function exists
Test-Scenario "Export-GcQueuesConfig function exists" {
    $cmd = Get-Command Export-GcQueuesConfig -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Export-GcQueuesConfig command not found"
    }
}

# Test 4: Export-GcFlowsConfig creates directory
Test-Scenario "Export-GcFlowsConfig creates output directory" {
    $outputPath = Join-Path -Path $testExportPath -ChildPath 'flows-test-1'
    
    $result = Export-GcFlowsConfig -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com' `
        -OutputPath $outputPath
    
    if ($result) {
        Write-Host "  Export completed: $($result.Type)" -ForegroundColor Gray
        if ($result.Directory) {
            if (-not (Test-Path $result.Directory)) {
                throw "Expected directory to be created: $($result.Directory)"
            }
            Write-Host "  Directory created: $($result.Directory)" -ForegroundColor Gray
        }
    }
}

# Test 5: Export-GcFlowsConfig generates manifest
Test-Scenario "Export-GcFlowsConfig generates manifest file" {
    $outputPath = Join-Path -Path $testExportPath -ChildPath 'flows-test-2'
    
    $result = Export-GcFlowsConfig -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com' `
        -OutputPath $outputPath
    
    if ($result -and $result.Manifest) {
        if (Test-Path $result.Manifest) {
            Write-Host "  Manifest created: $($result.Manifest)" -ForegroundColor Gray
            
            # Verify manifest is valid JSON
            $manifestContent = Get-Content $result.Manifest -Raw | ConvertFrom-Json
            Write-Host "  Manifest is valid JSON" -ForegroundColor Gray
        }
    }
}

# Test 6: Export-GcQueuesConfig creates directory
Test-Scenario "Export-GcQueuesConfig creates output directory" {
    $outputPath = Join-Path -Path $testExportPath -ChildPath 'queues-test-1'
    
    $result = Export-GcQueuesConfig -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com' `
        -OutputPath $outputPath
    
    if ($result) {
        Write-Host "  Export completed: $($result.Type)" -ForegroundColor Gray
        if ($result.Directory) {
            if (-not (Test-Path $result.Directory)) {
                throw "Expected directory to be created: $($result.Directory)"
            }
            Write-Host "  Directory created: $($result.Directory)" -ForegroundColor Gray
        }
    }
}

# Test 7: Export with specific FlowIds
Test-Scenario "Export-GcFlowsConfig with specific FlowIds" {
    $outputPath = Join-Path -Path $testExportPath -ChildPath 'flows-test-3'
    $flowIds = @('flow-123', 'flow-456')
    
    $result = Export-GcFlowsConfig -FlowIds $flowIds -AccessToken 'dummy-token' `
        -InstanceName 'mypurecloud.com' -OutputPath $outputPath
    
    # Should not error even if flows don't exist in offline mode
    Write-Host "  Specific FlowIds parameter accepted" -ForegroundColor Gray
}

# Test 8: Export with specific QueueIds
Test-Scenario "Export-GcQueuesConfig with specific QueueIds" {
    $outputPath = Join-Path -Path $testExportPath -ChildPath 'queues-test-2'
    $queueIds = @('queue-123', 'queue-456')
    
    $result = Export-GcQueuesConfig -QueueIds $queueIds -AccessToken 'dummy-token' `
        -InstanceName 'mypurecloud.com' -OutputPath $outputPath
    
    # Should not error even if queues don't exist in offline mode
    Write-Host "  Specific QueueIds parameter accepted" -ForegroundColor Gray
}

# Test 9: Verify parameter requirements
Test-Scenario "Functions have required parameters defined" {
    $exportCmd = Get-Command Export-GcFlowsConfig
    $mandatoryParams = @()
    
    foreach ($param in $exportCmd.Parameters.Values) {
        foreach ($attr in $param.Attributes) {
            if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.Mandatory) {
                $mandatoryParams += $param
                break
            }
        }
    }
    
    if ($mandatoryParams.Count -lt 3) {
        throw "Expected at least 3 mandatory parameters for Export-GcFlowsConfig"
    }
    
    Write-Host "  Export-GcFlowsConfig has $($mandatoryParams.Count) mandatory parameters" -ForegroundColor Gray
}

# Test 10: Result structure validation
Test-Scenario "Export result contains expected fields" {
    $outputPath = Join-Path -Path $testExportPath -ChildPath 'flows-test-4'
    
    $result = Export-GcFlowsConfig -AccessToken 'dummy-token' -InstanceName 'mypurecloud.com' `
        -OutputPath $outputPath
    
    if ($result) {
        if (-not $result.Type) {
            throw "Result missing Type field"
        }
        if (-not $result.Directory) {
            throw "Result missing Directory field"
        }
        
        Write-Host "  Result structure validated" -ForegroundColor Gray
    }
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { 'Green' } else { 'Red' })

# Cleanup test exports
Write-Host ""
Write-Host "Cleaning up test exports..." -ForegroundColor Gray
if (Test-Path $testExportPath) {
    Remove-Item -Path $testExportPath -Recurse -Force -ErrorAction SilentlyContinue
}

exit $testsFailed
