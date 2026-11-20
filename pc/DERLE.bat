@echo off
setlocal
cd /d "%~dp0"
title TR Altyazi - derleme
set "LOG=%~dp0derleme-kaydi.txt"
set "ROOT=%CD:\=/%"
set "PATH=%ProgramFiles%\Git\cmd;%USERPROFILE%\.cargo\bin;%PATH%"
set "CARGO_HOME=%USERPROFILE%\.cargo"
echo Derleme basladi %DATE% %TIME% > "%LOG%"
echo Derleniyor... (ilk seferde 15-25 dakika, sonrakiler birkac dakika). Ayrinti: derleme-kaydi.txt

set "VS="
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%i"
if not defined VS goto araclar_yok
rem Derleyicinin ortami. Ciktisi kayda yazilmaz: arka planda kalan yardimci programi kayit dosyasini kilitliyordu.
set VSCMD_SKIP_SENDTELEMETRY=1
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
echo derleyici ortami hazir >> "%LOG%"

rem --- ses modelinin kaynak kodu (sabit surum) ---
if exist zonos-src\servers\ggml\ggml\CMakeLists.txt goto kaynak_var
echo [1/4] Ses modelinin kaynak kodu indiriliyor...
if exist zonos-src rmdir /s /q zonos-src
git -c core.autocrlf=false clone https://github.com/Zyphra/ZONOS3-Mini zonos-src >> "%LOG%" 2>&1 || goto hata
git -C zonos-src -c core.autocrlf=false checkout a50e14117d99181ba7f28047b451ba03ba1a09a9 >> "%LOG%" 2>&1 || goto hata
git -C zonos-src -c core.autocrlf=false submodule update --init --depth 1 servers/ggml/ggml third_party/zyphra-textnorm >> "%LOG%" 2>&1 || goto hata
:kaynak_var

rem --- ekran karti (Vulkan) araclari ---
if exist vcpkg\installed\x64-windows\tools\shaderc\glslc.exe goto vulkan_var
echo [2/4] Ekran karti araclari hazirlaniyor (bir kereye mahsus, 5-15 dakika)...
if not exist vcpkg\bootstrap-vcpkg.bat git clone --depth 1 https://github.com/microsoft/vcpkg vcpkg >> "%LOG%" 2>&1 || goto hata
if not exist vcpkg\vcpkg.exe call vcpkg\bootstrap-vcpkg.bat -disableMetrics >> "%LOG%" 2>&1
vcpkg\vcpkg.exe install vulkan-headers vulkan-loader shaderc spirv-headers --triplet x64-windows >> "%LOG%" 2>&1 || goto hata
:vulkan_var

echo [3/4] Program derleniyor...
cmake -S Zonos -B build -A x64 "-DZONOS_SRC=%ROOT%/zonos-src" -DBUILD_SHARED_LIBS=OFF -DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON "-DCMAKE_TOOLCHAIN_FILE=%ROOT%/vcpkg/scripts/buildsystems/vcpkg.cmake" -DVCPKG_TARGET_TRIPLET=x64-windows "-DVulkan_GLSLC_EXECUTABLE=%ROOT%/vcpkg/installed/x64-windows/tools/shaderc/glslc.exe" >> "%LOG%" 2>&1 || goto hata
cmake --build build --config Release --target tr-altyazi-ses zb-pc -- /m /v:m >> "%LOG%" 2>&1 || goto hata

echo [4/4] Program yerine konuyor...
copy /y build\Release\zb-pc.exe ..\pc-olcum\zb-pc.exe >> "%LOG%" 2>&1
copy /y build\Release\tr-altyazi-ses.exe ..\pc-ses\tr-altyazi-ses.exe >> "%LOG%" 2>&1
if errorlevel 1 (
  echo PROGRAM ACIK: tr-altyazi-ses.exe kopyalanamadi, once sesli ceviri penceresini kapatin >> "%LOG%"
  echo Sesli ceviri penceresi acik oldugu icin yeni surum yerine konamadi. Pencereyi kapatip bu dosyayi yeniden calistirin.
  goto son
)
echo DERLEME TAMAM %DATE% %TIME% >> "%LOG%"
echo Derleme tamam.
goto son

:araclar_yok
echo HATA: derleme araclari kurulu degil, once KUR-ARACLAR.bat calistirin >> "%LOG%"
echo Derleme araclari kurulu degil: once KUR-ARACLAR.bat dosyasini calistirin.
goto son
:hata
echo DERLEME HATASI >> "%LOG%"
echo Derleme tamamlanamadi; ayrinti derleme-kaydi.txt dosyasinda.
:son
if "%1"=="" pause
