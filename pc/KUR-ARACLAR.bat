@echo off
setlocal
cd /d "%~dp0"
title TR Altyazi - derleme araclarinin kurulumu
set "LOG=%~dp0kurulum-gunluk.txt"
echo TR Altyazi programini bu bilgisayarda derleyebilmek icin su araclar kurulacak:
echo.
echo   1. Git                                  (kaynak kodu indirmek icin)
echo   2. Visual Studio 2022 Derleme Araclari  (Microsoft'un C++ derleyicisi, yaklasik 7 GB)
echo   3. Rust                                 (rustup ile)
echo.
echo Hepsi resmi kaynaklardan, Windows'un kendi paket yoneticisi (winget) ile indirilir.
echo Devam etmeniz, bu yazilimlarin lisans kosullarini kabul ettiginiz anlamina gelir
echo (Microsoft Visual Studio Build Tools lisansi dahil).
echo Windows bir kac kez yonetici izni soracak. Toplam 8-10 GB, 15-30 dakika.
echo.
echo Devam etmek icin bir tusa basin; vazgecmek icin bu pencereyi kapatin.
pause >nul
echo Kurulum basladi %DATE% %TIME% > "%LOG%"

echo.
echo [1/3] Git...
winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
echo git kurulum kodu %ERRORLEVEL% >> "%LOG%"

echo.
echo [2/3] Visual Studio Derleme Araclari (uzun surer, ayri bir pencerede ilerleme gosterir)...
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget --accept-package-agreements --accept-source-agreements --override "--passive --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
echo visual studio kurulum kodu %ERRORLEVEL% >> "%LOG%"

echo.
echo [3/3] Rust...
winget install --id Rustlang.Rustup -e --source winget --accept-package-agreements --accept-source-agreements
echo rust kurulum kodu %ERRORLEVEL% >> "%LOG%"
set "PATH=%ProgramFiles%\Git\cmd;%USERPROFILE%\.cargo\bin;%PATH%"
rustup default stable-x86_64-pc-windows-msvc >> "%LOG%" 2>&1

echo. >> "%LOG%"
echo ---- kontrol ---- >> "%LOG%"
set OK=1
git --version >> "%LOG%" 2>&1 || (echo EKSIK: git >> "%LOG%" & set OK=0)
rustc --version >> "%LOG%" 2>&1 || (echo EKSIK: rust >> "%LOG%" & set OK=0)
cargo --version >> "%LOG%" 2>&1 || (echo EKSIK: cargo >> "%LOG%" & set OK=0)
set "VS="
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%i"
if defined VS echo visual studio: "%VS%" >> "%LOG%"
if not defined VS echo EKSIK: visual studio C++ araclari >> "%LOG%"
if not defined VS set OK=0
if "%OK%"=="1" (echo ARACLAR HAZIR >> "%LOG%") else (echo KURULUM EKSIK >> "%LOG%")
echo.
if "%OK%"=="1" (echo Araclar hazir.) else (echo Bazi araclar kurulamadi; ayrinti kurulum-gunluk.txt dosyasinda.)
pause
