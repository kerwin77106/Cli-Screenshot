$script:PidFile = Join-Path $env:TEMP 'cli-screenshot.pid'
$script:LogFile = Join-Path $env:TEMP 'cli-screenshot.log'
$script:RefCountFile = Join-Path $env:TEMP 'cli-screenshot.refcount'

function Get-RefCount {
    if (-not (Test-Path $script:RefCountFile)) { return 0 }
    $val = (Get-Content $script:RefCountFile -Raw).Trim()
    if ($val -match '^\d+$') { return [int]$val } else { return 0 }
}

function Set-RefCount {
    param([int]$Count)
    if ($Count -le 0) {
        Remove-Item $script:RefCountFile -Force -ErrorAction SilentlyContinue
    } else {
        $Count | Set-Content -Path $script:RefCountFile -NoNewline
    }
}

function Test-CliScreenshotProcess {
    <#
    .SYNOPSIS
    Three-layer PID validation to prevent killing unrelated processes.
    Returns the process object if valid, $null otherwise. Cleans up stale PID file.
    #>
    param([int]$PidNumber)

    # Layer 1: Process exists?
    $proc = Get-Process -Id $PidNumber -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Layer 2: Is it a PowerShell process?
    if ($proc.Name -notmatch 'powershell|pwsh') {
        Write-Warning "PID $PidNumber is not a PowerShell process (actual: $($proc.Name)). Removing stale PID file."
        Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Layer 3: CommandLine contains cli-screenshot?
    $wmiProc = Get-CimInstance Win32_Process -Filter "ProcessId = $PidNumber" -ErrorAction SilentlyContinue
    if ($null -eq $wmiProc -or $wmiProc.CommandLine -notlike '*cli-screenshot*') {
        Write-Warning "PID $PidNumber is a PowerShell process but not cli-screenshot. Removing stale PID file."
        Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    return $proc
}

function Start-CliScreenshot {
    param(
        [switch]$Daemon,
        [int]$Interval = 250,
        [string]$Output,
        [switch]$Quiet
    )

    # Check for existing running instance (skip if the PID is ourselves - daemon child scenario)
    if (Test-Path $script:PidFile) {
        $existingPid = [int](Get-Content $script:PidFile -Raw).Trim()
        if ($existingPid -ne $PID) {
            $existingProc = Test-CliScreenshotProcess -PidNumber $existingPid
            if ($null -ne $existingProc) {
                Set-RefCount ((Get-RefCount) + 1)
                if (-not $Quiet) {
                    Write-Host "cli-screenshot is already running (PID: $existingPid). RefCount: $(Get-RefCount)"
                }
                return
            }
        }
    }

    if ($Daemon) {
        # Background mode
        # Detect current PowerShell executable and add STA if needed
        $psExe = (Get-Process -Id $PID).Path

        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'cli-screenshot.ps1'
        $scriptPath = (Resolve-Path $scriptPath).Path

        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')

        # pwsh.exe (PS7) needs -STA explicitly
        if ($psExe -match 'pwsh') {
            $arguments += '-STA'
        }

        $arguments += @('-WindowStyle', 'Hidden', '-File', $scriptPath, 'start', '-Interval', $Interval, '-Output', $Output)

        $process = Start-Process -FilePath $psExe -ArgumentList $arguments -PassThru -WindowStyle Hidden

        # Write child PID
        $process.Id | Set-Content -Path $script:PidFile -NoNewline
        Set-RefCount 1

        if (-not $Quiet) {
            Write-Host "cli-screenshot started in background (PID: $($process.Id))."
            Write-Host "Output: $Output"
            Write-Host "Log: $($script:LogFile)"
        }
    } else {
        # Foreground mode
        $PID | Set-Content -Path $script:PidFile -NoNewline

        try {
            if (-not $Quiet) {
                Write-Host "cli-screenshot started in foreground (PID: $PID)."
                Write-Host "Output: $Output"
                Write-Host "Press Ctrl+C to stop."
            }

            # Import Monitor module
            . (Join-Path $PSScriptRoot 'Monitor.ps1')

            Start-ClipboardMonitor -Interval $Interval -OutputDir $Output -LogFile $script:LogFile
        } finally {
            # Cleanup PID file on exit
            Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Stop-CliScreenshot {
    param(
        [switch]$Quiet
    )

    if (-not (Test-Path $script:PidFile)) {
        Set-RefCount 0
        if (-not $Quiet) {
            Write-Host "cli-screenshot is not running (no PID file found)."
        }
        return
    }

    $pidNumber = [int](Get-Content $script:PidFile -Raw).Trim()
    $proc = Test-CliScreenshotProcess -PidNumber $pidNumber

    if ($null -eq $proc) {
        Set-RefCount 0
        if (-not $Quiet) {
            Write-Host "cli-screenshot is not running (stale PID file cleaned up)."
        }
        return
    }

    $newCount = (Get-RefCount) - 1
    if ($newCount -gt 0) {
        Set-RefCount $newCount
        if (-not $Quiet) {
            Write-Host "cli-screenshot still in use by other sessions. RefCount: $newCount"
        }
        return
    }

    Stop-Process -Id $pidNumber -Force
    Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
    Set-RefCount 0

    if (-not $Quiet) {
        Write-Host "cli-screenshot stopped (PID: $pidNumber)."
    }
}

function Get-CliScreenshotStatus {
    if (-not (Test-Path $script:PidFile)) {
        Write-Host "Status:  STOPPED"
        return
    }

    $pidNumber = [int](Get-Content $script:PidFile -Raw).Trim()
    $proc = Test-CliScreenshotProcess -PidNumber $pidNumber

    if ($null -eq $proc) {
        Write-Host "Status:  STOPPED (stale PID file cleaned up)"
        return
    }

    # Gather stats
    $memoryMB = [Math]::Round($proc.WorkingSet64 / 1MB, 1)
    $uptime = (Get-Date) - $proc.StartTime
    $uptimeStr = '{0:hh\:mm\:ss}' -f $uptime

    # Count screenshots from log
    $screenshotCount = 0
    if (Test-Path $script:LogFile) {
        $screenshotCount = (Select-String -Path $script:LogFile -Pattern 'NEW screenshot saved' -SimpleMatch | Measure-Object).Count
    }

    Write-Host "Status:      RUNNING"
    Write-Host "PID:         $pidNumber"
    Write-Host "RefCount:    $(Get-RefCount)"
    Write-Host "Memory:      ${memoryMB} MB"
    Write-Host "Uptime:      $uptimeStr"
    Write-Host "Screenshots: $screenshotCount saved"
}
