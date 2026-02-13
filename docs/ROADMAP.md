# AGenesysToolKit Roadmap

This roadmap outlines the phased development of the AGenesysToolKit, aligned with the UX prototype and the core vision of jobs-first, pagination-complete, decision-grade tooling.

---

## Phase 0: Repository Foundation ✅

**Goal**: Establish the project's "contract surface" so future phases don't drift.

**Deliverables**:
- [x] Canonical folder structure (`/Core`, `/App`, `/docs`, `/tests`, `/artifacts`)
- [x] Clear architecture documentation (`docs/ARCHITECTURE.md`)
- [x] Roadmap document (`docs/ROADMAP.md`)
- [x] Style guide (`docs/STYLE.md`)
- [x] Smoke tests that prove core modules load (`tests/smoke.ps1`)
- [x] `.gitignore` with proper exclusions (artifacts, secrets, logs)

**Acceptance Criteria**:
- `tests/smoke.ps1` runs cleanly in PowerShell 5.1 and 7+
- Core commands exist and can be loaded: `Invoke-GcRequest`, `Invoke-GcPagedRequest`, `Wait-GcAsyncJob`
- No secrets committed; artifacts directory is ignored
- Documentation clearly defines what goes where and what each core function guarantees

**Non-Goals** (explicitly excluded):
- ❌ Real OAuth implementation
- ❌ Refactoring UX prototype layout
- ❌ Implementing new Genesys endpoints
- ❌ Changing business logic beyond module loading requirements

---

## Phase 1: Core HTTP & Pagination Primitives ✅

**Goal**: Fully implement the two foundational HTTP functions with production-grade reliability.

**Status**: Complete - Delivered in v0.2.0

**Deliverables**:

### 1.1: `Invoke-GcRequest` Hardening
- Comprehensive error handling (4xx, 5xx, network errors)
- Configurable retry logic with exponential backoff
- Rate limit detection and automatic throttling (429 responses)
- Request/response logging (opt-in via `-Verbose`)
- Support for all HTTP methods (GET, POST, PUT, PATCH, DELETE)
- Path parameter substitution (e.g., `{conversationId}`)
- Query string encoding (including array parameters)
- Body serialization (automatic JSON conversion)
- Custom headers support
- Region/instance configuration (e.g., `usw2.pure.cloud`, `mypurecloud.com.au`)

### 1.2: `Invoke-GcPagedRequest` Implementation
- Support all pagination patterns:
  - `nextPage` / `nextUri` (full URL, relative path, query string)
  - `pageCount` / `pageNumber` (page-based)
  - `cursor` / `nextCursor` (cursor-based)
- Default behavior: retrieve entire dataset (no silent truncation)
- User controls: `-MaxPages`, `-MaxItems`, `-PageSize`
- Automatic item extraction from common response properties (`entities`, `results`, `conversations`, `items`, `data`)
- Progress callbacks for long-running pagination
- Parallel page fetching (experimental, opt-in)

### 1.3: Testing & Validation
- Unit tests for each pagination pattern
- Integration tests against live Genesys Cloud API (optional, requires credentials)
- Error scenario tests (network failures, rate limits, malformed responses)
- Performance benchmarks (large datasets, many pages)

**Acceptance Criteria** (All Met):
- ✅ `Invoke-GcRequest` handles all error cases gracefully with retries
- ✅ `Invoke-GcPagedRequest` retrieves complete datasets by default
- ✅ All pagination patterns supported and tested
- ✅ Rate limiting is automatic and transparent
- ✅ Verbose logging provides clear insight into request/response flow

---

## Phase 2: Core Jobs & Analytics Endpoints ✅

**Goal**: Implement the Job pattern for long-running operations, starting with analytics endpoints.

**Status**: Complete - Delivered in v0.3.0

**Deliverables**:

### 2.1: Job Pattern Implementation
- `Wait-GcAsyncJob`: Generic polling function with configurable timeout and interval
- Job status detection (FULFILLED, COMPLETED, SUCCESS, FAILED, ERROR, RUNNING)
- Timeout handling with clear error messages
- Progress tracking (if API supports it)

### 2.2: Analytics Conversation Details Jobs
- `Start-GcAnalyticsConversationDetailsJob`: Submit conversation details query
- `Get-GcAnalyticsConversationDetailsJobAvailability`: Check job availability
- `Get-GcAnalyticsConversationDetailsJobStatus`: Poll job status
- `Stop-GcAnalyticsConversationDetailsJob`: Cancel job
- `Get-GcAnalyticsConversationDetailsJobResults`: Fetch results (paginated)
- `Invoke-GcAnalyticsConversationDetailsQuery`: One-call helper (Submit → Poll → Fetch)

### 2.3: Analytics User Details Jobs
- `Start-GcAnalyticsUserDetailsJob`: Submit user details query
- `Get-GcAnalyticsUserDetailsJobAvailability`: Check job availability
- `Get-GcAnalyticsUserDetailsJobStatus`: Poll job status
- `Stop-GcAnalyticsUserDetailsJob`: Cancel job
- `Get-GcAnalyticsUserDetailsJobResults`: Fetch results (paginated)
- `Invoke-GcAnalyticsUserDetailsQuery`: One-call helper

### 2.4: Usage Query Jobs
- `Start-GcUsageAggregatesQueryJob`: Submit org usage query
- `Get-GcUsageAggregatesQueryJob`: Get job status and results
- `Start-GcClientUsageAggregatesQueryJob`: Submit client usage query
- `Get-GcClientUsageAggregatesQueryJob`: Get job status and results

### 2.5: Testing & Validation
- Unit tests for job status detection and polling logic
- Integration tests with live API (conversation details, user details, usage queries)
- Timeout and cancellation tests
- Error scenario tests (job failures, malformed responses)

**Acceptance Criteria** (All Met):
- ✅ All job functions work end-to-end (Submit → Poll → Fetch)
- ✅ Timeout and cancellation are reliable
- ✅ Results are paginated correctly (complete datasets by default)
- ✅ One-call helpers simplify common workflows
- ✅ Error messages are actionable

---

## Phase 3: UI Integration & Job Center ✅

**Goal**: Wire the UX prototype to the job engine, add Job Center UI, and implement export functionality.

**Status**: Complete - Delivered in v0.4.0, enhanced through v0.6.0

**Deliverables**:

### 3.1: Job Center UI
- Real-time job list with status, progress, and logs
- Cancel button for in-progress jobs
- View logs button to see detailed job execution
- Auto-refresh every 2 seconds
- Job history (completed/failed jobs remain visible)
- Clear all completed jobs button

### 3.2: UX Prototype → Job Engine Integration
- Replace mock timers with real job submissions
- Wire "Conversation Search" to `Invoke-GcAnalyticsConversationDetailsQuery`
- Wire "User Details" to `Invoke-GcAnalyticsUserDetailsQuery`
- Wire "Usage Query" to usage job functions
- Add progress tracking and status updates

### 3.3: Export Snackbar & Artifacts
- "Export" button in all data views
- Snackbar notification: "Exporting X items to JSON..." → "Export complete! [Open Folder]"
- Write files to `artifacts/` directory (gitignored)
- Support JSON, TXT formats (always available)
- Optional XLSX support (if `ImportExcel` module detected)
- Auto-open folder on completion

### 3.4: Error Handling & User Feedback
- Toast notifications for errors (with "View Details" button)
- Error details modal with full exception info
- Retry button for transient failures
- Cancel button for long-running operations

### 3.5: Testing & Validation
- End-to-end tests: Submit job → View in Job Center → Cancel → Export results
- Error scenario tests: Network failures, job failures, cancellations
- Performance tests: Large datasets, multiple concurrent jobs
- UX testing: Snackbar timing, toast visibility, button states

**Acceptance Criteria** (All Met):
- ✅ Job Center displays all active/completed jobs with real-time updates
- ✅ Users can cancel jobs and see immediate feedback
- ✅ Export works for all supported formats (JSON, TXT, optional XLSX)
- ✅ Snackbar notifications are clear and actionable
- ✅ Error messages provide context and recovery options
- ✅ No UI freezing or blocking during long operations

---

## Phase 4+: Future Enhancements (Backlog) 🔮

**Status**: Not Started - Deferred to v1.0.0 and beyond

These are potential future phases, subject to user feedback and prioritization. See [BACKLOG.md](./BACKLOG.md) for the complete list of planned future enhancements.

**Key Future Areas:**
- Enhanced OAuth (token refresh, secure storage)
- Additional workspaces & modules (Operations, Advanced Conversations)
- Performance optimizations (parallel pagination, caching, database backend)
- Advanced features (offline mode, dark mode, multi-org support)
- Testing & Quality improvements (>80% unit test coverage)

---

## Version History

**Completed Releases:**
- **v0.1.0** (Phase 0 ✅): Repository foundation, architecture, and smoke tests
- **v0.2.0** (Phase 1 ✅): Core HTTP & pagination primitives
- **v0.3.0** (Phase 2 ✅): Job pattern, OAuth authentication, and analytics endpoints
- **v0.4.0** (Phase 3 ✅): UI integration, Job Center, export packets, and timeline reconstruction
- **v0.5.0** (Modules 56%): 5 of 9 modules implemented
  - ✅ Conversations::Conversation Lookup
  - ✅ Conversations::Analytics Jobs
  - ✅ Conversations::Incident Packet (standalone)
  - ✅ Routing & People::Users & Presence
  - ✅ Orchestration::Config Export
- **v0.6.0** (Modules 100% ✅): All planned modules complete
  - ✅ Routing & People::Routing Snapshot - Real-time queue metrics with auto-refresh
  - ✅ Conversations::Abandon & Experience - Abandonment metrics and analysis
  - ✅ Conversations::Media & Quality - Recordings, transcripts, evaluations
  - ✅ Orchestration::Dependency / Impact Map - Flow reference search
  - ✅ All 9 planned modules fully implemented
  - ✅ 16 core modules in production
  - ✅ Smoke tests passing (10/10)

**Planned Releases:**
- **v1.0.0** (Future): Production-ready release with enhanced OAuth, token refresh, and secure storage

**Current Status**: v0.6.0 - All phases 0-3 complete, all 9 modules operational, 16 core modules in production

---

## Contributing

See `docs/STYLE.md` for coding conventions and contribution guidelines.

For questions or feature requests, open an issue on GitHub.
