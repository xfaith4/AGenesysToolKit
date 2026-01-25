### BEGIN FILE: Sanitize-GcConversationJson.ps1
#requires -Version 5.1
<#
.SYNOPSIS
  Loads the `Sanitize-GcConversationJson` function for local use.

.DESCRIPTION
  This file intentionally has no side effects when executed or dot-sourced.
  It simply dot-sources the real function implementation from
  `Addons/SanitizeConversationJson/Sanitize-GcConversationJson.Function.ps1`.

.EXAMPLE
  .\Addons\Sanitize-GcConversationJson.ps1
  Sanitize-GcConversationJson -Path .\details.json -OutPath .\details.sanitized.json | Out-Null
#>

$addonRoot = Split-Path -Parent $PSCommandPath
$implPath = Join-Path -Path $addonRoot -ChildPath 'SanitizeConversationJson/Sanitize-GcConversationJson.Function.ps1'

if (-not (Test-Path -LiteralPath $implPath)) {
  throw "Sanitizer implementation not found: $implPath"
}

. $implPath
