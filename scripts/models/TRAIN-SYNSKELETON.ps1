param([Parameter(Mandatory=$true)][string]$Dataset,[string]$Out="SynSkeleton.ssm",[int]$Runs=8)
$Root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
python (Join-Path $Root "tools\synskeleton\train.py") $Dataset --out $Out --runs $Runs
exit $LASTEXITCODE
