@echo off
setlocal

REM ============================================================================
REM  zip-project.bat
REM  Put this file in your project's root folder (next to package.json) and
REM  double-click it. It creates a clean zip in the PARENT folder, so the zip
REM  never ends up inside itself.
REM
REM  Left OUT of the zip: node_modules, real .env files (secrets), build
REM  output, caches, logs, and any other .zip files.
REM  Kept: .git (so branches and commits travel with the zip) and .env.example
REM  (it only holds empty variable names).
REM  Needs Windows 10 / 11 (uses the built-in "tar" command).
REM ============================================================================

pushd "%~dp0"

if not exist "package.json" (
  echo ERROR: package.json not found. Put this file in the project root folder.
  popd
  pause
  exit /b 1
)

where tar >nul 2>nul
if errorlevel 1 (
  echo ERROR: the "tar" command was not found. This needs Windows 10 or 11.
  popd
  pause
  exit /b 1
)

for %%I in ("%CD%") do set "NAME=%%~nxI"
for %%I in ("%CD%\..") do set "PARENT=%%~fI"
for /f %%I in ('powershell -nologo -noprofile -command "Get-Date -Format yyyyMMdd-HHmm"') do set "STAMP=%%I"

set "OUT=%PARENT%\%NAME%-%STAMP%.zip"

echo Zipping "%CD%"
echo        to "%OUT%"
echo.

tar -a -c -f "%OUT%" ^
  --exclude=node_modules ^
  --exclude=.env ^
  --exclude=.env.local ^
  --exclude=.env.development ^
  --exclude=.env.production ^
  --exclude=.env.staging ^
  --exclude=.env.test ^
  --exclude=.env.*.local ^
  --exclude=.dev.vars ^
  --exclude=dist ^
  --exclude=.output ^
  --exclude=.vinxi ^
  --exclude=.tanstack ^
  --exclude=.wrangler ^
  --exclude=.netlify ^
  --exclude=.vercel ^
  --exclude=.turbo ^
  --exclude=.cache ^
  --exclude=coverage ^
  --exclude=*.tsbuildinfo ^
  --exclude=*.log ^
  --exclude=*.zip ^
  --exclude=.DS_Store ^
  --exclude=Thumbs.db ^
  .

if errorlevel 1 (
  echo.
  echo ERROR: zipping failed.
  popd
  pause
  exit /b 1
)

echo.
echo Safety check: looking for things that should NOT be in the zip...
tar -tf "%OUT%" | findstr /i /r /c:"node_modules/" /c:"\.env$" /c:"\.env\.local$" /c:"\.env\.production$" /c:"\.env\.development$" /c:"\.dev\.vars$" >nul
if not errorlevel 1 (
  echo WARNING: the zip may contain node_modules or a real .env file.
  echo Do NOT share it. Delete it and tell me what the check found.
  popd
  pause
  exit /b 2
)
echo OK - none found.

echo.
echo Done:
echo   %OUT%
popd
pause
endlocal