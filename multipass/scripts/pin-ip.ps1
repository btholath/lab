# Run in Windows PowerShell. Adds a fixed secondary IP to one Multipass VM (DHCP is kept).
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\pin-ip.ps1 -Vm master -Ip 172.25.246.7
# Prefix defaults to 20 (the Default Switch /20 subnet).
param(
  [Parameter(Mandatory = $true)][string]$Vm,
  [Parameter(Mandatory = $true)][string]$Ip,
  [int]$Prefix = 20
)
$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "pin-ip.sh"

multipass transfer $script "${Vm}:/home/ubuntu/pin-ip.sh"
multipass exec $Vm -- sed -i 's/\r$//' /home/ubuntu/pin-ip.sh
multipass exec $Vm -- sudo bash /home/ubuntu/pin-ip.sh $Ip $Prefix
multipass list
