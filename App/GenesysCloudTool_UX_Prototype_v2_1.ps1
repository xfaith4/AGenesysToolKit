### BEGIN FILE: GenesysCloudTool_UX_Prototype_v2_1.ps1
# Genesys Cloud Tool — UX Prototype v2.1
# UX-first shell: Workspaces + Modules + non-blocking Job Center + Backstage Artifacts + Export Snackbar.
# Backend operations are mocked (timers + simulated events). Goal: validate information architecture + workflow ergonomics.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

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
$script:AppState = [ordered]@{
  Region       = 'mypurecloud.com'
  Org          = 'Production'
  Auth         = 'Not logged in'
  TokenStatus  = 'No token'

  Workspace    = 'Operations'
  Module       = 'Topic Subscriptions'
  IsStreaming  = $false

  Jobs         = New-Object System.Collections.ObjectModel.ObservableCollection[object]
  Artifacts    = New-Object System.Collections.ObjectModel.ObservableCollection[object]

  PinnedCount  = 0
  StreamCount  = 0
  FocusConversationId = ''
}

$script:ArtifactsDir = Join-Path -Path $PSScriptRoot -ChildPath 'artifacts'
New-Item -ItemType Directory -Path $script:ArtifactsDir -Force | Out-Null

function New-Artifact {
  param([string]$Name, [string]$Path)
  [pscustomobject]@{
    Name    = $Name
    Path    = $Path
    Created = Get-Date
  }
}

function New-Job {
  param([string]$Name, [string]$Type = 'General')
  [pscustomobject]@{
    Id        = [Guid]::NewGuid().ToString()
    Name      = $Name
    Type      = $Type
    Status    = 'Queued'
    Progress  = 0
    Started   = $null
    Ended     = $null
    Logs      = New-Object System.Collections.ObjectModel.ObservableCollection[string]
    CanCancel = $true
  }
}

function Add-JobLog {
  param([object]$Job, [string]$Message)
  $ts = (Get-Date).ToString('HH:mm:ss')
  $Job.Logs.Add("[$ts] $Message") | Out-Null
}

function Start-JobSim {
  param(
    [object]$Job,
    [int]$DurationMs = 1800,
    [scriptblock]$OnComplete,
    [scriptblock]$OnTick
  )

  $Job.Status  = 'Running'
  $Job.Started = Get-Date
  Add-JobLog -Job $Job -Message "Started ($($Job.Type))."

  $ticks = [Math]::Max(6, [int]($DurationMs / 250))
  $step  = [Math]::Max(1, [int](100 / $ticks))

  $timer = New-Object Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(250)

  $timer.Add_Tick({
    if ($Job.Status -eq 'Canceled') {
      $timer.Stop()
      Add-JobLog -Job $Job -Message "Canceled."
      $Job.Ended = Get-Date
      return
    }

    $Job.Progress = [Math]::Min(100, $Job.Progress + $step)
    if ($OnTick) { & $OnTick $Job }

    if ($Job.Progress -ge 100) {
      $timer.Stop()
      $Job.Status    = 'Completed'
      $Job.Ended     = Get-Date
      $Job.CanCancel = $false
      Add-JobLog -Job $Job -Message "Completed."
      if ($OnComplete) { & $OnComplete $Job }
    }
  })

  $timer.Start()
  return $timer
}

function Queue-Job {
  param(
    [string]$Name,
    [string]$Type = 'General',
    [int]$DurationMs = 1800,
    [scriptblock]$OnComplete
  )

  $job = New-Job -Name $Name -Type $Type
  $script:AppState.Jobs.Add($job) | Out-Null
  Add-JobLog -Job $job -Message "Queued."

  Start-JobSim -Job $job -DurationMs $DurationMs -OnComplete $OnComplete | Out-Null
  return $job
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
                   Text="{ &quot;hint&quot;: &quot;Select an event to view raw payload, correlation IDs, and media stats.&quot; }"/>
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
    if (-not $conv) { $conv = "c-$(Get-Random -Minimum 100000 -Maximum 999999)" ; $txtConv.Text = $conv }

    $lst.Items.Clear()
    $events = @(
      "13:20:01  Call connected (conv=$conv)",
      "13:20:17  Entered IVR",
      "13:21:02  Entered Queue: Support - Voice",
      "13:22:44  WebRTC errorCode: ICE_FAILED",
      "13:23:10  Agent connected: a-$(Get-Random -Minimum 1000 -Maximum 9999)",
      "13:24:05  MOS dropped below 3.5 (jitter spike)",
      "13:25:40  Hold started",
      "13:26:02  Hold ended",
      "13:27:18  Recording: enabled"
    )
    foreach ($e in $events) { $lst.Items.Add($e) | Out-Null }
    Set-Status "Timeline built (mock) for $conv."
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

    Queue-Job -Name "Export Incident Packet (Timeline) — $conv" -Type 'Export' -DurationMs 1400 -OnComplete {
      $file = Join-Path -Path $script:ArtifactsDir -ChildPath "incident-packet-$($conv)-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
      @(
        "Incident Packet (mock)",
        "ConversationId: $conv",
        "Generated: $(Get-Date)",
        "",
        "Contents would include:",
        "- conversation summary JSON",
        "- timeline events",
        "- media stats (MOS, jitter, packet loss)",
        "- WebRTC error codes",
        "- subscription event slice + transcript (if applicable)"
      ) | Set-Content -Path $file -Encoding UTF8

      Add-ArtifactAndNotify -Name "Incident Packet — $conv" -Path $file -ToastTitle 'Export complete'
      Set-Status "Exported incident packet (mock): $file"
    } | Out-Null

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
  if ($null -ne $script:StreamTimer) {
    $script:StreamTimer.Stop() | Out-Null
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

    [pscustomobject]@{
      ts = (Get-Date).ToString('HH:mm:ss.fff')
      type = $etype
      severity = $sev
      conversationId = $conv
      queue = $h.TxtQueue.Text
      text = ($snips | Get-Random)
    }
  }

  $script:StreamTimer.Add_Tick({
    if (-not $script:AppState.IsStreaming) { return }

    $evt = New-MockEvent
    $line = "[$($evt.ts)] [$($evt.severity)] $($evt.type)  conv=$($evt.conversationId)  —  $($evt.text)"
    $h.LstEvents.Items.Insert(0, $line) | Out-Null

    if ($evt.type -like 'audiohook.transcription*') { Append-TranscriptLine "$($evt.ts)  $($evt.text)" }
    if ($evt.type -like 'audiohook.agentassist*')   { Append-TranscriptLine "$($evt.ts)  [Agent Assist] $($evt.text)" }
    if ($evt.type -eq 'audiohook.error')            { Append-TranscriptLine "$($evt.ts)  [ERROR] $($evt.text)" }

    $script:AppState.StreamCount++
    Refresh-HeaderStats

    if ($h.LstEvents.Items.Count -gt 250) {
      $h.LstEvents.Items.RemoveAt($h.LstEvents.Items.Count - 1)
    }
  })
  $script:StreamTimer.Start()

  # Actions
  $h.BtnStart.Add_Click({
    if ($script:AppState.IsStreaming) { return }

    Queue-Job -Name "Connect subscription (AudioHook / Agent Assist)" -Type 'Subscription' -DurationMs 1200 -OnComplete {
      $script:AppState.IsStreaming = $true
      $h.BtnStart.IsEnabled = $false
      $h.BtnStop.IsEnabled  = $true
      Set-Status "Subscription started (mock)."
      Refresh-HeaderStats
    } | Out-Null

    Refresh-HeaderStats
  })

  $h.BtnStop.Add_Click({
    if (-not $script:AppState.IsStreaming) { return }

    Queue-Job -Name "Disconnect subscription" -Type 'Subscription' -DurationMs 700 -OnComplete {
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
      $script:AppState.PinnedCount++
      Refresh-HeaderStats
      Set-Status "Pinned event (mock)."
    }
  })

  $h.BtnOpenTimeline.Add_Click({
    # Derive conversation ID from selected event if possible
    $conv = ''
    if ($h.LstEvents.SelectedItem) {
      $s = [string]$h.LstEvents.SelectedItem
      if ($s -match 'conv=(?<cid>c-\d+)\s') { $conv = $matches['cid'] }
    }
    if (-not $conv -and $h.TxtConv.Text -and $h.TxtConv.Text -ne '(optional)') { $conv = $h.TxtConv.Text }
    if (-not $conv) { $conv = "c-$(Get-Random -Minimum 100000 -Maximum 999999)" }

    $script:AppState.FocusConversationId = $conv
    Set-Status "Opening Conversation Timeline for $conv (mock)."
    Show-WorkspaceAndModule -Workspace 'Conversations' -Module 'Conversation Timeline'
  })

  $h.BtnExportPacket.Add_Click({
    $conv = if ($h.TxtConv.Text -and $h.TxtConv.Text -ne '(optional)') { $h.TxtConv.Text } else { "c-$(Get-Random -Minimum 100000 -Maximum 999999)" }

    Queue-Job -Name "Export Incident Packet (Subscription) — $conv" -Type 'Export' -DurationMs 1400 -OnComplete {
      $file = Join-Path -Path $script:ArtifactsDir -ChildPath "incident-packet-sub-$($conv)-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
      @(
        "Incident Packet (mock) — Subscription Evidence",
        "ConversationId: $conv",
        "Generated: $(Get-Date)",
        "",
        "Would include:",
        "- subscription event slice (NDJSON)",
        "- transcript.txt (stitched)",
        "- agent_assist_cards.json",
        "- summary.md / summary.html",
        "- any pinned events",
        "- correlation IDs for follow-up"
      ) | Set-Content -Path $file -Encoding UTF8

      Add-ArtifactAndNotify -Name "Incident Packet (Sub) — $conv" -Path $file -ToastTitle 'Export complete'
      Set-Status "Exported incident packet (mock): $file"
    } | Out-Null

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
  $script:AppState.Auth        = 'Logged in (mock)'
  $script:AppState.TokenStatus = 'Token OK (mock)'
  Set-TopContext
  Set-Status "Auth updated (mock)."
})

$BtnTestToken.Add_Click({
  Set-Status "Token test: OK (mock)."
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
