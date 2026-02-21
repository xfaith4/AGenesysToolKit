# Patch-OfflineDemoButtons.ps1
# Enables primary action buttons when OfflineDemo is enabled OR AccessToken exists.
# Also removes a stray broken patch line inside Set-OfflineDemoMode (if present).
[CmdletBinding()]
param(
  [string]$Path = "G:\Development\20_Staging\AGenesysToolKit\App\GenesysCloudTool.ps1"
)

if (-not (Test-Path -LiteralPath $Path)) {
  throw "File not found: $Path"
}

$backup = "$Path.bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
Copy-Item -LiteralPath $Path -Destination $backup -Force
Write-Host "Backup created: $backup"

$lines = Get-Content -LiteralPath $Path -Encoding UTF8

# -----------------------------
# 1) Inject helpers once
# -----------------------------
$helperMarker = "### BEGIN: AUTH_READY_BUTTON_ENABLE_HELPERS"
if ($lines -notcontains $helperMarker) {

  $insertAfter = $null
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'function\s+Set-ControlEnabled\b') { $insertAfter = $i; break }
  }
  if ($null -eq $insertAfter) { throw "Could not find function Set-ControlEnabled in file." }

  # Find end of Set-ControlEnabled function by brace depth (line-wise)
  $depth = 0
  $foundOpen = $false
  for ($j = $insertAfter; $j -lt $lines.Count; $j++) {
    $line = $lines[$j]
    foreach ($ch in $line.ToCharArray()) {
      if ($ch -eq '{') { $depth++; $foundOpen = $true }
      elseif ($ch -eq '}') { $depth-- }
    }
    if ($foundOpen -and $depth -le 0) { $insertAfter = $j; break }
  }

  $helpers = @"
$helperMarker
function Test-AuthReady {
  # Auth-ready means we can let the UI do work:
  # - Offline demo mode is enabled (no real token required)
  # - OR a real token is present
  try {
    if (Get-Command Test-OfflineDemoEnabled -ErrorAction SilentlyContinue) {
      if (Test-OfflineDemoEnabled) { return $true }
    }
  } catch { }

  return (-not [string]::IsNullOrWhiteSpace($script:AppState.AccessToken))
}

function Enable-PrimaryActionButtons {
  param([hashtable]$Handles)

  if ($null -eq $Handles) { return }
  $canRun = Test-AuthReady

  # Only enable "primary actions" (Load/Search/Start/Query).
  # Exports should typically remain disabled until data exists.
  $primaryKeys = @(
    'BtnQueueLoad',
    'BtnSkillLoad',
    'BtnUserLoad',
    'BtnFlowLoad',
    'btnConvSearch',
    'BtnGeneratePacket',
    'BtnAbandonQuery',
    'BtnSearchReferences',
    'BtnSnapshotRefresh',
    'BtnStart',
    'BtnRunReport'
  )

  foreach ($k in $primaryKeys) {
    if ($Handles.ContainsKey($k) -and $Handles[$k]) {
      Set-ControlEnabled -Control $Handles[$k] -Enabled $canRun
    }
  }
}
### END: AUTH_READY_BUTTON_ENABLE_HELPERS
"@.Split("`n")

  $lines = @(
    $lines[0..$insertAfter]
    ""
    $helpers
    ""
    $lines[($insertAfter + 1)..($lines.Count - 1)]
  )

  Write-Host "Injected auth-ready helpers."
}

# -----------------------------
# 2) Remove a known-bad stray patch line if present
# (this came from an earlier regex replacement attempt)
# -----------------------------
$lines = $lines | Where-Object { $_ -notmatch '\$\(\$matches\["cond"\]\)' }

# -----------------------------
# 3) Make BtnTestToken enable logic include OfflineDemo
# Replace: BtnTestToken.IsEnabled = [bool]$script:AppState.AccessToken
# With:    Set-ControlEnabled -Control $BtnTestToken -Enabled (Test-AuthReady)
# -----------------------------
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '\$BtnTestToken\.IsEnabled\s*=\s*\[bool\]\$script:AppState\.AccessToken') {
    $indent = ($lines[$i] -replace '^(\s*).*', '$1')
    $lines[$i] = "${indent}Set-ControlEnabled -Control `$BtnTestToken -Enabled (Test-AuthReady)"
  }
  if ($lines[$i] -match 'if\s*\(\s*\$BtnTestToken\s*\)\s*\{\s*\$BtnTestToken\.IsEnabled\s*=\s*\[bool\]\$script:AppState\.AccessToken\s*\}') {
    $indent = ($lines[$i] -replace '^(\s*).*', '$1')
    $lines[$i] = "${indent}if (`$BtnTestToken) { Set-ControlEnabled -Control `$BtnTestToken -Enabled (Test-AuthReady) }"
  }
}

# -----------------------------
# 4) After each view handle map ($h = @{ ... }) is created, enable primaries
# We ONLY do this when the handle map includes one of the primary keys.
# -----------------------------
$primaryKeyRegex = '(BtnQueueLoad|BtnSkillLoad|BtnUserLoad|BtnFlowLoad|btnConvSearch|BtnGeneratePacket|BtnAbandonQuery|BtnSearchReferences|BtnSnapshotRefresh|BtnStart|BtnRunReport)'
$out = New-Object System.Collections.Generic.List[string]

$inH = $false
$hDepth = 0
$hSawPrimary = $false

for ($i = 0; $i -lt $lines.Count; $i++) {
  $line = $lines[$i]
  $out.Add($line)

  # detect "$h = @{"
  if (-not $inH -and $line -match '^\s*\$h\s*=\s*@\{\s*$') {
    $inH = $true
    $hDepth = 0
    $hSawPrimary = $false
    continue
  }

  if ($inH) {
    if ($line -match $primaryKeyRegex) { $hSawPrimary = $true }

    foreach ($ch in $line.ToCharArray()) {
      if ($ch -eq '{') { $hDepth++ }
      elseif ($ch -eq '}') { $hDepth-- }
    }

    # end of hashtable: a line that's just "}" (possibly indented)
    if ($line -match '^\s*\}\s*$') {
      # we treat this as the end of the handle map
      if ($hSawPrimary) {
        $indent = ($line -replace '^(\s*).*', '$1')
        $out.Add("")
        $out.Add("${indent}Enable-PrimaryActionButtons -Handles `$h")
        $out.Add("")
      }

      $inH = $false
      $hDepth = 0
      $hSawPrimary = $false
    }
  }
}

$lines = $out.ToArray()

# -----------------------------
# 5) Fix Set-OfflineDemoMode footer messaging (optional but nice)
# If it always says "disabled", patch to conditional messages.
# -----------------------------
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match 'Write-GcTrace -Level ''INFO'' -Message "Offline demo disabled"') {
    $indent = ($lines[$i] -replace '^(\s*).*', '$1')
    $lines[$i] = "${indent}Write-GcTrace -Level 'INFO' -Message (if (`$Enabled) { 'Offline demo enabled' } else { 'Offline demo disabled' })"
  }
  if ($lines[$i] -match 'Set-Status "Offline demo disabled\."') {
    $indent = ($lines[$i] -replace '^(\s*).*', '$1')
    $lines[$i] = "${indent}try { Set-Status (if (`$Enabled) { 'Offline demo enabled.' } else { 'Offline demo disabled.' }) } catch { }"
  }
}

Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
Write-Host "Patched successfully: $Path"
Write-Host "Re-run with: pwsh -STA -NoProfile -File `"$Path`" -OfflineDemo"
