### BEGIN: Core.Subscriptions.psm1

Set-StrictMode -Version Latest

# Subscription state
$script:ActiveSubscription = $null
$script:EventBuffer = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

function New-GcSubscriptionProvider {
  <#
  .SYNOPSIS
    Creates a new subscription provider for Genesys Cloud notifications.
  
  .DESCRIPTION
    Abstraction for subscription providers. Currently supports
    Genesys Cloud Notifications WebSocket API.
  
  .PARAMETER Region
    Genesys Cloud region
  
  .PARAMETER AccessToken
    OAuth access token
  
  .OUTPUTS
    Subscription provider object
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Region,
    
    [Parameter(Mandatory)]
    [string]$AccessToken
  )
  
  $provider = [PSCustomObject]@{
    Type          = 'GenesysNotifications'
    Region        = $Region
    AccessToken   = $AccessToken
    ChannelId     = $null
    WebSocket     = $null
    IsConnected   = $false
    Subscriptions = @()
    OnEvent       = $null
    OnError       = $null
    ReceiveTask   = $null
  }
  
  return $provider
}

function Connect-GcSubscriptionProvider {
  <#
  .SYNOPSIS
    Connects the subscription provider and creates a notification channel.
  
  .PARAMETER Provider
    Subscription provider object
  
  .OUTPUTS
    $true if connected successfully
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Provider
  )
  
  try {
    # Create notification channel
    $uri = "https://api.$($Provider.Region)/api/v2/notifications/channels"
    $headers = @{
      'Authorization' = "Bearer $($Provider.AccessToken)"
      'Content-Type'  = 'application/json'
    }
    
    Write-Verbose "Creating notification channel..."
    $channel = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers
    
    $Provider.ChannelId = $channel.id
    $wsUri = $channel.connectUri
    
    Write-Verbose "Channel ID: $($Provider.ChannelId)"
    Write-Verbose "WebSocket URI: $wsUri"
    
    # Connect WebSocket
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.SetRequestHeader('Authorization', "Bearer $($Provider.AccessToken)")
    
    $cts = New-Object System.Threading.CancellationTokenSource
    $connectTask = $ws.ConnectAsync([Uri]$wsUri, $cts.Token)
    
    # Wait for connection (with timeout)
    $timeout = [TimeSpan]::FromSeconds(30)
    if (-not $connectTask.Wait($timeout)) {
      throw "WebSocket connection timed out after 30 seconds"
    }
    
    $Provider.WebSocket = $ws
    $Provider.IsConnected = $true
    
    Write-Verbose "WebSocket connected successfully"
    
    return $true
    
  } catch {
    Write-Error "Failed to connect subscription provider: $_"
    $Provider.IsConnected = $false
    return $false
  }
}

function Add-GcSubscription {
  <#
  .SYNOPSIS
    Adds a topic subscription to the notification channel.
  
  .PARAMETER Provider
    Subscription provider object
  
  .PARAMETER Topics
    Array of topic strings to subscribe to
  
  .OUTPUTS
    $true if subscription successful
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Provider,
    
    [Parameter(Mandatory)]
    [string[]]$Topics
  )
  
  if (-not $Provider.IsConnected -or -not $Provider.ChannelId) {
    Write-Error "Provider not connected. Call Connect-GcSubscriptionProvider first."
    return $false
  }
  
  try {
    # Create subscriptions
    $uri = "https://api.$($Provider.Region)/api/v2/notifications/channels/$($Provider.ChannelId)/subscriptions"
    $headers = @{
      'Authorization' = "Bearer $($Provider.AccessToken)"
      'Content-Type'  = 'application/json'
    }
    
    $body = @($Topics | ForEach-Object { @{ id = $_ } }) | ConvertTo-Json -Depth 3
    
    Write-Verbose "Creating subscriptions for topics: $($Topics -join ', ')"
    $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body
    
    $Provider.Subscriptions += $Topics
    
    Write-Verbose "Subscriptions created successfully"
    return $true
    
  } catch {
    Write-Error "Failed to add subscriptions: $_"
    return $false
  }
}

function Start-GcSubscriptionReceive {
  <#
  .SYNOPSIS
    Starts receiving events from the WebSocket in a background task.
  
  .PARAMETER Provider
    Subscription provider object
  
  .PARAMETER OnEvent
    Script block to call when an event is received
  
  .PARAMETER OnError
    Script block to call when an error occurs
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Provider,
    
    [scriptblock]$OnEvent,
    
    [scriptblock]$OnError
  )
  
  if (-not $Provider.IsConnected) {
    Write-Error "Provider not connected."
    return
  }
  
  $Provider.OnEvent = $OnEvent
  $Provider.OnError = $OnError
  
  # Start receive loop in background runspace
  $receiveScript = {
    param($ws, $onEvent, $onError, $eventBuffer)
    
    $buffer = New-Object byte[] 4096
    $segment = [ArraySegment[byte]]::new($buffer)
    
    try {
      while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $result = $null
        $message = ""
        
        # Receive message (potentially in multiple chunks)
        do {
          $cts = New-Object System.Threading.CancellationTokenSource
          $cts.CancelAfter(1000)  # 1 second timeout per chunk
          
          try {
            $receiveTask = $ws.ReceiveAsync($segment, $cts.Token)
            $receiveTask.Wait() | Out-Null
            $result = $receiveTask.Result
            
            $chunk = [Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
            $message += $chunk
          } catch [System.OperationCanceledException] {
            # Timeout - check if we should continue
            if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
              break
            }
            continue
          }
          
        } while (-not $result.EndOfMessage)
        
        if ($message) {
          # Parse and queue event
          try {
            $eventObj = $message | ConvertFrom-Json
            $eventBuffer.Enqueue($eventObj)
          } catch {
            if ($onError) {
              & $onError "Failed to parse event: $_"
            }
          }
        }
      }
    } catch {
      if ($onError) {
        & $onError "Error in receive loop: $_"
      }
    }
  }
  
  # Start background task
  $runspace = [runspacefactory]::CreateRunspace()
  $runspace.Open()
  
  $ps = [powershell]::Create()
  $ps.Runspace = $runspace
  [void]$ps.AddScript($receiveScript)
  [void]$ps.AddArgument($Provider.WebSocket)
  [void]$ps.AddArgument($Provider.OnEvent)
  [void]$ps.AddArgument($Provider.OnError)
  [void]$ps.AddArgument($script:EventBuffer)
  
  $Provider.ReceiveTask = $ps.BeginInvoke()
}

function Get-GcSubscriptionEvents {
  <#
  .SYNOPSIS
    Retrieves queued events from the event buffer.
  
  .OUTPUTS
    Array of event objects
  #>
  [CmdletBinding()]
  param()
  
  $events = @()
  $event = $null
  
  while ($script:EventBuffer.TryDequeue([ref]$event)) {
    $events += $event
  }
  
  return $events
}

function Disconnect-GcSubscriptionProvider {
  <#
  .SYNOPSIS
    Disconnects the subscription provider and cleans up resources.
  
  .PARAMETER Provider
    Subscription provider object
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Provider
  )
  
  try {
    if ($Provider.WebSocket -and $Provider.WebSocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      $cts = New-Object System.Threading.CancellationTokenSource
      $cts.CancelAfter(5000)
      
      $closeTask = $Provider.WebSocket.CloseAsync(
        [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
        "Client disconnect",
        $cts.Token
      )
      
      $closeTask.Wait() | Out-Null
    }
    
    if ($Provider.WebSocket) {
      $Provider.WebSocket.Dispose()
    }
    
    $Provider.IsConnected = $false
    $Provider.Subscriptions = @()
    
  } catch {
    Write-Warning "Error during disconnect: $_"
  }
}

function Get-GcTopicCatalog {
  <#
  .SYNOPSIS
    Returns the topic catalog for mapping UI selections to topic strings.
  
  .DESCRIPTION
    Returns a catalog of available notification topics. This can be
    customized or loaded from a JSON file in production.
  
  .OUTPUTS
    Hashtable of topic categories and their topic strings
  #>
  [CmdletBinding()]
  param()
  
  return @{
    'AudioHook.Transcription' = @(
      'v2.conversations.{id}.audioHook.transcription'
    )
    'AgentAssist' = @(
      'v2.conversations.{id}.agentAssist'
    )
    'Errors' = @(
      'v2.system.errors'
    )
    'Conversations' = @(
      'v2.conversations.{id}'
    )
    'Users' = @(
      'v2.users.{id}'
    )
    'Queue' = @(
      'v2.routing.queues.{id}.conversations'
    )
  }
}

function Resolve-GcTopicWithId {
  <#
  .SYNOPSIS
    Resolves a topic template by replacing {id} with actual ID.
  
  .PARAMETER TopicTemplate
    Topic string with {id} placeholder
  
  .PARAMETER Id
    ID to substitute (conversationId, queueId, userId, etc.)
  
  .OUTPUTS
    Resolved topic string
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$TopicTemplate,
    
    [string]$Id = '*'
  )
  
  return $TopicTemplate -replace '\{id\}', $Id
}

Export-ModuleMember -Function New-GcSubscriptionProvider, Connect-GcSubscriptionProvider, `
  Add-GcSubscription, Start-GcSubscriptionReceive, Get-GcSubscriptionEvents, `
  Disconnect-GcSubscriptionProvider, Get-GcTopicCatalog, Resolve-GcTopicWithId

### END: Core.Subscriptions.psm1
