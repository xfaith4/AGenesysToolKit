# Feature Audit - 2026-02-13

## Scope
This audit focuses on feature readiness of the PowerShell UX app and core modules, based on:

- Static code inspection of `App/GenesysCloudTool_UX_Prototype.ps1` and `Core/*.psm1`.
- Local command checks available in this execution environment.
- A "no token" baseline expectation: an API response (401/403) is considered a successful plumbing check.

## Environment constraints
- `pwsh` is not available in this environment, so built-in PowerShell test suites cannot be executed here.
- Outbound calls to `https://api.usw2.pure.cloud` fail at proxy tunnel setup (`CONNECT tunnel failed, response 403`), so live unauthorized-response tests cannot be completed from this runner.

## What was validated successfully

### 1) Feature inventory and UI route wiring
All major workspaces and modules are present and route to concrete view factories (not placeholders for the main functional paths):

- Orchestration: Flows, Data Actions, Dependency / Impact Map, Config Export
- Routing & People: Queues, Skills, Users & Presence, Routing Snapshot
- Conversations: Conversation Lookup, Conversation Timeline, Media & Quality, Abandon & Experience, Analytics Jobs, Incident Packet
- Operations: Topic Subscriptions, Operational Event Logs, Audit Logs, OAuth / Token Usage
- Reports & Exports: Report Builder, Export History, Quick Exports

### 2) Conversation detail report path (known working path)
The conversation-inspect report path is implemented end-to-end using Analytics Job pattern (submit -> poll -> fetch), then timeline generation and artifact output scaffolding. This aligns with your observation that conversation detail reporting is the one consistently working path.

### 3) Pagination/rate-limit primitives exist centrally
`Invoke-GcPagedRequest` and `Invoke-GcRequest` provide shared pagination/retry primitives used broadly by modules.

## Broken / high-risk findings

### A) "No token" baseline is blocked by current app behavior
Your requested baseline test case (feature is considered minimally successful if it receives unauthorized response without token) is currently prevented by design:

1. Primary action buttons are disabled unless token (or offline demo) is present.
2. App-level request wrapper throws before request dispatch when token is absent.

Impact: You cannot exercise real endpoint reachability from most modules in a no-token state.

### B) One concrete API method bug found
`Get-GcQualityEvaluations` calls `/api/v2/quality/evaluations/query` with `GET`; this endpoint is query-style and should be `POST` with body in typical Genesys API usage.

Impact: Media & Quality -> evaluations path is expected to fail or return no useful results even with valid auth.

### C) Multiple modules swallow API failures and return empty/null
Several feature modules catch exceptions and return empty arrays/`$null`, which makes broken API calls appear as "no results" instead of actionable failures.

Impact: This directly matches your symptom: features appear to run but produce nothing, while the underlying error gets hidden.

## Feature status matrix (current)

- **Likely functional (based on implemented flow and your report)**
  - Conversation Detail / Conversation Inspect Packet report

- **Implemented but currently blocked or opaque in failure mode**
  - Queues / Skills / Users & Presence
  - Routing Snapshot
  - Flows / Data Actions / Config Export / Dependency map
  - Conversation Lookup / Media & Quality / Abandon & Experience / Analytics Jobs / Incident Packet
  - Operational Event Logs / Audit Logs / OAuth Token Usage
  - Reports & Exports (except conversation-inspect path confidence)

- **Known broken by code defect**
  - Media & Quality evaluations query path (`GET` vs expected `POST`)

## Recommended next fixes (incremental)

1. **Enable no-token probe mode**
   - Add a per-module "Probe endpoint" action (or global toggle) that allows dispatch without token and surfaces HTTP status.

2. **Fix quality evaluations method mismatch**
   - Change `Get-GcQualityEvaluations` to `POST` and include required body/paging fields.

3. **Stop silent empty returns for API failures**
   - Return structured error payloads (status code, endpoint, message) to UI and render explicit error cards.

4. **Preserve deterministic artifacts**
   - For each feature run, write deterministic audit artifacts under `artifacts/feature-audit/<timestamp>/...` with redacted token fields.

5. **Add dedicated no-token smoke tests**
   - New tests should assert that endpoint probes return an HTTP status and never throw before network dispatch.

