@echo off
:: Usage: build_fdroid.bat [COMMIT_HASH/COMMIT_TAG]
setlocal

:: Convert backslashes to forward slashes, then to WSL paths
set "FWD_CD=%CD:\=/%"
set "FWD_DP0=%~dp0"
set "FWD_DP0=%FWD_DP0:\=/%"
for /f "delims=" %%P in ('wsl.exe wslpath "%FWD_CD%"') do set "WSL_CWD=%%P"
for /f "delims=" %%P in ('wsl.exe wslpath "%FWD_DP0%"') do set "WSL_SCRIPT_DIR=%%P"

echo Starting fdroid build...
wsl.exe bash "%WSL_SCRIPT_DIR%build_fdroid.sh" "%WSL_CWD%" %*

if %ERRORLEVEL% neq 0 (
    echo Build failed with error code %ERRORLEVEL%
	pause
    exit /b %ERRORLEVEL%
)

echo Done. APK should be in: %CD%
endlocal
pause
