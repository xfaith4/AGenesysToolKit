### BEGIN FILE: GenesysCloudTool_UX_Prototype_v2_1.ps1
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
  -Region 'mypurecloud.com' `
  -ClientId 'YOUR_CLIENT_ID_HERE' `
  -RedirectUri 'http://localhost:8400/oauth/callback' `
  -Scopes @('conversations', 'analytics', 'notifications', 'users')

$script:AppState = [ordered]@{
  Region       = 'mypurecloud.com'
  Org          = 'Production'
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
    'Conversations::Conversation Timeline' {
      $TxtSubtitle.Text = 'Timeline-first: evidence → story → export'
      $MainHost.Content = (New-ConversationTimelineView)
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
$BtnLogin.Add_Click({
  # Check if already logged in - if so, logout
  if ($script:AppState.AccessToken) {
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
  Start-AppJob -Name "OAuth Login" -Type "Auth" -ScriptBlock {
    try {
      $tokenResponse = Get-GcTokenAsync -TimeoutSeconds 300
      return $tokenResponse
    } catch {
      Write-Error $_
      return $null
    }
  } -OnCompleted {
    param($job)

    if ($job.Result) {
      $tokenState = Get-GcTokenState
      $script:AppState.AccessToken = $tokenState.AccessToken
      $script:AppState.Auth = "Logged in"
      $script:AppState.TokenStatus = "Token OK"

      if ($tokenState.UserInfo) {
        $script:AppState.Auth = "Logged in as $($tokenState.UserInfo.name)"
      }

      Set-TopContext
      Set-Status "Authentication successful!"
      $BtnLogin.Content = "Logout"
      $BtnLogin.IsEnabled = $true
      $BtnTestToken.IsEnabled = $true
    } else {
      $script:AppState.Auth = "Login failed"
      $script:AppState.TokenStatus = "No token"
      Set-TopContext
      Set-Status "Authentication failed. Check job logs for details."
      $BtnLogin.Content = "Login…"
      $BtnLogin.IsEnabled = $true
    }
  }
})

$BtnTestToken.Add_Click({
  # STEP 1 CHANGE: Updated Test Token handler to use Invoke-AppGcRequest wrapper
  # This validates the token by calling GET /api/v2/users/me with auto-injected auth

  if (-not $script:AppState.AccessToken) {
    # Show error if no token is set
    [System.Windows.MessageBox]::Show(
      "No access token available. Please set AppState.AccessToken or use the Login button.",
      "No Token",
      [System.Windows.MessageBoxButton]::OK,
      [System.Windows.MessageBoxImage]::Warning
    )
    Set-Status "No token available."
    return
  }

  # Disable button during test
  $BtnTestToken.IsEnabled = $false
  $BtnTestToken.Content = "Testing..."
  Set-Status "Testing token..."

  # Queue background job to test token via GET /api/v2/users/me
  Start-AppJob -Name "Test Token" -Type "Auth" -ScriptBlock {
    # Note: No parameters needed - Invoke-AppGcRequest reads from AppState
    try {
      # STEP 1: Call GET /api/v2/users/me using Invoke-AppGcRequest
      # The wrapper automatically injects AccessToken and InstanceName from AppState
      $userInfo = Invoke-AppGcRequest -Path '/api/v2/users/me' -Method GET

      return [PSCustomObject]@{
        Success = $true
        UserInfo = $userInfo
        Error = $null
      }
    } catch {
      # Capture detailed error information for better diagnostics
      $errorMessage = $_.Exception.Message
      $statusCode = $null

      # Try to extract HTTP status code if available
      if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
      }

      return [PSCustomObject]@{
        Success = $false
        UserInfo = $null
        Error = $errorMessage
        StatusCode = $statusCode
      }
    }
  } -OnCompleted {
    param($job)

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
      if ($errorMsg -match "401|Unauthorized") {
        $userMessage = "Token Invalid or Expired"
        $detailMessage = "The access token is not valid or has expired. Please log in again."
      }
      elseif ($errorMsg -match "Unable to connect|could not be resolved|Name or service not known") {
        $userMessage = "Connection Failed"
        $detailMessage = "Cannot connect to region '$($script:AppState.Region)'. Please verify:`n• Region is correct`n• Network connection is available`n`nError: $errorMsg"
      }
      elseif ($errorMsg -match "404|Not Found") {
        $userMessage = "Endpoint Not Found"
        $detailMessage = "API endpoint not found. This may indicate:`n• Wrong region configured`n• API version mismatch`n`nError: $errorMsg"
      }
      elseif ($errorMsg -match "403|Forbidden") {
        $userMessage = "Permission Denied"
        $detailMessage = "Token is valid but lacks permission to access user information."
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
### END FILE
