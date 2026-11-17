@echo off
rem Build the Windows ARM64 client with makefile.vc.
rem   build.cmd <vcvarsall arch: arm64 (native) or amd64_arm64 (cross)> <log dir>
setlocal
set VCARCH=%1
set LOGDIR=%2
if not exist %LOGDIR% mkdir %LOGDIR%
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set "VSDIR=%%i"
echo VSDIR=%VSDIR%
call "%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat" %VCARCH%
if errorlevel 1 exit /b 1

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
nmake -nologo -f makefile.vc /K PROCESSOR_ARCHITECTURE=ARM64 > %LOGDIR%\build.log 2>&1
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
exit /b %RC%
