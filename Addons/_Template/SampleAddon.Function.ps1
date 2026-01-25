#requires -Version 5.1

function Invoke-GcSampleAddonAction {
  [CmdletBinding()]
  param()

  "Sample addon action executed at $(Get-Date -Format o)"
}

