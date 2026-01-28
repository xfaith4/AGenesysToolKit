# UI → Function Parameter Mapping

## Overview

This document describes how UI controls map to function parameters throughout AGenesysToolKit, with a focus on the reliable parameter plumbing implemented for offline demo support.

## Helper Functions

### UI Access Helpers

#### `Get-UiTextSafe`
Safely retrieves text from UI controls without null reference errors.

```powershell
function Get-UiTextSafe {
  param([AllowNull()]$Control)
  # Returns empty string if control is null or missing Text property
}
```

**Usage:**
```powershell
$region = Get-UiTextSafe -Control $h.TxtRegion
# Safe even if $h.TxtRegion is $null
```

#### `Get-UiSelectionSafe`
Safely retrieves selected items from selection controls.

```powershell
function Get-UiSelectionSafe {
  param([AllowNull()]$Control)
  # Returns $null if control is null or has no selection
}
```

**Usage:**
```powershell
$selectedTemplate = Get-UiSelectionSafe -Control $h.LstTemplates
if ($selectedTemplate -and $selectedTemplate.Tag) {
  # Use selection safely
}
```

### State Synchronization

#### `Sync-AppStateFromUi`
Synchronizes UI values into `$script:AppState` with normalization.

```powershell
function Sync-AppStateFromUi {
  param(
    [AllowNull()]$RegionControl,
    [AllowNull()]$TokenControl
  )
  # Normalizes using Normalize-GcInstanceName and Normalize-GcAccessToken
  # Updates $script:AppState.Region and $script:AppState.AccessToken
  # Calls Set-TopContext to refresh UI
}
```

**Usage:**
```powershell
# After user enters token/region manually
Sync-AppStateFromUi -RegionControl $h.TxtRegion -TokenControl $h.TxtAccessToken
```

### API Call Context

#### `Get-CallContext`
Builds a standardized context hashtable for API calls.

```powershell
function Get-CallContext {
  # Returns: @{ InstanceName, Region, AccessToken, IsOfflineDemo }
  # Returns $null if context is invalid (missing token when not offline)
  # Auto-fills offline defaults when Test-OfflineDemoEnabled returns true
}
```

**Usage:**
```powershell
$ctx = Get-CallContext
if ($ctx) {
  $result = Invoke-GcRequest -InstanceName $ctx.InstanceName -AccessToken $ctx.AccessToken -Path '/api/v2/users/me'
}
```

**Offline Mode Behavior:**
- When `$env:GC_TOOLKIT_OFFLINE_DEMO = '1'`:
  - `InstanceName` defaults to `'offline.local'`
  - `AccessToken` defaults to `'offline-demo'`
  - `FocusConversationId` defaults to `'c-demo-001'`
  - `IsOfflineDemo` returns `$true`

## Report Template Parameters

### Type-Aware Parameter Controls

Report templates define parameters with type metadata:

```powershell
Parameters = @{
  Region = @{ Type = 'String'; Required = $true; Description = 'Genesys Cloud region' }
  AccessToken = @{ Type = 'String'; Required = $true; Description = 'OAuth access token' }
  TargetDate = @{ Type = 'DateTime'; Required = $false; Description = 'Date to report on' }
  IncludeDetails = @{ Type = 'Bool'; Required = $false; Description = 'Include detailed breakdown' }
  Topics = @{ Type = 'Array'; Required = $true; Description = 'Subscribed topics' }
  MaxResults = @{ Type = 'Int'; Required = $false; Description = 'Maximum results to return' }
}
```

### UI Control Mapping

`Build-ParameterPanel` creates type-appropriate controls:

| Parameter Type | UI Control | Default Value | Notes |
|----------------|------------|---------------|-------|
| `String` | `TextBox` | Auto-fill from AppState if Region/AccessToken/ConversationId | Standard text input |
| `DateTime` | `DatePicker` | Yesterday | Calendar picker |
| `Bool` | `CheckBox` | False | Boolean toggle |
| `Int` | `TextBox` | None | With validation tooltip |
| `Array` | `TextBox` (multiline) | None | Accepts JSON array or comma-separated |

**Auto-fill Rules:**
- `Region` or `InstanceName` → `$script:AppState.Region`
- `AccessToken` → `$script:AppState.AccessToken`
- `ConversationId` → `$script:AppState.FocusConversationId`
- Auto-filled controls are **read-only** with gray background

### Value Conversion

`Get-ParameterValues` converts UI values to correct types:

```powershell
function script:Get-ParameterValues {
  # Returns hashtable with typed values:
  # - CheckBox → [bool]
  # - DatePicker → [DateTime]
  # - TextBox → [string], [int], [array], or [bool] based on content pattern
}
```

**Conversion Logic:**
- Text starting with `[` or containing `,` → Try JSON, fallback to comma-separated array
- Text matching `^\d+$` → Convert to `[int]`
- Text matching `^(true|false)$` → Convert to `[bool]`
- Otherwise → Keep as `[string]`

### Validation

`Validate-ReportParameters` checks requirements:

```powershell
function script:Validate-ReportParameters {
  param($Template, $ParameterValues)
  # Returns array of error messages
  # Checks:
  # - Required parameters are present and non-empty
  # - Type-specific validation (Int must parse as integer)
}
```

**Usage in BtnRunReport handler:**
```powershell
$validationErrors = Validate-ReportParameters -Template $template -ParameterValues $params
if ($validationErrors -and $validationErrors.Count -gt 0) {
  $errorMsg = "Validation errors:`n" + ($validationErrors -join "`n")
  [System.Windows.MessageBox]::Show($errorMsg, "Validation Error", ...)
  return
}
```

## Event Handler Patterns

### Null-Safe Event Handler Template

All event handlers follow this pattern:

```powershell
if ($h.ControlName) {
  $h.ControlName.Add_Click({
    try {
      # 1. Safely get values from UI
      $selectedItem = Get-UiSelectionSafe -Control $h.LstSomething
      if (-not $selectedItem) { return }
      
      # 2. Perform action
      # ...
      
      # 3. Update status (wrapped in try/catch)
      try { Set-Status "Action completed" } catch { }
      
    } catch {
      Write-GcTrace -Level 'ERROR' -Message "ControlName.Click error: $($_.Exception.Message)"
      try { Set-Status "⚠️ Error: $($_.Exception.Message)" } catch { }
    }
  }.GetNewClosure())
}
```

**Key Points:**
- Check control exists before adding handler (`if ($h.ControlName)`)
- Use `Get-UiTextSafe` / `Get-UiSelectionSafe` for values
- Wrap entire handler in try/catch
- Log errors with `Write-GcTrace`
- Wrap `Set-Status` calls in try/catch
- Always use `.GetNewClosure()` to capture variables

## Core Module Parameter Flow

### Standard API Functions

All Core module API functions accept:

```powershell
-AccessToken [string]    # OAuth access token
-InstanceName [string]   # Genesys Cloud instance (e.g., 'usw2.pure.cloud')
```

**Examples:**
```powershell
Get-GcQueues -AccessToken $token -InstanceName $instance
Get-GcConversationById -ConversationId $id -AccessToken $token -InstanceName $instance
```

### Timeline & Artifact Functions

Timeline and artifact functions use `-Region` instead of `-InstanceName`:

```powershell
Get-GcConversationDetails -ConversationId $id -AccessToken $token -Region $region
Export-GcConversationPacket -ConversationId $id -AccessToken $token -Region $region
```

**Note:** `Region` and `InstanceName` are treated as synonyms.

### App Wrapper Function

`Invoke-AppGcRequest` automatically injects parameters from AppState:

```powershell
# Core modules can optionally use this wrapper:
Invoke-AppGcRequest -Method GET -Path '/api/v2/users/me'
# AccessToken and InstanceName come from $script:AppState automatically
```

**Setup:**
```powershell
Set-GcAppState -State ([ref]$script:AppState)
```

## Offline Demo Defaults

### Environment Detection

```powershell
function Test-OfflineDemoEnabled {
  # Checks: $env:GC_TOOLKIT_OFFLINE_DEMO -match '^(1|true|yes|on)$'
}
```

### Offline State Initialization

When offline demo is enabled:

```powershell
function Set-OfflineDemoMode {
  param([bool]$Enabled)
  if ($Enabled) {
    $script:AppState.Region = 'offline.local'
    $script:AppState.AccessToken = 'offline-demo'
    $script:AppState.FocusConversationId = 'c-demo-001'
    $script:AppState.Auth = 'Offline demo'
    $script:AppState.TokenStatus = 'Offline demo'
    # Routes all Invoke-GcRequest calls to Core/SampleData.psm1
  }
}
```

### Offline Request Routing

All API calls via `Invoke-GcRequest` automatically route to sample data:

```powershell
# In Core/HttpRequests.psm1:
if (Test-GcOfflineDemoEnabled) {
  # Route to Core/SampleData.psm1 based on Method + Path
  return Get-SampleResponse -Method $Method -Path $Path
}
```

**Supported Endpoints in Offline Mode:**
- `/api/v2/users/me`
- `/api/v2/oauth/clients`
- `/api/v2/audits/query`
- `/api/v2/flows`
- `/api/v2/routing/queues`
- `/api/v2/recording/recordings`
- Analytics conversation details jobs
- Timeline reconstruction for `c-demo-001`
- Many more (see `Core/SampleData.psm1`)

## Error Handling

### User-Facing Errors

```powershell
[System.Windows.MessageBox]::Show(
  "Error message",
  "Error Title",
  [System.Windows.MessageBoxButton]::OK,
  [System.Windows.MessageBoxImage]::Error
)
```

### Status Bar Updates

```powershell
try { Set-Status "Operation completed" } catch { }
```

### Trace Logging

```powershell
Write-GcTrace -Level 'ERROR' -Message "Component failed: $($_.Exception.Message)"
# Levels: INFO, WARN, ERROR, DEBUG
# Writes to $env:GC_TOOLKIT_TRACE_LOG if tracing enabled
```

## Summary

**Key Principles:**

1. ✅ **Always use helper functions** (`Get-UiTextSafe`, `Get-UiSelectionSafe`, `Get-CallContext`)
2. ✅ **Validate before use** (null checks, parameter validation)
3. ✅ **Normalize inputs** (`Normalize-GcInstanceName`, `Normalize-GcAccessToken`)
4. ✅ **Type-aware parameters** (DatePicker for DateTime, CheckBox for Bool, etc.)
5. ✅ **Offline-first design** (all features work with sample data)
6. ✅ **Fail gracefully** (try/catch, error logging, user feedback)
7. ✅ **Auto-fill from context** (Region/AccessToken from AppState)

**Result:** Zero null-valued expression errors during offline demo click-through.
