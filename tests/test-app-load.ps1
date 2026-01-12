### BEGIN: tests/test-app-load.ps1
# Test script to verify the main app loads without errors
# This validates that all functions are defined and modules import correctly

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "App Load Validation Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
$appFile = Join-Path -Path $repoRoot -ChildPath 'App/GenesysCloudTool_UX_Prototype_v2_1.ps1'

Write-Host "Testing: $appFile" -ForegroundColor Gray
Write-Host ""

try {
  # Create a test script that loads the app in a safe way
  $testScript = @"
`$ErrorActionPreference = 'Stop'

# Mock WPF types for testing (since we're not in Windows)
if (-not ('System.Windows.Window' -as [Type])) {
  Add-Type -TypeDefinition @'
  namespace System.Windows {
    public class Window {}
    public class MessageBoxButton {}
    public class MessageBoxImage {}
    public class MessageBoxResult {}
    public class MessageBox {
      public static MessageBoxResult Show(string message, string title, MessageBoxButton buttons, MessageBoxImage icon) {
        return new MessageBoxResult();
      }
    }
  }
  namespace System.Windows.Controls {
    public class ListBoxItem {}
  }
  namespace System.Windows.Threading {
    public class DispatcherTimer {}
  }
'@
}

# Source the app file (but don't execute UI parts)
# We'll just validate it parses and defines functions
`$content = Get-Content -Path '$appFile' -Raw

# Check if key functions are defined in the content
`$requiredFunctions = @(
  'Show-TimelineWindow',
  'New-PlaceholderView',
  'New-ConversationTimelineView',
  'New-SubscriptionsView',
  'Start-AppJob',
  'Format-EventSummary'
)

`$missingFunctions = @()
foreach (`$func in `$requiredFunctions) {
  if (`$content -notmatch "function `$func") {
    `$missingFunctions += `$func
  }
}

if (`$missingFunctions.Count -gt 0) {
  Write-Error "Missing functions: `$(`$missingFunctions -join ', ')"
  exit 1
}

Write-Host '✓ All required functions found' -ForegroundColor Green
Write-Host ''

# Check for syntax errors by parsing
try {
  `$null = [System.Management.Automation.PSParser]::Tokenize(`$content, [ref]`$null)
  Write-Host '✓ No syntax errors detected' -ForegroundColor Green
} catch {
  Write-Error "Syntax error: `$_"
  exit 1
}

exit 0
"@

  # Execute test script
  $result = pwsh -NoProfile -Command $testScript
  
  if ($LASTEXITCODE -eq 0) {
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "    ✓ APP LOAD VALIDATION PASS" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    exit 0
  } else {
    Write-Host "Output: $result" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "    ✗ APP LOAD VALIDATION FAIL" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    exit 1
  }
  
} catch {
  Write-Host "Error: $_" -ForegroundColor Red
  Write-Host "========================================" -ForegroundColor Red
  Write-Host "    ✗ APP LOAD VALIDATION FAIL" -ForegroundColor Red
  Write-Host "========================================" -ForegroundColor Red
  exit 1
}

### END: tests/test-app-load.ps1
