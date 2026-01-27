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

# -----------------------------
# XAML Helpers
# -----------------------------

function Escape-GcXml {
  <#
  .SYNOPSIS
    Escapes special XML characters to prevent parsing errors.

  .DESCRIPTION
    Uses System.Security.SecurityElement.Escape to properly escape
    special characters like &, <, >, ", ' in XML/XAML content.

  .PARAMETER Text
    The text to escape for XML/XAML.

  .EXAMPLE
    Escape-GcXml "Routing & People"
    # Returns: "Routing &amp; People"
  #>
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  return [System.Security.SecurityElement]::Escape($Text)
}

function ConvertFrom-GcXaml {
  <#
  .SYNOPSIS
    Safely loads XAML from a string using XmlReader + XamlReader.Load.

  .DESCRIPTION
    This function provides a safe way to load XAML that avoids issues
    with direct [xml] casting, particularly when XAML contains x:Name
    or other namespace-dependent elements. It uses XmlReader with
    proper settings and XamlReader.Load for parsing.

  .PARAMETER XamlString
    The XAML string to parse.

  .EXAMPLE
    $view = ConvertFrom-GcXaml -XamlString $xamlString
  #>
  param([Parameter(Mandatory)][string]$XamlString)

  try {
    # Create StringReader from XAML string
    $stringReader = New-Object System.IO.StringReader($XamlString)

    # Create XmlReader with appropriate settings
    $xmlReaderSettings = New-Object System.Xml.XmlReaderSettings
    $xmlReaderSettings.IgnoreWhitespace = $false
    $xmlReaderSettings.IgnoreComments = $true

    $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $xmlReaderSettings)

    # Load XAML using XamlReader
    $result = [Windows.Markup.XamlReader]::Load($xmlReader)

    # Clean up
    $xmlReader.Close()
    $stringReader.Close()

    return $result
  }
  catch {
    Write-Error "Failed to parse XAML: $($_.Exception.Message)"
    throw
  }
}

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
} catch { }

Set-GcAuthConfig `
  -Region 'usw2.pure.cloud' `
  -ClientId 'YOUR_CLIENT_ID_HERE' `
  -RedirectUri 'http://localhost:8085/callback' `
  -Scopes @('conversations', 'analytics', 'notifications', 'users')

$script:AppState = [ordered]@{
  Region       = 'usw2.pure.cloud'
  Org          = ''
  Auth         = 'Not logged in'
  TokenStatus  = 'No token'
  AccessToken  = $null  # STEP 1: Set a token here for testing: $script:AppState.AccessToken = "YOUR_TOKEN_HERE"
  RepositoryRoot = $repoRoot

  Workspace    = 'Operations'
  Module       = 'Topic Subscriptions'
  IsStreaming  = $false

  SubscriptionProvider = $null
  EventBuffer          = New-Object System.Collections.ObjectModel.ObservableCollection[object]
  PinnedEvents         = New-Object System.Collections.ObjectModel.ObservableCollection[object]

  Jobs         = New-Object System.Collections.ObjectModel.ObservableCollection[object]
  Artifacts    = New-Object System.Collections.ObjectModel.ObservableCollection[object]

  PinnedCount  = 0
  StreamCount  = 0
  FocusConversationId = ''
}

# STEP 1 CHANGE: Make AppState available to HttpRequests module for Invoke-AppGcRequest
# This allows the wrapper function to automatically inject AccessToken and Region
Set-GcAppState -State ([ref]$script:AppState)

$script:ArtifactsDir = Join-Path -Path $PSScriptRoot -ChildPath 'artifacts'
New-Item -ItemType Directory -Path $script:ArtifactsDir -Force | Out-Null

# When this script is executed (not dot-sourced), WPF event handlers run in global scope.
# Publish key state/paths to global so handlers can resolve them reliably.
$global:repoRoot = $repoRoot
$global:coreRoot = $coreRoot
$global:AppState = $script:AppState
$global:ArtifactsDir = $script:ArtifactsDir

# -----------------------------
# Trace log (persistent diagnostics)
# -----------------------------
# Used by OfflineDemo + optional debug logging across runspaces/modules.
$script:GcTraceEnvVar = 'GC_TOOLKIT_TRACE'
$script:GcTraceLogEnvVar = 'GC_TOOLKIT_TRACE_LOG'
$script:GcTraceLogPath = Join-Path -Path $script:ArtifactsDir -ChildPath ("trace-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { [Environment]::SetEnvironmentVariable($script:GcTraceLogEnvVar, $script:GcTraceLogPath, 'Process') } catch { }

function Test-GcTraceEnabled {
  try {
    $v = [Environment]::GetEnvironmentVariable($script:GcTraceEnvVar)
    return ($v -and ($v -match '^(1|true|yes|on)$'))
  } catch {
    return $false
  }
}

function Write-GcTrace {
  param(
    [Parameter(Mandatory)][string]$Message,
    [string]$Level = 'INFO'
  )

  if (-not (Test-GcTraceEnabled)) { return }

  $ts = (Get-Date).ToString('HH:mm:ss.fff')
  $line = "[{0}] [{1}] {2}" -f $ts, $Level.ToUpperInvariant(), $Message

  try {
    $path = [Environment]::GetEnvironmentVariable($script:GcTraceLogEnvVar)
    if ($path) { Add-Content -LiteralPath $path -Value $line -Encoding utf8 }
  } catch { }
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
  try { $searchText = ($h.TxtTemplateSearch.Text ?? '') } catch { $searchText = '' }
  $searchText = $searchText.ToLower()

  $filtered = $Templates
  if ($searchText -and $searchText -ne 'search templates...') {
    $filtered = $Templates | Where-Object {
      (($_.Name ?? '').ToLower().Contains($searchText)) -or
      (($_.Description ?? '').ToLower().Contains($searchText))
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

function Sync-AppStateFromUi {
  <#
  .SYNOPSIS
    Synchronizes UI control values back into AppState with normalization.

  .DESCRIPTION
    Reads region/token fields from login dialog or manual entry controls,
    normalizes them using Core/HttpRequests.psm1 functions, and updates AppState.
    Calls Set-TopContext afterward to refresh the UI.

  .PARAMETER RegionControl
    Optional TextBox containing region/instance name input.

  .PARAMETER TokenControl
    Optional TextBox containing access token input.

  .EXAMPLE
    Sync-AppStateFromUi -RegionControl $h.TxtRegion -TokenControl $h.TxtAccessToken
  #>
  param(
    [AllowNull()]$RegionControl,
    [AllowNull()]$TokenControl
  )

  # Read and normalize region if control provided
  if ($RegionControl) {
    $rawRegion = Get-UiTextSafe -Control $RegionControl
    if (-not [string]::IsNullOrWhiteSpace($rawRegion)) {
      $normalized = Normalize-GcInstanceName -RegionText $rawRegion
      if ($normalized) {
        $script:AppState.Region = $normalized
        Write-GcTrace -Level 'INFO' -Message "AppState.Region updated: $normalized"
      }
    }
  }

  # Read and normalize token if control provided
  if ($TokenControl) {
    $rawToken = Get-UiTextSafe -Control $TokenControl
    if (-not [string]::IsNullOrWhiteSpace($rawToken)) {
      $normalized = Normalize-GcAccessToken -TokenText $rawToken
      if ($normalized) {
        $script:AppState.AccessToken = $normalized
        Write-GcTrace -Level 'INFO' -Message "AppState.AccessToken updated (length: $($normalized.Length))"
      }
    }
  }

  # Refresh UI context display
  try { Set-TopContext } catch { }
}

function Get-CallContext {
  <#
  .SYNOPSIS
    Builds a call context hashtable for API functions.

  .DESCRIPTION
    Returns a hashtable containing InstanceName, AccessToken, and IsOfflineDemo.
    If offline demo is enabled and token/region are missing, sets safe defaults.
    If not offline and token is missing, returns null to indicate invalid context.

  .OUTPUTS
    Hashtable with keys: InstanceName, AccessToken, IsOfflineDemo, Region
    Returns $null if context is invalid (missing token when not in offline mode).

  .EXAMPLE
    $ctx = Get-CallContext
    if ($ctx) {
      $result = Invoke-GcRequest -InstanceName $ctx.InstanceName -AccessToken $ctx.AccessToken ...
    }
  #>

  $isOffline = Test-OfflineDemoEnabled

  # Get current values from AppState
  $region = $script:AppState.Region
  $token = $script:AppState.AccessToken

  # In offline demo mode, ensure safe defaults
  if ($isOffline) {
    if ([string]::IsNullOrWhiteSpace($region) -or $region -eq 'usw2.pure.cloud') {
      $region = 'offline.local'
      $script:AppState.Region = $region
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
      $token = 'offline-demo'
      $script:AppState.AccessToken = $token
    }
    if ([string]::IsNullOrWhiteSpace($script:AppState.FocusConversationId)) {
      $script:AppState.FocusConversationId = 'c-demo-001'
    }
  } else {
    # Not in offline mode - token is required
    if ([string]::IsNullOrWhiteSpace($token)) {
      Write-GcTrace -Level 'WARN' -Message "Get-CallContext: No access token available and not in offline mode"
      return $null
    }
  }

  # Build and return context
  return @{
    InstanceName    = $region
    Region          = $region  # Some functions use Region instead of InstanceName
    AccessToken     = $token
    IsOfflineDemo   = $isOffline
  }
}

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

function Set-ControlEnabled {
  param(
    $Control,
    [Parameter(Mandatory)][bool]$Enabled
  )
  if ($null -eq $Control) { return }
  try {
    if ($Control -is [System.Windows.Threading.DispatcherObject] -and -not $Control.Dispatcher.CheckAccess()) {
      $Control.Dispatcher.Invoke(([action]{ Set-ControlEnabled -Control $Control -Enabled $Enabled }))
      return
    }
  } catch { }

  try { $Control.IsEnabled = $Enabled; return } catch { }
  try { $Control.Enabled = $Enabled; return } catch { }
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

function Enable-PrimaryActionButtons {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]
    [hashtable]$Handles
  )

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


function Set-ControlEnabled {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)] $Control,
    [Parameter(Mandatory=$true)] [bool] $Enabled
  )

  if ($null -eq $Control) { return }

  # WPF
  if ($Control.PSObject.Properties.Match('IsEnabled').Count -gt 0) {
    try { $Control.IsEnabled = $Enabled; return } catch { }
  }

  # WinForms
  if ($Control.PSObject.Properties.Match('Enabled').Count -gt 0) {
    try { $Control.Enabled = $Enabled; return } catch { }
  }

  # Fallback: do nothing (better than crashing)
}

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

  Start-GcJob -Job $job -ScriptBlock $wrappedScriptBlock -ArgumentList @(
    $coreRootForJob,
    $appStateSnapshot,
    $artifactsDirSnapshot,
    $userScriptText,
    $userArgs
  ) -OnComplete $OnCompleted

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

# -----------------------------
# Workspaces + Modules
# -----------------------------
$script:WorkspaceModules = [ordered]@{
  'Orchestration' = @(
    'Flows',
    'Data Actions',
    'Dependency / Impact Map',
    'Config Export'
  )
  'Routing & People' = @(
    'Queues',
    'Skills',
    'Users & Presence',
    'Routing Snapshot'
  )
  'Conversations' = @(
    'Conversation Lookup',
    'Conversation Timeline',
    'Media & Quality',
    'Abandon & Experience',
    'Analytics Jobs',
    'Incident Packet'
  )
  'Operations' = @(
    'Topic Subscriptions',
    'Operational Event Logs',
    'Audit Logs',
    'OAuth / Token Usage'
  )
  'Reports & Exports' = @(
    'Report Builder',
    'Export History',
    'Quick Exports'
  )
}

# -----------------------------
# Addons (manifest-driven)
# -----------------------------
$script:AddonsByRoute = @{}

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
      Write-GcTrace -Level 'ADDON' -Message ("Addon '{0}' ignored: unknown workspace '{1}'." -f ($a.Name ?? $a.Id ?? $a.Module), $a.Workspace)
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

  try {
    Ensure-GcAddonLoaded -Addon $Addon
  } catch {
    return New-PlaceholderView -Title ($Addon.Name ?? $Addon.Module) -Hint ("Failed to load addon: {0}" -f $_.Exception.Message)
  }

  if ($Addon.ViewFactory) {
    $cmd = Get-Command -Name $Addon.ViewFactory -ErrorAction SilentlyContinue
    if ($cmd) {
      try {
        return & $cmd -Addon $Addon
      } catch {
        return New-PlaceholderView -Title ($Addon.Name ?? $Addon.Module) -Hint ("Addon view factory failed: {0}" -f $_.Exception.Message)
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
# XAML - App Shell + Backstage + Snackbar
# -----------------------------
$xamlString = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Genesys Cloud Tool — UX Prototype v2.1" Height="900" Width="1560"
        WindowStartupLocation="CenterScreen" Background="#FFF7F7F9">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="56"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="28"/>
    </Grid.RowDefinitions>

    <!-- Top Bar -->
    <DockPanel Grid.Row="0" Background="#FF111827" LastChildFill="True">
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Left" Margin="12,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="Genesys Cloud Tool" Foreground="White" FontSize="16" FontWeight="SemiBold"/>
        <TextBlock Text="  — UX Prototype" Foreground="#FFCBD5E1" FontSize="12" Margin="8,4,0,0"/>
      </StackPanel>

      <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" Margin="0,0,12,0" VerticalAlignment="Center">
        <TextBlock x:Name="TxtContext" Text="Region:  | Org:  | Auth:  | Token:" Foreground="#FFE5E7EB" FontSize="12" Margin="0,0,12,0" VerticalAlignment="Center"/>
        <Button x:Name="BtnAuth" Content="Authentication" Width="130" Height="28" Margin="0,0,10,0" IsEnabled="True"/>
        <Button x:Name="BtnBackstage" Content="Backstage" Width="110" Height="28" Margin="0,0,10,0" IsEnabled="True"/>
      </StackPanel>

      <Border DockPanel.Dock="Right" Margin="0,0,12,0" VerticalAlignment="Center" CornerRadius="6" Background="#FF0B1220" BorderBrush="#FF374151" BorderThickness="1">
        <DockPanel Margin="8,4">
          <TextBlock Text="Ctrl+K" Foreground="#FF9CA3AF" FontSize="11" Margin="0,0,8,0" VerticalAlignment="Center"/>
          <TextBox x:Name="TxtCommand" Width="460" Background="Transparent" Foreground="#FFF9FAFB" BorderThickness="0"
                   FontSize="12" VerticalContentAlignment="Center"
                   ToolTip="Search: endpoints, modules, actions… (mock)"/>
        </DockPanel>
      </Border>
    </DockPanel>

    <!-- Main -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="200"/>
        <ColumnDefinition Width="200"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Workspace Rail -->
      <Border Grid.Column="0" Background="White" BorderBrush="#FFE5E7EB" BorderThickness="0,0,1,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="12,12,12,8">
            <TextBlock Text="Workspaces" FontWeight="SemiBold" Foreground="#FF111827"/>
            <TextBlock Text="Genesys-native categories" FontSize="11" Foreground="#FF6B7280"/>
          </StackPanel>
          <ListBox x:Name="NavWorkspaces" Margin="12,0,12,12">
            <ListBoxItem Content="Orchestration"/>
            <ListBoxItem Content="Routing &amp; People"/>
            <ListBoxItem Content="Conversations"/>
            <ListBoxItem Content="Operations"/>
            <ListBoxItem Content="Reports &amp; Exports"/>
          </ListBox>
        </DockPanel>
      </Border>

      <!-- Module Rail -->
      <Border Grid.Column="1" Background="#FFF9FAFB" BorderBrush="#FFE5E7EB" BorderThickness="0,0,1,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="12,12,12,8">
            <TextBlock x:Name="TxtModuleHeader" Text="Modules" FontWeight="SemiBold" Foreground="#FF111827"/>
            <TextBlock x:Name="TxtModuleHint" Text="Select a module" FontSize="11" Foreground="#FF6B7280"/>
          </StackPanel>
          <ListBox x:Name="NavModules" Margin="12,0,12,12"/>
        </DockPanel>
      </Border>

      <!-- Content -->
      <Grid Grid.Column="2" Margin="14,12,14,12">
        <Grid.RowDefinitions>
          <RowDefinition Height="44"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <DockPanel Grid.Row="0">
          <StackPanel Orientation="Vertical" DockPanel.Dock="Left">
            <TextBlock x:Name="TxtTitle" Text="Operations" FontSize="18" FontWeight="SemiBold" Foreground="#FF111827"/>
            <TextBlock x:Name="TxtSubtitle" Text="Topic Subscriptions (AudioHook / Agent Assist monitoring)" FontSize="12" Foreground="#FF6B7280"/>
          </StackPanel>
        </DockPanel>

        <Border Grid.Row="1" Background="White" CornerRadius="10" BorderBrush="#FFE5E7EB" BorderThickness="1">
          <ContentControl x:Name="MainHost" Margin="12"/>
        </Border>
      </Grid>

      <!-- Backstage Drawer (overlay on right) -->
      <Border x:Name="BackstageOverlay" Grid.ColumnSpan="3" Background="#80000000" Visibility="Collapsed">
        <Grid HorizontalAlignment="Right" Width="560">
          <Border Background="White" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="10" Margin="12" Padding="12">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>

              <DockPanel Grid.Row="0">
                <TextBlock Text="Backstage" FontSize="16" FontWeight="SemiBold" Foreground="#FF111827" DockPanel.Dock="Left"/>
                <Button x:Name="BtnCloseBackstage" Content="Close" Width="70" Height="26" DockPanel.Dock="Right" Margin="0,0,0,0" IsEnabled="False"/>
              </DockPanel>

              <TabControl x:Name="BackstageTabs" Grid.Row="1" Margin="0,10,0,10">
                <TabItem Header="Jobs">
                  <Grid Margin="0,10,0,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="240"/>
                    </Grid.ColumnDefinitions>

                    <ListBox x:Name="LstJobs" Grid.Column="0" Margin="0,0,10,0"/>

                    <Border Grid.Column="1" Background="#FFF9FAFB" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="8" Padding="10">
                      <StackPanel>
                        <TextBlock Text="Job Details" FontWeight="SemiBold" Foreground="#FF111827"/>
                        <TextBlock x:Name="TxtJobMeta" Text="Select a job…" Margin="0,6,0,0" Foreground="#FF374151" TextWrapping="Wrap"/>
                        <Button x:Name="BtnCancelJob" Content="Cancel Job" Height="28" Margin="0,10,0,0" IsEnabled="False"/>
                        <TextBlock Text="Logs" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,12,0,0"/>
                        <ListBox x:Name="LstJobLogs" Height="260" Margin="0,6,0,0"/>
                      </StackPanel>
                    </Border>
                  </Grid>
                </TabItem>

                <TabItem Header="Artifacts">
                  <Grid Margin="0,10,0,0">
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="*"/>
                      <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <TextBlock Text="Recent exports / packets / reports" Foreground="#FF6B7280" FontSize="11"/>

                    <ListBox x:Name="LstArtifacts" Grid.Row="1" Margin="0,10,0,10"/>

                    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
                      <Button x:Name="BtnOpenArtifactsFolder" Content="Open Folder" Width="110" Height="26" Margin="0,0,8,0" IsEnabled="False"/>
                      <Button x:Name="BtnOpenSelectedArtifact" Content="Open Selected" Width="120" Height="26" IsEnabled="False"/>
                    </StackPanel>
                  </Grid>
                </TabItem>
              </TabControl>

              <DockPanel Grid.Row="2">
                <TextBlock x:Name="TxtBackstageFooter"
                           Text="Jobs run in the background. Artifacts are outputs (packets, summaries, reports)."
                           Foreground="#FF6B7280" FontSize="11" VerticalAlignment="Center"/>
              </DockPanel>
            </Grid>
          </Border>
        </Grid>
      </Border>

    </Grid>

    <!-- Status Bar -->
    <DockPanel Grid.Row="2" Background="#FFF3F4F6">
      <TextBlock x:Name="TxtStatus" Margin="12,0" VerticalAlignment="Center" Foreground="#FF374151" FontSize="12"
                 Text="Ready."/>
      <TextBlock x:Name="TxtStats" Margin="0,0,12,0" VerticalAlignment="Center" Foreground="#FF6B7280" FontSize="11"
                 DockPanel.Dock="Right" Text="Pinned: 0 | Stream: 0"/>
    </DockPanel>

    <!-- Snackbar (export complete) -->
    <Border x:Name="SnackbarHost"
            Grid.RowSpan="3"
            HorizontalAlignment="Right"
            VerticalAlignment="Bottom"
            Margin="0,0,16,16"
            Background="#FF111827"
            CornerRadius="10"
            Padding="12"
            Visibility="Collapsed"
            Opacity="0.98">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0" Margin="0,0,12,0">
          <TextBlock x:Name="SnackbarTitle" Text="Export complete" Foreground="White" FontWeight="SemiBold" FontSize="12"/>
          <TextBlock x:Name="SnackbarBody" Text="Artifact created." Foreground="#FFCBD5E1" FontSize="11" TextWrapping="Wrap" Margin="0,4,0,0" MaxWidth="480"/>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnSnackPrimary" Content="Open" Width="72" Height="26" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnSnackSecondary" Content="Folder" Width="72" Height="26" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnSnackClose" Content="×" Width="26" Height="26" Margin="0,0,0,0" HorizontalAlignment="Right"/>
        </StackPanel>
      </Grid>
    </Border>

  </Grid>
</Window>
"@

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
$global:TxtStatus   = Get-El 'TxtStatus'
$global:TxtStats    = Get-El 'TxtStats'

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

# -----------------------------
# Console diagnostics (Token workflows)
# -----------------------------
# NOTE: These are intentionally noisy; the user requested console-level tracing to diagnose 400 responses.
# Set `GC_TOOLKIT_REVEAL_SECRETS=1` to print full token values (otherwise masked).
$script:GcConsoleDiagnosticsEnabled = $true
$script:GcConsoleDiagnosticsRevealSecrets = $false
try {
  if ($env:GC_TOOLKIT_DIAGNOSTICS -and ($env:GC_TOOLKIT_DIAGNOSTICS -match '^(0|false|no|off)$')) {
    $script:GcConsoleDiagnosticsEnabled = $false
  }
  if ($env:GC_TOOLKIT_REVEAL_SECRETS -and ($env:GC_TOOLKIT_REVEAL_SECRETS -match '^(1|true|yes|on)$')) {
    $script:GcConsoleDiagnosticsRevealSecrets = $true
  }
} catch { }

function Format-GcDiagSecret {
  param(
    [AllowNull()][AllowEmptyString()][string]$Value,
    [int]$Head = 10,
    [int]$Tail = 6
  )

  if ($script:GcConsoleDiagnosticsRevealSecrets) { return $Value }
  if ([string]::IsNullOrWhiteSpace($Value)) { return '<empty>' }

  $len = $Value.Length
  if ($len -le ($Head + $Tail + 3)) { return ("<{0} chars>" -f $len) }
  return ("{0}...{1} (<{2} chars>)" -f $Value.Substring(0, $Head), $Value.Substring($len - $Tail), $len)
}

function Write-GcDiag {
  param(
    [Parameter(Mandatory)][string]$Message
  )
  $ts = (Get-Date).ToString('HH:mm:ss.fff')
  $line = ("[{0}] [DIAG] {1}" -f $ts, $Message)
  if ($script:GcConsoleDiagnosticsEnabled) {
    Write-Host $line
  }
  Write-GcTrace -Level 'DIAG' -Message $Message
}

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
      Write-GcDiag ("Manual token entry: region(raw)='{0}' region(normalized)='{1}'" -f ($regionRaw ?? ''), ($region ?? ''))

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
  try { $clientIdTrim = [string]($authConfig.ClientId ?? '') } catch { $clientIdTrim = [string]$authConfig.ClientId }
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
  try { $redirectUriTrim = [string]($authConfig.RedirectUri ?? '') } catch { $redirectUriTrim = [string]$authConfig.RedirectUri }
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
        if ($OnSuccess) { & $OnSuccess $job.Result }
      } else {
        $err = $null
        if ($job.Result) { $err = $job.Result.Error }

        $script:AppState.Auth = "Login failed"
        $script:AppState.TokenStatus = "No token"
        Set-TopContext
        Set-Status "Authentication failed. Check job logs for details."
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
        if ($OnSuccess) { & $OnSuccess $job.Result }
      } else {
        $err = if ($job.Result) { $job.Result.Error } else { "Unknown error" }
        $script:AppState.Auth = "Client credentials failed"
        $script:AppState.TokenStatus = "No token"
        Set-TopContext
        Set-Status "Client credentials token failed."
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
      $txtOauthConfig.Text = @(
        ("Region:       {0}" -f ($authConfig.Region ?? ''))
        ("ClientId:     {0}" -f ($authConfig.ClientId ?? ''))
        ("RedirectUri:  {0}" -f ($authConfig.RedirectUri ?? ''))
        ("Scopes:       {0}" -f (($authConfig.Scopes ?? @()) -join ' '))
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

    & $setDialogStatus ("Current: {0} | {1}" -f ($script:AppState.Auth ?? ''), ($script:AppState.TokenStatus ?? ''))

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
function Refresh-JobsList {
  # Preserve selected index to avoid flashing when list refreshes
  $selectedIdx = $LstJobs.SelectedIndex

  $LstJobs.Items.Clear()
  foreach ($j in $script:AppState.Jobs) {
    $LstJobs.Items.Add("$($j.Status) [$($j.Progress)%] — $($j.Name)") | Out-Null
  }

  # Restore selection if it was valid and still within range
  if ($selectedIdx -ge 0 -and $selectedIdx -lt $LstJobs.Items.Count) {
    $LstJobs.SelectedIndex = $selectedIdx
  }

  Refresh-HeaderStats
}

function Open-Backstage([ValidateSet('Jobs','Artifacts')]$Tab = 'Jobs') {
  Write-GcTrace -Level 'UI' -Message ("Open Backstage Tab='{0}'" -f $Tab)
  if ($Tab -eq 'Jobs') { $BackstageTabs.SelectedIndex = 0 } else { $BackstageTabs.SelectedIndex = 1 }
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
  $idx = $LstJobs.SelectedIndex
  if ($idx -lt 0 -or $idx -ge $script:AppState.Jobs.Count) {
    $TxtJobMeta.Text = "Select a job…"
    $LstJobLogs.Items.Clear()
    Set-ControlEnabled -Control $BtnCancelJob -Enabled ($false)
    return
  }

  $job = $script:AppState.Jobs[$idx]
  $TxtJobMeta.Text = "Name: $($job.Name)`r`nType: $($job.Type)`r`nStatus: $($job.Status)`r`nProgress: $($job.Progress)%"
  $LstJobLogs.Items.Clear()
  foreach ($l in $job.Logs) { $LstJobLogs.Items.Add($l) | Out-Null }
  Set-ControlEnabled -Control $BtnCancelJob -Enabled ([bool]$job.CanCancel)
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

function New-OperationalEventLogsView {
  <#
  .SYNOPSIS
    Creates the Operational Event Logs module view with query, grid, and export capabilities.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Operational Event Logs" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
            <TextBlock Text="Time Range:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="CmbOpTimeRange" Width="140" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="Last 1 hour"/>
              <ComboBoxItem Content="Last 6 hours"/>
              <ComboBoxItem Content="Last 24 hours"/>
              <ComboBoxItem Content="Last 7 days"/>
            </ComboBox>
            <TextBlock Text="Service:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <ComboBox x:Name="CmbOpService" Width="180" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="All Services"/>
              <ComboBoxItem Content="Platform"/>
              <ComboBoxItem Content="Routing"/>
              <ComboBoxItem Content="Analytics"/>
            </ComboBox>
            <TextBlock Text="Level:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <ComboBox x:Name="CmbOpLevel" Width="120" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="All Levels"/>
              <ComboBoxItem Content="Error"/>
              <ComboBoxItem Content="Warning"/>
              <ComboBoxItem Content="Info"/>
            </ComboBox>
          </StackPanel>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnOpQuery" Content="Query" Width="86" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnOpExportJson" Content="Export JSON" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnOpExportCsv" Content="Export CSV" Width="100" Height="32" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Operational Events" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBox x:Name="TxtOpSearch" Margin="12,0,0,0" Width="300" Height="26" Text="Search events..."/>
          <TextBlock x:Name="TxtOpCount" Text="(0 events)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
        </StackPanel>

        <DataGrid x:Name="GridOpEvents" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Timestamp" Binding="{Binding Timestamp}" Width="180"/>
            <DataGridTextColumn Header="Service" Binding="{Binding Service}" Width="150"/>
            <DataGridTextColumn Header="Level" Binding="{Binding Level}" Width="100"/>
            <DataGridTextColumn Header="Message" Binding="{Binding Message}" Width="*"/>
            <DataGridTextColumn Header="User" Binding="{Binding User}" Width="180"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    CmbOpTimeRange   = $view.FindName('CmbOpTimeRange')
    CmbOpService     = $view.FindName('CmbOpService')
    CmbOpLevel       = $view.FindName('CmbOpLevel')
    BtnOpQuery       = $view.FindName('BtnOpQuery')
    BtnOpExportJson  = $view.FindName('BtnOpExportJson')
    BtnOpExportCsv   = $view.FindName('BtnOpExportCsv')
    TxtOpSearch      = $view.FindName('TxtOpSearch')
    TxtOpCount       = $view.FindName('TxtOpCount')
    GridOpEvents     = $view.FindName('GridOpEvents')
  }

  # Store events data for export
  $script:OpEventsData = @()

  # Query button handler
  $h.BtnOpQuery.Add_Click({
    Set-Status "Querying operational events..."
    Set-ControlEnabled -Control $h.BtnOpQuery -Enabled $false
    Set-ControlEnabled -Control $h.BtnOpExportJson -Enabled $false
    Set-ControlEnabled -Control $h.BtnOpExportCsv -Enabled $false

    # Determine time range
    $hours = switch ($h.CmbOpTimeRange.SelectedIndex) {
      0 { 1 }
      1 { 6 }
      2 { 24 }
      3 { 168 }
      default { 24 }
    }

    $endTime = Get-Date
    $startTime = $endTime.AddHours(-$hours)

    Start-AppJob -Name "Query Operational Events" -Type "Query" -ScriptBlock {
      param($startTime, $endTime)

      # Build query body for audit logs
      $queryBody = @{
        interval = "$($startTime.ToString('o'))/$($endTime.ToString('o'))"
        pageSize = 100
        pageNumber = 1
      }

      # Use Invoke-GcPagedRequest to query audit logs
      $maxItems = 500  # Limit to prevent excessive API calls
      try {
        $results = Invoke-GcPagedRequest -Path '/api/v2/audits/query' -Method POST -Body $queryBody `
          -InstanceName $script:AppState.Region -AccessToken $script:AppState.AccessToken -MaxItems $maxItems

        return $results
      } catch {
        Write-Error "Failed to query operational events: $_"
        return @()
      }
    } -ArgumentList @($startTime, $endTime) -OnCompleted ({
      param($job)

      Set-ControlEnabled -Control $h.BtnOpQuery -Enabled $true

      if ($job.Result) {
        $events = $job.Result
        $script:OpEventsData = $events

        # Transform to display format
        $displayData = $events | ForEach-Object {
          [PSCustomObject]@{
            Timestamp = if ($_.Timestamp) { $_.Timestamp } else { '' }
            Service = if ($_.ServiceName) { $_.ServiceName } elseif ($_.Entity.Type) { $_.Entity.Type } else { 'N/A' }
            Level = if ($_.Level) { $_.Level } else { 'Info' }
            Message = if ($_.Action) { $_.Action } else { 'N/A' }
            User = if ($_.User -and $_.User.Name) { $_.User.Name } else { 'System' }
          }
        }

        $h.GridOpEvents.ItemsSource = $displayData
        $h.TxtOpCount.Text = "($($events.Count) events)"
        Set-ControlEnabled -Control $h.BtnOpExportJson -Enabled $true
        Set-ControlEnabled -Control $h.BtnOpExportCsv -Enabled $true

        Set-Status "Loaded $($events.Count) operational events."
      } else {
        Set-Status "Failed to query operational events. Check job logs."
        $h.GridOpEvents.ItemsSource = @()
        $h.TxtOpCount.Text = "(0 events)"
      }
    }.GetNewClosure())
  }.GetNewClosure())

  # Search text changed handler
  $h.TxtOpSearch.Add_TextChanged({
    if (-not $script:OpEventsData -or $script:OpEventsData.Count -eq 0) { return }

    $searchText = $h.TxtOpSearch.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "search events...") {
      $displayData = $script:OpEventsData | ForEach-Object {
        [PSCustomObject]@{
          Timestamp = if ($_.Timestamp) { $_.Timestamp } else { '' }
          Service = if ($_.ServiceName) { $_.ServiceName } elseif ($_.Entity.Type) { $_.Entity.Type } else { 'N/A' }
          Level = if ($_.Level) { $_.Level } else { 'Info' }
          Message = if ($_.Action) { $_.Action } else { 'N/A' }
          User = if ($_.User -and $_.User.Name) { $_.User.Name } else { 'System' }
        }
      }
      $h.GridOpEvents.ItemsSource = $displayData
      $h.TxtOpCount.Text = "($($script:OpEventsData.Count) events)"
      return
    }

    $filtered = $script:OpEventsData | Where-Object {
      $json = ($_ | ConvertTo-Json -Compress -Depth 5).ToLower()
      $json -like "*$searchText*"
    }

    $displayData = $filtered | ForEach-Object {
      [PSCustomObject]@{
        Timestamp = if ($_.Timestamp) { $_.Timestamp } else { '' }
        Service = if ($_.ServiceName) { $_.ServiceName } elseif ($_.Entity.Type) { $_.Entity.Type } else { 'N/A' }
        Level = if ($_.Level) { $_.Level } else { 'Info' }
        Message = if ($_.Action) { $_.Action } else { 'N/A' }
        User = if ($_.User -and $_.User.Name) { $_.User.Name } else { 'System' }
      }
    }

    $h.GridOpEvents.ItemsSource = $displayData
    $h.TxtOpCount.Text = "($($filtered.Count) events)"
  }.GetNewClosure())

  # Export JSON handler
  $h.BtnOpExportJson.Add_Click({
    if (-not $script:OpEventsData -or $script:OpEventsData.Count -eq 0) {
      [System.Windows.MessageBox]::Show("No data to export.", "Export", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
      return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $filename = "operational_events_$timestamp.json"
    $filepath = Join-Path -Path $script:ArtifactsDir -ChildPath $filename

    try {
      $script:OpEventsData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      $script:AppState.Artifacts.Add((New-Artifact -Name $filename -Path $filepath))
      Set-Status "Exported to $filename"
      [System.Windows.MessageBox]::Show("Exported to:`n$filepath", "Export Successful", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch {
      Set-Status "Export failed: $_"
      [System.Windows.MessageBox]::Show("Export failed: $_", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
  }.GetNewClosure())

  # Export CSV handler
  $h.BtnOpExportCsv.Add_Click({
    if (-not $script:OpEventsData -or $script:OpEventsData.Count -eq 0) {
      [System.Windows.MessageBox]::Show("No data to export.", "Export", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
      return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $filename = "operational_events_$timestamp.csv"
    $filepath = Join-Path -Path $script:ArtifactsDir -ChildPath $filename

    try {
      $csvData = $script:OpEventsData | ForEach-Object {
        [PSCustomObject]@{
          Timestamp = if ($_.Timestamp) { $_.Timestamp } else { '' }
          Service = if ($_.ServiceName) { $_.ServiceName } elseif ($_.Entity.Type) { $_.Entity.Type } else { 'N/A' }
          Level = if ($_.Level) { $_.Level } else { 'Info' }
          Action = if ($_.Action) { $_.Action } else { 'N/A' }
          User = if ($_.User -and $_.User.Name) { $_.User.Name } else { 'System' }
          EntityType = if ($_.Entity -and $_.Entity.Type) { $_.Entity.Type } else { '' }
          EntityId = if ($_.Entity -and $_.Entity.Id) { $_.Entity.Id } else { '' }
        }
      }
      $csvData | Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      $script:AppState.Artifacts.Add((New-Artifact -Name $filename -Path $filepath))
      Set-Status "Exported to $filename"
      [System.Windows.MessageBox]::Show("Exported to:`n$filepath", "Export Successful", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch {
      Set-Status "Export failed: $_"
      [System.Windows.MessageBox]::Show("Export failed: $_", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
  }.GetNewClosure())

  return $view
}

function New-AuditLogsView {
  <#
  .SYNOPSIS
    Creates the Audit Logs module view with query, grid, and export capabilities.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Audit Logs" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
            <TextBlock Text="Time Range:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="CmbAuditTimeRange" Width="140" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="Last 1 hour"/>
              <ComboBoxItem Content="Last 6 hours"/>
              <ComboBoxItem Content="Last 24 hours"/>
              <ComboBoxItem Content="Last 7 days"/>
            </ComboBox>
            <TextBlock Text="Entity Type:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <ComboBox x:Name="CmbAuditEntity" Width="180" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="All Types"/>
              <ComboBoxItem Content="User"/>
              <ComboBoxItem Content="Queue"/>
              <ComboBoxItem Content="Flow"/>
              <ComboBoxItem Content="Integration"/>
            </ComboBox>
            <TextBlock Text="Action:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <ComboBox x:Name="CmbAuditAction" Width="120" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="All Actions"/>
              <ComboBoxItem Content="Create"/>
              <ComboBoxItem Content="Update"/>
              <ComboBoxItem Content="Delete"/>
            </ComboBox>
          </StackPanel>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnAuditQuery" Content="Query" Width="86" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnAuditExportJson" Content="Export JSON" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnAuditExportCsv" Content="Export CSV" Width="100" Height="32" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Audit Entries" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBox x:Name="TxtAuditSearch" Margin="12,0,0,0" Width="300" Height="26" Text="Search audits..."/>
          <TextBlock x:Name="TxtAuditCount" Text="(0 audits)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
        </StackPanel>

        <DataGrid x:Name="GridAuditLogs" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Timestamp" Binding="{Binding Timestamp}" Width="180"/>
            <DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="120"/>
            <DataGridTextColumn Header="Entity Type" Binding="{Binding EntityType}" Width="150"/>
            <DataGridTextColumn Header="Entity Name" Binding="{Binding EntityName}" Width="200"/>
            <DataGridTextColumn Header="User" Binding="{Binding User}" Width="180"/>
            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="100"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    CmbAuditTimeRange   = $view.FindName('CmbAuditTimeRange')
    CmbAuditEntity      = $view.FindName('CmbAuditEntity')
    CmbAuditAction      = $view.FindName('CmbAuditAction')
    BtnAuditQuery       = $view.FindName('BtnAuditQuery')
    BtnAuditExportJson  = $view.FindName('BtnAuditExportJson')
    BtnAuditExportCsv   = $view.FindName('BtnAuditExportCsv')
    TxtAuditSearch      = $view.FindName('TxtAuditSearch')
    TxtAuditCount       = $view.FindName('TxtAuditCount')
    GridAuditLogs       = $view.FindName('GridAuditLogs')
  }

  # Store audit data for export
  $script:AuditLogsData = @()

  # Query button handler
  $h.BtnAuditQuery.Add_Click({
    Set-Status "Querying audit logs..."
    Set-ControlEnabled -Control $h.BtnAuditQuery -Enabled $false
    Set-ControlEnabled -Control $h.BtnAuditExportJson -Enabled $false
    Set-ControlEnabled -Control $h.BtnAuditExportCsv -Enabled $false

    # Determine time range
    $hours = switch ($h.CmbAuditTimeRange.SelectedIndex) {
      0 { 1 }
      1 { 6 }
      2 { 24 }
      3 { 168 }
      default { 24 }
    }

    $endTime = Get-Date
    $startTime = $endTime.AddHours(-$hours)

    Start-AppJob -Name "Query Audit Logs" -Type "Query" -ScriptBlock {
      param($startTime, $endTime)

      # Build query body for audit logs
      $queryBody = @{
        interval = "$($startTime.ToString('o'))/$($endTime.ToString('o'))"
        pageSize = 100
        pageNumber = 1
      }

      # Use Invoke-GcPagedRequest to query audit logs
      $maxItems = 500  # Limit to prevent excessive API calls
      try {
        $results = Invoke-GcPagedRequest -Path '/api/v2/audits/query' -Method POST -Body $queryBody `
          -InstanceName $script:AppState.Region -AccessToken $script:AppState.AccessToken -MaxItems $maxItems

        return $results
      } catch {
        Write-Error "Failed to query audit logs: $_"
        return @()
      }
    } -ArgumentList @($startTime, $endTime) -OnCompleted ({
      param($job)

      Set-ControlEnabled -Control $h.BtnAuditQuery -Enabled $true

      if ($job.Result) {
        $audits = $job.Result
        $script:AuditLogsData = $audits

        # Transform to display format
        $displayData = $audits | ForEach-Object {
          [PSCustomObject]@{
            Timestamp = if ($_.Timestamp) { $_.Timestamp } else { '' }
            Action = if ($_.Action) { $_.Action } else { 'N/A' }
            EntityType = if ($_.Entity -and $_.Entity.Type) { $_.Entity.Type } else { 'N/A' }
            EntityName = if ($_.Entity -and $_.Entity.Name) { $_.Entity.Name } else { 'N/A' }
            User = if ($_.User -and $_.User.Name) { $_.User.Name } else { 'System' }
            Status = if ($_.Status) { $_.Status } else { 'Success' }
          }
        }

        $h.GridAuditLogs.ItemsSource = $displayData
        $h.TxtAuditCount.Text = "($($audits.Count) audits)"
        Set-ControlEnabled -Control $h.BtnAuditExportJson -Enabled $true
        Set-ControlEnabled -Control $h.BtnAuditExportCsv -Enabled $true

        Set-Status "Loaded $($audits.Count) audit entries."
      } else {
        Set-Status "Failed to query audit logs. Check job logs."
        $h.GridAuditLogs.ItemsSource = @()
        $h.TxtAuditCount.Text = "(0 audits)"
      }
    }.GetNewClosure())
  }.GetNewClosure())

  # Search text changed handler
  $h.TxtAuditSearch.Add_TextChanged({
    if (-not $script:AuditLogsData -or $script:AuditLogsData.Count -eq 0) { return }

    $searchText = $h.TxtAuditSearch.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "search audits...") {
      $displayData = $script:AuditLogsData | ForEach-Object {
        [PSCustomObject]@{
          Timestamp = if ($_.Timestamp) { $_.Timestamp } else { '' }
          Action = if ($_.Action) { $_.Action } else { 'N/A' }
          EntityType = if ($_.Entity -and $_.Entity.Type) { $_.Entity.Type } else { 'N/A' }
          EntityName = if ($_.Entity -and $_.Entity.Name) { $_.Entity.Name } else { 'N/A' }
          User = if ($_.User -and $_.User.Name) { $_.User.Name } else { 'System' }
          Status = if ($_.Status) { $_.Status } else { 'Success' }
        }
      }
      $h.GridAuditLogs.ItemsSource = $displayData
      $h.TxtAuditCount.Text = "($($script:AuditLogsData.Count) audits)"
      return
    }

    $filtered = $script:AuditLogsData | Where-Object {
      $json = ($_ | ConvertTo-Json -Compress -Depth 5).ToLower()
      $json -like "*$searchText*"
    }

    $displayData = $filtered | ForEach-Object {
      [PSCustomObject]@{
        Timestamp = if ($_.Timestamp) { $_.Timestamp } else { '' }
        Action = if ($_.Action) { $_.Action } else { 'N/A' }
        EntityType = if ($_.Entity -and $_.Entity.Type) { $_.Entity.Type } else { 'N/A' }
        EntityName = if ($_.Entity -and $_.Entity.Name) { $_.Entity.Name } else { 'N/A' }
        User = if ($_.User -and $_.User.Name) { $_.User.Name } else { 'System' }
        Status = if ($_.Status) { $_.Status } else { 'Success' }
      }
    }

    $h.GridAuditLogs.ItemsSource = $displayData
    $h.TxtAuditCount.Text = "($($filtered.Count) audits)"
  }.GetNewClosure())

  # Export JSON handler
  $h.BtnAuditExportJson.Add_Click({
    if (-not $script:AuditLogsData -or $script:AuditLogsData.Count -eq 0) {
      [System.Windows.MessageBox]::Show("No data to export.", "Export", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
      return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $filename = "audit_logs_$timestamp.json"
    $filepath = Join-Path -Path $script:ArtifactsDir -ChildPath $filename

    try {
      $script:AuditLogsData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      $script:AppState.Artifacts.Add((New-Artifact -Name $filename -Path $filepath))
      Set-Status "Exported to $filename"
      [System.Windows.MessageBox]::Show("Exported to:`n$filepath", "Export Successful", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch {
      Set-Status "Export failed: $_"
      [System.Windows.MessageBox]::Show("Export failed: $_", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
  }.GetNewClosure())

  # Export CSV handler
  $h.BtnAuditExportCsv.Add_Click({
    if (-not $script:AuditLogsData -or $script:AuditLogsData.Count -eq 0) {
      [System.Windows.MessageBox]::Show("No data to export.", "Export", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
      return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $filename = "audit_logs_$timestamp.csv"
    $filepath = Join-Path -Path $script:ArtifactsDir -ChildPath $filename

    try {
      $csvData = $script:AuditLogsData | ForEach-Object {
        [PSCustomObject]@{
          Timestamp = if ($_.Timestamp) { $_.Timestamp } else { '' }
          Action = if ($_.Action) { $_.Action } else { 'N/A' }
          EntityType = if ($_.Entity -and $_.Entity.Type) { $_.Entity.Type } else { 'N/A' }
          EntityName = if ($_.Entity -and $_.Entity.Name) { $_.Entity.Name } else { 'N/A' }
          EntityId = if ($_.Entity -and $_.Entity.Id) { $_.Entity.Id } else { '' }
          User = if ($_.User -and $_.User.Name) { $_.User.Name } else { 'System' }
          UserId = if ($_.User -and $_.User.Id) { $_.User.Id } else { '' }
          Status = if ($_.Status) { $_.Status } else { 'Success' }
        }
      }
      $csvData | Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      $script:AppState.Artifacts.Add((New-Artifact -Name $filename -Path $filepath))
      Set-Status "Exported to $filename"
      [System.Windows.MessageBox]::Show("Exported to:`n$filepath", "Export Successful", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch {
      Set-Status "Export failed: $_"
      [System.Windows.MessageBox]::Show("Export failed: $_", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
  }.GetNewClosure())

  return $view
}

function New-OAuthTokenUsageView {
  <#
  .SYNOPSIS
    Creates the OAuth / Token Usage module view with query, grid, and export capabilities.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="OAuth Clients &amp; Token Usage" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
            <TextBlock Text="View:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="CmbTokenView" Width="180" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="OAuth Clients"/>
              <ComboBoxItem Content="Active Tokens"/>
            </ComboBox>
            <TextBlock Text="Filter:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <ComboBox x:Name="CmbTokenFilter" Width="160" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="All"/>
              <ComboBoxItem Content="Active Only"/>
              <ComboBoxItem Content="Disabled Only"/>
            </ComboBox>
          </StackPanel>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnTokenQuery" Content="Query" Width="86" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnTokenExportJson" Content="Export JSON" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnTokenExportCsv" Content="Export CSV" Width="100" Height="32" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="OAuth Clients" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBox x:Name="TxtTokenSearch" Margin="12,0,0,0" Width="300" Height="26" Text="Search clients..."/>
          <TextBlock x:Name="TxtTokenCount" Text="(0 clients)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
        </StackPanel>

        <DataGrid x:Name="GridTokenUsage" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="250"/>
            <DataGridTextColumn Header="Client ID" Binding="{Binding ClientId}" Width="280"/>
            <DataGridTextColumn Header="Grant Type" Binding="{Binding GrantType}" Width="180"/>
            <DataGridTextColumn Header="State" Binding="{Binding State}" Width="100"/>
            <DataGridTextColumn Header="Created" Binding="{Binding Created}" Width="180"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    CmbTokenView        = $view.FindName('CmbTokenView')
    CmbTokenFilter      = $view.FindName('CmbTokenFilter')
    BtnTokenQuery       = $view.FindName('BtnTokenQuery')
    BtnTokenExportJson  = $view.FindName('BtnTokenExportJson')
    BtnTokenExportCsv   = $view.FindName('BtnTokenExportCsv')
    TxtTokenSearch      = $view.FindName('TxtTokenSearch')
    TxtTokenCount       = $view.FindName('TxtTokenCount')
    GridTokenUsage      = $view.FindName('GridTokenUsage')
  }

  # Store token data for export
  $script:TokenUsageData = @()

  # Query button handler
  $h.BtnTokenQuery.Add_Click({
    Set-Status "Querying OAuth clients..."
    Set-ControlEnabled -Control $h.BtnTokenQuery -Enabled $false
    Set-ControlEnabled -Control $h.BtnTokenExportJson -Enabled $false
    Set-ControlEnabled -Control $h.BtnTokenExportCsv -Enabled $false

    Start-AppJob -Name "Query OAuth Clients" -Type "Query" -ScriptBlock {
      # Use Invoke-GcPagedRequest to query OAuth clients
      $maxItems = 500  # Limit to prevent excessive API calls
      try {
        $results = Invoke-GcPagedRequest -Path '/api/v2/oauth/clients' -Method GET `
          -InstanceName $script:AppState.Region -AccessToken $script:AppState.AccessToken -MaxItems $maxItems

        return $results
      } catch {
        Write-Error "Failed to query OAuth clients: $_"
        return @()
      }
    } -OnCompleted ({
      param($job)

      Set-ControlEnabled -Control $h.BtnTokenQuery -Enabled $true

      if ($job.Result) {
        $clients = $job.Result
        $script:TokenUsageData = $clients

        # Transform to display format
        $displayData = $clients | ForEach-Object {
          [PSCustomObject]@{
            Name = if ($_.Name) { $_.Name } else { 'N/A' }
            ClientId = if ($_.Id) { $_.Id } else { 'N/A' }
            GrantType = if ($_.AuthorizedGrantType) { $_.AuthorizedGrantType } else { 'N/A' }
            State = if ($_.State) { $_.State } else { 'Active' }
            Created = if ($_.DateCreated) { $_.DateCreated } else { '' }
          }
        }

        $h.GridTokenUsage.ItemsSource = $displayData
        $h.TxtTokenCount.Text = "($($clients.Count) clients)"
        Set-ControlEnabled -Control $h.BtnTokenExportJson -Enabled $true
        Set-ControlEnabled -Control $h.BtnTokenExportCsv -Enabled $true

        Set-Status "Loaded $($clients.Count) OAuth clients."
      } else {
        Set-Status "Failed to query OAuth clients. Check job logs."
        $h.GridTokenUsage.ItemsSource = @()
        $h.TxtTokenCount.Text = "(0 clients)"
      }
    }.GetNewClosure())
  }.GetNewClosure())

  # Search text changed handler
  $h.TxtTokenSearch.Add_TextChanged({
    if (-not $script:TokenUsageData -or $script:TokenUsageData.Count -eq 0) { return }

    $searchText = $h.TxtTokenSearch.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "search clients...") {
      $displayData = $script:TokenUsageData | ForEach-Object {
        [PSCustomObject]@{
          Name = if ($_.Name) { $_.Name } else { 'N/A' }
          ClientId = if ($_.Id) { $_.Id } else { 'N/A' }
          GrantType = if ($_.AuthorizedGrantType) { $_.AuthorizedGrantType } else { 'N/A' }
          State = if ($_.State) { $_.State } else { 'Active' }
          Created = if ($_.DateCreated) { $_.DateCreated } else { '' }
        }
      }
      $h.GridTokenUsage.ItemsSource = $displayData
      $h.TxtTokenCount.Text = "($($script:TokenUsageData.Count) clients)"
      return
    }

    $filtered = $script:TokenUsageData | Where-Object {
      $json = ($_ | ConvertTo-Json -Compress -Depth 5).ToLower()
      $json -like "*$searchText*"
    }

    $displayData = $filtered | ForEach-Object {
      [PSCustomObject]@{
        Name = if ($_.Name) { $_.Name } else { 'N/A' }
        ClientId = if ($_.Id) { $_.Id } else { 'N/A' }
        GrantType = if ($_.AuthorizedGrantType) { $_.AuthorizedGrantType } else { 'N/A' }
        State = if ($_.State) { $_.State } else { 'Active' }
        Created = if ($_.DateCreated) { $_.DateCreated } else { '' }
      }
    }

    $h.GridTokenUsage.ItemsSource = $displayData
    $h.TxtTokenCount.Text = "($($filtered.Count) clients)"
  }.GetNewClosure())

  # Export JSON handler
  $h.BtnTokenExportJson.Add_Click({
    if (-not $script:TokenUsageData -or $script:TokenUsageData.Count -eq 0) {
      [System.Windows.MessageBox]::Show("No data to export.", "Export", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
      return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $filename = "oauth_clients_$timestamp.json"
    $filepath = Join-Path -Path $script:ArtifactsDir -ChildPath $filename

    try {
      $script:TokenUsageData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      $script:AppState.Artifacts.Add((New-Artifact -Name $filename -Path $filepath))
      Set-Status "Exported to $filename"
      [System.Windows.MessageBox]::Show("Exported to:`n$filepath", "Export Successful", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch {
      Set-Status "Export failed: $_"
      [System.Windows.MessageBox]::Show("Export failed: $_", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
  }.GetNewClosure())

  # Export CSV handler
  $h.BtnTokenExportCsv.Add_Click({
    if (-not $script:TokenUsageData -or $script:TokenUsageData.Count -eq 0) {
      [System.Windows.MessageBox]::Show("No data to export.", "Export", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
      return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $filename = "oauth_clients_$timestamp.csv"
    $filepath = Join-Path -Path $script:ArtifactsDir -ChildPath $filename

    try {
      $csvData = $script:TokenUsageData | ForEach-Object {
        [PSCustomObject]@{
          Name = if ($_.Name) { $_.Name } else { 'N/A' }
          ClientId = if ($_.Id) { $_.Id } else { 'N/A' }
          GrantType = if ($_.AuthorizedGrantType) { $_.AuthorizedGrantType } else { 'N/A' }
          State = if ($_.State) { $_.State } else { 'Active' }
          Created = if ($_.DateCreated) { $_.DateCreated } else { '' }
          Description = if ($_.Description) { $_.Description } else { '' }
        }
      }
      $csvData | Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      $script:AppState.Artifacts.Add((New-Artifact -Name $filename -Path $filepath))
      Set-Status "Exported to $filename"
      [System.Windows.MessageBox]::Show("Exported to:`n$filepath", "Export Successful", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch {
      Set-Status "Export failed: $_"
      [System.Windows.MessageBox]::Show("Export failed: $_", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
  }.GetNewClosure())

  return $view
}

function New-ConversationLookupView {
  <#
  .SYNOPSIS
    Creates the Conversation Lookup module view with search, filter, and export capabilities.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <StackPanel>
            <TextBlock Text="Conversation Lookup" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
            <TextBlock Text="Search conversations by date range, queue, participants, and more" Margin="0,4,0,0" Foreground="#FF6B7280"/>
          </StackPanel>

          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnConvSearch" Content="Search" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
            <Button x:Name="BtnConvExportJson" Content="Export JSON" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
            <Button x:Name="BtnConvExportCsv" Content="Export CSV" Width="100" Height="32" IsEnabled="False"/>
          </StackPanel>
        </Grid>

        <StackPanel Grid.Row="1" Margin="0,12,0,0">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="200"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="200"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="150"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <TextBlock Grid.Column="0" Text="Date Range:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="CmbDateRange" Grid.Column="1" Height="26" SelectedIndex="2">
              <ComboBoxItem Content="Last 1 hour"/>
              <ComboBoxItem Content="Last 6 hours"/>
              <ComboBoxItem Content="Last 24 hours"/>
              <ComboBoxItem Content="Last 7 days"/>
              <ComboBoxItem Content="Custom"/>
            </ComboBox>

            <TextBlock Grid.Column="2" Text="Conversation ID:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <TextBox x:Name="TxtConvIdFilter" Grid.Column="3" Height="26"/>

            <TextBlock Grid.Column="4" Text="Max Results:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <TextBox x:Name="TxtMaxResults" Grid.Column="5" Height="26" Text="500"/>
          </Grid>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Conversations" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBox x:Name="TxtConvSearchFilter" Margin="12,0,0,0" Width="300" Height="26" Text="Filter results..."/>
          <TextBlock x:Name="TxtConvCount" Text="(0 conversations)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
          <Button x:Name="BtnOpenTimeline" Content="Open Timeline" Width="120" Height="26" Margin="12,0,0,0" IsEnabled="False"/>
        </StackPanel>

        <DataGrid x:Name="GridConversations" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Conversation ID" Binding="{Binding ConversationId}" Width="280"/>
            <DataGridTextColumn Header="Start Time" Binding="{Binding StartTime}" Width="160"/>
            <DataGridTextColumn Header="Duration" Binding="{Binding Duration}" Width="100"/>
            <DataGridTextColumn Header="Participants" Binding="{Binding Participants}" Width="150"/>
            <DataGridTextColumn Header="Media" Binding="{Binding Media}" Width="100"/>
            <DataGridTextColumn Header="Direction" Binding="{Binding Direction}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    BtnConvSearch       = $view.FindName('BtnConvSearch')
    BtnConvExportJson   = $view.FindName('BtnConvExportJson')
    BtnConvExportCsv    = $view.FindName('BtnConvExportCsv')
    CmbDateRange        = $view.FindName('CmbDateRange')
    TxtConvIdFilter     = $view.FindName('TxtConvIdFilter')
    TxtMaxResults       = $view.FindName('TxtMaxResults')
    TxtConvSearchFilter = $view.FindName('TxtConvSearchFilter')
    TxtConvCount        = $view.FindName('TxtConvCount')
    BtnOpenTimeline     = $view.FindName('BtnOpenTimeline')
    GridConversations   = $view.FindName('GridConversations')
  }

  Enable-PrimaryActionButtons -Handles $h


  # Capture control references for event handlers (avoid dynamic scoping surprises)
  $btnConvSearch       = $h.BtnConvSearch
  $btnConvExportJson   = $h.BtnConvExportJson
  $btnConvExportCsv    = $h.BtnConvExportCsv
  $btnConvOpenTimeline = $h.BtnOpenTimeline
  $cmbDateRange        = $h.CmbDateRange
  $txtConvIdFilter     = $h.TxtConvIdFilter
  $txtMaxResults       = $h.TxtMaxResults
  $txtConvSearchFilter = $h.TxtConvSearchFilter
  $txtConvCount        = $h.TxtConvCount
  $gridConversations   = $h.GridConversations

  $script:ConversationsData = @()

  if ($btnConvSearch) { $btnConvSearch.Add_Click({
    Set-Status "Searching conversations..."

    # Build date range
    $endTime = Get-Date
    $startTime = switch ($cmbDateRange.SelectedIndex) {
      0 { $endTime.AddHours(-1) }
      1 { $endTime.AddHours(-6) }
      2 { $endTime.AddHours(-24) }
      3 { $endTime.AddDays(-7) }
      default { $endTime.AddHours(-24) }
    }

    $interval = "$($startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))/$($endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"

    # Get max results
    $maxResults = 500
    if (-not [string]::IsNullOrWhiteSpace($txtMaxResults.Text)) {
      if ([int]::TryParse($txtMaxResults.Text, [ref]$maxResults)) {
        # Valid number
      } else {
        $maxResults = 500
      }
    }

    # Build query body
    $queryBody = @{
      interval = $interval
      order = "desc"
      orderBy = "conversationStart"
      paging = @{
        pageSize = 100
        pageNumber = 1
      }
    }

    # Add conversation ID filter if provided
    if (-not [string]::IsNullOrWhiteSpace($txtConvIdFilter.Text)) {
      $queryBody.conversationFilters = @(
        @{
          type = "and"
          predicates = @(
            @{
              dimension = "conversationId"
              value = $txtConvIdFilter.Text
            }
          )
        }
      )
    }

    Start-AppJob -Name "Search Conversations" -Type "Query" -ScriptBlock {
      param($queryBody, $accessToken, $instanceName, $maxItems)

      Search-GcConversations -Body $queryBody -AccessToken $accessToken -InstanceName $instanceName -MaxItems $maxItems
    } -ArgumentList @($queryBody, $script:AppState.AccessToken, $script:AppState.Region, $maxResults) -OnCompleted ({
      param($job)

      if ($job.Result) {
        $script:ConversationsData = $job.Result
        $displayData = $job.Result | ForEach-Object {
          $startTime = if ($_.conversationStart) {
            try { [DateTime]::Parse($_.conversationStart).ToString('yyyy-MM-dd HH:mm:ss') }
            catch { $_.conversationStart }
          } else { 'N/A' }

          $duration = if ($_.conversationEnd -and $_.conversationStart) {
            try {
              $start = [DateTime]::Parse($_.conversationStart)
              $end = [DateTime]::Parse($_.conversationEnd)
              $span = $end - $start
              "$([int]$span.TotalSeconds)s"
            } catch { 'N/A' }
          } else { 'N/A' }

          $participants = if ($_.participants) { $_.participants.Count } else { 0 }

          $mediaTypes = if ($_.participants) {
            ($_.participants | ForEach-Object {
              if ($_.sessions) {
                $_.sessions | ForEach-Object {
                  if ($_.mediaType) { $_.mediaType }
                }
              }
            } | Select-Object -Unique) -join ', '
          } else { 'N/A' }

          $direction = if ($_.participants) {
            $dirs = $_.participants | ForEach-Object {
              if ($_.sessions) {
                $_.sessions | ForEach-Object {
                  if ($_.direction) { $_.direction }
                }
              }
            } | Select-Object -Unique
            $dirs -join ', '
          } else { 'N/A' }

          [PSCustomObject]@{
            ConversationId = if ($_.conversationId) { $_.conversationId } else { 'N/A' }
            StartTime = $startTime
            Duration = $duration
            Participants = $participants
            Media = $mediaTypes
            Direction = $direction
            RawData = $_
          }
        }
        if ($gridConversations) { $gridConversations.ItemsSource = $displayData }
        if ($txtConvCount) { $txtConvCount.Text = "($($job.Result.Count) conversations)" }
        Set-Status "Found $($job.Result.Count) conversations."
      } else {
        if ($gridConversations) { $gridConversations.ItemsSource = @() }
        if ($txtConvCount) { $txtConvCount.Text = "(0 conversations)" }
        Set-Status "Search failed or returned no results."
      }
    }.GetNewClosure())
  }.GetNewClosure()) }

  if ($btnConvExportJson) { $btnConvExportJson.Add_Click({
    if (-not $script:ConversationsData -or $script:ConversationsData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "conversations_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:ConversationsData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($script:ConversationsData.Count) conversations to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  }.GetNewClosure()) }

  if ($btnConvExportCsv) { $btnConvExportCsv.Add_Click({
    if (-not $script:ConversationsData -or $script:ConversationsData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "conversations_$timestamp.csv"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $gridConversations.ItemsSource | Select-Object ConversationId, StartTime, Duration, Participants, Media, Direction |
        Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      Set-Status "Exported $($script:ConversationsData.Count) conversations to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  }.GetNewClosure()) }

  if ($btnConvOpenTimeline) { $btnConvOpenTimeline.Add_Click({
    $selected = $gridConversations.SelectedItem
    if (-not $selected) {
      Set-Status "Please select a conversation to view timeline."
      return
    }

    $convId = $selected.ConversationId
    if ([string]::IsNullOrWhiteSpace($convId) -or $convId -eq 'N/A') {
      Set-Status "Invalid conversation ID."
      return
    }

    # Set the conversation ID for timeline view to pick up
    $script:AppState.FocusConversationId = $convId

    # Navigate to Conversation Timeline
    Show-WorkspaceAndModule -Workspace "Conversations" -Module "Conversation Timeline"
  }.GetNewClosure()) }

  if ($txtConvSearchFilter) { $txtConvSearchFilter.Add_TextChanged({
    if (-not $script:ConversationsData -or $script:ConversationsData.Count -eq 0) { return }

    $searchText = $txtConvSearchFilter.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "filter results...") {
      $gridConversations.ItemsSource = $script:ConversationsData | ForEach-Object {
        $startTime = if ($_.conversationStart) {
          try { [DateTime]::Parse($_.conversationStart).ToString('yyyy-MM-dd HH:mm:ss') }
          catch { $_.conversationStart }
        } else { 'N/A' }

        $duration = if ($_.conversationEnd -and $_.conversationStart) {
          try {
            $start = [DateTime]::Parse($_.conversationStart)
            $end = [DateTime]::Parse($_.conversationEnd)
            $span = $end - $start
            "$([int]$span.TotalSeconds)s"
          } catch { 'N/A' }
        } else { 'N/A' }

        $participants = if ($_.participants) { $_.participants.Count } else { 0 }

        $mediaTypes = if ($_.participants) {
          ($_.participants | ForEach-Object {
            if ($_.sessions) {
              $_.sessions | ForEach-Object {
                if ($_.mediaType) { $_.mediaType }
              }
            }
          } | Select-Object -Unique) -join ', '
        } else { 'N/A' }

        $direction = if ($_.participants) {
          $dirs = $_.participants | ForEach-Object {
            if ($_.sessions) {
              $_.sessions | ForEach-Object {
                if ($_.direction) { $_.direction }
              }
            }
          } | Select-Object -Unique
          $dirs -join ', '
        } else { 'N/A' }

        [PSCustomObject]@{
          ConversationId = if ($_.conversationId) { $_.conversationId } else { 'N/A' }
          StartTime = $startTime
          Duration = $duration
          Participants = $participants
          Media = $mediaTypes
          Direction = $direction
          RawData = $_
        }
      }
      $txtConvCount.Text = "($($script:ConversationsData.Count) conversations)"
      return
    }

    $filtered = $script:ConversationsData | Where-Object {
      $json = ($_ | ConvertTo-Json -Compress -Depth 5).ToLower()
      $json -like "*$searchText*"
    }

    $displayData = $filtered | ForEach-Object {
      $startTime = if ($_.conversationStart) {
        try { [DateTime]::Parse($_.conversationStart).ToString('yyyy-MM-dd HH:mm:ss') }
        catch { $_.conversationStart }
      } else { 'N/A' }

      $duration = if ($_.conversationEnd -and $_.conversationStart) {
        try {
          $start = [DateTime]::Parse($_.conversationStart)
          $end = [DateTime]::Parse($_.conversationEnd)
          $span = $end - $start
          "$([int]$span.TotalSeconds)s"
        } catch { 'N/A' }
      } else { 'N/A' }

      $participants = if ($_.participants) { $_.participants.Count } else { 0 }

      $mediaTypes = if ($_.participants) {
        ($_.participants | ForEach-Object {
          if ($_.sessions) {
            $_.sessions | ForEach-Object {
              if ($_.mediaType) { $_.mediaType }
            }
          }
        } | Select-Object -Unique) -join ', '
      } else { 'N/A' }

      $direction = if ($_.participants) {
        $dirs = $_.participants | ForEach-Object {
          if ($_.sessions) {
            $_.sessions | ForEach-Object {
              if ($_.direction) { $_.direction }
            }
          }
        } | Select-Object -Unique
        $dirs -join ', '
      } else { 'N/A' }

      [PSCustomObject]@{
        ConversationId = if ($_.conversationId) { $_.conversationId } else { 'N/A' }
        StartTime = $startTime
        Duration = $duration
        Participants = $participants
        Media = $mediaTypes
        Direction = $direction
        RawData = $_
      }
    }

    $gridConversations.ItemsSource = $displayData
    $txtConvCount.Text = "($($filtered.Count) conversations)"
  }.GetNewClosure()) }

  $h.TxtConvSearchFilter.Add_GotFocus({
    if ($h.TxtConvSearchFilter.Text -eq "Filter results...") {
      $h.TxtConvSearchFilter.Text = ""
    }
  }.GetNewClosure())

  $h.TxtConvSearchFilter.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtConvSearchFilter.Text)) {
      $h.TxtConvSearchFilter.Text = "Filter results..."
    }
  }.GetNewClosure())

  return $view
}

function New-ConversationTimelineView {
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="Conversation ID:" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBox x:Name="TxtConvId" Width="260" Height="28"/>
        <TextBlock Text="Time Range:" VerticalAlignment="Center" Margin="14,0,8,0"/>
        <ComboBox Width="160" Height="28" SelectedIndex="0">
          <ComboBoxItem Content="Last 60 minutes"/>
          <ComboBoxItem Content="Last 24 hours"/>
          <ComboBoxItem Content="Yesterday"/>
        </ComboBox>
        <Button x:Name="BtnBuild" Content="Build Timeline" Width="120" Height="28" Margin="12,0,0,0" IsEnabled="False"/>
        <Button x:Name="BtnExport" Content="Export Packet" Width="110" Height="28" Margin="10,0,0,0" IsEnabled="False"/>
      </StackPanel>
    </Border>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="420"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12" Margin="0,0,12,0">
        <StackPanel>
          <TextBlock Text="Timeline" FontWeight="SemiBold" Foreground="#FF111827"/>
          <ListBox x:Name="LstTimeline" Margin="0,10,0,0"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
        <StackPanel>
          <TextBlock Text="Detail" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBox x:Name="TxtDetail" Margin="0,10,0,0" AcceptsReturn="True" Height="520"
                   VerticalScrollBarVisibility="Auto" FontFamily="Consolas" TextWrapping="NoWrap"
                   Text="{} { &quot;hint&quot;: &quot;Select an event to view raw payload, correlation IDs, and media stats.&quot; }"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $txtConv  = $view.FindName('TxtConvId')
  $btnBuild = $view.FindName('BtnBuild')
  $btnExport= $view.FindName('BtnExport')
  $lst      = $view.FindName('LstTimeline')
  $detail   = $view.FindName('TxtDetail')

  if ($script:AppState.FocusConversationId) {
    if ($txtConv) { $txtConv.Text = $script:AppState.FocusConversationId }
  }

  $btnBuild.Add_Click({
    if (-not $txtConv) {
      Set-Status "Conversation ID input is not available in this view."
      return
    }

    $conv = ([string]$txtConv.Text).Trim()

    # Validate conversation ID
    if (-not $conv) {
      [System.Windows.MessageBox]::Show(
        "Please enter a conversation ID.",
        "No Conversation ID",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )
      return
    }

    # Check if authenticated
    if (-not $script:AppState.AccessToken) {
      [System.Windows.MessageBox]::Show(
        "Please log in first to retrieve conversation details.",
        "Authentication Required",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )
      return
    }

    Set-Status "Retrieving timeline for conversation $conv..."

    # Start background job to retrieve and build timeline (using shared scriptblock)
    Start-AppJob -Name "Build Timeline — $conv" -Type 'Timeline' -ScriptBlock $script:TimelineJobScriptBlock -ArgumentList @($conv, $script:AppState.Region, $script:AppState.AccessToken, $script:AppState.EventBuffer) `
    -OnCompleted {
      param($job)

      if ($job.Result -and $job.Result.Timeline) {
        $result = $job.Result
        Set-Status "Timeline ready for conversation $($result.ConversationId) with $($result.Timeline.Count) events."

        # Show timeline window
        Show-TimelineWindow `
          -ConversationId $result.ConversationId `
          -TimelineEvents $result.Timeline `
          -SubscriptionEvents $result.SubscriptionEvents `
          -ConversationData $result.ConversationData
      } else {
        Set-Status "Failed to build timeline. See job logs for details."
        [System.Windows.MessageBox]::Show(
          "Failed to retrieve conversation timeline. Check job logs for details.",
          "Timeline Error",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Error
        )
      }
    }

    Refresh-HeaderStats
  }.GetNewClosure())

  $lst.Add_SelectionChanged({
    if ($lst.SelectedItem) {
      $sel = [string]$lst.SelectedItem
      $detail.Text = "{`r`n  `"event`": `"$sel`",`r`n  `"note`": `"Mock payload would include segments, media stats, participant/session IDs.`"`r`n}"
    }
  }.GetNewClosure())

  $btnExport.Add_Click({
    $conv = if ($txtConv) { ([string]$txtConv.Text).Trim() } else { '' }
    if (-not $conv) { $conv = "c-unknown" }

    if (-not $script:AppState.AccessToken) {
      [System.Windows.MessageBox]::Show(
        "Please log in first to export real conversation data.",
        "Authentication Required",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )

      # Fallback to mock export using Start-AppJob
      Start-AppJob -Name "Export Incident Packet (Mock) — $conv" -Type 'Export' -ScriptBlock {
        param($conversationId, $artifactsDir)

        Start-Sleep -Milliseconds 1400

        $file = Join-Path -Path $artifactsDir -ChildPath "incident-packet-mock-$($conversationId)-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
        @(
          "Incident Packet (mock)",
          "ConversationId: $conversationId",
          "Generated: $(Get-Date)",
          "",
          "NOTE: This is a mock packet. Log in to export real conversation data."
        ) | Set-Content -Path $file -Encoding UTF8

        return $file
      } -ArgumentList @($conv, $script:ArtifactsDir) -OnCompleted {
        param($job)

        if ($job.Result) {
          $file = $job.Result
          Add-ArtifactAndNotify -Name "Incident Packet (Mock) — $conv" -Path $file -ToastTitle 'Export complete (mock)'
          Set-Status "Exported mock incident packet: $file"
        }
      } | Out-Null

      Refresh-HeaderStats
      return
    }

    # Real export using ArtifactGenerator with Start-AppJob
    Start-AppJob -Name "Export Incident Packet — $conv" -Type 'Export' -ScriptBlock {
      param($conversationId, $region, $accessToken, $artifactsDir, $eventBuffer)

      try {
        # Export packet
        $packet = Export-GcConversationPacket `
          -ConversationId $conversationId `
          -Region $region `
          -AccessToken $accessToken `
          -OutputDirectory $artifactsDir `
          -SubscriptionEvents $eventBuffer `
          -CreateZip

        return $packet
      } catch {
        Write-Error "Failed to export packet: $_"
        return $null
      }
    } -ArgumentList @($conv, $script:AppState.Region, $script:AppState.AccessToken, $script:ArtifactsDir, $script:AppState.EventBuffer) `
    -OnCompleted {
      param($job)

      if ($job.Result) {
        $packet = $job.Result
        $artifactPath = if ($packet.ZipPath) { $packet.ZipPath } else { $packet.PacketDirectory }
        $artifactName = "Incident Packet — $($packet.ConversationId)"

        Add-ArtifactAndNotify -Name $artifactName -Path $artifactPath -ToastTitle 'Export complete'
        Set-Status "Exported incident packet: $artifactPath"
      } else {
        Set-Status "Failed to export packet. See job logs for details."
      }
    }

    Refresh-HeaderStats
  }.GetNewClosure())

  return $view
}

function New-AnalyticsJobsView {
  <#
  .SYNOPSIS
    Creates the Analytics Jobs module view for managing long-running analytics queries.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <StackPanel>
            <TextBlock Text="Analytics Jobs" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
            <TextBlock Text="Submit and monitor long-running analytics queries" Margin="0,4,0,0" Foreground="#FF6B7280"/>
          </StackPanel>

          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnSubmitJob" Content="Submit Job" Width="110" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
            <Button x:Name="BtnRefresh" Content="Refresh" Width="100" Height="32" Margin="8,0,0,0" IsEnabled="False"/>
          </StackPanel>
        </Grid>

        <StackPanel Grid.Row="1" Margin="0,12,0,0">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="200"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="150"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <TextBlock Grid.Column="0" Text="Date Range:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="CmbJobDateRange" Grid.Column="1" Height="26" SelectedIndex="2">
              <ComboBoxItem Content="Last 1 hour"/>
              <ComboBoxItem Content="Last 6 hours"/>
              <ComboBoxItem Content="Last 24 hours"/>
              <ComboBoxItem Content="Last 7 days"/>
            </ComboBox>

            <TextBlock Grid.Column="2" Text="Max Results:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <TextBox x:Name="TxtJobMaxResults" Grid.Column="3" Height="26" Text="1000"/>
          </Grid>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Analytics Jobs" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock x:Name="TxtJobCount" Text="(0 jobs)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
          <Button x:Name="BtnViewResults" Content="View Results" Width="110" Height="26" Margin="12,0,0,0" IsEnabled="False"/>
          <Button x:Name="BtnExportResults" Content="Export Results" Width="110" Height="26" Margin="8,0,0,0" IsEnabled="False"/>
        </StackPanel>

        <DataGrid x:Name="GridJobs" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Job ID" Binding="{Binding JobId}" Width="280"/>
            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="120"/>
            <DataGridTextColumn Header="Submitted" Binding="{Binding SubmittedTime}" Width="160"/>
            <DataGridTextColumn Header="Completed" Binding="{Binding CompletedTime}" Width="160"/>
            <DataGridTextColumn Header="Results" Binding="{Binding ResultCount}" Width="100"/>
            <DataGridTextColumn Header="Duration" Binding="{Binding Duration}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    BtnSubmitJob      = $view.FindName('BtnSubmitJob')
    BtnRefresh        = $view.FindName('BtnRefresh')
    CmbJobDateRange   = $view.FindName('CmbJobDateRange')
    TxtJobMaxResults  = $view.FindName('TxtJobMaxResults')
    TxtJobCount       = $view.FindName('TxtJobCount')
    BtnViewResults    = $view.FindName('BtnViewResults')
    BtnExportResults  = $view.FindName('BtnExportResults')
    GridJobs          = $view.FindName('GridJobs')
  }

  # Track submitted jobs
  if (-not (Get-Variable -Name AnalyticsJobs -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AnalyticsJobs = @()
  }

  function Refresh-JobsList {
    if ($script:AnalyticsJobs.Count -eq 0) {
      $h.GridJobs.ItemsSource = @()
      $h.TxtJobCount.Text = "(0 jobs)"
      return
    }

    $displayData = $script:AnalyticsJobs | ForEach-Object {
      $duration = if ($_.CompletedTime -and $_.SubmittedTime) {
        try {
          $start = [DateTime]$_.SubmittedTime
          $end = [DateTime]$_.CompletedTime
          $span = $end - $start
          "$([int]$span.TotalSeconds)s"
        } catch { 'N/A' }
      } else { 'In Progress' }

      [PSCustomObject]@{
        JobId = $_.JobId
        Status = $_.Status
        SubmittedTime = if ($_.SubmittedTime) { $_.SubmittedTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
        CompletedTime = if ($_.CompletedTime) { $_.CompletedTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        ResultCount = if ($_.Results) { $_.Results.Count } else { 0 }
        Duration = $duration
        JobData = $_
      }
    }

    $h.GridJobs.ItemsSource = $displayData
    $h.TxtJobCount.Text = "($($script:AnalyticsJobs.Count) jobs)"
  }

  $h.BtnSubmitJob.Add_Click({
    Set-Status "Submitting analytics job..."
    Set-ControlEnabled -Control $h.BtnSubmitJob -Enabled $false

    # Build date range
    $endTime = Get-Date
    $startTime = switch ($h.CmbJobDateRange.SelectedIndex) {
      0 { $endTime.AddHours(-1) }
      1 { $endTime.AddHours(-6) }
      2 { $endTime.AddHours(-24) }
      3 { $endTime.AddDays(-7) }
      default { $endTime.AddHours(-24) }
    }

    $interval = "$($startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))/$($endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"

    # Get max results
    $maxResults = 1000
    if (-not [string]::IsNullOrWhiteSpace($h.TxtJobMaxResults.Text)) {
      if ([int]::TryParse($h.TxtJobMaxResults.Text, [ref]$maxResults)) {
        # Valid number
      } else {
        $maxResults = 1000
      }
    }

    # Build query body
    $queryBody = @{
      interval = $interval
      order = "desc"
      orderBy = "conversationStart"
      paging = @{
        pageSize = 100
        pageNumber = 1
      }
    }

    # Submit job via background runner
    Start-AppJob -Name "Submit Analytics Job" -Type "Query" -ScriptBlock {
      param($queryBody, $accessToken, $instanceName, $maxItems)

      # Helper function to call Invoke-GcRequest with context
      function Invoke-GcRequestWithContext {
        param($Method, $Path, $Body = $null)
        Invoke-GcRequest -Method $Method -Path $Path -Body $Body -AccessToken $accessToken -InstanceName $instanceName
      }

      # Submit the job
      $jobResponse = Invoke-GcRequestWithContext -Method POST -Path '/api/v2/analytics/conversations/details/jobs' -Body $queryBody

      # Poll for completion
      $jobId = $jobResponse.id
      $timeout = 300
      $pollInterval = 2
      $elapsed = 0

      while ($elapsed -lt $timeout) {
        $status = Invoke-GcRequestWithContext -Method GET -Path "/api/v2/analytics/conversations/details/jobs/$jobId"

        if ($status.state -match 'FULFILLED|COMPLETED|SUCCESS') {
          # Fetch results
          $results = Invoke-GcPagedRequest -Method GET -Path "/api/v2/analytics/conversations/details/jobs/$jobId/results" `
            -AccessToken $accessToken -InstanceName $instanceName -MaxItems $maxItems
          return @{
            JobId = $jobId
            Status = $status.state
            Results = $results
            Job = $jobResponse
            StatusData = $status
          }
        }

        if ($status.state -match 'FAILED|ERROR') {
          throw "Analytics job failed: $($status.state)"
        }

        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval
      }

      throw "Analytics job timed out after $timeout seconds"
    } -ArgumentList @($queryBody, $script:AppState.AccessToken, $script:AppState.Region, $maxResults) -OnCompleted ({
      param($job)
      Set-ControlEnabled -Control $h.BtnSubmitJob -Enabled $true

      if ($job.Result -and $job.Result.JobId) {
        $jobData = @{
          JobId = $job.Result.JobId
          Status = $job.Result.Status
          SubmittedTime = Get-Date
          CompletedTime = Get-Date
          Results = $job.Result.Results
          RawJob = $job.Result.Job
          RawStatus = $job.Result.StatusData
        }

        $script:AnalyticsJobs += $jobData
        Refresh-JobsList
        Set-Status "Analytics job completed: $($jobData.JobId) - $($jobData.Results.Count) results"

        Set-ControlEnabled -Control $h.BtnViewResults -Enabled $true
        Set-ControlEnabled -Control $h.BtnExportResults -Enabled $true
      } else {
        Set-Status "Failed to submit analytics job. See job logs for details."
      }
    }.GetNewClosure())
  }.GetNewClosure())

  $h.BtnRefresh.Add_Click({
    Refresh-JobsList
    Set-Status "Refreshed job list."
  }.GetNewClosure())

  $h.BtnViewResults.Add_Click({
    $selected = $h.GridJobs.SelectedItem
    if (-not $selected) {
      Set-Status "Please select a job to view results."
      return
    }

    $jobId = $selected.JobId
    $jobData = $script:AnalyticsJobs | Where-Object { $_.JobId -eq $jobId } | Select-Object -First 1

    if (-not $jobData -or -not $jobData.Results) {
      Set-Status "No results available for this job."
      return
    }

    # Show results in a message box (simplified - in production, this would open a new view)
    $resultSummary = "Job ID: $($jobData.JobId)`nStatus: $($jobData.Status)`nResults: $($jobData.Results.Count) conversations"
    [System.Windows.MessageBox]::Show(
      $resultSummary,
      "Analytics Job Results",
      [System.Windows.MessageBoxButton]::OK,
      [System.Windows.MessageBoxImage]::Information
    )
    Set-Status "Viewing results for job: $jobId"
  }.GetNewClosure())

  $h.BtnExportResults.Add_Click({
    $selected = $h.GridJobs.SelectedItem
    if (-not $selected) {
      Set-Status "Please select a job to export results."
      return
    }

    $jobId = $selected.JobId
    $jobData = $script:AnalyticsJobs | Where-Object { $_.JobId -eq $jobId } | Select-Object -First 1

    if (-not $jobData -or -not $jobData.Results) {
      Set-Status "No results available for this job."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "analytics_job_${jobId}_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $jobData.Results | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($jobData.Results.Count) results to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }.GetNewClosure()
    } catch {
      Set-Status "Failed to export: $_"
    }
  }.GetNewClosure())

  Refresh-JobsList

  return $view
}

function New-IncidentPacketView {
  <#
  .SYNOPSIS
    Creates the Incident Packet module view for generating comprehensive conversation packets.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <StackPanel>
            <TextBlock Text="Incident Packet Generator" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
            <TextBlock Text="Generate comprehensive incident packets with conversation data, timeline, and artifacts" Margin="0,4,0,0" Foreground="#FF6B7280"/>
          </StackPanel>

          <Button x:Name="BtnGeneratePacket" Grid.Column="1" Content="Generate Packet" Width="140" Height="32" VerticalAlignment="Center" Margin="0,0,8,0" IsEnabled="False"/>
        </Grid>

        <StackPanel Grid.Row="1" Margin="0,12,0,0">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="300"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <TextBlock Grid.Column="0" Text="Conversation ID:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBox x:Name="TxtPacketConvId" Grid.Column="1" Height="28" Text="Enter conversation ID..."/>
          </Grid>

          <TextBlock Text="Packet Contents:" FontWeight="SemiBold" Margin="0,12,0,8"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="250"/>
              <ColumnDefinition Width="250"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0">
              <CheckBox x:Name="ChkConversationJson" Content="conversation.json" IsChecked="True" IsEnabled="False" Margin="0,0,0,4"/>
              <CheckBox x:Name="ChkTimelineJson" Content="timeline.json" IsChecked="True" IsEnabled="False" Margin="0,0,0,4"/>
              <CheckBox x:Name="ChkSummaryMd" Content="summary.md" IsChecked="True" IsEnabled="False" Margin="0,0,0,4"/>
            </StackPanel>

            <StackPanel Grid.Column="1">
              <CheckBox x:Name="ChkTranscriptTxt" Content="transcript.txt" IsChecked="True" IsEnabled="False" Margin="0,0,0,4"/>
              <CheckBox x:Name="ChkEventsNdjson" Content="events.ndjson (if available)" IsChecked="True" IsEnabled="False" Margin="0,0,0,4"/>
              <CheckBox x:Name="ChkZip" Content="Create ZIP archive" IsChecked="True" Margin="0,0,0,4"/>
            </StackPanel>
          </Grid>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Recent Packets" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock x:Name="TxtPacketCount" Text="(0 packets)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
          <Button x:Name="BtnOpenPacketFolder" Content="Open Artifacts" Width="120" Height="26" Margin="12,0,0,0" IsEnabled="False"/>
        </StackPanel>

        <DataGrid x:Name="GridPackets" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Conversation ID" Binding="{Binding ConversationId}" Width="280"/>
            <DataGridTextColumn Header="Generated Time" Binding="{Binding GeneratedTime}" Width="160"/>
            <DataGridTextColumn Header="Files" Binding="{Binding FileCount}" Width="80"/>
            <DataGridTextColumn Header="Size" Binding="{Binding Size}" Width="100"/>
            <DataGridTextColumn Header="Path" Binding="{Binding Path}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    BtnGeneratePacket      = $view.FindName('BtnGeneratePacket')
    TxtPacketConvId        = $view.FindName('TxtPacketConvId')
    ChkConversationJson    = $view.FindName('ChkConversationJson')
    ChkTimelineJson        = $view.FindName('ChkTimelineJson')
    ChkSummaryMd           = $view.FindName('ChkSummaryMd')
    ChkTranscriptTxt       = $view.FindName('ChkTranscriptTxt')
    ChkEventsNdjson        = $view.FindName('ChkEventsNdjson')
    ChkZip                 = $view.FindName('ChkZip')
    TxtPacketCount         = $view.FindName('TxtPacketCount')
    BtnOpenPacketFolder    = $view.FindName('BtnOpenPacketFolder')
    GridPackets            = $view.FindName('GridPackets')
  }

  Enable-PrimaryActionButtons -Handles $h


  # Track packet history
  if (-not (Get-Variable -Name IncidentPacketHistory -Scope Script -ErrorAction SilentlyContinue)) {
    $script:IncidentPacketHistory = @()
  }

  function Refresh-PacketHistory {
    if ($script:IncidentPacketHistory.Count -eq 0) {
      $h.GridPackets.ItemsSource = @()
      $h.TxtPacketCount.Text = "(0 packets)"
      return
    }

    $displayData = $script:IncidentPacketHistory | ForEach-Object {
      $size = if (Test-Path $_.Path) {
        $item = Get-Item $_.Path
        if ($item.PSIsContainer) {
          $totalSize = (Get-ChildItem $_.Path -Recurse | Measure-Object -Property Length -Sum).Sum
          "{0:N2} MB" -f ($totalSize / 1MB)
        } else {
          "{0:N2} MB" -f ($item.Length / 1MB)
        }
      } else { "N/A" }

      [PSCustomObject]@{
        ConversationId = $_.ConversationId
        GeneratedTime = $_.GeneratedTime.ToString('yyyy-MM-dd HH:mm:ss')
        FileCount = $_.FileCount
        Size = $size
        Path = $_.Path
        PacketData = $_
      }
    }

    $h.GridPackets.ItemsSource = $displayData
    $h.TxtPacketCount.Text = "($($script:IncidentPacketHistory.Count) packets)"
  }

  $h.BtnGeneratePacket.Add_Click({
    $convId = $h.TxtPacketConvId.Text.Trim()

    # Validate conversation ID
    if ([string]::IsNullOrWhiteSpace($convId) -or $convId -eq "Enter conversation ID...") {
      [System.Windows.MessageBox]::Show(
        "Please enter a conversation ID.",
        "No Conversation ID",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )
      return
    }

    # Check authentication
    if (-not $script:AppState.AccessToken) {
      [System.Windows.MessageBox]::Show(
        "Please log in first to generate incident packets.",
        "Authentication Required",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )
      return
    }

    Set-Status "Generating incident packet for conversation: $convId"
    Set-ControlEnabled -Control $h.BtnGeneratePacket -Enabled ($false)

    $createZip = $h.ChkZip.IsChecked

    Start-AppJob -Name "Export Incident Packet — $convId" -Type 'Export' -ScriptBlock {
      param($conversationId, $region, $accessToken, $artifactsDir, $eventBuffer, $createZip)

      try {
        # Build subscription events from buffer (if available)
        $subscriptionEvents = $eventBuffer

        # Export packet
        $packet = Export-GcConversationPacket `
          -ConversationId $conversationId `
          -Region $region `
          -AccessToken $accessToken `
          -OutputDirectory $artifactsDir `
          -SubscriptionEvents $subscriptionEvents `
          -CreateZip:$createZip

        return $packet
      } catch {
        Write-Error "Failed to export packet: $_"
        return $null
      }
    } -ArgumentList @($convId, $script:AppState.Region, $script:AppState.AccessToken, $script:ArtifactsDir, $script:AppState.EventBuffer, $createZip) -OnCompleted {
      param($job)
      Set-ControlEnabled -Control $h.BtnGeneratePacket -Enabled ($true)

      if ($job.Result) {
        $packet = $job.Result
        $artifactPath = if ($packet.ZipPath) { $packet.ZipPath } else { $packet.PacketDirectory }

        # Count files in packet
        $fileCount = 0
        if (Test-Path $packet.PacketDirectory) {
          $fileCount = (Get-ChildItem $packet.PacketDirectory -File).Count
        }

        $packetRecord = @{
          ConversationId = $packet.ConversationId
          GeneratedTime = Get-Date
          FileCount = $fileCount
          Path = $artifactPath
          PacketData = $packet
        }

        $script:IncidentPacketHistory += $packetRecord
        Refresh-PacketHistory

        $displayPath = Split-Path $artifactPath -Leaf
        Set-Status "Incident packet generated: $displayPath"
        Show-Snackbar "Packet generated! Saved to artifacts/$displayPath" -Action "Open Folder" -ActionCallback {
          Start-Process (Split-Path $artifactPath -Parent)
        }
      } else {
        Set-Status "Failed to generate packet. See job logs for details."
      }
    }
  })

  $h.BtnOpenPacketFolder.Add_Click({
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (Test-Path $artifactsDir) {
      Start-Process $artifactsDir
      Set-Status "Opened artifacts folder."
    } else {
      Set-Status "Artifacts folder not found."
    }
  })

  $h.TxtPacketConvId.Add_GotFocus({
    if ($h.TxtPacketConvId.Text -eq "Enter conversation ID...") {
      $h.TxtPacketConvId.Text = ""
    }
  }.GetNewClosure())

  $h.TxtPacketConvId.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtPacketConvId.Text)) {
      $h.TxtPacketConvId.Text = "Enter conversation ID..."
    }
  }.GetNewClosure())

  Refresh-PacketHistory

  return $view
}

function New-AbandonExperienceView {
  <#
  .SYNOPSIS
    Creates the Abandon & Experience module view with abandonment metrics and analysis.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Abandonment &amp; Experience Analysis" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock Text="Analyze abandonment metrics and customer experience" Margin="0,4,0,0" Foreground="#FF6B7280"/>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="Date Range:" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <ComboBox x:Name="CmbAbandonDateRange" Width="150" Height="26" Margin="0,0,8,0" SelectedIndex="0">
            <ComboBoxItem Content="Last 1 hour"/>
            <ComboBoxItem Content="Last 6 hours"/>
            <ComboBoxItem Content="Last 24 hours"/>
            <ComboBoxItem Content="Last 7 days"/>
          </ComboBox>
          <Button x:Name="BtnAbandonQuery" Content="Query Metrics" Width="120" Height="32" Margin="0,0,0,0" IsEnabled="True"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <StackPanel Margin="0,0,12,0">
          <TextBlock Text="Abandonment Rate" FontSize="12" Foreground="#FF6B7280" Margin="0,0,0,4"/>
          <TextBlock x:Name="TxtAbandonRate" Text="--" FontSize="24" FontWeight="Bold" Foreground="#FF111827"/>
        </StackPanel>

        <StackPanel Grid.Column="1" Margin="0,0,12,0">
          <TextBlock Text="Total Offered" FontSize="12" Foreground="#FF6B7280" Margin="0,0,0,4"/>
          <TextBlock x:Name="TxtTotalOffered" Text="--" FontSize="24" FontWeight="Bold" Foreground="#FF111827"/>
        </StackPanel>

        <StackPanel Grid.Column="2" Margin="0,0,12,0">
          <TextBlock Text="Avg Wait Time" FontSize="12" Foreground="#FF6B7280" Margin="0,0,0,4"/>
          <TextBlock x:Name="TxtAvgWaitTime" Text="--" FontSize="24" FontWeight="Bold" Foreground="#FF111827"/>
        </StackPanel>

        <StackPanel Grid.Column="3">
          <TextBlock Text="Avg Handle Time" FontSize="12" Foreground="#FF6B7280" Margin="0,0,0,4"/>
          <TextBlock x:Name="TxtAvgHandleTime" Text="--" FontSize="24" FontWeight="Bold" Foreground="#FF111827"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="2" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Abandoned Conversations" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock x:Name="TxtAbandonCount" Text="(0 conversations)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
          <Button x:Name="BtnAbandonExport" Content="Export JSON" Width="100" Height="26" Margin="12,0,0,0" IsEnabled="False"/>
        </StackPanel>

        <DataGrid x:Name="GridAbandonedConversations" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Conversation ID" Binding="{Binding ConversationId}" Width="250"/>
            <DataGridTextColumn Header="Start Time" Binding="{Binding StartTime}" Width="180"/>
            <DataGridTextColumn Header="Queue" Binding="{Binding QueueName}" Width="180"/>
            <DataGridTextColumn Header="Wait Time" Binding="{Binding WaitTime}" Width="120"/>
            <DataGridTextColumn Header="Direction" Binding="{Binding Direction}" Width="100"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    CmbAbandonDateRange        = $view.FindName('CmbAbandonDateRange')
    BtnAbandonQuery            = $view.FindName('BtnAbandonQuery')
    TxtAbandonRate             = $view.FindName('TxtAbandonRate')
    TxtTotalOffered            = $view.FindName('TxtTotalOffered')
    TxtAvgWaitTime             = $view.FindName('TxtAvgWaitTime')
    TxtAvgHandleTime           = $view.FindName('TxtAvgHandleTime')
    TxtAbandonCount            = $view.FindName('TxtAbandonCount')
    BtnAbandonExport           = $view.FindName('BtnAbandonExport')
    GridAbandonedConversations = $view.FindName('GridAbandonedConversations')
  }

  Enable-PrimaryActionButtons -Handles $h


  $script:AbandonmentData = $null
  $script:AbandonedConversations = @()

  # Query button click handler
  $h.BtnAbandonQuery.Add_Click({
    Set-Status "Querying abandonment metrics..."
    Set-ControlEnabled -Control $h.BtnAbandonQuery -Enabled ($false)
    Set-ControlEnabled -Control $h.BtnAbandonExport -Enabled ($false)

    # Get date range
    $now = Get-Date
    $startTime = switch ($h.CmbAbandonDateRange.SelectedIndex) {
      0 { $now.AddHours(-1) }
      1 { $now.AddHours(-6) }
      2 { $now.AddHours(-24) }
      3 { $now.AddDays(-7) }
      default { $now.AddHours(-24) }
    }
    $endTime = $now

    $coreAnalyticsPath = Join-Path -Path $coreRoot -ChildPath 'Analytics.psm1'
    $coreHttpPath = Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1'

    Start-AppJob -Name "Query Abandonment Metrics" -Type "Query" -ScriptBlock {
      param($analyticsPath, $httpPath, $accessToken, $region, $start, $end)

      Import-Module $httpPath -Force
      Import-Module $analyticsPath -Force

      $metrics = Get-GcAbandonmentMetrics -StartTime $start -EndTime $end `
        -AccessToken $accessToken -InstanceName $region

      $conversations = Search-GcAbandonedConversations -StartTime $start -EndTime $end `
        -AccessToken $accessToken -InstanceName $region -MaxItems 100

      return @{
        metrics = $metrics
        conversations = $conversations
      }
    } -ArgumentList @($coreAnalyticsPath, $coreHttpPath, $script:AppState.AccessToken, $script:AppState.Region, $startTime, $endTime) -OnCompleted {
      param($job)
      Set-ControlEnabled -Control $h.BtnAbandonQuery -Enabled ($true)

      if ($job.Result -and $job.Result.metrics) {
        $metrics = $job.Result.metrics
        $script:AbandonmentData = $metrics

        # Update metric cards
        $h.TxtAbandonRate.Text = "$($metrics.abandonmentRate)%"
        $h.TxtTotalOffered.Text = "$($metrics.totalOffered)"
        $h.TxtAvgWaitTime.Text = "$($metrics.avgWaitTime)s"
        $h.TxtAvgHandleTime.Text = "$($metrics.avgHandleTime)s"

        # Update abandoned conversations grid
        if ($job.Result.conversations -and $job.Result.conversations.Count -gt 0) {
          $script:AbandonedConversations = $job.Result.conversations

          $displayData = $job.Result.conversations | ForEach-Object {
            $queueName = 'N/A'
            $waitTime = 'N/A'
            $direction = 'N/A'

            if ($_.participants) {
              foreach ($participant in $_.participants) {
                if ($participant.sessions) {
                  foreach ($session in $participant.sessions) {
                    if ($session.segments) {
                      foreach ($segment in $session.segments) {
                        if ($segment.queueName) { $queueName = $segment.queueName }
                        if ($segment.segmentType -eq 'interact') {
                          if ($segment.properties -and $segment.properties.direction) {
                            $direction = $segment.properties.direction
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            [PSCustomObject]@{
              ConversationId = $_.conversationId
              StartTime = if ($_.conversationStart) { $_.conversationStart } else { 'N/A' }
              QueueName = $queueName
              WaitTime = $waitTime
              Direction = $direction
            }
          }

          $h.GridAbandonedConversations.ItemsSource = $displayData
          $h.TxtAbandonCount.Text = "($($job.Result.conversations.Count) conversations)"
          Set-ControlEnabled -Control $h.BtnAbandonExport -Enabled ($true)
        } else {
          $h.GridAbandonedConversations.ItemsSource = @()
          $h.TxtAbandonCount.Text = "(0 conversations)"
        }

        Set-Status "Abandonment metrics loaded successfully."
      } else {
        # Reset display
        $h.TxtAbandonRate.Text = "--"
        $h.TxtTotalOffered.Text = "--"
        $h.TxtAvgWaitTime.Text = "--"
        $h.TxtAvgHandleTime.Text = "--"
        $h.GridAbandonedConversations.ItemsSource = @()
        $h.TxtAbandonCount.Text = "(0 conversations)"
        Set-Status "Failed to load abandonment metrics."
      }
    }
  })

  # Export button click handler
  $h.BtnAbandonExport.Add_Click({
    if (-not $script:AbandonmentData -and (-not $script:AbandonedConversations -or $script:AbandonedConversations.Count -eq 0)) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "abandonment_analysis_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $exportData = @{
        metrics = $script:AbandonmentData
        conversations = $script:AbandonedConversations
        timestamp = (Get-Date).ToString('o')
      }

      $exportData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported abandonment analysis to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  return $view
}

function New-MediaQualityView {
  <#
  .SYNOPSIS
    Creates the Media & Quality module view with recordings, transcripts, and evaluations.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <TabControl x:Name="TabsMediaQuality">
      <TabItem Header="Recordings">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="12,12,12,12">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>

              <StackPanel>
                <TextBlock Text="Recordings" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
                <TextBlock Text="View and download conversation recordings" Margin="0,4,0,0" Foreground="#FF6B7280"/>
              </StackPanel>

              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnLoadRecordings" Content="Load Recordings" Width="130" Height="32" Margin="0,0,8,0"/>
                <Button x:Name="BtnExportRecordings" Content="Export JSON" Width="100" Height="32" IsEnabled="False"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12" Margin="12,0,12,12">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>

              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Recordings List" FontWeight="SemiBold" Foreground="#FF111827"/>
                <TextBlock x:Name="TxtRecordingCount" Text="(0 recordings)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
              </StackPanel>

              <DataGrid x:Name="GridRecordings" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                        HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Recording ID" Binding="{Binding RecordingId}" Width="250"/>
                  <DataGridTextColumn Header="Conversation ID" Binding="{Binding ConversationId}" Width="250"/>
                  <DataGridTextColumn Header="Duration (s)" Binding="{Binding Duration}" Width="120"/>
                  <DataGridTextColumn Header="Created" Binding="{Binding Created}" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
            </Grid>
          </Border>
        </Grid>
      </TabItem>

      <TabItem Header="Transcripts">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="12,12,12,12">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>

              <StackPanel>
                <TextBlock Text="Conversation Transcripts" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
                <TextBlock Text="View conversation transcripts" Margin="0,4,0,0" Foreground="#FF6B7280"/>
              </StackPanel>

              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <TextBox x:Name="TxtTranscriptConvId" Width="250" Height="26" Margin="0,0,8,0" Text="Enter conversation ID..."/>
                <Button x:Name="BtnLoadTranscript" Content="Load Transcript" Width="120" Height="32" Margin="0,0,8,0"/>
                <Button x:Name="BtnExportTranscript" Content="Export TXT" Width="100" Height="32" IsEnabled="False"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12" Margin="12,0,12,12">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <TextBlock x:Name="TxtTranscriptContent" Text="No transcript loaded. Enter a conversation ID and click Load Transcript."
                         TextWrapping="Wrap" Foreground="#FF111827" FontFamily="Consolas"/>
            </ScrollViewer>
          </Border>
        </Grid>
      </TabItem>

      <TabItem Header="Quality Evaluations">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="12,12,12,12">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>

              <StackPanel>
                <TextBlock Text="Quality Evaluations" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
                <TextBlock Text="View quality evaluation scores and details" Margin="0,4,0,0" Foreground="#FF6B7280"/>
              </StackPanel>

              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnLoadEvaluations" Content="Load Evaluations" Width="130" Height="32" Margin="0,0,8,0"/>
                <Button x:Name="BtnExportEvaluations" Content="Export JSON" Width="100" Height="32" IsEnabled="False"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12" Margin="12,0,12,12">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>

              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Evaluations List" FontWeight="SemiBold" Foreground="#FF111827"/>
                <TextBlock x:Name="TxtEvaluationCount" Text="(0 evaluations)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
              </StackPanel>

              <DataGrid x:Name="GridEvaluations" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                        HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Evaluation ID" Binding="{Binding EvaluationId}" Width="200"/>
                  <DataGridTextColumn Header="Agent" Binding="{Binding Agent}" Width="150"/>
                  <DataGridTextColumn Header="Evaluator" Binding="{Binding Evaluator}" Width="150"/>
                  <DataGridTextColumn Header="Score" Binding="{Binding Score}" Width="80"/>
                  <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="100"/>
                  <DataGridTextColumn Header="Created" Binding="{Binding Created}" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
            </Grid>
          </Border>
        </Grid>
      </TabItem>
    </TabControl>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    # Recordings tab
    BtnLoadRecordings      = $view.FindName('BtnLoadRecordings')
    BtnExportRecordings    = $view.FindName('BtnExportRecordings')
    TxtRecordingCount      = $view.FindName('TxtRecordingCount')
    GridRecordings         = $view.FindName('GridRecordings')

    # Transcripts tab
    TxtTranscriptConvId    = $view.FindName('TxtTranscriptConvId')
    BtnLoadTranscript      = $view.FindName('BtnLoadTranscript')
    BtnExportTranscript    = $view.FindName('BtnExportTranscript')
    TxtTranscriptContent   = $view.FindName('TxtTranscriptContent')

    # Quality Evaluations tab
    BtnLoadEvaluations     = $view.FindName('BtnLoadEvaluations')
    BtnExportEvaluations   = $view.FindName('BtnExportEvaluations')
    TxtEvaluationCount     = $view.FindName('TxtEvaluationCount')
    GridEvaluations        = $view.FindName('GridEvaluations')
  }

  $script:RecordingsData = @()
  $script:TranscriptData = $null
  $script:EvaluationsData = @()

  # Load Recordings button handler
  $h.BtnLoadRecordings.Add_Click({
    Set-Status "Loading recordings..."
    Set-ControlEnabled -Control $h.BtnLoadRecordings -Enabled $false
    Set-ControlEnabled -Control $h.BtnExportRecordings -Enabled $false

    $coreConvPath = Join-Path -Path $coreRoot -ChildPath 'ConversationsExtended.psm1'
    $coreHttpPath = Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1'

    Start-AppJob -Name "Load Recordings" -Type "Query" -ScriptBlock {
      param($convPath, $httpPath, $accessToken, $region)

      Import-Module $httpPath -Force
      Import-Module $convPath -Force

      Get-GcRecordings -AccessToken $accessToken -InstanceName $region -MaxItems 100
    } -ArgumentList @($coreConvPath, $coreHttpPath, $script:AppState.AccessToken, $script:AppState.Region) -OnCompleted ({
      param($job)
      Set-ControlEnabled -Control $h.BtnLoadRecordings -Enabled $true

      if ($job.Result -and $job.Result.Count -gt 0) {
        $script:RecordingsData = $job.Result

        $displayData = $job.Result | ForEach-Object {
          [PSCustomObject]@{
            RecordingId = if ($_.id) { $_.id } else { 'N/A' }
            ConversationId = if ($_.conversationId) { $_.conversationId } else { 'N/A' }
            Duration = if ($_.durationMilliseconds) { [Math]::Round($_.durationMilliseconds / 1000, 1) } else { 0 }
            Created = if ($_.dateCreated) { $_.dateCreated } else { 'N/A' }
          }
        }

        $h.GridRecordings.ItemsSource = $displayData
        $h.TxtRecordingCount.Text = "($($job.Result.Count) recordings)"
        Set-ControlEnabled -Control $h.BtnExportRecordings -Enabled $true
        Set-Status "Loaded $($job.Result.Count) recordings."
      } else {
        $h.GridRecordings.ItemsSource = @()
        $h.TxtRecordingCount.Text = "(0 recordings)"
        Set-Status "No recordings found or failed to load."
      }
    }.GetNewClosure())
  }.GetNewClosure())

  # Export Recordings button handler
  $h.BtnExportRecordings.Add_Click({
    if (-not $script:RecordingsData -or $script:RecordingsData.Count -eq 0) {
      Set-Status "No recordings to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "recordings_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:RecordingsData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($script:RecordingsData.Count) recordings to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }.GetNewClosure()
    } catch {
      Set-Status "Failed to export: $_"
    }
  }.GetNewClosure())

  # Load Transcript button handler
  $h.BtnLoadTranscript.Add_Click({
    $convId = if ($h.TxtTranscriptConvId) { ([string]$h.TxtTranscriptConvId.Text).Trim() } else { '' }

    if ([string]::IsNullOrWhiteSpace($convId) -or $convId -eq "Enter conversation ID...") {
      [System.Windows.MessageBox]::Show("Please enter a conversation ID.", "Missing Input",
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
      return
    }

    Set-Status "Loading transcript for conversation $convId..."
    Set-ControlEnabled -Control $h.BtnLoadTranscript -Enabled $false
    Set-ControlEnabled -Control $h.BtnExportTranscript -Enabled $false
    $h.TxtTranscriptContent.Text = "Loading transcript..."

    $coreConvPath = Join-Path -Path $coreRoot -ChildPath 'ConversationsExtended.psm1'
    $coreHttpPath = Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1'

    Start-AppJob -Name "Load Transcript" -Type "Query" -ScriptBlock {
      param($convPath, $httpPath, $accessToken, $region, $convId)

      Import-Module $httpPath -Force
      Import-Module $convPath -Force

      Get-GcConversationTranscript -ConversationId $convId -AccessToken $accessToken -InstanceName $region
    } -ArgumentList @($coreConvPath, $coreHttpPath, $script:AppState.AccessToken, $script:AppState.Region, $convId) -OnCompleted ({
      param($job)
      Set-ControlEnabled -Control $h.BtnLoadTranscript -Enabled $true

      if ($job.Result -and $job.Result.Count -gt 0) {
        $script:TranscriptData = $job.Result

        # Format transcript as text
        $transcriptText = ""
        foreach ($entry in $job.Result) {
          $time = if ($entry.timestamp) { $entry.timestamp } else { "N/A" }
          $participant = if ($entry.participant) { $entry.participant } else { "Unknown" }
          $message = if ($entry.message) { $entry.message } else { "" }

          $transcriptText += "[$time] $participant`: $message`r`n`r`n"
        }

        if ([string]::IsNullOrWhiteSpace($transcriptText)) {
          $transcriptText = "No transcript messages found for this conversation."
        }

        $h.TxtTranscriptContent.Text = $transcriptText
        Set-ControlEnabled -Control $h.BtnExportTranscript -Enabled $true
        Set-Status "Loaded transcript for conversation $convId."
      } else {
        $h.TxtTranscriptContent.Text = "No transcript found for conversation $convId or conversation does not exist."
        Set-Status "No transcript found."
      }
    }.GetNewClosure())
  }.GetNewClosure())

  # Export Transcript button handler
  $h.BtnExportTranscript.Add_Click({
    if (-not $script:TranscriptData) {
      Set-Status "No transcript to export."
      return
    }

    $convId = if ($h.TxtTranscriptConvId) { ([string]$h.TxtTranscriptConvId.Text).Trim() } else { '' }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "transcript_${convId}_$timestamp.txt"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $h.TxtTranscriptContent.Text | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported transcript to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }.GetNewClosure()
    } catch {
      Set-Status "Failed to export: $_"
    }
  }.GetNewClosure())

  # Load Evaluations button handler
  $h.BtnLoadEvaluations.Add_Click({
    Set-Status "Loading quality evaluations..."
    Set-ControlEnabled -Control $h.BtnLoadEvaluations -Enabled $false
    Set-ControlEnabled -Control $h.BtnExportEvaluations -Enabled $false

    $coreConvPath = Join-Path -Path $coreRoot -ChildPath 'ConversationsExtended.psm1'
    $coreHttpPath = Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1'

    Start-AppJob -Name "Load Quality Evaluations" -Type "Query" -ScriptBlock {
      param($convPath, $httpPath, $accessToken, $region)

      Import-Module $httpPath -Force
      Import-Module $convPath -Force

      Get-GcQualityEvaluations -AccessToken $accessToken -InstanceName $region -MaxItems 100
    } -ArgumentList @($coreConvPath, $coreHttpPath, $script:AppState.AccessToken, $script:AppState.Region) -OnCompleted ({
      param($job)
      Set-ControlEnabled -Control $h.BtnLoadEvaluations -Enabled $true

      if ($job.Result -and $job.Result.Count -gt 0) {
        $script:EvaluationsData = $job.Result

        $displayData = $job.Result | ForEach-Object {
          [PSCustomObject]@{
            EvaluationId = if ($_.id) { $_.id } else { 'N/A' }
            Agent = if ($_.agent -and $_.agent.name) { $_.agent.name } else { 'N/A' }
            Evaluator = if ($_.evaluator -and $_.evaluator.name) { $_.evaluator.name } else { 'N/A' }
            Score = if ($_.score) { $_.score } else { 'N/A' }
            Status = if ($_.status) { $_.status } else { 'N/A' }
            Created = if ($_.dateCreated) { $_.dateCreated } else { 'N/A' }
          }
        }

        $h.GridEvaluations.ItemsSource = $displayData
        $h.TxtEvaluationCount.Text = "($($job.Result.Count) evaluations)"
        Set-ControlEnabled -Control $h.BtnExportEvaluations -Enabled $true
        Set-Status "Loaded $($job.Result.Count) quality evaluations."
      } else {
        $h.GridEvaluations.ItemsSource = @()
        $h.TxtEvaluationCount.Text = "(0 evaluations)"
        Set-Status "No evaluations found or failed to load."
      }
    }.GetNewClosure())
  }.GetNewClosure())

  # Export Evaluations button handler
  $h.BtnExportEvaluations.Add_Click({
    if (-not $script:EvaluationsData -or $script:EvaluationsData.Count -eq 0) {
      Set-Status "No evaluations to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "quality_evaluations_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:EvaluationsData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($script:EvaluationsData.Count) evaluations to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }.GetNewClosure()
    } catch {
      Set-Status "Failed to export: $_"
    }
  }.GetNewClosure())

  # Transcript conversation ID textbox focus handlers
  $h.TxtTranscriptConvId.Add_GotFocus({
    if ($h.TxtTranscriptConvId.Text -eq "Enter conversation ID...") {
      $h.TxtTranscriptConvId.Text = ""
    }
  }.GetNewClosure())

  $h.TxtTranscriptConvId.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtTranscriptConvId.Text)) {
      $h.TxtTranscriptConvId.Text = "Enter conversation ID..."
    }
  }.GetNewClosure())

  return $view
}

function New-FlowsView {
  <#
  .SYNOPSIS
    Creates the Flows module view with list, search, and export capabilities.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Architect Flows" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
            <TextBlock Text="Type:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="CmbFlowType" Width="180" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="All Types"/>
              <ComboBoxItem Content="Inbound Call"/>
              <ComboBoxItem Content="Inbound Chat"/>
              <ComboBoxItem Content="Inbound Email"/>
              <ComboBoxItem Content="Outbound"/>
              <ComboBoxItem Content="Workflow"/>
              <ComboBoxItem Content="Bot"/>
            </ComboBox>
            <TextBlock Text="Status:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <ComboBox x:Name="CmbFlowStatus" Width="140" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="All Status"/>
              <ComboBoxItem Content="Published"/>
              <ComboBoxItem Content="Draft"/>
              <ComboBoxItem Content="Checked Out"/>
            </ComboBox>
          </StackPanel>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnFlowLoad" Content="Load Flows" Width="100" Height="32" Margin="0,0,8,0"/>
          <Button x:Name="BtnFlowExportJson" Content="Export JSON" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnFlowExportCsv" Content="Export CSV" Width="100" Height="32" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Flows" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBox x:Name="TxtFlowSearch" Margin="12,0,0,0" Width="300" Height="26" Text="Search flows..."/>
          <TextBlock x:Name="TxtFlowCount" Text="(0 flows)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
        </StackPanel>

        <DataGrid x:Name="GridFlows" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="250"/>
            <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="150"/>
            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="120"/>
            <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="80"/>
            <DataGridTextColumn Header="Modified" Binding="{Binding Modified}" Width="180"/>
            <DataGridTextColumn Header="Modified By" Binding="{Binding ModifiedBy}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    CmbFlowType        = $view.FindName('CmbFlowType')
    CmbFlowStatus      = $view.FindName('CmbFlowStatus')
    BtnFlowLoad        = $view.FindName('BtnFlowLoad')
    BtnFlowExportJson  = $view.FindName('BtnFlowExportJson')
    BtnFlowExportCsv   = $view.FindName('BtnFlowExportCsv')
    TxtFlowSearch      = $view.FindName('TxtFlowSearch')
    TxtFlowCount       = $view.FindName('TxtFlowCount')
    GridFlows          = $view.FindName('GridFlows')
  }

  Enable-PrimaryActionButtons -Handles $h


  # Store flows data for export
  $script:FlowsData = @()

  # Load button handler
  $h.BtnFlowLoad.Add_Click({
    Set-Status "Loading flows..."

    Start-AppJob -Name "Load Flows" -Type "Query" -ScriptBlock {
      # Query flows using Genesys Cloud API
      $maxItems = 500  # Limit to prevent excessive API calls
      try {
        $results = Invoke-GcPagedRequest -Path '/api/v2/flows' -Method GET `
          -InstanceName $script:AppState.Region -AccessToken $script:AppState.AccessToken -MaxItems $maxItems

        return $results
      } catch {
        Write-Error "Failed to load flows: $_"
        return @()
      }
    } -OnCompleted {
      param($job)


      if ($job.Result) {
        $flows = $job.Result
        $script:FlowsData = $flows

        # Transform to display format
        $displayData = $flows | ForEach-Object {
          [PSCustomObject]@{
            Name = if ($_.name) { $_.name } else { 'N/A' }
            Type = if ($_.type) { $_.type } else { 'N/A' }
            Status = if ($_.publishedVersion) { 'Published' } elseif ($_.checkedInVersion) { 'Checked In' } else { 'Draft' }
            Version = if ($_.publishedVersion.version) { $_.publishedVersion.version } elseif ($_.checkedInVersion.version) { $_.checkedInVersion.version } else { 'N/A' }
            Modified = if ($_.dateModified) { $_.dateModified } else { '' }
            ModifiedBy = if ($_.modifiedBy -and $_.modifiedBy.name) { $_.modifiedBy.name } else { 'N/A' }
          }
        }

        if ($h.GridFlows) { $h.GridFlows.ItemsSource = $displayData }
        if ($h.TxtFlowCount) { $h.TxtFlowCount.Text = "($($flows.Count) flows)" }

        Set-Status "Loaded $($flows.Count) flows."
      } else {
        Set-Status "Failed to load flows. Check job logs."
        if ($h.GridFlows) { $h.GridFlows.ItemsSource = @() }
        if ($h.TxtFlowCount) { $h.TxtFlowCount.Text = "(0 flows)" }
      }
    }
  })

  # Export JSON button handler
  $h.BtnFlowExportJson.Add_Click({
    if (-not $script:FlowsData -or $script:FlowsData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "flows_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:FlowsData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($script:FlowsData.Count) flows to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  # Export CSV button handler
  $h.BtnFlowExportCsv.Add_Click({
    if (-not $script:FlowsData -or $script:FlowsData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "flows_$timestamp.csv"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:FlowsData | Select-Object name, type, @{N='status';E={if ($_.publishedVersion) {'Published'} else {'Draft'}}},
        @{N='version';E={if ($_.publishedVersion.version) {$_.publishedVersion.version} else {'N/A'}}},
        dateModified, @{N='modifiedBy';E={if ($_.modifiedBy.name) {$_.modifiedBy.name} else {'N/A'}}} |
        Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      Set-Status "Exported $($script:FlowsData.Count) flows to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  # Search text changed handler
  $h.TxtFlowSearch.Add_TextChanged({
    if (-not $script:FlowsData -or $script:FlowsData.Count -eq 0) { return }

    $searchText = if ($h.TxtFlowSearch) { $h.TxtFlowSearch.Text.ToLower() } else { "" }
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "search flows...") {
      $displayData = $script:FlowsData | ForEach-Object {
        [PSCustomObject]@{
          Name = if ($_.name) { $_.name } else { 'N/A' }
          Type = if ($_.type) { $_.type } else { 'N/A' }
          Status = if ($_.publishedVersion) { 'Published' } elseif ($_.checkedInVersion) { 'Checked In' } else { 'Draft' }
          Version = if ($_.publishedVersion.version) { $_.publishedVersion.version } elseif ($_.checkedInVersion.version) { $_.checkedInVersion.version } else { 'N/A' }
          Modified = if ($_.dateModified) { $_.dateModified } else { '' }
          ModifiedBy = if ($_.modifiedBy -and $_.modifiedBy.name) { $_.modifiedBy.name } else { 'N/A' }
        }
      }
      if ($h.GridFlows) { $h.GridFlows.ItemsSource = $displayData }
      if ($h.TxtFlowCount) { $h.TxtFlowCount.Text = "($($script:FlowsData.Count) flows)" }
      return
    }

    $filtered = $script:FlowsData | Where-Object {
      $json = ($_ | ConvertTo-Json -Compress -Depth 5).ToLower()
      $json -like "*$searchText*"
    }

    $displayData = $filtered | ForEach-Object {
      [PSCustomObject]@{
        Name = if ($_.name) { $_.name } else { 'N/A' }
        Type = if ($_.type) { $_.type } else { 'N/A' }
        Status = if ($_.publishedVersion) { 'Published' } elseif ($_.checkedInVersion) { 'Checked In' } else { 'Draft' }
        Version = if ($_.publishedVersion.version) { $_.publishedVersion.version } elseif ($_.checkedInVersion.version) { $_.checkedInVersion.version } else { 'N/A' }
        Modified = if ($_.dateModified) { $_.dateModified } else { '' }
        ModifiedBy = if ($_.modifiedBy -and $_.modifiedBy.name) { $_.modifiedBy.name } else { 'N/A' }
      }
    }

    if ($h.GridFlows) { $h.GridFlows.ItemsSource = $displayData }
    if ($h.TxtFlowCount) { $h.TxtFlowCount.Text = "($($filtered.Count) flows)" }
  })

  # Clear search placeholder on focus
  $h.TxtFlowSearch.Add_GotFocus({
    if ($h.TxtFlowSearch -and $h.TxtFlowSearch.Text -eq "Search flows...") {
      $h.TxtFlowSearch.Text = ""
    }
  }.GetNewClosure())

  # Restore search placeholder on lost focus if empty
  $h.TxtFlowSearch.Add_LostFocus({
    if ($h.TxtFlowSearch -and [string]::IsNullOrWhiteSpace($h.TxtFlowSearch.Text)) {
      $h.TxtFlowSearch.Text = "Search flows..."
    }
  }.GetNewClosure())

  return $view
}

function New-DataActionsView {
  <#
  .SYNOPSIS
    Creates the Data Actions module view with list, search, and export capabilities.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Data Actions" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
            <TextBlock Text="Category:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="CmbDataActionCategory" Width="180" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="All Categories"/>
              <ComboBoxItem Content="Custom"/>
              <ComboBoxItem Content="Platform"/>
              <ComboBoxItem Content="Integration"/>
            </ComboBox>
            <TextBlock Text="Status:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <ComboBox x:Name="CmbDataActionStatus" Width="140" Height="26" SelectedIndex="0">
              <ComboBoxItem Content="All Status"/>
              <ComboBoxItem Content="Active"/>
              <ComboBoxItem Content="Inactive"/>
            </ComboBox>
          </StackPanel>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnDataActionLoad" Content="Load Actions" Width="110" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnDataActionExportJson" Content="Export JSON" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnDataActionExportCsv" Content="Export CSV" Width="100" Height="32" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Data Actions" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBox x:Name="TxtDataActionSearch" Margin="12,0,0,0" Width="300" Height="26" Text="Search actions..."/>
          <TextBlock x:Name="TxtDataActionCount" Text="(0 actions)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
        </StackPanel>

        <Grid Grid.Row="1" Margin="0,10,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="12"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <DataGrid x:Name="GridDataActions" Grid.Column="0" AutoGenerateColumns="False" IsReadOnly="True"
                    HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="220"/>
              <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="130"/>
              <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="90"/>
              <DataGridTextColumn Header="Integration" Binding="{Binding Integration}" Width="180"/>
              <DataGridTextColumn Header="Modified" Binding="{Binding Modified}" Width="170"/>
              <DataGridTextColumn Header="Modified By" Binding="{Binding ModifiedBy}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>

          <Border Grid.Column="2" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="10">
            <StackPanel>
              <TextBlock Text="Action Detail" FontWeight="SemiBold" Foreground="#FF111827"/>
              <TextBox x:Name="TxtDataActionDetail" Margin="0,10,0,0" AcceptsReturn="True" Height="520"
                       VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11" TextWrapping="NoWrap"
                       Text="{ } { &quot;hint&quot;: &quot;Select a data action to view the raw payload.&quot; }"/>
            </StackPanel>
          </Border>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    CmbDataActionCategory    = $view.FindName('CmbDataActionCategory')
    CmbDataActionStatus      = $view.FindName('CmbDataActionStatus')
    BtnDataActionLoad        = $view.FindName('BtnDataActionLoad')
    BtnDataActionExportJson  = $view.FindName('BtnDataActionExportJson')
    BtnDataActionExportCsv   = $view.FindName('BtnDataActionExportCsv')
    TxtDataActionSearch      = $view.FindName('TxtDataActionSearch')
    TxtDataActionCount       = $view.FindName('TxtDataActionCount')
    GridDataActions          = $view.FindName('GridDataActions')
    TxtDataActionDetail      = $view.FindName('TxtDataActionDetail')
  }

  # Capture control references for event handlers (avoid dynamic scoping surprises)
  $cmbCategory   = $h.CmbDataActionCategory
  $cmbStatus     = $h.CmbDataActionStatus
  $btnLoad       = $h.BtnDataActionLoad
  $btnExportJson = $h.BtnDataActionExportJson
  $btnExportCsv  = $h.BtnDataActionExportCsv
  $txtSearch     = $h.TxtDataActionSearch
  $txtCount      = $h.TxtDataActionCount
  $grid          = $h.GridDataActions
  $txtDetail     = $h.TxtDataActionDetail

  # Store data actions for export
  $script:DataActionsData = @()

  # Load button handler
  if ($btnLoad) { $btnLoad.Add_Click({
    Set-Status "Loading data actions..."
    Set-ControlEnabled -Control $btnLoad -Enabled ($false)

    Start-AppJob -Name "Load Data Actions" -Type "Query" -ScriptBlock {
      param($coreModulePath, $instanceName, $accessToken, $maxItems)

      Import-Module (Join-Path -Path $coreModulePath -ChildPath 'HttpRequests.psm1') -Force

      try {
        return Invoke-GcPagedRequest -Path '/api/v2/integrations/actions' -Method GET `
          -InstanceName $instanceName -AccessToken $accessToken -MaxItems $maxItems
      } catch {
        Write-Error "Failed to load data actions: $_"
        return @()
      }
    } -ArgumentList @($coreRoot, $script:AppState.Region, $script:AppState.AccessToken, 500) -OnCompleted ({
      param($job)


      $actions = @()
      try { if ($job.Result) { $actions = @($job.Result) } } catch { $actions = @() }

      if ($actions.Count -gt 0) {
        $script:DataActionsData = $actions

        # Transform to display format
        $displayData = $actions | ForEach-Object {
          $status = 'Active'
          try {
            if ($_.enabled -is [bool] -and -not $_.enabled) { $status = 'Inactive' }
          } catch { }

          [PSCustomObject]@{
            Name = if ($_.name) { $_.name } else { 'N/A' }
            Category = if ($_.category) { $_.category } else { 'N/A' }
            Status = $status
            Integration = if ($_.integrationId) { $_.integrationId } else { 'N/A' }
            Modified = if ($_.dateModified) { $_.dateModified } elseif ($_.modifiedDate) { $_.modifiedDate } else { '' }
            ModifiedBy = if ($_.modifiedBy -and $_.modifiedBy.name) { $_.modifiedBy.name } else { 'N/A' }
            RawData = $_
          }
        }

        if ($grid) { $grid.ItemsSource = $displayData }
        if ($txtCount) { $txtCount.Text = "($($actions.Count) actions)" }

        Set-Status "Loaded $($actions.Count) data actions."
      } else {
        Set-Status "Failed to load data actions. Check job logs."
        if ($grid) { $grid.ItemsSource = @() }
        if ($txtCount) { $txtCount.Text = "(0 actions)" }
      }
    }.GetNewClosure())
  }.GetNewClosure()) }

  # Selection -> show raw payload
  if ($grid -and $txtDetail) {
    $grid.Add_SelectionChanged({
      if (-not $grid.SelectedItem) { return }
      $item = $grid.SelectedItem
      $raw = $null
      try { $raw = $item.RawData } catch { $raw = $null }
      if (-not $raw) { $raw = $item }
      try { $txtDetail.Text = ($raw | ConvertTo-Json -Depth 12) } catch { $txtDetail.Text = [string]$raw }
    }.GetNewClosure())
  }

  # Export JSON button handler
  $h.BtnDataActionExportJson.Add_Click({
    if (-not $script:DataActionsData -or $script:DataActionsData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "data_actions_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:DataActionsData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($script:DataActionsData.Count) data actions to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  # Export CSV button handler
  $h.BtnDataActionExportCsv.Add_Click({
    if (-not $script:DataActionsData -or $script:DataActionsData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "data_actions_$timestamp.csv"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:DataActionsData | Select-Object name, category,
        @{N='status';E={'Enabled'}},
        integrationId, modifiedDate, @{N='modifiedBy';E={if ($_.modifiedBy.name) {$_.modifiedBy.name} else {'N/A'}}} |
        Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      Set-Status "Exported $($script:DataActionsData.Count) data actions to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  # Search text changed handler
  if ($txtSearch) { $txtSearch.Add_TextChanged({
    if (-not $script:DataActionsData -or $script:DataActionsData.Count -eq 0) { return }

    $searchText = ''
    try { $searchText = ($txtSearch.Text ?? '').ToLower() } catch { $searchText = '' }

    $filtered = $script:DataActionsData
    if (-not [string]::IsNullOrWhiteSpace($searchText) -and $searchText -ne "search actions...") {
      $filtered = $script:DataActionsData | Where-Object {
        $json = ($_ | ConvertTo-Json -Compress -Depth 6).ToLower()
        $json -like "*$searchText*"
      }
    }

    $displayData = @($filtered) | ForEach-Object {
      $status = 'Active'
      try {
        if ($_.enabled -is [bool] -and -not $_.enabled) { $status = 'Inactive' }
      } catch { }

      [PSCustomObject]@{
        Name = if ($_.name) { $_.name } else { 'N/A' }
        Category = if ($_.category) { $_.category } else { 'N/A' }
        Status = $status
        Integration = if ($_.integrationId) { $_.integrationId } else { 'N/A' }
        Modified = if ($_.dateModified) { $_.dateModified } elseif ($_.modifiedDate) { $_.modifiedDate } else { '' }
        ModifiedBy = if ($_.modifiedBy -and $_.modifiedBy.name) { $_.modifiedBy.name } else { 'N/A' }
        RawData = $_
      }
    }

    if ($grid) { $grid.ItemsSource = $displayData }
    if ($txtCount) { $txtCount.Text = "($(@($filtered).Count) actions)" }
  }.GetNewClosure()) }

  # Clear search placeholder on focus
  if ($txtSearch) { $txtSearch.Add_GotFocus({
    if ($txtSearch.Text -eq "Search actions...") { $txtSearch.Text = "" }
  }.GetNewClosure()) }

  # Restore search placeholder on lost focus if empty
  if ($txtSearch) { $txtSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($txtSearch.Text)) { $txtSearch.Text = "Search actions..." }
  }.GetNewClosure()) }

  return $view
}

function New-ConfigExportView {
  <#
  .SYNOPSIS
    Creates the Configuration Export module view for exporting Genesys Cloud configuration.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <StackPanel>
            <TextBlock Text="Configuration Export" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
            <TextBlock Text="Export Genesys Cloud configuration to JSON for backup or migration" Margin="0,4,0,0" Foreground="#FF6B7280"/>
          </StackPanel>

          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnExportSelected" Content="Export Selected" Width="130" Height="32" Margin="0,0,8,0"/>
            <Button x:Name="BtnExportAll" Content="Export All" Width="110" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          </StackPanel>
        </Grid>

        <StackPanel Grid.Row="1" Margin="0,12,0,0">
          <TextBlock Text="Select configuration types to export:" FontWeight="SemiBold" Margin="0,0,0,8"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="200"/>
              <ColumnDefinition Width="200"/>
              <ColumnDefinition Width="200"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <CheckBox x:Name="ChkFlows" Grid.Column="0" Content="Flows" IsChecked="True" Margin="0,0,0,8"/>
            <CheckBox x:Name="ChkQueues" Grid.Column="1" Content="Queues" IsChecked="True" Margin="0,0,0,8"/>
            <CheckBox x:Name="ChkSkills" Grid.Column="2" Content="Skills" IsChecked="True" Margin="0,0,0,8"/>
            <CheckBox x:Name="ChkDataActions" Grid.Column="3" Content="Data Actions" IsChecked="True" Margin="0,0,0,8"/>
          </Grid>
          <CheckBox x:Name="ChkCreateZip" Content="Create ZIP archive" IsChecked="True" Margin="0,8,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Export History" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock x:Name="TxtExportCount" Text="(0 exports)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
          <Button x:Name="BtnOpenFolder" Content="Open Folder" Width="110" Height="26" Margin="12,0,0,0"/>
        </StackPanel>

        <DataGrid x:Name="GridExports" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Export Time" Binding="{Binding ExportTime}" Width="160"/>
            <DataGridTextColumn Header="Types Exported" Binding="{Binding Types}" Width="250"/>
            <DataGridTextColumn Header="Total Items" Binding="{Binding TotalItems}" Width="100"/>
            <DataGridTextColumn Header="Path" Binding="{Binding Path}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    BtnExportSelected = $view.FindName('BtnExportSelected')
    BtnExportAll      = $view.FindName('BtnExportAll')
    ChkFlows          = $view.FindName('ChkFlows')
    ChkQueues         = $view.FindName('ChkQueues')
    ChkSkills         = $view.FindName('ChkSkills')
    ChkDataActions    = $view.FindName('ChkDataActions')
    ChkCreateZip      = $view.FindName('ChkCreateZip')
    TxtExportCount    = $view.FindName('TxtExportCount')
    BtnOpenFolder     = $view.FindName('BtnOpenFolder')
    GridExports       = $view.FindName('GridExports')
  }

  # Track export history
  if (-not (Get-Variable -Name ConfigExportHistory -Scope Script -ErrorAction SilentlyContinue)) {
    $script:ConfigExportHistory = @()
  }

  function Refresh-ExportHistory {
    if ($script:ConfigExportHistory.Count -eq 0) {
      $h.GridExports.ItemsSource = @()
      $h.TxtExportCount.Text = "(0 exports)"
      return
    }

    $displayData = $script:ConfigExportHistory | ForEach-Object {
      [PSCustomObject]@{
        ExportTime = $_.ExportTime.ToString('yyyy-MM-dd HH:mm:ss')
        Types = $_.Types -join ', '
        TotalItems = $_.TotalItems
        Path = $_.Path
        ExportData = $_
      }
    }

    $h.GridExports.ItemsSource = $displayData
    $h.TxtExportCount.Text = "($($script:ConfigExportHistory.Count) exports)"
  }

  $h.BtnExportSelected.Add_Click({
    # Check if any type is selected
    if (-not ($h.ChkFlows.IsChecked -or $h.ChkQueues.IsChecked -or $h.ChkSkills.IsChecked -or $h.ChkDataActions.IsChecked)) {
      [System.Windows.MessageBox]::Show(
        "Please select at least one configuration type to export.",
        "No Type Selected",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )
      return
    }

    Set-Status "Exporting configuration..."
    Set-ControlEnabled -Control $h.BtnExportSelected -Enabled ($false)
    Set-ControlEnabled -Control $h.BtnExportAll -Enabled ($false)

    $includeFlows = $h.ChkFlows.IsChecked
    $includeQueues = $h.ChkQueues.IsChecked
    $includeSkills = $h.ChkSkills.IsChecked
    $includeDataActions = $h.ChkDataActions.IsChecked
    $createZip = $h.ChkCreateZip.IsChecked

    Start-AppJob -Name "Export Configuration" -Type "Export" -ScriptBlock {
      param($accessToken, $instanceName, $artifactsDir, $includeFlows, $includeQueues, $includeSkills, $includeDataActions, $createZip)

      Export-GcCompleteConfig `
        -AccessToken $accessToken `
        -InstanceName $instanceName `
        -OutputDirectory $artifactsDir `
        -IncludeFlows:$includeFlows `
        -IncludeQueues:$includeQueues `
        -IncludeSkills:$includeSkills `
        -IncludeDataActions:$includeDataActions `
        -CreateZip:$createZip
    } -ArgumentList @($script:AppState.AccessToken, $script:AppState.Region, $script:ArtifactsDir, $includeFlows, $includeQueues, $includeSkills, $includeDataActions, $createZip) -OnCompleted {
      param($job)
      Set-ControlEnabled -Control $h.BtnExportSelected -Enabled ($true)
      Set-ControlEnabled -Control $h.BtnExportAll -Enabled ($true)

      if ($job.Result) {
        $export = $job.Result
        $totalItems = ($export.Results | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
        $types = $export.Results | ForEach-Object { $_.Type }

        $exportRecord = @{
          ExportTime = Get-Date
          Types = $types
          TotalItems = $totalItems
          Path = if ($export.ZipPath) { $export.ZipPath } else { $export.ExportDirectory }
          ExportData = $export
        }

        $script:ConfigExportHistory += $exportRecord
        Refresh-ExportHistory

        $displayPath = if ($export.ZipPath) { Split-Path $export.ZipPath -Leaf } else { Split-Path $export.ExportDirectory -Leaf }
        Set-Status "Configuration exported: $displayPath ($totalItems items)"
        Show-Snackbar "Export complete! Saved to artifacts/$displayPath" -Action "Open Folder" -ActionCallback {
          Start-Process (Split-Path $exportRecord.Path -Parent)
        }
      } else {
        Set-Status "Failed to export configuration. See job logs for details."
      }
    }
  })

  $h.BtnExportAll.Add_Click({
    # Select all types
    $h.ChkFlows.IsChecked = $true
    $h.ChkQueues.IsChecked = $true
    $h.ChkSkills.IsChecked = $true
    $h.ChkDataActions.IsChecked = $true

    # Trigger export
    $h.BtnExportSelected.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
  })

  $h.BtnOpenFolder.Add_Click({
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (Test-Path $artifactsDir) {
      Start-Process $artifactsDir
      Set-Status "Opened artifacts folder."
    } else {
      Set-Status "Artifacts folder not found."
    }
  })

  Refresh-ExportHistory

  return $view
}

function New-DependencyImpactMapView {
  <#
  .SYNOPSIS
    Creates the Dependency / Impact Map module view with object reference search.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Dependency / Impact Map" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock Text="Search flows for references to queues, data actions, and other objects" Margin="0,4,0,0" Foreground="#FF6B7280"/>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="Object Type:" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <ComboBox x:Name="CmbObjectType" Width="120" Height="26" Margin="0,0,8,0" SelectedIndex="0">
            <ComboBoxItem Content="Queue"/>
            <ComboBoxItem Content="Data Action"/>
            <ComboBoxItem Content="Schedule"/>
            <ComboBoxItem Content="Skill"/>
          </ComboBox>
          <TextBox x:Name="TxtObjectId" Width="300" Height="26" Margin="0,0,8,0" Text="Enter object ID..."/>
          <Button x:Name="BtnSearchReferences" Content="Search" Width="100" Height="32" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Flow References" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock x:Name="TxtReferenceCount" Text="(0 flows)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
          <Button x:Name="BtnExportReferences" Content="Export JSON" Width="100" Height="26" Margin="12,0,0,0" IsEnabled="False"/>
        </StackPanel>

        <DataGrid x:Name="GridReferences" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Flow Name" Binding="{Binding FlowName}" Width="250"/>
            <DataGridTextColumn Header="Flow Type" Binding="{Binding FlowType}" Width="150"/>
            <DataGridTextColumn Header="Division" Binding="{Binding Division}" Width="150"/>
            <DataGridTextColumn Header="Published" Binding="{Binding Published}" Width="100"/>
            <DataGridTextColumn Header="Occurrences" Binding="{Binding Occurrences}" Width="120"/>
            <DataGridTextColumn Header="Flow ID" Binding="{Binding FlowId}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    CmbObjectType        = $view.FindName('CmbObjectType')
    TxtObjectId          = $view.FindName('TxtObjectId')
    BtnSearchReferences  = $view.FindName('BtnSearchReferences')
    TxtReferenceCount    = $view.FindName('TxtReferenceCount')
    BtnExportReferences  = $view.FindName('BtnExportReferences')
    GridReferences       = $view.FindName('GridReferences')
  }

  Enable-PrimaryActionButtons -Handles $h


  $script:DependencyReferencesData = @()

  # Search button click handler
  $h.BtnSearchReferences.Add_Click({
    $objectId = $h.TxtObjectId.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($objectId) -or $objectId -eq "Enter object ID...") {
      [System.Windows.MessageBox]::Show("Please enter an object ID to search.", "Missing Input",
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
      return
    }

    $objectType = switch ($h.CmbObjectType.SelectedIndex) {
      0 { "queue" }
      1 { "dataAction" }
      2 { "schedule" }
      3 { "skill" }
      default { "queue" }
    }

    Set-Status "Searching for references to $objectType $objectId..."
    Set-ControlEnabled -Control $h.BtnSearchReferences -Enabled ($false)
    Set-ControlEnabled -Control $h.BtnExportReferences -Enabled ($false)

    $coreDepsPath = Join-Path -Path $coreRoot -ChildPath 'Dependencies.psm1'
    $coreHttpPath = Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1'

    Start-AppJob -Name "Search Flow References" -Type "Query" -ScriptBlock {
      param($depsPath, $httpPath, $accessToken, $region, $objId, $objType)

      Import-Module $httpPath -Force
      Import-Module $depsPath -Force

      Search-GcFlowReferences -ObjectId $objId -ObjectType $objType `
        -AccessToken $accessToken -InstanceName $region
    } -ArgumentList @($coreDepsPath, $coreHttpPath, $script:AppState.AccessToken, $script:AppState.Region, $objectId, $objectType) -OnCompleted {
      param($job)
      Set-ControlEnabled -Control $h.BtnSearchReferences -Enabled ($true)

      if ($job.Result -and $job.Result.Count -gt 0) {
        $script:DependencyReferencesData = $job.Result

        $displayData = $job.Result | ForEach-Object {
          [PSCustomObject]@{
            FlowName = $_.flowName
            FlowType = $_.flowType
            Division = $_.division
            Published = if ($_.published) { "Yes" } else { "No" }
            Occurrences = $_.occurrences
            FlowId = $_.flowId
          }
        }

        $h.GridReferences.ItemsSource = $displayData
        $h.TxtReferenceCount.Text = "($($job.Result.Count) flows)"
        Set-ControlEnabled -Control $h.BtnExportReferences -Enabled ($true)
        Set-Status "Found $($job.Result.Count) flows referencing $objectType $objectId."
      } else {
        $h.GridReferences.ItemsSource = @()
        $h.TxtReferenceCount.Text = "(0 flows)"
        Set-Status "No flow references found for $objectType $objectId."
      }
    }
  })

  # Export button click handler
  $h.BtnExportReferences.Add_Click({
    if (-not $script:DependencyReferencesData -or $script:DependencyReferencesData.Count -eq 0) {
      Set-Status "No references to export."
      return
    }

    $objectId = $h.TxtObjectId.Text.Trim()
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "dependencies_${objectId}_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $exportData = @{
        objectId = $objectId
        objectType = switch ($h.CmbObjectType.SelectedIndex) {
          0 { "queue" }
          1 { "dataAction" }
          2 { "schedule" }
          3 { "skill" }
          default { "queue" }
        }
        references = $script:DependencyReferencesData
        timestamp = (Get-Date).ToString('o')
      }

      $exportData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported dependency map to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  # Object ID textbox focus handlers
  $h.TxtObjectId.Add_GotFocus({
    if ($h.TxtObjectId.Text -eq "Enter object ID...") {
      $h.TxtObjectId.Text = ""
    }
  }.GetNewClosure())

  $h.TxtObjectId.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtObjectId.Text)) {
      $h.TxtObjectId.Text = "Enter object ID..."
    }
  }.GetNewClosure())

  return $view
}

function New-QueuesView {
  <#
  .SYNOPSIS
    Creates the Queues module view with load, search, and export capabilities.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Routing Queues" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock Text="View and export routing queues" Margin="0,4,0,0" Foreground="#FF6B7280"/>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnQueueLoad" Content="Load Queues" Width="110" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnQueueExportJson" Content="Export JSON" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnQueueExportCsv" Content="Export CSV" Width="100" Height="32" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Queues" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBox x:Name="TxtQueueSearch" Margin="12,0,0,0" Width="300" Height="26" Text="Search queues..."/>
          <TextBlock x:Name="TxtQueueCount" Text="(0 queues)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
        </StackPanel>

        <DataGrid x:Name="GridQueues" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="250"/>
            <DataGridTextColumn Header="Division" Binding="{Binding Division}" Width="180"/>
            <DataGridTextColumn Header="Members" Binding="{Binding Members}" Width="100"/>
            <DataGridTextColumn Header="Active" Binding="{Binding Active}" Width="80"/>
            <DataGridTextColumn Header="Modified" Binding="{Binding Modified}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    BtnQueueLoad        = $view.FindName('BtnQueueLoad')
    BtnQueueExportJson  = $view.FindName('BtnQueueExportJson')
    BtnQueueExportCsv   = $view.FindName('BtnQueueExportCsv')
    TxtQueueSearch      = $view.FindName('TxtQueueSearch')
    TxtQueueCount       = $view.FindName('TxtQueueCount')
    GridQueues          = $view.FindName('GridQueues')
  }

  Enable-PrimaryActionButtons -Handles $h


  $queuesData = @()

  $h.BtnQueueLoad.Add_Click({
    Set-Status "Loading queues..."
    Set-ControlEnabled -Control $h.BtnQueueLoad -Enabled $false
    Set-ControlEnabled -Control $h.BtnQueueExportJson -Enabled $false
    Set-ControlEnabled -Control $h.BtnQueueExportCsv -Enabled $false

    Start-AppJob -Name "Load Queues" -Type "Query" -ScriptBlock {
      Get-GcQueues -AccessToken $script:AppState.AccessToken -InstanceName $script:AppState.Region
    } -OnCompleted ({
      param($job)
      Set-ControlEnabled -Control $h.BtnQueueLoad -Enabled $true

      if ($job.Result) {
        $queuesData = @($job.Result)
        $displayData = $job.Result | ForEach-Object {
          [PSCustomObject]@{
            Name = if ($_.name) { $_.name } else { 'N/A' }
            Division = if ($_.division -and $_.division.name) { $_.division.name } else { 'N/A' }
            Members = if ($_.memberCount) { $_.memberCount } else { 0 }
            Active = if ($_.mediaSettings) { 'Yes' } else { 'No' }
            Modified = if ($_.dateModified) { $_.dateModified } else { '' }
          }
        }
        $h.GridQueues.ItemsSource = $displayData
        $h.TxtQueueCount.Text = "($($job.Result.Count) queues)"
        Set-ControlEnabled -Control $h.BtnQueueExportJson -Enabled $true
        Set-ControlEnabled -Control $h.BtnQueueExportCsv -Enabled $true
        Set-Status "Loaded $($job.Result.Count) queues."
      } else {
        $h.GridQueues.ItemsSource = @()
        $h.TxtQueueCount.Text = "(0 queues)"
        Set-Status "Failed to load queues."
      }
    }.GetNewClosure())
  }.GetNewClosure())

  $h.BtnQueueExportJson.Add_Click({
    if (-not $queuesData -or $queuesData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "queues_$timestamp.json"
    $artifactsDir = $global:ArtifactsDir
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $queuesData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($queuesData.Count) queues to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }.GetNewClosure()
    } catch {
      Set-Status "Failed to export: $_"
    }
  }.GetNewClosure())

  $h.BtnQueueExportCsv.Add_Click({
    if (-not $queuesData -or $queuesData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "queues_$timestamp.csv"
    $artifactsDir = $global:ArtifactsDir
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $queuesData | Select-Object name, @{N='division';E={if($_.division.name){$_.division.name}else{'N/A'}}}, memberCount, dateModified |
        Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      Set-Status "Exported $($queuesData.Count) queues to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }.GetNewClosure()
    } catch {
      Set-Status "Failed to export: $_"
    }
  }.GetNewClosure())

  $h.TxtQueueSearch.Add_TextChanged({
    if (-not $queuesData -or $queuesData.Count -eq 0) { return }

    $searchText = $h.TxtQueueSearch.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "search queues...") {
      $displayData = $queuesData | ForEach-Object {
        [PSCustomObject]@{
          Name = if ($_.name) { $_.name } else { 'N/A' }
          Division = if ($_.division -and $_.division.name) { $_.division.name } else { 'N/A' }
          Members = if ($_.memberCount) { $_.memberCount } else { 0 }
          Active = if ($_.mediaSettings) { 'Yes' } else { 'No' }
          Modified = if ($_.dateModified) { $_.dateModified } else { '' }
        }
      }
      $h.GridQueues.ItemsSource = $displayData
      $h.TxtQueueCount.Text = "($($queuesData.Count) queues)"
      return
    }

    $filtered = $queuesData | Where-Object {
      $json = ($_ | ConvertTo-Json -Compress -Depth 5).ToLower()
      $json -like "*$searchText*"
    }

    $displayData = $filtered | ForEach-Object {
      [PSCustomObject]@{
        Name = if ($_.name) { $_.name } else { 'N/A' }
        Division = if ($_.division -and $_.division.name) { $_.division.name } else { 'N/A' }
        Members = if ($_.memberCount) { $_.memberCount } else { 0 }
        Active = if ($_.mediaSettings) { 'Yes' } else { 'No' }
        Modified = if ($_.dateModified) { $_.dateModified } else { '' }
      }
    }

    $h.GridQueues.ItemsSource = $displayData
    $h.TxtQueueCount.Text = "($($filtered.Count) queues)"
  }.GetNewClosure())

  $h.TxtQueueSearch.Add_GotFocus({
    if ($h.TxtQueueSearch.Text -eq "Search queues...") {
      $h.TxtQueueSearch.Text = ""
    }
  }.GetNewClosure())

  $h.TxtQueueSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtQueueSearch.Text)) {
      $h.TxtQueueSearch.Text = "Search queues..."
    }
  }.GetNewClosure())

  return $view
}

function New-SkillsView {
  <#
  .SYNOPSIS
    Creates the Skills (ACD Skills) module view with load, search, and export capabilities.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="ACD Skills" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock Text="View and export routing skills" Margin="0,4,0,0" Foreground="#FF6B7280"/>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnSkillLoad" Content="Load Skills" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnSkillExportJson" Content="Export JSON" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnSkillExportCsv" Content="Export CSV" Width="100" Height="32" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Skills" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBox x:Name="TxtSkillSearch" Margin="12,0,0,0" Width="300" Height="26" Text="Search skills..."/>
          <TextBlock x:Name="TxtSkillCount" Text="(0 skills)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
        </StackPanel>

        <DataGrid x:Name="GridSkills" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="300"/>
            <DataGridTextColumn Header="State" Binding="{Binding State}" Width="120"/>
            <DataGridTextColumn Header="Modified" Binding="{Binding Modified}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    BtnSkillLoad        = $view.FindName('BtnSkillLoad')
    BtnSkillExportJson  = $view.FindName('BtnSkillExportJson')
    BtnSkillExportCsv   = $view.FindName('BtnSkillExportCsv')
    TxtSkillSearch      = $view.FindName('TxtSkillSearch')
    TxtSkillCount       = $view.FindName('TxtSkillCount')
    GridSkills          = $view.FindName('GridSkills')
  }

  Enable-PrimaryActionButtons -Handles $h


  $skillsData = @()

  $h.BtnSkillLoad.Add_Click({
    Set-Status "Loading skills..."
    Set-ControlEnabled -Control $h.BtnSkillLoad -Enabled $false
    Set-ControlEnabled -Control $h.BtnSkillExportJson -Enabled $false
    Set-ControlEnabled -Control $h.BtnSkillExportCsv -Enabled $false

    Start-AppJob -Name "Load Skills" -Type "Query" -ScriptBlock {
      Get-GcSkills -AccessToken $script:AppState.AccessToken -InstanceName $script:AppState.Region
    } -OnCompleted ({
      param($job)
      Set-ControlEnabled -Control $h.BtnSkillLoad -Enabled $true

      if ($job.Result) {
        $skillsData = @($job.Result)
        $displayData = $job.Result | ForEach-Object {
          [PSCustomObject]@{
            Name = if ($_.name) { $_.name } else { 'N/A' }
            State = if ($_.state) { $_.state } else { 'active' }
            Modified = if ($_.dateModified) { $_.dateModified } else { '' }
          }
        }
        $h.GridSkills.ItemsSource = $displayData
        $h.TxtSkillCount.Text = "($($job.Result.Count) skills)"
        Set-ControlEnabled -Control $h.BtnSkillExportJson -Enabled $true
        Set-ControlEnabled -Control $h.BtnSkillExportCsv -Enabled $true
        Set-Status "Loaded $($job.Result.Count) skills."
      } else {
        $h.GridSkills.ItemsSource = @()
        $h.TxtSkillCount.Text = "(0 skills)"
        Set-Status "Failed to load skills."
      }
    }.GetNewClosure())
  }.GetNewClosure())

  $h.BtnSkillExportJson.Add_Click({
    if (-not $skillsData -or $skillsData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "skills_$timestamp.json"
    $artifactsDir = $global:ArtifactsDir
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $skillsData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($skillsData.Count) skills to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }.GetNewClosure()
    } catch {
      Set-Status "Failed to export: $_"
    }
  }.GetNewClosure())

  $h.BtnSkillExportCsv.Add_Click({
    if (-not $skillsData -or $skillsData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "skills_$timestamp.csv"
    $artifactsDir = $global:ArtifactsDir
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $skillsData | Select-Object name, state, dateModified |
        Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      Set-Status "Exported $($skillsData.Count) skills to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }.GetNewClosure()
    } catch {
      Set-Status "Failed to export: $_"
    }
  }.GetNewClosure())

  $h.TxtSkillSearch.Add_TextChanged({
    if (-not $skillsData -or $skillsData.Count -eq 0) { return }

    $searchText = $h.TxtSkillSearch.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "search skills...") {
      $displayData = $skillsData | ForEach-Object {
        [PSCustomObject]@{
          Name = if ($_.name) { $_.name } else { 'N/A' }
          State = if ($_.state) { $_.state } else { 'active' }
          Modified = if ($_.dateModified) { $_.dateModified } else { '' }
        }
      }
      $h.GridSkills.ItemsSource = $displayData
      $h.TxtSkillCount.Text = "($($skillsData.Count) skills)"
      return
    }

    $filtered = $skillsData | Where-Object {
      $json = ($_ | ConvertTo-Json -Compress -Depth 5).ToLower()
      $json -like "*$searchText*"
    }

    $displayData = $filtered | ForEach-Object {
      [PSCustomObject]@{
        Name = if ($_.name) { $_.name } else { 'N/A' }
        State = if ($_.state) { $_.state } else { 'active' }
        Modified = if ($_.dateModified) { $_.dateModified } else { '' }
      }
    }

    $h.GridSkills.ItemsSource = $displayData
    $h.TxtSkillCount.Text = "($($filtered.Count) skills)"
  }.GetNewClosure())

  $h.TxtSkillSearch.Add_GotFocus({
    if ($h.TxtSkillSearch.Text -eq "Search skills...") {
      $h.TxtSkillSearch.Text = ""
    }
  }.GetNewClosure())

  $h.TxtSkillSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtSkillSearch.Text)) {
      $h.TxtSkillSearch.Text = "Search skills..."
    }
  }.GetNewClosure())

  return $view
}

function New-RoutingSnapshotView {
  <#
  .SYNOPSIS
    Creates the Routing Snapshot module view with real-time queue metrics and health indicators.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Routing Snapshot" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock Text="Real-time queue metrics and routing health indicators" Margin="0,4,0,0" Foreground="#FF6B7280"/>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnSnapshotRefresh" Content="Refresh Now" Width="110" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnSnapshotExport" Content="Export JSON" Width="100" Height="32" IsEnabled="False"/>
          <CheckBox x:Name="ChkAutoRefresh" Content="Auto-refresh (30s)" VerticalAlignment="Center" Margin="8,0,0,0" IsChecked="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Queue Metrics" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock x:Name="TxtSnapshotTimestamp" Text="" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
          <TextBlock x:Name="TxtSnapshotCount" Text="(0 queues)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
        </StackPanel>

        <DataGrid x:Name="GridSnapshot" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Queue" Binding="{Binding QueueName}" Width="200"/>
            <DataGridTextColumn Header="Status" Binding="{Binding HealthStatusDisplay}" Width="80"/>
            <DataGridTextColumn Header="On Queue" Binding="{Binding AgentsOnQueue}" Width="100"/>
            <DataGridTextColumn Header="Available" Binding="{Binding AgentsAvailable}" Width="100"/>
            <DataGridTextColumn Header="Active" Binding="{Binding InteractionsActive}" Width="100"/>
            <DataGridTextColumn Header="Waiting" Binding="{Binding InteractionsWaiting}" Width="100"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    BtnSnapshotRefresh  = $view.FindName('BtnSnapshotRefresh')
    BtnSnapshotExport   = $view.FindName('BtnSnapshotExport')
    ChkAutoRefresh      = $view.FindName('ChkAutoRefresh')
    TxtSnapshotTimestamp = $view.FindName('TxtSnapshotTimestamp')
    TxtSnapshotCount    = $view.FindName('TxtSnapshotCount')
    GridSnapshot        = $view.FindName('GridSnapshot')
  }

  Enable-PrimaryActionButtons -Handles $h


  $script:RoutingSnapshotData = $null
  $script:RoutingSnapshotTimer = $null

  # Function to refresh snapshot
  $refreshSnapshot = {
    Set-Status "Refreshing routing snapshot..."
    Set-ControlEnabled -Control $h.BtnSnapshotRefresh -Enabled ($false)

    $coreModulePath = Join-Path -Path $coreRoot -ChildPath 'RoutingPeople.psm1'
    $httpModulePath = Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1'

    Start-AppJob -Name "Refresh Routing Snapshot" -Type "Query" -ScriptBlock {
      param($coreModulePath, $httpModulePath, $accessToken, $region)

      Import-Module $httpModulePath -Force
      Import-Module $coreModulePath -Force

      Get-GcRoutingSnapshot -AccessToken $accessToken -InstanceName $region
    } -ArgumentList @($coreModulePath, $httpModulePath, $script:AppState.AccessToken, $script:AppState.Region) -OnCompleted {
      param($job)
      Set-ControlEnabled -Control $h.BtnSnapshotRefresh -Enabled ($true)

      if ($job.Result -and $job.Result.queues) {
        $script:RoutingSnapshotData = $job.Result

        $displayData = $job.Result.queues | ForEach-Object {
          [PSCustomObject]@{
            QueueName = $_.queueName
            HealthStatusDisplay = switch($_.healthStatus) {
              'green' { '🟢 Good' }
              'yellow' { '🟡 Warning' }
              'red' { '🔴 Critical' }
              default { '⚪ Unknown' }
            }
            AgentsOnQueue = $_.agentsOnQueue
            AgentsAvailable = $_.agentsAvailable
            InteractionsActive = $_.interactionsActive
            InteractionsWaiting = $_.interactionsWaiting
          }
        }

        $h.GridSnapshot.ItemsSource = $displayData
        $h.TxtSnapshotCount.Text = "($($job.Result.queues.Count) queues)"

        try {
          $timestamp = [DateTime]::Parse($job.Result.timestamp)
          $h.TxtSnapshotTimestamp.Text = "Last updated: " + $timestamp.ToLocalTime().ToString('HH:mm:ss')
        } catch {
          $h.TxtSnapshotTimestamp.Text = "Last updated: just now"
        }

        Set-ControlEnabled -Control $h.BtnSnapshotExport -Enabled ($true)
        Set-Status "Routing snapshot refreshed successfully."
      } else {
        $h.GridSnapshot.ItemsSource = @()
        $h.TxtSnapshotCount.Text = "(0 queues)"
        $h.TxtSnapshotTimestamp.Text = ""
        Set-Status "Failed to refresh routing snapshot."
      }
    }
  }

  # Refresh button click handler
  $h.BtnSnapshotRefresh.Add_Click($refreshSnapshot)

  # Export button click handler
  $h.BtnSnapshotExport.Add_Click({
    if (-not $script:RoutingSnapshotData) {
      Set-Status "No snapshot data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "routing_snapshot_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:RoutingSnapshotData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported routing snapshot to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  # Auto-refresh checkbox handler
  $h.ChkAutoRefresh.Add_Checked({
    # Create timer for auto-refresh every 30 seconds
    $script:RoutingSnapshotTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:RoutingSnapshotTimer.Interval = [TimeSpan]::FromSeconds(30)
    $script:RoutingSnapshotTimer.Add_Tick($refreshSnapshot)
    $script:RoutingSnapshotTimer.Start()
    Set-Status "Auto-refresh enabled (30 seconds)."
  })

  $h.ChkAutoRefresh.Add_Unchecked({
    if ($script:RoutingSnapshotTimer) {
      $script:RoutingSnapshotTimer.Stop()
      $script:RoutingSnapshotTimer = $null
    }
    Set-Status "Auto-refresh disabled."
  })

  # Cleanup when view is unloaded
  $view.Add_Unloaded({
    if ($script:RoutingSnapshotTimer) {
      $script:RoutingSnapshotTimer.Stop()
      $script:RoutingSnapshotTimer = $null
    }
  })

  return $view
}

function New-UsersPresenceView {
  <#
  .SYNOPSIS
    Creates the Users & Presence module view with user management and presence monitoring.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Users &amp; Presence" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock Text="View users, monitor presence status, and manage routing" Margin="0,4,0,0" Foreground="#FF6B7280"/>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnUserLoad" Content="Load Users" Width="110" Height="32" Margin="0,0,8,0"/>
          <Button x:Name="BtnUserExportJson" Content="Export JSON" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnUserExportCsv" Content="Export CSV" Width="100" Height="32" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Users" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBox x:Name="TxtUserSearch" Margin="12,0,0,0" Width="300" Height="26" Text="Search users..."/>
          <TextBlock x:Name="TxtUserCount" Text="(0 users)" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7280"/>
        </StackPanel>

        <DataGrid x:Name="GridUsers" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="200"/>
            <DataGridTextColumn Header="Email" Binding="{Binding Email}" Width="250"/>
            <DataGridTextColumn Header="Division" Binding="{Binding Division}" Width="150"/>
            <DataGridTextColumn Header="State" Binding="{Binding State}" Width="100"/>
            <DataGridTextColumn Header="Username" Binding="{Binding Username}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    BtnUserLoad        = $view.FindName('BtnUserLoad')
    BtnUserExportJson  = $view.FindName('BtnUserExportJson')
    BtnUserExportCsv   = $view.FindName('BtnUserExportCsv')
    TxtUserSearch      = $view.FindName('TxtUserSearch')
    TxtUserCount       = $view.FindName('TxtUserCount')
    GridUsers          = $view.FindName('GridUsers')
  }

  Enable-PrimaryActionButtons -Handles $h


  $script:UsersData = @()

  $h.BtnUserLoad.Add_Click({
    Set-Status "Loading users..."
    Set-ControlEnabled -Control $h.BtnUserLoad -Enabled ($false)
    Set-ControlEnabled -Control $h.BtnUserExportJson -Enabled ($false)
    Set-ControlEnabled -Control $h.BtnUserExportCsv -Enabled ($false)

    Start-AppJob -Name "Load Users" -Type "Query" -ScriptBlock {
      param($accessToken, $instanceName)

      Get-GcUsers -AccessToken $accessToken -InstanceName $instanceName
    } -ArgumentList @($script:AppState.AccessToken, $script:AppState.Region) -OnCompleted {
      param($job)
      Set-ControlEnabled -Control $h.BtnUserLoad -Enabled ($true)

      if ($job.Result) {
        $script:UsersData = $job.Result
        $displayData = $job.Result | ForEach-Object {
          [PSCustomObject]@{
            Name = if ($_.name) { $_.name } else { 'N/A' }
            Email = if ($_.email) { $_.email } else { 'N/A' }
            Division = if ($_.division -and $_.division.name) { $_.division.name } else { 'N/A' }
            State = if ($_.state) { $_.state } else { 'N/A' }
            Username = if ($_.username) { $_.username } else { 'N/A' }
          }
        }
        $h.GridUsers.ItemsSource = $displayData
        $h.TxtUserCount.Text = "($($job.Result.Count) users)"
        Set-ControlEnabled -Control $h.BtnUserExportJson -Enabled ($true)
        Set-ControlEnabled -Control $h.BtnUserExportCsv -Enabled ($true)
        Set-Status "Loaded $($job.Result.Count) users."
      } else {
        $h.GridUsers.ItemsSource = @()
        $h.TxtUserCount.Text = "(0 users)"
        Set-Status "Failed to load users."
      }
    }
  })

  $h.BtnUserExportJson.Add_Click({
    if (-not $script:UsersData -or $script:UsersData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "users_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:UsersData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($script:UsersData.Count) users to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  $h.BtnUserExportCsv.Add_Click({
    if (-not $script:UsersData -or $script:UsersData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "users_$timestamp.csv"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:UsersData | Select-Object name, email, username, state, @{N='division';E={if($_.division.name){$_.division.name}else{'N/A'}}} |
        Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      Set-Status "Exported $($script:UsersData.Count) users to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  $h.TxtUserSearch.Add_TextChanged({
    if (-not $script:UsersData -or $script:UsersData.Count -eq 0) { return }

    $searchText = $h.TxtUserSearch.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "search users...") {
      $displayData = $script:UsersData | ForEach-Object {
        [PSCustomObject]@{
          Name = if ($_.name) { $_.name } else { 'N/A' }
          Email = if ($_.email) { $_.email } else { 'N/A' }
          Division = if ($_.division -and $_.division.name) { $_.division.name } else { 'N/A' }
          State = if ($_.state) { $_.state } else { 'N/A' }
          Username = if ($_.username) { $_.username } else { 'N/A' }
        }
      }
      $h.GridUsers.ItemsSource = $displayData
      $h.TxtUserCount.Text = "($($script:UsersData.Count) users)"
      return
    }

    $filtered = $script:UsersData | Where-Object {
      $json = ($_ | ConvertTo-Json -Compress -Depth 5).ToLower()
      $json -like "*$searchText*"
    }

    $displayData = $filtered | ForEach-Object {
      [PSCustomObject]@{
        Name = if ($_.name) { $_.name } else { 'N/A' }
        Email = if ($_.email) { $_.email } else { 'N/A' }
        Division = if ($_.division -and $_.division.name) { $_.division.name } else { 'N/A' }
        State = if ($_.state) { $_.state } else { 'N/A' }
        Username = if ($_.username) { $_.username } else { 'N/A' }
      }
    }

    $h.GridUsers.ItemsSource = $displayData
    $h.TxtUserCount.Text = "($($filtered.Count) users)"
  })

  $h.TxtUserSearch.Add_GotFocus({
    if ($h.TxtUserSearch.Text -eq "Search users...") {
      $h.TxtUserSearch.Text = ""
    }
  }.GetNewClosure())

  $h.TxtUserSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtUserSearch.Text)) {
      $h.TxtUserSearch.Text = "Search users..."
    }
  }.GetNewClosure())

  return $view
}

function New-SubscriptionsView {
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Topic Subscriptions" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
            <TextBlock Text="Topics:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <CheckBox x:Name="ChkTranscription" Content="AudioHook Transcription" IsChecked="True" Margin="0,0,10,0"/>
            <CheckBox x:Name="ChkAgentAssist" Content="Google Agent Assist" IsChecked="True" Margin="0,0,10,0"/>
            <CheckBox x:Name="ChkErrors" Content="Errors" IsChecked="True"/>
          </StackPanel>

          <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
            <TextBlock Text="Queue:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBox x:Name="TxtQueue" Width="220" Height="26" Text="Support - Voice"/>
            <TextBlock Text="Severity:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <ComboBox x:Name="CmbSeverity" Width="120" Height="26" SelectedIndex="1">
              <ComboBoxItem Content="info+"/>
              <ComboBoxItem Content="warn+"/>
              <ComboBoxItem Content="error"/>
            </ComboBox>
            <TextBlock Text="ConversationId:" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <TextBox x:Name="TxtConv" Width="240" Height="26" Text="(optional)"/>
          </StackPanel>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnStart" Content="Start" Width="86" Height="32" Margin="0,0,8,0"/>
          <Button x:Name="BtnStop" Content="Stop" Width="86" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnOpenTimeline" Content="Open Timeline" Width="120" Height="32" Margin="0,0,8,0"/>
          <Button x:Name="BtnExportPacket" Content="Export Packet" Width="120" Height="32"/>
        </StackPanel>
      </Grid>
    </Border>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="460"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12" Margin="0,0,12,0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <StackPanel Orientation="Horizontal" Grid.Row="0">
            <TextBlock Text="Live Event Stream" FontWeight="SemiBold" Foreground="#FF111827"/>
            <TextBox x:Name="TxtSearch" Margin="12,0,0,0" Width="300" Height="26" Text="search (conversationId, error, agent…)"/>
            <Button x:Name="BtnPin" Content="Pin Selected" Width="110" Height="26" Margin="12,0,0,0"/>
          </StackPanel>

          <ListBox x:Name="LstEvents" Grid.Row="1" Margin="0,10,0,0"/>
        </Grid>
      </Border>

      <Border Grid.Column="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock Text="Transcript / Agent Assist" FontWeight="SemiBold" Foreground="#FF111827"/>

          <TextBox x:Name="TxtTranscript" Grid.Row="1" Margin="0,10,0,10"
                   AcceptsReturn="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"
                   Text="(When streaming, transcript snippets + Agent Assist hints appear here.)"/>

          <Border Grid.Row="2" Background="#FFF9FAFB" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="6" Padding="10">
            <StackPanel>
              <TextBlock Text="Agent Assist (mock cards)" FontWeight="SemiBold" Foreground="#FF111827"/>
              <TextBlock Text="• Suggestion: Verify identity (DOB + ZIP)" Margin="0,6,0,0" Foreground="#FF374151"/>
              <TextBlock Text="• Knowledge: Password Reset – Standard Flow" Margin="0,3,0,0" Foreground="#FF374151"/>
              <TextBlock Text="• Warning: Rising WebRTC disconnects in Support - Voice" Margin="0,3,0,0" Foreground="#FF374151"/>
            </StackPanel>
          </Border>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    ChkTranscription = $view.FindName('ChkTranscription')
    ChkAgentAssist   = $view.FindName('ChkAgentAssist')
    ChkErrors        = $view.FindName('ChkErrors')
    TxtQueue         = $view.FindName('TxtQueue')
    CmbSeverity      = $view.FindName('CmbSeverity')
    TxtConv          = $view.FindName('TxtConv')
    BtnStart         = $view.FindName('BtnStart')
    BtnStop          = $view.FindName('BtnStop')
    BtnOpenTimeline  = $view.FindName('BtnOpenTimeline')
    BtnExportPacket  = $view.FindName('BtnExportPacket')
    TxtSearch        = $view.FindName('TxtSearch')
    BtnPin           = $view.FindName('BtnPin')
    LstEvents        = $view.FindName('LstEvents')
    TxtTranscript    = $view.FindName('TxtTranscript')
  }

  Enable-PrimaryActionButtons -Handles $h


  # Streaming timer (simulated AudioHook / Agent Assist)
  if (Get-Variable -Name StreamTimer -Scope Script -ErrorAction SilentlyContinue) {
    if ($null -ne $script:StreamTimer) {
      $script:StreamTimer.Stop() | Out-Null
    }
  }

  $script:StreamTimer = New-Object Windows.Threading.DispatcherTimer
  $script:StreamTimer.Interval = [TimeSpan]::FromMilliseconds(650)

  function Append-TranscriptLine([string]$line) {
    $h.TxtTranscript.AppendText("$line`r`n")
    $h.TxtTranscript.ScrollToEnd()
  }

  function New-MockEvent {
    $conv = if ($h.TxtConv.Text -and $h.TxtConv.Text -ne '(optional)') { $h.TxtConv.Text } else { "c-$(Get-Random -Minimum 100000 -Maximum 999999)" }

    $types = @(
      'audiohook.transcription.partial',
      'audiohook.transcription.final',
      'audiohook.agentassist.suggestion',
      'audiohook.error'
    )

    $allowed = @()
    if ($h.ChkTranscription.IsChecked) { $allowed += $types | Where-Object { $_ -like 'audiohook.transcription*' } }
    if ($h.ChkAgentAssist.IsChecked)   { $allowed += $types | Where-Object { $_ -like 'audiohook.agentassist*' } }
    if ($h.ChkErrors.IsChecked)        { $allowed += $types | Where-Object { $_ -eq 'audiohook.error' } }
    if (-not $allowed) { $allowed = $types }

    $etype = $allowed | Get-Random
    $sev = switch ($etype) {
      'audiohook.error' { 'error' }
      'audiohook.agentassist.suggestion' { 'info' }
      default { 'warn' }
    }

    $snips = @(
      "Caller: I'm having trouble logging in.",
      "Agent: Can you confirm your account number?",
      "Caller: It says my password is incorrect.",
      "Agent: Let's do a reset — do you have email access?",
      "Agent Assist: Ask for DOB + ZIP to verify identity.",
      "Agent Assist: Surface KB: Password Reset — Standard Flow.",
      "ERROR: Transcription upstream timeout (HTTP 504)."
    )

    $text = ($snips | Get-Random)
    $ts = Get-Date
    $queueName = $h.TxtQueue.Text

    # Create raw data object (simulates original parsed JSON)
    $raw = @{
      eventId = [guid]::NewGuid().ToString()
      timestamp = $ts.ToString('o')
      topicName = $etype
      eventBody = @{
        conversationId = $conv
        text = $text
        severity = $sev
        queueName = $queueName
      }
    }

    # Pre-calculate cached JSON for search performance
    $cachedJson = ''
    try {
      $cachedJson = ($raw | ConvertTo-Json -Compress -Depth 10).ToLower()
    } catch {
      # If JSON conversion fails, use empty string
    }

    # Return structured event object with consistent schema
    [pscustomobject]@{
      ts = $ts
      severity = $sev
      topic = $etype
      conversationId = $conv
      queueId = $null
      queueName = $queueName
      text = $text
      raw = $raw
      _cachedRawJson = $cachedJson
    }
  }

  $script:StreamTimer.Add_Tick({
    if (-not $script:AppState.IsStreaming) { return }

    $evt = New-MockEvent

    # Store in EventBuffer for export
    $script:AppState.EventBuffer.Insert(0, $evt)

    # Format for display and add to ListBox with object as Tag
    $listItem = New-Object System.Windows.Controls.ListBoxItem
    $listItem.Content = Format-EventSummary -Event $evt
    $listItem.Tag = $evt
    $h.LstEvents.Items.Insert(0, $listItem) | Out-Null

    # Update transcript panel
    $tsStr = $evt.ts.ToString('HH:mm:ss.fff')
    if ($evt.topic -like 'audiohook.transcription*') { Append-TranscriptLine "$tsStr  $($evt.text)" }
    if ($evt.topic -like 'audiohook.agentassist*')   { Append-TranscriptLine "$tsStr  [Agent Assist] $($evt.text)" }
    if ($evt.topic -eq 'audiohook.error')            { Append-TranscriptLine "$tsStr  [ERROR] $($evt.text)" }

    $script:AppState.StreamCount++
    Refresh-HeaderStats

    # Limit list size (keep most recent 250 events)
    if ($h.LstEvents.Items.Count -gt 250) {
      $h.LstEvents.Items.RemoveAt($h.LstEvents.Items.Count - 1)
    }

    # Limit EventBuffer size
    if ($script:AppState.EventBuffer.Count -gt 1000) {
      $script:AppState.EventBuffer.RemoveAt($script:AppState.EventBuffer.Count - 1)
    }
  })
  $script:StreamTimer.Start()

  # Actions
  $h.BtnStart.Add_Click({
    if ($script:AppState.IsStreaming) { return }

    Start-AppJob -Name "Connect subscription (AudioHook / Agent Assist)" -Type 'Subscription' -ScriptBlock {
      # Simulate subscription connection work
      Start-Sleep -Milliseconds 1200
      return @{ Success = $true; Message = "Subscription connected" }
    } -OnCompleted {
      param($job)
      $script:AppState.IsStreaming = $true
      Set-ControlEnabled -Control $h.BtnStart -Enabled ($false)
      Set-ControlEnabled -Control $h.BtnStop -Enabled ($true)
      Set-Status "Subscription started."
      Refresh-HeaderStats
    } | Out-Null

    Refresh-HeaderStats
  })

  $h.BtnStop.Add_Click({
    if (-not $script:AppState.IsStreaming) { return }

    Start-AppJob -Name "Disconnect subscription" -Type 'Subscription' -ScriptBlock {
      # Simulate subscription disconnection work
      Start-Sleep -Milliseconds 700
      return @{ Success = $true; Message = "Subscription disconnected" }
    } -OnCompleted {
      param($job)
      $script:AppState.IsStreaming = $false
      Set-ControlEnabled -Control $h.BtnStart -Enabled ($true)
      Set-ControlEnabled -Control $h.BtnStop -Enabled ($false)
      Set-Status "Subscription stopped."
      Refresh-HeaderStats
    } | Out-Null

    Refresh-HeaderStats
  })

  $h.BtnPin.Add_Click({
    if ($h.LstEvents.SelectedItem) {
      $selectedItem = $h.LstEvents.SelectedItem

      # Get the event object from the ListBoxItem's Tag
      if ($selectedItem -is [System.Windows.Controls.ListBoxItem] -and $selectedItem.Tag) {
        $evt = $selectedItem.Tag

        # Check if already pinned (avoid duplicates)
        $alreadyPinned = $false
        foreach ($pinnedEvt in $script:AppState.PinnedEvents) {
          if ($pinnedEvt.raw.eventId -eq $evt.raw.eventId) {
            $alreadyPinned = $true
            break
          }
        }

        if (-not $alreadyPinned) {
          $script:AppState.PinnedEvents.Add($evt)
          $script:AppState.PinnedCount++
          Refresh-HeaderStats
          Set-Status "Pinned event: $($evt.topic) for conversation $($evt.conversationId)"
        } else {
          Set-Status "Event already pinned."
        }
      } else {
        Set-Status "Cannot pin event: invalid selection."
      }
    }
  })

  # Search box filtering
  $h.TxtSearch.Add_TextChanged({
    $searchText = $h.TxtSearch.Text

    # Skip filtering if placeholder text
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq 'search (conversationId, error, agent…)') {
      # Show all events
      foreach ($item in $h.LstEvents.Items) {
        if ($item -is [System.Windows.Controls.ListBoxItem]) {
          $item.Visibility = 'Visible'
        }
      }
      return
    }

    $searchLower = $searchText.ToLower()

    # Filter events
    foreach ($item in $h.LstEvents.Items) {
      if ($item -is [System.Windows.Controls.ListBoxItem] -and $item.Tag) {
        $evt = $item.Tag
        $shouldShow = $false

        # Search in conversationId
        if ($evt.conversationId -and $evt.conversationId.ToLower().Contains($searchLower)) {
          $shouldShow = $true
        }

        # Search in topic/type
        if (-not $shouldShow -and $evt.topic -and $evt.topic.ToLower().Contains($searchLower)) {
          $shouldShow = $true
        }

        # Search in severity
        if (-not $shouldShow -and $evt.severity -and $evt.severity.ToLower().Contains($searchLower)) {
          $shouldShow = $true
        }

        # Search in text
        if (-not $shouldShow -and $evt.text -and $evt.text.ToLower().Contains($searchLower)) {
          $shouldShow = $true
        }

        # Search in queueName
        if (-not $shouldShow -and $evt.queueName -and $evt.queueName.ToLower().Contains($searchLower)) {
          $shouldShow = $true
        }

        # Search in raw JSON (pre-cached during event creation for performance)
        if (-not $shouldShow -and $evt._cachedRawJson -and $evt._cachedRawJson.Contains($searchLower)) {
          $shouldShow = $true
        }

        $item.Visibility = if ($shouldShow) { 'Visible' } else { 'Collapsed' }
      }
    }
  })

  # Clear search placeholder on focus
  $h.TxtSearch.Add_GotFocus({
    if ($h.TxtSearch.Text -eq 'search (conversationId, error, agent…)') {
      Set-ControlValue -Control $h.TxtSearch -Value ''
    }
  }.GetNewClosure())

  # Restore search placeholder on lost focus if empty
  $h.TxtSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtSearch.Text)) {
      Set-ControlValue -Control $h.TxtSearch -Value 'search (conversationId, error, agent…)'
    }
  }.GetNewClosure())

  $h.BtnOpenTimeline.Add_Click({
    # Derive conversation ID from textbox first, then from selected event
    $conv = ''

    # Priority 1: Check conversationId textbox
    if ($h.TxtConv.Text -and $h.TxtConv.Text -ne '(optional)') {
      $conv = $h.TxtConv.Text.Trim()
    }

    # Priority 2: Infer from selected event
    if (-not $conv -and $h.LstEvents.SelectedItem) {
      if ($h.LstEvents.SelectedItem -is [System.Windows.Controls.ListBoxItem] -and $h.LstEvents.SelectedItem.Tag) {
        $evt = $h.LstEvents.SelectedItem.Tag
        $conv = $evt.conversationId
      } else {
        # Fallback: parse from string (for backward compatibility)
        $s = [string]$h.LstEvents.SelectedItem
        if ($s -match 'conv=(?<cid>c-\d+)\s') { $conv = $matches['cid'] }
      }
    }

    # Validate we have a conversation ID
    if (-not $conv) {
      [System.Windows.MessageBox]::Show(
        "Please enter a conversation ID or select an event from the stream.",
        "No Conversation ID",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )
      return
    }

    # Check if authenticated
    if (-not $script:AppState.AccessToken) {
      [System.Windows.MessageBox]::Show(
        "Please log in first to retrieve conversation details.",
        "Authentication Required",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )
      return
    }

    Set-Status "Retrieving timeline for conversation $conv..."

    # Start background job to retrieve and build timeline (using shared scriptblock)
    Start-AppJob -Name "Open Timeline - $conv" -Type 'Timeline' -ScriptBlock $script:TimelineJobScriptBlock -ArgumentList @($conv, $script:AppState.Region, $script:AppState.AccessToken, $script:AppState.EventBuffer) `
    -OnCompleted {
      param($job)

      if ($job.Result -and $job.Result.Timeline) {
        $result = $job.Result
        Set-Status "Timeline ready for conversation $($result.ConversationId) with $($result.Timeline.Count) events."

        # Show timeline window
        Show-TimelineWindow `
          -ConversationId $result.ConversationId `
          -TimelineEvents $result.Timeline `
          -SubscriptionEvents $result.SubscriptionEvents `
          -ConversationData $result.ConversationData
      } else {
        Set-Status "Failed to build timeline. See job logs for details."
        [System.Windows.MessageBox]::Show(
          "Failed to retrieve conversation timeline. Check job logs for details.",
          "Timeline Error",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Error
        )
      }
    }

    Refresh-HeaderStats
  })

  $h.BtnExportPacket.Add_Click({
    $conv = if ($h.TxtConv.Text -and $h.TxtConv.Text -ne '(optional)') { $h.TxtConv.Text } else { "c-$(Get-Random -Minimum 100000 -Maximum 999999)" }

    if (-not $script:AppState.AccessToken) {
      [System.Windows.MessageBox]::Show(
        "Please log in first to export real conversation data.",
        "Authentication Required",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )

      # Fallback to mock export using Start-AppJob
      Start-AppJob -Name "Export Incident Packet (Mock) — $conv" -Type 'Export' -ScriptBlock {
        param($conversationId, $artifactsDir)

        Start-Sleep -Milliseconds 1400

        $file = Join-Path -Path $artifactsDir -ChildPath "incident-packet-mock-$($conversationId)-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
        @(
          "Incident Packet (mock) — Subscription Evidence",
          "ConversationId: $conversationId",
          "Generated: $(Get-Date)",
          "",
          "NOTE: This is a mock packet. Log in to export real conversation data.",
          ""
        ) | Set-Content -Path $file -Encoding UTF8

        return $file
      } -ArgumentList @($conv, $script:ArtifactsDir) -OnCompleted {
        param($job)

        if ($job.Result) {
          $file = $job.Result
          Add-ArtifactAndNotify -Name "Incident Packet (Mock) — $conv" -Path $file -ToastTitle 'Export complete (mock)'
          Set-Status "Exported mock incident packet: $file"
        }
      } | Out-Null

      Refresh-HeaderStats
      return
    }

    # Real export using ArtifactGenerator with Start-AppJob
    Start-AppJob -Name "Export Incident Packet — $conv" -Type 'Export' -ScriptBlock {
      param($conversationId, $region, $accessToken, $artifactsDir, $eventBuffer)

      try {
        # Build subscription events from buffer
        $subscriptionEvents = $eventBuffer

        # Export packet
        $packet = Export-GcConversationPacket `
          -ConversationId $conversationId `
          -Region $region `
          -AccessToken $accessToken `
          -OutputDirectory $artifactsDir `
          -SubscriptionEvents $subscriptionEvents `
          -CreateZip

        return $packet
      } catch {
        Write-Error "Failed to export packet: $_"
        return $null
      }
    } -ArgumentList @($conv, $script:AppState.Region, $script:AppState.AccessToken, $script:ArtifactsDir, $script:AppState.EventBuffer) `
    -OnCompleted {
      param($job)

      if ($job.Result) {
        $packet = $job.Result
        $artifactPath = if ($packet.ZipPath) { $packet.ZipPath } else { $packet.PacketDirectory }
        $artifactName = "Incident Packet — $($packet.ConversationId)"

        Add-ArtifactAndNotify -Name $artifactName -Path $artifactPath -ToastTitle 'Export complete'
        Set-Status "Exported incident packet: $artifactPath"
      } else {
        Set-Status "Failed to export packet. See job logs for details."
      }
    }

    Refresh-HeaderStats
  })

  return $view
}

function New-ReportsExportsView {
  <#
  .SYNOPSIS
    Creates the Reports & Exports module view with template-driven report generation and artifact management.
  #>
  $xamlString = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="300"/>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="400"/>
    </Grid.ColumnDefinitions>

    <!-- LEFT: Template Picker -->
    <Border Grid.Column="0" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12" Margin="0,0,12,0">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Text="Report Templates" FontWeight="SemiBold" Foreground="#FF111827" FontSize="14"/>

        <TextBox x:Name="TxtTemplateSearch" Grid.Row="1" Height="28" Margin="0,8,0,0" Text="Search templates..."/>

        <ListBox x:Name="LstTemplates" Grid.Row="2" Margin="0,8,0,0" SelectionMode="Single"/>

        <Border Grid.Row="3" Background="#FFF9FAFB" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="6" Padding="10" Margin="0,8,0,0">
          <StackPanel>
            <TextBlock Text="Template Details" FontWeight="SemiBold" Foreground="#FF111827" FontSize="12"/>
            <TextBlock x:Name="TxtTemplateDescription" Text="Select a template to view details" Margin="0,6,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>

        <StackPanel Grid.Row="4" Margin="0,8,0,0">
          <Button x:Name="BtnLoadPreset" Content="Load Preset" Height="28" Margin="0,0,0,4"/>
          <Button x:Name="BtnSavePreset" Content="Save Preset" Height="28"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- MIDDLE: Parameters + Run Controls -->
    <Border Grid.Column="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12" Margin="0,0,12,0">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <TextBlock Text="Parameters" FontWeight="SemiBold" Foreground="#FF111827" FontSize="14"/>
          <Button x:Name="BtnRunReport" Grid.Column="1" Content="Run Report" Width="120" Height="32"/>
        </Grid>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,12,0,12">
          <StackPanel x:Name="PnlParameters"/>
        </ScrollViewer>

        <Border Grid.Row="2" Background="#FFF3F4F6" BorderBrush="#FFE5E7EB" BorderThickness="1" CornerRadius="6" Padding="10">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Preview" FontWeight="SemiBold" Foreground="#FF111827"/>
              <Button x:Name="BtnOpenInBrowser" Content="Open in Browser" Width="120" Height="24" Margin="12,0,0,0" IsEnabled="False"/>
            </StackPanel>

            <WebBrowser x:Name="WebPreview" Grid.Row="1" Height="200" Margin="0,8,0,0"/>
          </Grid>
        </Border>
      </Grid>
    </Border>

    <!-- RIGHT: Export Actions + Artifact Hub -->
    <Border Grid.Column="2" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <TextBlock Text="Export Actions" FontWeight="SemiBold" Foreground="#FF111827" FontSize="14"/>

        <StackPanel Grid.Row="1" Margin="0,12,0,0">
          <Button x:Name="BtnExportHtml" Content="Export HTML" Height="32" Margin="0,0,0,4" IsEnabled="False"/>
          <Button x:Name="BtnExportJson" Content="Export JSON" Height="32" Margin="0,0,0,4" IsEnabled="False"/>
          <Button x:Name="BtnExportCsv" Content="Export CSV" Height="32" Margin="0,0,0,4" IsEnabled="False"/>
          <Button x:Name="BtnExportExcel" Content="Export Excel" Height="32" Margin="0,0,0,8" IsEnabled="False"/>
          <Button x:Name="BtnCopyPath" Content="Copy Artifact Path" Height="28" Margin="0,0,0,4" IsEnabled="False"/>
          <Button x:Name="BtnOpenFolder" Content="Open Containing Folder" Height="28" IsEnabled="False"/>
        </StackPanel>

        <Border Grid.Row="2" CornerRadius="6" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="8" Margin="0,12,0,0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Artifact Hub" FontWeight="SemiBold" Foreground="#FF111827" FontSize="12"/>
              <Button x:Name="BtnRefreshArtifacts" Content="↻" Width="24" Height="24" Margin="8,0,0,0" ToolTip="Refresh artifact list"/>
            </StackPanel>

            <ListBox x:Name="LstArtifacts" Grid.Row="1" Margin="0,8,0,0">
              <ListBox.ItemTemplate>
                <DataTemplate>
                  <StackPanel Margin="0,0,0,8">
                    <TextBlock Text="{Binding DisplayName}" FontWeight="SemiBold" Foreground="#FF111827" FontSize="11"/>
                    <TextBlock Text="{Binding DisplayTime}" Foreground="#FF6B7280" FontSize="10"/>
                  </StackPanel>
                </DataTemplate>
              </ListBox.ItemTemplate>
              <ListBox.ContextMenu>
                <ContextMenu>
                  <MenuItem x:Name="MnuArtifactOpen" Header="Open HTML Report"/>
                  <MenuItem x:Name="MnuArtifactFolder" Header="Open Folder"/>
                  <MenuItem x:Name="MnuArtifactCopy" Header="Copy Path"/>
                  <Separator/>
                  <MenuItem x:Name="MnuArtifactDelete" Header="Delete"/>
                </ContextMenu>
              </ListBox.ContextMenu>
            </ListBox>
          </Grid>
        </Border>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    TxtTemplateSearch      = $view.FindName('TxtTemplateSearch')
    LstTemplates           = $view.FindName('LstTemplates')
    TxtTemplateDescription = $view.FindName('TxtTemplateDescription')
    BtnLoadPreset          = $view.FindName('BtnLoadPreset')
    BtnSavePreset          = $view.FindName('BtnSavePreset')
    PnlParameters          = $view.FindName('PnlParameters')
    BtnRunReport           = $view.FindName('BtnRunReport')
    WebPreview             = $view.FindName('WebPreview')
    BtnOpenInBrowser       = $view.FindName('BtnOpenInBrowser')
    BtnExportHtml          = $view.FindName('BtnExportHtml')
    BtnExportJson          = $view.FindName('BtnExportJson')
    BtnExportCsv           = $view.FindName('BtnExportCsv')
    BtnExportExcel         = $view.FindName('BtnExportExcel')
    BtnCopyPath            = $view.FindName('BtnCopyPath')
    BtnOpenFolder          = $view.FindName('BtnOpenFolder')
    LstArtifacts           = $view.FindName('LstArtifacts')
    BtnRefreshArtifacts    = $view.FindName('BtnRefreshArtifacts')
    MnuArtifactOpen        = $view.FindName('MnuArtifactOpen')
    MnuArtifactFolder      = $view.FindName('MnuArtifactFolder')
    MnuArtifactCopy        = $view.FindName('MnuArtifactCopy')
    MnuArtifactDelete      = $view.FindName('MnuArtifactDelete')
  }

  Enable-PrimaryActionButtons -Handles $h


  $appState = if ($global:AppState) { $global:AppState } else { $script:AppState }
  $repoRootForView = if ($global:repoRoot) { $global:repoRoot } elseif ($appState -and $appState.RepositoryRoot) { $appState.RepositoryRoot } else { $null }

  # Track current report run (view-local state)
  $currentReportBundle = $null
  $parameterControls = @{}

  # Load templates
  $templates = Get-GcReportTemplates

  function Refresh-TemplateList {
    $searchText = $h.TxtTemplateSearch.Text.ToLower()

    $filteredTemplates = $templates
    if ($searchText -and $searchText -ne 'search templates...') {
      $filteredTemplates = $templates | Where-Object {
        $_.Name.ToLower().Contains($searchText) -or
        $_.Description.ToLower().Contains($searchText)
      }
    }

    $h.LstTemplates.Items.Clear()
    foreach ($template in $filteredTemplates) {
      $item = New-Object System.Windows.Controls.ListBoxItem
      $item.Content = $template.Name
      $item.Tag = $template
      $h.LstTemplates.Items.Add($item)
    }
  }

  $buildParameterPanel = {
    param($template)

    $h.PnlParameters.Children.Clear()
    $parameterControls.Clear()

    if (-not $template.Parameters -or $template.Parameters.Count -eq 0) {
      $noParamsText = New-Object System.Windows.Controls.TextBlock
      $noParamsText.Text = "This template has no parameters"
      $noParamsText.Foreground = [System.Windows.Media.Brushes]::Gray
      $noParamsText.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
      $h.PnlParameters.Children.Add($noParamsText)
      return
    }

    foreach ($paramName in $template.Parameters.Keys) {
      $paramDef = $template.Parameters[$paramName]

      # Create parameter group
      $paramGrid = New-Object System.Windows.Controls.Grid
      $paramGrid.Margin = New-Object System.Windows.Thickness(0, 0, 0, 12)

      $row1 = New-Object System.Windows.Controls.RowDefinition
      $row1.Height = [System.Windows.GridLength]::Auto
      $row2 = New-Object System.Windows.Controls.RowDefinition
      $row2.Height = [System.Windows.GridLength]::Auto
      $row3 = New-Object System.Windows.Controls.RowDefinition
      $row3.Height = [System.Windows.GridLength]::Auto
      $paramGrid.RowDefinitions.Add($row1)
      $paramGrid.RowDefinitions.Add($row2)
      $paramGrid.RowDefinitions.Add($row3)

      # Label
      $label = New-Object System.Windows.Controls.TextBlock
      $labelText = $paramName
      if ($paramDef.Required) { $labelText += " *" }
      $label.Text = $labelText
      $label.FontWeight = [System.Windows.FontWeights]::SemiBold
      $label.Foreground = [System.Windows.Media.Brushes]::Black
      [System.Windows.Controls.Grid]::SetRow($label, 0)
      $paramGrid.Children.Add($label)

      # Description
      if ($paramDef.Description) {
        $desc = New-Object System.Windows.Controls.TextBlock
        $desc.Text = $paramDef.Description
        $desc.FontSize = 11
        $desc.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(107, 114, 128))
        $desc.Margin = New-Object System.Windows.Thickness(0, 2, 0, 4)
        $desc.TextWrapping = [System.Windows.TextWrapping]::Wrap
        [System.Windows.Controls.Grid]::SetRow($desc, 1)
        $paramGrid.Children.Add($desc)
      }

      # Input control based on type
      $control = $null
      $paramType = if ($paramDef.Type) { $paramDef.Type.ToLower() } else { 'string' }

      switch ($paramType) {
        'bool' {
          $control = New-Object System.Windows.Controls.CheckBox
          $control.IsChecked = $false
          $control.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
        }
        'int' {
          $control = New-Object System.Windows.Controls.TextBox
          $control.Height = 28
          $control.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
        }
        'datetime' {
          $control = New-Object System.Windows.Controls.DatePicker
          $control.Height = 28
          $control.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
          $control.SelectedDate = Get-Date
        }
        'array' {
          $control = New-Object System.Windows.Controls.TextBox
          $control.Height = 60
          $control.AcceptsReturn = $true
          $control.TextWrapping = [System.Windows.TextWrapping]::Wrap
          $control.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
          $control.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
        }
        default {
          $control = New-Object System.Windows.Controls.TextBox
          $control.Height = 28
          $control.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)

          # Auto-fill some common parameters
          if ($paramName -eq 'Region' -and $script:AppState.Region) {
            $control.Text = $script:AppState.Region
          }
          if ($paramName -eq 'AccessToken' -and $script:AppState.AccessToken) {
            $control.Text = '***TOKEN***'
          }
        }
      }

      [System.Windows.Controls.Grid]::SetRow($control, 2)
      $paramGrid.Children.Add($control)

      $h.PnlParameters.Children.Add($paramGrid)
      $parameterControls[$paramName] = @{
        Control = $control
        Type = $paramType
        Required = $paramDef.Required
      }
    }
  }.GetNewClosure()

  $getParameterValues = {
    $params = @{}
    $valid = $true

    foreach ($paramName in $parameterControls.Keys) {
      $paramInfo = $parameterControls[$paramName]
      $control = $paramInfo.Control
      $type = $paramInfo.Type

      $value = $null

      switch ($type) {
        'bool' {
          $value = $control.IsChecked
        }
        'int' {
          if ($control.Text) {
            try {
              $value = [int]$control.Text
            } catch {
              $valid = $false
            }
          }
        }
        'datetime' {
          if ($control.SelectedDate) {
            $value = $control.SelectedDate
          }
        }
        'array' {
          if ($control.Text) {
            # Split by newlines
            $value = $control.Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
          }
        }
        default {
          $value = $control.Text

          # Special handling for AccessToken
          if ($paramName -eq 'AccessToken' -and $value -eq '***TOKEN***') {
            $value = if ($appState) { $appState.AccessToken } else { $null }
          }
        }
      }

      # Validate required parameters
      if ($paramInfo.Required -and (-not $value -or $value -eq '')) {
        $control.BorderBrush = [System.Windows.Media.Brushes]::Red
        $valid = $false
      } else {
        $control.BorderBrush = [System.Windows.Media.Brushes]::LightGray
      }

      if ($value) {
        $params[$paramName] = $value
      }
    }

    if (-not $valid) {
      return $null
    }

    return $params
  }.GetNewClosure()

  $refreshArtifactList = {
    try {
      if (-not $h.LstArtifacts) { return }

      $artifacts = Get-GcArtifactIndex

      $displayItems = $artifacts | Sort-Object -Property Timestamp -Descending | Select-Object -First 20 | ForEach-Object {
        [PSCustomObject]@{
          DisplayName = $_.ReportName
          DisplayTime = "$($_.Timestamp) - $($_.Status)"
          BundlePath = $_.BundlePath
          RunId = $_.RunId
          ArtifactData = $_
        }
      }

      # Clear ItemsSource binding and use Items collection directly for proper WPF display
      $h.LstArtifacts.ItemsSource = $null
      $h.LstArtifacts.Items.Clear()
      foreach ($item in $displayItems) {
        $h.LstArtifacts.Items.Add($item) | Out-Null
      }
    } catch {
      Write-GcTrace -Level 'WARN' -Message "Failed to load artifact index: $($_.Exception.Message)"
    }
  }.GetNewClosure()

  # Template search
  if ($h.TxtTemplateSearch) {
    $h.TxtTemplateSearch.Add_TextChanged({
      try {
        script:Refresh-TemplateList -h $h -Templates $templates
      } catch {
        Write-GcTrace -Level 'ERROR' -Message "TxtTemplateSearch.TextChanged error: $($_.Exception.Message)"
      }
    }.GetNewClosure())

    $h.TxtTemplateSearch.Add_GotFocus({
      try {
        if ($h.TxtTemplateSearch -and $h.TxtTemplateSearch.Text -eq "Search templates...") {
          $h.TxtTemplateSearch.Text = ""
        }
      } catch { }
    }.GetNewClosure())

    $h.TxtTemplateSearch.Add_LostFocus({
      try {
        if ($h.TxtTemplateSearch -and [string]::IsNullOrWhiteSpace($h.TxtTemplateSearch.Text)) {
          $h.TxtTemplateSearch.Text = "Search templates..."
        }
      } catch { }
    }.GetNewClosure())
  }

  # Template selection
  if ($h.LstTemplates) {
    $h.LstTemplates.Add_SelectionChanged({
      $selectedItem = Get-UiSelectionSafe -Control $h.LstTemplates
      if ($selectedItem -and $selectedItem.Tag) {
        $template = $selectedItem.Tag

        # Update template description with visual highlight
        try {
          if ($h.TxtTemplateDescription) {
            $h.TxtTemplateDescription.Text = $template.Description
            $h.TxtTemplateDescription.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(255, 255, 224)) # LightYellow
          }
        } catch { }

        # Show selection confirmation
        try { Set-Status "Template selected: $($template.Name)" } catch { }

        # Enable Run Report button
        try {
          if ($h.BtnRunReport) {
            $h.BtnRunReport.IsEnabled = $true
            $h.BtnRunReport.Content = "Run Report ▶"
          }
        } catch { }

        # Build parameter panel
        & $buildParameterPanel $template

        # Reset current report
        $currentReportBundle = $null
      } else {
        # No selection - disable Run Report button
        try {
          if ($h.BtnRunReport) {
            $h.BtnRunReport.IsEnabled = $false
            $h.BtnRunReport.Content = "Run Report (Select a template first)"
          }
          if ($h.TxtTemplateDescription) {
            $h.TxtTemplateDescription.Background = [System.Windows.Media.Brushes]::White
          }
        } catch { }
      }
    }.GetNewClosure())
  }

  # Run report
  if ($h.BtnRunReport) {
    $h.BtnRunReport.Add_Click({
      try {
        $selectedItem = Get-UiSelectionSafe -Control $h.LstTemplates
        if (-not $selectedItem -or -not $selectedItem.Tag) {
          [System.Windows.MessageBox]::Show(
            "Please select a report template from the list on the left.",
            "No Template Selected",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
          )
          return
        }

        $template = $selectedItem.Tag

        # Visual feedback - disable button and show progress
        $originalButtonContent = $h.BtnRunReport.Content
        try {
          $h.BtnRunReport.IsEnabled = $false
          $h.BtnRunReport.Content = "⏳ Running..."
          Set-Status "Validating parameters..."
        } catch { }

        $params = & $getParameterValues

        # Validate parameters
        $validationErrors = Validate-ReportParameters -Template $template -ParameterValues $params
        if ($validationErrors -and $validationErrors.Count -gt 0) {
          $errorMsg = "Please fix the following errors:`n`n" + ($validationErrors -join "`n")
          [System.Windows.MessageBox]::Show(
            $errorMsg,
            "Validation Failed",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
          )
          # Re-enable button
          try {
            $h.BtnRunReport.IsEnabled = $true
            $h.BtnRunReport.Content = $originalButtonContent
          } catch { }
          return
        }

        try { Set-Status "Starting report generation..." } catch { }

        Start-AppJob -Name "Run Report — $($template.Name)" -Type 'Report' -ScriptBlock {
          param($templateName, $params)

          try {
            $bundle = Invoke-GcReportTemplate -TemplateName $templateName -Parameters $params
            return $bundle
          } catch {
            Write-Error "Failed to run report: $_"
            return $null
          }
        } -ArgumentList @($template.Name, $params) -OnCompleted ({
          param($job)

          # Re-enable button
          try {
            $h.BtnRunReport.IsEnabled = $true
            $h.BtnRunReport.Content = "Run Report ▶"
          } catch { }

          if ($job.Result) {
            $bundle = $job.Result
            $currentReportBundle = $bundle

            try { Set-Status "✓ Report complete: $($template.Name)" } catch { }

            # Load HTML preview
            if ($bundle.ReportHtmlPath -and (Test-Path $bundle.ReportHtmlPath)) {
              try {
                if ($h.WebPreview) { $h.WebPreview.Navigate($bundle.ReportHtmlPath) }
              } catch { }
            }

            # Enable export buttons

            # Refresh artifact list
            try { & $refreshArtifactList } catch { }

            try {
              Show-Snackbar "Report completed successfully!" -Action "Open" -ActionCallback {
                if ($bundle.BundlePath -and (Test-Path $bundle.BundlePath)) {
                  Start-Process $bundle.BundlePath
                }
              }.GetNewClosure()
            } catch { }
          } else {
            try { Set-Status "✗ Report failed: See job logs for details" } catch { }

            # Get error details from job if available
            $errorDetails = "Check job logs for details."
            if ($job.Error) {
              $errorDetails = $job.Error
            }

            [System.Windows.MessageBox]::Show(
              "Report generation failed:`n`n$errorDetails",
              "Report Failed",
              [System.Windows.MessageBoxButton]::OK,
              [System.Windows.MessageBoxImage]::Error
            )
          }
        }.GetNewClosure())
      } catch {
        Write-GcTrace -Level 'ERROR' -Message "BtnRunReport.Click error: $($_.Exception.Message)"
        try {
          Set-Status "✗ Error: $($_.Exception.Message)"
          $h.BtnRunReport.IsEnabled = $true
          $h.BtnRunReport.Content = "Run Report ▶"
        } catch { }

        [System.Windows.MessageBox]::Show(
          "An error occurred:`n`n$($_.Exception.Message)",
          "Error",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Error
        )
      }
    }.GetNewClosure())
  }

  # Export actions
  if ($h.BtnOpenInBrowser) {
    $h.BtnOpenInBrowser.Add_Click({
      try {
        if ($currentReportBundle -and $currentReportBundle.ReportHtmlPath -and (Test-Path $currentReportBundle.ReportHtmlPath)) {
          Start-Process $currentReportBundle.ReportHtmlPath
        }
      } catch {
        Write-GcTrace -Level 'ERROR' -Message "BtnOpenInBrowser.Click error: $($_.Exception.Message)"
      }
    }.GetNewClosure())
  }

  if ($h.BtnExportHtml) {
    $h.BtnExportHtml.Add_Click({
      try {
        if ($currentReportBundle -and $currentReportBundle.ReportHtmlPath -and (Test-Path $currentReportBundle.ReportHtmlPath)) {
          Start-Process $currentReportBundle.ReportHtmlPath
          try { Set-Status "Opened HTML report" } catch { }
        }
      } catch {
        Write-GcTrace -Level 'ERROR' -Message "BtnExportHtml.Click error: $($_.Exception.Message)"
      }
    }.GetNewClosure())
  }

  if ($h.BtnExportJson) {
    $h.BtnExportJson.Add_Click({
      try {
        if ($currentReportBundle -and $currentReportBundle.DataJsonPath -and (Test-Path $currentReportBundle.DataJsonPath)) {
          Start-Process $currentReportBundle.DataJsonPath
          try { Set-Status "Opened JSON data" } catch { }
        }
      } catch {
        Write-GcTrace -Level 'ERROR' -Message "BtnExportJson.Click error: $($_.Exception.Message)"
      }
    }.GetNewClosure())
  }

  if ($h.BtnExportCsv) {
    $h.BtnExportCsv.Add_Click({
      try {
        if ($currentReportBundle -and $currentReportBundle.DataCsvPath -and (Test-Path $currentReportBundle.DataCsvPath)) {
          Start-Process $currentReportBundle.DataCsvPath
          try { Set-Status "Opened CSV data" } catch { }
        }
      } catch {
        Write-GcTrace -Level 'ERROR' -Message "BtnExportCsv.Click error: $($_.Exception.Message)"
      }
    }.GetNewClosure())
  }

  if ($h.BtnExportExcel) {
    $h.BtnExportExcel.Add_Click({
      try {
        if ($currentReportBundle -and $currentReportBundle.DataXlsxPath -and (Test-Path $currentReportBundle.DataXlsxPath)) {
          Start-Process $currentReportBundle.DataXlsxPath
          try { Set-Status "Opened Excel workbook" } catch { }
        } else {
          [System.Windows.MessageBox]::Show(
            "Excel file not available. Ensure ImportExcel module is installed.",
            "Excel Not Available",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
          )
        }
      } catch {
        Write-GcTrace -Level 'ERROR' -Message "BtnExportExcel.Click error: $($_.Exception.Message)"
      }
    }.GetNewClosure())
  }

  if ($h.BtnCopyPath) {
    $h.BtnCopyPath.Add_Click({
      try {
        if ($currentReportBundle -and $currentReportBundle.BundlePath) {
          [System.Windows.Clipboard]::SetText($currentReportBundle.BundlePath)
          try { Set-Status "Artifact path copied to clipboard" } catch { }
          try { Show-Snackbar "Path copied to clipboard" } catch { }
        }
      } catch {
        Write-GcTrace -Level 'ERROR' -Message "BtnCopyPath.Click error: $($_.Exception.Message)"
      }
    }.GetNewClosure())
  }

  if ($h.BtnOpenFolder) {
    $h.BtnOpenFolder.Add_Click({
      try {
        if ($currentReportBundle -and $currentReportBundle.BundlePath -and (Test-Path $currentReportBundle.BundlePath)) {
          Start-Process $currentReportBundle.BundlePath
          try { Set-Status "Opened artifact folder" } catch { }
        }
      } catch {
        Write-GcTrace -Level 'ERROR' -Message "BtnOpenFolder.Click error: $($_.Exception.Message)"
      }
    }.GetNewClosure())
  }

  # Preset management
  $h.BtnLoadPreset.Add_Click({
    $presetsDir = if ($repoRootForView) { Join-Path -Path $repoRootForView -ChildPath 'App\artifacts\presets' } else { $null }

    if (-not $presetsDir -or -not (Test-Path $presetsDir)) {
      [System.Windows.MessageBox]::Show(
        "No presets found. Save a preset first.",
        "No Presets",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
      )
      return
    }

    $presets = Get-ChildItem -Path $presetsDir -Filter "*.json" -ErrorAction SilentlyContinue
    if (-not $presets -or $presets.Count -eq 0) {
      [System.Windows.MessageBox]::Show(
        "No presets found. Save a preset first.",
        "No Presets",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
      )
      return
    }

    # Show preset selection dialog (simplified - just use first preset for now)
    $presetFile = $presets[0]
    try {
      $presetData = Get-Content -Path $presetFile.FullName -Raw | ConvertFrom-Json

      # Load template
      $template = $templates | Where-Object { $_.Name -eq $presetData.TemplateName }
      if ($template) {
        # Select template in list
        for ($i = 0; $i -lt $h.LstTemplates.Items.Count; $i++) {
          if ($h.LstTemplates.Items[$i].Tag.Name -eq $template.Name) {
            $h.LstTemplates.SelectedIndex = $i
            break
          }
        }

        # Load parameter values
        foreach ($paramName in $presetData.Parameters.Keys) {
          if ($parameterControls.ContainsKey($paramName)) {
            $control = $parameterControls[$paramName].Control
            $value = $presetData.Parameters[$paramName]

            if ($control -is [System.Windows.Controls.TextBox]) {
              $control.Text = $value
            } elseif ($control -is [System.Windows.Controls.CheckBox]) {
              $control.IsChecked = $value
            } elseif ($control -is [System.Windows.Controls.DatePicker]) {
              try { $control.SelectedDate = [datetime]$value } catch {}
            }
          }
        }

        Set-Status "Loaded preset: $($presetFile.Name)"
      }
    } catch {
      [System.Windows.MessageBox]::Show(
        "Failed to load preset: $_",
        "Preset Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
      )
    }
  }.GetNewClosure())

  $h.BtnSavePreset.Add_Click({
    $selectedItem = $h.LstTemplates.SelectedItem
    if (-not $selectedItem -or -not $selectedItem.Tag) {
      [System.Windows.MessageBox]::Show(
        "Please select a template first.",
        "No Template Selected",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )
      return
    }

    $template = $selectedItem.Tag
    $params = & $getParameterValues

    if (-not $params) {
      [System.Windows.MessageBox]::Show(
        "Please fill in parameters before saving preset.",
        "No Parameters",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
      )
      return
    }

    # Create presets directory
    $presetsDir = if ($repoRootForView) { Join-Path -Path $repoRootForView -ChildPath 'App\artifacts\presets' } else { $null }
    if (-not (Test-Path $presetsDir)) {
      New-Item -ItemType Directory -Path $presetsDir -Force | Out-Null
    }

    # Save preset
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $presetName = "$($template.Name -replace '[^a-zA-Z0-9]', '_')_$timestamp.json"
    $presetPath = Join-Path -Path $presetsDir -ChildPath $presetName

    $presetData = @{
      TemplateName = $template.Name
      SavedAt = (Get-Date -Format o)
      Parameters = $params
    }

    try {
      $presetData | ConvertTo-Json -Depth 10 | Set-Content -Path $presetPath -Encoding UTF8
      Set-Status "Preset saved: $presetName"
      Show-Snackbar "Preset saved successfully"
    } catch {
      [System.Windows.MessageBox]::Show(
        "Failed to save preset: $_",
        "Save Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
      )
    }
  }.GetNewClosure())

  # Artifact hub actions
  $h.BtnRefreshArtifacts.Add_Click({
    & $refreshArtifactList
    Set-Status "Artifact list refreshed"
  }.GetNewClosure())

  # Artifact context menu handlers
  $h.MnuArtifactOpen.Add_Click({
    $selectedItem = $h.LstArtifacts.SelectedItem
    if ($selectedItem -and $selectedItem.BundlePath) {
      $htmlPath = Join-Path -Path $selectedItem.BundlePath -ChildPath 'report.html'
      if (Test-Path $htmlPath) {
        Start-Process $htmlPath
        Set-Status "Opened report: $($selectedItem.DisplayName)"
      } else {
        [System.Windows.MessageBox]::Show(
          "Report HTML file not found.",
          "File Not Found",
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Warning
        )
      }
    }
  }.GetNewClosure())

  $h.MnuArtifactFolder.Add_Click({
    $selectedItem = $h.LstArtifacts.SelectedItem
    if ($selectedItem -and $selectedItem.BundlePath -and (Test-Path $selectedItem.BundlePath)) {
      Start-Process $selectedItem.BundlePath
      Set-Status "Opened folder: $($selectedItem.DisplayName)"
    }
  }.GetNewClosure())

  $h.MnuArtifactCopy.Add_Click({
    $selectedItem = $h.LstArtifacts.SelectedItem
    if ($selectedItem -and $selectedItem.BundlePath) {
      [System.Windows.Clipboard]::SetText($selectedItem.BundlePath)
      Set-Status "Path copied to clipboard"
      Show-Snackbar "Path copied to clipboard"
    }
  }.GetNewClosure())

  $h.MnuArtifactDelete.Add_Click({
    $selectedItem = $h.LstArtifacts.SelectedItem
    if ($selectedItem -and $selectedItem.BundlePath) {
      $result = [System.Windows.MessageBox]::Show(
        "Delete artifact: $($selectedItem.DisplayName)?`n`nThis will move it to artifacts/_trash.",
        "Confirm Delete",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
      )

      if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
        try {
          # Create trash directory
          $repoRoot = Split-Path -Parent $PSScriptRoot
          $trashDir = Join-Path -Path $repoRoot -ChildPath 'App\artifacts\_trash'
          if (-not (Test-Path $trashDir)) {
            New-Item -ItemType Directory -Path $trashDir -Force | Out-Null
          }

          # Move to trash
          if (Test-Path $selectedItem.BundlePath) {
            $folderName = Split-Path -Leaf $selectedItem.BundlePath
            $trashPath = Join-Path -Path $trashDir -ChildPath $folderName
            Move-Item -Path $selectedItem.BundlePath -Destination $trashPath -Force

            # Remove from index (would need to rebuild index or filter it)
            # For now, just refresh the list
            & $refreshArtifactList
            Set-Status "Artifact moved to trash"
            Show-Snackbar "Artifact deleted"
          }
        } catch {
          [System.Windows.MessageBox]::Show(
            "Failed to delete artifact: $_",
            "Delete Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
          )
        }
      }
    }
  }.GetNewClosure())

  # Double-click to open artifact
  $h.LstArtifacts.Add_MouseDoubleClick({
    $selectedItem = $h.LstArtifacts.SelectedItem
    if ($selectedItem -and $selectedItem.BundlePath) {
      $htmlPath = Join-Path -Path $selectedItem.BundlePath -ChildPath 'report.html'
      if (Test-Path $htmlPath) {
        Start-Process $htmlPath
      }
    }
  }.GetNewClosure())

  # Initialize view
  script:Refresh-TemplateList -h $h -Templates $templates
  & $refreshArtifactList

  # Select first template by default
  if ($h.LstTemplates.Items.Count -gt 0) {
    $h.LstTemplates.SelectedIndex = 0
  }

  return $view
}

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
  Refresh-JobsList
  Refresh-HeaderStats
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
