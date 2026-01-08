### BEGIN: Core Jobs (Core/Jobs.psm1)

# Requires: Invoke-GcRequest + Invoke-GcPagedRequest from Core/GenesysClient.psm1

function Wait-GcAsyncJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$StatusPath,
    [Parameter(Mandatory)][string]$JobId,

    [int]$TimeoutSeconds = 300,
    [int]$PollMs = 1500
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $st = Invoke-GcRequest -Method GET -Path ($StatusPath -f $JobId)

    # Be flexible: Genesys often uses status values like "FULFILLED", "RUNNING", etc.
    $status = $st.status
    if ($status -match 'FULFILLED|COMPLETED|SUCCESS') { return $st }
    if ($status -match 'FAILED|ERROR') { throw "Async job failed: $($st | ConvertTo-Json -Depth 6)" }

    Start-Sleep -Milliseconds $PollMs
  }

  throw "Async job timed out after $TimeoutSeconds seconds (jobId=$JobId)."
}

# ----------------------------
# Analytics: Conversation Details Jobs
# ----------------------------

function Start-GcAnalyticsConversationDetailsJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Body
  )
  Invoke-GcRequest -Method POST -Path '/api/v2/analytics/conversations/details/jobs' -Body $Body
}

function Get-GcAnalyticsConversationDetailsJobAvailability {
  [CmdletBinding()]
  param()
  Invoke-GcRequest -Method GET -Path '/api/v2/analytics/conversations/details/jobs/availability'
}

function Get-GcAnalyticsConversationDetailsJobStatus {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$JobId)
  Invoke-GcRequest -Method GET -Path ("/api/v2/analytics/conversations/details/jobs/{0}" -f $JobId)
}

function Stop-GcAnalyticsConversationDetailsJob {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$JobId)
  Invoke-GcRequest -Method DELETE -Path ("/api/v2/analytics/conversations/details/jobs/{0}" -f $JobId)
}

function Get-GcAnalyticsConversationDetailsJobResults {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$JobId,

    # Default to ALL: fetch all pages of results unless constrained.
    [switch]$All = $true,
    [int]$PageSize = 100,
    [int]$MaxItems = 0,
    [int]$MaxPages = 0
  )

  # Results endpoint paging varies; use the core paging primitive.
  Invoke-GcPagedRequest -Method GET `
    -Path ("/api/v2/analytics/conversations/details/jobs/{0}/results" -f $JobId) `
    -All:$All -PageSize $PageSize -MaxItems $MaxItems -MaxPages $MaxPages
}

# One-call helper: submit → wait → fetch results
function Invoke-GcAnalyticsConversationDetailsQuery {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Body,
    [int]$TimeoutSeconds = 600,
    [switch]$All = $true,
    [int]$PageSize = 100,
    [int]$MaxItems = 0,
    [int]$MaxPages = 0
  )

  $job = Start-GcAnalyticsConversationDetailsJob -Body $Body
  $jobId = $job.id
  if (-not $jobId) { throw "No job.id returned from Start-GcAnalyticsConversationDetailsJob." }

  Wait-GcAsyncJob -StatusPath '/api/v2/analytics/conversations/details/jobs/{0}' -JobId $jobId -TimeoutSeconds $TimeoutSeconds | Out-Null
  Get-GcAnalyticsConversationDetailsJobResults -JobId $jobId -All:$All -PageSize $PageSize -MaxItems $MaxItems -MaxPages $MaxPages
}

# ----------------------------
# Analytics: User Details Jobs
# ----------------------------

function Start-GcAnalyticsUserDetailsJob {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Body)
  Invoke-GcRequest -Method POST -Path '/api/v2/analytics/users/details/jobs' -Body $Body
}

function Get-GcAnalyticsUserDetailsJobAvailability {
  [CmdletBinding()]
  param()
  Invoke-GcRequest -Method GET -Path '/api/v2/analytics/users/details/jobs/availability'
}

function Get-GcAnalyticsUserDetailsJobStatus {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$JobId)
  Invoke-GcRequest -Method GET -Path ("/api/v2/analytics/users/details/jobs/{0}" -f $JobId)
}

function Stop-GcAnalyticsUserDetailsJob {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$JobId)
  Invoke-GcRequest -Method DELETE -Path ("/api/v2/analytics/users/details/jobs/{0}" -f $JobId)
}

function Get-GcAnalyticsUserDetailsJobResults {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$JobId,
    [switch]$All = $true,
    [int]$PageSize = 100,
    [int]$MaxItems = 0,
    [int]$MaxPages = 0
  )

  Invoke-GcPagedRequest -Method GET `
    -Path ("/api/v2/analytics/users/details/jobs/{0}/results" -f $JobId) `
    -All:$All -PageSize $PageSize -MaxItems $MaxItems -MaxPages $MaxPages
}

function Invoke-GcAnalyticsUserDetailsQuery {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Body,
    [int]$TimeoutSeconds = 600,
    [switch]$All = $true,
    [int]$PageSize = 100,
    [int]$MaxItems = 0,
    [int]$MaxPages = 0
  )

  $job = Start-GcAnalyticsUserDetailsJob -Body $Body
  $jobId = $job.id
  if (-not $jobId) { throw "No job.id returned from Start-GcAnalyticsUserDetailsJob." }

  Wait-GcAsyncJob -StatusPath '/api/v2/analytics/users/details/jobs/{0}' -JobId $jobId -TimeoutSeconds $TimeoutSeconds | Out-Null
  Get-GcAnalyticsUserDetailsJobResults -JobId $jobId -All:$All -PageSize $PageSize -MaxItems $MaxItems -MaxPages $MaxPages
}

# ----------------------------
# Usage Aggregates Query Jobs (Org + Client)
# ----------------------------

function Start-GcUsageAggregatesQueryJob {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Body)

  Invoke-GcRequest -Method POST -Path '/api/v2/usage/aggregates/query/jobs' -Body $Body
}

function Get-GcUsageAggregatesQueryJob {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$JobId)

  Invoke-GcRequest -Method GET -Path ("/api/v2/usage/aggregates/query/jobs/{0}" -f $JobId)
}

function Start-GcClientUsageAggregatesQueryJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)]$Body
  )

  Invoke-GcRequest -Method POST -Path ("/api/v2/usage/client/{0}/aggregates/query/jobs" -f $ClientId) -Body $Body
}

function Get-GcClientUsageAggregatesQueryJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$JobId
  )

  Invoke-GcRequest -Method GET -Path ("/api/v2/usage/client/{0}/aggregates/query/jobs/{1}" -f $ClientId, $JobId)
}

# ----------------------------
# Agent Checklist inference jobs (as shown)
# ----------------------------

function Start-GcAgentChecklistInferenceJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ConversationId,
    [Parameter(Mandatory)][string]$CommunicationId,
    [Parameter(Mandatory)][string]$AgentChecklistId,
    [Parameter(Mandatory)]$Body
  )

  $path = "/api/v2/conversations/$ConversationId/communications/$CommunicationId/agentchecklists/$AgentChecklistId/jobs"
  Invoke-GcRequest -Method POST -Path $path -Body $Body
}

function Get-GcAgentChecklistInferenceJobStatus {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ConversationId,
    [Parameter(Mandatory)][string]$CommunicationId,
    [Parameter(Mandatory)][string]$AgentChecklistId,
    [Parameter(Mandatory)][string]$JobId
  )

  $path = "/api/v2/conversations/$ConversationId/communications/$CommunicationId/agentchecklists/$AgentChecklistId/jobs/$JobId"
  Invoke-GcRequest -Method GET -Path $path
}

### END: Core Jobs
