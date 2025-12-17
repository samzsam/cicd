<#
.SYNOPSIS
    Initial setup for Nessus Plugin Manager.
.DESCRIPTION
    Configures Nessus to disable auto-updates and sets up the plugin management
    infrastructure including scheduled tasks.
.PARAMETER NexusUrl
    URL of your Nexus Repository (e.g., http://nexus.local:8081)
.PARAMETER NexusUsername
    Nexus username for authentication.
.PARAMETER NexusPassword
    Nexus password for authentication.
.PARAMETER NexusRepository
    Name of the Nexus raw repository for plugins (default: nessus-plugins)
.PARAMETER DisableAutoUpdate
    Disable Nessus automatic plugin updates.
.PARAMETER CreateScheduledTask
    Create a Windows scheduled task for plugin sync.
#>

param(
    [string]$NexusUrl,
    [string]$NexusUsername = "admin",
    [string]$NexusPassword,
    [string]$NexusRepository = "nessus-plugins",
    [switch]$DisableAutoUpdate,
    [switch]$CreateScheduledTask
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARN" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage }
    }
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-NessusInstallation {
    $possiblePaths = @(
        "C:\Program Files\Tenable\Nessus",
        "C:\Program Files (x86)\Tenable\Nessus",
        "${env:ProgramFiles}\Tenable\Nessus"
    )

    foreach ($path in $possiblePaths) {
        if (Test-Path "$path\nessuscli.exe") {
            return $path
        }
    }

    return $null
}

function Find-NessusDataPath {
    $possiblePaths = @(
        "C:\ProgramData\Tenable\Nessus\nessus",
        "${env:ProgramData}\Tenable\Nessus\nessus"
    )

    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

function Disable-NessusAutoUpdate {
    param([string]$NessusCliPath)

    Write-Log "Disabling Nessus automatic updates..."

    # Method 1: Use nessuscli to set advanced settings
    try {
        & "$NessusCliPath\nessuscli.exe" fix --set auto_update=no 2>&1 | Out-Null
        Write-Log "Disabled: auto_update" -Level "SUCCESS"
    }
    catch {
        Write-Log "Could not set auto_update: $_" -Level "WARN"
    }

    try {
        & "$NessusCliPath\nessuscli.exe" fix --set auto_update_ui=no 2>&1 | Out-Null
        Write-Log "Disabled: auto_update_ui" -Level "SUCCESS"
    }
    catch {
        Write-Log "Could not set auto_update_ui: $_" -Level "WARN"
    }

    # Method 2: Direct config file modification as backup
    $configFile = "C:\ProgramData\Tenable\Nessus\nessus\nessusd.conf"

    if (Test-Path $configFile) {
        $content = Get-Content $configFile -Raw

        if ($content -notmatch "auto_update\s*=\s*no") {
            if ($content -match "auto_update\s*=\s*yes") {
                $content = $content -replace "auto_update\s*=\s*yes", "auto_update=no"
            }
            else {
                $content += "`nauto_update=no"
            }

            Set-Content $configFile $content
            Write-Log "Updated nessusd.conf" -Level "SUCCESS"
        }
    }

    Write-Log "Automatic updates disabled"
}

function Update-Configuration {
    param(
        [string]$NessusPath,
        [string]$NessusDataPath,
        [string]$NexusUrl,
        [string]$NexusUsername,
        [string]$NexusPassword,
        [string]$NexusRepository
    )

    $configPath = "$ScriptDir\..\config\settings.json"
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    $config.nessus.installPath = $NessusPath
    $config.nessus.dataPath = $NessusDataPath

    if ($NexusUrl) {
        $config.nexus.url = $NexusUrl
    }
    if ($NexusUsername) {
        $config.nexus.username = $NexusUsername
    }
    if ($NexusPassword) {
        $config.nexus.password = $NexusPassword
    }
    if ($NexusRepository) {
        $config.nexus.repository = $NexusRepository
    }

    $config | ConvertTo-Json -Depth 5 | Set-Content $configPath
    Write-Log "Configuration updated: $configPath" -Level "SUCCESS"
}

function New-PluginSyncScheduledTask {
    param([string]$ScriptPath)

    $taskName = "Nessus Plugin Sync"
    $description = "Downloads plugins from Nexus and applies to Nessus"

    # Remove existing task if present
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Log "Removed existing scheduled task"
    }

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath\Apply-PluginsFromNexus.ps1`" -Force"

    # Run weekly on Sunday at 3 AM
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3am

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable

    Register-ScheduledTask `
        -TaskName $taskName `
        -Description $description `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings

    Write-Log "Created scheduled task: $taskName" -Level "SUCCESS"
}

function Create-NexusRepository {
    param(
        [string]$NexusUrl,
        [string]$Username,
        [string]$Password,
        [string]$RepoName
    )

    Write-Log "Creating Nexus repository: $RepoName"

    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
    $headers = @{
        "Authorization" = "Basic $base64Auth"
        "Content-Type" = "application/json"
    }

    # Check if repo exists
    $checkUrl = "$NexusUrl/service/rest/v1/repositories/$RepoName"
    try {
        Invoke-RestMethod -Uri $checkUrl -Headers $headers -Method Get -ErrorAction Stop
        Write-Log "Repository '$RepoName' already exists" -Level "SUCCESS"
        return $true
    }
    catch {
        # Repo doesn't exist, create it
    }

    # Create raw hosted repository
    $repoConfig = @{
        name = $RepoName
        online = $true
        storage = @{
            blobStoreName = "default"
            strictContentTypeValidation = $false
            writePolicy = "ALLOW"
        }
        cleanup = $null
    }

    $createUrl = "$NexusUrl/service/rest/v1/repositories/raw/hosted"

    try {
        Invoke-RestMethod -Uri $createUrl -Headers $headers -Method Post -Body ($repoConfig | ConvertTo-Json -Depth 5) -ErrorAction Stop
        Write-Log "Repository '$RepoName' created" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to create repository: $_" -Level "WARN"
        Write-Log "Please create a 'raw (hosted)' repository named '$RepoName' manually in Nexus" -Level "WARN"
        return $false
    }
}

# Main execution
Write-Log "=== Nessus Plugin Manager Setup ===" -Level "SUCCESS"
Write-Host ""

# Check administrator privileges
if (-not (Test-Administrator)) {
    Write-Log "This script requires Administrator privileges" -Level "ERROR"
    Write-Log "Please run PowerShell as Administrator" -Level "ERROR"
    exit 1
}

# Find Nessus installation
$nessusPath = Find-NessusInstallation
if (-not $nessusPath) {
    Write-Log "Nessus installation not found" -Level "ERROR"
    Write-Log "Please install Nessus first from: https://www.tenable.com/downloads/nessus" -Level "ERROR"
    exit 1
}
Write-Log "Found Nessus at: $nessusPath" -Level "SUCCESS"

$nessusDataPath = Find-NessusDataPath
if (-not $nessusDataPath) {
    $nessusDataPath = "C:\ProgramData\Tenable\Nessus\nessus"
    Write-Log "Using default data path: $nessusDataPath" -Level "WARN"
}
else {
    Write-Log "Found Nessus data at: $nessusDataPath" -Level "SUCCESS"
}

# Create local storage directory
$storagePath = "C:\NessusPlugins"
if (-not (Test-Path $storagePath)) {
    New-Item -ItemType Directory -Path $storagePath -Force | Out-Null
    New-Item -ItemType Directory -Path "$storagePath\backups" -Force | Out-Null
    Write-Log "Created storage directory: $storagePath" -Level "SUCCESS"
}

# Disable auto-updates if requested
if ($DisableAutoUpdate) {
    Disable-NessusAutoUpdate -NessusCliPath $nessusPath

    # Restart Nessus to apply changes
    Write-Log "Restarting Nessus service..."
    Restart-Service -Name "Tenable Nessus" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    Write-Log "Nessus service restarted" -Level "SUCCESS"
}

# Update configuration
Update-Configuration `
    -NessusPath $nessusPath `
    -NessusDataPath $nessusDataPath `
    -NexusUrl $NexusUrl `
    -NexusUsername $NexusUsername `
    -NexusPassword $NexusPassword `
    -NexusRepository $NexusRepository

# Create Nexus repository if Nexus is configured
if ($NexusUrl -and $NexusPassword) {
    Create-NexusRepository `
        -NexusUrl $NexusUrl `
        -Username $NexusUsername `
        -Password $NexusPassword `
        -RepoName $NexusRepository
}

# Create scheduled task if requested
if ($CreateScheduledTask) {
    New-PluginSyncScheduledTask -ScriptPath $ScriptDir
}

Write-Host ""
Write-Log "=== Setup Complete ===" -Level "SUCCESS"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Edit config\settings.json with your Nexus credentials" -ForegroundColor White
Write-Host "2. Run: .\Download-NessusPlugins.ps1  (to export current plugins)" -ForegroundColor White
Write-Host "3. Run: .\Upload-ToNexus.ps1         (to upload to Nexus)" -ForegroundColor White
Write-Host "4. Run: .\Apply-PluginsFromNexus.ps1 (to apply from Nexus)" -ForegroundColor White
Write-Host ""
