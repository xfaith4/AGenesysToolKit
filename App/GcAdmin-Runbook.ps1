#!/usr/bin/env pwsh
# GcAdmin-Runbook.ps1
# ═══════════════════════════════════════════════════════════════════════════════
# Genesys Cloud Admin Toolbox — Runbook
# Copy the section you need and paste into your own scripts.
# ═══════════════════════════════════════════════════════════════════════════════
#
# PREREQUISITES
#   • PowerShell 5.1+ or PowerShell 7+
#   • All .psm1 files from AGenesysToolKit in the SAME directory as GcAdmin.psm1
#   • A Genesys Cloud OAuth client (Client Credentials or auth-code)
#
# QUICK START
#   1. Copy GcAdmin.psm1 + all other .psm1 files into one folder
#   2. Edit gc-admin.json with your region & credentials
#   3. Run:  pwsh -File GcAdmin-Runbook.ps1
# ═══════════════════════════════════════════════════════════════════════════════

# ── Load the toolbox ──────────────────────────────────────────────────────────
Import-Module "$PSScriptRoot\GcAdmin.psm1" -Force

# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW 1 — Daily health check (run as a scheduled task)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-DailyHealthRun {
    # Authenticate via config file
    Initialize-GcAdmin -ConfigPath "$PSScriptRoot\gc-admin.json"

    # Full health check (API ping, queue count, 1-hour abandonment pulse)
    $health = Invoke-GcHealthCheck

    # Run all guardrail policies
    $violations = Invoke-GcGuardrailAudit

    # Show only CRIT alerts
    $crits = Get-GcCriticalAlerts
    if ($crits) {
        Write-Host "`n  !! $($crits.Count) CRITICAL alert(s) require immediate attention:" -ForegroundColor Red
        $crits | Format-Table Timestamp, Category, Message -AutoSize
    }

    # Export results for upstream ITSM / ticketing
    $violationsPath = ".\gc-violations-$(Get-Date -Format 'yyyyMMdd').json"
    $violations | ConvertTo-Json -Depth 5 | Set-Content $violationsPath -Encoding UTF8
    Write-Host "  Violations saved → $violationsPath"
}


# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW 2 — Abandonment deep-dive for a specific window
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-AbandonmentDeepDive {
    param([int]$Hours = 8, [double]$Threshold = 5)

    Initialize-GcAdmin -ConfigPath "$PSScriptRoot\gc-admin.json"

    # Report only queues above threshold; saves to disk
    $report = Invoke-GcAbandonmentReport `
        -Hours                $Hours `
        -AbandonThresholdPct  $Threshold `
        -OutputPath           ".\abandonment-$(Get-Date -Format 'yyyyMMdd-HHmm').json"

    # For any queue above 15%, generate an incident packet
    foreach ($q in ($report | Where-Object { $_.AbandonPct -gt 15 })) {
        Write-Host "  Pulling incident details for queue $($q.QueueId)..." -ForegroundColor Yellow
        # Use the underlying Analytics module directly if ArtifactGenerator is loaded
        if (Get-Command Export-GcConversationPacket -ErrorAction SilentlyContinue) {
            # Fetch last abandoned conversation ID for this queue, then build packet
            # (In production, replace placeholder with actual conversation lookup)
            Write-Host "  → Export-GcConversationPacket -ConversationId <id> -Region $((Get-GcSession).Region) ..."
        }
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW 3 — Safe configuration change with guardrails
# ─────────────────────────────────────────────────────────────────────────────
function Update-QueueWithGuardrails {
    param(
        [string]$QueueId,
        [hashtable]$Changes
    )

    Initialize-GcAdmin -ConfigPath "$PSScriptRoot\gc-admin.json"

    # This will:
    #   1. Run ALL guardrail policies
    #   2. Block if ANY are CRIT
    #   3. Warn and require -Force for WARN violations
    Invoke-GcWithGuardrails -Category Routing -Action {
        $result = Invoke-GcApi -Method PATCH -Path "/api/v2/routing/queues/$QueueId" -Body $Changes
        Write-Host "  Queue updated: $($result.name)" -ForegroundColor Green
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW 4 — Add a custom guardrail at runtime
# ─────────────────────────────────────────────────────────────────────────────
function Add-CustomGuardrailExample {

    Initialize-GcAdmin -ConfigPath "$PSScriptRoot\gc-admin.json"

    # Add a policy that blocks deployment if > 10 flows are in a DRAFT state
    Add-GcGuardrail `
        -Name        'DraftFlowLimit' `
        -Category    'Config' `
        -Severity    'CRIT' `
        -Threshold   10 `
        -Description 'More than 10 unpublished draft flows indicates runaway development.' `
        -CheckScript {
            param($Ctx, $Threshold, $ApiCall)
            $r     = $ApiCall.Invoke('/api/v2/flows?pageSize=200')
            $draft = @($r.entities | Where-Object { -not $_.publishedVersion })
            if ($draft.Count -gt $Threshold) {
                return @{ Pass=$false; Detail="$($draft.Count) draft flows (limit: $Threshold)" }
            }
            return $true
        }

    # Now run audit — your new policy participates automatically
    Invoke-GcGuardrailAudit -Category Config
}


# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW 5 — Dependency impact before deleting a resource
# ─────────────────────────────────────────────────────────────────────────────
function Test-DeletionImpact {
    param([string]$ObjectId, [string]$ObjectType = 'queue')

    Initialize-GcAdmin -ConfigPath "$PSScriptRoot\gc-admin.json"

    $refs = Find-GcDependencies -ObjectId $ObjectId -ObjectType $ObjectType

    if ($refs.Count -gt 0) {
        Write-Host "`n  !! IMPACT WARNING: $($refs.Count) flow(s) reference this $ObjectType" -ForegroundColor Red
        $refs | Format-Table flowName, flowType, occurrences -AutoSize
        Write-Host "  Deletion would break the above flows. Review before proceeding." -ForegroundColor Red
    } else {
        Write-Host "  No flow references found. Safe to delete." -ForegroundColor Green
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW 6 — Full config snapshot (backup before a release)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PreReleaseBackup {
    Initialize-GcAdmin -ConfigPath "$PSScriptRoot\gc-admin.json"

    # Guardrail audit first — don't backup a broken config without flagging it
    $violations = Invoke-GcGuardrailAudit
    $crits = @($violations | Where-Object { $_.Severity -eq 'CRIT' })

    if ($crits.Count -gt 0) {
        Write-Host "`n  !! $($crits.Count) critical issue(s) found BEFORE backup — review required." -ForegroundColor Red
    }

    # Export full org config
    $result = Export-GcConfig -OutputDirectory ".\backups\$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    if ($result) {
        Write-Host "  Backup complete: $($result.ExportDirectory)" -ForegroundColor Green
        $result.Results | Format-Table Type, Count -AutoSize
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# Entry point — uncomment the workflow you want to run
# ─────────────────────────────────────────────────────────────────────────────

# Invoke-DailyHealthRun
# Invoke-AbandonmentDeepDive -Hours 8 -Threshold 5
# Update-QueueWithGuardrails -QueueId 'YOUR-QUEUE-ID' -Changes @{ acwSettings = @{ wrapupPrompt = 'MANDATORY' } }
# Add-CustomGuardrailExample
# Test-DeletionImpact -ObjectId 'YOUR-QUEUE-ID' -ObjectType 'queue'
# Invoke-PreReleaseBackup

Write-Host ""
Write-Host "  Runbook loaded. Uncomment a workflow above, or call functions directly." -ForegroundColor Cyan
Write-Host "  Available commands:" -ForegroundColor DarkGray
Write-Host "    Initialize-GcAdmin    Get-GcGuardrails    Invoke-GcGuardrailAudit" -ForegroundColor DarkGray
Write-Host "    Invoke-GcHealthCheck  Invoke-GcAbandonmentReport  Invoke-GcCapacitySnapshot" -ForegroundColor DarkGray
Write-Host "    Invoke-GcWithGuardrails  Find-GcDependencies  Export-GcConfig" -ForegroundColor DarkGray
Write-Host "    Get-GcCriticalAlerts  Add-GcGuardrail  Invoke-GcApi" -ForegroundColor DarkGray
Write-Host ""
