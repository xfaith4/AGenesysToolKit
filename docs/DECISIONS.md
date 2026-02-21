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
| Primary UI | PowerShell + WPF/XAML | `App/GenesysCloudTool_UX_Prototype.ps1` | ~10,400 lines, fully featured |
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

## ADR-002: Monolith Decomposition — App/GenesysCloudTool_UX_Prototype.ps1

**Status**: IN PROGRESS

**Date**: 2026-02-21

### Context

The primary application file (`App/GenesysCloudTool_UX_Prototype.ps1`) was
~10,700 lines at the time this decision was recorded. It contains:
- XAML helper utilities
- The main window XAML definition
- Application state management
- ~25 workspace view functions, each containing inline XAML + event handlers
- Authentication UI
- Job monitoring UI
- All WPF event wiring

This makes the file impossible to unit test (UI and logic are fused), expensive
to merge (every feature change touches the same file), and difficult to navigate.

### Decision

Decompose incrementally by extraction, not by rewrite. Each extraction step
should be independently verifiable (run the app, confirm it loads).

**Decomposition order (priority):**

1. **Utilities** — Functions with no UI dependency
   - `App/XamlHelpers.ps1` — `Escape-GcXml`, `ConvertFrom-GcXaml` ✅ DONE
   - `App/AppLogger.ps1` — `Write-GcAppLog`, `ConvertTo-GcAppLogSafeData` (duplicates Core/ patterns)

2. **Shell XAML** — External file, loaded at startup
   - `App/Shell.xaml` — Main window, backstage, snackbar ✅ DONE

3. **Per-workspace view files** — Each workspace becomes its own file
   - `App/Views/Operations/` — Subscriptions, presence, queue stats
   - `App/Views/Conversations/` — Lookup, analytics jobs, packet, media, abandonment
   - `App/Views/RoutingPeople/` — Users, routing snapshot
   - `App/Views/Orchestration/` — Config export, dependency map
   - `App/Views/Reports/` — Report views

4. **AppState module** — `$script:AppState` extracted to `App/AppState.ps1`
   with explicit init and accessor functions

5. **File rename** — Once the main file contains only orchestration logic
   (wiring views to state), rename from `GenesysCloudTool_UX_Prototype.ps1`
   to `GenesysCloudTool.ps1`

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
