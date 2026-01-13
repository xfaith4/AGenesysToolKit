# ConversationsExtended.psm1
# Extended module for Conversations operations (lookup, media, analytics jobs, etc.)

function Search-GcConversations {
  <#
  .SYNOPSIS
    Searches for conversations using query parameters.
  
  .PARAMETER Body
    Query body with conversation search parameters.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  
  .PARAMETER MaxItems
    Maximum number of items to retrieve (default: 500).
  #>
  param(
    [Parameter(Mandatory)][hashtable]$Body,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [int]$MaxItems = 500
  )

  try {
    $results = Invoke-GcPagedRequest -Path '/api/v2/analytics/conversations/details/query' -Method POST `
      -Body $Body -InstanceName $InstanceName -AccessToken $AccessToken -MaxItems $MaxItems
    
    return $results
  } catch {
    Write-Error "Failed to search conversations: $_"
    return @()
  }
}

function Get-GcConversationById {
  <#
  .SYNOPSIS
    Retrieves a specific conversation by ID.
  
  .PARAMETER ConversationId
    The conversation ID to retrieve.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  #>
  param(
    [Parameter(Mandatory)][string]$ConversationId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )

  try {
    $result = Invoke-GcRequest -Path "/api/v2/conversations/$ConversationId" -Method GET `
      -InstanceName $InstanceName -AccessToken $AccessToken
    
    return $result
  } catch {
    Write-Error "Failed to retrieve conversation: $_"
    return $null
  }
}

function Get-GcRecordings {
  <#
  .SYNOPSIS
    Retrieves recordings with optional filters.
  
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
    $results = Invoke-GcPagedRequest -Path '/api/v2/recording/recordings' -Method GET `
      -InstanceName $InstanceName -AccessToken $AccessToken -MaxItems $MaxItems
    
    return $results
  } catch {
    Write-Error "Failed to retrieve recordings: $_"
    return @()
  }
}

function Get-GcQualityEvaluations {
  <#
  .SYNOPSIS
    Retrieves quality evaluations.
  
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
    $results = Invoke-GcPagedRequest -Path '/api/v2/quality/evaluations/query' -Method POST `
      -Body @{} -InstanceName $InstanceName -AccessToken $AccessToken -MaxItems $MaxItems
    
    return $results
  } catch {
    Write-Error "Failed to retrieve quality evaluations: $_"
    return @()
  }
}

Export-ModuleMember -Function Search-GcConversations, Get-GcConversationById, Get-GcRecordings, Get-GcQualityEvaluations
