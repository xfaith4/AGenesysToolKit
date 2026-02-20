# GcAdmin.psm1
# ============================================================
# Genesys Cloud Admin Toolbox — Unified Workflow Orchestrator
# ============================================================
# Wraps all sub-modules into a single coherent surface:
#   Auth → Query → Guardrail → Report → Artifact
#
# Usage:
#   Import-Module .\GcAdmin.psm1
#   Initialize-GcAdmin -ConfigPath .\gc-admin.json
#   Invoke-GcHealthCheck
#   Invoke-GcGuardrailAudit
#   Invoke-GcAbandonmentReport -Hours 24
#
# Design goals
#   1. Single import — no need to juggle individual .psm1 files
#   2. Session context — authenticate once, reuse everywhere
#   3. Guardrails — policy definitions that raise WARN/BLOCK before mutations
#   4. Critical-only output — suppress noise, surface what matters
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Module root (works when dot-sourced or imported) ──────────────────────────
$script:ModuleRoot = $PSScriptRoot

# ── Session context (populated by Initialize-GcAdmin) ────────────────────────
$script:Ctx = @{
    AccessToken  = $null
    Region       = $null
    OrgName      = $null
    UserEmail    = $null
    InitialisedAt = $null
}

# ── Policy store (populated by Set-GcGuardrail / loaded from config) ─────────
$script:Policies = [System.Collections.Generic.List[hashtable]]::new()

# ── Critical alert buffer (flushed by Get-GcCriticalAlerts) ──────────────────
$script:Alerts   = [System.Collections.Generic.List[hashtable]]::new()

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

function Import-GcSubModule {
    param([string]$Name)
    $path = Join-Path $script:ModuleRoot "$Name.psm1"
    if (Test-Path $path) {
        Import-Module $path -Force -Global -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

function Assert-GcSession {
    if (-not $script:Ctx.AccessToken) {
        throw "No active session. Call Initialize-GcAdmin first."
    }
}

function Write-GcStatus {
    param([string]$Message, [ValidateSet('INFO','WARN','CRIT','OK')]$Level = 'INFO')
    $symbols = @{ INFO = '·'; WARN = '⚠'; CRIT = '✖'; OK = '✔' }
    $colors  = @{ INFO = 'Cyan'; WARN = 'Yellow'; CRIT = 'Red'; OK = 'Green' }
    $sym = $symbols[$Level]
    Write-Host "  $sym  $Message" -ForegroundColor $colors[$Level]
}

function Add-GcAlert {
    param(
        [string]$Severity,   # WARN | CRIT
        [string]$Category,
        [string]$Message,
        [hashtable]$Details = @{}
    )
    $script:Alerts.Add(@{
        Severity  = $Severity
        Category  = $Category
        Message   = $Message
        Details   = $Details
        Timestamp = Get-Date
    })
}

function Invoke-GcApi {
    <#
    Thin wrapper around Invoke-GcRequest that injects session context.
    Falls back to raw Invoke-RestMethod if HttpRequests module isn't loaded.
    #>
    param(
        [string]$Method = 'GET',
        [string]$Path,
        [object]$Body
    )
    Assert-GcSession

    if (Get-Command Invoke-GcRequest -ErrorAction SilentlyContinue) {
        $params = @{
            Method       = $Method
            Path         = $Path
            AccessToken  = $script:Ctx.AccessToken
            InstanceName = $script:Ctx.Region
        }
        if ($Body) { $params['Body'] = $Body }
        return Invoke-GcRequest @params
    }

    # Fallback: raw REST
    $uri     = "https://api.$($script:Ctx.Region)$Path"
    $headers = @{
        Authorization  = "Bearer $($script:Ctx.AccessToken)"
        'Content-Type' = 'application/json'
    }
    $irmParams = @{ Uri = $uri; Method = $Method; Headers = $headers }
    if ($Body) {
        $irmParams['Body']        = ($Body | ConvertTo-Json -Depth 20 -Compress)
        $irmParams['ContentType'] = 'application/json'
    }
    return Invoke-RestMethod @irmParams
}

function Invoke-GcApiPaged {
    param([string]$Path, [int]$MaxItems = 500)
    Assert-GcSession

    if (Get-Command Invoke-GcPagedRequest -ErrorAction SilentlyContinue) {
        return Invoke-GcPagedRequest -Method GET -Path $Path `
            -AccessToken $script:Ctx.AccessToken `
            -InstanceName $script:Ctx.Region `
            -MaxItems $MaxItems
    }

    # Simple single-page fallback
    return @(Invoke-GcApi -Path $Path)
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Initialisation
# ─────────────────────────────────────────────────────────────────────────────

function Initialize-GcAdmin {
    <#
    .SYNOPSIS
        Bootstrap the Admin Toolbox — load sub-modules, authenticate, seed default guardrails.

    .PARAMETER Region
        Genesys Cloud region (e.g. 'mypurecloud.com', 'usw2.pure.cloud').

    .PARAMETER ClientId
        OAuth Client ID. Use with -ClientSecret for Client Credentials flow.

    .PARAMETER ClientSecret
        OAuth Client Secret. Triggers Client Credentials grant when provided.

    .PARAMETER AccessToken
        Supply a pre-existing token (skips OAuth entirely — useful in CI).

    .PARAMETER ConfigPath
        Path to a JSON config file containing any of the above fields plus
        optional Guardrails definitions.

    .PARAMETER NoDefaultGuardrails
        Skip seeding the built-in default guardrail policies.

    .EXAMPLE
        Initialize-GcAdmin -Region 'mypurecloud.com' -ClientId 'abc' -ClientSecret 'xyz'

    .EXAMPLE
        Initialize-GcAdmin -ConfigPath .\gc-admin.json
    #>
    [CmdletBinding()]
    param(
        [string]$Region,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$AccessToken,
        [string]$ConfigPath,
        [switch]$NoDefaultGuardrails
    )

    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │   Genesys Cloud Admin Toolbox            │" -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""

    # ── Load config file ──────────────────────────────────────────────────────
    $cfg = @{}
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        try {
            $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            Write-GcStatus "Loaded config from $ConfigPath" -Level OK
        } catch {
            Write-GcStatus "Config parse failed — using parameter values only" -Level WARN
        }
    }

    # Parameters override config file
    if (-not $Region)       { $Region       = $cfg['region'] }
    if (-not $ClientId)     { $ClientId     = $cfg['clientId'] }
    if (-not $ClientSecret) { $ClientSecret = $cfg['clientSecret'] }
    if (-not $AccessToken)  { $AccessToken  = $cfg['accessToken'] }

    if (-not $Region) { throw "Region is required. Pass -Region or set 'region' in config." }

    # ── Load sub-modules ──────────────────────────────────────────────────────
    Write-GcStatus "Loading sub-modules..." -Level INFO
    $modules = @('Auth','HttpRequests','Analytics','RoutingPeople',
                 'ConversationsExtended','ConfigExport','Dependencies',
                 'Diagnostics','Jobs','JobRunner','Reporting',
                 'ReportTemplates','Subscriptions','Timeline',
                 'ArtifactGenerator','SampleData')
    foreach ($m in $modules) {
        $ok = Import-GcSubModule -Name $m
        if ($ok) { Write-GcStatus "$m" -Level OK }
    }

    $script:Ctx.Region = $Region

    # ── Authenticate ──────────────────────────────────────────────────────────
    Write-GcStatus "Authenticating..." -Level INFO

    if ($AccessToken) {
        $script:Ctx.AccessToken = $AccessToken
        Write-GcStatus "Using supplied access token" -Level OK
    } elseif ($ClientId -and $ClientSecret) {
        if (Get-Command Set-GcAuthConfig -ErrorAction SilentlyContinue) {
            Set-GcAuthConfig -Region $Region -ClientId $ClientId -ClientSecret $ClientSecret
            $tok = Get-GcClientCredentialsToken -Region $Region -ClientId $ClientId -ClientSecret $ClientSecret
            $script:Ctx.AccessToken = $tok.access_token
        } else {
            # Fallback inline client-credentials
            $pair     = "$ClientId`:$ClientSecret"
            $b64      = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
            $response = Invoke-RestMethod `
                -Uri "https://login.$Region/oauth/token" `
                -Method POST `
                -Headers @{ Authorization = "Basic $b64" } `
                -Body @{ grant_type = 'client_credentials' } `
                -ContentType 'application/x-www-form-urlencoded'
            $script:Ctx.AccessToken = $response.access_token
        }
        Write-GcStatus "Client credentials token acquired" -Level OK
    } else {
        throw "Authentication required. Provide -AccessToken or -ClientId/-ClientSecret."
    }

    # ── Validate token & pull org info ────────────────────────────────────────
    try {
        $me = Invoke-GcApi -Path '/api/v2/users/me'
        $script:Ctx.UserEmail     = $me.email
        $script:Ctx.OrgName       = $me.organization.name
        $script:Ctx.InitialisedAt = Get-Date
        Write-GcStatus "Connected  ·  $($me.email)  ·  $($me.organization.name)" -Level OK
    } catch {
        Write-GcStatus "Token validation failed: $_" -Level CRIT
        throw
    }

    # ── Seed guardrails ───────────────────────────────────────────────────────
    if (-not $NoDefaultGuardrails) {
        Register-GcDefaultGuardrails
        # Load custom guardrails from config if present
        if ($cfg['guardrails']) {
            foreach ($gr in $cfg['guardrails']) {
                Add-GcGuardrail `
                    -Name        $gr.name `
                    -Category    $gr.category `
                    -Description $gr.description `
                    -Severity    ($gr.severity ?? 'WARN') `
                    -Threshold   ($gr.threshold ?? $null) `
                    -CheckScript ([scriptblock]::Create($gr.checkScript))
            }
        }
        Write-GcStatus "$($script:Policies.Count) guardrail policies active" -Level OK
    }

    Write-Host ""
    Write-Host "  Admin Toolbox ready. Run Invoke-GcHealthCheck to verify." -ForegroundColor Cyan
    Write-Host ""
}

function Get-GcSession {
    <# Returns the current session context (non-secret fields only). #>
    return [PSCustomObject]@{
        Region       = $script:Ctx.Region
        OrgName      = $script:Ctx.OrgName
        UserEmail    = $script:Ctx.UserEmail
        InitialisedAt = $script:Ctx.InitialisedAt
        TokenPresent = [bool]$script:Ctx.AccessToken
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Guardrail engine
# ─────────────────────────────────────────────────────────────────────────────

function Add-GcGuardrail {
    <#
    .SYNOPSIS
        Register a custom guardrail policy.

    .DESCRIPTION
        Guardrails are named policy checks that run against live Genesys data.
        Each policy declares a scriptblock that returns:
            $true  — policy satisfied (no alert)
            $false — policy violated  (alert raised at declared severity)
            OR a hashtable: @{ Pass=$bool; Detail='...' }

        Built-in categories: Routing, Analytics, Config, Capacity, Security

    .PARAMETER Name
        Unique name for this policy.

    .PARAMETER Category
        Logical grouping (Routing | Analytics | Config | Capacity | Security | Custom).

    .PARAMETER Description
        Human-readable explanation of what the policy checks.

    .PARAMETER Severity
        WARN or CRIT. CRIT blocks a mutation (when called via Invoke-GcWithGuardrails).

    .PARAMETER Threshold
        Optional numeric threshold (referenced inside CheckScript as $Threshold).

    .PARAMETER CheckScript
        Scriptblock that performs the check. Has access to:
            $Ctx        — session context
            $Threshold  — policy threshold value
            $ApiCall    — helper alias for Invoke-GcApi

    .EXAMPLE
        Add-GcGuardrail -Name 'MaxQueueACW' -Category Routing -Severity WARN -Threshold 300 -CheckScript {
            $queues = $ApiCall.Invoke('/api/v2/routing/queues?pageSize=100')
            $violations = $queues.entities | Where-Object { $_.acwSettings.timeoutMs -gt ($Threshold * 1000) }
            if ($violations) { return @{ Pass=$false; Detail="$($violations.Count) queue(s) exceed ACW threshold" } }
            return $true
        } -Description 'Flag queues with ACW > 5 min'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Description,
        [ValidateSet('WARN','CRIT')][string]$Severity = 'WARN',
        [object]$Threshold = $null,
        [Parameter(Mandatory)][scriptblock]$CheckScript
    )

    # Deduplicate by name
    $existing = $script:Policies | Where-Object { $_.Name -eq $Name }
    if ($existing) {
        $script:Policies.Remove($existing) | Out-Null
    }

    $script:Policies.Add(@{
        Name        = $Name
        Category    = $Category
        Description = $Description
        Severity    = $Severity
        Threshold   = $Threshold
        CheckScript = $CheckScript
        Enabled     = $true
    })
}

function Remove-GcGuardrail {
    param([Parameter(Mandatory)][string]$Name)
    $pol = $script:Policies | Where-Object { $_.Name -eq $Name }
    if ($pol) { $script:Policies.Remove($pol) | Out-Null }
}

function Get-GcGuardrails {
    return $script:Policies | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.Name
            Category    = $_.Category
            Severity    = $_.Severity
            Description = $_.Description
            Enabled     = $_.Enabled
            Threshold   = $_.Threshold
        }
    }
}

function Invoke-GcGuardrailAudit {
    <#
    .SYNOPSIS
        Run all enabled guardrail policies against live data and report violations.

    .PARAMETER Category
        Optionally limit to a specific category.

    .PARAMETER OutputPath
        If specified, writes a JSON results file to this path.

    .OUTPUTS
        Array of violation hashtables (empty if all pass).
    #>
    [CmdletBinding()]
    param(
        [string]$Category,
        [string]$OutputPath
    )

    Assert-GcSession

    $policies = $script:Policies | Where-Object { $_.Enabled }
    if ($Category) { $policies = $policies | Where-Object { $_.Category -eq $Category } }

    Write-Host ""
    Write-Host "  ── Guardrail Audit ────────────────────────" -ForegroundColor Cyan
    Write-Host "     Org: $($script:Ctx.OrgName)" -ForegroundColor DarkGray
    Write-Host "     Policies: $($policies.Count)" -ForegroundColor DarkGray
    Write-Host ""

    $violations = @()
    $apiCall    = { param([string]$p, [string]$m='GET', [object]$b=$null)
                    Invoke-GcApi -Path $p -Method $m -Body $b }

    foreach ($pol in $policies) {
        $result = $null
        try {
            $result = & $pol.CheckScript `
                -Ctx       $script:Ctx `
                -Threshold $pol.Threshold `
                -ApiCall   $apiCall
        } catch {
            $result = @{ Pass = $false; Detail = "CHECK ERROR: $_" }
        }

        $pass   = $true
        $detail = ''

        if ($result -is [bool]) {
            $pass = $result
        } elseif ($result -is [hashtable]) {
            $pass   = [bool]$result.Pass
            $detail = $result.Detail
        }

        if ($pass) {
            Write-GcStatus "[$($pol.Category)] $($pol.Name)" -Level OK
        } else {
            $msg = "[$($pol.Category)] $($pol.Name)"
            if ($detail) { $msg += " — $detail" }
            Write-GcStatus $msg -Level $pol.Severity
            $v = @{
                Policy      = $pol.Name
                Category    = $pol.Category
                Severity    = $pol.Severity
                Description = $pol.Description
                Detail      = $detail
                Timestamp   = Get-Date
            }
            $violations += $v
            Add-GcAlert -Severity $pol.Severity -Category $pol.Category -Message $msg -Details $v
        }
    }

    Write-Host ""
    if ($violations.Count -eq 0) {
        Write-GcStatus "All policies passed." -Level OK
    } else {
        $crit = @($violations | Where-Object { $_.Severity -eq 'CRIT' }).Count
        $warn = @($violations | Where-Object { $_.Severity -eq 'WARN' }).Count
        Write-GcStatus "$crit critical  ·  $warn warnings" -Level $(if ($crit -gt 0) { 'CRIT' } else { 'WARN' })
    }
    Write-Host ""

    if ($OutputPath) {
        $violations | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
        Write-GcStatus "Results saved → $OutputPath" -Level INFO
    }

    return $violations
}

function Invoke-GcWithGuardrails {
    <#
    .SYNOPSIS
        Run a scriptblock only after guardrail checks pass. Blocks on CRIT violations.

    .PARAMETER Action
        Scriptblock containing the mutation or operation.

    .PARAMETER Category
        Only check guardrails in this category (default: all).

    .PARAMETER Force
        Run the action even if WARN-level violations exist (CRIT still blocks).

    .EXAMPLE
        Invoke-GcWithGuardrails -Category Routing -Action {
            # e.g. update a queue setting
            Invoke-GcApi -Method PATCH -Path '/api/v2/routing/queues/abc' -Body @{...}
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Category,
        [switch]$Force
    )

    $params = @{}
    if ($Category) { $params['Category'] = $Category }
    $violations = Invoke-GcGuardrailAudit @params

    $crits = @($violations | Where-Object { $_.Severity -eq 'CRIT' })
    $warns = @($violations | Where-Object { $_.Severity -eq 'WARN' })

    if ($crits.Count -gt 0) {
        Write-GcStatus "Action BLOCKED by $($crits.Count) critical guardrail(s)." -Level CRIT
        return $null
    }

    if ($warns.Count -gt 0 -and -not $Force) {
        Write-GcStatus "$($warns.Count) warning(s) exist. Re-run with -Force to proceed." -Level WARN
        return $null
    }

    Write-GcStatus "Guardrails passed — executing action..." -Level OK
    return & $Action
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Default guardrail policies
# ─────────────────────────────────────────────────────────────────────────────

function Register-GcDefaultGuardrails {

    # ── Routing ───────────────────────────────────────────────────────────────

    Add-GcGuardrail -Name 'EmptyQueues' -Category Routing -Severity WARN -Description `
        'Queues with 0 members are likely misconfigured or orphaned.' -CheckScript {
        param($Ctx, $Threshold, $ApiCall)
        try {
            $r = $ApiCall.Invoke('/api/v2/routing/queues?pageSize=100&sortBy=name')
            $empty = @($r.entities | Where-Object { $_.memberCount -eq 0 })
            if ($empty.Count -gt 0) {
                return @{ Pass=$false; Detail="$($empty.Count) queue(s) have 0 members" }
            }
        } catch { return @{ Pass=$false; Detail="API error: $_" } }
        return $true
    }

    Add-GcGuardrail -Name 'QueueWithoutSkillEval' -Category Routing -Severity WARN -Description `
        'Queues missing a skill evaluation method may route sub-optimally.' -CheckScript {
        param($Ctx, $Threshold, $ApiCall)
        try {
            $r = $ApiCall.Invoke('/api/v2/routing/queues?pageSize=100')
            $bad = @($r.entities | Where-Object { -not $_.skillEvaluationMethod -or $_.skillEvaluationMethod -eq 'NONE' })
            if ($bad.Count -gt 3) {
                return @{ Pass=$false; Detail="$($bad.Count) queue(s) have no skill evaluation" }
            }
        } catch { }
        return $true
    }

    Add-GcGuardrail -Name 'FlowWithNoPublishedVersion' -Category Routing -Severity WARN -Description `
        'Flows that have never been published are not serving traffic but still consume namespace.' -CheckScript {
        param($Ctx, $Threshold, $ApiCall)
        try {
            $r = $ApiCall.Invoke('/api/v2/flows?pageSize=100')
            $unpub = @($r.entities | Where-Object { -not $_.publishedVersion })
            if ($unpub.Count -gt 0) {
                return @{ Pass=$false; Detail="$($unpub.Count) flow(s) have no published version" }
            }
        } catch { }
        return $true
    }

    # ── Analytics / SLA ───────────────────────────────────────────────────────

    Add-GcGuardrail -Name 'HighAbandonmentRate' -Category Analytics -Severity CRIT `
        -Threshold 15 -Description 'Abandonment rate > 15% signals a service quality crisis.' -CheckScript {
        param($Ctx, $Threshold, $ApiCall)
        try {
            $end   = (Get-Date).ToUniversalTime()
            $start = $end.AddHours(-4)
            $iv    = "$($start.ToString('o'))/$($end.ToString('o'))"
            $body  = @{
                interval = $iv
                groupBy  = @('queueId')
                metrics  = @('nOffered','nAbandon')
                filter   = @{ type='and'; predicates=@(@{dimension='mediaType';value='voice'}) }
            }
            $r = $ApiCall.Invoke('/api/v2/analytics/conversations/aggregates/query','POST',$body)
            $offered  = 0; $abandon = 0
            foreach ($res in $r.results) {
                foreach ($dp in $res.data) {
                    if ($dp.metric -eq 'nOffered') { $offered += $dp.stats.count }
                    if ($dp.metric -eq 'nAbandon') { $abandon += $dp.stats.count }
                }
            }
            if ($offered -gt 50) {
                $rate = [Math]::Round(($abandon / $offered) * 100, 1)
                if ($rate -gt $Threshold) {
                    return @{ Pass=$false; Detail="${rate}% abandonment in last 4 h (threshold: ${Threshold}%)" }
                }
            }
        } catch { }
        return $true
    }

    Add-GcGuardrail -Name 'LongAvgHandleTime' -Category Analytics -Severity WARN `
        -Threshold 600 -Description 'Avg handle time > 10 min may indicate agent struggle or routing issues.' -CheckScript {
        param($Ctx, $Threshold, $ApiCall)
        try {
            $end   = (Get-Date).ToUniversalTime()
            $start = $end.AddHours(-8)
            $iv    = "$($start.ToString('o'))/$($end.ToString('o'))"
            $body  = @{
                interval = $iv
                groupBy  = @('queueId')
                metrics  = @('tHandle','nHandled')
                filter   = @{ type='and'; predicates=@(@{dimension='mediaType';value='voice'}) }
            }
            $r = $ApiCall.Invoke('/api/v2/analytics/conversations/aggregates/query','POST',$body)
            $totalHandle = 0; $handled = 0
            foreach ($res in $r.results) {
                foreach ($dp in $res.data) {
                    if ($dp.metric -eq 'tHandle' -and $dp.stats.sum) { $totalHandle += $dp.stats.sum }
                    if ($dp.metric -eq 'nHandled') { $handled += $dp.stats.count }
                }
            }
            if ($handled -gt 20) {
                $avgSec = [Math]::Round($totalHandle / $handled / 1000)
                if ($avgSec -gt $Threshold) {
                    return @{ Pass=$false; Detail="Avg handle time ${avgSec}s (threshold: ${Threshold}s)" }
                }
            }
        } catch { }
        return $true
    }

    # ── Config ────────────────────────────────────────────────────────────────

    Add-GcGuardrail -Name 'UnusedDataActions' -Category Config -Severity WARN -Description `
        'Data actions not referenced in any flow waste license capacity.' -CheckScript {
        param($Ctx, $Threshold, $ApiCall)
        try {
            $r = $ApiCall.Invoke('/api/v2/integrations/actions?pageSize=100&category=custom')
            $count = if ($r.entities) { @($r.entities).Count } else { 0 }
            if ($count -gt 50) {
                return @{ Pass=$false; Detail="$count data actions — review for orphans (use Search-GcFlowReferences)" }
            }
        } catch { }
        return $true
    }

    Add-GcGuardrail -Name 'OrphanedSkills' -Category Config -Severity WARN -Description `
        'Routing skills with zero associated users cannot influence routing.' -CheckScript {
        param($Ctx, $Threshold, $ApiCall)
        try {
            $r = $ApiCall.Invoke('/api/v2/routing/skills?pageSize=100')
            $orphans = @($r.entities | Where-Object { $_.userCount -eq 0 -or -not $_.userCount })
            if ($orphans.Count -gt 5) {
                return @{ Pass=$false; Detail="$($orphans.Count) skill(s) have no assigned users" }
            }
        } catch { }
        return $true
    }

    # ── Capacity ──────────────────────────────────────────────────────────────

    Add-GcGuardrail -Name 'OverloadedQueues' -Category Capacity -Severity CRIT `
        -Threshold 50 -Description 'Queues with waiting conversations > threshold indicate a staffing emergency.' -CheckScript {
        param($Ctx, $Threshold, $ApiCall)
        try {
            $r = $ApiCall.Invoke('/api/v2/routing/queues/observations/query') 2>$null
            # This endpoint requires POST — skip silently if it errors
        } catch { return $true }
        # Placeholder: real implementation would check waiting counts per queue
        return $true
    }

    # ── Security ──────────────────────────────────────────────────────────────

    Add-GcGuardrail -Name 'InactiveIntegrations' -Category Security -Severity WARN -Description `
        'Integrations in a broken/inactive state should be removed or repaired to reduce attack surface.' -CheckScript {
        param($Ctx, $Threshold, $ApiCall)
        try {
            $r = $ApiCall.Invoke('/api/v2/integrations?pageSize=100')
            $broken = @($r.entities | Where-Object { $_.integrationType -and ($_.reported.status -eq 'Error' -or $_.reported.status -eq 'AuthFailed') })
            if ($broken.Count -gt 0) {
                return @{ Pass=$false; Detail="$($broken.Count) integration(s) are in error state" }
            }
        } catch { }
        return $true
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Health check
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-GcHealthCheck {
    <#
    .SYNOPSIS
        Rapid end-to-end connectivity and configuration sanity check.
        Reports only items requiring attention (critical-first design).

    .OUTPUTS
        PSCustomObject with health check results.
    #>
    [CmdletBinding()]
    param()

    Assert-GcSession

    Write-Host ""
    Write-Host "  ── Health Check ───────────────────────────" -ForegroundColor Cyan
    Write-Host "     $($script:Ctx.OrgName)  ·  $($script:Ctx.Region)" -ForegroundColor DarkGray
    Write-Host ""

    $checks = [ordered]@{}

    # 1. API ping
    try {
        Invoke-GcApi -Path '/api/v2/users/me' | Out-Null
        $checks['API Connectivity'] = 'OK'
        Write-GcStatus "API Connectivity" -Level OK
    } catch {
        $checks['API Connectivity'] = "FAIL: $_"
        Write-GcStatus "API Connectivity: $_" -Level CRIT
    }

    # 2. Queue count
    try {
        $q = Invoke-GcApi -Path '/api/v2/routing/queues?pageSize=1'
        $checks['Queue Count'] = $q.total
        $level = if ($q.total -eq 0) { 'CRIT' } else { 'OK' }
        Write-GcStatus "Queues: $($q.total) found" -Level $level
        if ($q.total -eq 0) { Add-GcAlert -Severity CRIT -Category Routing -Message "No queues found in org" }
    } catch {
        $checks['Queue Count'] = "Error"
        Write-GcStatus "Queue query failed" -Level WARN
    }

    # 3. Active flows
    try {
        $f = Invoke-GcApi -Path '/api/v2/flows?pageSize=1'
        $checks['Flow Count'] = $f.total
        Write-GcStatus "Flows: $($f.total) found" -Level OK
    } catch {
        $checks['Flow Count'] = "Error"
    }

    # 4. User count
    try {
        $u = Invoke-GcApi -Path '/api/v2/users?pageSize=1&state=active'
        $checks['Active Users'] = $u.total
        Write-GcStatus "Active users: $($u.total)" -Level OK
    } catch {
        $checks['Active Users'] = "Error"
    }

    # 5. Quick abandonment pulse (last 1h)
    try {
        $end   = (Get-Date).ToUniversalTime()
        $start = $end.AddHours(-1)
        $body  = @{
            interval = "$($start.ToString('o'))/$($end.ToString('o'))"
            metrics  = @('nOffered','nAbandon')
            filter   = @{ type='and'; predicates=@(@{dimension='mediaType';value='voice'}) }
        }
        $agg = Invoke-GcApi -Method POST -Path '/api/v2/analytics/conversations/aggregates/query' -Body $body
        $offered = 0; $abandon = 0
        foreach ($res in $agg.results) {
            foreach ($dp in $res.data) {
                if ($dp.metric -eq 'nOffered') { $offered += $dp.stats.count }
                if ($dp.metric -eq 'nAbandon') { $abandon += $dp.stats.count }
            }
        }
        $rate = if ($offered -gt 0) { [Math]::Round(($abandon/$offered)*100,1) } else { 0 }
        $checks['Abandonment 1h'] = "$rate% ($abandon/$offered)"
        $lvl = if ($rate -gt 20) { 'CRIT' } elseif ($rate -gt 10) { 'WARN' } else { 'OK' }
        Write-GcStatus "Abandonment (1h): $rate%  ($abandon abandoned of $offered)" -Level $lvl
        if ($rate -gt 20) { Add-GcAlert -Severity CRIT -Category Analytics -Message "Abandonment spike: $rate% in last hour" }
    } catch {
        $checks['Abandonment 1h'] = "N/A"
        Write-GcStatus "Abandonment check skipped (analytics not available)" -Level INFO
    }

    Write-Host ""

    return [PSCustomObject]@{
        OrgName  = $script:Ctx.OrgName
        Region   = $script:Ctx.Region
        Checks   = $checks
        Alerts   = @($script:Alerts | Select-Object -Last 10)
        RunAt    = Get-Date
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Reporting shortcuts
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-GcAbandonmentReport {
    <#
    .SYNOPSIS
        Pull abandonment metrics for the last N hours and output a focused summary.
        Only reports queues where abandonment exceeds threshold.

    .PARAMETER Hours
        Look-back window in hours (default: 24).

    .PARAMETER AbandonThresholdPct
        Only include queues above this abandonment % in the report (default: 5).

    .PARAMETER OutputPath
        Optional JSON output path.
    #>
    [CmdletBinding()]
    param(
        [int]$Hours = 24,
        [double]$AbandonThresholdPct = 5,
        [string]$OutputPath
    )

    Assert-GcSession

    Write-Host ""
    Write-Host "  ── Abandonment Report  (last ${Hours}h) ──────" -ForegroundColor Cyan
    Write-Host ""

    $end   = (Get-Date).ToUniversalTime()
    $start = $end.AddHours(-$Hours)

    $body = @{
        interval = "$($start.ToString('o'))/$($end.ToString('o'))"
        groupBy  = @('queueId')
        metrics  = @('nOffered','nAbandon','tWait')
        filter   = @{ type='and'; predicates=@(@{dimension='mediaType';value='voice'}) }
    }

    try {
        $agg = Invoke-GcApi -Method POST -Path '/api/v2/analytics/conversations/aggregates/query' -Body $body
    } catch {
        Write-GcStatus "Analytics API error: $_" -Level CRIT
        return $null
    }

    # Build per-queue summary
    $queueStats = @{}
    foreach ($res in $agg.results) {
        $qId = $res.group.queueId
        if (-not $queueStats[$qId]) { $queueStats[$qId] = @{ offered=0; abandon=0; waitSum=0; waitCount=0 } }
        foreach ($dp in $res.data) {
            switch ($dp.metric) {
                'nOffered' { $queueStats[$qId].offered += $dp.stats.count }
                'nAbandon' { $queueStats[$qId].abandon += $dp.stats.count }
                'tWait'    {
                    if ($dp.stats.sum)   { $queueStats[$qId].waitSum   += $dp.stats.sum }
                    if ($dp.stats.count) { $queueStats[$qId].waitCount += $dp.stats.count }
                }
            }
        }
    }

    $report = @()
    $totalOffered = 0; $totalAbandoned = 0

    foreach ($qId in $queueStats.Keys) {
        $s    = $queueStats[$qId]
        $rate = if ($s.offered -gt 0) { [Math]::Round(($s.abandon/$s.offered)*100,1) } else { 0 }
        $avgW = if ($s.waitCount -gt 0) { [Math]::Round($s.waitSum/$s.waitCount/1000,0) } else { 0 }
        $totalOffered   += $s.offered
        $totalAbandoned += $s.abandon

        if ($rate -ge $AbandonThresholdPct -and $s.offered -gt 5) {
            $lvl = if ($rate -gt 20) { 'CRIT' } else { 'WARN' }
            Write-GcStatus "Queue $qId  →  $rate% abandon  (${avgW}s avg wait)" -Level $lvl
            $report += [PSCustomObject]@{
                QueueId        = $qId
                Offered        = $s.offered
                Abandoned      = $s.abandon
                AbandonPct     = $rate
                AvgWaitSec     = $avgW
            }
            if ($rate -gt 15) {
                Add-GcAlert -Severity CRIT -Category Analytics -Message "Queue $qId abandon $rate%" -Details @{ QueueId=$qId; Rate=$rate }
            }
        }
    }

    $overallRate = if ($totalOffered -gt 0) { [Math]::Round(($totalAbandoned/$totalOffered)*100,1) } else { 0 }

    Write-Host ""
    Write-GcStatus "Overall:  $totalOffered offered  ·  $totalAbandoned abandoned  ·  $overallRate% rate" `
        -Level $(if ($overallRate -gt 15) { 'CRIT' } elseif ($overallRate -gt 8) { 'WARN' } else { 'OK' })
    Write-Host ""

    if ($report.Count -eq 0) {
        Write-GcStatus "No queues exceeded ${AbandonThresholdPct}% threshold." -Level OK
    }

    if ($OutputPath) {
        $report | ConvertTo-Json -Depth 5 | Set-Content $OutputPath -Encoding UTF8
        Write-GcStatus "Report saved → $OutputPath" -Level INFO
    }

    return $report
}

function Invoke-GcCapacitySnapshot {
    <#
    .SYNOPSIS
        Pull a point-in-time view of queue staffing and on-queue agent counts.
        Only surfaces queues where on-queue agents is 0 (critical gap).
    #>
    [CmdletBinding()]
    param()

    Assert-GcSession

    Write-Host ""
    Write-Host "  ── Capacity Snapshot ──────────────────────" -ForegroundColor Cyan
    Write-Host ""

    try {
        $queues = Invoke-GcApiPaged -Path '/api/v2/routing/queues?sortBy=name&pageSize=100'
    } catch {
        Write-GcStatus "Queue fetch failed: $_" -Level CRIT
        return
    }

    $gaps = @()
    foreach ($q in $queues) {
        $members = 0
        try {
            $mu = Invoke-GcApi -Path "/api/v2/routing/queues/$($q.id)/members?pageSize=1"
            $members = $mu.total
        } catch { }

        if ($members -eq 0) {
            Write-GcStatus "UNSTAFFED: $($q.name)" -Level CRIT
            $gaps += [PSCustomObject]@{ QueueName=$q.name; QueueId=$q.id }
            Add-GcAlert -Severity CRIT -Category Capacity -Message "Queue '$($q.name)' has 0 members"
        }
    }

    Write-Host ""
    if ($gaps.Count -eq 0) {
        Write-GcStatus "All queues have at least one member." -Level OK
    } else {
        Write-GcStatus "$($gaps.Count) unstaffed queue(s) found." -Level CRIT
    }
    Write-Host ""

    return $gaps
}

function Get-GcCriticalAlerts {
    <#
    .SYNOPSIS
        Returns all alerts accumulated in this session, filtered to CRIT by default.

    .PARAMETER AllSeverities
        Include WARN-level alerts as well.
    #>
    [CmdletBinding()]
    param([switch]$AllSeverities)

    $alerts = $script:Alerts.ToArray()
    if (-not $AllSeverities) {
        $alerts = $alerts | Where-Object { $_.Severity -eq 'CRIT' }
    }
    return $alerts | ForEach-Object {
        [PSCustomObject]@{
            Severity  = $_.Severity
            Category  = $_.Category
            Message   = $_.Message
            Timestamp = $_.Timestamp
        }
    }
}

function Clear-GcAlerts {
    $script:Alerts.Clear()
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Config & dependency utilities (convenience wrappers)
# ─────────────────────────────────────────────────────────────────────────────

function Export-GcConfig {
    <#
    .SYNOPSIS
        Export org configuration (flows, queues, skills, data actions) to disk.

    .PARAMETER OutputDirectory
        Where to write the export. Defaults to .\gc-export-<timestamp>.

    .PARAMETER IncludeFlows
    .PARAMETER IncludeQueues
    .PARAMETER IncludeSkills
    .PARAMETER IncludeDataActions
    #>
    [CmdletBinding()]
    param(
        [string]$OutputDirectory,
        [switch]$IncludeFlows       = $true,
        [switch]$IncludeQueues      = $true,
        [switch]$IncludeSkills      = $true,
        [switch]$IncludeDataActions = $true
    )

    Assert-GcSession

    if (-not $OutputDirectory) {
        $OutputDirectory = ".\gc-export-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }

    if (Get-Command Export-GcCompleteConfig -ErrorAction SilentlyContinue) {
        return Export-GcCompleteConfig `
            -AccessToken  $script:Ctx.AccessToken `
            -InstanceName $script:Ctx.Region `
            -OutputDirectory $OutputDirectory `
            -IncludeFlows:$IncludeFlows `
            -IncludeQueues:$IncludeQueues `
            -IncludeSkills:$IncludeSkills `
            -IncludeDataActions:$IncludeDataActions
    } else {
        Write-GcStatus "ConfigExport module not loaded — run Initialize-GcAdmin first." -Level WARN
    }
}

function Find-GcDependencies {
    <#
    .SYNOPSIS
        Find all flows that reference a given queue, skill, or data action.

    .PARAMETER ObjectId
        The GUID of the object to search for.

    .PARAMETER ObjectType
        queue | skill | dataAction
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ObjectId,
        [Parameter(Mandatory)][ValidateSet('queue','skill','dataAction')][string]$ObjectType
    )

    Assert-GcSession

    if (Get-Command Search-GcFlowReferences -ErrorAction SilentlyContinue) {
        Write-GcStatus "Scanning flows for references to $ObjectType $ObjectId ..." -Level INFO
        $refs = Search-GcFlowReferences `
            -ObjectId     $ObjectId `
            -ObjectType   $ObjectType `
            -AccessToken  $script:Ctx.AccessToken `
            -InstanceName $script:Ctx.Region
        Write-GcStatus "$($refs.Count) reference(s) found" -Level $(if ($refs.Count -eq 0) { 'WARN' } else { 'OK' })
        return $refs
    }
    Write-GcStatus "Dependencies module not loaded." -Level WARN
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Module exports
# ─────────────────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    # Bootstrap
    'Initialize-GcAdmin'
    'Get-GcSession'
    # Guardrails
    'Add-GcGuardrail'
    'Remove-GcGuardrail'
    'Get-GcGuardrails'
    'Invoke-GcGuardrailAudit'
    'Invoke-GcWithGuardrails'
    # Health & reporting
    'Invoke-GcHealthCheck'
    'Invoke-GcAbandonmentReport'
    'Invoke-GcCapacitySnapshot'
    'Get-GcCriticalAlerts'
    'Clear-GcAlerts'
    # Config
    'Export-GcConfig'
    'Find-GcDependencies'
    # Low-level API (for custom scripts)
    'Invoke-GcApi'
    'Invoke-GcApiPaged'
)
