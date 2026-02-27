### BEGIN: Core.Auth.psm1

Set-StrictMode -Version Latest

# OAuth configuration
$script:GcAuthConfig = @{
  Region       = 'usw2.pure.cloud'
  ClientId     = ''
  RedirectUri  = 'http://localhost:8085/callback'
  Scopes       = @()
  ClientSecret = ''
}

# Token cache
$script:GcTokenState = @{
  AccessToken  = $null
  TokenType    = $null
  ExpiresIn    = $null
  ExpiresAt    = $null
  RefreshToken = $null
  UserInfo     = $null
}

# Optional diagnostics (off by default)
$script:GcAuthDiagnostics = @{
  Enabled       = $false
  LogDirectory  = $null
  LogPath       = $null
  CorrelationId = $null
}

function Write-GcAuthDiag {
  [CmdletBinding()]
  param(
    [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR')]
    [string]$Level = 'INFO',
    [Parameter(Mandatory)][string]$Message,
    [hashtable]$Data
  )

  if (-not $script:GcAuthDiagnostics.Enabled) { return }

  if (-not $script:GcAuthDiagnostics.LogPath) {
    $logDir = if ($script:GcAuthDiagnostics.LogDirectory) { $script:GcAuthDiagnostics.LogDirectory } else { Join-Path $env:TEMP 'GcReportCard' }
    try {
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    } catch {
      return
    }

    $script:GcAuthDiagnostics.CorrelationId = [Guid]::NewGuid().ToString('n')
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:GcAuthDiagnostics.LogPath = Join-Path $logDir "auth-$stamp-$($script:GcAuthDiagnostics.CorrelationId).log"
  }

  $line = "[{0}] [{1}] {2}" -f (Get-Date).ToString('o'), $Level, $Message
  if ($Data) {
    try {
      $line += ' | data=' + ($Data | ConvertTo-Json -Depth 8 -Compress)
    } catch {
      $line += ' | data=<unserializable>'
    }
  }

  try {
    Add-Content -LiteralPath $script:GcAuthDiagnostics.LogPath -Value $line -Encoding UTF8
  } catch {
    # best effort logging only
  }
}

function Enable-GcAuthDiagnostics {
  [CmdletBinding()]
  param([string]$LogDirectory)

  $script:GcAuthDiagnostics.Enabled = $true
  if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
    $script:GcAuthDiagnostics.LogDirectory = $LogDirectory
  }
  $script:GcAuthDiagnostics.LogPath = $null

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

function Set-GcAuthConfig {
  [CmdletBinding()]
  param(
    [string]$Region,
    [string]$ClientId,
    [string]$RedirectUri,
    [string[]]$Scopes,
    [string]$ClientSecret
  )

  if ($PSBoundParameters.ContainsKey('Region')) { $script:GcAuthConfig.Region = $Region }
  if ($PSBoundParameters.ContainsKey('ClientId')) { $script:GcAuthConfig.ClientId = $ClientId }
  if ($PSBoundParameters.ContainsKey('RedirectUri')) { $script:GcAuthConfig.RedirectUri = $RedirectUri }
  if ($PSBoundParameters.ContainsKey('Scopes')) { $script:GcAuthConfig.Scopes = if ($Scopes) { $Scopes } else { @() } }
  if ($PSBoundParameters.ContainsKey('ClientSecret')) { $script:GcAuthConfig.ClientSecret = $ClientSecret }
}

function Get-GcAuthConfig {
  [CmdletBinding()]
  param()

  $config = $script:GcAuthConfig.Clone()
  if (-not $config.Scopes) { $config.Scopes = @() }
  return $config
}

function Get-GcPkceChallenge {
  [CmdletBinding()]
  param()

  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

  $verifier = [Convert]::ToBase64String($bytes) -replace '\+', '-' -replace '/', '_' -replace '=', ''
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $challengeBytes = $sha256.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
  } finally {
    $sha256.Dispose()
  }

  $challenge = [Convert]::ToBase64String($challengeBytes) -replace '\+', '-' -replace '/', '_' -replace '=', ''

  return [PSCustomObject]@{
    CodeVerifier  = $verifier
    CodeChallenge = $challenge
  }
}

function Start-GcBrowser {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Url)

  try {
    Start-Process -FilePath $Url -ErrorAction Stop | Out-Null
    return $true
  } catch { }

  try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Url
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)
    return $true
  } catch { }

  try {
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'start', '""', $Url) -WindowStyle Hidden -ErrorAction Stop | Out-Null
    return $true
  } catch { }

  return $false
}

function Get-GcListenerPrefixes {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$RedirectUri)

  $prefixes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $uri = $null
  try { $uri = [Uri]$RedirectUri } catch { $uri = $null }

  if (-not $uri) {
    [void]$prefixes.Add(($RedirectUri.TrimEnd('/') + '/'))
    return @($prefixes)
  }

  $scheme = $uri.Scheme
  $host = $uri.Host
  $port = $uri.Port
  $path = if ([string]::IsNullOrWhiteSpace($uri.AbsolutePath)) { '/' } else { $uri.AbsolutePath }

  [void]$prefixes.Add(("{0}://{1}:{2}/" -f $scheme, $host, $port))

  $exactPath = if ($path.EndsWith('/')) { $path } else { "$path/" }
  [void]$prefixes.Add(("{0}://{1}:{2}{3}" -f $scheme, $host, $port, $exactPath))

  if ($host -eq 'localhost') {
    [void]$prefixes.Add(("{0}://127.0.0.1:{1}/" -f $scheme, $port))
    [void]$prefixes.Add(("{0}://127.0.0.1:{1}{2}" -f $scheme, $port, $exactPath))
    try { [void]$prefixes.Add(("{0}://[::1]:{1}/" -f $scheme, $port)) } catch { }
    try { [void]$prefixes.Add(("{0}://[::1]:{1}{2}" -f $scheme, $port, $exactPath)) } catch { }
  }

  return @($prefixes)
}

function Start-GcAuthCodeFlow {
  [CmdletBinding()]
  param([int]$TimeoutSeconds = 300)

  if ([string]::IsNullOrWhiteSpace($script:GcAuthConfig.Region)) {
    Write-Error 'Region not configured. Call Set-GcAuthConfig first.'
    return $null
  }
  if ([string]::IsNullOrWhiteSpace($script:GcAuthConfig.ClientId)) {
    Write-Error 'ClientId not configured. Call Set-GcAuthConfig first.'
    return $null
  }
  if ([string]::IsNullOrWhiteSpace($script:GcAuthConfig.RedirectUri)) {
    Write-Error 'RedirectUri not configured. Call Set-GcAuthConfig first.'
    return $null
  }

  $region = $script:GcAuthConfig.Region
  $clientId = $script:GcAuthConfig.ClientId
  $redirectUri = $script:GcAuthConfig.RedirectUri
  $scopes = if ($script:GcAuthConfig.Scopes -and @($script:GcAuthConfig.Scopes).Count -gt 0) {
    (@($script:GcAuthConfig.Scopes) -join ' ')
  } else {
    ''
  }

  $pkce = Get-GcPkceChallenge
  $state = [Guid]::NewGuid().ToString('n')

  $authUrl = "https://login.$region/oauth/authorize?response_type=code"
  $authUrl += "&client_id=$([Uri]::EscapeDataString($clientId))"
  $authUrl += "&redirect_uri=$([Uri]::EscapeDataString($redirectUri))"
  $authUrl += "&code_challenge=$([Uri]::EscapeDataString($pkce.CodeChallenge))"
  $authUrl += '&code_challenge_method=S256'
  $authUrl += "&state=$([Uri]::EscapeDataString($state))"
  if (-not [string]::IsNullOrWhiteSpace($scopes)) {
    $authUrl += "&scope=$([Uri]::EscapeDataString($scopes))"
  }

  $listener = $null
  try {
    $listener = [System.Net.HttpListener]::new()
    $prefixes = Get-GcListenerPrefixes -RedirectUri $redirectUri
    foreach ($prefix in $prefixes) {
      try { [void]$listener.Prefixes.Add($prefix) } catch { }
    }

    if ($listener.Prefixes.Count -eq 0) {
      throw 'No valid HTTP listener prefixes could be created from RedirectUri.'
    }

    $listener.Start()

    if (-not (Start-GcBrowser -Url $authUrl)) {
      throw "Failed to launch browser for OAuth URL: $authUrl"
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $authCode = $null
    $receivedState = $null
    $oauthError = $null
    $oauthErrorDescription = $null

    while ((Get-Date) -lt $deadline -and $listener.IsListening) {
      $iar = $listener.BeginGetContext($null, $null)
      $signaled = $false
      try { $signaled = $iar.AsyncWaitHandle.WaitOne(800) } catch { $signaled = $false }
      if (-not $signaled) { continue }

      $context = $listener.EndGetContext($iar)
      $request = $context.Request
      $response = $context.Response

      try { $authCode = $request.QueryString['code'] } catch { }
      try { $receivedState = $request.QueryString['state'] } catch { }
      try { $oauthError = $request.QueryString['error'] } catch { }
      try { $oauthErrorDescription = $request.QueryString['error_description'] } catch { }

      $html = if ($oauthError) {
        "<html><body><h1>Authentication Failed</h1><p>Error: $oauthError</p><p>$oauthErrorDescription</p><p>You can close this window.</p></body></html>"
      } elseif ($authCode) {
        '<html><body><h1>Authentication Successful</h1><p>You can close this window.</p></body></html>'
      } else {
        '<html><body><h1>OAuth Callback Listener</h1><p>Waiting for authorization code...</p></body></html>'
      }

      $buffer = [Text.Encoding]::UTF8.GetBytes($html)
      $response.ContentType = 'text/html'
      $response.ContentLength64 = $buffer.Length
      $stream = $response.OutputStream
      try {
        $stream.Write($buffer, 0, $buffer.Length)
      } finally {
        $stream.Close()
      }

      if ($oauthError -or $authCode) {
        $listener.Stop()
        break
      }
    }

    if ($oauthError) {
      Write-Error ("OAuth error returned from provider: {0} {1}" -f $oauthError, $oauthErrorDescription)
      return $null
    }

    if (-not $authCode) {
      Write-Error ("Failed to receive authorization code within timeout period. Verify RedirectUri exactly matches '{0}'." -f $redirectUri)
      return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($receivedState) -and $receivedState -ne $state) {
      Write-Warning 'OAuth callback state mismatch. Possible CSRF or stale callback response.'
    }

    return [PSCustomObject]@{
      AuthCode     = $authCode
      CodeVerifier = $pkce.CodeVerifier
    }
  } catch {
    Write-GcAuthDiag -Level ERROR -Message 'OAuth authorization code flow failed' -Data @{ Error = $_.Exception.Message }
    Write-Error ("Error during OAuth flow: {0}" -f $_.Exception.Message)
    return $null
  } finally {
    if ($listener -and $listener.IsListening) {
      try { $listener.Stop() } catch { }
    }
  }
}

function Get-GcTokenFromAuthCode {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$AuthCode,
    [Parameter(Mandatory)][string]$CodeVerifier
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
    $pair = "{0}:{1}" -f $clientId, $script:GcAuthConfig.ClientSecret
    $headers.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
  }

  $request = @{
    Uri         = $tokenUrl
    Method      = 'POST'
    Body        = $body
    ContentType = 'application/x-www-form-urlencoded'
    TimeoutSec  = 30
  }
  if ($headers.Count -gt 0) { $request.Headers = $headers }

  $response = Invoke-RestMethod @request

  if ($null -eq $response -or -not $response.access_token) {
    throw 'Token endpoint returned no access_token.'
  }

  $script:GcTokenState.AccessToken = $response.access_token
  $script:GcTokenState.TokenType = $response.token_type
  $script:GcTokenState.ExpiresIn = $response.expires_in
  $script:GcTokenState.ExpiresAt = if ($response.expires_in) { (Get-Date).AddSeconds([int]$response.expires_in) } else { $null }
  $script:GcTokenState.RefreshToken = $response.refresh_token

  return $response
}

function Get-GcClientCredentialsToken {
  [CmdletBinding()]
  param(
    [string]$Region,
    [string]$ClientId,
    [string]$ClientSecret,
    [string[]]$Scopes
  )

  $regionUse = if ($Region) { $Region } else { $script:GcAuthConfig.Region }
  $clientIdUse = if ($ClientId) { $ClientId } else { $script:GcAuthConfig.ClientId }
  $clientSecretUse = if ($ClientSecret) { $ClientSecret } else { $script:GcAuthConfig.ClientSecret }
  $scopesUse = if ($Scopes) { $Scopes } else { $script:GcAuthConfig.Scopes }

  if ([string]::IsNullOrWhiteSpace($regionUse)) { throw 'Region is required for client credentials token.' }
  if ([string]::IsNullOrWhiteSpace($clientIdUse)) { throw 'ClientId is required for client credentials token.' }
  if ([string]::IsNullOrWhiteSpace($clientSecretUse)) { throw 'ClientSecret is required for client credentials token.' }

  $tokenUrl = "https://login.$regionUse/oauth/token"
  $body = @{ grant_type = 'client_credentials' }
  if ($scopesUse -and @($scopesUse).Count -gt 0) {
    $body.scope = (@($scopesUse) -join ' ').Trim()
  }

  $pair = "{0}:{1}" -f $clientIdUse, $clientSecretUse
  $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }

  $response = Invoke-RestMethod -Uri $tokenUrl -Method POST -Headers $headers -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30

  if ($null -eq $response -or -not $response.access_token) {
    throw 'Token endpoint returned no access_token.'
  }

  $script:GcTokenState.AccessToken = $response.access_token
  $script:GcTokenState.TokenType = $response.token_type
  $script:GcTokenState.ExpiresIn = $response.expires_in
  $script:GcTokenState.ExpiresAt = if ($response.expires_in) { (Get-Date).AddSeconds([int]$response.expires_in) } else { $null }
  $script:GcTokenState.RefreshToken = $response.refresh_token

  return $response
}

function Get-GcTokenAsync {
  [CmdletBinding()]
  param([int]$TimeoutSeconds = 300)

  try {
    $authResult = Start-GcAuthCodeFlow -TimeoutSeconds $TimeoutSeconds
    if (-not $authResult) { return $null }
    return Get-GcTokenFromAuthCode -AuthCode $authResult.AuthCode -CodeVerifier $authResult.CodeVerifier
  } catch {
    Write-Error ("Authentication flow failed: {0}" -f $_.Exception.Message)
    return $null
  }
}

function Test-GcToken {
  [CmdletBinding()]
  param()

  if (-not $script:GcTokenState.AccessToken) {
    Write-Warning 'No access token available. Call Get-GcTokenAsync first.'
    return $null
  }

  $uri = "https://api.$($script:GcAuthConfig.Region)/api/v2/users/me"
  $headers = @{
    Authorization = "Bearer $($script:GcTokenState.AccessToken)"
    'Content-Type' = 'application/json'
  }

  try {
    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -TimeoutSec 20
    $script:GcTokenState.UserInfo = $response
    return $response
  } catch {
    Write-Warning ("Token test failed: {0}" -f $_.Exception.Message)
    $script:GcTokenState.AccessToken = $null
    return $null
  }
}

function Get-GcAccessToken {
  [CmdletBinding()]
  param()

  return $script:GcTokenState.AccessToken
}

function Get-GcTokenState {
  [CmdletBinding()]
  param()

  return $script:GcTokenState
}

function Clear-GcTokenState {
  [CmdletBinding()]
  param()

  $script:GcTokenState.AccessToken = $null
  $script:GcTokenState.TokenType = $null
  $script:GcTokenState.ExpiresIn = $null
  $script:GcTokenState.ExpiresAt = $null
  $script:GcTokenState.RefreshToken = $null
  $script:GcTokenState.UserInfo = $null
}

function Test-GcConnection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$AccessToken
  )

  $tests = @{
    'API Reachability' = $false
    Authentication = $false
    'Basic Permissions' = $false
  }

  try {
    $uri = "https://api.$Region/api/v2/users/me"
    $headers = @{
      Authorization = "Bearer $AccessToken"
      'Content-Type' = 'application/json'
    }

    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -TimeoutSec 10

    $tests['API Reachability'] = $true
    $tests['Authentication'] = $true
    if ($null -ne $response.id) { $tests['Basic Permissions'] = $true }

    return @{
      Success = $true
      Tests = $tests
      UserInfo = $response
    }
  } catch {
    return @{
      Success = $false
      Tests = $tests
      Error = $_.Exception.Message
    }
  }
}

Export-ModuleMember -Function Set-GcAuthConfig, Get-GcAuthConfig, `
  Get-GcTokenAsync, Get-GcClientCredentialsToken, Test-GcToken, Get-GcAccessToken, Get-GcTokenState, Clear-GcTokenState, `
  Enable-GcAuthDiagnostics, Get-GcAuthDiagnostics, Test-GcConnection

### END: Core.Auth.psm1
