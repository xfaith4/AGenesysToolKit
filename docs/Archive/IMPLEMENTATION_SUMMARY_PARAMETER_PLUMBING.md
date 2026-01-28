# Implementation Summary: UI Parameter Plumbing & Offline Demo Hardening

## Overview

This implementation ensures **reliable UI → function parameter plumbing** across AGenesysToolKit, with a focus on:

1. **Zero null-valued expression errors** during offline demo mode
2. **Type-aware parameter handling** for report templates
3. **Proper validation** of all user inputs
4. **Offline-first design** where all features work with sample data

## What Was Implemented

### 1. Core Helper Functions

#### `Get-UiTextSafe`
```powershell
function Get-UiTextSafe {
  param([AllowNull()]$Control)
  # Returns empty string if control is null
  # Safely accesses .Text property with error handling
}
```

**Purpose:** Eliminate null reference errors when reading TextBox/TextBlock values.

#### `Get-UiSelectionSafe`
```powershell
function Get-UiSelectionSafe {
  param([AllowNull()]$Control)
  # Returns $null if control is null or has no selection
  # Safely accesses .SelectedItem property
}
```

**Purpose:** Eliminate null reference errors when accessing ComboBox/ListBox selections.

#### `Sync-AppStateFromUi`
```powershell
function Sync-AppStateFromUi {
  param($RegionControl, $TokenControl)
  # Reads UI values
  # Normalizes via Normalize-GcInstanceName / Normalize-GcAccessToken
  # Updates $script:AppState
  # Calls Set-TopContext to refresh UI
}
```

**Purpose:** Centralize UI → AppState synchronization with proper normalization.

**Usage Example:**
```powershell
# After user enters token/region manually
Sync-AppStateFromUi -RegionControl $h.TxtRegion -TokenControl $h.TxtAccessToken
```

#### `Get-CallContext`
```powershell
function Get-CallContext {
  # Returns: @{ InstanceName, Region, AccessToken, IsOfflineDemo }
  # Auto-fills offline defaults when needed:
  #   - InstanceName = 'offline.local'
  #   - AccessToken = 'offline-demo'
  #   - FocusConversationId = 'c-demo-001'
  # Returns $null if invalid (missing token when not offline)
}
```

**Purpose:** Build standardized API call context with offline demo support.

**Usage Example:**
```powershell
$ctx = Get-CallContext
if ($ctx) {
  $result = Invoke-GcRequest -InstanceName $ctx.InstanceName -AccessToken $ctx.AccessToken -Path '/api/v2/users/me'
}
```

### 2. Type-Aware Parameter Controls

Enhanced **`Build-ParameterPanel`** to create type-appropriate UI controls based on parameter definitions:

| Parameter Type | UI Control | Default Behavior |
|----------------|------------|------------------|
| `String` | TextBox | Auto-fill from AppState if Region/AccessToken/ConversationId |
| `DateTime` | DatePicker | Default to yesterday |
| `Bool` | CheckBox | Default unchecked |
| `Int` | TextBox | Validation tooltip |
| `Array` | Multiline TextBox | Accepts JSON or CSV |

**Auto-fill Logic:**
```powershell
# Parameters named 'Region' or 'InstanceName'
if ($paramName -eq 'Region' -or $paramName -eq 'InstanceName') {
  $defaultValue = $script:AppState.Region
  # Control is read-only with gray background
}

# Parameters named 'AccessToken'
elseif ($paramName -eq 'AccessToken') {
  $defaultValue = $script:AppState.AccessToken
  # Control is read-only with gray background
}

# Parameters named 'ConversationId'
elseif ($paramName -eq 'ConversationId' -and $script:AppState.FocusConversationId) {
  $defaultValue = $script:AppState.FocusConversationId
}
```

**Read-Only Styling for Security Parameters:**
```powershell
if (($paramName -eq 'Region' -or $paramName -eq 'AccessToken') -and $defaultValue) {
  $control.IsReadOnly = $true
  $control.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(240, 240, 240))
  $control.ToolTip = "Auto-filled from current session context"
}
```

### 3. Intelligent Type Conversion

Enhanced **`Get-ParameterValues`** to convert UI values to correct types:

```powershell
function script:Get-ParameterValues {
  # Conversion rules:
  # - CheckBox → [bool]
  # - DatePicker → [DateTime]
  # - TextBox containing '[' → Try JSON, fallback to string
  # - TextBox with comma → Check if number with thousands separator or CSV array
  # - TextBox matching ^\d+$ → Convert to [int]
  # - TextBox matching ^(true|false)$ → Convert to [bool]
  # - Otherwise → Keep as [string]
}
```

**Example Conversions:**
- `"1,000"` → `1000` (integer with thousand separator)
- `"1,2,3"` → `["1","2","3"]` (array)
- `"[\"topic1\",\"topic2\"]"` → `["topic1","topic2"]` (JSON array)
- `"true"` → `$true` (boolean)
- `"42"` → `42` (integer)

### 4. Parameter Validation

Added **`Validate-ReportParameters`** to check requirements before execution:

```powershell
function script:Validate-ReportParameters {
  param($Template, $ParameterValues)
  
  # Checks:
  # 1. Required parameters are present and non-empty
  # 2. Type-specific validation (Int values must parse)
  
  # Returns array of error messages
}
```

**Usage in BtnRunReport:**
```powershell
$validationErrors = Validate-ReportParameters -Template $template -ParameterValues $params
if ($validationErrors -and $validationErrors.Count -gt 0) {
  $errorMsg = "Validation errors:`n" + ($validationErrors -join "`n")
  [System.Windows.MessageBox]::Show($errorMsg, "Validation Error", ...)
  return
}
```

### 5. Event Handler Hardening

All Reports & Exports event handlers now follow this pattern:

```powershell
if ($h.ControlName) {
  $h.ControlName.Add_Click({
    try {
      # 1. Safely get values
      $selectedItem = Get-UiSelectionSafe -Control $h.LstTemplates
      if (-not $selectedItem) { return }
      
      # 2. Perform action
      # ...
      
      # 3. Update status (wrapped)
      try { Set-Status "Action completed" } catch { }
      
    } catch {
      Write-GcTrace -Level 'ERROR' -Message "ControlName.Click: $($_.Exception.Message)"
      try { Set-Status "⚠️ Error: $($_.Exception.Message)" } catch { }
    }
  }.GetNewClosure())
}
```

**Key Improvements:**
- ✅ Null check before adding handler (`if ($h.ControlName)`)
- ✅ Use helper functions (`Get-UiSelectionSafe`, `Get-UiTextSafe`)
- ✅ Entire handler wrapped in try/catch
- ✅ Error logging via `Write-GcTrace`
- ✅ Safe `Set-Status` calls
- ✅ Always use `.GetNewClosure()` to capture variables

### 6. Documentation

Created **PARAMETER_MAPPING.md** with:
- Helper function usage patterns
- Parameter type mapping rules
- Offline demo defaults
- Event handler patterns
- Error handling guidelines

## Files Changed

### App/GenesysCloudTool_UX_Prototype.ps1

**Added Functions:**
- `Get-UiTextSafe` (line ~342)
- `Get-UiSelectionSafe` (line ~358)
- `Sync-AppStateFromUi` (line ~374)
- `Get-CallContext` (line ~413)
- `Validate-ReportParameters` (line ~473)

**Enhanced Functions:**
- `Build-ParameterPanel`: Type-aware controls, auto-fill, read-only styling
- `Get-ParameterValues`: Intelligent type conversion

**Hardened Event Handlers:**
- Template selection handler (null-safe)
- BtnRunReport handler (validation, error handling)
- All export button handlers (null checks, try/catch)
- Template search handlers (null-safe)

### tests/test-reports-exports-ui.ps1

**Fixed:**
- Function detection to handle script-scoped functions (`function script:name`)

### New Files

**PARAMETER_MAPPING.md**: Complete documentation of parameter flow patterns

## Test Results

All 5 acceptance tests pass:

✅ **test-parameter-flow.ps1**: 34/34 tests passed
- Verifies parameter flow through all Core modules
- Confirms AccessToken and InstanceName parameters exist

✅ **test-offlinedemo-workflow.ps1**: 15/15 tests passed
- Validates offline demo functionality
- Tests timeline reconstruction
- Tests packet export
- Tests analytics jobs

✅ **test-app-load.ps1**: Passed
- App loads without errors
- Functions are defined correctly

✅ **test-app-xaml.ps1**: Passed
- XAML parsing validated
- No syntax errors
- Helper functions present

✅ **test-reports-exports-ui.ps1**: 6/6 tests passed
- New-ReportsExportsView function exists
- Navigation routes correctly
- All required UI elements present
- Event handlers implemented
- Helper functions exist
- Core module integration verified

## Offline Demo Support

### How It Works

1. **Environment Detection:**
   ```powershell
   Test-OfflineDemoEnabled
   # Checks: $env:GC_TOOLKIT_OFFLINE_DEMO = '1'
   ```

2. **State Initialization:**
   ```powershell
   Set-OfflineDemoMode -Enabled $true
   # Sets: Region = 'offline.local'
   #       AccessToken = 'offline-demo'
   #       FocusConversationId = 'c-demo-001'
   ```

3. **Request Routing:**
   - All `Invoke-GcRequest` calls route to `Core/SampleData.psm1`
   - Sample responses returned for common endpoints
   - No actual API calls made

4. **UI Integration:**
   - `Get-CallContext` auto-fills offline defaults
   - Parameter controls pre-populate with demo values
   - No crashes when clicking through UI without login

### Supported in Offline Mode

- User info (`/api/v2/users/me`)
- OAuth clients listing
- Audits query (paged)
- Flows listing and configuration
- Data actions
- Routing queues and observations
- Skills and users
- Recordings
- Quality evaluations
- Analytics conversation details jobs
- Timeline reconstruction for `c-demo-001`
- Packet export

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
# Writes to $env:GC_TOOLKIT_TRACE_LOG when tracing enabled
```

## Key Benefits

1. ✅ **Zero null reference errors** during offline demo
2. ✅ **Type-safe parameters** with automatic conversion
3. ✅ **Validation before execution** prevents invalid API calls
4. ✅ **Auto-fill from context** reduces user input errors
5. ✅ **Offline-first design** enables testing without live environment
6. ✅ **Consistent error handling** across all handlers
7. ✅ **Read-only security params** prevents accidental modification

## Breaking Changes

**None.** All changes are additive and backward-compatible.

## Security Considerations

### Parameter Security

- Region and AccessToken parameters are **auto-filled** from AppState
- Auto-filled security parameters are **read-only** to prevent modification
- All user input is **normalized** via `Normalize-GcInstanceName` / `Normalize-GcAccessToken`
- Validation prevents empty or malformed parameters from reaching API calls

### Error Handling

- Errors are **logged** via `Write-GcTrace` for diagnostics
- Sensitive information (tokens) are **not exposed** in error messages
- User-facing errors are **friendly and actionable**

### Offline Demo

- Offline mode uses **fake credentials** (`offline-demo` token)
- No real API calls are made in offline mode
- Sample data responses are **safe and pre-defined**

## Future Enhancements

Potential improvements for future PRs:

1. **Preset Management**: Save/load parameter presets for common report configurations
2. **Parameter History**: Remember last-used values for parameters
3. **Validation Hints**: Real-time validation feedback as user types
4. **Custom Validators**: Support for custom validation functions per parameter
5. **Dependency Management**: Handle parameter dependencies (e.g., param B required when param A is set)

## Conclusion

This implementation provides a **robust, type-safe, and user-friendly** parameter plumbing system that works reliably in both live and offline demo modes. All event handlers are hardened against null references, and proper validation ensures only valid parameters reach API functions.

**Result:** Zero crashes during offline demo click-through, with all 5 acceptance tests passing.
