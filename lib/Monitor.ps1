function Write-Log {
    param(
        [string]$LogFile,
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message"

    # Console output
    Write-Host $line

    if (-not $LogFile) { return }

    try {
        # Log rotation: truncate if > 5MB, keep last ~2.5MB
        if (Test-Path $LogFile) {
            $fileInfo = Get-Item $LogFile
            if ($fileInfo.Length -gt 5MB) {
                $content = [System.IO.File]::ReadAllText($LogFile)
                $keepFrom = [Math]::Max(0, $content.Length - 2500000)
                $truncated = $content.Substring($keepFrom)
                # Find first newline to avoid partial line
                $firstNewline = $truncated.IndexOf("`n")
                if ($firstNewline -gt 0) {
                    $truncated = $truncated.Substring($firstNewline + 1)
                }
                [System.IO.File]::WriteAllText($LogFile, $truncated)
            }
        }

        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {
        # Silently ignore log write failures
    }
}

function Invoke-ClipboardAction {
    param(
        [scriptblock]$Action,
        [int]$MaxRetries = 5,
        [int]$RetryDelayMs = 50
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return (& $Action)
        } catch [System.Runtime.InteropServices.ExternalException] {
            if ($attempt -eq $MaxRetries) { throw }
            Start-Sleep -Milliseconds $RetryDelayMs
        }
    }
}

function Start-ClipboardMonitor {
    param(
        [int]$Interval = 250,
        [string]$OutputDir,
        [string]$LogFile
    )

    # Load required assemblies
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Ensure output directory exists
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    Write-Log $LogFile "Monitor started. Output: $OutputDir, Interval: ${Interval}ms"

    $lastHash = ""

    while ($true) {
        Start-Sleep -Milliseconds $Interval

        try {
            # Maintain STA message pump
            [System.Windows.Forms.Application]::DoEvents()

            # Check if clipboard contains an image
            $hasImage = Invoke-ClipboardAction { [System.Windows.Forms.Clipboard]::ContainsImage() }
            if (-not $hasImage) { continue }

            # Layer 1: Format fingerprint detection
            # New screenshot = has Image but NOT the tri-format combo (Text + FileDropList) we set
            $hasText = Invoke-ClipboardAction { [System.Windows.Forms.Clipboard]::ContainsText() }
            $hasFiles = Invoke-ClipboardAction { [System.Windows.Forms.Clipboard]::ContainsFileDropList() }

            if ($hasText -and $hasFiles) {
                # This is likely our own tri-format output, skip
                continue
            }

            # Get the image from clipboard
            $img = $null
            try {
                $img = Invoke-ClipboardAction { [System.Windows.Forms.Clipboard]::GetImage() }
                if ($null -eq $img) { continue }

                # Convert to PNG bytes for hashing
                $ms = New-Object System.IO.MemoryStream
                try {
                    $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                    $bytes = $ms.ToArray()
                } finally {
                    $ms.Dispose()
                }

                # Compute SHA256 hash
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $hashBytes = $sha.ComputeHash($bytes)
                    $hash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
                } finally {
                    $sha.Dispose()
                }

                # Layer 2: Hash dedup - same hash means same image, skip
                if ($hash -eq $lastHash) { continue }

                $filePath = Join-Path $OutputDir "$hash.png"

                # Write file only if it doesn't exist (disk dedup)
                if (-not (Test-Path $filePath)) {
                    [System.IO.File]::WriteAllBytes($filePath, $bytes)
                    Write-Log $LogFile "NEW screenshot saved: $filePath"
                } else {
                    Write-Log $LogFile "Duplicate detected, updating clipboard: $filePath"
                }

                # Always update clipboard with tri-format (user may have copied something else in between)
                $data = New-Object System.Windows.Forms.DataObject
                $data.SetImage($img)
                $data.SetText($filePath)
                $files = New-Object System.Collections.Specialized.StringCollection
                $files.Add($filePath) | Out-Null
                $data.SetFileDropList($files)
                Invoke-ClipboardAction { [System.Windows.Forms.Clipboard]::SetDataObject($data, $true) }

                Write-Log $LogFile "Clipboard updated: $filePath"

                # Update last hash
                $lastHash = $hash

            } catch {
                Write-Log $LogFile "ERROR: $($_.Exception.Message)"
            } finally {
                if ($null -ne $img) { $img.Dispose() }
            }

        } catch {
            Write-Log $LogFile "ERROR (outer): $($_.Exception.Message)"
        }
    }
}
