# CoreIntegration.ps1
# ─────────────────────────────────────────────────────────────────────────────
# Discovery and initialization of the Genesys.Core backend module.
#
# Genesys.Core is the portable, catalog-driven data collection engine at
# https://github.com/xfaith4/Genesys.Core
#
# This file handles locating Genesys.Core across the scenarios a new user
# will actually encounter:
#   1. Both repos cloned side-by-side in the same parent directory (most common)
#   2. Path saved from a previous session in gc-admin.json
#   3. GC_CORE_MODULE_PATH environment variable (CI/CD + power users)
#   4. Genesys.Core installed as a PowerShell module
#
# Discovery order is: config → env var → sibling directory → PS module path
#
# Dot-sourced by GenesysCloudTool.ps1 at startup.
# ─────────────────────────────────────────────────────────────────────────────

### BEGIN: CoreIntegrationState
$script:GcCoreState = [ordered]@{
  Available       = $false
  ModulePath      = $null   # Absolute path to Genesys.Core.psd1
  CatalogPath     = $null   # Absolute path to genesys-core.catalog.json
  Version         = $null   # Module version string, if readable
  DiscoverySource = $null   # 'config' | 'env' | 'sibling' | 'psmodule' | 'manual'
  LastError       = $null   # Last failure message (for UI display)
}
### END: CoreIntegrationState

### BEGIN: GcCoreCandidates
function Get-GcCoreCandidates {
  <#
  .SYNOPSIS
    Returns an ordered list of candidate Genesys.Core.psd1 paths to probe,
    based on the discovery priority chain.
  #>
  [CmdletBinding()]
  param(
    [string]$ScriptRoot,   # App/ directory
    [string]$RepoRoot,     # AGenesysToolKit/ directory
    [string]$ConfigPath    # Path to gc-admin.json
  )

  $candidates = [System.Collections.Generic.List[object]]::new()

  # ── 1. Explicit path saved in gc-admin.json ────────────────────────────────
  if ($ConfigPath -and (Test-Path $ConfigPath -ErrorAction SilentlyContinue)) {
    try {
      $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
      $savedPath = if ($cfg.genesysCore -and $cfg.genesysCore.modulePath) { [string]$cfg.genesysCore.modulePath } else { $null }
      if (-not [string]::IsNullOrWhiteSpace($savedPath)) {
        $candidates.Add([pscustomobject]@{ Path = $savedPath; Source = 'config' }) | Out-Null
      }
    } catch {
      # Intentional: malformed config must not prevent startup.
      Write-Verbose "[CoreIntegration] Could not read genesysCore.modulePath from config: $_"
    }
  }

  # ── 2. Environment variable GC_CORE_MODULE_PATH ────────────────────────────
  try {
    $envPath = [Environment]::GetEnvironmentVariable('GC_CORE_MODULE_PATH')
    if (-not [string]::IsNullOrWhiteSpace($envPath)) {
      $candidates.Add([pscustomobject]@{ Path = $envPath; Source = 'env' }) | Out-Null
    }
  } catch {
    Write-Verbose "[CoreIntegration] Could not read GC_CORE_MODULE_PATH env var: $_"
  }

  # ── 3. Sibling directory convention ────────────────────────────────────────
  # Covers the most common GitHub clone scenario:
  #   C:\Projects\
  #   ├── AGenesysToolKit\   ← this repo
  #   └── Genesys.Core\      ← companion repo cloned alongside
  if ($RepoRoot) {
    $parentDir  = Split-Path -Parent $RepoRoot
    $modulePsd1 = 'src\ps-module\Genesys.Core\Genesys.Core.psd1'

    # Standard sibling: ../Genesys.Core/
    $candidates.Add([pscustomobject]@{
      Path   = Join-Path $parentDir (Join-Path 'Genesys.Core' $modulePsd1)
      Source = 'sibling'
    }) | Out-Null

    # Case-variant: ../genesys.core/ (Linux-style clone naming)
    $candidates.Add([pscustomobject]@{
      Path   = Join-Path $parentDir (Join-Path 'genesys.core' $modulePsd1)
      Source = 'sibling'
    }) | Out-Null

    # Alternate clone name: ../GenesysCore/
    $candidates.Add([pscustomobject]@{
      Path   = Join-Path $parentDir (Join-Path 'GenesysCore' $modulePsd1)
      Source = 'sibling'
    }) | Out-Null
  }

  # ── 4. PowerShell module path (if installed via Install-Module / PSGet) ────
  try {
    $psModule = Get-Module -Name 'Genesys.Core' -ListAvailable -ErrorAction SilentlyContinue |
                Sort-Object Version -Descending | Select-Object -First 1
    if ($psModule -and $psModule.Path) {
      $candidates.Add([pscustomobject]@{ Path = $psModule.Path; Source = 'psmodule' }) | Out-Null
    }
  } catch {
    Write-Verbose "[CoreIntegration] PS module search failed: $_"
  }

  return @($candidates)
}
### END: GcCoreCandidates

### BEGIN: FindGcCatalog
function Find-GcCoreCatalog {
  <#
  .SYNOPSIS
    Given the path to Genesys.Core.psd1, locate the companion catalog JSON file.
    The catalog lives at the repo root (../../genesys-core.catalog.json relative
    to the module .psd1 inside src/ps-module/Genesys.Core/).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ModulePath)

  # Standard layout: <root>/src/ps-module/Genesys.Core/Genesys.Core.psd1
  $moduleDir = Split-Path $ModulePath -Parent   # Genesys.Core/
  $psModule  = Split-Path $moduleDir  -Parent   # ps-module/
  $src       = Split-Path $psModule   -Parent   # src/
  $root      = Split-Path $src        -Parent   # repo root

  $candidates = @(
    (Join-Path $root   'genesys-core.catalog.json'),
    (Join-Path $root   (Join-Path 'catalog' 'genesys-core.catalog.json'))
  )

  foreach ($c in $candidates) {
    if (Test-Path $c -ErrorAction SilentlyContinue) { return (Resolve-Path $c).Path }
  }

  return $null
}
### END: FindGcCatalog

### BEGIN: InitializeGcCoreIntegration
function Initialize-GcCoreIntegration {
  <#
  .SYNOPSIS
    Runs the discovery chain and loads Genesys.Core into the current session
    if found. Populates $script:GcCoreState with results.

  .PARAMETER ScriptRoot
    Directory containing the running script (App/).

  .PARAMETER RepoRoot
    Root of the AGenesysToolKit repository.

  .PARAMETER ConfigPath
    Path to gc-admin.json for reading/writing the saved module path.
  #>
  [CmdletBinding()]
  param(
    [string]$ScriptRoot,
    [string]$RepoRoot,
    [string]$ConfigPath
  )

  $script:GcCoreState.Available       = $false
  $script:GcCoreState.ModulePath      = $null
  $script:GcCoreState.CatalogPath     = $null
  $script:GcCoreState.Version         = $null
  $script:GcCoreState.DiscoverySource = $null
  $script:GcCoreState.LastError       = $null

  $candidates = Get-GcCoreCandidates -ScriptRoot $ScriptRoot -RepoRoot $RepoRoot -ConfigPath $ConfigPath

  foreach ($candidate in $candidates) {
    $resolvedPath = $null
    try {
      if (-not (Test-Path $candidate.Path -ErrorAction SilentlyContinue)) { continue }
      $resolvedPath = (Resolve-Path $candidate.Path).Path
    } catch {
      continue
    }

    try {
      Import-Module $resolvedPath -Force -ErrorAction Stop
      Write-Verbose "[CoreIntegration] Loaded Genesys.Core from $resolvedPath (source: $($candidate.Source))"

      $catalogPath = Find-GcCoreCatalog -ModulePath $resolvedPath

      # Read version from manifest if possible
      $version = $null
      try {
        $manifestData = Import-PowerShellDataFile -Path $resolvedPath -ErrorAction SilentlyContinue
        if ($manifestData -and $manifestData.ModuleVersion) { $version = [string]$manifestData.ModuleVersion }
      } catch {
        # Intentional: version metadata is nice-to-have, not required.
        Write-Verbose "[CoreIntegration] Could not read module version: $_"
      }

      $script:GcCoreState.Available       = $true
      $script:GcCoreState.ModulePath      = $resolvedPath
      $script:GcCoreState.CatalogPath     = $catalogPath
      $script:GcCoreState.Version         = $version
      $script:GcCoreState.DiscoverySource = $candidate.Source
      return

    } catch {
      Write-Verbose "[CoreIntegration] Failed to load from $resolvedPath : $_"
      $script:GcCoreState.LastError = $_.Exception.Message
      # Continue to next candidate.
    }
  }

  $script:GcCoreState.LastError = if ($candidates.Count -eq 0) {
    'No candidates found. Clone https://github.com/xfaith4/Genesys.Core alongside this repository.'
  } else {
    'Genesys.Core was not found in any of the standard locations. Use the Integration tab in Backstage to locate it manually.'
  }

  Write-Verbose "[CoreIntegration] Genesys.Core not available: $($script:GcCoreState.LastError)"
}
### END: InitializeGcCoreIntegration

### BEGIN: GcCoreHelpers
function Get-GcCoreStatus {
  <#
  .SYNOPSIS
    Returns the current Genesys.Core integration state as a PSCustomObject.
  #>
  return [pscustomobject]$script:GcCoreState
}

function Get-GcCoreStatusLabel {
  <#
  .SYNOPSIS
    Returns a short status string suitable for display in the UI status bar.
  #>
  if ($script:GcCoreState.Available) {
    $src = switch ($script:GcCoreState.DiscoverySource) {
      'config'   { 'cfg' }
      'env'      { 'env' }
      'sibling'  { 'auto' }
      'psmodule' { 'psgallery' }
      'manual'   { 'manual' }
      default    { '?' }
    }
    return "Core: connected ($src)"
  }
  return 'Core: not found'
}

function Save-GcCoreModulePath {
  <#
  .SYNOPSIS
    Persists a module path into gc-admin.json so it survives restarts.
    Creates the genesysCore section if missing.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ModulePath,
    [Parameter(Mandatory)][string]$ConfigPath
  )

  if (-not (Test-Path $ConfigPath -ErrorAction SilentlyContinue)) {
    Write-Warning "[CoreIntegration] gc-admin.json not found at '$ConfigPath' — cannot save path."
    return $false
  }

  try {
    $json     = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $jsonHash = [ordered]@{}

    foreach ($prop in $json.PSObject.Properties) {
      $jsonHash[$prop.Name] = $prop.Value
    }

    if ($jsonHash.ContainsKey('genesysCore') -and $null -ne $jsonHash['genesysCore']) {
      $existing = $jsonHash['genesysCore']
      $gcHash   = [ordered]@{}
      foreach ($p in $existing.PSObject.Properties) { $gcHash[$p.Name] = $p.Value }
      $gcHash['modulePath'] = $ModulePath
      $jsonHash['genesysCore'] = [pscustomobject]$gcHash
    } else {
      $jsonHash['genesysCore'] = [pscustomobject]@{
        '_comment'  = 'Path to Genesys.Core module. Set by the Integration panel. Remove to re-auto-discover.'
        'modulePath' = $ModulePath
      }
    }

    $jsonHash | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding utf8
    Write-Verbose "[CoreIntegration] Saved module path to $ConfigPath"
    return $true
  } catch {
    Write-Warning "[CoreIntegration] Failed to save path to gc-admin.json: $_"
    return $false
  }
}

function Clear-GcCoreModulePath {
  <#
  .SYNOPSIS
    Removes the saved modulePath from gc-admin.json so auto-discovery runs
    fresh on the next startup.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ConfigPath)

  if (-not (Test-Path $ConfigPath -ErrorAction SilentlyContinue)) { return $false }

  try {
    $json     = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $jsonHash = [ordered]@{}
    foreach ($prop in $json.PSObject.Properties) { $jsonHash[$prop.Name] = $prop.Value }

    if ($jsonHash.ContainsKey('genesysCore') -and $null -ne $jsonHash['genesysCore']) {
      $existing = $jsonHash['genesysCore']
      $gcHash   = [ordered]@{}
      foreach ($p in $existing.PSObject.Properties) { $gcHash[$p.Name] = $p.Value }
      $gcHash['modulePath'] = $null
      $jsonHash['genesysCore'] = [pscustomobject]$gcHash
      $jsonHash | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding utf8
    }
    return $true
  } catch {
    Write-Warning "[CoreIntegration] Failed to clear path from gc-admin.json: $_"
    return $false
  }
}
### END: GcCoreHelpers
