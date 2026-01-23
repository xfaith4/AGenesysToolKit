# OfflineDemo Test Plan (Manual)

This plan validates all features intended to work without a real Genesys Cloud org by using the OfflineDemo sample-data router (`GC_TOOLKIT_OFFLINE_DEMO=1`).

## Prereqs

- Windows + PowerShell 7 recommended (PowerShell 5.1 should work for most scenarios)
- Repo root open: `AGenesysToolKit`

## Enable OfflineDemo

1. Launch the app:
   - `pwsh -NoProfile -File App/GenesysCloudTool_UX_Prototype.ps1`
2. Right-click `Login…` → `Offline Demo: Enable`
3. Optional: right-click `Login…` → `Offline Demo: Seed Sample Events`
4. (Optional but recommended) turn on tracing for troubleshooting:
   - Edit `App/GenesysCloudTool_UX_Prototype.ps1` and set:
     - `$EnableToolkitTrace = $true`
     - `$EnableToolkitTraceBodies = $true` (only if you need request bodies)
   - Right-click `Login…` → `Open Trace Log`

## Manual Test Checklist

### A. Global / Navigation

- [ ] Switch between each workspace and a few modules; no unhandled exceptions.
- [ ] Open Backstage (Jobs) while switching modules; logs update and remain responsive.
- [ ] Backstage → Artifacts shows exported files after any export below.

### B. Operations → Operational Event Logs

- [ ] Click `Query` and wait for the job to complete (should populate grid).
- [ ] Type into `Search events...` and verify filtering changes the result count.
- [ ] Click `Export JSON` and verify a file appears in Artifacts and can be opened.
- [ ] Click `Export CSV` and verify a file appears in Artifacts and can be opened.

### C. Operations → Audit Logs

- [ ] Click `Query` and verify results populate.
- [ ] Export JSON/CSV and verify artifacts are created.

### D. Operations → Topic Subscriptions

- [ ] Click connect/start (Offline demo should not require a real websocket).
- [ ] Verify status messages update and no crashes occur.
- [ ] If you seeded sample events, verify the live event grid has items and can be searched.

### E. Operations → Conversation Timeline

- [ ] Use conversation id `c-demo-001` and open the timeline view.
- [ ] Verify timeline shows multiple events and is time-sorted.
- [ ] Verify any “Export packet” actions create artifacts.

### F. Conversations → Search / Analytics (Offline)

- [ ] Run a conversation search (date range or explicit `c-demo-001`).
- [ ] Verify results populate and a selected conversation can be opened.
- [ ] Verify jobs complete and job logs show progress messages.

### G. Routing & People

- [ ] Load Queues and verify at least one queue appears.
- [ ] Load Users and verify at least one user appears.
- [ ] Refresh Routing Snapshot and verify metrics populate.

### H. Orchestration

- [ ] Load Flows and verify at least one flow appears.
- [ ] Open a flow configuration (latest configuration) and verify content loads.
- [ ] Load Data Actions and verify at least one action appears.

### I. Media & Quality (Offline)

- [ ] Load Recordings and verify at least one recording appears.
- [ ] Open recording media and verify a URL is produced (offline placeholder is OK).
- [ ] Load Quality Evaluations and verify at least one evaluation appears.

## What to Capture When Something Fails

- Backstage → Jobs → select the failed job → copy the job logs
- Trace file (right-click `Login…` → `Open Trace Log`)
- If an artifact was expected but missing, note the module + button pressed + timestamp

