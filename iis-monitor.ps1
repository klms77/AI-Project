<#
.SYNOPSIS
Monitors IIS application pools and restarts stopped pools.

.DESCRIPTION
Checks all IIS application pool states every 60 seconds. If any pool is Stopped,
captures Windows Event Log errors from the last 10 minutes and restarts the pool.
Logs actions to C:\Logs\iis-monitor.log with timestamps.

.PARAMETER DryRun
If provided, shows actions without performing restarts or state changes.

.NOTES
Environment: Windows Server 2022, IIS installed, WebAdministration module available
#>

function Show-Usage {
    Write-Output "Usage: .\iis-monitor.ps1 [-DryRun|--dryrun]"
    Write-Output "  -DryRun or --dryrun : Show actions without performing restarts"
    Write-Output "  -Help or --help     : Show this usage message"
}

$DryRun = $false
foreach ($arg in $args) {
    switch ($arg.ToLower()) {
        '--dryrun' { $DryRun = $true; continue }
        '-dryrun' { $DryRun = $true; continue }
        '--help' { Show-Usage; exit 0 }
        '-help' { Show-Usage; exit 0 }
        default {
            Write-Error "Unknown argument: $arg"
            Show-Usage
            exit 1
        }
    }
}

Set-StrictMode -Version Latest

$IntervalSeconds = 60
$LogDir = 'C:\Logs'
$LogFile = Join-Path $LogDir 'iis-monitor.log'
$StateFile = 'C:\ProgramData\iis-monitor-state.json'
$PidFile = 'C:\ProgramData\iis-monitor.pid'
$Running = $true

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "$ts $Message"
    try {
        if (-not (Test-Path -Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {
        Write-Error "Failed to write log: $_"
    }
}

function Register-SingleInstance {
    try {
        if (Test-Path -Path $PidFile) {
            $existing = Get-Content -Path $PidFile -ErrorAction SilentlyContinue
            if ($existing) {
                try {
                    $proc = Get-Process -Id [int]$existing -ErrorAction SilentlyContinue
                    if ($proc) {
                        Write-Log "Monitor already running with PID $existing"
                        Write-Verbose "Monitor already running with PID $existing"
                        Exit 0
                    }
                } catch { Write-Log "Error checking existing PID: $_" }
            }
            Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
        }
        $procId = $PID
        Set-Content -Path $PidFile -Value $procId -Encoding ASCII -Force
    } catch {
        Write-Log "Register-SingleInstance failed: $_"
    }
}

function Save-OriginalState {
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $states = @{}
        Get-ChildItem IIS:\AppPools | ForEach-Object { $states[$_.Name] = $_.State }
        $states | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8 -Force
        Write-Log "Saved original app pool states to $StateFile"
    } catch {
        Write-Log "Failed to save original state: $_"
        throw
    }
}

function Get-RecentEvent {
    param([string]$PoolName)
    try {
        $start = (Get-Date).AddMinutes(-10)
        $filter = @{LogName='Application'; Level=2; StartTime=$start}
        $events = Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue | Where-Object {
            ($_ | Select-Object -ExpandProperty Message) -match $PoolName -or $_.ProviderName -match 'IIS|W3SVC|WAS'
        }
        if ($events) {
            Write-Log "Captured events for pool ${PoolName}:"
            foreach ($e in $events | Select-Object -First 50) {
                $msg = "EventId=$($e.Id) Provider=$($e.ProviderName) Time=$($e.TimeCreated) $($e.Message -replace "\r|\n", ' | ' )"
                Write-Log $msg
            }
        } else {
            Write-Log "No recent error events for pool $PoolName"
        }
    } catch {
        Write-Log "Failed to get recent events for ${PoolName}: ${_}"
    }
}

function Restart-AppPool {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$PoolName)
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $appPool = Get-Item "IIS:\AppPools\$PoolName" -ErrorAction Stop
        $current = $appPool.State
        Write-Log "Current state of '$PoolName' is $current"
        if ($current -eq 'Started') {
            Write-Log "Pool '$PoolName' already running; skipping restart"
            return
        }

        Get-RecentEvent -PoolName $PoolName

        if ($DryRun) {
            Write-Log "[DRY-RUN] Would start app pool: $PoolName"
            Write-Verbose "[DRY-RUN] Would start app pool: $PoolName"
            return
        }

        Write-Log "Starting app pool: $PoolName"
        if ($PSCmdlet.ShouldProcess("AppPool/$PoolName", 'Start')) {
            try {
                Start-WebAppPool -Name $PoolName -ErrorAction Stop
                Write-Log "Successfully started app pool: $PoolName"
            } catch {
                Write-Log "Error starting app pool ${PoolName}: ${_}"
            }
        } else {
            Write-Log "ShouldProcess prevented starting app pool: $PoolName"
        }
    } catch {
        Write-Log "Restart-AppPool encountered an error for ${PoolName}: ${_}"
    }
}

function Rollback {
    param()
    Write-Log "Rollback requested: stopping monitor and restoring original pool states"
    $script:Running = $false
    if ($DryRun) {
        Write-Log "[DRY-RUN] Would restore original pool states from $StateFile"
        Write-Verbose "[DRY-RUN] Rollback would restore original pool states"
        return
    }
    try {
        if (-not (Test-Path -Path $StateFile)) {
            Write-Log "No state file found at $StateFile; nothing to rollback"
            return
        }
        $orig = Get-Content -Path $StateFile -Raw | ConvertFrom-Json
        foreach ($kv in $orig.PSObject.Properties) {
            $name = $kv.Name
            $desired = $kv.Value
            try {
                $item = Get-Item "IIS:\AppPools\$name" -ErrorAction SilentlyContinue
                if (-not $item) { Write-Log "App pool $name no longer exists; skipping"; continue }
                $cur = $item.State
                if ($desired -eq 'Started' -and $cur -ne 'Started') {
                    Write-Log "Restoring pool $name to Started"
                    if (-not $DryRun) { Start-WebAppPool -Name $name -ErrorAction SilentlyContinue }
                } elseif ($desired -eq 'Stopped' -and $cur -ne 'Stopped') {
                    Write-Log "Restoring pool $name to Stopped"
                    if (-not $DryRun) { Stop-WebAppPool -Name $name -ErrorAction SilentlyContinue }
                }
            } catch {
                Write-Log "Failed to restore pool ${name}: ${_}"
            }
        }
        Write-Log "Rollback completed"
    } catch {
        Write-Log "Rollback failed: ${_}"
    }
}

function Cleanup {
    try {
        if (Test-Path -Path $PidFile) { Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue }
    } catch {
        Write-Log "Cleanup error: $_"
    }
}

# Exit hooks
try {
    $null = Register-EngineEvent PowerShell.Exiting -Action { Write-Log 'Engine exiting'; $script:Running = $false; Rollback }
} catch {
    Write-Log "Failed to register engine exit event: $_"
}
trap {
    Write-Log 'Ctrl+C pressed'
    $script:Running = $false
    Rollback
}

# Main
Register-SingleInstance
Save-OriginalState

Write-Log "Starting IIS monitor. DryRun=$DryRun Interval=${IntervalSeconds}s"

try {
    while ($Running) {
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $pools = Get-ChildItem IIS:\AppPools -ErrorAction Stop
            foreach ($p in $pools) {
                try {
                    $name = $p.Name
                    $state = $p.State
                    if ($state -eq 'Stopped') {
                        Write-Log "Detected stopped pool: $name"
                        Restart-AppPool -PoolName $name
                    }
                } catch {
                    Write-Log "Error checking pool $($p.Name): $_"
                }
            }
        } catch {
            Write-Log "IIS monitoring loop error: $_"
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    Cleanup
    Write-Log "IIS monitor exiting"
}
