@echo off
REM Honor X50 Root Setup - one-shot command-line script
REM Usage: root_setup.bat

setlocal EnableDelayedExpansion

REM --- Find adb ---
where adb >nul 2>&1
if errorlevel 1 (
    echo [ERROR] adb not in PATH. Install Android SDK platform-tools.
    exit /b 1
)

REM --- Check device ---
adb devices | findstr /R "device$" >nul
if errorlevel 1 (
    echo [ERROR] No device connected. Enable USB debug and connect Honor X50.
    exit /b 1
)

echo [+] Device:
adb shell getprop ro.product.model

REM --- Check uptime (need >= 240s) ---
for /f "tokens=*" %%i in ('adb shell "cat /proc/uptime | awk '{print int($1)}'"') do set UPTIME=%%i
echo [+] Uptime: !UPTIME!s
if !UPTIME! LSS 240 (
    echo [WARN] Uptime ^< 240s. Wait 30s before exploit to clear early-boot antiroot...
    ping -n 31 127.0.0.1 >nul
)

REM --- Create RUNDIR ---
for /f "tokens=*" %%i in ('adb shell "echo /data/local/tmp/root_$(date +%%Y%%m%%d_%%H%%M%%S)"') do set RUNDIR=%%i
echo [+] RUNDIR: !RUNDIR!
adb shell "mkdir -p !RUNDIR!"

REM --- Push exploit ---
echo [+] Pushing exploit...
adb push "%~dp0exploit_ondevice_static" "!RUNDIR!/h80gt_exploit" >nul
adb shell "chmod 755 !RUNDIR!/h80gt_exploit"

REM --- Push su ---
echo [+] Pushing su binary...
adb push "%~dp0su_arm64" "/data/local/tmp/su" >nul
adb shell "chmod 755 /data/local/tmp/su"

REM --- Run exploit ---
set LOG=!RUNDIR!/exploit.log
echo [+] Running exploit (waiting up to 180s)...
adb shell "SE_LINUX=1 FLIP_SIG=1 KSU_RUNDIR=!RUNDIR! !RUNDIR!/h80gt_exploit > !LOG! 2>&1 &"

set DONE=0
for /L %%i in (1,1,90) do (
    ping -n 3 127.0.0.1 >nul
    adb shell "grep -q 'chain complete' !LOG! 2>/dev/null && echo OK" | findstr "OK" >nul
    if not errorlevel 1 (
        echo [+] Exploit complete after %%is
        set DONE=1
        goto :check_state
    )
    adb shell "grep -q 'short route failed' !LOG! 2>/dev/null && echo FAIL" | findstr "FAIL" >nul
    if not errorlevel 1 (
        echo [-] Exploit failed: route miss
        adb shell "tail -10 !LOG!"
        exit /b 1
    )
)

if !DONE!==0 (
    echo [-] Timeout waiting for exploit
    adb shell "tail -10 !LOG!"
    exit /b 1
)

:check_state
echo [+] State:
adb shell getenforce
adb shell cat /sys/module/module/parameters/sig_enforce

REM --- Setup su via cmd watcher ---
echo [+] Setting up su (chown + chmod 6755 + remount)...
adb shell "echo 'exec chown root:root /data/local/tmp/su && chmod 6755 /data/local/tmp/su && mount -o remount,rw,suid /data' > !RUNDIR!/cmd_req"
ping -n 3 127.0.0.1 >nul
adb shell "cat !RUNDIR!/cmd_out 2>/dev/null"

REM --- Unlock /data for shell/su domain (Honor f2fs seclabel trap) ---
echo [+] Unlocking /data (chmod 0777) for su access...
adb shell "echo 'exec chmod 0777 /data && chown system:system /data' > !RUNDIR!/cmd_req"
ping -n 3 127.0.0.1 >nul
adb shell "cat !RUNDIR!/cmd_out 2>/dev/null"

REM --- Verify ---
echo [+] Verify:
adb shell "ls -la /data/local/tmp/su"

REM --- Test ---
echo [+] Test su:
adb shell "/data/local/tmp/su -c id"

echo.
echo ============================================================
echo  ROOT READY
echo  adb shell /data/local/tmp/su              - interactive root
echo  adb shell /data/local/tmp/su -c 'cmd'     - single root cmd
echo ============================================================