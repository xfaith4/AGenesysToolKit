# Dependencies.psm1
# Core module for dependency analysis and impact mapping

function Search-GcFlowReferences {
  <#
  .SYNOPSIS
    Search flows for references to a specific object (queue, data action, etc.).
  
  .DESCRIPTION
    This function performs a text-based search through flow configurations to find
    references to a specific object. Note: This implementation makes individual API
    calls for each flow's configuration. For large environments with many flows,
    this may be slow and could approach API rate limits.
    
    Future enhancement: Implement batching, parallel processing with throttling,
    or caching mechanisms to improve performance.
  
  .PARAMETER ObjectId
    The ID of the object to search for.
  
  .PARAMETER ObjectType
    The type of object (queue, dataAction, schedule, etc.).
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  #>
  param(
    [Parameter(Mandatory)][string]$ObjectId,
    [Parameter(Mandatory)][string]$ObjectType,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
  try {
    # Get all flows (paginated)
    $flows = Invoke-GcPagedRequest -Path '/api/v2/flows' -Method GET `
      -AccessToken $AccessToken -InstanceName $InstanceName -MaxItems 500
    
    if (-not $flows -or $flows.Count -eq 0) {
      return @()
    }
    
    # Search flow configurations for object ID
    # NOTE: This makes individual API calls per flow. For orgs with many flows,
    # this can be slow. Future enhancement: parallel processing with throttling.
    $references = @()
    
    foreach ($flow in $flows) {
      try {
        # Get full flow configuration
        $flowDetail = Invoke-GcRequest -Method GET -Path "/api/v2/flows/$($flow.id)/latestconfiguration" `
          -AccessToken $AccessToken -InstanceName $InstanceName -ErrorAction SilentlyContinue
        
        if ($flowDetail) {
          # Convert to JSON string for text search
          $configJson = ($flowDetail | ConvertTo-Json -Depth 20 -Compress).ToLower()
          $searchId = $ObjectId.ToLower()
          
          # Simple text search for object ID
          if ($configJson -like "*$searchId*") {
            # Count occurrences
            $occurrences = ([regex]::Matches($configJson, [regex]::Escape($searchId))).Count
            
            $references += @{
              flowId = $flow.id
              flowName = $flow.name
              flowType = if ($flow.type) { $flow.type } else { 'N/A' }
              division = if ($flow.division -and $flow.division.name) { $flow.division.name } else { 'N/A' }
              published = if ($flow.publishedVersion) { $true } else { $false }
              occurrences = $occurrences
            }
          }
        }
      } catch {
        # Skip flows that fail to load (permissions, etc.)
        Write-Verbose "Skipped flow $($flow.id): $_"
      }
    }
    
    return $references
  } catch {
    Write-Error "Failed to search flow references: $_"
    return @()
  }
}

function Get-GcObjectById {
  <#
  .SYNOPSIS
    Get basic information about an object by ID and type.
  
  .PARAMETER ObjectId
    The ID of the object to retrieve.
  
  .PARAMETER ObjectType
    The type of object (queue, dataAction, schedule, etc.).
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  #>
  param(
    [Parameter(Mandatory)][string]$ObjectId,
    [Parameter(Mandatory)][string]$ObjectType,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
  try {
    $path = switch ($ObjectType.ToLower()) {
      'queue' { "/api/v2/routing/queues/$ObjectId" }
      'dataaction' { "/api/v2/integrations/actions/$ObjectId" }
      'schedule' { "/api/v2/architect/schedules/$ObjectId" }
      'skill' { "/api/v2/routing/skills/$ObjectId" }
      default { $null }
    }
    
    if (-not $path) {
      Write-Warning "Unsupported object type: $ObjectType"
      return $null
    }
    
    $result = Invoke-GcRequest -Method GET -Path $path `
      -AccessToken $AccessToken -InstanceName $InstanceName
    
    return $result
  } catch {
    Write-Error "Failed to retrieve object: $_"
    return $null
  }
}

Export-ModuleMember -Function Search-GcFlowReferences, Get-GcObjectById
