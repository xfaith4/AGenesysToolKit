# Genesys Cloud Tool — Real Implementation v3.0
# Money path flow: Login → Start Subscription → Stream events → Open Timeline → Export Packet

param(
  [switch]$OfflineDemo
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Import core modules
$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

Import-Module (Join-Path -Path $coreRoot -ChildPath 'Auth.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'JobRunner.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Subscriptions.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Timeline.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ArtifactGenerator.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'RoutingPeople.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ConversationsExtended.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ConfigExport.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Analytics.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Dependencies.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Reporting.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ReportTemplates.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ExtensionAudit.psm1') -Force

# -----------------------------
# XAML Helpers (extracted to App/XamlHelpers.ps1)
# -----------------------------
. (Join-Path $scriptRoot 'XamlHelpers.ps1')

# -----------------------------
# Genesys.Core integration (extracted to App/CoreIntegration.ps1)
# Provides: Find-GcCoreModule, Initialize-GcCoreIntegration, Get-GcCoreStatus,
#           Get-GcCoreStatusLabel, Save-GcCoreModulePath, Clear-GcCoreModulePath
# -----------------------------
. (Join-Path $scriptRoot 'CoreIntegration.ps1')

# -----------------------------
# App Logger (extracted to App/AppLogger.ps1)
# Provides: Write-GcAppLog, Write-GcTrace, Write-GcDiag, Format-GcDiagSecret,
#           ConvertTo-GcAppLogSafeData, ConvertTo-GcAppLogSafeString, Test-GcTraceEnabled
# Call Initialize-GcAppLogger after $script:ArtifactsDir is created below.
# -----------------------------
. (Join-Path $scriptRoot 'AppLogger.ps1')

# -----------------------------
# Application state (extracted to App/AppState.ps1)
# Provides: Initialize-GcAppState, $script:WorkspaceModules, $script:AddonsByRoute,
#           Sync-AppStateFromUi, Get-CallContext
# Call Initialize-GcAppState after $repoRoot is available (see startup block below).
# -----------------------------
. (Join-Path $scriptRoot 'AppState.ps1')

# -----------------------------
# Workspace view functions (extracted to App/Views/)
# Each file defines the New-*View functions for one workspace group.
# Safe to dot-source early: function bodies are lazy-evaluated at call time.
# -----------------------------
. (Join-Path $scriptRoot 'Views/Operations.ps1')
. (Join-Path $scriptRoot 'Views/Conversations.ps1')
. (Join-Path $scriptRoot 'Views/Orchestration.ps1')
. (Join-Path $scriptRoot 'Views/RoutingPeople.ps1')
. (Join-Path $scriptRoot 'Views/Reports.ps1')
. (Join-Path $scriptRoot 'Views/Audits.ps1')

# -----------------------------
# State + helpers
# -----------------------------

# Initialize Auth Configuration (user should customize these)
#
# USER SETTINGS (customize)
# - Set $EnableToolkitTrace = $true to write detailed tracing to App/artifacts/trace-*.log
# - Set $EnableToolkitTraceBodies = $true to include HTTP request bodies in the trace (may include sensitive data)
$EnableToolkitTrace = $false
$EnableToolkitTraceBodies = $false
try {
  if ($EnableToolkitTrace) {
    [Environment]::SetEnvironmentVariable('GC_TOOLKIT_TRACE', '1', 'Process')
    if ($EnableToolkitTraceBodies) {
      [Environment]::SetEnvironmentVariable('GC_TOOLKIT_TRACE_BODY', '1', 'Process')
    } else {
      [Environment]::SetEnvironmentVariable('GC_TOOLKIT_TRACE_BODY', $null, 'Process')
    }
  } else {
    [Environment]::SetEnvironmentVariable('GC_TOOLKIT_TRACE', $null, 'Process')
    [Environment]::SetEnvironmentVariable('GC_TOOLKIT_TRACE_BODY', $null, 'Process')
  }
} catch {
  Write-Verbose "[Startup] Failed to configure toolkit trace env vars: $_"
}

Set-GcAuthConfig `
  -Region 'usw2.pure.cloud' `
  -ClientId 'YOUR_CLIENT_ID_HERE' `
  -RedirectUri 'http://localhost:8085/callback' `
  -Scopes @('conversations', 'analytics', 'notifications', 'users')

# Initialize AppState — creates $script:AppState and registers it with HttpRequests.
# (AppState.ps1 was dot-sourced above; Initialize-GcAppState is now available.)
Initialize-GcAppState -RepoRoot $repoRoot

# ── Genesys.Core integration ─────────────────────────────────────────────────
# Run discovery silently at startup. The UI status bar and Backstage Integration
# tab reflect the result. Fails gracefully — Core is always optional.
$script:GcAdminConfigPath = Join-Path $scriptRoot 'gc-admin.json'
try {
  Initialize-GcCoreIntegration `
    -ScriptRoot  $scriptRoot `
    -RepoRoot    $repoRoot `
    -ConfigPath  $script:GcAdminConfigPath

  $coreStatus = Get-GcCoreStatus
  $script:AppState.GcCoreAvailable   = $coreStatus.Available
  $script:AppState.GcCoreModulePath  = $coreStatus.ModulePath
  $script:AppState.GcCoreCatalogPath = $coreStatus.CatalogPath
  $script:AppState.GcCoreVersion     = $coreStatus.Version
} catch {
  # Intentional: Core integration failure must never prevent the app from starting.
  Write-Verbose "[Startup] Genesys.Core integration failed: $_"
}
# ─────────────────────────────────────────────────────────────────────────────

$script:ArtifactsDir = Join-Path -Path $PSScriptRoot -ChildPath 'artifacts'
New-Item -ItemType Directory -Path $script:ArtifactsDir -Force | Out-Null

# Initialize the app logger now that the artifacts directory exists.
# (Functions were dot-sourced from AppLogger.ps1 above; this sets up file paths.)
Initialize-GcAppLogger -ArtifactsDir $script:ArtifactsDir

# When this script is executed (not dot-sourced), WPF event handlers run in global scope.
# Publish key state/paths to global so handlers can resolve them reliably.
$global:repoRoot = $repoRoot
$global:coreRoot = $coreRoot
$global:AppState = $script:AppState
$global:ArtifactsDir = $script:ArtifactsDir

try {
  Write-GcAppLog -Level 'INFO' -Category 'startup' -Message 'Toolkit started' -Data @{
    ScriptPath   = $PSCommandPath
    ArtifactsDir = $script:ArtifactsDir
    TraceLog     = $script:GcTraceLogPath
    AppLog       = $script:GcAppLogPath
  }
} catch {
  Write-Verbose "[Startup] Failed to write startup log entry: $_"
}

### BEGIN: Compatibility Helpers (Convert-XamlToControl / Get-NamedElements)
# Some older prompts and modules refer to these helper names. Provide them as thin wrappers.
function Convert-XamlToControl {
  param([Parameter(Mandatory=$true)][string]$Xaml)
  return ConvertFrom-GcXaml -XamlString $Xaml
}

function Get-NamedElements {
  param([Parameter(Mandatory=$true)]$Root)
  $map = @{}
  function _Walk($node) {
    if ($null -eq $node) { return }
    if ($node -is [System.Windows.FrameworkElement] -and $node.Name) {
      if (-not $map.ContainsKey($node.Name)) { $map[$node.Name] = $node }
    }
    $children = @()
    try { $children = [System.Windows.LogicalTreeHelper]::GetChildren($node) } catch {}
    foreach ($c in $children) { _Walk $c }
  }
  _Walk $Root
  return $map
}
### END: Compatibility Helpers (Convert-XamlToControl / Get-NamedElements)


### BEGIN: Reports helpers (script-scope; safe for event handlers)

function script:Refresh-TemplateList {
  param(
    [Parameter(Mandatory=$true)][hashtable]$h,
    [Parameter(Mandatory=$true)][object[]]$Templates
  )

  $searchText = ''
  try { $searchText = [string]$h.TxtTemplateSearch.Text } catch { $searchText = '' }
  if ($null -eq $searchText) { $searchText = '' }
  $searchText = $searchText.ToLower()

  $filtered = $Templates
  if ($searchText -and $searchText -ne 'search templates...') {
    $filtered = $Templates | Where-Object {
      $tmplName = if ($null -ne $_.Name) { [string]$_.Name } else { '' }
      $tmplDesc = if ($null -ne $_.Description) { [string]$_.Description } else { '' }
      ($tmplName.ToLower().Contains($searchText)) -or
      ($tmplDesc.ToLower().Contains($searchText))
    }
  }

  $h.LstTemplates.Items.Clear()
  foreach ($t in $filtered) {
    $item = New-Object System.Windows.Controls.ListBoxItem
    $item.Content = $t.Name
    $item.Tag     = $t
    [void]$h.LstTemplates.Items.Add($item)
  }
}

function script:Build-ParameterPanel {
  param(
    [Parameter(Mandatory=$true)][hashtable]$h,
    [Parameter(Mandatory=$true)]$Template
  )

  if (-not $script:ParameterControls) { $script:ParameterControls = @{} }
  $h.PnlParameters.Children.Clear()
  $script:ParameterControls.Clear() | Out-Null

  if (-not $Template.Parameters -or $Template.Parameters.Count -eq 0) {
    $noParamsText = New-Object System.Windows.Controls.TextBlock
    $noParamsText.Text = "This template has no parameters"
    $noParamsText.Foreground = [System.Windows.Media.Brushes]::Gray
    $noParamsText.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
    [void]$h.PnlParameters.Children.Add($noParamsText)
    return
  }

  foreach ($paramName in $Template.Parameters.Keys) {
    $paramDef = $Template.Parameters[$paramName]
    $paramType = if ($paramDef.Type) { $paramDef.Type } else { 'String' }

    $paramGrid = New-Object System.Windows.Controls.Grid
    $paramGrid.Margin = New-Object System.Windows.Thickness(0, 0, 0, 12)

    $row1 = New-Object System.Windows.Controls.RowDefinition; $row1.Height = [System.Windows.GridLength]::Auto
    $row2 = New-Object System.Windows.Controls.RowDefinition; $row2.Height = [System.Windows.GridLength]::Auto
    $row3 = New-Object System.Windows.Controls.RowDefinition; $row3.Height = [System.Windows.GridLength]::Auto
    [void]$paramGrid.RowDefinitions.Add($row1)
    [void]$paramGrid.RowDefinitions.Add($row2)
    [void]$paramGrid.RowDefinitions.Add($row3)

    $label = New-Object System.Windows.Controls.TextBlock
    $labelText = $paramName
    if ($paramDef.Required) { $labelText += " *" }
    $label.Text = $labelText
    $label.FontWeight = [System.Windows.FontWeights]::SemiBold
    # Required fields in dark red
    if ($paramDef.Required) {
      $label.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(139, 0, 0)) # DarkRed
    } else {
      $label.Foreground = [System.Windows.Media.Brushes]::Black
    }
    [System.Windows.Controls.Grid]::SetRow($label, 0)
    [void]$paramGrid.Children.Add($label)

    if ($paramDef.Description) {
      $desc = New-Object System.Windows.Controls.TextBlock
      $desc.Text = $paramDef.Description
      $desc.FontSize = 11
      $desc.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(107, 114, 128))
      $desc.Margin = New-Object System.Windows.Thickness(0, 2, 0, 4)
      $desc.TextWrapping = [System.Windows.TextWrapping]::Wrap
      [System.Windows.Controls.Grid]::SetRow($desc, 1)
      [void]$paramGrid.Children.Add($desc)
    }

    # Create type-appropriate control
    $control = $null
    $defaultValue = $null

    # Auto-fill from AppState for known parameters
    if ($paramName -eq 'Region' -or $paramName -eq 'InstanceName') {
      $defaultValue = $script:AppState.Region
    } elseif ($paramName -eq 'AccessToken') {
      $defaultValue = $script:AppState.AccessToken
    } elseif ($paramName -eq 'ConversationId' -and $script:AppState.FocusConversationId) {
      $defaultValue = $script:AppState.FocusConversationId
    }

    switch ($paramType) {
      'DateTime' {
        # DatePicker for DateTime parameters
        $control = New-Object System.Windows.Controls.DatePicker
        $control.Height = 28
        # Default to yesterday for reports
        if (-not $defaultValue) {
          $control.SelectedDate = (Get-Date).AddDays(-1).Date
        } else {
          try { $control.SelectedDate = [DateTime]$defaultValue } catch { }
        }
      }
      'Bool' {
        # CheckBox for Boolean parameters
        $control = New-Object System.Windows.Controls.CheckBox
        $control.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        if ($defaultValue) {
          try { $control.IsChecked = [bool]$defaultValue } catch { }
        }
      }
      'Int' {
        # TextBox with numeric validation hint
        $control = New-Object System.Windows.Controls.TextBox
        $control.Height = 28
        if ($defaultValue) { $control.Text = [string]$defaultValue }
        # Add tooltip for validation
        $control.ToolTip = "Enter an integer value"
      }
      'Array' {
        # Multi-line TextBox for arrays
        $control = New-Object System.Windows.Controls.TextBox
        $control.MinHeight = 60
        $control.AcceptsReturn = $true
        $control.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $control.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        if ($defaultValue) { $control.Text = [string]$defaultValue }
        $control.ToolTip = "Enter JSON array or comma-separated values"
      }
      default {
        # TextBox for String and other types
        $control = New-Object System.Windows.Controls.TextBox
        $control.Height = 28
        if ($defaultValue) { $control.Text = [string]$defaultValue }
      }
    }

    # Make Region and AccessToken read-only if auto-filled
    if (($paramName -eq 'Region' -or $paramName -eq 'AccessToken') -and $defaultValue) {
      $control.IsReadOnly = $true
      $control.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(240, 240, 240))
      $control.ToolTip = "Auto-filled from current session context"
    }

    # Add real-time validation for TextBox controls
    if ($control -is [System.Windows.Controls.TextBox] -and -not $control.IsReadOnly) {
      # Tag control with metadata for validation
      $control.Tag = @{
        ParameterName = $paramName
        Required = $paramDef.Required
        Type = $paramType
      }

      # Add LostFocus event for validation feedback
      $control.Add_LostFocus({
        $tag = $this.Tag
        if ($tag.Required -and [string]::IsNullOrWhiteSpace($this.Text)) {
          # Required field is empty - show red border
          $this.BorderBrush = [System.Windows.Media.Brushes]::Red
          $this.BorderThickness = New-Object System.Windows.Thickness(2)
          $this.ToolTip = "$($tag.ParameterName) is required"
        } else {
          # Valid input - show green border
          $this.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(34, 197, 94)) # Green
          $this.BorderThickness = New-Object System.Windows.Thickness(1)
          $this.ToolTip = $null
        }
      }.GetNewClosure())
    }

    $control.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($control, 2)
    [void]$paramGrid.Children.Add($control)

    $script:ParameterControls[$paramName] = $control
    [void]$h.PnlParameters.Children.Add($paramGrid)
  }
}

function script:Get-ParameterValues {
  <#
  .SYNOPSIS
    Returns parameter values from UI controls with type conversion.

  .DESCRIPTION
    Reads values from parameter controls created by Build-ParameterPanel
    and converts them to appropriate types based on control type.
    Handles DateTime, Bool, Int, Array, and String conversions.

  .OUTPUTS
    Hashtable of parameter name -> typed value
  #>
  $values = @{}
  if (-not $script:ParameterControls) { return $values }

  foreach ($k in $script:ParameterControls.Keys) {
    $c = $script:ParameterControls[$k]
    if ($null -eq $c) { continue }

    if ($c -is [System.Windows.Controls.CheckBox]) {
      # Boolean parameter
      $values[$k] = [bool]$c.IsChecked
    } elseif ($c -is [System.Windows.Controls.DatePicker]) {
      # DateTime parameter
      if ($c.SelectedDate) {
        $values[$k] = $c.SelectedDate
      }
    } else {
      # TextBox - need to parse based on content
      $text = Get-UiTextSafe -Control $c

      # Skip conversion for empty strings
      if ([string]::IsNullOrWhiteSpace($text)) {
        $values[$k] = $text
        continue
      }

      # Try to detect if this should be an array
      # Pattern: starts with [ OR contains comma (but comma could be in a single number like 1,000)
      # So we check: starts with [ OR (contains comma AND not purely numeric with optional commas)
      if ($text -match '^\s*\[') {
        # Definitely a JSON array
        try {
          $values[$k] = ($text | ConvertFrom-Json)
        } catch {
          # Fall back to treating as string
          $values[$k] = $text
        }
      } elseif ($text -match ',') {
        # Contains comma - check if it's a number with thousand separators or an array
        $testNumeric = $text -replace '[,\s]', ''
        if ($testNumeric -match '^\d+$') {
          # Looks like a number with thousand separators (e.g., "1,000")
          try {
            $values[$k] = [int]($text -replace ',', '')
          } catch {
            $values[$k] = $text
          }
        } else {
          # Treat as comma-separated array
          $values[$k] = @($text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
      } elseif ($text -match '^\s*-?\d+\s*$') {
        # Looks like an integer (with optional negative sign)
        try {
          $values[$k] = [int]$text
        } catch {
          # If it fails to parse, keep as string - validation will catch this later
          Write-GcTrace -Level 'WARN' -Message "Failed to parse '$text' as integer for parameter '$k'"
          $values[$k] = $text
        }
      } elseif ($text -match '^\s*(true|false)\s*$') {
        # Looks like a boolean
        $values[$k] = ($text.Trim() -eq 'true')
      } else {
        # String value
        $values[$k] = $text
      }
    }
  }
  return $values
}

function script:Validate-ReportParameters {
  <#
  .SYNOPSIS
    Validates report parameters against template requirements.

  .DESCRIPTION
    Checks that all required parameters have values and returns
    validation errors as a string array.

  .PARAMETER Template
    The report template definition

  .PARAMETER ParameterValues
    The hashtable of parameter values from Get-ParameterValues

  .OUTPUTS
    Array of error messages (empty if valid)
  #>
  param(
    [Parameter(Mandatory=$true)]$Template,
    [Parameter(Mandatory=$true)][hashtable]$ParameterValues
  )

  $errors = @()

  if (-not $Template.Parameters) { return $errors }

  foreach ($paramName in $Template.Parameters.Keys) {
    $paramDef = $Template.Parameters[$paramName]

    if ($paramDef.Required) {
      $value = $ParameterValues[$paramName]
      $isEmpty = $false

      if ($null -eq $value) {
        $isEmpty = $true
      } elseif ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
        $isEmpty = $true
      } elseif ($value -is [array] -and $value.Count -eq 0) {
        $isEmpty = $true
      }

      if ($isEmpty) {
        $errors += "Required parameter '$paramName' is missing or empty"
      }
    }

    # Type-specific validation
    if ($ParameterValues.ContainsKey($paramName)) {
      $value = $ParameterValues[$paramName]
      $paramType = if ($paramDef.Type) { $paramDef.Type } else { 'String' }

      if ($paramType -eq 'Int' -and $value -is [string]) {
        try {
          [int]$value | Out-Null
        } catch {
          $errors += "Parameter '$paramName' must be an integer"
        }
      }
    }
  }

  return $errors
}

### END: Reports helpers (script-scope; safe for event handlers)


### BEGIN: UI → State → API Parameter Plumbing Helpers

function Get-UiTextSafe {
  <#
  .SYNOPSIS
    Safely retrieves text from a UI control without null reference errors.

  .DESCRIPTION
    Returns the text value from a TextBox, TextBlock, or similar control.
    Returns empty string if control is null or doesn't have a Text property.
    Trims whitespace and handles null coalescing.

  .PARAMETER Control
    The UI control to read text from.

  .EXAMPLE
    $region = Get-UiTextSafe -Control $h.TxtRegion
  #>
  param([AllowNull()]$Control)

  if ($null -eq $Control) { return '' }

  try {
    $text = $Control.Text
    if ($null -eq $text) { return '' }
    return [string]$text.Trim()
  } catch {
    return ''
  }
}

function Get-UiSelectionSafe {
  <#
  .SYNOPSIS
    Safely retrieves the selected item from a selection control without null reference errors.

  .DESCRIPTION
    Returns the SelectedItem from a ComboBox, ListBox, or DataGrid.
    Returns null if control is null or has no selection.

  .PARAMETER Control
    The selection control to read from.

  .EXAMPLE
    $selectedTemplate = Get-UiSelectionSafe -Control $h.LstTemplates
  #>
  param([AllowNull()]$Control)

  if ($null -eq $Control) { return $null }

  try {
    return $Control.SelectedItem
  } catch {
    return $null
  }
}

# (Sync-AppStateFromUi, Get-CallContext extracted to App/AppState.ps1)

### END: UI → State → API Parameter Plumbing Helpers


function Format-EventSummary {
  <#
  .SYNOPSIS
    Formats an event object into a friendly one-line summary for display.

  .DESCRIPTION
    Converts structured event objects into human-readable one-line summaries
    for display in the Live Event Stream list. Preserves object structure
    while providing consistent, readable formatting.

  .PARAMETER Event
    The event object to format. Should contain ts, severity, topic, conversationId, and raw properties.

  .EXAMPLE
    Format-EventSummary -Event $eventObject
    # Returns: "[13:20:15.123] [warn] audiohook.transcription.final  conv=c-123456  — Caller: I'm having trouble..."
  #>
  param(
    [Parameter(Mandatory)]
    [object]$Event
  )

  # Format timestamp consistently - handle both DateTime objects and strings
  $ts = if ($Event.ts) {
    if ($Event.ts -is [DateTime]) {
      $Event.ts.ToString('HH:mm:ss.fff')
    } else {
      $Event.ts.ToString()
    }
  } else {
    (Get-Date).ToString('HH:mm:ss.fff')
  }

  $sev = if ($Event.severity) { $Event.severity } else { 'info' }
  $topic = if ($Event.topic) { $Event.topic } else { 'unknown' }
  $conv = if ($Event.conversationId) { $Event.conversationId } else { 'n/a' }

  # Extract text - check Event.text first (direct field), then raw.eventBody.text
  $text = ''
  if ($Event.text) {
    $text = $Event.text
  } elseif ($Event.raw -and $Event.raw.eventBody -and $Event.raw.eventBody.text) {
    $text = $Event.raw.eventBody.text
  }

  return "[$ts] [$sev] $topic  conv=$conv  —  $text"
}

function New-Artifact {
  param([string]$Name, [string]$Path)
  [pscustomobject]@{
    Name    = $Name
    Path    = $Path
    Created = Get-Date
  }
}

$script:ControlTooltipCache = @{}
$script:PrimaryActionHandleMaps = [System.Collections.Generic.List[hashtable]]::new()

function Set-ControlEnabled {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)] $Control,
    [Parameter(Mandatory=$true)] [bool] $Enabled,
    [string] $DisabledReason
  )

  if ($null -eq $Control) { return }

  try {
    if ($Control -is [System.Windows.Threading.DispatcherObject] -and -not $Control.Dispatcher.CheckAccess()) {
      $Control.Dispatcher.Invoke(([action]{ Set-ControlEnabled -Control $Control -Enabled $Enabled -DisabledReason $DisabledReason }))
      return
    }
  } catch { }

  # WPF
  if ($Control.PSObject.Properties.Match('IsEnabled').Count -gt 0) {
    try { $Control.IsEnabled = $Enabled } catch { }
  }

  # WinForms
  if ($Control.PSObject.Properties.Match('Enabled').Count -gt 0) {
    try { $Control.Enabled = $Enabled } catch { }
  }

  # Attach clear disabled-reason tooltips so "greyed out" controls explain why.
  if ($Control.PSObject.Properties.Match('ToolTip').Count -gt 0) {
    $key = [string][System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Control)

    if ($Enabled) {
      if ($script:ControlTooltipCache.ContainsKey($key)) {
        try { $Control.ToolTip = $script:ControlTooltipCache[$key] } catch { }
        $script:ControlTooltipCache.Remove($key) | Out-Null
      }
      return
    }

    if (-not $script:ControlTooltipCache.ContainsKey($key)) {
      try { $script:ControlTooltipCache[$key] = $Control.ToolTip } catch { $script:ControlTooltipCache[$key] = $null }
    }

    $reason = $DisabledReason
    if ([string]::IsNullOrWhiteSpace($reason)) {
      try {
        if ($Control.ToolTip -and -not [string]::IsNullOrWhiteSpace([string]$Control.ToolTip)) {
          $reason = [string]$Control.ToolTip
        }
      } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($reason)) {
      $reason = 'This option is currently unavailable. Complete required prerequisites or wait for the current action to finish.'
    }

    try { $Control.ToolTip = $reason } catch { }
  }
}

### BEGIN: AUTH_READY_BUTTON_ENABLE_HELPERS
function Test-AuthReady {
  <#
    Auth-ready means we can let the UI do work:
    - Offline demo mode is enabled (no real token required)
    - OR a real token is present
  #>

  try {
    if (Get-Command Test-OfflineDemoEnabled -ErrorAction SilentlyContinue) {
      if (Test-OfflineDemoEnabled) { return $true }
    }
  } catch { }

  return (-not [string]::IsNullOrWhiteSpace($script:AppState.AccessToken))
}

function Get-AuthUnavailableReason {
  [CmdletBinding()]
  param()

  if (Test-AuthReady) { return $null }
  return 'Authentication required. Open Backstage > Authentication and sign in, or set/test an access token.'
}

function Get-PrimaryActionKeys {
  [CmdletBinding()]
  param()

  return @(
    'BtnQueueLoad',
    'BtnSkillLoad',
    'BtnUserLoad',
    'BtnFlowLoad',
    'BtnConvSearch',
    'BtnGeneratePacket',
    'BtnAbandonQuery',
    'BtnSearchReferences',
    'BtnSnapshotRefresh',
    'BtnStart',
    'BtnRunReport',
    'BtnAuditRun'
  )
}

function Enable-PrimaryActionButtons {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]
    [hashtable]$Handles,
    [switch]$SkipRegistration
  )

  if ($null -eq $Handles) { return }

  if (-not $SkipRegistration) {
    $already = $false
    foreach ($map in @($script:PrimaryActionHandleMaps)) {
      if ([object]::ReferenceEquals($map, $Handles)) { $already = $true; break }
    }
    if (-not $already) { [void]$script:PrimaryActionHandleMaps.Add($Handles) }
  }

  $canRun = Test-AuthReady
  $authReason = if ($canRun) { $null } else { Get-AuthUnavailableReason }

  foreach ($k in (Get-PrimaryActionKeys)) {
    if ($Handles.ContainsKey($k) -and $Handles[$k]) {
      Set-ControlEnabled -Control $Handles[$k] -Enabled $canRun -DisabledReason $authReason
    }
  }
}

function Refresh-PrimaryActionButtons {
  [CmdletBinding()]
  param()

  foreach ($handles in @($script:PrimaryActionHandleMaps)) {
    try {
      Enable-PrimaryActionButtons -Handles $handles -SkipRegistration
    } catch {
      # Intentional: a single handle map failing must not prevent the others from refreshing.
      Write-Verbose "[Refresh-PrimaryActionButtons] Suppressed per-map error: $_"
    }
  }
}

function Apply-DisabledReasonsToView {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)] $Root
  )

  if ($null -eq $Root) { return }

  $defaultReason = if (Test-AuthReady) {
    'This option is unavailable until required data is loaded or prerequisites are complete for this module.'
  } else {
    Get-AuthUnavailableReason
  }

  $queue = [System.Collections.Queue]::new()
  $queue.Enqueue($Root)

  while ($queue.Count -gt 0) {
    $node = $queue.Dequeue()
    if ($null -eq $node) { continue }

    try {
      if ($node -is [System.Windows.Controls.Primitives.ButtonBase]) {
        $enabled = $true
        try { $enabled = [bool]$node.IsEnabled } catch { $enabled = $true }
        if (-not $enabled) {
          $hasTooltip = $false
          try {
            $tipText = if ($null -ne $node.ToolTip) { [string]$node.ToolTip } else { '' }
            $hasTooltip = -not [string]::IsNullOrWhiteSpace($tipText)
          } catch { $hasTooltip = $false }

          if (-not $hasTooltip) {
            Set-ControlEnabled -Control $node -Enabled $false -DisabledReason $defaultReason
          }
        }
      }
    } catch { }

    try {
      $childCount = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
      for ($i = 0; $i -lt $childCount; $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($node, $i)
        if ($null -ne $child) { $queue.Enqueue($child) }
      }
    } catch { }
  }
}

### END: AUTH_READY_BUTTON_ENABLE_HELPERS

function Add-ClickSafe {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)] $Control,
    [Parameter(Mandatory=$true)] [scriptblock] $Handler
  )

  if ($null -eq $Control) { return }

  # Most WPF/WinForms objects exposed in PS will support Add_Click
  if ($Control.PSObject.Methods.Match('Add_Click').Count -gt 0) {
    try { $Control.Add_Click($Handler); return } catch { }
  }

  # Fallback: do nothing
}
function Start-AppJob {
  <#
  .SYNOPSIS
    Starts a background job using PowerShell runspaces - simplified API.

  .DESCRIPTION
    Provides a simplified API for starting background jobs that:
    - Run script blocks in background runspaces
    - Stream log lines back to the UI via thread-safe collections
    - Support cancellation via CancelRequested flag
    - Track Status: Queued/Running/Completed/Failed/Canceled
    - Capture StartTime/EndTime/Duration

  .PARAMETER Name
    Human-readable job name

  .PARAMETER ScriptBlock
    Script block to execute in background runspace

  .PARAMETER ArgumentList
    Arguments to pass to the script block

  .PARAMETER OnCompleted
    Script block to execute when job completes (runs on UI thread)

  .PARAMETER Type
    Job type category (default: 'General')

  .EXAMPLE
    Start-AppJob -Name "Test Job" -ScriptBlock { Start-Sleep 2; "Done" } -OnCompleted { param($job) Write-Host "Completed!" }

  .NOTES
    This is a wrapper around New-GcJobContext and Start-GcJob from JobRunner.psm1.
    Compatible with PowerShell 5.1 and 7+.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [scriptblock]$ScriptBlock,

    [object[]]$ArgumentList = @(),

    [scriptblock]$OnCompleted,

    [string]$Type = 'General'
  )

  # Create job context using JobRunner
  $job = New-GcJobContext -Name $Name -Type $Type

  # Add to app state jobs collection
  $script:AppState.Jobs.Add($job) | Out-Null
  Add-GcJobLog -Job $job -Message "Queued."
  Write-GcTrace -Level 'JOB' -Message ("Queued job: Name='{0}' Type='{1}'" -f $Name, $Type)
  try { Write-GcAppLog -Level 'JOB' -Category 'job' -Message 'Queued job' -Data @{ Name = $Name; Type = $Type } } catch { }

  # Start the job in a fresh runspace that needs:
  # - core modules imported (Invoke-GcRequest, Invoke-GcPagedRequest, Export-GcConversationPacket, etc.)
  # - minimal AppState available for older job scriptblocks that reference $script:AppState.*
  $coreRootForJob = $null
  try { $coreRootForJob = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'Core' } catch { $coreRootForJob = $null }
  if (-not $coreRootForJob) { $coreRootForJob = $coreRoot }

  $appStateSnapshot = [pscustomobject]@{
    Region         = $script:AppState.Region
    AccessToken    = $script:AppState.AccessToken
    RepositoryRoot = $script:AppState.RepositoryRoot
  }
  $artifactsDirSnapshot = $script:ArtifactsDir
  $userScriptText = $ScriptBlock.ToString()
  $userArgs = if ($null -eq $ArgumentList) { @() } else { @($ArgumentList) }

  $wrappedScriptBlock = {
    param(
      [string]$coreRoot,
      [object]$appState,
      [string]$artifactsDir,
      [string]$userScriptText,
      [object[]]$userArgs
    )

    # Provide expected script-scope variables used by existing job scriptblocks.
    $script:AppState = $appState
    $script:ArtifactsDir = $artifactsDir

    # Ensure core cmdlets exist in this runspace.
    $modules = @(
      'HttpRequests.psm1'
      'RoutingPeople.psm1'
      'ConversationsExtended.psm1'
      'Timeline.psm1'
      'ArtifactGenerator.psm1'
      'ConfigExport.psm1'
      'Analytics.psm1'
      'Dependencies.psm1'
      'Reporting.psm1'
      'ReportTemplates.psm1'
      'Jobs.psm1'
      'Auth.psm1'
      'Subscriptions.psm1'
    )

    foreach ($m in $modules) {
      try {
        $p = Join-Path -Path $coreRoot -ChildPath $m
        if (Test-Path $p) { Import-Module $p -Force -ErrorAction Stop }
      } catch { }
    }

    # Allow HttpRequests helpers to auto-inject Region/AccessToken when used.
    try { Set-GcAppState -State ([ref]$script:AppState) } catch { }

    $sb = [scriptblock]::Create($userScriptText)
    & $sb @userArgs
  }

  $onComplete = $null
  if ($OnCompleted) {
    $userOnCompleted = $OnCompleted
    $onComplete = {
      param($job)
      try {
        $resultKeys = @()
        try { if ($job -and $job.Result) { $resultKeys = @($job.Result.PSObject.Properties.Name) } } catch { $resultKeys = @() }
        Write-GcAppLog -Level 'JOB' -Category 'job' -Message 'Job completed' -Data @{
          Name      = (try { [string]$job.Name } catch { '' })
          Type      = (try { [string]$job.Type } catch { '' })
          Status    = (try { [string]$job.Status } catch { '' })
          ErrorCount = (try { @($job.Errors).Count } catch { 0 })
          ResultKeys = $resultKeys
        }
      } catch { }
      & $userOnCompleted $job
    }.GetNewClosure()
  }

  Start-GcJob -Job $job -ScriptBlock $wrappedScriptBlock -ArgumentList @(
    $coreRootForJob,
    $appStateSnapshot,
    $artifactsDirSnapshot,
    $userScriptText,
    $userArgs
  ) -OnComplete $onComplete

  return $job
}

# -----------------------------
# Timeline Job Helper
# -----------------------------
# Shared scriptblock for timeline retrieval to avoid duplication
$script:TimelineJobScriptBlock = {
  param($conversationId, $region, $accessToken, $eventBuffer)

  try {
    Write-Output "Querying analytics for conversation $conversationId..."

    # Build analytics query body
    $queryBody = @{
      conversationFilters = @(
        @{
          type = 'and'
          predicates = @(
            @{
              dimension = 'conversationId'
              value = $conversationId
            }
          )
        }
      )
      order = 'asc'
      orderBy = 'conversationStart'
    }

    # Submit analytics job
    Write-Output "Submitting analytics job..."
    $jobResponse = Invoke-GcRequest `
      -Method POST `
      -Path '/api/v2/analytics/conversations/details/jobs' `
      -Body $queryBody `
      -InstanceName $region `
      -AccessToken $accessToken

    $jobId = $jobResponse.id
    if (-not $jobId) { throw "No job ID returned from analytics API." }

    Write-Output "Job submitted: $jobId. Waiting for completion..."

    # Poll for completion
    $maxAttempts = 120  # 2 minutes max (120 * 1 second)
    $attempt = 0
    $completed = $false

    while ($attempt -lt $maxAttempts) {
      Start-Sleep -Milliseconds 1000
      $attempt++

      $status = Invoke-GcRequest `
        -Method GET `
        -Path "/api/v2/analytics/conversations/details/jobs/$jobId" `
        -InstanceName $region `
        -AccessToken $accessToken

      if ($status.state -match 'FULFILLED|COMPLETED|SUCCESS') {
        $completed = $true
        Write-Output "Job completed successfully."
        break
      }

      if ($status.state -match 'FAILED|ERROR') {
        throw "Analytics job failed: $($status.state)"
      }
    }

    if (-not $completed) {
      throw "Analytics job timed out after $maxAttempts seconds."
    }

    # Fetch results
    Write-Output "Fetching results..."
    $results = Invoke-GcRequest `
      -Method GET `
      -Path "/api/v2/analytics/conversations/details/jobs/$jobId/results" `
      -InstanceName $region `
      -AccessToken $accessToken

    if (-not $results.conversations -or $results.conversations.Count -eq 0) {
      throw "No conversation data found for ID: $conversationId"
    }

    Write-Output "Retrieved conversation data. Building timeline..."

    $conversationData = $results.conversations[0]

    # Filter subscription events for this conversation
    $relevantSubEvents = @()
    if ($eventBuffer -and $eventBuffer.Count -gt 0) {
      foreach ($evt in $eventBuffer) {
        if ($evt.conversationId -eq $conversationId) {
          $relevantSubEvents += $evt
        }
      }
      Write-Output "Found $($relevantSubEvents.Count) subscription events for this conversation."
    }

    # Convert to timeline events
    $timeline = ConvertTo-GcTimeline `
      -ConversationData $conversationData `
      -AnalyticsData $conversationData `
      -SubscriptionEvents $relevantSubEvents

    Write-Output "Timeline built with $($timeline.Count) events."

    # Add "Live Events" category for subscription events
    if ($relevantSubEvents.Count -gt 0) {
      $liveEventsAdded = 0
      foreach ($subEvt in $relevantSubEvents) {
        try {
          # Parse event timestamp with error handling
          $eventTime = $null
          if ($subEvt.ts -is [datetime]) {
            $eventTime = $subEvt.ts
          } elseif ($subEvt.ts) {
            $eventTime = [datetime]::Parse($subEvt.ts)
          } else {
            Write-Warning "Subscription event missing timestamp, skipping: $($subEvt.topic)"
            continue
          }

          # Create live event
          $timeline += New-GcTimelineEvent `
            -Time $eventTime `
            -Category 'Live Events' `
            -Label "$($subEvt.topic): $($subEvt.text)" `
            -Details $subEvt `
            -CorrelationKeys @{
              conversationId = $conversationId
              eventType = $subEvt.topic
            }

          $liveEventsAdded++
        } catch {
          Write-Warning "Failed to parse subscription event timestamp: $_"
          continue
        }
      }

      # Re-sort timeline
      $timeline = $timeline | Sort-Object -Property Time
      Write-Output "Added $liveEventsAdded live events to timeline."
    }

    return @{
      ConversationId = $conversationId
      ConversationData = $conversationData
      Timeline = $timeline
      SubscriptionEvents = $relevantSubEvents
    }

  } catch {
    Write-Error "Failed to build timeline: $_"
    throw
  }
}

# ($script:WorkspaceModules extracted to App/AppState.ps1)
# ($script:AddonsByRoute extracted to App/AppState.ps1)

# -----------------------------
# Addons (manifest-driven)
# -----------------------------

function Get-GcAddonDefinitions {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$AddonsRoot)

  if (-not (Test-Path -LiteralPath $AddonsRoot)) { return @() }

  $files = @(
    Get-ChildItem -Path $AddonsRoot -Recurse -File -Filter '*.addon.psd1' -ErrorAction SilentlyContinue
  )

  $out = New-Object System.Collections.Generic.List[object]
  foreach ($f in $files) {
    if ($f.FullName -match '[\\/]\_Template[\\/]') { continue }

    $data = $null
    try {
      $data = Import-PowerShellDataFile -Path $f.FullName
    } catch {
      Write-GcTrace -Level 'ADDON' -Message ("Failed to read addon manifest: {0} ({1})" -f $f.FullName, $_.Exception.Message)
      continue
    }

    $workspace = [string]$data.Workspace
    $module = [string]$data.Module
    $entryRel = [string]$data.EntryPoint
    if (-not $workspace -or -not $module -or -not $entryRel) {
      Write-GcTrace -Level 'ADDON' -Message ("Invalid addon manifest (missing Workspace/Module/EntryPoint): {0}" -f $f.FullName)
      continue
    }

    $manifestDir = Split-Path -Parent $f.FullName
    $entryPath = Join-Path -Path $manifestDir -ChildPath $entryRel

    $out.Add([pscustomobject]@{
      Id          = [string]$data.Id
      Name        = [string]$data.Name
      Version     = [string]$data.Version
      Workspace   = $workspace
      Module      = $module
      Description = [string]$data.Description
      ManifestPath = $f.FullName
      EntryPointPath = $entryPath
      ViewFactory = [string]$data.ViewFactory
      Loaded      = $false
    }) | Out-Null
  }

  @($out)
}

function Initialize-GcAddons {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$RepoRoot)

  $script:AddonsByRoute = @{}
  $addonsRoot = Join-Path -Path $RepoRoot -ChildPath 'Addons'

  foreach ($a in @(Get-GcAddonDefinitions -AddonsRoot $addonsRoot)) {
    if (-not $script:WorkspaceModules.Contains($a.Workspace)) {
      $addonIdentity = if (-not [string]::IsNullOrWhiteSpace([string]$a.Name)) {
        [string]$a.Name
      } elseif (-not [string]::IsNullOrWhiteSpace([string]$a.Id)) {
        [string]$a.Id
      } else {
        [string]$a.Module
      }
      Write-GcTrace -Level 'ADDON' -Message ("Addon '{0}' ignored: unknown workspace '{1}'." -f $addonIdentity, $a.Workspace)
      continue
    }

    $route = ("{0}::{1}" -f $a.Workspace, $a.Module)
    if ($script:AddonsByRoute.ContainsKey($route)) {
      Write-GcTrace -Level 'ADDON' -Message ("Addon route duplicate ignored: {0}" -f $route)
      continue
    }

    # Surface addon as a module under its target workspace
    $mods = @($script:WorkspaceModules[$a.Workspace])
    if ($mods -notcontains $a.Module) {
      $script:WorkspaceModules[$a.Workspace] = @($mods + $a.Module)
    }

    $script:AddonsByRoute[$route] = $a
  }

  Write-GcTrace -Level 'ADDON' -Message ("Addons loaded: {0}" -f $script:AddonsByRoute.Count)
}

function Ensure-GcAddonLoaded {
  [CmdletBinding()]
  param([Parameter(Mandatory)][pscustomobject]$Addon)

  if ($Addon.Loaded) { return }

  if (-not (Test-Path -LiteralPath $Addon.EntryPointPath)) {
    throw "Addon entry point not found: $($Addon.EntryPointPath)"
  }

  . $Addon.EntryPointPath
  $Addon.Loaded = $true
}

function New-GcAddonLauncherView {
  [CmdletBinding()]
  param([Parameter(Mandatory)][pscustomobject]$Addon)

  $name = if ($Addon.Name) { [string]$Addon.Name } else { [string]$Addon.Module }
  $desc = if ($Addon.Description) { [string]$Addon.Description } else { 'This addon does not provide an in-app view factory. Use the shortcuts below.' }

  $escapedName = Escape-GcXml $name
  $escapedDesc = Escape-GcXml $desc
  $escapedManifest = Escape-GcXml ([string]$Addon.ManifestPath)
  $escapedEntry = Escape-GcXml ([string]$Addon.EntryPointPath)

  $xaml = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Border CornerRadius="10" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="14">
      <StackPanel>
        <TextBlock Text="$escapedName" FontSize="16" FontWeight="SemiBold" Foreground="#FF111827"/>
        <TextBlock Text="$escapedDesc" Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>

        <TextBlock Text="Manifest:" Margin="0,14,0,0" Foreground="#FF374151" FontWeight="SemiBold"/>
        <TextBlock Text="$escapedManifest" Foreground="#FF6B7280" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11"/>

        <TextBlock Text="Entry:" Margin="0,10,0,0" Foreground="#FF374151" FontWeight="SemiBold"/>
        <TextBlock Text="$escapedEntry" Foreground="#FF6B7280" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11"/>

        <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
          <Button x:Name="BtnOpenAddonFolder" Content="Open Folder" Height="30" Width="110" Margin="0,0,10,0" IsEnabled="True"/>
          <Button x:Name="BtnOpenEntry" Content="Open Entry" Height="30" Width="110" Margin="0,0,10,0" IsEnabled="True"/>
          <Button x:Name="BtnOpenManifest" Content="Open Manifest" Height="30" Width="120" Margin="0,0,0,0" IsEnabled="True"/>
        </StackPanel>
      </StackPanel>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xaml
  $btnFolder = $view.FindName('BtnOpenAddonFolder')
  $btnEntry = $view.FindName('BtnOpenEntry')
  $btnManifest = $view.FindName('BtnOpenManifest')

  $btnFolder.Add_Click({
    try {
      $dir = Split-Path -Parent $Addon.EntryPointPath
      if (Test-Path $dir) { Start-Process -FilePath $dir | Out-Null }
    } catch { }
  }.GetNewClosure())

  $btnEntry.Add_Click({
    try { if (Test-Path $Addon.EntryPointPath) { Start-Process -FilePath $Addon.EntryPointPath | Out-Null } } catch { }
  }.GetNewClosure())

  $btnManifest.Add_Click({
    try { if (Test-Path $Addon.ManifestPath) { Start-Process -FilePath $Addon.ManifestPath | Out-Null } } catch { }
  }.GetNewClosure())

  $view
}

function Get-GcAddonView {
  [CmdletBinding()]
  param([Parameter(Mandatory)][pscustomobject]$Addon)

  $addonTitle = if (-not [string]::IsNullOrWhiteSpace([string]$Addon.Name)) {
    [string]$Addon.Name
  } else {
    [string]$Addon.Module
  }

  try {
    Ensure-GcAddonLoaded -Addon $Addon
  } catch {
    return New-PlaceholderView -Title $addonTitle -Hint ("Failed to load addon: {0}" -f $_.Exception.Message)
  }

  if ($Addon.ViewFactory) {
    $cmd = Get-Command -Name $Addon.ViewFactory -ErrorAction SilentlyContinue
    if ($cmd) {
      try {
        return & $cmd -Addon $Addon
      } catch {
        return New-PlaceholderView -Title $addonTitle -Hint ("Addon view factory failed: {0}" -f $_.Exception.Message)
      }
    }
  }

  New-GcAddonLauncherView -Addon $Addon
}

try {
  Initialize-GcAddons -RepoRoot $repoRoot
} catch {
  Write-GcTrace -Level 'ADDON' -Message ("Addon initialization failed: {0}" -f $_.Exception.Message)
}

# -----------------------------
# XAML - App Shell + Backstage + Snackbar (extracted to App/Shell.xaml)
# -----------------------------
$xamlString = Get-Content -LiteralPath (Join-Path $scriptRoot 'Shell.xaml') -Raw

$global:Window = ConvertFrom-GcXaml -XamlString $xamlString

function Get-El([string]$name) { $global:Window.FindName($name) }

# Top bar
$global:TxtContext   = Get-El 'TxtContext'
$global:BtnAuth      = Get-El 'BtnAuth'
$global:BtnBackstage = Get-El 'BtnBackstage'
$global:TxtCommand   = Get-El 'TxtCommand'

# Nav
$global:NavWorkspaces   = Get-El 'NavWorkspaces'
$global:NavModules      = Get-El 'NavModules'
$global:TxtModuleHeader = Get-El 'TxtModuleHeader'
$global:TxtModuleHint   = Get-El 'TxtModuleHint'

# Header + content
$global:TxtTitle    = Get-El 'TxtTitle'
$global:TxtSubtitle = Get-El 'TxtSubtitle'
$global:MainHost    = Get-El 'MainHost'
$global:TxtStatus     = Get-El 'TxtStatus'
$global:TxtStats      = Get-El 'TxtStats'
$global:TxtCoreStatus = Get-El 'TxtCoreStatus'

# Backstage
$global:BackstageOverlay = Get-El 'BackstageOverlay'
$global:BackstageTabs    = Get-El 'BackstageTabs'
$global:BtnCloseBackstage= Get-El 'BtnCloseBackstage'
$global:LstJobs          = Get-El 'LstJobs'
$global:TxtJobMeta       = Get-El 'TxtJobMeta'
$global:BtnCancelJob     = Get-El 'BtnCancelJob'
$global:LstJobLogs       = Get-El 'LstJobLogs'

$global:LstArtifacts            = Get-El 'LstArtifacts'
$global:BtnOpenArtifactsFolder  = Get-El 'BtnOpenArtifactsFolder'
$global:BtnOpenSelectedArtifact = Get-El 'BtnOpenSelectedArtifact'

# Integration tab controls
$global:CoreStatusBanner   = Get-El 'CoreStatusBanner'
$global:TxtCoreStatusIcon  = Get-El 'TxtCoreStatusIcon'
$global:TxtCoreStatusLabel = Get-El 'TxtCoreStatusLabel'
$global:TxtCoreStatusDetail= Get-El 'TxtCoreStatusDetail'
$global:TxtCorePath        = Get-El 'TxtCorePath'
$global:BtnCoreBrowse      = Get-El 'BtnCoreBrowse'
$global:BtnCoreSave        = Get-El 'BtnCoreSave'
$global:BtnCoreReset       = Get-El 'BtnCoreReset'

# Snackbar
$global:SnackbarHost      = Get-El 'SnackbarHost'
$global:SnackbarTitle     = Get-El 'SnackbarTitle'
$global:SnackbarBody      = Get-El 'SnackbarBody'
$global:BtnSnackPrimary   = Get-El 'BtnSnackPrimary'
$global:BtnSnackSecondary = Get-El 'BtnSnackSecondary'
$global:BtnSnackClose     = Get-El 'BtnSnackClose'

function Publish-GcScriptFunctionsToGlobal {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ScriptPath)

  $resolvedScript = $null
  try { $resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path } catch { $resolvedScript = $ScriptPath }
  if (-not $resolvedScript) { return }

  $funcs = Get-Command -CommandType Function -ErrorAction SilentlyContinue | Where-Object {
    $_.ScriptBlock -and $_.ScriptBlock.File
  }

  foreach ($cmd in $funcs) {
    $file = $null
    try { $file = (Resolve-Path -LiteralPath $cmd.ScriptBlock.File -ErrorAction SilentlyContinue).Path } catch { $file = $cmd.ScriptBlock.File }
    if (-not $file) { continue }
    if ($file -ne $resolvedScript) { continue }

    try {
      $existing = Get-Command -Name $cmd.Name -CommandType Function -ErrorAction SilentlyContinue
      if ($existing -and $existing.ScriptBlock -and $existing.ScriptBlock.File) {
        $existingFile = $null
        try { $existingFile = (Resolve-Path -LiteralPath $existing.ScriptBlock.File -ErrorAction SilentlyContinue).Path } catch { $existingFile = $existing.ScriptBlock.File }
        if ($existingFile -and $existingFile -ne $resolvedScript) { continue }
      }

      Set-Item -Path ("function:global:{0}" -f $cmd.Name) -Value $cmd.ScriptBlock
    } catch { }
  }
}

# -----------------------------
# Control Helpers
# -----------------------------

function Set-ControlValue {
  <#
  .SYNOPSIS
    Safely sets the value of a WPF control (Text, Content, or SelectedItem).

  .DESCRIPTION
    Detects the control type and sets the appropriate property.
    Handles TextBox, TextBlock, Label, ComboBox, and ContentControl types.
    Silently skips if control is null or property doesn't exist.

  .PARAMETER Control
    WPF control to update

  .PARAMETER Value
    Value to set

  .EXAMPLE
    Set-ControlValue -Control $TxtSearch -Value "Search text"
  #>
  param(
    [object]$Control,
    [object]$Value
  )

  if ($null -eq $Control) {
    Write-Verbose "Set-ControlValue: Control is null, skipping"
    return
  }

  $controlType = $Control.GetType().Name

  try {
    # Try Text property first (TextBox, TextBlock)
    if ($Control.PSObject.Properties['Text']) {
      $Control.Text = $Value
      return
    }

    # Try Content property (Label, Button, ContentControl)
    if ($Control.PSObject.Properties['Content']) {
      $Control.Content = $Value
      return
    }

    # Try SelectedItem for ComboBox
    if ($Control.PSObject.Properties['SelectedItem']) {
      $Control.SelectedItem = $Value
      return
    }

    Write-Verbose "Set-ControlValue: Control type '$controlType' doesn't have Text, Content, or SelectedItem property"
  } catch {
    Write-Warning "Set-ControlValue: Failed to set value on control type '$controlType': $_"
  }
}

# -----------------------------
# UI helpers
# -----------------------------
function Set-TopContext {
  $TxtContext.Text = "Region: $($script:AppState.Region)  |  Org: $($script:AppState.Org)  |  Auth: $($script:AppState.Auth)  |  Token: $($script:AppState.TokenStatus)"
  try { Refresh-PrimaryActionButtons } catch { }
  try { Refresh-CoreStatusBar } catch { }
}

function Set-Status([string]$msg) { $TxtStatus.Text = $msg }

$script:OfflineDemoEnvVar = 'GC_TOOLKIT_OFFLINE_DEMO'
$script:OfflineDemoPreviousState = $null

function Test-OfflineDemoEnabled {
  try {
    $v = [Environment]::GetEnvironmentVariable($script:OfflineDemoEnvVar)
    return ($v -and ($v -match '^(1|true|yes|on)$'))
  } catch {
    return $false
  }
}

function Set-OfflineDemoMode {
  param(
    [Parameter(Mandatory)][bool]$Enabled
  )

  if ($Enabled) {
    if (-not $script:OfflineDemoPreviousState) {
      $script:OfflineDemoPreviousState = [pscustomobject]@{
        Region      = $script:AppState.Region
        Org         = $script:AppState.Org
        Auth        = $script:AppState.Auth
        TokenStatus = $script:AppState.TokenStatus
        AccessToken = $script:AppState.AccessToken
        Trace       = [Environment]::GetEnvironmentVariable($script:GcTraceEnvVar)
      }
    }

    [Environment]::SetEnvironmentVariable($script:OfflineDemoEnvVar, '1', 'Process')
    # Enable persistent tracing by default in OfflineDemo to support "click around" debugging.
    try { [Environment]::SetEnvironmentVariable($script:GcTraceEnvVar, '1', 'Process') } catch { }

    $script:AppState.Region = 'offline.local'
    if (-not $script:AppState.AccessToken) { $script:AppState.AccessToken = 'offline-demo' }
    $script:AppState.Auth = 'Offline demo'
    $script:AppState.TokenStatus = 'Offline demo'
    $script:AppState.Org = 'Demo Org (Offline)'

    # Make a known conversation available for quick timeline demos
    $script:AppState.FocusConversationId = 'c-demo-001'

    try {
      if ($BtnAuth) { $BtnAuth.Content = 'Offline (Disable)' }
    } catch { }

    Write-GcTrace -Level 'INFO' -Message "Offline demo enabled"
    try { Set-TopContext } catch { }
    try { Set-Status "Offline demo enabled (sample data)." } catch { }
    return
  }

  [Environment]::SetEnvironmentVariable($script:OfflineDemoEnvVar, $null, 'Process')

  if ($script:OfflineDemoPreviousState) {
    $script:AppState.Region = $script:OfflineDemoPreviousState.Region
    $script:AppState.Org = $script:OfflineDemoPreviousState.Org
    $script:AppState.Auth = $script:OfflineDemoPreviousState.Auth
    $script:AppState.TokenStatus = $script:OfflineDemoPreviousState.TokenStatus
    $script:AppState.AccessToken = $script:OfflineDemoPreviousState.AccessToken
    try { [Environment]::SetEnvironmentVariable($script:GcTraceEnvVar, $script:OfflineDemoPreviousState.Trace, 'Process') } catch { }
    $script:OfflineDemoPreviousState = $null
  } else {
    $script:AppState.AccessToken = $null
    $script:AppState.Auth = 'Not logged in'
    $script:AppState.TokenStatus = 'No token'
    $script:AppState.Org = ''
  }

  try {
    if ($BtnAuth) { $BtnAuth.Content = 'Authentication' }
  } catch { }

  Write-GcTrace -Level 'INFO' -Message $(if ($Enabled) { 'Offline demo enabled' } else { 'Offline demo disabled' })
  try { Set-TopContext } catch { }
  try { Set-Status $(if ($Enabled) { 'Offline demo enabled.' } else { 'Offline demo disabled.' }) } catch { }
}

function Add-OfflineDemoSampleEvents {
  param(
    [int]$Count = 18
  )

  $convIds = @('c-demo-001','c-demo-002','c-demo-003')
  $topics = @(
    'audiohook.transcription.final',
    'audiohook.agentassist.suggestion',
    'audiohook.error'
  )
  $snips = @(
    "Caller: I forgot my password and can't log in.",
    "Agent Assist: Suggest verifying identity (DOB + ZIP).",
    "Agent Assist: Surface KB: Password Reset - Standard Flow.",
    "ERROR: WebRTC jitter spike detected (offline demo)."
  )

  for ($i = 0; $i -lt $Count; $i++) {
    $cid = $convIds[$i % $convIds.Count]
    $topic = $topics[$i % $topics.Count]
    $sev = if ($topic -eq 'audiohook.error') { 'error' } elseif ($topic -like '*agentassist*') { 'warn' } else { 'info' }
    $text = $snips[$i % $snips.Count]
    $ts = (Get-Date).AddMilliseconds(-1 * (250 * $i))

    $raw = @{
      eventId = [guid]::NewGuid().ToString()
      timestamp = $ts.ToString('o')
      topicName = $topic
      eventBody = @{
        conversationId = $cid
        text = $text
        severity = $sev
        queueName = 'Support - Voice'
      }
    }

    $cachedJson = ''
    try { $cachedJson = ($raw | ConvertTo-Json -Compress -Depth 10).ToLower() } catch { }

    $evt = [pscustomobject]@{
      ts = $ts
      severity = $sev
      topic = $topic
      conversationId = $cid
      queueId = $null
      queueName = 'Support - Voice'
      text = $text
      raw = $raw
      _cachedRawJson = $cachedJson
    }

    try { $script:AppState.EventBuffer.Insert(0, $evt) } catch { $script:AppState.EventBuffer.Add($evt) | Out-Null }
    $script:AppState.StreamCount++
  }

  Refresh-HeaderStats
  Set-Status ("Seeded {0} offline demo events. Try Conversation Timeline with {1}." -f $Count, $convIds[0])
  Write-GcTrace -Level 'INFO' -Message ("Offline demo: seeded events Count={0} FocusConversationId={1}" -f $Count, $convIds[0])
}

function Refresh-HeaderStats {
  $jobCount = $script:AppState.Jobs.Count
  $artifactCount = $script:AppState.Artifacts.Count
  $BtnBackstage.Content = "Backstage ($jobCount/$artifactCount)"
  $TxtStats.Text        = "Pinned: $($script:AppState.PinnedCount) | Stream: $($script:AppState.StreamCount)"
  try { Refresh-CoreStatusBar } catch { }
}

function Refresh-CoreStatusBar {
  <#
    Updates the TxtCoreStatus status bar chip and, if the Integration tab controls
    are rendered, synchronizes the banner and path field in Backstage.
  #>
  if (-not $TxtCoreStatus) { return }

  $status = Get-GcCoreStatus

  if ($status.Available) {
    $TxtCoreStatus.Text       = Get-GcCoreStatusLabel
    $TxtCoreStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22C55E')  # green
  } else {
    $TxtCoreStatus.Text       = 'Core: not found'
    $TxtCoreStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF9CA3AF')  # muted grey
  }

  # Sync the Backstage Integration tab if its controls are available
  try {
    if ($TxtCoreStatusLabel) {
      if ($status.Available) {
        $src = switch ($status.DiscoverySource) {
          'config'   { 'saved path (gc-admin.json)' }
          'env'      { 'GC_CORE_MODULE_PATH env var' }
          'sibling'  { 'auto-discovered (sibling directory)' }
          'psmodule' { 'installed PowerShell module' }
          'manual'   { 'manually configured' }
          default    { 'unknown' }
        }
        $ver = if ($status.Version) { " v$($status.Version)" } else { '' }
        $TxtCoreStatusLabel.Text  = "Genesys.Core$ver — connected"
        $TxtCoreStatusDetail.Text = "Found via $src`n$($status.ModulePath)"
        $CoreStatusBanner.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFF0FDF4')
        $CoreStatusBanner.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF86EFAC')
        $TxtCoreStatusIcon.Text       = '●'
        $TxtCoreStatusIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF22C55E')
        if ($TxtCorePath -and [string]::IsNullOrWhiteSpace($TxtCorePath.Text)) {
          $TxtCorePath.Text = $status.ModulePath
        }
      } else {
        $TxtCoreStatusLabel.Text  = 'Genesys.Core — not connected'
        $TxtCoreStatusDetail.Text = $status.LastError
        $CoreStatusBanner.Background  = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFF7ED')
        $CoreStatusBanner.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFBBF24')
        $TxtCoreStatusIcon.Text       = '○'
        $TxtCoreStatusIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFBBF24')
      }
    }
  } catch {
    # Intentional: Integration tab controls may not yet be rendered.
    Write-Verbose "[Refresh-CoreStatusBar] Tab controls not ready: $_"
  }
}

function Refresh-ArtifactsList {
  $LstArtifacts.Items.Clear()
  foreach ($a in $script:AppState.Artifacts) {
    $LstArtifacts.Items.Add("$($a.Created.ToString('MM-dd HH:mm'))  —  $($a.Name)") | Out-Null
  }
  Refresh-HeaderStats
}

### BEGIN: Manual Token Entry
# -----------------------------
# Manual Token Entry Dialog
# -----------------------------

# (Console diagnostics: Format-GcDiagSecret, Write-GcDiag — extracted to App/AppLogger.ps1)

function Start-TokenTest {
  <#
  .SYNOPSIS
    Tests the current access token by calling GET /api/v2/users/me.

  .DESCRIPTION
    Validates the token in AppState.AccessToken by making a test API call.
    Updates UI with test results including user info and organization.
    Can be called from button handler or programmatically after setting a token.

    This function depends on:
    - $script:AppState (global AppState with AccessToken and Region)
    - Invoke-AppGcRequest (from HttpRequests module)
    - Set-Status, Set-TopContext (UI helper functions)
    - Start-AppJob (job runner function)

  .EXAMPLE
    Start-TokenTest
  #>

  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)] $ProgressButton
  )

  # Normalize copy/pasted region/token formats before testing.
  $normalizedRegion = Normalize-GcInstanceName -RegionText $script:AppState.Region
  if ($normalizedRegion -and $normalizedRegion -ne $script:AppState.Region) {
    Write-GcDiag ("Start-TokenTest: normalized Region '{0}' -> '{1}'" -f $script:AppState.Region, $normalizedRegion)
    $script:AppState.Region = $normalizedRegion
  }

  $normalizedToken = Normalize-GcAccessToken -TokenText $script:AppState.AccessToken
  if ($normalizedToken -and $script:AppState.AccessToken -and $normalizedToken -ne $script:AppState.AccessToken) {
    Write-GcDiag ("Start-TokenTest: normalized Token {0} -> {1}" -f (Format-GcDiagSecret -Value $script:AppState.AccessToken), (Format-GcDiagSecret -Value $normalizedToken))
    $script:AppState.AccessToken = $normalizedToken
  }

  if (-not $script:AppState.AccessToken) {
    Write-GcDiag "Start-TokenTest: no token in AppState.AccessToken"
    Set-Status "No token available to test."
    return
  }

  Write-GcDiag ("Start-TokenTest: begin (Region='{0}', Token={1})" -f $script:AppState.Region, (Format-GcDiagSecret -Value $script:AppState.AccessToken))

  $btn = $ProgressButton
  $originalContent = $null
  try { if ($btn) { $originalContent = $btn.Content } } catch { }

  try {
    Set-ControlEnabled -Control $btn -Enabled ($false)
    try { if ($btn) { $btn.Content = "Testing..." } } catch { }
  } catch { }

  Set-Status "Testing token..."

  # Queue background job to test token via GET /api/v2/users/me
  Start-AppJob -Name "Test Token" -Type "Auth" -ScriptBlock {
    param($region, $token, $coreModulePath)

    # Import required modules in runspace
    Import-Module (Join-Path -Path $coreModulePath -ChildPath 'HttpRequests.psm1') -Force

    try {
      $diag = New-Object 'System.Collections.Generic.List[string]'

      $baseUri = "https://api.$region/"
      $path = '/api/v2/users/me'
      $resolvedPath = $path.TrimStart('/')
      $requestUri = ($baseUri.TrimEnd('/') + '/' + $resolvedPath)

      $reveal = $false
      try {
        if ($env:GC_TOOLKIT_REVEAL_SECRETS -and ($env:GC_TOOLKIT_REVEAL_SECRETS -match '^(1|true|yes|on)$')) { $reveal = $true }
      } catch { }

      $tokenShown = "<empty>"
      if ($token) {
        if ($reveal) {
          $tokenShown = $token
        } else {
          $tokenShown = ("{0}...<{1} chars>" -f $token.Substring(0, [Math]::Min(12, $token.Length)), $token.Length)
        }
      }

      $diag.Add("Start: region='$region'") | Out-Null
      $diag.Add(("BaseUri: {0}" -f $baseUri)) | Out-Null
      $diag.Add(("Request: GET {0}" -f $requestUri)) | Out-Null
      $diag.Add(("Authorization: Bearer {0}" -f $tokenShown)) | Out-Null
      $diag.Add("Content-Type: application/json; charset=utf-8") | Out-Null

      # Call GET /api/v2/users/me using Invoke-GcRequest with explicit parameters
      $userInfo = Invoke-GcRequest -Path '/api/v2/users/me' -Method GET `
        -InstanceName $region -AccessToken $token -RetryCount 0

      return [PSCustomObject]@{
        Success = $true
        UserInfo = $userInfo
        Error = $null
        Diagnostics = @($diag)
        RequestUri = $requestUri
      }
    } catch {
      # Capture detailed error information for better diagnostics
      $errorMessage = $_.Exception.Message
      $statusCode = $null
      $responseBody = $null

      # Try to extract HTTP status code if available
      if ($_.Exception.Response) {
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        try {
          # Windows PowerShell (HttpWebResponse)
          if ($_.Exception.Response -is [System.Net.HttpWebResponse]) {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
              $reader = New-Object System.IO.StreamReader($stream)
              $responseBody = $reader.ReadToEnd()
            }
          }

          # PowerShell 7+ (HttpResponseMessage)
          if (-not $responseBody -and $_.Exception.Response -is [System.Net.Http.HttpResponseMessage]) {
            $responseBody = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
          }
        } catch { }
      }

      # PowerShell 7 often places response content into ErrorDetails
      try {
        if (-not $responseBody -and $_.ErrorDetails -and $_.ErrorDetails.Message) {
          $responseBody = $_.ErrorDetails.Message
        }
      } catch { }

      return [PSCustomObject]@{
        Success = $false
        UserInfo = $null
        Error = $errorMessage
        StatusCode = $statusCode
        ResponseBody = $responseBody
        Diagnostics = @($diag)
        RequestUri = $requestUri
      }
    }
  } -ArgumentList @($script:AppState.Region, $script:AppState.AccessToken, $coreRoot) -OnCompleted {
    param($job)

    try {

    # Dump diagnostics to console + job logs (UI thread safe)
    try {
      if ($job.Result -and $job.Result.Diagnostics) {
        Write-GcDiag ("Token test diagnostics ({0} lines):" -f @($job.Result.Diagnostics).Count)
        foreach ($line in @($job.Result.Diagnostics)) {
          Write-GcDiag $line
          try { Add-GcJobLog -Job $job -Message ("DIAG: {0}" -f $line) } catch { }
        }
      }
      if ($job.Result -and $job.Result.RequestUri) {
        Write-GcDiag ("Token test requestUri: {0}" -f $job.Result.RequestUri)
        try { Add-GcJobLog -Job $job -Message ("DIAG: requestUri={0}" -f $job.Result.RequestUri) } catch { }
      }
      if ($job.Result -and -not $job.Result.Success) {
        Write-GcDiag ("Token test failed: StatusCode={0} Error='{1}'" -f $job.Result.StatusCode, $job.Result.Error)
        if ($job.Result.ResponseBody) {
          $body = [string]$job.Result.ResponseBody
          if ($body.Length -gt 4096) { $body = $body.Substring(0, 4096) + '…' }
          Write-GcDiag ("Token test error body: {0}" -f $body)
          try { Add-GcJobLog -Job $job -Message ("DIAG: errorBody={0}" -f $body) } catch { }
        }
      }
    } catch { }

    if ($job.Result -and $job.Result.Success) {
      # SUCCESS: Token is valid
      $userInfo = $job.Result.UserInfo

      # Update AppState with success status and user information
      $script:AppState.Auth = "Logged in"
      if ($userInfo.name) {
        $script:AppState.Auth = "Logged in as $($userInfo.name)"
      }
      $script:AppState.TokenStatus = "Token valid"

      # Update header display
      Set-TopContext

      # Show success status with username if available
      $statusMsg = "Token test: OK"
      if ($userInfo.name) { $statusMsg += ". User: $($userInfo.name)" }
      if ($userInfo.organization -and $userInfo.organization.name) {
        $statusMsg += " | Org: $($userInfo.organization.name)"
        $script:AppState.Org = $userInfo.organization.name
      }
      Set-Status $statusMsg

    } else {
      # FAILURE: Token test failed
      $errorMsg = if ($job.Result) { $job.Result.Error } else { "Unknown error" }
      $statusCode = $null
      $requestUri = $null
      $responseBody = $null
      try {
        if ($job.Result) {
          $statusCode = $job.Result.StatusCode
          $requestUri = $job.Result.RequestUri
          $responseBody = $job.Result.ResponseBody
        }
      } catch { }

      $extraDetails = New-Object System.Collections.Generic.List[string]
      if ($requestUri) { $extraDetails.Add(("Request: {0}" -f $requestUri)) | Out-Null }
      if ($statusCode) { $extraDetails.Add(("HTTP: {0}" -f $statusCode)) | Out-Null }
      if ($responseBody) {
        $body = [string]$responseBody
        if ($body.Length -gt 2000) { $body = $body.Substring(0, 2000) + '…' }
        $extraDetails.Add("Response body (first 2000 chars):") | Out-Null
        $extraDetails.Add($body) | Out-Null
      }
      $extraText = ''
      if ($extraDetails.Count -gt 0) {
        $extraText = "`n`n" + ($extraDetails -join "`n")
      }

      # Special-case: client-credentials tokens cannot call /api/v2/users/me, but the token can still be valid.
      $responseCode = $null
      $responseMessage = $null
      try {
        if ($responseBody) {
          $bodyObj = $null
          try { $bodyObj = ([string]$responseBody | ConvertFrom-Json -ErrorAction Stop) } catch { $bodyObj = $null }
          if ($bodyObj) {
            try { $responseCode = [string]$bodyObj.code } catch { }
            try { $responseMessage = [string]$bodyObj.message } catch { }
          }
        }
      } catch { }

      $isClientCredentialsToken = $false
      if ($statusCode -eq 400 -and (
        $responseCode -eq 'not.a.user' -or
        ($responseMessage -and $responseMessage -match 'requires a user context') -or
        ($errorMsg -and $errorMsg -match 'not\\.a\\.user')
      )) {
        $isClientCredentialsToken = $true
      }

      if ($isClientCredentialsToken) {
        $script:AppState.Auth = "Token OK (client credentials)"
        $script:AppState.TokenStatus = "Token valid (client credentials)"
        Set-TopContext

        [System.Windows.MessageBox]::Show(
          "This access token is a Client Credentials token (no user context).`n`nIt is valid, but it cannot call /api/v2/users/me.`nMany UI workflows require a user-context token (Authorization Code + PKCE).`n`nTo proceed, use OAuth Login (user) or paste a user access token.",
          "Client Credentials Token",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Warning
        )

        Set-Status "Token test: OK (client credentials). Some features require user-context OAuth."
        return
      }

      # Analyze error and provide user-friendly message
      $userMessage = "Token test failed."
      $detailMessage = $errorMsg

      # Check for common error scenarios
      if ($statusCode -eq 400 -or $errorMsg -match "400|Bad Request") {
        $userMessage = "Bad Request"
        $detailMessage = "The API request was rejected as malformed (HTTP 400). Common causes:`n• Token includes hidden whitespace/line breaks or surrounding quotes`n• You pasted a full JSON token response instead of only access_token`n• Region/host was pasted as an apps/login/api URL`n`nRegion: $($script:AppState.Region)`nAPI Host: https://api.$($script:AppState.Region)`n`nError: $errorMsg$extraText"
      }
      elseif ($statusCode -eq 401 -or $errorMsg -match "401|Unauthorized") {
        $userMessage = "Token Invalid or Expired"
        $detailMessage = "The access token is not valid or has expired. Please log in again.`n`nRegion: $($script:AppState.Region)`nError: $errorMsg$extraText"
      }
      elseif ($errorMsg -match "Unable to connect|could not be resolved|Name or service not known") {
        $userMessage = "Connection Failed"
        $detailMessage = "Cannot connect to region '$($script:AppState.Region)'. Please verify:`n• Region is correct (e.g., mypurecloud.com, usw2.pure.cloud)`n• Network connection is available`n`nError: $errorMsg$extraText"
      }
      elseif ($statusCode -eq 404 -or $errorMsg -match "404|Not Found") {
        $userMessage = "Endpoint Not Found"
        $detailMessage = "API endpoint not found. This may indicate:`n• Wrong region configured`n• API version mismatch`n`nRegion: $($script:AppState.Region)`nError: $errorMsg$extraText"
      }
      elseif ($statusCode -eq 403 -or $errorMsg -match "403|Forbidden") {
        $userMessage = "Permission Denied"
        $detailMessage = "Token is valid but lacks permission to access user information.`n`nRegion: $($script:AppState.Region)`nError: $errorMsg$extraText"
      } else {
        $detailMessage = "$errorMsg$extraText"
      }

      # Update AppState to reflect failure
      $script:AppState.Auth = "Not logged in"
      $script:AppState.TokenStatus = "Token invalid"
      Set-TopContext

      # Show error dialog with details
      [System.Windows.MessageBox]::Show(
        $detailMessage,
        $userMessage,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
      )

      Set-Status "Token test failed: $userMessage"
    }
    } finally {
      try {
        Set-ControlEnabled -Control $btn -Enabled ($true)
        if ($btn -and $null -ne $originalContent) { $btn.Content = $originalContent }
        elseif ($btn) { $btn.Content = "Test Token" }
      } catch { }
    }
  }
}

function Get-GcSavedAccessTokenPath {
  [CmdletBinding()]
  param()

  $base = $null
  try { $base = $env:LOCALAPPDATA } catch { $base = $null }
  if ([string]::IsNullOrWhiteSpace($base)) {
    try { $base = $env:APPDATA } catch { $base = $null }
  }
  if ([string]::IsNullOrWhiteSpace($base)) {
    throw "Cannot resolve LOCALAPPDATA/APPDATA for saved token storage."
  }

  $dir = Join-Path -Path $base -ChildPath 'AGenesysToolKit'
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
  }

  return (Join-Path -Path $dir -ChildPath 'saved-access-token.json')
}

function Save-GcSavedAccessToken {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$AccessToken
  )

  $regionNorm = Normalize-GcInstanceName -RegionText $Region
  $tokenNorm = Normalize-GcAccessToken -TokenText $AccessToken
  if ([string]::IsNullOrWhiteSpace($regionNorm)) { throw "Region is required." }
  if ([string]::IsNullOrWhiteSpace($tokenNorm)) { throw "Access token is required." }

  $secure = ConvertTo-SecureString -String $tokenNorm -AsPlainText -Force
  $protected = ConvertFrom-SecureString -SecureString $secure

  $payload = [pscustomobject]@{
    Version       = 1
    SavedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
    Region        = $regionNorm
    TokenProtected = $protected
  }

  $path = Get-GcSavedAccessTokenPath
  ($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-GcSavedAccessToken {
  [CmdletBinding()]
  param()

  $path = Get-GcSavedAccessTokenPath
  if (-not (Test-Path -LiteralPath $path)) { return $null }

  $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($json)) { return $null }

  $obj = $null
  try { $obj = $json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
  if (-not $obj) { return $null }

  $protected = $null
  try { $protected = [string]$obj.TokenProtected } catch { $protected = $null }
  if ([string]::IsNullOrWhiteSpace($protected)) { return $null }

  $secure = ConvertTo-SecureString -String $protected

  $bstr = [IntPtr]::Zero
  try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    if ($bstr -ne [IntPtr]::Zero) {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }

  $regionLoaded = ''
  try { $regionLoaded = [string]$obj.Region } catch { $regionLoaded = '' }

  return [pscustomobject]@{
    Region      = $regionLoaded
    AccessToken = $plain
  }
}

function Remove-GcSavedAccessToken {
  [CmdletBinding()]
  param()

  $path = Get-GcSavedAccessTokenPath
  if (Test-Path -LiteralPath $path) {
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
  }
}

function Show-SetTokenDialog {
  <#
  .SYNOPSIS
    Opens a modal dialog for manually setting an access token.

  .DESCRIPTION
    Provides a UI for entering region and access token manually.
    Validates and sets the token, then triggers an immediate token test.
    Useful for testing with tokens obtained from other sources.

    This function depends on:
    - $Window (script-scoped main window for dialog owner)
    - $script:AppState (global AppState for region and token)
    - ConvertFrom-GcXaml (XAML parsing helper)
    - Set-TopContext, Set-Status (UI helper functions)
    - Start-TokenTest (token validation function)

  .EXAMPLE
    Show-SetTokenDialog
  #>

  $xamlString = @"
  <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
          xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
          Title="Set Access Token"
         Height="440" Width="760"
          WindowStartupLocation="CenterOwner"
          Background="#FFF7F7F9"
          ResizeMode="NoResize">
   <Grid Margin="16">
     <Grid.RowDefinitions>
       <RowDefinition Height="Auto"/>   <!-- Header -->
       <RowDefinition Height="Auto"/>   <!-- Region Input -->
       <RowDefinition Height="Auto"/>   <!-- Token Label -->
       <RowDefinition Height="*"/>      <!-- Token Input -->
       <RowDefinition Height="Auto"/>   <!-- Storage -->
       <RowDefinition Height="Auto"/>   <!-- Buttons -->
     </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#FF111827" CornerRadius="6" Padding="12" Margin="0,0,0,16">
      <StackPanel>
        <TextBlock Text="Manual Token Entry" FontSize="14" FontWeight="SemiBold" Foreground="White"/>
        <TextBlock Text="Paste a user access token (Authorization Code) for testing or manual authentication"
                   FontSize="11" Foreground="#FFA0AEC0" Margin="0,4,0,0"/>
      </StackPanel>
    </Border>

    <!-- Region Input -->
    <StackPanel Grid.Row="1" Margin="0,0,0,12">
      <TextBlock Text="Region:" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,4"/>
      <TextBox x:Name="TxtRegion" Height="28" Padding="6,4" FontSize="12"/>
    </StackPanel>

    <!-- Token Input -->
    <StackPanel Grid.Row="2" Margin="0,0,0,12">
      <TextBlock Text="Access Token:" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,4"/>
      <TextBlock Text="(Bearer prefix will be automatically removed if present)"
                 FontSize="10" Foreground="#FF6B7280" Margin="0,0,0,4"/>
    </StackPanel>

     <Border Grid.Row="3" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="4"
             Background="White" Padding="6" Margin="0,0,0,16">
        <TextBox x:Name="TxtToken"
                 AcceptsReturn="True"
                 TextWrapping="NoWrap"
                 HorizontalScrollBarVisibility="Auto"
                 VerticalScrollBarVisibility="Auto"
                 BorderThickness="0"
                 FontFamily="Consolas"
                 FontSize="10"/>
     </Border>

     <!-- Storage -->
     <Border Grid.Row="4" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="6" Background="White" Padding="10" Margin="0,0,0,14">
       <Grid>
         <Grid.ColumnDefinitions>
           <ColumnDefinition Width="*"/>
           <ColumnDefinition Width="Auto"/>
         </Grid.ColumnDefinitions>
         <StackPanel Grid.Column="0" Orientation="Vertical">
           <CheckBox x:Name="ChkRememberToken" Content="Save token securely for this Windows user (DPAPI)" Margin="0,0,0,2"/>
           <TextBlock Text="Saved tokens are encrypted for the current Windows user and machine."
                      FontSize="10" Foreground="#FF6B7280"/>
         </StackPanel>
         <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
           <Button x:Name="BtnLoadSaved" Content="Load Saved" Width="92" Height="28" Margin="0,0,8,0"/>
           <Button x:Name="BtnClearSaved" Content="Clear Saved" Width="92" Height="28"/>
         </StackPanel>
       </Grid>
     </Border>

     <!-- Buttons -->
     <Grid Grid.Row="5">
       <Grid.ColumnDefinitions>
         <ColumnDefinition Width="*"/>
         <ColumnDefinition Width="Auto"/>
       </Grid.ColumnDefinitions>

      <Button x:Name="BtnClearToken" Grid.Column="0" Content="Clear Token"
              Width="100" Height="30" HorizontalAlignment="Left"/>

      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="BtnSetTest" Content="Set + Test" Width="100" Height="30" Margin="0,0,8,0" HorizontalAlignment="Right"/>
        <Button x:Name="BtnCancel" Content="Cancel" Width="80" Height="30" Margin="0,0,0,0"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
"@

  try {
    Write-GcDiag ("Show-SetTokenDialog: open (prefill Region='{0}')" -f $script:AppState.Region)
    $dialog = ConvertFrom-GcXaml -XamlString $xamlString

    # Set owner if parent window is available
    if ($Window) {
      $dialog.Owner = $Window
    }

    $txtRegion = $dialog.FindName('TxtRegion')
    $txtToken = $dialog.FindName('TxtToken')
    $chkRememberToken = $dialog.FindName('ChkRememberToken')
    $btnLoadSaved = $dialog.FindName('BtnLoadSaved')
    $btnClearSaved = $dialog.FindName('BtnClearSaved')
    $btnSetTest = $dialog.FindName('BtnSetTest')
    $btnCancel = $dialog.FindName('BtnCancel')
    $btnClearToken = $dialog.FindName('BtnClearToken')

    # Prefill region from current AppState
    $txtRegion.Text = $script:AppState.Region

    $refreshSavedButtons = {
      $saved = $null
      try { $saved = Get-GcSavedAccessToken } catch { $saved = $null }
      $hasSaved = [bool]$saved
      Set-ControlEnabled -Control $btnLoadSaved -Enabled $hasSaved
      Set-ControlEnabled -Control $btnClearSaved -Enabled $hasSaved
    }

    & $refreshSavedButtons

    $btnLoadSaved.Add_Click({
      try {
        $saved = Get-GcSavedAccessToken
        if (-not $saved -or [string]::IsNullOrWhiteSpace($saved.AccessToken)) {
          [System.Windows.MessageBox]::Show(
            "No saved token found for this Windows user.",
            "No Saved Token",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
          )
          & $refreshSavedButtons
          return
        }

        if ($saved.Region) { $txtRegion.Text = [string]$saved.Region }
        $txtToken.Text = [string]$saved.AccessToken
        try { $chkRememberToken.IsChecked = $true } catch { }
        Set-Status "Loaded saved token (encrypted)."
      } catch {
        [System.Windows.MessageBox]::Show(
          "Failed to load saved token: $($_.Exception.Message)",
          "Load Failed",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Error
        )
      } finally {
        & $refreshSavedButtons
      }
    })

    $btnClearSaved.Add_Click({
      $result = [System.Windows.MessageBox]::Show(
        "This will remove the saved token from this computer for the current Windows user. Continue?",
        "Clear Saved Token",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
      )
      if ($result -ne [System.Windows.MessageBoxResult]::Yes) { return }

      try {
        Remove-GcSavedAccessToken
        Set-Status "Saved token cleared."
      } catch {
        [System.Windows.MessageBox]::Show(
          "Failed to clear saved token: $($_.Exception.Message)",
          "Clear Failed",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Error
        )
      } finally {
        & $refreshSavedButtons
      }
    })

    # Set + Test button handler
    $btnSetTest.Add_Click({
      Write-GcDiag "Manual token entry: 'Set + Test' clicked"

      # Get and clean region input
      $regionRaw = $txtRegion.Text
      $region = Normalize-GcInstanceName -RegionText $regionRaw
      $regionRawForLog = if ($null -ne $regionRaw) { [string]$regionRaw } else { '' }
      $regionForLog = if ($null -ne $region) { [string]$region } else { '' }
      Write-GcDiag ("Manual token entry: region(raw)='{0}' region(normalized)='{1}'" -f $regionRawForLog, $regionForLog)

      # Get token and perform comprehensive sanitization
      $tokenRaw = $txtToken.Text
      $token = Normalize-GcAccessToken -TokenText $tokenRaw
      Write-GcDiag ("Manual token entry: token(normalized)={0}" -f (Format-GcDiagSecret -Value $token))

      # Validate region input
      if ([string]::IsNullOrWhiteSpace($region)) {
        [System.Windows.MessageBox]::Show(
          "Please enter a region (e.g., mypurecloud.com, usw2.pure.cloud). You can also paste an apps/login/api URL and it will be normalized.",
          "Region Required",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Warning
        )
        return
      }

      if (-not ($region -match '\.')) {
        [System.Windows.MessageBox]::Show(
          "The region value doesn't look like a domain name.`n`nExpected examples:`n• mypurecloud.com`n• usw2.pure.cloud`n`nGot: $region",
          "Region Format Warning",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Warning
        )
        return
      }

      # Validate token input
      if ([string]::IsNullOrWhiteSpace($token)) {
        [System.Windows.MessageBox]::Show(
          "Please enter an access token",
          "Token Required",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Warning
        )
        return
      }

      # Basic token format validation (should look like a JWT or similar)
      # JWT tokens have format: xxxxx.yyyyy.zzzzz (base64 parts separated by dots)
      # Minimum length of 20 characters catches obviously invalid tokens while
      # allowing various token formats (JWT typically 100+ chars, OAuth2 tokens vary)
      if ($token.Length -lt 20) {
        [System.Windows.MessageBox]::Show(
          "The token appears too short to be valid. Please verify you've copied the complete token.",
          "Token Format Warning",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Warning
        )
        return
      }

      # Update AppState with sanitized values
      $script:AppState.Region = $region
      $script:AppState.AccessToken = $token
      $script:AppState.TokenStatus = "Token set (manual)"
      $script:AppState.Auth = "Manual token"
      Write-GcDiag ("Manual token entry: AppState updated (Region='{0}', AccessToken={1})" -f $script:AppState.Region, (Format-GcDiagSecret -Value $script:AppState.AccessToken))

      $remember = $false
      try { $remember = [bool]$chkRememberToken.IsChecked } catch { $remember = $false }
      if ($remember) {
        try {
          Save-GcSavedAccessToken -Region $script:AppState.Region -AccessToken $script:AppState.AccessToken
          Set-Status "Token set and saved securely."
        } catch {
          [System.Windows.MessageBox]::Show(
            "Token was set, but saving failed: $($_.Exception.Message)",
            "Save Failed",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
          )
        } finally {
          & $refreshSavedButtons
        }
      }

      # Update UI context
      Set-TopContext

      # Close dialog
      $dialog.DialogResult = $true
      $dialog.Close()

      # Trigger token test using the dedicated helper function
      Write-GcDiag "Manual token entry: launching Start-TokenTest"
      Start-TokenTest
    })

    # Cancel button handler
    $btnCancel.Add_Click({
      Write-GcDiag "Manual token entry: Cancel clicked"
      $dialog.DialogResult = $false
      $dialog.Close()
    })

    # Clear Token button handler
    $btnClearToken.Add_Click({
      Write-GcDiag "Manual token entry: Clear Token clicked"
      $result = [System.Windows.MessageBox]::Show(
        "This will clear the current access token. Continue?",
        "Clear Token",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
      )

      if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
        Write-GcDiag "Manual token entry: Clear Token confirmed (Yes)"
        $script:AppState.AccessToken = $null
        $script:AppState.Auth = "Not logged in"
        $script:AppState.TokenStatus = "No token"
        Set-TopContext
        Set-Status "Token cleared."

        $dialog.DialogResult = $false
        $dialog.Close()
      }
    })

    # Show dialog
    $dialog.ShowDialog() | Out-Null
    Write-GcDiag "Show-SetTokenDialog: closed"

  } catch {
    Write-Error "Failed to show token dialog: $_"
    [System.Windows.MessageBox]::Show(
      "Failed to show token dialog: $_",
      "Error",
      [System.Windows.MessageBoxButton]::OK,
      [System.Windows.MessageBoxImage]::Error
    )
  }
}

function Invoke-GcLogoutUi {
  [CmdletBinding()]
  param()

  try { Clear-GcTokenState } catch { }

  $script:AppState.AccessToken = $null
  $script:AppState.Auth = "Not logged in"
  $script:AppState.TokenStatus = "No token"
  try { $script:AppState.Org = '' } catch { }

  try { Write-GcAppLog -Level 'AUTH' -Category 'auth' -Message 'Logout' } catch { }
  try { Set-TopContext } catch { }
  try { Set-Status "Logged out." } catch { }
}

function Start-GcOAuthLoginUi {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)] $ProgressButton,
    [Parameter(Mandatory=$false)] [scriptblock] $OnSuccess,
    [Parameter(Mandatory=$false)] [scriptblock] $OnFailure
  )

  $authConfig = Get-GcAuthConfig

  $clientIdTrim = ''
  try { $clientIdTrim = [string]$authConfig.ClientId } catch { $clientIdTrim = [string]$authConfig.ClientId }
  if ($null -eq $clientIdTrim) { $clientIdTrim = '' }
  $clientIdTrim = $clientIdTrim.Trim()
  $isPlaceholderClientId = (-not $clientIdTrim) -or ($clientIdTrim -in @('YOUR_CLIENT_ID_HERE','your-client-id','clientid','client-id'))
  if ($isPlaceholderClientId) {
    [System.Windows.MessageBox]::Show(
      "Please configure your OAuth Client ID in the script.`n`nSet-GcAuthConfig -ClientId 'your-client-id' -Region 'your-region'",
      "Configuration Required",
      [System.Windows.MessageBoxButton]::OK,
      [System.Windows.MessageBoxImage]::Warning
    ) | Out-Null
    return
  }

  $redirectUriTrim = ''
  try { $redirectUriTrim = [string]$authConfig.RedirectUri } catch { $redirectUriTrim = [string]$authConfig.RedirectUri }
  if ($null -eq $redirectUriTrim) { $redirectUriTrim = '' }
  $redirectUriTrim = $redirectUriTrim.Trim()
  if (-not $redirectUriTrim) {
    [System.Windows.MessageBox]::Show(
      "Please configure your OAuth Redirect URI in the script (must match your Genesys OAuth client).`n`nExample:`nhttp://localhost:8085/callback",
      "Configuration Required",
      [System.Windows.MessageBoxButton]::OK,
      [System.Windows.MessageBoxImage]::Warning
    ) | Out-Null
    return
  }

  $originalContent = $null
  try { if ($ProgressButton) { $originalContent = $ProgressButton.Content } } catch { }

  try {
    Set-ControlEnabled -Control $ProgressButton -Enabled ($false)
    try { if ($ProgressButton) { $ProgressButton.Content = "Authenticating..." } } catch { }
  } catch { }

  try { Set-Status "Starting OAuth flow..." } catch { }
  try {
    Write-GcAppLog -Level 'AUTH' -Category 'auth' -Message 'OAuth login started' -Data @{
      Region      = $authConfig.Region
      RedirectUri = $authConfig.RedirectUri
      ScopesCount = @($authConfig.Scopes).Count
      ClientId    = ConvertTo-GcAppLogSafeString -Value $authConfig.ClientId
    }
  } catch { }

  $authModulePath = Join-Path -Path $coreRoot -ChildPath 'Auth.psm1'
  $authConfigSnapshot = Get-GcAuthConfig

  Start-AppJob -Name "OAuth Login" -Type "Auth" -ScriptBlock {
    param($authModulePath, $authConfigSnapshot, $artifactsDir)

    Import-Module $authModulePath -Force
    Enable-GcAuthDiagnostics -LogDirectory $artifactsDir | Out-Null

    Set-GcAuthConfig `
      -Region $authConfigSnapshot.Region `
      -ClientId $authConfigSnapshot.ClientId `
      -RedirectUri $authConfigSnapshot.RedirectUri `
      -Scopes $authConfigSnapshot.Scopes `
      -ClientSecret $authConfigSnapshot.ClientSecret

    $diag = $null
    try { $diag = Get-GcAuthDiagnostics } catch { }

    try {
      $tokenResponse = Get-GcTokenAsync -TimeoutSeconds 300
      if (-not $tokenResponse -or -not $tokenResponse.access_token) {
        try { $diag = Get-GcAuthDiagnostics } catch { }
        return [PSCustomObject]@{
          Success     = $false
          Error       = "OAuth flow returned no access_token."
          AccessToken = $null
          TokenType   = $null
          ExpiresIn   = $null
          UserInfo    = $null
          AuthLogPath = if ($diag) { $diag.LogPath } else { $null }
        }
      }

      $userInfo = $null
      try { $userInfo = Test-GcToken } catch { }

      try { $diag = Get-GcAuthDiagnostics } catch { }

      return [PSCustomObject]@{
        Success     = $true
        Error       = $null
        AccessToken = $tokenResponse.access_token
        TokenType   = $tokenResponse.token_type
        ExpiresIn   = $tokenResponse.expires_in
        UserInfo    = $userInfo
        AuthLogPath = if ($diag) { $diag.LogPath } else { $null }
      }
    } catch {
      try { $diag = Get-GcAuthDiagnostics } catch { }
      $msg = $_.Exception.Message
      Write-Error $_
      return [PSCustomObject]@{
        Success     = $false
        Error       = $msg
        AccessToken = $null
        TokenType   = $null
        ExpiresIn   = $null
        UserInfo    = $null
        AuthLogPath = if ($diag) { $diag.LogPath } else { $null }
      }
    }
  } -ArgumentList @($authModulePath, $authConfigSnapshot, $script:ArtifactsDir) -OnCompleted {
    param($job)

    try {
      if ($job.Result -and $job.Result.Success) {
        $script:AppState.AccessToken = $job.Result.AccessToken
        $script:AppState.Auth = "Logged in"
        $script:AppState.TokenStatus = "Token OK"
        if ($job.Result.UserInfo) {
          try { $script:AppState.Auth = "Logged in as $($job.Result.UserInfo.name)" } catch { }
        }

        Set-TopContext
        Set-Status "Authentication successful!"
        try {
          Write-GcAppLog -Level 'AUTH' -Category 'auth' -Message 'OAuth login succeeded' -Data @{
            Region      = $script:AppState.Region
            TokenLength = (try { [int]$script:AppState.AccessToken.Length } catch { 0 })
            User        = (try { [string]$job.Result.UserInfo.name } catch { $null })
            AuthLogPath = (try { [string]$job.Result.AuthLogPath } catch { $null })
          }
        } catch { }
        if ($OnSuccess) { & $OnSuccess $job.Result }
      } else {
        $err = $null
        if ($job.Result) { $err = $job.Result.Error }

        $script:AppState.Auth = "Login failed"
        $script:AppState.TokenStatus = "No token"
        Set-TopContext
        Set-Status "Authentication failed. Check job logs for details."
        try {
          Write-GcAppLog -Level 'AUTH' -Category 'auth' -Message 'OAuth login failed' -Data @{
            Error      = $err
            AuthLogPath = (try { [string]$job.Result.AuthLogPath } catch { $null })
          }
        } catch { }
        if ($OnFailure) { & $OnFailure $job.Result }
      }
    } finally {
      try {
        Set-ControlEnabled -Control $ProgressButton -Enabled ($true)
        if ($ProgressButton -and $null -ne $originalContent) { $ProgressButton.Content = $originalContent }
      } catch { }
    }
  }
}

function Start-GcClientCredentialsTokenUi {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret,
    [Parameter(Mandatory=$false)][string[]]$Scopes,
    [Parameter(Mandatory=$false)] $ProgressButton,
    [Parameter(Mandatory=$false)] [scriptblock] $OnSuccess,
    [Parameter(Mandatory=$false)] [scriptblock] $OnFailure
  )

  $regionNorm = Normalize-GcInstanceName -RegionText $Region
  if ([string]::IsNullOrWhiteSpace($regionNorm)) { throw "Region is required." }

  $clientIdTrim = ([string]$ClientId).Trim()
  if ([string]::IsNullOrWhiteSpace($clientIdTrim)) { throw "Client ID is required." }

  $clientSecretTrim = [string]$ClientSecret
  if ([string]::IsNullOrWhiteSpace($clientSecretTrim)) { throw "Client secret is required." }

  $originalContent = $null
  try { if ($ProgressButton) { $originalContent = $ProgressButton.Content } } catch { }

  try {
    Set-ControlEnabled -Control $ProgressButton -Enabled ($false)
    try { if ($ProgressButton) { $ProgressButton.Content = "Getting token..." } } catch { }
  } catch { }

  try { Set-Status "Requesting client credentials token..." } catch { }
  try {
    Write-GcAppLog -Level 'AUTH' -Category 'auth' -Message 'Client credentials token request started' -Data @{
      Region          = $regionNorm
      ClientId        = ConvertTo-GcAppLogSafeString -Value $clientIdTrim
      ScopesCount     = if ($Scopes) { @($Scopes).Count } else { 0 }
      HasClientSecret = $true
    }
  } catch { }

  $authModulePath = Join-Path -Path $coreRoot -ChildPath 'Auth.psm1'
  $scopesSnapshot = @()
  if ($Scopes) { $scopesSnapshot = @($Scopes) }

  Start-AppJob -Name "Client Credentials Token" -Type "Auth" -ScriptBlock {
    param($authModulePath, $region, $clientId, $clientSecret, $scopes, $artifactsDir)

    Import-Module $authModulePath -Force
    Enable-GcAuthDiagnostics -LogDirectory $artifactsDir | Out-Null

    try {
      $tokenResponse = Get-GcClientCredentialsToken -Region $region -ClientId $clientId -ClientSecret $clientSecret -Scopes $scopes
      return [pscustomobject]@{
        Success     = $true
        Error       = $null
        Region      = $region
        AccessToken = $tokenResponse.access_token
        TokenType   = $tokenResponse.token_type
        ExpiresIn   = $tokenResponse.expires_in
      }
    } catch {
      return [pscustomobject]@{
        Success     = $false
        Error       = $_.Exception.Message
        Region      = $region
        AccessToken = $null
        TokenType   = $null
        ExpiresIn   = $null
      }
    }
  } -ArgumentList @($authModulePath, $regionNorm, $clientIdTrim, $clientSecretTrim, $scopesSnapshot, $script:ArtifactsDir) -OnCompleted {
    param($job)

    try {
      if ($job.Result -and $job.Result.Success) {
        $script:AppState.Region = $job.Result.Region
        $script:AppState.AccessToken = $job.Result.AccessToken
        $script:AppState.Auth = "Client credentials"
        $script:AppState.TokenStatus = "Token set (client credentials)"
        Set-TopContext
        Set-Status "Client credentials token acquired."
        try {
          Write-GcAppLog -Level 'AUTH' -Category 'auth' -Message 'Client credentials token acquired' -Data @{
            Region      = $script:AppState.Region
            TokenLength = (try { [int]$script:AppState.AccessToken.Length } catch { 0 })
          }
        } catch { }
        if ($OnSuccess) { & $OnSuccess $job.Result }
      } else {
        $err = if ($job.Result) { $job.Result.Error } else { "Unknown error" }
        $script:AppState.Auth = "Client credentials failed"
        $script:AppState.TokenStatus = "No token"
        Set-TopContext
        Set-Status "Client credentials token failed."
        try {
          Write-GcAppLog -Level 'AUTH' -Category 'auth' -Message 'Client credentials token failed' -Data @{
            Error = $err
            Region = $regionNorm
          }
        } catch { }
        if ($OnFailure) { & $OnFailure $job.Result }
        try {
          [System.Windows.MessageBox]::Show(
            "Client credentials token request failed: $err",
            "Authentication Failed",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
          ) | Out-Null
        } catch { }
      }
    } finally {
      try {
        Set-ControlEnabled -Control $ProgressButton -Enabled ($true)
        if ($ProgressButton -and $null -ne $originalContent) { $ProgressButton.Content = $originalContent }
      } catch { }
    }
  }
}

function Show-AuthenticationDialog {
  [CmdletBinding()]
  param()

  $authConfig = $null
  try { $authConfig = Get-GcAuthConfig } catch { $authConfig = $null }

  $xamlString = @"
  <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
          xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
          Title="Authentication"
          Height="560" Width="900"
          WindowStartupLocation="CenterOwner"
          Background="#FFF7F7F9"
          ResizeMode="NoResize">
    <Grid Margin="16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Border Grid.Row="0" Background="#FF111827" CornerRadius="6" Padding="12">
        <StackPanel>
          <TextBlock Text="Authentication" FontSize="14" FontWeight="SemiBold" Foreground="White"/>
          <TextBlock Text="OAuth (PKCE), Client Credentials, or a saved token"
                     FontSize="11" Foreground="#FFA0AEC0" Margin="0,4,0,0"/>
        </StackPanel>
      </Border>

      <TabControl Grid.Row="1" Margin="0,12,0,12">
        <TabItem Header="OAuth (PKCE)">
          <Grid Margin="12">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0"
                       Text="Authorization Code + PKCE (browser-based consent)"
                       Foreground="#FF111827" FontWeight="SemiBold"/>

            <Border Grid.Row="1" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="6" Background="White" Padding="10" Margin="0,8,0,10">
              <TextBlock x:Name="TxtOauthConfig" FontFamily="Consolas" FontSize="11" Foreground="#FF111827"/>
            </Border>

            <TextBlock Grid.Row="2"
                       Text="Tip: PKCE does not require a client secret. If you have a confidential client, set -ClientSecret to use Basic auth during token exchange."
                       TextWrapping="Wrap" FontSize="11" Foreground="#FF6B7280"/>

            <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="BtnOAuthLogin" Content="Login via Browser" Width="150" Height="30" Margin="0,0,8,0"/>
              <Button x:Name="BtnOAuthLogout" Content="Logout" Width="90" Height="30" Margin="0,0,8,0"/>
              <Button x:Name="BtnOAuthTest" Content="Test Token" Width="100" Height="30"/>
            </StackPanel>
          </Grid>
        </TabItem>

        <TabItem Header="Client Credentials">
          <Grid Margin="12">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Text="Client Credentials (grant_type=client_credentials)" Foreground="#FF111827" FontWeight="SemiBold"/>

            <StackPanel Grid.Row="1" Margin="0,10,0,0">
              <TextBlock Text="Region:" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,4"/>
              <TextBox x:Name="TxtClientRegion" Height="28" Padding="6,4" FontSize="12"/>
            </StackPanel>

            <StackPanel Grid.Row="2" Margin="0,10,0,0">
              <TextBlock Text="Client ID:" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,4"/>
              <TextBox x:Name="TxtClientId" Height="28" Padding="6,4" FontSize="12"/>
            </StackPanel>

            <StackPanel Grid.Row="3" Margin="0,10,0,0">
              <TextBlock Text="Client Secret:" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,4"/>
              <PasswordBox x:Name="PwdClientSecret" Height="28" Padding="6,4" FontSize="12"/>
            </StackPanel>

            <StackPanel Grid.Row="4" Margin="0,10,0,0">
              <TextBlock Text="Scopes (optional, space-separated):" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,4"/>
              <TextBox x:Name="TxtClientScopes" Height="28" Padding="6,4" FontSize="12"/>
            </StackPanel>

            <TextBlock Grid.Row="5"
                       Text="Note: client-credentials tokens have no user context and cannot call /api/v2/users/me. Some UI workflows require a user token (OAuth PKCE)."
                       TextWrapping="Wrap" FontSize="11" Foreground="#FF6B7280" Margin="0,12,0,0"/>

            <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
              <Button x:Name="BtnClientGetToken" Content="Get Token" Width="100" Height="30" Margin="0,0,8,0"/>
              <Button x:Name="BtnClientTest" Content="Test Token" Width="100" Height="30"/>
            </StackPanel>
          </Grid>
        </TabItem>

        <TabItem Header="Token">
          <Grid Margin="12">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Text="Paste or load an access token" Foreground="#FF111827" FontWeight="SemiBold"/>

            <StackPanel Grid.Row="1" Margin="0,10,0,0">
              <TextBlock Text="Region:" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,4"/>
              <TextBox x:Name="TxtTokenRegion" Height="28" Padding="6,4" FontSize="12"/>
            </StackPanel>

            <StackPanel Grid.Row="2" Margin="0,10,0,6">
              <TextBlock Text="Access Token:" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,4"/>
              <TextBlock Text="(Bearer prefix will be automatically removed if present)" FontSize="10" Foreground="#FF6B7280"/>
            </StackPanel>

            <Border Grid.Row="3" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="6" Background="White" Padding="6">
              <TextBox x:Name="TxtTokenValue"
                       AcceptsReturn="True"
                       TextWrapping="NoWrap"
                       HorizontalScrollBarVisibility="Auto"
                       VerticalScrollBarVisibility="Auto"
                       BorderThickness="0"
                       FontFamily="Consolas"
                       FontSize="10"/>
            </Border>

            <Border Grid.Row="4" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="6" Background="White" Padding="10" Margin="0,10,0,0">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Vertical">
                  <CheckBox x:Name="ChkTokenRemember" Content="Save token securely for this Windows user (DPAPI)" Margin="0,0,0,2"/>
                  <TextBlock Text="Saved tokens are encrypted for the current Windows user and machine."
                             FontSize="10" Foreground="#FF6B7280"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                  <Button x:Name="BtnTokenLoadSaved" Content="Load Saved" Width="92" Height="28" Margin="0,0,8,0"/>
                  <Button x:Name="BtnTokenClearSaved" Content="Clear Saved" Width="92" Height="28"/>
                </StackPanel>
              </Grid>
            </Border>

            <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
              <Button x:Name="BtnTokenSet" Content="Set Token" Width="100" Height="30" Margin="0,0,8,0"/>
              <Button x:Name="BtnTokenSetTest" Content="Set + Test" Width="100" Height="30" Margin="0,0,8,0"/>
              <Button x:Name="BtnTokenTest" Content="Test Token" Width="100" Height="30" Margin="0,0,8,0"/>
              <Button x:Name="BtnTokenLogout" Content="Logout" Width="90" Height="30"/>
            </StackPanel>
          </Grid>
        </TabItem>
      </TabControl>

      <Grid Grid.Row="2">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtAuthDialogStatus" Grid.Column="0" Foreground="#FF374151" FontSize="11" VerticalAlignment="Center"/>
        <Button x:Name="BtnAuthClose" Grid.Column="1" Content="Close" Width="90" Height="30" />
      </Grid>
    </Grid>
  </Window>
"@

  try {
    $dialog = ConvertFrom-GcXaml -XamlString $xamlString
    if ($Window) { $dialog.Owner = $Window }

    $txtOauthConfig = $dialog.FindName('TxtOauthConfig')
    $btnOAuthLogin = $dialog.FindName('BtnOAuthLogin')
    $btnOAuthLogout = $dialog.FindName('BtnOAuthLogout')
    $btnOAuthTest = $dialog.FindName('BtnOAuthTest')

    $txtClientRegion = $dialog.FindName('TxtClientRegion')
    $txtClientId = $dialog.FindName('TxtClientId')
    $pwdClientSecret = $dialog.FindName('PwdClientSecret')
    $txtClientScopes = $dialog.FindName('TxtClientScopes')
    $btnClientGetToken = $dialog.FindName('BtnClientGetToken')
    $btnClientTest = $dialog.FindName('BtnClientTest')

    $txtTokenRegion = $dialog.FindName('TxtTokenRegion')
    $txtTokenValue = $dialog.FindName('TxtTokenValue')
    $chkTokenRemember = $dialog.FindName('ChkTokenRemember')
    $btnTokenLoadSaved = $dialog.FindName('BtnTokenLoadSaved')
    $btnTokenClearSaved = $dialog.FindName('BtnTokenClearSaved')
    $btnTokenSet = $dialog.FindName('BtnTokenSet')
    $btnTokenSetTest = $dialog.FindName('BtnTokenSetTest')
    $btnTokenTest = $dialog.FindName('BtnTokenTest')
    $btnTokenLogout = $dialog.FindName('BtnTokenLogout')

    $txtDialogStatus = $dialog.FindName('TxtAuthDialogStatus')
    $btnClose = $dialog.FindName('BtnAuthClose')

    $setDialogStatus = {
      param([string]$Text)
      try { if ($txtDialogStatus) { $txtDialogStatus.Text = $Text } } catch { }
    }

    $region = $script:AppState.Region
    if ($txtClientRegion) { $txtClientRegion.Text = $region }
    if ($txtTokenRegion) { $txtTokenRegion.Text = $region }

    if ($authConfig -and $txtOauthConfig) {
      $cfgRegion = if ($null -ne $authConfig.Region) { [string]$authConfig.Region } else { '' }
      $cfgClientId = if ($null -ne $authConfig.ClientId) { [string]$authConfig.ClientId } else { '' }
      $cfgRedirectUri = if ($null -ne $authConfig.RedirectUri) { [string]$authConfig.RedirectUri } else { '' }
      $cfgScopes = if ($null -ne $authConfig.Scopes) { @($authConfig.Scopes) } else { @() }
      $txtOauthConfig.Text = @(
        ("Region:       {0}" -f $cfgRegion)
        ("ClientId:     {0}" -f $cfgClientId)
        ("RedirectUri:  {0}" -f $cfgRedirectUri)
        ("Scopes:       {0}" -f ($cfgScopes -join ' '))
        ("HasSecret:    {0}" -f (-not [string]::IsNullOrWhiteSpace($authConfig.ClientSecret)))
      ) -join "`n"
    }

    $refreshSavedButtons = {
      $saved = $null
      try { $saved = Get-GcSavedAccessToken } catch { $saved = $null }
      $hasSaved = [bool]$saved
      Set-ControlEnabled -Control $btnTokenLoadSaved -Enabled $hasSaved
      Set-ControlEnabled -Control $btnTokenClearSaved -Enabled $hasSaved
    }
    & $refreshSavedButtons

    $btnTokenLoadSaved.Add_Click({
      try {
        $saved = Get-GcSavedAccessToken
        if (-not $saved -or [string]::IsNullOrWhiteSpace($saved.AccessToken)) {
          & $setDialogStatus "No saved token found."
          & $refreshSavedButtons
          return
        }

        if ($saved.Region) { $txtTokenRegion.Text = [string]$saved.Region }
        $txtTokenValue.Text = [string]$saved.AccessToken
        try { $chkTokenRemember.IsChecked = $true } catch { }
        & $setDialogStatus "Loaded saved token (encrypted)."
      } catch {
        [System.Windows.MessageBox]::Show(
          "Failed to load saved token: $($_.Exception.Message)",
          "Load Failed",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
      } finally {
        & $refreshSavedButtons
      }
    })

    $btnTokenClearSaved.Add_Click({
      $result = [System.Windows.MessageBox]::Show(
        "This will remove the saved token from this computer for the current Windows user. Continue?",
        "Clear Saved Token",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
      )
      if ($result -ne [System.Windows.MessageBoxResult]::Yes) { return }

      try {
        Remove-GcSavedAccessToken
        & $setDialogStatus "Saved token cleared."
      } catch {
        [System.Windows.MessageBox]::Show(
          "Failed to clear saved token: $($_.Exception.Message)",
          "Clear Failed",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
      } finally {
        & $refreshSavedButtons
      }
    })

    $applyTokenFromFields = {
      $regionRaw = $txtTokenRegion.Text
      $tokenRaw = $txtTokenValue.Text
      $regionNorm = Normalize-GcInstanceName -RegionText $regionRaw
      $tokenNorm = Normalize-GcAccessToken -TokenText $tokenRaw

      if ([string]::IsNullOrWhiteSpace($regionNorm)) { & $setDialogStatus "Region is required."; return $false }
      if ([string]::IsNullOrWhiteSpace($tokenNorm)) { & $setDialogStatus "Token is required."; return $false }

      $script:AppState.Region = $regionNorm
      $script:AppState.AccessToken = $tokenNorm
      $script:AppState.TokenStatus = "Token set (manual)"
      $script:AppState.Auth = "Manual token"
      Set-TopContext
      try {
        Write-GcAppLog -Level 'AUTH' -Category 'auth' -Message 'Manual token set (auth dialog)' -Data @{
          Region      = $script:AppState.Region
          TokenLength = (try { [int]$script:AppState.AccessToken.Length } catch { 0 })
          Remember    = (try { [bool]$chkTokenRemember.IsChecked } catch { $false })
        }
      } catch { }

      $remember = $false
      try { $remember = [bool]$chkTokenRemember.IsChecked } catch { $remember = $false }
      if ($remember) {
        try { Save-GcSavedAccessToken -Region $script:AppState.Region -AccessToken $script:AppState.AccessToken } catch { }
        & $refreshSavedButtons
        & $setDialogStatus "Token set and saved securely."
      } else {
        & $setDialogStatus "Token set."
      }

      return $true
    }

    $btnTokenSet.Add_Click({
      $null = & $applyTokenFromFields
    })

    $btnTokenSetTest.Add_Click({
      if (& $applyTokenFromFields) {
        Start-TokenTest
      }
    })

    $btnTokenTest.Add_Click({ Start-TokenTest })
    $btnTokenLogout.Add_Click({ Invoke-GcLogoutUi; & $setDialogStatus "Logged out." })

    $btnOAuthLogout.Add_Click({ Invoke-GcLogoutUi; & $setDialogStatus "Logged out." })
    $btnOAuthTest.Add_Click({ Start-TokenTest })
    $btnOAuthLogin.Add_Click({
      Start-GcOAuthLoginUi -ProgressButton $btnOAuthLogin -OnSuccess { & $setDialogStatus "OAuth login succeeded." } -OnFailure { & $setDialogStatus "OAuth login failed." }
    })

    $btnClientTest.Add_Click({ Start-TokenTest })
    $btnClientGetToken.Add_Click({
      try {
        $regionRaw = [string]$txtClientRegion.Text
        $clientIdRaw = [string]$txtClientId.Text
        $clientSecretRaw = [string]$pwdClientSecret.Password
        $scopesText = ''
        try { $scopesText = [string]$txtClientScopes.Text } catch { $scopesText = '' }

        $scopes = @()
        if (-not [string]::IsNullOrWhiteSpace($scopesText)) {
          $scopes = @($scopesText -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        Start-GcClientCredentialsTokenUi `
          -Region $regionRaw `
          -ClientId $clientIdRaw `
          -ClientSecret $clientSecretRaw `
          -Scopes $scopes `
          -ProgressButton $btnClientGetToken `
          -OnSuccess { & $setDialogStatus "Client credentials token acquired." } `
          -OnFailure { & $setDialogStatus "Client credentials token failed." }
      } catch {
        & $setDialogStatus "Client credentials token failed."
        [System.Windows.MessageBox]::Show(
          "Client credentials token failed: $($_.Exception.Message)",
          "Authentication Failed",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
      }
    })

    $btnClose.Add_Click({ $dialog.DialogResult = $true; $dialog.Close() })

    $currentAuth = if ($null -ne $script:AppState.Auth) { [string]$script:AppState.Auth } else { '' }
    $currentTokenStatus = if ($null -ne $script:AppState.TokenStatus) { [string]$script:AppState.TokenStatus } else { '' }
    & $setDialogStatus ("Current: {0} | {1}" -f $currentAuth, $currentTokenStatus)

    $dialog.ShowDialog() | Out-Null
  } catch {
    Write-Error "Failed to show authentication dialog: $_"
    [System.Windows.MessageBox]::Show(
      "Failed to show authentication dialog: $_",
      "Error",
      [System.Windows.MessageBoxButton]::OK,
      [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
  }
}

### END: Manual Token Entry

# -----------------------------
# Snackbar logic (Export complete)
# -----------------------------
$script:SnackbarTimer = New-Object Windows.Threading.DispatcherTimer
$script:SnackbarTimer.Interval = [TimeSpan]::FromMilliseconds(6500)
$script:SnackbarPrimaryAction = $null
$script:SnackbarSecondaryAction = $null

function Close-Snackbar {
  $script:SnackbarTimer.Stop()
  $SnackbarHost.Visibility = 'Collapsed'
  $script:SnackbarPrimaryAction = $null
  $script:SnackbarSecondaryAction = $null
}

function Show-Snackbar {
  param(
    [string]$Title,
    [string]$Body,
    [scriptblock]$OnPrimary,
    [scriptblock]$OnSecondary,
    [string]$PrimaryText = 'Open',
    [string]$SecondaryText = 'Folder',
    [int]$TimeoutMs = 6500
  )

  $SnackbarTitle.Text = $Title
  $SnackbarBody.Text  = $Body

  $BtnSnackPrimary.Content   = $PrimaryText
  $BtnSnackSecondary.Content = $SecondaryText

  $script:SnackbarPrimaryAction   = $OnPrimary
  $script:SnackbarSecondaryAction = $OnSecondary

  $SnackbarHost.Visibility = 'Visible'
  $script:SnackbarTimer.Interval = [TimeSpan]::FromMilliseconds($TimeoutMs)
  $script:SnackbarTimer.Stop()
  $script:SnackbarTimer.Start()
}

$script:SnackbarTimer.Add_Tick({ Close-Snackbar })
$BtnSnackClose.Add_Click({ Close-Snackbar })
$BtnSnackPrimary.Add_Click({
  try { if ($script:SnackbarPrimaryAction) { & $script:SnackbarPrimaryAction } }
  finally { Close-Snackbar }
})
$BtnSnackSecondary.Add_Click({
  try { if ($script:SnackbarSecondaryAction) { & $script:SnackbarSecondaryAction } }
  finally { Close-Snackbar }
})

function Add-ArtifactAndNotify {
  param([string]$Name, [string]$Path, [string]$ToastTitle = 'Export complete')

  $a = New-Artifact -Name $Name -Path $Path
  $script:AppState.Artifacts.Insert(0, $a) | Out-Null
  Refresh-ArtifactsList

  Show-Snackbar -Title $ToastTitle -Body ("$Name`n$Path") `
    -OnPrimary   { if (Test-Path $Path) { Start-Process -FilePath $Path | Out-Null } } `
    -OnSecondary { Start-Process -FilePath $script:ArtifactsDir | Out-Null }
}

# -----------------------------
# Backstage drawer
# -----------------------------
function Update-SelectedJobDetails {
  $idx = $LstJobs.SelectedIndex
  if ($idx -lt 0 -or $idx -ge $script:AppState.Jobs.Count) {
    if ($TxtJobMeta.Text -ne "Select a job…") { $TxtJobMeta.Text = "Select a job…" }
    if ($LstJobLogs.Items.Count -gt 0) { $LstJobLogs.Items.Clear() }
    Set-ControlEnabled -Control $BtnCancelJob -Enabled ($false)
    return
  }

  $job = $script:AppState.Jobs[$idx]
  $meta = "Name: $($job.Name)`r`nType: $($job.Type)`r`nStatus: $($job.Status)`r`nProgress: $($job.Progress)%"
  if ($TxtJobMeta.Text -ne $meta) { $TxtJobMeta.Text = $meta }

  # Incremental log sync to avoid UI thrash during frequent refreshes
  $uiCount = $LstJobLogs.Items.Count
  $jobCount = @($job.Logs).Count
  if ($uiCount -gt $jobCount) {
    $LstJobLogs.Items.Clear()
    $uiCount = 0
  }
  if ($uiCount -lt $jobCount) {
    for ($i = $uiCount; $i -lt $jobCount; $i++) {
      $LstJobLogs.Items.Add($job.Logs[$i]) | Out-Null
    }
  }

  Set-ControlEnabled -Control $BtnCancelJob -Enabled ([bool]$job.CanCancel)
}

function Refresh-JobsList {
  # Preserve selection and avoid SelectionChanged/UI thrash while refreshing frequently
  $selectedIdx = $LstJobs.SelectedIndex

  $newItems = New-Object 'System.Collections.Generic.List[string]'
  foreach ($j in $script:AppState.Jobs) {
    [void]$newItems.Add("$($j.Status) [$($j.Progress)%] — $($j.Name)")
  }

  $script:SuppressJobsSelectionChanged = $true
  try {
    if ($LstJobs.Items.Count -ne $newItems.Count) {
      $LstJobs.Items.Clear()
      foreach ($s in $newItems) { $LstJobs.Items.Add($s) | Out-Null }
    } else {
      for ($i = 0; $i -lt $newItems.Count; $i++) {
        if ([string]$LstJobs.Items[$i] -ne $newItems[$i]) {
          $LstJobs.Items[$i] = $newItems[$i]
        }
      }
    }

    if ($selectedIdx -ge 0 -and $selectedIdx -lt $LstJobs.Items.Count) {
      if ($LstJobs.SelectedIndex -ne $selectedIdx) { $LstJobs.SelectedIndex = $selectedIdx }
    } else {
      if ($LstJobs.SelectedIndex -ne -1) { $LstJobs.SelectedIndex = -1 }
    }
  } finally {
    $script:SuppressJobsSelectionChanged = $false
  }

  Update-SelectedJobDetails
  Refresh-HeaderStats
}

function Open-Backstage([ValidateSet('Jobs','Artifacts','Integration')]$Tab = 'Jobs') {
  Write-GcTrace -Level 'UI' -Message ("Open Backstage Tab='{0}'" -f $Tab)
  switch ($Tab) {
    'Jobs'        { $BackstageTabs.SelectedIndex = 0 }
    'Artifacts'   { $BackstageTabs.SelectedIndex = 1 }
    'Integration' { $BackstageTabs.SelectedIndex = 2; try { Refresh-CoreStatusBar } catch { } }
  }
  Refresh-JobsList
  Refresh-ArtifactsList
  $BackstageOverlay.Visibility = 'Visible'
}
function Close-Backstage {
  Write-GcTrace -Level 'UI' -Message "Close Backstage"
  $BackstageOverlay.Visibility = 'Collapsed'
}

$BtnCloseBackstage.Add_Click({ Close-Backstage })

# -----------------------------
# Jobs selection
# -----------------------------
$LstJobs.Add_SelectionChanged({
  if ($script:SuppressJobsSelectionChanged) { return }
  Update-SelectedJobDetails
})

$BtnCancelJob.Add_Click({
  $idx = $LstJobs.SelectedIndex
  if ($idx -ge 0 -and $idx -lt $script:AppState.Jobs.Count) {
    $job = $script:AppState.Jobs[$idx]
    if ($job.CanCancel -and $job.Status -eq 'Running') {
      # Try real job runner cancellation first
      if (Get-Command -Name Stop-GcJob -ErrorAction SilentlyContinue) {
        try {
          Stop-GcJob -Job $job
          Set-Status "Cancellation requested for: $($job.Name)"
          Refresh-JobsList
          return
        } catch {
          # Fallback to mock cancellation
        }
      }

      # Fallback: mock cancellation
      $job.Status = 'Canceled'
      $job.CanCancel = $false
      Add-JobLog -Job $job -Message "Cancel requested by user."
      Set-Status "Canceled job: $($job.Name)"
      Refresh-JobsList
    }
  }
})

# -----------------------------
# Artifacts actions
# -----------------------------
$BtnOpenArtifactsFolder.Add_Click({ Start-Process -FilePath $script:ArtifactsDir | Out-Null })

$BtnOpenSelectedArtifact.Add_Click({
  $idx = $LstArtifacts.SelectedIndex
  if ($idx -ge 0 -and $idx -lt $script:AppState.Artifacts.Count) {
    $a = $script:AppState.Artifacts[$idx]
    if (Test-Path $a.Path) { Start-Process -FilePath $a.Path | Out-Null }
  }
})

$LstArtifacts.Add_MouseDoubleClick({
  $idx = $LstArtifacts.SelectedIndex
  if ($idx -ge 0 -and $idx -lt $script:AppState.Artifacts.Count) {
    $a = $script:AppState.Artifacts[$idx]
    if (Test-Path $a.Path) { Start-Process -FilePath $a.Path | Out-Null }
  }
})

# -----------------------------
# Integration tab — Genesys.Core
# -----------------------------

if ($BtnCoreBrowse) { $BtnCoreBrowse.Add_Click({
  Add-Type -AssemblyName System.Windows.Forms
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title  = 'Locate Genesys.Core.psd1'
  $dlg.Filter = 'PowerShell Module Manifest (*.psd1)|*.psd1|All Files (*.*)|*.*'
  $dlg.FileName = 'Genesys.Core.psd1'

  # Start in the sibling directory if it exists
  $siblingDir = Split-Path -Parent $repoRoot
  if (Test-Path $siblingDir) { $dlg.InitialDirectory = $siblingDir }

  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    if ($TxtCorePath) { $TxtCorePath.Text = $dlg.FileName }
  }
}.GetNewClosure()) }

if ($BtnCoreSave) { $BtnCoreSave.Add_Click({
  $pathToTry = if ($TxtCorePath) { [string]$TxtCorePath.Text.Trim() } else { '' }

  if ([string]::IsNullOrWhiteSpace($pathToTry)) {
    Set-Status "Enter or browse to the path of Genesys.Core.psd1 first."
    return
  }

  if (-not (Test-Path $pathToTry -ErrorAction SilentlyContinue)) {
    Set-Status "Path not found: $pathToTry"
    return
  }

  Set-Status "Loading Genesys.Core from $pathToTry …"

  try {
    Import-Module $pathToTry -Force -ErrorAction Stop

    $catalogPath = Find-GcCoreCatalog -ModulePath $pathToTry
    $version = $null
    try {
      $manifest = Import-PowerShellDataFile -Path $pathToTry -ErrorAction SilentlyContinue
      if ($manifest -and $manifest.ModuleVersion) { $version = [string]$manifest.ModuleVersion }
    } catch { }

    $script:GcCoreState.Available       = $true
    $script:GcCoreState.ModulePath      = $pathToTry
    $script:GcCoreState.CatalogPath     = $catalogPath
    $script:GcCoreState.Version         = $version
    $script:GcCoreState.DiscoverySource = 'manual'
    $script:GcCoreState.LastError       = $null

    $script:AppState.GcCoreAvailable   = $true
    $script:AppState.GcCoreModulePath  = $pathToTry
    $script:AppState.GcCoreCatalogPath = $catalogPath
    $script:AppState.GcCoreVersion     = $version

    $saved = Save-GcCoreModulePath -ModulePath $pathToTry -ConfigPath $script:GcAdminConfigPath
    $savedMsg = if ($saved) { ' Path saved to gc-admin.json.' } else { '' }

    Refresh-CoreStatusBar
    Set-Status "Genesys.Core connected successfully.$savedMsg"
    Write-GcTrace -Level 'INFO' -Message "Genesys.Core manually connected: $pathToTry"
  } catch {
    $script:GcCoreState.Available = $false
    $script:GcCoreState.LastError = $_.Exception.Message
    Refresh-CoreStatusBar
    Set-Status "Failed to load Genesys.Core: $($_.Exception.Message)"
    Write-GcTrace -Level 'WARN' -Message "Genesys.Core manual load failed: $_"
  }
}.GetNewClosure()) }

if ($BtnCoreReset) { $BtnCoreReset.Add_Click({
  # Clear the saved path and re-run auto-discovery
  try { Clear-GcCoreModulePath -ConfigPath $script:GcAdminConfigPath | Out-Null } catch { }

  if ($TxtCorePath) { $TxtCorePath.Text = '' }
  Set-Status "Re-running Genesys.Core auto-discovery…"

  try {
    Initialize-GcCoreIntegration `
      -ScriptRoot $scriptRoot `
      -RepoRoot   $repoRoot `
      -ConfigPath $script:GcAdminConfigPath

    $coreStatus = Get-GcCoreStatus
    $script:AppState.GcCoreAvailable   = $coreStatus.Available
    $script:AppState.GcCoreModulePath  = $coreStatus.ModulePath
    $script:AppState.GcCoreCatalogPath = $coreStatus.CatalogPath
    $script:AppState.GcCoreVersion     = $coreStatus.Version
    if ($TxtCorePath -and $coreStatus.ModulePath) { $TxtCorePath.Text = $coreStatus.ModulePath }

    if ($coreStatus.Available) {
      Set-Status "Genesys.Core connected via $($coreStatus.DiscoverySource)."
    } else {
      Set-Status "Genesys.Core not found — $($coreStatus.LastError)"
    }
  } catch {
    Set-Status "Auto-discovery failed: $_"
  }

  Refresh-CoreStatusBar
}.GetNewClosure()) }

if ($TxtCoreStatus) { $TxtCoreStatus.Add_MouseLeftButtonUp({
  # Clicking the Core status chip in the status bar opens the Integration tab
  Open-Backstage -Tab 'Integration'
}) }

# -----------------------------
# Views
# -----------------------------

function Show-TimelineWindow {
  <#
  .SYNOPSIS
    Opens a new timeline window for a conversation.

  .PARAMETER ConversationId
    The conversation ID to display timeline for

  .PARAMETER TimelineEvents
    Array of timeline events to display

  .PARAMETER SubscriptionEvents
    Optional array of subscription events to include
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ConversationId,

    [Parameter(Mandatory)]
    [object[]]$TimelineEvents,

    [object[]]$SubscriptionEvents = @(),

    [object]$ConversationData
  )

  $xamlString = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Conversation Timeline - $ConversationId"
        Height="700" Width="1200"
        WindowStartupLocation="CenterScreen"
        Background="#FFF7F7F9">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#FF111827" CornerRadius="6" Padding="12" Margin="0,0,0,12">
      <StackPanel>
        <TextBlock Text="Conversation Timeline" FontSize="16" FontWeight="SemiBold" Foreground="White"/>
        <TextBlock x:Name="TxtConvInfo" Text="Conversation ID: $ConversationId" FontSize="12" Foreground="#FFA0AEC0" Margin="0,4,0,0"/>
        <TextBlock x:Name="TxtConvMeta" Text="" FontSize="11" Foreground="#FFCBD5E1" Margin="0,6,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <!-- Main Content -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="2*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Timeline Grid -->
      <Border Grid.Column="0" Background="White" CornerRadius="6" BorderBrush="#FFE5E7EB" BorderThickness="1" Padding="12">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <TextBlock Grid.Row="0" Text="Timeline" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,10"/>

          <TabControl Grid.Row="1" x:Name="TabTimeline">
            <TabItem Header="Visual">
              <ListBox x:Name="LstTimelineVisual" Background="White" BorderThickness="0" Margin="0,6,0,0"/>
            </TabItem>
            <TabItem Header="Grid">
              <DataGrid x:Name="DgTimeline"
                        AutoGenerateColumns="False"
                        IsReadOnly="True"
                        SelectionMode="Single"
                        GridLinesVisibility="None"
                        HeadersVisibility="Column"
                        CanUserResizeRows="False"
                        CanUserSortColumns="True"
                        AlternatingRowBackground="#FFF9FAFB"
                        Background="White"
                        Margin="0,6,0,0">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Time" Binding="{Binding TimeFormatted}" Width="170" CanUserSort="True"/>
                  <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="120" CanUserSort="True"/>
                  <DataGridTextColumn Header="Label" Binding="{Binding Label}" Width="*" CanUserSort="True"/>
                </DataGrid.Columns>
              </DataGrid>
            </TabItem>
          </TabControl>
        </Grid>
      </Border>

      <!-- Detail Pane -->
      <Border Grid.Column="2" Background="White" CornerRadius="6" BorderBrush="#FFE5E7EB" BorderThickness="1" Padding="12">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <TextBlock Grid.Row="0" Text="Event Details" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,10"/>

          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
            <TextBox x:Name="TxtDetail"
                     AcceptsReturn="True"
                     IsReadOnly="True"
                     BorderThickness="0"
                     Background="Transparent"
                     FontFamily="Consolas"
                     FontSize="11"
                     TextWrapping="NoWrap"
                     Text="Select an event to view details..."/>
          </ScrollViewer>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
"@

  try {
    $window = ConvertFrom-GcXaml -XamlString $xamlString

    $dgTimeline = $window.FindName('DgTimeline')
    $lstTimelineVisual = $window.FindName('LstTimelineVisual')
    $txtDetail = $window.FindName('TxtDetail')
    $txtConvInfo = $window.FindName('TxtConvInfo')
    $txtConvMeta = $window.FindName('TxtConvMeta')

    # Update conversation info with event count
    $txtConvInfo.Text = "Conversation ID: $ConversationId  |  Events: $($TimelineEvents.Count)"

    # Conversation metadata (best-effort)
    if ($txtConvMeta) {
      try {
        if ($ConversationData) {
          $start = $null
          $end = $null
          try {
            if ($ConversationData.conversationStart) { $start = [datetime]::Parse($ConversationData.conversationStart) }
            elseif ($ConversationData.startTime) { $start = [datetime]::Parse($ConversationData.startTime) }
          } catch { }
          try {
            if ($ConversationData.conversationEnd) { $end = [datetime]::Parse($ConversationData.conversationEnd) }
            elseif ($ConversationData.endTime) { $end = [datetime]::Parse($ConversationData.endTime) }
          } catch { }

          $duration = ''
          if ($start -and $end) {
            $span = $end.ToUniversalTime() - $start.ToUniversalTime()
            $duration = ("Duration: {0:mm\\:ss}" -f $span)
          }

          $participants = 0
          try { if ($ConversationData.participants) { $participants = $ConversationData.participants.Count } } catch { }

          $queues = @()
          try {
            if ($ConversationData.participants) {
              foreach ($p in $ConversationData.participants) {
                foreach ($s in @($p.sessions)) {
                  foreach ($seg in @($s.segments)) {
                    if ($seg.queueName) { $queues += [string]$seg.queueName }
                    elseif ($seg.queueId) { $queues += [string]$seg.queueId }
                  }
                }
              }
            }
          } catch { }
          $queues = @($queues | Where-Object { $_ } | Select-Object -Unique)

          $media = @()
          try {
            if ($ConversationData.participants) {
              foreach ($p in $ConversationData.participants) {
                foreach ($s in @($p.sessions)) {
                  if ($s.mediaType) { $media += [string]$s.mediaType }
                }
              }
            }
          } catch { }
          $media = @($media | Where-Object { $_ } | Select-Object -Unique)

          $metaParts = @()
          if ($start) { $metaParts += ("Start: {0}" -f $start.ToString('yyyy-MM-dd HH:mm:ss')) }
          if ($end)   { $metaParts += ("End: {0}" -f $end.ToString('yyyy-MM-dd HH:mm:ss')) }
          if ($duration) { $metaParts += $duration }
          $metaParts += ("Participants: {0}" -f $participants)
          if ($queues.Count -gt 0) { $metaParts += ("Queues: {0}" -f ($queues -join ', ')) }
          if ($media.Count -gt 0)  { $metaParts += ("Media: {0}" -f ($media -join ', ')) }

          $txtConvMeta.Text = ($metaParts -join "  |  ")
        } else {
          $txtConvMeta.Text = ""
        }
      } catch {
        $txtConvMeta.Text = ""
      }
    }

    function Get-CategoryBrushLocal {
      param([string]$Category)
      switch ($Category) {
        'Error'        { return (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(220, 38, 38))) } # red-600
        'Transcription'{ return (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(37, 99, 235))) } # blue-600
        'AgentAssist'  { return (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(124, 58, 237))) } # violet-600
        'MediaStats'   { return (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(5, 150, 105))) }  # emerald-600
        'System'       { return (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(75, 85, 99))) }    # gray-600
        'Live Events'  { return (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(245, 158, 11))) }   # amber-500
        default        { return (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(17, 24, 39))) }     # gray-900
      }
    }

    # Prepare timeline events for display (add formatted time property)
    $displayEvents = @()
    foreach ($evt in $TimelineEvents) {
      $preview = ''
      try {
        if ($evt.Details -and $evt.Details.PSObject.Properties.Name -contains 'text' -and $evt.Details.text) {
          $preview = [string]$evt.Details.text
        } elseif ($evt.Details -is [string]) {
          $preview = $evt.Details
        } elseif ($evt.Details) {
          $preview = ($evt.Details | ConvertTo-Json -Compress -Depth 6)
        }
      } catch { $preview = '' }
      if ($preview -and $preview.Length -gt 180) { $preview = $preview.Substring(0, 180) + '…' }

      $displayEvent = [PSCustomObject]@{
        Time = $evt.Time
        TimeFormatted = $evt.Time.ToString('yyyy-MM-dd HH:mm:ss.fff')
        TimeShort = $evt.Time.ToString('HH:mm:ss.fff')
        Category = $evt.Category
        CategoryBrush = (Get-CategoryBrushLocal -Category $evt.Category)
        Label = $evt.Label
        DetailPreview = $preview
        Details = $evt.Details
        CorrelationKeys = $evt.CorrelationKeys
        OriginalEvent = $evt
      }
      $displayEvents += $displayEvent
    }

    # Bind events to DataGrid
    $dgTimeline.ItemsSource = $displayEvents

    # Build a simple "visual" list with a custom template (uses the same displayEvents items)
    if ($lstTimelineVisual) {
      $lstTimelineVisual.ItemTemplate = $null
      $visualTemplate = @"
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <Grid Margin="0,4,0,4">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="90"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <TextBlock Grid.Column="0" Text="{Binding TimeShort}" Foreground="#FF6B7280" FontFamily="Consolas" FontSize="11" VerticalAlignment="Top" Margin="0,2,10,0"/>

    <Border Grid.Column="1" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="8" Padding="10" Background="White">
      <StackPanel>
        <StackPanel Orientation="Horizontal">
          <Border Background="{Binding CategoryBrush}" CornerRadius="10" Padding="8,2" Margin="0,0,10,0" VerticalAlignment="Center">
            <TextBlock Text="{Binding Category}" Foreground="White" FontSize="11"/>
          </Border>
          <TextBlock Text="{Binding Label}" FontWeight="SemiBold" Foreground="#FF111827" TextWrapping="Wrap"/>
        </StackPanel>
        <TextBlock Text="{Binding DetailPreview}" Margin="0,6,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
  </Grid>
</DataTemplate>
"@
      $lstTimelineVisual.ItemTemplate = ([System.Windows.Markup.XamlReader]::Parse($visualTemplate))
      $lstTimelineVisual.ItemsSource = $displayEvents
    }

    $updateDetail = {
      param($selected)
      if (-not $selected) { return }
      $detailObj = [ordered]@{
        Time = $selected.Time.ToString('o')
        Category = $selected.Category
        Label = $selected.Label
        CorrelationKeys = $selected.CorrelationKeys
        Details = $selected.Details
      }
      $txtDetail.Text = ($detailObj | ConvertTo-Json -Depth 10)
    }.GetNewClosure()

    # Handle selection change to show details (both views)
    $dgTimeline.Add_SelectionChanged({ if ($dgTimeline.SelectedItem) { & $updateDetail $dgTimeline.SelectedItem } }.GetNewClosure())
    if ($lstTimelineVisual) {
      $lstTimelineVisual.Add_SelectionChanged({ if ($lstTimelineVisual.SelectedItem) { & $updateDetail $lstTimelineVisual.SelectedItem } }.GetNewClosure())
    }

    # Show window
    $window.ShowDialog() | Out-Null

  } catch {
    Write-Error "Failed to show timeline window: $_"
    [System.Windows.MessageBox]::Show(
      "Failed to show timeline window: $_",
      "Error",
      [System.Windows.MessageBoxButton]::OK,
      [System.Windows.MessageBoxImage]::Error
    )
  }
}

function New-PlaceholderView {
  param([string]$Title, [string]$Hint)

  # Escape XML special characters to prevent parsing errors
  $escapedTitle = Escape-GcXml $Title
  $escapedHint = Escape-GcXml $Hint

  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <Grid>
    <Border CornerRadius="10" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="14">
      <StackPanel>
        <TextBlock Text="$escapedTitle" FontSize="16" FontWeight="SemiBold" Foreground="#FF111827"/>
        <TextBlock Text="$escapedHint" Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
        <TextBlock Text="UX-first module shell. Backend wiring comes later via a non-blocking job engine."
                   Margin="0,10,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
  </Grid>
</UserControl>
"@

  ConvertFrom-GcXaml -XamlString $xamlString
}

# All New-*View workspace view functions are in App/Views/*.ps1
# (dot-sourced at startup — see the dot-source block near the top of this file)

# -----------------------------
# Routing (workspace + module)
# -----------------------------
function Populate-Modules([string]$workspace) {
  $NavModules.Items.Clear()
  foreach ($m in $script:WorkspaceModules[$workspace]) {
    $NavModules.Items.Add($m) | Out-Null
  }
  $TxtModuleHeader.Text = "Modules — $workspace"
  $TxtModuleHint.Text   = "Select a module"
}

function Set-ContentForModule([string]$workspace, [string]$module) {
  Write-GcTrace -Level 'NAV' -Message ("Workspace='{0}' Module='{1}'" -f $workspace, $module)
  $script:AppState.Workspace = $workspace
  $script:AppState.Module    = $module

  $TxtTitle.Text    = $workspace
  $TxtSubtitle.Text = $module

  switch ("$workspace::$module") {
    'Operations::Topic Subscriptions' {
      $TxtSubtitle.Text = 'Topic Subscriptions (AudioHook / Agent Assist monitoring)'
      $MainHost.Content = (New-SubscriptionsView)
    }
    'Operations::Operational Event Logs' {
      $TxtSubtitle.Text = 'Query and export operational event logs'
      $MainHost.Content = (New-OperationalEventLogsView)
    }
    'Operations::Audit Logs' {
      $TxtSubtitle.Text = 'Query and export audit logs'
      $MainHost.Content = (New-AuditLogsView)
    }
    'Operations::OAuth / Token Usage' {
      $TxtSubtitle.Text = 'View OAuth clients and token usage'
      $MainHost.Content = (New-OAuthTokenUsageView)
    }
    'Conversations::Conversation Lookup' {
      $TxtSubtitle.Text = 'Search conversations by date range, participants, and filters'
      $MainHost.Content = (New-ConversationLookupView)
    }
    'Conversations::Conversation Timeline' {
      $TxtSubtitle.Text = 'Timeline-first: evidence → story → export'
      $MainHost.Content = (New-ConversationTimelineView)
    }
    'Conversations::Analytics Jobs' {
      $TxtSubtitle.Text = 'Submit and monitor analytics queries'
      $MainHost.Content = (New-AnalyticsJobsView)
    }
    'Conversations::Incident Packet' {
      $TxtSubtitle.Text = 'Generate comprehensive incident packets'
      $MainHost.Content = (New-IncidentPacketView)
    }
    'Conversations::Abandon & Experience' {
      $TxtSubtitle.Text = 'Analyze abandonment metrics and customer experience'
      $MainHost.Content = (New-AbandonExperienceView)
    }
    'Conversations::Media & Quality' {
      $TxtSubtitle.Text = 'View recordings, transcripts, and quality evaluations'
      $MainHost.Content = (New-MediaQualityView)
    }
    'Orchestration::Flows' {
      $TxtSubtitle.Text = 'View and export Architect flows'
      $MainHost.Content = (New-FlowsView)
    }
    'Orchestration::Data Actions' {
      $TxtSubtitle.Text = 'View and export data actions'
      $MainHost.Content = (New-DataActionsView)
    }
    'Orchestration::Config Export' {
      $TxtSubtitle.Text = 'Export configuration to JSON for backup or migration'
      $MainHost.Content = (New-ConfigExportView)
    }
    'Orchestration::Dependency / Impact Map' {
      $TxtSubtitle.Text = 'Search flows for object references and dependencies'
      $MainHost.Content = (New-DependencyImpactMapView)
    }
    'Routing & People::Queues' {
      $TxtSubtitle.Text = 'View and export routing queues'
      $MainHost.Content = (New-QueuesView)
    }
    'Routing & People::Skills' {
      $TxtSubtitle.Text = 'View and export ACD skills'
      $MainHost.Content = (New-SkillsView)
    }
    'Routing & People::Users & Presence' {
      $TxtSubtitle.Text = 'View users and monitor presence status'
      $MainHost.Content = (New-UsersPresenceView)
    }
    'Routing & People::Routing Snapshot' {
      $TxtSubtitle.Text = 'Real-time routing health and queue metrics'
      $MainHost.Content = (New-RoutingSnapshotView)
    }
    'Reports & Exports::Report Builder' {
      $TxtSubtitle.Text = 'Template-driven report generation with HTML + CSV + JSON + XLSX output'
      $MainHost.Content = (New-ReportsExportsView)
    }
    'Reports & Exports::Export History' {
      $TxtSubtitle.Text = 'View and manage past exports from App/artifacts index'
      $MainHost.Content = (New-ReportsExportsView)
    }
    'Reports & Exports::Quick Exports' {
      $TxtSubtitle.Text = 'Contextual export buttons for grid-based views'
      $MainHost.Content = (New-ReportsExportsView)
    }
    'Audits::Extension Audit' {
      $TxtSubtitle.Text = 'Detect extension misconfigurations and user anomalies'
      $MainHost.Content = (New-ExtensionAuditView)
    }
    default {
      $route = "$workspace::$module"
      if ($script:AddonsByRoute -and $script:AddonsByRoute.ContainsKey($route)) {
        $addon = $script:AddonsByRoute[$route]
        if ($addon.Description) { $TxtSubtitle.Text = [string]$addon.Description }
        $MainHost.Content = (Get-GcAddonView -Addon $addon)
      } else {
        $MainHost.Content = (New-PlaceholderView -Title $module -Hint "Module shell for $workspace. UX-first; job-driven backend later.")
      }
    }
  }

  try { Apply-DisabledReasonsToView -Root $MainHost.Content } catch { }
  Set-Status "Workspace: $workspace  |  Module: $module"
}

function Show-WorkspaceAndModule {
  param([Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$Module)

  # Select workspace
  for ($i=0; $i -lt $NavWorkspaces.Items.Count; $i++) {
    if ([string]$NavWorkspaces.Items[$i].Content -eq $Workspace) {
      $NavWorkspaces.SelectedIndex = $i
      break
    }
  }

  Populate-Modules -workspace $Workspace

  # Select module
  for ($i=0; $i -lt $NavModules.Items.Count; $i++) {
    if ([string]$NavModules.Items[$i] -eq $Module) {
      $NavModules.SelectedIndex = $i
      break
    }
  }

  Set-ContentForModule -workspace $Workspace -module $Module
}

# -----------------------------
# Nav events
# -----------------------------
Publish-GcScriptFunctionsToGlobal -ScriptPath $PSCommandPath

$NavWorkspaces.Add_SelectionChanged({
  $item = $NavWorkspaces.SelectedItem
  if (-not $item) { return }

  $ws = [string]$item.Content
  Populate-Modules -workspace $ws

  $NavModules.SelectedIndex = 0
  $default = [string]$NavModules.SelectedItem
  if ($default) { Set-ContentForModule -workspace $ws -module $default }
})

$NavModules.Add_SelectionChanged({
  $wsItem = $NavWorkspaces.SelectedItem
  if (-not $wsItem) { return }
  $ws = [string]$wsItem.Content

  $module = [string]$NavModules.SelectedItem
  if (-not $module) { return }

  Set-ContentForModule -workspace $ws -module $module
})

# -----------------------------
# Top bar actions
# -----------------------------

### BEGIN: Manual Token Entry
# Add right-click context menu to Authentication button for quick auth helpers
$authContextMenu = New-Object System.Windows.Controls.ContextMenu

$authDialogMenuItem = New-Object System.Windows.Controls.MenuItem
$authDialogMenuItem.Header = "Authentication…"
$authDialogMenuItem.Add_Click({ Show-AuthenticationDialog })
$authContextMenu.Items.Add($authDialogMenuItem) | Out-Null

$pasteTokenMenuItem = New-Object System.Windows.Controls.MenuItem
$pasteTokenMenuItem.Header = "Paste Token…"
$pasteTokenMenuItem.Add_Click({ Show-SetTokenDialog })
$authContextMenu.Items.Add($pasteTokenMenuItem) | Out-Null

$testTokenMenuItem = New-Object System.Windows.Controls.MenuItem
$testTokenMenuItem.Header = "Test Token"
$testTokenMenuItem.Add_Click({ Start-TokenTest })
$authContextMenu.Items.Add($testTokenMenuItem) | Out-Null

$logoutMenuItem = New-Object System.Windows.Controls.MenuItem
$logoutMenuItem.Header = "Logout"
$logoutMenuItem.Add_Click({ Invoke-GcLogoutUi })
$authContextMenu.Items.Add($logoutMenuItem) | Out-Null

$offlineEnableMenuItem = New-Object System.Windows.Controls.MenuItem
$offlineEnableMenuItem.Header = "Offline Demo: Enable"
$offlineEnableMenuItem.Add_Click({ Set-OfflineDemoMode -Enabled $true })
$authContextMenu.Items.Add($offlineEnableMenuItem) | Out-Null

$offlineDisableMenuItem = New-Object System.Windows.Controls.MenuItem
$offlineDisableMenuItem.Header = "Offline Demo: Disable"
$offlineDisableMenuItem.Add_Click({ Set-OfflineDemoMode -Enabled $false })
$authContextMenu.Items.Add($offlineDisableMenuItem) | Out-Null

$offlineSeedMenuItem = New-Object System.Windows.Controls.MenuItem
$offlineSeedMenuItem.Header = "Offline Demo: Seed Sample Events"
$offlineSeedMenuItem.Add_Click({ Add-OfflineDemoSampleEvents -Count 18 })
$authContextMenu.Items.Add($offlineSeedMenuItem) | Out-Null

$traceLogMenuItem = New-Object System.Windows.Controls.MenuItem
$traceLogMenuItem.Header = "Open Trace Log"
$traceLogMenuItem.Add_Click({
  try {
    if ($script:GcTraceLogPath -and (Test-Path -LiteralPath $script:GcTraceLogPath)) {
      Start-Process -FilePath $script:GcTraceLogPath | Out-Null
    } else {
      Start-Process -FilePath $script:ArtifactsDir | Out-Null
    }
  } catch { }
})
$authContextMenu.Items.Add($traceLogMenuItem) | Out-Null

$appLogMenuItem = New-Object System.Windows.Controls.MenuItem
$appLogMenuItem.Header = "Open App Log"
$appLogMenuItem.Add_Click({
  try {
    if ($script:GcAppLogPath -and (Test-Path -LiteralPath $script:GcAppLogPath)) {
      Start-Process -FilePath $script:GcAppLogPath | Out-Null
    } else {
      Start-Process -FilePath $script:ArtifactsDir | Out-Null
    }
  } catch { }
})
$authContextMenu.Items.Add($appLogMenuItem) | Out-Null

$BtnAuth.ContextMenu = $authContextMenu
### END: Manual Token Entry

$BtnAuth.Add_Click({
  if (Test-OfflineDemoEnabled) {
    Set-OfflineDemoMode -Enabled $false
    return
  }

  Show-AuthenticationDialog
})

$BtnBackstage.Add_Click({ Open-Backstage -Tab 'Jobs' })

# Keep Jobs list fresh (light polling)
$script:JobsRefreshTimer = New-Object Windows.Threading.DispatcherTimer
$script:JobsRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:JobsRefreshTimer.Add_Tick({
  if ($BackstageOverlay.Visibility -eq 'Visible') {
    Refresh-JobsList
  } else {
    Refresh-HeaderStats
  }
})
$script:JobsRefreshTimer.Start()

# -----------------------------
# Initial view
# -----------------------------
if ($OfflineDemo) {
  Set-OfflineDemoMode -Enabled $true
}
Set-TopContext
Refresh-HeaderStats

# Default: Operations → Topic Subscriptions
for ($i=0; $i -lt $NavWorkspaces.Items.Count; $i++) {
  if ([string]$NavWorkspaces.Items[$i].Content -eq 'Operations') { $NavWorkspaces.SelectedIndex = $i; break }
}
Populate-Modules -workspace 'Operations'
$NavModules.SelectedIndex = 0
Set-ContentForModule -workspace 'Operations' -module 'Topic Subscriptions'

# Seed one artifact (so the artifacts list isn't empty)
$seedFile = Join-Path -Path $script:ArtifactsDir -ChildPath "welcome-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
"Artifacts appear here when you export packets, summaries, or reports." | Set-Content -Path $seedFile -Encoding UTF8
$script:AppState.Artifacts.Add((New-Artifact -Name 'Welcome Artifact' -Path $seedFile)) | Out-Null
Refresh-ArtifactsList

# Show
[void]$Window.ShowDialog()

### BEGIN: Manual Token Entry - Test Checklist
<#
MANUAL TEST CHECKLIST - Manual Token Entry Flow

Prerequisites:
- Valid Genesys Cloud access token (obtain from Developer Tools or OAuth flow)
- Valid region (e.g., mypurecloud.com, mypurecloud.com.au, etc.)

Test Cases:

1. Test Token Button (No Token):
   [ ] Click "Test Token" button when no token is set
   [ ] Verify "Set Access Token" dialog opens
   [ ] Verify Region field is prefilled with current region
   [ ] Verify Token field is empty

2. Manual Token Entry - Valid Token:
   [ ] Right-click "Login…" button
   [ ] Select "Paste Token…" from context menu
   [ ] Verify dialog opens
   [ ] Enter valid region (e.g., mypurecloud.com)
   [ ] Paste valid access token
   [ ] Click "Set + Test" button
   [ ] Verify dialog closes
   [ ] Verify token test job starts automatically
   [ ] Verify status bar shows "Testing token..."
   [ ] Verify top context updates with "Manual token" and "Token set (manual)"
   [ ] Verify token test succeeds with user info displayed

3. Manual Token Entry - Bearer Prefix Removal:
   [ ] Open "Set Access Token" dialog
   [ ] Paste token with "Bearer " prefix (e.g., "Bearer abc123...")
   [ ] Click "Set + Test"
   [ ] Verify token is accepted and "Bearer " prefix is removed
   [ ] Verify token test succeeds

4. Manual Token Entry - Invalid Token:
   [ ] Open "Set Access Token" dialog
   [ ] Enter invalid token
   [ ] Click "Set + Test"
   [ ] Verify token test starts
   [ ] Verify error message appears indicating token is invalid
   [ ] Verify AppState shows "Token invalid"

5. Manual Token Entry - Cancel:
   [ ] Open "Set Access Token" dialog
   [ ] Enter region and token
   [ ] Click "Cancel" button
   [ ] Verify dialog closes without changes
   [ ] Verify AppState remains unchanged

6. Manual Token Entry - Clear Token:
   [ ] Set a valid token first
   [ ] Open "Set Access Token" dialog
   [ ] Click "Clear Token" button
   [ ] Verify confirmation dialog appears
   [ ] Click "Yes" to confirm
   [ ] Verify token is cleared from AppState
   [ ] Verify top context updates to show "Not logged in" and "No token"
   [ ] Verify status bar shows "Token cleared."

7. Manual Token Entry - Validation:
   [ ] Open "Set Access Token" dialog
   [ ] Leave Region field empty
   [ ] Click "Set + Test"
   [ ] Verify warning message: "Region Required"
   [ ] Enter region, leave Token field empty
   [ ] Click "Set + Test"
   [ ] Verify warning message: "Token Required"

8. Context Menu:
   [ ] Right-click "Login…" button
   [ ] Verify context menu appears with "Paste Token…" option
   [ ] Click "Paste Token…"
   [ ] Verify "Set Access Token" dialog opens

9. Integration with Token Test:
   [ ] Set a manual token using the dialog
   [ ] Click "Test Token" button (not from dialog)
   [ ] Verify token test runs with existing token
   [ ] Verify no dialog appears when token already exists

10. UI State After Manual Token:
    [ ] Set manual token successfully
    [ ] Verify "Login…" button remains as "Login…" (not "Logout")
    [ ] Verify top bar shows correct region, org, auth status, and token status
    [ ] Verify "Test Token" button remains enabled
    [ ] Verify can perform operations requiring authentication (e.g., Open Timeline)

Notes:
- All changes are marked with "### BEGIN: Manual Token Entry" and "### END: Manual Token Entry" comments
- Dialog is modal and centers on parent window
- Token is automatically trimmed and "Bearer " prefix is removed if present
- Dialog triggers existing token test logic after setting token
- No changes to main window layout or OAuth login flow
#>
### END: Manual Token Entry - Test Checklist

### END FILE
