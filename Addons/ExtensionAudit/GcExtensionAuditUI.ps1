#requires -Version 5.1
#requires -PSEdition Desktop
Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:UiBusyCount = 0
$script:Context = $null
$script:DryRunReport = $null

$modulePath = Join-Path $PSScriptRoot 'GcExtensionAudit.psm1'
Import-Module $modulePath -Force

$defaultApiBaseUri = 'https://api.usw2.pure.cloud'
$logPath = New-GcExtensionAuditLogPath -Prefix 'GcExtensionAuditUI'
Set-GcLogPath -Path $logPath

$script:ModulePathForTasks = $modulePath
$script:LogPathForTasks = $logPath

function ConvertTo-PlainText {
  param([Parameter(Mandatory)][Security.SecureString]$SecureString)

  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function ConvertFrom-GcXamlFile {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { throw "XAML file not found: $Path" }
  $xamlString = Get-Content -LiteralPath $Path -Raw

  $stringReader = New-Object System.IO.StringReader($xamlString)
  $xmlReaderSettings = New-Object System.Xml.XmlReaderSettings
  $xmlReaderSettings.IgnoreComments = $true
  $xmlReaderSettings.IgnoreWhitespace = $false
  $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $xmlReaderSettings)
  try {
    return [Windows.Markup.XamlReader]::Load($xmlReader)
  } finally {
    try { $xmlReader.Close() } catch { $null = $_ }
    try { $stringReader.Close() } catch { $null = $_ }
  }
}

function Get-Control {
  param(
    [Parameter(Mandatory)] $Root,
    [Parameter(Mandatory)] [string] $Name
  )
  $c = $Root.FindName($Name)
  if (-not $c) { throw "UI control not found: $Name" }
  return $c
}

function Show-ErrorDialog {
  param(
    [Parameter(Mandatory)] [string] $Title,
    [Parameter(Mandatory)] [string] $Message
  )
  [void][System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
}

function Show-InfoDialog {
  param(
    [Parameter(Mandatory)] [string] $Title,
    [Parameter(Mandatory)] [string] $Message
  )
  [void][System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
}

function Format-ObjectAsText {
  param([Parameter()] $Object)
  if ($null -eq $Object) { return '' }
  try { return ($Object | Format-List | Out-String).Trim() } catch { return [string]$Object }
}

function Ensure-FolderStructure {
  $outFolder = Join-Path $PSScriptRoot 'out'
  $logsFolder = Join-Path $PSScriptRoot 'logs'
  if (-not (Test-Path -LiteralPath $outFolder)) { New-Item -ItemType Directory -Path $outFolder -Force | Out-Null }
  if (-not (Test-Path -LiteralPath $logsFolder)) { New-Item -ItemType Directory -Path $logsFolder -Force | Out-Null }
}

function Update-BusyState {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string] $Status,
    [Parameter(Mandatory)] [bool] $IsBusy
  )

  $script:TxtStatus.Text = $Status
  $script:Progress.Visibility = if ($IsBusy) { 'Visible' } else { 'Collapsed' }

  $buttons = @(
    $script:BtnBuildContext, $script:BtnClear,
    $script:BtnDryRun, $script:BtnDryRunExport,
    $script:BtnMissing, $script:BtnMissingExport,
    $script:BtnDiscrepancies, $script:BtnDiscrepanciesExport,
    $script:BtnDupUsers, $script:BtnDupUsersExport,
    $script:BtnDupExts, $script:BtnDupExtsExport,
    $script:BtnRunPatch,
    $script:BtnOpenLog, $script:BtnOpenOut
  )
  foreach ($b in $buttons) { $b.IsEnabled = -not $IsBusy }
}

function Start-UiTask {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [scriptblock] $Task,
    [Parameter()] [object[]] $Arguments = @(),
    [Parameter(Mandatory)] [scriptblock] $OnSuccess,
    [Parameter(Mandatory)] [scriptblock] $OnError
  )

  $script:UiBusyCount++
  Update-BusyState -Status $Name -IsBusy:$true

  $runspace = [runspacefactory]::CreateRunspace()
  $runspace.ApartmentState = 'MTA'
  $runspace.ThreadOptions = 'ReuseThread'
  $runspace.Open()

  $ps = [powershell]::Create()
  $ps.Runspace = $runspace

  $runner = {
    param(
      [string] $ModulePath,
      [string] $LogPath,
      [scriptblock] $Task,
      [object[]] $Arguments
    )

    Import-Module $ModulePath -Force
    Set-GcLogPath -Path $LogPath -Append
    & $Task @Arguments
  }

  [void]$ps.AddScript($runner).AddArgument($script:ModulePathForTasks).AddArgument($script:LogPathForTasks).AddArgument($Task).AddArgument($Arguments)
  $handle = $ps.BeginInvoke()

  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(150)
  $timer.Add_Tick({
    if (-not $handle.IsCompleted) { return }
    $timer.Stop()

    try {
      $out = $ps.EndInvoke($handle)
      & $OnSuccess $out
    } catch {
      & $OnError $_
    } finally {
      try { $ps.Dispose() } catch { $null = $_ }
      try { $runspace.Close() } catch { $null = $_ }
      $script:UiBusyCount--
      Update-BusyState -Status 'Ready' -IsBusy:($script:UiBusyCount -gt 0)
    }
  })
  $timer.Start()
}

function Ensure-Context {
  if (-not $script:Context) { throw 'Context not built. Click "Build Context" first.' }
}

function Get-TokenFromUi {
  if ($script:ChkUseEnvToken.IsChecked) {
    if ([string]::IsNullOrWhiteSpace($env:GC_ACCESS_TOKEN)) { throw 'GC_ACCESS_TOKEN is not set.' }
    return $env:GC_ACCESS_TOKEN
  }
  $secure = $script:PwdToken.SecurePassword
  if (-not $secure -or $secure.Length -le 0) { throw 'Access token is required (or enable Use $env:GC_ACCESS_TOKEN).' }
  return (ConvertTo-PlainText -SecureString $secure)
}

function Refresh-ContextSummary {
  if (-not $script:Context) {
    $script:TxtContext.Text = "No context loaded. Log: $script:LogPathForTasks"
    return
  }

  $ctx = $script:Context
  $script:TxtContext.Text = "Context ready. Users=$(@($ctx.Users).Count); UsersWithProfileExt=$(@($ctx.UsersWithProfileExtension).Count); DistinctProfileExt=$(@($ctx.ProfileExtensionNumbers).Count); ExtensionsLoaded=$(@($ctx.Extensions).Count); ExtensionMode=$($ctx.ExtensionMode); Log=$script:LogPathForTasks"
}

Ensure-FolderStructure

$xamlPath = Join-Path $PSScriptRoot 'GcExtensionAuditUI.xaml'
$window = ConvertFrom-GcXamlFile -Path $xamlPath

$script:TxtApiBaseUri = Get-Control -Root $window -Name 'TxtApiBaseUri'
$script:PwdToken = Get-Control -Root $window -Name 'PwdToken'
$script:ChkUseEnvToken = Get-Control -Root $window -Name 'ChkUseEnvToken'
$script:ChkIncludeInactive = Get-Control -Root $window -Name 'ChkIncludeInactive'
$script:BtnBuildContext = Get-Control -Root $window -Name 'BtnBuildContext'
$script:BtnClear = Get-Control -Root $window -Name 'BtnClear'
$script:BtnOpenLog = Get-Control -Root $window -Name 'BtnOpenLog'
$script:BtnOpenOut = Get-Control -Root $window -Name 'BtnOpenOut'
$script:TxtContext = Get-Control -Root $window -Name 'TxtContext'

$script:TxtStatus = Get-Control -Root $window -Name 'TxtStatus'
$script:Progress = Get-Control -Root $window -Name 'Progress'
$script:TxtLogPath = Get-Control -Root $window -Name 'TxtLogPath'

$script:BtnDryRun = Get-Control -Root $window -Name 'BtnDryRun'
$script:BtnDryRunExport = Get-Control -Root $window -Name 'BtnDryRunExport'
$script:TxtDryRunSummary = Get-Control -Root $window -Name 'TxtDryRunSummary'
$script:GridDryRun = Get-Control -Root $window -Name 'GridDryRun'

$script:BtnMissing = Get-Control -Root $window -Name 'BtnMissing'
$script:BtnMissingExport = Get-Control -Root $window -Name 'BtnMissingExport'
$script:TxtMissingSummary = Get-Control -Root $window -Name 'TxtMissingSummary'
$script:GridMissing = Get-Control -Root $window -Name 'GridMissing'

$script:BtnDiscrepancies = Get-Control -Root $window -Name 'BtnDiscrepancies'
$script:BtnDiscrepanciesExport = Get-Control -Root $window -Name 'BtnDiscrepanciesExport'
$script:TxtDiscrepanciesSummary = Get-Control -Root $window -Name 'TxtDiscrepanciesSummary'
$script:GridDiscrepancies = Get-Control -Root $window -Name 'GridDiscrepancies'

$script:BtnDupUsers = Get-Control -Root $window -Name 'BtnDupUsers'
$script:BtnDupUsersExport = Get-Control -Root $window -Name 'BtnDupUsersExport'
$script:TxtDupUsersSummary = Get-Control -Root $window -Name 'TxtDupUsersSummary'
$script:GridDupUsers = Get-Control -Root $window -Name 'GridDupUsers'

$script:BtnDupExts = Get-Control -Root $window -Name 'BtnDupExts'
$script:BtnDupExtsExport = Get-Control -Root $window -Name 'BtnDupExtsExport'
$script:TxtDupExtsSummary = Get-Control -Root $window -Name 'TxtDupExtsSummary'
$script:GridDupExts = Get-Control -Root $window -Name 'GridDupExts'

$script:ChkWhatIf = Get-Control -Root $window -Name 'ChkWhatIf'
$script:TxtSleepMs = Get-Control -Root $window -Name 'TxtSleepMs'
$script:TxtMaxUpdates = Get-Control -Root $window -Name 'TxtMaxUpdates'
$script:TxtConfirmPatch = Get-Control -Root $window -Name 'TxtConfirmPatch'
$script:BtnRunPatch = Get-Control -Root $window -Name 'BtnRunPatch'
$script:TxtPatchSummary = Get-Control -Root $window -Name 'TxtPatchSummary'
$script:GridPatchUpdated = Get-Control -Root $window -Name 'GridPatchUpdated'
$script:GridPatchSkipped = Get-Control -Root $window -Name 'GridPatchSkipped'
$script:GridPatchFailed = Get-Control -Root $window -Name 'GridPatchFailed'

$script:TxtApiBaseUri.Text = $defaultApiBaseUri
$script:TxtLogPath.Text = $logPath
Refresh-ContextSummary

$script:BtnOpenLog.Add_Click({
  try {
    Ensure-FolderStructure
    if (Test-Path -LiteralPath $script:LogPathForTasks) { Start-Process -FilePath $script:LogPathForTasks }
    else { Start-Process -FilePath (Join-Path $PSScriptRoot 'logs') }
  } catch { Show-ErrorDialog -Title 'Open Log' -Message $_.Exception.Message }
})

$script:BtnOpenOut.Add_Click({
  try { Ensure-FolderStructure; Start-Process -FilePath (Join-Path $PSScriptRoot 'out') }
  catch { Show-ErrorDialog -Title 'Open Out' -Message $_.Exception.Message }
})

$script:BtnClear.Add_Click({
  $script:Context = $null
  $script:DryRunReport = $null

  $script:GridDryRun.ItemsSource = $null
  $script:TxtDryRunSummary.Text = ''
  $script:GridMissing.ItemsSource = $null
  $script:TxtMissingSummary.Text = ''
  $script:GridDiscrepancies.ItemsSource = $null
  $script:TxtDiscrepanciesSummary.Text = ''
  $script:GridDupUsers.ItemsSource = $null
  $script:TxtDupUsersSummary.Text = ''
  $script:GridDupExts.ItemsSource = $null
  $script:TxtDupExtsSummary.Text = ''
  $script:TxtPatchSummary.Text = ''
  $script:GridPatchUpdated.ItemsSource = $null
  $script:GridPatchSkipped.ItemsSource = $null
  $script:GridPatchFailed.ItemsSource = $null
  Refresh-ContextSummary
})

$script:BtnBuildContext.Add_Click({
  try {
    $apiBaseUri = [string]$script:TxtApiBaseUri.Text
    if ([string]::IsNullOrWhiteSpace($apiBaseUri)) { throw 'API Base URI is required.' }

    $token = Get-TokenFromUi
    $includeInactive = [bool]$script:ChkIncludeInactive.IsChecked

    Start-UiTask `
      -Name 'Building context (fetching users + extensions)' `
      -Task { param($ApiBaseUri, $Token, $IncludeInactive) New-GcExtensionAuditContext -ApiBaseUri $ApiBaseUri -AccessToken $Token -IncludeInactive:$IncludeInactive } `
      -Arguments @($apiBaseUri, $token, $includeInactive) `
      -OnSuccess {
        param($out)
        $script:Context = $out | Select-Object -Last 1
        Refresh-ContextSummary
        Show-InfoDialog -Title 'Context Ready' -Message 'Context has been built successfully.'
      } `
      -OnError { param($err) Show-ErrorDialog -Title 'Build Context Failed' -Message $err.Exception.Message }
  } catch {
    Show-ErrorDialog -Title 'Build Context' -Message $_.Exception.Message
  }
})

$script:BtnDryRun.Add_Click({
  try {
    Ensure-Context
    Start-UiTask `
      -Name 'Generating dry run report' `
      -Task { param($ctx) New-ExtensionDryRunReport -Context $ctx } `
      -Arguments @($script:Context) `
      -OnSuccess {
        param($out)
        $rep = $out | Select-Object -Last 1
        $script:DryRunReport = $rep
        $script:TxtDryRunSummary.Text = (Format-ObjectAsText $rep.Metadata) + "`r`n`r`n" + (Format-ObjectAsText $rep.Summary)
        $script:GridDryRun.ItemsSource = $null
        $script:GridDryRun.ItemsSource = @($rep.Rows)
      } `
      -OnError { param($err) Show-ErrorDialog -Title 'Dry Run' -Message $err.Exception.Message }
  } catch { Show-ErrorDialog -Title 'Dry Run' -Message $_.Exception.Message }
})

$script:BtnDryRunExport.Add_Click({
  try {
    if (-not $script:DryRunReport) { throw 'Generate a dry run report first.' }
    Ensure-FolderStructure

    $outFolder = Join-Path $PSScriptRoot 'out'
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $rowsPath = Join-Path $outFolder "DryRunReport_$ts.csv"
    $metaPath = Join-Path $outFolder "DryRunReport_Metadata_$ts.csv"
    $summaryPath = Join-Path $outFolder "DryRunReport_Summary_$ts.csv"

    Export-ReportCsv -Rows @($script:DryRunReport.Rows) -Path $rowsPath
    Export-ReportCsv -Rows @($script:DryRunReport.Metadata) -Path $metaPath
    Export-ReportCsv -Rows @($script:DryRunReport.Summary) -Path $summaryPath

    Show-InfoDialog -Title 'Export Complete' -Message "Exported:`r`n$rowsPath`r`n$metaPath`r`n$summaryPath"
  } catch { Show-ErrorDialog -Title 'Export Dry Run' -Message $_.Exception.Message }
})

$script:BtnMissing.Add_Click({
  try {
    Ensure-Context
    Start-UiTask `
      -Name 'Computing missing assignments' `
      -Task { param($ctx) Find-MissingExtensionAssignments -Context $ctx } `
      -Arguments @($script:Context) `
      -OnSuccess {
        param($out)
        $rows = @($out)
        $script:TxtMissingSummary.Text = "Rows: $(@($rows).Count)"
        $script:GridMissing.ItemsSource = $null
        $script:GridMissing.ItemsSource = $rows
      } `
      -OnError { param($err) Show-ErrorDialog -Title 'Missing Assignments' -Message $err.Exception.Message }
  } catch { Show-ErrorDialog -Title 'Missing Assignments' -Message $_.Exception.Message }
})

$script:BtnMissingExport.Add_Click({
  try {
    $rows = @($script:GridMissing.ItemsSource)
    if (@($rows).Count -eq 0) { throw 'No rows to export. Refresh Missing first.' }
    Ensure-FolderStructure
    $outFolder = Join-Path $PSScriptRoot 'out'
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $path = Join-Path $outFolder "MissingAssignments_$ts.csv"
    Export-ReportCsv -Rows $rows -Path $path
    Show-InfoDialog -Title 'Export Complete' -Message "Exported:`r`n$path"
  } catch { Show-ErrorDialog -Title 'Export Missing' -Message $_.Exception.Message }
})

$script:BtnDiscrepancies.Add_Click({
  try {
    Ensure-Context
    Start-UiTask `
      -Name 'Computing discrepancies' `
      -Task { param($ctx) Find-ExtensionDiscrepancies -Context $ctx } `
      -Arguments @($script:Context) `
      -OnSuccess {
        param($out)
        $rows = @($out)
        $script:TxtDiscrepanciesSummary.Text = "Rows: $(@($rows).Count)"
        $script:GridDiscrepancies.ItemsSource = $null
        $script:GridDiscrepancies.ItemsSource = $rows
      } `
      -OnError { param($err) Show-ErrorDialog -Title 'Discrepancies' -Message $err.Exception.Message }
  } catch { Show-ErrorDialog -Title 'Discrepancies' -Message $_.Exception.Message }
})

$script:BtnDiscrepanciesExport.Add_Click({
  try {
    $rows = @($script:GridDiscrepancies.ItemsSource)
    if (@($rows).Count -eq 0) { throw 'No rows to export. Refresh Discrepancies first.' }
    Ensure-FolderStructure
    $outFolder = Join-Path $PSScriptRoot 'out'
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $path = Join-Path $outFolder "Discrepancies_$ts.csv"
    Export-ReportCsv -Rows $rows -Path $path
    Show-InfoDialog -Title 'Export Complete' -Message "Exported:`r`n$path"
  } catch { Show-ErrorDialog -Title 'Export Discrepancies' -Message $_.Exception.Message }
})

$script:BtnDupUsers.Add_Click({
  try {
    Ensure-Context
    Start-UiTask `
      -Name 'Computing user duplicates' `
      -Task { param($ctx) Find-DuplicateUserExtensionAssignments -Context $ctx } `
      -Arguments @($script:Context) `
      -OnSuccess {
        param($out)
        $rows = @($out)
        $script:TxtDupUsersSummary.Text = "Rows: $(@($rows).Count)"
        $script:GridDupUsers.ItemsSource = $null
        $script:GridDupUsers.ItemsSource = $rows
      } `
      -OnError { param($err) Show-ErrorDialog -Title 'Duplicates (Users)' -Message $err.Exception.Message }
  } catch { Show-ErrorDialog -Title 'Duplicates (Users)' -Message $_.Exception.Message }
})

$script:BtnDupUsersExport.Add_Click({
  try {
    $rows = @($script:GridDupUsers.ItemsSource)
    if (@($rows).Count -eq 0) { throw 'No rows to export. Refresh User Duplicates first.' }
    Ensure-FolderStructure
    $outFolder = Join-Path $PSScriptRoot 'out'
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $path = Join-Path $outFolder "DuplicateUserAssignments_$ts.csv"
    Export-ReportCsv -Rows $rows -Path $path
    Show-InfoDialog -Title 'Export Complete' -Message "Exported:`r`n$path"
  } catch { Show-ErrorDialog -Title 'Export User Duplicates' -Message $_.Exception.Message }
})

$script:BtnDupExts.Add_Click({
  try {
    Ensure-Context
    Start-UiTask `
      -Name 'Computing extension duplicates' `
      -Task { param($ctx) Find-DuplicateExtensionRecords -Context $ctx } `
      -Arguments @($script:Context) `
      -OnSuccess {
        param($out)
        $rows = @($out)
        $script:TxtDupExtsSummary.Text = "Rows: $(@($rows).Count)"
        $script:GridDupExts.ItemsSource = $null
        $script:GridDupExts.ItemsSource = $rows
      } `
      -OnError { param($err) Show-ErrorDialog -Title 'Duplicates (Extensions)' -Message $err.Exception.Message }
  } catch { Show-ErrorDialog -Title 'Duplicates (Extensions)' -Message $_.Exception.Message }
})

$script:BtnDupExtsExport.Add_Click({
  try {
    $rows = @($script:GridDupExts.ItemsSource)
    if (@($rows).Count -eq 0) { throw 'No rows to export. Refresh Extension Duplicates first.' }
    Ensure-FolderStructure
    $outFolder = Join-Path $PSScriptRoot 'out'
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $path = Join-Path $outFolder "DuplicateExtensionRecords_$ts.csv"
    Export-ReportCsv -Rows $rows -Path $path
    Show-InfoDialog -Title 'Export Complete' -Message "Exported:`r`n$path"
  } catch { Show-ErrorDialog -Title 'Export Extension Duplicates' -Message $_.Exception.Message }
})

$script:BtnRunPatch.Add_Click({
  try {
    Ensure-Context
    Ensure-FolderStructure

    $whatIf = [bool]$script:ChkWhatIf.IsChecked
    if (-not $whatIf) {
      if ([string]$script:TxtConfirmPatch.Text -ne 'PATCH') { throw 'To run real changes, uncheck WhatIf and type PATCH in Confirm.' }
      $confirm = [System.Windows.MessageBox]::Show(
        'You are about to apply real changes (PATCH). Continue?',
        'Confirm Patch',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
      )
      if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    $sleepMs = 150
    if (-not [int]::TryParse([string]$script:TxtSleepMs.Text, [ref]$sleepMs) -or $sleepMs -lt 0) { throw 'Sleep (ms) must be a non-negative integer.' }
    $maxUpdates = 0
    if (-not [int]::TryParse([string]$script:TxtMaxUpdates.Text, [ref]$maxUpdates) -or $maxUpdates -lt 0) { throw 'Max updates must be a non-negative integer.' }

    Start-UiTask `
      -Name (if ($whatIf) { 'Running patch (WhatIf)' } else { 'Running patch (REAL)' }) `
      -Task { param($ctx, $sleepMs, $maxUpdates, $whatIf) Patch-MissingExtensionAssignments -Context $ctx -SleepMsBetween $sleepMs -MaxUpdates $maxUpdates -WhatIf:$whatIf } `
      -Arguments @($script:Context, $sleepMs, $maxUpdates, $whatIf) `
      -OnSuccess {
        param($out)
        $result = $out | Select-Object -Last 1
        $script:TxtPatchSummary.Text = (Format-ObjectAsText $result.Summary)

        $script:GridPatchUpdated.ItemsSource = $null
        $script:GridPatchUpdated.ItemsSource = @($result.Updated)
        $script:GridPatchSkipped.ItemsSource = $null
        $script:GridPatchSkipped.ItemsSource = @($result.Skipped)
        $script:GridPatchFailed.ItemsSource = $null
        $script:GridPatchFailed.ItemsSource = @($result.Failed)

        $outFolder = Join-Path $PSScriptRoot 'out'
        $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $updatedPath = Join-Path $outFolder "PatchUpdated_$ts.csv"
        $skippedPath = Join-Path $outFolder "PatchSkipped_$ts.csv"
        $failedPath  = Join-Path $outFolder "PatchFailed_$ts.csv"
        $summaryPath = Join-Path $outFolder "PatchSummary_$ts.csv"
        Export-ReportCsv -Rows @($result.Updated) -Path $updatedPath
        Export-ReportCsv -Rows @($result.Skipped) -Path $skippedPath
        Export-ReportCsv -Rows @($result.Failed) -Path $failedPath
        Export-ReportCsv -Rows @($result.Summary) -Path $summaryPath

        Show-InfoDialog -Title 'Patch Complete' -Message "Exported:`r`n$updatedPath`r`n$skippedPath`r`n$failedPath`r`n$summaryPath"
      } `
      -OnError { param($err) Show-ErrorDialog -Title 'Patch' -Message $err.Exception.Message }
  } catch { Show-ErrorDialog -Title 'Patch' -Message $_.Exception.Message }
})

$window.Add_Closed({
  try { Write-Log -Level INFO -Message 'Extension audit UI closed' -Data @{ LogPath = $script:LogPathForTasks } } catch { $null = $_ }
})

[void]$window.ShowDialog()
