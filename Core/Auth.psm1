### BEGIN: Core.Auth.psm1

Set-StrictMode -Version Latest

# OAuth Configuration
$script:GcAuthConfig = @{
  Region       = 'mypurecloud.com'
  ClientId     = ''
  RedirectUri  = 'http://localhost:8400/oauth/callback'
  Scopes       = @()
  ClientSecret = ''  # Optional, for client credentials flow
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
    Set-GcAuthConfig -Region 'mypurecloud.com' -ClientId 'abc123' -RedirectUri 'http://localhost:8080' -Scopes @('conversations:readonly')
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
  #>
  [CmdletBinding()]
  param()
  
  return $script:GcAuthConfig
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
  
  # Generate PKCE challenge
  $pkce = Get-GcPkceChallenge
  
  # Build authorization URL
  $region = $script:GcAuthConfig.Region
  $clientId = $script:GcAuthConfig.ClientId
  $redirectUri = $script:GcAuthConfig.RedirectUri
  $scopes = ($script:GcAuthConfig.Scopes -join ' ')
  
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
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($redirectUri.TrimEnd('/') + '/')
    $listener.Start()
    
    Write-Host "Starting OAuth flow. Opening browser..."
    Start-Process $authUrl
    
    # Wait for callback
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $authCode = $null
    $receivedState = $null
    
    while ((Get-Date) -lt $deadline -and $listener.IsListening) {
      $contextTask = $listener.GetContextAsync()
      
      # Poll with timeout
      $waitResult = $contextTask.AsyncWaitHandle.WaitOne(1000)
      if (-not $waitResult) { continue }
      
      $context = $contextTask.GetAwaiter().GetResult()
      $request = $context.Request
      $response = $context.Response
      
      # Parse query string
      $query = $request.Url.Query
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
      Write-Error "Failed to receive authorization code within timeout period."
      return $null
    }
    
    if ($receivedState -ne $state) {
      Write-Warning "State mismatch in OAuth callback. Possible CSRF attack."
    }
    
    return [PSCustomObject]@{
      AuthCode     = $authCode
      CodeVerifier = $pkce.CodeVerifier
    }
    
  } catch {
    Write-Error "Error during OAuth flow: $_"
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
  
  try {
    $response = Invoke-RestMethod -Uri $tokenUrl -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded'
    
    # Store token state
    $script:GcTokenState.AccessToken = $response.access_token
    $script:GcTokenState.TokenType = $response.token_type
    $script:GcTokenState.ExpiresIn = $response.expires_in
    $script:GcTokenState.ExpiresAt = (Get-Date).AddSeconds($response.expires_in)
    $script:GcTokenState.RefreshToken = $response.refresh_token
    
    return $response
  } catch {
    Write-Error "Failed to exchange authorization code for token: $_"
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
  
  $authResult = Start-GcAuthCodeFlow -TimeoutSeconds $TimeoutSeconds
  if (-not $authResult) {
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
    
    return $response
  } catch {
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
  Get-GcTokenAsync, Test-GcToken, Get-GcAccessToken, Get-GcTokenState, Clear-GcTokenState

### END: Core.Auth.psm1
