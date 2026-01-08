### BEGIN: Core Paging Primitive (Core/GenesysClient.psm1)

function Invoke-GcRequest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','PATCH','DELETE')] [string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [hashtable]$Query,
    $Body,
    [hashtable]$Headers
  )

  # NOTE: This is a placeholder wrapper. Your real implementation should:
  # - Build full URL (region)
  # - Add Authorization header
  # - JSON serialize body (when appropriate)
  # - Handle errors and rate limiting
  throw "Invoke-GcRequest not implemented in this snippet."
}

function Invoke-GcPagedRequest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('GET','POST')] [string]$Method,
    [Parameter(Mandatory)][string]$Path,

    # For APIs where paging is driven by POST body (some analytics endpoints)
    $Body,

    [hashtable]$Query = @{},
    [hashtable]$Headers,

    # Product principle: default to ALL unless user constrains it.
    [switch]$All = $true,

    [int]$PageSize = 100,
    [int]$MaxItems = 0,   # 0 = unlimited (dangerous in massive orgs, but matches your principle)
    [int]$MaxPages = 0    # 0 = unlimited
  )

  # If caller doesn’t want All, just do one request.
  if (-not $All) {
    return Invoke-GcRequest -Method $Method -Path $Path -Query $Query -Body $Body -Headers $Headers
  }

  $items = New-Object System.Collections.Generic.List[object]

  # Try to detect style: cursor vs pageNumber vs nextUri
  $cursor = $null
  $pageNumber = 1
  $pagesFetched = 0

  while ($true) {
    $q = @{} + $Query

    # Apply standard page sizing hints if they’re respected.
    if (-not $q.ContainsKey('pageSize')) { $q.pageSize = $PageSize }

    if ($cursor) {
      $q.cursor = $cursor
    } else {
      # Some endpoints use pageNumber/pageSize; harmless if ignored.
      if (-not $q.ContainsKey('pageNumber')) { $q.pageNumber = $pageNumber }
    }

    $resp = Invoke-GcRequest -Method $Method -Path $Path -Query $q -Body $Body -Headers $Headers
    $pagesFetched++

    # Heuristic: pick the “collection” property if known; otherwise attempt common ones.
    $batch = $null
    foreach ($k in @('entities','results','conversations','users','items','data')) {
      if ($resp.PSObject.Properties.Name -contains $k) { $batch = $resp.$k; break }
    }

    if ($null -eq $batch) {
      # If response itself is an array, treat it as batch.
      if ($resp -is [System.Collections.IEnumerable] -and -not ($resp -is [string])) {
        $batch = $resp
      } else {
        # No obvious list; return raw response.
        return $resp
      }
    }

    foreach ($it in $batch) {
      $items.Add($it) | Out-Null
      if ($MaxItems -gt 0 -and $items.Count -ge $MaxItems) { break }
    }

    if ($MaxItems -gt 0 -and $items.Count -ge $MaxItems) { break }
    if ($MaxPages -gt 0 -and $pagesFetched -ge $MaxPages) { break }

    # Cursor pattern
    $nextCursor = $null
    if ($resp.PSObject.Properties.Name -contains 'cursor') { $nextCursor = $resp.cursor }
    if ($resp.PSObject.Properties.Name -contains 'nextCursor') { $nextCursor = $resp.nextCursor }

    # nextUri / nextPage pattern
    $nextUri = $null
    foreach ($k in @('nextUri','nextPage','next')) {
      if ($resp.PSObject.Properties.Name -contains $k) { $nextUri = $resp.$k; break }
    }

    # totalHits/pageCount pattern
    $pageCount = $null
    if ($resp.PSObject.Properties.Name -contains 'pageCount') { $pageCount = [int]$resp.pageCount }

    if ($nextCursor) {
      $cursor = $nextCursor
      continue
    }

    if ($nextUri) {
      # If the API returns a full path for the next page, follow it.
      # Normalize to Path (strip host) if your client expects path-only.
      $Path = $nextUri
      $cursor = $null
      continue
    }

    if ($pageCount) {
      if ($pageNumber -ge $pageCount) { break }
      $pageNumber++
      continue
    }

    # If no paging signals, assume we’re done.
    break
  }

  return $items
}

### END: Core Paging Primitive
