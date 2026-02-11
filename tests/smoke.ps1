### BEGIN: tests/smoke.ps1
# Smoke Test: Verify core modules load and key commands exist
# Runs on PowerShell 5.1 and PowerShell 7+

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "AGenesysToolKit Smoke Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Determine script root
$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot

Write-Host "Repository root: $repoRoot" -ForegroundColor Gray
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host ""

# Test counter
$testsPassed = 0
$testsFailed = 0

function Test-Module {
    param(
        [string]$ModulePath,
        [string]$ModuleName
    )
    
    Write-Host "Testing module: $ModuleName" -ForegroundColor Yellow
    
    try {
        # Check if file exists
        if (-not (Test-Path $ModulePath)) {
            Write-Host "  [FAIL] Module file not found: $ModulePath" -ForegroundColor Red
            return $false
        }
        
        # Try to import module
        Import-Module $ModulePath -Force -ErrorAction Stop
        Write-Host "  [PASS] Module loaded successfully" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "  [FAIL] Module failed to load: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Test-Command {
    param(
        [string]$CommandName
    )
    
    Write-Host "Testing command: $CommandName" -ForegroundColor Yellow
    
    try {
        $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            Write-Host "  [FAIL] Command not found: $CommandName" -ForegroundColor Red
            return $false
        }
        
        Write-Host "  [PASS] Command exists: $CommandName" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "  [FAIL] Error checking command: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Test 1: Core/HttpRequests.psm1
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 1: Core/HttpRequests.psm1" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$httpRequestsPath = Join-Path $repoRoot "Core/HttpRequests.psm1"
if (Test-Module -ModulePath $httpRequestsPath -ModuleName "HttpRequests") {
    $testsPassed++
} else {
    $testsFailed++
}
Write-Host ""

# Test 2: Core/Jobs.psm1
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 2: Core/Jobs.psm1" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$jobsPath = Join-Path $repoRoot "Core/Jobs.psm1"
if (Test-Module -ModulePath $jobsPath -ModuleName "Jobs") {
    $testsPassed++
} else {
    $testsFailed++
}
Write-Host ""

# Test 3: Verify Invoke-GcRequest command exists
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 3: Invoke-GcRequest Command" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
if (Test-Command -CommandName "Invoke-GcRequest") {
    $testsPassed++
} else {
    $testsFailed++
}
Write-Host ""

# Test 4: Verify Invoke-GcPagedRequest command exists
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 4: Invoke-GcPagedRequest Command" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
if (Test-Command -CommandName "Invoke-GcPagedRequest") {
    $testsPassed++
} else {
    $testsFailed++
}
Write-Host ""

# Test 5: Verify Wait-GcAsyncJob command exists
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 5: Wait-GcAsyncJob Command" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
if (Test-Command -CommandName "Wait-GcAsyncJob") {
    $testsPassed++
} else {
    $testsFailed++
}
Write-Host ""

# Test 6: Core/Auth.psm1
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 6: Core/Auth.psm1" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$authPath = Join-Path $repoRoot "Core/Auth.psm1"
if (Test-Module -ModulePath $authPath -ModuleName "Auth") {
    $testsPassed++
} else {
    $testsFailed++
}
Write-Host ""

# Test 7: Core/JobRunner.psm1
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 7: Core/JobRunner.psm1" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$jobRunnerPath = Join-Path $repoRoot "Core/JobRunner.psm1"
if (Test-Module -ModulePath $jobRunnerPath -ModuleName "JobRunner") {
    $testsPassed++
} else {
    $testsFailed++
}
Write-Host ""

# Test 8: Core/Subscriptions.psm1
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 8: Core/Subscriptions.psm1" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$subscriptionsPath = Join-Path $repoRoot "Core/Subscriptions.psm1"
if (Test-Module -ModulePath $subscriptionsPath -ModuleName "Subscriptions") {
    $testsPassed++
} else {
    $testsFailed++
}
Write-Host ""

# Test 9: Core/Timeline.psm1
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 9: Core/Timeline.psm1" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$timelinePath = Join-Path $repoRoot "Core/Timeline.psm1"
if (Test-Module -ModulePath $timelinePath -ModuleName "Timeline") {
    $testsPassed++
} else {
    $testsFailed++
}
Write-Host ""

# Test 10: Core/ArtifactGenerator.psm1
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test 10: Core/ArtifactGenerator.psm1" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$artifactGenPath = Join-Path $repoRoot "Core/ArtifactGenerator.psm1"
if (Test-Module -ModulePath $artifactGenPath -ModuleName "ArtifactGenerator") {
    $testsPassed++
} else {
    $testsFailed++
}
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Smoke Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { "Green" } else { "Red" })
Write-Host ""

if ($testsFailed -eq 0) {
    Write-Host "================================" -ForegroundColor Green
    Write-Host "    [PASS] SMOKE PASS" -ForegroundColor Green
    Write-Host "================================" -ForegroundColor Green
    Write-Host ""
    exit 0
} else {
    Write-Host "================================" -ForegroundColor Red
    Write-Host "    [FAIL] SMOKE FAIL" -ForegroundColor Red
    Write-Host "================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}

### END: tests/smoke.ps1

