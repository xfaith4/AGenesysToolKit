# Analytics.psm1
# Core module for analytics aggregates and abandonment metrics

function Get-GcAbandonmentMetrics {
  <#
  .SYNOPSIS
    Query abandonment metrics using analytics aggregates API.
  
  .PARAMETER StartTime
    Start of the time interval.
  
  .PARAMETER EndTime
    End of the time interval.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  #>
  param(
    [Parameter(Mandatory)][DateTime]$StartTime,
    [Parameter(Mandatory)][DateTime]$EndTime,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
  try {
    $interval = "$($StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))/$($EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"
    
    $body = @{
      interval = $interval
      groupBy = @("queueId")
      metrics = @("nOffered", "nHandled", "nAbandon", "tWait", "tHandle")
      filter = @{
        type = "and"
        predicates = @(
          @{ dimension = "mediaType"; value = "voice" }
        )
      }
    }
    
    $results = Invoke-GcRequest -Method POST -Path '/api/v2/analytics/conversations/aggregates/query' `
      -Body $body -AccessToken $AccessToken -InstanceName $InstanceName
    
    if (-not $results -or -not $results.results) {
      return @{
        abandonmentRate = 0
        totalOffered = 0
        totalAbandoned = 0
        avgWaitTime = 0
        avgHandleTime = 0
        byQueue = @()
      }
    }
    
    # Calculate aggregate metrics
    $totalOffered = 0
    $totalAbandoned = 0
    $totalWaitTime = 0
    $totalHandleTime = 0
    $queueCount = 0
    
    foreach ($result in $results.results) {
      if ($result.data) {
        foreach ($dataPoint in $result.data) {
          switch ($dataPoint.metric) {
            'nOffered' { $totalOffered += $dataPoint.stats.count }
            'nAbandon' { $totalAbandoned += $dataPoint.stats.count }
            'tWait' { 
              if ($dataPoint.stats.sum -and $dataPoint.stats.count -gt 0) {
                $totalWaitTime += $dataPoint.stats.sum
              }
            }
            'tHandle' { 
              if ($dataPoint.stats.sum -and $dataPoint.stats.count -gt 0) {
                $totalHandleTime += $dataPoint.stats.sum
              }
            }
          }
        }
        $queueCount++
      }
    }
    
    $abandonmentRate = if ($totalOffered -gt 0) { [Math]::Round(($totalAbandoned / $totalOffered) * 100, 2) } else { 0 }
    $avgWaitTime = if ($totalOffered -gt 0) { [Math]::Round($totalWaitTime / $totalOffered / 1000, 1) } else { 0 }
    $avgHandleTime = if ($totalOffered -gt 0) { [Math]::Round($totalHandleTime / $totalOffered / 1000, 1) } else { 0 }
    
    return @{
      abandonmentRate = $abandonmentRate
      totalOffered = $totalOffered
      totalAbandoned = $totalAbandoned
      avgWaitTime = $avgWaitTime
      avgHandleTime = $avgHandleTime
      byQueue = $results.results
    }
  } catch {
    Write-Error "Failed to query abandonment metrics: $_"
    return @{
      abandonmentRate = 0
      totalOffered = 0
      totalAbandoned = 0
      avgWaitTime = 0
      avgHandleTime = 0
      byQueue = @()
      error = $_.Exception.Message
    }
  }
}

function Search-GcAbandonedConversations {
  <#
  .SYNOPSIS
    Query conversations with abandoned outcome.
  
  .PARAMETER StartTime
    Start of the time interval.
  
  .PARAMETER EndTime
    End of the time interval.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  
  .PARAMETER MaxItems
    Maximum number of conversations to retrieve (default: 500).
  #>
  param(
    [Parameter(Mandatory)][DateTime]$StartTime,
    [Parameter(Mandatory)][DateTime]$EndTime,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [int]$MaxItems = 500
  )
  
  try {
    $interval = "$($StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))/$($EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"
    
    $body = @{
      interval = $interval
      order = "desc"
      orderBy = "conversationStart"
      segmentFilters = @(
        @{
          type = "and"
          predicates = @(
            @{ dimension = "segmentType"; value = "interact" }
            @{ dimension = "disconnectType"; value = "peer" }
          )
        }
      )
      paging = @{
        pageSize = [Math]::Min($MaxItems, 100)
        pageNumber = 1
      }
    }
    
    $results = Invoke-GcPagedRequest -Method POST -Path '/api/v2/analytics/conversations/details/query' `
      -Body $body -AccessToken $AccessToken -InstanceName $InstanceName -MaxItems $MaxItems
    
    return $results
  } catch {
    Write-Error "Failed to search abandoned conversations: $_"
    return @()
  }
}

Export-ModuleMember -Function Get-GcAbandonmentMetrics, Search-GcAbandonedConversations
