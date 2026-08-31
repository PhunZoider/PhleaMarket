@echo off
setlocal enabledelayedexpansion

rem ---------------------------------------------------------------------------
rem Runs the Lua test suites against a runtime cut down to PZ B42.20.4.
rem See README.md in this folder for what that means and why it matters.
rem
rem Unlike PhunMart2's, this one globs test_*.lua rather than naming each suite.
rem Nothing here depends on running in a particular order, and a list that has
rem to be edited every time a file is added is a list that eventually forgets
rem one.
rem ---------------------------------------------------------------------------

set LUA=
where luajit >nul 2>nul && set LUA=luajit
if "%LUA%"=="" if exist "%LOCALAPPDATA%\Programs\LuaJIT\bin\luajit.exe" set LUA=%LOCALAPPDATA%\Programs\LuaJIT\bin\luajit.exe

if "%LUA%"=="" (
    echo No LuaJIT found.
    echo Install it with:  winget install --id DEVCOM.LuaJIT --source winget
    exit /b 1
)

set FAILED=0
set FOUND=0

for %%T in ("%~dp0test_*.lua") do (
    set FOUND=1
    echo.
    echo ==================== %%~nT ====================
    "%LUA%" "%%~fT"
    if errorlevel 1 set FAILED=1
)

echo.
if "%FOUND%"=="0" (
    echo No test_*.lua suites found.
    exit /b 1
)
if "%FAILED%"=="1" (
    echo SUITE FAILED
    exit /b 1
)
echo All suites passed.
endlocal
