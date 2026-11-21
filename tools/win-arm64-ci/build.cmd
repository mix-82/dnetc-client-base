@echo off
rem Build a Windows client with makefile.vc in the current directory.
rem   build.cmd <vcvarsall arch> <makefile.vc PROCESSOR_ARCHITECTURE> <log dir>
rem e.g. arm64 ARM64 (native ARM64), amd64_arm64 ARM64 (cross), x64 AMD64, x86 x86
setlocal
set VCARCH=%1
set MAKEARCH=%2
set LOGDIR=%3
if not exist %LOGDIR% mkdir %LOGDIR%
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set "VSDIR=%%i"
echo VSDIR=%VSDIR%
call "%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat" %VCARCH%
if errorlevel 1 exit /b 1

if not "%MAKEARCH%"=="ARM64" goto haveclang
where clang.exe >nul 2>&1 && goto haveclang
if exist "%VSDIR%\VC\Tools\Llvm\ARM64\bin\clang.exe" set "PATH=%VSDIR%\VC\Tools\Llvm\ARM64\bin;%PATH%"
where clang.exe >nul 2>&1 && goto haveclang
if exist "%VSDIR%\VC\Tools\Llvm\x64\bin\clang.exe" set "PATH=%VSDIR%\VC\Tools\Llvm\x64\bin;%PATH%"
where clang.exe >nul 2>&1 && goto haveclang
if exist "%ProgramFiles%\LLVM\bin\clang.exe" set "PATH=%ProgramFiles%\LLVM\bin;%PATH%"
where clang.exe >nul 2>&1 && goto haveclang
echo ERROR: clang not found
exit /b 1

:haveclang
echo --- tools
where clang.exe clang-cl.exe cl.exe link.exe nmake.exe rc.exe
clang --version
cl 2>&1 | findstr /i version
echo --- build
if not exist output mkdir output
nmake -nologo -f makefile.vc /K PROCESSOR_ARCHITECTURE=%MAKEARCH% > %LOGDIR%\build.log 2>&1
set RC=%ERRORLEVEL%
type %LOGDIR%\build.log
echo nmake exit code %RC%
for %%f in (dnetc.exe dnetc.com dnetc.scr) do (
  if exist %%f (
    echo --- %%f
    dumpbin /nologo /headers %%f | findstr /i /c:"machine" /c:"subsystem"
    dumpbin /nologo /dependents %%f | findstr /i ".dll"
  ) else (
    echo --- %%f: NOT BUILT
  )
)
if not "%MAKEARCH%"=="ARM64" exit /b %RC%
echo --- exe compressor check: a dry run with UPX set to a directory without upx.exe must not call upx
nmake -nologo -n -a -f makefile.vc PROCESSOR_ARCHITECTURE=ARM64 UPX=C:\upx > %LOGDIR%\dryrun-upx.txt 2>&1
echo dry run: nmake exit code %ERRORLEVEL%
findstr /i /c:"link " %LOGDIR%\dryrun-upx.txt | find /c /v ""
findstr /i /c:"upx.exe" %LOGDIR%\dryrun-upx.txt
if not errorlevel 1 (
  echo FAIL: the ARM64 build would run the exe compressor
  exit /b 1
)
echo ok: no exe compressor in the ARM64 build
exit /b %RC%
