# Run in Windows PowerShell. Copies a YAML file into the master and applies it.
# Usage: .\apply-manifest.ps1 ..\manifests\deployment.yaml
# (Piping YAML straight into "multipass exec ... kubectl apply -f -" can hang on Windows.)
param([Parameter(Mandatory = $true)][string]$File)
$name = Split-Path $File -Leaf
multipass transfer $File "master:/home/ubuntu/$name"
multipass exec master -- kubectl apply -f "/home/ubuntu/$name"
