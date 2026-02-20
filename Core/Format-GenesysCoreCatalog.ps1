### BEGIN FILE: Format-GenesysCoreCatalog.ps1
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$Path,

  [switch]$InPlace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Newtonsoft {
  # PowerShell ships Newtonsoft.Json in most modern builds (via SMA).
  try {
    [void][Newtonsoft.Json.Linq.JToken] | Out-Null
    return $true
  } catch {
    try {
      Add-Type -AssemblyName 'Newtonsoft.Json' | Out-Null
      return $true
    } catch {
      return $false
    }
  }
}

if (-not (Test-Path -LiteralPath $Path)) {
  throw "File not found: $Path"
}

if (-not (Get-Newtonsoft)) {
  throw "Newtonsoft.Json not available. In PS7 it should be; otherwise install a runtime that includes it."
}

$raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

# Strict read: disallow duplicate keys; report line/pos on failures.
$sr = New-Object System.IO.StringReader($raw)
$reader = New-Object Newtonsoft.Json.JsonTextReader($sr)
$reader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
$reader.FloatParseHandling = [Newtonsoft.Json.FloatParseHandling]::Decimal

# Key: error on duplicates (pristine rule)
$load = New-Object Newtonsoft.Json.Linq.JsonLoadSettings
$load.DuplicatePropertyNameHandling = [Newtonsoft.Json.Linq.DuplicatePropertyNameHandling]::Error

try {
  $token = [Newtonsoft.Json.Linq.JToken]::ReadFrom($reader, $load)
} catch {
  $line = $reader.LineNumber
  $pos  = $reader.LinePosition
  throw "Invalid JSON (strict). $($_.Exception.Message) at line $line, position $pos."
}

# Pretty write with stable indentation
$sw = New-Object System.IO.StringWriter
$jw = New-Object Newtonsoft.Json.JsonTextWriter($sw)
$jw.Formatting  = [Newtonsoft.Json.Formatting]::Indented
$jw.Indentation = 2
$jw.IndentChar  = ' '
$jw.StringEscapeHandling = [Newtonsoft.Json.StringEscapeHandling]::Default

$token.WriteTo($jw)
$jw.Flush()

# Ensure trailing newline
$out = $sw.ToString()
if (-not $out.EndsWith("`n")) { $out += "`n" }

if ($InPlace) {
  Set-Content -LiteralPath $Path -Value $out -Encoding UTF8
  Write-Host "Formatted in place: $Path"
} else {
  $out
}
### END FILE
