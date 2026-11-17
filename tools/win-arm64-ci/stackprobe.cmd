@echo off
rem Build and run the stack-growth test (stackprobe.c) against the core
rem objects of the finished ARM64 build in output\.
setlocal
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set "VSDIR=%%i"
call "%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat" arm64 >nul
if errorlevel 1 exit /b 1
where clang.exe >nul 2>&1 || set "PATH=%VSDIR%\VC\Tools\Llvm\ARM64\bin;%PATH%"
clang --target=aarch64-pc-windows-msvc -c -o output\badprobe.obj tools\win-arm64-ci\badprobe.S || exit /b 1
cl -nologo -O1 -MT -Feoutput\stackprobe.exe -Fooutput\ tools\win-arm64-ci\stackprobe.c output\r72-neon-mix.obj output\r72-neon-hyb.obj output\badprobe.obj || exit /b 1
echo --- stack layout
output\stackprobe.exe info
echo --- test
output\stackprobe.exe
set RC=%ERRORLEVEL%
echo stackprobe exit code %RC%
echo --- control: how far below sp may a write land? (-1073741819 = access violation)
set CRASHED=0
for %%n in (1 2 3 4 5 6 8 12 16 32 64) do (
  output\stackprobe.exe bad %%n
  call :report %%n
)
if "%CRASHED%"=="0" echo no control crashed: the test has no proven sensitivity & exit /b 1
exit /b %RC%

:report
set E=%ERRORLEVEL%
if not "%E%"=="0" (
  echo control: write %1 pages below sp CRASHED, exit code %E%
  set CRASHED=1
)
exit /b 0
