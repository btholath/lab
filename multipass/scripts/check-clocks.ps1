<#
.SYNOPSIS
  Compares each Multipass VM's clock with the Windows clock, and can fix drift.

.DESCRIPTION
  After the laptop sleeps, the VMs can be paused and their clocks fall behind
  by minutes, each one correcting itself only at its own next time-service
  poll. This script measures every VM's offset from Windows. With -Fix it first
  restarts systemd-timesyncd on each VM, which in testing corrected a drifted
  clock within about 40 seconds.

  The offset is accurate to about half the round trip of the multipass call
  (typically 1 to 1.5 seconds in testing), so offsets under about 2 seconds
  are measurement noise.

.PARAMETER Fix
  Restart systemd-timesyncd on every VM, wait, then measure.

.PARAMETER Vms
  VM names. Default: master, worker1, worker2.

.PARAMETER ThresholdSeconds
  Offsets larger than this are marked OFF. Default: 2.

.PARAMETER WaitSeconds
  How long to wait after restarting the time service. Default: 40.

.EXAMPLE
  .\check-clocks.ps1
  Measure only.

.EXAMPLE
  .\check-clocks.ps1 -Fix
  Restart the time service everywhere, wait, then measure.

.NOTES
  If PowerShell refuses to run the script, start it with:
    powershell -ExecutionPolicy Bypass -File .\check-clocks.ps1 -Fix
#>
param(
    [switch]$Fix,
    [string[]]$Vms = @("master", "worker1", "worker2"),
    [double]$ThresholdSeconds = 2.0,
    [int]$WaitSeconds = 40
)

function Get-VmClockOffset {
    param([string]$Vm)
    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $r = multipass exec $Vm -- date -u +%s.%N
    $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $mid = ($t0 + $t1) / 2000.0
    [pscustomobject]@{
        VM            = $Vm
        OffsetSeconds = [math]::Round(([double]$r - $mid), 1)
        RoundTripMs   = ($t1 - $t0)
    }
}

if ($Fix) {
    foreach ($vm in $Vms) {
        multipass exec $vm -- sudo systemctl restart systemd-timesyncd | Out-Null
    }
    Write-Host ("Restarted systemd-timesyncd on {0}. Waiting {1} seconds..." -f ($Vms -join ", "), $WaitSeconds)
    Start-Sleep -Seconds $WaitSeconds
}

Write-Host ("Windows UTC: " + (Get-Date).ToUniversalTime().ToString("HH:mm:ss"))

$bad = 0
$rows = foreach ($vm in $Vms) {
    $o = Get-VmClockOffset -Vm $vm
    $status = "ok"
    if ([math]::Abs($o.OffsetSeconds) -gt $ThresholdSeconds) {
        $status = "OFF"
        $bad = $bad + 1
    }
    [pscustomobject]@{
        VM            = $o.VM
        OffsetSeconds = $o.OffsetSeconds
        RoundTripMs   = $o.RoundTripMs
        Status        = $status
    }
}

$rows | Format-Table -AutoSize

if ($bad -gt 0) {
    if ($Fix) {
        Write-Warning "Some VMs are still off. Wait another minute and run again, or paste this output for diagnosis."
    }
    else {
        Write-Warning "Some VMs are off. Run again with -Fix to restart the time service."
    }
}
else {
    Write-Host "All clocks agree with Windows within the threshold."
}
