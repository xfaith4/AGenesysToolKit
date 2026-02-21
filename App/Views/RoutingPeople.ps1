# RoutingPeople.ps1
# -----------------------------------------------------------------------------
# Routing & People workspace views: Queues, Skills, Users & Presence, Routing Snapshot
#
# Dot-sourced by GenesysCloudTool.ps1 at startup.
# All functions depend on helpers defined in the main script (Get-El,
# Set-Status, Start-AppJob, Set-ControlEnabled, etc.) which are in
# scope at call time since dot-sourcing completes before the window opens.
# -----------------------------------------------------------------------------

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

