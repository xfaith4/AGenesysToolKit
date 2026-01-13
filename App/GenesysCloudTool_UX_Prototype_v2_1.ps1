# Genesys Cloud Tool — Real Implementation v3.0
# Money path flow: Login → Start Subscription → Stream events → Open Timeline → Export Packet

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Import core modules
$scriptRoot = Split-Path -Parent $PSCommandPath
$coreRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'Core'

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
Set-GcAuthConfig `
  -Region 'usw2.pure.cloud' `
  -ClientId 'clientid' `
  -RedirectUri 'http://localhost:8085/callback' `
  -Scopes @('conversations', 'analytics', 'notifications', 'users')

$script:AppState = [ordered]@{
  Region       = 'usw2.pure.cloud'
  Auth         = 'Not logged in'
  TokenStatus  = 'No token'
  AccessToken  = $null  # STEP 1: Set a token here for testing: $script:AppState.AccessToken = "YOUR_TOKEN_HERE"

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

  # Start the job
  Start-GcJob -Job $job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -OnComplete $OnCompleted

  return $job
}

# -----------------------------
# Timeline Job Helper
# -----------------------------
# Shared scriptblock for timeline retrieval to avoid duplication
$script:TimelineJobScriptBlock = {
  param($conversationId, $region, $accessToken, $eventBuffer)

  # Import required modules in runspace
  $scriptRoot = Split-Path -Parent $PSCommandPath
  $coreRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'Core'
  Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
  Import-Module (Join-Path -Path $coreRoot -ChildPath 'Timeline.psm1') -Force

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
        <Button x:Name="BtnLogin" Content="Login…" Width="92" Height="28" Margin="0,0,8,0"/>
        <Button x:Name="BtnTestToken" Content="Test Token" Width="92" Height="28" Margin="0,0,10,0"/>
        <Button x:Name="BtnJobs" Content="Jobs (0)" Width="92" Height="28" Margin="0,0,8,0"/>
        <Button x:Name="BtnArtifacts" Content="Artifacts (0)" Width="110" Height="28"/>
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
        <ColumnDefinition Width="280"/>
        <ColumnDefinition Width="280"/>
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
                <Button x:Name="BtnCloseBackstage" Content="Close" Width="70" Height="26" DockPanel.Dock="Right"/>
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
                      <Button x:Name="BtnOpenArtifactsFolder" Content="Open Folder" Width="110" Height="26" Margin="0,0,8,0"/>
                      <Button x:Name="BtnOpenSelectedArtifact" Content="Open Selected" Width="120" Height="26"/>
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
          <Button x:Name="BtnSnackPrimary" Content="Open" Width="72" Height="26" Margin="0,0,8,0"/>
          <Button x:Name="BtnSnackSecondary" Content="Folder" Width="72" Height="26" Margin="0,0,8,0"/>
          <Button x:Name="BtnSnackClose" Content="×" Width="26" Height="26"/>
        </StackPanel>
      </Grid>
    </Border>

  </Grid>
</Window>
"@

$Window = ConvertFrom-GcXaml -XamlString $xamlString

function Get-El([string]$name) { $Window.FindName($name) }

# Top bar
$TxtContext   = Get-El 'TxtContext'
$BtnLogin     = Get-El 'BtnLogin'
$BtnTestToken = Get-El 'BtnTestToken'
$BtnJobs      = Get-El 'BtnJobs'
$BtnArtifacts = Get-El 'BtnArtifacts'
$TxtCommand   = Get-El 'TxtCommand'

# Nav
$NavWorkspaces   = Get-El 'NavWorkspaces'
$NavModules      = Get-El 'NavModules'
$TxtModuleHeader = Get-El 'TxtModuleHeader'
$TxtModuleHint   = Get-El 'TxtModuleHint'

# Header + content
$TxtTitle    = Get-El 'TxtTitle'
$TxtSubtitle = Get-El 'TxtSubtitle'
$MainHost    = Get-El 'MainHost'
$TxtStatus   = Get-El 'TxtStatus'
$TxtStats    = Get-El 'TxtStats'

# Backstage
$BackstageOverlay = Get-El 'BackstageOverlay'
$BackstageTabs    = Get-El 'BackstageTabs'
$BtnCloseBackstage= Get-El 'BtnCloseBackstage'
$LstJobs          = Get-El 'LstJobs'
$TxtJobMeta       = Get-El 'TxtJobMeta'
$BtnCancelJob     = Get-El 'BtnCancelJob'
$LstJobLogs       = Get-El 'LstJobLogs'

$LstArtifacts            = Get-El 'LstArtifacts'
$BtnOpenArtifactsFolder  = Get-El 'BtnOpenArtifactsFolder'
$BtnOpenSelectedArtifact = Get-El 'BtnOpenSelectedArtifact'

# Snackbar
$SnackbarHost      = Get-El 'SnackbarHost'
$SnackbarTitle     = Get-El 'SnackbarTitle'
$SnackbarBody      = Get-El 'SnackbarBody'
$BtnSnackPrimary   = Get-El 'BtnSnackPrimary'
$BtnSnackSecondary = Get-El 'BtnSnackSecondary'
$BtnSnackClose     = Get-El 'BtnSnackClose'

# -----------------------------
# UI helpers
# -----------------------------
function Set-TopContext {
  $TxtContext.Text = "Region: $($script:AppState.Region)  |  Org: $($script:AppState.Org)  |  Auth: $($script:AppState.Auth)  |  Token: $($script:AppState.TokenStatus)"
}

function Set-Status([string]$msg) { $TxtStatus.Text = $msg }

function Refresh-HeaderStats {
  $BtnJobs.Content      = "Jobs ($($script:AppState.Jobs.Count))"
  $BtnArtifacts.Content = "Artifacts ($($script:AppState.Artifacts.Count))"
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
  if (-not $script:GcConsoleDiagnosticsEnabled) { return }
  $ts = (Get-Date).ToString('HH:mm:ss.fff')
  Write-Host ("[{0}] [DIAG] {1}" -f $ts, $Message)
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
    - $BtnTestToken (UI button element for state management)
    - Invoke-AppGcRequest (from HttpRequests module)
    - Set-Status, Set-TopContext (UI helper functions)
    - Start-AppJob (job runner function)

  .EXAMPLE
    Start-TokenTest
  #>

  if (-not $script:AppState.AccessToken) {
    Write-GcDiag "Start-TokenTest: no token in AppState.AccessToken"
    Set-Status "No token available to test."
    return
  }

  Write-GcDiag ("Start-TokenTest: begin (Region='{0}', Token={1})" -f $script:AppState.Region, (Format-GcDiagSecret -Value $script:AppState.AccessToken))

  # Disable button during test
  $BtnTestToken.IsEnabled = $false
  $BtnTestToken.Content = "Testing..."
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

      # Analyze error and provide user-friendly message
      $userMessage = "Token test failed."
      $detailMessage = $errorMsg

      # Check for common error scenarios
      if ($errorMsg -match "400|Bad Request") {
        $userMessage = "Bad Request"
        $detailMessage = "The API request was malformed. This usually indicates:`n• Token has invalid format or characters`n• Token contains line breaks or extra whitespace`n• Region format is incorrect`n`nRegion: $($script:AppState.Region)`nPlease verify the token was copied correctly without any line breaks.`n`nError: $errorMsg"
      }
      elseif ($errorMsg -match "401|Unauthorized") {
        $userMessage = "Token Invalid or Expired"
        $detailMessage = "The access token is not valid or has expired. Please log in again.`n`nError: $errorMsg"
      }
      elseif ($errorMsg -match "Unable to connect|could not be resolved|Name or service not known") {
        $userMessage = "Connection Failed"
        $detailMessage = "Cannot connect to region '$($script:AppState.Region)'. Please verify:`n• Region is correct (e.g., mypurecloud.com, usw2.pure.cloud)`n• Network connection is available`n`nError: $errorMsg"
      }
      elseif ($errorMsg -match "404|Not Found") {
        $userMessage = "Endpoint Not Found"
        $detailMessage = "API endpoint not found. This may indicate:`n• Wrong region configured`n• API version mismatch`n`nRegion: $($script:AppState.Region)`nError: $errorMsg"
      }
      elseif ($errorMsg -match "403|Forbidden") {
        $userMessage = "Permission Denied"
        $detailMessage = "Token is valid but lacks permission to access user information.`n`nError: $errorMsg"
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

    # Re-enable button
    $BtnTestToken.Content = "Test Token"
    $BtnTestToken.IsEnabled = $true
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
         Height="380" Width="760"
         WindowStartupLocation="CenterOwner"
         Background="#FFF7F7F9"
         ResizeMode="NoResize">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- Header -->
      <RowDefinition Height="Auto"/>   <!-- Region Input -->
      <RowDefinition Height="Auto"/>   <!-- Token Label -->
      <RowDefinition Height="*"/>      <!-- Token Input -->
      <RowDefinition Height="Auto"/>   <!-- Buttons -->
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#FF111827" CornerRadius="6" Padding="12" Margin="0,0,0,16">
      <StackPanel>
        <TextBlock Text="Manual Token Entry" FontSize="14" FontWeight="SemiBold" Foreground="White"/>
        <TextBlock Text="Paste an access token for testing or manual authentication"
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

    <!-- Buttons -->
    <Grid Grid.Row="4">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <Button x:Name="BtnClearToken" Grid.Column="0" Content="Clear Token"
              Width="100" Height="30" HorizontalAlignment="Left"/>

      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="BtnSetTest" Content="Set + Test" Width="100" Height="30" Margin="0,0,8,0"/>
        <Button x:Name="BtnCancel" Content="Cancel" Width="80" Height="30"/>
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
    $btnSetTest = $dialog.FindName('BtnSetTest')
    $btnCancel = $dialog.FindName('BtnCancel')
    $btnClearToken = $dialog.FindName('BtnClearToken')

    # Prefill region from current AppState
    $txtRegion.Text = $script:AppState.Region

    # Set + Test button handler
    $btnSetTest.Add_Click({
      Write-GcDiag "Manual token entry: 'Set + Test' clicked"

      # Get and clean region input
      $region = $txtRegion.Text.Trim()
      Write-GcDiag ("Manual token entry: region(raw)='{0}'" -f $region)

      # Get token and perform comprehensive sanitization
      # Remove all line breaks, carriage returns, and extra whitespace
      $token = $txtToken.Text -replace '[\r\n]+', ''  # Remove line breaks
      $token = $token.Trim()  # Remove leading/trailing whitespace
      Write-GcDiag ("Manual token entry: token(raw/sanitized)={0}" -f (Format-GcDiagSecret -Value $token))

      # Validate region input
      if ([string]::IsNullOrWhiteSpace($region)) {
        [System.Windows.MessageBox]::Show(
          "Please enter a region (e.g., mypurecloud.com, usw2.pure.cloud)",
          "Region Required",
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

      # Remove "Bearer " prefix if present (case-insensitive)
      if ($token -imatch '^Bearer\s+(.+)$') {
        $token = $matches[1].Trim()
      }
      Write-GcDiag ("Manual token entry: token(after Bearer strip)={0}" -f (Format-GcDiagSecret -Value $token))

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
  $LstJobs.Items.Clear()
  foreach ($j in $script:AppState.Jobs) {
    $LstJobs.Items.Add("$($j.Status) [$($j.Progress)%] — $($j.Name)") | Out-Null
  }
  Refresh-HeaderStats
}

function Open-Backstage([ValidateSet('Jobs','Artifacts')]$Tab = 'Jobs') {
  if ($Tab -eq 'Jobs') { $BackstageTabs.SelectedIndex = 0 } else { $BackstageTabs.SelectedIndex = 1 }
  Refresh-JobsList
  Refresh-ArtifactsList
  $BackstageOverlay.Visibility = 'Visible'
}
function Close-Backstage { $BackstageOverlay.Visibility = 'Collapsed' }

$BtnCloseBackstage.Add_Click({ Close-Backstage })

# -----------------------------
# Jobs selection
# -----------------------------
$LstJobs.Add_SelectionChanged({
  $idx = $LstJobs.SelectedIndex
  if ($idx -lt 0 -or $idx -ge $script:AppState.Jobs.Count) {
    $TxtJobMeta.Text = "Select a job…"
    $LstJobLogs.Items.Clear()
    $BtnCancelJob.IsEnabled = $false
    return
  }

  $job = $script:AppState.Jobs[$idx]
  $TxtJobMeta.Text = "Name: $($job.Name)`r`nType: $($job.Type)`r`nStatus: $($job.Status)`r`nProgress: $($job.Progress)%"
  $LstJobLogs.Items.Clear()
  foreach ($l in $job.Logs) { $LstJobLogs.Items.Add($l) | Out-Null }
  $BtnCancelJob.IsEnabled = [bool]$job.CanCancel
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

    [object[]]$SubscriptionEvents = @()
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

          <TextBlock Grid.Row="0" Text="Timeline Events" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827" Margin="0,0,0,10"/>

          <DataGrid x:Name="DgTimeline" Grid.Row="1"
                    AutoGenerateColumns="False"
                    IsReadOnly="True"
                    SelectionMode="Single"
                    GridLinesVisibility="None"
                    HeadersVisibility="Column"
                    CanUserResizeRows="False"
                    CanUserSortColumns="True"
                    AlternatingRowBackground="#FFF9FAFB"
                    Background="White">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Time" Binding="{Binding TimeFormatted}" Width="140" CanUserSort="True"/>
              <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="120" CanUserSort="True"/>
              <DataGridTextColumn Header="Label" Binding="{Binding Label}" Width="*" CanUserSort="True"/>
            </DataGrid.Columns>
          </DataGrid>
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
    $txtDetail = $window.FindName('TxtDetail')
    $txtConvInfo = $window.FindName('TxtConvInfo')

    # Update conversation info with event count
    $txtConvInfo.Text = "Conversation ID: $ConversationId  |  Events: $($TimelineEvents.Count)"

    # Prepare timeline events for display (add formatted time property)
    $displayEvents = @()
    foreach ($evt in $TimelineEvents) {
      $displayEvent = [PSCustomObject]@{
        Time = $evt.Time
        TimeFormatted = $evt.Time.ToString('yyyy-MM-dd HH:mm:ss.fff')
        Category = $evt.Category
        Label = $evt.Label
        Details = $evt.Details
        CorrelationKeys = $evt.CorrelationKeys
        OriginalEvent = $evt
      }
      $displayEvents += $displayEvent
    }

    # Bind events to DataGrid
    $dgTimeline.ItemsSource = $displayEvents

    # Handle selection change to show details
    $dgTimeline.Add_SelectionChanged({
      if ($dgTimeline.SelectedItem) {
        $selected = $dgTimeline.SelectedItem
        $detailObj = [ordered]@{
          Time = $selected.Time.ToString('o')
          Category = $selected.Category
          Label = $selected.Label
          CorrelationKeys = $selected.CorrelationKeys
          Details = $selected.Details
        }
        $txtDetail.Text = ($detailObj | ConvertTo-Json -Depth 10)
      }
    })

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
          <Button x:Name="BtnOpQuery" Content="Query" Width="86" Height="32" Margin="0,0,8,0"/>
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
    $h.BtnOpQuery.IsEnabled = $false
    $h.BtnOpExportJson.IsEnabled = $false
    $h.BtnOpExportCsv.IsEnabled = $false

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
    } -ArgumentList @($startTime, $endTime) -OnCompleted {
      param($job)

      $h.BtnOpQuery.IsEnabled = $true

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
        $h.BtnOpExportJson.IsEnabled = $true
        $h.BtnOpExportCsv.IsEnabled = $true

        Set-Status "Loaded $($events.Count) operational events."
      } else {
        Set-Status "Failed to query operational events. Check job logs."
        $h.GridOpEvents.ItemsSource = @()
        $h.TxtOpCount.Text = "(0 events)"
      }
    }
  })

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
  })

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
  })

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
  })

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
          <Button x:Name="BtnAuditQuery" Content="Query" Width="86" Height="32" Margin="0,0,8,0"/>
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
    $h.BtnAuditQuery.IsEnabled = $false
    $h.BtnAuditExportJson.IsEnabled = $false
    $h.BtnAuditExportCsv.IsEnabled = $false

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
    } -ArgumentList @($startTime, $endTime) -OnCompleted {
      param($job)

      $h.BtnAuditQuery.IsEnabled = $true

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
        $h.BtnAuditExportJson.IsEnabled = $true
        $h.BtnAuditExportCsv.IsEnabled = $true

        Set-Status "Loaded $($audits.Count) audit entries."
      } else {
        Set-Status "Failed to query audit logs. Check job logs."
        $h.GridAuditLogs.ItemsSource = @()
        $h.TxtAuditCount.Text = "(0 audits)"
      }
    }
  })

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
  })

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
  })

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
  })

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
          <Button x:Name="BtnTokenQuery" Content="Query" Width="86" Height="32" Margin="0,0,8,0"/>
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
    $h.BtnTokenQuery.IsEnabled = $false
    $h.BtnTokenExportJson.IsEnabled = $false
    $h.BtnTokenExportCsv.IsEnabled = $false

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
    } -OnCompleted {
      param($job)

      $h.BtnTokenQuery.IsEnabled = $true

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
        $h.BtnTokenExportJson.IsEnabled = $true
        $h.BtnTokenExportCsv.IsEnabled = $true

        Set-Status "Loaded $($clients.Count) OAuth clients."
      } else {
        Set-Status "Failed to query OAuth clients. Check job logs."
        $h.GridTokenUsage.ItemsSource = @()
        $h.TxtTokenCount.Text = "(0 clients)"
      }
    }
  })

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
  })

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
  })

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
  })

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
            <Button x:Name="BtnConvSearch" Content="Search" Width="100" Height="32" Margin="0,0,8,0"/>
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

  $script:ConversationsData = @()

  $h.BtnConvSearch.Add_Click({
    Set-Status "Searching conversations..."
    $h.BtnConvSearch.IsEnabled = $false
    $h.BtnConvExportJson.IsEnabled = $false
    $h.BtnConvExportCsv.IsEnabled = $false
    $h.BtnOpenTimeline.IsEnabled = $false

    # Build date range
    $endTime = Get-Date
    $startTime = switch ($h.CmbDateRange.SelectedIndex) {
      0 { $endTime.AddHours(-1) }
      1 { $endTime.AddHours(-6) }
      2 { $endTime.AddHours(-24) }
      3 { $endTime.AddDays(-7) }
      default { $endTime.AddHours(-24) }
    }

    $interval = "$($startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))/$($endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"
    
    # Get max results
    $maxResults = 500
    if (-not [string]::IsNullOrWhiteSpace($h.TxtMaxResults.Text)) {
      if ([int]::TryParse($h.TxtMaxResults.Text, [ref]$maxResults)) {
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
    if (-not [string]::IsNullOrWhiteSpace($h.TxtConvIdFilter.Text)) {
      $queryBody.conversationFilters = @(
        @{
          type = "and"
          predicates = @(
            @{
              dimension = "conversationId"
              value = $h.TxtConvIdFilter.Text
            }
          )
        }
      )
    }

    Start-AppJob -Name "Search Conversations" -Type "Query" -ScriptBlock {
      param($queryBody, $accessToken, $instanceName, $maxItems)
      
      # Import required modules in runspace
      $scriptRoot = Split-Path -Parent $PSCommandPath
      $coreRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'Core'
      Import-Module (Join-Path -Path $coreRoot -ChildPath 'ConversationsExtended.psm1') -Force
      
      Search-GcConversations -Body $queryBody -AccessToken $accessToken -InstanceName $instanceName -MaxItems $maxItems
    } -ArgumentList @($queryBody, $script:AppState.AccessToken, $script:AppState.Region, $maxResults) -OnCompleted {
      param($job)
      $h.BtnConvSearch.IsEnabled = $true

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
        $h.GridConversations.ItemsSource = $displayData
        $h.TxtConvCount.Text = "($($job.Result.Count) conversations)"
        $h.BtnConvExportJson.IsEnabled = $true
        $h.BtnConvExportCsv.IsEnabled = $true
        $h.BtnOpenTimeline.IsEnabled = $true
        Set-Status "Found $($job.Result.Count) conversations."
      } else {
        $h.GridConversations.ItemsSource = @()
        $h.TxtConvCount.Text = "(0 conversations)"
        Set-Status "Search failed or returned no results."
      }
    }
  })

  $h.BtnConvExportJson.Add_Click({
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
  })

  $h.BtnConvExportCsv.Add_Click({
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
      $h.GridConversations.ItemsSource | Select-Object ConversationId, StartTime, Duration, Participants, Media, Direction |
        Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      Set-Status "Exported $($script:ConversationsData.Count) conversations to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  $h.BtnOpenTimeline.Add_Click({
    $selected = $h.GridConversations.SelectedItem
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
  })

  $h.TxtConvSearchFilter.Add_TextChanged({
    if (-not $script:ConversationsData -or $script:ConversationsData.Count -eq 0) { return }

    $searchText = $h.TxtConvSearchFilter.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "filter results...") {
      $h.GridConversations.ItemsSource = $script:ConversationsData | ForEach-Object {
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
      $h.TxtConvCount.Text = "($($script:ConversationsData.Count) conversations)"
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

    $h.GridConversations.ItemsSource = $displayData
    $h.TxtConvCount.Text = "($($filtered.Count) conversations)"
  })

  $h.TxtConvSearchFilter.Add_GotFocus({
    if ($h.TxtConvSearchFilter.Text -eq "Filter results...") {
      $h.TxtConvSearchFilter.Text = ""
    }
  })

  $h.TxtConvSearchFilter.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtConvSearchFilter.Text)) {
      $h.TxtConvSearchFilter.Text = "Filter results..."
    }
  })

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
        <Button x:Name="BtnBuild" Content="Build Timeline" Width="120" Height="28" Margin="12,0,0,0"/>
        <Button x:Name="BtnExport" Content="Export Packet" Width="110" Height="28" Margin="10,0,0,0"/>
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
    $txtConv.Text = $script:AppState.FocusConversationId
  }

  $btnBuild.Add_Click({
    $conv = $txtConv.Text.Trim()

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
          -SubscriptionEvents $result.SubscriptionEvents
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

  $lst.Add_SelectionChanged({
    if ($lst.SelectedItem) {
      $sel = [string]$lst.SelectedItem
      $detail.Text = "{`r`n  `"event`": `"$sel`",`r`n  `"note`": `"Mock payload would include segments, media stats, participant/session IDs.`"`r`n}"
    }
  })

  $btnExport.Add_Click({
    $conv = $txtConv.Text.Trim()
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

      # Import required modules in runspace
      $scriptRoot = Split-Path -Parent $PSCommandPath
      $coreRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'Core'
      Import-Module (Join-Path -Path $coreRoot -ChildPath 'ArtifactGenerator.psm1') -Force

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
  })

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
            <Button x:Name="BtnSubmitJob" Content="Submit Job" Width="110" Height="32" Margin="0,0,8,0"/>
            <Button x:Name="BtnRefresh" Content="Refresh" Width="100" Height="32"/>
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
    $h.BtnSubmitJob.IsEnabled = $false

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
      
      # Import required modules in runspace
      $scriptRoot = Split-Path -Parent $PSCommandPath
      $coreRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'Core'
      Import-Module (Join-Path -Path $coreRoot -ChildPath 'Jobs.psm1') -Force
      Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
      
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
    } -ArgumentList @($queryBody, $script:AppState.AccessToken, $script:AppState.Region, $maxResults) -OnCompleted {
      param($job)
      $h.BtnSubmitJob.IsEnabled = $true

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
        
        $h.BtnViewResults.IsEnabled = $true
        $h.BtnExportResults.IsEnabled = $true
      } else {
        Set-Status "Failed to submit analytics job. See job logs for details."
      }
    }
  })

  $h.BtnRefresh.Add_Click({
    Refresh-JobsList
    Set-Status "Refreshed job list."
  })

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
  })

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
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

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

          <Button x:Name="BtnGeneratePacket" Grid.Column="1" Content="Generate Packet" Width="140" Height="32" VerticalAlignment="Center"/>
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
          <Button x:Name="BtnOpenPacketFolder" Content="Open Artifacts" Width="120" Height="26" Margin="12,0,0,0"/>
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
    $h.BtnGeneratePacket.IsEnabled = $false

    $createZip = $h.ChkZip.IsChecked

    Start-AppJob -Name "Export Incident Packet — $convId" -Type 'Export' -ScriptBlock {
      param($conversationId, $region, $accessToken, $artifactsDir, $eventBuffer, $createZip)

      # Import required modules in runspace
      $scriptRoot = Split-Path -Parent $PSCommandPath
      $coreRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'Core'
      Import-Module (Join-Path -Path $coreRoot -ChildPath 'ArtifactGenerator.psm1') -Force

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
      $h.BtnGeneratePacket.IsEnabled = $true

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
  })

  $h.TxtPacketConvId.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtPacketConvId.Text)) {
      $h.TxtPacketConvId.Text = "Enter conversation ID..."
    }
  })

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
          <Button x:Name="BtnAbandonQuery" Content="Query Metrics" Width="120" Height="32"/>
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

  $script:AbandonmentData = $null
  $script:AbandonedConversations = @()

  # Query button click handler
  $h.BtnAbandonQuery.Add_Click({
    Set-Status "Querying abandonment metrics..."
    $h.BtnAbandonQuery.IsEnabled = $false
    $h.BtnAbandonExport.IsEnabled = $false

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
      $h.BtnAbandonQuery.IsEnabled = $true

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
          $h.BtnAbandonExport.IsEnabled = $true
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
    $h.BtnLoadRecordings.IsEnabled = $false
    $h.BtnExportRecordings.IsEnabled = $false

    $coreConvPath = Join-Path -Path $coreRoot -ChildPath 'ConversationsExtended.psm1'
    $coreHttpPath = Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1'

    Start-AppJob -Name "Load Recordings" -Type "Query" -ScriptBlock {
      param($convPath, $httpPath, $accessToken, $region)
      
      Import-Module $httpPath -Force
      Import-Module $convPath -Force
      
      Get-GcRecordings -AccessToken $accessToken -InstanceName $region -MaxItems 100
    } -ArgumentList @($coreConvPath, $coreHttpPath, $script:AppState.AccessToken, $script:AppState.Region) -OnCompleted {
      param($job)
      $h.BtnLoadRecordings.IsEnabled = $true

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
        $h.BtnExportRecordings.IsEnabled = $true
        Set-Status "Loaded $($job.Result.Count) recordings."
      } else {
        $h.GridRecordings.ItemsSource = @()
        $h.TxtRecordingCount.Text = "(0 recordings)"
        Set-Status "No recordings found or failed to load."
      }
    }
  })

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
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  # Load Transcript button handler
  $h.BtnLoadTranscript.Add_Click({
    $convId = $h.TxtTranscriptConvId.Text.Trim()
    
    if ([string]::IsNullOrWhiteSpace($convId) -or $convId -eq "Enter conversation ID...") {
      [System.Windows.MessageBox]::Show("Please enter a conversation ID.", "Missing Input", 
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
      return
    }

    Set-Status "Loading transcript for conversation $convId..."
    $h.BtnLoadTranscript.IsEnabled = $false
    $h.BtnExportTranscript.IsEnabled = $false
    $h.TxtTranscriptContent.Text = "Loading transcript..."

    $coreConvPath = Join-Path -Path $coreRoot -ChildPath 'ConversationsExtended.psm1'
    $coreHttpPath = Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1'

    Start-AppJob -Name "Load Transcript" -Type "Query" -ScriptBlock {
      param($convPath, $httpPath, $accessToken, $region, $convId)
      
      Import-Module $httpPath -Force
      Import-Module $convPath -Force
      
      Get-GcConversationTranscript -ConversationId $convId -AccessToken $accessToken -InstanceName $region
    } -ArgumentList @($coreConvPath, $coreHttpPath, $script:AppState.AccessToken, $script:AppState.Region, $convId) -OnCompleted {
      param($job)
      $h.BtnLoadTranscript.IsEnabled = $true

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
        $h.BtnExportTranscript.IsEnabled = $true
        Set-Status "Loaded transcript for conversation $convId."
      } else {
        $h.TxtTranscriptContent.Text = "No transcript found for conversation $convId or conversation does not exist."
        Set-Status "No transcript found."
      }
    }
  })

  # Export Transcript button handler
  $h.BtnExportTranscript.Add_Click({
    if (-not $script:TranscriptData) {
      Set-Status "No transcript to export."
      return
    }

    $convId = $h.TxtTranscriptConvId.Text.Trim()
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
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  # Load Evaluations button handler
  $h.BtnLoadEvaluations.Add_Click({
    Set-Status "Loading quality evaluations..."
    $h.BtnLoadEvaluations.IsEnabled = $false
    $h.BtnExportEvaluations.IsEnabled = $false

    $coreConvPath = Join-Path -Path $coreRoot -ChildPath 'ConversationsExtended.psm1'
    $coreHttpPath = Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1'

    Start-AppJob -Name "Load Quality Evaluations" -Type "Query" -ScriptBlock {
      param($convPath, $httpPath, $accessToken, $region)
      
      Import-Module $httpPath -Force
      Import-Module $convPath -Force
      
      Get-GcQualityEvaluations -AccessToken $accessToken -InstanceName $region -MaxItems 100
    } -ArgumentList @($coreConvPath, $coreHttpPath, $script:AppState.AccessToken, $script:AppState.Region) -OnCompleted {
      param($job)
      $h.BtnLoadEvaluations.IsEnabled = $true

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
        $h.BtnExportEvaluations.IsEnabled = $true
        Set-Status "Loaded $($job.Result.Count) quality evaluations."
      } else {
        $h.GridEvaluations.ItemsSource = @()
        $h.TxtEvaluationCount.Text = "(0 evaluations)"
        Set-Status "No evaluations found or failed to load."
      }
    }
  })

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
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  # Transcript conversation ID textbox focus handlers
  $h.TxtTranscriptConvId.Add_GotFocus({
    if ($h.TxtTranscriptConvId.Text -eq "Enter conversation ID...") {
      $h.TxtTranscriptConvId.Text = ""
    }
  })

  $h.TxtTranscriptConvId.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtTranscriptConvId.Text)) {
      $h.TxtTranscriptConvId.Text = "Enter conversation ID..."
    }
  })

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

  # Store flows data for export
  $script:FlowsData = @()

  # Load button handler
  $h.BtnFlowLoad.Add_Click({
    Set-Status "Loading flows..."
    $h.BtnFlowLoad.IsEnabled = $false
    $h.BtnFlowExportJson.IsEnabled = $false
    $h.BtnFlowExportCsv.IsEnabled = $false

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

      $h.BtnFlowLoad.IsEnabled = $true

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

        $h.GridFlows.ItemsSource = $displayData
        $h.TxtFlowCount.Text = "($($flows.Count) flows)"
        $h.BtnFlowExportJson.IsEnabled = $true
        $h.BtnFlowExportCsv.IsEnabled = $true

        Set-Status "Loaded $($flows.Count) flows."
      } else {
        Set-Status "Failed to load flows. Check job logs."
        $h.GridFlows.ItemsSource = @()
        $h.TxtFlowCount.Text = "(0 flows)"
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

    $searchText = $h.TxtFlowSearch.Text.ToLower()
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
      $h.GridFlows.ItemsSource = $displayData
      $h.TxtFlowCount.Text = "($($script:FlowsData.Count) flows)"
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

    $h.GridFlows.ItemsSource = $displayData
    $h.TxtFlowCount.Text = "($($filtered.Count) flows)"
  })

  # Clear search placeholder on focus
  $h.TxtFlowSearch.Add_GotFocus({
    if ($h.TxtFlowSearch.Text -eq "Search flows...") {
      $h.TxtFlowSearch.Text = ""
    }
  })

  # Restore search placeholder on lost focus if empty
  $h.TxtFlowSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtFlowSearch.Text)) {
      $h.TxtFlowSearch.Text = "Search flows..."
    }
  })

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
          <Button x:Name="BtnDataActionLoad" Content="Load Actions" Width="110" Height="32" Margin="0,0,8,0"/>
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

        <DataGrid x:Name="GridDataActions" Grid.Row="1" Margin="0,10,0,0" AutoGenerateColumns="False" IsReadOnly="True"
                  HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="250"/>
            <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="150"/>
            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="100"/>
            <DataGridTextColumn Header="Integration" Binding="{Binding Integration}" Width="180"/>
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
    CmbDataActionCategory    = $view.FindName('CmbDataActionCategory')
    CmbDataActionStatus      = $view.FindName('CmbDataActionStatus')
    BtnDataActionLoad        = $view.FindName('BtnDataActionLoad')
    BtnDataActionExportJson  = $view.FindName('BtnDataActionExportJson')
    BtnDataActionExportCsv   = $view.FindName('BtnDataActionExportCsv')
    TxtDataActionSearch      = $view.FindName('TxtDataActionSearch')
    TxtDataActionCount       = $view.FindName('TxtDataActionCount')
    GridDataActions          = $view.FindName('GridDataActions')
  }

  # Store data actions for export
  $script:DataActionsData = @()

  # Load button handler
  $h.BtnDataActionLoad.Add_Click({
    Set-Status "Loading data actions..."
    $h.BtnDataActionLoad.IsEnabled = $false
    $h.BtnDataActionExportJson.IsEnabled = $false
    $h.BtnDataActionExportCsv.IsEnabled = $false

    Start-AppJob -Name "Load Data Actions" -Type "Query" -ScriptBlock {
      # Query data actions using Genesys Cloud API
      $maxItems = 500  # Limit to prevent excessive API calls
      try {
        $results = Invoke-GcPagedRequest -Path '/api/v2/integrations/actions' -Method GET `
          -InstanceName $script:AppState.Region -AccessToken $script:AppState.AccessToken -MaxItems $maxItems

        return $results
      } catch {
        Write-Error "Failed to load data actions: $_"
        return @()
      }
    } -OnCompleted {
      param($job)

      $h.BtnDataActionLoad.IsEnabled = $true

      if ($job.Result) {
        $actions = $job.Result
        $script:DataActionsData = $actions

        # Transform to display format
        $displayData = $actions | ForEach-Object {
          [PSCustomObject]@{
            Name = if ($_.name) { $_.name } else { 'N/A' }
            Category = if ($_.category) { $_.category } else { 'N/A' }
            Status = 'Enabled'
            Integration = if ($_.integrationId) { $_.integrationId } else { 'N/A' }
            Modified = if ($_.modifiedDate) { $_.modifiedDate } else { '' }
            ModifiedBy = if ($_.modifiedBy -and $_.modifiedBy.name) { $_.modifiedBy.name } else { 'N/A' }
          }
        }

        $h.GridDataActions.ItemsSource = $displayData
        $h.TxtDataActionCount.Text = "($($actions.Count) actions)"
        $h.BtnDataActionExportJson.IsEnabled = $true
        $h.BtnDataActionExportCsv.IsEnabled = $true

        Set-Status "Loaded $($actions.Count) data actions."
      } else {
        Set-Status "Failed to load data actions. Check job logs."
        $h.GridDataActions.ItemsSource = @()
        $h.TxtDataActionCount.Text = "(0 actions)"
      }
    }
  })

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
  $h.TxtDataActionSearch.Add_TextChanged({
    if (-not $script:DataActionsData -or $script:DataActionsData.Count -eq 0) { return }

    $searchText = $h.TxtDataActionSearch.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "search actions...") {
      $displayData = $script:DataActionsData | ForEach-Object {
        [PSCustomObject]@{
          Name = if ($_.name) { $_.name } else { 'N/A' }
          Category = if ($_.category) { $_.category } else { 'N/A' }
          Status = 'Enabled'
          Integration = if ($_.integrationId) { $_.integrationId } else { 'N/A' }
          Modified = if ($_.modifiedDate) { $_.modifiedDate } else { '' }
          ModifiedBy = if ($_.modifiedBy -and $_.modifiedBy.name) { $_.modifiedBy.name } else { 'N/A' }
        }
      }
      $h.GridDataActions.ItemsSource = $displayData
      $h.TxtDataActionCount.Text = "($($script:DataActionsData.Count) actions)"
      return
    }

    $filtered = $script:DataActionsData | Where-Object {
      $json = ($_ | ConvertTo-Json -Compress -Depth 5).ToLower()
      $json -like "*$searchText*"
    }

    $displayData = $filtered | ForEach-Object {
      [PSCustomObject]@{
        Name = if ($_.name) { $_.name } else { 'N/A' }
        Category = if ($_.category) { $_.category } else { 'N/A' }
        Status = 'Enabled'
        Integration = if ($_.integrationId) { $_.integrationId } else { 'N/A' }
        Modified = if ($_.modifiedDate) { $_.modifiedDate } else { '' }
        ModifiedBy = if ($_.modifiedBy -and $_.modifiedBy.name) { $_.modifiedBy.name } else { 'N/A' }
      }
    }

    $h.GridDataActions.ItemsSource = $displayData
    $h.TxtDataActionCount.Text = "($($filtered.Count) actions)"
  })

  # Clear search placeholder on focus
  $h.TxtDataActionSearch.Add_GotFocus({
    if ($h.TxtDataActionSearch.Text -eq "Search actions...") {
      $h.TxtDataActionSearch.Text = ""
    }
  })

  # Restore search placeholder on lost focus if empty
  $h.TxtDataActionSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtDataActionSearch.Text)) {
      $h.TxtDataActionSearch.Text = "Search actions..."
    }
  })

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
            <Button x:Name="BtnExportAll" Content="Export All" Width="110" Height="32"/>
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
    $h.BtnExportSelected.IsEnabled = $false
    $h.BtnExportAll.IsEnabled = $false

    $includeFlows = $h.ChkFlows.IsChecked
    $includeQueues = $h.ChkQueues.IsChecked
    $includeSkills = $h.ChkSkills.IsChecked
    $includeDataActions = $h.ChkDataActions.IsChecked
    $createZip = $h.ChkCreateZip.IsChecked

    Start-AppJob -Name "Export Configuration" -Type "Export" -ScriptBlock {
      param($accessToken, $instanceName, $artifactsDir, $includeFlows, $includeQueues, $includeSkills, $includeDataActions, $createZip)
      
      # Import required modules in runspace
      $scriptRoot = Split-Path -Parent $PSCommandPath
      $coreRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'Core'
      Import-Module (Join-Path -Path $coreRoot -ChildPath 'ConfigExport.psm1') -Force
      Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
      
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
      $h.BtnExportSelected.IsEnabled = $true
      $h.BtnExportAll.IsEnabled = $true

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
          <Button x:Name="BtnQueueLoad" Content="Load Queues" Width="110" Height="32" Margin="0,0,8,0"/>
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

  $script:QueuesData = @()

  $h.BtnQueueLoad.Add_Click({
    Set-Status "Loading queues..."
    $h.BtnQueueLoad.IsEnabled = $false
    $h.BtnQueueExportJson.IsEnabled = $false
    $h.BtnQueueExportCsv.IsEnabled = $false

    Start-AppJob -Name "Load Queues" -Type "Query" -ScriptBlock {
      Get-GcQueues -AccessToken $script:AppState.AccessToken -InstanceName $script:AppState.Region
    } -OnCompleted {
      param($job)
      $h.BtnQueueLoad.IsEnabled = $true

      if ($job.Result) {
        $script:QueuesData = $job.Result
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
        $h.BtnQueueExportJson.IsEnabled = $true
        $h.BtnQueueExportCsv.IsEnabled = $true
        Set-Status "Loaded $($job.Result.Count) queues."
      } else {
        $h.GridQueues.ItemsSource = @()
        $h.TxtQueueCount.Text = "(0 queues)"
        Set-Status "Failed to load queues."
      }
    }
  })

  $h.BtnQueueExportJson.Add_Click({
    if (-not $script:QueuesData -or $script:QueuesData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "queues_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:QueuesData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($script:QueuesData.Count) queues to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  $h.BtnQueueExportCsv.Add_Click({
    if (-not $script:QueuesData -or $script:QueuesData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "queues_$timestamp.csv"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:QueuesData | Select-Object name, @{N='division';E={if($_.division.name){$_.division.name}else{'N/A'}}}, memberCount, dateModified | 
        Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      Set-Status "Exported $($script:QueuesData.Count) queues to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  $h.TxtQueueSearch.Add_TextChanged({
    if (-not $script:QueuesData -or $script:QueuesData.Count -eq 0) { return }

    $searchText = $h.TxtQueueSearch.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "search queues...") {
      $displayData = $script:QueuesData | ForEach-Object {
        [PSCustomObject]@{
          Name = if ($_.name) { $_.name } else { 'N/A' }
          Division = if ($_.division -and $_.division.name) { $_.division.name } else { 'N/A' }
          Members = if ($_.memberCount) { $_.memberCount } else { 0 }
          Active = if ($_.mediaSettings) { 'Yes' } else { 'No' }
          Modified = if ($_.dateModified) { $_.dateModified } else { '' }
        }
      }
      $h.GridQueues.ItemsSource = $displayData
      $h.TxtQueueCount.Text = "($($script:QueuesData.Count) queues)"
      return
    }

    $filtered = $script:QueuesData | Where-Object {
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
  })

  $h.TxtQueueSearch.Add_GotFocus({
    if ($h.TxtQueueSearch.Text -eq "Search queues...") {
      $h.TxtQueueSearch.Text = ""
    }
  })

  $h.TxtQueueSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtQueueSearch.Text)) {
      $h.TxtQueueSearch.Text = "Search queues..."
    }
  })

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
          <Button x:Name="BtnSkillLoad" Content="Load Skills" Width="100" Height="32" Margin="0,0,8,0"/>
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

  $script:SkillsData = @()

  $h.BtnSkillLoad.Add_Click({
    Set-Status "Loading skills..."
    $h.BtnSkillLoad.IsEnabled = $false
    $h.BtnSkillExportJson.IsEnabled = $false
    $h.BtnSkillExportCsv.IsEnabled = $false

    Start-AppJob -Name "Load Skills" -Type "Query" -ScriptBlock {
      Get-GcSkills -AccessToken $script:AppState.AccessToken -InstanceName $script:AppState.Region
    } -OnCompleted {
      param($job)
      $h.BtnSkillLoad.IsEnabled = $true

      if ($job.Result) {
        $script:SkillsData = $job.Result
        $displayData = $job.Result | ForEach-Object {
          [PSCustomObject]@{
            Name = if ($_.name) { $_.name } else { 'N/A' }
            State = if ($_.state) { $_.state } else { 'active' }
            Modified = if ($_.dateModified) { $_.dateModified } else { '' }
          }
        }
        $h.GridSkills.ItemsSource = $displayData
        $h.TxtSkillCount.Text = "($($job.Result.Count) skills)"
        $h.BtnSkillExportJson.IsEnabled = $true
        $h.BtnSkillExportCsv.IsEnabled = $true
        Set-Status "Loaded $($job.Result.Count) skills."
      } else {
        $h.GridSkills.ItemsSource = @()
        $h.TxtSkillCount.Text = "(0 skills)"
        Set-Status "Failed to load skills."
      }
    }
  })

  $h.BtnSkillExportJson.Add_Click({
    if (-not $script:SkillsData -or $script:SkillsData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "skills_$timestamp.json"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:SkillsData | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      Set-Status "Exported $($script:SkillsData.Count) skills to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  $h.BtnSkillExportCsv.Add_Click({
    if (-not $script:SkillsData -or $script:SkillsData.Count -eq 0) {
      Set-Status "No data to export."
      return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "skills_$timestamp.csv"
    $artifactsDir = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'artifacts'
    if (-not (Test-Path $artifactsDir)) {
      New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
    }
    $filepath = Join-Path -Path $artifactsDir -ChildPath $filename

    try {
      $script:SkillsData | Select-Object name, state, dateModified | 
        Export-Csv -Path $filepath -NoTypeInformation -Encoding UTF8
      Set-Status "Exported $($script:SkillsData.Count) skills to $filename"
      Show-Snackbar "Export complete! Saved to artifacts/$filename" -Action "Open Folder" -ActionCallback {
        Start-Process (Split-Path $filepath -Parent)
      }
    } catch {
      Set-Status "Failed to export: $_"
    }
  })

  $h.TxtSkillSearch.Add_TextChanged({
    if (-not $script:SkillsData -or $script:SkillsData.Count -eq 0) { return }

    $searchText = $h.TxtSkillSearch.Text.ToLower()
    if ([string]::IsNullOrWhiteSpace($searchText) -or $searchText -eq "search skills...") {
      $displayData = $script:SkillsData | ForEach-Object {
        [PSCustomObject]@{
          Name = if ($_.name) { $_.name } else { 'N/A' }
          State = if ($_.state) { $_.state } else { 'active' }
          Modified = if ($_.dateModified) { $_.dateModified } else { '' }
        }
      }
      $h.GridSkills.ItemsSource = $displayData
      $h.TxtSkillCount.Text = "($($script:SkillsData.Count) skills)"
      return
    }

    $filtered = $script:SkillsData | Where-Object {
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
  })

  $h.TxtSkillSearch.Add_GotFocus({
    if ($h.TxtSkillSearch.Text -eq "Search skills...") {
      $h.TxtSkillSearch.Text = ""
    }
  })

  $h.TxtSkillSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtSkillSearch.Text)) {
      $h.TxtSkillSearch.Text = "Search skills..."
    }
  })

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
          <Button x:Name="BtnSnapshotRefresh" Content="Refresh Now" Width="110" Height="32" Margin="0,0,8,0"/>
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

  $script:RoutingSnapshotData = $null
  $script:RoutingSnapshotTimer = $null

  # Function to refresh snapshot
  $refreshSnapshot = {
    Set-Status "Refreshing routing snapshot..."
    $h.BtnSnapshotRefresh.IsEnabled = $false

    $coreModulePath = Join-Path -Path $coreRoot -ChildPath 'RoutingPeople.psm1'
    $httpModulePath = Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1'

    Start-AppJob -Name "Refresh Routing Snapshot" -Type "Query" -ScriptBlock {
      param($coreModulePath, $httpModulePath, $accessToken, $region)
      
      Import-Module $httpModulePath -Force
      Import-Module $coreModulePath -Force
      
      Get-GcRoutingSnapshot -AccessToken $accessToken -InstanceName $region
    } -ArgumentList @($coreModulePath, $httpModulePath, $script:AppState.AccessToken, $script:AppState.Region) -OnCompleted {
      param($job)
      $h.BtnSnapshotRefresh.IsEnabled = $true

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
        
        $h.BtnSnapshotExport.IsEnabled = $true
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

  $script:UsersData = @()

  $h.BtnUserLoad.Add_Click({
    Set-Status "Loading users..."
    $h.BtnUserLoad.IsEnabled = $false
    $h.BtnUserExportJson.IsEnabled = $false
    $h.BtnUserExportCsv.IsEnabled = $false

    Start-AppJob -Name "Load Users" -Type "Query" -ScriptBlock {
      param($accessToken, $instanceName)
      
      # Import required modules in runspace
      $scriptRoot = Split-Path -Parent $PSCommandPath
      $coreRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'Core'
      Import-Module (Join-Path -Path $coreRoot -ChildPath 'RoutingPeople.psm1') -Force
      Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
      
      Get-GcUsers -AccessToken $accessToken -InstanceName $instanceName
    } -ArgumentList @($script:AppState.AccessToken, $script:AppState.Region) -OnCompleted {
      param($job)
      $h.BtnUserLoad.IsEnabled = $true

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
        $h.BtnUserExportJson.IsEnabled = $true
        $h.BtnUserExportCsv.IsEnabled = $true
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
  })

  $h.TxtUserSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtUserSearch.Text)) {
      $h.TxtUserSearch.Text = "Search users..."
    }
  })

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
      $h.BtnStart.IsEnabled = $false
      $h.BtnStop.IsEnabled  = $true
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
      $h.BtnStart.IsEnabled = $true
      $h.BtnStop.IsEnabled  = $false
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
      $h.TxtSearch.Text = ''
    }
  })

  # Restore search placeholder on lost focus if empty
  $h.TxtSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($h.TxtSearch.Text)) {
      $h.TxtSearch.Text = 'search (conversationId, error, agent…)'
    }
  })

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
    Start-AppJob -Name "Open Timeline — $conv" -Type 'Timeline' -ScriptBlock $script:TimelineJobScriptBlock -ArgumentList @($conv, $script:AppState.Region, $script:AppState.AccessToken, $script:AppState.EventBuffer) `
    -OnCompleted {
      param($job)

      if ($job.Result -and $job.Result.Timeline) {
        $result = $job.Result
        Set-Status "Timeline ready for conversation $($result.ConversationId) with $($result.Timeline.Count) events."

        # Show timeline window
        Show-TimelineWindow `
          -ConversationId $result.ConversationId `
          -TimelineEvents $result.Timeline `
          -SubscriptionEvents $result.SubscriptionEvents
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

      # Import required modules in runspace
      $scriptRoot = Split-Path -Parent $PSCommandPath
      $coreRoot = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'Core'
      Import-Module (Join-Path -Path $coreRoot -ChildPath 'ArtifactGenerator.psm1') -Force

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
    default {
      $MainHost.Content = (New-PlaceholderView -Title $module -Hint "Module shell for $workspace. UX-first; job-driven backend later.")
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
# Add right-click context menu to Login button for manual token entry
$loginContextMenu = New-Object System.Windows.Controls.ContextMenu

$pasteTokenMenuItem = New-Object System.Windows.Controls.MenuItem
$pasteTokenMenuItem.Header = "Paste Token…"
$pasteTokenMenuItem.Add_Click({
  Show-SetTokenDialog
})

$loginContextMenu.Items.Add($pasteTokenMenuItem) | Out-Null
$BtnLogin.ContextMenu = $loginContextMenu
### END: Manual Token Entry

$BtnLogin.Add_Click({
  Write-GcDiag ("Login button clicked (HasToken={0}, Region='{1}')" -f [bool]$script:AppState.AccessToken, $script:AppState.Region)
  # Check if already logged in - if so, logout
  if ($script:AppState.AccessToken) {
    Write-GcDiag "Login button: logging out (clearing token state)"
    # Logout: Clear token and reset UI
    # Clear-GcTokenState clears the Auth module's token state
    # We also clear AppState.AccessToken (application-level state) for complete logout
    Clear-GcTokenState
    $script:AppState.AccessToken = $null
    $script:AppState.Auth = "Not logged in"
    $script:AppState.TokenStatus = "No token"

    Set-TopContext
    Set-Status "Logged out successfully."

    $BtnLogin.Content = "Login…"
    $BtnTestToken.IsEnabled = $false
    return
  }

  # Login flow
  $authConfig = Get-GcAuthConfig
  Write-GcDiag ("OAuth config snapshot: Region='{0}' ClientId='{1}' RedirectUri='{2}' Scopes='{3}' HasClientSecret={4}" -f $authConfig.Region, $authConfig.ClientId, $authConfig.RedirectUri, ($authConfig.Scopes -join ' '), (-not [string]::IsNullOrWhiteSpace($authConfig.ClientSecret)))

  # Check if client ID is configured
  if ($authConfig.ClientId -eq 'YOUR_CLIENT_ID_HERE' -or -not $authConfig.ClientId) {
    [System.Windows.MessageBox]::Show(
      "Please configure your OAuth Client ID in the script.`n`nSet-GcAuthConfig -ClientId 'your-client-id' -Region 'your-region'",
      "Configuration Required",
      [System.Windows.MessageBoxButton]::OK,
      [System.Windows.MessageBoxImage]::Warning
    )
    return
  }

  # Disable button during auth
  $BtnLogin.IsEnabled = $false
  $BtnLogin.Content = "Authenticating..."
  Set-Status "Starting OAuth flow..."

  # Run OAuth flow in background
  $authModulePath = Join-Path -Path $coreRoot -ChildPath 'Auth.psm1'
  $authConfigSnapshot = Get-GcAuthConfig
  Write-GcDiag ("Starting OAuth Login job (AuthModule='{0}', ArtifactsDir='{1}')" -f $authModulePath, $script:ArtifactsDir)

  Start-AppJob -Name "OAuth Login" -Type "Auth" -ScriptBlock {
    param($authModulePath, $authConfigSnapshot, $artifactsDir)

    Import-Module $authModulePath -Force
    Enable-GcAuthDiagnostics -LogDirectory $artifactsDir | Out-Null

    # Re-apply auth configuration inside the job runspace (module state is per-runspace).
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

    if ($job.Result -and $job.Result.Success) {
      Write-GcDiag ("OAuth Login: SUCCESS (Token={0})" -f (Format-GcDiagSecret -Value $job.Result.AccessToken))
      if ($job.Result.AuthLogPath) { Write-GcDiag ("OAuth Login: Auth diagnostics log: {0}" -f $job.Result.AuthLogPath) }

      $script:AppState.AccessToken = $job.Result.AccessToken
      $script:AppState.Auth = "Logged in"
      $script:AppState.TokenStatus = "Token OK"

      if ($job.Result.UserInfo) {
        $script:AppState.Auth = "Logged in as $($job.Result.UserInfo.name)"
      }

      Set-TopContext
      Set-Status "Authentication successful!"
      $BtnLogin.Content = "Logout"
      $BtnLogin.IsEnabled = $true
      $BtnTestToken.IsEnabled = $true
    } else {
      $err = $null
      if ($job.Result) { $err = $job.Result.Error }
      Write-GcDiag ("OAuth Login: FAILED (Error='{0}')" -f $err)
      $BtnTestToken.IsEnabled = $false

      $script:AppState.Auth = "Login failed"
      $script:AppState.TokenStatus = "No token"
      Set-TopContext
      $authLogPath = $null
      if ($job.Result -and $job.Result.AuthLogPath) { $authLogPath = $job.Result.AuthLogPath }
      try {
        $combined = @()
        if ($job.Errors) { $combined += @($job.Errors) }
        if ($job.Logs) { $combined += @($job.Logs) }
        $text = ($combined -join "`n")
        if ($text -match 'Auth diagnostics:\s*(?<p>[^)\r\n]+)') {
          $authLogPath = $matches['p'].Trim()
        }
      } catch { }

      if ($authLogPath) {
        Write-GcDiag ("OAuth Login: Auth diagnostics log: {0}" -f $authLogPath)
        try {
          if (Test-Path -LiteralPath $authLogPath) {
            $tail = Get-Content -LiteralPath $authLogPath -Tail 80 -ErrorAction SilentlyContinue
            Write-GcDiag ("OAuth Login: last {0} auth log lines:" -f @($tail).Count)
            foreach ($l in @($tail)) { Write-Host $l }
          }
        } catch { }
        Set-Status "Authentication failed. Auth log: $authLogPath"
      } else {
        Set-Status "Authentication failed. Check job logs for details."
      }
      $BtnLogin.Content = "Login…"
      $BtnLogin.IsEnabled = $true
    }
  }
})

$BtnTestToken.Add_Click({
  Write-GcDiag ("Test Token button clicked (HasToken={0}, Region='{1}')" -f [bool]$script:AppState.AccessToken, $script:AppState.Region)
  ### BEGIN: Manual Token Entry
  # If no token exists, open the manual token entry dialog instead of showing an error
  if (-not $script:AppState.AccessToken) {
    Write-GcDiag "Test Token: no token set -> opening manual token dialog"
    Show-SetTokenDialog
    return
  }

  # Use the dedicated token test function
  Write-GcDiag "Test Token: token exists -> running Start-TokenTest"
  Start-TokenTest
  ### END: Manual Token Entry
})

$BtnJobs.Add_Click({ Open-Backstage -Tab 'Jobs' })
$BtnArtifacts.Add_Click({ Open-Backstage -Tab 'Artifacts' })

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
