# Architectural Decision Records

This file captures major architectural decisions for AGenesysToolKit. Each
record explains the context, the options considered, the decision made, and
the consequences. Decisions here are meant to be stable — if a decision
changes, update this file and note what changed and why.

---

## ADR-001: UI Framework — WPF vs .NET MAUI

**Status**: DECIDED — WPF is the committed UI framework for the foreseeable future.

**Date**: 2026-02-21

### Context

The project currently contains two parallel UI implementations:

| Layer | Technology | Location | Status |
|---|---|---|---|
| Primary UI | PowerShell + WPF/XAML | `App/GenesysCloudTool.ps1` | ~10,400 lines, fully featured |
| Secondary UI | C# + .NET MAUI | `Apps/ExtensionAuditMaui/` | ~8 source files, extension audit only |

The WPF application is Windows-only (requires .NET Framework or .NET 6+/Windows).
The MAUI application is cross-platform (Windows, macOS, iOS, Android). PowerShell
7+ is also cross-platform, but the WPF dependency hard-pins the UI to Windows.

The primary users of this tool are Windows-based Genesys Cloud administrators and
operations engineers. Cross-platform deployment has been discussed but is not a
current requirement with any named stakeholders.

The ROADMAP.md references cross-platform aspirations without specifying a timeline
or commitment.

### Options Considered

**Option A: Commit to WPF. Deprecate the MAUI app.**
- WPF is deeply embedded (10,400+ lines, 25+ views, all workflows implemented)
- Zero cross-platform reach; Windows administrators are the target audience
- MAUI app is removed from scope; its only feature (extension audit) is moved into the WPF app
- No split maintenance burden; all UI effort flows into one place

**Option B: Commit to MAUI. Migrate the WPF app.**
- Full cross-platform reach (Windows, macOS, Linux via MAUI Blazor hybrid)
- Requires rewriting 10,400 lines of PowerShell/WPF into C# + MAUI
- Core PowerShell modules would need to be wrapped or rewritten as C# libraries
- Multi-year effort; current WPF investment is abandoned
- Unlocks a consumer-grade app-store distribution model if desired

**Option C: Hybrid — MAUI shell, PowerShell engine.**
- MAUI app hosts a WebView or terminal panel that invokes PowerShell commands
- WPF app remains as the "power user" experience for Windows
- Core PowerShell modules remain the engine; MAUI becomes a cross-platform launcher
- Reduces rewrite scope significantly
- Still requires maintaining two rendering layers

### Decision

**Option A: Commit to WPF. Deprecate the MAUI app.**

Rationale:
1. The target audience (Windows-based Genesys Cloud engineers and operations teams)
   does not require macOS or mobile access.
2. The WPF app represents years of accumulated workflow design; migrating it is not
   justified by a cross-platform requirement that has no named stakeholders.
3. The MAUI app's only implemented feature (extension audit) is better served by
   integrating it into the WPF app as an `Addons/` module, which already exists as
   a pattern (`Addons/PeakConcurrency/`).
4. Maintaining two parallel UI frameworks creates confusion about the product's
   identity and splits maintenance effort across two technologies.
5. If cross-platform becomes a real requirement with a specific user population and
   timeline, this decision should be revisited at that point — not in anticipation
   of a requirement that may not arrive.

### Consequences

**Positive:**
- Clear product identity: one UI, one platform, one technology stack
- All UI development effort flows into the WPF app
- Extension audit functionality can be added as an Addon module
- CI/CD only needs `windows-latest` runners (already the case)

**Negative:**
- No cross-platform UI access
- Users on macOS or Linux cannot use the UI (they can still use the headless
  `GcAdmin.psm1` from PowerShell 7+)
- If a cross-platform requirement emerges later, the migration cost will be higher
  than if started earlier

### Action Items

1. Archive `Apps/ExtensionAuditMaui/` — preserve for reference but remove from
   active build targets
2. Port the extension ownership mismatch audit into a new `Addons/ExtensionAudit/`
   module following the existing Addon pattern
3. Update ROADMAP.md to remove cross-platform UI aspirations or explicitly defer
   them to a post-2.0 consideration
4. Update README.md to clearly state the Windows requirement rather than implying
   cross-platform potential

---

## ADR-002: Monolith Decomposition — App/GenesysCloudTool.ps1

**Status**: COMPLETE ✅

**Date**: 2026-02-21

### Context

The primary application file was originally named
`App/GenesysCloudTool_UX_Prototype.ps1` and was ~10,700 lines. It contained:
XAML helper utilities, the main window XAML definition, application state
management, ~25 workspace view functions (each with inline XAML + event
handlers), authentication UI, job monitoring UI, and all WPF event wiring.

This made the file impossible to unit test (UI and logic were fused), expensive
to merge (every feature change touched the same file), and difficult to navigate.

### Decision

Decompose incrementally by extraction, not by rewrite. Each extraction step
independently verifiable (run the app, confirm it loads).

**Decomposition — completed steps:**

1. **Utilities** — Functions with no UI dependency ✅ DONE
   - `App/XamlHelpers.ps1` — `Escape-GcXml`, `ConvertFrom-GcXaml`
   - `App/CoreIntegration.ps1` — Genesys.Core discovery engine (4-level chain)
   - `App/AppLogger.ps1` — `Write-GcAppLog`, `Write-GcTrace`, `Write-GcDiag`, `Format-GcDiagSecret`, `ConvertTo-GcAppLogSafeData`, `Test-GcTraceEnabled`

2. **Shell XAML** — External file, loaded at startup ✅ DONE
   - `App/Shell.xaml` — Main window, backstage, snackbar

3. **Per-workspace view files** — Each workspace becomes its own file ✅ DONE
   - `App/Views/Operations.ps1` — Subscriptions, Operational Event Logs, Audit Logs, OAuth / Token Usage (1,350 lines)
   - `App/Views/Conversations.ps1` — Lookup, Timeline, Analytics Jobs, Incident Packet, Abandon & Experience, Media & Quality (1,992 lines)
   - `App/Views/Orchestration.ps1` — Flows, Data Actions, Config Export, Dependency / Impact Map (995 lines)
   - `App/Views/RoutingPeople.ps1` — Queues, Skills, Users & Presence, Routing Snapshot (859 lines)
   - `App/Views/Reports.ps1` — Report Builder, Export History, Quick Exports (987 lines)

4. **AppState module** ✅ DONE
   - `App/AppState.ps1` — `Initialize-GcAppState`, `$script:WorkspaceModules`, `$script:AddonsByRoute`, `Sync-AppStateFromUi`, `Get-CallContext`

5. **File rename** ✅ DONE
   - `GenesysCloudTool_UX_Prototype.ps1` → `GenesysCloudTool.ps1`
   - All active references updated (tests, docs, comments)

### Acceptance Criteria

The decomposition is complete when:
- No single file exceeds 1,000 lines
- Each workspace view file can be read in isolation and understood
- The main orchestrator file contains no inline XAML strings
- All workspace view functions have corresponding unit tests in `tests/`

---

## ADR-003: Guardrail Engine — Config-Sourced Script Execution

**Status**: DECIDED — Allowed with warning and validation; opt-out available.

**Date**: 2026-02-21

### Context

`Initialize-GcAdmin` loads guardrail policies from `gc-admin.json`. The
`checkScript` field in each policy is a string of PowerShell code that is
converted to a `[scriptblock]` at load time via `[scriptblock]::Create()`.

This is functionally equivalent to `Invoke-Expression` — it executes arbitrary
code from a configuration file. Anyone with write access to `gc-admin.json`
can execute arbitrary PowerShell in the process context, with full access to
the active API token.

### Decision

- Config-sourced `checkScript` execution is **allowed** because it is the
  intended use case of the guardrail engine (policy-as-code for org governance)
- A `Write-Warning` is emitted for each custom policy loaded from config so
  operators are never surprised
- A blocklist of obviously dangerous patterns is checked before execution
  (e.g., `Invoke-Expression`, `Start-Process`, `DownloadFile`, etc.)
- A `-NoConfigScripts` switch is added to `Initialize-GcAdmin` to disable
  config-sourced script execution entirely for high-trust-required environments
- **The real security control is filesystem ACLs on `gc-admin.json`**, not
  code-level filtering. The blocklist is defence-in-depth, not a security boundary.
- `gc-admin.json` MUST NOT be world-writable in production deployments

### Consequences

- Guardrail engine retains its full expressive power for legitimate use
- Operators in high-security environments can disable custom scripts entirely
- The blocklist will miss novel injection patterns — it is not a trust boundary
- This decision should be revisited if the tool is ever deployed in a multi-tenant
  or shared-config environment where untrusted users can write to the config file

---

## ADR-004: Genesys.Core Integration — Frontend/Backend Split

**Status**: DECIDED — AGenesysToolKit is the frontend; Genesys.Core is the optional backend.

**Date**: 2026-02-21

### Context

[Genesys.Core](https://github.com/xfaith4/Genesys.Core) is a companion repository:
a catalog-driven, batch data collection engine that executes governed Genesys Cloud
dataset runs and produces deterministic, auditable artifacts:

```text
out/<dataset>/<runId>/
  manifest.json   — dataset key, run window, git SHA, item counts, warnings
  events.jsonl    — structured trace of every retry, 429 backoff, and pagination step
  summary.json    — fast "coffee view" summary
  data/*.jsonl    — normalized, PII-redacted dataset records
```

Its own AGENTS.md states the design intent: *"UIs must be clients of the Core — not
reimplementations of the Core."*

AGenesysToolKit's Core/ modules independently reimplemented several of the same
concerns: HTTP retry with Retry-After, pagination (nextUri/pageNumber/cursor/async
jobs), and bulk data fetches for users, queues, and analytics. AGenesysToolKit also
provides capabilities Genesys.Core has no equivalent for: OAuth PKCE, WebSocket
subscriptions, timeline reconstruction, incident packet generation, and a WPF UI.

### Decision

Adopt Genesys.Core as an **optional** backend dependency. Integration is:

- **Opt-in at runtime**: discovered automatically if present; absent if not.
  The application starts and runs fully without it.
- **Never bundled**: Genesys.Core remains its own repository. Users who want
  the extended dataset capabilities clone it separately.
- **Auth-bridged**: AGenesysToolKit holds the OAuth token from its PKCE flow and
  passes `@{ Authorization = "Bearer $token" }` to `Invoke-Dataset`. Genesys.Core
  has no auth layer; it only accepts headers.

### The Seam

```text
AGenesysToolKit (WPF frontend)
  └─ App/CoreIntegration.ps1         → discovery, load, status
  └─ AppState.GcCoreAvailable        → $true once module is loaded

Genesys.Core (PowerShell module backend)
  └─ Invoke-Dataset -Dataset <key> -Headers $headers -OutputRoot $artifactsDir
  └─ out/<dataset>/<runId>/...       → read by AGenesysToolKit display layer
```

### Discovery Chain (priority order)

| Priority | Source | Notes |
| --- | --- | --- |
| 1 | `gc-admin.json` → `genesysCore.modulePath` | Saved from a previous session or manual config |
| 2 | `GC_CORE_MODULE_PATH` env var | CI/CD pipelines, advanced users |
| 3 | Sibling directory convention | `../Genesys.Core/src/ps-module/Genesys.Core/Genesys.Core.psd1` — the standard GitHub side-by-side clone layout |
| 4 | PowerShell module path | `Get-Module -Name Genesys.Core -ListAvailable` — if installed via Install-Module |
| 5 | Not found | Graceful degradation; UI shows "Core: not found" chip in status bar |

### What AGenesysToolKit Owns (stays in this repo)

| Capability | Reason |
| --- | --- |
| OAuth PKCE | Genesys.Core accepts headers; it has no auth layer |
| WebSocket subscriptions | Genesys.Core is batch-only; streaming is incompatible |
| Timeline reconstruction + incident packets | No equivalent in Genesys.Core |
| Guardrail/policy engine | Domain-specific governance; not a data collection concern |
| Runspace-based job runner | UI-responsive threading is a UI concern |
| Offline demo mode | `GC_TOOLKIT_OFFLINE_DEMO` bypasses HTTP at the `Invoke-GcRequest` level; Genesys.Core always makes live calls |
| WPF workspaces | Presentation is the frontend's job |

### What Genesys.Core Provides (net-new, no equivalent in AGenesysToolKit)

- Audit logs (`audit-logs` dataset — async submit/poll/results)
- API usage by org, client, user (`usage.*` datasets)
- Organization details and rate limits (`organization.*` datasets)
- All divisions (`authorization.get.all.divisions`)
- 26 additional catalog-derived datasets synchronized from the Genesys Cloud Swagger
- PII redaction layer (`Protect-RecordData`) applied automatically before artifact write
- Structured run events per page/retry for full observability of data collection mechanics

### Consequences

**Positive:**

- AGenesysToolKit gains 31 datasets of coverage without writing new HTTP code
- Clean architectural boundary: data collection vs. data presentation
- Users who only need the WPF UI are unaffected; Genesys.Core is purely optional
- Both repositories can evolve independently without coupling

**Negative:**

- Offline demo mode (`GC_TOOLKIT_OFFLINE_DEMO`) does not suppress Genesys.Core HTTP
  calls. Offline mode for Core-backed dataset views requires the `-RequestInvoker`
  injectable mock parameter in `Invoke-Dataset`.
- AGenesysToolKit must read JSONL files from `data/*.jsonl` to display Core dataset
  output; the existing in-memory object model does not apply.
- If Genesys.Core's output contract changes, the AGenesysToolKit display layer must
  be updated accordingly.

### Action Items

1. ✅ `App/CoreIntegration.ps1` — discovery engine with 4-level fallback chain
2. ✅ `App/Shell.xaml` — Core status indicator in status bar + Integration tab in Backstage
3. ✅ `App/gc-admin.json` — `genesysCore.modulePath` field added
4. Build Audit Logs view as the first dataset-backed workspace (next sprint)
5. Establish the `Read-GcCoreDataset` helper pattern for loading JSONL output into WPF DataGrids
