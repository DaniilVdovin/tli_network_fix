@echo off
chcp 65001 > nul
:: ============================================================
:: update-zapret.bat
:: Copies the TLI fix files into the zapret folder, if the
:: zapret folder is next to this one (..\zapret-discord-youtube).
::
::   tli_network_fix\            (this folder)
::   zapret-discord-youtube\     (expected next to it)
::
:: Copies:
::   general (Torchlight).bat   -> zapret root
::   tli-hosts-fix.ps1          -> zapret root
::   lists\ipset-torchlight.txt -> zapret lists\
:: Other zapret files are never touched.
:: ============================================================

set "SRC=%~dp0"
set "ZAPRET=%~dp0..\zapret-discord-youtube"

if not exist "%ZAPRET%" (
    echo.
    echo zapret folder not found next to this one:
    echo   %ZAPRET%
    echo.
    echo Copy the files manually - see README, Setup.
    pause
    exit /b 1
)

echo Updating zapret folder: %ZAPRET%
echo.

copy /y "%SRC%general (Torchlight).bat" "%ZAPRET%\" || goto :err
copy /y "%SRC%tli-hosts-fix.ps1" "%ZAPRET%\" || goto :err
if not exist "%ZAPRET%\lists" mkdir "%ZAPRET%\lists"
copy /y "%SRC%lists\ipset-torchlight.txt" "%ZAPRET%\lists\" || goto :err

echo.
echo Done, copied:
echo   general (Torchlight).bat
echo   tli-hosts-fix.ps1
echo   lists\ipset-torchlight.txt
echo.
pause
exit /b 0

:err
echo.
echo Copy failed.
pause
exit /b 1
