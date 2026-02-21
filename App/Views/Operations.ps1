# Operations.ps1
# -----------------------------------------------------------------------------
# Operations workspace views: Topic Subscriptions, Operational Event Logs, Audit Logs, OAuth / Token Usage
#
# Dot-sourced by GenesysCloudTool.ps1 at startup.
# All functions depend on helpers defined in the main script (Get-El,
# Set-Status, Start-AppJob, Set-ControlEnabled, etc.) which are in
# scope at call time since dot-sourcing completes before the window opens.
# -----------------------------------------------------------------------------

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
      param($startTime, $endTime, $accessToken, $region)

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
          -InstanceName $region -AccessToken $accessToken -MaxItems $maxItems

        return $results
      } catch {
        Write-Error "Failed to query operational events: $_"
        return @()
      }
    } -ArgumentList @($startTime, $endTime, $script:AppState.AccessToken, $script:AppState.Region) -OnCompleted ({
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
      param($startTime, $endTime, $accessToken, $region)

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
          -InstanceName $region -AccessToken $accessToken -MaxItems $maxItems

        return $results
      } catch {
        Write-Error "Failed to query audit logs: $_"
        return @()
      }
    } -ArgumentList @($startTime, $endTime, $script:AppState.AccessToken, $script:AppState.Region) -OnCompleted ({
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
      param($accessToken, $region)
      # Use Invoke-GcPagedRequest to query OAuth clients
      $maxItems = 500  # Limit to prevent excessive API calls
      try {
        $results = Invoke-GcPagedRequest -Path '/api/v2/oauth/clients' -Method GET `
          -InstanceName $region -AccessToken $accessToken -MaxItems $maxItems

        return $results
      } catch {
        Write-Error "Failed to query OAuth clients: $_"
        return @()
      }
    } -ArgumentList @($script:AppState.AccessToken, $script:AppState.Region) -OnCompleted ({
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

