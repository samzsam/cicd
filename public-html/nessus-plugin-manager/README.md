# Nessus Plugin Manager

Controlled Nessus plugin distribution using Nexus Repository as an intermediary.

## Overview

This solution provides controlled plugin updates for Tenable Nessus by:

1. **Downloading** plugins from Tenable (or exporting from an existing Nessus installation)
2. **Uploading** plugins to Nexus Repository for centralized storage
3. **Applying** plugins manually from Nexus after review/approval

This prevents automatic plugin updates from the internet while maintaining the ability to update plugins in a controlled manner.

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Tenable       │     │     Nexus       │     │    Nessus       │
│   (Internet)    │────►│   Repository    │────►│   Scanner       │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
   Download               Upload/Store            Pull & Apply
   Plugins                 Plugins                 Manually
```

## Prerequisites

### Windows
- Windows Server/Workstation
- PowerShell 5.1+
- Tenable Nessus installed
- Administrator privileges

### Linux (Amazon Linux)
- Amazon Linux 2 / Amazon Linux 2023
- bash, curl, jq, tar
- Tenable Nessus installed
- Root privileges

### Common
- Nexus Repository Manager (or similar artifact repository)

---

# Windows Setup

## Quick Start

### 1. Initial Setup

Run the setup script as Administrator:

```powershell
cd nessus-plugin-manager\scripts

# Basic setup - disable auto-updates
.\Setup-NessusPluginManager.ps1 -DisableAutoUpdate

# Full setup with Nexus configuration
.\Setup-NessusPluginManager.ps1 `
    -NexusUrl "http://nexus.local:8081" `
    -NexusUsername "admin" `
    -NexusPassword "your-password" `
    -NexusRepository "nessus-plugins" `
    -DisableAutoUpdate `
    -CreateScheduledTask
```

### 2. Configure Settings

Edit `config\settings.json` with your environment details:

```json
{
  "nessus": {
    "installPath": "C:\\Program Files\\Tenable\\Nessus",
    "dataPath": "C:\\ProgramData\\Tenable\\Nessus\\nessus",
    "webUrl": "https://localhost:8834"
  },
  "nexus": {
    "url": "http://nexus.local:8081",
    "repository": "nessus-plugins",
    "username": "admin",
    "password": "your-nexus-password"
  },
  "pluginStorage": {
    "localPath": "C:\\NessusPlugins",
    "retentionDays": 30
  },
  "schedule": {
    "manualApprovalRequired": true
  }
}
```

### 3. Usage

```powershell
# Export plugins from Nessus
.\Download-NessusPlugins.ps1

# Upload to Nexus
.\Upload-ToNexus.ps1

# Apply from Nexus (interactive)
.\Apply-PluginsFromNexus.ps1

# Apply from Nexus (auto)
.\Apply-PluginsFromNexus.ps1 -Force

# Full workflow
.\Sync-PluginWorkflow.ps1 -Mode full
```

---

# Linux (Amazon Linux) Setup

## Quick Start

### 1. Install Nessus

```bash
cd nessus-plugin-manager/scripts/linux
chmod +x *.sh

# Download Nessus RPM from https://www.tenable.com/downloads/nessus
# Then install:
./install-nessus.sh Nessus-10.x.x-amzn2.x86_64.rpm --license YOUR-LICENSE-KEY
```

### 2. Initial Setup

```bash
# Basic setup - disable auto-updates
sudo ./setup-nessus-plugin-manager.sh --disable-auto-update

# Full setup with Nexus configuration
sudo ./setup-nessus-plugin-manager.sh \
    --nexus-url "http://nexus.local:8081" \
    --nexus-user "admin" \
    --nexus-pass "your-password" \
    --nexus-repo "nessus-plugins" \
    --disable-auto-update \
    --create-cron
```

### 3. Configure Settings

Edit `config/settings-linux.json`:

```json
{
  "nessus": {
    "installPath": "/opt/nessus/sbin",
    "dataPath": "/opt/nessus/var/nessus",
    "configPath": "/opt/nessus/etc/nessus",
    "webUrl": "https://localhost:8834"
  },
  "nexus": {
    "url": "http://nexus.local:8081",
    "repository": "nessus-plugins",
    "username": "admin",
    "password": "your-nexus-password"
  },
  "pluginStorage": {
    "localPath": "/var/lib/nessus-plugins",
    "retentionDays": 30
  },
  "schedule": {
    "manualApprovalRequired": true
  }
}
```

### 4. Usage

```bash
# Export plugins from Nessus
./download-nessus-plugins.sh

# Upload to Nexus
./upload-to-nexus.sh

# Apply from Nexus (interactive)
./apply-plugins-from-nexus.sh

# Apply from Nexus (auto)
./apply-plugins-from-nexus.sh --force

# Full workflow
./sync-plugin-workflow.sh --mode full

# Apply only (pull from Nexus)
./sync-plugin-workflow.sh --mode apply --force
```

---

# Create Nexus Repository

In Nexus Repository Manager:
1. Go to **Settings** → **Repositories** → **Create repository**
2. Select **raw (hosted)**
3. Name: `nessus-plugins`
4. Blob store: default
5. Deployment policy: Allow redeploy

---

# Disabling Auto-Updates Manually

## Windows

### Method 1: CLI
```powershell
Stop-Service "Tenable Nessus"
& "C:\Program Files\Tenable\Nessus\nessuscli.exe" fix --set auto_update=no
& "C:\Program Files\Tenable\Nessus\nessuscli.exe" fix --set auto_update_ui=no
Start-Service "Tenable Nessus"
```

### Method 2: Config File
Edit `C:\ProgramData\Tenable\Nessus\nessus\nessusd.conf`:
```ini
auto_update=no
auto_update_ui=no
```

## Linux

### Method 1: CLI
```bash
sudo systemctl stop nessusd
sudo /opt/nessus/sbin/nessuscli fix --set auto_update=no
sudo /opt/nessus/sbin/nessuscli fix --set auto_update_ui=no
sudo systemctl start nessusd
```

### Method 2: Config File
Edit `/opt/nessus/etc/nessus/nessusd.conf`:
```ini
auto_update=no
auto_update_ui=no
```

## Web UI (Both)
1. Log into Nessus at `https://localhost:8834`
2. Go to **Settings** → **Software Update**
3. Set **Automatic Updates** to **Disabled**

---

# Directory Structure

```
nessus-plugin-manager/
├── config/
│   ├── settings.json           # Windows configuration
│   └── settings-linux.json     # Linux configuration
├── scripts/
│   ├── Setup-NessusPluginManager.ps1     # Windows setup
│   ├── Download-NessusPlugins.ps1        # Windows export
│   ├── Upload-ToNexus.ps1                # Windows upload
│   ├── Apply-PluginsFromNexus.ps1        # Windows apply
│   ├── Sync-PluginWorkflow.ps1           # Windows workflow
│   └── linux/
│       ├── install-nessus.sh             # Linux install helper
│       ├── setup-nessus-plugin-manager.sh # Linux setup
│       ├── download-nessus-plugins.sh    # Linux export
│       ├── upload-to-nexus.sh            # Linux upload
│       ├── apply-plugins-from-nexus.sh   # Linux apply
│       └── sync-plugin-workflow.sh       # Linux workflow
├── logs/
└── README.md

Plugin Storage:
  Windows: C:\NessusPlugins\
  Linux:   /var/lib/nessus-plugins/
```

---

# Nexus Repository Structure

```
nessus-plugins/
├── latest/
│   └── nessus-plugins-latest.tar.gz    # Always points to most recent
├── 2024/
│   └── 12/
│       └── 16/
│           ├── nessus-plugins-20241216-103000.tar.gz
│           └── nessus-plugins-20241216-103000.metadata.json
```

---

# Troubleshooting

## Windows

### Nessus service won't stop
```powershell
Stop-Process -Name "nessusd" -Force
Stop-Service "Tenable Nessus" -Force
```

### Check auto-update status
```powershell
& "C:\Program Files\Tenable\Nessus\nessuscli.exe" fix --list | Select-String "auto_update"
```

## Linux

### Nessus service won't stop
```bash
sudo pkill -9 nessusd
sudo systemctl stop nessusd
```

### Check auto-update status
```bash
sudo /opt/nessus/sbin/nessuscli fix --list | grep auto_update
```

## Common Issues

### Plugin update fails
- Verify archive is valid: `tar -tzf archive.tar.gz`
- Check Nessus CLI path is correct
- Ensure service account has permissions

### Nexus upload fails
- Verify repository exists and is type `raw (hosted)`
- Check credentials in settings file
- Ensure deployment policy allows uploads

---

# Security Considerations

- Store Nexus credentials securely
- Restrict access to plugin storage directories
- Review plugins before applying in production
- Keep backups of working plugin sets
- Consider network segmentation for Nessus scanners
- Use HTTPS for Nexus if possible
