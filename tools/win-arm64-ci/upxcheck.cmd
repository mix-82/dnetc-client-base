@echo off
rem Check the UPX version gate of the ARM64 target in makefile.vc.
rem   upxcheck.cmd <dir of UPX 5.3.0 or newer> <dir of an older UPX> <log dir>
setlocal
set NEW=%1
set OLD=%2
set LOGDIR=%3
if not exist %LOGDIR% mkdir %LOGDIR%
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set "VSDIR=%%i"
call "%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat" arm64 >nul
if errorlevel 1 exit /b 1
set FAIL=0

echo --- plat\win\upxver.cmd
cmd /c plat\win\upxver.cmd "%NEW%"
set VNEW=%ERRORLEVEL%
cmd /c plat\win\upxver.cmd "%OLD%"
set VOLD=%ERRORLEVEL%
cmd /c plat\win\upxver.cmd "C:\no-such-dir"
set VNONE=%ERRORLEVEL%
echo new UPX: %VNEW%   old UPX: %VOLD%   no UPX: %VNONE%
if not "%VNEW%"=="503" set FAIL=1
if not "%VOLD%"=="500" set FAIL=1
if not "%VNONE%"=="0" set FAIL=1

echo --- dry run, ARM64, old UPX: must not compress
nmake -nologo -n -a -f makefile.vc PROCESSOR_ARCHITECTURE=ARM64 UPX=%OLD% > %LOGDIR%\dry-arm64-old.txt 2>&1
findstr /c:"not compressing" %LOGDIR%\dry-arm64-old.txt
findstr /i /c:"upx.exe" %LOGDIR%\dry-arm64-old.txt && set FAIL=1

echo --- dry run, ARM64, new UPX: must compress dnetc.exe and dnetc.scr
nmake -nologo -n -a -f makefile.vc PROCESSOR_ARCHITECTURE=ARM64 UPX=%NEW% > %LOGDIR%\dry-arm64-new.txt 2>&1
findstr /i /c:"upx.exe" %LOGDIR%\dry-arm64-new.txt || set FAIL=1

echo --- dry run, AMD64, old UPX: unchanged, compresses as before
nmake -nologo -n -a -f makefile.vc PROCESSOR_ARCHITECTURE=AMD64 UPX=%OLD% > %LOGDIR%\dry-amd64-old.txt 2>&1
findstr /i /c:"upx.exe" %LOGDIR%\dry-amd64-old.txt || set FAIL=1

echo --- upxcheck status: %FAIL%
exit /b %FAIL%
