@echo off
setlocal
cd /d "%~dp0"
title TR Altyazi - bilgisayar olcumu
set MODE=%1
if exist sonuc.txt del sonuc.txt
if not exist modeller mkdir modeller
echo TR Altyazi - bilgisayar olcumu
echo.
echo Ses modeli dosyalari kontrol ediliyor (ilk seferde 1,1 GB indirilir)...
call :indir backbone-ptq-edit.gguf 663491840
call :indir zac-keep2.gguf 452325440
call :indir spk-encoder.gguf 45385728
echo.
echo Olcum basliyor (1-3 dakika surer). Bu pencereyi kapatmayin.
echo.
zb-pc.exe modeller Minjun.npy zonos3_mini_heads_tr.json sonuc.txt %MODE% 2> gunluk.txt
set KOD=%ERRORLEVEL%
echo.>> sonuc.txt
findstr /c:"backend" /c:"spk: loaded" gunluk.txt >> sonuc.txt
if not "%KOD%"=="0" echo Olcum tamamlanamadi (kod %KOD%).>> sonuc.txt
echo.
if "%KOD%"=="0" (echo Bitti. Sonuclar sonuc.txt dosyasina yazildi.) else (echo Olcum tamamlanamadi, kod %KOD%. Ayrinti gunluk.txt dosyasinda.)
if "%MODE%"=="" pause
exit /b %KOD%

:indir
set F=modeller\%1
if exist "%F%" for %%A in ("%F%") do if "%%~zA"=="%2" goto :eof
if exist "%F%" del "%F%"
echo Indiriliyor: %1
curl.exe -L --fail --retry 5 -o "%F%" https://huggingface.co/Zyphra/ZONOS3-Mini/resolve/main/gguf/%1
if exist "%F%" for %%A in ("%F%") do if "%%~zA"=="%2" goto :eof
echo HATA: %1 indirilemedi. Internet baglantisini kontrol edip yeniden deneyin.
echo HATA: %1 indirilemedi>> sonuc.txt
if "%MODE%"=="" pause
exit 1
