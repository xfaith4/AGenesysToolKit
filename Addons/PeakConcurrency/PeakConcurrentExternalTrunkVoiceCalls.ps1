#requires -Version 5.1
<#
.SYNOPSIS
  Computes peak concurrent external-trunk voice call volume (Edge trunk RTP legs) over a specified interval.

.DESCRIPTION
  This script uses Genesys Cloud Analytics Conversation Details Jobs to retrieve conversation details in
  chunked intervals (with overlap), extracts qualifying external trunk voice session intervals, de-duplicates
  across chunk overlap, clips to the analysis window, and computes peak concurrency using a sweep-line algorithm.

  Trunk session qualification (strict):
    Include:
      - session.mediaType == "voice"
      - session.provider  == "Edge"
      - session.sessionDnis starts with "tel:"
      - session.mediaEndpointStats exists and has at least 1 entry
    Exclude:
      - session.mediaType == "callback"
      - participant.purpose == "voicemail" OR session.sessionDnis contains "user=voicemail"

  Trunk occupancy interval:
    - Min(segmentStart) to Max(segmentEnd) across session segments
    - Segment types containing "wrapup", "acw", or "aftercallwork" are ignored if present
    - Interval is clipped to the analysis window

.NOTES
  - Authentication is intentionally not implemented. Provide -Headers (with Authorization) or -AccessToken.
  - Designed for PowerShell 5.1 and 7+.

.EXAMPLE
  $h = @{ Authorization = "Bearer $token" }
  $jobBase = @{
    interval = "placeholder"
    order    = "asc"
    paging   = @{ pageSize = 100; pageNumber = 1 }
  }

  .\PeakConcurrentExternalTrunkVoiceCalls.Clean.ps1 `
    -ApiBaseUri "https://api.usw2.pure.cloud" `
    -Headers $h `
    -StartUtc "2024-02-16T00:00:00Z" -EndUtc "2024-02-17T00:00:00Z" `
    -ChunkSize 1 -ChunkUnit Hours -ChunkOverlapMinutes 120 `
    -JobRequestBodyBase $jobBase `
    -ExportSummaryJson -ExportIntervalsCsv

#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string]$StartUtc,

  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string]$EndUtc,

  [Parameter(Mandatory)]
  [ValidateNotNull()]
  [hashtable]$JobRequestBodyBase,

  [Parameter()]
  [string[]]$AllowedEdgeIds,

  [Parameter()]
  [switch]$ExportIntervalsCsv,

  [Parameter()]
  [switch]$ExportEventsCsv,

  [Parameter()]
  [switch]$ExportSummaryJson,

  [Parameter()]
  [switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ApiBaseUri="https://api.usw2.pure.cloud"
 [int]$ChunkSize = 1
 [string]$ChunkUnit = 'Hours'
 [int]$ChunkOverlapMinutes = 120
 [int]$PageSize = 100
 [int]$PollIntervalSeconds = 5
 [int]$JobTimeoutSeconds = 900

function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet('INFO','WARN','ERROR','DEBUG')]
    [string]$Level = 'INFO'
  )

  if ($Level -eq 'DEBUG' -and -not $VerboseLog) { return }
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
  Write-Host "[$ts] [$Level] $Message"
}

function ConvertTo-UtcDateTime {
  param([Parameter(Mandatory)][string]$Value)

  $dt = $null
  if (-not [DateTime]::TryParse($Value, [ref]$dt)) {
    throw "Invalid datetime: '$Value' (expected ISO8601)."
  }

  if ($dt.Kind -eq [DateTimeKind]::Unspecified) {
    $dt = [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc)
  } else {
    $dt = $dt.ToUniversalTime()
  }

  return $dt
}

function Format-IsoUtc {
  param([Parameter(Mandatory)][DateTime]$Utc)
  return $Utc.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

function Ensure-Headers {
  if (-not $Headers) { $Headers = @{} }

  if (-not $Headers.ContainsKey('Accept')) { $Headers['Accept'] = 'application/json' }
  if (-not $Headers.ContainsKey('Content-Type')) { $Headers['Content-Type'] = 'application/json' }

  if ($AccessToken) {
    $Headers['Authorization'] = "Bearer $AccessToken"
  }

  if (-not $Headers.ContainsKey('Authorization')) {
    throw "Provide -Headers with an Authorization header or supply -AccessToken."
  }
}

function Invoke-GcRequest {
  param(
    [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
    [Parameter(Mandatory)][string]$Uri,
    [Parameter()][object]$Body,
    [Parameter()][int]$MaxRetries = 4,
    [Parameter()][int]$RetryBaseMs = 500
  )

  $attempt = 0
  while ($true) {
    $attempt++
    try {
      if ($Method -eq 'GET') {
        return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 120
      } else {
        $json = $null
        if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Depth 20) }
        return Invoke-RestMethod -Method Post -Uri $Uri -Headers $Headers -Body $json -TimeoutSec 120
      }
    } catch {
      $ex = $_.Exception
      $status = $null
      try { $status = $ex.Response.StatusCode.value__ } catch { }

      $retryable = $false
      if ($status -in 408,429,500,502,503,504) { $retryable = $true }

      if (-not $retryable -or $attempt -ge $MaxRetries) {
        throw
      }

      $sleepMs = [Math]::Min(15000, ($RetryBaseMs * [Math]::Pow(2, ($attempt - 1))))
      Write-Log -Level 'WARN' -Message ("HTTP {0} on {1}. Retry {2}/{3} in {4}ms." -f $status, $Uri, $attempt, $MaxRetries, $sleepMs)
      Start-Sleep -Milliseconds $sleepMs
    }
  }
}

function New-TimeChunks {
  param(
    [Parameter(Mandatory)][DateTime]$Start,
    [Parameter(Mandatory)][DateTime]$End,
    [Parameter(Mandatory)][int]$Size,
    [Parameter(Mandatory)][string]$Unit,
    [Parameter(Mandatory)][int]$OverlapMinutes
  )

  $chunks = New-Object System.Collections.Generic.List[object]
  $cursor = $Start
  $idx = 0
  $overlap = New-TimeSpan -Minutes $OverlapMinutes

  while ($cursor -lt $End) {
    $idx++
    switch ($Unit) {
      'Minutes' { $chunkEnd = $cursor.AddMinutes($Size) }
      'Hours'   { $chunkEnd = $cursor.AddHours($Size) }
      'Days'    { $chunkEnd = $cursor.AddDays($Size) }
      default   { throw "Unsupported ChunkUnit: $Unit" }
    }
    if ($chunkEnd -gt $End) { $chunkEnd = $End }

    $queryStart = $cursor.Subtract($overlap)
    $queryEnd   = $chunkEnd.Add($overlap)

    $chunks.Add([pscustomobject]@{
      Index      = $idx
      ChunkStart = $cursor
      ChunkEnd   = $chunkEnd
      QueryStart = $queryStart
      QueryEnd   = $queryEnd
    }) | Out-Null

    $cursor = $chunkEnd
  }

  return $chunks
}

function New-DetailsJob {
  param(
    [Parameter(Mandatory)][DateTime]$QueryStart,
    [Parameter(Mandatory)][DateTime]$QueryEnd
  )

  $uri = ($ApiBaseUri.TrimEnd('/') + "/api/v2/analytics/conversations/details/jobs")
  $body = @{}
  foreach ($k in $JobRequestBodyBase.Keys) { $body[$k] = $JobRequestBodyBase[$k] }

  $body.interval = ("{0}/{1}" -f (Format-IsoUtc $QueryStart), (Format-IsoUtc $QueryEnd))
  $resp = Invoke-GcRequest -Method POST -Uri $uri -Body $body
  if (-not $resp.id) { throw "Job creation did not return an id." }
  return $resp.id
}

function Wait-DetailsJob {
  param([Parameter(Mandatory)][string]$JobId)

  $uri = ($ApiBaseUri.TrimEnd('/') + "/api/v2/analytics/conversations/details/jobs/$JobId")
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  while ($true) {
    $resp = Invoke-GcRequest -Method GET -Uri $uri
    $state = $resp.state

    if ($state -eq 'FULFILLED') { return $resp }
    if ($state -in 'FAILED','CANCELLED') {
      $msg = $null
      try { $msg = $resp.errorMessage } catch { }
      throw ("Job {0} ended in state {1}. {2}" -f $JobId, $state, $msg)
    }

    if ($sw.Elapsed.TotalSeconds -ge $JobTimeoutSeconds) {
      throw ("Job {0} timed out after {1}s." -f $JobId, $JobTimeoutSeconds)
    }

    Start-Sleep -Seconds $PollIntervalSeconds
  }
}

function Get-DetailsJobResults {
  param([Parameter(Mandatory)][string]$JobId)

  $all = New-Object System.Collections.Generic.List[object]
  $page = 1
  $pageCount = $null

  while ($true) {
    $uri = ($ApiBaseUri.TrimEnd('/') + "/api/v2/analytics/conversations/details/jobs/$JobId/results?pageNumber=$page&pageSize=$PageSize")
    $resp = Invoke-GcRequest -Method GET -Uri $uri

    if ($null -ne $resp.pageCount -and $null -ne $resp.pageNumber) {
      $pageCount = [int]$resp.pageCount
    }

    $items = $null
    if ($resp.conversations) { $items = $resp.conversations }
    elseif ($resp.entities)   { $items = $resp.entities }
    elseif ($resp.results)    { $items = $resp.results }

    if ($items) {
      foreach ($c in $items) { $all.Add($c) | Out-Null }
    }

    if ($pageCount) {
      if ($page -ge $pageCount) { break }
    } else {
      if (-not $items -or $items.Count -lt $PageSize) { break }
    }

    $page++
  }

  return $all
}

function Test-QualifyingTrunkSession {
  param(
    [Parameter(Mandatory)][object]$Participant,
    [Parameter(Mandatory)][object]$Session
  )

  if ($Session.mediaType -ne 'voice') { return $false }
  if ($Session.provider  -ne 'Edge')  { return $false }

  $sdnis = $Session.sessionDnis
  if (-not $sdnis) { return $false }
  if (-not $sdnis.StartsWith('tel:')) { return $false }

  if ($Session.mediaType -eq 'callback') { return $false }
  if ($Participant.purpose -eq 'voicemail') { return $false }
  if ($sdnis -match 'user=voicemail') { return $false }

  if (-not $Session.mediaEndpointStats -or $Session.mediaEndpointStats.Count -lt 1) { return $false }

  if ($AllowedEdgeIds -and $AllowedEdgeIds.Count -gt 0) {
    $edgeId = $Session.edgeId
    if (-not $edgeId) { return $false }
    if ($AllowedEdgeIds -notcontains $edgeId) { return $false }
  }

  return $true
}

function Get-SessionIntervalUtc {
  param([Parameter(Mandatory)][object]$Session)

  $seg = $Session.segments
  if (-not $seg -or $seg.Count -lt 1) { return $null }

  $use = @()
  foreach ($s in $seg) {
    $t = [string]$s.segmentType
    if ($t -match '(?i)wrapup|acw|aftercallwork') { continue }
    if (-not $s.segmentStart -or -not $s.segmentEnd) { continue }
    $use += $s
  }

  if ($use.Count -lt 1) { return $null }

  $starts = foreach ($s in $use) { ConvertTo-UtcDateTime $s.segmentStart }
  $ends   = foreach ($s in $use) { ConvertTo-UtcDateTime $s.segmentEnd }

  $minStart = ($starts | Sort-Object | Select-Object -First 1)
  $maxEnd   = ($ends   | Sort-Object | Select-Object -Last 1)

  if ($maxEnd -le $minStart) { return $null }

  return [pscustomobject]@{
    StartUtc = $minStart
    EndUtc   = $maxEnd
  }
}

function Clip-Interval {
  param(
    [Parameter(Mandatory)][DateTime]$StartUtc,
    [Parameter(Mandatory)][DateTime]$EndUtc,
    [Parameter(Mandatory)][DateTime]$WindowStartUtc,
    [Parameter(Mandatory)][DateTime]$WindowEndUtc
  )

  $s = $StartUtc
  $e = $EndUtc
  if ($s -lt $WindowStartUtc) { $s = $WindowStartUtc }
  if ($e -gt $WindowEndUtc)   { $e = $WindowEndUtc }
  if ($e -le $s) { return $null }

  return [pscustomobject]@{
    StartUtc = $s
    EndUtc   = $e
  }
}

function Get-TrunkIntervalsFromConversations {
  param(
    [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Conversations,
    [Parameter(Mandatory)][DateTime]$WindowStartUtc,
    [Parameter(Mandatory)][DateTime]$WindowEndUtc
  )

  $intervals = New-Object System.Collections.Generic.List[object]

  foreach ($conv in $Conversations) {
    $convId = $conv.conversationId
    if (-not $conv.participants) { continue }

    foreach ($p in $conv.participants) {
      $pid = $p.participantId
      if (-not $p.sessions) { continue }

      foreach ($s in $p.sessions) {
        if (-not (Test-QualifyingTrunkSession -Participant $p -Session $s)) { continue }

        $si = Get-SessionIntervalUtc -Session $s
        if (-not $si) { continue }

        $clipped = Clip-Interval -StartUtc $si.StartUtc -EndUtc $si.EndUtc -WindowStartUtc $WindowStartUtc -WindowEndUtc $WindowEndUtc
        if (-not $clipped) { continue }

        $legKey = ("{0}|{1}|{2}" -f $convId, $pid, $s.sessionId)

        $intervals.Add([pscustomobject]@{
          LegKey         = $legKey
          ConversationId = $convId
          ParticipantId  = $pid
          SessionId      = $s.sessionId
          EdgeId         = $s.edgeId
          Ani            = $s.ani
          Dnis           = $s.dnis
          SessionDnis    = $s.sessionDnis
          Direction      = $s.direction
          StartUtc       = $clipped.StartUtc
          EndUtc         = $clipped.EndUtc
          DurationSec    = [Math]::Round(($clipped.EndUtc - $clipped.StartUtc).TotalSeconds, 3)
        }) | Out-Null
      }
    }
  }

  return $intervals
}

function DeDupe-Intervals {
  param([Parameter(Mandatory)][System.Collections.Generic.List[object]]$Intervals)

  $map = @{}
  $dupCount = 0

  foreach ($i in $Intervals) {
    $k = $i.LegKey
    if (-not $map.ContainsKey($k)) {
      $map[$k] = $i
      continue
    }

    $dupCount++
    $existing = $map[$k]
    $start = $existing.StartUtc
    $end   = $existing.EndUtc

    if ($i.StartUtc -lt $start) { $start = $i.StartUtc }
    if ($i.EndUtc   -gt $end)   { $end   = $i.EndUtc   }

    $existing.StartUtc = $start
    $existing.EndUtc   = $end
    $existing.DurationSec = [Math]::Round(($end - $start).TotalSeconds, 3)
  }

  $out = New-Object System.Collections.Generic.List[object]
  foreach ($v in $map.Values) { $out.Add($v) | Out-Null }

  return [pscustomobject]@{
    Intervals = $out
    DuplicatesCollapsed = $dupCount
  }
}

function Compute-Concurrency {
  param(
    [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Intervals,
    [Parameter(Mandatory)][DateTime]$WindowStartUtc,
    [Parameter(Mandatory)][DateTime]$WindowEndUtc
  )

  $events = New-Object System.Collections.Generic.List[object]
  foreach ($i in $Intervals) {
    $events.Add([pscustomobject]@{ Ts = $i.StartUtc; Delta =  1; LegKey = $i.LegKey }) | Out-Null
    $events.Add([pscustomobject]@{ Ts = $i.EndUtc;   Delta = -1; LegKey = $i.LegKey }) | Out-Null
  }

  if ($events.Count -eq 0) {
    return [pscustomobject]@{
      Peak = 0
      PeakUtc = $null
      Average = 0
      Events = $events
    }
  }

  $sorted = $events | Sort-Object Ts, Delta, LegKey

  $cur = 0
  $peak = 0
  $peakTs = $null

  $areaSeconds = 0.0
  $prevTs = $WindowStartUtc

  foreach ($e in $sorted) {
    $ts = $e.Ts
    if ($ts -lt $WindowStartUtc) { continue }
    if ($ts -gt $WindowEndUtc)   { break }

    $dt = ($ts - $prevTs).TotalSeconds
    if ($dt -gt 0) { $areaSeconds += ($cur * $dt) }

    $cur += $e.Delta
    if ($cur -gt $peak) {
      $peak = $cur
      $peakTs = $ts
    }

    $prevTs = $ts
  }

  if ($prevTs -lt $WindowEndUtc) {
    $dtTail = ($WindowEndUtc - $prevTs).TotalSeconds
    if ($dtTail -gt 0) { $areaSeconds += ($cur * $dtTail) }
  }

  $windowSeconds = ($WindowEndUtc - $WindowStartUtc).TotalSeconds
  $avg = 0
  if ($windowSeconds -gt 0) { $avg = $areaSeconds / $windowSeconds }

  return [pscustomobject]@{
    Peak    = $peak
    PeakUtc = $peakTs
    Average = [Math]::Round($avg, 6)
    Events  = $sorted
  }
}

function Get-ScriptDirectory {
  if ($PSCommandPath) {
    return [System.IO.Path]::GetDirectoryName($PSCommandPath)
  }
  return (Get-Location).Path
}

Ensure-Headers

$windowStart = ConvertTo-UtcDateTime $StartUtc
$windowEnd   = ConvertTo-UtcDateTime $EndUtc
if ($windowEnd -le $windowStart) { throw "EndUtc must be greater than StartUtc." }

$chunks = New-TimeChunks -Start $windowStart -End $windowEnd -Size $ChunkSize -Unit $ChunkUnit -OverlapMinutes $ChunkOverlapMinutes
Write-Log -Message ("Interval {0} -> {1} (UTC). Chunks: {2} ({3} {4}), Overlap: {5}m." -f (Format-IsoUtc $windowStart), (Format-IsoUtc $windowEnd), $chunks.Count, $ChunkSize, $ChunkUnit, $ChunkOverlapMinutes)

$allIntervals = New-Object System.Collections.Generic.List[object]
$chunkStats = New-Object System.Collections.Generic.List[object]

foreach ($c in $chunks) {
  Write-Log -Message ("Chunk {0}/{1}: {2} -> {3} (query {4} -> {5})" -f $c.Index, $chunks.Count, (Format-IsoUtc $c.ChunkStart), (Format-IsoUtc $c.ChunkEnd), (Format-IsoUtc $c.QueryStart), (Format-IsoUtc $c.QueryEnd)) -Level 'DEBUG'

  $jobId = New-DetailsJob -QueryStart $c.QueryStart -QueryEnd $c.QueryEnd
  $null = Wait-DetailsJob -JobId $jobId
  $convs = Get-DetailsJobResults -JobId $jobId

  $intervals = Get-TrunkIntervalsFromConversations -Conversations $convs -WindowStartUtc $windowStart -WindowEndUtc $windowEnd
  foreach ($i in $intervals) { $allIntervals.Add($i) | Out-Null }

  $chunkStats.Add([pscustomobject]@{
    ChunkIndex      = $c.Index
    ChunkStartUtc   = $c.ChunkStart
    ChunkEndUtc     = $c.ChunkEnd
    QueryStartUtc   = $c.QueryStart
    QueryEndUtc     = $c.QueryEnd
    JobId           = $jobId
    Conversations   = $convs.Count
    IntervalsFound  = $intervals.Count
  }) | Out-Null

  Write-Log -Message ("Chunk {0} conversations={1}, intervals={2}" -f $c.Index, $convs.Count, $intervals.Count) -Level 'DEBUG'
}

$dedupe = DeDupe-Intervals -Intervals $allIntervals
$finalIntervals = $dedupe.Intervals
$duplicatesCollapsed = $dedupe.DuplicatesCollapsed

$cc = Compute-Concurrency -Intervals $finalIntervals -WindowStartUtc $windowStart -WindowEndUtc $windowEnd

$scriptDir = Get-ScriptDirectory
$stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$baseName = "PeakConcurrentExternalTrunkVoiceCalls_$stamp"

if ($ExportIntervalsCsv) {
  $csvPath = Join-Path -Path $scriptDir -ChildPath ($baseName + "_intervals.csv")
  $finalIntervals | Sort-Object StartUtc | Export-Csv -NoTypeInformation -Path $csvPath -Encoding UTF8
  Write-Log -Message ("Wrote intervals CSV: {0}" -f $csvPath)
}

if ($ExportEventsCsv) {
  $csvPath = Join-Path -Path $scriptDir -ChildPath ($baseName + "_events.csv")
  $cc.Events | Select-Object Ts, Delta, LegKey | Export-Csv -NoTypeInformation -Path $csvPath -Encoding UTF8
  Write-Log -Message ("Wrote events CSV: {0}" -f $csvPath)
}

$summary = [pscustomobject]@{
  RunUtc = (Format-IsoUtc (Get-Date).ToUniversalTime())
  ApiBaseUri = $ApiBaseUri
  IntervalUtc = [pscustomobject]@{
    StartUtc = (Format-IsoUtc $windowStart)
    EndUtc   = (Format-IsoUtc $windowEnd)
    DurationSeconds = [Math]::Round(($windowEnd - $windowStart).TotalSeconds, 3)
  }
  Definition = [pscustomobject]@{
    Include = @(
      'session.mediaType == "voice"',
      'session.provider == "Edge"',
      'session.sessionDnis startsWith "tel:"',
      'session.mediaEndpointStats exists (>=1)'
    )
    Exclude = @(
      'session.mediaType == "callback"',
      'participant.purpose == "voicemail"',
      'session.sessionDnis contains "user=voicemail"',
      'segments with type matching wrapup|acw|aftercallwork'
    )
  }
  Chunking = [pscustomobject]@{
    ChunkSize = $ChunkSize
    ChunkUnit = $ChunkUnit
    ChunkOverlapMinutes = $ChunkOverlapMinutes
    PageSize = $PageSize
    PollIntervalSeconds = $PollIntervalSeconds
    JobTimeoutSeconds = $JobTimeoutSeconds
    AllowedEdgeIds = $AllowedEdgeIds
    Chunks = $chunkStats
  }
  Results = [pscustomobject]@{
    IntervalsTotalPreDedup = $allIntervals.Count
    DuplicatesCollapsed    = $duplicatesCollapsed
    IntervalsFinal         = $finalIntervals.Count
    PeakConcurrent         = $cc.Peak
    PeakUtc                = if ($cc.PeakUtc) { (Format-IsoUtc $cc.PeakUtc) } else { $null }
    AverageConcurrent      = $cc.Average
  }
}

if ($ExportSummaryJson) {
  $jsonPath = Join-Path -Path $scriptDir -ChildPath ($baseName + "_summary.json")
  $summary | ConvertTo-Json -Depth 30 | Out-File -FilePath $jsonPath -Encoding UTF8
  Write-Log -Message ("Wrote summary JSON: {0}" -f $jsonPath)
}

Write-Host ""
Write-Host ("Peak Concurrent External-Trunk Voice Calls: {0}" -f $summary.Results.PeakConcurrent)
Write-Host ("Peak Timestamp (UTC): {0}" -f $summary.Results.PeakUtc)
Write-Host ("Average Concurrent (UTC window): {0}" -f $summary.Results.AverageConcurrent)
Write-Host ("Intervals (final): {0} (collapsed duplicates: {1})" -f $summary.Results.IntervalsFinal, $summary.Results.DuplicatesCollapsed)
Write-Host ""

return $summary
