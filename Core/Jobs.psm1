### BEGIN: Core Jobs (Core/Jobs.psm1)

# Requires: Invoke-GcRequest + Invoke-GcPagedRequest from Core/GenesysClient.psm1

Set-StrictMode -Version Latest

function Wait-GcAsyncJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$StatusPath,
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,

    [int]$TimeoutSeconds = 300,
    [int]$PollMs = 1500
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $st = Invoke-GcRequest -Method GET -Path ($StatusPath -f $JobId) -AccessToken $AccessToken -InstanceName $InstanceName

    # Be flexible: Genesys often uses status values like "FULFILLED", "RUNNING", etc.
    $status = $null
    try { $status = $st.status } catch { $status = $null }
    if (-not $status) {
      # Many Genesys async job resources use `state` instead of `status`.
      try { $status = $st.state } catch { $status = $null }
    }
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
    [Parameter(Mandatory)]$Body,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  Invoke-GcRequest -Method POST -Path '/api/v2/analytics/conversations/details/jobs' -Body $Body -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcAnalyticsConversationDetailsJobAvailability {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  Invoke-GcRequest -Method GET -Path '/api/v2/analytics/conversations/details/jobs/availability' -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcAnalyticsConversationDetailsJobStatus {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  Invoke-GcRequest -Method GET -Path ("/api/v2/analytics/conversations/details/jobs/{0}" -f $JobId) -AccessToken $AccessToken -InstanceName $InstanceName
}

function Stop-GcAnalyticsConversationDetailsJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  Invoke-GcRequest -Method DELETE -Path ("/api/v2/analytics/conversations/details/jobs/{0}" -f $JobId) -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcAnalyticsConversationDetailsJobResults {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,

    # Default to ALL: fetch all pages of results unless constrained.
    [switch]$All = $true,
    [int]$PageSize = 100,
    [int]$MaxItems = 0,
    [int]$MaxPages = 0
  )

  # Results endpoint paging varies; use the core paging primitive.
  Invoke-GcPagedRequest -Method GET `
    -Path ("/api/v2/analytics/conversations/details/jobs/{0}/results" -f $JobId) `
    -AccessToken $AccessToken -InstanceName $InstanceName `
    -All:$All -PageSize $PageSize -MaxItems $MaxItems -MaxPages $MaxPages
}

# One-call helper: submit → wait → fetch results
function Invoke-GcAnalyticsConversationDetailsQuery {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Body,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [int]$TimeoutSeconds = 600,
    [switch]$All = $true,
    [int]$PageSize = 100,
    [int]$MaxItems = 0,
    [int]$MaxPages = 0
  )

  $job = Start-GcAnalyticsConversationDetailsJob -Body $Body -AccessToken $AccessToken -InstanceName $InstanceName
  $jobId = $job.id
  if (-not $jobId) { throw "No job.id returned from Start-GcAnalyticsConversationDetailsJob." }

  Wait-GcAsyncJob -StatusPath '/api/v2/analytics/conversations/details/jobs/{0}' -JobId $jobId -AccessToken $AccessToken -InstanceName $InstanceName -TimeoutSeconds $TimeoutSeconds | Out-Null
  Get-GcAnalyticsConversationDetailsJobResults -JobId $jobId -AccessToken $AccessToken -InstanceName $InstanceName -All:$All -PageSize $PageSize -MaxItems $MaxItems -MaxPages $MaxPages
}

# ----------------------------
# Analytics: User Details Jobs
# ----------------------------

function Start-GcAnalyticsUserDetailsJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Body,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  Invoke-GcRequest -Method POST -Path '/api/v2/analytics/users/details/jobs' -Body $Body -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcAnalyticsUserDetailsJobAvailability {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  Invoke-GcRequest -Method GET -Path '/api/v2/analytics/users/details/jobs/availability' -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcAnalyticsUserDetailsJobStatus {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  Invoke-GcRequest -Method GET -Path ("/api/v2/analytics/users/details/jobs/{0}" -f $JobId) -AccessToken $AccessToken -InstanceName $InstanceName
}

function Stop-GcAnalyticsUserDetailsJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  Invoke-GcRequest -Method DELETE -Path ("/api/v2/analytics/users/details/jobs/{0}" -f $JobId) -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcAnalyticsUserDetailsJobResults {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [switch]$All = $true,
    [int]$PageSize = 100,
    [int]$MaxItems = 0,
    [int]$MaxPages = 0
  )

  Invoke-GcPagedRequest -Method GET `
    -Path ("/api/v2/analytics/users/details/jobs/{0}/results" -f $JobId) `
    -AccessToken $AccessToken -InstanceName $InstanceName `
    -All:$All -PageSize $PageSize -MaxItems $MaxItems -MaxPages $MaxPages
}

function Invoke-GcAnalyticsUserDetailsQuery {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Body,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [int]$TimeoutSeconds = 600,
    [switch]$All = $true,
    [int]$PageSize = 100,
    [int]$MaxItems = 0,
    [int]$MaxPages = 0
  )

  $job = Start-GcAnalyticsUserDetailsJob -Body $Body -AccessToken $AccessToken -InstanceName $InstanceName
  $jobId = $job.id
  if (-not $jobId) { throw "No job.id returned from Start-GcAnalyticsUserDetailsJob." }

  Wait-GcAsyncJob -StatusPath '/api/v2/analytics/users/details/jobs/{0}' -JobId $jobId -AccessToken $AccessToken -InstanceName $InstanceName -TimeoutSeconds $TimeoutSeconds | Out-Null
  Get-GcAnalyticsUserDetailsJobResults -JobId $jobId -AccessToken $AccessToken -InstanceName $InstanceName -All:$All -PageSize $PageSize -MaxItems $MaxItems -MaxPages $MaxPages
}

# ----------------------------
# Usage Aggregates Query Jobs (Org + Client)
# ----------------------------

function Start-GcUsageAggregatesQueryJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Body,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )

  Invoke-GcRequest -Method POST -Path '/api/v2/usage/aggregates/query/jobs' -Body $Body -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcUsageAggregatesQueryJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )

  Invoke-GcRequest -Method GET -Path ("/api/v2/usage/aggregates/query/jobs/{0}" -f $JobId) -AccessToken $AccessToken -InstanceName $InstanceName
}

function Start-GcClientUsageAggregatesQueryJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)]$Body,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )

  Invoke-GcRequest -Method POST -Path ("/api/v2/usage/client/{0}/aggregates/query/jobs" -f $ClientId) -Body $Body -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcClientUsageAggregatesQueryJob {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )

  Invoke-GcRequest -Method GET -Path ("/api/v2/usage/client/{0}/aggregates/query/jobs/{1}" -f $ClientId, $JobId) -AccessToken $AccessToken -InstanceName $InstanceName
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
    [Parameter(Mandatory)]$Body,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )

  $path = "/api/v2/conversations/$ConversationId/communications/$CommunicationId/agentchecklists/$AgentChecklistId/jobs"
  Invoke-GcRequest -Method POST -Path $path -Body $Body -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcAgentChecklistInferenceJobStatus {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ConversationId,
    [Parameter(Mandatory)][string]$CommunicationId,
    [Parameter(Mandatory)][string]$AgentChecklistId,
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )

  $path = "/api/v2/conversations/$ConversationId/communications/$CommunicationId/agentchecklists/$AgentChecklistId/jobs/$JobId"
  Invoke-GcRequest -Method GET -Path $path -AccessToken $AccessToken -InstanceName $InstanceName
}

Export-ModuleMember -Function Wait-GcAsyncJob, `
  Start-GcAnalyticsConversationDetailsJob, `
  Get-GcAnalyticsConversationDetailsJobAvailability, `
  Get-GcAnalyticsConversationDetailsJobStatus, `
  Stop-GcAnalyticsConversationDetailsJob, `
  Get-GcAnalyticsConversationDetailsJobResults, `
  Invoke-GcAnalyticsConversationDetailsQuery, `
  Start-GcAnalyticsUserDetailsJob, `
  Get-GcAnalyticsUserDetailsJobAvailability, `
  Get-GcAnalyticsUserDetailsJobStatus, `
  Stop-GcAnalyticsUserDetailsJob, `
  Get-GcAnalyticsUserDetailsJobResults, `
  Invoke-GcAnalyticsUserDetailsQuery, `
  Start-GcUsageAggregatesQueryJob, `
  Get-GcUsageAggregatesQueryJob, `
  Start-GcClientUsageAggregatesQueryJob, `
  Get-GcClientUsageAggregatesQueryJob, `
  Start-GcAgentChecklistInferenceJob, `
  Get-GcAgentChecklistInferenceJobStatus

### END: Core Jobs
