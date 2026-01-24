<#
PeakConcurrentExternalTrunkVoiceCalls is now a single-function, single-input script:
PeakConcurrentExternalTrunkVoiceCalls -Interval "startZ/endZ"
It builds headers internally from $script:AccessToken, chunks with overlap, de-dupes by leg key, and computes peak concurrency via sweep-line.

Your metric definition is enforced in compute (most defensible):

Include: voice, Edge, sessionDnis starts tel:, mediaEndpointStats exists
Exclude: callback, voicemail, wrapup/acw/aftercallwork segments

This version hardens all ".Count" usage by normalizing potentially-scalar values to arrays via @(...),
which avoids StrictMode failures when APIs return a single object instead of an array.
#>

#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ApiBaseUri           = $script:ApiBaseUri           ?? 'https://api.usw2.pure.cloud'
$script:AccessToken          = $script:AccessToken          ?? $null
$script:ChunkSize            = $script:ChunkSize            ?? 1
$script:ChunkUnit            = $script:ChunkUnit            ?? 'Hours'
$script:ChunkOverlapMinutes  = $script:ChunkOverlapMinutes  ?? 120
$script:PageSize             = $script:PageSize             ?? 100
$script:PollIntervalSeconds  = $script:PollIntervalSeconds  ?? 2
$script:JobTimeoutSeconds    = $script:JobTimeoutSeconds    ?? 900
$script:AllowedEdgeIds       = $script:AllowedEdgeIds       ?? $null

function ConvertTo-UtcDateTime {
  param([Parameter(Mandatory)][string]$Value)
  $dt = $null
  if (-not [DateTime]::TryParse($Value, [ref]$dt)) { throw "Invalid datetime: '$Value' (expected ISO8601)." }
  if ($dt.Kind -eq [DateTimeKind]::Unspecified) { $dt = [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc) }
  else { $dt = $dt.ToUniversalTime() }
  $dt
}

function Format-IsoUtc {
  param([Parameter(Mandatory)][DateTime]$Utc)
  $Utc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function New-Headers {
  if (-not $script:AccessToken) {
    throw 'AccessToken is not set. Populate $script:AccessToken before calling PeakConcurrentExternalTrunkVoiceCalls.'
  }
  @{
    Accept         = 'application/json'
    'Content-Type' = 'application/json'
    Authorization  = "Bearer $($script:AccessToken)"
  }
}

function Invoke-GcRequest {
  param(
    [Parameter(Mandatory)][hashtable]$Headers,
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
      }
      $json = $null
      if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Depth 30) }
      return Invoke-RestMethod -Method Post -Uri $Uri -Headers $Headers -Body $json -TimeoutSec 120
    } catch {
      $ex = $_.Exception
      $status = $null
      try { $status = $ex.Response.StatusCode.value__ } catch { }
      if ($status -notin 408,429,500,502,503,504) { throw }
      if ($attempt -ge $MaxRetries) { throw }
      $sleepMs = [Math]::Min(15000, ($RetryBaseMs * [Math]::Pow(2, ($attempt - 1))))
      Start-Sleep -Milliseconds $sleepMs
    }
  }
}

function New-TimeChunks {
  param(
    [Parameter(Mandatory)][DateTime]$StartUtc,
    [Parameter(Mandatory)][DateTime]$EndUtc,
    [Parameter(Mandatory)][int]$Size,
    [Parameter(Mandatory)][ValidateSet('Minutes','Hours','Days')][string]$Unit,
    [Parameter(Mandatory)][int]$OverlapMinutes
  )
  $chunks = New-Object System.Collections.Generic.List[object]
  $cursor = $StartUtc
  $idx = 0
  $overlap = New-TimeSpan -Minutes $OverlapMinutes

  while ($cursor -lt $EndUtc) {
    $idx++
    switch ($Unit) {
      'Minutes' { $chunkEnd = $cursor.AddMinutes($Size) }
      'Hours'   { $chunkEnd = $cursor.AddHours($Size) }
      'Days'    { $chunkEnd = $cursor.AddDays($Size) }
    }
    if ($chunkEnd -gt $EndUtc) { $chunkEnd = $EndUtc }

    $chunks.Add([pscustomobject]@{
      Index      = $idx
      ChunkStart = $cursor
      ChunkEnd   = $chunkEnd
      QueryStart = $cursor.Subtract($overlap)
      QueryEnd   = $chunkEnd.Add($overlap)
    }) | Out-Null

    $cursor = $chunkEnd
  }

  $chunks
}

function New-JobBodyBase {
  param([Parameter(Mandatory)][int]$PageSize)
  @{
    interval = 'placeholder'
    order    = 'asc'
    paging   = @{ pageSize = $PageSize; pageNumber = 1 }
    segmentFilters = @(
      @{
        type = 'and'
        predicates = @(
          @{ type = 'dimension'; dimension = 'mediaType'; operator = 'matches'; value = 'voice' },
          @{ type = 'dimension'; dimension = 'provider';  operator = 'matches'; value = 'Edge'  },
          @{ type = 'dimension'; dimension = 'dnis';      operator = 'matches'; value = '^tel:' }
        )
      }
    )
  }
}

function New-DetailsJob {
  param(
    [Parameter(Mandatory)][hashtable]$Headers,
    [Parameter(Mandatory)][hashtable]$JobRequestBodyBase,
    [Parameter(Mandatory)][DateTime]$QueryStartUtc,
    [Parameter(Mandatory)][DateTime]$QueryEndUtc
  )
  $uri = ($script:ApiBaseUri.TrimEnd('/') + '/api/v2/analytics/conversations/details/jobs')
  $body = @{}
  foreach ($k in $JobRequestBodyBase.Keys) { $body[$k] = $JobRequestBodyBase[$k] }
  $body.interval = ('{0}/{1}' -f (Format-IsoUtc $QueryStartUtc), (Format-IsoUtc $QueryEndUtc))
  $resp = Invoke-GcRequest -Headers $Headers -Method POST -Uri $uri -Body $body
  if (-not $resp.id) { throw 'Job creation did not return an id.' }
  $resp.id
}

function Wait-DetailsJob {
  param([Parameter(Mandatory)][hashtable]$Headers, [Parameter(Mandatory)][string]$JobId)
  $uri = ($script:ApiBaseUri.TrimEnd('/') + "/api/v2/analytics/conversations/details/jobs/$JobId")
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $resp = Invoke-GcRequest -Headers $Headers -Method GET -Uri $uri
    $state = $resp.state
    if ($state -eq 'FULFILLED') { return }
    if ($state -in 'FAILED','CANCELLED') {
      $msg = $null
      try { $msg = $resp.errorMessage } catch { }
      throw ("Job {0} ended in state {1}. {2}" -f $JobId, $state, $msg)
    }
    if ($sw.Elapsed.TotalSeconds -ge $script:JobTimeoutSeconds) {
      throw ("Job {0} timed out after {1}s." -f $JobId, $script:JobTimeoutSeconds)
    }
    Start-Sleep -Seconds $script:PollIntervalSeconds
  }
}

function Get-DetailsJobResults {
  param(
    [Parameter(Mandatory)][hashtable]$Headers,
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][int]$PageSize
  )
  $all = New-Object System.Collections.Generic.List[object]
  $page = 1
  $pageCount = $null

  while ($true) {
    $uri = ($script:ApiBaseUri.TrimEnd('/') + "/api/v2/analytics/conversations/details/jobs/$JobId/results?pageNumber=$page&pageSize=$PageSize")
    $resp = Invoke-GcRequest -Headers $Headers -Method GET -Uri $uri

    if ($null -ne $resp.pageCount -and $null -ne $resp.pageNumber) { $pageCount = [int]$resp.pageCount }

    $items = $null
    if ($resp.conversations) { $items = $resp.conversations }
    elseif ($resp.entities)  { $items = $resp.entities }
    elseif ($resp.results)   { $items = $resp.results }

    # Normalize to array to avoid StrictMode failures when API returns a single object
    $itemsArr = @($items)

    if ($itemsArr.Count -gt 0) {
      foreach ($c in $itemsArr) { $all.Add($c) | Out-Null }
    }

    if ($pageCount) {
      if ($page -ge $pageCount) { break }
    } else {
      # Stop when we got less than a full page (or none)
      if ($itemsArr.Count -lt $PageSize) { break }
    }
    $page++
  }
  $all
}

function Test-QualifyingTrunkSession {
  param([Parameter(Mandatory)][object]$Participant, [Parameter(Mandatory)][object]$Session)

  if ($Session.mediaType -ne 'voice') { return $false }
  if ($Session.provider  -ne 'Edge')  { return $false }

  $sdnis = $Session.sessionDnis
  if (-not $sdnis) { return $false }
  if (-not $sdnis.StartsWith('tel:')) { return $false }

  if ($Session.mediaType -eq 'callback') { return $false }
  if ($Participant.purpose -eq 'voicemail') { return $false }
  if ($sdnis -match 'user=voicemail') { return $false }

  if (@($Session.mediaEndpointStats).Count -lt 1) { return $false }

  # Normalize AllowedEdgeIds to array-of-strings (handles $null, scalar string, or array)
  $allowedEdgeIds = @($script:AllowedEdgeIds) | Where-Object { $_ -and $_.ToString().Trim() -ne '' }
  if ($allowedEdgeIds.Count -gt 0) {
    $edgeId = $Session.edgeId
    if (-not $edgeId) { return $false }
    if ($allowedEdgeIds -notcontains $edgeId) { return $false }
  }

  $true
}

function Get-SessionIntervalUtc {
  param([Parameter(Mandatory)][object]$Session)

  $seg = @($Session.segments)
  if ($seg.Count -lt 1) { return $null }

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

  [pscustomobject]@{ StartUtc = $minStart; EndUtc = $maxEnd }
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
  [pscustomobject]@{ StartUtc = $s; EndUtc = $e }
}

function Get-TrunkIntervalsFromConversations {
  param(
    [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Conversations,
    [Parameter(Mandatory)][DateTime]$WindowStartUtc,
    [Parameter(Mandatory)][DateTime]$WindowEndUtc
  )
  $intervals = New-Object System.Collections.Generic.List[object]

  foreach ($conv in @($Conversations)) {
    $convId = $conv.conversationId
    foreach ($p in @($conv.participants)) {
      $partid = $p.participantId
      foreach ($s in @($p.sessions)) {
        if (-not (Test-QualifyingTrunkSession -Participant $p -Session $s)) { continue }

        $si = Get-SessionIntervalUtc -Session $s
        if (-not $si) { continue }

        $clipped = Clip-Interval -StartUtc $si.StartUtc -EndUtc $si.EndUtc -WindowStartUtc $WindowStartUtc -WindowEndUtc $WindowEndUtc
        if (-not $clipped) { continue }

        $intervals.Add([pscustomobject]@{
          LegKey         = ("{0}|{1}|{2}" -f $convId, $partid, $s.sessionId)
          ConversationId = $convId
          ParticipantId  = $partid
          SessionId      = $s.sessionId
          EdgeId         = $s.edgeId
          SessionDnis    = $s.sessionDnis
          Direction      = $s.direction
          StartUtc       = $clipped.StartUtc
          EndUtc         = $clipped.EndUtc
          DurationSec    = [Math]::Round(($clipped.EndUtc - $clipped.StartUtc).TotalSeconds, 3)
        }) | Out-Null
      }
    }
  }
  $intervals
}

function DeDupe-Intervals {
  param([Parameter(Mandatory)][System.Collections.Generic.List[object]]$Intervals)
  $map = @{}
  $dupCount = 0

  foreach ($i in @($Intervals)) {
    $k = $i.LegKey
    if (-not $map.ContainsKey($k)) { $map[$k] = $i; continue }

    $dupCount++
    $existing = $map[$k]
    if ($i.StartUtc -lt $existing.StartUtc) { $existing.StartUtc = $i.StartUtc }
    if ($i.EndUtc   -gt $existing.EndUtc)   { $existing.EndUtc   = $i.EndUtc }
    $existing.DurationSec = [Math]::Round(($existing.EndUtc - $existing.StartUtc).TotalSeconds, 3)
  }

  $out = New-Object System.Collections.Generic.List[object]
  foreach ($v in $map.Values) { $out.Add($v) | Out-Null }

  [pscustomobject]@{ Intervals = $out; DuplicatesCollapsed = $dupCount }
}

function Compute-Concurrency {
  param(
    [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Intervals,
    [Parameter(Mandatory)][DateTime]$WindowStartUtc,
    [Parameter(Mandatory)][DateTime]$WindowEndUtc
  )

  $events = New-Object System.Collections.Generic.List[object]
  foreach ($i in @($Intervals)) {
    $events.Add([pscustomobject]@{ Ts = $i.StartUtc; Delta =  1; LegKey = $i.LegKey }) | Out-Null
    $events.Add([pscustomobject]@{ Ts = $i.EndUtc;   Delta = -1; LegKey = $i.LegKey }) | Out-Null
  }

  if ($events.Count -eq 0) { return [pscustomobject]@{ Peak = 0; PeakUtc = $null; Average = 0 } }

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
    if ($cur -gt $peak) { $peak = $cur; $peakTs = $ts }

    $prevTs = $ts
  }

  if ($prevTs -lt $WindowEndUtc) {
    $dtTail = ($WindowEndUtc - $prevTs).TotalSeconds
    if ($dtTail -gt 0) { $areaSeconds += ($cur * $dtTail) }
  }

  $windowSeconds = ($WindowEndUtc - $WindowStartUtc).TotalSeconds
  $avg = 0
  if ($windowSeconds -gt 0) { $avg = $areaSeconds / $windowSeconds }

  [pscustomobject]@{ Peak = $peak; PeakUtc = $peakTs; Average = [Math]::Round($avg, 6) }
}

function PeakConcurrentExternalTrunkVoiceCalls {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Interval
  )

  if (-not $script:ApiBaseUri) { throw 'ApiBaseUri is not set.' }

  # Normalize split result to array
  $parts = @($Interval -split '/' | Where-Object { $_ -and $_.Trim() })
  if ($parts.Count -ne 2) { throw 'Interval must be in the form "start/end" (ISO8601).' }

  $windowStart = ConvertTo-UtcDateTime $parts[0].Trim()
  $windowEnd   = ConvertTo-UtcDateTime $parts[1].Trim()
  if ($windowEnd -le $windowStart) { throw 'Interval end must be greater than interval start.' }

  $headers = New-Headers
  $jobBase = New-JobBodyBase -PageSize $script:PageSize

  $chunks = New-TimeChunks -StartUtc $windowStart -EndUtc $windowEnd -Size $script:ChunkSize -Unit $script:ChunkUnit -OverlapMinutes $script:ChunkOverlapMinutes
  $allIntervals = New-Object System.Collections.Generic.List[object]

  foreach ($c in @($chunks)) {
    $jobId = New-DetailsJob -Headers $headers -JobRequestBodyBase $jobBase -QueryStartUtc $c.QueryStart -QueryEndUtc $c.QueryEnd
    Wait-DetailsJob -Headers $headers -JobId $jobId
    $convs = Get-DetailsJobResults -Headers $headers -JobId $jobId -PageSize $script:PageSize

    $intervals = Get-TrunkIntervalsFromConversations -Conversations $convs -WindowStartUtc $windowStart -WindowEndUtc $windowEnd
    foreach ($i in @($intervals)) { $allIntervals.Add($i) | Out-Null }
  }

  $dedupe = DeDupe-Intervals -Intervals $allIntervals
  $finalIntervals = $dedupe.Intervals
  $cc = Compute-Concurrency -Intervals $finalIntervals -WindowStartUtc $windowStart -WindowEndUtc $windowEnd

  [pscustomobject]@{
    IntervalUtc         = ('{0}/{1}' -f (Format-IsoUtc $windowStart), (Format-IsoUtc $windowEnd))
    IntervalsFinal      = $finalIntervals.Count
    DuplicatesCollapsed = $dedupe.DuplicatesCollapsed
    PeakConcurrent      = $cc.Peak
    PeakUtc             = if ($cc.PeakUtc) { Format-IsoUtc $cc.PeakUtc } else { $null }
    AverageConcurrent   = $cc.Average
  }
}
