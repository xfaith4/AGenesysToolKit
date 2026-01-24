### BEGIN FILE: Sanitize-GcConversationJson.ps1
#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Sanitize-GcConversationJson {
  [CmdletBinding()]
  param(
    # Either pass a file...
    [Parameter(ParameterSetName='File', Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    # ...or pass raw JSON text
    [Parameter(ParameterSetName='Json', Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Json,

    # Output file path (optional). If omitted, returns sanitized JSON string.
    [Parameter()]
    [string]$OutPath,

    # If set, placeholders are stable across runs (salted hash). If not set, stable within a single run.
    [Parameter()]
    [switch]$StableAcrossRuns,

    # Salt used only when -StableAcrossRuns is enabled
    [Parameter()]
    [string]$Salt = 'gc-sanitize',

    # Extra property names to treat as PII (case-insensitive exact match)
    [Parameter()]
    [string[]]$ExtraPiiKeys
  )

  # --- Configuration: common Genesys-ish PII-ish keys (case-insensitive exact match) ---
  $piiPhoneKeys = @(
    'ani','dnis','sessiondnis','address','phonenumber','callbacknumber','externalnumber',
    'from','to','caller','callee','dialednumber'
  )
  $piiEmailKeys = @('email','emailaddress','smtpaddress')
  $piiNameKeys  = @('name','firstname','lastname','fullname','displayname')
  $piiIdKeys    = @('externalcontactid','contactid','customerid','accountid','personid')
  $piiSipKeys   = @('sipuri','uri','sessionuri')
  $piiIpKeys    = @('ip','ipaddress','remoteip','localip')

  if ($ExtraPiiKeys) {
    $piiIdKeys += $ExtraPiiKeys
  }

  # Normalize to hashsets for fast lookup
  $setPhone = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $setEmail = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $setName  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $setId    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $setSip   = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $setIp    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

  foreach ($k in $piiPhoneKeys) { [void]$setPhone.Add($k) }
  foreach ($k in $piiEmailKeys) { [void]$setEmail.Add($k) }
  foreach ($k in $piiNameKeys)  { [void]$setName.Add($k)  }
  foreach ($k in $piiIdKeys)    { [void]$setId.Add($k)    }
  foreach ($k in $piiSipKeys)   { [void]$setSip.Add($k)   }
  foreach ($k in $piiIpKeys)    { [void]$setIp.Add($k)    }

  # --- Placeholder generator ---
  $counters = @{
    TEL=0; EMAIL=0; NAME=0; SIP=0; IP=0; ID=0; TEXT=0
  }

  # Map: original -> placeholder (ensures consistent replacements in the same run)
  $map = @{
    TEL  = @{}
    EMAIL= @{}
    NAME = @{}
    SIP  = @{}
    IP   = @{}
    ID   = @{}
    TEXT = @{}
  }

  function Get-HashTag {
    param([Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][string]$Value)

    # stable across runs: salted hash -> short tag
    $bytes = [Text.Encoding]::UTF8.GetBytes("$Salt|$Type|$Value")
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try {
      $hash = $sha.ComputeHash($bytes)
    } finally {
      $sha.Dispose()
    }
    # first 6 bytes -> 12 hex chars
    ($hash[0..5] | ForEach-Object { $_.ToString('x2') }) -join ''
  }

  function New-Token {
    param(
      [Parameter(Mandatory)][ValidateSet('TEL','EMAIL','NAME','SIP','IP','ID','TEXT')]
      [string]$Type,
      [Parameter(Mandatory)][string]$Original
    )

    if ($map[$Type].ContainsKey($Original)) { return $map[$Type][$Original] }

    $token = $null
    if ($StableAcrossRuns) {
      $tag = Get-HashTag -Type $Type -Value $Original
      $token = "<$Type`_$tag>"
    } else {
      $counters[$Type]++
      $token = "<$Type`_{0:D4}>" -f [int]$counters[$Type]
    }

    $map[$Type][$Original] = $token
    return $token
  }

  # --- Pattern redaction inside any string (keeps tel:/sip: prefixes intact where possible) ---
  $reEmail = [regex]'(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b'
  $reTel   = [regex]'(?i)\btel:\+?[0-9][0-9\-\.\(\) ]{6,}[0-9]\b'
  $reSip   = [regex]'(?i)\bsip:[^ \t\r\n"]+'
  $reIp    = [regex]'\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\b'
  # loose phone pattern (non-tel:), used cautiously
  $rePhoneLoose = [regex]'(?i)\b(?:\+?1[\s\-\.]?)?(?:\(?\d{3}\)?[\s\-\.]?)\d{3}[\s\-\.]?\d{4}\b'

  function Sanitize-String {
    param([Parameter(Mandatory)][string]$s)

    # tel: first (so we can preserve prefix)
    $s = $reTel.Replace($s, {
      param($m)
      $orig = $m.Value
      $tok = New-Token -Type 'TEL' -Original $orig
      # keep tel: prefix to avoid breaking filters
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
      $orig = $m.Value
      New-Token -Type 'EMAIL' -Original $orig
    })

    $s = $reIp.Replace($s, {
      param($m)
      $orig = $m.Value
      New-Token -Type 'IP' -Original $orig
    })

    $s = $rePhoneLoose.Replace($s, {
      param($m)
      $orig = $m.Value
      New-Token -Type 'TEL' -Original $orig
    })

    return $s
  }

  function Sanitize-Value {
    param(
      [Parameter(Mandatory)]$Value,
      [string]$PropName
    )

    if ($null -eq $Value) { return $null }

    # Primitive
    if ($Value -is [string]) {
      # If property name indicates stronger typing, replace entirely
      if ($PropName) {
        if ($setPhone.Contains($PropName)) {
          $orig = $Value
          if ($orig -match '^(?i)tel:') { return 'tel:' + (New-Token -Type 'TEL' -Original $orig) }
          return New-Token -Type 'TEL' -Original $orig
        }
        if ($setSip.Contains($PropName))   { return 'sip:' + (New-Token -Type 'SIP' -Original $Value) }
        if ($setEmail.Contains($PropName)) { return New-Token -Type 'EMAIL' -Original $Value }
        if ($setName.Contains($PropName))  { return New-Token -Type 'NAME'  -Original $Value }
        if ($setIp.Contains($PropName))    { return New-Token -Type 'IP'    -Original $Value }
        if ($setId.Contains($PropName))    { return New-Token -Type 'ID'    -Original $Value }
      }

      # Otherwise pattern-sanitize inside the string
      return (Sanitize-String -s $Value)
    }

    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [datetime]) {
      return $Value
    }

    # Arrays
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
      $list = @()
      foreach ($item in $Value) {
        $list += (Sanitize-Value -Value $item -PropName $null)
      }
      return $list
    }

    # Hashtables / dictionaries
    if ($Value -is [System.Collections.IDictionary]) {
      $out = @{}
      foreach ($k in $Value.Keys) {
        $keyName = [string]$k
        $out[$k] = Sanitize-Value -Value $Value[$k] -PropName $keyName
      }
      return $out
    }

    # PSCustomObject or other object: treat as property bag
    $props = $Value.PSObject.Properties | Where-Object { $_.MemberType -in 'NoteProperty','Property' }
    if (-not $props) { return $Value }

    $o = [ordered]@{}
    foreach ($p in $props) {
      $o[$p.Name] = Sanitize-Value -Value $p.Value -PropName $p.Name
    }
    return [pscustomobject]$o
  }

  # Load JSON
  if ($PSCmdlet.ParameterSetName -eq 'File') {
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  } else {
    $raw = $Json
  }

  $obj = $raw | ConvertFrom-Json -Depth 200
  $sanitized = Sanitize-Value -Value $obj -PropName $null

  $outJson = $sanitized | ConvertTo-Json -Depth 200

  if ($OutPath) {
    $outJson | Out-File -LiteralPath $OutPath -Encoding UTF8
    return Get-Item -LiteralPath $OutPath
  }

  return $outJson
}

<#
Examples:

# 1) Sanitize a file, write a file (stable within this run)
Sanitize-GcConversationJson -Path .\details.json -OutPath .\details.sanitized.json | Out-Null

# 2) Stable across runs (use a salt stored in your repo / test harness)
Sanitize-GcConversationJson -Path .\details.json -OutPath .\details.sanitized.json -StableAcrossRuns -Salt 'your-repo-salt' | Out-Null

# 3) Pipe JSON text in
$clean = Sanitize-GcConversationJson -Json (Get-Content .\details.json -Raw)

# 4) Add org-specific PII keys
Sanitize-GcConversationJson -Path .\details.json -OutPath .\details.sanitized.json -ExtraPiiKeys @('customernumber','mrn','memberid')
#>
### END FILE: Sanitize-GcConversationJson.ps1
