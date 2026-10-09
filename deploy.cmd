@echo off
setlocal enabledelayedexpansion

rem ---------------------------------------------------------------------------
rem PhleaMarket deploy.
rem
rem Same pipeline as PhunMart2's, kept as its own copy because this is its own
rem repository: reaching across to another checkout for a build step is how you
rem end up unable to build one without the other.
rem
rem Deploys to:
rem   %USERPROFILE%\Zomboid\mods\<Mod>                - playable
rem   %USERPROFILE%\Zomboid\mods\<Mod>Dev             - dev-id variant
rem   %USERPROFILE%\Zomboid\Workshop\PhleaMarket      - upload staging
rem   %USERPROFILE%\Zomboid\Workshop\PhleaMarketDev   - dev upload staging
rem
rem The mod requires phunmart2, so it does nothing on its own: PhunMart 2 has to
rem be deployed and enabled alongside it.
rem ---------------------------------------------------------------------------

set MODS=PhleaMarket

set SRC=%~dp0
set MODDIR=%USERPROFILE%\Zomboid\mods
set WS=%USERPROFILE%\Zomboid\Workshop\PhleaMarket
set WSDEV=%USERPROFILE%\Zomboid\Workshop\PhleaMarketDev

echo [PhleaMarket] Deploying to %MODDIR%

rem --- Live mods -------------------------------------------------------------
for %%M in (%MODS%) do (
    rmdir /S /Q "%MODDIR%\%%M" 2>nul
    xcopy "%SRC%Contents\mods\%%M" "%MODDIR%\%%M" /Y /I /E /F /Q /EXCLUDE:%SRC%xclude >nul
    if errorlevel 1 echo [PhleaMarket] FAILED copying %%M
)

rem --- Dev-id variants -------------------------------------------------------
rem Copy the live mod, then overlay Tests\root\<Mod> which swaps in a mod.info
rem carrying the dev ids. Lets both versions sit side by side in one install.
for %%M in (%MODS%) do (
    rmdir /S /Q "%MODDIR%\%%MDev" 2>nul
    xcopy "%MODDIR%\%%M" "%MODDIR%\%%MDev" /Y /I /E /F /Q >nul
    if exist "%SRC%Tests\root\%%M" (
        xcopy "%SRC%Tests\root\%%M" "%MODDIR%\%%MDev" /Y /I /E /F /Q >nul
    )
)

rem --- Workshop staging, live ------------------------------------------------
rmdir /S /Q "%WS%" 2>nul
xcopy "%SRC%" "%WS%" /Y /I /E /F /Q /EXCLUDE:%SRC%xclude >nul
rmdir /S /Q "%WS%\Tests" 2>nul
rmdir /S /Q "%WS%\Contents" 2>nul
for %%M in (%MODS%) do (
    xcopy "%MODDIR%\%%M" "%WS%\Contents\mods\%%M" /Y /I /E /F /Q >nul
)

rem --- Workshop staging, test ------------------------------------------------
rem Same mod folder names as live, but each carries the dev mod.info, and the
rem workshop.txt / preview.png come from Tests\.
rmdir /S /Q "%WSDEV%" 2>nul
xcopy "%SRC%" "%WSDEV%" /Y /I /E /F /Q /EXCLUDE:%SRC%xclude >nul
rmdir /S /Q "%WSDEV%\Tests" 2>nul
rmdir /S /Q "%WSDEV%\Contents" 2>nul
for %%M in (%MODS%) do (
    xcopy "%MODDIR%\%%MDev" "%WSDEV%\Contents\mods\%%M" /Y /I /E /F /Q >nul
)
copy /Y "%SRC%Tests\workshop.txt" "%WSDEV%\workshop.txt" >nul
if exist "%SRC%Tests\preview.png" copy /Y "%SRC%Tests\preview.png" "%WSDEV%\preview.png" >nul

echo [PhleaMarket] Done.
endlocal
