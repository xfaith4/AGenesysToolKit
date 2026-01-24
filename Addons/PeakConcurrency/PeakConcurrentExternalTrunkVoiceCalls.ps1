### BEGIN FILE: PeakConcurrentExternalTrunkVoiceCalls.ps1
<#
.SYNOPSIS
  Peak Concurrent External-Trunk Voice Calls (Genesys Cloud) — single-file PowerShell script.

.DESCRIPTION
  Computes a defendable, explainable "peak concurrent external-trunk voice legs" metric over a time interval
  using Genesys Cloud Analytics Conversation Details Jobs.

  Core features:
    - Chunked interval processing with overlap buffer (prevents boundary undercount)
    - Pagination-complete result retrieval
    - Interval extraction for external-trunk voice legs (non-wrapup segments)
    - Global de-dupe across overlapping chunks (prevents double-count from overlap)
    - Sweep-line overlap algorithm for peak concurrency (deterministic, auditable)
    - Optional exports: intervals CSV, events CSV, summary JSON

  Authentication is intentionally NOT implemented here.
  Provide -Headers (recommended) that include Authorization, or provide -AccessToken.

.NOTES
  Works in Windows PowerShell 5.1+ and PowerShell 7+.
  Avoids ForEach-Object -Parallel and $using: for PS 5.1 compatibility.

#>

[CmdletBinding()]
param(
  # --- API target ---
  [Parameter(Mandatory=$false)]
  [ValidateNotNullOrEmpty()]
  [string]$ApiBaseUri = 'https://api.usw2.pure.cloud',

  # --- Auth (provided by you; this script will not fetch tokens) ---
  [Parameter(Mandatory=$false)]
  [ValidateNotNullOrEmpty()]
  [string]$AccessToken,

  [Parameter(Mandatory=$false)]
  [hashtable]$Headers,

  # --- Analysis interval (UTC strongly recommended) ---
  [Parameter(Mandatory=$true)]
  [ValidateNotNullOrEmpty()]
  [datetime]$StartUtc,

  [Parameter(Mandatory=$true)]
  [ValidateNotNullOrEmpty()]
  [datetime]$EndUtc,

  # --- Chunking ---
  [Parameter(Mandatory=$false)]
  [ValidateRange(1, 100000)]
  [int]$ChunkSize = 1,

  [Parameter(Mandatory=$false)]
  [ValidateSet('Minutes','Hours','Days')]
  [string]$ChunkUnit = 'Hours',

  # Overlap buffer on each chunk query window. Calls spanning chunk boundaries will be captured.
  [Parameter(Mandatory=$false)]
  [ValidateRange(0, 1440)]
  [int]$ChunkOverlapMinutes = 120,

  # --- Paging ---
  [Parameter(Mandatory=$false)]
  [ValidateRange(10, 500)]
  [int]$PageSize = 100,

  # --- Filtering / selection heuristics ---
  # Optional allow-list of edgeId values; if specified, only include legs matching these.
  [Parameter(Mandatory=$false)]
  [string[]]$AllowedEdgeId,

  # If you want to enforce the "tel:" constraint (ANI/DNIS starts with tel:).
  [Parameter(Mandatory=$false)]
  [switch]$RequireTelUri,

  # If you want to enforce peerId is null/missing (often indicates "root external trunk leg").
  [Parameter(Mandatory=$false)]
  [switch]$RequireNullPeerId,

  # --- Exports ---
  [Parameter(Mandatory=$false)]
  [string]$OutDir = (Get-Location).Path,

  [Parameter(Mandatory=$false)]
  [switch]$ExportIntervalsCsv,

  [Parameter(Mandatory=$false)]
  [switch]$ExportEventsCsv,

  [Parameter(Mandatory=$false)]
  [switch]$ExportSummaryJson,

  # --- API job request body base ---
  # Provide a hashtable representing the POST body for /analytics/conversations/details/jobs.
  # The script will overwrite only the interval part (start/end) per chunk.
  #
  # If omitted, a minimal default is used. You may want to add filters (divisionIds, etc.)
  # appropriate to your environment.
  [Parameter(Mandatory=$false)]
  [hashtable]$JobRequestBodyBase,

  # --- Robustness / Retry ---
  [Parameter(Mandatory=$false)]
  [ValidateRange(0, 20)]
  [int]$MaxRetries = 8,

  [Parameter(Mandatory=$false)]
  [ValidateRange(1, 600)]
  [int]$PollSeconds = 3,

  [Parameter(Mandatory=$false)]
  [ValidateRange(1, 3600)]
  [int]$MaxJobWaitSeconds = 1800,

  [Parameter(Mandatory=$false)]
  [switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------
# Helpers
# -------------------------

function New-LogLine {
  param(
    [Parameter(Mandatory)][ValidateSet('DEBUG','INFO','WARN','ERROR')]
    [string]$Level,
    [Parameter(Mandatory)][string]$Message,
    [hashtable]$Data
  )
  $obj = [ordered]@{
    tsUtc  = ([DateTime]::UtcNow).ToString('o')
    level  = $Level
    msg    = $Message
  }
  if ($Data) {
    foreach ($k in $Data.Keys) { $obj[$k] = $Data[$k] }
  }
  return ($obj | ConvertTo-Json -Compress)
}

function Write-Log {
  param(
    [Parameter(Mandatory)][ValidateSet('DEBUG','INFO','WARN','ERROR')]
    [string]$Level,
    [Parameter(Mandatory)][string]$Message,
    [hashtable]$Data
  )
  if (-not $VerboseLog -and $Level -eq 'DEBUG') { return }
  $line = New-LogLine -Level $Level -Message $Message -Data $Data
  if ($Level -eq 'ERROR') { Write-Error $line }
  elseif ($Level -eq 'WARN') { Write-Warning $line }
  else { Write-Host $line }
}

function Ensure-Dir {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function To-DateTimeOffsetUtc {
  param([Parameter(Mandatory)][object]$Value)
  if ($null -eq $Value) { return $null }

  if ($Value -is [DateTimeOffset]) {
    return $Value.ToUniversalTime()
  }
  if ($Value -is [DateTime]) {
    if ($Value.Kind -eq [DateTimeKind]::Utc) {
      return [DateTimeOffset]::new($Value)
    }
    return ([DateTimeOffset]$Value).ToUniversalTime()
  }

  # Strings from API typically ISO 8601
  $dto = [DateTimeOffset]::Parse($Value.ToString(), [System.Globalization.CultureInfo]::InvariantCulture)
  return $dto.ToUniversalTime()
}

function Clip-Interval {
  param(
    [Parameter(Mandatory)][DateTimeOffset]$Start,
    [Parameter(Mandatory)][DateTimeOffset]$End,
    [Parameter(Mandatory)][DateTimeOffset]$ClipStart,
    [Parameter(Mandatory)][DateTimeOffset]$ClipEnd
  )
  $s = if ($Start -gt $ClipStart) { $Start } else { $ClipStart }
  $e = if ($End   -lt $ClipEnd)   { $End }   else { $ClipEnd }
  if ($e -le $s) { return $null }
  return [pscustomobject]@{ Start=$s; End=$e }
}

function Add-Minutes {
  param([Parameter(Mandatory)][DateTimeOffset]$Ts, [Parameter(Mandatory)][int]$Minutes)
  return $Ts.AddMinutes($Minutes)
}

function Add-ChunkUnit {
  param(
    [Parameter(Mandatory)][DateTimeOffset]$Ts,
    [Parameter(Mandatory)][int]$Size,
    [Parameter(Mandatory)][string]$Unit
  )
  switch ($Unit) {
    'Minutes' { return $Ts.AddMinutes($Size) }
    'Hours'   { return $Ts.AddHours($Size) }
    'Days'    { return $Ts.AddDays($Size) }
    default   { throw "Unsupported ChunkUnit '$Unit'." }
  }
}

function New-ChunkWindows {
  param(
    [Parameter(Mandatory)][DateTimeOffset]$Start,
    [Parameter(Mandatory)][DateTimeOffset]$End,
    [Parameter(Mandatory)][int]$ChunkSize,
    [Parameter(Mandatory)][string]$ChunkUnit,
    [Parameter(Mandatory)][int]$OverlapMinutes
  )

  $chunks = New-Object System.Collections.Generic.List[object]
  $cursor = $Start
  $i = 0
  while ($cursor -lt $End) {
    $chunkStart = $cursor
    $chunkEnd   = Add-ChunkUnit -Ts $cursor -Size $ChunkSize -Unit $ChunkUnit
    if ($chunkEnd -gt $End) { $chunkEnd = $End }

    $queryStart = Add-Minutes -Ts $chunkStart -Minutes (-1 * $OverlapMinutes)
    $queryEnd   = Add-Minutes -Ts $chunkEnd   -Minutes ($OverlapMinutes)

    $chunks.Add([pscustomobject]@{
      Index      = $i
      ChunkStart = $chunkStart
      ChunkEnd   = $chunkEnd
      QueryStart = $queryStart
      QueryEnd   = $queryEnd
    }) | Out-Null

    $cursor = $chunkEnd
    $i++
  }
  return $chunks
}

function Get-EffectiveHeaders {
  # Merge default headers + provided headers + access token
  $h = @{}
  $h['Accept'] = 'application/json'
  $h['Content-Type'] = 'application/json'

  if ($Headers) {
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
  }

  if ($AccessToken) {
    # Don't stomp an explicit Authorization header
    if (-not $h.ContainsKey('Authorization')) {
      $h['Authorization'] = "Bearer $AccessToken"
    }
  }

  if (-not $h.ContainsKey('Authorization')) {
    throw "No Authorization header present. Provide -Headers @{ Authorization = 'Bearer ...' } or -AccessToken."
  }

  return $h
}

function Invoke-GcRequest {
  param(
    [Parameter(Mandatory)][ValidateSet('GET','POST')]
    [string]$Method,
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory=$false)][object]$Body,
    [Parameter(Mandatory=$false)][hashtable]$Headers,
    [Parameter(Mandatory=$false)][int]$MaxRetries = 8
  )

  $attempt = 0
  $delaySeconds = 1

  while ($true) {
    $attempt++
    try {
      $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ErrorAction = 'Stop'
      }
      if ($null -ne $Body) {
        $json = ($Body | ConvertTo-Json -Depth 50 -Compress)
        $params['Body'] = $json
      }

      Write-Log -Level 'DEBUG' -Message "HTTP $Method $Uri" -Data @{ attempt=$attempt }

      # Invoke-RestMethod returns deserialized objects
      return Invoke-RestMethod @params
    }
    catch {
      $ex = $_.Exception
      $statusCode = $null
      $retryAfter = $null

      # Best-effort: pull status code + retry-after if possible
      if ($ex.PSObject.Properties.Name -contains 'Response' -and $ex.Response) {
        try {
          $statusCode = [int]$ex.Response.StatusCode
        } catch { }
        try {
          $retryAfter = $ex.Response.Headers['Retry-After']
        } catch { }
      }

      $isRetryable = $false
      if ($statusCode -in 429, 500, 502, 503, 504) { $isRetryable = $true }

      if (-not $isRetryable -or $attempt -gt $MaxRetries) {
        Write-Log -Level 'ERROR' -Message "HTTP failure (non-retryable or retries exhausted)" -Data @{
          uri=$Uri; method=$Method; attempt=$attempt; statusCode=$statusCode; error=$ex.Message
        }
        throw
      }

      # Respect Retry-After if present, else exponential backoff (capped)
      $sleep = $null
      if ($retryAfter) {
        try { $sleep = [int]$retryAfter } catch { $sleep = $null }
      }
      if (-not $sleep) {
        $sleep = [Math]::Min(60, $delaySeconds)
        $delaySeconds = [Math]::Min(120, $delaySeconds * 2)
      }

      Write-Log -Level 'WARN' -Message "HTTP retryable error; backing off" -Data @{
        uri=$Uri; method=$Method; attempt=$attempt; statusCode=$statusCode; sleepSeconds=$sleep; error=$ex.Message
      }
      Start-Sleep -Seconds $sleep
    }
  }
}

function Get-DefaultJobBody {
  # Minimal valid body; you likely want to add filters (divisionIds, etc.) externally.
  # We will overwrite the interval per chunk. Keep everything else as-is.
  return @{
    interval = '1970-01-01T00:00:00.000Z/1970-01-01T01:00:00.000Z'
    # order is optional; included for determinism
    order   = 'asc'
    paging  = @{
      pageSize   = $PageSize
      pageNumber = 1
    }
  }
}

function Set-JobInterval {
  param(
    [Parameter(Mandatory)][hashtable]$Body,
    [Parameter(Mandatory)][DateTimeOffset]$FromUtc,
    [Parameter(Mandatory)][DateTimeOffset]$ToUtc
  )
  $Body.interval = ("{0}/{1}" -f $FromUtc.ToString('o'), $ToUtc.ToString('o'))
  return $Body
}

function Start-DetailsJob {
  param(
    [Parameter(Mandatory)][DateTimeOffset]$FromUtc,
    [Parameter(Mandatory)][DateTimeOffset]$ToUtc,
    [Parameter(Mandatory)][hashtable]$Headers,
    [Parameter(Mandatory)][hashtable]$JobBodyBase
  )
  $uri = "{0}/api/v2/analytics/conversations/details/jobs" -f $ApiBaseUri.TrimEnd('/')

  # clone body base so we don't mutate caller
  $body = @{}
  foreach ($k in $JobBodyBase.Keys) { $body[$k] = $JobBodyBase[$k] }

  # if nested paging is a hashtable, clone it too
  if ($body.ContainsKey('paging') -and $body['paging'] -is [hashtable]) {
    $p = @{}
    foreach ($k in $body['paging'].Keys) { $p[$k] = $body['paging'][$k] }
    $body['paging'] = $p
  }

  $body = Set-JobInterval -Body $body -FromUtc $FromUtc -ToUtc $ToUtc

  $resp = Invoke-GcRequest -Method 'POST' -Uri $uri -Body $body -Headers $Headers -MaxRetries $MaxRetries

  # Typical response includes jobId
  $jobId = $null
  if ($resp.PSObject.Properties.Name -contains 'jobId') { $jobId = $resp.jobId }
  elseif ($resp.PSObject.Properties.Name -contains 'id') { $jobId = $resp.id }

  if (-not $jobId) {
    throw "POST details job did not return a jobId. Response keys: $($resp.PSObject.Properties.Name -join ', ')"
  }
  return $jobId
}

function Wait-DetailsJob {
  param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][hashtable]$Headers
  )
  $uri = "{0}/api/v2/analytics/conversations/details/jobs/{1}" -f $ApiBaseUri.TrimEnd('/'), $JobId

  $start = [DateTimeOffset]::UtcNow
  while ($true) {
    $resp = Invoke-GcRequest -Method 'GET' -Uri $uri -Headers $Headers -MaxRetries $MaxRetries

    $state = $null
    if ($resp.PSObject.Properties.Name -contains 'state') { $state = $resp.state }
    elseif ($resp.PSObject.Properties.Name -contains 'status') { $state = $resp.status }

    if ($state) { $state = $state.ToString().ToUpperInvariant() }

    if ($state -in 'FULFILLED','COMPLETED','SUCCESS') {
      return $resp
    }
    if ($state -in 'FAILED','ERROR','CANCELED','CANCELLED') {
      throw "Analytics job $($JobId) failed with state '$($state)'."
    }

    $elapsed = ([DateTimeOffset]::UtcNow - $start).TotalSeconds
    if ($elapsed -gt $MaxJobWaitSeconds) {
      throw "Analytics job $($JobId) exceeded MaxJobWaitSeconds ($MaxJobWaitSeconds). Last state '$($state)'."
    }

    Start-Sleep -Seconds $PollSeconds
  }
}

function Get-DetailsJobResultsPaged {
  param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][hashtable]$Headers,
    [Parameter(Mandatory)][int]$PageSize
  )

  $all = New-Object System.Collections.Generic.List[object]
  $pageNumber = 1

  while ($true) {
    $uri = "{0}/api/v2/analytics/conversations/details/jobs/{1}/results?pageNumber={2}&pageSize={3}" -f `
      $ApiBaseUri.TrimEnd('/'), $JobId, $pageNumber, $PageSize

    $resp = Invoke-GcRequest -Method 'GET' -Uri $uri -Headers $Headers -MaxRetries $MaxRetries

    # Response shapes vary; commonly: conversations (array) + cursor/paging info
    $items = $null
    if ($resp.PSObject.Properties.Name -contains 'conversations') { $items = $resp.conversations }
    elseif ($resp.PSObject.Properties.Name -contains 'results') { $items = $resp.results }
    elseif ($resp.PSObject.Properties.Name -contains 'entities') { $items = $resp.entities }

    if ($items) {
      foreach ($it in $items) { $all.Add($it) | Out-Null }
    }

    # Determine whether more pages exist
    $hasMore = $false
    $totalHits = $null
    $pageCount = $null
    $currentSize = 0
    if ($items) { $currentSize = @($items).Count }

    # Prefer explicit paging metadata
    if ($resp.PSObject.Properties.Name -contains 'pageCount') { $pageCount = [int]$resp.pageCount }
    if ($resp.PSObject.Properties.Name -contains 'totalHits') { $totalHits = [int]$resp.totalHits }
    if ($resp.PSObject.Properties.Name -contains 'paging' -and $resp.paging) {
      if ($resp.paging.PSObject.Properties.Name -contains 'pageCount') { $pageCount = [int]$resp.paging.pageCount }
      if ($resp.paging.PSObject.Properties.Name -contains 'total')     { $totalHits = [int]$resp.paging.total }
    }

    if ($pageCount) {
      if ($pageNumber -lt $pageCount) { $hasMore = $true }
    }
    elseif ($totalHits -ne $null) {
      if ($all.Count -lt $totalHits) { $hasMore = $true }
    }
    else {
      # Fallback: if the API returned a full page, assume there may be more
      if ($currentSize -ge $PageSize) { $hasMore = $true }
    }

    if (-not $hasMore) { break }
    $pageNumber++
  }

  return $all
}

function Get-Prop {
  param([Parameter(Mandatory)][object]$Obj, [Parameter(Mandatory)][string]$Name)
  if ($null -eq $Obj) { return $null }
  if ($Obj.PSObject.Properties.Name -contains $Name) { return $Obj.$Name }
  return $null
}

function Get-AnyProp {
  param([Parameter(Mandatory)][object]$Obj, [Parameter(Mandatory)][string[]]$Names)
  foreach ($n in $Names) {
    $v = Get-Prop -Obj $Obj -Name $n
    if ($null -ne $v) { return $v }
  }
  return $null
}

function Test-StartsWithTel {
  param([object]$Value)
  if ($null -eq $Value) { return $false }
  $s = $Value.ToString()
  return $s.StartsWith('tel:', [System.StringComparison]::OrdinalIgnoreCase)
}

function Normalize-String {
  param([object]$Value)
  if ($null -eq $Value) { return $null }
  $s = $Value.ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  return $s
}

function Get-LegKey {
  param(
    [Parameter(Mandatory)][string]$ConversationId,
    [Parameter(Mandatory)][object]$Participant,
    [Parameter(Mandatory)][object]$Session,
    [Parameter(Mandatory)][DateTimeOffset]$Start,
    [Parameter(Mandatory)][DateTimeOffset]$End
  )

  $pid = Normalize-String (Get-AnyProp -Obj $Participant -Names @('participantId','id'))
  $sid = Normalize-String (Get-AnyProp -Obj $Session -Names @('sessionId','id'))

  if ($pid -and $sid) {
    return ("{0}|{1}|{2}" -f $ConversationId, $pid, $sid)
  }

  # Fallback: stable-ish composite
  $ani = Normalize-String (Get-AnyProp -Obj $Session -Names @('ani','caller','fromAddress','from'))
  $dnis = Normalize-String (Get-AnyProp -Obj $Session -Names @('dnis','callee','toAddress','to'))
  return ("{0}|{1:o}|{2:o}|{3}|{4}" -f $ConversationId, $Start, $End, $ani, $dnis)
}

function Get-SessionSegments {
  param([Parameter(Mandatory)][object]$Session)
  $segs = Get-AnyProp -Obj $Session -Names @('segments','segment')
  if ($segs) { return @($segs) }

  # Some schemas: session has 'metrics' or other nested arrays; ignore by default
  return @()
}

function Get-SegmentTime {
  param([Parameter(Mandatory)][object]$Segment, [Parameter(Mandatory)][string[]]$Names)
  $v = Get-AnyProp -Obj $Segment -Names $Names
  if ($null -eq $v) { return $null }
  return To-DateTimeOffsetUtc -Value $v
}

function Get-IntervalFromSession {
  <#
    Strategy:
      - Look at session segments.
      - Exclude wrapup-like segments.
      - Start = min(segmentStart)
      - End   = max(segmentEnd)
      - If end missing, fallback to session end or conversation end passed in
  #>
  param(
    [Parameter(Mandatory)][object]$Session,
    [Parameter(Mandatory)][DateTimeOffset]$ConversationStartUtc,
    [Parameter(Mandatory)][DateTimeOffset]$ConversationEndUtc
  )

  $segments = Get-SessionSegments -Session $Session
  $usable = New-Object System.Collections.Generic.List[object]

  foreach ($seg in $segments) {
    $segType = Normalize-String (Get-AnyProp -Obj $seg -Names @('segmentType','type','name'))
    if ($segType -and $segType.Equals('wrapup', [System.StringComparison]::OrdinalIgnoreCase)) {
      continue
    }
    # Some payloads have more detailed types; "acw"/"aftercallwork" are also not trunk/media
    if ($segType -and ($segType -match 'after' -or $segType -match 'acw' -or $segType -match 'wrap')) {
      continue
    }
    $usable.Add($seg) | Out-Null
  }

  $starts = @()
  $ends   = @()

  foreach ($seg in $usable) {
    $s = Get-SegmentTime -Segment $seg -Names @('segmentStart','segmentStartTime','startTime','start','startDateTime')
    $e = Get-SegmentTime -Segment $seg -Names @('segmentEnd','segmentEndTime','endTime','end','endDateTime')
    if ($s) { $starts += $s }
    if ($e) { $ends   += $e }
  }

  $start = $null
  $end   = $null

  if ($starts.Count -gt 0) { $start = ($starts | Sort-Object)[0] }
  if ($ends.Count   -gt 0) { $end   = ($ends   | Sort-Object)[-1] }

  if (-not $start) {
    # Fallback to session start fields
    $start = To-DateTimeOffsetUtc (Get-AnyProp -Obj $Session -Names @('startTime','start','connectedTime','establishedTime'))
  }
  if (-not $end) {
    # Fallback to session end fields
    $end = To-DateTimeOffsetUtc (Get-AnyProp -Obj $Session -Names @('endTime','end','disconnectedTime'))
  }

  if (-not $start) { $start = $ConversationStartUtc }
  if (-not $end)   { $end   = $ConversationEndUtc }

  if ($null -eq $start -or $null -eq $end) { return $null }
  if ($end -le $start) { return $null }

  return [pscustomobject]@{ Start=$start; End=$end }
}

function Test-IsExternalTrunkVoiceLeg {
  <#
    Heuristic filter:
      - voice media
      - optional: ANI/DNIS starts with tel:
      - optional: peerId is null/missing
      - optional: edgeId allow-list

    Since conversation details schemas can vary, this checks a few likely property names.
  #>
  param(
    [Parameter(Mandatory)][object]$Conversation,
    [Parameter(Mandatory)][object]$Participant,
    [Parameter(Mandatory)][object]$Session
  )

  $mediaType = Normalize-String (Get-AnyProp -Obj $Session -Names @('mediaType','media','type'))
  if (-not $mediaType) {
    $mediaType = Normalize-String (Get-AnyProp -Obj $Participant -Names @('mediaType','media','type'))
  }
  if (-not $mediaType -or -not $mediaType.Equals('voice', [System.StringComparison]::OrdinalIgnoreCase)) {
    return $false
  }

  if ($RequireTelUri) {
    $ani = Get-AnyProp -Obj $Session -Names @('ani','fromAddress','caller','from')
    $dnis = Get-AnyProp -Obj $Session -Names @('dnis','toAddress','callee','to')
    if (-not (Test-StartsWithTel $ani) -and -not (Test-StartsWithTel $dnis)) {
      return $false
    }
  }

  if ($RequireNullPeerId) {
    $peerId = Get-AnyProp -Obj $Session -Names @('peerId','peerID','peer')
    if ($null -ne $peerId -and -not [string]::IsNullOrWhiteSpace($peerId.ToString())) {
      return $false
    }
  }

  if ($AllowedEdgeId -and $AllowedEdgeId.Count -gt 0) {
    $edgeId = Normalize-String (Get-AnyProp -Obj $Session -Names @('edgeId','edgeID'))
    if (-not $edgeId) {
      $edgeId = Normalize-String (Get-AnyProp -Obj $Participant -Names @('edgeId','edgeID'))
    }
    if (-not $edgeId) { return $false }
    if (-not ($AllowedEdgeId -contains $edgeId)) { return $false }
  }

  return $true
}

function Convert-ConversationsToIntervals {
  param(
    [Parameter(Mandatory)][object[]]$Conversations,
    [Parameter(Mandatory)][DateTimeOffset]$AnalysisStartUtc,
    [Parameter(Mandatory)][DateTimeOffset]$AnalysisEndUtc
  )

  $intervals = New-Object System.Collections.Generic.List[object]

  # Explainability counters
  $counts = [ordered]@{
    conversations = @($Conversations).Count
    participants  = 0
    sessions      = 0
    voiceSessions = 0
    passedFilter  = 0
    intervalsRaw  = 0
    intervalsClipped = 0
    intervalsDropped = 0
  }

  foreach ($c in $Conversations) {
    $conversationId = Normalize-String (Get-AnyProp -Obj $c -Names @('conversationId','id'))
    if (-not $conversationId) { $conversationId = [Guid]::NewGuid().ToString() }

    $cStart = To-DateTimeOffsetUtc (Get-AnyProp -Obj $c -Names @('conversationStart','startTime','start'))
    $cEnd   = To-DateTimeOffsetUtc (Get-AnyProp -Obj $c -Names @('conversationEnd','endTime','end'))

    if (-not $cStart) { $cStart = $AnalysisStartUtc }
    if (-not $cEnd)   { $cEnd   = $AnalysisEndUtc }

    $parts = Get-AnyProp -Obj $c -Names @('participants','participant')
    if (-not $parts) { continue }
    $parts = @($parts)
    $counts.participants += $parts.Count

    foreach ($p in $parts) {
      $sessions = Get-AnyProp -Obj $p -Names @('sessions','session')
      if (-not $sessions) { continue }
      $sessions = @($sessions)
      $counts.sessions += $sessions.Count

      foreach ($s in $sessions) {
        # mediaType check (voice)
        $mediaType = Normalize-String (Get-AnyProp -Obj $s -Names @('mediaType','media','type'))
        if ($mediaType -and $mediaType.Equals('voice',[System.StringComparison]::OrdinalIgnoreCase)) {
          $counts.voiceSessions++
        }

        if (-not (Test-IsExternalTrunkVoiceLeg -Conversation $c -Participant $p -Session $s)) {
          continue
        }
        $counts.passedFilter++

        $iv = Get-IntervalFromSession -Session $s -ConversationStartUtc $cStart -ConversationEndUtc $cEnd
        if (-not $iv) { continue }
        $counts.intervalsRaw++

        $clipped = Clip-Interval -Start $iv.Start -End $iv.End -ClipStart $AnalysisStartUtc -ClipEnd $AnalysisEndUtc
        if (-not $clipped) {
          $counts.intervalsDropped++
          continue
        }

        $key = Get-LegKey -ConversationId $conversationId -Participant $p -Session $s -Start $clipped.Start -End $clipped.End

        $intervals.Add([pscustomobject]@{
          LegKey         = $key
          ConversationId = $conversationId
          StartUtc       = $clipped.Start
          EndUtc         = $clipped.End
          Ani            = Normalize-String (Get-AnyProp -Obj $s -Names @('ani','fromAddress','caller','from'))
          Dnis           = Normalize-String (Get-AnyProp -Obj $s -Names @('dnis','toAddress','callee','to'))
          EdgeId         = Normalize-String (Get-AnyProp -Obj $s -Names @('edgeId','edgeID'))
          PeerId         = Normalize-String (Get-AnyProp -Obj $s -Names @('peerId','peerID','peer'))
        }) | Out-Null

        $counts.intervalsClipped++
      }
    }
  }

  return [pscustomobject]@{
    Intervals = $intervals
    Counts    = $counts
  }
}

function Deduplicate-Intervals {
  param([Parameter(Mandatory)][System.Collections.Generic.List[object]]$Intervals)

  $map = @{}
  $deduped = New-Object System.Collections.Generic.List[object]
  $dupes = 0

  foreach ($iv in $Intervals) {
    $k = $iv.LegKey
    if ($map.ContainsKey($k)) {
      # If duplicates exist, keep the widest interval (defensive)
      $existing = $map[$k]
      $newStart = if ($iv.StartUtc -lt $existing.StartUtc) { $iv.StartUtc } else { $existing.StartUtc }
      $newEnd   = if ($iv.EndUtc   -gt $existing.EndUtc)   { $iv.EndUtc }   else { $existing.EndUtc }
      $existing.StartUtc = $newStart
      $existing.EndUtc   = $newEnd
      $dupes++
      continue
    }
    $map[$k] = $iv
    $deduped.Add($iv) | Out-Null
  }

  return [pscustomobject]@{
    Intervals = $deduped
    DuplicateCount = $dupes
  }
}

function New-EventsFromIntervals {
  param([Parameter(Mandatory)][System.Collections.Generic.List[object]]$Intervals)

  $events = New-Object System.Collections.Generic.List[object]
  foreach ($iv in $Intervals) {
    # Start event
    $events.Add([pscustomobject]@{
      TsUtc  = $iv.StartUtc
      Delta  = 1
      LegKey = $iv.LegKey
    }) | Out-Null

    # End event
    $events.Add([pscustomobject]@{
      TsUtc  = $iv.EndUtc
      Delta  = -1
      LegKey = $iv.LegKey
    }) | Out-Null
  }
  return $events
}

function Get-PeakConcurrency {
  <#
    Sweep-line algorithm:
      - Create start/end events
      - Sort by timestamp asc; on ties, process end (-1) before start (+1)
      - Walk events tracking current concurrency and max concurrency
      - Also compute average concurrency by integrating over time.

    Returns:
      Peak, PeakTimestampUtc, AvgConcurrency, DurationSeconds, PeakSampleLegKeys
  #>
  param(
    [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Intervals,
    [Parameter(Mandatory)][DateTimeOffset]$AnalysisStartUtc,
    [Parameter(Mandatory)][DateTimeOffset]$AnalysisEndUtc
  )

  $durationSeconds = ($AnalysisEndUtc - $AnalysisStartUtc).TotalSeconds
  if ($durationSeconds -le 0) { throw "Analysis interval duration is <= 0 seconds." }

  $events = New-EventsFromIntervals -Intervals $Intervals

  # Sort: TsUtc asc, Delta asc (so -1 before +1), LegKey stable
  $sorted = $events | Sort-Object -Property @{Expression='TsUtc'; Ascending=$true}, @{Expression='Delta'; Ascending=$true}, @{Expression='LegKey'; Ascending=$true}

  $current = 0
  $peak = 0
  $peakTs = $null

  # For average concurrency (area under concurrency curve)
  $area = 0.0
  $prevTs = $AnalysisStartUtc

  # Track leg keys active at peak moment (best-effort explainability)
  # We only track when peak is hit; we do not retain full active set history for memory reasons.
  $active = New-Object 'System.Collections.Generic.HashSet[string]'
  $peakSample = @()

  foreach ($ev in $sorted) {
    $t = [DateTimeOffset]$ev.TsUtc

    # Ignore events outside analysis window (should be clipped already, but keep safe)
    if ($t -lt $AnalysisStartUtc) { continue }
    if ($t -gt $AnalysisEndUtc)   { break }

    # Integrate area from prevTs -> t with current concurrency
    $dt = ($t - $prevTs).TotalSeconds
    if ($dt -gt 0) {
      $area += ($current * $dt)
      $prevTs = $t
    }

    # Apply delta with tie-break already ensured by sorting Delta asc (end first)
    if ($ev.Delta -eq -1) {
      $null = $active.Remove([string]$ev.LegKey)
      $current -= 1
    }
    else {
      $null = $active.Add([string]$ev.LegKey)
      $current += 1
      if ($current -gt $peak) {
        $peak = $current
        $peakTs = $t

        # snapshot up to 50 keys for explainability
        $peakSample = @()
        $i = 0
        foreach ($k in $active) {
          $peakSample += $k
          $i++
          if ($i -ge 50) { break }
        }
      }
    }
  }

  # Close out integration to AnalysisEndUtc
  if ($prevTs -lt $AnalysisEndUtc) {
    $dtTail = ($AnalysisEndUtc - $prevTs).TotalSeconds
    if ($dtTail -gt 0) { $area += ($current * $dtTail) }
  }

  $avg = $area / $durationSeconds

  return [pscustomobject]@{
    PeakConcurrency     = $peak
    PeakTimestampUtc    = $peakTs
    AverageConcurrency  = [Math]::Round($avg, 6)
    DurationSeconds     = [Math]::Round($durationSeconds, 3)
    IntervalCount       = $Intervals.Count
    PeakSampleLegKeys   = $peakSample
  }
}

# -------------------------
# Main
# -------------------------

Ensure-Dir -Path $OutDir

$analysisStart = To-DateTimeOffsetUtc -Value $StartUtc
$analysisEnd   = To-DateTimeOffsetUtc -Value $EndUtc

if ($analysisEnd -le $analysisStart) {
  throw "EndUtc must be after StartUtc."
}

$effHeaders = Get-EffectiveHeaders

$jobBodyBase = $JobRequestBodyBase
if (-not $jobBodyBase) { $jobBodyBase = Get-DefaultJobBody }

Write-Log -Level 'INFO' -Message 'Starting analysis' -Data @{
  apiBaseUri = $ApiBaseUri
  analysisStartUtc = $analysisStart.ToString('o')
  analysisEndUtc   = $analysisEnd.ToString('o')
  chunkSize = $ChunkSize
  chunkUnit = $ChunkUnit
  overlapMinutes = $ChunkOverlapMinutes
  pageSize = $PageSize
  requireTelUri = [bool]$RequireTelUri
  requireNullPeerId = [bool]$RequireNullPeerId
  allowedEdgeIdCount = if ($AllowedEdgeId) { $AllowedEdgeId.Count } else { 0 }
}

$chunks = New-ChunkWindows -Start $analysisStart -End $analysisEnd -ChunkSize $ChunkSize -ChunkUnit $ChunkUnit -OverlapMinutes $ChunkOverlapMinutes

Write-Log -Level 'INFO' -Message 'Chunk plan built' -Data @{
  chunkCount = $chunks.Count
}

# Aggregate intervals across all chunks (they are clipped to analysis range, then de-duped globally)
$allIntervals = New-Object System.Collections.Generic.List[object]

# Explainability: per-chunk counters
$chunkStats = New-Object System.Collections.Generic.List[object]

for ($ci = 0; $ci -lt $chunks.Count; $ci++) {
  $chunk = $chunks[$ci]

  Write-Progress -Activity 'Processing chunks' -Status ("Chunk {0}/{1}" -f ($ci+1), $chunks.Count) -PercentComplete ((($ci+1) / $chunks.Count) * 100)

  Write-Log -Level 'INFO' -Message 'Starting chunk' -Data @{
    index = $chunk.Index
    chunkStartUtc = $chunk.ChunkStart.ToString('o')
    chunkEndUtc   = $chunk.ChunkEnd.ToString('o')
    queryStartUtc = $chunk.QueryStart.ToString('o')
    queryEndUtc   = $chunk.QueryEnd.ToString('o')
  }

  $jobId = Start-DetailsJob -FromUtc $chunk.QueryStart -ToUtc $chunk.QueryEnd -Headers $effHeaders -JobBodyBase $jobBodyBase
  Write-Log -Level 'INFO' -Message 'Job created' -Data @{ index=$chunk.Index; jobId=$jobId }

  $null = Wait-DetailsJob -JobId $jobId -Headers $effHeaders
  Write-Log -Level 'INFO' -Message 'Job fulfilled' -Data @{ index=$chunk.Index; jobId=$jobId }

  $convos = Get-DetailsJobResultsPaged -JobId $jobId -Headers $effHeaders -PageSize $PageSize
  Write-Log -Level 'INFO' -Message 'Results retrieved' -Data @{ index=$chunk.Index; jobId=$jobId; conversations=@($convos).Count }

  $converted = Convert-ConversationsToIntervals -Conversations $convos -AnalysisStartUtc $analysisStart -AnalysisEndUtc $analysisEnd

  foreach ($iv in $converted.Intervals) { $allIntervals.Add($iv) | Out-Null }

  $chunkStats.Add([pscustomobject]@{
    chunkIndex = $chunk.Index
    jobId      = $jobId
    queryStartUtc = $chunk.QueryStart
    queryEndUtc   = $chunk.QueryEnd
    counts     = $converted.Counts
    intervalsAdded = $converted.Intervals.Count
  }) | Out-Null

  Write-Log -Level 'INFO' -Message 'Chunk converted' -Data @{
    index = $chunk.Index
    intervalsAdded = $converted.Intervals.Count
    intervalsRaw = $converted.Counts.intervalsRaw
    intervalsDropped = $converted.Counts.intervalsDropped
    passedFilter = $converted.Counts.passedFilter
  }
}

Write-Progress -Activity 'Processing chunks' -Completed

Write-Log -Level 'INFO' -Message 'All chunks processed' -Data @{
  totalIntervalsPreDedup = $allIntervals.Count
}

$dedup = Deduplicate-Intervals -Intervals $allIntervals
$intervals = $dedup.Intervals

Write-Log -Level 'INFO' -Message 'De-duplication complete' -Data @{
  totalIntervalsPostDedup = $intervals.Count
  duplicateCount = $dedup.DuplicateCount
}

# Compute peak concurrency + average concurrency
$metric = Get-PeakConcurrency -Intervals $intervals -AnalysisStartUtc $analysisStart -AnalysisEndUtc $analysisEnd

Write-Log -Level 'INFO' -Message 'Metric computed' -Data @{
  peakConcurrency = $metric.PeakConcurrency
  peakTimestampUtc = if ($metric.PeakTimestampUtc) { $metric.PeakTimestampUtc.ToString('o') } else { $null }
  averageConcurrency = $metric.AverageConcurrency
  durationSeconds = $metric.DurationSeconds
  intervalCount = $metric.IntervalCount
}

# --- Exports ---
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss')
$baseName = "peak_concurrency_external_trunk_voice_{0}" -f $stamp

if ($ExportIntervalsCsv) {
  $path = [System.IO.Path]::Combine($OutDir, "$baseName`_intervals.csv")
  $intervals |
    Select-Object LegKey, ConversationId,
      @{n='StartUtc';e={$_.StartUtc.ToString('o')}},
      @{n='EndUtc';e={$_.EndUtc.ToString('o')}},
      Ani, Dnis, EdgeId, PeerId |
    Export-Csv -NoTypeInformation -Path $path -Encoding UTF8
  Write-Log -Level 'INFO' -Message 'Exported intervals CSV' -Data @{ path=$path; count=$intervals.Count }
}

if ($ExportEventsCsv) {
  $events = New-EventsFromIntervals -Intervals $intervals
  $path = [System.IO.Path]::Combine($OutDir, "$baseName`_events.csv")
  $events |
    Select-Object @{n='TsUtc';e={$_.TsUtc.ToString('o')}}, Delta, LegKey |
    Export-Csv -NoTypeInformation -Path $path -Encoding UTF8
  Write-Log -Level 'INFO' -Message 'Exported events CSV' -Data @{ path=$path; count=$events.Count }
}

if ($ExportSummaryJson) {
  $path = [System.IO.Path]::Combine($OutDir, "$baseName`_summary.json")
  $summary = [ordered]@{
    apiBaseUri = $ApiBaseUri
    analysis = @{
      startUtc = $analysisStart.ToString('o')
      endUtc   = $analysisEnd.ToString('o')
      durationSeconds = $metric.DurationSeconds
    }
    chunking = @{
      chunkSize = $ChunkSize
      chunkUnit = $ChunkUnit
      overlapMinutes = $ChunkOverlapMinutes
      chunkCount = $chunks.Count
    }
    filtering = @{
      requireTelUri = [bool]$RequireTelUri
      requireNullPeerId = [bool]$RequireNullPeerId
      allowedEdgeIds = $AllowedEdgeId
    }
    results = @{
      peakConcurrency = $metric.PeakConcurrency
      peakTimestampUtc = if ($metric.PeakTimestampUtc) { $metric.PeakTimestampUtc.ToString('o') } else { $null }
      averageConcurrency = $metric.AverageConcurrency
      intervalCount = $metric.IntervalCount
      duplicatesRemoved = $dedup.DuplicateCount
      peakSampleLegKeys = $metric.PeakSampleLegKeys
    }
    perChunkStats = $chunkStats
  }

  $summary | ConvertTo-Json -Depth 50 | Set-Content -Path $path -Encoding UTF8
  Write-Log -Level 'INFO' -Message 'Exported summary JSON' -Data @{ path=$path }
}

# --- Friendly console summary (human-readable) ---
"`n=== Peak Concurrent External-Trunk Voice Calls (Genesys Cloud) ==="
"Interval (UTC): {0}  ->  {1}" -f $analysisStart.ToString('o'), $analysisEnd.ToString('o')
"Intervals used (deduped): {0}" -f $intervals.Count
"Duplicates removed: {0}" -f $dedup.DuplicateCount
"Peak concurrency: {0}" -f $metric.PeakConcurrency
"Peak timestamp (UTC): {0}" -f (if ($metric.PeakTimestampUtc) { $metric.PeakTimestampUtc.ToString('o') } else { '<none>' })
"Average concurrency: {0}" -f $metric.AverageConcurrency
"Duration seconds: {0}" -f $metric.DurationSeconds
"=========================================================`n"

### END FILE: PeakConcurrentExternalTrunkVoiceCalls.ps1
