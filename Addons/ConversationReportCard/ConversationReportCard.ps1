# ConversationReportCard.ps1
# Standalone WPF desktop application: enter a Conversation ID → get a full HTML report card.
# Auth: Browser OAuth / PKCE via Auth.psm1
# Dependencies: Auth.psm1, XamlHelpers.ps1, GcApiClient.psm1, GcReportCard.psm1

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$scriptRoot = Split-Path -Parent $PSCommandPath

# ── Module imports ───────────────────────────────────────────────────────────
Import-Module (Join-Path $scriptRoot 'Auth.psm1')         -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'GcApiClient.psm1')  -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'GcReportCard.psm1') -Force -ErrorAction Stop
. (Join-Path $scriptRoot 'XamlHelpers.ps1')

# ── Config persistence ───────────────────────────────────────────────────────
$script:ConfigDir  = Join-Path $env:APPDATA 'GcReportCard'
$script:ConfigFile = Join-Path $script:ConfigDir 'config.json'

function Load-Config {
  $defaults = @{ Region = 'usw2.pure.cloud'; ClientId = ''; RedirectUri = 'http://localhost:8085/callback' }
  if (Test-Path $script:ConfigFile) {
    try {
      $json = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
      $defaults.Region      = if ($json.Region)      { $json.Region }      else { $defaults.Region }
      $defaults.ClientId    = if ($json.ClientId)    { $json.ClientId }    else { $defaults.ClientId }
      $defaults.RedirectUri = if ($json.RedirectUri) { $json.RedirectUri } else { $defaults.RedirectUri }
    } catch { }
  }
  return $defaults
}

function Save-Config {
  param([string]$Region, [string]$ClientId, [string]$RedirectUri)
  try {
    if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
    @{ Region = $Region; ClientId = $ClientId; RedirectUri = $RedirectUri } | ConvertTo-Json | Set-Content $script:ConfigFile -Encoding UTF8
  } catch { }
}

# ── Temp output dir ──────────────────────────────────────────────────────────
$script:TempDir = Join-Path $env:TEMP 'GcReportCard'
if (-not (Test-Path $script:TempDir)) { New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null }
$script:LastHtmlPath = $null

# ── App state ────────────────────────────────────────────────────────────────
$script:IsLoggedIn  = $false
$script:IsBusy      = $false
$script:CurrentUser = $null
$script:StoredAccessToken = $null
$script:StoredRegion      = $null

# ── XAML ─────────────────────────────────────────────────────────────────────
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Genesys Cloud — Conversation Report Card"
        Width="940" Height="720" MinWidth="700" MinHeight="500"
        WindowStartupLocation="CenterScreen"
        Background="#F3F4F6">

  <Window.Resources>
    <!-- Primary button -->
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#0066CC"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#0052A3"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Background" Value="#9CA3AF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Secondary button -->
    <Style x:Key="SecondaryBtn" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#374151"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#F9FAFB"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#9CA3AF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- TextBox style -->
    <Style x:Key="InputBox" TargetType="TextBox">
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>  <!-- Dark header bar -->
      <RowDefinition Height="Auto"/>  <!-- Connection section -->
      <RowDefinition Height="Auto"/>  <!-- Lookup section -->
      <RowDefinition Height="Auto"/>  <!-- Progress bar -->
      <RowDefinition Height="*"/>     <!-- WebBrowser -->
      <RowDefinition Height="Auto"/>  <!-- Bottom toolbar -->
    </Grid.RowDefinitions>

    <!-- ─── Dark header bar ──────────────────────────────────────────── -->
    <Border Grid.Row="0" Background="#111827" Padding="16,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="Genesys Cloud" FontSize="15" FontWeight="Bold" Foreground="#60A5FA"/>
          <TextBlock Text=" — Conversation Report Card" FontSize="13" Foreground="#9CA3AF" VerticalAlignment="Bottom" Margin="4,0,0,1"/>
        </StackPanel>
        <TextBlock x:Name="TxtUserInfo" Grid.Column="1" Foreground="#9CA3AF" FontSize="11" VerticalAlignment="Center" Text="Not logged in"/>
      </Grid>
    </Border>

    <!-- ─── Connection section ───────────────────────────────────────── -->
    <Border Grid.Row="1" Background="White" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1" Padding="16,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="160"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="200"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <TextBlock Grid.Column="0" Text="Region:" VerticalAlignment="Center" FontSize="11" Foreground="#6B7280" Margin="0,0,6,0"/>
        <TextBox x:Name="TxtRegion" Grid.Column="1" Style="{StaticResource InputBox}" Height="30"/>

        <TextBlock Grid.Column="2" Text="Client ID:" VerticalAlignment="Center" FontSize="11" Foreground="#6B7280" Margin="10,0,6,0"/>
        <TextBox x:Name="TxtClientId" Grid.Column="3" Style="{StaticResource InputBox}" Height="30"/>

        <!-- Status dot -->
        <Ellipse x:Name="DotStatus" Grid.Column="4" Width="8" Height="8" Fill="#D1D5DB" Margin="12,0,6,0" VerticalAlignment="Center"/>

        <TextBlock x:Name="TxtAuthStatus" Grid.Column="5" Text="Click Login to authenticate" Foreground="#9CA3AF" FontSize="11" VerticalAlignment="Center"/>

        <Button x:Name="BtnLogin" Grid.Column="6" Content="Login with Genesys" Style="{StaticResource PrimaryBtn}" Height="30"/>
      </Grid>
    </Border>

    <!-- ─── Lookup section ───────────────────────────────────────────── -->
    <Border Grid.Row="2" Background="White" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1" Padding="16,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <TextBlock Grid.Column="0" Text="Conversation ID:" VerticalAlignment="Center" FontSize="11" Foreground="#6B7280" Margin="0,0,8,0"/>
        <TextBox x:Name="TxtConvId" Grid.Column="1" Style="{StaticResource InputBox}" Height="30"
                 FontFamily="Consolas" IsEnabled="False"
                 ToolTip="Paste a Genesys Cloud conversation UUID"/>

        <Button x:Name="BtnGenerate" Grid.Column="2" Content="Generate Report Card" Style="{StaticResource PrimaryBtn}" Height="30" Margin="8,0,0,0" IsEnabled="False"/>
        <Button x:Name="BtnClear"    Grid.Column="3" Content="Clear" Style="{StaticResource SecondaryBtn}" Height="30" Margin="6,0,0,0" IsEnabled="False"/>
      </Grid>
    </Border>

    <!-- ─── Progress bar ─────────────────────────────────────────────── -->
    <Border Grid.Row="3" Background="White" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1" Padding="16,6" Visibility="Collapsed" x:Name="PnlProgress">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <ProgressBar x:Name="ProgBar" Height="6" Minimum="0" Maximum="11" Value="0" Foreground="#0066CC" Background="#E5E7EB"/>
        <TextBlock x:Name="TxtProgress" Grid.Column="1" Foreground="#6B7280" FontSize="11" Margin="10,0,0,0" VerticalAlignment="Center" Text="Starting..."/>
      </Grid>
    </Border>

    <!-- ─── WebBrowser ───────────────────────────────────────────────── -->
    <Border Grid.Row="4" Background="#F9FAFB" Padding="0">
      <WebBrowser x:Name="WebReport"/>
    </Border>

    <!-- ─── Bottom toolbar ───────────────────────────────────────────── -->
    <Border Grid.Row="5" Background="White" BorderBrush="#E5E7EB" BorderThickness="0,1,0,0" Padding="16,8">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <Button x:Name="BtnExport"     Grid.Column="0" Content="⬇ Export HTML…"    Style="{StaticResource SecondaryBtn}" Height="28" IsEnabled="False"/>
        <Button x:Name="BtnOpenBrowser" Grid.Column="1" Content="⬡ Open in Browser" Style="{StaticResource SecondaryBtn}" Height="28" Margin="6,0,0,0" IsEnabled="False"/>

        <TextBlock x:Name="TxtStatusBar" Grid.Column="2" Text="Ready" Foreground="#9CA3AF" FontSize="11" VerticalAlignment="Center" Margin="12,0,0,0"/>

        <Button x:Name="BtnLogout" Grid.Column="3" Content="Logout" Style="{StaticResource SecondaryBtn}" Height="28" IsEnabled="False"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

# ── Create window ────────────────────────────────────────────────────────────
$window = ConvertFrom-GcXaml -XamlString $xaml

# Control refs
$txtRegion      = $window.FindName('TxtRegion')
$txtClientId    = $window.FindName('TxtClientId')
$txtConvId      = $window.FindName('TxtConvId')
$btnLogin       = $window.FindName('BtnLogin')
$btnGenerate    = $window.FindName('BtnGenerate')
$btnClear       = $window.FindName('BtnClear')
$btnExport      = $window.FindName('BtnExport')
$btnOpenBrowser = $window.FindName('BtnOpenBrowser')
$btnLogout      = $window.FindName('BtnLogout')
$dotStatus      = $window.FindName('DotStatus')
$txtAuthStatus  = $window.FindName('TxtAuthStatus')
$txtUserInfo    = $window.FindName('TxtUserInfo')
$txtProgress    = $window.FindName('TxtProgress')
$progBar        = $window.FindName('ProgBar')
$pnlProgress    = $window.FindName('PnlProgress')
$webReport      = $window.FindName('WebReport')
$txtStatusBar   = $window.FindName('TxtStatusBar')

function Dispose-GcRunspaceResources {
  param(
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PowerShell]$PowerShellInstance,
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.Runspaces.Runspace]$RunspaceInstance
  )

  if ($PowerShellInstance) {
    try { $PowerShellInstance.Dispose() } catch { }
  }
  if ($RunspaceInstance) {
    try {
      if ($RunspaceInstance.RunspaceStateInfo.State -ne [System.Management.Automation.Runspaces.RunspaceState]::Closed) {
        $RunspaceInstance.Close()
      }
    } catch { }
    try { $RunspaceInstance.Dispose() } catch { }
  }
}

# ── Load-config on startup ───────────────────────────────────────────────────
$cfg = Load-Config
$txtRegion.Text   = $cfg.Region
$txtClientId.Text = $cfg.ClientId

# ── Show welcome page in WebBrowser ─────────────────────────────────────────
$welcomeHtml = @"
<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>
  body { font-family: 'Segoe UI',system-ui,sans-serif; background:#F3F4F6; display:flex; align-items:center; justify-content:center; height:100vh; margin:0; }
  .card { background:white; border:1px solid #E5E7EB; border-radius:10px; padding:40px 50px; text-align:center; max-width:460px; }
  h1 { color:#111827; font-size:20px; margin-bottom:10px; }
  p  { color:#6B7280; font-size:13px; line-height:1.6; }
  .step { display:flex; align-items:center; gap:10px; text-align:left; margin:8px 0; }
  .num  { background:#0066CC; color:white; border-radius:50%; width:22px; height:22px; font-size:11px; font-weight:700; display:flex; align-items:center; justify-content:center; flex-shrink:0; }
</style></head><body>
<div class="card">
  <h1>&#x1F4CB; Conversation Report Card</h1>
  <p>Enter a Genesys Cloud Conversation ID to generate a comprehensive report card covering timing, agents, queues, IVR flow, quality, and more.</p>
  <br>
  <div class="step"><div class="num">1</div><span>Enter your Region and Client ID, then click <strong>Login with Genesys</strong></span></div>
  <div class="step"><div class="num">2</div><span>Paste a Conversation UUID into the Conversation ID field</span></div>
  <div class="step"><div class="num">3</div><span>Click <strong>Generate Report Card</strong> and wait for all API data to load</span></div>
  <div class="step"><div class="num">4</div><span>Review the report here or open it in your default browser</span></div>
</div>
</body></html>
"@

$welcomeFile = Join-Path $script:TempDir 'welcome.html'
$welcomeHtml | Set-Content -LiteralPath $welcomeFile -Encoding UTF8
$webReport.Navigate($welcomeFile)

# ── Login button handler ─────────────────────────────────────────────────────
$btnLogin.Add_Click({
  if ($script:IsBusy) { return }

  $region      = $txtRegion.Text.Trim()
  $clientId    = $txtClientId.Text.Trim()
  $redirectUri = $cfg.RedirectUri

  if ([string]::IsNullOrWhiteSpace($region)) {
    [System.Windows.MessageBox]::Show('Please enter a Genesys Cloud Region (e.g., usw2.pure.cloud)', 'Missing Region', 'OK', 'Warning') | Out-Null
    return
  }
  if ([string]::IsNullOrWhiteSpace($clientId)) {
    [System.Windows.MessageBox]::Show('Please enter your OAuth Client ID.', 'Missing Client ID', 'OK', 'Warning') | Out-Null
    return
  }

  # Save config
  Save-Config -Region $region -ClientId $clientId -RedirectUri $redirectUri

  $btnLogin.IsEnabled = $false
  $dotStatus.Fill     = [System.Windows.Media.Brushes]::Orange
  $txtAuthStatus.Text = 'Opening browser for login…'
  $txtStatusBar.Text  = 'Authenticating…'

  # Run OAuth in background
  $psInst = [PowerShell]::Create()
  [void]$psInst.AddScript({
    param($Region, $ClientId, $RedirectUri, $AuthModulePath)
    Import-Module $AuthModulePath -Force
    Set-GcAuthConfig -Region $Region -ClientId $ClientId -RedirectUri $RedirectUri
    $token = Get-GcTokenAsync -TimeoutSeconds 300
    if (-not $token) { return @{ Success = $false; Error = 'No token returned' } }
    $user  = Test-GcToken
    return @{ Success = $true; Token = $token.access_token; User = $user }
  })
  [void]$psInst.AddArgument($region)
  [void]$psInst.AddArgument($clientId)
  [void]$psInst.AddArgument($redirectUri)
  [void]$psInst.AddArgument((Join-Path $scriptRoot 'Auth.psm1'))

  $asyncResult = $psInst.BeginInvoke()

  # Poll for completion on a timer
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(500)
  $timer.Add_Tick({
    if ($asyncResult.IsCompleted) {
      $timer.Stop()
      $result = $null
      try {
        $rawResults = @($psInst.EndInvoke($asyncResult))
        if ($rawResults.Count -gt 0) { $result = $rawResults[0] }
        if ($result -and $result.Success) {
          Set-GcAuthConfig -Region $region -ClientId $clientId -RedirectUri $redirectUri
          $script:StoredAccessToken = $result.Token
          $script:StoredRegion      = $region

          $userName = if ($result.User -and $result.User.name) { $result.User.name } else { 'Authenticated' }
          $script:IsLoggedIn  = $true
          $script:CurrentUser = $result.User

          $dotStatus.Fill       = [System.Windows.Media.Brushes]::Green
          $txtAuthStatus.Text   = "Logged in as: $userName"
          $txtUserInfo.Text     = $userName
          $txtConvId.IsEnabled  = $true
          $btnGenerate.IsEnabled = $true
          $btnClear.IsEnabled    = $true
          $btnLogout.IsEnabled   = $true
          $btnLogin.Content      = 'Re-Login'
          $btnLogin.IsEnabled    = $true
          $txtStatusBar.Text     = "Authenticated. Paste a Conversation ID above."
        } else {
          $dotStatus.Fill     = [System.Windows.Media.Brushes]::Red
          $errMsg = if ($result -and $result.Error) { $result.Error } else { 'Login failed or cancelled.' }
          $txtAuthStatus.Text = "Login failed: $errMsg"
          $txtStatusBar.Text  = 'Login failed.'
          $btnLogin.IsEnabled = $true
        }
      } catch {
        $dotStatus.Fill     = [System.Windows.Media.Brushes]::Red
        $txtAuthStatus.Text = "Error during login: $($_.Exception.Message)"
        $btnLogin.IsEnabled = $true
      } finally {
        Dispose-GcRunspaceResources -PowerShellInstance $psInst
      }
    }
  })
  $timer.Start()
})

# ── Logout button handler ────────────────────────────────────────────────────
$btnLogout.Add_Click({
  $script:IsLoggedIn       = $false
  $script:StoredAccessToken = $null
  $script:StoredRegion      = $null
  $dotStatus.Fill          = [System.Windows.Media.Brushes]::Gray
  $txtAuthStatus.Text      = 'Logged out. Click Login to authenticate again.'
  $txtUserInfo.Text        = 'Not logged in'
  $btnGenerate.IsEnabled   = $false
  $btnClear.IsEnabled      = $false
  $btnLogout.IsEnabled     = $false
  $btnLogin.Content        = 'Login with Genesys'
  $txtConvId.IsEnabled     = $false
  $txtStatusBar.Text       = 'Logged out.'
})

# ── Clear button handler ─────────────────────────────────────────────────────
$btnClear.Add_Click({
  $txtConvId.Text = ''
  $btnExport.IsEnabled      = $false
  $btnOpenBrowser.IsEnabled = $false
  $script:LastHtmlPath      = $null
  $pnlProgress.Visibility   = [System.Windows.Visibility]::Collapsed
  $progBar.Value            = 0
  $webReport.Navigate($welcomeFile)
  $txtStatusBar.Text        = 'Cleared.'
})

# ── Generate button handler ──────────────────────────────────────────────────
$btnGenerate.Add_Click({
  if ($script:IsBusy -or -not $script:IsLoggedIn) { return }

  $convId      = $txtConvId.Text.Trim()
  $accessToken = $script:StoredAccessToken
  $region      = $script:StoredRegion

  # Validate UUID format
  $uuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  if (-not ($convId -match $uuidPattern)) {
    [System.Windows.MessageBox]::Show(
      "Conversation ID must be a valid UUID (e.g., xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).`n`nYou entered: $convId",
      'Invalid Conversation ID', 'OK', 'Warning') | Out-Null
    return
  }

  if ([string]::IsNullOrWhiteSpace($accessToken)) {
    [System.Windows.MessageBox]::Show('Session appears expired. Please login again.', 'Session Expired', 'OK', 'Warning') | Out-Null
    return
  }

  # Update UI to busy state
  $script:IsBusy            = $true
  $btnGenerate.IsEnabled    = $false
  $btnExport.IsEnabled      = $false
  $btnOpenBrowser.IsEnabled = $false
  $pnlProgress.Visibility   = [System.Windows.Visibility]::Visible
  $progBar.Value            = 0
  $progBar.Maximum          = 11
  $txtProgress.Text         = 'Starting…'
  $txtStatusBar.Text        = "Generating report for $convId…"

  # Show loading page
  $loadingHtml = @"
<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>
  body{font-family:'Segoe UI',sans-serif;background:#F3F4F6;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;}
  .card{background:white;border:1px solid #E5E7EB;border-radius:10px;padding:40px 50px;text-align:center;}
  .spinner{width:36px;height:36px;border:3px solid #E5E7EB;border-top-color:#0066CC;border-radius:50%;animation:spin 0.8s linear infinite;margin:0 auto 16px;}
  @keyframes spin{to{transform:rotate(360deg)}}
  h2{color:#111827;font-size:16px;margin-bottom:6px;}
  p{color:#9CA3AF;font-size:12px;}
</style></head><body>
<div class="card">
  <div class="spinner"></div>
  <h2>Fetching data&hellip;</h2>
  <p>Calling Genesys Cloud APIs for conversation $convId</p>
  </div></body></html>
"@
  $loadingFile = Join-Path $script:TempDir 'loading.html'
  $loadingHtml | Set-Content -LiteralPath $loadingFile -Encoding UTF8
  $webReport.Navigate($loadingFile)

  # Capture vars for closure
  $capturedConvId  = $convId
  $capturedToken   = $accessToken
  $capturedRegion  = $region
  $capturedScriptRoot = $scriptRoot
  $capturedTempDir = $script:TempDir

  # Launch background runspace
  $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
  $runspace.Open()

  $psInst = [PowerShell]::Create()
  $psInst.Runspace = $runspace

  [void]$psInst.AddScript({
    param($ConversationId, $AccessToken, $Region, $ScriptRoot, $TempDir)

    try {
      Import-Module (Join-Path $ScriptRoot 'GcApiClient.psm1')  -Force
      Import-Module (Join-Path $ScriptRoot 'GcReportCard.psm1') -Force

      # Progress callback passes step info via output stream
      $progressCallback = {
        param($Step, $Total, $Message)
        Write-Output "PROGRESS:${Step}/${Total}:${Message}"
      }

      $data = Get-GcConversationReportData `
        -ConversationId $ConversationId `
        -Region         $Region `
        -AccessToken    $AccessToken `
        -ProgressCallback $progressCallback

      # Check if base conversation returned anything
      if (-not $data.Base -and -not $data.Analytics) {
        Write-Output "ERROR:Conversation not found or no access. Check the Conversation ID and your API permissions."
        return
      }

      Write-Output "PROGRESS:11/11:Generating HTML report…"
      $html = New-GcConversationReportCard -ReportData $data

      $outFile = Join-Path $TempDir "$ConversationId.html"
      $html | Set-Content -LiteralPath $outFile -Encoding UTF8

      Write-Output "DONE:$outFile"

    } catch {
      Write-Output "ERROR:$($_.Exception.Message)"
    }
  })

  [void]$psInst.AddArgument($capturedConvId)
  [void]$psInst.AddArgument($capturedToken)
  [void]$psInst.AddArgument($capturedRegion)
  [void]$psInst.AddArgument($capturedScriptRoot)
  [void]$psInst.AddArgument($capturedTempDir)

  $asyncResult = $psInst.BeginInvoke()

  # Poll timer — reads output stream to update progress
  $pollTimer = New-Object System.Windows.Threading.DispatcherTimer
  $pollTimer.Interval = [TimeSpan]::FromMilliseconds(300)
  $pollTimer.Add_Tick({
    if ($asyncResult.IsCompleted) {
      $pollTimer.Stop()
      $results = @()
      try {
        $results = @($psInst.EndInvoke($asyncResult))
      } catch {
        $results = @("ERROR:$($_.Exception.Message)")
      } finally {
        Dispose-GcRunspaceResources -PowerShellInstance $psInst -RunspaceInstance $runspace
      }

      $script:IsBusy = $false

      # Parse results
      $doneFile  = $null
      $errorMsg  = $null

      foreach ($line in $results) {
        if ($line -match '^PROGRESS:(\d+)/(\d+):(.+)$') {
          $progBar.Value    = [int]$Matches[1]
          $progBar.Maximum  = [int]$Matches[2]
          $txtProgress.Text = $Matches[3]
        } elseif ($line -match '^DONE:(.+)$') {
          $doneFile = $Matches[1]
        } elseif ($line -match '^ERROR:(.+)$') {
          $errorMsg = $Matches[1]
        }
      }

      if ($doneFile -and (Test-Path $doneFile)) {
        $script:LastHtmlPath      = $doneFile
        $progBar.Value            = 11
        $txtProgress.Text         = 'Complete!'
        $pnlProgress.Visibility   = [System.Windows.Visibility]::Collapsed
        $btnGenerate.IsEnabled    = $true
        $btnExport.IsEnabled      = $true
        $btnOpenBrowser.IsEnabled = $true
        $txtStatusBar.Text        = "Report generated for $capturedConvId"
        $webReport.Navigate($doneFile)
      } elseif ($errorMsg) {
        # Show error report
        $errHtml = @"
<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>
  body{font-family:'Segoe UI',sans-serif;background:#F3F4F6;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;}
  .card{background:white;border:1px solid #FCA5A5;border-radius:10px;padding:40px 50px;text-align:center;max-width:500px;}
  h2{color:#B91C1C;margin-bottom:10px;}
  p{color:#6B7280;font-size:12px;line-height:1.6;}
  pre{background:#F9FAFB;border:1px solid #E5E7EB;border-radius:6px;padding:12px;font-size:11px;text-align:left;overflow-x:auto;margin-top:12px;}
</style></head><body>
<div class="card">
  <h2>&#x26A0; Report Generation Failed</h2>
  <p>An error occurred while fetching data for:</p>
  <pre>$capturedConvId</pre>
  <pre>$errorMsg</pre>
  <p>Check that you have the correct permissions and that the Conversation ID is valid.</p>
</div></body></html>
"@
        $errFile = Join-Path $script:TempDir 'error.html'
        $errHtml | Set-Content -LiteralPath $errFile -Encoding UTF8
        $webReport.Navigate($errFile)
        $pnlProgress.Visibility = [System.Windows.Visibility]::Collapsed
        $btnGenerate.IsEnabled  = $script:IsLoggedIn
        $txtStatusBar.Text      = "Error: $errorMsg"
      } else {
        $pnlProgress.Visibility = [System.Windows.Visibility]::Collapsed
        $btnGenerate.IsEnabled  = $script:IsLoggedIn
        $txtStatusBar.Text      = 'No output returned from report engine.'
      }
    }
  })
  $pollTimer.Start()
})

# ── Export HTML button ───────────────────────────────────────────────────────
$btnExport.Add_Click({
  if (-not $script:LastHtmlPath -or -not (Test-Path $script:LastHtmlPath)) {
    [System.Windows.MessageBox]::Show('No report to export. Generate a report first.', 'No Report', 'OK', 'Information') | Out-Null
    return
  }

  $convId    = $txtConvId.Text.Trim()
  $datePart  = (Get-Date).ToString('yyyyMMdd-HHmm')
  $dlg       = New-Object Microsoft.Win32.SaveFileDialog
  $dlg.Title       = 'Export Report Card'
  $dlg.Filter      = 'HTML File (*.html)|*.html|All Files (*.*)|*.*'
  $dlg.FileName    = "ConvReport_${convId}_${datePart}.html"
  $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')

  if ($dlg.ShowDialog() -eq $true) {
    try {
      Copy-Item -LiteralPath $script:LastHtmlPath -Destination $dlg.FileName -Force
      $txtStatusBar.Text = "Exported to: $($dlg.FileName)"
    } catch {
      [System.Windows.MessageBox]::Show("Export failed: $($_.Exception.Message)", 'Export Error', 'OK', 'Error') | Out-Null
    }
  }
})

# ── Open in Browser button ────────────────────────────────────────────────────
$btnOpenBrowser.Add_Click({
  if (-not $script:LastHtmlPath -or -not (Test-Path $script:LastHtmlPath)) {
    [System.Windows.MessageBox]::Show('No report to open. Generate a report first.', 'No Report', 'OK', 'Information') | Out-Null
    return
  }
  try {
    Start-Process -FilePath $script:LastHtmlPath
  } catch {
    # Fallback using cmd
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c start `"`" `"$($script:LastHtmlPath)`"" -WindowStyle Hidden
  }
})

# ── ConvID field: Enter key triggers Generate ────────────────────────────────
$txtConvId.Add_KeyDown({
  param($sender, $e)
  if ($e.Key -eq [System.Windows.Input.Key]::Return -and $btnGenerate.IsEnabled) {
    $btnGenerate.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
  }
})

# ── Region/ClientId fields: save on change ───────────────────────────────────
$txtRegion.Add_LostFocus({
  if ($txtRegion.Text.Trim() -and $txtClientId.Text.Trim()) {
    Save-Config -Region $txtRegion.Text.Trim() -ClientId $txtClientId.Text.Trim() -RedirectUri $cfg.RedirectUri
  }
})
$txtClientId.Add_LostFocus({
  if ($txtRegion.Text.Trim() -and $txtClientId.Text.Trim()) {
    Save-Config -Region $txtRegion.Text.Trim() -ClientId $txtClientId.Text.Trim() -RedirectUri $cfg.RedirectUri
  }
})

# ── Show window ──────────────────────────────────────────────────────────────
$window.ShowDialog() | Out-Null
