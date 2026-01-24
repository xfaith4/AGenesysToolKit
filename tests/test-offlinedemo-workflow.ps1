#!/usr/bin/env pwsh
# OfflineDemo workflow tests (headless)
# Exercises all features supported by Core/SampleData.psm1 via Invoke-GcRequest.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "OfflineDemo Workflow Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

$artifactsRoot = Join-Path -Path $repoRoot -ChildPath 'artifacts'
New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null

$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$traceLog = Join-Path -Path $artifactsRoot -ChildPath ("offlinedemo-test-{0}.log" -f $runStamp)

# Enable offline mode + tracing for this run.
$env:GC_TOOLKIT_OFFLINE_DEMO = '1'
$env:GC_TOOLKIT_TRACE = '1'
$env:GC_TOOLKIT_TRACE_BODY = '1'
$env:GC_TOOLKIT_TRACE_LOG = $traceLog

Write-Host ("Trace log: {0}" -f $traceLog) -ForegroundColor Gray
Write-Host ""

Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Jobs.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'Timeline.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'ArtifactGenerator.psm1') -Force
Import-Module (Join-Path -Path $coreRoot -ChildPath 'RoutingPeople.psm1') -Force

$instanceName = 'offline.local'
$accessToken = 'offline-demo'

function Assert-True {
  param(
    [Parameter(Mandatory)][bool]$Condition,
    [Parameter(Mandatory)][string]$Message
  )
  if (-not $Condition) { throw $Message }
}

$passed = 0
$failed = 0

function Invoke-TestCase {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Body
  )

  Write-Host "Test: $Name" -ForegroundColor Cyan
  try {
    & $Body
    Write-Host "  [PASS] $Name" -ForegroundColor Green
    $script:passed++
  } catch {
    Write-Host "  [FAIL] $Name" -ForegroundColor Red
    Write-Host ("    {0}" -f $_.Exception.Message) -ForegroundColor Gray
    $script:failed++
  }
  Write-Host ""
}

Invoke-TestCase -Name "Offline /users/me" -Body {
  $me = Invoke-GcRequest -Method GET -Path '/api/v2/users/me' -InstanceName $instanceName -AccessToken $accessToken
  Assert-True -Condition ([bool]$me) -Message "Expected non-null response."
  Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$me.id)) -Message "Expected me.id."
  Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$me.name)) -Message "Expected me.name."
}

Invoke-TestCase -Name "Offline OAuth clients list" -Body {
  $resp = Invoke-GcRequest -Method GET -Path '/api/v2/oauth/clients' -InstanceName $instanceName -AccessToken $accessToken
  Assert-True -Condition ([bool]$resp.entities) -Message "Expected entities collection."
  Assert-True -Condition ($resp.entities.Count -ge 1) -Message "Expected at least one oauth client."
}

Invoke-TestCase -Name "Offline audits query (paged)" -Body {
  $body = @{
    interval = ("{0}/{1}" -f (Get-Date).AddHours(-6).ToString('o'), (Get-Date).ToString('o'))
    pageSize = 25
    pageNumber = 1
  }
  $items = Invoke-GcPagedRequest -Method POST -Path '/api/v2/audits/query' -InstanceName $instanceName -AccessToken $accessToken -Body $body -MaxItems 250
  Assert-True -Condition ($items.Count -ge 1) -Message "Expected at least one audit entity."
}

Invoke-TestCase -Name "Offline flows list + latestconfiguration" -Body {
  $flows = Invoke-GcRequest -Method GET -Path '/api/v2/flows' -InstanceName $instanceName -AccessToken $accessToken
  Assert-True -Condition ($flows.entities.Count -ge 1) -Message "Expected at least one flow."
  $flowId = [string]$flows.entities[0].id
  Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($flowId)) -Message "Expected flow id."
  $cfg = Invoke-GcRequest -Method GET -Path "/api/v2/flows/$flowId/latestconfiguration" -InstanceName $instanceName -AccessToken $accessToken
  Assert-True -Condition ([bool]$cfg) -Message "Expected latestconfiguration response."
  Assert-True -Condition ([string]$cfg.id -eq $flowId) -Message "Expected latestconfiguration.id to match flow id."
}

Invoke-TestCase -Name "Offline data actions list + get by id" -Body {
  $actions = Invoke-GcRequest -Method GET -Path '/api/v2/integrations/actions' -InstanceName $instanceName -AccessToken $accessToken
  Assert-True -Condition ($actions.entities.Count -ge 1) -Message "Expected at least one data action."
  $actionId = [string]$actions.entities[0].id
  $a = Invoke-GcRequest -Method GET -Path "/api/v2/integrations/actions/$actionId" -InstanceName $instanceName -AccessToken $accessToken
  Assert-True -Condition ([string]$a.id -eq $actionId) -Message "Expected action id match."
}

Invoke-TestCase -Name "Offline routing queues + snapshot" -Body {
  $queues = Invoke-GcRequest -Method GET -Path '/api/v2/routing/queues' -InstanceName $instanceName -AccessToken $accessToken
  Assert-True -Condition ($queues.entities.Count -ge 1) -Message "Expected at least one queue."
  $queueId = [string]$queues.entities[0].id
  $body = @{
    filter = @{
      type = 'or'
      predicates = @(
        @{ dimension = 'queueId'; value = $queueId }
      )
    }
    metrics = @('oOnQueue','oWaiting','oInteracting')
  }
  $obs = Invoke-GcRequest -Method POST -Path '/api/v2/analytics/queues/observations/query' -InstanceName $instanceName -AccessToken $accessToken -Body $body
  Assert-True -Condition ($obs.results.Count -ge 1) -Message "Expected observations results."
}

Invoke-TestCase -Name "Offline routing skills list + get by id (module + endpoint)" -Body {
  $skills = Get-GcSkills -AccessToken $accessToken -InstanceName $instanceName
  Assert-True -Condition ($skills.Count -ge 1) -Message "Expected at least one skill."
  $skillId = [string]$skills[0].id
  Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($skillId)) -Message "Expected skill id."

  $skill = Invoke-GcRequest -Method GET -Path "/api/v2/routing/skills/$skillId" -InstanceName $instanceName -AccessToken $accessToken
  Assert-True -Condition ([string]$skill.id -eq $skillId) -Message "Expected skill id match."
}

Invoke-TestCase -Name "Offline users list (module)" -Body {
  $users = Get-GcUsers -AccessToken $accessToken -InstanceName $instanceName
  Assert-True -Condition ($users.Count -ge 1) -Message "Expected at least one user."
  Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$users[0].id)) -Message "Expected user id."
}

Invoke-TestCase -Name "Offline recordings list + media" -Body {
  $recs = Invoke-GcRequest -Method GET -Path '/api/v2/recording/recordings' -InstanceName $instanceName -AccessToken $accessToken
  Assert-True -Condition ($recs.entities.Count -ge 1) -Message "Expected at least one recording."
  $recId = [string]$recs.entities[0].id
  $media = Invoke-GcRequest -Method GET -Path "/api/v2/recording/recordings/$recId/media" -InstanceName $instanceName -AccessToken $accessToken
  Assert-True -Condition ([string]$media.id -eq $recId) -Message "Expected media id match."
  Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$media.mediaUrl)) -Message "Expected mediaUrl."
}

Invoke-TestCase -Name "Offline quality evaluations query" -Body {
  $body = @{
    pageSize = 25
    pageNumber = 1
  }
  $q = Invoke-GcRequest -Method POST -Path '/api/v2/quality/evaluations/query' -InstanceName $instanceName -AccessToken $accessToken -Body $body
  Assert-True -Condition ($q.entities.Count -ge 1) -Message "Expected at least one evaluation."
}

Invoke-TestCase -Name "Offline analytics conversation details job helper" -Body {
  $body = @{
    conversationFilters = @(
      @{
        type = 'and'
        predicates = @(
          @{ dimension = 'conversationId'; value = 'c-demo-001' }
        )
      }
    )
    order = 'asc'
    orderBy = 'conversationStart'
  }

  $job = Start-GcAnalyticsConversationDetailsJob -Body $body -AccessToken $accessToken -InstanceName $instanceName
  Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$job.id)) -Message "Expected job id."

  $st = Wait-GcAsyncJob -StatusPath '/api/v2/analytics/conversations/details/jobs/{0}' -JobId $job.id -AccessToken $accessToken -InstanceName $instanceName -TimeoutSeconds 10 -PollMs 50
  Assert-True -Condition ([bool]$st) -Message "Expected non-null status."

  $results = Get-GcAnalyticsConversationDetailsJobResults -JobId $job.id -AccessToken $accessToken -InstanceName $instanceName -All
  Assert-True -Condition ($results.Count -ge 1) -Message "Expected at least one result item."
}

Invoke-TestCase -Name "Offline timeline reconstruction (conversation + analytics)" -Body {
  $conversationId = 'c-demo-001'
  $conv = Get-GcConversationDetails -ConversationId $conversationId -Region $instanceName -AccessToken $accessToken
  $ana = Get-GcConversationAnalytics -ConversationId $conversationId -Region $instanceName -AccessToken $accessToken
  Assert-True -Condition ([bool]$conv) -Message "Expected conversation details."
  Assert-True -Condition ([bool]$ana) -Message "Expected analytics details."

  $timeline = ConvertTo-GcTimeline -ConversationData $conv -AnalyticsData $ana -SubscriptionEvents @()
  Assert-True -Condition ($timeline.Count -ge 3) -Message "Expected timeline events."
  # Ensure sorted (non-decreasing).
  for ($i = 1; $i -lt $timeline.Count; $i++) {
    Assert-True -Condition ($timeline[$i].Time -ge $timeline[$i-1].Time) -Message "Timeline not sorted at index $i."
  }
}

Invoke-TestCase -Name "Offline incident packet export" -Body {
  $conversationId = 'c-demo-001'
  $outDir = Join-Path -Path $artifactsRoot -ChildPath ("offlinedemo-packet-{0}" -f $runStamp)
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null

  $raw = Export-GcConversationPacket -ConversationId $conversationId -Region $instanceName -AccessToken $accessToken -OutputDirectory $outDir -CreateZip
  $packet = @($raw | Where-Object { $_ -isnot [string] } | Select-Object -Last 1)
  if ($packet.Count -eq 1) { $packet = $packet[0] }
  Assert-True -Condition ([bool]$packet) -Message "Expected packet object."
  Assert-True -Condition (Test-Path -LiteralPath $packet.PacketDirectory) -Message "Expected packet directory to exist."

  $required = @('conversation.json','events.ndjson','summary.md')
  foreach ($f in $required) {
    $p = Join-Path -Path $packet.PacketDirectory -ChildPath $f
    Assert-True -Condition (Test-Path -LiteralPath $p) -Message "Expected packet file: $f"
  }
}

Invoke-TestCase -Name "Offline async job error path (unknown job id)" -Body {
  $thrown = $false
  try {
    Wait-GcAsyncJob -StatusPath '/api/v2/analytics/conversations/details/jobs/{0}' -JobId 'job-does-not-exist' -AccessToken $accessToken -InstanceName $instanceName -TimeoutSeconds 1 -PollMs 50 | Out-Null
  } catch {
    $thrown = $true
  }
  Assert-True -Condition $thrown -Message "Expected Wait-GcAsyncJob to throw for a failed job."
}

Invoke-TestCase -Name "Trace log is written" -Body {
  Assert-True -Condition (Test-Path -LiteralPath $traceLog) -Message "Expected trace log file to exist."
  $len = (Get-Item -LiteralPath $traceLog).Length
  Assert-True -Condition ($len -gt 0) -Message "Expected trace log to be non-empty."
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("Passed: {0}" -f $passed) -ForegroundColor Green
$failedColor = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host ("Failed: {0}" -f $failed) -ForegroundColor $failedColor
Write-Host ""

if ($failed -gt 0) { exit 1 }
exit 0
