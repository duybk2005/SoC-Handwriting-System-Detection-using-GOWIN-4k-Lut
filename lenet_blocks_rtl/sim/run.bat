@echo off
rem Cach dung:  run tb_relu_rq      (hoac:  run tb_ref_model)
rem Goi run.ps1 ma khong bi Windows chan script.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
