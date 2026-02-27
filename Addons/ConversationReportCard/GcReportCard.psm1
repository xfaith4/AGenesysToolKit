### BEGIN: GcReportCard.psm1
# Generates a self-contained HTML report card for a Genesys Cloud conversation.
# Input:  hashtable from Get-GcConversationReportData (GcApiClient.psm1)
# Output: string containing complete HTML (inline CSS + JS, no external deps)

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Internal formatting helpers
# ---------------------------------------------------------------------------

function Format-Duration {
  param([double]$Seconds)
  if ($null -eq $Seconds -or $Seconds -le 0) { return '0s' }
  $ts = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
  if ($ts.TotalHours -ge 1) { return '{0}h {1}m {2}s' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds }
  if ($ts.TotalMinutes -ge 1) { return '{0}m {1}s' -f [int]$ts.TotalMinutes, $ts.Seconds }
  return '{0}s' -f $ts.Seconds
}

function Format-Ts {
  param([string]$Iso)
  if ([string]::IsNullOrWhiteSpace($Iso)) { return '—' }
  try {
    $dt = [datetime]::Parse($Iso)
    return $dt.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
  } catch { return $Iso }
}

function Format-TsShort {
  param([string]$Iso)
  if ([string]::IsNullOrWhiteSpace($Iso)) { return '—' }
  try {
    $dt = [datetime]::Parse($Iso)
    return $dt.ToUniversalTime().ToString('HH:mm:ss')
  } catch { return $Iso }
}

function Get-RelativeOffset {
  param([string]$IsoStart, [string]$IsoEvent)
  if ([string]::IsNullOrWhiteSpace($IsoStart) -or [string]::IsNullOrWhiteSpace($IsoEvent)) { return '' }
  try {
    $s = [datetime]::Parse($IsoStart)
    $e = [datetime]::Parse($IsoEvent)
    $diff = ($e - $s).TotalSeconds
    if ($diff -lt 0) { return '-' + (Format-Duration -Seconds ([Math]::Abs($diff))) }
    return '+' + (Format-Duration -Seconds $diff)
  } catch { return '' }
}

function Html-Escape {
  param([string]$Text)
  if ($null -eq $Text) { return '' }
  $Text = $Text -replace '&','&amp;'
  $Text = $Text -replace '<','&lt;'
  $Text = $Text -replace '>','&gt;'
  $Text = $Text -replace '"','&quot;'
  return $Text
}

function Json-Pretty {
  param([object]$Obj)
  if ($null -eq $Obj) { return 'null' }
  try { return ($Obj | ConvertTo-Json -Depth 15) } catch { return [string]$Obj }
}

function Get-PurposeBadgeClass {
  param([string]$Purpose)
  switch ($Purpose.ToLower()) {
    'customer'  { return 'badge-blue' }
    'ivr'       { return 'badge-purple' }
    'acd'       { return 'badge-teal' }
    'agent'     { return 'badge-green' }
    'voicemail' { return 'badge-orange' }
    'outbound'  { return 'badge-blue' }
    default     { return 'badge-gray' }
  }
}

function Get-SegmentTypeClass {
  param([string]$SegType)
  switch ($SegType.ToLower()) {
    'interact'       { return 'tl-interact' }
    'hold'           { return 'tl-hold' }
    'wrapup'         { return 'tl-acw' }
    'ivr'            { return 'tl-ivr' }
    'alert'          { return 'tl-alert' }
    'scheduled'      { return 'tl-scheduled' }
    'dialing'        { return 'tl-dialing' }
    'contacting'     { return 'tl-dialing' }
    'transmitting'   { return 'tl-ivr' }
    'parked'         { return 'tl-hold' }
    default          { return 'tl-system' }
  }
}

# ---------------------------------------------------------------------------
# Data extraction helpers
# ---------------------------------------------------------------------------

function Get-ConvStartTime {
  param([hashtable]$D)
  if ($D.Base -and $D.Base.startTime) { return $D.Base.startTime }
  if ($D.Analytics -and $D.Analytics.conversationStart) { return $D.Analytics.conversationStart }
  return $null
}

function Get-ConvEndTime {
  param([hashtable]$D)
  if ($D.Base -and $D.Base.endTime) { return $D.Base.endTime }
  if ($D.Analytics -and $D.Analytics.conversationEnd) { return $D.Analytics.conversationEnd }
  return $null
}

function Get-ConvDuration {
  param([hashtable]$D)
  $s = Get-ConvStartTime -D $D
  $e = Get-ConvEndTime -D $D
  if (-not $s -or -not $e) { return $null }
  try {
    $start = [datetime]::Parse($s)
    $end   = [datetime]::Parse($e)
    return ($end - $start).TotalSeconds
  } catch { return $null }
}

function Get-MediaType {
  param([hashtable]$D)
  if ($D.Base -and $D.Base.participants) {
    foreach ($p in $D.Base.participants) {
      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          if ($s.mediaType) { return $s.mediaType }
        }
      }
    }
  }
  if ($D.Analytics -and $D.Analytics.participants) {
    foreach ($p in $D.Analytics.participants) {
      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          if ($s.mediaType) { return $s.mediaType }
        }
      }
    }
  }
  return 'voice'
}

function Get-Direction {
  param([hashtable]$D)
  if ($D.Base -and $D.Base.participants) {
    foreach ($p in $D.Base.participants) {
      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          if ($s.direction) { return $s.direction }
        }
      }
    }
  }
  if ($D.Analytics -and $D.Analytics.participants) {
    foreach ($p in $D.Analytics.participants) {
      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          if ($s.direction) { return $s.direction }
        }
      }
    }
  }
  return '—'
}

function Get-AllParticipants {
  param([hashtable]$D)
  $participants = [System.Collections.Generic.List[hashtable]]::new()

  if ($D.Base -and $D.Base.participants) {
    foreach ($p in $D.Base.participants) {
      $entry = @{
        Purpose   = if ($p.purpose) { $p.purpose } else { '—' }
        Name      = if ($p.name)    { $p.name    } else { '' }
        UserId    = if ($p.userId)  { $p.userId  } else { '' }
        Id        = if ($p.id)      { $p.id      } else { '' }
        StartTime = if ($p.startTime) { $p.startTime } else { '' }
        EndTime   = if ($p.endTime)   { $p.endTime   } else { '' }
        Wrapup    = $null
        Sessions  = @()
        AniName   = if ($p.aniName)  { $p.aniName  } else { '' }
        Address   = if ($p.address)  { $p.address   } else { '' }
        Dnis      = if ($p.dnis)     { $p.dnis      } else { '' }
      }

      if ($p.wrapup) {
        $entry.Wrapup = @{
          Code  = if ($p.wrapup.code)  { $p.wrapup.code  } else { '' }
          Name  = if ($p.wrapup.name)  { $p.wrapup.name  } else { '' }
          Notes = if ($p.wrapup.notes) { $p.wrapup.notes } else { '' }
        }
      }

      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          $sessionEntry = @{
            Id        = if ($s.sessionId) { $s.sessionId } else { '' }
            MediaType = if ($s.mediaType) { $s.mediaType } else { '' }
            Direction = if ($s.direction) { $s.direction } else { '' }
            Segments  = @()
            Metrics   = @()
          }
          if ($s.segments) {
            foreach ($seg in $s.segments) {
              $sessionEntry.Segments += @{
                Type         = if ($seg.segmentType)    { $seg.segmentType }    else { '—' }
                Start        = if ($seg.segmentStart)   { $seg.segmentStart }   else { '' }
                End          = if ($seg.segmentEnd)     { $seg.segmentEnd }     else { '' }
                DurationMs   = if ($seg.durationMs)     { $seg.durationMs }     else { 0 }
                QueueId      = if ($seg.queueId)        { $seg.queueId }        else { '' }
                FlowId       = if ($seg.flowId)         { $seg.flowId }         else { '' }
                ErrorCode    = if ($seg.errorCode)      { $seg.errorCode }      else { '' }
                DisconnectType = if ($seg.disconnectType) { $seg.disconnectType } else { '' }
                WrapupCode   = if ($seg.wrapUpCode)     { $seg.wrapUpCode }     else { '' }
              }
            }
          }
          $entry.Sessions += $sessionEntry
        }
      }

      $null = $participants.Add($entry)
    }
  }

  return @($participants)
}

function Build-Timeline {
  param([hashtable]$D)

  $events = [System.Collections.Generic.List[hashtable]]::new()
  $startTime = Get-ConvStartTime -D $D

  # Conversation start
  if ($startTime) {
    $null = $events.Add(@{
      Time     = $startTime
      Category = 'System'
      Label    = 'Conversation Started'
      Detail   = @{ ConversationId = $D.ConversationId; CollectedAt = $D.CollectedAt }
    })
  }

  # Process analytics participants (richer data)
  $sourceParticipants = $null
  if ($D.Analytics -and $D.Analytics.participants) {
    $sourceParticipants = $D.Analytics.participants
  } elseif ($D.Base -and $D.Base.participants) {
    $sourceParticipants = $D.Base.participants
  }

  if ($sourceParticipants) {
    foreach ($p in $sourceParticipants) {
      $pPurpose = if ($p.purpose) { $p.purpose } else { '?' }
      $pName    = if ($p.participantName) { $p.participantName }
                  elseif ($p.name)        { $p.name }
                  else                    { $pPurpose }
      $pId      = if ($p.participantId) { $p.participantId }
                  elseif ($p.id)        { $p.id }
                  else                  { '' }

      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          if ($s.segments) {
            foreach ($seg in $s.segments) {
              $segType = if ($seg.segmentType) { $seg.segmentType } else { 'unknown' }
              $segStart = if ($seg.segmentStart) { $seg.segmentStart } else { '' }
              if (-not $segStart) { continue }

              $label = "$pName - $segType"
              $cat   = 'Segment'
              if ($segType -in @('ivr','transmitting')) { $cat = 'IVR' }
              elseif ($pPurpose -eq 'acd' -or $seg.queueId) { $cat = 'Queue' }
              elseif ($segType -in @('hold','parked'))   { $cat = 'Hold' }

              $null = $events.Add(@{
                Time     = $segStart
                Category = $cat
                Label    = $label
                Detail   = @{
                  Participant = $pName
                  Purpose     = $pPurpose
                  SegmentType = $segType
                  Start       = $segStart
                  End         = if ($seg.segmentEnd) { $seg.segmentEnd } else { '' }
                  DurationMs  = if ($seg.durationMs) { $seg.durationMs } else { 0 }
                  QueueId     = if ($seg.queueId)    { $seg.queueId }    else { '' }
                  FlowId      = if ($seg.flowId)     { $seg.flowId }     else { '' }
                  ErrorCode   = if ($seg.errorCode)  { $seg.errorCode }  else { '' }
                  DisconnectType = if ($seg.disconnectType) { $seg.disconnectType } else { '' }
                }
              })

              # Error events
              $errCode = if ($seg.errorCode) { $seg.errorCode } else { '' }
              $discType = if ($seg.disconnectType) { $seg.disconnectType } else { '' }
              if ($errCode -or ($discType -and $discType -notin @('client','endpoint','peer'))) {
                $null = $events.Add(@{
                  Time     = $segStart
                  Category = 'Error'
                  Label    = if ($errCode) { "Error: $errCode" } else { "Disconnect: $discType" }
                  Detail   = @{ ErrorCode = $errCode; DisconnectType = $discType; Participant = $pName }
                })
              }
            }
          }
        }
      }
    }
  }

  # Conversation end
  $endTime = Get-ConvEndTime -D $D
  if ($endTime) {
    $null = $events.Add(@{
      Time     = $endTime
      Category = 'System'
      Label    = 'Conversation Ended'
      Detail   = @{ ConversationId = $D.ConversationId }
    })
  }

  # Sort by time
  $sorted = $events | Sort-Object { try { [datetime]::Parse($_.Time) } catch { [datetime]::MinValue } }
  return @($sorted)
}

# ---------------------------------------------------------------------------
# HTML section builders
# ---------------------------------------------------------------------------

function Build-HtmlHeader {
  param([hashtable]$D)

  $convId    = $D.ConversationId
  $startTime = Get-ConvStartTime -D $D
  $endTime   = Get-ConvEndTime -D $D
  $durSecs   = Get-ConvDuration -D $D
  $mediaType = Get-MediaType -D $D
  $direction = Get-Direction -D $D
  $region    = $D.Region

  $durStr   = if ($durSecs) { Format-Duration -Seconds $durSecs } else { '—' }
  $startStr = Format-Ts -Iso $startTime
  $endStr   = Format-Ts -Iso $endTime

  $mediaBadgeClass = switch ($mediaType.ToLower()) {
    'voice'   { 'badge-green'  }
    'chat'    { 'badge-blue'   }
    'email'   { 'badge-orange' }
    'message' { 'badge-teal'   }
    'video'   { 'badge-purple' }
    default   { 'badge-gray'   }
  }
  $dirBadgeClass = if ($direction -eq 'inbound') { 'badge-blue' } else { 'badge-teal' }

  return @"
  <div class="report-header">
    <div class="header-top">
      <div class="header-logo">Genesys Cloud</div>
      <div class="header-subtitle">Conversation Report Card</div>
    </div>
    <div class="header-convid">
      <span id="convIdText">$convId</span>
      <button class="copy-btn" onclick="copyText('$convId')" title="Copy Conversation ID">&#x2398;</button>
    </div>
    <div class="header-badges">
      <span class="badge $mediaBadgeClass">$(Html-Escape $mediaType.ToUpper())</span>
      <span class="badge $dirBadgeClass">$(Html-Escape $direction.ToUpper())</span>
      <span class="badge badge-gray">$(Html-Escape $region)</span>
    </div>
    <div class="header-times">
      <div class="time-stat"><div class="ts-label">Start</div><div class="ts-val">$startStr</div></div>
      <div class="time-stat"><div class="ts-label">End</div><div class="ts-val">$endStr</div></div>
      <div class="time-stat"><div class="ts-label">Duration</div><div class="ts-val">$durStr</div></div>
    </div>
  </div>
"@
}

function Build-HtmlQuickStats {
  param([hashtable]$D)

  $participants = @()
  if ($D.Base -and $D.Base.participants) { $participants = $D.Base.participants }

  $agentParticipants = @($participants | Where-Object { $_.purpose -eq 'agent' })
  $participantCount  = $participants.Count
  $recordingCount    = if ($D.Recordings) { @($D.Recordings).Count } else { 0 }
  $evalCount         = if ($D.Evaluations) { @($D.Evaluations).Count } else { 0 }

  # Calculate talk/hold/acw from analytics
  $talkSecs = 0; $holdSecs = 0; $acwSecs = 0; $queueSecs = 0
  $transferCount = 0

  $analyticsParts = $null
  if ($D.Analytics -and $D.Analytics.participants) { $analyticsParts = $D.Analytics.participants }

  if ($analyticsParts) {
    foreach ($p in $analyticsParts) {
      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          if ($s.segments) {
            foreach ($seg in $s.segments) {
              $dur = if ($seg.durationMs) { [double]$seg.durationMs / 1000 } else { 0 }
              switch ($seg.segmentType) {
                'interact' { $talkSecs += $dur }
                'hold'     { $holdSecs += $dur }
                'wrapup'   { $acwSecs  += $dur }
                'alert'    { $queueSecs += $dur }
              }
              if ($seg.transferType -or ($seg.disconnectType -and $seg.disconnectType -eq 'transfer')) {
                $transferCount++
              }
            }
          }
        }
      }
    }
  }

  $stats = @(
    @{ Label = 'Participants';  Value = $participantCount }
    @{ Label = 'Talk Time';     Value = Format-Duration -Seconds $talkSecs }
    @{ Label = 'Hold Time';     Value = Format-Duration -Seconds $holdSecs }
    @{ Label = 'After-Call Work'; Value = Format-Duration -Seconds $acwSecs }
    @{ Label = 'Queue Wait';    Value = Format-Duration -Seconds $queueSecs }
    @{ Label = 'Agents';        Value = $agentParticipants.Count }
    @{ Label = 'Recordings';    Value = $recordingCount }
    @{ Label = 'Evaluations';   Value = $evalCount }
  )

  $statHtml = ($stats | ForEach-Object {
    "<div class='qs-item'><div class='qs-val'>$($_.Value)</div><div class='qs-label'>$($_.Label)</div></div>"
  }) -join "`n"

  return @"
  <div class="section">
    <div class="qs-grid">$statHtml</div>
  </div>
"@
}

function Build-HtmlParticipants {
  param([hashtable]$D)

  $participants = @(Get-AllParticipants -D $D)
  if ($participants.Count -eq 0) { return '<div class="section"><p class="empty-msg">No participant data available.</p></div>' }

  $rows = $participants | ForEach-Object {
    $p = $_
    $purpose = $p.Purpose
    $badgeClass = Get-PurposeBadgeClass -Purpose $purpose

    $displayName = $p.Name
    if (-not $displayName -and $p.UserId -and $D.Users.ContainsKey($p.UserId)) {
      $displayName = $D.Users[$p.UserId].name
    }
    if (-not $displayName) { $displayName = $purpose }

    $duration = ''
    if ($p.StartTime -and $p.EndTime) {
      try {
        $dur = ([datetime]::Parse($p.EndTime) - [datetime]::Parse($p.StartTime)).TotalSeconds
        $duration = Format-Duration -Seconds $dur
      } catch { }
    }

    $wrapupStr = '—'
    if ($p.Wrapup) {
      $wrapupName = $p.Wrapup.Name
      if (-not $wrapupName -and $p.Wrapup.Code -and $D.WrapupCodes.ContainsKey($p.Wrapup.Code)) {
        $wrapupName = $D.WrapupCodes[$p.Wrapup.Code].name
      }
      if ($wrapupName) { $wrapupStr = Html-Escape $wrapupName }
      if ($p.Wrapup.Notes) { $wrapupStr += "<br><small class='muted'>$(Html-Escape $p.Wrapup.Notes)</small>" }
    }

    $sessCount = $p.Sessions.Count
    $segCount  = ($p.Sessions | ForEach-Object { $_.Segments.Count } | Measure-Object -Sum).Sum

    $addressStr = ''
    if ($p.AniName)  { $addressStr += Html-Escape $p.AniName }
    if ($p.Address)  { $addressStr += if ($addressStr) { ' / ' } else { '' }; $addressStr += Html-Escape $p.Address }

    "<tr>
      <td><span class='badge $badgeClass'>$(Html-Escape $purpose)</span></td>
      <td><strong>$(Html-Escape $displayName)</strong>$(if($addressStr){"<br><small class='muted'>$addressStr</small>"})</td>
      <td class='mono small'>$(Format-TsShort -Iso $p.StartTime)</td>
      <td class='mono small'>$(Format-TsShort -Iso $p.EndTime)</td>
      <td>$duration</td>
      <td>$sessCount</td>
      <td>$segCount</td>
      <td>$wrapupStr</td>
    </tr>"
  }

  $rowsHtml = $rows -join "`n"

  return @"
  <div class="section">
    <h2 class="section-title">Participant Journey</h2>
    <div class="table-wrap">
      <table>
        <thead><tr>
          <th>Purpose</th><th>Name / Address</th><th>Start</th><th>End</th>
          <th>Duration</th><th>Sessions</th><th>Segments</th><th>Wrapup</th>
        </tr></thead>
        <tbody>$rowsHtml</tbody>
      </table>
    </div>
  </div>
"@
}

function Build-HtmlTimeline {
  param([hashtable]$D)

  $events    = @(Build-Timeline -D $D)
  $startTime = Get-ConvStartTime -D $D

  if ($events.Count -eq 0) { return '<div class="section"><p class="empty-msg">No timeline data available.</p></div>' }

  $catColors = @{
    'System'  = '#6B7280'
    'IVR'     = '#7C3AED'
    'Queue'   = '#0284C7'
    'Segment' = '#0066CC'
    'Hold'    = '#F59E0B'
    'Error'   = '#DC2626'
    default   = '#6B7280'
  }

  $itemsHtml = ($events | ForEach-Object {
    $ev     = $_
    $cat    = if ($ev.Category) { $ev.Category } else { 'System' }
    $color  = if ($catColors.ContainsKey($cat)) { $catColors[$cat] } else { $catColors['default'] }
    $offset = Get-RelativeOffset -IsoStart $startTime -IsoEvent $ev.Time
    $ts     = Format-TsShort -Iso $ev.Time
    $label  = Html-Escape $ev.Label
    $detailJson = Html-Escape (Json-Pretty -Obj $ev.Detail)
    $idx    = [System.Guid]::NewGuid().ToString('n').Substring(0,8)

    @"
    <div class="tl-item">
      <div class="tl-dot" style="background:$color"></div>
      <div class="tl-content">
        <div class="tl-header">
          <span class="tl-time mono">$ts</span>
          <span class="tl-offset muted">$offset</span>
          <span class="badge" style="background:${color}22;color:$color;border-color:${color}55">$cat</span>
          <span class="tl-label">$label</span>
          <button class="tl-toggle" onclick="toggleEl('tld-$idx')">&#x25BC;</button>
        </div>
        <div id="tld-$idx" class="tl-detail collapsed"><pre class="json-block">$detailJson</pre></div>
      </div>
    </div>
"@
  }) -join "`n"

  return @"
  <div class="section">
    <h2 class="section-title">Timeline <span class="muted small">($(($events).Count) events)</span></h2>
    <div class="timeline">$itemsHtml</div>
  </div>
"@
}

function Build-HtmlIvrFlow {
  param([hashtable]$D)

  $ivrSegments = [System.Collections.Generic.List[hashtable]]::new()

  $analyticsParts = if ($D.Analytics -and $D.Analytics.participants) { $D.Analytics.participants } else { @() }
  foreach ($p in $analyticsParts) {
    if ($p.sessions) {
      foreach ($s in $p.sessions) {
        if ($s.segments) {
          foreach ($seg in $s.segments) {
            if ($seg.segmentType -in @('ivr','transmitting') -or $p.purpose -eq 'ivr') {
              $flowId   = if ($seg.flowId)   { $seg.flowId }   else { if ($s.flowId) { $s.flowId } else { '' } }
              $flowName = '—'
              if ($flowId -and $D.Flows.ContainsKey($flowId)) {
                $flowName = $D.Flows[$flowId].name
              }
              $null = $ivrSegments.Add(@{
                FlowId   = $flowId
                FlowName = $flowName
                Type     = if ($seg.segmentType) { $seg.segmentType } else { '—' }
                Start    = if ($seg.segmentStart) { $seg.segmentStart } else { '' }
                End      = if ($seg.segmentEnd)   { $seg.segmentEnd   } else { '' }
                Dur      = if ($seg.durationMs)   { Format-Duration -Seconds ([double]$seg.durationMs / 1000) } else { '—' }
                Disconnect = if ($seg.disconnectType) { $seg.disconnectType } else { '' }
              })
            }
          }
        }
      }
    }
  }

  if ($ivrSegments.Count -eq 0) {
    return @"
  <div class="section">
    <h2 class="section-title">IVR &amp; Flow Execution</h2>
    <p class="empty-msg">No IVR/flow data found for this conversation.</p>
  </div>
"@
  }

  $rows = $ivrSegments | ForEach-Object {
    $seg = $_
    "<tr>
      <td>$(Html-Escape $seg.FlowName)</td>
      <td class='mono small'>$(Html-Escape $seg.FlowId)</td>
      <td><span class='badge badge-purple'>$(Html-Escape $seg.Type)</span></td>
      <td class='mono small'>$(Format-TsShort -Iso $seg.Start)</td>
      <td class='mono small'>$(Format-TsShort -Iso $seg.End)</td>
      <td>$($seg.Dur)</td>
      <td>$(Html-Escape $seg.Disconnect)</td>
    </tr>"
  }

  $rowsHtml = $rows -join "`n"
  return @"
  <div class="section">
    <h2 class="section-title">IVR &amp; Flow Execution</h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Flow Name</th><th>Flow ID</th><th>Type</th><th>Start</th><th>End</th><th>Duration</th><th>Exit</th></tr></thead>
        <tbody>$rowsHtml</tbody>
      </table>
    </div>
  </div>
"@
}

function Build-HtmlQueueJourney {
  param([hashtable]$D)

  $queueEntries = [System.Collections.Generic.List[hashtable]]::new()

  $analyticsParts = if ($D.Analytics -and $D.Analytics.participants) { $D.Analytics.participants } else { @() }
  foreach ($p in $analyticsParts) {
    if ($p.sessions) {
      foreach ($s in $p.sessions) {
        if ($s.segments) {
          foreach ($seg in $s.segments) {
            if ($seg.queueId) {
              $qid      = [string]$seg.queueId
              $qDetails = if ($D.Queues.ContainsKey($qid)) { $D.Queues[$qid] } else { $null }
              $qName    = if ($qDetails -and $qDetails.name) { $qDetails.name } else { '—' }

              # Audio monitoring from queue config
              $hasListen  = $false
              $hasRecord  = $false
              if ($qDetails) {
                if ($qDetails.mediaSettings) {
                  $ms = $qDetails.mediaSettings
                  # Genesys stores these as call.enableVoicemail, or monitoringSettings
                  if ($ms.call -and $ms.call.enableAudioMonitoring) { $hasListen = $true }
                }
                if ($qDetails.monitoringSettings) {
                  if ($qDetails.monitoringSettings.hasListening) { $hasListen = $true }
                  if ($qDetails.monitoringSettings.hasRecording) { $hasRecord = $true }
                }
                # Also check managedAddresses or acwSettings
              }

              $routingMethod = '—'
              if ($qDetails -and $qDetails.skillEvaluationMethod) {
                $routingMethod = $qDetails.skillEvaluationMethod
              }

              $null = $queueEntries.Add(@{
                QueueId       = $qid
                QueueName     = $qName
                Start         = if ($seg.segmentStart) { $seg.segmentStart } else { '' }
                End           = if ($seg.segmentEnd)   { $seg.segmentEnd   } else { '' }
                DurMs         = if ($seg.durationMs)   { $seg.durationMs   } else { 0 }
                HasListen     = $hasListen
                HasRecord     = $hasRecord
                RoutingMethod = $routingMethod
                SegmentType   = if ($seg.segmentType) { $seg.segmentType } else { '—' }
              })
            }
          }
        }
      }
    }
  }

  if ($queueEntries.Count -eq 0) {
    return @"
  <div class="section">
    <h2 class="section-title">Queue Journey</h2>
    <p class="empty-msg">No queue data found for this conversation.</p>
  </div>
"@
  }

  $rows = $queueEntries | ForEach-Object {
    $q = $_
    $dur = if ($q.DurMs -gt 0) { Format-Duration -Seconds ([double]$q.DurMs / 1000) } else { '—' }
    $listenBadge = if ($q.HasListen) { "<span class='badge badge-green'>&#x1F50A; Monitoring ON</span>" } else { "<span class='badge badge-gray'>Monitoring Off</span>" }
    $recordBadge = if ($q.HasRecord) { "<span class='badge badge-green'>&#x23FA; Recording ON</span>" } else { "" }
    "<tr>
      <td><strong>$(Html-Escape $q.QueueName)</strong><br><small class='mono muted'>$(Html-Escape $q.QueueId)</small></td>
      <td><span class='badge badge-gray'>$(Html-Escape $q.SegmentType)</span></td>
      <td class='mono small'>$(Format-TsShort -Iso $q.Start)</td>
      <td class='mono small'>$(Format-TsShort -Iso $q.End)</td>
      <td>$dur</td>
      <td>$(Html-Escape $q.RoutingMethod)</td>
      <td>$listenBadge $recordBadge</td>
    </tr>"
  }

  $rowsHtml = $rows -join "`n"
  return @"
  <div class="section">
    <h2 class="section-title">Queue Journey</h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Queue</th><th>Segment</th><th>Entry</th><th>Exit</th><th>Duration</th><th>Routing</th><th>Monitoring</th></tr></thead>
        <tbody>$rowsHtml</tbody>
      </table>
    </div>
  </div>
"@
}

function Build-HtmlAgentActivity {
  param([hashtable]$D)

  $agentParts = [System.Collections.Generic.List[hashtable]]::new()

  $analyticsParts = if ($D.Analytics -and $D.Analytics.participants) { $D.Analytics.participants } else { @() }
  foreach ($p in $analyticsParts) {
    if ($p.purpose -ne 'agent') { continue }

    $userId   = if ($p.userId) { $p.userId } else { '' }
    $userName = ''
    if ($userId -and $D.Users.ContainsKey($userId)) {
      $userName = $D.Users[$userId].name
    }
    if (-not $userName) { $userName = if ($p.participantName) { $p.participantName } else { "Agent ($userId)" } }

    $talkSecs = 0; $holdSecs = 0; $acwSecs = 0; $alertSecs = 0
    $wentNotResponding = $false
    $segments = [System.Collections.Generic.List[hashtable]]::new()

    if ($p.sessions) {
      foreach ($s in $p.sessions) {
        if ($s.segments) {
          foreach ($seg in $s.segments) {
            $dur = if ($seg.durationMs) { [double]$seg.durationMs / 1000 } else { 0 }
            $segType = if ($seg.segmentType) { $seg.segmentType.ToLower() } else { '' }
            switch ($segType) {
              'interact' { $talkSecs  += $dur }
              'hold'     { $holdSecs  += $dur }
              'wrapup'   { $acwSecs   += $dur }
              'alert'    { $alertSecs += $dur }
            }
            if ($seg.disconnectType -eq 'notresponding' -or $seg.errorCode -like '*notrespond*') {
              $wentNotResponding = $true
            }

            $wrapupCodeName = ''
            if ($seg.wrapUpCode) {
              $wid = [string]$seg.wrapUpCode
              if ($D.WrapupCodes.ContainsKey($wid)) { $wrapupCodeName = $D.WrapupCodes[$wid].name }
            }

            $null = $segments.Add(@{
              Type       = $segType
              Start      = if ($seg.segmentStart) { $seg.segmentStart } else { '' }
              End        = if ($seg.segmentEnd)   { $seg.segmentEnd   } else { '' }
              Dur        = Format-Duration -Seconds $dur
              WrapupCode = $wrapupCodeName
              QueueId    = if ($seg.queueId) { $seg.queueId } else { '' }
            })
          }
        }
      }
    }

    $null = $agentParts.Add(@{
      UserId            = $userId
      Name              = $userName
      TalkSecs          = $talkSecs
      HoldSecs          = $holdSecs
      AcwSecs           = $acwSecs
      AlertSecs         = $alertSecs
      WentNotResponding = $wentNotResponding
      Segments          = @($segments)
    })
  }

  if ($agentParts.Count -eq 0) {
    return @"
  <div class="section">
    <h2 class="section-title">Agent Activity</h2>
    <p class="empty-msg">No agent data found for this conversation.</p>
  </div>
"@
  }

  $agentHtml = ($agentParts | ForEach-Object {
    $a   = $_
    $idx = [System.Guid]::NewGuid().ToString('n').Substring(0,8)

    $nrBadge = if ($a.WentNotResponding) { "<span class='badge badge-red'>&#x26A0; NOT RESPONDING</span>" } else { '' }

    $segRows = ($a.Segments | ForEach-Object {
      $seg = $_
      $cls = Get-SegmentTypeClass -SegType $seg.Type
      "<tr class='seg-row $cls'>
        <td><span class='badge badge-gray'>$($seg.Type)</span></td>
        <td class='mono small'>$(Format-TsShort -Iso $seg.Start)</td>
        <td class='mono small'>$(Format-TsShort -Iso $seg.End)</td>
        <td>$($seg.Dur)</td>
        <td>$(Html-Escape $seg.WrapupCode)</td>
      </tr>"
    }) -join "`n"

    @"
    <div class="agent-card">
      <div class="agent-header" onclick="toggleEl('agent-$idx')">
        <span class="agent-name">$(Html-Escape $a.Name)</span>
        $nrBadge
        <span class="muted small mono">$(Html-Escape $a.UserId)</span>
        <div class="agent-stats-inline">
          <span>Talk: <strong>$(Format-Duration -Seconds $a.TalkSecs)</strong></span>
          <span>Hold: <strong>$(Format-Duration -Seconds $a.HoldSecs)</strong></span>
          <span>ACW: <strong>$(Format-Duration -Seconds $a.AcwSecs)</strong></span>
          <span>Alert: <strong>$(Format-Duration -Seconds $a.AlertSecs)</strong></span>
        </div>
        <button class="tl-toggle">&#x25BC;</button>
      </div>
      <div id="agent-$idx" class="agent-detail collapsed">
        <div class="table-wrap">
          <table>
            <thead><tr><th>Segment</th><th>Start</th><th>End</th><th>Duration</th><th>Wrapup Code</th></tr></thead>
            <tbody>$segRows</tbody>
          </table>
        </div>
      </div>
    </div>
"@
  }) -join "`n"

  return @"
  <div class="section">
    <h2 class="section-title">Agent Activity</h2>
    $agentHtml
  </div>
"@
}

function Build-HtmlQualityRecordings {
  param([hashtable]$D)

  # Recordings
  $recHtml = ''
  if ($D.Recordings -and @($D.Recordings).Count -gt 0) {
    $recRows = (@($D.Recordings) | ForEach-Object {
      $r = $_
      $dur   = if ($r.durationMs) { Format-Duration -Seconds ([double]$r.durationMs / 1000) } else { '—' }
      $rtype = if ($r.fileState) { $r.fileState } else { '—' }
      $mtype = if ($r.mediaType) { $r.mediaType } else { if ($r.fileType) { $r.fileType } else { '—' } }
      "<tr>
        <td><span class='badge badge-gray'>$(Html-Escape $mtype)</span></td>
        <td>$dur</td>
        <td><span class='badge badge-blue'>$(Html-Escape $rtype)</span></td>
        <td class='mono small'>$(Format-TsShort -Iso $r.startTime)</td>
        <td class='mono small'>$(Html-Escape $r.id)</td>
      </tr>"
    }) -join "`n"
    $recHtml = @"
    <h3 class="sub-title">Recordings ($((@($D.Recordings)).Count))</h3>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Type</th><th>Duration</th><th>State</th><th>Started</th><th>Recording ID</th></tr></thead>
        <tbody>$recRows</tbody>
      </table>
    </div>
"@
  } else {
    $recHtml = '<p class="empty-msg">No recordings found (or insufficient permissions).</p>'
  }

  # Evaluations
  $evalHtml = ''
  if ($D.Evaluations -and @($D.Evaluations).Count -gt 0) {
    $evalRows = (@($D.Evaluations) | ForEach-Object {
      $ev    = $_
      $score = if ($ev.totalScore -ne $null)    { "$($ev.totalScore)%" }    else { '—' }
      $eval  = if ($ev.evaluator -and $ev.evaluator.name) { $ev.evaluator.name } else { '—' }
      $form  = if ($ev.evaluationForm -and $ev.evaluationForm.name) { $ev.evaluationForm.name } else { '—' }
      $critFail = if ($ev.isCriticalScore -eq $false) { "<span class='badge badge-red'>CRITICAL FAIL</span>" } else { '' }
      $status   = if ($ev.status) { $ev.status } else { '—' }
      "<tr>
        <td>$(Html-Escape $eval)</td>
        <td>$(Html-Escape $form)</td>
        <td><strong>$score</strong> $critFail</td>
        <td><span class='badge badge-gray'>$(Html-Escape $status)</span></td>
        <td class='mono small'>$(Format-TsShort -Iso $ev.evaluationDate)</td>
      </tr>"
    }) -join "`n"
    $evalHtml = @"
    <h3 class="sub-title">Quality Evaluations ($((@($D.Evaluations)).Count))</h3>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Evaluator</th><th>Form</th><th>Score</th><th>Status</th><th>Date</th></tr></thead>
        <tbody>$evalRows</tbody>
      </table>
    </div>
"@
  } else {
    $evalHtml = '<p class="empty-msg">No quality evaluations found.</p>'
  }

  return @"
  <div class="section">
    <h2 class="section-title">Quality &amp; Recordings</h2>
    $recHtml
    $evalHtml
  </div>
"@
}

function Build-HtmlSpeechAnalytics {
  param([hashtable]$D)

  if (-not $D.SpeechAnalytics) {
    return @"
  <div class="section">
    <h2 class="section-title">Speech &amp; Text Analytics</h2>
    <p class="empty-msg">Speech analytics unavailable (feature may not be enabled or insufficient permissions).</p>
  </div>
"@
  }

  $sa = $D.SpeechAnalytics

  # Sentiment
  $sentHtml = ''
  if ($sa.sentimentScore -ne $null) {
    $score     = [Math]::Round([double]$sa.sentimentScore * 100, 1)
    $positive  = if ($sa.sentimentPositivePct)  { [Math]::Round([double]$sa.sentimentPositivePct, 1)  } else { '—' }
    $neutral   = if ($sa.sentimentNeutralPct)   { [Math]::Round([double]$sa.sentimentNeutralPct, 1)   } else { '—' }
    $negative  = if ($sa.sentimentNegativePct)  { [Math]::Round([double]$sa.sentimentNegativePct, 1)  } else { '—' }
    $sentClass = if ($score -gt 20)    { 'badge-green' } elseif ($score -lt -20) { 'badge-red' } else { 'badge-orange' }
    $sentHtml = @"
    <div class="sentiment-row">
      <span class="badge $sentClass">Sentiment: $score%</span>
      <span class="muted small">&nbsp;&#x1F7E2; Positive: ${positive}%&nbsp;&nbsp;&#x26AA; Neutral: ${neutral}%&nbsp;&nbsp;&#x1F534; Negative: ${negative}%</span>
    </div>
"@
  }

  # Topics
  $topicsHtml = ''
  if ($sa.topics -and @($sa.topics).Count -gt 0) {
    $topicBadges = (@($sa.topics) | ForEach-Object { "<span class='badge badge-blue'>$(Html-Escape $_.name)</span>" }) -join ' '
    $topicsHtml = "<div class='topics-row'><strong>Topics: </strong>$topicBadges</div>"
  }

  # Detected phrases
  $phrasesHtml = ''
  if ($sa.detectedPhrases -and @($sa.detectedPhrases).Count -gt 0) {
    $phraseRows = (@($sa.detectedPhrases) | Select-Object -First 20 | ForEach-Object {
      $ph = $_
      "<tr>
        <td class='mono small'>$(Format-TsShort -Iso $ph.detectedTime)</td>
        <td>$(Html-Escape $ph.phrase)</td>
        <td>$(Html-Escape $ph.participant)</td>
        <td>$(Html-Escape $ph.confidence)</td>
      </tr>"
    }) -join "`n"
    $phrasesHtml = @"
    <h3 class="sub-title">Detected Phrases</h3>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Time</th><th>Phrase</th><th>Speaker</th><th>Confidence</th></tr></thead>
        <tbody>$phraseRows</tbody>
      </table>
    </div>
"@
  }

  return @"
  <div class="section">
    <h2 class="section-title">Speech &amp; Text Analytics</h2>
    $sentHtml
    $topicsHtml
    $phrasesHtml
  </div>
"@
}

function Build-HtmlErrors {
  param([hashtable]$D)

  $errors = [System.Collections.Generic.List[hashtable]]::new()

  # Scan analytics for error conditions
  $analyticsParts = if ($D.Analytics -and $D.Analytics.participants) { $D.Analytics.participants } else { @() }
  foreach ($p in $analyticsParts) {
    $pName = if ($p.participantName) { $p.participantName } else { $p.purpose }
    if ($p.sessions) {
      foreach ($s in $p.sessions) {
        if ($s.segments) {
          foreach ($seg in $s.segments) {
            $errCode   = if ($seg.errorCode)      { [string]$seg.errorCode }      else { '' }
            $discType  = if ($seg.disconnectType) { [string]$seg.disconnectType } else { '' }
            $segType   = if ($seg.segmentType)    { [string]$seg.segmentType }    else { '' }

            if ($errCode) {
              $null = $errors.Add(@{
                Time     = if ($seg.segmentStart) { $seg.segmentStart } else { '' }
                Severity = 'ERROR'
                Type     = 'API Error Code'
                Message  = $errCode
                Actor    = $pName
              })
            }
            if ($discType -and $discType.ToLower() -notin @('client','endpoint','peer','other','transfer','conference','forward')) {
              $null = $errors.Add(@{
                Time     = if ($seg.segmentStart) { $seg.segmentStart } else { '' }
                Severity = 'WARNING'
                Type     = 'Unusual Disconnect'
                Message  = $discType
                Actor    = $pName
              })
            }
            if ($discType -eq 'notresponding') {
              $errors[-1].Severity = 'ERROR'
              $errors[-1].Type = 'Agent Not Responding'
            }
          }
        }
      }
    }
  }

  # Add failed API fetches as warnings
  foreach ($log in $D._FetchLog) {
    if ($log.Status -notin @('OK')) {
      $null = $errors.Add(@{
        Time     = ''
        Severity = if ($log.Status -eq 'Unauthorized') { 'INFO' } else { 'WARNING' }
        Type     = "API $($log.Status)"
        Message  = "$($log.Api): $($log.Message)"
        Actor    = 'System'
      })
    }
  }

  if ($errors.Count -eq 0) {
    return @"
  <div class="section">
    <h2 class="section-title">Errors &amp; Anomalies</h2>
    <div class="alert-ok">&#x2714; No errors or anomalies detected in this conversation.</div>
  </div>
"@
  }

  $rows = ($errors | ForEach-Object {
    $e = $_
    $sevClass = switch ($e.Severity) {
      'ERROR'   { 'badge-red'    }
      'WARNING' { 'badge-orange' }
      default   { 'badge-gray'   }
    }
    "<tr>
      <td class='mono small'>$(Format-TsShort -Iso $e.Time)</td>
      <td><span class='badge $sevClass'>$(Html-Escape $e.Severity)</span></td>
      <td>$(Html-Escape $e.Type)</td>
      <td>$(Html-Escape $e.Message)</td>
      <td>$(Html-Escape $e.Actor)</td>
    </tr>"
  }) -join "`n"

  return @"
  <div class="section">
    <h2 class="section-title">Errors &amp; Anomalies <span class="badge badge-orange">$($errors.Count)</span></h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Time</th><th>Severity</th><th>Type</th><th>Detail</th><th>Actor</th></tr></thead>
        <tbody>$rows</tbody>
      </table>
    </div>
  </div>
"@
}

function Build-HtmlExternalContacts {
  param([hashtable]$D)

  if (-not $D.ExternalContacts) {
    return @"
  <div class="section">
    <h2 class="section-title">External Contacts</h2>
    <p class="empty-msg">No external contacts linked to this conversation.</p>
  </div>
"@
  }

  $contacts = @()
  if ($D.ExternalContacts -is [System.Collections.IEnumerable] -and -not ($D.ExternalContacts -is [string])) {
    $contacts = @($D.ExternalContacts)
  } elseif ($D.ExternalContacts.entities) {
    $contacts = @($D.ExternalContacts.entities)
  } else {
    $contacts = @($D.ExternalContacts)
  }

  if ($contacts.Count -eq 0) {
    return @"
  <div class="section">
    <h2 class="section-title">External Contacts</h2>
    <p class="empty-msg">No external contacts linked to this conversation.</p>
  </div>
"@
  }

  $rows = ($contacts | ForEach-Object {
    $c    = $_
    $name = if ($c.firstName -or $c.lastName) { "$($c.firstName) $($c.lastName)".Trim() } else { '—' }
    $org  = if ($c.externalOrganization -and $c.externalOrganization.name) { $c.externalOrganization.name } else { '—' }
    $phone = '—'
    if ($c.phoneNumbers -and @($c.phoneNumbers).Count -gt 0) { $phone = $c.phoneNumbers[0].e164 }
    "<tr>
      <td>$(Html-Escape $name)</td>
      <td>$(Html-Escape $org)</td>
      <td class='mono'>$(Html-Escape $phone)</td>
      <td class='mono small'>$(Html-Escape $c.id)</td>
    </tr>"
  }) -join "`n"

  return @"
  <div class="section">
    <h2 class="section-title">External Contacts</h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Name</th><th>Organization</th><th>Phone</th><th>Contact ID</th></tr></thead>
        <tbody>$rows</tbody>
      </table>
    </div>
  </div>
"@
}

function Build-HtmlAuditTrail {
  param([hashtable]$D)

  $audits = @()
  if ($D.Audits) {
    if ($D.Audits -is [System.Collections.IEnumerable] -and -not ($D.Audits -is [string])) {
      $audits = @($D.Audits)
    } elseif ($D.Audits.entities) {
      $audits = @($D.Audits.entities)
    }
  }

  if ($audits.Count -eq 0) {
    return @"
  <div class="section">
    <h2 class="section-title">Audit Trail</h2>
    <p class="empty-msg">No audit records found (may require auditing permissions or the conversation may be too old).</p>
  </div>
"@
  }

  $rows = ($audits | Select-Object -First 50 | ForEach-Object {
    $a      = $_
    $actor  = if ($a.user -and $a.user.name) { $a.user.name } else { if ($a.application) { $a.application } else { '—' } }
    $action = if ($a.action) { $a.action } else { '—' }
    $entity = if ($a.entityType) { $a.entityType } else { '—' }
    $ts     = if ($a.timestamp) { Format-TsShort -Iso $a.timestamp } else { '—' }
    "<tr>
      <td class='mono small'>$ts</td>
      <td>$(Html-Escape $actor)</td>
      <td><span class='badge badge-gray'>$(Html-Escape $action)</span></td>
      <td>$(Html-Escape $entity)</td>
    </tr>"
  }) -join "`n"

  return @"
  <div class="section">
    <h2 class="section-title">Audit Trail <span class="muted small">($($audits.Count) records)</span></h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Time</th><th>Actor</th><th>Action</th><th>Entity</th></tr></thead>
        <tbody>$rows</tbody>
      </table>
    </div>
  </div>
"@
}

function Build-HtmlFetchLog {
  param([hashtable]$D)

  $log = $D._FetchLog
  if (-not $log -or @($log).Count -eq 0) { return '' }

  $rows = (@($log) | ForEach-Object {
    $entry   = $_
    $status  = $entry.Status
    $icon    = switch ($status) {
      'OK'          { "&#x2714;" }
      'Unauthorized'{ "&#x1F512;" }
      'NotFound'    { "&#x2753;" }
      'RateLimited' { "&#x23F1;" }
      default       { "&#x2716;" }
    }
    $cls = switch ($status) {
      'OK'          { 'badge-green'  }
      'Unauthorized'{ 'badge-orange' }
      'NotFound'    { 'badge-gray'   }
      default       { 'badge-red'    }
    }
    "<tr>
      <td class='mono small'>$(Html-Escape $entry.Api)</td>
      <td><span class='badge $cls'>$icon $(Html-Escape $status)</span></td>
      <td class='mono small'>$($entry.DurationMs)ms</td>
      <td class='small muted'>$(Html-Escape $entry.Message)</td>
    </tr>"
  }) -join "`n"

  return @"
  <div class="section">
    <h2 class="section-title">Data Collection Log</h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>API Call</th><th>Status</th><th>Duration</th><th>Notes</th></tr></thead>
        <tbody>$rows</tbody>
      </table>
    </div>
  </div>
"@
}

function Build-HtmlRawData {
  param([hashtable]$D)

  $sections = @(
    @{ Title = 'Base Conversation';         Key = 'Base'             }
    @{ Title = 'Analytics Details';         Key = 'Analytics'        }
    @{ Title = 'Recordings';                Key = 'Recordings'       }
    @{ Title = 'Quality Evaluations';       Key = 'Evaluations'      }
    @{ Title = 'Speech & Text Analytics';   Key = 'SpeechAnalytics'  }
    @{ Title = 'External Contacts';         Key = 'ExternalContacts' }
    @{ Title = 'Audit Logs';                Key = 'Audits'           }
    @{ Title = 'Queue Details';             Key = 'Queues'           }
    @{ Title = 'User Details';              Key = 'Users'            }
    @{ Title = 'Flow Details';              Key = 'Flows'            }
    @{ Title = 'Wrapup Codes';              Key = 'WrapupCodes'      }
  )

  $accordions = ($sections | ForEach-Object {
    $sec = $_
    $key = $sec.Key
    $val = $D[$key]
    if ($null -eq $val) { $val = '(not available)' }
    $jsonStr   = Html-Escape (Json-Pretty -Obj $val)
    $idx       = [System.Guid]::NewGuid().ToString('n').Substring(0,8)
    @"
    <div class="raw-accordion">
      <div class="raw-header" onclick="toggleEl('raw-$idx')">
        <span>$(Html-Escape $sec.Title)</span>
        <button class="copy-btn" onclick="event.stopPropagation();copyEl('raw-json-$idx')" title="Copy JSON">&#x2398;</button>
        <span class="tl-toggle">&#x25BC;</span>
      </div>
      <div id="raw-$idx" class="raw-body collapsed">
        <pre id="raw-json-$idx" class="json-block">$jsonStr</pre>
      </div>
    </div>
"@
  }) -join "`n"

  return @"
  <div class="section">
    <h2 class="section-title">Raw Data Appendix</h2>
    <p class="muted small">Click any section to expand. All data is as-returned from the Genesys Cloud API.</p>
    $accordions
  </div>
"@
}

# ---------------------------------------------------------------------------
# Main exported function
# ---------------------------------------------------------------------------

function New-GcConversationReportCard {
  <#
  .SYNOPSIS
    Generates a complete self-contained HTML report card for a Genesys Cloud conversation.

  .PARAMETER ReportData
    Hashtable returned by Get-GcConversationReportData from GcApiClient.psm1.

  .OUTPUTS
    String containing complete HTML with all CSS/JS inline.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [hashtable]$ReportData
  )

  $D = $ReportData

  # Build all sections
  $htmlHeader        = Build-HtmlHeader        -D $D
  $htmlQuickStats    = Build-HtmlQuickStats     -D $D
  $htmlParticipants  = Build-HtmlParticipants   -D $D
  $htmlTimeline      = Build-HtmlTimeline       -D $D
  $htmlIvr           = Build-HtmlIvrFlow        -D $D
  $htmlQueue         = Build-HtmlQueueJourney   -D $D
  $htmlAgents        = Build-HtmlAgentActivity  -D $D
  $htmlQuality       = Build-HtmlQualityRecordings -D $D
  $htmlSpeech        = Build-HtmlSpeechAnalytics   -D $D
  $htmlErrors        = Build-HtmlErrors         -D $D
  $htmlExtContacts   = Build-HtmlExternalContacts  -D $D
  $htmlAudit         = Build-HtmlAuditTrail     -D $D
  $htmlFetchLog      = Build-HtmlFetchLog       -D $D
  $htmlRaw           = Build-HtmlRawData        -D $D

  $collectedAt = if ($D.CollectedAt) { Format-Ts -Iso $D.CollectedAt } else { '' }
  $convId      = Html-Escape $D.ConversationId

  return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Report Card — $convId</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; font-size: 13px; background: #F3F4F6; color: #111827; }
  a { color: #0066CC; }

  /* Header */
  .report-header { background: #111827; color: white; padding: 20px 24px 16px; }
  .header-top { display: flex; align-items: baseline; gap: 12px; margin-bottom: 8px; }
  .header-logo { font-size: 18px; font-weight: 700; color: #60A5FA; letter-spacing: -.3px; }
  .header-subtitle { font-size: 13px; color: #9CA3AF; }
  .header-convid { font-family: 'Cascadia Code', 'Consolas', monospace; font-size: 15px; color: #E5E7EB; margin-bottom: 10px; word-break: break-all; }
  .header-badges { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 12px; }
  .header-times { display: flex; gap: 24px; flex-wrap: wrap; }
  .time-stat { }
  .ts-label { font-size: 10px; color: #9CA3AF; text-transform: uppercase; letter-spacing: .05em; }
  .ts-val { font-size: 13px; color: #E5E7EB; }

  /* Sections */
  .container { max-width: 1400px; margin: 0 auto; padding: 16px; }
  .section { background: white; border: 1px solid #E5E7EB; border-radius: 8px; padding: 16px; margin-bottom: 12px; }
  .section-title { font-size: 15px; font-weight: 600; color: #111827; margin-bottom: 12px; border-bottom: 1px solid #F3F4F6; padding-bottom: 8px; }
  .sub-title { font-size: 13px; font-weight: 600; color: #374151; margin: 12px 0 8px; }

  /* Badges */
  .badge { display: inline-block; padding: 2px 7px; border-radius: 10px; font-size: 11px; font-weight: 600; border: 1px solid transparent; }
  .badge-blue   { background: #DBEAFE; color: #1D4ED8; border-color: #93C5FD; }
  .badge-green  { background: #DCFCE7; color: #15803D; border-color: #86EFAC; }
  .badge-red    { background: #FEE2E2; color: #B91C1C; border-color: #FCA5A5; }
  .badge-orange { background: #FEF3C7; color: #B45309; border-color: #FCD34D; }
  .badge-purple { background: #EDE9FE; color: #6D28D9; border-color: #C4B5FD; }
  .badge-teal   { background: #CCFBF1; color: #0F766E; border-color: #5EEAD4; }
  .badge-gray   { background: #F3F4F6; color: #4B5563; border-color: #D1D5DB; }

  /* Quick Stats */
  .qs-grid { display: flex; flex-wrap: wrap; gap: 0; }
  .qs-item { flex: 1; min-width: 120px; text-align: center; padding: 12px 8px; border-right: 1px solid #F3F4F6; }
  .qs-item:last-child { border-right: none; }
  .qs-val { font-size: 20px; font-weight: 700; color: #0066CC; }
  .qs-label { font-size: 11px; color: #6B7280; margin-top: 2px; }

  /* Tables */
  .table-wrap { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; font-size: 12px; }
  thead { background: #F9FAFB; }
  th { text-align: left; padding: 8px 10px; font-size: 11px; font-weight: 600; color: #6B7280; text-transform: uppercase; letter-spacing: .04em; border-bottom: 1px solid #E5E7EB; white-space: nowrap; }
  td { padding: 8px 10px; border-bottom: 1px solid #F3F4F6; vertical-align: top; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #FAFAFA; }
  .mono { font-family: 'Cascadia Code', 'Consolas', monospace; }
  .small { font-size: 11px; }
  .muted { color: #9CA3AF; }

  /* Timeline */
  .timeline { position: relative; padding-left: 20px; }
  .timeline::before { content:''; position: absolute; left: 6px; top: 0; bottom: 0; width: 2px; background: #E5E7EB; }
  .tl-item { position: relative; margin-bottom: 6px; }
  .tl-dot { position: absolute; left: -17px; top: 6px; width: 10px; height: 10px; border-radius: 50%; border: 2px solid white; }
  .tl-content { background: #F9FAFB; border: 1px solid #E5E7EB; border-radius: 6px; padding: 6px 10px; }
  .tl-header { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .tl-time { font-size: 11px; color: #374151; min-width: 60px; }
  .tl-offset { font-size: 10px; color: #9CA3AF; min-width: 48px; }
  .tl-label { flex: 1; font-size: 12px; }
  .tl-toggle { background: none; border: none; cursor: pointer; color: #9CA3AF; font-size: 10px; padding: 2px 4px; }
  .tl-detail { margin-top: 6px; }
  .tl-interact  { border-left: 3px solid #22C55E; }
  .tl-hold      { border-left: 3px solid #F59E0B; }
  .tl-acw       { border-left: 3px solid #8B5CF6; }
  .tl-ivr       { border-left: 3px solid #7C3AED; }
  .tl-alert     { border-left: 3px solid #0284C7; }
  .tl-scheduled { border-left: 3px solid #6B7280; }
  .tl-dialing   { border-left: 3px solid #0284C7; }
  .tl-system    { border-left: 3px solid #D1D5DB; }

  /* Agent cards */
  .agent-card { border: 1px solid #E5E7EB; border-radius: 6px; margin-bottom: 8px; overflow: hidden; }
  .agent-header { display: flex; align-items: center; gap: 10px; padding: 10px 14px; background: #F9FAFB; cursor: pointer; flex-wrap: wrap; }
  .agent-header:hover { background: #F3F4F6; }
  .agent-name { font-weight: 600; font-size: 13px; }
  .agent-stats-inline { display: flex; gap: 12px; margin-left: auto; }
  .agent-stats-inline span { font-size: 11px; color: #6B7280; }
  .agent-detail { padding: 12px; }

  /* Sentiment */
  .sentiment-row { margin-bottom: 8px; }
  .topics-row { margin-bottom: 10px; }

  /* Raw data */
  .raw-accordion { border: 1px solid #E5E7EB; border-radius: 6px; margin-bottom: 6px; overflow: hidden; }
  .raw-header { display: flex; align-items: center; gap: 8px; padding: 8px 12px; background: #F9FAFB; cursor: pointer; font-weight: 500; }
  .raw-header:hover { background: #F3F4F6; }
  .raw-header .tl-toggle { margin-left: auto; }
  .raw-body { }
  .json-block { background: #1E2936; color: #A8D8A8; font-family: 'Cascadia Code','Consolas',monospace; font-size: 11px; padding: 12px; overflow-x: auto; white-space: pre-wrap; word-break: break-word; max-height: 400px; overflow-y: auto; }

  /* Utility */
  .collapsed { display: none; }
  .alert-ok { background: #DCFCE7; border: 1px solid #86EFAC; color: #15803D; padding: 10px 14px; border-radius: 6px; }
  .empty-msg { color: #9CA3AF; font-style: italic; padding: 4px 0; }
  .copy-btn { background: none; border: 1px solid #D1D5DB; border-radius: 4px; cursor: pointer; color: #6B7280; font-size: 13px; padding: 2px 6px; }
  .copy-btn:hover { background: #F3F4F6; }

  /* Report footer */
  .report-footer { text-align: center; padding: 12px; color: #9CA3AF; font-size: 11px; }

  /* Print */
  @media print {
    body { background: white; }
    .section { border: 1px solid #ccc; break-inside: avoid; }
    .collapsed { display: block !important; }
    .tl-toggle, .copy-btn { display: none; }
    .json-block { max-height: none; }
  }
</style>
</head>
<body>

$htmlHeader

<div class="container">

$htmlQuickStats

$htmlParticipants

$htmlTimeline

$htmlIvr

$htmlQueue

$htmlAgents

$htmlQuality

$htmlSpeech

$htmlErrors

$htmlExtContacts

$htmlAudit

$htmlFetchLog

$htmlRaw

<div class="report-footer">
  Generated by Genesys Cloud Conversation Report Card &nbsp;|&nbsp; $collectedAt
</div>

</div><!-- /container -->

<script>
function toggleEl(id) {
  var el = document.getElementById(id);
  if (!el) return;
  if (el.classList.contains('collapsed')) {
    el.classList.remove('collapsed');
  } else {
    el.classList.add('collapsed');
  }
}

function copyText(text) {
  if (navigator.clipboard) {
    navigator.clipboard.writeText(text).then(function() { showCopied(); });
  } else {
    var ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    showCopied();
  }
}

function copyEl(id) {
  var el = document.getElementById(id);
  if (el) copyText(el.innerText || el.textContent);
}

function showCopied() {
  var div = document.createElement('div');
  div.textContent = 'Copied!';
  div.style.cssText = 'position:fixed;top:20px;right:20px;background:#111827;color:white;padding:8px 14px;border-radius:6px;font-size:12px;z-index:9999;';
  document.body.appendChild(div);
  setTimeout(function() { document.body.removeChild(div); }, 1500);
}
</script>
</body>
</html>
"@
}

Export-ModuleMember -Function New-GcConversationReportCard

### END: GcReportCard.psm1
