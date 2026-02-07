# RoutingPeople.psm1
# Core module for Routing & People operations (Queues, Skills, Users & Presence)

Set-StrictMode -Version Latest

function Get-GcQueues {
  <#
  .SYNOPSIS
    Retrieves queues from Genesys Cloud.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  
  .PARAMETER MaxItems
    Maximum number of items to retrieve (default: 500).
  #>
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [int]$MaxItems = 500
  )

  try {
    $results = Invoke-GcPagedRequest -Path '/api/v2/routing/queues' -Method GET `
      -InstanceName $InstanceName -AccessToken $AccessToken -MaxItems $MaxItems
    
    return $results
  } catch {
    Write-Error "Failed to retrieve queues: $_"
    return @()
  }
}

function Get-GcSkills {
  <#
  .SYNOPSIS
    Retrieves routing skills from Genesys Cloud.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  
  .PARAMETER MaxItems
    Maximum number of items to retrieve (default: 500).
  #>
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [int]$MaxItems = 500
  )

  try {
    $results = Invoke-GcPagedRequest -Path '/api/v2/routing/skills' -Method GET `
      -InstanceName $InstanceName -AccessToken $AccessToken -MaxItems $MaxItems
    
    return $results
  } catch {
    Write-Error "Failed to retrieve skills: $_"
    return @()
  }
}

function Get-GcUsers {
  <#
  .SYNOPSIS
    Retrieves users from Genesys Cloud.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  
  .PARAMETER MaxItems
    Maximum number of items to retrieve (default: 500).
  #>
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [int]$MaxItems = 500
  )

  try {
    $results = Invoke-GcPagedRequest -Path '/api/v2/users' -Method GET `
      -InstanceName $InstanceName -AccessToken $AccessToken -MaxItems $MaxItems
    
    return $results
  } catch {
    Write-Error "Failed to retrieve users: $_"
    return @()
  }
}

function Get-GcUserPresence {
  <#
  .SYNOPSIS
    Retrieves presence definitions from Genesys Cloud.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  #>
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )

  try {
    $results = Invoke-GcRequest -Path '/api/v2/presencedefinitions' -Method GET `
      -InstanceName $InstanceName -AccessToken $AccessToken
    
    return $results.entities
  } catch {
    Write-Error "Failed to retrieve presence definitions: $_"
    return @()
  }
}

function Get-GcQueueObservations {
  <#
  .SYNOPSIS
    Query real-time queue observations for metrics.
  
  .PARAMETER QueueIds
    Array of queue IDs to query.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  #>
  param(
    [Parameter(Mandatory)][string[]]$QueueIds,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
  try {
    $body = @{
      filter = @{
        type = "and"
        predicates = @(
          @{
            dimension = "queueId"
            value = $QueueIds
          }
        )
      }
      metrics = @("oInteracting", "oWaiting", "oOnQueue")
    }
    
    $results = Invoke-GcRequest -Method POST -Path '/api/v2/analytics/queues/observations/query' `
      -Body $body -AccessToken $AccessToken -InstanceName $InstanceName
    
    return $results
  } catch {
    Write-Error "Failed to query queue observations: $_"
    return @{ results = @() }
  }
}

function Get-GcRoutingSnapshot {
  <#
  .SYNOPSIS
    Aggregate snapshot across all queues with health indicators.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  #>
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
  try {
    # Get all queues
    $queues = Invoke-GcPagedRequest -Path '/api/v2/routing/queues' -Method GET `
      -AccessToken $AccessToken -InstanceName $InstanceName -MaxItems 500
    
    if (-not $queues -or $queues.Count -eq 0) {
      return @{
        timestamp = (Get-Date).ToString('o')
        queues = @()
      }
    }
    
    $queueIds = $queues | ForEach-Object { $_.id }
    
    # Get observations for all queues
    $observations = Get-GcQueueObservations -QueueIds $queueIds `
      -AccessToken $AccessToken -InstanceName $InstanceName
    
    # Build snapshot with health indicators
    $snapshot = @{
      timestamp = (Get-Date).ToString('o')
      queues = @()
    }
    
    foreach ($queue in $queues) {
      $obs = $observations.results | Where-Object { $_.group.queueId -eq $queue.id } | Select-Object -First 1
      
      $agentsOnQueue = 0
      $interacting = 0
      $waiting = 0
      
      if ($obs -and $obs.data) {
        $onQueueMetric = $obs.data | Where-Object { $_.metric -eq 'oOnQueue' }
        if ($onQueueMetric -and $onQueueMetric.stats) {
          $agentsOnQueue = $onQueueMetric.stats.count
        }
        
        $interactingMetric = $obs.data | Where-Object { $_.metric -eq 'oInteracting' }
        if ($interactingMetric -and $interactingMetric.stats) {
          $interacting = $interactingMetric.stats.count
        }
        
        $waitingMetric = $obs.data | Where-Object { $_.metric -eq 'oWaiting' }
        if ($waitingMetric -and $waitingMetric.stats) {
          $waiting = $waitingMetric.stats.count
        }
      }
      
      # Calculate health status based on waiting interactions
      # Green: no waiting, Yellow: 1-4 waiting, Red: 5+ waiting
      $healthStatus = if ($waiting -eq 0) { 'green' } 
                      elseif ($waiting -lt 5) { 'yellow' } 
                      else { 'red' }
      
      $snapshot.queues += @{
        queueId = $queue.id
        queueName = $queue.name
        agentsOnQueue = $agentsOnQueue
        agentsAvailable = [Math]::Max(0, $agentsOnQueue - $interacting)
        interactionsWaiting = $waiting
        interactionsActive = $interacting
        healthStatus = $healthStatus
      }
    }
    
    return $snapshot
  } catch {
    Write-Error "Failed to generate routing snapshot: $_"
    return @{
      timestamp = (Get-Date).ToString('o')
      queues = @()
      error = $_.Exception.Message
    }
  }
}

Export-ModuleMember -Function Get-GcQueues, Get-GcSkills, Get-GcUsers, Get-GcUserPresence, Get-GcQueueObservations, Get-GcRoutingSnapshot
