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
  $packetName = "IncidentPacket_${ConversationId}_${timestamp}"
  $packetDir = Join-Path -Path $OutputDirectory -ChildPath $packetName
  
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
  
  # 3. events.ndjson
  if ($SubscriptionEvents.Count -gt 0) {
    $eventsPath = Join-Path -Path $packetDir -ChildPath 'events.ndjson'
    $lines = $SubscriptionEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 }
    $lines | Set-Content -Path $eventsPath -Encoding UTF8
    $files['events'] = $eventsPath
  }
  
  # 4. transcript.txt
  $transcriptEvents = $SubscriptionEvents | Where-Object { $_.type -like '*transcription*' -or $_.text }
  if ($transcriptEvents.Count -gt 0) {
    $transcriptPath = Join-Path -Path $packetDir -ChildPath 'transcript.txt'
    $transcriptLines = @()
    $transcriptLines += "Conversation Transcript"
    $transcriptLines += "Conversation ID: $ConversationId"
    $transcriptLines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $transcriptLines += ""
    $transcriptLines += "=" * 60
    $transcriptLines += ""
    
    foreach ($event in $transcriptEvents) {
      $timeStr = if ($event.ts) { $event.ts.ToString('HH:mm:ss.fff') } else { "Unknown" }
      $speaker = if ($event.speaker) { $event.speaker } else { "System" }
      $text = if ($event.text) { $event.text } else { "(no text)" }
      
      $transcriptLines += "[$timeStr] $speaker:"
      $transcriptLines += "  $text"
      $transcriptLines += ""
    }
    
    $transcriptLines | Set-Content -Path $transcriptPath -Encoding UTF8
    $files['transcript'] = $transcriptPath
  }
  
  # 5. agent_assist.json
  $agentAssistEvents = $SubscriptionEvents | Where-Object { $_.type -like '*agentassist*' }
  if ($agentAssistEvents.Count -gt 0) {
    $agentAssistPath = Join-Path -Path $packetDir -ChildPath 'agent_assist.json'
    $agentAssistEvents | ConvertTo-Json -Depth 10 | Set-Content -Path $agentAssistPath -Encoding UTF8
    $files['agent_assist'] = $agentAssistPath
  }
  
  # 6. summary.md
  $summaryPath = Join-Path -Path $packetDir -ChildPath 'summary.md'
  $summaryLines = @()
  $summaryLines += "# Incident Packet Summary"
  $summaryLines += ""
  $summaryLines += "**Conversation ID:** $ConversationId"
  $summaryLines += "**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $summaryLines += ""
  $summaryLines += "## Overview"
  $summaryLines += ""
  
  if ($ConversationData) {
    $summaryLines += "- **Started:** $($ConversationData.startTime)"
    if ($ConversationData.endTime) {
      $summaryLines += "- **Ended:** $($ConversationData.endTime)"
    }
    if ($ConversationData.participants) {
      $summaryLines += "- **Participants:** $($ConversationData.participants.Count)"
    }
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
  }
  
  $summaryLines += ""
  $summaryLines += "## Subscription Events"
  $summaryLines += ""
  
  if ($SubscriptionEvents.Count -gt 0) {
    $summaryLines += "Total subscription events: $($SubscriptionEvents.Count)"
    $summaryLines += ""
    
    $errorEvents = $SubscriptionEvents | Where-Object { $_.severity -eq 'error' -or $_.type -like '*error*' }
    if ($errorEvents.Count -gt 0) {
      $summaryLines += "### Errors ($($errorEvents.Count))"
      $summaryLines += ""
      foreach ($err in $errorEvents | Select-Object -First 10) {
        $summaryLines += "- **[$($err.ts)]** $($err.type): $($err.text)"
      }
      $summaryLines += ""
    }
  }
  
  $summaryLines += ""
  $summaryLines += "## Files Included"
  $summaryLines += ""
  
  foreach ($key in $files.Keys) {
    $fileName = Split-Path -Leaf $files[$key]
    $summaryLines += "- `$fileName` - $key data"
  }
  
  $summaryLines | Set-Content -Path $summaryPath -Encoding UTF8
  $files['summary'] = $summaryPath
  
  # 7. Create ZIP if requested
  $zipPath = $null
  if ($CreateZip) {
    $zipPath = Join-Path -Path $OutputDirectory -ChildPath "$packetName.zip"
    
    try {
      # Use .NET compression
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [System.IO.Compression.ZipFile]::CreateFromDirectory($packetDir, $zipPath)
      
      Write-Verbose "Created ZIP archive: $zipPath"
    } catch {
      Write-Warning "Failed to create ZIP archive: $_"
    }
  }
  
  return [PSCustomObject]@{
    PacketName       = $packetName
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
  if (-not (Get-Command -Name Get-GcConversationDetails -ErrorAction SilentlyContinue)) {
    $timelineModule = Join-Path -Path $PSScriptRoot -ChildPath 'Timeline.psm1'
    Import-Module $timelineModule -Force
  }
  
  try {
    Write-Verbose "Fetching conversation details for $ConversationId..."
    $conversationData = Get-GcConversationDetails -ConversationId $ConversationId -Region $Region -AccessToken $AccessToken
    
    Write-Verbose "Building timeline..."
    $timeline = ConvertTo-GcTimeline -ConversationData $conversationData -SubscriptionEvents $SubscriptionEvents
    
    Write-Verbose "Generating incident packet..."
    $packet = New-GcIncidentPacket `
      -ConversationId $ConversationId `
      -OutputDirectory $OutputDirectory `
      -ConversationData $conversationData `
      -Timeline $timeline `
      -SubscriptionEvents $SubscriptionEvents `
      -CreateZip:$CreateZip
    
    Write-Verbose "Packet created successfully: $($packet.PacketDirectory)"
    
    return $packet
    
  } catch {
    Write-Error "Failed to export conversation packet: $_"
    throw
  }
}

Export-ModuleMember -Function New-GcIncidentPacket, Export-GcConversationPacket

### END: Core.ArtifactGenerator.psm1
