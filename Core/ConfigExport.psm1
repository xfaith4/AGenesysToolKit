# ConfigExport.psm1
# Core module for exporting Genesys Cloud configuration to JSON/YAML

Set-StrictMode -Version Latest

function Get-GcConfigProperty {
  param(
    [Parameter(Mandatory=$false)][object]$Object,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory=$false)]$DefaultValue = $null
  )

  if ($null -eq $Object) { return $DefaultValue }
  try {
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $DefaultValue }
    return $prop.Value
  } catch {
    return $DefaultValue
  }
}

function Export-GcFlowsConfig {
  <#
  .SYNOPSIS
    Exports flows to JSON files.
  
  .PARAMETER FlowIds
    Array of flow IDs to export. If not provided, exports all flows.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  
  .PARAMETER OutputPath
    Directory path for exported files.
  #>
  param(
    [string[]]$FlowIds,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [Parameter(Mandatory)][string]$OutputPath
  )

  try {
    # Get flows
    if ($FlowIds -and $FlowIds.Count -gt 0) {
      $flows = $FlowIds | ForEach-Object {
        Invoke-GcRequest -Path "/api/v2/flows/$_" -Method GET `
          -InstanceName $InstanceName -AccessToken $AccessToken
      }
    } else {
      $flows = Invoke-GcPagedRequest -Path '/api/v2/flows' -Method GET `
        -InstanceName $InstanceName -AccessToken $AccessToken
    }

    # Create output directory
    $flowsDir = Join-Path -Path $OutputPath -ChildPath 'flows'
    if (-not (Test-Path $flowsDir)) {
      New-Item -ItemType Directory -Path $flowsDir -Force | Out-Null
    }

    # Export each flow
    $manifest = @()
    foreach ($flow in @($flows)) {
      $flowId = [string](Get-GcConfigProperty -Object $flow -Name 'id' -DefaultValue '')
      if ([string]::IsNullOrWhiteSpace($flowId)) { $flowId = [guid]::NewGuid().ToString('N') }
      $flowName = [string](Get-GcConfigProperty -Object $flow -Name 'name' -DefaultValue 'Unknown Flow')
      $flowType = [string](Get-GcConfigProperty -Object $flow -Name 'type' -DefaultValue 'Unknown')

      $filename = "flow_$flowId.json"
      $filepath = Join-Path -Path $flowsDir -ChildPath $filename
      $flow | ConvertTo-Json -Depth 20 | Set-Content -Path $filepath -Encoding UTF8
      
      $manifest += @{
        id = $flowId
        name = $flowName
        type = $flowType
        filename = $filename
      }
    }

    # Create manifest
    $manifestPath = Join-Path -Path $flowsDir -ChildPath 'manifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

    return @{
      Type = 'Flows'
      Count = @($flows).Count
      Directory = $flowsDir
      Manifest = $manifestPath
    }
  } catch {
    Write-Error "Failed to export flows: $_"
    return $null
  }
}

function Export-GcQueuesConfig {
  <#
  .SYNOPSIS
    Exports queues to JSON files.
  #>
  param(
    [string[]]$QueueIds,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [Parameter(Mandatory)][string]$OutputPath
  )

  try {
    # Get queues
    if ($QueueIds -and $QueueIds.Count -gt 0) {
      $queues = $QueueIds | ForEach-Object {
        Invoke-GcRequest -Path "/api/v2/routing/queues/$_" -Method GET `
          -InstanceName $InstanceName -AccessToken $AccessToken
      }
    } else {
      $queues = Invoke-GcPagedRequest -Path '/api/v2/routing/queues' -Method GET `
        -InstanceName $InstanceName -AccessToken $AccessToken
    }

    # Create output directory
    $queuesDir = Join-Path -Path $OutputPath -ChildPath 'queues'
    if (-not (Test-Path $queuesDir)) {
      New-Item -ItemType Directory -Path $queuesDir -Force | Out-Null
    }

    # Export each queue
    $manifest = @()
    foreach ($queue in @($queues)) {
      $queueId = [string](Get-GcConfigProperty -Object $queue -Name 'id' -DefaultValue '')
      if ([string]::IsNullOrWhiteSpace($queueId)) { $queueId = [guid]::NewGuid().ToString('N') }
      $queueName = [string](Get-GcConfigProperty -Object $queue -Name 'name' -DefaultValue 'Unknown Queue')

      $filename = "queue_$queueId.json"
      $filepath = Join-Path -Path $queuesDir -ChildPath $filename
      $queue | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      
      $manifest += @{
        id = $queueId
        name = $queueName
        filename = $filename
      }
    }

    # Create manifest
    $manifestPath = Join-Path -Path $queuesDir -ChildPath 'manifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

    return @{
      Type = 'Queues'
      Count = @($queues).Count
      Directory = $queuesDir
      Manifest = $manifestPath
    }
  } catch {
    Write-Error "Failed to export queues: $_"
    return $null
  }
}

function Export-GcSkillsConfig {
  <#
  .SYNOPSIS
    Exports skills to JSON files.
  #>
  param(
    [string[]]$SkillIds,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [Parameter(Mandatory)][string]$OutputPath
  )

  try {
    # Get skills
    if ($SkillIds -and $SkillIds.Count -gt 0) {
      $skills = $SkillIds | ForEach-Object {
        Invoke-GcRequest -Path "/api/v2/routing/skills/$_" -Method GET `
          -InstanceName $InstanceName -AccessToken $AccessToken
      }
    } else {
      $skills = Invoke-GcPagedRequest -Path '/api/v2/routing/skills' -Method GET `
        -InstanceName $InstanceName -AccessToken $AccessToken
    }

    # Create output directory
    $skillsDir = Join-Path -Path $OutputPath -ChildPath 'skills'
    if (-not (Test-Path $skillsDir)) {
      New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null
    }

    # Export each skill
    $manifest = @()
    foreach ($skill in @($skills)) {
      $skillId = [string](Get-GcConfigProperty -Object $skill -Name 'id' -DefaultValue '')
      if ([string]::IsNullOrWhiteSpace($skillId)) { $skillId = [guid]::NewGuid().ToString('N') }
      $skillName = [string](Get-GcConfigProperty -Object $skill -Name 'name' -DefaultValue 'Unknown Skill')

      $filename = "skill_$skillId.json"
      $filepath = Join-Path -Path $skillsDir -ChildPath $filename
      $skill | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath -Encoding UTF8
      
      $manifest += @{
        id = $skillId
        name = $skillName
        filename = $filename
      }
    }

    # Create manifest
    $manifestPath = Join-Path -Path $skillsDir -ChildPath 'manifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

    return @{
      Type = 'Skills'
      Count = @($skills).Count
      Directory = $skillsDir
      Manifest = $manifestPath
    }
  } catch {
    Write-Error "Failed to export skills: $_"
    return $null
  }
}

function Export-GcDataActionsConfig {
  <#
  .SYNOPSIS
    Exports data actions to JSON files.
  #>
  param(
    [string[]]$ActionIds,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [Parameter(Mandatory)][string]$OutputPath
  )

  try {
    # Get data actions
    if ($ActionIds -and $ActionIds.Count -gt 0) {
      $actions = $ActionIds | ForEach-Object {
        Invoke-GcRequest -Path "/api/v2/integrations/actions/$_" -Method GET `
          -InstanceName $InstanceName -AccessToken $AccessToken
      }
    } else {
      $actions = Invoke-GcPagedRequest -Path '/api/v2/integrations/actions' -Method GET `
        -InstanceName $InstanceName -AccessToken $AccessToken
    }

    # Create output directory
    $actionsDir = Join-Path -Path $OutputPath -ChildPath 'data_actions'
    if (-not (Test-Path $actionsDir)) {
      New-Item -ItemType Directory -Path $actionsDir -Force | Out-Null
    }

    # Export each action
    $manifest = @()
    foreach ($action in @($actions)) {
      $actionId = [string](Get-GcConfigProperty -Object $action -Name 'id' -DefaultValue '')
      if ([string]::IsNullOrWhiteSpace($actionId)) { $actionId = [guid]::NewGuid().ToString('N') }
      $actionName = [string](Get-GcConfigProperty -Object $action -Name 'name' -DefaultValue 'Unknown Action')
      $actionCategory = [string](Get-GcConfigProperty -Object $action -Name 'category' -DefaultValue '')

      $filename = "action_$actionId.json"
      $filepath = Join-Path -Path $actionsDir -ChildPath $filename
      $action | ConvertTo-Json -Depth 20 | Set-Content -Path $filepath -Encoding UTF8
      
      $manifest += @{
        id = $actionId
        name = $actionName
        category = $actionCategory
        filename = $filename
      }
    }

    # Create manifest
    $manifestPath = Join-Path -Path $actionsDir -ChildPath 'manifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

    return @{
      Type = 'DataActions'
      Count = @($actions).Count
      Directory = $actionsDir
      Manifest = $manifestPath
    }
  } catch {
    Write-Error "Failed to export data actions: $_"
    return $null
  }
}

function Export-GcCompleteConfig {
  <#
  .SYNOPSIS
    Exports complete Genesys Cloud configuration to organized directory structure.
  
  .PARAMETER AccessToken
    OAuth access token for authentication.
  
  .PARAMETER InstanceName
    Genesys Cloud instance (e.g., 'usw2.pure.cloud').
  
  .PARAMETER OutputDirectory
    Base directory for exported configuration.
  
  .PARAMETER IncludeFlows
    Include flows in export.
  
  .PARAMETER IncludeQueues
    Include queues in export.
  
  .PARAMETER IncludeSkills
    Include skills in export.
  
  .PARAMETER IncludeDataActions
    Include data actions in export.
  
  .PARAMETER CreateZip
    Create ZIP archive of exported configuration.
  #>
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$InstanceName,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$IncludeFlows = $true,
    [switch]$IncludeQueues = $true,
    [switch]$IncludeSkills = $true,
    [switch]$IncludeDataActions = $true,
    [switch]$CreateZip = $false
  )

  try {
    # Create timestamped export directory
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $exportDir = Join-Path -Path $OutputDirectory -ChildPath "config_export_$timestamp"
    if (-not (Test-Path $exportDir)) {
      New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    }

    $results = @()

    # Export flows
    if ($IncludeFlows) {
      Write-Host "Exporting flows..."
      $flowResult = Export-GcFlowsConfig -AccessToken $AccessToken -InstanceName $InstanceName -OutputPath $exportDir
      if ($flowResult) {
        $results += $flowResult
      }
    }

    # Export queues
    if ($IncludeQueues) {
      Write-Host "Exporting queues..."
      $queueResult = Export-GcQueuesConfig -AccessToken $AccessToken -InstanceName $InstanceName -OutputPath $exportDir
      if ($queueResult) {
        $results += $queueResult
      }
    }

    # Export skills
    if ($IncludeSkills) {
      Write-Host "Exporting skills..."
      $skillResult = Export-GcSkillsConfig -AccessToken $AccessToken -InstanceName $InstanceName -OutputPath $exportDir
      if ($skillResult) {
        $results += $skillResult
      }
    }

    # Export data actions
    if ($IncludeDataActions) {
      Write-Host "Exporting data actions..."
      $actionResult = Export-GcDataActionsConfig -AccessToken $AccessToken -InstanceName $InstanceName -OutputPath $exportDir
      if ($actionResult) {
        $results += $actionResult
      }
    }

    # Create metadata file
    $metadata = @{
      exportTimestamp = (Get-Date).ToString('o')
      instanceName = $InstanceName
      exportedTypes = $results | ForEach-Object { $_.Type }
      summary = $results | ForEach-Object {
        @{
          type = $_.Type
          count = $_.Count
        }
      }
    }
    $metadataPath = Join-Path -Path $exportDir -ChildPath 'metadata.json'
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -Path $metadataPath -Encoding UTF8

    # Create ZIP archive if requested
    $zipPath = $null
    if ($CreateZip) {
      Write-Host "Creating ZIP archive..."
      $zipPath = "$exportDir.zip"
      Compress-Archive -Path $exportDir -DestinationPath $zipPath -Force
    }

    return @{
      ExportDirectory = $exportDir
      ZipPath = $zipPath
      Results = $results
      Metadata = $metadata
    }
  } catch {
    Write-Error "Failed to export complete configuration: $_"
    return $null
  }
}

Export-ModuleMember -Function Export-GcFlowsConfig, Export-GcQueuesConfig, Export-GcSkillsConfig, Export-GcDataActionsConfig, Export-GcCompleteConfig
