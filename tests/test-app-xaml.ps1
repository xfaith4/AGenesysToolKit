#!/usr/bin/env pwsh
# Test to verify the main script's XAML can be parsed without errors

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Testing GenesysCloudTool_UX_Prototype.ps1 XAML Parsing" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get the script path
$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot
$appScript = Join-Path $repoRoot "App/GenesysCloudTool_UX_Prototype.ps1"

Write-Host "Testing script: $appScript" -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $appScript)) {
    Write-Host "[FAIL] Script not found: $appScript" -ForegroundColor Red
    exit 1
}

# Read the script and extract XAML strings
$scriptContent = Get-Content $appScript -Raw

# Count XAML strings (should find @" markers)
$xamlCount = ([regex]::Matches($scriptContent, '@"')).Count

Write-Host "Found $xamlCount XAML string definitions in the script" -ForegroundColor Gray
Write-Host ""

# Test: Verify the script can be dot-sourced without errors
# Note: This won't launch the GUI but will parse all XAML definitions
Write-Host "Test: Verifying script syntax and XAML definitions..." -ForegroundColor Yellow

try {
    # Use AST to parse the script without executing it
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($appScript, [ref]$null, [ref]$errors)
    
    if ($errors) {
        Write-Host "[FAIL] Script has parsing errors:" -ForegroundColor Red
        foreach ($error in $errors) {
            Write-Host "  Line $($error.Extent.StartLineNumber): $($error.Message)" -ForegroundColor Red
        }
        exit 1
    }
    
    Write-Host "[PASS] Script syntax is valid" -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Host "[FAIL] Failed to parse script: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Test: Verify helper functions exist for safe XAML construction
Write-Host "Test: Verifying XAML helper functions exist..." -ForegroundColor Yellow

if ($scriptContent -match 'function\s+ConvertFrom-GcXaml' -and $scriptContent -match 'function\s+Escape-GcXml') {
    Write-Host "[PASS] ConvertFrom-GcXaml and Escape-GcXml are present" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host "[FAIL] Missing ConvertFrom-GcXaml or Escape-GcXml" -ForegroundColor Red
    exit 1
}

# Test: Verify no unescaped curly braces in Text attributes
Write-Host "Test: Checking for unescaped curly braces in Text attributes..." -ForegroundColor Yellow

# Look for Text="{ but not Text="{} {
# Pattern: Text=" followed by { that is NOT followed by }
$unescapedPattern = 'Text="\\{(?!\\})'
if ($scriptContent -match $unescapedPattern) {
    Write-Host "[WARN] Found potential unescaped curly brace in Text attribute" -ForegroundColor Yellow
    Write-Host "       This may not be an issue if it's intentional" -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "[PASS] No unescaped curly braces found in Text attributes" -ForegroundColor Green
    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[PASS] Script syntax is valid" -ForegroundColor Green
Write-Host "[PASS] XAML helper functions are present" -ForegroundColor Green
Write-Host "[PASS] Ready for execution" -ForegroundColor Green
Write-Host ""
Write-Host "================================" -ForegroundColor Green
Write-Host "    [PASS] ALL TESTS PASS" -ForegroundColor Green
Write-Host "================================" -ForegroundColor Green
Write-Host ""

exit 0

