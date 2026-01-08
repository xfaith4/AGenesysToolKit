### BEGIN: tests/test-xaml-helpers.ps1
# Test script for XAML helper functions
# Validates Escape-GcXml helper works correctly

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "XAML Helpers Test Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Test counter
$testsPassed = 0
$testsFailed = 0

# Define the helper function (same as in App script)
function Escape-GcXml {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  return [System.Security.SecurityElement]::Escape($Text)
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Suite: Escape-GcXml" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Test 1: Ampersand
Write-Host "Test 1: Ampersand (&)" -ForegroundColor Yellow
$input1 = "Routing & People"
$expected1 = "Routing &amp; People"
$result1 = Escape-GcXml -Text $input1
if ($result1 -eq $expected1) {
    Write-Host "  [PASS] '$input1' -> '$result1'" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "  [FAIL] Expected: '$expected1', Got: '$result1'" -ForegroundColor Red
    $testsFailed++
}
Write-Host ""

# Test 2: Less than
Write-Host "Test 2: Less than (<)" -ForegroundColor Yellow
$input2 = "Value < 10"
$expected2 = "Value &lt; 10"
$result2 = Escape-GcXml -Text $input2
if ($result2 -eq $expected2) {
    Write-Host "  [PASS] '$input2' -> '$result2'" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "  [FAIL] Expected: '$expected2', Got: '$result2'" -ForegroundColor Red
    $testsFailed++
}
Write-Host ""

# Test 3: Greater than
Write-Host "Test 3: Greater than (>)" -ForegroundColor Yellow
$input3 = "Value > 10"
$expected3 = "Value &gt; 10"
$result3 = Escape-GcXml -Text $input3
if ($result3 -eq $expected3) {
    Write-Host "  [PASS] '$input3' -> '$result3'" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "  [FAIL] Expected: '$expected3', Got: '$result3'" -ForegroundColor Red
    $testsFailed++
}
Write-Host ""

# Test 4: Double quote
Write-Host "Test 4: Double quote" -ForegroundColor Yellow
$input4 = 'Say "Hello"'
$expected4 = 'Say &quot;Hello&quot;'
$result4 = Escape-GcXml -Text $input4
if ($result4 -eq $expected4) {
    Write-Host "  [PASS] '$input4' -> '$result4'" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "  [FAIL] Expected: '$expected4', Got: '$result4'" -ForegroundColor Red
    $testsFailed++
}
Write-Host ""

# Test 5: Apostrophe
Write-Host "Test 5: Apostrophe" -ForegroundColor Yellow
$input5 = "It's working"
$expected5 = "It&apos;s working"
$result5 = Escape-GcXml -Text $input5
if ($result5 -eq $expected5) {
    Write-Host "  [PASS] '$input5' -> '$result5'" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "  [FAIL] Expected: '$expected5', Got: '$result5'" -ForegroundColor Red
    $testsFailed++
}
Write-Host ""

# Test 6: Empty string
Write-Host "Test 6: Empty string" -ForegroundColor Yellow
$input6 = ""
$expected6 = ""
$result6 = Escape-GcXml -Text $input6
if ($result6 -eq $expected6) {
    Write-Host "  [PASS] Empty string returns empty" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "  [FAIL] Expected empty, Got: '$result6'" -ForegroundColor Red
    $testsFailed++
}
Write-Host ""

# Test 7: Multiple special chars
Write-Host "Test 7: Multiple special chars" -ForegroundColor Yellow
$input7 = "A & B < C > D"
$expected7 = "A &amp; B &lt; C &gt; D"
$result7 = Escape-GcXml -Text $input7
if ($result7 -eq $expected7) {
    Write-Host "  [PASS] '$input7' -> '$result7'" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "  [FAIL] Expected: '$expected7', Got: '$result7'" -ForegroundColor Red
    $testsFailed++
}
Write-Host ""

# Test 8: Routing & People (realistic workspace name)
Write-Host "Test 8: Routing & People (workspace name)" -ForegroundColor Yellow
$input8 = "Routing & People"
$expected8 = "Routing &amp; People"
$result8 = Escape-GcXml -Text $input8
if ($result8 -eq $expected8) {
    Write-Host "  [PASS] Workspace name escaped correctly" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "  [FAIL] Expected: '$expected8', Got: '$result8'" -ForegroundColor Red
    $testsFailed++
}
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
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

### END: tests/test-xaml-helpers.ps1
