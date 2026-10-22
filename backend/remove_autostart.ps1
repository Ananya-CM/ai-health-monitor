# Stops and removes the auto-start task.
$taskName = 'AIHealthMonitorBackend'
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Auto-start removed. If the backend window is still open, close it."
