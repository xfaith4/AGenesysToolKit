### BEGIN: Core.SampleData.psm1

Set-StrictMode -Version Latest

$script:SampleDataset = $null
$script:AnalyticsConversationJobs = @{}
$script:GeneratedConversationCount = 0

function AddOrGet-GcSampleConversation {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ConversationId
  )

  $dataset = Get-GcSampleDataset

  $existing = @($dataset.analytics.conversations | Where-Object { $_.conversationId -eq $ConversationId -or $_.id -eq $ConversationId } | Select-Object -First 1)
  if ($existing -and $existing.Count -gt 0) { return $existing[0] }

  # Create a deterministic-but-reasonable conversation for arbitrary IDs (keeps timeline view consistent)
  $script:GeneratedConversationCount++
  $seedSeconds = [Math]::Abs($ConversationId.GetHashCode()) % 1800
  $startUtc = (Get-Date).ToUniversalTime().AddMinutes(-30).AddSeconds($seedSeconds)

  # Alternate queues a bit
  $queueId = if (($script:GeneratedConversationCount % 2) -eq 0) { 'q-demo-support-voice' } else { 'q-demo-billing' }
  $queueName = if ($queueId -eq 'q-demo-support-voice') { 'Support - Voice' } else { 'Billing' }
  $disconnect = if (($script:GeneratedConversationCount % 3) -eq 0) { 'client' } else { 'peer' }

  # Reuse the generator inside the default dataset creator by pattern: build a minimal compatible shape here
  $endUtc = $startUtc.AddMinutes(7).AddSeconds(($seedSeconds % 120))

  $customerParticipantId = "p-$ConversationId-customer"
  $agentParticipantId    = "p-$ConversationId-agent"
  $customerSessionId = "s-$ConversationId-customer-1"
  $agentSessionId    = "s-$ConversationId-agent-1"

  $segment1Start = $startUtc.AddSeconds(3)
  $segment2Start = $startUtc.AddSeconds(45)
  $segment3Start = $startUtc.AddMinutes(6)

  $newConv = [pscustomobject]@{
    conversationId    = $ConversationId
    id                = $ConversationId
    conversationStart = $startUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    startTime         = $startUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    conversationEnd   = $endUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    endTime           = $endUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    participants      = @(
      [pscustomobject]@{
        participantId = $customerParticipantId
        id            = $customerParticipantId
        purpose       = 'customer'
        name          = 'Customer'
        startTime     = $startUtc.ToString('o')
        endTime       = $endUtc.ToString('o')
        sessions      = @(
          [pscustomobject]@{
            sessionId  = $customerSessionId
            id         = $customerSessionId
            mediaType  = 'voice'
            direction  = 'inbound'
            segments   = @(
              [pscustomobject]@{
                segmentType    = 'interact'
                segmentStart   = $segment2Start.ToString('o')
                segmentEnd     = $segment3Start.ToString('o')
                disconnectType = $disconnect
                queueId        = $queueId
                queueName      = $queueName
                properties     = [pscustomobject]@{
                  message = 'Offline demo: customer request captured.'
                }
              }
            )
            metrics    = @(
              [pscustomobject]@{ name = 'tTalk'; emitDate = $segment2Start.AddSeconds(10).ToString('o'); stats = [pscustomobject]@{ sum = 180000; count = 1 } }
            )
          }
        )
      }
      [pscustomobject]@{
        participantId = $agentParticipantId
        id            = $agentParticipantId
        purpose       = 'agent'
        name          = 'Alex Demo'
        userId        = 'user-demo-001'
        startTime     = $startUtc.AddSeconds(35).ToString('o')
        endTime       = $endUtc.ToString('o')
        sessions      = @(
          [pscustomobject]@{
            sessionId  = $agentSessionId
            id         = $agentSessionId
            mediaType  = 'voice'
            direction  = 'outbound'
            segments   = @(
              [pscustomobject]@{
                segmentType  = 'alert'
                segmentStart = $segment1Start.ToString('o')
                segmentEnd   = $segment2Start.ToString('o')
                queueId      = $queueId
                queueName    = $queueName
              }
              [pscustomobject]@{
                segmentType    = 'interact'
                segmentStart   = $segment2Start.ToString('o')
                segmentEnd     = $segment3Start.ToString('o')
                disconnectType = $disconnect
                queueId        = $queueId
                queueName      = $queueName
              }
              [pscustomobject]@{
                segmentType  = 'wrapup'
                segmentStart = $segment3Start.ToString('o')
                segmentEnd   = $endUtc.ToString('o')
                queueId      = $queueId
                queueName    = $queueName
              }
            )
            metrics    = @(
              [pscustomobject]@{ name = 'tHandle'; emitDate = $segment3Start.AddSeconds(1).ToString('o'); stats = [pscustomobject]@{ sum = 420000; count = 1 } }
            )
          }
        )
      }
    )
  }

  # Append into dataset for subsequent queries.
  $dataset.analytics.conversations = @($dataset.analytics.conversations) + @($newConv)
  return $newConv
}

function New-GcDefaultSampleDataset {
  $nowUtc = (Get-Date).ToUniversalTime()

  $org = [pscustomobject]@{
    id   = 'org-demo-001'
    name = 'Demo Org (Offline)'
  }

  $userMe = [pscustomobject]@{
    id           = 'user-demo-001'
    name         = 'Alex Demo'
    email        = 'alex.demo@example.com'
    organization = $org
  }

  $queues = @(
    [pscustomobject]@{ id = 'q-demo-support-voice'; name = 'Support - Voice'; division = [pscustomobject]@{ name = 'Support' } }
    [pscustomobject]@{ id = 'q-demo-billing';       name = 'Billing';        division = [pscustomobject]@{ name = 'Back Office' } }
  )

  $skills = @(
    [pscustomobject]@{ id = 'skill-demo-english';  name = 'English' }
    [pscustomobject]@{ id = 'skill-demo-spanish';  name = 'Spanish' }
    [pscustomobject]@{ id = 'skill-demo-vip';      name = 'VIP' }
    [pscustomobject]@{ id = 'skill-demo-password'; name = 'Password Reset' }
  )

  $presenceDefinitions = @(
    [pscustomobject]@{ id = 'pres-demo-available';  languageLabels = [pscustomobject]@{ en_US = 'Available' } }
    [pscustomobject]@{ id = 'pres-demo-break';      languageLabels = [pscustomobject]@{ en_US = 'Break' } }
    [pscustomobject]@{ id = 'pres-demo-away';       languageLabels = [pscustomobject]@{ en_US = 'Away' } }
    [pscustomobject]@{ id = 'pres-demo-busy';       languageLabels = [pscustomobject]@{ en_US = 'Busy' } }
  )

  $users = @(
    [pscustomobject]@{ id = 'user-demo-001'; name = 'Alex Demo';  email = 'alex.demo@example.com';  username = 'alex.demo';  state = 'active'; division = [pscustomobject]@{ name = 'Support' } }
    [pscustomobject]@{ id = 'user-demo-002'; name = 'Casey Ops';  email = 'casey.ops@example.com';  username = 'casey.ops';  state = 'active'; division = [pscustomobject]@{ name = 'Operations' } }
    [pscustomobject]@{ id = 'user-demo-003'; name = 'Jordan QA';  email = 'jordan.qa@example.com';  username = 'jordan.qa';  state = 'active'; division = [pscustomobject]@{ name = 'Quality' } }
  )

  $oauthClients = @(
    [pscustomobject]@{
      id = 'oauth-demo-001'
      name = 'Offline Demo App'
      authorizedGrantType = 'authorization_code'
      state = 'active'
      dateCreated = $nowUtc.AddDays(-120).ToString('o')
      description = 'Sample OAuth client for offline demo.'
    }
    [pscustomobject]@{
      id = 'oauth-demo-002'
      name = 'Reporting Export Worker'
      authorizedGrantType = 'client_credentials'
      state = 'active'
      dateCreated = $nowUtc.AddDays(-45).ToString('o')
      description = 'Sample worker client.'
    }
  )

  $audits = @(
    [pscustomobject]@{
      id = 'audit-demo-001'
      action = 'UPDATE'
      entity = [pscustomobject]@{ type = 'routingQueue'; id = 'q-demo-support-voice'; name = 'Support - Voice' }
      user = [pscustomobject]@{ id = 'user-demo-002'; name = 'Casey Ops' }
      timestamp = $nowUtc.AddMinutes(-32).ToString('o')
      details = [pscustomobject]@{ field = 'acwTimeoutMs'; old = 30000; new = 45000 }
    }
    [pscustomobject]@{
      id = 'audit-demo-002'
      action = 'CREATE'
      entity = [pscustomobject]@{ type = 'flow'; id = 'flow-demo-001'; name = 'Password Reset - Voice' }
      user = [pscustomobject]@{ id = 'user-demo-001'; name = 'Alex Demo' }
      timestamp = $nowUtc.AddHours(-4).ToString('o')
      details = [pscustomobject]@{ note = 'Created for offline demo.' }
    }
  )

  $flows = @(
    [pscustomobject]@{ id = 'flow-demo-001'; name = 'Password Reset - Voice'; type = 'inboundcall'; publishedVersion = 12; division = [pscustomobject]@{ name = 'IVR' } }
    [pscustomobject]@{ id = 'flow-demo-002'; name = 'Billing - Inbound';     type = 'inboundcall'; publishedVersion = 5;  division = [pscustomobject]@{ name = 'IVR' } }
  )

  $dataActions = @(
    [pscustomobject]@{
      id = 'da-demo-001'
      name = 'Lookup Customer'
      category = 'Integration'
      integrationId = 'int-demo-001'
      contract = [pscustomobject]@{ input = [pscustomobject]@{ properties = [pscustomobject]@{ customerId = [pscustomobject]@{ type = 'string' } } }; output = [pscustomobject]@{ properties = [pscustomobject]@{ status = [pscustomobject]@{ type = 'string' } } } }
      secure = $false
      config = [pscustomobject]@{ request = [pscustomobject]@{ urlTemplate = 'https://offline.local/crm/customers/{customerId}'; requestType = 'GET' } }
      dateCreated = $nowUtc.AddDays(-120).ToString('o')
      dateModified = $nowUtc.AddDays(-9).ToString('o')
      modifiedBy = [pscustomobject]@{ id = 'user-demo-002'; name = 'Casey Ops' }
      description = 'Returns a lightweight customer profile for agent assist and case routing.'
    }
    [pscustomobject]@{
      id = 'da-demo-002'
      name = 'Create Ticket'
      category = 'Integration'
      integrationId = 'int-demo-002'
      contract = [pscustomobject]@{ input = [pscustomobject]@{ properties = [pscustomobject]@{ subject = [pscustomobject]@{ type = 'string' }; severity = [pscustomobject]@{ type = 'string' } } }; output = [pscustomobject]@{ properties = [pscustomobject]@{ ticketId = [pscustomobject]@{ type = 'string' } } } }
      secure = $true
      config = [pscustomobject]@{ request = [pscustomobject]@{ urlTemplate = 'https://offline.local/itsm/tickets'; requestType = 'POST' } }
      dateCreated = $nowUtc.AddDays(-45).ToString('o')
      dateModified = $nowUtc.AddDays(-2).ToString('o')
      modifiedBy = [pscustomobject]@{ id = 'user-demo-001'; name = 'Alex Demo' }
      description = 'Creates an ITSM ticket; used by incident packet export workflows.'
    }
    [pscustomobject]@{
      id = 'da-demo-003'
      name = 'Reset Password (Dry Run)'
      category = 'Custom'
      integrationId = 'int-demo-003'
      contract = [pscustomobject]@{ input = [pscustomobject]@{ properties = [pscustomobject]@{ email = [pscustomobject]@{ type = 'string' } } }; output = [pscustomobject]@{ properties = [pscustomobject]@{ ok = [pscustomobject]@{ type = 'boolean' } } } }
      secure = $false
      config = [pscustomobject]@{ request = [pscustomobject]@{ urlTemplate = 'https://offline.local/auth/reset/dryrun'; requestType = 'POST' } }
      dateCreated = $nowUtc.AddDays(-14).ToString('o')
      dateModified = $nowUtc.AddDays(-1).ToString('o')
      modifiedBy = [pscustomobject]@{ id = 'user-demo-003'; name = 'Jordan QA' }
      description = 'Offline demo-only action used to validate payloads without changing systems.'
    }
  )

  $recordings = @(
    [pscustomobject]@{ id = 'rec-demo-001'; conversationId = 'c-demo-001'; startTime = $nowUtc.AddMinutes(-52).ToString('o'); endTime = $nowUtc.AddMinutes(-44).ToString('o'); media = 'audio' }
    [pscustomobject]@{ id = 'rec-demo-002'; conversationId = 'c-demo-002'; startTime = $nowUtc.AddHours(-3).ToString('o');  endTime = $nowUtc.AddHours(-3).AddMinutes(6).ToString('o'); media = 'audio' }
  )

  $qualityEvaluations = @(
    [pscustomobject]@{ id = 'qe-demo-001'; conversationId = 'c-demo-001'; agentId = 'user-demo-001'; evaluatorId = 'user-demo-003'; status = 'released'; score = 92 }
    [pscustomobject]@{ id = 'qe-demo-002'; conversationId = 'c-demo-002'; agentId = 'user-demo-002'; evaluatorId = 'user-demo-003'; status = 'inProgress'; score = $null }
  )

  function New-SampleConversation {
    param(
      [Parameter(Mandatory)][string]$ConversationId,
      [Parameter(Mandatory)][datetime]$StartUtc,
      [int]$DurationSeconds = 420,
      [string]$QueueId = 'q-demo-support-voice',
      [string]$QueueName = 'Support - Voice',
      [string]$DisconnectType = 'peer',
      [string]$Direction = 'inbound',
      [string]$MediaType = 'voice'
    )

    $endUtc = $StartUtc.AddSeconds($DurationSeconds)

    $customerParticipantId = "p-$ConversationId-customer"
    $agentParticipantId    = "p-$ConversationId-agent"

    $customerSessionId = "s-$ConversationId-customer-1"
    $agentSessionId    = "s-$ConversationId-agent-1"

    $segment1Start = $StartUtc.AddSeconds(3)
    $segment2Start = $StartUtc.AddSeconds(45)
    $segment3Start = $StartUtc.AddSeconds([Math]::Max(60, $DurationSeconds - 20))

    $conversation = [pscustomobject]@{
      conversationId    = $ConversationId
      id                = $ConversationId
      conversationStart = $StartUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
      startTime         = $StartUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
      conversationEnd   = $endUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
      endTime           = $endUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
      participants      = @(
        [pscustomobject]@{
          participantId = $customerParticipantId
          id            = $customerParticipantId
          purpose       = 'customer'
          name          = 'Customer'
          startTime     = $StartUtc.ToString('o')
          endTime       = $endUtc.ToString('o')
          sessions      = @(
            [pscustomobject]@{
              sessionId  = $customerSessionId
              id         = $customerSessionId
              mediaType  = $MediaType
              direction  = $Direction
              segments   = @(
                [pscustomobject]@{
                  segmentType    = 'interact'
                  segmentStart   = $segment2Start.ToString('o')
                  segmentEnd     = $segment3Start.ToString('o')
                  disconnectType = $DisconnectType
                  queueId        = $QueueId
                  queueName      = $QueueName
                  properties     = [pscustomobject]@{
                    message = 'I need help resetting my password.'
                  }
                }
              )
              metrics    = @(
                [pscustomobject]@{ name = 'tTalk';  emitDate = $segment2Start.AddSeconds(10).ToString('o'); stats = [pscustomobject]@{ sum = 240000; count = 1 } }
                [pscustomobject]@{ name = 'tHold';  emitDate = $segment2Start.AddSeconds(40).ToString('o'); stats = [pscustomobject]@{ sum = 20000; count = 1 } }
              )
            }
          )
        }
        [pscustomobject]@{
          participantId = $agentParticipantId
          id            = $agentParticipantId
          purpose       = 'agent'
          name          = 'Alex Demo'
          userId        = 'user-demo-001'
          startTime     = $StartUtc.AddSeconds(35).ToString('o')
          endTime       = $endUtc.ToString('o')
          sessions      = @(
            [pscustomobject]@{
              sessionId  = $agentSessionId
              id         = $agentSessionId
              mediaType  = $MediaType
              direction  = 'outbound'
              segments   = @(
                [pscustomobject]@{
                  segmentType  = 'alert'
                  segmentStart = $segment1Start.ToString('o')
                  segmentEnd   = $segment2Start.ToString('o')
                  queueId      = $QueueId
                  queueName    = $QueueName
                }
                [pscustomobject]@{
                  segmentType    = 'interact'
                  segmentStart   = $segment2Start.ToString('o')
                  segmentEnd     = $segment3Start.ToString('o')
                  disconnectType = $DisconnectType
                  queueId        = $QueueId
                  queueName      = $QueueName
                }
                [pscustomobject]@{
                  segmentType  = 'wrapup'
                  segmentStart = $segment3Start.ToString('o')
                  segmentEnd   = $endUtc.ToString('o')
                  queueId      = $QueueId
                  queueName    = $QueueName
                }
              )
              metrics    = @(
                [pscustomobject]@{ name = 'tHandle'; emitDate = $segment3Start.AddSeconds(1).ToString('o'); stats = [pscustomobject]@{ sum = ($DurationSeconds * 1000); count = 1 } }
              )
            }
          )
        }
      )
    }

    return $conversation
  }

  $sampleConversations = @()

  # Seed a handful of conversations across time ranges so "Last 24 hours" / "Last 7 days" demos look realistic.
  $seedSpecs = @(
    @{ id='c-demo-001'; start=$nowUtc.AddMinutes(-55);                dur=520; disc='peer';   qid='q-demo-support-voice'; qn='Support - Voice'; media='voice'; dir='inbound' }
    @{ id='c-demo-002'; start=$nowUtc.AddHours(-3).AddMinutes(-10);   dur=380; disc='client'; qid='q-demo-billing';       qn='Billing';        media='voice'; dir='inbound' }
    @{ id='c-demo-003'; start=$nowUtc.AddDays(-2).AddHours(-1);       dur=690; disc='peer';   qid='q-demo-support-voice'; qn='Support - Voice'; media='chat';  dir='inbound' }
    @{ id='c-demo-004'; start=$nowUtc.AddHours(-8);                  dur=265; disc='peer';   qid='q-demo-support-voice'; qn='Support - Voice'; media='voice'; dir='inbound' }
    @{ id='c-demo-005'; start=$nowUtc.AddDays(-1).AddHours(-2);      dur=812; disc='client'; qid='q-demo-billing';       qn='Billing';        media='voice'; dir='inbound' }
    @{ id='c-demo-006'; start=$nowUtc.AddDays(-4).AddMinutes(-22);   dur=155; disc='peer';   qid='q-demo-support-voice'; qn='Support - Voice'; media='message'; dir='inbound' }
    @{ id='c-demo-007'; start=$nowUtc.AddDays(-6).AddHours(-4);      dur=402; disc='peer';   qid='q-demo-support-voice'; qn='Support - Voice'; media='voice'; dir='inbound' }
    @{ id='c-demo-008'; start=$nowUtc.AddMinutes(-18);               dur=305; disc='peer';   qid='q-demo-billing';       qn='Billing';        media='chat';  dir='inbound' }
    @{ id='c-demo-009'; start=$nowUtc.AddHours(-20);                 dur=905; disc='client'; qid='q-demo-support-voice'; qn='Support - Voice'; media='voice'; dir='inbound' }
    @{ id='c-demo-010'; start=$nowUtc.AddDays(-3).AddHours(-6);      dur=441; disc='peer';   qid='q-demo-billing';       qn='Billing';        media='voice'; dir='inbound' }
  )

  foreach ($s in $seedSpecs) {
    $sampleConversations += New-SampleConversation `
      -ConversationId $s.id `
      -StartUtc $s.start `
      -DurationSeconds $s.dur `
      -QueueId $s.qid `
      -QueueName $s.qn `
      -DisconnectType $s.disc `
      -Direction $s.dir `
      -MediaType $s.media
  }

  return [pscustomobject]@{
    meta = [pscustomobject]@{
      name = 'Default Offline Demo Dataset'
      version = 1
      generatedAt = $nowUtc.ToString('o')
    }
    org = $org
    userMe = $userMe
    routing = [pscustomobject]@{
      queues = $queues
      skills = $skills
      presenceDefinitions = $presenceDefinitions
    }
    users = $users
    oauthClients = $oauthClients
    audits = $audits
    flows = $flows
    dataActions = $dataActions
    recordings = $recordings
    qualityEvaluations = $qualityEvaluations
    analytics = [pscustomobject]@{
      conversations = $sampleConversations
    }
  }
}

function Get-GcSampleDataset {
  if ($null -eq $script:SampleDataset) {
    $script:SampleDataset = New-GcDefaultSampleDataset
    $script:AnalyticsConversationJobs = @{}
    $script:GeneratedConversationCount = 0
  }
  return $script:SampleDataset
}

function Reset-GcSampleDataset {
  $script:SampleDataset = $null
  $script:AnalyticsConversationJobs = @{}
  $script:GeneratedConversationCount = 0
}

function Invoke-GcSampleRequest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,

    [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
    [string]$Method = 'GET',

    [hashtable]$Query,
    [hashtable]$PathParams,
    [object]$Body
  )

  $dataset = Get-GcSampleDataset

  $p = $Path
  if (-not $p.StartsWith('/')) { $p = '/' + $p }
  if ($p -match '^(?<base>[^?]+)\\?(?<qs>.*)$') { $p = $matches.base }

  # Apply path params (mirror Resolve-GcEndpoint behavior but on already-normalized path)
  if ($PathParams) {
    foreach ($k in $PathParams.Keys) {
      $token = '{' + $k + '}'
      if ($p -like "*$token*") {
        $p = $p.Replace($token, [string]$PathParams[$k])
      }
    }
  }

  $key = ('{0} {1}' -f $Method.ToUpperInvariant(), $p)

  switch -Regex ($key) {
    '^GET /api/v2/users/me$' {
      return $dataset.userMe
    }

    '^GET /api/v2/conversations/(?<conversationId>[^/]+)$' {
      $cid = $matches.conversationId
      $conv = @($dataset.analytics.conversations | Where-Object { $_.conversationId -eq $cid -or $_.id -eq $cid } | Select-Object -First 1)
      if (-not $conv -or $conv.Count -eq 0) { $conv = @(AddOrGet-GcSampleConversation -ConversationId $cid) }
      return $conv[0]
    }

    '^POST /api/v2/analytics/conversations/details/query$' {
      $convs = @($dataset.analytics.conversations)

      # Basic interval filtering (best effort)
      try {
        if ($Body -and $Body.interval -and ($Body.interval -match '/')) {
          $parts = [string]$Body.interval -split '/'
          if ($parts.Count -eq 2) {
            $start = [datetime]::Parse($parts[0]).ToUniversalTime()
            $end   = [datetime]::Parse($parts[1]).ToUniversalTime()
            $convs = $convs | Where-Object {
              try {
                $cs = [datetime]::Parse($_.conversationStart).ToUniversalTime()
                ($cs -ge $start) -and ($cs -le $end)
              } catch { $true }
            }
          }
        }
      } catch { }

      # conversationId filter (common pattern)
      try {
        if ($Body -and $Body.conversationFilters) {
          foreach ($f in @($Body.conversationFilters)) {
            foreach ($pred in @($f.predicates)) {
              if ($pred.dimension -eq 'conversationId' -and $pred.value) {
                $cid = [string]$pred.value
                $convs = $convs | Where-Object { $_.conversationId -eq $cid -or $_.id -eq $cid }
                if (-not $convs -or @($convs).Count -eq 0) {
                  $convs = @(AddOrGet-GcSampleConversation -ConversationId $cid)
                }
              }
            }
          }
        }
      } catch { }

      return [pscustomobject]@{
        conversations = @($convs)
        totalHits = @($convs).Count
        pageNumber = 1
        pageCount = 1
      }
    }

    '^POST /api/v2/analytics/conversations/details/jobs$' {
      $conversationId = $null
      try {
        foreach ($f in @($Body.conversationFilters)) {
          foreach ($pred in @($f.predicates)) {
            if ($pred.dimension -eq 'conversationId' -and $pred.value) { $conversationId = [string]$pred.value }
          }
        }
      } catch { }

      if (-not $conversationId) { $conversationId = 'c-demo-001' }

      # Ensure a backing conversation exists for the requested ID (keeps timeline generation consistent)
      [void](AddOrGet-GcSampleConversation -ConversationId $conversationId)

      $jobId = ('job-demo-{0}-{1}' -f $conversationId, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
      $script:AnalyticsConversationJobs[$jobId] = [pscustomobject]@{
        jobId = $jobId
        conversationId = $conversationId
        createdAt = (Get-Date).ToString('o')
      }

      return [pscustomobject]@{ id = $jobId }
    }

    '^GET /api/v2/analytics/conversations/details/jobs/(?<jobId>[^/]+)$' {
      $jobId = $matches.jobId
      if ($script:AnalyticsConversationJobs.ContainsKey($jobId)) {
        return [pscustomobject]@{
          id = $jobId
          state = 'FULFILLED'
        }
      }
      return [pscustomobject]@{
        id = $jobId
        state = 'FAILED'
      }
    }

    '^GET /api/v2/analytics/conversations/details/jobs/(?<jobId>[^/]+)/results$' {
      $jobId = $matches.jobId
      $cid = $null
      if ($script:AnalyticsConversationJobs.ContainsKey($jobId)) {
        $cid = $script:AnalyticsConversationJobs[$jobId].conversationId
      }
      if (-not $cid) { $cid = 'c-demo-001' }

      $convObj = AddOrGet-GcSampleConversation -ConversationId $cid
      $conv = @($convObj)

      return [pscustomobject]@{
        conversations = @($conv)
      }
    }

    '^POST /api/v2/audits/query$' {
      return [pscustomobject]@{
        entities = @($dataset.audits)
        pageNumber = 1
        pageCount = 1
      }
    }

    '^GET /api/v2/oauth/clients$' {
      return [pscustomobject]@{
        entities = @($dataset.oauthClients)
        pageNumber = 1
        pageCount = 1
      }
    }

    '^GET /api/v2/flows$' {
      return [pscustomobject]@{
        entities = @($dataset.flows)
        pageNumber = 1
        pageCount = 1
      }
    }

    '^GET /api/v2/flows/(?<flowId>[^/]+)/latestconfiguration$' {
      return [pscustomobject]@{
        id = $matches.flowId
        name = 'Demo Flow Configuration'
        description = 'Offline demo configuration payload (mock).'
        modifiedDate = (Get-Date).ToString('o')
      }
    }

    '^GET /api/v2/integrations/actions$' {
      return [pscustomobject]@{
        entities = @($dataset.dataActions)
        pageNumber = 1
        pageCount = 1
      }
    }

    '^GET /api/v2/integrations/actions/(?<actionId>[^/]+)$' {
      $a = @($dataset.dataActions | Where-Object { $_.id -eq $matches.actionId } | Select-Object -First 1)
      if (-not $a -or $a.Count -eq 0) { return [pscustomobject]@{ id = $matches.actionId; name = 'Unknown Action (Offline)' } }
      return $a[0]
    }

    '^GET /api/v2/routing/queues$' {
      return [pscustomobject]@{
        entities = @($dataset.routing.queues)
        pageNumber = 1
        pageCount = 1
      }
    }

    '^GET /api/v2/routing/queues/(?<queueId>[^/]+)$' {
      $q = @($dataset.routing.queues | Where-Object { $_.id -eq $matches.queueId } | Select-Object -First 1)
      if (-not $q -or $q.Count -eq 0) { $q = [pscustomobject]@{ id = $matches.queueId; name = 'Unknown Queue (Offline)' } }
      return $q
    }

    '^GET /api/v2/routing/skills$' {
      return [pscustomobject]@{
        entities = @($dataset.routing.skills)
        pageNumber = 1
        pageCount = 1
      }
    }

    '^GET /api/v2/routing/skills/(?<skillId>[^/]+)$' {
      $s = @($dataset.routing.skills | Where-Object { $_.id -eq $matches.skillId } | Select-Object -First 1)
      if (-not $s -or $s.Count -eq 0) { $s = [pscustomobject]@{ id = $matches.skillId; name = 'Unknown Skill (Offline)' } }
      return $s
    }

    '^GET /api/v2/users$' {
      return [pscustomobject]@{
        entities = @($dataset.users)
        pageNumber = 1
        pageCount = 1
      }
    }

    '^GET /api/v2/presencedefinitions$' {
      return [pscustomobject]@{
        entities = @($dataset.routing.presenceDefinitions)
      }
    }

    '^POST /api/v2/analytics/queues/observations/query$' {
      $queueIds = @()
      try {
        $queueIds = @($Body.filter.predicates | Where-Object { $_.dimension -eq 'queueId' } | ForEach-Object { $_.value }) | ForEach-Object { @($_) } | Select-Object -First 1
      } catch { }
      if (-not $queueIds) { $queueIds = @($dataset.routing.queues | ForEach-Object { $_.id }) }

      $results = foreach ($qid in @($queueIds)) {
        $seed = [Math]::Abs($qid.GetHashCode())
        $onQueue = ($seed % 14) + 2
        $waiting = ($seed % 6)
        $interacting = [Math]::Max(0, $onQueue - $waiting)
        [pscustomobject]@{
          group = [pscustomobject]@{ queueId = $qid }
          data = @(
            [pscustomobject]@{ metric = 'oOnQueue';      stats = [pscustomobject]@{ count = $onQueue } }
            [pscustomobject]@{ metric = 'oWaiting';      stats = [pscustomobject]@{ count = $waiting } }
            [pscustomobject]@{ metric = 'oInteracting';  stats = [pscustomobject]@{ count = $interacting } }
          )
        }
      }

      return [pscustomobject]@{
        results = @($results)
      }
    }

    '^GET /api/v2/userrecordings$' {
      $entities = foreach ($rec in @($dataset.recordings)) {
        $durationMs = 0
        try {
          if ($rec.startTime -and $rec.endTime) {
            $durationMs = [int](([datetime]$rec.endTime - [datetime]$rec.startTime).TotalMilliseconds)
          }
        } catch { }

        [pscustomobject]@{
          id                   = $rec.id
          name                 = "Recording $($rec.id)"
          conversationId       = $rec.conversationId
          conversation         = [pscustomobject]@{ id = $rec.conversationId }
          dateCreated          = if ($rec.startTime) { $rec.startTime } else { (Get-Date).ToString('o') }
          durationMilliseconds = $durationMs
        }
      }

      return [pscustomobject]@{
        entities   = @($entities)
        pageNumber = 1
        pageCount  = 1
      }
    }

    '^GET /api/v2/userrecordings/(?<recId>[^/]+)$' {
      $rec = @($dataset.recordings | Where-Object { $_.id -eq $matches.recId } | Select-Object -First 1)
      if (-not $rec -or $rec.Count -eq 0) {
        throw "Recording not found: $($matches.recId)"
      }
      $r = $rec[0]

      $durationMs = 0
      try {
        if ($r.startTime -and $r.endTime) {
          $durationMs = [int](([datetime]$r.endTime - [datetime]$r.startTime).TotalMilliseconds)
        }
      } catch { }

      return [pscustomobject]@{
        id                   = $r.id
        name                 = "Recording $($r.id)"
        conversationId       = $r.conversationId
        conversation         = [pscustomobject]@{ id = $r.conversationId }
        dateCreated          = if ($r.startTime) { $r.startTime } else { (Get-Date).ToString('o') }
        durationMilliseconds = $durationMs
      }
    }

    '^GET /api/v2/conversations/(?<conversationId>[^/]+)/recordings/(?<recId>[^/]+)$' {
      return [pscustomobject]@{
        id             = $matches.recId
        conversationId = $matches.conversationId
        mediaUris      = [pscustomobject]@{
          HTTPGET = ("https://offline.local/recordings/{0}.mp3" -f $matches.recId)
        }
      }
    }

    # Legacy recording routes retained for compatibility with older code paths.
    '^GET /api/v2/recording/recordings$' {
      return [pscustomobject]@{
        entities = @($dataset.recordings)
        pageNumber = 1
        pageCount = 1
      }
    }

    '^GET /api/v2/recording/recordings/(?<recId>[^/]+)/media$' {
      return [pscustomobject]@{
        id = $matches.recId
        mediaUrl = ("https://offline.local/recordings/{0}.mp3" -f $matches.recId)
      }
    }

    '^GET /api/v2/quality/evaluations/query$' {
      return [pscustomobject]@{
        entities = @($dataset.qualityEvaluations)
        pageNumber = 1
        pageCount = 1
      }
    }

    # Legacy method retained for compatibility with older code paths.
    '^POST /api/v2/quality/evaluations/query$' {
      return [pscustomobject]@{
        entities = @($dataset.qualityEvaluations)
        pageNumber = 1
        pageCount = 1
      }
    }

    '^POST /api/v2/analytics/conversations/aggregates/query$' {
      $results = foreach ($q in @($dataset.routing.queues)) {
        $seed = [Math]::Abs($q.id.GetHashCode())
        $offered = ($seed % 240) + 40
        $abandoned = [Math]::Max(0, [int]($offered * 0.08))
        $handled = $offered - $abandoned
        $waitSumMs = ($seed % 120) * 1000 * $offered
        $handleSumMs = ($seed % 220) * 1000 * $handled

        [pscustomobject]@{
          group = [pscustomobject]@{ queueId = $q.id }
          data = @(
            [pscustomobject]@{ metric = 'nOffered'; stats = [pscustomobject]@{ count = $offered } }
            [pscustomobject]@{ metric = 'nHandled'; stats = [pscustomobject]@{ count = $handled } }
            [pscustomobject]@{ metric = 'nAbandon'; stats = [pscustomobject]@{ count = $abandoned } }
            [pscustomobject]@{ metric = 'tWait';    stats = [pscustomobject]@{ sum = $waitSumMs; count = $offered } }
            [pscustomobject]@{ metric = 'tHandle';  stats = [pscustomobject]@{ sum = $handleSumMs; count = $handled } }
          )
        }
      }

      return [pscustomobject]@{
        results = @($results)
      }
    }
  }

  # Default fallback: return an object that paged callers will interpret as empty.
  return [pscustomobject]@{
    entities = @()
    results = @()
    conversations = @()
    items = @()
    data = @()
    offlineDemo = $true
    method = $Method
    path = $p
  }
}

Export-ModuleMember -Function Get-GcSampleDataset, Reset-GcSampleDataset, Invoke-GcSampleRequest

### END: Core.SampleData.psm1
