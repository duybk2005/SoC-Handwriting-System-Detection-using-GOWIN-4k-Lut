# Chay 1 testbench bang ModelSim (console, khong GUI)
#   cd lenet_blocks_rtl\sim
#   .\run.ps1 tb_relu_rq
#   .\run.ps1 tb_ref_model
# Script compile TAT CA file trong ..\rtl va file ..\tb\<ten>.v, roi chay <ten>.
param([Parameter(Mandatory=$true)][string]$Top, [switch]$Gui)

$ms = "C:\altera\13.0sp1\modelsim_ase\win32aloem"
Set-Location $PSScriptRoot
if (-not (Test-Path work)) { & "$ms\vlib.exe" work | Out-Null }

$rtl = @(Get-ChildItem ..\rtl -Filter *.v -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
& "$ms\vlog.exe" -work work $rtl "..\tb\$Top.v"
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED" -ForegroundColor Red; exit 1 }

if ($Gui) { & "$ms\vsim.exe" $Top -do "add wave -r /*; run -all" }
else      { & "$ms\vsim.exe" -c $Top -do "run -all; quit -f" }
