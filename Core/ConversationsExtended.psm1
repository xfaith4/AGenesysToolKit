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
    Retrieves user recordings with optional filters.
  
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
    $results = Invoke-GcPagedRequest -Path '/api/v2/userrecordings' -Method GET `
      -InstanceName $InstanceName -AccessToken $AccessToken -MaxItems $MaxItems

    # Backward-compatible shape for existing UI binding logic.
    foreach ($recording in @($results)) {
      if (-not $recording) { continue }

      try {
        if (-not $recording.PSObject.Properties.Match('conversationId').Count -and
            $recording.PSObject.Properties.Match('conversation').Count -and
            $recording.conversation -and
            $recording.conversation.id) {
          Add-Member -InputObject $recording -NotePropertyName 'conversationId' -NotePropertyValue $recording.conversation.id -Force
        }
      } catch { }
    }

    return @($results)
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
    $results = Invoke-GcPagedRequest -Path '/api/v2/quality/evaluations/query' -Method GET `
      -InstanceName $InstanceName -AccessToken $AccessToken -MaxItems $MaxItems
    
    return $results
  } catch {
    Write-Error "Failed to retrieve quality evaluations: $_"
    return @()
  }
}

function Get-GcRecordingMedia {
  <#
  .SYNOPSIS
    Get recording media URL or metadata for download.
  
  .PARAMETER RecordingId
    The recording ID to retrieve.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  #>
  param(
    [Parameter(Mandatory)][string]$RecordingId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
  try {
    # Fetch user recording first (current supported API surface).
    $userRecording = Invoke-GcRequest -Method GET -Path "/api/v2/userrecordings/$RecordingId" `
      -AccessToken $AccessToken -InstanceName $InstanceName

    if (-not $userRecording) {
      return $null
    }

    # If conversation linkage exists, attempt richer conversation recording details.
    $conversationId = $null
    try {
      if ($userRecording.conversation -and $userRecording.conversation.id) {
        $conversationId = [string]$userRecording.conversation.id
      }
    } catch { }

    if (-not [string]::IsNullOrWhiteSpace($conversationId)) {
      try {
        $recording = Invoke-GcRequest -Method GET `
          -Path "/api/v2/conversations/$conversationId/recordings/$RecordingId" `
          -AccessToken $AccessToken -InstanceName $InstanceName
        if ($recording) { return $recording }
      } catch { }
    }

    return $userRecording
  } catch {
    Write-Error "Failed to retrieve recording media: $_"
    return $null
  }
}

function Get-GcConversationTranscript {
  <#
  .SYNOPSIS
    Fetch and format conversation transcript from conversation details.
  
  .PARAMETER ConversationId
    The conversation ID to retrieve transcript from.
  
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
    # Get conversation details
    $conv = Invoke-GcRequest -Method GET -Path "/api/v2/conversations/$ConversationId" `
      -AccessToken $AccessToken -InstanceName $InstanceName
    
    if (-not $conv) {
      return @()
    }
    
    # Extract transcript from conversation data
    $transcript = @()
    
    if ($conv.participants) {
      foreach ($participant in $conv.participants) {
        $participantName = if ($participant.name) { $participant.name } else { "Unknown" }
        
        if ($participant.sessions) {
          foreach ($session in $participant.sessions) {
            if ($session.segments) {
              foreach ($segment in $session.segments) {
                # Look for interact segments with messages
                if ($segment.segmentType -eq 'interact') {
                  $timestamp = if ($segment.segmentStart) { $segment.segmentStart } else { "" }
                  
                  # Check for text messages in properties
                  if ($segment.properties) {
                    if ($segment.properties.message) {
                      $transcript += @{
                        timestamp = $timestamp
                        participant = $participantName
                        message = $segment.properties.message
                        type = "message"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    
    return $transcript
  } catch {
    Write-Error "Failed to retrieve conversation transcript: $_"
    return @()
  }
}

Export-ModuleMember -Function Search-GcConversations, Get-GcConversationById, Get-GcRecordings, Get-GcQualityEvaluations, Get-GcRecordingMedia, Get-GcConversationTranscript
