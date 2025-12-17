<#
.SYNOPSIS
    Uploads Nessus plugin archives to Nexus Repository.
.DESCRIPTION
    This script uploads plugin archives to a Nexus raw repository
    for centralized storage and distribution to air-gapped Nessus instances.
.PARAMETER PluginArchive
    Path to the plugin archive to upload. If not specified, uploads the latest.
.PARAMETER ConfigPath
    Path to the settings.json configuration file.
#>

param(
    [string]$PluginArchive,
    [string]$ConfigPath = "$PSScriptRoot\..\config\settings.json"
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
    Add-Content -Path "$logDir\upload.log" -Value $logMessage
}

# Test Nexus connectivity
function Test-NexusConnection {
    param(
        [string]$NexusUrl,
        [PSCredential]$Credential
    )

    Write-Log "Testing Nexus connectivity..."
    $uri = "$NexusUrl/service/rest/v1/status"

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
        Write-Log "Nexus is available"
        return $true
    }
    catch {
        Write-Log "Failed to connect to Nexus: $_" -Level "WARN"
        return $false
    }
}

# Ensure repository exists in Nexus
function Ensure-NexusRepository {
    param(
        [string]$NexusUrl,
        [string]$RepositoryName,
        [PSCredential]$Credential
    )

    Write-Log "Checking if repository '$RepositoryName' exists..."
    $uri = "$NexusUrl/service/rest/v1/repositories"

    try {
        $headers = @{}
        if ($Credential) {
            $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"))
            $headers["Authorization"] = "Basic $base64Auth"
        }

        $repos = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

        if ($repos.name -contains $RepositoryName) {
            Write-Log "Repository '$RepositoryName' exists"
            return $true
        }

        Write-Log "Repository '$RepositoryName' not found. Please create it in Nexus." -Level "WARN"
        Write-Log "Create a 'raw (hosted)' repository named '$RepositoryName'" -Level "WARN"
        return $false
    }
    catch {
        Write-Log "Could not verify repository: $_" -Level "WARN"
        return $false
    }
}

# Upload file to Nexus raw repository
function Upload-ToNexusRaw {
    param(
        [string]$NexusUrl,
        [string]$RepositoryName,
        [string]$FilePath,
        [string]$TargetPath,
        [PSCredential]$Credential
    )

    $fileName = Split-Path $FilePath -Leaf
    $uri = "$NexusUrl/repository/$RepositoryName/$TargetPath/$fileName"

    Write-Log "Uploading to: $uri"

    $headers = @{}
    if ($Credential) {
        $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"))
        $headers["Authorization"] = "Basic $base64Auth"
    }

    # Read file as bytes
    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)

    $response = Invoke-WebRequest -Uri $uri -Method Put -Headers $headers -Body $fileBytes -ContentType "application/gzip" -UseBasicParsing

    if ($response.StatusCode -eq 201 -or $response.StatusCode -eq 200) {
        Write-Log "Upload successful: $fileName"
        return $uri
    }

    throw "Upload failed with status: $($response.StatusCode)"
}

# Update the 'latest' pointer in Nexus
function Update-LatestPointer {
    param(
        [string]$NexusUrl,
        [string]$RepositoryName,
        [string]$SourcePath,
        [PSCredential]$Credential
    )

    Write-Log "Updating 'latest' pointer..."

    # Upload a copy as 'latest-plugins.tar.gz'
    $latestUri = "$NexusUrl/repository/$RepositoryName/latest/nessus-plugins-latest.tar.gz"

    $headers = @{}
    if ($Credential) {
        $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"))
        $headers["Authorization"] = "Basic $base64Auth"
    }

    $fileBytes = [System.IO.File]::ReadAllBytes($SourcePath)

    $response = Invoke-WebRequest -Uri $latestUri -Method Put -Headers $headers -Body $fileBytes -ContentType "application/gzip" -UseBasicParsing

    if ($response.StatusCode -eq 201 -or $response.StatusCode -eq 200) {
        Write-Log "Latest pointer updated"
        return $latestUri
    }

    Write-Log "Failed to update latest pointer" -Level "WARN"
}

# Create metadata file
function Create-MetadataFile {
    param(
        [string]$PluginArchive,
        [string]$OutputPath
    )

    $fileInfo = Get-Item $PluginArchive
    $hash = (Get-FileHash $PluginArchive -Algorithm SHA256).Hash

    $metadata = @{
        filename = $fileInfo.Name
        size = $fileInfo.Length
        sha256 = $hash
        uploadedAt = Get-Date -Format "o"
        uploadedBy = $env:USERNAME
        hostname = $env:COMPUTERNAME
    }

    $metadataPath = Join-Path $OutputPath "$($fileInfo.BaseName).metadata.json"
    $metadata | ConvertTo-Json | Set-Content $metadataPath

    return $metadataPath
}

# Main execution
try {
    Write-Log "=== Nexus Upload Started ==="

    $config = Get-Config -Path $ConfigPath

    $nexusUrl = $config.nexus.url
    $repoName = $config.nexus.repository
    $username = $config.nexus.username
    $password = $config.nexus.password
    $storagePath = $config.pluginStorage.localPath

    # Create credential
    $credential = $null
    if ($username -and $password) {
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        $credential = New-Object PSCredential($username, $securePassword)
    }

    # Determine which archive to upload
    if (-not $PluginArchive) {
        $PluginArchive = Join-Path $storagePath "latest-plugins.tar.gz"
        if (-not (Test-Path $PluginArchive)) {
            throw "No plugin archive found. Run Download-NessusPlugins.ps1 first."
        }
    }

    if (-not (Test-Path $PluginArchive)) {
        throw "Plugin archive not found: $PluginArchive"
    }

    Write-Log "Plugin archive: $PluginArchive"
    $archiveInfo = Get-Item $PluginArchive
    Write-Log "Archive size: $([math]::Round($archiveInfo.Length / 1MB, 2)) MB"

    # Test Nexus connectivity
    if (-not (Test-NexusConnection -NexusUrl $nexusUrl -Credential $credential)) {
        throw "Cannot connect to Nexus at $nexusUrl"
    }

    # Check repository exists
    Ensure-NexusRepository -NexusUrl $nexusUrl -RepositoryName $repoName -Credential $credential

    # Create metadata
    $metadataPath = Create-MetadataFile -PluginArchive $PluginArchive -OutputPath $storagePath

    # Upload to dated folder
    $dateFolder = Get-Date -Format "yyyy/MM/dd"

    $uploadedUri = Upload-ToNexusRaw `
        -NexusUrl $nexusUrl `
        -RepositoryName $repoName `
        -FilePath $PluginArchive `
        -TargetPath $dateFolder `
        -Credential $credential

    # Upload metadata
    Upload-ToNexusRaw `
        -NexusUrl $nexusUrl `
        -RepositoryName $repoName `
        -FilePath $metadataPath `
        -TargetPath $dateFolder `
        -Credential $credential

    # Update latest pointer
    $latestUri = Update-LatestPointer `
        -NexusUrl $nexusUrl `
        -RepositoryName $repoName `
        -SourcePath $PluginArchive `
        -Credential $credential

    Write-Log "=== Nexus Upload Completed ==="

    # Output for pipeline
    Write-Output @{
        Success = $true
        UploadedUri = $uploadedUri
        LatestUri = $latestUri
        Timestamp = Get-Date -Format "o"
    } | ConvertTo-Json
}
catch {
    Write-Log "ERROR: $_" -Level "ERROR"
    Write-Log $_.ScriptStackTrace -Level "ERROR"
    exit 1
}
