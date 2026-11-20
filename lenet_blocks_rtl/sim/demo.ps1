# Menu demo - goi tu DEMO.bat (double-click) o thu muc goc
#   -Choice <so> : chay 1 lua chon roi thoat (khong hien menu)
param([string]$Choice = "")
$ErrorActionPreference = "Continue"
$ms = "C:\altera\13.0sp1\modelsim_ase\win32aloem"
Set-Location $PSScriptRoot

function Compile($top) {
    if (-not (Test-Path work)) { & "$ms\vlib.exe" work | Out-Null }
    $rtl = @(Get-ChildItem ..\rtl -Filter *.v | ForEach-Object { $_.FullName })
    & "$ms\vlog.exe" -work work $rtl "..\tb\$top.v" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function RunTest($top, $title) {
    Write-Host ""
    Write-Host "---- $title  ($top) ----" -ForegroundColor Cyan
    if (-not (Compile $top)) { Write-Host "  LOI COMPILE" -ForegroundColor Red; return }
    $out = & "$ms\vsim.exe" -c $top -do "run -all; quit -f"
    foreach ($line in $out) {
        $l = "$line"
        if ($l -match "PASS")                 { Write-Host ("  " + $l.TrimStart('#',' ')) -ForegroundColor Green }
        elseif ($l -match "FAIL")             { Write-Host ("  " + $l.TrimStart('#',' ')) -ForegroundColor Red }
        elseif ($l -match "mismatch|logit\[|So clock|So lan|Argmax|H3 \(") { Write-Host ("  " + $l.TrimStart('#',' ')) }
    }
}

function Wave($top) {
    if (-not (Compile $top)) { Write-Host "LOI COMPILE" -ForegroundColor Red; return }
    Write-Host "Dang mo ModelSim... (doi vai giay; dong cua so ModelSim de quay lai menu)"
    & "$ms\vsim.exe" $top -do "add wave -noupdate /$top/clk /$top/start /$top/done; add wave -noupdate -group DUT /$top/dut/*; run -all; wave zoom full"
}

while ($true) {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  DEMO RTL LeNet-5 - 3 khoi (Block1 C1, Block2 C3, Block3 C5-F6-Out)" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  1. Chay TAT CA test (khoang 1 phut) -> thay PASS"
    Write-Host "  2. Chi chay Block 1"
    Write-Host "  3. Chi chay Block 2"
    Write-Host "  4. Chi chay Block 3 (in 10 logits + chu so du doan)"
    Write-Host "  5. Mo dang song (waveform) Block 3 trong ModelSim"
    Write-Host "  6. Mo dang song (waveform) Block 1 trong ModelSim"
    Write-Host "  0. Thoat"
    if ($Choice -ne "") { $c = $Choice } else { $c = Read-Host "Chon so roi Enter" }
    switch ($c) {
        "1" {
            RunTest "tb_ref_model" "Buoc 0: mo hinh tham chieu vs golden"
            RunTest "tb_relu_rq"   "Buoc 1: khoi ReLU + Requant"
            RunTest "tb_mac"       "Buoc 2: khoi MAC"
            RunTest "tb_block1"    "KHOI 1: C1  (6x784)"
            RunTest "tb_block2"    "KHOI 2: C3  (16x100)"
            RunTest "tb_block3"    "KHOI 3: C5 -> F6 -> Output"
        }
        "2" { RunTest "tb_block1" "KHOI 1: C1  (6x784)" }
        "3" { RunTest "tb_block2" "KHOI 2: C3  (16x100)" }
        "4" { RunTest "tb_block3" "KHOI 3: C5 -> F6 -> Output" }
        "5" { Wave "tb_block3" }
        "6" { Wave "tb_block1" }
        "0" { exit }
        default { Write-Host "Chon 0..6" }
    }
    if ($Choice -ne "") { exit }
}
