# Contributing to AGenesysToolKit

Thank you for your interest in contributing to AGenesysToolKit! This document provides guidelines and best practices for contributing to the project.

## Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Code Standards](#code-standards)
- [Testing Guidelines](#testing-guidelines)
- [Pull Request Process](#pull-request-process)
- [Code Review](#code-review)
- [Documentation](#documentation)

## Getting Started

### Prerequisites

- PowerShell 5.1 or PowerShell 7+
- Windows OS (for WPF UI components)
- Git for version control
- A Genesys Cloud OAuth client for testing (see [CONFIGURATION.md](docs/CONFIGURATION.md))
- PSScriptAnalyzer for code linting: `Install-Module -Name PSScriptAnalyzer -Scope CurrentUser`

### First-Time Setup

1. **Fork and Clone**

   ```powershell
   # Fork the repository on GitHub first, then clone your fork
   git clone https://github.com/xfaith4/AGenesysToolKit.git
   cd AGenesysToolKit

   # Add upstream remote for syncing with main repository
   git remote add upstream https://github.com/xfaith4/AGenesysToolKit.git
   ```

2. **Run Smoke Tests**

   ```powershell
   ./tests/smoke.ps1
   ```

   All tests should pass (10/10).

3. **Configure OAuth Credentials**
   Follow the [CONFIGURATION.md](docs/CONFIGURATION.md) guide to set up OAuth credentials for testing.

4. **Read Key Documentation**
   - [ARCHITECTURE.md](docs/ARCHITECTURE.md) - Core contracts and design patterns
   - [STYLE.md](docs/STYLE.md) - Coding conventions and best practices
   - [ROADMAP.md](docs/ROADMAP.md) - Project direction and feature plans

## Development Setup

### Module Loading

All core modules are in the `/Core` directory. To test a module during development:

```powershell
# Import module with force reload
Import-Module ./Core/HttpRequests.psm1 -Force

# Test that functions are available
Get-Command -Module HttpRequests
```

### Running Tests

```powershell
# Run smoke tests (module loading verification)
./tests/smoke.ps1

# Run JobRunner tests
./tests/test-jobrunner.ps1

# Run parameter flow tests
./tests/test-parameter-flow.ps1

# Run all tests
Get-ChildItem ./tests/test-*.ps1 | ForEach-Object { & $_.FullName }
```

### Linting Your Code

```powershell
# Install PSScriptAnalyzer if not already installed
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force

# Lint a specific file
Invoke-ScriptAnalyzer -Path ./Core/YourModule.psm1 -Settings ./PSScriptAnalyzerSettings.psd1

# Lint all Core modules
Get-ChildItem ./Core/*.psm1 | ForEach-Object {
    Write-Host "Analyzing: $($_.Name)" -ForegroundColor Cyan
    Invoke-ScriptAnalyzer -Path $_.FullName -Settings ./PSScriptAnalyzerSettings.psd1
}
```

## Code Standards

### Function Naming Convention

All public functions MUST follow the `Verb-GcNoun` pattern:

✅ **Good:**

```powershell
function Get-GcUser { }
function Invoke-GcRequest { }
function Start-GcJob { }
```

❌ **Bad:**

```powershell
function Gc-GetUser { }      # Wrong order
function FetchUser { }       # Missing Gc prefix
function Fetch-GcUser { }    # 'Fetch' is not approved verb
```

See [Approved PowerShell Verbs](https://docs.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands).

### Parameter Standards

- Use `[Parameter(Mandatory)]` for required parameters
- Use strong typing: `[string]`, `[int]`, `[hashtable]`, etc.
- Add parameter validation where appropriate: `[ValidateNotNullOrEmpty()]`
- Use `[CmdletBinding()]` for advanced function features

```powershell
function Get-GcUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$UserId,

        [string]$AccessToken,

        [string]$InstanceName = 'mypurecloud.com'
    )

    # Implementation...
}
```

### Comment-Based Help

All public functions MUST include comment-based help:

```powershell
function Get-GcUser {
    <#
    .SYNOPSIS
        Retrieves a user by ID from Genesys Cloud.

    .DESCRIPTION
        Fetches user details including name, email, roles, and department
        using the Genesys Cloud API.

    .PARAMETER UserId
        The unique identifier (GUID) of the user.

    .PARAMETER AccessToken
        OAuth bearer token for authentication.

    .EXAMPLE
        Get-GcUser -UserId 'abc-123-def' -AccessToken $token

    .EXAMPLE
        $users | ForEach-Object { Get-GcUser -UserId $_.id -AccessToken $token }

    .OUTPUTS
        PSCustomObject representing the user.
    #>
    # Implementation...
}
```

### Error Handling

- **Fail fast**: Validate inputs early
- **Fail loud**: Throw exceptions with context
- **No silent failures**: Don't catch and ignore errors

```powershell
# Good error handling
if (-not $JobId) {
    throw "JobId parameter is required for Get-GcJobStatus"
}

try {
    $response = Invoke-GcRequest -Path $path -Method GET -AccessToken $AccessToken
} catch {
    throw "Failed to fetch job status for JobId=$JobId. Error: $($_.Exception.Message)"
}
```

### HTTP Calls

ALL HTTP calls MUST go through the core primitives:

✅ **Good:**

```powershell
# Single request
$user = Invoke-GcRequest -Path '/api/v2/users/me' -Method GET -AccessToken $token

# Paginated request
$allUsers = Invoke-GcPagedRequest -Path '/api/v2/users' -Method GET -AccessToken $token
```

❌ **Bad:**

```powershell
# Don't bypass the core primitives
$user = Invoke-RestMethod -Uri "https://api.usw2.pure.cloud/api/v2/users/me" -Headers $headers
```

**Why?** Centralization ensures consistent error handling, retry logic, logging, and rate limiting.

## Testing Guidelines

### Test Structure

- Tests are in `/tests` directory
- Name test files: `test-*.ps1` (e.g., `test-my-feature.ps1`)
- Tests should be self-contained and idempotent

### Writing Tests

```powershell
# tests/test-my-feature.ps1

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test: My Feature" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$ErrorCount = 0

# Test 1
Write-Host "`nTest 1: Module loads successfully"
try {
    Import-Module ./Core/MyModule.psm1 -Force
    Write-Host "  [PASS] Module loaded" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    $ErrorCount++
}

# Test 2
Write-Host "`nTest 2: Function exists"
$cmd = Get-Command Get-GcMyFunction -ErrorAction SilentlyContinue
if ($cmd) {
    Write-Host "  [PASS] Function exists" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Function not found" -ForegroundColor Red
    $ErrorCount++
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
if ($ErrorCount -eq 0) {
    Write-Host "All tests passed!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$ErrorCount tests failed" -ForegroundColor Red
    exit 1
}
```

### Test Coverage Expectations

- **Smoke tests**: Module loads, key functions exist
- **Unit tests**: Function behavior with mocked dependencies
- **Integration tests**: End-to-end with live API (optional, requires credentials)

## Pull Request Process

### Before Submitting

1. **Run all tests** and ensure they pass

   ```powershell
   ./tests/smoke.ps1
   ./tests/test-jobrunner.ps1
   ```

2. **Lint your code** and fix issues

   ```powershell
   Invoke-ScriptAnalyzer -Path ./Core/YourModule.psm1 -Settings ./PSScriptAnalyzerSettings.psd1
   ```

3. **Update documentation** if you've changed:
   - Function signatures
   - Core contracts or behavior
   - Configuration requirements

4. **Test manually** with the UI if you've changed app-facing code:

   ```powershell
   ./App/GenesysCloudTool.ps1
   ```

### PR Guidelines

- **One feature per PR**: Keep changes focused and reviewable
- **Descriptive title**: "Add pagination support for user endpoints" not "Update code"
- **Clear description**: Explain what changed and why
- **Link issues**: Reference related issues with `Fixes #123` or `Relates to #456`
- **Include tests**: Add or update tests for your changes
- **Update ROADMAP.md**: If you've completed a planned feature

### PR Template

```markdown
## Description
Brief description of what this PR does.

## Changes
- Added X function to Y module
- Updated Z documentation
- Fixed bug in A

## Testing
- [ ] Smoke tests pass
- [ ] New tests added/updated
- [ ] Manual testing completed
- [ ] Linting passes

## Related Issues
Fixes #123

## Checklist
- [ ] Code follows style guide
- [ ] Documentation updated
- [ ] Tests pass
- [ ] No secrets committed
```

## Code Review

### What Reviewers Look For

1. **Code Quality**
   - Follows naming conventions
   - Has proper error handling
   - Includes comment-based help
   - No hardcoded secrets or credentials

2. **Testing**
   - Tests exist and pass
   - Test coverage is adequate
   - Edge cases are considered

3. **Documentation**
   - README.md updated if needed
   - Architecture documentation reflects changes
   - Comments explain non-obvious logic

4. **Compatibility**
   - Works in PowerShell 5.1 and 7+
   - No breaking changes to existing APIs
   - Backward compatibility maintained

### Responding to Feedback

- Be receptive to suggestions
- Ask questions if feedback is unclear
- Make requested changes or explain why not
- Mark conversations as resolved when addressed

## Documentation

### When to Update Documentation

Update documentation when you:

- Add new public functions
- Change function signatures or behavior
- Add new modules or major features
- Change configuration requirements
- Fix bugs that were caused by unclear documentation

### Documentation Files

- **README.md**: Overview, quick start, project structure
- **docs/ARCHITECTURE.md**: Core contracts, design patterns, workspaces
- **docs/STYLE.md**: Coding conventions and best practices
- **docs/CONFIGURATION.md**: Setup and configuration instructions
- **docs/ROADMAP.md**: Development phases and version history
- **docs/TESTING.md**: Testing guidelines and procedures

### Documentation Style

- Use clear, concise language
- Include code examples
- Provide both simple and advanced examples
- Keep it up-to-date with code changes
- Use proper markdown formatting

## Common Tasks

### Adding a New Module

1. Create module file: `Core/MyModule.psm1`
2. Add comment-based help to module
3. Implement functions following naming conventions
4. Export public functions: `Export-ModuleMember -Function Get-GcMyFunction`
5. Add smoke test in `tests/smoke.ps1`
6. Update README.md to list the new module
7. Update ARCHITECTURE.md if it introduces new patterns

### Adding a New API Endpoint

1. Determine if it's a single call or paginated
2. Use `Invoke-GcRequest` or `Invoke-GcPagedRequest`
3. Add to appropriate module (or create new one)
4. Include AccessToken and InstanceName parameters
5. Add comment-based help
6. Write tests
7. Document in ARCHITECTURE.md if needed

### Fixing a Bug

1. Write a test that reproduces the bug
2. Fix the bug
3. Verify the test now passes
4. Check that existing tests still pass
5. Document the fix in commit message
6. Consider if documentation needs updating

## Questions?

- **General questions**: Open an issue with the `question` label
- **Bug reports**: Open an issue with the `bug` label
- **Feature requests**: Open an issue with the `enhancement` label

## Thank You!

Your contributions make AGenesysToolKit better for everyone. We appreciate your time and effort! 🎉
