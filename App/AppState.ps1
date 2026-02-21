# AppState.ps1
# ─────────────────────────────────────────────────────────────────────────────
# Application state management for the Genesys Cloud Admin Toolbox.
#
# Provides:
#   Initialize-GcAppState  — creates $script:AppState, registers it with the
#                            HttpRequests module via Set-GcAppState
#   $script:WorkspaceModules — static workspace/module nav registry
#   $script:AddonsByRoute    — runtime addon route table (populated at startup)
#   Sync-AppStateFromUi    — reads UI controls → updates AppState
#   Get-CallContext         — builds API call context from AppState
#
# Dot-sourced by GenesysCloudTool.ps1 at startup, before the Core modules are
# fully initialized. Call Initialize-GcAppState once $repoRoot is set.
# ─────────────────────────────────────────────────────────────────────────────

### BEGIN: AppStateInit
function Initialize-GcAppState {
  <#
  .SYNOPSIS
    Creates $script:AppState with all default values and registers it with the
    HttpRequests module so Invoke-AppGcRequest can inject the active token.

  .PARAMETER RepoRoot
    Absolute path to the repository root (parent of App/).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$RepoRoot
  )

  $script:AppState = [ordered]@{
    Region       = 'usw2.pure.cloud'
    Org          = ''
    Auth         = 'Not logged in'
    TokenStatus  = 'No token'
    AccessToken  = $null  # Set for testing: $script:AppState.AccessToken = "YOUR_TOKEN_HERE"
    RepositoryRoot = $RepoRoot

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

    # Genesys.Core backend integration (populated by Initialize-GcCoreIntegration)
    GcCoreAvailable   = $false
    GcCoreModulePath  = $null
    GcCoreCatalogPath = $null
    GcCoreVersion     = $null
  }

  # Register with HttpRequests module so Invoke-AppGcRequest auto-injects token + region.
  Set-GcAppState -State ([ref]$script:AppState)
}
### END: AppStateInit

### BEGIN: WorkspaceRegistry
# Static workspace → module nav registry.
# Executed immediately at dot-source time so Populate-Modules has data at first load.
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
  'Audits' = @(
    'Extension Audit'
  )
}

# Runtime addon route table — populated by Initialize-GcAddons at startup.
# Keys: "Workspace::Module", Values: addon definition objects.
$script:AddonsByRoute = @{}
### END: WorkspaceRegistry

### BEGIN: AppStateHelpers
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
        try { Write-GcAppLog -Level 'INFO' -Category 'state' -Message 'AppState.Region updated' -Data @{ Region = $normalized } } catch { }
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
        try { Write-GcAppLog -Level 'INFO' -Category 'state' -Message 'AppState.AccessToken updated' -Data @{ TokenLength = $normalized.Length } } catch { }
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
  $token  = $script:AppState.AccessToken

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
    # Not in offline mode — token is required
    if ([string]::IsNullOrWhiteSpace($token)) {
      Write-GcTrace -Level 'WARN' -Message "Get-CallContext: No access token available and not in offline mode"
      return $null
    }
  }

  # Build and return context
  return @{
    InstanceName  = $region
    Region        = $region  # Some functions use Region instead of InstanceName
    AccessToken   = $token
    IsOfflineDemo = $isOffline
  }
}
### END: AppStateHelpers
