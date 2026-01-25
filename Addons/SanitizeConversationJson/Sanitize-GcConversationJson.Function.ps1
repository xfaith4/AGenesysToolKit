#requires -Version 5.1

function Sanitize-GcConversationJson {
  <#
  .SYNOPSIS
    Sanitizes PII from Genesys Cloud conversation JSON exports.

  .DESCRIPTION
    Replaces values known to be PII (phone/email/name/id/IP/SIP) either by:
    - property name matches (stronger typing), and/or
    - pattern matching within free-form strings (emails, tel:/sip:, IPv4, loose US phone)

    By default, placeholders are stable within a single run (same input value maps to the same token).
    Use `-StableAcrossRuns` to make placeholders stable across runs (salted hash).

  .PARAMETER Path
    Path to a JSON file to sanitize.

  .PARAMETER Json
    Raw JSON text to sanitize.

  .PARAMETER OutPath
    Optional output file path. If omitted, returns sanitized JSON string.

  .PARAMETER StableAcrossRuns
    When set, tokens are derived from a salted SHA256 hash (stable across runs).

  .PARAMETER Salt
    Salt used for token hashing when `-StableAcrossRuns` is enabled.

  .PARAMETER ExtraPiiKeys
    Extra property names to treat as PII (case-insensitive exact match).

  .EXAMPLE
    Sanitize-GcConversationJson -Path .\details.json -OutPath .\details.sanitized.json | Out-Null

  .EXAMPLE
    $clean = Sanitize-GcConversationJson -Json (Get-Content .\details.json -Raw)
  #>
  [CmdletBinding()]
  param(
    [Parameter(ParameterSetName = 'File', Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter(ParameterSetName = 'Json', Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Json,

    [Parameter()]
    [string]$OutPath,

    [Parameter()]
    [switch]$StableAcrossRuns,

    [Parameter()]
    [string]$Salt = 'gc-sanitize',

    [Parameter()]
    [string[]]$ExtraPiiKeys
  )

  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'

  $piiPhoneKeys = @(
    'ani', 'dnis', 'sessiondnis', 'address', 'phonenumber', 'callbacknumber', 'externalnumber',
    'from', 'to', 'caller', 'callee', 'dialednumber'
  )
  $piiEmailKeys = @('email', 'emailaddress', 'smtpaddress')
  $piiNameKeys = @('name', 'firstname', 'lastname', 'fullname', 'displayname')
  $piiIdKeys = @('externalcontactid', 'contactid', 'customerid', 'accountid', 'personid')
  $piiSipKeys = @('sipuri', 'uri', 'sessionuri')
  $piiIpKeys = @('ip', 'ipaddress', 'remoteip', 'localip')

  if ($ExtraPiiKeys) {
    $piiIdKeys += $ExtraPiiKeys
  }

  $setPhone = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $setEmail = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $setName = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $setId = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $setSip = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $setIp = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

  foreach ($k in $piiPhoneKeys) { [void]$setPhone.Add($k) }
  foreach ($k in $piiEmailKeys) { [void]$setEmail.Add($k) }
  foreach ($k in $piiNameKeys) { [void]$setName.Add($k) }
  foreach ($k in $piiIdKeys) { [void]$setId.Add($k) }
  foreach ($k in $piiSipKeys) { [void]$setSip.Add($k) }
  foreach ($k in $piiIpKeys) { [void]$setIp.Add($k) }

  $counters = @{
    TEL = 0; EMAIL = 0; NAME = 0; SIP = 0; IP = 0; ID = 0
  }

  $map = @{
    TEL   = @{}
    EMAIL = @{}
    NAME  = @{}
    SIP   = @{}
    IP    = @{}
    ID    = @{}
  }

  function Get-HashTag {
    param([Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][string]$Value)

    $bytes = [Text.Encoding]::UTF8.GetBytes("$Salt|$Type|$Value")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $hash = $sha.ComputeHash($bytes)
    }
    finally {
      $sha.Dispose()
    }
    ($hash[0..5] | ForEach-Object { $_.ToString('x2') }) -join ''
  }

  function New-Token {
    param(
      [Parameter(Mandatory)][ValidateSet('TEL', 'EMAIL', 'NAME', 'SIP', 'IP', 'ID')]
      [string]$Type,
      [Parameter(Mandatory)][string]$Original
    )

    if ($map[$Type].ContainsKey($Original)) { return $map[$Type][$Original] }

    if ($StableAcrossRuns) {
      $tag = Get-HashTag -Type $Type -Value $Original
      $token = "<$Type`_$tag>"
    }
    else {
      $counters[$Type]++
      $token = "<$Type`_{0:D4}>" -f [int]$counters[$Type]
    }

    $map[$Type][$Original] = $token
    $token
  }

  $reEmail = [regex]'(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b'
  $reTel = [regex]'(?i)\btel:\+?[0-9][0-9\-\.\(\) ]{6,}[0-9]\b'
  $reSip = [regex]'(?i)\bsip:[^ \t\r\n"]+'
  $reIp = [regex]'\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\b'
  # Loose phone pattern (non-tel:), used cautiously.
  # Avoid leaving a leading "(" behind by not requiring \b at the start.
  $rePhoneLoose = [regex]'(?i)(?<!\w)(?:\+?1[\s\-\.]?)?\(?\d{3}\)?[\s\-\.]?\d{3}[\s\-\.]?\d{4}(?!\w)'

  function Sanitize-String {
    param([Parameter(Mandatory)][string]$s)

    $s = $reTel.Replace($s, {
        param($m)
        $orig = $m.Value
        $tok = New-Token -Type 'TEL' -Original $orig
        'tel:' + $tok
      })

    $s = $reSip.Replace($s, {
        param($m)
        $orig = $m.Value
        $tok = New-Token -Type 'SIP' -Original $orig
        'sip:' + $tok
      })

    $s = $reEmail.Replace($s, {
        param($m)
        New-Token -Type 'EMAIL' -Original $m.Value
      })

    $s = $reIp.Replace($s, {
        param($m)
        New-Token -Type 'IP' -Original $m.Value
      })

    $s = $rePhoneLoose.Replace($s, {
        param($m)
        New-Token -Type 'TEL' -Original $m.Value
      })

    $s
  }

  function Sanitize-Value {
    param(
      [Parameter(Mandatory)]$Value,
      [string]$PropName
    )

    if ($null -eq $Value) { return $null }

    if ($Value -is [string]) {
      if ($PropName) {
        if ($setPhone.Contains($PropName)) {
          $orig = $Value
          if ($orig -match '^(?i)tel:') { return 'tel:' + (New-Token -Type 'TEL' -Original $orig) }
          return New-Token -Type 'TEL' -Original $orig
        }
        if ($setSip.Contains($PropName)) { return 'sip:' + (New-Token -Type 'SIP' -Original $Value) }
        if ($setEmail.Contains($PropName)) { return New-Token -Type 'EMAIL' -Original $Value }
        if ($setName.Contains($PropName)) { return New-Token -Type 'NAME' -Original $Value }
        if ($setIp.Contains($PropName)) { return New-Token -Type 'IP' -Original $Value }
        if ($setId.Contains($PropName)) { return New-Token -Type 'ID' -Original $Value }
      }

      return (Sanitize-String -s $Value)
    }

    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [datetime]) {
      return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
      $out = @{}
      foreach ($k in $Value.Keys) {
        $keyName = [string]$k
        $out[$k] = Sanitize-Value -Value $Value[$k] -PropName $keyName
      }
      return $out
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [pscustomobject])) {
      $list = New-Object System.Collections.Generic.List[object]
      foreach ($item in $Value) {
        $list.Add((Sanitize-Value -Value $item -PropName $null)) | Out-Null
      }
      return $list.ToArray()
    }

    $props = $Value.PSObject.Properties | Where-Object { $_.MemberType -in 'NoteProperty', 'Property' }
    if (-not $props) { return $Value }

    $o = [ordered]@{}
    foreach ($p in $props) {
      $o[$p.Name] = Sanitize-Value -Value $p.Value -PropName $p.Name
    }
    [pscustomobject]$o
  }

  if ($PSCmdlet.ParameterSetName -eq 'File') {
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  }
  else {
    $raw = $Json
  }

  $obj = $raw | ConvertFrom-Json -Depth 100
  $sanitized = Sanitize-Value -Value $obj -PropName $null
  $outJson = $sanitized | ConvertTo-Json -Depth 100

  if ($OutPath) {
    $outJson | Out-File -LiteralPath $OutPath -Encoding UTF8
    return Get-Item -LiteralPath $OutPath
  }

  $outJson
}
