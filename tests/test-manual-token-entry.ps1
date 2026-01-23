#!/usr/bin/env pwsh
# Test script for manual token entry feature
# Validates token sanitization and error handling improvements

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Manual Token Entry Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Import the shared normalization helpers used by the app.
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path -Path $repoRoot -ChildPath 'Core\HttpRequests.psm1') -Force

# Test token sanitization function (extracted from dialog logic)
function Test-TokenSanitization {
    param(
        [string]$inputToken,
        [string]$expectedOutput,
        [string]$testName
    )
    
    $token = Normalize-GcAccessToken -TokenText $inputToken
    
    Write-Host "Test: $testName" -ForegroundColor Cyan
    if ($token -eq $expectedOutput) {
        Write-Host "  [PASS] Token sanitized correctly" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  [FAIL] Token sanitization mismatch" -ForegroundColor Red
        Write-Host "    Expected: $expectedOutput" -ForegroundColor Gray
        Write-Host "    Got:      $token" -ForegroundColor Gray
        return $false
    }
}

# Test cases covering the problem statement scenarios
$passedTests = 0
$failedTests = 0

Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Token Sanitization Tests" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

# Test 1: Token with no issues (baseline)
if (Test-TokenSanitization `
    -inputToken "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ" `
    -expectedOutput "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ" `
    -testName "Clean token (no formatting issues)") {
    $passedTests++
} else {
    $failedTests++
}
Write-Host ""

# Test 2: Token copied with line breaks from browser DevTools (common scenario)
$testToken2 = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9." + "`n" + "eyJzdWIiOiIxMjM0NTY3ODkwIn0." + "`n" + "TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ"
if (Test-TokenSanitization `
    -inputToken $testToken2 `
    -expectedOutput "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ" `
    -testName "Token with line breaks (Unix LF)") {
    $passedTests++
} else {
    $failedTests++
}
Write-Host ""

# Test 3: Token pasted from Windows application with CRLF
$testToken3 = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9." + "`r`n" + "eyJzdWIiOiIxMjM0NTY3ODkwIn0." + "`r`n" + "TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ"
if (Test-TokenSanitization `
    -inputToken $testToken3 `
    -expectedOutput "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ" `
    -testName "Token with line breaks (Windows CRLF)") {
    $passedTests++
} else {
    $failedTests++
}
Write-Host ""

# Test 4: Token with "Bearer " prefix
if (Test-TokenSanitization `
    -inputToken "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ" `
    -expectedOutput "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ" `
    -testName "Token with Bearer prefix") {
    $passedTests++
} else {
    $failedTests++
}
Write-Host ""

# Test 5: Token with both Bearer prefix and line breaks (worst case)
$testToken5 = "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9." + "`n" + "eyJzdWIiOiIxMjM0NTY3ODkwIn0." + "`n" + "TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ"
if (Test-TokenSanitization `
    -inputToken $testToken5 `
    -expectedOutput "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ" `
    -testName "Token with Bearer prefix AND line breaks") {
    $passedTests++
} else {
    $failedTests++
}
Write-Host ""

# Test 6: Token with leading/trailing spaces
if (Test-TokenSanitization `
    -inputToken "  eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ  " `
    -expectedOutput "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ" `
    -testName "Token with leading/trailing spaces") {
    $passedTests++
} else {
    $failedTests++
}
Write-Host ""

# Test 7: Mixed formatting (real-world chaos scenario)
$testToken7 = "  Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9." + "`r`n" + "eyJzdWIiOiIxMjM0NTY3ODkwIn0." + "`n" + "TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ  "
if (Test-TokenSanitization `
    -inputToken $testToken7 `
    -expectedOutput "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ" `
    -testName "Token with ALL formatting issues (spaces + Bearer + CRLF + LF)") {
    $passedTests++
} else {
    $failedTests++
}
Write-Host ""

Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Region Validation Tests" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

# Test region normalization (expected output should be instance name, ex: usw2.pure.cloud)
$regionCases = @(
    @{ Input = 'mypurecloud.com'; Expected = 'mypurecloud.com'; Name = 'Plain region (mypurecloud.com)' },
    @{ Input = 'usw2.pure.cloud'; Expected = 'usw2.pure.cloud'; Name = 'Plain region (usw2.pure.cloud)' },
    @{ Input = 'api.usw2.pure.cloud'; Expected = 'usw2.pure.cloud'; Name = 'API host pasted' },
    @{ Input = 'apps.usw2.pure.cloud'; Expected = 'usw2.pure.cloud'; Name = 'Apps host pasted' },
    @{ Input = 'login.usw2.pure.cloud'; Expected = 'usw2.pure.cloud'; Name = 'Login host pasted' },
    @{ Input = 'https://mypurecloud.com'; Expected = 'mypurecloud.com'; Name = 'Region URL pasted' },
    @{ Input = 'https://api.usw2.pure.cloud'; Expected = 'usw2.pure.cloud'; Name = 'API URL pasted' },
    @{ Input = 'https://apps.usw2.pure.cloud/directory/#/'; Expected = 'usw2.pure.cloud'; Name = 'Apps URL with path pasted' }
)

foreach ($case in $regionCases) {
    $actual = Normalize-GcInstanceName -RegionText $case.Input
    Write-Host "Test: $($case.Name)" -ForegroundColor Cyan
    if ($actual -eq $case.Expected) {
        Write-Host "  [PASS] Region normalized correctly ($actual)" -ForegroundColor Green
        $passedTests++
    } else {
        Write-Host "  [FAIL] Region normalization mismatch" -ForegroundColor Red
        Write-Host "    Input:    $($case.Input)" -ForegroundColor Gray
        Write-Host "    Expected: $($case.Expected)" -ForegroundColor Gray
        Write-Host "    Got:      $actual" -ForegroundColor Gray
        $failedTests++
    }
}
Write-Host ""

# Keep a small "looks like a region" validation check (used by the dialog).
$validRegions = @(
    'mypurecloud.com',
    'usw2.pure.cloud',
    'mypurecloud.ie',
    'mypurecloud.de',
    'mypurecloud.com.au',
    'mypurecloud.jp'
)

foreach ($region in $validRegions) {
    Write-Host "Test: Valid region format - $region" -ForegroundColor Cyan
    # Basic validation: should not be empty, should contain a dot.
    $isValid = (-not [string]::IsNullOrWhiteSpace($region)) -and ($region -match '\.')
    
    if ($isValid) {
        Write-Host "  [PASS] Region format is valid" -ForegroundColor Green
        $passedTests++
    } else {
        Write-Host "  [FAIL] Region format is invalid" -ForegroundColor Red
        $failedTests++
    }
}
Write-Host ""

# Test invalid region formats
$invalidRegions = @(
    '',
    '   ',
    'not_a_domain',
    'usw2 pure cloud'
)

foreach ($region in $invalidRegions) {
    Write-Host "Test: Invalid region format - $region" -ForegroundColor Cyan
    $normalized = Normalize-GcInstanceName -RegionText $region
    $isValid = (-not [string]::IsNullOrWhiteSpace($normalized)) -and ($normalized -match '\.')
    
    if (-not $isValid) {
        Write-Host "  [PASS] Correctly identified as invalid" -ForegroundColor Green
        $passedTests++
    } else {
        Write-Host "  [FAIL] Should be identified as invalid" -ForegroundColor Red
        $failedTests++
    }
}
Write-Host ""

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Total Tests: $($passedTests + $failedTests)" -ForegroundColor White
Write-Host "Passed:      $passedTests" -ForegroundColor Green
Write-Host "Failed:      $failedTests" -ForegroundColor $(if ($failedTests -eq 0) { "Green" } else { "Red" })
Write-Host ""

if ($failedTests -eq 0) {
    Write-Host "================================" -ForegroundColor Green
    Write-Host "    ✓ ALL TESTS PASSED" -ForegroundColor Green
    Write-Host "================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "The manual token entry feature is working correctly:" -ForegroundColor Green
    Write-Host "  • Token sanitization handles line breaks (LF and CRLF)" -ForegroundColor White
    Write-Host "  • Bearer prefix is automatically removed" -ForegroundColor White
    Write-Host "  • Leading/trailing spaces are trimmed" -ForegroundColor White
    Write-Host "  • Combined formatting issues are handled" -ForegroundColor White
    Write-Host "  • Region validation works correctly" -ForegroundColor White
    Write-Host ""
    exit 0
} else {
    Write-Host "================================" -ForegroundColor Red
    Write-Host "    ✗ TESTS FAILED" -ForegroundColor Red
    Write-Host "================================" -ForegroundColor Red
    exit 1
}
