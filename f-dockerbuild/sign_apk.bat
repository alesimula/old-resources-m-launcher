@echo off
setlocal

for /f "delims=" %%P in ('wsl.exe wslpath "%CD%"') do set "WSL_CWD=%%P"

echo Signing APK...
wsl.exe bash -c "cd '%WSL_CWD%' && apksigner sign --ks /PATH/TO/KEYSTORE --ks-key-alias KEY_ALIAS --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled false --out Murine-launcher.apk app.murinelauncher-aosp-withoutQuickstep-release-unsigned.apk"

if %ERRORLEVEL% neq 0 (
    echo Signing failed with error code %ERRORLEVEL%
	pause
    exit /b %ERRORLEVEL%
)

echo Done. Signed APK: Murine-launcher.apk
endlocal
pause
