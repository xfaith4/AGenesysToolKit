# Orchestration.ps1
# -----------------------------------------------------------------------------
# Orchestration workspace views: Flows, Data Actions, Config Export, Dependency / Impact Map
#
# Dot-sourced by GenesysCloudTool.ps1 at startup.
# All functions depend on helpers defined in the main script (Get-El,
# Set-Status, Start-AppJob, Set-ControlEnabled, etc.) which are in
# scope at call time since dot-sourcing completes before the window opens.
# -----------------------------------------------------------------------------

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
      param($accessToken, $region)
      # Query flows using Genesys Cloud API
      $maxItems = 500  # Limit to prevent excessive API calls
      try {
        $results = Invoke-GcPagedRequest -Path '/api/v2/flows' -Method GET `
          -InstanceName $region -AccessToken $accessToken -MaxItems $maxItems

        return $results
      } catch {
        Write-Error "Failed to load flows: $_"
        return @()
      }
    } -ArgumentList @($script:AppState.AccessToken, $script:AppState.Region) -OnCompleted {
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
                       Text="{} { &quot;hint&quot;: &quot;Select a data action to view the raw payload.&quot; }"/>
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
    try { $searchText = [string]$txtSearch.Text } catch { $searchText = '' }
    if ($null -eq $searchText) { $searchText = '' }
    $searchText = $searchText.ToLower()

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

