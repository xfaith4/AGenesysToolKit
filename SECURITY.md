# Security Policy

## Overview

AGenesysToolKit handles sensitive information including OAuth tokens, API credentials, and customer data from Genesys Cloud. This document outlines security best practices and our approach to handling security vulnerabilities.

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.6.x   | :white_check_mark: |
| < 0.6   | :x:                |

## Security Best Practices

### 1. OAuth Token Handling

#### ✅ DO

- **Use OAuth PKCE flow**: The toolkit implements Proof Key for Code Exchange (PKCE) for secure authentication
- **Store tokens in memory only**: Tokens are never persisted to disk
- **Clear tokens on logout**: Use `Clear-GcTokenState` to remove tokens from memory
- **Use short-lived tokens**: Configure appropriate token expiration in Genesys Cloud OAuth client

```powershell
# Good: Clear token when done
Clear-GcTokenState

# Good: Token validation
$isValid = Test-GcToken -AccessToken $token
if (-not $isValid) {
    # Re-authenticate
}
```

#### ❌ DON'T

- **Never log tokens in plain text**: The toolkit automatically redacts tokens in logs
- **Never commit tokens to version control**: `.gitignore` excludes `*.token` files
- **Never hardcode credentials**: Always use configuration files or environment variables

```powershell
# Bad: Hardcoded credentials
$clientId = "abc123..."  # DON'T DO THIS

# Good: Configuration file
Set-GcAuthConfig -ClientId $config.ClientId
```

### 2. Secrets Management

#### Configuration Files

- **Never commit secrets**: Use `.gitignore` to exclude sensitive files
- **Use separate config files**: Store credentials in gitignored config files

```powershell
# .gitignore includes:
*.token
*.secrets.json
*.log
```

#### OAuth Client Configuration

1. **Create OAuth client in Genesys Cloud Admin**
   - Use Authorization Code Grant with PKCE
   - Set minimal required scopes
   - Configure redirect URI: `http://localhost:8080/oauth/callback`

2. **Store Client ID securely**
   - Edit `App/GenesysCloudTool_UX_Prototype_v2_1.ps1`
   - Update `Set-GcAuthConfig` section
   - Do NOT commit if Client ID is sensitive

3. **Never share Client Secret**
   - PKCE flow does NOT require client secret
   - If using other flows, NEVER commit secrets

### 3. API Access Control

#### Principle of Least Privilege

Configure OAuth clients with minimal required permissions:

**Required Scopes (Minimum)**:
- `authorization:readonly` - Read user roles and permissions
- `users:readonly` - Read user information
- `analytics:readonly` - Read analytics data
- `conversations:readonly` - Read conversation details

**Optional Scopes** (based on features used):
- `routing:readonly` - Read queue and routing configuration
- `architect:readonly` - Read flows and configuration
- `quality:readonly` - Read quality evaluations
- `recordings:readonly` - Access recording media

#### Token Validation

Always validate tokens before use:

```powershell
# Validate token before API calls
try {
    $userInfo = Test-GcToken -AccessToken $token
    Write-Host "Token valid for: $($userInfo.name)"
} catch {
    Write-Error "Token validation failed: $($_.Exception.Message)"
    # Re-authenticate
}
```

### 4. Input Validation

#### Validate All User Inputs

```powershell
function Get-GcUser {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[a-f0-9-]{36}$')]  # GUID format
        [string]$UserId
    )
    
    # Additional validation
    if ($UserId -notmatch '^[a-f0-9-]{36}$') {
        throw "UserId must be a valid GUID format"
    }
}
```

#### Sanitize Path Inputs

```powershell
# When accepting file paths, validate and sanitize
function Export-GcReport {
    param(
        [string]$OutputPath
    )
    
    # Resolve to absolute path and verify directory exists
    $resolvedPath = Resolve-Path -Path $OutputPath -ErrorAction Stop
    
    # Ensure path is within expected directory
    if ($resolvedPath -notlike "$PSScriptRoot\artifacts\*") {
        throw "Output path must be within artifacts directory"
    }
}
```

### 5. Error Handling

#### Don't Leak Sensitive Information

```powershell
# ❌ Bad: Exposes token
try {
    Invoke-GcRequest -AccessToken $token
} catch {
    throw "Request failed with token: $token"  # DON'T DO THIS
}

# ✅ Good: No sensitive data
try {
    Invoke-GcRequest -AccessToken $token
} catch {
    throw "Request failed. Error: $($_.Exception.Message)"
}
```

#### Use Token Redaction

```powershell
# The toolkit provides token redaction utility
Import-Module ./Core/Auth.psm1

# Logs will automatically redact tokens
Write-Verbose "Request with token: $(ConvertTo-GcAuthSafeString -AccessToken $token)"
# Output: "Request with token: eyJ...xyz (redacted)"
```

### 6. Secure Communication

#### HTTPS Only

All API communication uses HTTPS:

```powershell
# The toolkit enforces HTTPS
$baseUri = "https://api.$InstanceName"  # Always HTTPS

# Never use HTTP
# $baseUri = "http://api.$InstanceName"  # WRONG
```

#### Certificate Validation

PowerShell's `Invoke-RestMethod` validates SSL certificates by default. Don't disable this:

```powershell
# ❌ Don't do this (disables certificate validation)
# [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

# ✅ Trust the system certificate store
# (default behavior - no code needed)
```

### 7. Data Export Security

#### Protect Exported Files

```powershell
# Artifacts directory is gitignored
# artifacts/
# *.token
# *.secrets.json

# Set appropriate file permissions
$artifactPath = "./artifacts/export.json"
$acl = Get-Acl $artifactPath
$acl.SetAccessRuleProtection($true, $false)
# Only owner can read/write
Set-Acl -Path $artifactPath -AclObject $acl
```

#### Scrub Sensitive Data from Exports

```powershell
# When exporting conversations, be mindful of PII
function Export-GcConversation {
    param($ConversationId)
    
    $conversation = Get-GcConversationById -ConversationId $ConversationId
    
    # Consider redacting PII before export
    if ($conversation.participants) {
        foreach ($p in $conversation.participants) {
            # Optionally redact phone numbers, emails, etc.
            # $p.address = "REDACTED"
        }
    }
    
    $conversation | Export-Json -Path "./artifacts/conversation-$ConversationId.json"
}
```

### 8. Secure Coding Practices

#### Avoid Code Injection

```powershell
# ❌ Bad: Potential code injection
$query = $UserInput
Invoke-Expression $query  # DANGEROUS

# ✅ Good: Parameterized
$query = @{
    filter = $UserInput
}
Invoke-GcRequest -Body $query
```

#### Use Strong Typing

```powershell
# ✅ Good: Strong typing prevents type confusion
function Get-GcQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$QueueId,
        
        [ValidateRange(1, 500)]
        [int]$PageSize = 100
    )
}
```

## Reporting Security Vulnerabilities

### How to Report

**DO NOT** open a public issue for security vulnerabilities.

Instead:

1. **Email**: Send details to the repository maintainer (check GitHub profile for contact)
2. **Include**:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)
3. **Wait for response**: We'll acknowledge within 48 hours

### What to Expect

1. **Acknowledgment**: Within 48 hours
2. **Investigation**: We'll assess the vulnerability
3. **Fix Development**: We'll develop and test a fix
4. **Disclosure**: We'll coordinate public disclosure after fix is released
5. **Credit**: Security researchers will be credited (if desired)

### Vulnerability Disclosure Timeline

- **Day 0**: Vulnerability reported
- **Day 1-2**: Acknowledgment sent
- **Day 3-7**: Investigation and assessment
- **Day 7-14**: Fix development and testing
- **Day 14-21**: Release and disclosure

## Security Checklist for Contributors

Before submitting code:

- [ ] No hardcoded credentials or secrets
- [ ] Tokens are redacted in logs
- [ ] Input validation on all user inputs
- [ ] Error messages don't leak sensitive data
- [ ] HTTPS used for all API communication
- [ ] No `Invoke-Expression` with user input
- [ ] Sensitive files in `.gitignore`
- [ ] Strong typing on parameters
- [ ] OAuth best practices followed

## Security Audit History

| Date | Version | Auditor | Summary |
|------|---------|---------|---------|
| 2026-01-14 | 0.6.0 | Development Team | Parameter flow audit - All modules pass |
| 2026-01-14 | 0.6.0 | Development Team | Auth module security review - No issues |

**Note**: Organizations should conduct independent security audits before production deployment.

## Known Security Considerations

### 1. Token Storage in Memory

**Risk**: Tokens stored in memory could be dumped if PowerShell process is compromised

**Mitigation**: 
- Use short-lived tokens
- Clear tokens on logout
- Run with least privilege

### 2. Localhost OAuth Callback

**Risk**: Callback server binds to localhost:8080

**Mitigation**:
- Only binds to localhost (not 0.0.0.0)
- Closes immediately after callback
- Uses unpredictable state parameter

### 3. Exported Artifacts

**Risk**: Exported files may contain sensitive customer data

**Mitigation**:
- Artifacts directory is gitignored
- Users responsible for securing exported files
- Documentation warns about PII in exports

### 4. WebSocket Subscriptions

**Risk**: WebSocket connections may persist sensitive data

**Mitigation**:
- Subscriptions use authenticated WebSocket connection
- Events stored in memory only
- Connections properly closed on shutdown

## Compliance Considerations

### GDPR

If processing EU customer data:

- **Right to be forgotten**: Delete exported artifacts when no longer needed
- **Data minimization**: Export only required fields
- **Purpose limitation**: Use data only for intended purpose (incident investigation)
- **Security**: Follow all security practices in this document

### Data Retention

- **In-memory only**: Tokens and API responses not persisted
- **Exported artifacts**: User responsibility to manage retention
- **Logs**: Ensure logs don't contain PII or tokens

## Additional Resources

- [OAuth 2.0 Best Practices](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-security-topics)
- [PKCE RFC 7636](https://datatracker.ietf.org/doc/html/rfc7636)
- [OWASP PowerShell Security Guide](https://owasp.org/www-community/vulnerabilities/)
- [PowerShell Security Best Practices](https://docs.microsoft.com/en-us/powershell/scripting/learn/security-best-practices)

## Questions?

For security questions (non-vulnerability):
- Open an issue with the `security` label
- Check existing security documentation
- Review `docs/CONFIGURATION.md` for OAuth setup

---

**Last Updated**: 2026-01-14  
**Version**: 0.6.0
