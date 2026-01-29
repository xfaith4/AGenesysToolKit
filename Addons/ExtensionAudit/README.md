# Genesys Cloud Extension Audit & Repair (PowerShell)

Audit Genesys Cloud user profile extensions against the Telephony **Extensions** inventory, generate a **dry-run change plan**, and **repair missing assignments** by re-asserting the extension on the user profile (with required `version` bump).

This tool is designed for **safe, observable operations**: it produces reviewable CSV reports, logs every run, minimizes API calls, and avoids ambiguous auto-fixes (duplicates are routed to manual review).

---

## Features

### ✅ Audit & Reporting

- **Dry Run Report (Before/After plan)**
  Shows who *would* be patched, what they currently have, and the expected result.
- **Duplicate User Extension Assignments**
  Finds cases where **multiple users share the same profile extension** → manual review.
- **Duplicate Extension Records**
  Finds cases where **multiple extension records share the same number** → manual review.
- **Discrepancies**
  Finds cases where a user's **profile extension exists** in the Extensions list but is:
  - owned by a different user, or
  - owned by a non-USER ownerType.
- **Missing Assignments (Primary target)**
  Finds cases where a user has an extension on their profile **but no matching extension record exists**.

### 🔧 Repair

- **Patch Missing Assignments**
  Performs a controlled PATCH against the **User** record (increments `version` by +1) to re-assert the extension on the user's phone address entry.
  - Includes **`-WhatIf` support**.
  - Produces Updated/Skipped/Failed CSVs.

### 📈 Monitoring & Observability

- `Write-Log` with log levels (DEBUG/INFO/WARN/ERROR)
- Log file per run (timestamped)
- API call counters (method/path totals) for performance tuning

### ⚡ API Efficiency

- Users are fetched **once** (paged) and cached in memory.
- Extensions are fetched via:
  - **FULL crawl** if extension paging is small, OR
  - **TARGETED lookups** by distinct profile-extension numbers if the extension set is large.

---

## Repository Layout

```text
.
├── GcExtensionAudit.psm1          # PowerShell module (all functions)
├── GcExtensionAuditMenu.ps1       # CLI menu runner (options 1–5)
├── GcExtensionAuditUI.ps1         # Simple WPF UI runner
├── GcExtensionAuditUI.xaml        # UI layout (XAML)
├── out/                           # CSV exports (created at runtime)
└── logs/                          # Log files (created at runtime)
```

---

## Quick Start

### GUI (Recommended)

Runs a simple Windows (WPF) front-end for building context, generating reports, exporting CSVs, and running the patch in `-WhatIf` or real mode.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GcExtensionAuditUI.ps1
```

Notes:
- If you prefer, set `$env:GC_ACCESS_TOKEN` and check **Use $env:GC_ACCESS_TOKEN** in the UI.
- Exports go to `.\out\` and logs go to `.\logs\` (relative to `Addons/ExtensionAudit`).

### CLI Menu

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GcExtensionAuditMenu.ps1
```
