### BEGIN: Core.Timeline.psm1

Set-StrictMode -Version Latest

function New-GcTimelineEvent {
  <#
  .SYNOPSIS
    Creates a timeline event object.
  
  .PARAMETER Time
    Timestamp of the event
  
  .PARAMETER Category
    Event category (Segment, MediaStats, Error, AgentAssist, Transcription, System)
  
  .PARAMETER Label
    Human-readable label
  
  .PARAMETER Details
    Detailed information (object or string)
  
  .PARAMETER CorrelationKeys
    Hashtable of correlation IDs (conversationId, participantId, etc.)
  
  .OUTPUTS
    Timeline event object
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [datetime]$Time,
    
    [Parameter(Mandatory)]
    [ValidateSet('Segment', 'MediaStats', 'Error', 'AgentAssist', 'Transcription', 'System', 'Quality')]
    [string]$Category,
    
    [Parameter(Mandatory)]
    [string]$Label,
    
    [object]$Details,
    
    [hashtable]$CorrelationKeys = @{}
  )
  
  return [PSCustomObject]@{
    Time            = $Time
    Category        = $Category
    Label           = $Label
    Details         = $Details
    CorrelationKeys = $CorrelationKeys
  }
}

function Get-GcConversationDetails {
  <#
  .SYNOPSIS
    Fetches conversation details from Genesys Cloud API.
  
  .PARAMETER ConversationId
    Conversation ID to fetch
  
  .PARAMETER Region
    Genesys Cloud region
  
  .PARAMETER AccessToken
    OAuth access token
  
  .OUTPUTS
    Conversation details object
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ConversationId,
    
    [Parameter(Mandatory)]
    [string]$Region,
    
    [Parameter(Mandatory)]
    [string]$AccessToken
  )
  
  try {
    $uri = "https://api.$Region/api/v2/conversations/$ConversationId"
    $headers = @{
      'Authorization' = "Bearer $AccessToken"
      'Content-Type'  = 'application/json'
    }
    
    $conversation = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
    return $conversation
    
  } catch {
    Write-Error "Failed to fetch conversation details: $_"
    throw
  }
}

function Get-GcConversationAnalytics {
  <#
  .SYNOPSIS
    Fetches conversation analytics using Analytics Conversation Details API.
  
  .DESCRIPTION
    Uses the analytics query to get detailed conversation information
    including segments, media stats, and participant information.
  
  .PARAMETER ConversationId
    Conversation ID to fetch
  
  .PARAMETER Region
    Genesys Cloud region
  
  .PARAMETER AccessToken
    OAuth access token
  
  .OUTPUTS
    Analytics conversation details object
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ConversationId,
    
    [Parameter(Mandatory)]
    [string]$Region,
    
    [Parameter(Mandatory)]
    [string]$AccessToken
  )
  
  try {
    # Query analytics for the specific conversation
    $uri = "https://api.$Region/api/v2/analytics/conversations/details/query"
    $headers = @{
      'Authorization' = "Bearer $AccessToken"
      'Content-Type'  = 'application/json'
    }
    
    $body = @{
      conversationFilters = @(
        @{
          type = 'and'
          predicates = @(
            @{
              dimension = 'conversationId'
              value = $ConversationId
            }
          )
        }
      )
      order = 'asc'
      orderBy = 'conversationStart'
    } | ConvertTo-Json -Depth 10
    
    $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body
    
    if ($response.conversations -and $response.conversations.Count -gt 0) {
      return $response.conversations[0]
    }
    
    return $null
    
  } catch {
    Write-Error "Failed to fetch conversation analytics: $_"
    throw
  }
}

function ConvertTo-GcTimeline {
  <#
  .SYNOPSIS
    Converts conversation data to a unified timeline model.
  
  .PARAMETER ConversationData
    Raw conversation data from API
  
  .PARAMETER AnalyticsData
    Optional analytics data for enrichment
  
  .PARAMETER SubscriptionEvents
    Optional subscription events to correlate
  
  .OUTPUTS
    Array of timeline events sorted by time
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$ConversationData,
    
    [object]$AnalyticsData,
    
    [object[]]$SubscriptionEvents = @()
  )
  
  $timeline = @()
  $conversationId = $ConversationData.id
  
  # Extract conversation start
  if ($ConversationData.startTime) {
    $timeline += New-GcTimelineEvent `
      -Time ([datetime]$ConversationData.startTime) `
      -Category 'System' `
      -Label 'Conversation Started' `
      -Details @{ conversationId = $conversationId } `
      -CorrelationKeys @{ conversationId = $conversationId }
  }
  
  # Extract participant events
  if ($ConversationData.participants) {
    foreach ($participant in $ConversationData.participants) {
      $participantId = $participant.id
      $participantName = if ($participant.name) { $participant.name } else { $participant.purpose }
      
      # Participant joined
      if ($participant.startTime) {
        $timeline += New-GcTimelineEvent `
          -Time ([datetime]$participant.startTime) `
          -Category 'Segment' `
          -Label "Participant Joined: $participantName" `
          -Details $participant `
          -CorrelationKeys @{ 
            conversationId = $conversationId
            participantId = $participantId
          }
      }
      
      # Extract session/segment events
      if ($participant.sessions) {
        foreach ($session in $participant.sessions) {
          foreach ($segment in $session.segments) {
            $segmentStart = [datetime]$segment.segmentStart
            $segmentType = $segment.segmentType
            
            $timeline += New-GcTimelineEvent `
              -Time $segmentStart `
              -Category 'Segment' `
              -Label "Segment: $segmentType" `
              -Details $segment `
              -CorrelationKeys @{
                conversationId = $conversationId
                participantId = $participantId
                sessionId = $session.id
                segmentType = $segmentType
              }
            
            # Extract disconnect/error codes
            if ($segment.disconnectType) {
              $timeline += New-GcTimelineEvent `
                -Time $segmentStart `
                -Category 'Error' `
                -Label "Disconnect: $($segment.disconnectType)" `
                -Details @{ 
                  disconnectType = $segment.disconnectType
                  segment = $segment
                } `
                -CorrelationKeys @{
                  conversationId = $conversationId
                  participantId = $participantId
                }
            }
          }
          
          # Extract media stats if available
          if ($session.metrics) {
            foreach ($metric in $session.metrics) {
              if ($metric.emitDate) {
                $timeline += New-GcTimelineEvent `
                  -Time ([datetime]$metric.emitDate) `
                  -Category 'MediaStats' `
                  -Label "Media Metric: $($metric.name)" `
                  -Details $metric `
                  -CorrelationKeys @{
                    conversationId = $conversationId
                    participantId = $participantId
                    sessionId = $session.id
                  }
              }
            }
          }
        }
      }
      
      # Participant left
      if ($participant.endTime) {
        $timeline += New-GcTimelineEvent `
          -Time ([datetime]$participant.endTime) `
          -Category 'Segment' `
          -Label "Participant Left: $participantName" `
          -Details @{ participant = $participant } `
          -CorrelationKeys @{
            conversationId = $conversationId
            participantId = $participantId
          }
      }
    }
  }
  
  # Integrate analytics data if available
  if ($AnalyticsData) {
    # Extract segments from analytics
    if ($AnalyticsData.participants) {
      foreach ($participant in $AnalyticsData.participants) {
        if ($participant.sessions) {
          foreach ($session in $participant.sessions) {
            if ($session.segments) {
              foreach ($segment in $session.segments) {
                # Check for quality issues
                if ($segment.queueId) {
                  $queueTime = [datetime]$segment.segmentStart
                  $timeline += New-GcTimelineEvent `
                    -Time $queueTime `
                    -Category 'Segment' `
                    -Label "Entered Queue: $($segment.queueId)" `
                    -Details $segment `
                    -CorrelationKeys @{
                      conversationId = $conversationId
                      participantId = $participant.participantId
                      queueId = $segment.queueId
                    }
                }
              }
            }
          }
        }
      }
    }
  }
  
  # Integrate subscription events
  foreach ($event in $SubscriptionEvents) {
    if ($event.ts) {
      $eventTime = if ($event.ts -is [datetime]) { $event.ts } else { [datetime]::Parse($event.ts) }
      
      $category = 'System'
      if ($event.type -like '*transcription*') { $category = 'Transcription' }
      elseif ($event.type -like '*agentassist*') { $category = 'AgentAssist' }
      elseif ($event.type -like '*error*') { $category = 'Error' }
      
      $timeline += New-GcTimelineEvent `
        -Time $eventTime `
        -Category $category `
        -Label "$($event.type): $($event.text)" `
        -Details $event `
        -CorrelationKeys @{
          conversationId = $event.conversationId
          eventType = $event.type
        }
    }
  }
  
  # Sort by time
  $timeline = $timeline | Sort-Object -Property Time
  
  return $timeline
}

function Export-GcTimelineToJson {
  <#
  .SYNOPSIS
    Exports timeline to JSON format.
  
  .PARAMETER Timeline
    Timeline event array
  
  .PARAMETER Path
    Output file path
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Timeline,
    
    [Parameter(Mandatory)]
    [string]$Path
  )
  
  $Timeline | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Export-GcTimelineToMarkdown {
  <#
  .SYNOPSIS
    Exports timeline to Markdown format for human readability.
  
  .PARAMETER Timeline
    Timeline event array
  
  .PARAMETER Path
    Output file path
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Timeline,
    
    [Parameter(Mandatory)]
    [string]$Path
  )
  
  $lines = @()
  $lines += "# Conversation Timeline"
  $lines += ""
  $lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $lines += ""
  $lines += "## Events"
  $lines += ""
  
  foreach ($event in $Timeline) {
    $timeStr = $event.Time.ToString('HH:mm:ss.fff')
    $lines += "### [$timeStr] $($event.Category): $($event.Label)"
    $lines += ""
    
    if ($event.CorrelationKeys) {
      $lines += "**Correlation Keys:**"
      foreach ($key in $event.CorrelationKeys.Keys) {
        $lines += "- ${key}: $($event.CorrelationKeys[$key])"
      }
      $lines += ""
    }
    
    $lines += "---"
    $lines += ""
  }
  
  $lines | Set-Content -Path $Path -Encoding UTF8
}

Export-ModuleMember -Function New-GcTimelineEvent, Get-GcConversationDetails, `
  Get-GcConversationAnalytics, ConvertTo-GcTimeline, `
  Export-GcTimelineToJson, Export-GcTimelineToMarkdown

### END: Core.Timeline.psm1
