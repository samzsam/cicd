<#
.SYNOPSIS
    Downloads Nessus plugins from Tenable and stores locally.
.DESCRIPTION
    This script downloads the latest plugin feed from Tenable using
    the challenge/response offline method or direct download with license.
.PARAMETER ConfigPath
    Path to the settings.json configuration file.
.PARAMETER Force
    Force download even if plugins were downloaded recently.
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\settings.json",
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
    Add-Content -Path "$logDir\download.log" -Value $logMessage
}

# Get Nessus challenge code for offline registration
function Get-NessusChallenge {
    param([string]$NessusCliPath)

    Write-Log "Retrieving Nessus challenge code..."
    $result = & "$NessusCliPath\nessuscli.exe" fetch --challenge 2>&1

    if ($result -match "Challenge code:\s*(\S+)") {
        return $matches[1]
    }
    throw "Failed to retrieve challenge code: $result"
}

# Download plugins using offline license file
function Download-PluginsOffline {
    param(
        [string]$LicenseFile,
        [string]$OutputPath
    )

    Write-Log "Downloading plugins using offline license..."

    # The offline URL is generated from Tenable's customer portal
    # Format: https://plugins.nessus.org/v2/nessus.php?f=all-2.0.tar.gz&u=<uuid>&p=<hash>

    if (-not (Test-Path $LicenseFile)) {
        throw "License file not found: $LicenseFile"
    }

    $licenseContent = Get-Content $LicenseFile -Raw
    if ($licenseContent -match "plugin_feed_url\s*=\s*(.+)") {
        $pluginUrl = $matches[1].Trim()

        $outputFile = Join-Path $OutputPath "all-2.0.tar.gz"
        Write-Log "Downloading from: $pluginUrl"

        Invoke-WebRequest -Uri $pluginUrl -OutFile $outputFile -UseBasicParsing

        return $outputFile
    }

    throw "Could not parse plugin feed URL from license file"
}

# Download plugins using Nessus CLI (if registered online)
function Download-PluginsViaCli {
    param(
        [string]$NessusCliPath,
        [string]$OutputPath
    )

    Write-Log "Downloading plugins via Nessus CLI..."

    # First, fetch plugins to Nessus installation
    $result = & "$NessusCliPath\nessuscli.exe" update --plugins-only 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download plugins: $result"
    }

    Write-Log "Plugins downloaded to Nessus installation"
    return $true
}

# Export current plugins from Nessus installation
function Export-InstalledPlugins {
    param(
        [string]$NessusDataPath,
        [string]$OutputPath
    )

    Write-Log "Exporting installed plugins..."

    $pluginsDir = Join-Path $NessusDataPath "plugins"
    if (-not (Test-Path $pluginsDir)) {
        throw "Plugins directory not found: $pluginsDir"
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $archiveName = "nessus-plugins-$timestamp.tar.gz"
    $outputFile = Join-Path $OutputPath $archiveName

    # Create tar.gz archive
    Push-Location $NessusDataPath
    try {
        & tar -czf $outputFile plugins
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create plugin archive"
        }
    }
    finally {
        Pop-Location
    }

    Write-Log "Plugins exported to: $outputFile"
    return $outputFile
}

# Main execution
try {
    Write-Log "=== Nessus Plugin Download Started ==="

    $config = Get-Config -Path $ConfigPath

    $nessusPath = $config.nessus.installPath
    $nessusDataPath = $config.nessus.dataPath
    $storagePath = $config.pluginStorage.localPath

    # Ensure storage directory exists
    if (-not (Test-Path $storagePath)) {
        New-Item -ItemType Directory -Path $storagePath -Force | Out-Null
        Write-Log "Created storage directory: $storagePath"
    }

    # Check if we should download
    $lastDownloadFile = Join-Path $storagePath ".last_download"
    if ((Test-Path $lastDownloadFile) -and -not $Force) {
        $lastDownload = Get-Content $lastDownloadFile
        $lastDate = [DateTime]::Parse($lastDownload)
        $hoursSince = (Get-Date) - $lastDate

        if ($hoursSince.TotalHours -lt 24) {
            Write-Log "Plugins downloaded within last 24 hours. Use -Force to override."
            exit 0
        }
    }

    # Method 1: Try to export from existing Nessus installation
    # This assumes Nessus has already downloaded plugins
    $pluginArchive = $null

    if (Test-Path "$nessusDataPath\plugins") {
        Write-Log "Found existing Nessus plugins, exporting..."
        $pluginArchive = Export-InstalledPlugins -NessusDataPath $nessusDataPath -OutputPath $storagePath
    }
    else {
        Write-Log "No existing plugins found. Please ensure Nessus has downloaded plugins at least once."
        Write-Log "You can manually download plugins from Tenable's customer portal."
    }

    if ($pluginArchive) {
        # Record download time
        Get-Date -Format "o" | Set-Content $lastDownloadFile

        # Create a 'latest' symlink/copy for easy reference
        $latestPath = Join-Path $storagePath "latest-plugins.tar.gz"
        Copy-Item $pluginArchive $latestPath -Force

        Write-Log "Plugin archive ready: $pluginArchive"
        Write-Log "Latest plugins: $latestPath"

        # Output for pipeline
        Write-Output @{
            Success = $true
            ArchivePath = $pluginArchive
            LatestPath = $latestPath
            Timestamp = Get-Date -Format "o"
        } | ConvertTo-Json
    }

    Write-Log "=== Nessus Plugin Download Completed ==="
}
catch {
    Write-Log "ERROR: $_" -Level "ERROR"
    Write-Log $_.ScriptStackTrace -Level "ERROR"
    exit 1
}
