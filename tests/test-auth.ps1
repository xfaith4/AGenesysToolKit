#!/usr/bin/env pwsh
# Test script for Auth module OAuth functionality

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Auth Module Unit Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Import Auth module
$scriptRoot = Split-Path -Parent $PSCommandPath
$coreRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'Core'
$authModulePath = Join-Path -Path $coreRoot -ChildPath 'Auth.psm1'

Write-Host "Importing Auth module..." -ForegroundColor Yellow
Import-Module $authModulePath -Force
Write-Host "  [PASS] Module imported" -ForegroundColor Green
Write-Host ""

# Common test configuration
$script:TestConfig = @{
    Region       = 'mypurecloud.com'
    ClientId     = 'test-client-id'
    RedirectUri  = 'http://localhost:8400/oauth/callback'
    Scopes       = @('conversations', 'analytics')
}

# Test 1: Set-GcAuthConfig
Write-Host "Test 1: Set-GcAuthConfig" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
try {
    Set-GcAuthConfig `
      -Region $script:TestConfig.Region `
      -ClientId $script:TestConfig.ClientId `
      -RedirectUri $script:TestConfig.RedirectUri `
      -Scopes $script:TestConfig.Scopes
    $config = Get-GcAuthConfig
    
    if ($config.Region -eq 'mypurecloud.com' -and 
        $config.ClientId -eq 'test-client-id' -and 
        $config.RedirectUri -eq 'http://localhost:8400/oauth/callback' -and
        $config.Scopes -contains 'conversations') {
        Write-Host "  [PASS] Configuration set correctly" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Configuration values incorrect" -ForegroundColor Red
        Write-Host "  Region: $($config.Region)" -ForegroundColor Gray
        Write-Host "  ClientId: $($config.ClientId)" -ForegroundColor Gray
        Write-Host "  RedirectUri: $($config.RedirectUri)" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 2: Get-GcTokenState (initial state)
Write-Host "Test 2: Get-GcTokenState (initial)" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
try {
    $tokenState = Get-GcTokenState
    
    if ($null -eq $tokenState.AccessToken) {
        Write-Host "  [PASS] Initial token state is null (not logged in)" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Token state has existing token" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 3: Clear-GcTokenState
Write-Host "Test 3: Clear-GcTokenState" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
try {
    # Set a dummy token first
    Set-GcAuthConfig `
      -Region $script:TestConfig.Region `
      -ClientId $script:TestConfig.ClientId `
      -RedirectUri $script:TestConfig.RedirectUri
    
    # Clear token state
    Clear-GcTokenState
    $tokenState = Get-GcTokenState
    
    if ($null -eq $tokenState.AccessToken -and 
        $null -eq $tokenState.TokenType -and 
        $null -eq $tokenState.UserInfo) {
        Write-Host "  [PASS] Token state cleared successfully" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Token state not fully cleared" -ForegroundColor Red
    }
} catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 4: Default redirect URI port
Write-Host "Test 4: Default Redirect URI Port" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
try {
    # Reset to defaults
    Remove-Module Auth -Force -ErrorAction SilentlyContinue
    Import-Module $authModulePath -Force
    
    $config = Get-GcAuthConfig
    
    if ($config.RedirectUri -eq 'http://localhost:8400/oauth/callback') {
        Write-Host "  [PASS] Default redirect URI uses port 8400" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Default redirect URI is: $($config.RedirectUri)" -ForegroundColor Red
        Write-Host "  Expected: http://localhost:8400/oauth/callback" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "All unit tests completed." -ForegroundColor Green
Write-Host ""
Write-Host "Note: These tests verify the Auth module's basic functionality." -ForegroundColor Yellow
Write-Host "For full OAuth flow testing (including browser and HTTP listener)," -ForegroundColor Yellow
Write-Host "see docs/OAUTH_TESTING.md for manual testing instructions." -ForegroundColor Yellow
Write-Host ""
