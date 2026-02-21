# Reports.ps1
# -----------------------------------------------------------------------------
# Reports & Exports workspace views: Report Builder, Export History, Quick Exports
#
# Dot-sourced by GenesysCloudTool.ps1 at startup.
# All functions depend on helpers defined in the main script (Get-El,
# Set-Status, Start-AppJob, Set-ControlEnabled, etc.) which are in
# scope at call time since dot-sourcing completes before the window opens.
# -----------------------------------------------------------------------------

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

  $setReportExportAvailability = {
    param($bundle)

    $hasHtml = [bool]($bundle -and $bundle.ReportHtmlPath -and (Test-Path $bundle.ReportHtmlPath))
    $hasJson = [bool]($bundle -and $bundle.DataJsonPath -and (Test-Path $bundle.DataJsonPath))
    $hasCsv = [bool]($bundle -and $bundle.DataCsvPath -and (Test-Path $bundle.DataCsvPath))
    $hasXlsx = [bool]($bundle -and $bundle.DataXlsxPath -and (Test-Path $bundle.DataXlsxPath))
    $hasBundleFolder = [bool]($bundle -and $bundle.BundlePath -and (Test-Path $bundle.BundlePath))

    Set-ControlEnabled -Control $h.BtnOpenInBrowser -Enabled $hasHtml -DisabledReason 'Run a report first to generate an HTML preview.'
    Set-ControlEnabled -Control $h.BtnExportHtml -Enabled $hasHtml -DisabledReason 'Run a report first to generate report HTML.'
    Set-ControlEnabled -Control $h.BtnExportJson -Enabled $hasJson -DisabledReason 'Run a report first to generate JSON output.'
    Set-ControlEnabled -Control $h.BtnExportCsv -Enabled $hasCsv -DisabledReason 'Run a report first to generate CSV output.'
    Set-ControlEnabled -Control $h.BtnExportExcel -Enabled $hasXlsx -DisabledReason 'Excel output is unavailable until a report is run with ImportExcel support.'
    Set-ControlEnabled -Control $h.BtnCopyPath -Enabled $hasBundleFolder -DisabledReason 'Run a report first to create an artifact bundle path.'
    Set-ControlEnabled -Control $h.BtnOpenFolder -Enabled $hasBundleFolder -DisabledReason 'Run a report first to create an artifact folder.'
  }.GetNewClosure()

  $updateRunReportAvailability = {
    param([bool]$HasTemplateSelected)

    $authReady = Test-AuthReady
    $enabled = ($authReady -and $HasTemplateSelected)

    $reason = $null
    if (-not $authReady) {
      $reason = Get-AuthUnavailableReason
    } elseif (-not $HasTemplateSelected) {
      $reason = 'Select a report template to enable this action.'
    }

    Set-ControlEnabled -Control $h.BtnRunReport -Enabled $enabled -DisabledReason $reason

    if ($h.BtnRunReport) {
      if ($enabled) {
        $h.BtnRunReport.Content = "Run Report ▶"
      } elseif (-not $HasTemplateSelected) {
        $h.BtnRunReport.Content = "Run Report (Select a template first)"
      } else {
        $h.BtnRunReport.Content = "Run Report (Authentication required)"
      }
    }
  }.GetNewClosure()

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

        # Enable Run Report based on both template selection and auth readiness.
        try { & $updateRunReportAvailability $true } catch { }

        # Build parameter panel
        & $buildParameterPanel $template

        # Reset current report
        $currentReportBundle = $null
        try { & $setReportExportAvailability $null } catch { }
      } else {
        # No selection - disable Run Report button
        try {
          & $updateRunReportAvailability $false
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
          Set-ControlEnabled -Control $h.BtnRunReport -Enabled $false -DisabledReason "Report is running. Wait for completion before starting another run."
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
            & $updateRunReportAvailability $true
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
            & $updateRunReportAvailability $true
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

            # Enable export buttons and artifact actions for generated outputs.
            try { & $setReportExportAvailability $bundle } catch { }

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
            try { & $setReportExportAvailability $null } catch { }
          }
        }.GetNewClosure())
      } catch {
        Write-GcTrace -Level 'ERROR' -Message "BtnRunReport.Click error: $($_.Exception.Message)"
        try {
          Set-Status "✗ Error: $($_.Exception.Message)"
          & $updateRunReportAvailability $true
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
  & $setReportExportAvailability $null
  & $updateRunReportAvailability $false

  # Select first template by default
  if ($h.LstTemplates.Items.Count -gt 0) {
    $h.LstTemplates.SelectedIndex = 0
  }

  return $view
}

