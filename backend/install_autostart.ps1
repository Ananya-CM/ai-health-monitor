# Registers a Windows scheduled task that starts the backend when you sign in,
# restarts it if it stops, and keeps the laptop awake while plugged in.
$ErrorActionPreference = 'Stop'

$backendFolder = $PSScriptRoot
$runner        = Join-Path $backendFolder 'run_forever.bat'
$taskName      = 'AIHealthMonitorBackend'

$action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$runner`"" -WorkingDirectory $backendFolder
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null

# While plugged in, never sleep or hibernate (battery settings are left alone).
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

Start-ScheduledTask -TaskName $taskName
Write-Host "Done. The backend starts at every sign-in and restarts if it stops."
Write-Host "Log file: $(Join-Path $backendFolder 'logs\backend.log')"
