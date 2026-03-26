#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer for cli-screenshot.
.DESCRIPTION
    Downloads and installs cli-screenshot to ~/.cli-screenshot/
    Creates a .cmd wrapper and adds to User PATH.
.EXAMPLE
    irm https://raw.githubusercontent.com/kerwin77106/Cli-Screenshot/main/install.ps1 | iex
#>

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:USERPROFILE '.cli-screenshot'
$binDir = Join-Path $installDir 'bin'
$repoZipUrl = 'https://github.com/kerwin77106/Cli-Screenshot/archive/refs/heads/main.zip'
$tempZip = Join-Path $env:TEMP 'cli-screenshot-install.zip'
$tempExtract = Join-Path $env:TEMP 'cli-screenshot-extract'

Write-Host "Installing cli-screenshot..." -ForegroundColor Cyan

# Step 1: Download repo zip
Write-Host "Downloading..."
try {
    Invoke-WebRequest -Uri $repoZipUrl -OutFile $tempZip -UseBasicParsing
} catch {
    Write-Error "Failed to download: $($_.Exception.Message)"
    exit 1
}

# Step 2: Extract to temp directory
Write-Host "Extracting..."
if (Test-Path $tempExtract) {
    Remove-Item $tempExtract -Recurse -Force
}
Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

# Find the extracted folder (usually cli-screenshot-main/)
$extractedFolder = Get-ChildItem $tempExtract -Directory | Select-Object -First 1

# Step 3: Copy to install directory
if (Test-Path $installDir) {
    # Preserve bin/ wrapper if it exists
    $existingBin = $null
    $wrapperPath = Join-Path $binDir 'cli-screenshot.cmd'
    if (Test-Path $wrapperPath) {
        $existingBin = $true
    }

    # Remove old files except bin/
    Get-ChildItem $installDir -Exclude 'bin' | Remove-Item -Recurse -Force
}

if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

Copy-Item -Path (Join-Path $extractedFolder.FullName '*') -Destination $installDir -Recurse -Force

# Step 4: Create .cmd wrapper
if (-not (Test-Path $binDir)) {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
}

$wrapperContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.cli-screenshot\cli-screenshot.ps1" %*
"@

$wrapperPath = Join-Path $binDir 'cli-screenshot.cmd'
[System.IO.File]::WriteAllText($wrapperPath, $wrapperContent)

# Step 5: Add bin/ to User PATH if not present
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$binDir*") {
    $newPath = "$userPath;$binDir"
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "Added $binDir to User PATH." -ForegroundColor Green

    # Also update current session
    $env:Path = "$env:Path;$binDir"
}

# Step 6: Cleanup temp files
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "  Location: $installDir"
Write-Host "  Command:  cli-screenshot"
Write-Host ""
Write-Host "If 'cli-screenshot' command is not available, please restart your terminal." -ForegroundColor Yellow
