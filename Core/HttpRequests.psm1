### BEGIN: Core.HttpRequests.psm1

Set-StrictMode -Version Latest

function Resolve-GcEndpoint {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Path,
    [hashtable] $PathParams
  )

  $resolved = $Path.TrimStart('/')

  # Replace {token} path params (ex: {conversationId})
  if ($PathParams) {
    foreach ($k in $PathParams.Keys) {
      $token = '{' + $k + '}'
      if ($resolved -like "*$token*") {
        $resolved = $resolved.Replace($token, [string]$PathParams[$k])
      }
    }
  }

  return $resolved
}

function ConvertTo-GcQueryString {
  [CmdletBinding()]
  param(
    [hashtable] $Query
  )

  if (-not $Query -or $Query.Count -eq 0) { return "" }

  $pairs = foreach ($kv in $Query.GetEnumerator()) {
    if ($null -eq $kv.Value) { continue }

    # Allow arrays: key=a&key=b
    if ($kv.Value -is [System.Collections.IEnumerable] -and -not ($kv.Value -is [string])) {
      foreach ($v in $kv.Value) {
        "{0}={1}" -f [Uri]::EscapeDataString([string]$kv.Key), [Uri]::EscapeDataString([string]$v)
      }
    } else {
      "{0}={1}" -f [Uri]::EscapeDataString([string]$kv.Key), [Uri]::EscapeDataString([string]$kv.Value)
    }
  }

  return ($pairs -join "&")
}

function Join-GcUri {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $BaseUri,
    [Parameter(Mandatory)] [string] $RelativePath,
    [string] $QueryString
  )

  $base = $BaseUri.TrimEnd('/')
  $rel  = $RelativePath.TrimStart('/')

  if ([string]::IsNullOrWhiteSpace($QueryString)) {
    return "$base/$rel"
  }

  return "$base/$rel`?$QueryString"
}

function Invoke-GcRequest {
  <#
  .SYNOPSIS
    Single Genesys Cloud API request (no pagination loop).

  .DESCRIPTION
    - Builds https://api.<InstanceName>/ + path
    - Replaces {pathParams}
    - Adds query string
    - Adds Authorization header if AccessToken provided
    - Retries transient failures (optional)

  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Path,

    [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
    [string] $Method = 'GET',

    # Either supply InstanceName (ex: "usw2.pure.cloud") or BaseUri directly.
    [string] $InstanceName = "usw2.pure.cloud",
    [string] $BaseUri,

    [hashtable] $Headers,
    [string] $AccessToken,

    [hashtable] $Query,
    [hashtable] $PathParams,

    [object] $Body,

    [int] $RetryCount = 2,
    [int] $RetryDelaySeconds = 2
  )

  if (-not $BaseUri) {
    $BaseUri = "https://api.$($InstanceName)/"
  }

  $resolvedPath = Resolve-GcEndpoint -Path $Path -PathParams $PathParams

  # Headers
  $h = @{}
  if ($Headers) { foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] } }

  if ($AccessToken) {
    $h['Authorization'] = "Bearer $($AccessToken)"
  }

  if (-not $h.ContainsKey('Content-Type')) {
    $h['Content-Type'] = "application/json; charset=utf-8"
  }

  $qs  = ConvertTo-GcQueryString -Query $Query
  $uri = Join-GcUri -BaseUri $BaseUri -RelativePath $resolvedPath -QueryString $qs

  Write-Verbose ("GC {0} {1}" -f $Method, $uri)

  $irmParams = @{
    Uri     = $uri
    Method  = $Method
    Headers = $h
  }

  if ($Method -in @('POST','PUT','PATCH') -and $null -ne $Body) {
    # If already a string assume caller knows; otherwise JSON it.
    if ($Body -is [string]) {
      $irmParams['Body'] = $Body
    } else {
      $irmParams['Body'] = ($Body | ConvertTo-Json -Depth 25)
    }
  }

  $attempt = 0
  while ($true) {
    try {
      return Invoke-RestMethod @irmParams
    } catch {
      $attempt++

      if ($attempt -gt $RetryCount) {
        throw
      }

      Write-Verbose ("Retry {0}/{1} after error: {2}" -f $attempt, $RetryCount, $_.Exception.Message)
      Start-Sleep -Seconds $RetryDelaySeconds
    }
  }
}

function Get-GcItemsFromResponse {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Response,
    [string[]] $ItemProperties = @('entities','results','conversations','items','data')
  )

  # If API returns an array directly
  if ($Response -is [System.Collections.IEnumerable] -and -not ($Response -is [string]) -and -not ($Response.PSObject.Properties.Name -contains 'PSComputerName')) {
    if ($Response -isnot [hashtable] -and $Response -isnot [pscustomobject]) {
      return ,$Response
    }
  }

  $all = New-Object 'System.Collections.Generic.List[object]'

  foreach ($p in $ItemProperties) {
    if ($Response.PSObject.Properties.Name -contains $p) {
      $val = $Response.$p
      if ($val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
        foreach ($x in $val) { [void]$all.Add($x) }
      }
    }
  }

  return $all
}

function Resolve-GcNextLinkToUri {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $NextValue,
    [Parameter(Mandatory)] [string] $BaseUri,
    [Parameter(Mandatory)] [string] $ResolvedPath
  )

  $n = $NextValue.Trim()

  # Full URL
  if ($n -match '^https?://') { return $n }

  # Relative path
  if ($n.StartsWith('/')) {
    $base = $BaseUri.TrimEnd('/')
    return "$base/$($n.TrimStart('/'))"
  }

  # Querystring-ish (your pattern: ^[^/?]+= )
  if ($n -match '^[^/?]+=' ) {
    $base = $BaseUri.TrimEnd('/')
    $rel  = $ResolvedPath.TrimStart('/')
    return "$base/$rel`?$n"
  }

  # Fallback: treat as already-formed URI-ish
  return $n
}

function Invoke-GcPagedRequest {
  <#
  .SYNOPSIS
    Calls a Genesys Cloud endpoint and auto-paginates until completion (default behavior).

  .DESCRIPTION
    Supports:
      - nextPage (querystring or relative path or full URL)
      - nextUri  (querystring or relative path or full URL)
      - pageCount/pageNumber (page-based pagination)
      - cursor-style pagination (cursor/nextCursor fields)

    Returns:
      - By default: the merged item list (entities/results/conversations/etc)
      - If no item list detected: returns the last response object
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Path,

    [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
    [string] $Method = 'GET',

    [string] $InstanceName = "usw2.pure.cloud",
    [string] $BaseUri,

    [hashtable] $Headers,
    [string] $AccessToken,

    [hashtable] $Query,
    [hashtable] $PathParams,
    [object] $Body,

    # Default: engineers get the whole dataset
    [switch] $All = $true,

    [int] $PageSize = 100,
    [int] $MaxPages = 0,     # 0 = unlimited
    [int] $MaxItems = 0,     # 0 = unlimited

    [string[]] $ItemProperties = @('entities','results','conversations','items','data'),

    [int] $RetryCount = 2,
    [int] $RetryDelaySeconds = 2
  )

  if (-not $BaseUri) {
    $BaseUri = "https://api.$($InstanceName)/"
  }

  $resolvedPath = Resolve-GcEndpoint -Path $Path -PathParams $PathParams

  $q = @{}
  if ($Query) { foreach ($k in $Query.Keys) { $q[$k] = $Query[$k] } }

  # Respect caller if they explicitly set pageSize, otherwise default it.
  if (-not $q.ContainsKey('pageSize') -and $PageSize -gt 0) {
    $q['pageSize'] = $PageSize
  }
  if (-not $q.ContainsKey('pageNumber')) {
    $q['pageNumber'] = 1
  }

  $items = New-Object 'System.Collections.Generic.List[object]'
  $pagesFetched = 0
  $lastResponse = $null

  # Initial request
  $lastResponse = Invoke-GcRequest -Path $resolvedPath -Method $Method -InstanceName $InstanceName -BaseUri $BaseUri `
    -Headers $Headers -AccessToken $AccessToken -Query $q -Body $Body -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds

  $chunk = Get-GcItemsFromResponse -Response $lastResponse -ItemProperties $ItemProperties
  foreach ($x in $chunk) { [void]$items.Add($x) }
  $pagesFetched++

  if (-not $All) {
    if ($items.Count -gt 0) { return $items }
    return $lastResponse
  }

  # Pull pagination signals (mirrors your screenshot logic)
  $nextPage   = $lastResponse.nextPage
  $nextUri    = $lastResponse.nextUri
  $pageCount  = $lastResponse.pageCount
  $pageNumber = $lastResponse.pageNumber
  $cursor     = $lastResponse.cursor
  $nextCursor = $lastResponse.nextCursor

  while ($true) {

    if ($MaxPages -gt 0 -and $pagesFetched -ge $MaxPages) { break }
    if ($MaxItems -gt 0 -and $items.Count -ge $MaxItems) { break }

    $nextCallUri = $null

    if ($nextPage) {
      $nextCallUri = Resolve-GcNextLinkToUri -NextValue ([string]$nextPage) -BaseUri $BaseUri -ResolvedPath $resolvedPath
    }
    elseif ($nextUri) {
      $nextCallUri = Resolve-GcNextLinkToUri -NextValue ([string]$nextUri) -BaseUri $BaseUri -ResolvedPath $resolvedPath
    }
    elseif ($nextCursor) {
      # Cursor-style (common pattern): add as query param for next request
      $q['cursor'] = [string]$nextCursor
      $q.Remove('pageNumber') | Out-Null
    }
    elseif ($cursor -and (-not $q.ContainsKey('cursor'))) {
      # Some endpoints return cursor (not nextCursor) and expect you to feed it back
      $q['cursor'] = [string]$cursor
      $q.Remove('pageNumber') | Out-Null
    }
    elseif ($pageCount -and $pageNumber -and ($pageCount -gt 1) -and ($pageNumber -lt $pageCount)) {
      $pageNumber++
      $q['pageNumber'] = $pageNumber
      # fall-through to normal request using updated query
    }
    else {
      break
    }

    # Fetch next page
    if ($nextCallUri) {
      # Reuse the same headers/token/body, just hit the resolved next URI
      Write-Verbose ("GC {0} {1}" -f $Method, $nextCallUri)

      $attempt = 0
      while ($true) {
        try {
          $irmParams = @{
            Uri     = $nextCallUri
            Method  = $Method
            Headers = if ($Headers) { $Headers } else { @{} }
          }

          if ($AccessToken) { $irmParams.Headers['Authorization'] = "Bearer $($AccessToken)" }
          if (-not $irmParams.Headers.ContainsKey('Content-Type')) { $irmParams.Headers['Content-Type'] = "application/json; charset=utf-8" }

          if ($Method -in @('POST','PUT','PATCH') -and $null -ne $Body) {
            if ($Body -is [string]) {
              $irmParams['Body'] = $Body
            } else {
              $irmParams['Body'] = ($Body | ConvertTo-Json -Depth 25)
            }
          }

          $lastResponse = Invoke-RestMethod @irmParams
          break
        } catch {
          $attempt++
          if ($attempt -gt $RetryCount) { throw }
          Start-Sleep -Seconds $RetryDelaySeconds
        }
      }
    }
    else {
      $lastResponse = Invoke-GcRequest -Path $resolvedPath -Method $Method -InstanceName $InstanceName -BaseUri $BaseUri `
        -Headers $Headers -AccessToken $AccessToken -Query $q -Body $Body -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds
    }

    $chunk = Get-GcItemsFromResponse -Response $lastResponse -ItemProperties $ItemProperties
    foreach ($x in $chunk) { [void]$items.Add($x) }
    $pagesFetched++

    # refresh pagination signals (matches your pattern)
    $nextPage   = $lastResponse.nextPage
    $nextUri    = $lastResponse.nextUri
    $pageCount  = $lastResponse.pageCount
    $pageNumber = $lastResponse.pageNumber
    $cursor     = $lastResponse.cursor
    $nextCursor = $lastResponse.nextCursor
  }

  if ($items.Count -gt 0) { return $items }
  return $lastResponse
}

Export-ModuleMember -Function Invoke-GcRequest, Invoke-GcPagedRequest

### END: Core.HttpRequests.psm1
