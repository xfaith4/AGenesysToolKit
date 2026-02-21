# XamlHelpers.ps1
# ─────────────────────────────────────────────────────────────────────────────
# Shared XAML utility functions.
# Dot-sourced by GenesysCloudTool.ps1 and any other script that
# needs to parse XAML strings or escape XML characters.
#
# Extracted from GenesysCloudTool.ps1 as the first decomposition
# step. Moving these here allows them to be unit-tested independently.
# ─────────────────────────────────────────────────────────────────────────────

function Escape-GcXml {
  <#
  .SYNOPSIS
    Escapes special XML characters to prevent parsing errors.

  .DESCRIPTION
    Uses System.Security.SecurityElement.Escape to properly escape
    special characters like &, <, >, ", ' in XML/XAML content.

  .PARAMETER Text
    The text to escape for XML/XAML.

  .EXAMPLE
    Escape-GcXml "Routing & People"
    # Returns: "Routing &amp; People"
  #>
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  return [System.Security.SecurityElement]::Escape($Text)
}

function ConvertFrom-GcXaml {
  <#
  .SYNOPSIS
    Safely loads XAML from a string using XmlReader + XamlReader.Load.

  .DESCRIPTION
    This function provides a safe way to load XAML that avoids issues
    with direct [xml] casting, particularly when XAML contains x:Name
    or other namespace-dependent elements. It uses XmlReader with
    proper settings and XamlReader.Load for parsing.

  .PARAMETER XamlString
    The XAML string to parse.

  .EXAMPLE
    $view = ConvertFrom-GcXaml -XamlString $xamlString
  #>
  param([Parameter(Mandatory)][string]$XamlString)

  try {
    # Create StringReader from XAML string
    $stringReader = New-Object System.IO.StringReader($XamlString)

    # Create XmlReader with appropriate settings
    $xmlReaderSettings = New-Object System.Xml.XmlReaderSettings
    $xmlReaderSettings.IgnoreWhitespace = $false
    $xmlReaderSettings.IgnoreComments = $true

    $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $xmlReaderSettings)

    # Load XAML using XamlReader
    $result = [Windows.Markup.XamlReader]::Load($xmlReader)

    # Clean up
    $xmlReader.Close()
    $stringReader.Close()

    return $result
  }
  catch {
    Write-Error "Failed to parse XAML: $($_.Exception.Message)"
    throw
  }
}
