# AGenesysToolKit - Future Enhancements Backlog

> **Consolidated list of planned future work beyond v0.6.0**

This document consolidates all unfinished and future planned work for AGenesysToolKit. All items in this backlog are subject to user feedback and prioritization.

**Current Status**: v0.6.0 - All phases 0-3 complete, all 9 modules operational  
**Next Milestone**: v1.0.0 - Production-ready release with enhanced OAuth

---

## Priority: High (v1.0.0 Candidates)

### OAuth & Authentication Enhancements

#### OAuth Token Refresh Logic
- **Status**: Not Started
- **Description**: Implement automatic OAuth token refresh before expiration
- **Benefits**: Seamless user experience, no re-authentication required
- **Effort**: Medium (2-3 days)
- **Dependencies**: Current OAuth implementation (v0.3.0)

#### Secure Token Storage
- **Status**: Not Started
- **Description**: Store OAuth tokens in Windows Credential Manager instead of memory
- **Benefits**: Tokens persist across sessions, enhanced security
- **Effort**: Small (1-2 days)
- **Dependencies**: Token refresh logic

#### Client Credentials Flow
- **Status**: Not Started
- **Description**: Support machine-to-machine authentication for automation scenarios
- **Benefits**: Enable scheduled tasks, CI/CD integration, service accounts
- **Effort**: Medium (3-4 days)
- **Dependencies**: None

---

## Priority: Medium (v1.1.0+)

### Additional Workspaces & Modules

#### Operations Workspace: Enhanced Topic Subscriptions
- **Status**: Infrastructure exists, needs UI polish
- **Description**: Real-time event monitoring with WebSocket-based subscriptions
- **Features**:
  - Presence monitoring (agent status changes)
  - Queue stats real-time updates
  - Conversation events (started, ended, transferred)
  - User-defined topic subscriptions
- **Effort**: Medium (3-5 days)
- **Dependencies**: Current Subscriptions.psm1

#### Conversations: Advanced Transcript Viewer
- **Status**: Basic transcript fetch exists
- **Description**: Enhanced transcript viewer with search, filtering, and export
- **Features**:
  - Syntax highlighting for different speakers
  - Search within transcript
  - Jump to specific timestamp
  - Export formatted transcript (PDF, DOCX)
- **Effort**: Large (1-2 weeks)
- **Dependencies**: Current ConversationsExtended.psm1

#### Conversations: Recording Downloads
- **Status**: URL retrieval implemented
- **Description**: Direct recording download and local playback
- **Features**:
  - Download recordings to local disk
  - In-app audio player (WPF MediaElement)
  - Batch download multiple recordings
  - Auto-organize by date/queue
- **Effort**: Medium (4-5 days)
- **Dependencies**: Current ConversationsExtended.psm1

#### Orchestration: User Management
- **Status**: Not Started
- **Description**: User creation, updates, role assignments
- **Features**:
  - User CRUD operations
  - Bulk user imports (CSV)
  - Role and skill assignment
  - User directory synchronization
- **Effort**: Large (1-2 weeks)
- **Dependencies**: RoutingPeople.psm1

#### Orchestration: Queue Management
- **Status**: Read operations exist
- **Description**: Queue creation, configuration, and monitoring
- **Features**:
  - Queue CRUD operations
  - Member assignment
  - Wrap-up code management
  - Queue routing rules
- **Effort**: Large (1-2 weeks)
- **Dependencies**: RoutingPeople.psm1

---

## Priority: Low (Future Consideration)

### Advanced Features

#### Multi-Org Support with Profile Switching
- **Status**: Not Started
- **Description**: Support multiple Genesys Cloud organizations with profile-based switching
- **Benefits**: Consultants, MSPs, and multi-org admins
- **Effort**: Large (2-3 weeks)
- **Dependencies**: Enhanced OAuth, secure storage

#### Offline Mode with Local Storage
- **Status**: Partial (OfflineDemo exists)
- **Description**: Cache data locally for offline analysis and demos
- **Benefits**: Demo mode, training environments, air-gapped analysis
- **Effort**: Large (2-3 weeks)
- **Dependencies**: None

#### Advanced Export Templates
- **Status**: JSON/TXT/XLSX exports exist
- **Description**: Custom CSV column selection, Excel formatting, branded PDFs
- **Benefits**: Custom reporting for executives, compliance requirements
- **Effort**: Medium (1 week)
- **Dependencies**: Current ArtifactGenerator.psm1

#### Export Scheduling
- **Status**: Not Started
- **Description**: Schedule recurring reports and exports
- **Benefits**: Daily/weekly operational reports, automated compliance exports
- **Effort**: Large (2-3 weeks)
- **Dependencies**: Windows Task Scheduler integration

#### Webhook/Event Forwarding
- **Status**: Not Started
- **Description**: Forward Genesys Cloud events to external systems (Slack, Teams, webhooks)
- **Benefits**: Integration with IT operations tools, custom alerting
- **Effort**: Large (2-3 weeks)
- **Dependencies**: Topic subscriptions

#### Dark Mode
- **Status**: Not Started
- **Description**: Dark theme for reduced eye strain
- **Benefits**: User preference, accessibility
- **Effort**: Medium (1 week)
- **Dependencies**: None

#### Accessibility Improvements
- **Status**: Not Started
- **Description**: Screen reader support, keyboard navigation, high contrast mode
- **Benefits**: Compliance with accessibility standards (WCAG 2.1)
- **Effort**: Large (3-4 weeks)
- **Dependencies**: None

---

## Performance & Scalability

### Parallel Pagination
- **Status**: Not Started
- **Description**: Fetch multiple pages simultaneously instead of sequentially
- **Benefits**: 3-5x faster for large datasets (10,000+ items)
- **Effort**: Medium (3-5 days)
- **Dependencies**: Current Invoke-GcPagedRequest
- **Risk**: Rate limiting, API throttling

### Streaming Results
- **Status**: Not Started
- **Description**: Display results as they arrive, don't wait for full dataset
- **Benefits**: Improved perceived performance, early access to data
- **Effort**: Medium (4-6 days)
- **Dependencies**: UI architecture changes

### Result Caching
- **Status**: Not Started
- **Description**: Cache frequently accessed resources (users, queues, skills) in memory
- **Benefits**: Reduced API calls, faster response times
- **Effort**: Medium (3-5 days)
- **Dependencies**: None

### Database Backend for Large Datasets
- **Status**: Not Started
- **Description**: Store large query results in SQLite for faster filtering and sorting
- **Benefits**: Handle 100,000+ items without memory issues
- **Effort**: Large (2-3 weeks)
- **Dependencies**: SQLite integration

---

## Testing & Quality

### Comprehensive Unit Test Coverage (>80%)
- **Status**: Basic smoke tests exist (10 tests)
- **Description**: Unit tests for all core modules with Pester
- **Benefits**: Confidence in changes, regression prevention
- **Effort**: Very Large (4-6 weeks)
- **Dependencies**: Pester test infrastructure

### Integration Test Suite with Mock API Server
- **Status**: Not Started
- **Description**: Mock Genesys Cloud API for integration testing
- **Benefits**: Test without live credentials, faster CI/CD
- **Effort**: Large (2-3 weeks)
- **Dependencies**: Mock server implementation

### UI Automation Tests
- **Status**: Not Started
- **Description**: Automated UI testing with Pester + WPF testing frameworks
- **Benefits**: Catch UI regressions, validate workflows
- **Effort**: Very Large (4-6 weeks)
- **Dependencies**: WPF testing framework

### Performance Benchmarks
- **Status**: Not Started
- **Description**: Automated performance tests and regression detection
- **Benefits**: Prevent performance degradation, validate optimizations
- **Effort**: Medium (1-2 weeks)
- **Dependencies**: Benchmarking infrastructure

### Security Audits
- **Status**: Manual audit complete (v0.6.0)
- **Description**: Regular automated security scanning with CodeQL, Bandit, etc.
- **Benefits**: Early vulnerability detection, compliance
- **Effort**: Medium (1 week setup, ongoing maintenance)
- **Dependencies**: CI/CD integration

---

## Backlog Management

### How to Use This Backlog

1. **Prioritization**: Items are grouped by priority (High/Medium/Low)
2. **Effort Estimates**: Rough estimates to aid planning
3. **Dependencies**: Prerequisites that must be completed first
4. **Status**: Current implementation status

### Contributing to This Backlog

- To request a new feature, open a GitHub issue with the `enhancement` label
- To propose changes to priorities, discuss in GitHub Discussions
- Pull requests addressing backlog items should reference this document

### Periodic Review

This backlog should be reviewed quarterly to:
- Re-prioritize items based on user feedback
- Remove obsolete items
- Add newly identified enhancements
- Update effort estimates based on learnings

---

**Last Updated**: 2026-02-13  
**Version**: v0.6.0  
**Next Review**: 2026-05-13 (Quarterly)

---

## Related Documentation

- [ROADMAP.md](./ROADMAP.md) - Completed phases 0-3
- [CHANGELOG.md](../CHANGELOG.md) - Version history
- [CONTRIBUTING.md](../CONTRIBUTING.md) - How to contribute
- [Archive/REMAINING_WORK.md](./Archive/REMAINING_WORK.md) - Historical work tracking
