### BEGIN: GcApiClient.psm1
# Genesys Cloud API Data Engine for Conversation Report Card
# Self-contained: only depends on Invoke-RestMethod (built-in)
# All calls are gracefully degrading — a 403/404/timeout never blocks the rest.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function Invoke-GcApiGet {
  param(
    [string]$Region,
    [string]$AccessToken,
    [string]$Path,
    [int]$TimeoutSec = 20
  )
  $uri = "https://api.$Region$Path"
  $headers = @{
    'Authorization' = "Bearer $AccessToken"
    'Content-Type'  = 'application/json'
  }
  return Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -TimeoutSec $TimeoutSec
}

function Invoke-GcApiPost {
  param(
    [string]$Region,
    [string]$AccessToken,
    [string]$Path,
    [hashtable]$Body,
    [int]$TimeoutSec = 30
  )
  $uri = "https://api.$Region$Path"
  $headers = @{
    'Authorization' = "Bearer $AccessToken"
    'Content-Type'  = 'application/json'
  }
  $bodyJson = $Body | ConvertTo-Json -Depth 15 -Compress
  return Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $bodyJson -TimeoutSec $TimeoutSec
}

function New-FetchLogEntry {
  param([string]$Api, [string]$Status, [string]$Message, [long]$DurationMs)
  return [PSCustomObject]@{
    Api        = $Api
    Status     = $Status
    Message    = $Message
    DurationMs = $DurationMs
  }
}

function Invoke-SafeFetch {
  <#
  .SYNOPSIS
    Wraps any scriptblock in a stopwatch + try/catch, appending to fetchLog.
  .OUTPUTS
    The result of the scriptblock, or $null on failure.
  #>
  param(
    [string]$Label,
    [scriptblock]$ScriptBlock,
    [System.Collections.Generic.List[object]]$FetchLog
  )

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $result = & $ScriptBlock
    $sw.Stop()
    $null = $FetchLog.Add((New-FetchLogEntry -Api $Label -Status 'OK' -Message 'Success' -DurationMs $sw.ElapsedMilliseconds))
    return $result
  } catch {
    $sw.Stop()
    $statusCode = $null
    try {
      if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
    } catch { }

    $msg = $_.Exception.Message
    if ($statusCode) { $msg = "HTTP ${statusCode}: $msg" }

    $status = if ($statusCode -in @(403, 401)) { 'Unauthorized' }
              elseif ($statusCode -eq 404)       { 'NotFound' }
              elseif ($statusCode -eq 429)       { 'RateLimited' }
              else                               { 'Error' }

    $null = $FetchLog.Add((New-FetchLogEntry -Api $Label -Status $status -Message $msg -DurationMs $sw.ElapsedMilliseconds))
    return $null
  }
}

# ---------------------------------------------------------------------------
# ID extraction helpers
# ---------------------------------------------------------------------------

function Get-UniqueQueueIds {
  param([object]$Analytics, [object]$Base)

  $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  # From analytics participants/sessions/segments
  if ($Analytics -and $Analytics.participants) {
    foreach ($p in $Analytics.participants) {
      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          if ($s.segments) {
            foreach ($seg in $s.segments) {
              if ($seg.queueId) { $null = $ids.Add([string]$seg.queueId) }
            }
          }
        }
      }
    }
  }

  # From base participants
  if ($Base -and $Base.participants) {
    foreach ($p in $Base.participants) {
      if ($p.queueId) { $null = $ids.Add([string]$p.queueId) }
      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          if ($s.segments) {
            foreach ($seg in $s.segments) {
              if ($seg.queueId) { $null = $ids.Add([string]$seg.queueId) }
            }
          }
        }
      }
    }
  }

  return @($ids)
}

function Get-UniqueUserIds {
  param([object]$Analytics, [object]$Base)

  $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  if ($Analytics -and $Analytics.participants) {
    foreach ($p in $Analytics.participants) {
      if ($p.userId) { $null = $ids.Add([string]$p.userId) }
    }
  }

  if ($Base -and $Base.participants) {
    foreach ($p in $Base.participants) {
      if ($p.userId) { $null = $ids.Add([string]$p.userId) }
    }
  }

  return @($ids)
}

function Get-UniqueFlowIds {
  param([object]$Analytics)

  $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  if ($Analytics -and $Analytics.participants) {
    foreach ($p in $Analytics.participants) {
      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          if ($s.flowId) { $null = $ids.Add([string]$s.flowId) }
          if ($s.segments) {
            foreach ($seg in $s.segments) {
              if ($seg.flowId) { $null = $ids.Add([string]$seg.flowId) }
            }
          }
        }
      }
    }
  }

  return @($ids)
}

function Get-UniqueWrapupCodeIds {
  param([object]$Analytics, [object]$Base)

  $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  if ($Analytics -and $Analytics.participants) {
    foreach ($p in $Analytics.participants) {
      if ($p.sessions) {
        foreach ($s in $p.sessions) {
          if ($s.wrapUpCode) { $null = $ids.Add([string]$s.wrapUpCode) }
          if ($s.segments) {
            foreach ($seg in $s.segments) {
              if ($seg.wrapUpCode) { $null = $ids.Add([string]$seg.wrapUpCode) }
            }
          }
        }
      }
    }
  }

  if ($Base -and $Base.participants) {
    foreach ($p in $Base.participants) {
      if ($p.wrapup -and $p.wrapup.code) { $null = $ids.Add([string]$p.wrapup.code) }
    }
  }

  return @($ids)
}

# ---------------------------------------------------------------------------
# Exported function
# ---------------------------------------------------------------------------

function Get-GcConversationReportData {
  <#
  .SYNOPSIS
    Fetches all available Genesys Cloud data for a given Conversation ID.

  .DESCRIPTION
    Calls 10+ API endpoints and aggregates results into a single structured
    hashtable. Each call is independently wrapped in error handling — a
    permission failure or 404 on any single API never blocks the others.

  .PARAMETER ConversationId
    The Genesys Cloud conversation UUID to fetch data for.

  .PARAMETER Region
    The Genesys Cloud region (e.g., 'usw2.pure.cloud', 'mypurecloud.com').

  .PARAMETER AccessToken
    A valid OAuth Bearer access token.

  .PARAMETER ProgressCallback
    Optional scriptblock called as each fetch step completes.
    Signature: { param($Step, $Total, $Message) }

  .OUTPUTS
    Hashtable with all fetched data and a _FetchLog property.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ConversationId,
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$AccessToken,
    [scriptblock]$ProgressCallback
  )

  $fetchLog = [System.Collections.Generic.List[object]]::new()

  function Report-Progress {
    param([int]$Step, [int]$Total, [string]$Message)
    if ($ProgressCallback) {
      try { & $ProgressCallback $Step $Total $Message } catch { }
    }
  }

  $totalSteps = 11

  # ── Step 1: Base conversation ────────────────────────────────────────────
  Report-Progress 1 $totalSteps 'Fetching conversation details...'
  $base = Invoke-SafeFetch -Label 'GET /conversations/{id}' -FetchLog $fetchLog -ScriptBlock {
    Invoke-GcApiGet -Region $Region -AccessToken $AccessToken -Path "/api/v2/conversations/$ConversationId"
  }

  # ── Step 2: Analytics details query ─────────────────────────────────────
  Report-Progress 2 $totalSteps 'Querying analytics details...'
  $analytics = Invoke-SafeFetch -Label 'POST /analytics/conversations/details/query' -FetchLog $fetchLog -ScriptBlock {
    $body = @{
      conversationFilters = @(
        @{
          type       = 'and'
          predicates = @(
            @{ dimension = 'conversationId'; value = $ConversationId }
          )
        }
      )
      order   = 'asc'
      orderBy = 'conversationStart'
    }
    $resp = Invoke-GcApiPost -Region $Region -AccessToken $AccessToken -Path '/api/v2/analytics/conversations/details/query' -Body $body
    if ($resp -and $resp.conversations -and $resp.conversations.Count -gt 0) {
      return $resp.conversations[0]
    }
    return $null
  }

  # ── Step 3: Recordings ──────────────────────────────────────────────────
  Report-Progress 3 $totalSteps 'Fetching recordings...'
  $recordings = Invoke-SafeFetch -Label 'GET /conversations/{id}/recordings' -FetchLog $fetchLog -ScriptBlock {
    Invoke-GcApiGet -Region $Region -AccessToken $AccessToken -Path "/api/v2/conversations/$ConversationId/recordings"
  }

  # ── Step 4: Quality evaluations ─────────────────────────────────────────
  Report-Progress 4 $totalSteps 'Fetching quality evaluations...'
  $evaluations = Invoke-SafeFetch -Label 'GET /quality/conversations/{id}/evaluations' -FetchLog $fetchLog -ScriptBlock {
    $resp = Invoke-GcApiGet -Region $Region -AccessToken $AccessToken -Path "/api/v2/quality/conversations/$ConversationId/evaluations"
    if ($resp -and $resp.entities) { return $resp.entities }
    return $resp
  }

  # ── Step 5: Speech & Text Analytics ────────────────────────────────────
  Report-Progress 5 $totalSteps 'Fetching speech & text analytics...'
  $speechAnalytics = Invoke-SafeFetch -Label 'GET /speechandtextanalytics/conversations/{id}' -FetchLog $fetchLog -ScriptBlock {
    Invoke-GcApiGet -Region $Region -AccessToken $AccessToken -Path "/api/v2/speechandtextanalytics/conversations/$ConversationId"
  }

  # ── Step 6: External contacts ───────────────────────────────────────────
  Report-Progress 6 $totalSteps 'Fetching external contacts...'
  $externalContacts = Invoke-SafeFetch -Label 'GET /conversations/{id}/externalcontacts' -FetchLog $fetchLog -ScriptBlock {
    Invoke-GcApiGet -Region $Region -AccessToken $AccessToken -Path "/api/v2/conversations/$ConversationId/externalcontacts"
  }

  # ── Step 7: Audit logs ──────────────────────────────────────────────────
  Report-Progress 7 $totalSteps 'Fetching audit trail...'
  $audits = Invoke-SafeFetch -Label 'POST /audits/query/realtime' -FetchLog $fetchLog -ScriptBlock {
    # Use a ±1 day interval anchored around the conversation start if available
    $startDate = $null
    $endDate   = $null

    if ($base -and $base.startTime) {
      try {
        $convStart = [datetime]::Parse($base.startTime).ToUniversalTime()
        $startDate = $convStart.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $endDate   = $convStart.AddHours(4).ToString('yyyy-MM-ddTHH:mm:ssZ')
      } catch { }
    }

    if (-not $startDate) {
      $now       = [datetime]::UtcNow
      $startDate = $now.AddDays(-7).ToString('yyyy-MM-ddTHH:mm:ssZ')
      $endDate   = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    $body = @{
      interval = "$startDate/$endDate"
      filters  = @(
        @{
          property = 'EntityId'
          value    = $ConversationId
        }
      )
      pageSize = 100
    }
    $resp = Invoke-GcApiPost -Region $Region -AccessToken $AccessToken -Path '/api/v2/audits/query/realtime' -Body $body
    if ($resp -and $resp.entities) { return $resp.entities }
    return $resp
  }

  # ── Step 8: Per-queue enrichment ────────────────────────────────────────
  Report-Progress 8 $totalSteps 'Fetching queue details...'
  $queueIds = Get-UniqueQueueIds -Analytics $analytics -Base $base
  $queues   = @{}
  foreach ($qid in $queueIds) {
    if ([string]::IsNullOrWhiteSpace($qid)) { continue }
    $q = Invoke-SafeFetch -Label "GET /routing/queues/$qid" -FetchLog $fetchLog -ScriptBlock {
      Invoke-GcApiGet -Region $Region -AccessToken $AccessToken -Path "/api/v2/routing/queues/$qid"
    }
    if ($q) { $queues[$qid] = $q }
  }

  # ── Step 9: Per-user enrichment ─────────────────────────────────────────
  Report-Progress 9 $totalSteps 'Fetching agent details...'
  $userIds = Get-UniqueUserIds -Analytics $analytics -Base $base
  $users   = @{}
  foreach ($uid in $userIds) {
    if ([string]::IsNullOrWhiteSpace($uid)) { continue }
    $u = Invoke-SafeFetch -Label "GET /users/$uid" -FetchLog $fetchLog -ScriptBlock {
      Invoke-GcApiGet -Region $Region -AccessToken $AccessToken -Path "/api/v2/users/$uid"
    }
    if ($u) { $users[$uid] = $u }
  }

  # ── Step 10: Per-flow enrichment ────────────────────────────────────────
  Report-Progress 10 $totalSteps 'Fetching flow details...'
  $flowIds = Get-UniqueFlowIds -Analytics $analytics
  $flows   = @{}
  foreach ($fid in $flowIds) {
    if ([string]::IsNullOrWhiteSpace($fid)) { continue }
    $f = Invoke-SafeFetch -Label "GET /flows/$fid" -FetchLog $fetchLog -ScriptBlock {
      Invoke-GcApiGet -Region $Region -AccessToken $AccessToken -Path "/api/v2/flows/$fid"
    }
    if ($f) { $flows[$fid] = $f }
  }

  # ── Step 11: Per-wrapup-code enrichment ─────────────────────────────────
  Report-Progress 11 $totalSteps 'Fetching wrapup code names...'
  $wrapupIds  = Get-UniqueWrapupCodeIds -Analytics $analytics -Base $base
  $wrapupCodes = @{}
  foreach ($wid in $wrapupIds) {
    if ([string]::IsNullOrWhiteSpace($wid)) { continue }
    $w = Invoke-SafeFetch -Label "GET /routing/wrapupcodes/$wid" -FetchLog $fetchLog -ScriptBlock {
      Invoke-GcApiGet -Region $Region -AccessToken $AccessToken -Path "/api/v2/routing/wrapupcodes/$wid"
    }
    if ($w) { $wrapupCodes[$wid] = $w }
  }

  Report-Progress $totalSteps $totalSteps 'Done.'

  return @{
    ConversationId   = $ConversationId
    Region           = $Region
    CollectedAt      = (Get-Date).ToString('o')
    Base             = $base
    Analytics        = $analytics
    Recordings       = $recordings
    Evaluations      = $evaluations
    SpeechAnalytics  = $speechAnalytics
    ExternalContacts = $externalContacts
    Audits           = $audits
    Queues           = $queues
    Users            = $users
    Flows            = $flows
    WrapupCodes      = $wrapupCodes
    _FetchLog        = @($fetchLog)
  }
}

Export-ModuleMember -Function Get-GcConversationReportData

### END: GcApiClient.psm1
