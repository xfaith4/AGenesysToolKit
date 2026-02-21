# Audits.ps1
# -----------------------------------------------------------------------------
# Audits workspace views: Extension Audit
#
# Dot-sourced by GenesysCloudTool.ps1 at startup.
# All functions depend on helpers defined in the main script (Get-El,
# Set-Status, Start-AppJob, Set-ControlEnabled, Enable-PrimaryActionButtons,
# Get-CallContext, etc.) which are in scope at call time.
#
# ExtensionAudit.psm1 is NOT imported at dot-source time; it is imported
# inside each Start-AppJob script block so it runs in the job's runspace.
# -----------------------------------------------------------------------------

function New-ExtensionAuditView {
  <#
  .SYNOPSIS
    Creates the Extension Audit module view.

  .DESCRIPTION
    Provides a UI for detecting Genesys Cloud extension and user
    misconfigurations:
      - Missing extension assignments
      - Extension discrepancies (owner mismatch)
      - Duplicate user extension assignments
      - Duplicate extension records
      - Stale tokens (> 90 days)
      - Users missing a default station
      - Users missing location

    Auth is read from $script:AppState.AccessToken (no separate token input).
    Background operations run via Start-AppJob (JobRunner runspace pattern).
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

    <!-- Control Panel -->
    <Border CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="12" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel>
          <TextBlock Text="Extension &amp; User Audit" FontSize="14" FontWeight="SemiBold" Foreground="#FF111827"/>
          <TextBlock Text="Detects misconfigurations: missing assignments, owner mismatches, duplicates, stale tokens, and missing defaults." Foreground="#FF6B7280" Margin="0,4,0,0" TextWrapping="Wrap"/>
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
            <CheckBox x:Name="ChkIncludeInactive" Content="Include inactive users" VerticalAlignment="Center" Margin="0,0,16,0"/>
            <TextBlock Text="Stale token threshold (days):" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="TxtStaleTokenDays" Text="90" Width="52" Height="24" VerticalContentAlignment="Center"/>
          </StackPanel>
        </StackPanel>

        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
          <Button x:Name="BtnAuditRun" Content="Build Context &amp; Run Audit" Width="180" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnAuditExportCsv" Content="Export CSV" Width="100" Height="32" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnAuditClear" Content="Clear" Width="70" Height="32" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Summary Cards -->
    <Border Grid.Row="1" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Card: Users loaded -->
        <Border Grid.Column="0" CornerRadius="6" Background="#FFF0FDF4" BorderBrush="#FF86EFAC" BorderThickness="1" Padding="10,8" Margin="0,0,6,0">
          <StackPanel>
            <TextBlock x:Name="TxtCardUsers" Text="—" FontSize="20" FontWeight="Bold" Foreground="#FF166534" HorizontalAlignment="Center"/>
            <TextBlock Text="Users loaded" FontSize="10" Foreground="#FF4ADE80" HorizontalAlignment="Center"/>
          </StackPanel>
        </Border>

        <!-- Card: Extensions -->
        <Border Grid.Column="1" CornerRadius="6" Background="#FFF0FDF4" BorderBrush="#FF86EFAC" BorderThickness="1" Padding="10,8" Margin="0,0,6,0">
          <StackPanel>
            <TextBlock x:Name="TxtCardExtensions" Text="—" FontSize="20" FontWeight="Bold" Foreground="#FF166534" HorizontalAlignment="Center"/>
            <TextBlock Text="Extensions loaded" FontSize="10" Foreground="#FF4ADE80" HorizontalAlignment="Center"/>
          </StackPanel>
        </Border>

        <!-- Card: Missing -->
        <Border Grid.Column="2" CornerRadius="6" Background="#FFFEF9C3" BorderBrush="#FFFEDF64" BorderThickness="1" Padding="10,8" Margin="0,0,6,0">
          <StackPanel>
            <TextBlock x:Name="TxtCardMissing" Text="—" FontSize="20" FontWeight="Bold" Foreground="#FF92400E" HorizontalAlignment="Center"/>
            <TextBlock Text="Missing assignments" FontSize="10" Foreground="#FFCA8A04" HorizontalAlignment="Center"/>
          </StackPanel>
        </Border>

        <!-- Card: Discrepancies -->
        <Border Grid.Column="3" CornerRadius="6" Background="#FFFEF9C3" BorderBrush="#FFFEDF64" BorderThickness="1" Padding="10,8" Margin="0,0,6,0">
          <StackPanel>
            <TextBlock x:Name="TxtCardDisc" Text="—" FontSize="20" FontWeight="Bold" Foreground="#FF92400E" HorizontalAlignment="Center"/>
            <TextBlock Text="Discrepancies" FontSize="10" Foreground="#FFCA8A04" HorizontalAlignment="Center"/>
          </StackPanel>
        </Border>

        <!-- Card: Dup Users -->
        <Border Grid.Column="4" CornerRadius="6" Background="#FFFFF1F2" BorderBrush="#FFFDB0BB" BorderThickness="1" Padding="10,8" Margin="0,0,6,0">
          <StackPanel>
            <TextBlock x:Name="TxtCardDupUsers" Text="—" FontSize="20" FontWeight="Bold" Foreground="#FF9F1239" HorizontalAlignment="Center"/>
            <TextBlock Text="Dup. user ext." FontSize="10" Foreground="#FFBE185D" HorizontalAlignment="Center"/>
          </StackPanel>
        </Border>

        <!-- Card: Dup Records -->
        <Border Grid.Column="5" CornerRadius="6" Background="#FFFFF1F2" BorderBrush="#FFFDB0BB" BorderThickness="1" Padding="10,8" Margin="0,0,6,0">
          <StackPanel>
            <TextBlock x:Name="TxtCardDupExts" Text="—" FontSize="20" FontWeight="Bold" Foreground="#FF9F1239" HorizontalAlignment="Center"/>
            <TextBlock Text="Dup. ext. records" FontSize="10" Foreground="#FFBE185D" HorizontalAlignment="Center"/>
          </StackPanel>
        </Border>

        <!-- Card: Stale tokens -->
        <Border Grid.Column="6" CornerRadius="6" Background="#FFEFF6FF" BorderBrush="#FFBFDBFE" BorderThickness="1" Padding="10,8" Margin="0,0,6,0">
          <StackPanel>
            <TextBlock x:Name="TxtCardStale" Text="—" FontSize="20" FontWeight="Bold" Foreground="#FF1E3A8A" HorizontalAlignment="Center"/>
            <TextBlock Text="Stale tokens" FontSize="10" Foreground="#FF3B82F6" HorizontalAlignment="Center"/>
          </StackPanel>
        </Border>

        <!-- Card: User issues -->
        <Border Grid.Column="7" CornerRadius="6" Background="#FFEFF6FF" BorderBrush="#FFBFDBFE" BorderThickness="1" Padding="10,8">
          <StackPanel>
            <TextBlock x:Name="TxtCardUserIssues" Text="—" FontSize="20" FontWeight="Bold" Foreground="#FF1E3A8A" HorizontalAlignment="Center"/>
            <TextBlock Text="Station/location" FontSize="10" Foreground="#FF3B82F6" HorizontalAlignment="Center"/>
          </StackPanel>
        </Border>
      </Grid>
    </Border>

    <!-- Result Tabs -->
    <Border Grid.Row="2" CornerRadius="8" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="White" Padding="12">
      <TabControl x:Name="TabResults" Background="Transparent" BorderThickness="0">

        <!-- Missing Assignments -->
        <TabItem Header="Missing Assignments">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Text="Users with a profile extension but no matching extension record." Foreground="#FF6B7280"/>
              <TextBlock x:Name="TxtMissingCount" Text="" Margin="8,0,0,0" Foreground="#FF92400E" FontWeight="SemiBold"/>
            </StackPanel>
            <DataGrid x:Name="GridMissing" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
                      HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Extension" Binding="{Binding ProfileExtension}" Width="120"/>
                <DataGridTextColumn Header="User ID"   Binding="{Binding UserId}"   Width="290"/>
                <DataGridTextColumn Header="Name"      Binding="{Binding UserName}"  Width="200"/>
                <DataGridTextColumn Header="Email"     Binding="{Binding UserEmail}" Width="250"/>
                <DataGridTextColumn Header="State"     Binding="{Binding UserState}" Width="*"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </TabItem>

        <!-- Discrepancies -->
        <TabItem Header="Discrepancies">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Text="Extension records whose owner does not match the user claiming that extension." Foreground="#FF6B7280"/>
              <TextBlock x:Name="TxtDiscCount" Text="" Margin="8,0,0,0" Foreground="#FF92400E" FontWeight="SemiBold"/>
            </StackPanel>
            <DataGrid x:Name="GridDisc" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
                      HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Extension"     Binding="{Binding ProfileExtension}"   Width="100"/>
                <DataGridTextColumn Header="User ID"       Binding="{Binding UserId}"             Width="290"/>
                <DataGridTextColumn Header="Name"          Binding="{Binding UserName}"           Width="180"/>
                <DataGridTextColumn Header="Ext. ID"       Binding="{Binding ExtensionId}"        Width="290"/>
                <DataGridTextColumn Header="Owner Type"    Binding="{Binding ExtensionOwnerType}" Width="100"/>
                <DataGridTextColumn Header="Owner ID"      Binding="{Binding ExtensionOwnerId}"   Width="*"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </TabItem>

        <!-- Duplicate User Assignments -->
        <TabItem Header="Duplicate User Ext.">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Text="Same extension number appears in the profile of multiple users." Foreground="#FF6B7280"/>
              <TextBlock x:Name="TxtDupUsersCount" Text="" Margin="8,0,0,0" Foreground="#FF9F1239" FontWeight="SemiBold"/>
            </StackPanel>
            <DataGrid x:Name="GridDupUsers" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
                      HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Extension" Binding="{Binding ProfileExtension}" Width="120"/>
                <DataGridTextColumn Header="User ID"   Binding="{Binding UserId}"   Width="290"/>
                <DataGridTextColumn Header="Name"      Binding="{Binding UserName}"  Width="200"/>
                <DataGridTextColumn Header="Email"     Binding="{Binding UserEmail}" Width="250"/>
                <DataGridTextColumn Header="State"     Binding="{Binding UserState}" Width="*"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </TabItem>

        <!-- Duplicate Extension Records -->
        <TabItem Header="Duplicate Ext. Records">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Text="Multiple telephony extension records share the same number." Foreground="#FF6B7280"/>
              <TextBlock x:Name="TxtDupExtsCount" Text="" Margin="8,0,0,0" Foreground="#FF9F1239" FontWeight="SemiBold"/>
            </StackPanel>
            <DataGrid x:Name="GridDupExts" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
                      HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Number"     Binding="{Binding ExtensionNumber}" Width="100"/>
                <DataGridTextColumn Header="Ext. ID"    Binding="{Binding ExtensionId}"     Width="290"/>
                <DataGridTextColumn Header="Owner Type" Binding="{Binding OwnerType}"       Width="110"/>
                <DataGridTextColumn Header="Owner ID"   Binding="{Binding OwnerId}"         Width="290"/>
                <DataGridTextColumn Header="Pool ID"    Binding="{Binding ExtensionPoolId}" Width="*"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </TabItem>

        <!-- Stale Tokens -->
        <TabItem Header="Stale Tokens">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Text="Users whose last token was issued beyond the configured day threshold." Foreground="#FF6B7280"/>
              <TextBlock x:Name="TxtStaleCount" Text="" Margin="8,0,0,0" Foreground="#FF1E3A8A" FontWeight="SemiBold"/>
            </StackPanel>
            <DataGrid x:Name="GridStale" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
                      HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
              <DataGrid.Columns>
                <DataGridTextColumn Header="User ID"           Binding="{Binding UserId}"               Width="290"/>
                <DataGridTextColumn Header="Name"              Binding="{Binding UserName}"             Width="200"/>
                <DataGridTextColumn Header="Email"             Binding="{Binding UserEmail}"            Width="240"/>
                <DataGridTextColumn Header="State"             Binding="{Binding UserState}"            Width="80"/>
                <DataGridTextColumn Header="Last Token (UTC)"  Binding="{Binding TokenLastIssuedUtc}"   Width="170"/>
                <DataGridTextColumn Header="Days Ago"          Binding="{Binding DaysSinceTokenIssued}" Width="*"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </TabItem>

        <!-- No Default Station -->
        <TabItem Header="No Default Station">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Text="Users with no default station assigned." Foreground="#FF6B7280"/>
              <TextBlock x:Name="TxtNoStationCount" Text="" Margin="8,0,0,0" Foreground="#FF1E3A8A" FontWeight="SemiBold"/>
            </StackPanel>
            <DataGrid x:Name="GridNoStation" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
                      HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
              <DataGrid.Columns>
                <DataGridTextColumn Header="User ID" Binding="{Binding UserId}"    Width="290"/>
                <DataGridTextColumn Header="Name"    Binding="{Binding UserName}"  Width="200"/>
                <DataGridTextColumn Header="Email"   Binding="{Binding UserEmail}" Width="*"/>
                <DataGridTextColumn Header="State"   Binding="{Binding UserState}" Width="80"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </TabItem>

        <!-- No Location -->
        <TabItem Header="No Location">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Text="Users with no location assigned." Foreground="#FF6B7280"/>
              <TextBlock x:Name="TxtNoLocationCount" Text="" Margin="8,0,0,0" Foreground="#FF1E3A8A" FontWeight="SemiBold"/>
            </StackPanel>
            <DataGrid x:Name="GridNoLocation" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
                      HeadersVisibility="Column" GridLinesVisibility="None" AlternatingRowBackground="#FFF9FAFB">
              <DataGrid.Columns>
                <DataGridTextColumn Header="User ID" Binding="{Binding UserId}"    Width="290"/>
                <DataGridTextColumn Header="Name"    Binding="{Binding UserName}"  Width="200"/>
                <DataGridTextColumn Header="Email"   Binding="{Binding UserEmail}" Width="*"/>
                <DataGridTextColumn Header="State"   Binding="{Binding UserState}" Width="80"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </TabItem>

      </TabControl>
    </Border>

  </Grid>
</UserControl>
"@

  $view = ConvertFrom-GcXaml -XamlString $xamlString

  $h = @{
    BtnAuditRun        = $view.FindName('BtnAuditRun')
    BtnAuditExportCsv  = $view.FindName('BtnAuditExportCsv')
    BtnAuditClear      = $view.FindName('BtnAuditClear')
    ChkIncludeInactive = $view.FindName('ChkIncludeInactive')
    TxtStaleTokenDays  = $view.FindName('TxtStaleTokenDays')
    TabResults         = $view.FindName('TabResults')

    # Summary cards
    TxtCardUsers       = $view.FindName('TxtCardUsers')
    TxtCardExtensions  = $view.FindName('TxtCardExtensions')
    TxtCardMissing     = $view.FindName('TxtCardMissing')
    TxtCardDisc        = $view.FindName('TxtCardDisc')
    TxtCardDupUsers    = $view.FindName('TxtCardDupUsers')
    TxtCardDupExts     = $view.FindName('TxtCardDupExts')
    TxtCardStale       = $view.FindName('TxtCardStale')
    TxtCardUserIssues  = $view.FindName('TxtCardUserIssues')

    # Tab labels
    TxtMissingCount    = $view.FindName('TxtMissingCount')
    TxtDiscCount       = $view.FindName('TxtDiscCount')
    TxtDupUsersCount   = $view.FindName('TxtDupUsersCount')
    TxtDupExtsCount    = $view.FindName('TxtDupExtsCount')
    TxtStaleCount      = $view.FindName('TxtStaleCount')
    TxtNoStationCount  = $view.FindName('TxtNoStationCount')
    TxtNoLocationCount = $view.FindName('TxtNoLocationCount')

    # DataGrids
    GridMissing    = $view.FindName('GridMissing')
    GridDisc       = $view.FindName('GridDisc')
    GridDupUsers   = $view.FindName('GridDupUsers')
    GridDupExts    = $view.FindName('GridDupExts')
    GridStale      = $view.FindName('GridStale')
    GridNoStation  = $view.FindName('GridNoStation')
    GridNoLocation = $view.FindName('GridNoLocation')
  }

  Enable-PrimaryActionButtons -Handles $h

  # ── Helpers ──────────────────────────────────────────────────────────────────

  function Reset-AuditCards {
    $h.TxtCardUsers.Text      = '—'
    $h.TxtCardExtensions.Text = '—'
    $h.TxtCardMissing.Text    = '—'
    $h.TxtCardDisc.Text       = '—'
    $h.TxtCardDupUsers.Text   = '—'
    $h.TxtCardDupExts.Text    = '—'
    $h.TxtCardStale.Text      = '—'
    $h.TxtCardUserIssues.Text = '—'

    $h.TxtMissingCount.Text    = ''
    $h.TxtDiscCount.Text       = ''
    $h.TxtDupUsersCount.Text   = ''
    $h.TxtDupExtsCount.Text    = ''
    $h.TxtStaleCount.Text      = ''
    $h.TxtNoStationCount.Text  = ''
    $h.TxtNoLocationCount.Text = ''

    $h.GridMissing.ItemsSource    = $null
    $h.GridDisc.ItemsSource       = $null
    $h.GridDupUsers.ItemsSource   = $null
    $h.GridDupExts.ItemsSource    = $null
    $h.GridStale.ItemsSource      = $null
    $h.GridNoStation.ItemsSource  = $null
    $h.GridNoLocation.ItemsSource = $null
  }

  function Populate-AuditResults {
    param($Result)

    if ($null -eq $Result) { return }

    # Summary cards
    $h.TxtCardUsers.Text      = [string]$Result.UsersTotal
    $h.TxtCardExtensions.Text = [string]$Result.ExtensionsTotal

    $h.TxtCardMissing.Text    = [string]@($Result.Missing).Count
    $h.TxtCardDisc.Text       = [string]@($Result.Discrepancies).Count
    $h.TxtCardDupUsers.Text   = [string]@($Result.DuplicateUsers).Count
    $h.TxtCardDupExts.Text    = [string]@($Result.DuplicateExtensions).Count
    $h.TxtCardStale.Text      = [string]@($Result.StaleTokens).Count
    $stationAndLoc            = @($Result.NoStation).Count + @($Result.NoLocation).Count
    $h.TxtCardUserIssues.Text = [string]$stationAndLoc

    # Tab count labels
    $h.TxtMissingCount.Text    = ("({0} users)" -f @($Result.Missing).Count)
    $h.TxtDiscCount.Text       = ("({0} issues)" -f @($Result.Discrepancies).Count)
    $h.TxtDupUsersCount.Text   = ("({0} rows)" -f @($Result.DuplicateUsers).Count)
    $h.TxtDupExtsCount.Text    = ("({0} rows)" -f @($Result.DuplicateExtensions).Count)
    $h.TxtStaleCount.Text      = ("({0} users)" -f @($Result.StaleTokens).Count)
    $h.TxtNoStationCount.Text  = ("({0} users)" -f @($Result.NoStation).Count)
    $h.TxtNoLocationCount.Text = ("({0} users)" -f @($Result.NoLocation).Count)

    # DataGrids
    $h.GridMissing.ItemsSource    = $Result.Missing
    $h.GridDisc.ItemsSource       = $Result.Discrepancies
    $h.GridDupUsers.ItemsSource   = $Result.DuplicateUsers
    $h.GridDupExts.ItemsSource    = $Result.DuplicateExtensions
    $h.GridStale.ItemsSource      = $Result.StaleTokens
    $h.GridNoStation.ItemsSource  = $Result.NoStation
    $h.GridNoLocation.ItemsSource = $Result.NoLocation
  }

  # ── Run Audit ─────────────────────────────────────────────────────────────────

  $h.BtnAuditRun.Add_Click({
    $ctx = Get-CallContext
    if (-not $ctx) {
      Set-Status "Extension Audit: no access token — authenticate first."
      return
    }

    $includeInactive = [bool]$h.ChkIncludeInactive.IsChecked
    $staleTokenDays  = 90
    try { $staleTokenDays = [int]$h.TxtStaleTokenDays.Text } catch { $staleTokenDays = 90 }
    if ($staleTokenDays -lt 1) { $staleTokenDays = 90 }

    Reset-AuditCards
    Set-Status "Extension Audit: building context (loading users + extensions)..."
    Set-ControlEnabled -Control $h.BtnAuditRun       -Enabled $false
    Set-ControlEnabled -Control $h.BtnAuditExportCsv -Enabled $false
    Set-ControlEnabled -Control $h.BtnAuditClear     -Enabled $false

    Start-AppJob -Name "Extension Audit" -Type "Audit" -ScriptBlock {
      param($includeInactive, $staleTokenDays)

      # Import the audit module inside this runspace.
      $coreRoot       = Join-Path -Path $script:AppState.RepositoryRoot -ChildPath 'Core'
      $auditModulePath = Join-Path $coreRoot 'ExtensionAudit.psm1'
      Import-Module $auditModulePath -Force -ErrorAction Stop

      $apiBaseUri  = "https://api.$($script:AppState.Region)"
      $accessToken = $script:AppState.AccessToken

      # Build context (loads all users and extensions via paged API)
      $ctx = New-GcExtensionAuditContext `
        -ApiBaseUri         $apiBaseUri `
        -AccessToken        $accessToken `
        -IncludeInactive:$includeInactive

      # Run all 7 finding functions
      $missing      = Find-MissingExtensionAssignments          -Context $ctx
      $disc         = Find-ExtensionDiscrepancies               -Context $ctx
      $dupUsers     = Find-DuplicateUserExtensionAssignments    -Context $ctx
      $dupExts      = Find-DuplicateExtensionRecords            -Context $ctx
      $stale        = Find-UsersWithStaleTokens                 -Context $ctx -OlderThanDays $staleTokenDays
      $noStation    = Find-UsersMissingDefaultStation           -Context $ctx
      $noLocation   = Find-UsersMissingLocation                 -Context $ctx

      # Return summary + findings (not the full context object, to minimize serialization)
      [pscustomobject]@{
        UsersTotal          = @($ctx.Users).Count
        ExtensionsTotal     = @($ctx.Extensions).Count
        ExtensionMode       = $ctx.ExtensionMode
        Missing             = $missing
        Discrepancies       = $disc
        DuplicateUsers      = $dupUsers
        DuplicateExtensions = $dupExts
        StaleTokens         = $stale
        NoStation           = $noStation
        NoLocation          = $noLocation
      }
    } -ArgumentList @($includeInactive, $staleTokenDays) -OnCompleted ({
      param($job)

      Set-ControlEnabled -Control $h.BtnAuditRun   -Enabled $true
      Set-ControlEnabled -Control $h.BtnAuditClear -Enabled $true

      if ($job.Status -eq 'Failed' -or $job.Status -eq 'Canceled') {
        $errMsg = if ($job.Errors -and @($job.Errors).Count -gt 0) { [string]$job.Errors[0] } else { 'Unknown error' }
        Set-Status "Extension Audit failed: $errMsg"
        $h.TxtCardUsers.Text = 'Error'
        return
      }

      $result = $job.Result
      if ($null -eq $result) {
        Set-Status "Extension Audit: completed but returned no data."
        return
      }

      Populate-AuditResults -Result $result

      $totalIssues = @($result.Missing).Count + @($result.Discrepancies).Count +
                     @($result.DuplicateUsers).Count + @($result.DuplicateExtensions).Count +
                     @($result.StaleTokens).Count + @($result.NoStation).Count + @($result.NoLocation).Count

      Set-Status ("Extension Audit complete — {0} users, {1} extensions, {2} total issues." -f
        $result.UsersTotal, $result.ExtensionsTotal, $totalIssues)

      Set-ControlEnabled -Control $h.BtnAuditExportCsv -Enabled ($totalIssues -gt 0)
    })
  })

  # ── Export CSV ────────────────────────────────────────────────────────────────

  $h.BtnAuditExportCsv.Add_Click({
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outputDir  = $script:ArtifactsDir
    $exportPath = Join-Path $outputDir ("audit-extension-{0}.csv" -f $timestamp)

    try {
      # Gather all findings from current grids
      $allRows = New-Object System.Collections.Generic.List[object]

      function Add-FindingRows {
        param($Grid, [string]$Category)
        if ($null -eq $Grid.ItemsSource) { return }
        foreach ($row in $Grid.ItemsSource) {
          $allRows.Add([pscustomobject]@{
            AuditCategory    = $Category
            Issue            = if ($row.PSObject.Properties['Issue'])            { $row.Issue }            else { $null }
            ProfileExtension = if ($row.PSObject.Properties['ProfileExtension']) { $row.ProfileExtension } else { if ($row.PSObject.Properties['ExtensionNumber']) { $row.ExtensionNumber } else { $null } }
            UserId           = if ($row.PSObject.Properties['UserId'])           { $row.UserId }           else { $null }
            UserName         = if ($row.PSObject.Properties['UserName'])         { $row.UserName }         else { $null }
            UserEmail        = if ($row.PSObject.Properties['UserEmail'])        { $row.UserEmail }        else { $null }
            UserState        = if ($row.PSObject.Properties['UserState'])        { $row.UserState }        else { $null }
            ExtensionId      = if ($row.PSObject.Properties['ExtensionId'])      { $row.ExtensionId }      else { $null }
            ExtensionOwnerId = if ($row.PSObject.Properties['ExtensionOwnerId']) { $row.ExtensionOwnerId } else { if ($row.PSObject.Properties['OwnerId']) { $row.OwnerId } else { $null } }
            DaysSinceToken   = if ($row.PSObject.Properties['DaysSinceTokenIssued']) { $row.DaysSinceTokenIssued } else { $null }
          })
        }
      }

      Add-FindingRows -Grid $h.GridMissing    -Category 'Missing Assignment'
      Add-FindingRows -Grid $h.GridDisc       -Category 'Discrepancy'
      Add-FindingRows -Grid $h.GridDupUsers   -Category 'Duplicate User Extension'
      Add-FindingRows -Grid $h.GridDupExts    -Category 'Duplicate Extension Record'
      Add-FindingRows -Grid $h.GridStale      -Category 'Stale Token'
      Add-FindingRows -Grid $h.GridNoStation  -Category 'No Default Station'
      Add-FindingRows -Grid $h.GridNoLocation -Category 'No Location'

      if ($allRows.Count -eq 0) {
        Set-Status "Extension Audit CSV export: no findings to export."
        return
      }

      $allRows | Export-Csv -NoTypeInformation -Path $exportPath -Encoding utf8 -Force

      # Register with app artifacts list
      try {
        $script:AppState.Artifacts.Add([pscustomobject]@{
          Name      = [System.IO.Path]::GetFileName($exportPath)
          Path      = $exportPath
          Timestamp = Get-Date
          Type      = 'CSV'
          Source    = 'Extension Audit'
        })
      } catch { }

      Set-Status ("Extension Audit: exported {0} findings to {1}" -f $allRows.Count, [System.IO.Path]::GetFileName($exportPath))
    } catch {
      Set-Status "Extension Audit CSV export failed: $_"
    }
  })

  # ── Clear ─────────────────────────────────────────────────────────────────────

  $h.BtnAuditClear.Add_Click({
    Reset-AuditCards
    Set-ControlEnabled -Control $h.BtnAuditExportCsv -Enabled $false
    Set-ControlEnabled -Control $h.BtnAuditClear     -Enabled $false
    Set-Status "Extension Audit: cleared."
  })

  return $view
}
