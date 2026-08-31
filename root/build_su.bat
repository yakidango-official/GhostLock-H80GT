@echo off
REM Build static ARM64 su binary using Android NDK
REM Usage: build_su.bat

set NDK=D:\android-ndk-r27-windows\android-ndk-r27
set CC=%NDK%\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android35-clang.cmd

if not exist "%CC%" (
    echo NDK clang not found: %CC%
    exit /b 1
)

"%CC%" -static -o "%~dp0su_arm64" "%~dp0su.c"
if errorlevel 1 (
    echo Build failed
    exit /b 1
)

echo Built: %~dp0su_arm64
dir "%~dp0su_arm64" | findstr "su_arm64"