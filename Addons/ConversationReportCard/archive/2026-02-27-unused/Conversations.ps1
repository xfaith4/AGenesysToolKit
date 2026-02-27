# Conversations.ps1
# -----------------------------------------------------------------------------
# Conversations workspace views: Conversation Lookup, Timeline, Analytics Jobs, Incident Packet, Abandon & Experience, Media & Quality
#
# Dot-sourced by GenesysCloudTool.ps1 at startup.
# All functions depend on helpers defined in the main script (Get-El,
# Set-Status, Start-AppJob, Set-ControlEnabled, etc.) which are in
# scope at call time since dot-sourcing completes before the window opens.
# -----------------------------------------------------------------------------

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
            <Button x:Name="BtnConvExportJson" Content="Export JSON" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"
                    ToolTip="Run a search first — export becomes available once results are loaded."/>
            <Button x:Name="BtnConvExportCsv" Content="Export CSV" Width="100" Height="32" IsEnabled="False"
                    ToolTip="Run a search first — export becomes available once results are loaded."/>
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
    Set-ControlEnabled -Control $btnConvSearch -Enabled $false
    Set-ControlEnabled -Control $btnConvExportJson -Enabled $false -DisabledReason 'Searching — export will be available once results are loaded.'
    Set-ControlEnabled -Control $btnConvExportCsv -Enabled $false -DisabledReason 'Searching — export will be available once results are loaded.'
    Set-ControlEnabled -Control $btnConvOpenTimeline -Enabled $false

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

      $authReady = Test-AuthReady
      $authReason = if ($authReady) { $null } else { Get-AuthUnavailableReason }
      Set-ControlEnabled -Control $btnConvSearch -Enabled $authReady -DisabledReason $authReason

      $results = @($job.Result)
      if ($results.Count -gt 0) {
        $script:ConversationsData = $results
        $displayData = $results | ForEach-Object {
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
        if ($txtConvCount) { $txtConvCount.Text = "($($results.Count) conversations)" }
        Set-ControlEnabled -Control $btnConvExportJson -Enabled $true
        Set-ControlEnabled -Control $btnConvExportCsv -Enabled $true
        Set-ControlEnabled -Control $btnConvOpenTimeline -Enabled $false
        Set-Status "Found $($results.Count) conversations."
      } else {
        $script:ConversationsData = @()
        if ($gridConversations) { $gridConversations.ItemsSource = @() }
        if ($txtConvCount) { $txtConvCount.Text = "(0 conversations)" }
        Set-ControlEnabled -Control $btnConvExportJson -Enabled $false -DisabledReason 'No conversations found. Refine your search criteria and try again.'
        Set-ControlEnabled -Control $btnConvExportCsv -Enabled $false -DisabledReason 'No conversations found. Refine your search criteria and try again.'
        Set-ControlEnabled -Control $btnConvOpenTimeline -Enabled $false
        Set-Status "Search failed or returned no results."
      }
    }.GetNewClosure())
  }.GetNewClosure()) }

  if ($gridConversations -and $btnConvOpenTimeline) {
    $gridConversations.Add_SelectionChanged({
      $selected = $gridConversations.SelectedItem
      $canOpen = $false
      if ($selected -and $selected.PSObject.Properties.Match('ConversationId').Count -gt 0) {
        $convId = [string]$selected.ConversationId
        $canOpen = (-not [string]::IsNullOrWhiteSpace($convId) -and $convId -ne 'N/A')
      }
      Set-ControlEnabled -Control $btnConvOpenTimeline -Enabled $canOpen
    }.GetNewClosure())
  }

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
          $convId = $null
          try { if ($_.conversationId) { $convId = $_.conversationId } } catch { }
          if (-not $convId) {
            try { if ($_.conversation -and $_.conversation.id) { $convId = $_.conversation.id } } catch { }
          }

          [PSCustomObject]@{
            RecordingId = if ($_.id) { $_.id } else { 'N/A' }
            ConversationId = if ($convId) { $convId } else { 'N/A' }
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

