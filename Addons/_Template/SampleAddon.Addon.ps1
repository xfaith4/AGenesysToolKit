#requires -Version 5.1

function New-GcSampleAddonView {
  [CmdletBinding()]
  param([Parameter(Mandatory)][pscustomobject]$Addon)

  $title = if ($Addon.Name) { [string]$Addon.Name } else { 'Sample Addon' }
  $desc = if ($Addon.Description) { [string]$Addon.Description } else { 'This is a template addon view.' }

  $escapedTitle = if (Get-Command Escape-GcXml -ErrorAction SilentlyContinue) { Escape-GcXml $title } else { $title }
  $escapedDesc = if (Get-Command Escape-GcXml -ErrorAction SilentlyContinue) { Escape-GcXml $desc } else { $desc }

  $xaml = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Border CornerRadius="10" BorderBrush="#FFE5E7EB" BorderThickness="1" Background="#FFF9FAFB" Padding="14">
      <StackPanel>
        <TextBlock Text="$escapedTitle" FontSize="16" FontWeight="SemiBold" Foreground="#FF111827"/>
        <TextBlock Text="$escapedDesc" Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
        <Button x:Name="BtnHello" Content="Hello" Width="90" Height="30" Margin="0,14,0,0"/>
        <TextBlock x:Name="TxtOut" Text="Ready." Margin="0,10,0,0" Foreground="#FF6B7280"/>
      </StackPanel>
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

  $btn = $view.FindName('BtnHello')
  $txt = $view.FindName('TxtOut')

  $btn.Add_Click({
    try { $txt.Text = "Hello from $title" } catch { }
  }.GetNewClosure())

  $view
}

