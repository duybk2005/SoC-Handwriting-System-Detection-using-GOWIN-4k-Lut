@echo off
rem Cach dung (trong folder syn):
rem    run_syn syn_wrap_gemm      (do tai nguyen gemm_engine, cau hinh C1)
rem    run_syn syn_wrap_block3    (do tai nguyen block3_top)
rem Mat khoang 1 phut. Ket qua: syn\<ten>\impl\pnr\<ten>.rpt.html (mo bang trinh duyet)
"C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe" "%~dp0run_syn.tcl" %1
echo.
echo ===== Bao cao tai nguyen: %~dp0%1\impl\pnr\%1.rpt.html
echo ===== Bao cao timing   : %~dp0%1\impl\pnr\%1_tr_content.html  (tim "Max Frequency Summary")
