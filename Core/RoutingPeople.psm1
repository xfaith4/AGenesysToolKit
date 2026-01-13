# RoutingPeople.psm1
# Core module for Routing & People operations (Queues, Skills, Users & Presence)

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

Export-ModuleMember -Function Get-GcQueues, Get-GcSkills, Get-GcUsers, Get-GcUserPresence
