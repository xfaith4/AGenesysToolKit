# Genesys Cloud Admin Toolbox — Unified Workflow

> **One import. One session. Guardrails baked in.**

---

## What changed

The original toolkit shipped as 15+ independent `.psm1` files. Each one had to be imported separately, credentials were passed to every function call, and there was no shared concept of "is this operation safe to run right now?"

`GcAdmin.psm1` wraps all of that into a single coherent surface:

```
Auth → Query → Guardrail check → Action → Critical-only report
```

---

## File layout

```
YourFolder/
├── GcAdmin.psm1          ← NEW: unified orchestrator (import this one)
├── gc-admin.json         ← NEW: config + custom guardrails
├── GcAdmin-Runbook.ps1   ← NEW: ready-to-run workflow examples
│
├── Auth.psm1             ← original (loaded automatically)
├── HttpRequests.psm1     ← original
├── Analytics.psm1        ← original
├── RoutingPeople.psm1    ← original
├── ConversationsExtended.psm1
├── ConfigExport.psm1
├── Dependencies.psm1
├── Diagnostics.psm1
├── Jobs.psm1
├── JobRunner.psm1
├── Reporting.psm1
├── ReportTemplates.psm1
├── Subscriptions.psm1
├── Timeline.psm1
└── ArtifactGenerator.psm1
```

---

## Quick start

```powershell
# 1. Edit gc-admin.json with your region + OAuth credentials
# 2. Import once
Import-Module .\GcAdmin.psm1

# 3. Authenticate (reads gc-admin.json)
Initialize-GcAdmin -ConfigPath .\gc-admin.json

# 4. Health check — connectivity + quick abandonment pulse
Invoke-GcHealthCheck

# 5. Guardrail audit — run all policies, show only violations
Invoke-GcGuardrailAudit

# 6. Abandonment report — only shows queues above 5% threshold
Invoke-GcAbandonmentReport -Hours 24 -AbandonThresholdPct 5
```

---

## Authentication options

| Scenario | Command |
|---|---|
| Config file (recommended) | `Initialize-GcAdmin -ConfigPath .\gc-admin.json` |
| CLI parameters | `Initialize-GcAdmin -Region 'mypurecloud.com' -ClientId '…' -ClientSecret '…'` |
| Pre-existing token (CI/CD) | `Initialize-GcAdmin -Region '…' -AccessToken $env:GC_TOKEN` |

---

## Guardrail engine

Guardrails are named policies that run before any mutation. They answer: *"Is it safe to make this change right now?"*

### Built-in policies

| Policy | Category | Severity | What it checks |
|---|---|---|---|
| `EmptyQueues` | Routing | WARN | Queues with 0 members |
| `QueueWithoutSkillEval` | Routing | WARN | Queues missing skill evaluation |
| `FlowWithNoPublishedVersion` | Routing | WARN | Flows never published |
| `HighAbandonmentRate` | Analytics | **CRIT** | Abandon > 15% in last 4h |
| `LongAvgHandleTime` | Analytics | WARN | Avg handle > 10 min in last 8h |
| `UnusedDataActions` | Config | WARN | > 50 data actions (review for orphans) |
| `OrphanedSkills` | Config | WARN | Skills with no assigned users |
| `InactiveIntegrations` | Security | WARN | Integrations in error/auth-failed state |

### Adding a custom policy

```powershell
Add-GcGuardrail `
    -Name        'NoTestQueuesInProd' `
    -Category    'Config' `
    -Severity    'CRIT' `
    -Description 'TEST* queues must not exist in production.' `
    -CheckScript {
        param($Ctx, $Threshold, $ApiCall)
        $r    = $ApiCall.Invoke('/api/v2/routing/queues?pageSize=100')
        $test = @($r.entities | Where-Object { $_.name -like 'TEST*' })
        if ($test.Count -gt 0) {
            return @{ Pass=$false; Detail="$($test.Count) TEST queue(s) found" }
        }
        return $true
    }
```

Or define it in `gc-admin.json` under the `"guardrails"` array so it loads automatically.

### Guardrail-gated mutations

```powershell
# Will BLOCK if any CRIT policy fires; WARN requires -Force
Invoke-GcWithGuardrails -Category Routing -Action {
    Invoke-GcApi -Method PATCH -Path '/api/v2/routing/queues/<id>' -Body @{ ... }
}
```

---

## Core commands

```powershell
# Session
Initialize-GcAdmin      # bootstrap + authenticate
Get-GcSession           # who am I, what region

# Health & reporting (critical-only output)
Invoke-GcHealthCheck         # connectivity + key metrics pulse
Invoke-GcAbandonmentReport   # abandonment by queue, above threshold only
Invoke-GcCapacitySnapshot    # queues with 0 members (immediate staffing gaps)
Get-GcCriticalAlerts         # all CRIT alerts raised this session

# Guardrails
Get-GcGuardrails             # list all policies
Add-GcGuardrail              # register a new policy
Remove-GcGuardrail           # remove a policy by name
Invoke-GcGuardrailAudit      # run all policies, report violations
Invoke-GcWithGuardrails      # wrap any action in guardrail gate

# Configuration & dependencies
Export-GcConfig              # snapshot flows, queues, skills, data actions
Find-GcDependencies          # which flows reference a given queue/skill/data action

# Low-level (for custom scripts)
Invoke-GcApi                 # authenticated single API call (session-aware)
Invoke-GcApiPaged            # paginated GET
```

---

## Critical-only design

Every command in this toolbox follows the same output philosophy:

- **Silent on success** — no noise when everything is fine
- **WARN** for items to investigate
- **CRIT** for items that require action *now*
- `Get-GcCriticalAlerts` aggregates every CRIT raised across all commands in the current session

This makes the toolbox suitable for scheduled tasks and CI/CD pipelines — exit on `$crits.Count -gt 0`.

---

## Scheduled task example (PowerShell)

```powershell
# daily-health.ps1  — run this via Windows Task Scheduler or cron
Import-Module C:\GcAdmin\GcAdmin.psm1
Initialize-GcAdmin -ConfigPath C:\GcAdmin\gc-admin.json

Invoke-GcHealthCheck | Out-Null
Invoke-GcGuardrailAudit | Out-Null

$crits = Get-GcCriticalAlerts
if ($crits.Count -gt 0) {
    # Post to Teams, PagerDuty, email, etc.
    $crits | ConvertTo-Json | Out-File C:\Logs\gc-crits-$(Get-Date -f yyyyMMdd).json
    exit 1   # non-zero exit for monitoring systems
}
exit 0
```

---

## What the original modules still do

`GcAdmin.psm1` does **not** replace the underlying modules — it orchestrates them. You can still call any original function directly after `Initialize-GcAdmin` loads them:

```powershell
# All original functions remain accessible
New-GcIncidentPacket   # ArtifactGenerator
ConvertTo-GcTimeline   # Timeline
Get-GcAbandonmentMetrics  # Analytics
Export-GcCompleteConfig   # ConfigExport
Search-GcFlowReferences   # Dependencies
```

---

## gc-admin.json reference

```json
{
  "region":       "mypurecloud.com",
  "clientId":     "your-client-id",
  "clientSecret": "your-client-secret",
  "accessToken":  null,
  "guardrails": [
    {
      "name":        "PolicyName",
      "category":    "Routing|Analytics|Config|Capacity|Security|Custom",
      "severity":    "WARN|CRIT",
      "description": "What this policy checks",
      "threshold":   300000,
      "checkScript": "param($Ctx,$Threshold,$ApiCall) ... return $true"
    }
  ]
}
```
