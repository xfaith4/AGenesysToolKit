### BEGIN: tests/test-offline-sampledata.ps1
# Verifies Offline Demo mode routes GC API calls to local sample responses.
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path -Path $repoRoot -ChildPath 'Core'

Import-Module (Join-Path -Path $coreRoot -ChildPath 'HttpRequests.psm1') -Force

[Environment]::SetEnvironmentVariable('GC_TOOLKIT_OFFLINE_DEMO', '1', 'Process')

try {
  Write-Host "Offline demo enabled via GC_TOOLKIT_OFFLINE_DEMO=1" -ForegroundColor Gray

  $user = Invoke-GcRequest -Method GET -Path '/api/v2/users/me' -InstanceName 'offline.local' -AccessToken 'offline-demo'
  if (-not $user -or -not $user.name) { throw "Expected sample /users/me response with name." }
  if (-not $user.organization -or -not $user.organization.name) { throw "Expected sample /users/me response with organization.name." }

  $queryBody = @{
    interval = "{0}/{1}" -f (Get-Date).AddDays(-7).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'), (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    order = 'desc'
    orderBy = 'conversationStart'
    paging = @{ pageSize = 100; pageNumber = 1 }
  }

  $convs = Invoke-GcPagedRequest -Method POST -Path '/api/v2/analytics/conversations/details/query' -Body $queryBody -InstanceName 'offline.local' -AccessToken 'offline-demo' -MaxItems 50
  if (-not $convs -or @($convs).Count -lt 1) { throw "Expected sample conversations from analytics query." }
  if (@($convs).Count -lt 5) { throw "Expected >= 5 sample conversations for demo realism." }

  $convDetail = Invoke-GcRequest -Method GET -Path '/api/v2/conversations/c-demo-001' -InstanceName 'offline.local' -AccessToken 'offline-demo'
  if (-not $convDetail -or -not $convDetail.participants) { throw "Expected sample conversation detail with participants." }

  $requestedConversationId = 'c-offline-generated-123'
  $jobBody = @{
    conversationFilters = @(
      @{
        type = 'and'
        predicates = @(
          @{ dimension = 'conversationId'; value = $requestedConversationId }
        )
      }
    )
    order = 'asc'
    orderBy = 'conversationStart'
  }

  $job = Invoke-GcRequest -Method POST -Path '/api/v2/analytics/conversations/details/jobs' -Body $jobBody -InstanceName 'offline.local' -AccessToken 'offline-demo'
  if (-not $job -or -not $job.id) { throw "Expected sample analytics job id." }

  $status = Invoke-GcRequest -Method GET -Path ("/api/v2/analytics/conversations/details/jobs/{0}" -f $job.id) -InstanceName 'offline.local' -AccessToken 'offline-demo'
  if (-not $status -or -not $status.state) { throw "Expected sample analytics job status." }
  if ($status.state -notmatch 'FULFILLED|COMPLETED|SUCCESS') { throw "Expected job to be fulfilled, got '$($status.state)'." }

  $results = Invoke-GcRequest -Method GET -Path ("/api/v2/analytics/conversations/details/jobs/{0}/results" -f $job.id) -InstanceName 'offline.local' -AccessToken 'offline-demo'
  if (-not $results -or -not $results.conversations -or $results.conversations.Count -lt 1) { throw "Expected analytics job results with conversations." }
  if ($results.conversations[0].conversationId -ne $requestedConversationId) {
    throw "Expected results conversationId '$requestedConversationId', got '$($results.conversations[0].conversationId)'."
  }

  $actions = Invoke-GcPagedRequest -Method GET -Path '/api/v2/integrations/actions' -InstanceName 'offline.local' -AccessToken 'offline-demo' -MaxItems 50
  if (-not $actions -or @($actions).Count -lt 3) { throw "Expected >= 3 sample data actions." }
  if (-not $actions[0].modifiedBy -or -not $actions[0].modifiedBy.name) { throw "Expected sample data actions to include modifiedBy.name." }
  if (-not $actions[0].dateModified -and -not $actions[0].modifiedDate) { throw "Expected sample data actions to include dateModified/modifiedDate." }

  Write-Host "PASS: Offline sample routing works." -ForegroundColor Green
}
finally {
  [Environment]::SetEnvironmentVariable('GC_TOOLKIT_OFFLINE_DEMO', $null, 'Process')
}

### END: tests/test-offline-sampledata.ps1
