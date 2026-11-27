@echo off
rem cmdcode.cmd program [arguments...]
rem Runs the program from the current directory and writes the exit code
rem that cmd.exe sees to code.txt. Used by exitcodes.sh with CMDCODE=1.
setlocal
set PROG=%1
set ARGS=
:next
shift
if "%~1"=="" goto run
set ARGS=%ARGS% %1
goto next
:run
%PROG%%ARGS%
set RC=%ERRORLEVEL%
>code.txt echo %RC%
exit /b %RC%
