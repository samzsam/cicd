<#
.SYNOPSIS
    Full plugin sync workflow: Download -> Upload to Nexus -> Apply from Nexus
.DESCRIPTION
    Orchestrates the complete plugin management workflow. Can be used for
    initial setup or scheduled sync operations.
.PARAMETER Mode
    Workflow mode: 'full' (download+upload+apply), 'upload' (download+upload), 'apply' (apply only)
.PARAMETER ConfigPath
    Path to configuration file.
.PARAMETER Force
    Skip confirmation prompts.
#>

param(
    [ValidateSet("full", "upload", "apply")]
    [string]$Mode = "full",
    [string]$ConfigPath = "$PSScriptRoot\..\config\settings.json",
    [switch]$Force
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
        "STEP" { Write-Host $logMessage -ForegroundColor Cyan }
        default { Write-Host $logMessage }
    }

    $logDir = "$ScriptDir\..\logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path "$logDir\workflow.log" -Value $logMessage
}

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Log "=== $Name ===" -Level "STEP"

    try {
        & $Action
        Write-Log "$Name completed" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log "$Name failed: $_" -Level "ERROR"
        return $false
    }
}

# Main workflow
Write-Host ""
Write-Log "========================================" -Level "STEP"
Write-Log "  Nessus Plugin Sync Workflow" -Level "STEP"
Write-Log "  Mode: $Mode" -Level "STEP"
Write-Log "========================================" -Level "STEP"
Write-Host ""

$success = $true

# Step 1: Download plugins (for 'full' and 'upload' modes)
if ($Mode -eq "full" -or $Mode -eq "upload") {
    $downloadResult = Invoke-Step -Name "Step 1: Download Plugins" -Action {
        $params = @{
            ConfigPath = $ConfigPath
        }
        if ($Force) { $params["Force"] = $true }

        & "$ScriptDir\Download-NessusPlugins.ps1" @params

        if ($LASTEXITCODE -ne 0) {
            throw "Download script failed"
        }
    }

    if (-not $downloadResult) {
        Write-Log "Workflow aborted due to download failure" -Level "ERROR"
        exit 1
    }
}

# Step 2: Upload to Nexus (for 'full' and 'upload' modes)
if ($Mode -eq "full" -or $Mode -eq "upload") {
    $uploadResult = Invoke-Step -Name "Step 2: Upload to Nexus" -Action {
        & "$ScriptDir\Upload-ToNexus.ps1" -ConfigPath $ConfigPath

        if ($LASTEXITCODE -ne 0) {
            throw "Upload script failed"
        }
    }

    if (-not $uploadResult) {
        Write-Log "Workflow aborted due to upload failure" -Level "ERROR"
        exit 1
    }
}

# Step 3: Apply from Nexus (for 'full' and 'apply' modes)
if ($Mode -eq "full" -or $Mode -eq "apply") {
    $applyResult = Invoke-Step -Name "Step 3: Apply Plugins from Nexus" -Action {
        $params = @{
            ConfigPath = $ConfigPath
            Version = "latest"
        }
        if ($Force) { $params["Force"] = $true }

        & "$ScriptDir\Apply-PluginsFromNexus.ps1" @params

        if ($LASTEXITCODE -ne 0) {
            throw "Apply script failed"
        }
    }

    if (-not $applyResult) {
        Write-Log "Workflow completed with warnings (apply step had issues)" -Level "WARN"
        exit 1
    }
}

Write-Host ""
Write-Log "========================================" -Level "SUCCESS"
Write-Log "  Workflow Completed Successfully!" -Level "SUCCESS"
Write-Log "========================================" -Level "SUCCESS"
Write-Host ""
