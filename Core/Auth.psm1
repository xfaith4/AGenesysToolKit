### BEGIN: Core.Auth.psm1

Set-StrictMode -Version Latest

# OAuth Configuration
$script:GcAuthConfig = @{
  Region       = 'usw2.pure.cloud'
  ClientId     = ''
  RedirectUri  = 'http://localhost:8085/callback'
  Scopes       = @()
  ClientSecret = ''  # Optional, for client credentials flow
}

# Diagnostics (safe logging; never logs secrets/tokens)
$script:GcAuthDiagnostics = @{
  Enabled       = $false
  LogDirectory  = $null
  LogPath       = $null
  CorrelationId = $null
}

# Token state
$script:GcTokenState = @{
  AccessToken  = $null
  TokenType    = $null
  ExpiresIn    = $null
  ExpiresAt    = $null
  RefreshToken = $null
  UserInfo     = $null
}

function Get-GcAuthDefaultLogDirectory {
  [CmdletBinding()]
  param()

  try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $appArtifacts = Join-Path -Path $repoRoot -ChildPath 'App\artifacts'
    return $appArtifacts
  } catch {
    return (Join-Path -Path $env:TEMP -ChildPath 'AGenesysToolKit\auth-logs')
  }
}

function Start-GcAuthDiagnosticsSession {
  [CmdletBinding()]
  param(
    [string]$LogDirectory,
    [switch]$ForceNewLogFile
  )

  if ($LogDirectory) { $script:GcAuthDiagnostics.LogDirectory = $LogDirectory }
  if (-not $script:GcAuthDiagnostics.LogDirectory) { $script:GcAuthDiagnostics.LogDirectory = Get-GcAuthDefaultLogDirectory }

  if ($ForceNewLogFile -or -not $script:GcAuthDiagnostics.LogPath) {
    $script:GcAuthDiagnostics.CorrelationId = ([Guid]::NewGuid().ToString('n'))
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:GcAuthDiagnostics.LogPath = Join-Path -Path $script:GcAuthDiagnostics.LogDirectory -ChildPath "auth-$stamp-$($script:GcAuthDiagnostics.CorrelationId).log"
  }

  try {
    New-Item -ItemType Directory -Path $script:GcAuthDiagnostics.LogDirectory -Force | Out-Null
  } catch { }

  try {
    if (-not (Test-Path -LiteralPath $script:GcAuthDiagnostics.LogPath)) {
      "Auth diagnostics started: $(Get-Date -Format o)" | Add-Content -LiteralPath $script:GcAuthDiagnostics.LogPath -Encoding UTF8
    }
  } catch { }
}

function Enable-GcAuthDiagnostics {
  <#
  .SYNOPSIS
    Enables diagnostic logging for OAuth/auth flows.

  .DESCRIPTION
    Writes a detailed log file useful for diagnosing login failures. Secrets
    (client secret, auth code, PKCE verifier, access token) are never written.
  #>
  [CmdletBinding()]
  param(
    [string]$LogDirectory
  )

  $script:GcAuthDiagnostics.Enabled = $true
  Start-GcAuthDiagnosticsSession -LogDirectory $LogDirectory -ForceNewLogFile
  return Get-GcAuthDiagnostics
}

function Get-GcAuthDiagnostics {
  [CmdletBinding()]
  param()

  return [PSCustomObject]@{
    Enabled       = [bool]$script:GcAuthDiagnostics.Enabled
    LogDirectory  = $script:GcAuthDiagnostics.LogDirectory
    LogPath       = $script:GcAuthDiagnostics.LogPath
    CorrelationId = $script:GcAuthDiagnostics.CorrelationId
  }
}

function ConvertTo-GcAuthSafeString {
  [CmdletBinding()]
  param(
    [AllowNull()] $Value,
    [int] $KeepStart = 4,
    [int] $KeepEnd = 4
  )

  if ($null -eq $Value) { return $null }

  $s = [string]$Value
  if ($s.Length -le ($KeepStart + $KeepEnd + 3)) { return ('*' * [Math]::Min(12, $s.Length)) }
  return ($s.Substring(0, $KeepStart) + '…' + $s.Substring($s.Length - $KeepEnd))
}

function ConvertTo-GcAuthSafeData {
  [CmdletBinding()]
  param(
    [AllowNull()] $Data,
    [int] $Depth = 0
  )

  if ($null -eq $Data) { return $null }
  if ($Depth -gt 6) { return '[MaxDepth]' }

  if ($Data -is [hashtable]) {
    $out = @{}
    foreach ($k in $Data.Keys) {
      $key = [string]$k
      $v = $Data[$k]

      if ($key -match '(?i)secret|token|authorization|code_verifier|verifier|authcode|code|access_token|refresh_token') {
        $out[$key] = ConvertTo-GcAuthSafeString -Value $v
      } else {
        $out[$key] = ConvertTo-GcAuthSafeData -Data $v -Depth ($Depth + 1)
      }
    }
    return $out
  }

  if ($Data -is [System.Collections.IEnumerable] -and -not ($Data -is [string])) {
    $arr = @()
    foreach ($item in $Data) {
      $arr += (ConvertTo-GcAuthSafeData -Data $item -Depth ($Depth + 1))
    }
    return $arr
  }

  return $Data
}

function Write-GcAuthDiag {
  [CmdletBinding()]
  param(
    [ValidateSet('TRACE','DEBUG','INFO','WARN','ERROR')]
    [string]$Level = 'INFO',

    [Parameter(Mandatory)]
    [string]$Message,

    [hashtable]$Data
  )

  if (-not $script:GcAuthDiagnostics.Enabled) { return }
  if (-not $script:GcAuthDiagnostics.LogPath) {
    Start-GcAuthDiagnosticsSession -ForceNewLogFile
  }

  $ts = (Get-Date).ToString('o')
  $cid = $script:GcAuthDiagnostics.CorrelationId
  $threadId = try { [System.Threading.Thread]::CurrentThread.ManagedThreadId } catch { $null }

  $line = "[{0}] [{1}] [cid={2}] [tid={3}] {4}" -f $ts, $Level, $cid, $threadId, $Message
  if ($Data) {
    try {
      $safe = ConvertTo-GcAuthSafeData -Data $Data
      $json = ($safe | ConvertTo-Json -Depth 12 -Compress)
      $line += " | data=$json"
    } catch {
      $line += " | data=<unserializable>"
    }
  }

  try {
    Add-Content -LiteralPath $script:GcAuthDiagnostics.LogPath -Value $line -Encoding UTF8
  } catch { }
}

function Get-GcAuthExceptionInfo {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    $ErrorRecord
  )

  $ex = $ErrorRecord.Exception
  $info = @{
    Message = $ex.Message
    Type    = $ex.GetType().FullName
  }

  if ($ex.InnerException) {
    $info.Inner = @{
      Message = $ex.InnerException.Message
      Type    = $ex.InnerException.GetType().FullName
    }
  }

  if ($ex.StackTrace) { $info.Stack = $ex.StackTrace }

  # Best-effort HTTP response capture across PS 5.1 / 7+
  try {
    if ($ex.Response) {
      $resp = $ex.Response
      $info.Http = @{
        ResponseType = $resp.GetType().FullName
      }

      # WebException (Windows PowerShell)
      if ($resp -is [System.Net.HttpWebResponse]) {
        $info.Http.StatusCode = [int]$resp.StatusCode
        $info.Http.StatusDescription = $resp.StatusDescription
        try {
          $stream = $resp.GetResponseStream()
          if ($stream) {
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            if ($body -and $body.Length -gt 8192) { $body = $body.Substring(0, 8192) + '…' }
            $info.Http.Body = $body
          }
        } catch { }
      }
    }
  } catch { }

  # PowerShell 7 HttpResponseException often stores response in ErrorDetails
  try {
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
      $details = $ErrorRecord.ErrorDetails.Message
      if ($details.Length -gt 8192) { $details = $details.Substring(0, 8192) + '…' }
      $info.ErrorDetails = $details
    }
  } catch { }

  return $info
}

function Initialize-GcAuthDiagnostics {
  [CmdletBinding()]
  param()

  $enableEnv = $env:GC_AUTH_DIAGNOSTICS
  if ($enableEnv) {
    if ($enableEnv -match '^(1|true|yes|on)$') {
      $script:GcAuthDiagnostics.Enabled = $true
      Start-GcAuthDiagnosticsSession -ForceNewLogFile
    }
  }
}

Initialize-GcAuthDiagnostics

function Set-GcAuthConfig {
  <#
  .SYNOPSIS
    Configure OAuth settings for Genesys Cloud authentication.

  .DESCRIPTION
    Sets up the OAuth configuration including region, client ID, redirect URI,
    scopes, and optional client secret for authentication flows.

  .PARAMETER Region
    The Genesys Cloud region (e.g., 'mypurecloud.com', 'mypurecloud.ie')

  .PARAMETER ClientId
    OAuth client ID from Genesys Cloud

  .PARAMETER RedirectUri
    OAuth redirect URI (must match configuration in Genesys Cloud)

  .PARAMETER Scopes
    Array of OAuth scopes to request

  .PARAMETER ClientSecret
    Optional client secret for client credentials flow

  .EXAMPLE
    Set-GcAuthConfig -Region 'mypurecloud.com' -ClientId 'abc123' -RedirectUri 'http://localhost:8400/oauth/callback' -Scopes @('conversations:readonly')
  #>
  [CmdletBinding()]
  param(
    [string]$Region,
    [string]$ClientId,
    [string]$RedirectUri,
    [string[]]$Scopes,
    [string]$ClientSecret
  )

  if ($Region) { $script:GcAuthConfig.Region = $Region }
  if ($ClientId) { $script:GcAuthConfig.ClientId = $ClientId }
  if ($RedirectUri) { $script:GcAuthConfig.RedirectUri = $RedirectUri }
  if ($Scopes) { $script:GcAuthConfig.Scopes = $Scopes }
  if ($ClientSecret) { $script:GcAuthConfig.ClientSecret = $ClientSecret }
}

function Get-GcAuthConfig {
  <#
  .SYNOPSIS
    Returns the current OAuth configuration.
  
  .DESCRIPTION
    Returns a clone of the current OAuth configuration with guaranteed Scopes property.
    This prevents null-valued expression errors when accessing Scopes in consuming code.
  #>
  [CmdletBinding()]
  param()

  # Ensure Scopes is always an array (never null)
  $config = $script:GcAuthConfig.Clone()
  if (-not $config.Scopes) {
    $config.Scopes = @()
  }
  
  return $config
}

function Get-GcPkceChallenge {
  <#
  .SYNOPSIS
    Generates PKCE code verifier and challenge for OAuth flow.

  .DESCRIPTION
    Creates a cryptographically random code verifier and derives the
    code challenge using SHA256, as required for OAuth PKCE flow.

  .OUTPUTS
    PSCustomObject with CodeVerifier and CodeChallenge properties
  #>
  [CmdletBinding()]
  param()

  # Generate code verifier (43-128 characters, base64url encoded)
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes)
  $codeVerifier = [Convert]::ToBase64String($bytes) -replace '\+', '-' -replace '/', '_' -replace '=', ''

  # Generate code challenge (SHA256 hash of verifier, base64url encoded)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  $challengeBytes = $sha256.ComputeHash([Text.Encoding]::ASCII.GetBytes($codeVerifier))
  $codeChallenge = [Convert]::ToBase64String($challengeBytes) -replace '\+', '-' -replace '/', '_' -replace '=', ''

  return [PSCustomObject]@{
    CodeVerifier  = $codeVerifier
    CodeChallenge = $codeChallenge
  }
}

function Start-GcAuthCodeFlow {
  <#
  .SYNOPSIS
    Initiates OAuth authorization code flow with PKCE.

  .DESCRIPTION
    Starts a local HTTP listener, opens the browser to the OAuth authorization
    page, and waits for the callback with the authorization code.

  .PARAMETER TimeoutSeconds
    How long to wait for the OAuth callback (default: 300 seconds)

  .OUTPUTS
    PSCustomObject with AuthCode and CodeVerifier properties, or $null if failed
  #>
  [CmdletBinding()]
  param(
    [int]$TimeoutSeconds = 300
  )

  if (-not $script:GcAuthConfig.ClientId) {
    Write-Error "ClientId not configured. Call Set-GcAuthConfig first."
    return $null
  }

  if ([string]::IsNullOrWhiteSpace($script:GcAuthConfig.RedirectUri)) {
    Write-Error "RedirectUri not configured. Call Set-GcAuthConfig first."
    return $null
  }

  Write-GcAuthDiag -Level INFO -Message "Start auth code flow" -Data @{
    Region      = $script:GcAuthConfig.Region
    RedirectUri = $script:GcAuthConfig.RedirectUri
    ScopesCount = @($script:GcAuthConfig.Scopes).Count
    ClientId    = (ConvertTo-GcAuthSafeString -Value $script:GcAuthConfig.ClientId)
  }

  # Generate PKCE challenge
  $pkce = Get-GcPkceChallenge

  # Build authorization URL
  $region = $script:GcAuthConfig.Region
  $clientId = $script:GcAuthConfig.ClientId
  $redirectUri = $script:GcAuthConfig.RedirectUri
  
  # Ensure Scopes is always an array to prevent null-valued expression errors
  $scopesArray = if ($script:GcAuthConfig.Scopes) { $script:GcAuthConfig.Scopes } else { @() }
  $scopes = ($scopesArray -join ' ')

  # Validate required configuration
  if ([string]::IsNullOrWhiteSpace($region)) {
    $msg = "Auth configuration error: Region is not set."
    Write-GcAuthDiag -Level ERROR -Message $msg
    throw $msg
  }
  if ([string]::IsNullOrWhiteSpace($clientId)) {
    $msg = "Auth configuration error: ClientId is not set."
    Write-GcAuthDiag -Level ERROR -Message $msg
    throw $msg
  }
  if ([string]::IsNullOrWhiteSpace($redirectUri)) {
    $msg = "Auth configuration error: RedirectUri is not set."
    Write-GcAuthDiag -Level ERROR -Message $msg
    throw $msg
  }

  $state = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes([Guid]::NewGuid().ToString())) -replace '=', ''

  $authUrl = "https://login.$region/oauth/authorize?" +
             "response_type=code" +
             "&client_id=$([Uri]::EscapeDataString($clientId))" +
             "&redirect_uri=$([Uri]::EscapeDataString($redirectUri))" +
             "&code_challenge=$([Uri]::EscapeDataString($pkce.CodeChallenge))" +
             "&code_challenge_method=S256" +
             "&state=$([Uri]::EscapeDataString($state))"

  if ($scopes) {
    $authUrl += "&scope=$([Uri]::EscapeDataString($scopes))"
  }

  Write-Verbose "Opening authorization URL: $authUrl"

  # Start local HTTP listener
  try {
    $listenerPrefix = $null
    try {
      $ru = [Uri]$redirectUri
      $path = $ru.AbsolutePath
      if ([string]::IsNullOrEmpty($path)) { $path = '/' }

      # Listen on the directory portion to avoid trailing-slash mismatches.
      $dirPath = $path
      if (-not $dirPath.EndsWith('/')) {
        $lastSlash = $dirPath.LastIndexOf('/')
        if ($lastSlash -ge 0) {
          $dirPath = $dirPath.Substring(0, $lastSlash + 1)
        } else {
          $dirPath = '/'
        }
      }

      $listenerPrefix = "{0}://{1}:{2}{3}" -f $ru.Scheme, $ru.Host, $ru.Port, $dirPath
      if (-not $listenerPrefix.EndsWith('/')) { $listenerPrefix += '/' }
    } catch {
      $listenerPrefix = ($redirectUri.TrimEnd('/') + '/')
    }

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($listenerPrefix)
    $listener.Start()

    Write-GcAuthDiag -Level INFO -Message "HTTP listener started" -Data @{
      Prefix  = $listenerPrefix
      TimeoutSeconds = $TimeoutSeconds
    }

    Write-Host "Starting OAuth flow. Opening browser..."
    Start-Process $authUrl

    # Wait for callback
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $authCode = $null
    $receivedState = $null

    while ((Get-Date) -lt $deadline -and $listener.IsListening) {
      $contextTask = $listener.GetContextAsync()

      if ($null -eq $contextTask) {
        throw "HttpListener.GetContextAsync() returned null (unexpected)."
      }

      # Poll with timeout
      $waitResult = $contextTask.Wait(1000)
      if (-not $waitResult) { continue }

      $context = $contextTask.GetAwaiter().GetResult()
      $request = $context.Request
      $response = $context.Response

      # Parse query string
      $query = ''
      try { $query = $request.Url.Query } catch { $query = '' }
      Write-GcAuthDiag -Level DEBUG -Message "Received OAuth callback request" -Data @{
        Url       = (try { $request.Url.AbsoluteUri } catch { $null })
        HasQuery  = (-not [string]::IsNullOrEmpty($query))
      }

      if ($query -match 'code=([^&]+)') {
        $authCode = [Uri]::UnescapeDataString($matches[1])
      }
      if ($query -match 'state=([^&]+)') {
        $receivedState = [Uri]::UnescapeDataString($matches[1])
      }

      # Send response to browser
      $responseHtml = if ($authCode) {
        "<html><body><h1>Authentication Successful</h1><p>You can close this window.</p></body></html>"
      } else {
        "<html><body><h1>Authentication Failed</h1><p>No authorization code received.</p></body></html>"
      }

      $buffer = [Text.Encoding]::UTF8.GetBytes($responseHtml)
      $response.ContentLength64 = $buffer.Length
      $response.ContentType = "text/html"
      $output = $response.OutputStream
      $output.Write($buffer, 0, $buffer.Length)
      $output.Close()

      $listener.Stop()
      break
    }

    if (-not $authCode) {
      Write-GcAuthDiag -Level ERROR -Message "No authorization code received before timeout" -Data @{
        TimeoutSeconds = $TimeoutSeconds
        RedirectUri    = $redirectUri
      }
      Write-Error "Failed to receive authorization code within timeout period."
      return $null
    }

    if ($receivedState -ne $state) {
      Write-Warning "State mismatch in OAuth callback. Possible CSRF attack."
      Write-GcAuthDiag -Level WARN -Message "OAuth state mismatch" -Data @{
        ExpectedState = (ConvertTo-GcAuthSafeString -Value $state)
        ReceivedState = (ConvertTo-GcAuthSafeString -Value $receivedState)
      }
    }

    Write-GcAuthDiag -Level INFO -Message "Received authorization code" -Data @{
      AuthCodeLength = $authCode.Length
    }

    return [PSCustomObject]@{
      AuthCode     = $authCode
      CodeVerifier = $pkce.CodeVerifier
    }

  } catch {
    $exInfo = Get-GcAuthExceptionInfo -ErrorRecord $_
    Write-GcAuthDiag -Level ERROR -Message "Error during OAuth flow" -Data $exInfo
    $diag = Get-GcAuthDiagnostics
    $suffix = if ($diag.LogPath) { " (Auth diagnostics: $($diag.LogPath))" } else { "" }
    Write-Error ("Error during OAuth flow: {0}{1}" -f $_.Exception.Message, $suffix)
    return $null
  } finally {
    if ($listener -and $listener.IsListening) {
      $listener.Stop()
    }
  }
}

function Get-GcTokenFromAuthCode {
  <#
  .SYNOPSIS
    Exchanges authorization code for access token.

  .PARAMETER AuthCode
    Authorization code from OAuth callback

  .PARAMETER CodeVerifier
    PKCE code verifier used in the initial request

  .OUTPUTS
    Token response object with access_token, expires_in, etc.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$AuthCode,

    [Parameter(Mandatory)]
    [string]$CodeVerifier
  )

  $region = $script:GcAuthConfig.Region
  $clientId = $script:GcAuthConfig.ClientId
  $redirectUri = $script:GcAuthConfig.RedirectUri

  $tokenUrl = "https://login.$region/oauth/token"

  $body = @{
    grant_type    = 'authorization_code'
    code          = $AuthCode
    redirect_uri  = $redirectUri
    client_id     = $clientId
    code_verifier = $CodeVerifier
  }

  $headers = @{}
  if (-not [string]::IsNullOrWhiteSpace($script:GcAuthConfig.ClientSecret)) {
    # Use Basic auth for confidential clients; do not log the secret.
    $pair = "{0}:{1}" -f $clientId, $script:GcAuthConfig.ClientSecret
    $headers['Authorization'] = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
  }

  Write-GcAuthDiag -Level INFO -Message "Exchange auth code for token" -Data @{
    TokenUrl        = $tokenUrl
    RedirectUri     = $redirectUri
    ClientId        = (ConvertTo-GcAuthSafeString -Value $clientId)
    HasClientSecret = (-not [string]::IsNullOrWhiteSpace($script:GcAuthConfig.ClientSecret))
    AuthCodeLength  = $AuthCode.Length
    VerifierLength  = $CodeVerifier.Length
  }

  try {
    $irmParams = @{
      Uri         = $tokenUrl
      Method      = 'POST'
      Body        = $body
      ContentType = 'application/x-www-form-urlencoded'
    }
    if ($headers.Count -gt 0) { $irmParams['Headers'] = $headers }

    $response = Invoke-RestMethod @irmParams

    if ($null -eq $response) {
      throw "Token endpoint returned null response."
    }
    if (-not $response.access_token) {
      $keys = @()
      try { $keys = @($response.PSObject.Properties.Name) } catch { }
      throw ("Token response missing access_token. Keys: {0}" -f ($keys -join ', '))
    }

    # Store token state
    $script:GcTokenState.AccessToken = $response.access_token
    $script:GcTokenState.TokenType = $response.token_type
    $script:GcTokenState.ExpiresIn = $response.expires_in
    $script:GcTokenState.ExpiresAt = (Get-Date).AddSeconds($response.expires_in)
    $script:GcTokenState.RefreshToken = $response.refresh_token

    Write-GcAuthDiag -Level INFO -Message "Token exchange succeeded" -Data @{
      TokenType    = $response.token_type
      ExpiresIn    = $response.expires_in
      HasRefresh   = [bool]$response.refresh_token
    }

    return $response
  } catch {
    $exInfo = Get-GcAuthExceptionInfo -ErrorRecord $_
    Write-GcAuthDiag -Level ERROR -Message "Token exchange failed" -Data $exInfo
    $diag = Get-GcAuthDiagnostics
    $suffix = if ($diag.LogPath) { " (Auth diagnostics: $($diag.LogPath))" } else { "" }
    Write-Error ("Failed to exchange authorization code for token: {0}{1}" -f $_.Exception.Message, $suffix)
    throw
  }
}

function Get-GcTokenAsync {
  <#
  .SYNOPSIS
    Complete OAuth flow: authorize + exchange code for token.

  .DESCRIPTION
    Performs the full OAuth authorization code + PKCE flow,
    storing the resulting token in module state.

  .PARAMETER TimeoutSeconds
    How long to wait for the OAuth callback

  .OUTPUTS
    Token response or $null if failed
  #>
  [CmdletBinding()]
  param(
    [int]$TimeoutSeconds = 300
  )

  if ($script:GcAuthDiagnostics.Enabled) {
    Start-GcAuthDiagnosticsSession
    Write-GcAuthDiag -Level INFO -Message "Begin full OAuth flow (Get-GcTokenAsync)" -Data @{
      TimeoutSeconds = $TimeoutSeconds
    }
  }

  $authResult = Start-GcAuthCodeFlow -TimeoutSeconds $TimeoutSeconds
  if (-not $authResult) {
    Write-GcAuthDiag -Level ERROR -Message "Auth code flow failed (no result)"
    return $null
  }

  $tokenResponse = Get-GcTokenFromAuthCode -AuthCode $authResult.AuthCode -CodeVerifier $authResult.CodeVerifier
  return $tokenResponse
}

function Test-GcToken {
  <#
  .SYNOPSIS
    Tests the current access token by calling /api/v2/users/me.

  .DESCRIPTION
    Validates that the stored access token works by making a test
    API call. Returns user info if successful.

  .OUTPUTS
    User info object or $null if token is invalid
  #>
  [CmdletBinding()]
  param()

  if (-not $script:GcTokenState.AccessToken) {
    Write-Warning "No access token available. Call Get-GcTokenAsync first."
    return $null
  }

  $region = $script:GcAuthConfig.Region
  $token = $script:GcTokenState.AccessToken

  $uri = "https://api.$region/api/v2/users/me"

  try {
    $headers = @{
      'Authorization' = "Bearer $token"
      'Content-Type'  = 'application/json'
    }

    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
    $script:GcTokenState.UserInfo = $response

    Write-GcAuthDiag -Level INFO -Message "Token test succeeded" -Data @{
      Uri = $uri
    }

    return $response
  } catch {
    $exInfo = Get-GcAuthExceptionInfo -ErrorRecord $_
    Write-GcAuthDiag -Level WARN -Message "Token test failed" -Data $exInfo
    Write-Warning "Token test failed: $_"
    $script:GcTokenState.AccessToken = $null
    return $null
  }
}

function Get-GcAccessToken {
  <#
  .SYNOPSIS
    Returns the current access token.
  #>
  [CmdletBinding()]
  param()

  return $script:GcTokenState.AccessToken
}

function Get-GcTokenState {
  <#
  .SYNOPSIS
    Returns the current token state (for UI updates).
  #>
  [CmdletBinding()]
  param()

  return $script:GcTokenState
}

function Clear-GcTokenState {
  <#
  .SYNOPSIS
    Clears the stored token state (logout).
  #>
  [CmdletBinding()]
  param()

  $script:GcTokenState.AccessToken = $null
  $script:GcTokenState.TokenType = $null
  $script:GcTokenState.ExpiresIn = $null
  $script:GcTokenState.ExpiresAt = $null
  $script:GcTokenState.RefreshToken = $null
  $script:GcTokenState.UserInfo = $null
}

Export-ModuleMember -Function Set-GcAuthConfig, Get-GcAuthConfig, `
  Get-GcTokenAsync, Test-GcToken, Get-GcAccessToken, Get-GcTokenState, Clear-GcTokenState, `
  Enable-GcAuthDiagnostics, Get-GcAuthDiagnostics

### END: Core.Auth.psm1
