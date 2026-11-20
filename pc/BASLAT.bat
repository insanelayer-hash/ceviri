@echo off
setlocal
cd /d "%~dp0"
title TR Altyazi - sesli ceviri
rem Model dosyalari olcum klasorunde zaten varsa oradan alinir (yeniden indirilmez).
if not exist modeller if exist ..\pc-olcum\modeller move ..\pc-olcum\modeller modeller >nul
if not exist modeller mkdir modeller
call :indir backbone-ptq-edit.gguf 663491840
call :indir zac-keep2.gguf 452325440
call :indir spk-encoder.gguf 45385728
tr-altyazi-ses.exe modeller sesler zonos3_mini_heads_tr.json ayar.txt %1 2> gunluk.txt
echo.
echo Program kapandi (kod %ERRORLEVEL%). Ayrinti: gunluk.txt
pause
exit /b

:indir
set F=modeller\%1
if exist "%F%" for %%A in ("%F%") do if "%%~zA"=="%2" goto :eof
if exist "%F%" del "%F%"
echo Indiriliyor: %1
curl.exe -L --fail --retry 5 -o "%F%" https://huggingface.co/Zyphra/ZONOS3-Mini/resolve/main/gguf/%1
if exist "%F%" for %%A in ("%F%") do if "%%~zA"=="%2" goto :eof
echo HATA: %1 indirilemedi. Internet baglantisini kontrol edip yeniden deneyin.
pause
exit 1
