### BEGIN: Core.JobRunner.psm1

Set-StrictMode -Version Latest

# Job state tracking
$script:RunningJobs = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()

function New-GcJobContext {
  <#
  .SYNOPSIS
    Creates a new job context object for tracking job execution.
  
  .PARAMETER Name
    Human-readable job name
  
  .PARAMETER Type
    Job type category (e.g., 'Export', 'Subscription', 'Query')
  
  .OUTPUTS
    Job context object with observable logs collection
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Name,
    
    [string]$Type = 'General'
  )
  
  $jobId = [Guid]::NewGuid().ToString()
  
  # Create synchronized collections for cross-thread safety
  $logs = [System.Collections.ObjectModel.ObservableCollection[string]]::new()
  $syncLogs = [System.Collections.Specialized.INotifyCollectionChanged]$logs
  
  $job = [PSCustomObject]@{
    Id              = $jobId
    Name            = $Name
    Type            = $Type
    Status          = 'Queued'
    Progress        = 0
    Started         = $null
    Ended           = $null
    Logs            = $logs
    CanCancel       = $true
    CancellationRequested = $false
    Runspace        = $null
    PowerShell      = $null
    Result          = $null
    Errors          = @()
    ArtifactsCreated = @()
    Summary         = ''
  }
  
  return $job
}

function Add-GcJobLog {
  <#
  .SYNOPSIS
    Adds a log entry to a job's log collection (thread-safe).
  
  .PARAMETER Job
    Job context object
  
  .PARAMETER Message
    Log message
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Job,
    
    [Parameter(Mandatory)]
    [string]$Message
  )
  
  $timestamp = (Get-Date).ToString('HH:mm:ss')
  $logEntry = "[$timestamp] $Message"
  
  # Use dispatcher if available (WPF UI thread)
  if ($Job.Logs -is [System.Collections.ObjectModel.ObservableCollection[string]]) {
    try {
      $Job.Logs.Add($logEntry)
    } catch {
      # Fallback if we can't add directly
      Write-Verbose "Failed to add log directly: $_"
    }
  } else {
    $Job.Logs += $logEntry
  }

  # Also persist to a trace file when enabled (helps with OfflineDemo debugging).
  try {
    $traceEnabled = $false
    try {
      $v = [Environment]::GetEnvironmentVariable('GC_TOOLKIT_TRACE')
      if ($v -and ($v -match '^(1|true|yes|on)$')) { $traceEnabled = $true }
    } catch { $traceEnabled = $false }

    if (-not $traceEnabled) { return }

    $tsFile = (Get-Date).ToString('HH:mm:ss.fff')
    $jobName = ''
    try { $jobName = [string]$Job.Name } catch { $jobName = '' }
    $jobTag = if ($jobName) { "JOB:$jobName" } else { "JOB" }
    $line = ("[{0}] [{1}] {2}" -f $tsFile, $jobTag, $Message)

    $path = $null
    try { $path = [Environment]::GetEnvironmentVariable('GC_TOOLKIT_TRACE_LOG') } catch { $path = $null }
    if ($path) { Add-Content -LiteralPath $path -Value $line -Encoding utf8 }
  } catch { }
}

function Start-GcJob {
  <#
  .SYNOPSIS
    Starts a background job using PowerShell runspaces.
  
  .DESCRIPTION
    Executes a script block in a background runspace, streaming logs
    back to the job context. Supports cancellation and progress updates.
  
  .PARAMETER Job
    Job context object from New-GcJobContext
  
  .PARAMETER ScriptBlock
    Script block to execute
  
  .PARAMETER ArgumentList
    Arguments to pass to the script block
  
  .PARAMETER OnComplete
    Script block to execute when job completes (runs on UI thread)
  
  .EXAMPLE
    $job = New-GcJobContext -Name "Test Job"
    Start-GcJob -Job $job -ScriptBlock { param($name) Write-Output "Hello $name" } -ArgumentList @("World")
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Job,
    
    [Parameter(Mandatory)]
    [scriptblock]$ScriptBlock,
    
    [object[]]$ArgumentList = @(),
    
    [scriptblock]$OnComplete
  )
  
  # Mark job as running
  $Job.Status = 'Running'
  $Job.Started = Get-Date
  Add-GcJobLog -Job $Job -Message "Started ($($Job.Type))."
  
  # Create runspace
  $runspace = [runspacefactory]::CreateRunspace()
  $runspace.Open()
  
  # Create PowerShell instance
  $ps = [powershell]::Create()
  $ps.Runspace = $runspace
  
  # Add script block with arguments
  [void]$ps.AddScript($ScriptBlock)
  if ($ArgumentList) {
    foreach ($arg in $ArgumentList) {
      [void]$ps.AddArgument($arg)
    }
  }
  
  $Job.Runspace = $runspace
  $Job.PowerShell = $ps
  
  # Store in running jobs dictionary
  $script:RunningJobs[$Job.Id] = $Job
  
  # Begin async execution
  $asyncResult = $ps.BeginInvoke()
  
  # Monitor completion on a timer (WPF dispatcher timer if available)
  $hasDispatcher = $false
  try {
    # Only use DispatcherTimer when we're actually running under a WPF dispatcher context.
    # In non-UI contexts, Dispatcher.CurrentDispatcher will still create a dispatcher, but
    # without a message pump the timer never ticks and jobs never complete.
    $dispatcherTimerType = [Type]::GetType('System.Windows.Threading.DispatcherTimer, WindowsBase')
    $dispatcherSyncContextType = [Type]::GetType('System.Windows.Threading.DispatcherSynchronizationContext, WindowsBase')

    if ($dispatcherTimerType -and $dispatcherSyncContextType) {
      $syncContext = [System.Threading.SynchronizationContext]::Current
      if ($syncContext -and $dispatcherSyncContextType.IsInstanceOfType($syncContext)) {
        $hasDispatcher = $true
      }
    }
  } catch {
    # WPF not available, use fallback
    $hasDispatcher = $false
  }
  
  if ($hasDispatcher) {
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)

    # Capture values for the timer callback (event handlers don't reliably see local variables)
    $jobContext = $Job
    $asyncContext = $asyncResult
    $onCompleteContext = $OnComplete
    
    $timer.Add_Tick({
      param($sender, $args)

      $Job = $jobContext
      $asyncResult = $asyncContext
      $OnComplete = $onCompleteContext
      
      # Check for cancellation
      if ($Job.CancellationRequested -and $Job.Status -eq 'Running') {
        try {
          $Job.PowerShell.Stop()
          $Job.Status = 'Canceled'
          Add-GcJobLog -Job $Job -Message "Canceled by user."
          $Job.Ended = Get-Date
          $Job.CanCancel = $false
          $sender.Stop()
          
          # Cleanup
          $Job.PowerShell.Dispose()
          $Job.Runspace.Close()
          $script:RunningJobs.TryRemove($Job.Id, [ref]$null) | Out-Null
          
          return
        } catch {
          Add-GcJobLog -Job $Job -Message "Error during cancellation: $_"
        }
      }
      
      # Check if completed
      if ($asyncResult.IsCompleted) {
        $sender.Stop()
        
        try {
          # Get results
          $Job.Result = $Job.PowerShell.EndInvoke($asyncResult)

          # Capture job output strings as log lines (many jobs use Write-Output for tracing).
          try {
            $out = @($Job.Result)
            $stringOut = @($out | Where-Object { $_ -is [string] })
            $nonStringOut = @($out | Where-Object { $null -ne $_ -and $_ -isnot [string] })
            if ($stringOut.Count -gt 0) {
              $max = 250
              $emit = $stringOut | Select-Object -First $max
              foreach ($line in $emit) { Add-GcJobLog -Job $Job -Message $line }
              if ($stringOut.Count -gt $max) {
                Add-GcJobLog -Job $Job -Message ("(output truncated: {0} lines; showing first {1})" -f $stringOut.Count, $max)
              }
            }
            # If the pipeline produced progress strings plus a single structured result, keep the object as Job.Result.
            if ($nonStringOut.Count -eq 1 -and ($stringOut.Count -gt 0)) {
              $Job.Result = $nonStringOut[0]
            }
          } catch { }

          # Capture verbose/information streams when toolkit tracing is enabled.
          $traceEnabled = $false
          try {
            $v = [Environment]::GetEnvironmentVariable('GC_TOOLKIT_TRACE')
            if ($v -and ($v -match '^(1|true|yes|on)$')) { $traceEnabled = $true }
          } catch { $traceEnabled = $false }

          if ($traceEnabled) {
            try {
              if ($Job.PowerShell.Streams.Verbose.Count -gt 0) {
                foreach ($v in $Job.PowerShell.Streams.Verbose) { Add-GcJobLog -Job $Job -Message ("VERBOSE: {0}" -f $v) }
              }
              if ($Job.PowerShell.Streams.Information.Count -gt 0) {
                foreach ($i in $Job.PowerShell.Streams.Information) {
                  $msg = $null
                  try { $msg = [string]$i.MessageData } catch { $msg = $i.ToString() }
                  Add-GcJobLog -Job $Job -Message ("INFO: {0}" -f $msg)
                }
              }
            } catch { }
          }
          
          # Check for errors
          if ($Job.PowerShell.Streams.Error.Count -gt 0) {
            foreach ($err in $Job.PowerShell.Streams.Error) {
              $Job.Errors += $err.ToString()
              Add-GcJobLog -Job $Job -Message "ERROR: $err"
            }
          }
          
          # Check for warnings
          if ($Job.PowerShell.Streams.Warning.Count -gt 0) {
            foreach ($warn in $Job.PowerShell.Streams.Warning) {
              Add-GcJobLog -Job $Job -Message "WARNING: $warn"
            }
          }
          
          # Mark complete
          $Job.Status = 'Completed'
          $Job.Progress = 100
          $Job.Ended = Get-Date
          $Job.CanCancel = $false
          Add-GcJobLog -Job $Job -Message "Completed."
          
          # Execute completion callback
          if ($OnComplete) {
            try {
              & $OnComplete $Job
            } catch {
              Add-GcJobLog -Job $Job -Message "Error in completion handler: $_"
            }
          }
          
        } catch {
          $Job.Status = 'Failed'
          $Job.Errors += $_.ToString()
          Add-GcJobLog -Job $Job -Message "Failed: $_"
          $Job.Ended = Get-Date
          $Job.CanCancel = $false
        } finally {
          # Cleanup
          $Job.PowerShell.Dispose()
          $Job.Runspace.Close()
          $script:RunningJobs.TryRemove($Job.Id, [ref]$null) | Out-Null
        }
      }
    }.GetNewClosure())
    
    $timer.Start()
  } else {
    # Fallback: block until complete (non-UI scenarios)
    try {
      $Job.Result = $ps.EndInvoke($asyncResult)

      # Capture job output strings as log lines (many jobs use Write-Output for tracing).
      try {
        $out = @($Job.Result)
        $stringOut = @($out | Where-Object { $_ -is [string] })
        $nonStringOut = @($out | Where-Object { $null -ne $_ -and $_ -isnot [string] })
        if ($stringOut.Count -gt 0) {
          $max = 250
          $emit = $stringOut | Select-Object -First $max
          foreach ($line in $emit) { Add-GcJobLog -Job $Job -Message $line }
          if ($stringOut.Count -gt $max) {
            Add-GcJobLog -Job $Job -Message ("(output truncated: {0} lines; showing first {1})" -f $stringOut.Count, $max)
          }
        }
        # If the pipeline produced progress strings plus a single structured result, keep the object as Job.Result.
        if ($nonStringOut.Count -eq 1 -and ($stringOut.Count -gt 0)) {
          $Job.Result = $nonStringOut[0]
        }
      } catch { }

      $traceEnabled = $false
      try {
        $v = [Environment]::GetEnvironmentVariable('GC_TOOLKIT_TRACE')
        if ($v -and ($v -match '^(1|true|yes|on)$')) { $traceEnabled = $true }
      } catch { $traceEnabled = $false }

      if ($traceEnabled) {
        try {
          if ($ps.Streams.Verbose.Count -gt 0) {
            foreach ($v in $ps.Streams.Verbose) { Add-GcJobLog -Job $Job -Message ("VERBOSE: {0}" -f $v) }
          }
          if ($ps.Streams.Information.Count -gt 0) {
            foreach ($i in $ps.Streams.Information) {
              $msg = $null
              try { $msg = [string]$i.MessageData } catch { $msg = $i.ToString() }
              Add-GcJobLog -Job $Job -Message ("INFO: {0}" -f $msg)
            }
          }
        } catch { }
      }
      
      # Check for errors
      if ($ps.Streams.Error.Count -gt 0) {
        foreach ($err in $ps.Streams.Error) {
          $Job.Errors += $err.ToString()
          Add-GcJobLog -Job $Job -Message "ERROR: $err"
        }
      }
      
      # Check for warnings
      if ($ps.Streams.Warning.Count -gt 0) {
        foreach ($warn in $ps.Streams.Warning) {
          Add-GcJobLog -Job $Job -Message "WARNING: $warn"
        }
      }
      
      $Job.Status = 'Completed'
      $Job.Progress = 100
      $Job.Ended = Get-Date
      Add-GcJobLog -Job $Job -Message "Completed."
      
      if ($OnComplete) {
        & $OnComplete $Job
      }
    } catch {
      $Job.Status = 'Failed'
      $Job.Errors += $_.ToString()
      Add-GcJobLog -Job $Job -Message "Failed: $_"
      $Job.Ended = Get-Date
    } finally {
      $ps.Dispose()
      $runspace.Close()
      $script:RunningJobs.TryRemove($Job.Id, [ref]$null) | Out-Null
    }
  }
}

function Stop-GcJob {
  <#
  .SYNOPSIS
    Requests cancellation of a running job.
  
  .PARAMETER Job
    Job context object
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Job
  )
  
  if ($Job.Status -eq 'Running' -and $Job.CanCancel) {
    $Job.CancellationRequested = $true
    Add-GcJobLog -Job $Job -Message "Cancellation requested..."
  }
}

function Get-GcRunningJobs {
  <#
  .SYNOPSIS
    Returns all currently running jobs.
  #>
  [CmdletBinding()]
  param()
  
  $values = $script:RunningJobs.Values
  if ($null -eq $values) {
    return @()
  }
  return $values
}

Export-ModuleMember -Function New-GcJobContext, Add-GcJobLog, Start-GcJob, Stop-GcJob, Get-GcRunningJobs

### END: Core.JobRunner.psm1
