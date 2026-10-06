# Run in Windows PowerShell. Creates the three Multipass VMs.
$vms = "master","worker1","worker2"
foreach ($vm in $vms) {
  multipass launch 24.04 --name $vm --cpus 2 --memory 2G --disk 20G
}
multipass list
