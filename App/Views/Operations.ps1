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

