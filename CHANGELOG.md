# Changelog

All notable changes to AGenesysToolKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- PSScriptAnalyzer configuration for consistent code quality
- Comprehensive CONTRIBUTING.md for developer onboarding
- Consolidated TESTING.md documentation
- SECURITY.md with security best practices
- DEPLOYMENT.md for production deployment guidance
- CI/CD workflow for automated testing and linting
- Enhanced .gitignore for comprehensive file exclusion

### Documentation
- Improved README.md with business value metrics
- Added cross-references between documentation files
- Enhanced onboarding documentation for new developers

## [0.6.0] - 2026-01-13

### Added - 100% Module Implementation Complete
- **Routing & People::Routing Snapshot** - Real-time queue metrics with auto-refresh
- **Conversations::Abandon & Experience** - Abandonment metrics and customer experience analysis
- **Conversations::Media & Quality** - Recordings, transcripts, and quality evaluations
- **Orchestration::Dependency / Impact Map** - Flow reference search and impact analysis

### New Modules
- `Core/Analytics.psm1` - Analytics aggregates and metrics
- `Core/Dependencies.psm1` - Dependency analysis and flow reference search

### Documentation
- `docs/REMAINING_WORK.md` - Updated to reflect 100% completion
- `docs/ROADMAP.md` - Updated with v0.6.0 achievements
- `docs/Archive/AUDIT_SUMMARY.md` - Comprehensive parameter flow audit (archived)

### Fixed
- Jobs.psm1 parameter passing (19 functions now properly pass AccessToken/InstanceName)

### Testing
- Added `test-parameter-flow.ps1` (34 tests)
- All test suites passing (56/56 tests)

## [0.5.0] - 2026-01-12

### Added
- **Conversations::Conversation Lookup** - Search and filter conversations
- **Conversations::Analytics Jobs** - Submit and monitor analytics queries
- **Conversations::Incident Packet** - Generate comprehensive export packets
- **Routing & People::Users & Presence** - User management and listing
- **Orchestration::Config Export** - Export configuration to JSON/ZIP

### Modules
- `Core/ConfigExport.psm1` - Configuration export functionality
- `Core/ConversationsExtended.psm1` - Extended conversation operations
- `Core/RoutingPeople.psm1` - User and routing management
- `Core/Reporting.psm1` - Report generation and artifact bundling
- `Core/ReportTemplates.psm1` - Reusable report templates

### Features
- Report templates system with HTML generation
- Artifact bundle creation and export history
- Metadata tracking for reports
- ZIP archive support for exports

## [0.4.0] - 2026-01-10

### Added
- **Real Export Packet Flow** - End-to-end incident packet generation
- **Incident Packet Generator** - Comprehensive ZIP archives with all artifacts
- **Conversation Timeline Reconstruction** - Unified event timeline
- **WebSocket Subscription Provider** - Real-time event streaming

### Modules
- `Core/Timeline.psm1` - Conversation timeline reconstruction
- `Core/ArtifactGenerator.psm1` - Incident packet generation
- `Core/Subscriptions.psm1` - WebSocket subscription provider

### Features
- Timeline window with sortable events
- Event correlation across data sources
- Subscription events integration
- Multiple export formats (JSON, NDJSON, TXT, MD, ZIP)

### Documentation
- `docs/TIMELINE_FEATURE.md` - Timeline feature documentation
- `docs/EXPORT_PACKET_IMPLEMENTATION.md` - Export packet details
- `docs/HOW_TO_TEST_JOBRUNNER.md` - JobRunner testing scenarios

## [0.3.0] - 2026-01-08

### Added
- **OAuth Authentication with PKCE** - Secure authentication flow
- **Background Job Runner (Runspaces)** - Non-blocking job execution
- **Start-AppJob Simplified API** - Easy job submission
- **Job Center UI** - Real-time job tracking and management

### Modules
- `Core/Auth.psm1` - OAuth authentication with PKCE
- `Core/JobRunner.psm1` - Background job execution (runspaces)

### Features
- OAuth PKCE flow with browser-based consent
- Runspace-based job execution (PowerShell 5.1 + 7 compatible)
- Thread-safe log streaming via ObservableCollection
- Cancellation support for jobs
- Status tracking: Queued/Running/Completed/Failed/Canceled
- Time tracking: StartTime/EndTime/Duration

### Documentation
- `docs/OAUTH_TESTING.md` - Comprehensive OAuth testing scenarios (12+ tests)
- `docs/HOW_TO_TEST.md` - Quick OAuth testing guide (5 minutes)
- `docs/JOBRUNNER_IMPLEMENTATION.md` - JobRunner implementation details

### Testing
- `tests/test-auth.ps1` - OAuth authentication tests
- `tests/test-jobrunner.ps1` - JobRunner tests (12 tests)

## [0.2.0] - 2026-01-05

### Added
- **Core HTTP Primitives** - `Invoke-GcRequest` and `Invoke-GcPagedRequest`
- **Job Pattern Implementation** - Submit → Poll → Fetch pattern
- **Analytics Job Endpoints** - Conversation and user details jobs

### Modules
- `Core/HttpRequests.psm1` - HTTP primitives
- `Core/Jobs.psm1` - Job pattern functions

### Features
- Comprehensive error handling (4xx, 5xx, network errors)
- Configurable retry logic with exponential backoff
- Rate limit detection and automatic throttling
- Multiple pagination patterns support (nextPage, cursor, pageNumber)
- Default behavior: retrieve entire dataset
- User controls: `-MaxPages`, `-MaxItems`, `-PageSize`

### Documentation
- `docs/ARCHITECTURE.md` - Core contracts and design patterns
- `docs/STYLE.md` - Coding conventions and best practices

### Testing
- `tests/smoke.ps1` - Smoke tests for module loading (10 tests)

## [0.1.0] - 2026-01-03

### Added
- **Repository Foundation** - Canonical folder structure
- **Documentation Framework** - Architecture, roadmap, style guide

### Structure
- `/Core` - Reusable PowerShell modules
- `/App` - Application entry points
- `/docs` - Documentation
- `/tests` - Test scripts
- `/artifacts` - Runtime output (gitignored)

### Documentation
- `README.md` - Project overview and quick start
- `docs/ARCHITECTURE.md` - Core contracts and design patterns
- `docs/ROADMAP.md` - Phased development plan
- `docs/STYLE.md` - Coding conventions
- `docs/CONFIGURATION.md` - Setup and configuration guide

### Configuration
- `.gitignore` - Proper exclusions for artifacts, secrets, logs

---

## Version History Summary

- **v0.6.0** (Current) - 100% module implementation complete (9 of 9 modules)
- **v0.5.0** - 56% module implementation (5 of 9 modules)
- **v0.4.0** - Export packet and timeline features
- **v0.3.0** - OAuth and JobRunner implementation
- **v0.2.0** - Core HTTP and job pattern primitives
- **v0.1.0** - Repository foundation

## Upgrade Guide

### From 0.5.x to 0.6.0

No breaking changes. New modules are additive.

**New Features Available**:
- Navigate to **Routing & People → Routing Snapshot** for real-time queue metrics
- Navigate to **Conversations → Abandon & Experience** for abandonment analysis
- Navigate to **Conversations → Media & Quality** for recordings and transcripts
- Navigate to **Orchestration → Dependency Map** for flow reference search

### From 0.4.x to 0.5.0

No breaking changes. New modules are additive.

**Configuration**: No changes required.

### From 0.3.x to 0.4.0

No breaking changes. New features for timeline and exports.

**Configuration**: No changes required.

### From 0.2.x to 0.3.0

**Breaking Change**: OAuth authentication now required.

**Migration Steps**:
1. Create OAuth client in Genesys Cloud Admin
2. Update `Set-GcAuthConfig` in main app with Client ID
3. Run application and authenticate via "Login..." button

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

## License

[To be determined]

---

**Maintained by**: xfaith4  
**Repository**: https://github.com/xfaith4/AGenesysToolKit
