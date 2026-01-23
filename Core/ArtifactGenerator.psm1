### BEGIN: Core.ArtifactGenerator.psm1

Set-StrictMode -Version Latest

function New-GcIncidentPacket {
  <#
  .SYNOPSIS
    Creates a complete incident packet for a conversation.
  
  .DESCRIPTION
    Generates a comprehensive incident packet including:
    - conversation.json (raw API response)
    - timeline.json (normalized timeline)
    - events.ndjson (subscription events)
    - transcript.txt (stitched transcript)
    - agent_assist.json (Agent Assist cards)
    - summary.md (human-readable summary)
    - Optional: ZIP archive
  
  .PARAMETER ConversationId
    Conversation ID to generate packet for
  
  .PARAMETER OutputDirectory
    Directory to save packet files
  
  .PARAMETER ConversationData
    Raw conversation data
  
  .PARAMETER Timeline
    Timeline events array
  
  .PARAMETER SubscriptionEvents
    Subscription events array
  
  .PARAMETER CreateZip
    Whether to create a ZIP archive
  
  .OUTPUTS
    PSCustomObject with packet information and file paths
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ConversationId,
    
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    
    [object]$ConversationData,
    
    [object[]]$Timeline,
    
    [object[]]$SubscriptionEvents = @(),
    
    [switch]$CreateZip
  )
  
  # Create packet directory
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  
  # Sanitize conversationId for Windows filesystem (replace invalid chars with underscore)
  $safeConvId = $ConversationId -replace '[<>:"/\\|?*]', '_'
  
  # Folder name: <timestamp>_<conversationId>
  $folderName = "${timestamp}_${safeConvId}"
  $packetDir = Join-Path -Path $OutputDirectory -ChildPath $folderName
  
  New-Item -ItemType Directory -Path $packetDir -Force | Out-Null
  
  $files = @{}
  
  # 1. conversation.json
  if ($ConversationData) {
    $convPath = Join-Path -Path $packetDir -ChildPath 'conversation.json'
    $ConversationData | ConvertTo-Json -Depth 20 | Set-Content -Path $convPath -Encoding UTF8
    $files['conversation'] = $convPath
  }
  
  # 2. timeline.json
  if ($Timeline) {
    $timelinePath = Join-Path -Path $packetDir -ChildPath 'timeline.json'
    $Timeline | ConvertTo-Json -Depth 20 | Set-Content -Path $timelinePath -Encoding UTF8
    $files['timeline'] = $timelinePath
  }
  
  # 3. events.ndjson (always created; filtered by conversationId if available)
  $eventsPath = Join-Path -Path $packetDir -ChildPath 'events.ndjson'
  if ($SubscriptionEvents -and $SubscriptionEvents.Count -gt 0) {
    # Filter subscription events for this conversation
    $relevantEvents = @($SubscriptionEvents | Where-Object {
      $_.conversationId -eq $ConversationId
    })

    # If no events match conversationId, include all (backward compatibility)
    if ($relevantEvents.Count -eq 0) {
      $relevantEvents = @($SubscriptionEvents)
    }

    $lines = $relevantEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 }
    $lines | Set-Content -Path $eventsPath -Encoding UTF8
  } else {
    # Keep an empty placeholder so packet consumers can rely on the file existing.
    "" | Set-Content -Path $eventsPath -Encoding UTF8
  }
  $files['events'] = $eventsPath
  
  # 4. transcript.txt (best-effort extraction from subscription events and timeline)
  # Filter events for this conversation
  $relevantSubEvents = @()
  if ($SubscriptionEvents -and $SubscriptionEvents.Count -gt 0) {
    $relevantSubEvents = @($SubscriptionEvents | Where-Object { 
      $_.conversationId -eq $ConversationId 
    })
    if ($relevantSubEvents.Count -eq 0) {
      $relevantSubEvents = @($SubscriptionEvents)
    }
  }
  
  $transcriptEvents = @($relevantSubEvents | Where-Object { 
    $_.topic -like '*transcription*' -or $_.text 
  })
  
  if ($transcriptEvents.Count -gt 0) {
    $transcriptPath = Join-Path -Path $packetDir -ChildPath 'transcript.txt'
    $transcriptLines = @()
    $transcriptLines += "Conversation Transcript"
    $transcriptLines += "Conversation ID: $ConversationId"
    $transcriptLines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $transcriptLines += ""
    $transcriptLines += "=" * 60
    $transcriptLines += ""
    
    # Sort events by timestamp
    $sortedEvents = $transcriptEvents | Sort-Object -Property ts
    
    foreach ($event in $sortedEvents) {
      $timeStr = if ($event.ts) { 
        if ($event.ts -is [datetime]) {
          $event.ts.ToString('HH:mm:ss.fff')
        } else {
          $event.ts.ToString()
        }
      } else { 
        "Unknown" 
      }
      
      # Determine speaker from topic or event properties
      $speaker = "Unknown"
      if ($event.topic -like '*transcription*') {
        if ($event.topic -like '*customer*' -or $event.topic -like '*caller*') {
          $speaker = "Customer"
        } elseif ($event.topic -like '*agent*') {
          $speaker = "Agent"
        } else {
          $speaker = "Participant"
        }
      }
      
      $text = if ($event.text) { $event.text } else { "(no text)" }
      
      $transcriptLines += "[$timeStr] ${speaker}:"
      $transcriptLines += "  $text"
      $transcriptLines += ""
    }
    
    $transcriptLines | Set-Content -Path $transcriptPath -Encoding UTF8
    $files['transcript'] = $transcriptPath
  }
  
  # 5. agent_assist.json (filter by conversationId)
  $relevantSubEvents = @()
  if ($SubscriptionEvents -and $SubscriptionEvents.Count -gt 0) {
    $relevantSubEvents = @($SubscriptionEvents | Where-Object { 
      $_.conversationId -eq $ConversationId 
    })
    if ($relevantSubEvents.Count -eq 0) {
      $relevantSubEvents = @($SubscriptionEvents)
    }
  }
  
  $agentAssistEvents = @($relevantSubEvents | Where-Object { 
    $_.topic -like '*agentassist*' 
  })
  
  if ($agentAssistEvents.Count -gt 0) {
    $agentAssistPath = Join-Path -Path $packetDir -ChildPath 'agent_assist.json'
    $agentAssistEvents | ConvertTo-Json -Depth 10 | Set-Content -Path $agentAssistPath -Encoding UTF8
    $files['agent_assist'] = $agentAssistPath
  }
  
  # 6. summary.md (enhanced with time range, quality notes, error details)
  $summaryPath = Join-Path -Path $packetDir -ChildPath 'summary.md'
  $summaryLines = @()
  $summaryLines += "# Incident Packet Summary"
  $summaryLines += ""
  $summaryLines += "**Conversation ID:** $ConversationId"
  $summaryLines += "**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $summaryLines += ""
  $summaryLines += "## Overview"
  $summaryLines += ""
  
  # Time range calculation
  $startTime = $null
  $endTime = $null
  
  if ($ConversationData) {
    if ($ConversationData.PSObject.Properties['startTime'] -and $ConversationData.startTime) {
      $startTime = $ConversationData.startTime
      $summaryLines += "- **Started:** $startTime"
    }
    if ($ConversationData.PSObject.Properties['endTime'] -and $ConversationData.endTime) {
      $endTime = $ConversationData.endTime
      $summaryLines += "- **Ended:** $endTime"
      
      # Calculate duration if both times available
      if ($startTime -and $endTime) {
        try {
          $start = [datetime]::Parse($startTime)
          $end = [datetime]::Parse($endTime)
          $duration = $end - $start
          $summaryLines += "- **Duration:** $($duration.ToString('hh\:mm\:ss'))"
        } catch {
          # Ignore parse errors
        }
      }
    }
    if ($ConversationData.PSObject.Properties['participants'] -and $ConversationData.participants) {
      $summaryLines += "- **Participants:** $($ConversationData.participants.Count)"
    }
  }
  
  # Calculate time range from timeline if not from conversation
  if (-not $startTime -and $Timeline -and $Timeline.Count -gt 0) {
    $sortedTimeline = $Timeline | Sort-Object -Property Time
    $firstEvent = $sortedTimeline[0]
    $lastEvent = $sortedTimeline[$sortedTimeline.Count - 1]
    
    $summaryLines += "- **Time Range (from timeline):** $($firstEvent.Time.ToString('yyyy-MM-dd HH:mm:ss')) to $($lastEvent.Time.ToString('yyyy-MM-dd HH:mm:ss'))"
  }
  
  $summaryLines += ""
  $summaryLines += "## Timeline Events"
  $summaryLines += ""
  
  if ($Timeline) {
    $summaryLines += "Total events: $($Timeline.Count)"
    $summaryLines += ""
    
    $categories = $Timeline | Group-Object -Property Category
    foreach ($cat in $categories) {
      $summaryLines += "- **$($cat.Name):** $($cat.Count) events"
    }
  } else {
    $summaryLines += "No timeline events available."
  }
  
  $summaryLines += ""
  $summaryLines += "## Subscription Events"
  $summaryLines += ""
  
  # Filter subscription events for this conversation
  $relevantSubEvents = @()
  if ($SubscriptionEvents -and $SubscriptionEvents.Count -gt 0) {
    $relevantSubEvents = @($SubscriptionEvents | Where-Object { 
      $_.conversationId -eq $ConversationId 
    })
    if ($relevantSubEvents.Count -eq 0) {
      $relevantSubEvents = @($SubscriptionEvents)
    }
  }
  
  if ($relevantSubEvents.Count -gt 0) {
    $summaryLines += "Total subscription events: $($relevantSubEvents.Count)"
    $summaryLines += ""
    
    # Group by severity
    $severityGroups = $relevantSubEvents | Group-Object -Property severity
    if ($severityGroups) {
      $summaryLines += "**By Severity:**"
      foreach ($sev in $severityGroups) {
        $summaryLines += "- $($sev.Name): $($sev.Count)"
      }
      $summaryLines += ""
    }
    
    # Error analysis
    $errorEvents = @($relevantSubEvents | Where-Object { 
      $_.severity -eq 'error' -or $_.topic -like '*error*' 
    })
    if ($errorEvents.Count -gt 0) {
      $summaryLines += "### Errors ($($errorEvents.Count))"
      $summaryLines += ""
      foreach ($err in $errorEvents | Select-Object -First 10) {
        $timeStr = if ($err.ts -is [datetime]) { 
          $err.ts.ToString('HH:mm:ss') 
        } else { 
          $err.ts 
        }
        $summaryLines += "- **[$timeStr]** $($err.topic): $($err.text)"
      }
      if ($errorEvents.Count -gt 10) {
        $summaryLines += "- ... and $($errorEvents.Count - 10) more errors (see events.ndjson)"
      }
      $summaryLines += ""
    }
    
    # Transcription quality notes
    $transcriptionEvents = @($relevantSubEvents | Where-Object { 
      $_.topic -like '*transcription*' 
    })
    if ($transcriptionEvents.Count -gt 0) {
      $summaryLines += "### Quality Notes"
      $summaryLines += ""
      $summaryLines += "- **Transcription Events:** $($transcriptionEvents.Count)"
      
      # Check for partial vs final transcriptions
      $partialCount = @($transcriptionEvents | Where-Object { $_.topic -like '*partial*' }).Count
      $finalCount = @($transcriptionEvents | Where-Object { $_.topic -like '*final*' }).Count
      
      if ($partialCount -gt 0) { $summaryLines += "- Partial transcriptions: $partialCount" }
      if ($finalCount -gt 0) { $summaryLines += "- Final transcriptions: $finalCount" }
      
      $summaryLines += ""
    }
  } else {
    $summaryLines += "No subscription events available."
  }
  
  $summaryLines += ""
  $summaryLines += "## Files Included"
  $summaryLines += ""
  
  foreach ($key in $files.Keys | Sort-Object) {
    $fileName = Split-Path -Leaf $files[$key]
    $summaryLines += "- `$fileName` - $key data"
  }
  
  $summaryLines | Set-Content -Path $summaryPath -Encoding UTF8
  $files['summary'] = $summaryPath
  
  # 7. Create ZIP if requested (with graceful fallback)
  $zipPath = $null
  if ($CreateZip) {
    # ZIP filename: IncidentPacket_<conversationId>_<timestamp>.zip
    $zipFileName = "IncidentPacket_${safeConvId}_${timestamp}.zip"
    $zipPath = Join-Path -Path $OutputDirectory -ChildPath $zipFileName
    
    try {
      # Check if compression is available
      $compressionAvailable = $true
      try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
      } catch {
        $compressionAvailable = $false
        Write-Warning "System.IO.Compression.FileSystem not available. ZIP creation skipped."
      }
      
      if ($compressionAvailable) {
        # Create ZIP archive
        [System.IO.Compression.ZipFile]::CreateFromDirectory($packetDir, $zipPath)
        Write-Verbose "Created ZIP archive: $zipPath"
      } else {
        $zipPath = $null
      }
    } catch {
      Write-Warning "Failed to create ZIP archive: $_"
      $zipPath = $null
    }
  }
  
  return [PSCustomObject]@{
    PacketName       = $folderName
    PacketDirectory  = $packetDir
    Files            = $files
    ZipPath          = $zipPath
    ConversationId   = $ConversationId
    Timestamp        = $timestamp
    Created          = Get-Date
  }
}

function Export-GcConversationPacket {
  <#
  .SYNOPSIS
    High-level function to export a complete conversation packet.
  
  .DESCRIPTION
    Fetches conversation data, builds timeline, and generates
    a complete incident packet with all artifacts.
  
  .PARAMETER ConversationId
    Conversation ID to export
  
  .PARAMETER Region
    Genesys Cloud region
  
  .PARAMETER AccessToken
    OAuth access token
  
  .PARAMETER OutputDirectory
    Directory to save packet
  
  .PARAMETER SubscriptionEvents
    Optional subscription events to include
  
  .PARAMETER CreateZip
    Whether to create a ZIP archive
  
  .OUTPUTS
    Packet information object
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ConversationId,
    
    [Parameter(Mandatory)]
    [string]$Region,
    
    [Parameter(Mandatory)]
    [string]$AccessToken,
    
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    
    [object[]]$SubscriptionEvents = @(),
    
    [switch]$CreateZip
  )
  
  # Import required modules
  $httpModule = Join-Path -Path $PSScriptRoot -ChildPath 'HttpRequests.psm1'
  $timelineModule = Join-Path -Path $PSScriptRoot -ChildPath 'Timeline.psm1'
  
  if (-not (Get-Command -Name Invoke-GcRequest -ErrorAction SilentlyContinue)) {
    Import-Module $httpModule -Force
  }
  if (-not (Get-Command -Name ConvertTo-GcTimeline -ErrorAction SilentlyContinue)) {
    Import-Module $timelineModule -Force
  }
  
  try {
    Write-Output "Querying analytics for conversation $ConversationId..."
    
    # Build analytics query body (same as timeline job)
    $queryBody = @{
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
    }
    
    # Submit analytics job
    Write-Output "Submitting analytics job..."
    $jobResponse = Invoke-GcRequest `
      -Method POST `
      -Path '/api/v2/analytics/conversations/details/jobs' `
      -Body $queryBody `
      -InstanceName $Region `
      -AccessToken $AccessToken
    
    $jobId = $jobResponse.id
    if (-not $jobId) { throw "No job ID returned from analytics API." }
    
    Write-Output "Job submitted: $jobId. Waiting for completion..."
    
    # Poll for completion
    $maxAttempts = 120  # 2 minutes max (120 * 1 second)
    $attempt = 0
    $completed = $false
    
    while ($attempt -lt $maxAttempts) {
      Start-Sleep -Milliseconds 1000
      $attempt++
      
      $status = Invoke-GcRequest `
        -Method GET `
        -Path "/api/v2/analytics/conversations/details/jobs/$jobId" `
        -InstanceName $Region `
        -AccessToken $AccessToken
      
      if ($status.state -match 'FULFILLED|COMPLETED|SUCCESS') {
        $completed = $true
        Write-Output "Job completed successfully."
        break
      }
      
      if ($status.state -match 'FAILED|ERROR') {
        throw "Analytics job failed: $($status.state)"
      }
    }
    
    if (-not $completed) {
      throw "Analytics job timed out after $maxAttempts seconds."
    }
    
    # Fetch results
    Write-Output "Fetching results..."
    $results = Invoke-GcRequest `
      -Method GET `
      -Path "/api/v2/analytics/conversations/details/jobs/$jobId/results" `
      -InstanceName $Region `
      -AccessToken $AccessToken
    
    if (-not $results.conversations -or $results.conversations.Count -eq 0) {
      throw "No conversation data found for ID: $ConversationId"
    }
    
    Write-Output "Retrieved conversation data. Building timeline..."
    
    $conversationData = $results.conversations[0]
    
    # Filter subscription events for this conversation
    $relevantSubEvents = @()
    if ($SubscriptionEvents -and $SubscriptionEvents.Count -gt 0) {
      foreach ($evt in $SubscriptionEvents) {
        if ($evt.conversationId -eq $ConversationId) {
          $relevantSubEvents += $evt
        }
      }
      Write-Output "Found $($relevantSubEvents.Count) subscription events for this conversation."
    }
    
    # Convert to timeline events
    $timeline = ConvertTo-GcTimeline `
      -ConversationData $conversationData `
      -AnalyticsData $conversationData `
      -SubscriptionEvents $relevantSubEvents
    
    Write-Output "Timeline built with $($timeline.Count) events."
    
    Write-Output "Generating incident packet..."
    $packet = New-GcIncidentPacket `
      -ConversationId $ConversationId `
      -OutputDirectory $OutputDirectory `
      -ConversationData $conversationData `
      -Timeline $timeline `
      -SubscriptionEvents $SubscriptionEvents `
      -CreateZip:$CreateZip
    
    Write-Output "Packet created successfully: $($packet.PacketDirectory)"
    
    return $packet
    
  } catch {
    Write-Error "Failed to export conversation packet: $_"
    throw
  }
}

Export-ModuleMember -Function New-GcIncidentPacket, Export-GcConversationPacket

### END: Core.ArtifactGenerator.psm1
