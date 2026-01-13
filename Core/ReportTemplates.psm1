### BEGIN FILE: Core/ReportTemplates.psm1

Set-StrictMode -Version Latest

<#
.SYNOPSIS
  Report template definitions for AGenesysToolKit.

.DESCRIPTION
  Provides built-in report templates that leverage Core/Reporting.psm1:
  1. Conversation Inspect Packet - Enhanced conversation export with HTML report
  2. Errors & Failures Snapshot - Cross-cutting error analysis
  3. Subscription Session Summary - Live subscription session export
#>

# Import dependencies
$reportingModule = Join-Path -Path $PSScriptRoot -ChildPath 'Reporting.psm1'
if (-not (Get-Command -Name New-GcArtifactBundle -ErrorAction SilentlyContinue)) {
  Import-Module $reportingModule -Force
}

function Get-GcReportTemplates {
  <#
  .SYNOPSIS
    Returns available report templates.
  
  .DESCRIPTION
    Returns an array of report template definitions with:
    - Name: Template display name
    - Description: What the template exports
    - Parameters: Required parameters schema
    - InvokeScript: ScriptBlock that returns @{ Rows; Summary; Warnings }
  
  .OUTPUTS
    Array of report template objects
  
  .EXAMPLE
    $templates = Get-GcReportTemplates
    $template = $templates | Where-Object { $_.Name -eq 'Conversation Inspect Packet' }
  #>
  [CmdletBinding()]
  [OutputType([array])]
  param()
  
  return @(
    [PSCustomObject]@{
      Name = 'Conversation Inspect Packet'
      Description = 'Complete conversation export with timeline, events, and analytics'
      Parameters = @{
        ConversationId = @{ Type = 'String'; Required = $true; Description = 'Conversation ID to inspect' }
        Region = @{ Type = 'String'; Required = $true; Description = 'Genesys Cloud region' }
        AccessToken = @{ Type = 'String'; Required = $true; Description = 'OAuth access token' }
        SubscriptionEvents = @{ Type = 'Array'; Required = $false; Description = 'Optional subscription events' }
      }
      InvokeScript = ${function:Invoke-ConversationInspectPacketReport}
    },
    
    [PSCustomObject]@{
      Name = 'Errors & Failures Snapshot'
      Description = 'Cross-cutting error analysis from jobs, subscriptions, and API calls'
      Parameters = @{
        Jobs = @{ Type = 'Array'; Required = $false; Description = 'App job collection' }
        SubscriptionErrors = @{ Type = 'Array'; Required = $false; Description = 'Subscription error events' }
        Since = @{ Type = 'DateTime'; Required = $false; Description = 'Only include errors since this time' }
      }
      InvokeScript = ${function:Invoke-ErrorsFailuresSnapshotReport}
    },
    
    [PSCustomObject]@{
      Name = 'Subscription Session Summary'
      Description = 'Live subscription session export with message counts and sample payloads'
      Parameters = @{
        SessionStart = @{ Type = 'DateTime'; Required = $true; Description = 'Session start time' }
        Topics = @{ Type = 'Array'; Required = $true; Description = 'Subscribed topics' }
        Events = @{ Type = 'Array'; Required = $true; Description = 'Collected events' }
        Disconnects = @{ Type = 'Int'; Required = $false; Description = 'Disconnect count' }
      }
      InvokeScript = ${function:Invoke-SubscriptionSessionSummaryReport}
    }
  )
}

function Invoke-ConversationInspectPacketReport {
  <#
  .SYNOPSIS
    Executes the Conversation Inspect Packet report.
  
  .DESCRIPTION
    Fetches conversation data, builds timeline, and returns structured report data.
    This extends the existing Export-GcConversationPacket with report format.
  
  .PARAMETER ConversationId
    Conversation ID
  
  .PARAMETER Region
    Genesys Cloud region
  
  .PARAMETER AccessToken
    OAuth access token
  
  .PARAMETER SubscriptionEvents
    Optional subscription events
  
  .OUTPUTS
    Hashtable with Rows, Summary, and Warnings
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ConversationId,
    
    [Parameter(Mandatory)]
    [string]$Region,
    
    [Parameter(Mandatory)]
    [string]$AccessToken,
    
    [object[]]$SubscriptionEvents = @()
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
  
  $warnings = @()
  $rows = @()
  $summary = [ordered]@{}
  
  try {
    Write-Output "Querying analytics for conversation $ConversationId..."
    
    # Build analytics query
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
    $jobResponse = Invoke-GcRequest `
      -Method POST `
      -Path '/api/v2/analytics/conversations/details/jobs' `
      -Body $queryBody `
      -InstanceName $Region `
      -AccessToken $AccessToken
    
    $jobId = $jobResponse.id
    if (-not $jobId) { throw "No job ID returned from analytics API." }
    
    Write-Output "Job submitted: $jobId. Polling for completion..."
    
    # Poll for completion
    $maxAttempts = 120
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
        break
      }
      
      if ($status.state -match 'FAILED|ERROR') {
        throw "Analytics job failed: $($status.state)"
      }
    }
    
    if (-not $completed) {
      throw "Analytics job timed out after $maxAttempts attempts."
    }
    
    # Fetch results
    $results = Invoke-GcRequest `
      -Method GET `
      -Path "/api/v2/analytics/conversations/details/jobs/$jobId/results" `
      -InstanceName $Region `
      -AccessToken $AccessToken
    
    if (-not $results.conversations -or $results.conversations.Count -eq 0) {
      $warnings += "No conversation data returned from analytics API."
      $summary['Status'] = 'No Data'
      return @{ Rows = @(); Summary = $summary; Warnings = $warnings }
    }
    
    $conversation = $results.conversations[0]
    
    # Build summary
    $summary['ConversationId'] = $ConversationId
    $summary['Region'] = $Region
    
    if ($conversation.conversationStart) {
      $summary['StartTime'] = $conversation.conversationStart
    }
    if ($conversation.conversationEnd) {
      $summary['EndTime'] = $conversation.conversationEnd
      
      # Calculate duration
      if ($conversation.conversationStart) {
        try {
          $start = [datetime]::Parse($conversation.conversationStart)
          $end = [datetime]::Parse($conversation.conversationEnd)
          $duration = $end - $start
          $summary['Duration'] = "$([int]$duration.TotalSeconds)s"
        } catch {
          $warnings += "Failed to calculate duration: $_"
        }
      }
    }
    
    if ($conversation.participants) {
      $summary['ParticipantCount'] = $conversation.participants.Count
    }
    
    # Build timeline
    Write-Output "Building timeline..."
    $timeline = ConvertTo-GcTimeline -ConversationData $conversation
    $summary['TimelineEventCount'] = $timeline.Count
    
    # Process subscription events
    $relevantSubEvents = @()
    if ($SubscriptionEvents -and $SubscriptionEvents.Count -gt 0) {
      $relevantSubEvents = @($SubscriptionEvents | Where-Object { 
        $_.conversationId -eq $ConversationId 
      })
      if ($relevantSubEvents.Count -eq 0) {
        $relevantSubEvents = @($SubscriptionEvents)
      }
    }
    $summary['SubscriptionEventCount'] = $relevantSubEvents.Count
    
    # Check for errors
    $errorEvents = @($relevantSubEvents | Where-Object { 
      $_.severity -eq 'error' -or $_.topic -like '*error*' 
    })
    if ($errorEvents.Count -gt 0) {
      $summary['ErrorCount'] = $errorEvents.Count
      $warnings += "$($errorEvents.Count) error events detected in subscription stream."
    }
    
    # Build rows (timeline events)
    $rows = $timeline | ForEach-Object {
      [PSCustomObject]@{
        Time = $_.Time.ToString('yyyy-MM-dd HH:mm:ss.fff')
        Category = $_.Category
        Label = $_.Label
        Details = ($_.Details | ConvertTo-Json -Compress -Depth 5)
      }
    }
    
    $summary['Status'] = 'OK'
    
  } catch {
    $warnings += "Error executing report: $_"
    $summary['Status'] = 'Failed'
  }
  
  return @{
    Rows = $rows
    Summary = $summary
    Warnings = $warnings
  }
}

function Invoke-ErrorsFailuresSnapshotReport {
  <#
  .SYNOPSIS
    Executes the Errors & Failures Snapshot report.
  
  .DESCRIPTION
    Gathers errors from jobs, subscriptions, and other sources.
  
  .PARAMETER Jobs
    App job collection
  
  .PARAMETER SubscriptionErrors
    Subscription error events
  
  .PARAMETER Since
    Filter to errors since this time
  
  .OUTPUTS
    Hashtable with Rows, Summary, and Warnings
  #>
  [CmdletBinding()]
  param(
    [object[]]$Jobs = @(),
    [object[]]$SubscriptionErrors = @(),
    [datetime]$Since = [datetime]::MinValue
  )
  
  $warnings = @()
  $rows = @()
  $summary = [ordered]@{}
  
  try {
    # Process failed jobs
    $failedJobs = @($Jobs | Where-Object { 
      $_.Status -eq 'Failed' -or $_.Status -eq 'Error'
    })
    
    foreach ($job in $failedJobs) {
      $timestamp = if ($job.Ended) { $job.Ended } else { Get-Date }
      
      if ($timestamp -lt $Since) { continue }
      
      $errorMsg = ''
      if ($job.Errors -and $job.Errors.Count -gt 0) {
        $errorMsg = ($job.Errors -join ' | ')
      } else {
        $errorMsg = 'Job failed (no error details)'
      }
      
      $rows += [PSCustomObject]@{
        Timestamp = $timestamp.ToString('yyyy-MM-dd HH:mm:ss')
        Source = 'Job'
        Category = $job.Type
        Name = $job.Name
        Error = $errorMsg
      }
    }
    
    # Process subscription errors
    foreach ($event in $SubscriptionErrors) {
      $timestamp = if ($event.ts) { 
        if ($event.ts -is [datetime]) { $event.ts } 
        else { 
          try { [datetime]::Parse($event.ts) } 
          catch { Get-Date } 
        }
      } else { Get-Date }
      
      if ($timestamp -lt $Since) { continue }
      
      $rows += [PSCustomObject]@{
        Timestamp = $timestamp.ToString('yyyy-MM-dd HH:mm:ss')
        Source = 'Subscription'
        Category = if ($event.topic) { $event.topic } else { 'Unknown' }
        Name = if ($event.conversationId) { $event.conversationId } else { 'N/A' }
        Error = if ($event.text) { $event.text } else { 'Error event (no details)' }
      }
    }
    
    # Build summary
    $summary['ReportGenerated'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $summary['Since'] = $Since.ToString('yyyy-MM-dd HH:mm:ss')
    $summary['TotalErrors'] = $rows.Count
    $summary['FailedJobs'] = $failedJobs.Count
    $summary['SubscriptionErrors'] = $SubscriptionErrors.Count
    $summary['Status'] = 'OK'
    
    if ($rows.Count -eq 0) {
      $warnings += "No errors found in the specified timeframe."
    }
    
  } catch {
    $warnings += "Error executing report: $_"
    $summary['Status'] = 'Failed'
  }
  
  return @{
    Rows = $rows
    Summary = $summary
    Warnings = $warnings
  }
}

function Invoke-SubscriptionSessionSummaryReport {
  <#
  .SYNOPSIS
    Executes the Subscription Session Summary report.
  
  .DESCRIPTION
    Summarizes a live subscription session with message counts and samples.
  
  .PARAMETER SessionStart
    Session start time
  
  .PARAMETER Topics
    Subscribed topics
  
  .PARAMETER Events
    Collected events
  
  .PARAMETER Disconnects
    Disconnect count
  
  .OUTPUTS
    Hashtable with Rows, Summary, and Warnings
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [datetime]$SessionStart,
    
    [Parameter(Mandatory)]
    [string[]]$Topics,
    
    [Parameter(Mandatory)]
    [object[]]$Events,
    
    [int]$Disconnects = 0
  )
  
  $warnings = @()
  $rows = @()
  $summary = [ordered]@{}
  
  try {
    $sessionEnd = Get-Date
    $duration = $sessionEnd - $SessionStart
    
    # Build summary
    $summary['SessionStart'] = $SessionStart.ToString('yyyy-MM-dd HH:mm:ss')
    $summary['SessionEnd'] = $sessionEnd.ToString('yyyy-MM-dd HH:mm:ss')
    $summary['Duration'] = "$([int]$duration.TotalSeconds)s"
    $summary['Topics'] = ($Topics -join ', ')
    $summary['TotalEvents'] = $Events.Count
    $summary['Disconnects'] = $Disconnects
    
    # Group events by topic
    $topicGroups = $Events | Group-Object -Property topic
    
    foreach ($group in $topicGroups) {
      $topicName = if ($group.Name) { $group.Name } else { 'Unknown' }
      $count = $group.Count
      
      # Get sample event (first in group)
      $sample = $group.Group[0]
      $sampleText = if ($sample.text) { 
        $sample.text.Substring(0, [Math]::Min(100, $sample.text.Length)) 
      } else { '(no text)' }
      
      $rows += [PSCustomObject]@{
        Topic = $topicName
        EventCount = $count
        SampleTimestamp = if ($sample.ts) { $sample.ts.ToString() } else { 'N/A' }
        SampleText = $sampleText
      }
    }
    
    # Check for warnings
    if ($Disconnects -gt 0) {
      $warnings += "$Disconnects disconnects occurred during the session."
    }
    
    if ($Events.Count -eq 0) {
      $warnings += "No events collected during the session."
    }
    
    $summary['Status'] = 'OK'
    
  } catch {
    $warnings += "Error executing report: $_"
    $summary['Status'] = 'Failed'
  }
  
  return @{
    Rows = $rows
    Summary = $summary
    Warnings = $warnings
  }
}

function Invoke-GcReportTemplate {
  <#
  .SYNOPSIS
    Executes a report template and generates artifact bundle.
  
  .DESCRIPTION
    High-level function that:
    1. Validates template and parameters
    2. Executes template InvokeScript
    3. Creates artifact bundle with HTML + CSV + JSON + metadata
    4. Updates artifact index
  
  .PARAMETER TemplateName
    Name of the template to execute
  
  .PARAMETER Parameters
    Hashtable of parameters to pass to the template
  
  .PARAMETER OutputDirectory
    Base output directory (defaults to App/artifacts)
  
  .OUTPUTS
    PSCustomObject with artifact bundle info
  
  .EXAMPLE
    $result = Invoke-GcReportTemplate -TemplateName 'Conversation Inspect Packet' -Parameters @{ ConversationId = 'c-123'; Region = 'usw2.pure.cloud'; AccessToken = $token }
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$TemplateName,
    
    [Parameter(Mandatory)]
    [hashtable]$Parameters,
    
    [string]$OutputDirectory
  )
  
  # Find template
  $templates = Get-GcReportTemplates
  $template = $templates | Where-Object { $_.Name -eq $TemplateName }
  
  if (-not $template) {
    throw "Report template '$TemplateName' not found. Available templates: $($templates.Name -join ', ')"
  }
  
  # Execute template
  Write-Output "Executing report template: $TemplateName"
  $reportData = & $template.InvokeScript @Parameters
  
  if (-not $reportData) {
    throw "Template execution returned no data."
  }
  
  # Create artifact bundle
  $runId = New-GcReportRunId
  $metadata = [ordered]@{
    TemplateName = $TemplateName
    Parameters = $Parameters
    Region = if ($Parameters.Region) { $Parameters.Region } else { 'N/A' }
    RowCount = if ($reportData.Rows) { $reportData.Rows.Count } else { 0 }
    Status = if ($reportData.Summary.Status) { $reportData.Summary.Status } else { 'Unknown' }
    Warnings = if ($reportData.Warnings) { $reportData.Warnings } else { @() }
  }
  
  $bundle = New-GcArtifactBundle `
    -ReportName $TemplateName `
    -OutputDirectory $OutputDirectory `
    -RunId $runId `
    -Metadata $metadata
  
  # Write HTML report
  Write-GcReportHtml `
    -Path $bundle.ReportHtmlPath `
    -Title $TemplateName `
    -Summary $reportData.Summary `
    -Rows $reportData.Rows `
    -Warnings $reportData.Warnings
  
  # Write data artifacts
  $artifactResults = Write-GcDataArtifacts `
    -Rows $reportData.Rows `
    -JsonPath $bundle.DataJsonPath `
    -CsvPath $bundle.DataCsvPath `
    -XlsxPath $bundle.DataXlsxPath `
    -CreateXlsx $true
  
  # Update metadata with artifact creation results
  $metadataContent = Get-Content -Path $bundle.MetadataPath -Raw | ConvertFrom-Json
  $metadataContent.Status = if ($reportData.Warnings.Count -gt 0) { 'Warnings' } else { 'OK' }
  $metadataContent.ArtifactsCreated = @{
    Html = $true
    Json = $artifactResults.JsonCreated
    Csv = $artifactResults.CsvCreated
    Xlsx = $artifactResults.XlsxCreated
  }
  if ($artifactResults.XlsxSkippedReason) {
    $metadataContent.XlsxSkippedReason = $artifactResults.XlsxSkippedReason
  }
  
  $metadataContent | ConvertTo-Json -Depth 10 | Set-Content -Path $bundle.MetadataPath -Encoding UTF8
  
  # Update artifact index
  Update-GcArtifactIndex -Entry @{
    ReportName = $TemplateName
    RunId = $runId
    Timestamp = (Get-Date -Format o)
    BundlePath = $bundle.BundlePath
    RowCount = $reportData.Rows.Count
    Status = if ($reportData.Warnings.Count -gt 0) { 'Warnings' } else { 'OK' }
    Warnings = $reportData.Warnings
  }
  
  Write-Output "Report complete: $($bundle.BundlePath)"
  
  return $bundle
}

# Export functions
Export-ModuleMember -Function @(
  'Get-GcReportTemplates',
  'Invoke-ConversationInspectPacketReport',
  'Invoke-ErrorsFailuresSnapshotReport',
  'Invoke-SubscriptionSessionSummaryReport',
  'Invoke-GcReportTemplate'
)

### END FILE: Core/ReportTemplates.psm1
