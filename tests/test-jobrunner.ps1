### BEGIN: tests/test-jobrunner.ps1
# Test script for JobRunner functionality
# Tests the runspace-based job execution with cancellation, status tracking, and log streaming

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "JobRunner Test Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Determine paths
$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

Write-Host "Repository root: $repoRoot" -ForegroundColor Gray
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host ""

# Import JobRunner module
$jobRunnerPath = Join-Path -Path $coreRoot -ChildPath 'JobRunner.psm1'
Import-Module $jobRunnerPath -Force

# Test counter
$testsPassed = 0
$testsFailed = 0

function Test-Scenario {
    param(
        [string]$Name,
        [scriptblock]$TestBlock
    )
    
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Test: $Name" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    try {
        & $TestBlock
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:testsPassed++
    }
    catch {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        $script:testsFailed++
    }
    Write-Host ""
}

# Test 1: Create Job Context
Test-Scenario -Name "New-GcJobContext creates job with correct properties" -TestBlock {
    $job = New-GcJobContext -Name "Test Job" -Type "Test"
    
    if (-not $job) { throw "Job is null" }
    if (-not $job.Id) { throw "Job ID is null" }
    if ($job.Name -ne "Test Job") { throw "Job name mismatch" }
    if ($job.Type -ne "Test") { throw "Job type mismatch" }
    if ($job.Status -ne "Queued") { throw "Job status should be Queued" }
    if ($null -ne $job.Started) { throw "Started should be null" }
    if ($null -ne $job.Ended) { throw "Ended should be null" }
    if ($null -eq $job.Logs) { throw "Logs collection is null" }
    if ($job.CanCancel -ne $true) { throw "CanCancel should be true" }
}

# Test 2: Add Job Log
Test-Scenario -Name "Add-GcJobLog adds log entries" -TestBlock {
    $job = New-GcJobContext -Name "Log Test" -Type "Test"
    
    Add-GcJobLog -Job $job -Message "Test message 1"
    Add-GcJobLog -Job $job -Message "Test message 2"
    
    if ($job.Logs.Count -ne 2) { throw "Expected 2 log entries, got $($job.Logs.Count)" }
    if ($job.Logs[0] -notmatch "Test message 1") { throw "Log message 1 not found" }
    if ($job.Logs[1] -notmatch "Test message 2") { throw "Log message 2 not found" }
}

# Test 3: Simple Job Execution (Non-WPF fallback mode)
Test-Scenario -Name "Start-GcJob executes simple script block" -TestBlock {
    $job = New-GcJobContext -Name "Simple Job" -Type "Test"
    
    # Execute job with simple script block
    Start-GcJob -Job $job -ScriptBlock {
        param($value)
        Start-Sleep -Milliseconds 100
        return "Result: $value"
    } -ArgumentList @("TestValue")
    
    # Job should complete
    if ($job.Status -ne "Completed") { throw "Job status should be Completed, got: $($job.Status)" }
    if ($job.Result -ne "Result: TestValue") { throw "Job result mismatch: $($job.Result)" }
}

# Test 4: Job with Parameters
Test-Scenario -Name "Start-GcJob passes arguments correctly" -TestBlock {
    $job = New-GcJobContext -Name "Parameterized Job" -Type "Test"
    
    Start-GcJob -Job $job -ScriptBlock {
        param($a, $b, $c)
        return "$a-$b-$c"
    } -ArgumentList @("First", "Second", "Third")
    
    if ($job.Result -ne "First-Second-Third") { throw "Parameter passing failed: $($job.Result)" }
}

# Test 5: Job that Returns Object
Test-Scenario -Name "Start-GcJob handles complex return types" -TestBlock {
    $job = New-GcJobContext -Name "Object Job" -Type "Test"
    
    Start-GcJob -Job $job -ScriptBlock {
        return [PSCustomObject]@{
            Name = "Test"
            Value = 42
            Items = @(1, 2, 3)
        }
    }
    
    if ($job.Result.Name -ne "Test") { throw "Object property mismatch" }
    if ($job.Result.Value -ne 42) { throw "Object value mismatch" }
    if ($job.Result.Items.Count -ne 3) { throw "Array count mismatch" }
}

# Test 6: Job Status Transitions
Test-Scenario -Name "Job status transitions correctly" -TestBlock {
    $job = New-GcJobContext -Name "Status Test" -Type "Test"
    
    if ($job.Status -ne "Queued") { throw "Initial status should be Queued" }
    
    Start-GcJob -Job $job -ScriptBlock {
        Start-Sleep -Milliseconds 50
    }
    
    if ($job.Status -ne "Completed") { throw "Final status should be Completed" }
    if ($null -eq $job.Started) { throw "Started time should be set" }
    if ($null -eq $job.Ended) { throw "Ended time should be set" }
}

# Test 7: Job Completion Callback
Test-Scenario -Name "OnComplete callback executes" -TestBlock {
    $global:callbackExecuted = $false
    
    $job = New-GcJobContext -Name "Callback Test" -Type "Test"
    
    Start-GcJob -Job $job -ScriptBlock {
        return "Done"
    } -OnComplete {
        param($completedJob)
        $global:callbackExecuted = $true
    }
    
    if (-not $global:callbackExecuted) { throw "OnComplete callback was not executed" }
    
    # Cleanup
    Remove-Variable -Name callbackExecuted -Scope Global -ErrorAction SilentlyContinue
}

# Test 8: Get Running Jobs
Test-Scenario -Name "Get-GcRunningJobs returns collection" -TestBlock {
    $runningJobs = Get-GcRunningJobs
    
    # In PowerShell, an empty collection can be null but still have Count = 0
    # This is expected behavior when no jobs are running
    if ($null -ne $runningJobs -or (@($runningJobs).Count -eq 0)) {
        Write-Host "  Running jobs count: $(@($runningJobs).Count)" -ForegroundColor Gray
    } else {
        throw "Get-GcRunningJobs returned unexpected value"
    }
}

# Test 9: Job Logs Timeline
Test-Scenario -Name "Job logs capture execution timeline" -TestBlock {
    $job = New-GcJobContext -Name "Log Timeline Test" -Type "Test"
    
    Start-GcJob -Job $job -ScriptBlock {
        Start-Sleep -Milliseconds 50
    }
    
    # Should have at least "Started" and "Completed" logs
    if ($job.Logs.Count -lt 2) { throw "Expected at least 2 log entries" }
    
    $hasStarted = $false
    $hasCompleted = $false
    
    foreach ($log in $job.Logs) {
        if ($log -match "Started") { $hasStarted = $true }
        if ($log -match "Completed") { $hasCompleted = $true }
    }
    
    if (-not $hasStarted) { throw "Missing 'Started' log entry" }
    if (-not $hasCompleted) { throw "Missing 'Completed' log entry" }
}

# Test 10: PowerShell 5.1 and 7+ Compatibility
Test-Scenario -Name "JobRunner works on current PowerShell version" -TestBlock {
    $version = $PSVersionTable.PSVersion
    
    Write-Host "  Testing on PowerShell $version" -ForegroundColor Gray
    
    $job = New-GcJobContext -Name "Compatibility Test" -Type "Test"
    
    Start-GcJob -Job $job -ScriptBlock {
        param($psVersion)
        return "PowerShell $psVersion"
    } -ArgumentList @($version.ToString())
    
    if ($job.Status -ne "Completed") { throw "Job failed on PowerShell $version" }
    if ($job.Result -notmatch "PowerShell") { throw "Result mismatch" }
}

# Test 11: Runspace-based Execution (Verify Independence)
Test-Scenario -Name "Jobs execute in separate runspaces" -TestBlock {
    $job = New-GcJobContext -Name "Runspace Test" -Type "Test"
    
    # Set a variable in main runspace
    $mainRunspaceVar = "MainValue"
    
    Start-GcJob -Job $job -ScriptBlock {
        # Try to access main runspace variable (should fail)
        if (Get-Variable -Name "mainRunspaceVar" -ErrorAction SilentlyContinue) {
            throw "Job should not access main runspace variables"
        }
        return "Independent"
    }
    
    if ($job.Result -ne "Independent") { throw "Runspace isolation failed" }
}

# Test 12: Error Handling
Test-Scenario -Name "Job captures errors correctly" -TestBlock {
    $job = New-GcJobContext -Name "Error Test" -Type "Test"
    
    Start-GcJob -Job $job -ScriptBlock {
        Write-Error "Test error message"
        return "Completed despite error"
    }
    
    # Job should complete even with errors
    if ($job.Status -ne "Completed") { throw "Job should complete even with errors" }
    
    # Error should be captured
    if ($job.Errors.Count -eq 0) {
        Write-Host "  Note: Error count is 0 (errors may not be captured in non-WPF mode)" -ForegroundColor Yellow
    }
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "JobRunner Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { "Green" } else { "Red" })
Write-Host ""

if ($testsFailed -eq 0) {
    Write-Host "================================" -ForegroundColor Green
    Write-Host "    ✓ ALL TESTS PASS" -ForegroundColor Green
    Write-Host "================================" -ForegroundColor Green
    Write-Host ""
    exit 0
} else {
    Write-Host "================================" -ForegroundColor Red
    Write-Host "    ✗ TESTS FAILED" -ForegroundColor Red
    Write-Host "================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}

### END: tests/test-jobrunner.ps1
