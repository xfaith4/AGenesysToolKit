#requires -Version 5.1

function New-GcSanitizeConversationJsonAddonView {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Addon
  )

  $addonDir = Split-Path -Parent $PSCommandPath
  $implPath = Join-Path -Path $addonDir -ChildPath 'Sanitize-GcConversationJson.Function.ps1'

  $title = if ($Addon.Name) { [string]$Addon.Name } else { 'Sanitize Conversation JSON' }
  $desc = if ($Addon.Description) { [string]$Addon.Description } else { 'Remove PII from Genesys Cloud conversation JSON exports.' }

  $escapedTitle = if (Get-Command Escape-GcXml -ErrorAction SilentlyContinue) { Escape-GcXml $title } else { $title }
  $escapedDesc = if (Get-Command Escape-GcXml -ErrorAction SilentlyContinue) { Escape-GcXml $desc } else { $desc }

  $xaml = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,12">
      <StackPanel>
        <TextBlock Text="$escapedTitle" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
        <TextBlock Text="$escapedDesc" Margin="0,6,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <TextBlock Grid.Row="0" Grid.Column="0" Text="Input JSON:" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <TextBox  Grid.Row="0" Grid.Column="1" x:Name="TxtInPath" Height="26" />
        <Button   Grid.Row="0" Grid.Column="2" x:Name="BtnBrowseIn" Content="Browse…" Width="90" Height="26" Margin="10,0,0,0"/>

        <TextBlock Grid.Row="1" Grid.Column="0" Text="Output JSON:" VerticalAlignment="Center" Margin="0,10,10,0"/>
        <TextBox  Grid.Row="1" Grid.Column="1" x:Name="TxtOutPath" Height="26" Margin="0,10,0,0"/>
        <Button   Grid.Row="1" Grid.Column="2" x:Name="BtnBrowseOut" Content="Browse…" Width="90" Height="26" Margin="10,10,0,0"/>

        <CheckBox Grid.Row="2" Grid.Column="1" x:Name="ChkStable" Content="Stable tokens across runs (salted hash)" Margin="0,12,0,0"/>

        <TextBlock Grid.Row="3" Grid.Column="0" Text="Salt:" VerticalAlignment="Center" Margin="0,10,10,0"/>
        <TextBox  Grid.Row="3" Grid.Column="1" x:Name="TxtSalt" Height="26" Margin="0,10,0,0" Text="gc-sanitize"/>
        <Button   Grid.Row="3" Grid.Column="2" x:Name="BtnRun" Content="Sanitize" Width="90" Height="26" Margin="10,10,0,0"/>

        <StackPanel Grid.Row="4" Grid.ColumnSpan="3" Margin="0,12,0,0">
          <TextBlock Text="Extra PII Keys (comma or newline separated):" Foreground="#FF374151"/>
          <TextBox x:Name="TxtExtraKeys" Height="64" Margin="0,6,0,0" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
          <TextBlock x:Name="TxtStatus" Text="Ready." Margin="0,10,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</UserControl>
"@

  $view = $null
  if (Get-Command ConvertFrom-GcXaml -ErrorAction SilentlyContinue) {
    $view = ConvertFrom-GcXaml -XamlString $xaml
  } else {
    $view = [Windows.Markup.XamlReader]::Parse($xaml)
  }

  function _GetEl([string]$name) { $view.FindName($name) }
  $h = [ordered]@{
    TxtInPath    = _GetEl 'TxtInPath'
    TxtOutPath   = _GetEl 'TxtOutPath'
    BtnBrowseIn  = _GetEl 'BtnBrowseIn'
    BtnBrowseOut = _GetEl 'BtnBrowseOut'
    ChkStable    = _GetEl 'ChkStable'
    TxtSalt      = _GetEl 'TxtSalt'
    TxtExtraKeys = _GetEl 'TxtExtraKeys'
    BtnRun       = _GetEl 'BtnRun'
    TxtStatus    = _GetEl 'TxtStatus'
  }

  $setStatus = {
    param([string]$msg)
    try { $h.TxtStatus.Text = $msg } catch { }
    try { if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status $msg } } catch { }
  }.GetNewClosure()

  $pickIn = {
    try {
      Add-Type -AssemblyName PresentationFramework | Out-Null
      $dlg = New-Object Microsoft.Win32.OpenFileDialog
      $dlg.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
      if ($dlg.ShowDialog()) {
        $h.TxtInPath.Text = $dlg.FileName
        if (-not $h.TxtOutPath.Text) {
          $base = [IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
          $h.TxtOutPath.Text = Join-Path -Path $script:ArtifactsDir -ChildPath ($base + '.sanitized.json')
        }
      }
    } catch {
      & $setStatus "Browse failed: $_"
    }
  }.GetNewClosure()

  $pickOut = {
    try {
      Add-Type -AssemblyName PresentationFramework | Out-Null
      $dlg = New-Object Microsoft.Win32.SaveFileDialog
      $dlg.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
      $dlg.FileName = if ($h.TxtOutPath.Text) { $h.TxtOutPath.Text } else { 'details.sanitized.json' }
      if ($dlg.ShowDialog()) {
        $h.TxtOutPath.Text = $dlg.FileName
      }
    } catch {
      & $setStatus "Browse failed: $_"
    }
  }.GetNewClosure()

  $h.BtnBrowseIn.Add_Click($pickIn)
  $h.BtnBrowseOut.Add_Click($pickOut)

  $h.BtnRun.Add_Click({
    try {
      $inPath = [string]$h.TxtInPath.Text
      $outPath = [string]$h.TxtOutPath.Text

      if (-not $inPath -or -not (Test-Path -LiteralPath $inPath)) {
        throw "Input file not found."
      }

      if (-not $outPath) {
        $base = [IO.Path]::GetFileNameWithoutExtension($inPath)
        $outPath = Join-Path -Path $script:ArtifactsDir -ChildPath ($base + '.sanitized.json')
        $h.TxtOutPath.Text = $outPath
      }

      $stable = ($h.ChkStable.IsChecked -eq $true)
      $salt = [string]$h.TxtSalt.Text
      if ($stable -and -not $salt) { throw "Salt is required when 'Stable across runs' is enabled." }

      $extraKeysRaw = [string]$h.TxtExtraKeys.Text
      $extraKeys = @()
      if ($extraKeysRaw) {
        $extraKeys = @(
          ($extraKeysRaw -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        )
      }

      & $setStatus "Queued sanitizer job…"

      $jobName = "Sanitize JSON: $([IO.Path]::GetFileName($inPath))"
      Start-AppJob -Name $jobName -Type 'Addon' -ScriptBlock {
        param($inPath, $outPath, $stable, $salt, $extraKeys, $repoRoot)
        $impl = Join-Path -Path $repoRoot -ChildPath 'Addons/SanitizeConversationJson/Sanitize-GcConversationJson.Function.ps1'
        if (-not (Test-Path -LiteralPath $impl)) { throw "Addon implementation not found: $impl" }
        . $impl

        Write-Output "Sanitizing file..."
        Write-Output "Input:  $inPath"
        Write-Output "Output: $outPath"

        $params = @{
          Path = $inPath
          OutPath = $outPath
        }
        if ($stable) {
          $params.StableAcrossRuns = $true
          $params.Salt = $salt
        }
        if ($extraKeys -and $extraKeys.Count -gt 0) { $params.ExtraPiiKeys = $extraKeys }

        Sanitize-GcConversationJson @params
      } -ArgumentList @(
        $inPath,
        $outPath,
        $stable,
        $salt,
        $extraKeys,
        $script:AppState.RepositoryRoot
      ) -OnCompleted {
        param($job)
        try {
          if ($job.Status -ne 'Completed') {
            & $setStatus ("Sanitize failed ({0})." -f $job.Status)
            return
          }

          $p = $null
          try { $p = [string]$job.Result.FullName } catch { $p = $null }
          if (-not $p) {
            try { $p = [string]$job.Result } catch { $p = $null }
          }

          if ($p) {
            & $setStatus "Sanitized JSON written: $p"
            if (Get-Command Show-Snackbar -ErrorAction SilentlyContinue) {
              Show-Snackbar -Title 'Sanitize complete' -Body $p `
                -OnPrimary { if (Test-Path $p) { Start-Process -FilePath $p | Out-Null } } `
                -OnSecondary { if (Test-Path (Split-Path -Parent $p)) { Start-Process -FilePath (Split-Path -Parent $p) | Out-Null } } `
                -PrimaryText 'Open' -SecondaryText 'Folder'
            }
          } else {
            & $setStatus "Sanitize complete."
          }
        } catch {
          & $setStatus "Sanitize completion handler failed: $_"
        }
      } | Out-Null
    } catch {
      & $setStatus "Sanitize failed: $_"
    }
  }.GetNewClosure())

  $view
}

