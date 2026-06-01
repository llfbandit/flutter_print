@echo off
setlocal

cd /d "%~dp0.."

echo Generating Pigeon messages...
dart run pigeon --input pigeon/messages.dart
if %ERRORLEVEL% neq 0 (
  echo Pigeon generation failed.
  exit /b %ERRORLEVEL%
)

echo Copying Messages.swift to macOS...
copy /Y "ios\flutter_print\Sources\flutter_print\Messages.swift" ^
        "macos\flutter_print\Sources\flutter_print\Messages.swift"
if %ERRORLEVEL% neq 0 (
  echo Copy failed.
  exit /b %ERRORLEVEL%
)

echo Done.
