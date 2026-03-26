param(
    [Parameter(Position=0)]
    [ValidateSet('start','stop','status','version')]
    [string]$Command = 'start',

    [Alias('d')]
    [switch]$Daemon,

    [Alias('i')]
    [int]$Interval = 250,

    [Alias('o')]
    [string]$Output = (Join-Path $env:USERPROFILE 'Pictures\Screenshots'),

    [Alias('q')]
    [switch]$Quiet
)

# STA check: if running in MTA, restart self with -STA
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    $allArgs = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path) + $args
    & $exe @allArgs
    exit $LASTEXITCODE
}

# Import modules
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Daemon.ps1')

# Command dispatch
switch ($Command) {
    'start'   { Start-CliScreenshot -Daemon:$Daemon -Interval $Interval -Output $Output -Quiet:$Quiet }
    'stop'    { Stop-CliScreenshot -Quiet:$Quiet }
    'status'  { Get-CliScreenshotStatus }
    'version' { Write-Host "cli-screenshot v1.0.0" }
}
