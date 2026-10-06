# Run in Windows PowerShell. Copies common.sh to every VM and runs it (steps 1-3).
$vms = "master","worker1","worker2"
foreach ($vm in $vms) {
  multipass transfer "$PSScriptRoot\common.sh" "${vm}:/home/ubuntu/common.sh"
  # PowerShell/Windows files may have CRLF line endings, which break bash scripts
  multipass exec $vm -- sed -i 's/\r$//' /home/ubuntu/common.sh
  multipass exec $vm -- bash /home/ubuntu/common.sh
}
