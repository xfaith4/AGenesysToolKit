#!/usr/bin/env pwsh
# Runs the full automated test suite and writes a local log under ./artifacts/.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path -Path $repoRoot -ChildPath 'artifacts'
New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path -Path $artifactsRoot -ChildPath ("test-run-{0}.log" -f $stamp)

$env:GC_TOOLKIT_TRACE = '1'
$env:GC_TOOLKIT_TRACE_LOG = $logPath

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "AGenesysToolKit Full Test Run" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("Log: {0}" -f $logPath) -ForegroundColor Gray
Write-Host ""

function Write-RunLog {
  param([Parameter(Mandatory)][string]$Line)
  $ts = (Get-Date).ToString('HH:mm:ss.fff')
  $l = "[{0}] {1}" -f $ts, $Line
  Add-Content -LiteralPath $logPath -Value $l -Encoding utf8
}

$testFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File |
  Where-Object { $_.Name -ne 'run-all.ps1' } |
  Sort-Object -Property Name

$results = New-Object System.Collections.Generic.List[object]

foreach ($t in $testFiles) {
  $name = $t.Name
  Write-Host ("=== {0} ===" -f $name) -ForegroundColor Yellow
  Write-RunLog ("BEGIN {0}" -f $name)

  $output = & pwsh -NoProfile -File $t.FullName 2>&1
  $exit = $LASTEXITCODE

  foreach ($line in @($output)) {
    $s = [string]$line
    if ($s) { Write-RunLog ("{0}: {1}" -f $name, $s) }
  }

  if ($exit -eq 0) {
    Write-Host ("PASS {0}" -f $name) -ForegroundColor Green
    Write-RunLog ("END {0} PASS" -f $name)
  } else {
    Write-Host ("FAIL {0} (exit={1})" -f $name, $exit) -ForegroundColor Red
    Write-RunLog ("END {0} FAIL exit={1}" -f $name, $exit)
  }

  $results.Add([pscustomobject]@{ Name = $name; ExitCode = $exit }) | Out-Null
  Write-Host ""
}

$failed = @($results | Where-Object { $_.ExitCode -ne 0 })

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("Total: {0}" -f $results.Count) -ForegroundColor Gray
Write-Host ("Passed: {0}" -f ($results.Count - $failed.Count)) -ForegroundColor Green
$failColor = if ($failed.Count -eq 0) { 'Green' } else { 'Red' }
Write-Host ("Failed: {0}" -f $failed.Count) -ForegroundColor $failColor

if ($failed.Count -gt 0) {
  Write-Host ""
  Write-Host "Failed tests:" -ForegroundColor Red
  foreach ($f in $failed) { Write-Host ("- {0} (exit={1})" -f $f.Name, $f.ExitCode) -ForegroundColor Red }
}

Write-Host ""
Write-Host ("Log written to: {0}" -f $logPath) -ForegroundColor Gray

if ($failed.Count -gt 0) { exit 1 }
exit 0

