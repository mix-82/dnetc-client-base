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
echo --- test
output\stackprobe.exe
set RC=%ERRORLEVEL%
echo stackprobe exit code %RC%
echo --- control
output\stackprobe.exe bad
set RCB=%ERRORLEVEL%
echo control exit code %RCB% (0xC0000005 = -1073741819 = access violation expected)
if "%RCB%"=="0" exit /b 1
exit /b %RC%
