<#
.SYNOPSIS
    Downloads and applies Nessus plugins from Nexus Repository.
.DESCRIPTION
    This script pulls plugin archives from Nexus and applies them to
    the local Nessus installation using nessuscli.
.PARAMETER Version
    Specific version/date to download (format: yyyy/MM/dd). Default: latest.
.PARAMETER ConfigPath
    Path to the settings.json configuration file.
.PARAMETER DryRun
    Download but don't apply plugins.
.PARAMETER Force
    Apply without confirmation prompt.
#>

param(
    [string]$Version = "latest",
    [string]$ConfigPath = "$PSScriptRoot\..\config\settings.json",
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Load configuration
function Get-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }
    return Get-Content $Path -Raw | ConvertFrom-Json
}

# Initialize logging
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage

    $logDir = "$PSScriptRoot\..\logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path "$logDir\apply.log" -Value $logMessage
}

# Download plugin archive from Nexus
function Download-FromNexus {
    param(
        [string]$NexusUrl,
        [string]$RepositoryName,
        [string]$Version,
        [string]$OutputPath,
        [PSCredential]$Credential
    )

    $headers = @{}
    if ($Credential) {
        $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"))
        $headers["Authorization"] = "Basic $base64Auth"
    }

    # Determine download URL
    if ($Version -eq "latest") {
        $downloadUrl = "$NexusUrl/repository/$RepositoryName/latest/nessus-plugins-latest.tar.gz"
        $outputFile = Join-Path $OutputPath "nessus-plugins-latest.tar.gz"
    }
    else {
        # Version is expected to be a date path like "2024/12/16"
        # Need to find the actual filename - list the directory first
        $searchUrl = "$NexusUrl/service/rest/v1/search/assets?repository=$RepositoryName&group=/$Version"

        try {
            $assets = Invoke-RestMethod -Uri $searchUrl -Headers $headers -ErrorAction Stop

            $pluginAsset = $assets.items | Where-Object { $_.path -like "*.tar.gz" -and $_.path -notlike "*.metadata*" } | Select-Object -First 1

            if (-not $pluginAsset) {
                throw "No plugin archive found for version: $Version"
            }

            $downloadUrl = $pluginAsset.downloadUrl
            $outputFile = Join-Path $OutputPath (Split-Path $pluginAsset.path -Leaf)
        }
        catch {
            Write-Log "Could not search Nexus, trying direct path..." -Level "WARN"
            # Fallback: try constructing a direct path
            $downloadUrl = "$NexusUrl/repository/$RepositoryName/$Version/nessus-plugins.tar.gz"
            $outputFile = Join-Path $OutputPath "nessus-plugins-$($Version -replace '/','-').tar.gz"
        }
    }

    Write-Log "Downloading from: $downloadUrl"

    Invoke-WebRequest -Uri $downloadUrl -OutFile $outputFile -Headers $headers -UseBasicParsing

    if (-not (Test-Path $outputFile)) {
        throw "Download failed: output file not created"
    }

    $fileInfo = Get-Item $outputFile
    Write-Log "Downloaded: $($fileInfo.Name) ($([math]::Round($fileInfo.Length / 1MB, 2)) MB)"

    return $outputFile
}

# Verify plugin archive integrity
function Test-PluginArchive {
    param([string]$ArchivePath)

    Write-Log "Verifying archive integrity..."

    # Check if it's a valid gzip/tar file
    try {
        $result = & tar -tzf $ArchivePath 2>&1 | Select-Object -First 10

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Archive is valid"
            return $true
        }
    }
    catch {
        Write-Log "Archive verification failed: $_" -Level "ERROR"
    }

    return $false
}

# Get current Nessus plugin info
function Get-CurrentPluginInfo {
    param([string]$NessusCliPath)

    Write-Log "Getting current plugin information..."

    try {
        $result = & "$NessusCliPath\nessuscli.exe" update --plugins-only --check 2>&1
        return $result
    }
    catch {
        return "Unable to retrieve plugin info"
    }
}

# Stop Nessus service
function Stop-NessusService {
    Write-Log "Stopping Nessus service..."

    $service = Get-Service -Name "Tenable Nessus" -ErrorAction SilentlyContinue

    if ($service -and $service.Status -eq "Running") {
        Stop-Service -Name "Tenable Nessus" -Force
        Start-Sleep -Seconds 5

        $service = Get-Service -Name "Tenable Nessus"
        if ($service.Status -ne "Stopped") {
            throw "Failed to stop Nessus service"
        }
        Write-Log "Nessus service stopped"
    }
    else {
        Write-Log "Nessus service is not running"
    }
}

# Start Nessus service
function Start-NessusService {
    Write-Log "Starting Nessus service..."

    Start-Service -Name "Tenable Nessus"
    Start-Sleep -Seconds 10

    $service = Get-Service -Name "Tenable Nessus"
    if ($service.Status -ne "Running") {
        throw "Failed to start Nessus service"
    }
    Write-Log "Nessus service started"
}

# Apply plugins using nessuscli
function Apply-Plugins {
    param(
        [string]$NessusCliPath,
        [string]$PluginArchive
    )

    Write-Log "Applying plugins from: $PluginArchive"

    # Use nessuscli update command
    $result = & "$NessusCliPath\nessuscli.exe" update $PluginArchive 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Plugin update failed: $result"
    }

    Write-Log "Plugins applied successfully"
    Write-Log "Output: $result"

    return $result
}

# Create backup of current plugins
function Backup-CurrentPlugins {
    param(
        [string]$NessusDataPath,
        [string]$BackupPath
    )

    $pluginsDir = Join-Path $NessusDataPath "plugins"

    if (-not (Test-Path $pluginsDir)) {
        Write-Log "No existing plugins to backup" -Level "WARN"
        return $null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupFile = Join-Path $BackupPath "plugins-backup-$timestamp.tar.gz"

    Write-Log "Creating backup: $backupFile"

    Push-Location $NessusDataPath
    try {
        & tar -czf $backupFile plugins 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Backup creation failed" -Level "WARN"
            return $null
        }
    }
    finally {
        Pop-Location
    }

    Write-Log "Backup created: $backupFile"
    return $backupFile
}

# Main execution
try {
    Write-Log "=== Plugin Apply from Nexus Started ==="
    Write-Log "Version: $Version"
    Write-Log "Dry Run: $DryRun"

    $config = Get-Config -Path $ConfigPath

    $nessusPath = $config.nessus.installPath
    $nessusDataPath = $config.nessus.dataPath
    $nexusUrl = $config.nexus.url
    $repoName = $config.nexus.repository
    $username = $config.nexus.username
    $password = $config.nexus.password
    $storagePath = $config.pluginStorage.localPath
    $manualApproval = $config.schedule.manualApprovalRequired

    # Create credential
    $credential = $null
    if ($username -and $password) {
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        $credential = New-Object PSCredential($username, $securePassword)
    }

    # Ensure storage directory exists
    if (-not (Test-Path $storagePath)) {
        New-Item -ItemType Directory -Path $storagePath -Force | Out-Null
    }

    # Download from Nexus
    $downloadedArchive = Download-FromNexus `
        -NexusUrl $nexusUrl `
        -RepositoryName $repoName `
        -Version $Version `
        -OutputPath $storagePath `
        -Credential $credential

    # Verify archive
    if (-not (Test-PluginArchive -ArchivePath $downloadedArchive)) {
        throw "Plugin archive verification failed"
    }

    # Show current plugin info
    $currentInfo = Get-CurrentPluginInfo -NessusCliPath $nessusPath
    Write-Log "Current plugin status: $currentInfo"

    if ($DryRun) {
        Write-Log "DRY RUN: Would apply plugins from $downloadedArchive"
        Write-Log "=== Dry Run Completed ==="
        exit 0
    }

    # Confirm if manual approval required
    if ($manualApproval -and -not $Force) {
        Write-Host ""
        Write-Host "Plugin archive downloaded: $downloadedArchive" -ForegroundColor Yellow
        Write-Host "Current Nessus status: $currentInfo" -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host "Apply plugins now? (y/N)"

        if ($confirm -ne "y" -and $confirm -ne "Y") {
            Write-Log "Plugin application cancelled by user"
            exit 0
        }
    }

    # Create backup
    $backupDir = Join-Path $storagePath "backups"
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    $backupFile = Backup-CurrentPlugins -NessusDataPath $nessusDataPath -BackupPath $backupDir

    # Stop Nessus
    Stop-NessusService

    try {
        # Apply plugins
        $applyResult = Apply-Plugins -NessusCliPath $nessusPath -PluginArchive $downloadedArchive
    }
    finally {
        # Always restart Nessus
        Start-NessusService
    }

    # Record application
    $applyRecord = @{
        appliedAt = Get-Date -Format "o"
        archive = $downloadedArchive
        version = $Version
        backup = $backupFile
        result = $applyResult
    }

    $recordPath = Join-Path $storagePath "apply-history.json"
    $history = @()
    if (Test-Path $recordPath) {
        $history = Get-Content $recordPath -Raw | ConvertFrom-Json
    }
    $history += $applyRecord
    $history | ConvertTo-Json -Depth 5 | Set-Content $recordPath

    Write-Log "=== Plugin Apply Completed ==="

    # Output for pipeline
    Write-Output @{
        Success = $true
        Archive = $downloadedArchive
        Backup = $backupFile
        Timestamp = Get-Date -Format "o"
    } | ConvertTo-Json
}
catch {
    Write-Log "ERROR: $_" -Level "ERROR"
    Write-Log $_.ScriptStackTrace -Level "ERROR"
    exit 1
}
