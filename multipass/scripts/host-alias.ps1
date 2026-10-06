# Run in an ADMINISTRATOR Windows PowerShell after a Windows reboot, ONLY if the Hyper-V
# "Default Switch" came back with a different subnet and your VMs became unreachable.
#
# It adds the OLD gateway address to the host's Default Switch adapter, so Windows can
# talk to the VMs' pinned addresses again (VM-to-VM and host-to-VM traffic).
# Internet access from the VMs will NOT work in this state (no NAT for the old subnet),
# so pulls of new images fail until you fix the subnet problem properly.
# The alias disappears at the next reboot, so re-run this script each time if needed.
#Requires -RunAsAdministrator
param(
  [string]$Address = "172.25.240.1",
  [int]$Prefix = 20,
  [string]$Alias = "vEthernet (Default Switch)"
)
$ErrorActionPreference = "Stop"

$current = Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4
Write-Host "Current addresses on '$Alias':"
$current | Format-Table IPAddress, PrefixLength -AutoSize

if ($current.IPAddress -contains $Address) {
  Write-Host "The adapter already has $Address. Nothing to do."
  exit 0
}
New-NetIPAddress -InterfaceAlias $Alias -IPAddress $Address -PrefixLength $Prefix | Out-Null
Write-Host "Added $Address/$Prefix. Now run: multipass list"
