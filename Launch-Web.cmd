@echo off
setlocal
rem Device CleanUpper - web launcher (opens in your browser, runs on this computer only)
rem Finds PowerShell 7 (pwsh) and starts the local web host. Keep the window open while you work.

set "HERE=%~dp0"
set "PWSH="

where pwsh >nul 2>&1 && set "PWSH=pwsh"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%LocalAppData%\Microsoft\PowerShell\7\pwsh.exe" set "PWSH=%LocalAppData%\Microsoft\PowerShell\7\pwsh.exe"

if not defined PWSH (
    echo.
    echo PowerShell 7 was not found.
    echo Install it with:   winget install --id Microsoft.PowerShell -e
    echo or download from:  https://aka.ms/powershell-release?tag=stable
    echo.
    pause
    exit /b 1
)

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%Start-Web.ps1"
if errorlevel 1 pause
endlocal
