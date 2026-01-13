# Remaining Work - Module Implementation

## Overview

This document outlines the remaining placeholder modules that need implementation to complete the AGenesysToolKit. As of v0.5.0, 56% of planned modules have been completed (5 of 9), with all high and medium priority modules fully implemented.

## Completed Modules (v0.5.0)

### High Priority ✅
1. **Conversations::Conversation Lookup** - Search and filter conversations
2. **Conversations::Analytics Jobs** - Submit and monitor analytics queries
3. **Routing & People::Users & Presence** - User management and listing

### Medium Priority ✅
4. **Orchestration::Config Export** - Export configuration to JSON/ZIP
5. **Conversations::Incident Packet** - Generate incident investigation packets

## Remaining Modules (4)

### 1. Routing & People::Routing Snapshot 🔴

**Priority**: Medium  
**Estimated Effort**: 6-8 hours  
**Status**: Not Implemented

**Purpose**: Real-time dashboard showing routing health, queue statistics, and agent activity

**Core Functions Needed**:
```powershell
# Add to Core/RoutingPeople.psm1

function Get-GcQueueObservations {
  <#
  .SYNOPSIS
    Query real-time queue observations for metrics
  #>
  param(
    [Parameter(Mandatory)][string[]]$QueueIds,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
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
  
  Invoke-GcRequest -Method POST -Path '/api/v2/analytics/queues/observations/query' `
    -Body $body -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcRoutingSnapshot {
  <#
  .SYNOPSIS
    Aggregate snapshot across all queues with health indicators
  #>
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
  # Get all queues
  $queues = Invoke-GcPagedRequest -Path '/api/v2/routing/queues' -Method GET `
    -AccessToken $AccessToken -InstanceName $InstanceName
  
  $queueIds = $queues | ForEach-Object { $_.id }
  
  # Get observations for all queues
  if ($queueIds.Count -gt 0) {
    $observations = Get-GcQueueObservations -QueueIds $queueIds `
      -AccessToken $AccessToken -InstanceName $InstanceName
  } else {
    $observations = @()
  }
  
  # Build snapshot with health indicators
  $snapshot = @{
    timestamp = (Get-Date).ToString('o')
    queues = @()
  }
  
  foreach ($queue in $queues) {
    $obs = $observations.results | Where-Object { $_.group.queueId -eq $queue.id } | Select-Object -First 1
    
    $agentsOnQueue = if ($obs) { $obs.data | Where-Object { $_.metric -eq 'oOnQueue' } | Select-Object -ExpandProperty stats | Select-Object -ExpandProperty count } else { 0 }
    $interacting = if ($obs) { $obs.data | Where-Object { $_.metric -eq 'oInteracting' } | Select-Object -ExpandProperty stats | Select-Object -ExpandProperty count } else { 0 }
    $waiting = if ($obs) { $obs.data | Where-Object { $_.metric -eq 'oWaiting' } | Select-Object -ExpandProperty stats | Select-Object -ExpandProperty count } else { 0 }
    
    # Calculate health status based on wait time
    # This is simplified - real implementation would use actual wait time metrics
    $healthStatus = if ($waiting -eq 0) { 'green' } 
                    elseif ($waiting -lt 5) { 'yellow' } 
                    else { 'red' }
    
    $snapshot.queues += @{
      queueId = $queue.id
      queueName = $queue.name
      agentsOnQueue = $agentsOnQueue
      agentsAvailable = $agentsOnQueue - $interacting
      interactionsWaiting = $waiting
      interactionsActive = $interacting
      healthStatus = $healthStatus
    }
  }
  
  return $snapshot
}

Export-ModuleMember -Function Get-GcQueueObservations, Get-GcRoutingSnapshot
```

**View Implementation**:
```powershell
function New-RoutingSnapshotView {
  # Create XAML with:
  # - Auto-refresh timer (every 10-30 seconds)
  # - DataGrid showing queue metrics with color-coded health status
  # - Summary cards: Total Agents, Total Waiting, Average Wait Time
  # - Refresh button for manual refresh
  # - Export snapshot to JSON
  
  # Use Start-AppJob to fetch snapshot without blocking UI
  # Update grid on timer tick
  # Color-code rows based on healthStatus (green/yellow/red)
}
```

**Switch Case**:
```powershell
'Routing & People::Routing Snapshot' {
  $TxtSubtitle.Text = 'Real-time routing health and queue metrics'
  $MainHost.Content = (New-RoutingSnapshotView)
}
```

---

### 2. Conversations::Media & Quality 🔴

**Priority**: Medium  
**Estimated Effort**: 8-10 hours  
**Status**: Not Implemented

**Purpose**: View recordings, transcripts, and quality evaluations

**Core Functions Needed**:
```powershell
# Add to Core/ConversationsExtended.psm1

function Get-GcRecordingMedia {
  <#
  .SYNOPSIS
    Get recording media URL or download recording
  #>
  param(
    [Parameter(Mandatory)][string]$RecordingId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
  Invoke-GcRequest -Method GET -Path "/api/v2/recording/recordings/$RecordingId/media" `
    -AccessToken $AccessToken -InstanceName $InstanceName
}

function Get-GcConversationTranscript {
  <#
  .SYNOPSIS
    Fetch and format conversation transcript
  #>
  param(
    [Parameter(Mandatory)][string]$ConversationId,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
  # Get conversation details
  $conv = Invoke-GcRequest -Method GET -Path "/api/v2/conversations/$ConversationId" `
    -AccessToken $AccessToken -InstanceName $InstanceName
  
  # Extract transcript from conversation data
  # This is simplified - real implementation would parse participant messages
  $transcript = @()
  
  foreach ($participant in $conv.participants) {
    if ($participant.sessions) {
      foreach ($session in $participant.sessions) {
        if ($session.segments) {
          foreach ($segment in $session.segments) {
            if ($segment.type -eq 'interact' -and $segment.properties) {
              $transcript += @{
                timestamp = $segment.segmentStart
                participant = $participant.name
                message = $segment.properties.message
              }
            }
          }
        }
      }
    }
  }
  
  return $transcript
}

Export-ModuleMember -Function Get-GcRecordingMedia, Get-GcConversationTranscript
```

**View Implementation**:
```powershell
function New-MediaQualityView {
  # Create XAML with tabbed interface:
  # Tab 1: Recordings
  #   - Date range filter
  #   - Queue filter
  #   - DataGrid: Recording ID, Conversation ID, Duration, Created Date
  #   - Actions: Load, Download, View in Timeline
  
  # Tab 2: Transcripts
  #   - Conversation ID input
  #   - Display transcript in scrollable text area
  #   - Export to TXT
  
  # Tab 3: Quality Evaluations
  #   - Date range filter
  #   - Evaluator filter
  #   - DataGrid: Evaluation ID, Agent, Evaluator, Score, Status
  #   - Actions: Load, View Details, Export
}
```

---

### 3. Conversations::Abandon & Experience 🔴

**Priority**: Medium  
**Estimated Effort**: 6-8 hours  
**Status**: Not Implemented

**Purpose**: Analyze abandonment metrics and customer experience

**Core Functions Needed**:
```powershell
# Create new Core/Analytics.psm1 module

function Get-GcAbandonmentMetrics {
  <#
  .SYNOPSIS
    Query abandonment metrics using analytics aggregates API
  #>
  param(
    [Parameter(Mandatory)][DateTime]$StartTime,
    [Parameter(Mandatory)][DateTime]$EndTime,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
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
  
  # Calculate metrics
  $totalOffered = ($results.results | Measure-Object -Property nOffered -Sum).Sum
  $totalAbandoned = ($results.results | Measure-Object -Property nAbandon -Sum).Sum
  $abandonmentRate = if ($totalOffered -gt 0) { $totalAbandoned / $totalOffered } else { 0 }
  
  return @{
    abandonmentRate = $abandonmentRate
    totalOffered = $totalOffered
    totalAbandoned = $totalAbandoned
    avgWaitTime = ($results.results | Measure-Object -Property tWait -Average).Average
    avgHandleTime = ($results.results | Measure-Object -Property tHandle -Average).Average
    byQueue = $results.results
  }
}

function Search-GcAbandonedConversations {
  <#
  .SYNOPSIS
    Query conversations with abandoned outcome
  #>
  param(
    [Parameter(Mandatory)][DateTime]$StartTime,
    [Parameter(Mandatory)][DateTime]$EndTime,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [int]$MaxItems = 500
  )
  
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
  }
  
  Invoke-GcPagedRequest -Method POST -Path '/api/v2/analytics/conversations/details/query' `
    -Body $body -AccessToken $AccessToken -InstanceName $InstanceName -MaxItems $MaxItems
}

Export-ModuleMember -Function Get-GcAbandonmentMetrics, Search-GcAbandonedConversations
```

**View Implementation**:
```powershell
function New-AbandonExperienceView {
  # Create XAML with:
  # - Date range selector
  # - Summary cards: Abandonment Rate, Avg Wait Time, Avg Handle Time
  # - DataGrid: Abandoned conversations with Queue, Wait Time, Timestamp
  # - Export metrics to JSON/CSV
  
  # Use Start-AppJob to query metrics
  # Display results in summary cards and grid
}
```

---

### 4. Orchestration::Dependency / Impact Map 🔴

**Priority**: Medium  
**Estimated Effort**: 4-6 hours (simplified version)  
**Status**: Not Implemented

**Purpose**: Visualize configuration dependencies (simplified text-based search)

**Core Functions Needed**:
```powershell
# Create new Core/Dependencies.psm1 module

function Search-GcFlowReferences {
  <#
  .SYNOPSIS
    Search flows for references to a queue, data action, or other object
  #>
  param(
    [Parameter(Mandatory)][string]$ObjectId,
    [Parameter(Mandatory)][string]$ObjectType, # queue, dataAction, schedule
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName
  )
  
  # Get all flows
  $flows = Invoke-GcPagedRequest -Path '/api/v2/flows' -Method GET `
    -AccessToken $AccessToken -InstanceName $InstanceName
  
  # Search flow configurations for object ID
  $references = @()
  
  foreach ($flow in $flows) {
    # Get full flow configuration
    $flowDetail = Invoke-GcRequest -Method GET -Path "/api/v2/flows/$($flow.id)/latestconfiguration" `
      -AccessToken $AccessToken -InstanceName $InstanceName -ErrorAction SilentlyContinue
    
    if ($flowDetail) {
      $configJson = $flowDetail | ConvertTo-Json -Depth 20
      
      # Simple text search for object ID
      if ($configJson -like "*$ObjectId*") {
        $references += @{
          flowId = $flow.id
          flowName = $flow.name
          flowType = $flow.type
        }
      }
    }
  }
  
  return $references
}

Export-ModuleMember -Function Search-GcFlowReferences
```

**View Implementation**:
```powershell
function New-DependencyImpactMapView {
  # Create XAML with:
  # - Object type selector (Queue, Data Action, Schedule)
  # - Object ID or name input
  # - Search button
  # - Results grid showing flows that reference the object
  # - Export results to JSON
  
  # Simplified approach: text-based search through configurations
  # Future enhancement: Build full dependency graph
}
```

---

## Implementation Checklist

For each remaining module:

1. **Core Functions**:
   - [ ] Create/update core module file
   - [ ] Implement API integration functions
   - [ ] Add error handling
   - [ ] Export module members

2. **View Implementation**:
   - [ ] Create XAML layout following existing patterns
   - [ ] Implement event handlers
   - [ ] Wire to core functions via Start-AppJob
   - [ ] Add export functionality
   - [ ] Add search/filter capabilities

3. **Integration**:
   - [ ] Import core module in main app if new
   - [ ] Add switch case in Set-ContentForModule
   - [ ] Test navigation and functionality

4. **Testing**:
   - [ ] Run smoke tests
   - [ ] Test with real API (requires OAuth)
   - [ ] Verify export functionality
   - [ ] Check error handling

5. **Documentation**:
   - [ ] Update roadmap with completion status
   - [ ] Add usage examples
   - [ ] Document any limitations

---

## Notes for Future Implementation

### General Patterns to Follow

1. **Background Execution**: Always use `Start-AppJob` for long-running operations
2. **Module Imports**: Import required modules in runspace ScriptBlock
3. **Parameter Passing**: Pass AccessToken and InstanceName to runspace
4. **Error Handling**: Use try/catch with user-friendly error messages
5. **Export**: Support JSON and CSV export to artifacts directory
6. **Search**: Implement real-time filtering on loaded data

### Code Style

- Follow `Verb-GcNoun` naming convention
- Use consistent XAML structure with rounded borders and padding
- Color scheme: `#FFE5E7EB` borders, `#FFF9FAFB` alternating rows
- Button styles: Height="32" or "26", consistent widths
- DataGrid: `AutoGenerateColumns="False"`, `IsReadOnly="True"`

### Testing

- Run `./tests/smoke.ps1` after any changes
- Test OAuth flow with real credentials
- Verify exports create files in artifacts directory
- Check snackbar notifications appear correctly

---

## Priority Recommendation

Based on user value and implementation complexity:

1. **Routing Snapshot** (6-8 hours) - High operational value for monitoring
2. **Abandon & Experience** (6-8 hours) - Important for customer experience analysis
3. **Media & Quality** (8-10 hours) - Useful but more complex
4. **Dependency / Impact Map** (4-6 hours) - Nice-to-have for advanced users

**Total Remaining Effort**: 24-32 hours

---

## Current State

**What's Working**:
- All high/medium priority modules implemented
- Core infrastructure complete (Auth, JobRunner, Timeline, ArtifactGenerator)
- Conversation search, analytics jobs, incident packets all functional
- Configuration export for backup/migration
- User management and listing

**What's Next**:
- Implement 4 remaining lower-priority modules
- Add comprehensive test coverage
- Performance optimization for large datasets
- UI polish and accessibility improvements

---

**Last Updated**: 2026-01-13  
**Version**: v0.5.0  
**Status**: 56% Complete (5 of 9 modules)
